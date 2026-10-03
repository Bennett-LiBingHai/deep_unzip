/// 解压方式类型：单文件解压 / 分片文件解压
enum ExtractorType { single, split }

/// 解压器注册模型
/// 用户扩展时需传入：类型名称、判断函数、解压函数
/// 两个函数的参数均为文件地址
class Extractor {
  final String name;
  final ExtractorType type;
  final String detectLogic; // 判断函数描述 / 代码摘要
  final String extractLogic; // 解压函数描述 / 代码
  final bool isBuiltin;

  const Extractor({
    required this.name,
    required this.type,
    required this.detectLogic,
    required this.extractLogic,
    this.isBuiltin = false,
  });

  String get typeLabel => type == ExtractorType.single ? 'SINGLE' : 'SPLIT';
  String get typeName => type == ExtractorType.single ? '单文件' : '分卷';
}
