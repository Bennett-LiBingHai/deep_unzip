/// 文件类型嗅探：只看文件头（和在必要时看文件尾）来判定**真实**格式。
///
/// 这是需求 5 的前半段 —— 后缀可以随便改，但字节改不了。
///
/// ## 三级判定
///
/// 1. **后缀跳过表**（[kContainerExtensions]）：命中就连文件都不开。一次
///    Downloads 扫描里几百个 `.docx`/`.apk` 能省掉几百次 open/read 系统调用。
/// 2. **偏移 0 的强签名**（[_kSignaturesAtZero]）：绝大多数文件在这里就定了。
/// 3. **兜底**：`MZ` 自解压文件在前 1 MiB 内重扫签名；其余文件从文件尾反向
///    找 ZIP EOCD 并反推前置数据长度。两级窗口（先 1 KiB 后 128 KiB）是为了
///    别让「一个都不认识的目录」付出 128 KiB × N 的读放大。
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
const int kEmbeddedScanBytes = 1024 * 1024;

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
/// IO 异常（权限不足、文件消失）会向上抛 `FileSystemException` —— 由调用方
/// 计入 `ScanSummary.unreadable`，这里不吞。
Future<SniffResult> sniffFile(String path, {String? declaredExt}) async {
  final ext = declaredExt ?? extensionOf(path);

  // 第一级防御：后缀跳过表。连文件都不开。
  final fast = kContainerExtensions[ext];
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
        );
      }
    }

    // 第 3 级之二：从文件尾反推 ZIP。
    final tail = await _findZipByTail(raf, size);
    if (tail != null) {
      return await _withContainer(
        raf, size, SniffFormat.zip, tail.confidence, ext, head,
        baseOffset: tail.baseOffset,
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

/// 前 1 MiB 内重扫偏移 0 签名集合。只在文件确实是 `MZ` 时调用。
Future<({int offset, SniffFormat format, SniffConfidence confidence})?>
    _scanEmbedded(RandomAccessFile raf, int size) async {
  final len = size < kEmbeddedScanBytes ? size : kEmbeddedScanBytes;
  if (len <= kSniffHeadBytes) return null; // 文件头已经覆盖过全部内容了
  final buf = await readFully(raf, 0, len);
  if (buf.length <= kSniffHeadBytes) return null;
  return _scanAnywhere(buf);
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
Future<SniffResult> _withContainer(
  RandomAccessFile raf,
  int size,
  SniffFormat format,
  SniffConfidence confidence,
  String ext,
  Uint8List head, {
  required int baseOffset,
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
  try {
    final listing = await readZipListing(raf, fileSize: size);
    if (listing != null) container = detectContainer(listing.entries);
  } catch (_) {
    // 中央目录坏了 / 被加密 / IO 抖动：退化成「不知道是不是容器」，
    // 交给解压期去发现真正的问题。不要在这里把整个扫描打断。
  }

  return SniffResult(
    format: format,
    confidence: confidence,
    declaredExt: ext,
    baseOffset: baseOffset,
    container: container,
    header: _preview(head),
  );
}

int _u32le(Uint8List b, int o) =>
    b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);

Uint8List _preview(Uint8List head) => head.length <= kHexPreviewBytes
    ? head
    : Uint8List.sublistView(head, 0, kHexPreviewBytes);

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
