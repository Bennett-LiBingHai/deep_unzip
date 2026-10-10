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

import 'limits.dart';
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

/// 扫描**用户明确点名的那些文件**，不碰同目录里别的文件。
///
/// ## 为什么与 [CmdScan] 分成两个类型，而不是给它加一个可选的清单字段
///
/// 那个 `switch (message)` 是对 sealed 类型穷尽匹配的，加子类型会**编译期**
/// 逼着每个分派点补分支；而塞一个「空列表算哪一种」的可选字段，只会让这件事
/// 变成要读实现才知道。
///
/// 语义差别也不止「输入形状」：这条路上**容器防线让位**（用户点了一个
/// `.docx` 就是想要它），而且**分卷会在同目录里自动补齐**（`x.zip.001` 单独
/// 一片在解码器眼里什么都不是）。两个开关都只属于这条路，见
/// `scanner.dart` 的 `scanFileList`。
final class CmdScanFiles extends WorkerCmd {
  const CmdScanFiles({
    required this.jobId,
    required this.paths,
    this.options = const ScanOptions(),
    this.ignoreContainers = true,
    this.expandSplitVolumes = true,
  });

  final int jobId;

  /// 用户点名的绝对路径。目前产品上只有「单选一个文件」，但这里收的是列表
  /// ——引擎这一层没必要把自己钉死在单选上，而扫描器本来就支持一串。
  final List<String> paths;

  final ScanOptions options;

  /// 见 `scanFileList(ignoreContainers:)`。默认 true：这条路存在的理由就是
  /// 「用户明确选了它」。
  final bool ignoreContainers;

  /// 见 `scanFileList(expandSplitVolumes:)`。默认 true：选了分卷的一片就是想
  /// 解一整套。
  final bool expandSplitVolumes;
}

/// 把一组（已排好序的）分卷解压到 [outDir]。
///
/// 解压本体跑在**原生侧自己的线程**上（`duz_extract_start` 立刻返回），worker
/// 只是用轮询循环取进度 —— 所以这条命令**不再阻塞** worker 的事件循环，[CmdCancel]
/// 在解压期间照样处理得到（它会在下一次轮询把取消送到原生侧）。
///
/// 这条架构是硬约束换来的：原生侧此前用 `NativeCallable.isolateLocal` 回调报
/// 进度，而 7-Zip 的多线程解码路径会从**它自己的工作线程**调那个回调，Dart VM
/// 直接 `FATAL`、进程消失（见 `src/duz_engine.h` 顶上那段线程约定）。现在原生侧
/// 永不回调 Dart，进度靠 [EvExtractTick] 主动推、取消靠标志位。
final class CmdExtract extends WorkerCmd {
  const CmdExtract({
    required this.jobId,
    required this.parts,
    required this.outDir,
    this.password,
    this.depth = 0,
    this.recursive = false,
    this.options = const ScanOptions(),
    this.limits = LimitThresholds.standard,
    this.availableBytes,
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
  /// 关掉的开关（如 `fakeExtDetect`）在嵌套这一层会悄悄复活。
  final ScanOptions options;

  /// 炸弹防护阈值。跟着命令一起过来，而不是让 worker 自己去读设置 ——
  /// 那是同一个理由：**这批任务全程用同一份快照**。用户在解压途中改了阈值，
  /// 不该让同一批里前半个包用旧值、后半个包用新值。
  ///
  /// [LimitThresholds] 全是 int，是平凡数据，跨 isolate 送没有问题。
  final LimitThresholds limits;

  /// 目标卷此刻还剩多少字节，由**主 isolate** 量好随命令带过来。
  ///
  /// 为什么不让 worker 自己量：`dart:io` 没有查剩余空间的 API，只能走平台通道
  /// （见 `services/disk_space.dart`），而方法通道要从后台 isolate 调需要额外
  /// 的 messenger 初始化。主 isolate 顺手量一次最省事。
  ///
  /// `null` = 量不到（非 Android、通道没注册、路径不可达）→ **跳过空间检查**，
  /// 不是「当作 0」。量不出来的东西不能拿来当判据。
  final int? availableBytes;
}

/// 请求中止当前任务。**没有对应参数** —— 同一时刻只有一个任务，
/// 「取消」只可能指它。
///
/// 扫描是协作式的（每个条目边界看一眼 epoch），解压靠轮询循环把标志送到原生
/// 侧 —— 两条路都是「尽快」，不是「立刻」。所以调用方不能假设 [CmdCancel]
/// 一送出任务就停了，得等那个任务自己收场。
final class CmdCancel extends WorkerCmd {
  const CmdCancel();
}

/// 停掉命令循环。主 isolate 随后会硬杀本 isolate。
///
/// worker 收到它要**等在飞的任务收尾**再关 inbox —— 解压那条路上，
/// `duz_close` 跑到了 C++ 那条解压线程才有人 join（见 `controller.dart` 的
/// `dispose()`：先送 cancel + shutdown，给一个宽限期，到期才硬杀）。
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
    this.breach,
    this.uncertain = false,
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

  /// 炸弹防护的裁决，有就带上。理由同 [code]：主 isolate 要区分「包坏了 →
  /// 跳过」和「是炸弹 → 问用户」，从文案里猜是不行的。
  ///
  /// [LimitBreach] 全是 `enum` + `String`，是平凡数据，可以跨 isolate 送。
  final LimitBreach? breach;

  /// 这次失败**说不清**是密码不对还是数据已损坏（见 [EngineException.uncertain]）。
  ///
  /// 理由同 [code] 与 [breach]：**它必须显式跨 isolate 传**。它不是路由键，
  /// 但它是**说法**，而 `EngineException` 是在主 isolate 这头重新组出来的 ——
  /// 漏掉这一格不会报任何错，只会让弹窗照旧替用户断言「密码不正确」。
  ///
  /// 这个坑真踩过：`uncertain` 一开始只加到了 [EngineException] 上，两条
  /// `EvFailed` 的搬运点都没跟上，于是真机上 `enc7z_content.7z` 走的一直是
  /// 「密码不正确」那句。单测全绿，因为假引擎直接抛 `EngineException`、
  /// 压根不过这道 isolate 边界。
  final bool uncertain;
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
  const EngineException(this.message,
      {this.detail, this.code, this.breach, this.uncertain = false});

  final String message;
  final String? detail;

  /// 原生引擎的错误码（`DUZ_ERR_*`），**不**在原生调用链上时为 null。
  ///
  /// 上层靠它决定策略（换密码重试 / 跳过这个包 / 报错），文案只适合展示。
  /// 类型是 int 而不是插件里的枚举，是为了让本文件（以及整个 `engine/`）
  /// 不必 import 插件包 —— 换后端时这里的签名不动。
  final int? code;

  /// 被炸弹防护拦下时的详情。**刻意不走 [code]**。
  ///
  /// [code] 的契约是「原生 `DUZ_ERR_*` 的镜像」，而炸弹判定完全在 Dart 侧，
  /// 原生那边没有对应的错误码。硬塞一个进去会让 `error_codes_test.dart` 那张
  /// 「每个镜像常量都要有原生对应」的表失去意义 —— 那张表正是用来防漂移的。
  ///
  /// 单独一个字段还有个好处：上层判「是不是炸弹」不必猜数字（比如「是否
  /// 小于 -6 就是 Dart 侧的错误」这种脆弱约定），直接 `breach != null`。
  /// P3 的弹窗要区分「损坏 → 跳过」「炸弹 → 暂停并问用户」，靠的就是它。
  final LimitBreach? breach;

  /// 这次失败**说不清**是密码不对还是数据已损坏。与 [breach] 同一种位置：**刻意
  /// 不走 [code]**，理由也一样 —— 路由不变，只是多层一个说法。
  ///
  /// 只可能在 [code] == [DuzErrorCode.password] 时为真，且只可能来自**解压**：
  /// 加密条目的数据压根没解开，而那种加密没有校验字（7z、RAR3），错密码和坏数据
  /// 在解码器眼里一模一样。ZIP / RAR5 有校验字，7-Zip 亲口报 `kWrongPassword`，
  /// 那两档恒为 false。
  ///
  /// **判策略不要看它**：`_PwdAttempt.isPasswordError`、换候选密码、弹密码窗
  /// 全都不该碰它。它的去处只有一个 —— 说法（弹窗上那句「两者无法区分」、
  /// 日志标签「密码或损坏」）。
  final bool uncertain;

  @override
  String toString() =>
      detail == null ? 'EngineException: $message' : 'EngineException: $message\n$detail';
}

/// 这次解压**被用户中止了** —— 不是失败，也不该被当成失败处理。
///
/// **刻意不继承 [EngineException]**，这一条是整个设计的关键：
///
/// - `app_state.dart` 的批次循环里有一条 `on EngineException` 兜底，会把接到的
///   一切记成失败日志、计一次失败数。取消走的是另一条 `on ExtractCancelled`。
/// - 更要紧的是**试密码那条链**（`_extractResolvingPassword`）：它的 `verify`
///   闭包把「拿到 outcome」直接当成「这个密码是对的」，而试密码本身就是一次
///   `engine.extract`（`duz_verify_password` 仍是 UNSUPPORTED）。如果把取消做成
///   `ExtractOutcome.cancelled` 一路用返回值往上带，那个闭包会把「用户按了停止」
///   读成「密码验证通过」并记一次密码库命中 —— **静默假绿**。
///
/// 做成异常之后，它穿过 `_extractResolvingPassword` 的六个成功出口自动传播，
/// 一处都不用逐个改；而因为类型上没有继承关系，它既不会被 `on EngineException`
/// 接住，也不会被那条 `verify` 闭包当成成功。
///
/// 边界划在这里：`extractArchive` / `extract` 那一层**返回值**（那里手上有归档，
/// outcome 是真的）；再往上就只剩这一个异常。
class ExtractCancelled implements Exception {
  const ExtractCancelled();

  @override
  String toString() => 'ExtractCancelled';
}
