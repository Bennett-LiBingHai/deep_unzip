/// 文件类型嗅探：只看文件头（和在必要时看文件尾）来判定**真实**格式。
///
/// 这是需求 5 的前半段 —— 后缀可以随便改，但字节改不了。
///
/// ## 三级判定
///
/// 1. **后缀跳过表**（[kContainerExtensions]）：命中就连文件都不开。一次
///    Downloads 扫描里几百个 `.docx`/`.apk` 能省掉几百次 open/read 系统调用。
/// 2. **文件头签名**：[_kSignaturesAtZero]（压缩包，绝大多数文件在这里就定了）、
///    [_kSignaturesOffset]（tar / lzh 的固定偏移）、[_kSignaturesExtra]（软件包与
///    磁盘映像那一批）。
/// 3. **兜底**：`MZ` 自解压文件在前 [kEmbeddedScanBytes] 内重扫签名；其余
///    文件从文件尾反向找 ZIP EOCD 并反推前置数据长度。两级窗口（先 1 KiB 后
///    128 KiB）是为了别让「一个都不认识的目录」付出 128 KiB × N 的读放大。
///    再看头窗口之外的两处：0x8000 的 ISO / UDF 卷描述符，和文件尾的 DMG 页脚。
/// 4. **向前搜签名**（排最后，也最贵）：在前 [kDefaultSniffWindowBytes] 字节里
///    找 7z / RAR5 / RAR4，命中后**按各自的块头 CRC 校验**。这是给「一张完整
///    图片打头、压缩包整段追加在后面」那种分享包准备的 —— 它没有可见的后缀
///    线索，签名也不在偏移 0。窗口大小可设（见 `SettingsData.sniffWindow`）。
///
/// ## 不做的事
///
/// 不判断「这个文件是不是压缩包内容」—— 那是扫描期的容器标记检测
/// （[detectContainer]）与解析期的级联（P5）的事。这里只回答「它是什么」。
library;

import 'dart:io';
import 'dart:typed_data';

import 'models.dart';
import 'zip_dir.dart';

// ---------------------------------------------------------------------------
// 窗口大小
// ---------------------------------------------------------------------------

/// 读文件头的字节数。512 字节覆盖了所有偏移 0 的签名，也覆盖了
/// TAR 位于偏移 257 的 `ustar`（需要到 262）。
const int kSniffHeadBytes = 512;

/// `MZ` 自解压文件向前重扫签名的最大距离。
///
/// **写死、不随设置变化**，这一点是刻意的：这条 PE 自解压的路自成一体，
/// 够不着 [`kDefaultSniffWindowBytes`] 那个可调窗口，所以把窗口调到多小
/// 都不会让「自解压包还认得出」这件事倒退。
const int kEmbeddedScanBytes = 1024 * 1024;

// 「向前搜签名」那个窗口的三个常量（`kDefaultSniffWindowBytes` /
// `kMinSniffWindowBytes` / `kMaxSniffWindowBytes`）定义在 `models.dart` ——
// `ScanOptions` 的默认值要引用它，而这个文件已经 import 了 `models.dart`，
// 放这边会变成互相 import。

/// ZIP EOCD 反向扫描的第一级窗口。绝大多数 zip 没有注释，EOCD 就压在
/// 最后 22 字节里，1 KiB 足够。
const int kTailProbeBytes = 1024;

// 第一级窗口没找到时扩到 `kTailScanBytes`（128 KiB），该常量定义在
// `zip_dir.dart` —— `readZipListing` 也要用它，两边必须一致。

/// 供 `FormatDetectModal.hexPreview` 使用的字节数。
const int kHexPreviewBytes = 16;

// ---------------------------------------------------------------------------
// 魔术字节表
// ---------------------------------------------------------------------------

/// 一条签名。
///
/// 表内**顺序即优先级**：靠前的先匹配。RAR5 的 8 字节签名以 RAR4 的 7 字节
/// 签名为前缀，所以 RAR5 必须排在 RAR4 前面，否则 RAR5 会被误判成 RAR4。
class _Signature {
  const _Signature(this.offset, this.pattern, this.format, this.confidence);

  final int offset;
  final List<int> pattern;
  final SniffFormat format;
  final SniffConfidence confidence;
}

/// 位于偏移 0 的签名。也是嵌入式重扫时唯一使用的集合。
const List<_Signature> _kSignaturesAtZero = [
  // —— 长签名优先 ——
  // RAR5：`Rar!\x1a\x07\x01\x00`，是 RAR4 签名的超集，必须先试。
  _Signature(0, [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00],
      SniffFormat.rar5, SniffConfidence.high),
  // RAR4：`Rar!\x1a\x07\x00`
  _Signature(0, [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00],
      SniffFormat.rar4, SniffConfidence.high),
  // 7z：`7z\xbc\xaf\x27\x1c`
  _Signature(0, [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C],
      SniffFormat.sevenZ, SniffConfidence.high),
  // XZ：`\xfd7zXZ\x00`
  _Signature(0, [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00],
      SniffFormat.xz, SniffConfidence.high),
  // ZIP 本地文件头 / 空归档（EOCD）/ 跨卷标记
  _Signature(0, [0x50, 0x4B, 0x03, 0x04], SniffFormat.zip, SniffConfidence.high),
  _Signature(0, [0x50, 0x4B, 0x05, 0x06], SniffFormat.zip, SniffConfidence.high),
  _Signature(0, [0x50, 0x4B, 0x07, 0x08], SniffFormat.zip, SniffConfidence.high),
  // CAB：`MSCF`
  _Signature(0, [0x4D, 0x53, 0x43, 0x46], SniffFormat.cab, SniffConfidence.high),
  // ZSTD：`\x28\xb5\x2f\xfd`
  _Signature(0, [0x28, 0xB5, 0x2F, 0xFD], SniffFormat.zstd, SniffConfidence.high),
  // CPIO ASCII 变体 `070707` / `070701`。
  // 降级为 medium：6 个 ASCII 数字是低熵串，纯文本文件也可能这样开头。
  _Signature(0, [0x30, 0x37, 0x30, 0x37, 0x30, 0x37], SniffFormat.cpio,
      SniffConfidence.medium),
  _Signature(0, [0x30, 0x37, 0x30, 0x37, 0x30, 0x31], SniffFormat.cpio,
      SniffConfidence.medium),
  // CPIO 二进制变体 `\xc7q`
  _Signature(0, [0xC7, 0x71], SniffFormat.cpio, SniffConfidence.medium),
  // BZIP2：`BZh`
  _Signature(0, [0x42, 0x5A, 0x68], SniffFormat.bzip2, SniffConfidence.medium),
  // GZIP：`\x1f\x8b`
  _Signature(0, [0x1F, 0x8B], SniffFormat.gzip, SniffConfidence.medium),
  // ARJ：`\x60\xea`
  _Signature(0, [0x60, 0xEA], SniffFormat.arj, SniffConfidence.medium),
];

/// 位于固定非 0 偏移的签名。**不参与嵌入式重扫** —— 在任意位置匹配 `ustar`
/// 或 `-lh` 的假阳性率太高，而「自解压包里套了个 tar」并不是真实场景。
const List<_Signature> _kSignaturesOffset = [
  // TAR：`ustar` 位于偏移 257（POSIX 头）
  _Signature(257, [0x75, 0x73, 0x74, 0x61, 0x72], SniffFormat.tar,
      SniffConfidence.medium),
  // LHA：偏移 2 起是 `-lh`，如 `-lh5-`
  _Signature(2, [0x2D, 0x6C, 0x68], SniffFormat.lzh, SniffConfidence.medium),
];

/// 软件包 / 光盘与磁盘映像这一批的签名（2026-10 补）。
///
/// **签名全部照 7-Zip 自己的 `REGISTER_ARC_I` 抄**（见各 `*Handler.cpp` 的
/// `k_Signature`），7-Zip 认什么我们就认什么，不自己发明判据。
///
/// 与 [_kSignaturesAtZero] **分开放**是有意的：那张表同时喂给 `MZ` 自解压壳的
/// 「前 1 MiB 内任意位置重扫」，而这批签名拿去在一堆可执行文件的内容里乱扫，
/// 假阳性没有意义 —— 一个 PE 里恰好出现 `xar!` 并不代表它是 xar 包。这张表
/// **只在固定位置匹配**（偏移 0 或下面写明的那个偏移）。
///
/// 置信度沿用上面的规矩：偏移 0 且 4 字节以上给 `high`，其余 `medium`。
const List<_Signature> _kSignaturesExtra = [
  // ---- 偏移 0 ----
  // WIM：`MSWIM\0\0\0`
  _Signature(0, [0x4D, 0x53, 0x57, 0x49, 0x4D, 0, 0, 0], SniffFormat.wim,
      SniffConfidence.high),
  // RPM：`ED AB EE DB`
  _Signature(0, [0xED, 0xAB, 0xEE, 0xDB], SniffFormat.rpm, SniffConfidence.high),
  // AR（含 .deb / .a）：`!<arch>\n`
  _Signature(0, [0x21, 0x3C, 0x61, 0x72, 0x63, 0x68, 0x3E, 0x0A], SniffFormat.ar,
      SniffConfidence.high),
  // XAR：`xar!\0`
  _Signature(0, [0x78, 0x61, 0x72, 0x21, 0x00], SniffFormat.xar,
      SniffConfidence.high),
  // CHM：`ITSF` + 版本 3 + 头长 0x60；LIT 电子书：`ITOLITLS` + …
  _Signature(0, [0x49, 0x54, 0x53, 0x46, 3, 0, 0, 0, 0x60, 0, 0, 0],
      SniffFormat.chm, SniffConfidence.high),
  _Signature(
      0,
      [0x49, 0x54, 0x4F, 0x4C, 0x49, 0x54, 0x4C, 0x53, 1, 0, 0, 0, 0x28, 0, 0, 0],
      SniffFormat.chm,
      SniffConfidence.high),
  // SquashFS：四种字节序 / 魔数写法（7-Zip 的 `kMultiSignature` 那四条）
  _Signature(0, [0x68, 0x73, 0x71, 0x73], SniffFormat.squashfs, SniffConfidence.high), // hsqs
  _Signature(0, [0x73, 0x71, 0x73, 0x68], SniffFormat.squashfs, SniffConfidence.high), // sqsh
  _Signature(0, [0x73, 0x68, 0x73, 0x71], SniffFormat.squashfs, SniffConfidence.high), // shsq
  _Signature(0, [0x71, 0x73, 0x68, 0x73], SniffFormat.squashfs, SniffConfidence.high), // qshs
  // QCOW：`QFI\xFB\0\0\0`（后面跟版本号）
  _Signature(0, [0x51, 0x46, 0x49, 0xFB, 0, 0, 0], SniffFormat.qcow,
      SniffConfidence.high),
  // VMDK 稀疏扩展：`KDMV`
  _Signature(0, [0x4B, 0x44, 0x4D, 0x56], SniffFormat.vmdk, SniffConfidence.high),
  // VHD（动态盘的文件头副本）：`conectix\0\0`。固定盘的页脚只在文件尾，不收。
  _Signature(0, [0x63, 0x6F, 0x6E, 0x65, 0x63, 0x74, 0x69, 0x78, 0, 0],
      SniffFormat.vhd, SniffConfidence.high),
  // VHDX：`vhdxfile`
  _Signature(0, [0x76, 0x68, 0x64, 0x78, 0x66, 0x69, 0x6C, 0x65],
      SniffFormat.vhdx, SniffConfidence.high),
  // Android sparse 映像：`3A FF 26 ED 01 00`
  _Signature(0, [0x3A, 0xFF, 0x26, 0xED, 1, 0], SniffFormat.sparse,
      SniffConfidence.high),
  // PPMd：`8F AF AC 84`
  _Signature(0, [0x8F, 0xAF, 0xAC, 0x84], SniffFormat.ppmd, SniffConfidence.high),
  // MS 压缩（`EXPAND` 用的 SZDD）：`SZDD 88 F0 27 33 41`
  _Signature(0, [0x53, 0x5A, 0x44, 0x44, 0x88, 0xF0, 0x27, 0x33, 0x41],
      SniffFormat.mslz, SniffConfidence.high),
  // Unix compress（.Z）：`1F 9D`。2 字节，所以只给 medium。
  _Signature(0, [0x1F, 0x9D], SniffFormat.z, SniffConfidence.medium),
  // ---- 固定偏移 ----
  // CramFS：偏移 16 起是 `Compressed ROMFS`
  _Signature(
      16,
      [0x43, 0x6F, 0x6D, 0x70, 0x72, 0x65, 0x73, 0x73, 0x65, 0x64, 0x20, 0x52,
       0x4F, 0x4D, 0x46, 0x53],
      SniffFormat.cramfs,
      SniffConfidence.medium),
  // VDI：偏移 0x40 起是 `7F 10 DA BE`
  _Signature(0x40, [0x7F, 0x10, 0xDA, 0xBE], SniffFormat.vdi, SniffConfidence.medium),
  // NTFS 卷引导扇区：偏移 3 起是 `NTFS    \0`
  _Signature(3, [0x4E, 0x54, 0x46, 0x53, 0x20, 0x20, 0x20, 0x20, 0],
      SniffFormat.ntfs, SniffConfidence.medium),
];

// ---------------------------------------------------------------------------
// 深处的签名（要多读一次磁盘）
// ---------------------------------------------------------------------------

/// ISO 9660 / UDF 的卷描述符区从 0x8000 起（前 32 KiB 是留给引导代码的系统区），
/// 超出了 [kSniffHeadBytes] 的窗口。
const int kVolumeDescriptorOffset = 0x8000;

/// DMG 的签名不在文件头，而在**文件尾**那块 512 字节的 `koly` 页脚的开头。
const int kDmgTrailerBytes = 512;

/// 看 0x8000 处的 [kVolumeDescriptorOffset] 起 8 字节是不是 ISO / UDF 卷描述符。
///
/// - ISO 9660：`01 'CD001'`（类型字节 1 = 主卷描述符）
/// - UDF：`00 'BEA01' 01 00`（纯 UDF 光盘，没有 ISO 桥）
///
/// 带光盘引导的混合 ISO 的头 512 字节是 MBR 引导码，**头窗口认不出来**，所以
/// 才必须走这条深探测。纯函数，不碰磁盘，可单测。
SniffFormat? matchVolumeDescriptor(Uint8List b) {
  if (b.length >= 6 &&
      b[0] == 1 &&
      b[1] == 0x43 &&
      b[2] == 0x44 &&
      b[3] == 0x30 &&
      b[4] == 0x30 &&
      b[5] == 0x31) {
    return SniffFormat.iso;
  }
  if (b.length >= 8 &&
      b[0] == 0 &&
      b[1] == 0x42 &&
      b[2] == 0x45 &&
      b[3] == 0x41 &&
      b[4] == 0x30 &&
      b[5] == 0x31 &&
      b[6] == 1 &&
      b[7] == 0) {
    return SniffFormat.udf;
  }
  return null;
}

/// 看文件尾 512 字节页脚的开头 12 字节是不是 DMG 的 `koly` 签名。纯函数。
///
/// 签名取 7-Zip 的完整 12 字节（`koly` + 版本 4 + 头长 0x200），不只是 4 个
/// 字母：文件尾的任意 4 个字节碰巧是 `koly` 并不罕见。
SniffFormat? matchDmgTrailer(Uint8List b) {
  const sig = [0x6B, 0x6F, 0x6C, 0x79, 0, 0, 0, 4, 0, 0, 2, 0];
  if (b.length < sig.length) return null;
  for (var i = 0; i < sig.length; i++) {
    if (b[i] != sig[i]) return null;
  }
  return SniffFormat.dmg;
}

/// 表里所有签名的首字节，用于重扫时的快速否决。
final Uint8List _kFirstByteMask = () {
  final m = Uint8List(256);
  for (final s in _kSignaturesAtZero) {
    m[s.pattern.first] = 1;
  }
  return m;
}();

// ---------------------------------------------------------------------------
// 后缀
// ---------------------------------------------------------------------------

/// 取小写后缀，不含点。无后缀（含 `.gitignore` 这种纯 dotfile）时返回空串。
String extensionOf(String path) {
  final slash = path.lastIndexOf(RegExp(r'[/\\]'));
  final base = slash >= 0 ? path.substring(slash + 1) : path;
  final dot = base.lastIndexOf('.');
  if (dot <= 0 || dot == base.length - 1) return '';
  return base.substring(dot + 1).toLowerCase();
}

/// 后缀 → 容器类型。命中则**一律不作为压缩包处理**，且跳过整个嗅探。
///
/// 语义是「这些后缀不递归解压」，不全是「这些后缀是 ZIP 容器」：
/// `.class`/`.dex` 根本不是 zip，列在这里只是省掉一次无谓的文件读。
///
/// 刻意**不含** `zip` / `7z` / `rar` / `cbz` / `cbr` / `gz` ——
/// 漫画包 `cbz`/`cbr` 是用户真心想解压的东西。
const Map<String, ContainerKind> kContainerExtensions = {
  // OOXML
  'docx': ContainerKind.ooxml,
  'docm': ContainerKind.ooxml,
  'dotx': ContainerKind.ooxml,
  'xlsx': ContainerKind.ooxml,
  'xlsm': ContainerKind.ooxml,
  'pptx': ContainerKind.ooxml,
  'pptm': ContainerKind.ooxml,
  // OpenDocument
  'odt': ContainerKind.odf,
  'ods': ContainerKind.odf,
  'odp': ContainerKind.odf,
  'odg': ContainerKind.odf,
  // 电子书
  'epub': ContainerKind.epub,
  // Android
  'apk': ContainerKind.apk,
  'aab': ContainerKind.aab,
  'aar': ContainerKind.jar,
  // JVM
  'jar': ContainerKind.jar,
  'war': ContainerKind.jar,
  'ear': ContainerKind.jar,
  'class': ContainerKind.other,
  'dex': ContainerKind.other,
  // 包管理器 / 扩展
  'nupkg': ContainerKind.nupkg,
  'xpi': ContainerKind.browserExt,
  'vsix': ContainerKind.browserExt,
  'crx': ContainerKind.browserExt,
  'ipa': ContainerKind.ipa,
  'kmz': ContainerKind.kmz,
  // 其余 ZIP 容器
  'whl': ContainerKind.other,
  'egg': ContainerKind.other,
  'asar': ContainerKind.other,
  'sb3': ContainerKind.other,
  'sketch': ContainerKind.other,
  'twbx': ContainerKind.other,
  'pages': ContainerKind.other,
  'numbers': ContainerKind.other,
  'key': ContainerKind.other,
};

// ---------------------------------------------------------------------------
// 纯函数：按文件头判定
// ---------------------------------------------------------------------------

/// 只根据**文件头字节**判定格式。不碰磁盘，可单测。
///
/// [head] 是文件前 [kSniffHeadBytes] 字节（文件更短时就是全部）。
/// [declaredExt] 传空会从 [fileSize] 之外的信息无从推断 —— 调用方应自行给出。
SniffResult sniffHeadBytes(
  Uint8List head, {
  String declaredExt = '',
}) {
  final m = _matchTable(head);
  if (m == null) {
    return SniffResult(
      format: SniffFormat.unknown,
      confidence: SniffConfidence.none,
      declaredExt: declaredExt,
      header: _preview(head),
    );
  }
  return SniffResult(
    format: m.format,
    confidence: m.confidence,
    declaredExt: declaredExt,
    header: _preview(head),
  );
}

/// 首字节是否为 `MZ`（DOS/Windows 可执行文件，自解压包的壳）。
bool looksLikeMz(Uint8List head) =>
    head.length >= 2 && head[0] == 0x4D && head[1] == 0x5A;

({SniffFormat format, SniffConfidence confidence})? _matchTable(Uint8List head) {
  for (final s in _kSignaturesAtZero) {
    if (_matchesAt(head, 0, s)) {
      return (format: s.format, confidence: s.confidence);
    }
  }
  for (final s in _kSignaturesOffset) {
    if (_matchesAt(head, s.offset, s)) {
      return (format: s.format, confidence: s.confidence);
    }
  }
  // 最后才轮到新收的那批。放最后是因为它们里有 2 字节的 `1F 9D` 和位于偏移
  // 3 的 `NTFS`：前面那些更强、更老的签名先说话。
  for (final s in _kSignaturesExtra) {
    if (_matchesAt(head, s.offset, s)) {
      return (format: s.format, confidence: s.confidence);
    }
  }
  return null;
}

bool _matchesAt(Uint8List buf, int offset, _Signature s) {
  final n = s.pattern.length;
  if (offset + n > buf.length) return false;
  for (var i = 0; i < n; i++) {
    if (buf[offset + i] != s.pattern[i]) return false;
  }
  return true;
}

/// 在某段缓冲区里找「任意偏移 0 签名」。返回首个命中的偏移与格式。
({int offset, SniffFormat format, SniffConfidence confidence})? _scanAnywhere(
  Uint8List buf, {
  int from = 1,
}) {
  for (var i = from; i < buf.length; i++) {
    if (_kFirstByteMask[buf[i]] == 0) continue;
    for (final s in _kSignaturesAtZero) {
      if (_matchesAt(buf, i, s)) {
        return (offset: i, format: s.format, confidence: SniffConfidence.medium);
      }
    }
  }
  return null;
}

/// 参与「向前搜」的三种格式。**不含 ZIP** —— 追加式 ZIP 由 [_findZipByTail]
/// 从尾部 EOCD 反推，在这儿再搜一遍只是白花一次 CRC。
const Set<SniffFormat> _kPrependedFormats = {
  SniffFormat.sevenZ,
  SniffFormat.rar4,
  SniffFormat.rar5,
};

/// 向前搜「追加式」压缩包的签名：7z / RAR5 / RAR4，命中后按格式校验块头。
///
/// 这是给「一张完整图片打头、压缩包整段追加在后面」那类分享包准备的 —— 它
/// 没有可见的后缀线索，签名也不在偏移 0。返回首个**校验通过**的候选。
///
/// ## 为什么校验不能省
///
/// 在一个 1 MB 窗口里裸搜 `37 7A BC AF 27 1C` 必然误报（[_findZipByTail] 的
/// 注释警告过同一件事），所以三种格式都得把签名后面的块头过一遍：
///
/// - **7z**：`CrcCalc(p + 12, 20) == Get32(p + 8)`（`7zIn.cpp` 的 `TestStartCrc`）
/// - **RAR5**：`CrcCalc(buf + 4, size - 4) == Get32(buf)`（`Rar5Handler.cpp` 的
///   `ReadHeader`），块长由 `buf + 4` 处最多 3 字节的 vint 推出来
/// - **RAR4**：`Get16(h) == CrcCalc(h + 2, headerSize - 2) & 0xFFFF` 且
///   `h[2] == 0x73`（`NBlockType::kArchiveHeader`，`RarHeader.h`）
///
/// 块头读不全（候选太靠近窗口末尾）时**放弃该候选**，不猜 —— 这是本函数唯一
/// 的固有限制：前置数据长到让块头横跨窗口边界就认不出，那种情况退回 `unknown`。
({int offset, SniffFormat format})? _scanVerifiedSignatures(Uint8List buf) {
  for (var i = 1; i < buf.length; i++) {
    if (_kFirstByteMask[buf[i]] == 0) continue;
    for (final s in _kSignaturesAtZero) {
      if (!_kPrependedFormats.contains(s.format)) continue;
      if (!_matchesAt(buf, i, s)) continue;
      if (_verifyBlockHeader(buf, i, s.format)) {
        return (offset: i, format: s.format);
      }
    }
  }
  return null;
}

/// 按格式校验签名后面的块头。[off] 是签名起点。
bool _verifyBlockHeader(Uint8List buf, int off, SniffFormat format) {
  switch (format) {
    case SniffFormat.sevenZ:
      // 32 字节：sig6 + ver2 + StartHeaderCRC4 + StartHeader20。
      if (off + 32 > buf.length) return false;
      return _crc32(buf, off + 12, off + 32) == _get32(buf, off + 8);
    case SniffFormat.rar5:
      return _verifyRar5(buf, off);
    case SniffFormat.rar4:
      return _verifyRar4(buf, off);
    default:
      return false;
  }
}

/// RAR5：marker 8 字节之后是块头 —— 4 字节 CRC32，再是块长的 vint。
bool _verifyRar5(Uint8List buf, int markerOff) {
  final h = markerOff + 8; // 块头起点
  if (h + 4 > buf.length) return false;
  // 先得读得出块长，才知道这个块有多长、CRC 要覆盖到哪。
  final head = _readVint(buf, h + 4, 3);
  if (head == null || head.value < 2) return false;

  // size 含那 4 字节 CRC 自己，与 `Rar5Handler.cpp` 的 `_bufSize` 同一个口径。
  final end = h + 4 + head.len + head.value;
  if (end > buf.length) return false;
  return _crc32(buf, h + 4, end) == _get32(buf, h);
}

/// RAR4：marker 7 字节之后是 13 字节的主头（加密时 14 字节，多一个版本字节）。
bool _verifyRar4(Uint8List buf, int markerOff) {
  final h = markerOff + 7; // 主头起点
  if (h + 13 > buf.length) return false;
  if (buf[h + 2] != 0x73) return false; // NBlockType::kArchiveHeader
  if (_crc16Low(buf, h, 13)) return true;
  // 主头整体加密时多一个字节，CRC 也跟着多覆盖一个。
  return h + 14 <= buf.length && _crc16Low(buf, h, 14);
}

/// RAR4 的头校验：前 2 字节存的是 CRC32 的低 16 位。
bool _crc16Low(Uint8List buf, int h, int headerSize) =>
    _get16(buf, h) == (_crc32(buf, h + 2, h + headerSize) & 0xFFFF);

// ---------------------------------------------------------------------------
// 纯函数：容器标记检测
// ---------------------------------------------------------------------------

/// 从中央目录条目名里判定这是不是某个「长得像压缩包的容器格式」。
///
/// 只看名字、不减压，所以对炸弹免疫。需要同时满足两个以上特征才判定，
/// 避免把「恰好有个 `manifest.json` 的普通 zip」误判成浏览器扩展。
ContainerKind detectContainer(List<ZipEntry> entries) {
  var hasContentTypes = false;
  var hasWord = false;
  var hasXl = false;
  var hasPpt = false;

  var hasAndroidManifest = false;
  var hasClassesDex = false;
  var hasBundleConfig = false;
  var hasBaseManifest = false;

  var hasManifestMf = false;
  var hasClass = false;

  var hasNuspec = false;
  var hasPayload = false;
  var hasAppInfoPlist = false;
  var hasDocKml = false;

  var hasMetaInfManifest = false;
  var hasContentXml = false;
  var hasContainerXml = false;

  var hasRootManifestJson = false;
  var hasLocales = false;

  var firstIsMimetype = false;

  for (var i = 0; i < entries.length; i++) {
    // 先把分隔符统一成 `/` 再匹配。
    //
    // ZIP 规范（APPNOTE 4.4.17.1）只说路径分隔符 **SHOULD** 用正斜杠，
    // 不是 MUST。实测 Windows 自带的 `Compress-Archive` 写出来的条目名就是
    // `word\document.xml`（字节层确认：反斜杠出现 2 次、正斜杠 0 次），
    // 而下面每一条判断都是分隔符敏感的 —— `word/` 前缀、`META-INF/MANIFEST.MF`
    // 全等、`.app/Info.plist` 后缀。不统一的话，一个由 Windows 工具产出的
    // 合法 OOXML 容器会被漏判成普通压缩包，然后被当压缩包解开。
    final n = entries[i].name.replaceAll(r'\', '/');
    if (i == 0 && n == 'mimetype') firstIsMimetype = true;

    // 刻意用**独立 if 而非 else-if 链**：一条路径可以同时满足多个条件。
    // （`Payload/Demo.app/Info.plist` 既以 `Payload/` 开头，又以
    //  `.app/Info.plist` 结尾，两者都必须置位。）条目数有上限，这点比较开销
    // 远小于漏判的代价。
    if (n == '[Content_Types].xml') hasContentTypes = true;
    if (n.startsWith('word/')) hasWord = true;
    if (n.startsWith('xl/')) hasXl = true;
    if (n.startsWith('ppt/')) hasPpt = true;

    if (n == 'AndroidManifest.xml') hasAndroidManifest = true;
    if (n == 'classes.dex' ||
        (n.startsWith('classes') && n.endsWith('.dex'))) {
      hasClassesDex = true;
    }
    if (n == 'BundleConfig.pb') hasBundleConfig = true;
    if (n == 'base/manifest/AndroidManifest.xml') hasBaseManifest = true;

    if (n == 'META-INF/MANIFEST.MF') hasManifestMf = true;
    if (n.endsWith('.class')) hasClass = true;

    if (n.endsWith('.nuspec') && !n.contains('/')) hasNuspec = true;
    if (n.startsWith('Payload/')) hasPayload = true;
    if (n.endsWith('.app/Info.plist')) hasAppInfoPlist = true;
    if (n == 'doc.kml') hasDocKml = true;

    if (n == 'META-INF/manifest.xml') hasMetaInfManifest = true;
    if (n == 'content.xml') hasContentXml = true;
    if (n == 'META-INF/container.xml') hasContainerXml = true;

    if (n == 'manifest.json') hasRootManifestJson = true;
    if (n.startsWith('_locales/')) hasLocales = true;
  }

  // 顺序即优先级：越具体的越先判。
  // AAB 必须先于 APK（AAB 里也有 AndroidManifest.xml，但没有 classes.dex）。
  if (hasBundleConfig && hasBaseManifest) return ContainerKind.aab;
  if (hasAndroidManifest && hasClassesDex) return ContainerKind.apk;
  if (hasPayload && hasAppInfoPlist) return ContainerKind.ipa;
  if (hasContentTypes && (hasWord || hasXl || hasPpt)) return ContainerKind.ooxml;
  if (firstIsMimetype && hasContainerXml) return ContainerKind.epub;
  if (firstIsMimetype && (hasMetaInfManifest || hasContentXml)) {
    return ContainerKind.odf;
  }
  if (hasManifestMf && hasClass) return ContainerKind.jar;
  if (hasNuspec) return ContainerKind.nupkg;
  if (hasDocKml) return ContainerKind.kmz;
  // 浏览器扩展：根目录 manifest.json **且** 有 _locales/。
  // 单靠 manifest.json 太容易误伤。
  if (hasRootManifestJson && hasLocales) return ContainerKind.browserExt;

  return ContainerKind.none;
}

// ---------------------------------------------------------------------------
// 异步：读文件
// ---------------------------------------------------------------------------

/// 读文件（必要时读文件尾），给出完整嗅探结论，并在是 ZIP 时补做容器检测。
///
/// 这是扫描期唯一该调用的入口。[declaredExt] 不传就从 [path] 推。
///
/// [honorContainerSkip] 为 false 时**两道容器防线一起让位**：后缀跳过表
/// （[kContainerExtensions]）与中央目录标记检测（[detectContainer]）。这是给
/// **用户明确点名的文件**用的 —— 「我就要解这一个 `.docx`」是他的权利，我们
/// 不该拿一条为「扫一整个 Downloads 目录」设计的防线把他挡回来。
/// **目录扫描永远用默认的 true**，那条防线在那边不能动。
///
/// 注意：让位之后魔术字节照读，所以一个真身是 zip 的 `.docx` 会正常被认成
/// zip；一个真身不是压缩包的（哪怕是真 docx）仍然会以 `unknown` 被丢掉 ——
/// 让位的是「按后缀/条目名提前判死」，不是「不看内容就收下」。
///
/// IO 异常（权限不足、文件消失）会向上抛 `FileSystemException` —— 由调用方
/// 计入 `ScanSummary.unreadable`，这里不吞。
Future<SniffResult> sniffFile(
  String path, {
  String? declaredExt,
  bool honorContainerSkip = true,
  int windowBytes = kDefaultSniffWindowBytes,
}) async {
  final ext = declaredExt ?? extensionOf(path);

  // 第一级防御：后缀跳过表。连文件都不开。
  final fast = honorContainerSkip ? kContainerExtensions[ext] : null;
  if (fast != null) {
    // 后缀在跳过表里 ⇒ 一定不是待解压的压缩包。format 是纯猜测，
    // 所以 confidence 记 none —— 调用方只会看 container / isArchive。
    return SniffResult(
      format: SniffFormat.zip,
      confidence: SniffConfidence.none,
      declaredExt: ext,
      container: fast,
    );
  }

  final file = File(path);
  final size = await file.length();
  if (size <= 0) {
    return SniffResult(
      format: SniffFormat.unknown,
      confidence: SniffConfidence.none,
      declaredExt: ext,
    );
  }

  final raf = await file.open();
  try {
    final headLen = size < kSniffHeadBytes ? size : kSniffHeadBytes;
    final head = await readFully(raf, 0, headLen);

    // 第 2 级：偏移 0 的强签名（以及 tar/lzh 的固定偏移）。
    final direct = _matchTable(head);
    if (direct != null) {
      // 必须 await：否则 finally 会在 _withContainer 还在用 raf 时就关掉文件。
      return await _withContainer(
        raf, size, direct.format, direct.confidence, ext, head,
        baseOffset: 0,
        honorContainerSkip: honorContainerSkip,
      );
    }

    // 第 3 级之一：自解压包 —— 壳是 PE，有效载荷在后面。
    if (looksLikeMz(head)) {
      final embedded = await _scanEmbedded(raf, size);
      if (embedded != null) {
        // 注意 head 是 PE 头，不是有效载荷的头；preview 就展示 PE 头，
        // 让 FormatDetectModal 的十六进制预览如实反映用户看到的文件。
        return await _withContainer(
          raf, size, embedded.format, embedded.confidence, ext, head,
          baseOffset: embedded.offset,
          honorContainerSkip: honorContainerSkip,
        );
      }
    }

    // 第 3 级之二：从文件尾反推 ZIP。
    final tail = await _findZipByTail(raf, size);
    if (tail != null) {
      return await _withContainer(
        raf, size, SniffFormat.zip, tail.confidence, ext, head,
        baseOffset: tail.baseOffset,
        honorContainerSkip: honorContainerSkip,
      );
    }

    // 第 3 级之三：ISO / UDF（卷描述符在 0x8000）与 DMG（签名在文件尾）。
    // 放这里：前面都认不出才值得多花这两次读 —— 而 ZIP 的尾部探测已经证明
    // 这个文件不是 ZIP 了，剩下的才是它们。
    final deep = await _sniffDeep(raf, size);
    if (deep != null) {
      return SniffResult(
        format: deep,
        confidence: SniffConfidence.medium,
        declaredExt: ext,
        header: _preview(head),
      );
    }

    // 第 4 级：向前搜「图片等文件后面追加的压缩包」。排在最后是因为它最贵
    // （要读前 [windowBytes] 字节），而前面几步已经把绝大多数文件分完了。
    final window = await _scanWindow(raf, size, windowBytes);
    if (window != null) {
      return SniffResult(
        format: window.format,
        confidence: window.confidence,
        declaredExt: ext,
        baseOffset: window.offset,
        header: _preview(head),
      );
    }

    return SniffResult(
      format: SniffFormat.unknown,
      confidence: SniffConfidence.none,
      declaredExt: ext,
      header: _preview(head),
    );
  } finally {
    await raf.close();
  }
}

/// 头窗口之外的两处签名：0x8000 的卷描述符（ISO / UDF），和文件尾的 `koly`（DMG）。
///
/// 两次读都很小（8 字节、12 字节），文件不够长时直接跳过，不越界。
Future<SniffFormat?> _sniffDeep(RandomAccessFile raf, int size) async {
  if (size >= kVolumeDescriptorOffset + 8) {
    final vd = await readFully(raf, kVolumeDescriptorOffset, 8);
    final f = matchVolumeDescriptor(vd);
    if (f != null) return f;
  }
  if (size >= kDmgTrailerBytes) {
    final trailer = await readFully(raf, size - kDmgTrailerBytes, 12);
    final f = matchDmgTrailer(trailer);
    if (f != null) return f;
  }
  return null;
}

/// 前 1 MiB 内重扫偏移 0 签名集合。只在文件确实是 `MZ` 时调用。
Future<({int offset, SniffFormat format, SniffConfidence confidence})?>
    _scanEmbedded(RandomAccessFile raf, int size) async {
  final len = size < kEmbeddedScanBytes ? size : kEmbeddedScanBytes;
  if (len <= kSniffHeadBytes) return null; // 文件头已经覆盖过全部内容了
  final buf = await readFully(raf, 0, len);
  if (buf.length <= kSniffHeadBytes) return null;
  return _scanAnywhere(buf);
}

/// 前 [windowBytes] 字节里向前搜 7z / RAR5 / RAR4 的签名，逐个做块头 CRC 校验。
///
/// 与 [_scanEmbedded] 是两条**不一样**的路：那条给 PE 自解压壳用（裸搜、无校验、
/// `medium`），这条给「追加在图片后面」的包用（带校验、`high`）。刻意不合并 ——
/// 既有测试钉着前者的置信度与偏移，而后者要求校验，两者的取舍正好相反。
Future<({int offset, SniffFormat format, SniffConfidence confidence})?>
    _scanWindow(RandomAccessFile raf, int size, int windowBytes) async {
  final len = size < windowBytes ? size : windowBytes;
  if (len <= kSniffHeadBytes) return null; // 文件头已经覆盖过全部内容了
  final buf = await readFully(raf, 0, len);
  if (buf.length <= kSniffHeadBytes) return null;
  final hit = _scanVerifiedSignatures(buf);
  if (hit == null) return null;
  // CRC 验过的，比 medium 强 —— 这正是它与 [_scanEmbedded] 的区别。
  return (
    offset: hit.offset,
    format: hit.format,
    confidence: SniffConfidence.high,
  );
}

/// 从文件尾反向找 ZIP EOCD，并**校验**推出来的起点确实是中央目录。
///
/// 不校验的话，随机二进制里偶然出现 `PK\x05\x06` 会被当成 ZIP，
/// 结果就是弹一堆「无法解压」的错 —— 比老实说「不认识」更糟。
Future<({int baseOffset, SniffConfidence confidence})?> _findZipByTail(
  RandomAccessFile raf,
  int size,
) async {
  if (size < kTailProbeBytes) return null;

  var tailLen = size < kTailProbeBytes ? size : kTailProbeBytes;
  var tail = await readFully(raf, size - tailLen, tailLen);
  var eocd = findEndOfCentralDirectory(
    tail,
    tailFileOffset: size - tailLen,
    fileSize: size,
  );

  if (eocd == null && tailLen < kTailScanBytes) {
    tailLen = size < kTailScanBytes ? size : kTailScanBytes;
    tail = await readFully(raf, size - tailLen, tailLen);
    eocd = findEndOfCentralDirectory(
      tail,
      tailFileOffset: size - tailLen,
      fileSize: size,
    );
  }
  if (eocd == null) return null;

  final start = eocd.archiveStartOffset;
  if (start < 0 || start > size) return null;

  // 校验 1：归档起点必须落在文件内，且推出来的起点不能是负数。
  if (start + eocd.centralDirectoryOffset + 4 > size) {
    if (eocd.centralDirectorySize > 0) return null;
  }

  // 校验 2：中央目录处必须是中央目录签名 `PK\x01\x02`。
  if (eocd.centralDirectorySize > 0) {
    final sig = await readFully(raf, start + eocd.centralDirectoryOffset, 4);
    if (sig.length < 4 || _u32le(sig, 0) != kCentralHeaderSignature) return null;
  } else if (eocd.declaredEntryCount > 0) {
    // 声称有条目却没有中央目录，自相矛盾。
    return null;
  }

  // 有前置数据时是 SFX/追加头场景，证据链更长，但仍然只是「尾部证据」，
  // 所以最高只给 medium。
  return (baseOffset: start, confidence: SniffConfidence.medium);
}

/// 是 ZIP 就补一次容器标记检测。检测失败不影响嗅探结论。
///
/// [honorContainerSkip] 为 false 时**跳过标记检测**（`container` 保持 none），
/// 但照样把条目列出来读一遍 —— 「要不要密码」是从同一份条目录白捡的，与
/// 「这算不算容器」是两件事，让位只让后者。见 [sniffFile] 的说明。
Future<SniffResult> _withContainer(
  RandomAccessFile raf,
  int size,
  SniffFormat format,
  SniffConfidence confidence,
  String ext,
  Uint8List head, {
  required int baseOffset,
  required bool honorContainerSkip,
}) async {
  if (format != SniffFormat.zip) {
    return SniffResult(
      format: format,
      confidence: confidence,
      declaredExt: ext,
      baseOffset: baseOffset,
      header: _preview(head),
    );
  }

  var container = ContainerKind.none;
  bool? encrypted;
  try {
    final listing = await readZipListing(raf, fileSize: size);
    if (listing != null) {
      if (honorContainerSkip) {
        container = detectContainer(listing.entries);
      }

      // 「要不要密码」也在这里白捡：通用位留在每条中央目录条目上，bit 0 就是
      // 「这条加密了」，而 `readZipListing` **已经在读**那份条目录了 ——
      // 同一个字节流上多看一眼的事，不必为此把引擎开起来（7z / RAR 才要，
      // 见 `EncryptedProbe`）。ZIP 是用户最常撞上的加密格式，这条最勤的那条
      // 路不能是贵的。
      //
      // 任一条加密就算加密：混装的包（部分条目加密）同样得先问密码才解得完。
      encrypted = listing.entries.any((e) => e.isEncrypted);
    }
  } catch (_) {
    // 中央目录坏了 / 被加密 / IO 抖动：退化成「不知道是不是容器」，
    // 交给解压期去发现真正的问题。不要在这里把整个扫描打断。
    // `encrypted` 也就留在 null 上 —— 「不知道」是诚实的答案，别写成 false。
  }

  return SniffResult(
    format: format,
    confidence: confidence,
    declaredExt: ext,
    baseOffset: baseOffset,
    container: container,
    header: _preview(head),
    encrypted: encrypted,
  );
}

int _u32le(Uint8List b, int o) =>
    b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);

Uint8List _preview(Uint8List head) => head.length <= kHexPreviewBytes
    ? head
    : Uint8List.sublistView(head, 0, kHexPreviewBytes);

// ---------------------------------------------------------------------------
// 校验用的字节小工具
// ---------------------------------------------------------------------------

// 7-Zip 的 `CrcCalc` 就在这几个格式的块头里用着，而 `engine/` 不得 import 外部
// 包（见 `models.dart` 开头的纪律），所以表驱动手写一份。表只建一次。
Uint32List? _crcTable;
Uint32List get _kCrcTable => _crcTable ??= _buildCrcTable();

Uint32List _buildCrcTable() {
  final table = Uint32List(256);
  for (var i = 0; i < 256; i++) {
    var c = i;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
    table[i] = c;
  }
  return table;
}

/// CRC32（多项式 `0xEDB88320`）。覆盖 `[start, end)`。
///
/// 与 7-Zip 的 `CrcCalc` 同构：初值全 1、末尾取反。返回 `int`（Dart 的 int 是
/// 64 位有符号，`& 0xFFFFFFFF` 保证与 C 侧的 `UInt32` 对齐后再比较）。
int _crc32(Uint8List buf, int start, int end) {
  final table = _kCrcTable;
  var crc = 0xFFFFFFFF;
  for (var i = start; i < end; i++) {
    crc = table[(crc ^ buf[i]) & 0xFF] ^ (crc >> 8);
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

int _get32(Uint8List b, int o) =>
    (b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24)) & 0xFFFFFFFF;

int _get16(Uint8List b, int o) => b[o] | (b[o + 1] << 8);

/// RAR5 的 vint：逐字节，低 7 位是数据、最高位是续读位。
///
/// 读不出来（越界 / `maxBytes` 个字节都还带续读位）返回 null —— 对应
/// `Rar5Handler.cpp` 的 `ReadVarInt` 在那里返回 0 表示失败。
({int len, int value})? _readVint(Uint8List b, int o, int maxBytes) {
  var value = 0;
  var shift = 0;
  for (var i = 0; i < maxBytes; i++) {
    if (o + i >= b.length) return null;
    final byte = b[o + i];
    value |= (byte & 0x7F) << shift;
    if ((byte & 0x80) == 0) return (len: i + 1, value: value);
    shift += 7;
  }
  return null;
}

// ---------------------------------------------------------------------------
// 展示格式化（供 FormatDetectModal 用）
// ---------------------------------------------------------------------------

/// `50 4B 03 04 ...`，最多 [kHexPreviewBytes] 字节。
String hexPreview(List<int> bytes) => bytes
    .take(kHexPreviewBytes)
    .map((b) => b.toRadixString(16).toUpperCase().padLeft(2, '0'))
    .join(' ');

/// `0x504B0304`，取前 4 字节 —— `FormatDetectModal.fileHeader` 的格式。
String hexWord(List<int> bytes) {
  final n = bytes.length < 4 ? bytes.length : 4;
  final sb = StringBuffer('0x');
  for (var i = 0; i < n; i++) {
    sb.write(bytes[i].toRadixString(16).toUpperCase().padLeft(2, '0'));
  }
  return sb.toString();
}
