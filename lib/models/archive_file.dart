/// 压缩包类型
enum ArchiveType { zip, rar, sevenz, tar, unknown }

/// 文件标记
enum ArchiveFlag { encrypted, split, fakeExtension, nested }

/// 压缩包文件模型
class ArchiveFile {
  final String name;
  final ArchiveType type;
  final String size;
  final List<ArchiveFlag> flags;
  final int depth;

  const ArchiveFile({
    required this.name,
    required this.type,
    required this.size,
    this.flags = const [],
    this.depth = 0,
  });

  String get typeLabel => type.name.toUpperCase();
}
