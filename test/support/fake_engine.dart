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

  /// 每个包要「解出」的嵌套包。key 是 `outDir`，缺省表示里面没有包。
  ///
  /// 真引擎由 worker 在解完之后扫目录得到这批条目（见 worker.dart 的
  /// `_findNested`）；这里直接喂，测试就不必去磁盘上真摆一层目录。
  final Map<String, List<ScanItem>> nestedFor = {};

  @override
  Future<ExtractOutcome> extract({
    required List<String> parts,
    required String outDir,
    String? password,
    int depth = 0,
    bool recursive = false,
    ScanOptions options = const ScanOptions(),
    LimitThresholds limits = LimitThresholds.standard,
  }) async {
    outDirs.add(outDir);
    partsSeen.add(parts);
    depthsSeen.add(depth);
    recursiveSeen.add(recursive);
    limitsSeen.add(limits);
    rounds++;
    await behavior?.call(this, outDir);
    return ExtractOutcome(
      outDir: outDir,
      entryCount: 1,
      unpackedBytes: 1024,
      elapsed: const Duration(milliseconds: 5),
      nested: nestedFor[outDir] ?? const [],
    );
  }
}
