/// 测试用的假引擎：只接管 `extract`，**扫描仍走真 worker isolate**。
///
/// ## 为什么只换一半
///
/// 这些测试盯的是「上层把引擎的**结果**翻译成 UI 模型翻得对不对」，真实解压
/// 已经由 `packages/deep_unzip_engine` 端到端测过。而 `flutter test` 跑在
/// Windows 宿主机上，那里根本没有 `deep_unzip_engine.dll` —— 真走一遍
/// `extract` 只会得到一条「无法加载原生引擎」，什么也验证不了。
///
/// 扫描则不换：`selectFolderPath` 要产出一串真实的 `ScanItem`（路径、分片、
/// 嗅探结果），假造一份等于把这组测试的前提也变成假的。
library;

import 'package:deep_unzip/engine/controller.dart';
import 'package:deep_unzip/engine/limits.dart';
import 'package:deep_unzip/engine/models.dart';

class FakeEngine extends EngineController {
  // 关掉节流：本类的 tick 是直接调 `onExtractTick` 发的，不经过底座；
  // 顺手让 `throttle` 与其余用例保持一致，免得读的人以为哪里漏了一层。
  FakeEngine() : super(throttle: Duration.zero);

  /// 每次 `extract` 的行为。抛异常即模拟原生失败；`await` 一个永远不完成的
  /// Future 即模拟「卡在这个包上」。
  ///
  /// 第一个参数是引擎自身，用例靠 `engine.rounds` 区分这是第几个包。
  Future<void> Function(FakeEngine engine, String outDir)? behavior;

  /// 依次收到的目标目录。长度 = 已经开工的包数。
  final List<String> outDirs = [];

  /// 依次收到的原始 `parts`。
  final List<List<String>> partsSeen = [];

  /// 已经开工的包数。
  int rounds = 0;

  /// 依次收到的递归层级，与 [outDirs] 等长同序。
  final List<int> depthsSeen = [];

  /// 依次收到的炸弹防护阈值，与 [outDirs] 等长同序。
  ///
  /// 记下来是为了钉住「设置页改的阈值真的传到了引擎」这条线 ——
  /// 闸门本身住在 `native_backend` 里（假引擎整个绕过它），所以那半边只能
  /// 靠 `limits_test.dart` 的纯函数用例覆盖，这半边只能靠这里。
  final List<LimitThresholds> limitsSeen = [];

  /// 依次收到的 `recursive` 开关，与 [outDirs] 等长同序。
  final List<bool> recursiveSeen = [];

  /// 依次收到的候选密码，与 [outDirs] 等长同序。
  ///
  /// 一次 `extract` 就是一次尝试，所以「这个包一共被试着解了几次、按什么顺序
  /// 试的」全在这张表里 —— 密码库那条链路只有这里能钉住（真引擎要 Android）。
  ///
  /// **开局那次「空密码」是空串 `''`，不是 `null`**，整条路也不该出现 `null`
  /// —— 原生 ZIP 路径上这是两个值两件事（见 `app_state.dart` 的
  /// `_kEmptyPassword`）。表里留 `String?` 只是不想让「到底送了没送」这件事
  /// 变得不可断言。
  final List<String?> passwordsSeen = [];

  /// 依次收到的目标卷剩余字节数，与 [outDirs] 等长同序。
  ///
  /// `null` = 那一刻没量到（非 Android、通道没注册），空间检查会被跳过。
  /// 这份记录钉的是「主 isolate 量的数真的随命令流到了引擎」——
  /// 假引擎整个绕过 `native_backend` 的闸门，闸门那半边只能靠
  /// `limits_test.dart` 的纯函数用例覆盖。
  final List<int?> availableBytesSeen = [];

  /// 每个包要「解出」的嵌套包。key 是 `outDir`，缺省表示里面没有包。
  ///
  /// 真引擎由 worker 在解完之后扫目录得到这批条目（见 worker.dart 的
  /// `_findNested`）；这里直接喂，测试就不必去磁盘上真摆一层目录。
  final Map<String, List<ScanItem>> nestedFor = {};

  /// 依次收到的「扫描时要跳过的目录」。
  ///
  /// 扫描本身**照跑真的**（见文件头），所以这里只是**记一笔再交给
  /// `super.scan`** —— 不是把扫描换掉。钉的是「选过输出根之后，它真的随
  /// 命令传下去了」这条线，也就是防自噬那一半。
  final List<Set<String>> skipDirsSeen = [];

  /// 依次收到的扫描选项。
  ///
  /// 钉的是「设置页改的『前置数据搜索窗口』真的随命令流到了引擎」这条线 ——
  /// 真实的 `sniffFile` 跑在 worker isolate 里，这里只记一笔再交给
  /// `super.scan`（扫描本体照跑真的，见文件头）。
  final List<ScanOptions> scanOptionsSeen = [];

  /// [cancel] 被调了几次。
  ///
  /// 底座的 `cancel()` 会 `await _ready.future` 再往那条 worker isolate 发
  /// 命令 —— 假引擎压根没起 worker，直接调它只会挂死。所以这里**只记数**，
  /// 不碰底座。钉的是「按下停止真的把取消送下去了」这条线。
  int cancelCalls = 0;

  @override
  Future<void> cancel() async {
    cancelCalls++;
  }

  @override
  Future<ScanOutcome> scan({
    required String rootPath,
    ScanOptions options = const ScanOptions(),
    Set<String> skipDirs = const {},
    int depth = 0,
  }) {
    skipDirsSeen.add(skipDirs);
    scanOptionsSeen.add(options);
    return super.scan(
      rootPath: rootPath,
      options: options,
      skipDirs: skipDirs,
      depth: depth,
    );
  }

  @override
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
    outDirs.add(outDir);
    partsSeen.add(parts);
    // 记在 `behavior` **之前**：用例要能读到「这一次带的是哪个密码」，
    // 而抛不抛异常正是 `behavior` 说了算的。
    passwordsSeen.add(password);
    depthsSeen.add(depth);
    recursiveSeen.add(recursive);
    limitsSeen.add(limits);
    availableBytesSeen.add(availableBytes);
    rounds++;
    // 与真引擎同构：**开局那一刻**记下取消计数，收工时比对。开局之前发生的
    // 取消不算数（那条包已经解完了），开工之后发生的才算 —— 这正是
    // `worker.dart` 里 `shouldCancel: () => epoch != _cancelEpoch` 的语义。
    final cancelBaseline = cancelCalls;
    await behavior?.call(this, outDir);
    return ExtractOutcome(
      outDir: outDir,
      entryCount: 1,
      unpackedBytes: 1024,
      elapsed: const Duration(milliseconds: 5),
      cancelled: cancelCalls != cancelBaseline,
      nested: nestedFor[outDir] ?? const [],
    );
  }
}
