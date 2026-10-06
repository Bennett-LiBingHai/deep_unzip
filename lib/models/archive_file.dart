/// 压缩包类型
///
/// 每个值自带一个 [label]，而不是靠 `name.toUpperCase()` 拼出来 —— 后者拼不出
/// 「7Z」：Dart 的枚举常量名必须是标识符，**不能以数字开头**（写 `7z` 直接是
/// `Expected an identifier` 的语法错误），`_7z` 虽然能编译，却成了声明它的库
/// 私有的（别的文件里 `ArchiveType._7z` 是 no constant named）。显示名只能挂
/// 在字段上。
///
/// 顺带解决了另一件事：7-Zip 认得出的 gzip/bzip2/xz/zstd 原先四个都映射到
/// [tar]（见 `engine/models.dart` 的 `SniffFormat`），列表角标一律显示 TAR，
/// 跟真实格式对不上。拆开后各显示各的。
enum ArchiveType {
  zip('ZIP'),
  rar('RAR'),
  sevenz('7Z'),
  tar('TAR'),
  gzip('GZIP'),
  bzip2('BZIP2'),
  xz('XZ'),
  zstd('ZSTD'),

  /// 认得出、但没有专属类型的那一大批（ISO / WIM / DMG / 各种磁盘映像 …）。
  /// 角标上写什么由 [ArchiveFile.badge] 决定，这里只管**颜色分组**。
  other('OTHER'),

  /// 真正认不出的东西。**不会出现在扫描结果里**（认不出就不入列），只给
  /// `SniffResult.unknown` 用。
  unknown('UNKNOWN');

  const ArchiveType(this.label);

  /// 列表里类型角标上的字。
  final String label;
}

/// 文件标记
enum ArchiveFlag { encrypted, split, fakeExtension, nested }

/// 压缩包文件模型
class ArchiveFile {
  final String name;
  final ArchiveType type;
  final String size;
  final List<ArchiveFlag> flags;
  final int depth;

  /// 角标上的字。`null` 时回退到 [type] 的显示名。
  ///
  /// 为什么需要它：[ArchiveType] 只是粗分类，二十几种「已识别但没有专属类型」的
  /// 格式都落在 [ArchiveType.other] 上，角标却得各写各的名字（ISO / WIM / DMG …）。
  final String? badge;

  const ArchiveFile({
    required this.name,
    required this.type,
    required this.size,
    this.flags = const [],
    this.depth = 0,
    this.badge,
  });

  String get typeLabel => badge ?? type.label;
}
