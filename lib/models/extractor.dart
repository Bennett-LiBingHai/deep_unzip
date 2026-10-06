import '../engine/models.dart';

/// 设置页「支持的格式」里的一行：app 认得出、并且解得开的一种格式。
///
/// ## 它不是「注册进来的解压器」（2026-10 改）
///
/// 这个类从前叫「解压方式」，设置页还有个「注册新的解压方式」入口，让用户自己
/// 填判断函数和解压函数。那个入口**从来没有接到引擎上**：`addExtractor` 只往
/// 列表里加一行，识别靠 `engine/sniff.dart`、解压靠内置的 7-Zip 核心，两边都不读
/// 这张表。入口已经整个撤掉，规则变成：**要支持新格式，改 `SniffFormat` 与嗅探
/// 签名表**，而不是让用户在界面上填。
///
/// 所以这里只剩只读的说明字段，且全部是**内置**的 —— 没有 `isBuiltin` 了。
///
/// ## 没有「单文件 / 分卷」这个二分
///
/// 分卷**不是一种格式**，而是任何格式都可能带的一个属性 —— ZIP、7z、RAR 都能
/// 分卷。`engine/split.dart` 就是这么做的：先把一堆分片聚成一个家族，再把整组
/// 交给格式后端，跟是哪种格式无关。所以分卷是 [split]（可空）：非空 = 这个格式
/// 有**它自己特有**的分卷命名；通用的裸切分（`*.001`）对任何格式都成立，不在
/// 这里重复。
class Extractor {
  /// 显示名。
  final String name;

  /// 列表左边那个方框里的短标签（38px 见方，最多三个字符）。
  final String tag;

  /// 这一行对应 [SniffFormat] 里的哪几种。
  ///
  /// **这是给测试用的钉子**，不是展示用的：`builtin_extractors_test.dart` 拿
  /// `SniffFormat.values` 跟它比一遍，保证「嗅探认得出的格式」与「这张表说支持
  /// 的格式」不会各走各的 —— 从前正是这么漂开的。
  final Set<SniffFormat> formats;

  /// 「怎么认出来的」。**照 `engine/sniff.dart` 的签名表写**，不是示意代码 ——
  /// 这一栏会原样显示在设置页上，写错了就是当着用户的面撒谎。
  final String detectLogic;

  /// 「拿什么解」。本 app 只有一条真路径：内置的 7-Zip 核心（FFI），**不调用
  /// 任何外部命令**。
  final String extractLogic;

  /// 这个格式**特有**的分卷命名；`null` = 只有通用的 `*.001` 裸切分。
  final String? split;

  const Extractor({
    required this.name,
    required this.tag,
    required this.formats,
    required this.detectLogic,
    required this.extractLogic,
    this.split,
  });
}
