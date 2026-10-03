/// 生成真机冒烟测试用的压缩包夹具。
///
/// 计划「验证方式 3」点名的六项需求各至少要有一例。这里产出前四项能覆盖的
/// 部分（密码库是 P4、暂停/跳过是 P3，都不在 P1 的范围里）：
///
/// | 文件 | 覆盖 |
/// |---|---|
/// | `plain.zip` | 基线：普通 zip 能不能解开 |
/// | `nested.zip` | 需求 1：里面套一个 `inner.zip` |
/// | `big.zip` | 进度回调：约 40MB 未压缩，才看得到进度条动 |
/// | `split.zip.001/.002/.003` | 需求 4：裸字节切分 |
/// | `fake.pdf` | 需求 5：内容是 zip、后缀是 pdf |
/// | `broken.zip` | 需求 3 的前置：条目数据对不上 CRC，**必须**失败 |
/// | `tree/` | 递归扫描的源目录 |
///
/// **刻意不生成加密包**：`package:archive` 写不了加密 zip（AES / ZipCrypto
/// 都写不了），那是 P4 接密码库时用别的手段造的事。
///
/// 用法：
/// ```
/// dart run tool/make_fixtures.dart            # 输出到 build/fixtures
/// dart run tool/make_fixtures.dart <输出目录>
/// ```
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

/// `broken.zip` 里那个条目的原文，`_assertUnreadable` 要拿它比对。
const originalContent = '损坏前的正常内容';

void main(List<String> args) {
  final root = args.isEmpty ? p.join('build', 'fixtures') : args.first;
  final dir = Directory(root);
  if (dir.existsSync()) dir.deleteSync(recursive: true);
  dir.createSync(recursive: true);

  _write(p.join(root, 'plain.zip'), _zip({'hello.txt': '你好，DeepUnzip' * 20}));

  // 嵌套：外层解出来的目录里躺着一个 inner.zip，供递归解压（P2）与手工
  // 二次解压用。
  _write(
    p.join(root, 'nested.zip'),
    _zip({
      'readme.txt': '外层压缩包，解出来的目录里还有一个 inner.zip',
      'inner.zip': _zip({'deep.txt': '你是第二层的文件'}),
    }),
  );

  // 进度：`Archive` 里存**未压缩**内容，所以这些字节会被真压一遍。
  //
  // 两个刻意的选择：
  // - **伪随机**而不是重复字符。重复内容压完只剩几百字节，7-Zip 报一次进度
  //   就结束了，看不到进度条在动 —— 而那正是这个夹具要验证的东西。
  // - **32MB** 而不是几 MB。中端机上 7-Zip 的吞吐量在几十 MB/s 量级，
  //   8MB 会在 0.2 秒内跑完，连一次 120ms 的合并窗口都凑不满，进度回调
  //   一次都不发，看起来就像「进度坏了」。
  const chunk = 1024 * 1024;
  _write(
    p.join(root, 'big.zip'),
    _zip({
      for (var i = 0; i < 32; i++) 'blob_$i.bin': _randomBytes(chunk),
    }),
  );

  // 分卷：把 plain.zip 按字节切三段。裸字节切分（`.001`）在 split.dart 里
  // 是「虚拟拼接」那一族，7-Zip 侧靠 parts 列表直接读。
  final splitSrc = _zip({'a.txt': 'x' * 5000, 'b.txt': 'y' * 5000});
  const pieces = 3;
  final pieceLen = (splitSrc.length / pieces).ceil();
  for (var i = 0; i < pieces; i++) {
    final from = i * pieceLen;
    final to = (from + pieceLen).clamp(0, splitSrc.length);
    _write(
      p.join(root, 'split.zip.${(i + 1).toString().padLeft(3, '0')}'),
      splitSrc.sublist(from, to),
    );
  }

  // 伪后缀：内容是真 zip，名字是 .pdf。
  _write(p.join(root, 'fake.pdf'), _zip({'hidden.txt': '后缀是假的'}));

  // 损坏：拿一个合法的 zip，把条目**数据**中间那一个字节翻掉。
  //
  // 这里踩过一次坑，记下来免得重蹈。最初写的是「把中央目录里每一处
  // PK\x01\x02 的首字节砸掉」，想的是中央目录没了就开不了 —— 真机上 7-Zip
  // 照样列出条目并顺利解压完，夹具成了假绿的。原因是 ZIP handler 有**恢复
  // 路径**：中央目录不可读时它会扫描全文找本地文件头（PK\x03\x04）重建条目
  // 表。中央目录坏掉在 7-Zip 眼里属于可恢复的损坏。
  //
  // 唯一救不回来的是**数据本身对不上 CRC**：中央目录还在、条目能定位、本地
  // 头里的 CRC32 也还在，但解出来的字节校验不过。那正是 P3「暂停/跳过」要
  // 处理的那一类失败。
  final pristine = Uint8List.fromList(_zip({'ok.txt': originalContent}));
  final broken = Uint8List.fromList(pristine);
  _corruptEntryData(broken, 'ok.txt');

  // 判据自检，**两个方向都要验**。
  //
  // 只验「坏包解不出原文」是不够的：一个恒返回 false 的判据（比如拿
  // `String.fromCharCodes` 去比 utf8 字节，或者原文本身生成时就编码错了）
  // 会让这条断言永远为真，用例照样是假绿的 —— 而这正是已经踩过的坑，
  // 还踩了两次。所以先把完好的那一份喂给同一个判据，它必须认得出原文；
  // 认不出就说明判据坏了，立刻停下。
  if (!_decodesTo(pristine, originalContent)) {
    throw StateError('自检判据本身是坏的：完好的 zip 都解不出原文，'
        '下面那条「必须解不开」于是毫无意义。先修判据，别信这条用例。');
  }
  if (_decodesTo(broken, originalContent)) {
    throw StateError('broken.zip 还能原样解出「$originalContent」—— 这一砸没砸到'
        '数据区，用例会变成假绿的。检查本地头的偏移计算。');
  }
  _write(p.join(root, 'broken.zip'), broken);

  // 递归扫描的源目录：顶层 + 子目录各放一个包，再加一堆无关文件。
  final tree = Directory(p.join(root, 'tree', 'sub'));
  tree.createSync(recursive: true);
  _write(p.join(root, 'tree', 'a.zip'), _zip({'a.txt': 'A'}));
  _write(p.join(tree.path, 'b.zip'), _zip({'b.txt': 'B'}));
  _write(
    p.join(tree.path, 'notes.txt'),
    utf8.encode('这个文件不是压缩包，不该出现在结果里'),
  );
  _write(p.join(root, 'tree', 'photo.jpg'), _randomBytes(4096));

  stdout.writeln('夹具已写到 ${dir.absolute.path}');
  for (final f in dir.listSync(recursive: true).whereType<File>()) {
    final kb = (f.lengthSync() / 1024).toStringAsFixed(1);
    stdout.writeln('  ${p.relative(f.path, from: dir.path)}  ($kb KB)');
  }
}

List<int> _zip(Map<String, Object> entries) {
  final archive = Archive();
  entries.forEach((name, content) {
    // 字符串一律走 utf8.encode，**不能**用 `codeUnits`。
    //
    // `codeUnits` 给的是 16 位码元，而 `Uint8List.fromList` 每个只留低 8 位，
    // 于是每个汉字被砍成 1 个字节的垃圾。这个坑很隐蔽：包照样是合法的 zip、
    // 能列能解、长度看着也「对」（240 个汉字 → 240 字节），只有把内容打印
    // 出来才会发现全是乱码。真机上一直没露馅，是因为冒烟测试只看条目数和
    // 大小、从不比对内容。
    //
    // 它还有第二重危害：`broken.zip` 的自检拿 `utf8.decode` 跟原文比，
    // 而被砍过的字节永远解不回原文 —— 判据对任何输入都返回「对不上」，
    // 等于没判。是拿一个完好的包试出来的。
    final bytes = content is List<int>
        ? Uint8List.fromList(content)
        : Uint8List.fromList(utf8.encode('$content'));
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  return ZipEncoder().encode(archive);
}

/// 自检：**确认 [broken] 真的解不出 [original] 了**。
///
/// 这个夹具最容易出的错不是「砸得不够狠」，而是「砸完之后它还能正常解开」
/// —— 之前砸中央目录那次就是这样，真机上安安静静地成功，用例变成假绿的，
/// 而且不会有人发现。
///
/// 所以判据交给第三个实现（`package:archive`，既不是我们写的、也不是 7-Zip）：
/// 解出原文算「能开」，解码抛异常或内容对不上都算「开不了」。
///
/// 判据本身有两个必须守住的细节，都是当场踩出来的：
///
/// 1. 比对要走 `utf8.decode`，**不能**用 `String.fromCharCodes`。后者把每个
///    字节直接当码元，24 字节的 UTF-8 变成 24 个字符，跟 8 个汉字的原文
///    永远不相等 —— 判据恒返回「开不了」，等于没判。
/// 2. 原文得真是原文。生成侧曾经用 `codeUnits` 编码字符串，汉字被砍成单
///    字节垃圾，同样让判据永远比不中。
///
/// 两条叠加起来，就是「判据永远是绿的」这种最坏的假测试。所以调用方必须
/// **两个方向都验**：完好的包要认得出，坏包要认不出。
bool _decodesTo(Uint8List zip, String original) {
  try {
    final files = ZipDecoder().decodeBytes(zip).files;
    return files.isNotEmpty &&
        utf8.decode(files.first.content as List<int>, allowMalformed: true) ==
            original;
  } catch (_) {
    // 解码阶段就炸了。同样是「开不了」，不必区分是哪种炸法。
    return false;
  }
}

/// 把 [zip] 里名为 [entryName] 的那个条目**解压后的字节**改坏，制造一个
/// 7-Zip 无法恢复的 CRC 失配。
///
/// 做法：定位本地文件头，按它记录的压缩后长度算出数据区中点，翻掉那一个
/// 字节。之所以砸中间而不是首字节：首字节可能落在 deflate 块的头部，
/// 有些解码器会直接判「流坏了」，而我们想验的恰恰是**解码成功但校验不过**
/// 那条路径（`SetOperationResult` 报 kCRCError）。
///
/// 本地文件头的布局（除签名外都是小端）：
///
/// ```
///   0..3   PK\x03\x04      签名
///   4..5   解压所需版本
///   6..7   通用标志
///   8..9   压缩方法
///   10..11 修改时间
///   12..13 修改日期
///   14..17 CRC32           ← 留着不砸，正是它让损坏暴露出来
///   18..21 压缩后大小
///   22..25 压缩前大小
///   26..27 文件名长度 n
///   28..29 扩展字段长度 m
///   30..   文件名(n) + 扩展字段(m) + 数据
/// ```
void _corruptEntryData(Uint8List zip, String entryName) {
  int u16(int at) => zip[at] | (zip[at + 1] << 8);
  int u32(int at) => u16(at) | (u16(at + 2) << 16);

  // 本地头在文件最前面（ZipEncoder 先写数据后写中央目录），所以第 0 个
  // PK\x03\x04 就是它。这里不做通用扫描：夹具是我们自己生成的，布局已知，
  // 假装通用反而会掩盖「生成方式变了」这个信号。
  if (zip[0] != 0x50 || zip[1] != 0x4B || zip[2] != 0x03 || zip[3] != 0x04) {
    throw StateError('开头不是本地文件头 —— 生成方式变了，这个夹具得重写');
  }

  final nameLen = u16(26);
  final extraLen = u16(28);
  final compSize = u32(18);
  final name = String.fromCharCodes(zip.sublist(30, 30 + nameLen));
  if (name != entryName) {
    throw StateError('第一个条目是 "$name"，不是 "$entryName"');
  }
  if (compSize < 2) {
    throw StateError('"$entryName" 压缩后只有 $compSize 字节，砸不动');
  }

  final dataStart = 30 + nameLen + extraLen;
  zip[dataStart + compSize ~/ 2] ^= 0xFF;
}

/// 伪随机但**可复现**：冒烟测试要能复现才有意义，用固定种子的 LCG。
/// 不用 `Random()` 是因为那样每次跑出来的夹具都不同，`broken.zip` 的
/// 校验和也没法比对。
Uint8List _randomBytes(int length) {
  final out = Uint8List(length);
  var seed = 0x12345678;
  for (var i = 0; i < length; i++) {
    seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF;
    out[i] = (seed >> 16) & 0xFF;
  }
  return out;
}

void _write(String path, List<int> bytes) {
  final f = File(path);
  f.parent.createSync(recursive: true);
  f.writeAsBytesSync(bytes);
}
