import '../models/extractor.dart';

/// 内置解压方式清单。
///
/// 这不是演示数据 —— 删掉 `utils/mock_data.dart` 时特意把它留了下来，因为
/// 它描述的是**这个 app 真正内置了哪几种解压后端**：设置页把它当「内置」分组
/// 展示，[Extractor.isBuiltin] 为真时删不掉（见 `AppState.deleteExtractor`），
/// 而且 P8 的声明式规格解析器要拿它当注册表的初始内容。
///
/// [Extractor.detectLogic] / [Extractor.extractLogic] 是**给人看的字符串**，
/// 不是可执行代码 —— 它们只在设置页的详情里原样显示。真正常用的是
/// `engine/sniff.dart`（探测）与 `engine/backends/`（解压），
/// 两者都不读这里的字符串。所以这里的值与后缀名对不上时，**以后者为准**。
class BuiltinExtractors {
  /// 按可信度从高到低排。`AppState.extractors` 拿它做初始列表。
  static const List<Extractor> all = [
    Extractor(
      name: 'ZIP',
      type: ExtractorType.single,
      detectLogic: 'readHeader(4) === 0x504B0304',
      extractLogic: 'unzip -o {file} -d {dir}',
      isBuiltin: true,
    ),
    Extractor(
      name: 'RAR5',
      type: ExtractorType.single,
      detectLogic: 'readHeader(7) === 0x526172211A0701',
      extractLogic: 'unrar x -y {file} {dir}',
      isBuiltin: true,
    ),
    Extractor(
      name: '7Z',
      type: ExtractorType.single,
      detectLogic: 'readHeader(6) === 0x377ABCAF271C',
      extractLogic: '7z x -y {file} -o{dir}',
      isBuiltin: true,
    ),
    Extractor(
      name: 'TAR.GZ',
      type: ExtractorType.single,
      detectLogic: 'readHeader(2) === 0x1F8B',
      extractLogic: 'tar -xzf {file} -C {dir}',
      isBuiltin: true,
    ),
    Extractor(
      name: 'RAR 分卷',
      type: ExtractorType.split,
      detectLogic: '匹配 *.part01.rar / *.r01 序列',
      extractLogic: 'unrar x -y {firstFile} {dir}',
      isBuiltin: true,
    ),
    Extractor(
      name: 'ZIP 分卷',
      type: ExtractorType.split,
      detectLogic: '匹配 *.zip.001 / *.z01 序列',
      extractLogic: 'zip -s- {firstFile} --out temp.zip && unzip temp.zip',
      isBuiltin: true,
    ),
  ];
}
