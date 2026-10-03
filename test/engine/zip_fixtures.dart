/// 测试夹具：手工拼 ZIP 字节与临时文件。
///
/// 为什么手工拼而不是全用 `ZipEncoder`：`ZipEncoder` 造不出我们真正要测的
/// 边界 —— 前置数据（SFX）、Zip64 额外字段、AES 额外字段、异常注释。
/// 而纯手工拼又有「夹具和被测代码犯同一个错」的风险，所以两条路都走
/// （见 `zip_dir_test.dart`：普通路径用 `ZipEncoder` 交叉验证）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:deep_unzip/engine/zip_dir.dart';
import 'package:path/path.dart' as p;

// ---------------------------------------------------------------------------
// 小端写入
// ---------------------------------------------------------------------------

Uint8List le16(int v) => Uint8List.fromList([v & 0xFF, (v >> 8) & 0xFF]);

Uint8List le32(int v) =>
    Uint8List.fromList([v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF]);

Uint8List le64(int v) {
  final b = BytesBuilder();
  b.add(le32(v & 0xFFFFFFFF));
  b.add(le32(v >> 32));
  return b.toBytes();
}

// ---------------------------------------------------------------------------
// 手工拼 ZIP
// ---------------------------------------------------------------------------

/// 一条中央目录记录。默认字段都合法，需要哪个畸形就传哪个。
Uint8List cdRecord({
  required String name,
  int flags = 0,
  int method = 8,
  int crc = 0,
  int compSize = 0,
  int uncompSize = 0,
  int localOffset = 0,
  int externalAttrs = 0,
  List<int> extra = const [],
}) {
  final nameBytes = utf8.encode(name);
  final b = BytesBuilder();
  b.add(le32(kCentralHeaderSignature));
  b.add(le16(20)); // version made by
  b.add(le16(20)); // version needed
  b.add(le16(flags));
  b.add(le16(method));
  b.add(le16(0)); // mod time
  b.add(le16(0)); // mod date
  b.add(le32(crc));
  b.add(le32(compSize));
  b.add(le32(uncompSize));
  b.add(le16(nameBytes.length));
  b.add(le16(extra.length));
  b.add(le16(0)); // comment length
  b.add(le16(0)); // disk number start
  b.add(le16(0)); // internal attrs
  b.add(le32(externalAttrs));
  b.add(le32(localOffset));
  b.add(nameBytes);
  b.add(extra);
  return b.toBytes();
}

/// 把若干条中央目录记录拼成一段连续字节。
///
/// 注意不要写成 `BytesBuilder()..add(a).toBytes()` —— 级联的优先级低于 `.`，
/// 那会被解析成 `..(add(a).toBytes())`，而 `add` 返回 `void`。
Uint8List cdBytes(List<Uint8List> records) {
  final b = BytesBuilder();
  for (final r in records) {
    b.add(r);
  }
  return b.toBytes();
}

/// EOCD 记录。
Uint8List eocdRecord({
  required int count,
  required int cdSize,
  required int cdOffset,
  int commentLength = 0,
}) {
  final b = BytesBuilder();
  b.add(le32(kEndOfCentralDirSignature));
  b.add(le16(0)); // this disk
  b.add(le16(0)); // disk with CD
  b.add(le16(count));
  b.add(le16(count));
  b.add(le32(cdSize));
  b.add(le32(cdOffset));
  b.add(le16(commentLength));
  return b.toBytes();
}

/// 拼一个「只有中央目录 + EOCD」的文件。
///
/// 不是可解压的真 zip（没有本地头和数据），但足够测中央目录解析与 EOCD 定位
/// —— 那两条路径本来就只看这两块。
/// [prefixLength] 个 0x00 字节模拟前置数据（SFX 壳）。
Uint8List zipFromCentralDirectory(
  List<Uint8List> records, {
  List<int> comment = const [],
  int prefixLength = 0,
  int? forcedCdOffset,
  int? forcedCount,
}) {
  final cd = BytesBuilder();
  for (final r in records) {
    cd.add(r);
  }
  final cdBytes = cd.toBytes();

  final b = BytesBuilder();
  b.add(Uint8List(prefixLength));
  b.add(cdBytes);
  b.add(eocdRecord(
    count: forcedCount ?? records.length,
    cdSize: cdBytes.length,
    cdOffset: forcedCdOffset ?? 0,
    commentLength: comment.length,
  ));
  b.add(comment);
  return b.toBytes();
}

/// AES 额外字段 `0x9901`。
Uint8List aesExtra({required int strength, required int method}) {
  final b = BytesBuilder();
  b.add(le16(kExtraAes));
  b.add(le16(7)); // data size
  b.add(le16(2)); // version
  b.add(ascii.encode('AE'));
  b.addByte(strength);
  b.add(le16(method));
  return b.toBytes();
}

/// Zip64 额外字段 `0x0001`。只放调用方需要的段，顺序按规范 4.5.3。
Uint8List zip64Extra({int? uncompSize, int? compSize, int? localOffset}) {
  final payload = BytesBuilder();
  if (uncompSize != null) payload.add(le64(uncompSize));
  if (compSize != null) payload.add(le64(compSize));
  if (localOffset != null) payload.add(le64(localOffset));
  final data = payload.toBytes();

  final b = BytesBuilder();
  b.add(le16(kExtraZip64));
  b.add(le16(data.length));
  b.add(data);
  return b.toBytes();
}

// ---------------------------------------------------------------------------
// 真 ZIP（交叉验证用）
// ---------------------------------------------------------------------------

/// 用 `ZipEncoder` 造一个真能解压的 zip。
Uint8List realZip(Map<String, String> files) {
  final archive = Archive();
  files.forEach((name, content) {
    archive.add(ArchiveFile.string(name, content));
  });
  return ZipEncoder().encodeBytes(archive);
}

// ---------------------------------------------------------------------------
// 临时文件
// ---------------------------------------------------------------------------

/// 临时目录，测试结束由调用方清理。
Directory makeTempDir(String tag) =>
    Directory.systemTemp.createTempSync('duz_test_$tag');

/// 写一个文件，返回绝对路径。
String writeTempFile(Directory dir, String name, List<int> bytes) {
  final path = p.join(dir.path, name);
  File(path).writeAsBytesSync(bytes);
  return path;
}
