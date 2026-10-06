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

/// EOCD 签名 `PK\x05\x06`。`zip_dir.dart` 只导出了「最小长度」那个常量，
/// 签名本身没导出（它只需要在内部按偏移找），所以这里自带一份。
const int _kEocdSignature = 0x06054B50;

/// 加密位：中央目录记录的通用位 bit 0。
///
/// 与 `zip_dir.dart` 的 `kFlagEncrypted` 同值 —— 那边导出了，这里刻意用
/// 字面量再写一遍：夹具要是直接引用被测代码的常量，那条常量被人改错时
/// **两边一起错**，测试照样绿。手写 0x0001 才让它们互相印证。
const int _kFlagEncryptedInFixture = 0x0001;

/// [realZip] 的加密版：把每条中央目录记录的通用位 bit 0 打开。
///
/// 只动中央目录、**不动局部头**：这样嗅探还是按正常的 ZIP 认出来（局部头
/// `PK\x03\x04` 原封不动），而「要不要密码」正是从中央目录读的 —— 于是这个
/// 夹具逼着被测代码走「读中央目录 → 认加密位」这条路，而不是蒙对。
///
/// 真实的加密 zip 两处都会置位，但这里只改判据真正看的地方，免得夹具比
/// 被测代码知道得还多。
Uint8List encryptedZip(Map<String, String> files) {
  final bytes = Uint8List.fromList(realZip(files));
  final bd = ByteData.sublistView(bytes);

  var eocd = -1;
  for (var i = bytes.length - kEocdMinSize; i >= 0; i--) {
    if (bd.getUint32(i, Endian.little) == _kEocdSignature) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0) throw StateError('夹具里没找到 EOCD，ZipEncoder 的输出变了？');

  var off = bd.getUint32(eocd + 16, Endian.little); // 中央目录起始偏移
  final count = bd.getUint16(eocd + 10, Endian.little);
  for (var n = 0; n < count; n++) {
    if (bd.getUint32(off, Endian.little) != kCentralHeaderSignature) {
      throw StateError('第 $n 条中央目录记录的签名不对，偏移算错了');
    }
    bd.setUint16(
      off + 8,
      bd.getUint16(off + 8, Endian.little) | _kFlagEncryptedInFixture,
      Endian.little,
    );
    off += 46 +
        bd.getUint16(off + 28, Endian.little) + // 名长
        bd.getUint16(off + 30, Endian.little) + // 额外字段长
        bd.getUint16(off + 32, Endian.little); // 注释长
  }
  return bytes;
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
