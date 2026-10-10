/// 引擎控制器：主 isolate 一侧的接口。
///
/// 职责有三件，且只有三件：
///
/// 1. **管 isolate 的生命周期**。一个长驻 worker，握手后一直活着 ——
///    不用 `Isolate.run`，因为它只返回单个 Future，没法流式推进度，
///    也没法协作取消。
/// 2. **节流**。worker 侧已按文件数合并过一次，这里再按时间合并一次。
///    四个页面都在 `IndexedStack` 里、各自包了一层 `ListenableBuilder`，
///    每次 `notifyListeners` 都会重建全部四棵树 —— 不节流必然掉帧。
/// 3. **把回调式的事件翻译成可 await 的 Future**。UI 那边 `await` 一个扫描
///    比订阅事件流好懂；进度仍然是回调，因为它本质是流。
///
/// **不做**时间数学（EWMA / ETA）。进度快照里的数字怎么算由
/// [ProgressMeter] 负责，等 P1 有真实字节计数时接进来。
library;

import 'dart:async';
import 'dart:isolate';

import 'limits.dart';
import 'models.dart';
import 'protocol.dart';
import 'scanner.dart';
import 'tick_throttle.dart';
import 'worker.dart';

/// 进度节流间隔（8Hz）。
///
/// 尾沿（trailing-edge）而不是首沿：首沿会让「第一次进度」立刻显示，
/// 之后每 125ms 才更新一次，而尾沿保证**最后一条**进度一定会发出去，
/// 进度条不会停在半路。
const Duration kProgressThrottle = Duration(milliseconds: 125);

/// [EngineController.dispose] 给 worker 自己收尾的宽限期。
///
/// 为什么不能像以前那样直接 `kill(immediate)`：解压现在跑在 **C++ 自己的
/// 线程**上，而 join 它的只能是 `duz_close` —— 那要 worker isolate 活到任务
/// 收尾才跑得到。硬杀会把那条线程变成孤儿：还在往盘上写，却没人 join、
/// 没人释放归档句柄。
///
/// 2 秒的依据：worker 侧从收到 `CmdShutdown` 到跑完 `finally` 只剩几步
/// Dart 代码（真正慢的「等 7-Zip 在下一个进度点 unwind」在 `duz_close` 的
/// join 里，而那是原生侧的事，不受 isolate 调度影响）。宽限期是兜底而不是
/// 常态 —— 超时说明 worker 真的卡住了（比如脚本跑飞），那时硬杀是唯一选择。
const Duration kShutdownGrace = Duration(seconds: 2);

/// 一次扫描的最终结果。
typedef ScanOutcome = ({ScanSummary summary, Duration elapsed});

/// worker isolate 的入口：拿一个 `SendPort` 就开始跑命令循环。
typedef WorkerEntry = void Function(SendPort toMain);

class EngineController {
  EngineController({
    this.throttle = kProgressThrottle,
    this.entryPoint = workerMain,
  });

  /// 进度节流间隔。传 [Duration.zero] 关闭节流（单测用，让事件同步到达）。
  final Duration throttle;

  /// 起哪个入口当 worker。**留出这个口子是为了测协议边界**。
  ///
  /// 生产永远用 [workerMain]，只有单测会换成假 worker。要它是因为：消息在
  /// **同一个 isolate 里构造、断言、扔掉**是测不到搬运的 —— 某个字段忘了跨
  /// 边界传，编译期合法、单测全绿，只有真机上表现成「弹窗上的说法不对」。
  /// 这个坑真踩过（见 `EvFailed.uncertain`）。有了假 worker，就能拿一条假的
  /// [EvFailed] 走一遍**真的** `Isolate.spawn`，把每个字段钉住。
  final WorkerEntry entryPoint;

  /// 节流后的扫描进度回调。**在节流窗口内多次 tick 只会调一次，且参数是最新的那条。**
  void Function(ScanTick tick)? onScanTick;

  /// 节流后的解压进度回调，语义同 [onScanTick]。
  void Function(ExtractTick tick)? onExtractTick;

  /// **后台**时那一份解压进度。前台时**不会**被调用（那时走 [onExtractTick]）。
  ///
  /// 它是给「不重建任何东西的消费者」准备的，目前只有一个：前台服务那条常驻
  /// 通知（见 `AppState._onExtractTickBackground`）。界面那一路在后台被整条掐掉
  /// 是对的 —— 四棵树没人看；但通知恰恰相反，后台时它是唯一还被人看的东西。
  ///
  /// 频率不低（worker 侧的合并间隔，约 8Hz），所以消费者自己要再节一层 ——
  /// 推一条通知要过一次系统通知服务，比重建一棵树还贵。
  void Function(ExtractTick tick)? onExtractTickBackground;

  ReceivePort? _inbox;
  ReceivePort? _errors;
  ReceivePort? _exits;
  Isolate? _isolate;
  SendPort? _toWorker;
  final Completer<void> _ready = Completer<void>();
  /// worker isolate 真的结束了。`dispose()` 靠它把宽限期缩短成「一退出就走」。
  final Completer<void> _exited = Completer<void>();
  bool _disposed = false;

  int _nextJobId = 1;
  int? _activeJob;
  final Map<int, Completer<void>> _pingWaiters = {};
  final Map<int, Completer<ScanOutcome>> _scanWaiters = {};
  final Map<int, Completer<ExtractOutcome>> _extractWaiters = {};

  bool _foreground = true;
  // 扫描**没有**后台那一档：它既没有常驻通知，也没有别的后台消费者，
  // 后台发出去的每一份都是白发的。
  late final _scanThrottle = TickThrottle<ScanTick>(
    delay: throttle,
    emit: (t) => onScanTick?.call(t),
    isForeground: () => _foreground,
  );
  late final _extractThrottle = TickThrottle<ExtractTick>(
    delay: throttle,
    emit: (t) => onExtractTick?.call(t),
    isForeground: () => _foreground,
    background: (t) => onExtractTickBackground?.call(t),
  );

  bool get isRunning => _isolate != null && !_disposed;

  /// 释放之后再用就是编程错误：`_toWorker` 已经是 null，不拦住会踩空断言。
  ///
  /// **必须在每个 `await` 之后调用**，不能只在方法开头调一次：`await` 是
  /// 挂起点，`dispose()` 完全可能在这期间跑完（调用方通常是
  /// `state.dispose(); controller.dispose();` 这种同步序列），
  /// 开头检查过、拿到锁之前对象就被释放了 —— 典型的 TOCTOU。
  void _ensureAlive() {
    if (_disposed) throw const EngineException('控制器已释放');
  }

  // -------------------------------------------------------------------------
  // 生命周期
  // -------------------------------------------------------------------------

  /// 启动 worker 并完成握手。重复调用是空操作。
  Future<void> start() async {
    if (_disposed) return;
    if (_isolate != null) return;

    final inbox = ReceivePort();
    _inbox = inbox;
    inbox.listen(_onMessage);

    // 单独的 error 端口：worker 如果在握手前就崩了，没有它的话
    // `_ready.future` 会永远挂着，界面表现为「点了没反应」。
    final errors = ReceivePort();
    _errors = errors;
    errors.listen((Object? e) {
      final text = e is List && e.isNotEmpty ? '${e.first}' : '$e';
      if (!_ready.isCompleted) {
        _ready.completeError(EngineException('工作线程启动失败：$text'));
      } else {
        _failActive(EngineException('工作线程异常：$text'));
      }
    });

    // 退出端口：`dispose()` 的宽限期靠它提前结束（见 [_shutdown]）。
    final exits = ReceivePort();
    _exits = exits;
    exits.listen((_) {
      if (!_exited.isCompleted) _exited.complete();
    });

    _isolate = await Isolate.spawn(
      entryPoint,
      inbox.sendPort,
      debugName: 'duz_worker',
      onError: errors.sendPort,
      onExit: exits.sendPort,
      errorsAreFatal: false,
    );

    try {
      await _ready.future;
    } catch (_) {
      // 握手失败说明 worker 根本没起来，把端口收掉，别留着泄漏。
      // dispose 本身有幂等守卫，即使已经被释放过也不会出错。
      dispose();
      rethrow;
    }
  }

  /// 收掉 worker。
  ///
  /// **本方法是同步的**（`_disposed` 立刻置位、在飞任务立刻以异常结束、端口
  /// 立刻关掉），但收掉那条 isolate 本身是**两段式**的：
  ///
  /// 1. 先 `CmdCancel` + `CmdShutdown` 请它自己收尾 —— 收到 `CmdShutdown` 的
  ///    worker 会等在飞任务跑完再关端口（见 `worker.dart`），而解压那条路上
  ///    「任务跑完」就是 `duz_close`，**只有它能 join C++ 那条解压线程**。
  /// 2. 宽限期（[kShutdownGrace]）过了才 `kill(immediate)` 硬杀。
  ///
  /// 以前是无条件硬杀。那在同步 FFI 时代没问题（杀掉的只是被堵住的 Dart 栈），
  /// 现在却会留下一条还在写盘的孤儿线程 —— 没人 join、没人释放归档句柄。
  ///
  /// 硬杀本身仍留在末尾兜底：worker 真卡住时（比如用户脚本跑飞），那是唯一
  /// 的出路。所以调用方**不必**等 [_shutdown]，它的返回值只给测试用。
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _scanThrottle.drop();
    _extractThrottle.drop();

    // 抛 EngineException 而不是 StateError：调用方只需要 catch 一种异常。
    for (final c in _scanWaiters.values) {
      if (!c.isCompleted) {
        c.completeError(const EngineException('控制器已释放，任务中断'));
      }
    }
    _scanWaiters.clear();
    for (final c in _extractWaiters.values) {
      if (!c.isCompleted) {
        c.completeError(const EngineException('控制器已释放，任务中断'));
      }
    }
    _extractWaiters.clear();
    _activeJob = null;
    for (final c in _pingWaiters.values) {
      if (!c.isCompleted) c.completeError(const EngineException('控制器已释放'));
    }
    _pingWaiters.clear();

    final worker = _toWorker;
    final isolate = _isolate;

    _inbox?.close();
    _errors?.close();
    _exits?.close();
    _inbox = null;
    _errors = null;
    _exits = null;
    _toWorker = null;
    _isolate = null;

    if (isolate == null) return;
    unawaited(_shutdown(worker, isolate));
  }

  /// [dispose] 的第二段。单独抽出来只为让它是个 async 函数 —— `dispose` 自己
  /// 必须同步返回（调用方是 `state.dispose(); controller.dispose();` 这种序列）。
  Future<void> _shutdown(SendPort? worker, Isolate isolate) async {
    // 顺序要紧：先取消，于是那条在飞的解压会尽快往原生侧送 cancel；紧接着的
    // shutdown 才不会被一个还要跑几分钟的解压拖住。
    worker?.send(const CmdCancel());
    worker?.send(const CmdShutdown());

    // 用可取消的 Timer 而不是 `Future.delayed`：后者在 worker 早早退出的正常
    // 情况下仍会留下一个跑满 2 秒的定时器，而 widget 测试会把「测试结束时还
    // 挂着的定时器」当成失败。
    final grace = Completer<void>();
    final timer = Timer(kShutdownGrace, () {
      if (!grace.isCompleted) grace.complete();
    });
    await Future.any([_exited.future, grace.future]);
    timer.cancel();

    if (!_exited.isCompleted) {
      // 宽限期到了它还没退出 —— 硬杀是唯一出路。
      isolate.kill(priority: Isolate.immediate);
    }
  }

  // -------------------------------------------------------------------------
  // 命令
  // -------------------------------------------------------------------------

  /// 往返一次存活探测。测试与「引擎是否还活着」的健康检查用。
  Future<void> ping([int token = 0]) async {
    await _ready.future;
    // 只能在这个 await **之后**检查：dispose 可能刚好在这期间跑完。
    _ensureAlive();
    final c = Completer<void>();
    _pingWaiters[token] = c;
    _toWorker!.send(CmdPing(token));
    return c.future;
  }

  /// 扫描一个目录，等到扫描结束。
  ///
  /// 取消**不是**异常：`cancel()` 之后这个 Future 正常完成，只是
  /// `summary.warnings` 里会多一条「已取消」。
  Future<ScanOutcome> scan({
    required String rootPath,
    ScanOptions options = const ScanOptions(),
    Set<String> skipDirs = const {},
    int depth = 0,
  }) async {
    await _ready.future;
    // 只能在这个 await **之后**检查：dispose 可能刚好在这期间跑完。
    _ensureAlive();
    if (_activeJob != null) {
      throw const EngineException('已有任务在运行');
    }

    final jobId = _nextJobId++;
    _activeJob = jobId;
    final c = Completer<ScanOutcome>();
    _scanWaiters[jobId] = c;

    _toWorker!.send(CmdScan(
      jobId: jobId,
      rootPath: rootPath,
      options: options,
      skipDirs: skipDirs,
      depth: depth,
    ));

    return c.future;
  }

  /// 扫描**用户点名的那些文件**（首页「选择文件」那条路）。
  ///
  /// 与 [scan] 的三点差别，全在 [CmdScanFiles] 的注释里：不碰同目录别的文件、
  /// 容器防线让位、分卷在同目录里自动补齐。
  Future<ScanOutcome> scanFiles({
    required List<String> paths,
    ScanOptions options = const ScanOptions(),
    bool ignoreContainers = true,
    bool expandSplitVolumes = true,
  }) async {
    await _ready.future;
    // 只能在这个 await **之后**检查：dispose 可能刚好在这期间跑完。
    _ensureAlive();
    if (_activeJob != null) {
      throw const EngineException('已有任务在运行');
    }

    final jobId = _nextJobId++;
    _activeJob = jobId;
    final c = Completer<ScanOutcome>();
    _scanWaiters[jobId] = c;

    _toWorker!.send(CmdScanFiles(
      jobId: jobId,
      paths: paths,
      options: options,
      ignoreContainers: ignoreContainers,
      expandSplitVolumes: expandSplitVolumes,
    ));

    return c.future;
  }

  /// 解压一组分卷到 [outDir]，等到解压结束。
  ///
  /// 进度走 [onExtractTick]（已节流），失败以 [EngineException] 抛出 ——
  /// 注意 `code == DUZ_ERR_PASSWORD` 时值得换下一个候选密码重试，
  /// 而不是把它当成「这个包坏了」。
  ///
  /// **取消在解压期间生效**：解压跑在原生侧自己的线程上，这里只是轮询，所以
  /// [cancel] 发的信号在下一轮轮询就会被送到引擎。被中止时这个 Future 正常
  /// 返回一个 `cancelled: true` 的 [ExtractOutcome]（不是抛异常）。
  ///
  /// [recursive] 为真时，返回值的 [ExtractOutcome.nested] 会带上「刚解出来的
  /// 内容里又发现的压缩包」，层级已经抬到 `depth + 1`。**解不解它们由调用方
  /// 决定** —— 这个方法只负责报告，不负责继续。
  Future<ExtractOutcome> extract({
    required List<String> parts,
    required String outDir,
    String? password,
    int depth = 0,
    bool recursive = false,
    ScanOptions options = const ScanOptions(),
    LimitThresholds limits = LimitThresholds.standard,
    int? availableBytes,
  }) async {
    await _ready.future;
    // 只能在这个 await **之后**检查：dispose 可能刚好在这期间跑完。
    _ensureAlive();
    if (parts.isEmpty) {
      throw const EngineException('没有可解压的分卷');
    }
    if (_activeJob != null) {
      throw const EngineException('已有任务在运行');
    }

    final jobId = _nextJobId++;
    _activeJob = jobId;
    final c = Completer<ExtractOutcome>();
    _extractWaiters[jobId] = c;

    _toWorker!.send(CmdExtract(
      jobId: jobId,
      parts: parts,
      outDir: outDir,
      password: password,
      depth: depth,
      recursive: recursive,
      options: options,
      limits: limits,
      availableBytes: availableBytes,
    ));

    return c.future;
  }

  /// 请求中止当前任务（扫描或解压）。没有任务在跑时是空操作。
  ///
  /// 名字里不再带 `Scan`：它两件事都能中止了。扫描在下一个条目边界响应，
  /// 解压在下一轮轮询把取消送到原生侧 —— 两条路都是「尽快」，不是「立刻」。
  ///
  /// **取消不是异常**：被中止的那个 Future 正常完成（扫描多一条「已取消」
  /// 的 warning，解压的 outcome 带 `cancelled: true`）。
  Future<void> cancel() async {
    await _ready.future;
    // 只能在这个 await **之后**检查：dispose 可能刚好在这期间跑完。
    _ensureAlive();
    if (_activeJob == null) return;
    _toWorker!.send(const CmdCancel());
  }

  // -------------------------------------------------------------------------
  // 前后台
  // -------------------------------------------------------------------------

  /// 切到后台时**界面那一路只标脏不发事件**，回到前台立刻补发最后一条。
  ///
  /// 后台时 Activity 已经不可见，每一次 `notifyListeners` 白重建四棵树。
  /// 唯一的例外是解压的 [onExtractTickBackground]：它不重建任何东西，而且在
  /// 后台时比在前台时更重要（那条常驻通知是锁屏期间唯一的进度来源）。
  void setForeground(bool value) {
    if (_foreground == value) return;
    _foreground = value;
    if (value) {
      _scanThrottle.flush();
      _extractThrottle.flush();
    }
  }

  // -------------------------------------------------------------------------
  // 事件
  // -------------------------------------------------------------------------

  void _onMessage(Object? message) {
    switch (message) {
      case EvReady(:final commandPort):
        _toWorker = commandPort;
        if (!_ready.isCompleted) _ready.complete();

      case EvPong(:final token):
        _pingWaiters.remove(token)?.complete();

      case EvScanTick(:final jobId, :final tick):
        // 上一个任务遗留的 tick 必须丢掉，否则会覆盖掉新任务的状态。
        if (jobId == _activeJob) _scanThrottle.add(tick);

      case EvScanDone(:final jobId, :final summary, :final elapsed):
        if (jobId != _activeJob) return;
        // **先丢掉攒着的 tick**：节流定时器可能还没触发，如果让它稍后再发，
        // 就会在「扫描完成」之后又把界面刷回旧进度。
        _scanThrottle.drop();
        _activeJob = null;
        _scanWaiters.remove(jobId)?.complete((summary: summary, elapsed: elapsed));

      case EvExtractTick(:final jobId, :final tick):
        if (jobId == _activeJob) _extractThrottle.add(tick);

      case EvExtractDone(:final jobId, :final outcome):
        if (jobId != _activeJob) return;
        _extractThrottle.drop();
        _activeJob = null;
        _extractWaiters.remove(jobId)?.complete(outcome);

      case EvFailed(
          :final jobId,
          :final message,
          :final detail,
          :final code,
          :final breach,
          // 别漏这一格：`EngineException` 是在**这里**重新组出来的，漏了它
          // 弹窗与日志就退回「密码不正确」（见 `EvFailed.uncertain`）。
          :final uncertain
        ):
        _failActive(
          EngineException(
            message,
            detail: detail,
            code: code,
            breach: breach,
            uncertain: uncertain,
          ),
          onlyJob: jobId == 0 ? null : jobId,
        );
    }
  }

  void _failActive(EngineException error, {int? onlyJob}) {
    final jobId = onlyJob ?? _activeJob;
    if (jobId == null) return;

    // 两个 waiter 表都要查：只有发起那个任务的那一侧会命中，另一侧是 null。
    final scanWaiter = _scanWaiters.remove(jobId);
    final extractWaiter = _extractWaiters.remove(jobId);
    if (jobId == _activeJob) {
      _scanThrottle.drop();
      _extractThrottle.drop();
      _activeJob = null;
    }

    if (scanWaiter != null && !scanWaiter.isCompleted) {
      scanWaiter.completeError(error);
    }
    if (extractWaiter != null && !extractWaiter.isCompleted) {
      extractWaiter.completeError(error);
    }
  }
}
