/// worker isolate 的入口与命令循环。
///
/// ## 为什么用 `listen` 而不是 `await for`
///
/// 任务本体（[scanDirectory]）内部会 await，`await for` 会把整个命令循环堵在
/// 这一次迭代上：任务跑完之前，`CmdCancel` 根本进不来，取消就成了摆设。
/// 用 `listen` 才能做到「任务在跑的同时命令循环还活着」。
///
/// 代价是处理器之间会交错，所以要自己保证「同一时刻只有一个任务」——
/// `_WorkerState._busy` 就是干这个的。
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'backends/native_backend.dart';
import 'models.dart';
import 'protocol.dart';
import 'scanner.dart';
import 'tick_merge.dart';

/// 解压进度在 worker 侧的合并间隔（三层节流的第一层）。
///
/// 7-Zip 报进度远比 UI 需要得密（大文件里每写几 MB 就报一次），原样转发会把
/// 端口和主 isolate 一起淹掉。丢样的实现在 [TickMerger]，三层各自省什么的
/// 完整说明也在那个文件里。
///
/// 120ms 这个数的来历：它比主 isolate 那一层的 125ms（8Hz）略小。**必须略小**
/// —— 两层取同一个值的话，某些采样时刻会两层同时开窗，连续两条 tick 都落在
/// 各自的窗口里被各自吃掉，界面在那一段就没有任何更新；错开一点让两层的窗口
/// 边界不要长期重合。
const Duration kExtractTickMerge = Duration(milliseconds: 120);

/// isolate 入口。顶层函数，`Isolate.spawn` 要求如此。
void workerMain(SendPort toMain) {
  final inbox = ReceivePort();
  final state = _WorkerState(toMain);

  // 握手：先把命令端口交出去，再开始收命令。
  toMain.send(EvReady(inbox.sendPort));

  inbox.listen((Object? message) async {
    if (message is! WorkerCmd) return;
    try {
      // 交换性命令（取消）优先于任务类命令，且不受 busy 影响。
      switch (message) {
        case CmdShutdown():
          inbox.close();
          return;
        case CmdCancel():
          state.cancel();
          return;
        case CmdPing(:final token):
          toMain.send(EvPong(token));
          return;
        case CmdScan():
          await state.runScan(message);
        case CmdExtract():
          await state.runExtract(message);
      }
    } catch (e, st) {
      // 兜底：任何漏网的异常都不能让 worker 静默死掉 ——
      // 主 isolate 那边会表现为 Future 永不完成。
      toMain.send(EvFailed(
        jobId: message is CmdScan ? message.jobId : 0,
        message: '工作线程内部错误：$e',
        detail: st.toString(),
      ));
    }
  });
}

class _WorkerState {
  _WorkerState(this.toMain);

  final SendPort toMain;

  /// 是否有任务在跑。扫描与解压共用一个槽位。
  bool _busy = false;

  /// 取消信号用**计数**而不是布尔：一个布尔标志在任务结束后要记得复位，
  /// 漏了就变成「下一个任务一启动就自杀」。计数则天然只作用于
  /// 捕获了旧值的那次任务。
  int _cancelEpoch = 0;

  void cancel() {
    _cancelEpoch++;
  }

  Future<void> runScan(CmdScan cmd) async {
    if (_busy) {
      toMain.send(EvFailed(
        jobId: cmd.jobId,
        message: '上一个任务还没结束，拒绝并发扫描',
      ));
      return;
    }

    _busy = true;
    final epoch = _cancelEpoch;
    final watch = Stopwatch()..start();

    try {
      final summary = await scanDirectory(
        cmd.rootPath,
        options: cmd.options,
        skipDirs: cmd.skipDirs,
        baseDepth: cmd.depth,
        onTick: (tick) => toMain.send(EvScanTick(jobId: cmd.jobId, tick: tick)),
        isCancelled: () => epoch != _cancelEpoch,
      );
      toMain.send(EvScanDone(
        jobId: cmd.jobId,
        summary: summary,
        elapsed: watch.elapsed,
      ));
    } catch (e, st) {
      toMain.send(EvFailed(
        jobId: cmd.jobId,
        message: '扫描失败：$e',
        detail: st.toString(),
      ));
    } finally {
      _busy = false;
    }
  }

  Future<void> runExtract(CmdExtract cmd) async {
    if (_busy) {
      toMain.send(EvFailed(
        jobId: cmd.jobId,
        message: '上一个任务还没结束，拒绝并发解压',
      ));
      return;
    }

    _busy = true;
    // 解压本体（同步 FFI）期间取消进不来，但**之后的嵌套扫描是可以被打断的**
    // ——那时命令循环是活的。所以这里如实捕获，让取消至少能中止扫描那一段。
    final epoch = _cancelEpoch;

    try {
      // ---- 第一层节流：合并进度 ----
      // 这里刻意**不**用 Stopwatch 之外的东西：回调跑在解压线程上，
      // 多算一点就多一分阻塞 7-Zip。所以 `TickMerger` 只做一次减法，
      // 时间由这里读好再传进去。
      final merger = TickMerger(kExtractTickMerge);
      final clock = Stopwatch()..start();

      final outcome = extractArchive(
        parts: cmd.parts,
        outDir: cmd.outDir,
        password: cmd.password,
        limits: cmd.limits,
        onTick: (tick) {
          if (!merger.shouldEmit(clock.elapsed)) return;
          toMain.send(EvExtractTick(jobId: cmd.jobId, tick: tick));
        },
        // P1 不支持解压中途取消：本回调同步跑在被堵住的 worker 上，
        // 没有任何东西能在解压期间把「取消」写进这里。诚实返回 false，
        // 而不是留个永远读不到的标志假装支持。
        shouldCancel: () => false,
      );

      // ---- 嵌套扫描（需求 1）----
      // 只在调用方要的时候做。**扫的是 outcome.outDir 而不是 cmd.outDir**：
      // 重名时前者才是真正落盘的那个目录。
      //
      // 这一步跑在解压**之后**、和它同一轮 await 里，所以期间来的 CmdCancel
      // 同样处理不到（和 CmdExtract 的限制一致）。扫描本身按文件数每
      // kTickEveryFiles 才报一次，对大归档也不会把端口刷爆。
      final done = cmd.recursive
          ? outcome.withNested(await _findNested(
              cmd: cmd,
              outDir: outcome.outDir,
              isCancelled: () => epoch != _cancelEpoch,
            ))
          : outcome;

      toMain.send(EvExtractDone(jobId: cmd.jobId, outcome: done));
    } catch (e, st) {
      toMain.send(EvFailed(
        jobId: cmd.jobId,
        message: '解压失败：${_describe(e)}',
        detail: st.toString(),
        code: e is EngineException ? e.code : null,
        // 炸弹裁决也跨过去：主 isolate 要凭它区分「包坏了」和「是炸弹」。
        breach: e is EngineException ? e.breach : null,
      ));
    } finally {
      _busy = false;
    }
  }

  /// 异常 → 给用户看的一句话。
  ///
  /// [EngineException] 的 message 已经是「事实 + 建议」的完整句子
  /// （见 native_backend 的 _translate），原样用；其余异常才加前缀。
  static String _describe(Object e) => e is EngineException ? e.message : '$e';

  /// 在刚解出来的目录里找嵌套压缩包（需求 1）。
  ///
  /// 走 [scanFileList] 而不是 [scanDirectory] —— 后者会**遍历**目录，把
  /// 我们这一层产出的东西当成源目录再扫一遍。这里只要「我刚写下去的那些
  /// 文件」，扫描器那边也把这条路径写成了它的用途（见 scanner.dart）。
  ///
  /// `baseDepth: cmd.depth + 1` 把嵌套包的层级如实抬一层；能不能真的入队
  /// 由上层按深度顶和自引用判定决定，这里不越权。
  static Future<List<ScanItem>> _findNested({
    required CmdExtract cmd,
    required String outDir,
    required bool Function() isCancelled,
  }) async {
    final files = await _listFiles(outDir);
    if (files.isEmpty) return const [];

    final summary = await scanFileList(
      files,
      options: cmd.options,
      baseDepth: cmd.depth + 1,
      isCancelled: isCancelled,
    );
    return summary.items;
  }

  /// 递归列出 [dir] 下的**普通文件**，按路径排序。
  ///
  /// - `followLinks: false`：软链接一律不跟（需求 1 的安全策略，见计划 3.3）。
  ///   链接既不会被遍历，也不会出现在结果里 —— `Directory.list` 对软链接
  ///   给的是 [Link] 而不是 [File]，`whereType<File>()` 自然把它滤掉。
  /// - 排序是为了让同一棵树上两次扫描给出同样的顺序，进度与日志才可复现。
  /// - 封顶 [kMaxScannedFiles]：解一个把硬盘塞满的包时，先建一张一千万行的
  ///   路径表再让扫描器去截断，内存就先炸了。这里和扫描器的截断阈值取同一个
  ///   数，于是「列出来的」和「扫得到的」不会对不上。
  static Future<List<String>> _listFiles(String dir) async {
    final root = Directory(dir);
    if (!await root.exists()) return const [];

    final out = <String>[];
    await for (final entity
        in root.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      out.add(entity.path);
      if (out.length >= kMaxScannedFiles) break;
    }
    out.sort();
    return out;
  }
}
