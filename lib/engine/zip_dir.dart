/// 极简 ZIP 中央目录（Central Directory）解析器。
///
/// ## 为什么不用 `package:archive`
///
/// 1. `ZipDecoder.decodeStream` 对 **symlink 条目**会调 `readBytes()` 触发真实
///    解压（源码里 `entry.symbolicLink = utf8.decode(bytes)`）。扫描来路不明的
///    压缩包时这是一条可被利用的炸弹路径。**本文件任何路径都不会解压**，只做
///    字节读取与偏移计算。
/// 2. 我们需要 `generalPurposeBitFlag`（判断 ZipCrypto 加密）、`method`
///    （判断 store/deflate 以便 P4 选廉价验证方式）、以及 `0x9901` AES 额外字段
///    （区分 WinZip AES 与 ZipCrypto、拿真实压缩算法与密钥强度）。
///    `ArchiveFile` 一个都不暴露。
/// 3. 纯字节操作 ⇒ 可以在 `flutter_test` 里手工造夹具单测，不需要真文件。
///
/// ## 边界
///
/// 只做「读」，不做「解」。分卷压缩包的跨卷读取不在这里（P6 走原生回调），
/// 本模块假定调用方给的是一段连续字节。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

// ---------------------------------------------------------------------------
// 常量
// ---------------------------------------------------------------------------

const int kLocalHeaderSignature = 0x04034B50;
const int kCentralHeaderSignature = 0x02014B50;
const int kEndOfCentralDirSignature = 0x06054B50;
const int kZip64EndOfCentralDirSignature = 0x06064B50;
const int kZip64EndOfCentralDirLocatorSignature = 0x07064B50;
const int kDataDescriptorSignature = 0x08074B50;

/// EOCD 定长部分为 22 字节，其后最多跟 65535 字节注释。
const int kEocdMinSize = 22;
const int kMaxZipComment = 0xFFFF;

/// Zip64 EOCD 定位器固定 20 字节，紧挨在 EOCD 之前。
const int kZip64LocatorSize = 20;

/// 中央目录一次最多读入的字节数。64 MiB 已远超 20 万条目的规模，
/// 达不到时按截断处理（解析出的条目数 < `declaredEntryCount`）。
const int kMaxCentralDirectoryBytes = 64 * 1024 * 1024;

/// 中央目录一次最多解析的条目数，与 `limits.dart` 的炸弹阈值一致。
const int kMaxCentralDirectoryEntries = 200000;

// 额外字段 ID
const int kExtraZip64 = 0x0001;
const int kExtraAes = 0x9901;

// 通用位标志
const int kFlagEncrypted = 0x0001;
const int kFlagUtf8Name = 0x0800;
const int kFlagDataDescriptor = 0x0008;

// ---------------------------------------------------------------------------
// 小端读取
// ---------------------------------------------------------------------------

int _u16(Uint8List b, int o) => b[o] | (b[o + 1] << 8);

int _u32(Uint8List b, int o) =>
    b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);

int _u64(Uint8List b, int o) => _u32(b, o) + _u32(b, o + 4) * 0x100000000;

// ---------------------------------------------------------------------------
// 条目
// ---------------------------------------------------------------------------

/// 中央目录里的一条记录。字段名沿用 ZIP 规范（APPNOTE 4.4.10）。
class ZipEntry {
  const ZipEntry({
    required this.name,
    required this.flags,
    required this.method,
    required this.crc32,
    required this.compressedSize,
    required this.uncompressedSize,
    required this.localHeaderOffset,
    required this.externalAttrs,
    this.aesStrength = 0,
    this.aesMethod = 0,
  });

  /// 条目名。CP437 在 Dart 里没有现成解码器，故按 latin1 解（ASCII 部分精确，
  /// 容器标记检测只需要 ASCII），位 11 置位时按 UTF-8 解。
  final String name;

  /// 通用位标志。
  final int flags;

  /// 实际压缩算法。AES 条目此处已被 [aesMethod] 覆盖（ZIP 规范要求
  /// AES 条目的 method 字段写 99，真实算法藏在 `0x9901` 里）。
  final int method;

  final int crc32;
  final int compressedSize;
  final int uncompressedSize;

  /// 本地文件头相对「归档起始处」的偏移，P4 靠它定位 AES salt / ZipCrypto 头。
  final int localHeaderOffset;

  /// 外部属性，高 16 位是 Unix mode（法规 3.3 的符号链接判定要用）。
  final int externalAttrs;

  /// WinZip AES 密钥强度：1 = 128 位，2 = 192 位，3 = 256 位；0 表示非 AES。
  final int aesStrength;

  /// `0x9901` 里的真实压缩算法；0 表示非 AES。
  final int aesMethod;

  /// ZipCrypto 或 AES 加密（两者都用通用位 0 标记）。
  bool get isEncrypted => (flags & kFlagEncrypted) != 0;

  /// WinZip AES。与 ZipCrypto 的验证方式完全不同，P4 必须分开处理。
  bool get isAes => aesMethod != 0;

  /// AES 密钥长度（位）。非 AES 时为 0。
  int get aesKeyBits => switch (aesStrength) {
    1 => 128,
    2 => 192,
    3 => 256,
    _ => 0,
  };

  /// AES 载荷头（salt + 2 字节 passwordVerification）的长度。
  /// salt 长度 = 密钥长度 / 16 字节。
  int get aesSaltBytes => switch (aesStrength) {
    1 => 8,
    2 => 12,
    3 => 16,
    _ => 0,
  };

  bool get hasDataDescriptor => (flags & kFlagDataDescriptor) != 0;

  bool get isDirectory => name.endsWith('/');

  /// Unix 模式下 `S_IFLNK`，即符号链接条目。
  bool get isSymlink => (externalAttrs >> 16) & 0xF000 == 0xA000;

  @override
  String toString() => 'ZipEntry($name, method=$method, '
      '${compressedSize}B→${uncompressedSize}B'
      '${isEncrypted ? ', enc' : ''}${isAes ? '/aes$aesStrength' : ''})';
}

/// EOCD 定位结果。
class ZipEndOfCentralDirectory {
  const ZipEndOfCentralDirectory({
    required this.eocdFileOffset,
    required this.declaredEntryCount,
    required this.centralDirectorySize,
    required this.centralDirectoryOffset,
    required this.commentLength,
    required this.isZip64,
  });

  /// EOCD 签名在**文件中**的绝对偏移。
  final int eocdFileOffset;

  /// 中央目录声明的条目总数（可能超出 16 位而走 Zip64）。
  final int declaredEntryCount;

  final int centralDirectorySize;

  /// 中央目录相对**归档起始处**的偏移。
  final int centralDirectoryOffset;

  final int commentLength;

  final bool isZip64;

  /// 归档起始处在文件中的绝对偏移（= 前置数据长度，即 SFX 场景下的
  /// [SniffResult.baseOffset]）。
  ///
  /// EOCD 紧跟在中央目录之后，所以：
  /// `eocdOffset = archiveStart + cdOffset + cdSize`
  int get archiveStartOffset =>
      eocdFileOffset - centralDirectoryOffset - centralDirectorySize;
}

/// 一次中央目录读取的完整产出。
class ZipListing {
  const ZipListing({
    required this.entries,
    required this.archiveStartOffset,
    required this.declaredEntryCount,
    required this.centralDirectorySize,
    required this.commentLength,
    required this.isZip64,
  });

  final List<ZipEntry> entries;

  /// 归档起始处在文件中的绝对偏移，> 0 表示有前置数据。
  final int archiveStartOffset;

  /// EOCD 声明的条目数。若大于 `entries.length`，说明要么撞上了
  /// [kMaxCentralDirectoryEntries] 上限，要么中央目录被截断。
  final int declaredEntryCount;

  final int centralDirectorySize;
  final int commentLength;
  final bool isZip64;

  bool get isTruncated => entries.length < declaredEntryCount;

  int get entryCount => entries.length;
}

// ---------------------------------------------------------------------------
// EOCD 定位（纯函数）
// ---------------------------------------------------------------------------

/// 在一段**文件尾部字节**里反向查找 EOCD。
///
/// [tail] 是文件末尾的一段连续字节，[tailFileOffset] 是 `tail[0]` 在文件中的
/// 绝对偏移。**同一条记录可能有多个签名**（注释里恰好出现 `PK\x05\x06`），
/// 所以从后往前扫，并且要求「签名位置 + 22 + 注释长度 == 文件长度」才算数。
///
/// 找不到返回 null。
ZipEndOfCentralDirectory? findEndOfCentralDirectory(
  Uint8List tail, {
  required int tailFileOffset,
  required int fileSize,
}) {
  if (tail.isEmpty) return null;

  // 从后往前扫。EOCD 最早可能出现在 fileSize - 22 - 65535 处。
  final lowest = 0;
  for (var i = tail.length - kEocdMinSize; i >= lowest; i--) {
    if (_u32(tail, i) != kEndOfCentralDirSignature) continue;

    final abs = tailFileOffset + i;
    final commentLength = _u16(tail, i + 20);

    // 自洽性检查：EOCD 之后只能是注释，且长度必须刚好对上。
    // 这一条把「注释里恰好出现签名的假阳性」几乎全部排除。
    if (abs + kEocdMinSize + commentLength != fileSize) continue;

    var entryCount = _u16(tail, i + 10);
    var cdSize = _u32(tail, i + 12);
    var cdOffset = _u32(tail, i + 16);
    var isZip64 = false;

    // 任一 32 位字段溢出，就去 Zip64 记录里取真值。
    if (entryCount == 0xFFFF || cdSize == 0xFFFFFFFF || cdOffset == 0xFFFFFFFF) {
      final z = _readZip64(tail, tailFileOffset, abs);
      if (z != null) {
        entryCount = z.entryCount;
        cdSize = z.cdSize;
        cdOffset = z.cdOffset;
        isZip64 = true;
      }
    }

    return ZipEndOfCentralDirectory(
      eocdFileOffset: abs,
      declaredEntryCount: entryCount,
      centralDirectorySize: cdSize,
      centralDirectoryOffset: cdOffset,
      commentLength: commentLength,
      isZip64: isZip64,
    );
  }
  return null;
}

/// 顺着 Zip64 定位器读 Zip64 EOCD 记录。任何一步不成立都返回 null
/// （宁可退化成 32 位视图，也不要抛异常打断一次扫描）。
({int entryCount, int cdSize, int cdOffset})? _readZip64(
  Uint8List tail,
  int tailFileOffset,
  int eocdOffset,
) {
  // 定位器紧挨在 EOCD 之前。
  final locIdx = eocdOffset - kZip64LocatorSize - tailFileOffset;
  if (locIdx < 0 || locIdx + kZip64LocatorSize > tail.length) return null;
  if (_u32(tail, locIdx) != kZip64EndOfCentralDirLocatorSignature) return null;

  final z64Offset = _u64(tail, locIdx + 8);
  final z64Idx = z64Offset - tailFileOffset;
  // Zip64 EOCD 记录本身 56 字节；调用方给的 tail 通常够。
  if (z64Idx < 0 || z64Idx + 56 > tail.length) return null;
  if (_u32(tail, z64Idx) != kZip64EndOfCentralDirSignature) return null;

  return (
    entryCount: _u64(tail, z64Idx + 32),
    cdSize: _u64(tail, z64Idx + 40),
    cdOffset: _u64(tail, z64Idx + 48),
  );
}

// ---------------------------------------------------------------------------
// 中央目录解析（纯函数）
// ---------------------------------------------------------------------------

/// 解析一段中央目录字节。
///
/// 输入必须是**从中央目录开头**开始的连续字节；解析到尾巴不足一条记录、
/// 或遇到非中央目录签名时停止（视为缓冲区被截断），不会抛异常。
List<ZipEntry> parseCentralDirectory(
  Uint8List cd, {
  int maxEntries = kMaxCentralDirectoryEntries,
}) {
  final entries = <ZipEntry>[];
  var p = 0;

  while (p + 46 <= cd.length && entries.length < maxEntries) {
    if (_u32(cd, p) != kCentralHeaderSignature) break;

    final flags = _u16(cd, p + 8);
    var method = _u16(cd, p + 10);
    final crc = _u32(cd, p + 16);
    var compSize = _u32(cd, p + 20);
    var uncompSize = _u32(cd, p + 24);
    final nameLen = _u16(cd, p + 28);
    final extraLen = _u16(cd, p + 30);
    final commentLen = _u16(cd, p + 32);
    final externalAttrs = _u32(cd, p + 38);
    var localOffset = _u32(cd, p + 42);

    final nameStart = p + 46;
    final extraStart = nameStart + nameLen;
    final extraEnd = extraStart + extraLen;
    final recordEnd = extraEnd + commentLen;

    // 缓冲区被截断（cd 被 kMaxCentralDirectoryBytes 砍过）→ 丢掉这条不完整的。
    if (recordEnd > cd.length) break;

    var aesStrength = 0;
    var aesMethod = 0;

    var e = extraStart;
    while (e + 4 <= extraEnd) {
      final id = _u16(cd, e);
      final size = _u16(cd, e + 2);
      final dataStart = e + 4;
      if (dataStart + size > extraEnd) break; // 额外字段自相矛盾，放弃剩余

      if (id == kExtraZip64) {
        // 规范 4.5.3：只包含固定头里写成 0xFFFFFFFF 的那些字段，且按此顺序。
        var q = dataStart;
        final limit = dataStart + size;
        if (uncompSize == 0xFFFFFFFF && q + 8 <= limit) {
          uncompSize = _u64(cd, q);
          q += 8;
        }
        if (compSize == 0xFFFFFFFF && q + 8 <= limit) {
          compSize = _u64(cd, q);
          q += 8;
        }
        if (localOffset == 0xFFFFFFFF && q + 8 <= limit) {
          localOffset = _u64(cd, q);
          q += 8;
        }
      } else if (id == kExtraAes && size >= 7) {
        // dataStart+0..1 版本，+2..3 厂商 "AE"，+4 强度，+5..6 真实 method
        aesStrength = cd[dataStart + 4];
        aesMethod = _u16(cd, dataStart + 5);
        if (aesMethod != 0) method = aesMethod;
      }
      e = dataStart + size;
    }

    entries.add(ZipEntry(
      name: _decodeName(
        Uint8List.sublistView(cd, nameStart, nameStart + nameLen),
        flags,
      ),
      flags: flags,
      method: method,
      crc32: crc,
      compressedSize: compSize,
      uncompressedSize: uncompSize,
      localHeaderOffset: localOffset,
      externalAttrs: externalAttrs,
      aesStrength: aesStrength,
      aesMethod: aesMethod,
    ));

    p = recordEnd;
  }

  return entries;
}

String _decodeName(Uint8List bytes, int flags) {
  if (bytes.isEmpty) return '';
  // 位 11 置位 = 名字是 UTF-8。未置位按 CP437，但 Dart 无 CP437 码表；
  // latin1 对 ASCII 部分（我们做标记匹配只用 ASCII）完全精确。
  if ((flags & kFlagUtf8Name) != 0) {
    return utf8.decode(bytes, allowMalformed: true);
  }
  return latin1.decode(bytes, allowInvalid: true);
}

// ---------------------------------------------------------------------------
// 读文件（异步）
// ---------------------------------------------------------------------------

/// 从文件里读出中央目录并解析。
///
/// 自己从尾部 EOCD 推出 [ZipListing.archiveStartOffset]，因此调用方不需要事先
/// 知道前置数据长度 —— 这也正是需求 5（SFX / 被追加文件头的压缩包）要的。
///
/// 任何失败（不是 ZIP、EOCD 自洽性不过、IO 错误）都返回 null，不抛异常：
/// 扫描路径上「读不出来」是常态，不该中断整次扫描。
Future<ZipListing?> readZipListing(
  RandomAccessFile raf, {
  required int fileSize,
  int maxEntries = kMaxCentralDirectoryEntries,
  int maxCdBytes = kMaxCentralDirectoryBytes,
}) async {
  if (fileSize < kEocdMinSize) return null;

  final tailLen = fileSize < kTailScanBytes ? fileSize : kTailScanBytes;
  final tailOffset = fileSize - tailLen;
  final tail = await readFully(raf, tailOffset, tailLen);
  if (tail.length < kEocdMinSize) return null;

  final eocd = findEndOfCentralDirectory(
    tail,
    tailFileOffset: tailOffset,
    // 注意：用 tail 的实际长度反推，因为文件可能在读取期间被改过。
    fileSize: tailOffset + tail.length,
  );
  if (eocd == null) return null;

  final start = eocd.archiveStartOffset;
  if (start < 0 || start > fileSize) return null;

  // 自相矛盾：声称有条目却没有任何中央目录。真实的空归档这两项都是 0。
  // 这条必须放在下面的 cdSize == 0 提前返回之前，否则会被绕过。
  if (eocd.centralDirectorySize == 0 && eocd.declaredEntryCount > 0) {
    return null;
  }

  final cdReadSize = eocd.centralDirectorySize > maxCdBytes
      ? maxCdBytes
      : eocd.centralDirectorySize;
  if (cdReadSize <= 0) {
    return ZipListing(
      entries: const [],
      archiveStartOffset: start,
      declaredEntryCount: eocd.declaredEntryCount,
      centralDirectorySize: eocd.centralDirectorySize,
      commentLength: eocd.commentLength,
      isZip64: eocd.isZip64,
    );
  }

  final cd = await readFully(raf, start + eocd.centralDirectoryOffset, cdReadSize);
  if (cd.isEmpty) return null;
  if (_u32(cd, 0) != kCentralHeaderSignature) return null; // 中央目录签名对不上

  return ZipListing(
    entries: parseCentralDirectory(cd, maxEntries: maxEntries),
    archiveStartOffset: start,
    declaredEntryCount: eocd.declaredEntryCount,
    centralDirectorySize: eocd.centralDirectorySize,
    commentLength: eocd.commentLength,
    isZip64: eocd.isZip64,
  );
}

/// EOCD 反向扫描的窗口大小。注释最长 65535 字节，128 KiB 足够覆盖。
const int kTailScanBytes = 128 * 1024;

/// 一次「读满 N 字节」，读不满就返回读到的部分。
///
/// `RandomAccessFile.read` 不保证一次读满，直接当定长用会踩坑。
Future<Uint8List> readFully(
  RandomAccessFile raf,
  int offset,
  int length,
) async {
  if (length <= 0) return Uint8List(0);
  await raf.setPosition(offset);
  final buf = Uint8List(length);
  var got = 0;
  while (got < length) {
    final n = await raf.readInto(buf, got, length);
    if (n <= 0) break;
    got += n;
  }
  return got == length ? buf : Uint8List.sublistView(buf, 0, got);
}
