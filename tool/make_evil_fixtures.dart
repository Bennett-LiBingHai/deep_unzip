/// 生成**对抗性**压缩包夹具 —— 专门用来打路径安全那一条线。
///
/// 和 `make_fixtures.dart` 分家的理由：那个产的是「正常应该能解」的包，
/// 这个产的是「必须解不出去」的包。两者的判据方向相反，混在一起容易看错。
///
/// ## 为什么手写 ZIP 字节，不用 `package:archive`
///
/// 一是 `ZipEncoder` 大概率会把 `../` 规范化掉（它自己的 `ArchiveFile.name`
/// 有清洗），那样夹具生成出来就不再是攻击样本了 —— 一个「被生成器提前修好
/// 的 zip-slip」是最坏的假绿。
/// 二是符号链接要 `versionMadeBy = 3`（Unix）加上 `external attributes` 里的
/// `S_IFLNK`，`ArchiveFile` 那层 API 碰不到这两个字段。
///
/// 所以这里全部**存储**（method 0）、零压缩，逐字段手写，每个字节都是我们放的。
///
/// 用法：
/// ```
/// dart run tool/make_evil_fixtures.dart [输出目录]
/// ```
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

/// 一个要写进 zip 的条目。[unixMode] 非空时按 Unix 语义写 `versionMadeBy`
/// 与外部属性 —— 符号链接（`0xA1FF`）靠的就是它。
class _Entry {
  const _Entry(this.name, this.data, {this.unixMode});
  final String name;

  /// `String` 或 `List<int>`。取 `Object` 而不是 `List<int>` 是为了让上面的
  /// 字面量能写成 `const` —— 编码推迟到 [bytes] 里做。
  final Object data;
  final int? unixMode;

  /// 字符串一律走 `utf8.encode`，**不能**用 `codeUnits`：后者给的是 16 位码元，
  /// 会被 `Uint8List` 砍成单字节垃圾（`make_fixtures.dart` 里踩过一次，
  /// 那次让 `broken.zip` 的自检恒返回「解不开」，等于没判）。
  List<int> get bytes =>
      data is List<int> ? data as List<int> : utf8.encode('$data');
}

void main(List<String> args) {
  final root = args.isEmpty ? p.join('build', 'evil') : args.first;
  final dir = Directory(root);
  if (dir.existsSync()) dir.deleteSync(recursive: true);
  dir.createSync(recursive: true);

  // 1. 相对穿越。真机上必须落在输出目录**内部**（被清洗成 `duz_escape.txt`
  //    之类），绝不能出现在 /sdcard/Download/ 或更上层。
  _write(
    p.join(root, 'escape.zip'),
    _rawZip(const [
      _Entry('readme.txt', '这个包是干净的，用来确认它确实被解开了'),
      _Entry('../../duz_escape.txt', '如果这个文件出现在输出目录之外，就是 zip-slip'),
      _Entry('a/../../../duz_escape2.txt', '中间夹一层，考的是逐段处理'),
      _Entry('./duz_dot.txt', '单点段'),
    ]),
  );

  // 2. 绝对路径。`kCurPaths` 之外还要它别把 `/sdcard/...` 当成根。
  _write(
    p.join(root, 'absolute.zip'),
    _rawZip(const [
      _Entry('/sdcard/Download/duz_evil_abs.txt', '绝对路径穿越'),
    ]),
  );

  // 3. 符号链接 → 指向输出目录之外。一期策略是**不建链接**（C++ 侧
  //    `SymLinks.Val = false`），所以预期是它压根不出现在输出里，或者落成
  //    一个普通文件；无论哪种，都不能是一个指向 /sdcard/Download 的链接。
  _write(
    p.join(root, 'symlink.zip'),
    _rawZip(const [
      _Entry('normal.txt', '同包里的正常条目'),
      _Entry('evil_link', '/sdcard/Download', unixMode: 0xA1FF), // S_IFLNK|0777
    ]),
  );

  stdout.writeln('对抗性夹具已写到 ${dir.absolute.path}');
  for (final f in dir.listSync().whereType<File>()) {
    stdout.writeln('  ${p.basename(f.path)}  (${f.lengthSync()} B)');
  }
}

/// 手写一个**存储式**（不压缩）ZIP。
///
/// 布局按 PKWARE APPNOTE：
/// ```
/// 本地文件头 30 + n + m 字节
///   0..3  PK\x03\x04   4..5 解压所需版本   6..7 通用标志   8..9 压缩方法(0=存储)
///   10..11 时间        12..13 日期         14..17 CRC32
///   18..21 压缩后大小  22..25 压缩前大小   26..27 名字长度 n
///   28..29 扩展长度 m  30.. 名字 + 扩展 + 数据
/// 中央目录 46 + n + m + k
///   0..3  PK\x01\x02   4..5 写入者版本     6..7 解压所需版本
///   ...
///   16..19 CRC32       20..23 压缩后       24..27 压缩前
///   28..29 名字长度    30..31 扩展长度     32..33 注释长度
///   34..35 起始盘      36..37 内部属性     38..41 外部属性
///   42..45 本地头偏移  46.. 名字 + 扩展 + 注释
/// 结尾记录 22 字节
/// ```
Uint8List _rawZip(List<_Entry> entries) {
  final out = BytesBuilder();
  final offsets = <int>[];

  for (final e in entries) {
    final name = utf8.encode(e.name);
    final crc = getCrc32(e.bytes);
    offsets.add(out.length);

    out.add(_u32(0x04034b50)); // PK\x03\x04
    out.add(_u16(20)); // 解压所需版本
    out.add(_u16(0)); // 通用标志
    out.add(_u16(0)); // 存储
    out.add(_u16(0)); // 时间
    out.add(_u16(0x2821)); // 日期（随便一个合法值）
    out.add(_u32(crc));
    out.add(_u32(e.bytes.length));
    out.add(_u32(e.bytes.length));
    out.add(_u16(name.length));
    out.add(_u16(0)); // 无扩展字段
    out.add(name);
    out.add(e.bytes);
  }

  final cdStart = out.length;
  for (var i = 0; i < entries.length; i++) {
    final e = entries[i];
    final name = utf8.encode(e.name);
    // 写入者版本：高字节是宿主系统，3 = Unix。只有它非零，外部属性里的
    // S_IFLNK 才会被 7-Zip 当回事。
    final madeBy = e.unixMode != null ? (3 << 8) | 20 : (0 << 8) | 20;

    out.add(_u32(0x02014b50)); // PK\x01\x02
    out.add(_u16(madeBy));
    out.add(_u16(20));
    out.add(_u16(0));
    out.add(_u16(0));
    out.add(_u16(0));
    out.add(_u16(0x2821));
    out.add(_u32(getCrc32(e.bytes)));
    out.add(_u32(e.bytes.length));
    out.add(_u32(e.bytes.length));
    out.add(_u16(name.length));
    out.add(_u16(0)); // 扩展
    out.add(_u16(0)); // 注释
    out.add(_u16(0)); // 起始盘
    out.add(_u16(0)); // 内部属性
    // 外部属性高 16 位是 Unix 权限位。符号链接要 S_IFLNK(0xA000) | 0777。
    out.add(_u32(e.unixMode == null ? 0 : e.unixMode! << 16));
    out.add(_u32(offsets[i]));
    out.add(name);
  }
  final cdSize = out.length - cdStart;

  out.add(_u32(0x06054b50)); // PK\x05\x06
  out.add(_u16(0)); // 本盘号
  out.add(_u16(0)); // 中央目录起始盘
  out.add(_u16(entries.length));
  out.add(_u16(entries.length));
  out.add(_u32(cdSize));
  out.add(_u32(cdStart));
  out.add(_u16(0)); // 注释长度

  return out.toBytes();
}

Uint8List _u16(int v) => Uint8List(2)
  ..[0] = v & 0xFF
  ..[1] = (v >> 8) & 0xFF;

Uint8List _u32(int v) => Uint8List(4)
  ..[0] = v & 0xFF
  ..[1] = (v >> 8) & 0xFF
  ..[2] = (v >> 16) & 0xFF
  ..[3] = (v >> 24) & 0xFF;

void _write(String path, List<int> bytes) {
  final f = File(path);
  f.parent.createSync(recursive: true);
  f.writeAsBytesSync(bytes);
}
