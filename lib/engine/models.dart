/// 引擎内部数据模型。
///
/// 本文件（以及 `engine/` 下除 `backends/native_backend.dart` 外的所有文件）
/// 只依赖 `dart:*`，**不得 import `package:flutter`** —— 整个引擎要跑在
/// isolate 里，也要能在 `flutter_test` 里无设备单测。
///
/// 这里刻意不修改 `lib/models/` 下已有的四个显示模型：
/// `ArchiveFile`（size 是预格式化字符串、没有路径）、`LogEntry`（time 是
/// 「今天 14:32」）、`PasswordEntry`、`Extractor`。UI 直接渲染它们，任何
/// 字段改动都会牵动 4 个页面 + 4 个弹窗。真实路径、分卷清单、嗅探缓存
/// 一律走 `ScanItem`，与 `ArchiveFile` 在下标上一一对应。
library;

import 'dart:typed_data';

import '../models/archive_file.dart';

// ---------------------------------------------------------------------------
// 格式
// ---------------------------------------------------------------------------

/// 由文件头（魔术字节）判定出的**真实**格式。
///
/// 比 `ArchiveType` 细：`ArchiveType` 只有 5 个值且是给 UI 显示用的，这里
/// 需要区分 RAR4/RAR5、以及各种压缩包装容器，因为它们的解压路径不同。
enum SniffFormat {
  zip('ZIP 压缩包', ArchiveType.zip),
  rar4('RAR 压缩包', ArchiveType.rar),
  rar5('RAR5 压缩包', ArchiveType.rar),
  sevenZ('7-Zip 压缩包', ArchiveType.sevenz),
  tar('TAR 归档', ArchiveType.tar),
  gzip('GZIP 压缩', ArchiveType.tar),
  bzip2('BZIP2 压缩', ArchiveType.tar),
  xz('XZ 压缩', ArchiveType.tar),
  zstd('ZSTD 压缩', ArchiveType.tar),
  cab('CAB 归档', ArchiveType.unknown),
  lzh('LHA 归档', ArchiveType.unknown),
  arj('ARJ 归档', ArchiveType.unknown),
  cpio('CPIO 归档', ArchiveType.unknown),
  unknown('未知格式', ArchiveType.unknown);

  const SniffFormat(this.label, this.archiveType);

  /// 给 `FormatDetectModal` 的 `realFormat` 参数用，例如「ZIP 压缩包」。
  final String label;

  /// 映射回 UI 层已有的 `ArchiveType`（`typeLabel` 会取 name 的大写）。
  final ArchiveType archiveType;
}

/// 各类格式「正常」应有的后缀集合，用于判断后缀是否被篡改。
///
/// 故意宽松：把同族后缀都列上，避免把 `tar.gz`、`tgz` 这类正常写法误判成
/// 篡改而弹窗骚扰用户。没有列出的格式（cab/lzh/...）不做后缀判定。
const Map<SniffFormat, Set<String>> kFormatExtensions = {
  SniffFormat.zip: {'zip', 'zipx', 'cbz', 'jar', 'apk'},
  SniffFormat.rar4: {'rar', 'cbr'},
  SniffFormat.rar5: {'rar', 'cbr'},
  SniffFormat.sevenZ: {'7z', 'cb7'},
  SniffFormat.tar: {'tar'},
  SniffFormat.gzip: {'gz', 'tgz'},
  SniffFormat.bzip2: {'bz2', 'tbz', 'tbz2'},
  SniffFormat.xz: {'xz', 'txz'},
  SniffFormat.zstd: {'zst', 'tzst'},
};

/// 嗅探置信度。只有 `medium` 及以上才允许入队解压。
enum SniffConfidence {
  /// 4 字节及以上强签名，位于偏移 0。
  high,

  /// 2 字节签名，或签名位于非 0 偏移（tar 的 ustar、SFX 内嵌数据）。
  medium,

  /// 只有弱线索（如纯文本启发式），不足以断言。
  low,

  /// 没有匹配任何签名。
  none,
}

/// 基于 ZIP 的**容器格式**。
///
/// 这些文件技术上都是 ZIP，但把它们当压缩包递归解压，会让一次针对
/// `Download` 目录的扫描炸开成几千个 `.docx`/`.apk` 条目。命中这些特征
/// 就跳过，并在扫描结束时提示「已忽略 N 个容器格式文件」。
enum ContainerKind {
  ooxml('Office 文档'),
  odf('OpenDocument 文档'),
  epub('EPUB 电子书'),
  apk('Android 安装包'),
  aab('Android App Bundle'),
  jar('Java 归档'),
  nupkg('NuGet 包'),
  browserExt('浏览器扩展'),
  ipa('iOS 应用包'),
  kmz('KML 压缩包'),

  /// 同样是 ZIP 容器、同样应当跳过，但没有专属类别
  /// （`.whl` / `.sb3` / `.sketch` / `.twbx` / `.pages` / `.asar` …）。
  /// 单独分一类是为了不在 UI 上把它们误标成「NuGet 包」。
  other('容器格式'),
  none('');

  const ContainerKind(this.label);

  final String label;
}

/// 一次嗅探的完整结果，缓存在 [ScanItem] 上，解压期不重复解析。
class SniffResult {
  const SniffResult({
    required this.format,
    required this.confidence,
    this.declaredExt = '',
    this.baseOffset = 0,
    this.container = ContainerKind.none,
    this.header = const [],
  });

  /// 供「什么都没读出来」的情况使用。
  static const SniffResult unknown = SniffResult(
    format: SniffFormat.unknown,
    confidence: SniffConfidence.none,
  );

  final SniffFormat format;
  final SniffConfidence confidence;

  /// 文件声明的后缀：小写、不含点，无后缀时为空串。
  final String declaredExt;

  /// 真实数据起始偏移。> 0 表示前面有前置数据（自解压 SFX、被追加了文件头
  /// 的压缩包等），解压时要跳过这么多字节。
  final int baseOffset;

  /// 非 [ContainerKind.none] 表示这是容器格式，不应作为压缩包递归解压。
  final ContainerKind container;

  /// 文件头前若干字节，供 `FormatDetectModal` 的 `hexPreview` 使用。
  final List<int> header;

  /// 是否可以作为一个压缩包去解压。
  bool get isArchive =>
      format != SniffFormat.unknown && container == ContainerKind.none;

  /// 后缀是否被篡改（需求 5 的弹窗触发条件之一）。
  ///
  /// 刻意保守：
  /// - 无后缀（`declaredExt` 为空）不算篡改 —— 静默按真实格式解压，不骚扰用户；
  /// - 认不出真实格式时不算篡改 —— 谈不上「篡改成了什么」；
  /// - 该格式没有维护后缀表时不做判定。
  bool get isExtensionSpoofed {
    if (declaredExt.isEmpty) return false;
    if (format == SniffFormat.unknown) return false;
    final expected = kFormatExtensions[format];
    if (expected == null) return false;
    return !expected.contains(declaredExt);
  }
}

// ---------------------------------------------------------------------------
// 分卷
// ---------------------------------------------------------------------------

/// 分卷家族的种类，决定「怎么把这组文件喂给解码器」。
enum SplitKind {
  /// `x.zip.001` / `x.7z.001` / `x.001` —— 裸字节切分，可直接虚拟拼接。
  rawSplit,

  /// `x.z01`…`x.zNN` + `x.zip` —— Info-ZIP spanning。
  /// 顺序是 zNN 在前、`.zip` 在**最后**，各卷自带局部中央目录，
  /// 因此**不是**简单的字节拼接。
  infoZipSpanned,

  /// `x.rar` + `x.r00` + `x.r01`… —— RAR3 旧式卷。
  rarVolumes,

  /// `x.part1.rar` / `x.part01.rar`… —— RAR5 新式卷。
  rar5Volumes,
}

/// 一组属于同一个逻辑压缩包的分卷文件。
///
/// 在 UI 层面它只占**一行**（与 mock 里 `backup_2026.part01.rar` 一致），
/// 全部分卷清单存在这里。
class SplitFamily {
  const SplitFamily({
    required this.kind,
    required this.entryPath,
    required this.parts,
    this.warnings = const [],
  });

  final SplitKind kind;

  /// 用户可见的入口点：列表里显示的那一行、双击时要处理的那个文件。
  final String entryPath;

  /// 按正确顺序排好的全部卷（**含**入口点）。
  final List<String> parts;

  /// 非致命问题（缺号、尺寸不均等），进日志 tags。
  final List<String> warnings;

  int get partCount => parts.length;
}

// ---------------------------------------------------------------------------
// 解压
// ---------------------------------------------------------------------------

/// 一次解压进度的原始计数。
///
/// 刻意只有「字节 + 当前条目名」三个字段，**不含**速度/ETA/百分比 ——
/// 那些是 [ProgressMeter] 的活，在主 isolate 算（见 progress_meter.dart 的说明）。
/// worker 只负责如实上报，不上报对时间的解释。
class ExtractTick {
  const ExtractTick({
    required this.doneBytes,
    required this.totalBytes,
    required this.current,
  });

  /// 已写出的**未压缩**字节数。7-Zip 报的是这个。
  final int doneBytes;

  /// 本次解压的未压缩总量。0 表示未知。
  ///
  /// 对**本任务**而言这个分母是固定的（7-Zip 在 SetTotal 时一次给全），
  /// 与递归解压的「全局进度」分母会增长不同 —— 后者由上层聚合多个
  /// ExtractTick 得到，见 ScanProgress 的说明。
  final int totalBytes;

  /// 当前条目名（UTF-8 已解码）。空串表示 7-Zip 还没进到具体条目。
  final String current;

  @override
  String toString() => 'ExtractTick($doneBytes/$totalBytes, "$current")';
}

/// 一次解压的最终结果。
class ExtractOutcome {
  const ExtractOutcome({
    required this.outDir,
    required this.entryCount,
    required this.unpackedBytes,
    required this.elapsed,
    this.nested = const [],
  });

  /// 实际落盘的目标目录（重名时可能被加了 `_1` 后缀，以这个为准）。
  final String outDir;

  /// 归档里的条目数（含目录），由 `duz_list` 得到。
  final int entryCount;

  /// 全部非目录条目的原始大小之和。
  final int unpackedBytes;

  final Duration elapsed;

  /// 刚解出来的内容里**又发现的**压缩包（需求 1 的「嵌套压缩包继续解压」）。
  ///
  /// 只在调用方要求时扫描（[CmdExtract.recursive]），否则恒为空 —— 扫描
  /// 要读目录、要读每个文件的头部，不是免费的。它们的 `depth` 已经由
  /// 扫描时的 `baseDepth` 抬到「父任务 + 1」，但**能不能入队由上层决定**：
  /// 这里只负责如实报告「里面有什么」，不自作主张往下解。
  ///
  /// 已按 [ScanItem] 的既有不变量排好序（文件在前、子目录在后、自然序）。
  final List<ScanItem> nested;

  /// 有没有发现嵌套包。UI 上「递归」这一行的计数用它。
  bool get hasNested => nested.isNotEmpty;

  ExtractOutcome withNested(List<ScanItem> items) => ExtractOutcome(
        outDir: outDir,
        entryCount: entryCount,
        unpackedBytes: unpackedBytes,
        elapsed: elapsed,
        nested: items,
      );
}

// ---------------------------------------------------------------------------
// 扫描
// ---------------------------------------------------------------------------

/// 扫描参数（设置快照）。
class ScanOptions {
  const ScanOptions({
    this.detectFakeExtension = true,
    this.mergeSplitVolumes = true,
    this.pruneDirs = kDefaultPruneDirs,
  });

  /// 是否启用后缀篡改检测（对应设置项 `fakeExtDetect`）。
  final bool detectFakeExtension;

  /// 是否自动合并分卷（对应设置项 `splitMerge`）。
  final bool mergeSplitVolumes;

  /// 遍历时直接剪枝的目录名。避免走进回收站、系统目录、依赖缓存。
  final Set<String> pruneDirs;
}

/// 默认剪枝的目录名（不区分大小写比较）。
const Set<String> kDefaultPruneDirs = {
  r'$RECYCLE.BIN',
  'System Volume Information',
  'node_modules',
  '.git',
  'Android/data',
  'Android/obb',
  '.thumbnails',
};

/// 扫描结果的一条，与 UI 的 `ArchiveFile` 一一对应（等长、同序）。
///
/// 不变量在 `AppState._applyScan` 一处建立：`items[i]` 对应 `archives[i]`。
class ScanItem {
  const ScanItem({
    required this.entryPath,
    required this.parts,
    required this.sniff,
    required this.sizeBytes,
    required this.flags,
    required this.depth,
    this.split,
  });

  /// 真实文件路径。单文件时等于 [parts] 的唯一元素。
  final String entryPath;

  /// 全部分卷的绝对路径，按正确顺序排列；单文件时为 `[entryPath]`。
  final List<String> parts;

  /// 嗅探结果（已缓存，解压期不重复读文件头）。
  final SniffResult sniff;

  /// 全部卷的字节数之和（列表里显示的 size 由它格式化而来）。
  final int sizeBytes;

  /// 给 UI 渲染角标用：加密 / 分片 / 伪后缀 / 嵌套。
  final Set<ArchiveFlag> flags;

  /// 递归层级。顶层扫描得到的都是 0，解压过程中发现的嵌套包依次 +1。
  final int depth;

  /// 非 null 表示这是一个多卷压缩包的入口点。
  final SplitFamily? split;

  /// 文件名（含后缀），列表里显示用。
  String get fileName => entryPath.split(RegExp(r'[/\\]')).last;

  bool get isSplit => split != null;
}

/// 一次扫描的完整产出。
class ScanSummary {
  const ScanSummary({
    required this.items,
    this.containerSkipped = 0,
    this.unreadable = 0,
    this.warnings = const [],
  });

  /// 可以作为压缩包解压的条目。
  final List<ScanItem> items;

  /// 被识别为容器格式（docx/apk/…）而跳过的文件数。
  final int containerSkipped;

  /// 读取失败（权限不足 / IO 错误）的文件数。
  final int unreadable;

  /// 非致命问题汇总。
  final List<String> warnings;

  bool get isEmpty => items.isEmpty;
}

/// 读取一个文件前 N 字节的结果，嗅探器的原始输入。
class FileHead {
  const FileHead({required this.bytes, required this.fileSize});

  final Uint8List bytes;
  final int fileSize;

  int get length => bytes.length;
}
