/// 主 isolate ↔ worker isolate 的消息协议。
///
/// ## 为什么用 `sealed`
///
/// 两个方向都是封闭的继承层级，接收端一律用穷尽 `switch`。加一条新消息时
/// 编译器会把所有漏掉的分支指出来 —— 这正是我们想要的：isolate 消息漏处理
/// 在运行期表现为「界面莫名其妙不动」，最难查。
///
/// ## 消息必须是平凡数据
///
/// isolate 之间只传可复制的数据。**不能**传闭包、`File`/`RandomAccessFile`
/// 句柄、`Completer`、`Timer`。所以这里只有值对象、字符串、数字、列表、
/// 集合，以及 [ScanSummary] 这类纯数据模型。
///
/// 进度回调没法直接传（那是闭包），改由 worker 主动发 [EvScanTick]。
///
/// ## 关于暂停 / 错误决断 / 解压
///
/// 这三个属于 P1（原生引擎）与 P3（弹窗桥接），**协议里暂时没有它们**。
/// 与其现在凭想象定下一份 P1 会推翻的契约，不如等那时按真实需求加 ——
/// `sealed` 保证了那时的改动是编译期可见的，不会漏掉分支。
library;

import 'dart:isolate';

import 'models.dart';
import 'scanner.dart';

// ---------------------------------------------------------------------------
// 主 → worker
// ---------------------------------------------------------------------------

sealed class WorkerCmd {
  const WorkerCmd();
}

/// 存活探测。往返一次证明 worker 还活着、命令循环没被堵死。
final class CmdPing extends WorkerCmd {
  const CmdPing(this.token);

  /// 由调用方自选，原样回传，用来对上是哪一次探测。
  final int token;
}

/// 扫描一个目录（递归）。
final class CmdScan extends WorkerCmd {
  const CmdScan({
    required this.jobId,
    required this.rootPath,
    this.options = const ScanOptions(),
    this.skipDirs = const {},
    this.depth = 0,
  });

  final int jobId;
  final String rootPath;
  final ScanOptions options;

  /// 绝对路径集合，整个跳过（journal 记录的历史输出目录）。
  final Set<String> skipDirs;

  /// 写进 `ScanItem.depth`，嵌套场景用。
  final int depth;
}

/// 把一组（已排好序的）分卷解压到 [outDir]。
///
/// 这是**唯一**会长时间阻塞 worker 的命令：`duz_extract_all` 是一次同步
/// FFI 调用，跑完之前 worker 的事件循环不转。所以：
///
/// - 解压期间进来的 [CmdCancel] **要到解压结束才会被处理** —— 也就是说
///   现阶段它取消失败（不报错，只是不生效）。真正的「解压中途取消/暂停」
///   需要把取消信号做成原生内存里的一个标志字节，让 7-Zip 的进度回调直接
///   去读，而不必等事件循环。那是 P3 的活，这里不假装已经支持。
/// - 进度靠 [EvExtractTick] 主动推，不是被拉。
final class CmdExtract extends WorkerCmd {
  const CmdExtract({
    required this.jobId,
    required this.parts,
    required this.outDir,
    this.password,
    this.depth = 0,
    this.recursive = false,
    this.options = const ScanOptions(),
  });

  final int jobId;

  /// 全部卷的绝对路径，**顺序已由调用方定好**（见 split.dart），worker 不猜。
  /// 单卷就是长度为 1 的列表。
  final List<String> parts;

  /// 目标目录。worker 会确保它存在（原生侧只往里写，不建目录）。
  final String outDir;

  /// 候选密码。null 表示不带密码打开（归档头加密的包会因此打不开）。
  final String? password;

  /// 本次任务在递归树里的层级。只用来给事后扫描出的嵌套包打
  /// `baseDepth = depth + 1`，不影响解压本身。
  final int depth;

  /// 解完之后要不要在 [outDir] 里找嵌套压缩包（见 [ExtractOutcome.nested]）。
  ///
  /// 关掉时 worker 完全不碰目录，行为与没加这个特性时逐字节一致 ——
  /// 这是刻意的：嵌套扫描要遍历刚解出来的整棵树，对「只想解一层」的
  /// 用户不该白付这份开销。
  final bool recursive;

  /// 嵌套扫描用的扫描参数。与顶层扫描**同一份快照**，否则用户在设置里
  /// 关掉的开关（`splitMerge` / `fakeExtDetect`）在嵌套这一层会悄悄复活。
  final ScanOptions options;
}

/// 请求中止当前任务。**没有对应参数** —— 同一时刻只有一个任务，
/// 「取消」只可能指它。
final class CmdCancel extends WorkerCmd {
  const CmdCancel();
}

/// 停掉命令循环。主 isolate 随后会硬杀本 isolate。
final class CmdShutdown extends WorkerCmd {
  const CmdShutdown();
}

// ---------------------------------------------------------------------------
// worker → 主
// ---------------------------------------------------------------------------

sealed class WorkerEvent {
  const WorkerEvent();
}

/// worker 启动后的第一件事：把自己的命令端口交给主 isolate。
///
/// 主 isolate 在收到它之前不能发任何命令 —— 这是握手，不是可选项。
final class EvReady extends WorkerEvent {
  const EvReady(this.commandPort);

  final SendPort commandPort;
}

final class EvPong extends WorkerEvent {
  const EvPong(this.token);

  final int token;
}

/// 扫描进度。已由 worker 侧按文件数合并过（见 [kTickEveryFiles]），
/// 主 isolate 还会再按时间节流一次。
final class EvScanTick extends WorkerEvent {
  const EvScanTick({required this.jobId, required this.tick});

  final int jobId;
  final ScanTick tick;
}

/// 扫描结束。[summary] 里的 `warnings` 已经包含取消 / 截断 / 不可读的说明，
/// 所以取消走的也是这条事件（不是错误）。
final class EvScanDone extends WorkerEvent {
  const EvScanDone({
    required this.jobId,
    required this.summary,
    required this.elapsed,
  });

  final int jobId;
  final ScanSummary summary;
  final Duration elapsed;
}

/// 解压进度。worker 侧已按时间合并过（见 `kExtractTickMerge`），
/// 主 isolate 还会再按时间节流一次。
final class EvExtractTick extends WorkerEvent {
  const EvExtractTick({required this.jobId, required this.tick});

  final int jobId;
  final ExtractTick tick;
}

/// 解压结束（成功）。失败走 [EvFailed]。
final class EvExtractDone extends WorkerEvent {
  const EvExtractDone({required this.jobId, required this.outcome});

  final int jobId;
  final ExtractOutcome outcome;
}

/// 任务失败。[detail] 是堆栈，只进调试日志，不给用户看。
final class EvFailed extends WorkerEvent {
  const EvFailed({
    required this.jobId,
    required this.message,
    this.detail,
    this.code,
  });

  /// 0 表示「不属于任何任务」（例如协议本身出错）。
  final int jobId;
  final String message;
  final String? detail;

  /// 原生错误码（`DUZ_ERR_*`），有就带上。
  ///
  /// 必须显式跨 isolate 传：主 isolate 收到 [EngineException] 时要靠它决定
  /// 「换个候选密码重试」还是「放弃这个包」，而从文案里猜是不行的。
  /// 非原生失败（如协议错误）为 null。
  final int? code;
}

// ---------------------------------------------------------------------------
// 错误
// ---------------------------------------------------------------------------

/// 原生引擎错误码，**镜像** `packages/deep_unzip_engine/src/duz_engine.h`
/// 里的 `DUZ_ERR_*` 枚举。
///
/// 为什么不直接 import 插件包来用它的常量：那样 `engine/` 的每一层都得依赖
/// 插件，而 [EngineException.code] 的类型就成了插件类型，换后端要动一大片。
/// 这里放一份整数镜像，插件只被 `backends/native_backend.dart` 认识。
///
/// 镜像就有漂移风险，所以有 `test/engine/error_codes_test.dart` 逐条比对
/// 两边 —— 改了 `duz_engine.h` 而忘了这里，测试会立刻红。
abstract final class DuzErrorCode {
  static const int ok = 0;

  /// 打不开：格式不识别 / 分片缺失 / 文件损坏。
  static const int open = -1;

  /// 需要密码或密码错误。**换下一个候选密码重试是有意义的。**
  static const int password = -2;

  /// 该平台未编译 7-Zip 核心，或格式不被支持。
  static const int unsupported = -3;

  static const int arg = -4;

  /// 解压中途失败（含用户取消）。
  static const int extract = -5;

  static const int noMem = -6;
}

/// 引擎侧失败，由 `EngineController` 的 Future 抛出。
class EngineException implements Exception {
  const EngineException(this.message, {this.detail, this.code});

  final String message;
  final String? detail;

  /// 原生引擎的错误码（`DUZ_ERR_*`），**不**在原生调用链上时为 null。
  ///
  /// 上层靠它决定策略（换密码重试 / 跳过这个包 / 报错），文案只适合展示。
  /// 类型是 int 而不是插件里的枚举，是为了让本文件（以及整个 `engine/`）
  /// 不必 import 插件包 —— 换后端时这里的签名不动。
  final int? code;

  @override
  String toString() =>
      detail == null ? 'EngineException: $message' : 'EngineException: $message\n$detail';
}
