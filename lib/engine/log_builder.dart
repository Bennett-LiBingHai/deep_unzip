/// 引擎结果 → `LogEntry` 的字段拼装。
///
/// ## 为什么从 AppState 里搬出来
///
/// 这段逻辑本来长在 `AppState._applyScan` / `_runExtractBatch` 里，跟
/// `notifyListeners()`、批次状态机混在一起，于是**没法单独测**。而它其实全是
/// 纯函数：输入是一次扫描/解压的结局，输出是六个字段。搬到这儿之后，
/// 「哪些情况该记成 partial」「失败时该挂哪些 tag」这类判断才测得到。
///
/// ## 依赖方向
///
/// `engine/models.dart` 与 `engine/scanner.dart` 本来就 import
/// `models/archive_file.dart`（`ScanItem.flags` 是 `ArchiveFlag`），所以这里
/// 用 `models/log_entry.dart` 不是新开的口子。`LogEntry` 是纯 Dart、不依赖
/// `package:flutter`，「engine 能在 isolate 与 `flutter test` 里跑」这条
/// 不受影响。
library;

import '../models/archive_file.dart';
import '../models/log_entry.dart';
import 'format.dart';
import 'models.dart';
import 'protocol.dart';

/// 这个包是**怎么打开的** —— 日志上要能一眼看出密码是谁给的。
///
/// 只记来源，**不记密码本身**：日志会落盘到 `<appSupport>/logs.json`，明文
/// 密码不该跟着它走到磁盘上去。密码库放在 `flutter_secure_storage` 里正是
/// 为了这件事，转手又抄一份进日志等于把那道防线绕过去了。
///
/// 定义在这里而不是 `services/`：它是**日志的形状**（`buildExtractLog` 的
/// 入参），而 `log_builder.dart` 必须保持纯 Dart（`engine/` 里不许 import
/// flutter），所以两边都 import 得到的只有这一个地方。
enum PasswordSource {
  /// 密码库里某一条命中的（命中数与最近使用时间由 `_markVaultHit` 同步更新）。
  vault('密码库'),

  /// 用户在弹窗里手敲的。**不自动入库**：敲一次就存一次等于替用户做主，
  /// 而用户手敲的很可能是一次性的东西。
  manual('手输密码');

  const PasswordSource(this.label);

  /// 日志标签上那两个字。芯片很小，别写长句。
  final String label;
}

/// 一次扫描该记成什么状态。
///
/// 「有告警」不等于「部分成功」：目录压根不存在时也是一个都没找到、也带告警，
/// 那是彻底失败而不是部分成功。所以**先看有没有东西被扫出来**。
LogStatus scanLogStatus(ScanSummary summary) {
  if (summary.items.isEmpty) {
    return summary.warnings.isEmpty ? LogStatus.success : LogStatus.failed;
  }
  return summary.warnings.isEmpty ? LogStatus.success : LogStatus.partial;
}

/// 把一次扫描收成一条日志。
///
/// `size` 是**各包大小之和**（`ArchiveFile.size` 那种预格式化字符串）；
/// 一个包都没扫到时记 `-`，因为 `0 B` 会被读成「有个空包」。
LogEntry buildScanLog({
  required String folderName,
  required ScanSummary summary,
  required Duration elapsed,
  required DateTime now,
}) {
  var total = 0;
  for (final item in summary.items) {
    total += item.sizeBytes;
  }

  // 扫描期认出来的「要密码」的包有几个。这是首页那张「需密码」统计卡在日志里
  // 的同一个数，所以**从同一处数**（`ArchiveFlag.encrypted`），不在别处另算
  // 一遍 —— 两处口径一旦分家，用户会看到卡片说 4、日志说 3。
  final needsPassword =
      summary.items.where((i) => i.flags.contains(ArchiveFlag.encrypted)).length;

  return LogEntry(
    name: '$folderName（扫描）',
    status: scanLogStatus(summary),
    size: summary.items.isEmpty ? '-' : formatBytes(total),
    time: formatLogTime(now),
    at: now,
    duration: formatDuration(elapsed),
    tags: [
      '${summary.items.length} 个压缩包',
      if (needsPassword > 0) '需密码 $needsPassword',
      if (summary.containerSkipped > 0) '忽略 ${summary.containerSkipped} 个容器',
      if (summary.unreadable > 0) '${summary.unreadable} 个不可读',
    ],
  );
}

/// 扫描整个没跑起来（目录打不开、worker 起不来）时记的那条。
LogEntry buildScanFailureLog({
  required String folderName,
  required DateTime now,
}) =>
    LogEntry(
      name: folderName,
      status: LogStatus.failed,
      size: '-',
      time: formatLogTime(now),
      at: now,
      duration: '-',
      tags: const ['扫描失败'],
    );

/// 「密码没对上」那一档的标签。
///
/// **单独一个函数是为了让两条路不至于分家**：解压失败那条（本文件的 tag 表）
/// 与「弹窗关着、静默跳过」那条（`app_state.dart` 传的 `skippedReason`）说的是
/// 同一件事，两边各写一遍字符串迟早只改一边。
///
/// [uncertain] 为真时措辞要留活口：那种加密没有校验字（7z 的内容加密、RAR3），
/// 「密码未匹配」读起来像在说「你的密码错了」，可我们并不知道 —— 坏掉的
/// 也可能是数据本身。这与弹窗上那句「两者无法区分」是同一条。
///
/// 能确定的 ZIP-AES / RAR5 照旧记「密码未匹配」。
String passwordTag({required bool uncertain}) =>
    uncertain ? '密码或损坏' : '密码未匹配';

/// 把一次解压的结局收成一条日志。
///
/// [outcome] / [error] / [skippedReason] **恰好**有一个非空 —— 这是这个函数
/// 存在的意义：「成功该挂什么 tag、失败该挂什么 tag、跳过该挂什么 tag」
/// 分成三条路写死在一处，调用方只要把手里那个东西传进来就行。
///
/// 跳过与失败必须分开（[LogStatus.skipped] vs [LogStatus.failed]）：跳过是
/// 「我们主动没解」（自引用、超深），失败是「解了但没成」。混成一种的话，
/// 用户看到一排红字会以为程序坏了，而其实是我们按规则拦下来的。
///
/// [passwordSource] 只在**成功**那条路上有意义（失败与跳过都另有话说，
/// 见下面的 tag 表）：这个包是被哪个密码打开的。没用到密码（绝大多数包）传
/// `null`，那一格就不出标签。
///
/// [sourceDeleted] / [sourceDeleteFailed] 同理，也只在成功那条路上有意义 ——
/// 只有成功才会去删源包（见 `app_state.dart` 的批次循环）。默认 false 让既有
/// 调用点零改动。
LogEntry buildExtractLog({
  required ScanItem item,
  required DateTime now,
  ExtractOutcome? outcome,
  EngineException? error,
  String? skippedReason,
  PasswordSource? passwordSource,
  bool sourceDeleted = false,
  bool sourceDeleteFailed = false,
}) {
  assert(
    (outcome != null ? 1 : 0) +
            (error != null ? 1 : 0) +
            (skippedReason != null ? 1 : 0) ==
        1,
    '解压要么成功、要么失败、要么跳过，三选一',
  );

  final base = LogEntry(
    name: item.fileName,
    // 失败时记 `-`：这个字段是「花了多久」，而失败的那次没解出东西，
    // 写个 `0.3s` 会让人以为部分成功了。
    size: formatBytes(item.sizeBytes),
    time: formatLogTime(now),
    at: now,
    status: switch ((outcome, error, skippedReason)) {
      (final o, _, _) when o != null => LogStatus.success,
      (_, final e, _) when e != null => LogStatus.failed,
      _ => LogStatus.skipped,
    },
    duration: outcome != null ? formatDuration(outcome.elapsed) : '-',
    tags: switch ((outcome, error, skippedReason)) {
      // 四个 flag 一个都不能漏。`ArchiveFlag` 那边定义了四个，这里少写一个
      // 不会有任何提示，只会表现成「这类包在日志里看不出区别」—— 扫描页明明
      // 给 `fake.pdf` 挂了「伪后缀」角标，日志里却与普通包长得一模一样。
      (final o, _, _) when o != null => [
          if (item.isSplit) '分片 ×${item.parts.length}',
          if (item.flags.contains(ArchiveFlag.nested)) '嵌套',
          if (item.flags.contains(ArchiveFlag.encrypted)) '加密',
          // 「加密」说的是**这个包锁着**，「密码库 / 手输密码」说的是**谁给的
          // 钥匙**，两件事。分开记是因为它们会分家：分卷加密包扫描期认不出
          // 「加密」（见 scanner.dart 那条已知缺口），但它照样要密码才解得开
          // —— 只看角标那一格，用户会发现日志里一个密码相关的字都没有。
          if (passwordSource != null) passwordSource.label,
          if (item.flags.contains(ArchiveFlag.fakeExtension)) '伪后缀',
          '${o.entryCount} 项',
          // 开了「自动删除源压缩包」时，让这一条如实说出去：删了就说删了，
          // 没删净更要说（「说好删了却没删」比不删更糟）。两者互斥：有没删净的
          // 就报那一句，全部删净才报「已删源」。没开这颗开关时两个都是 false，
          // 这一格一个标签都不出。
          if (sourceDeleteFailed) '源未删净' else if (sourceDeleted) '已删源',
        ],
      // 三种失败要分得开：
      // - 密码错 → 换下一个候选密码还有救（P4 会自动试）
      // - 炸弹防护 → 不是「坏了」，是我们主动放弃；将来还能让用户选
      // - 其余 → 包坏了，只能跳过
      // 都记成「解压失败」的话，用户看着密码库里的条目、或者看着一个明明
      // 完好的包被标红，都会一头雾水。
      (_, final e, _) when e != null => [
          if (e.breach != null) ...[e.breach!.tag, '解压失败']
          else if (e.code == DuzErrorCode.password) passwordTag(uncertain: e.uncertain)
          else '解压失败',
        ],
      (_, _, final reason) => [reason!],
    },
  );
  return base;
}
