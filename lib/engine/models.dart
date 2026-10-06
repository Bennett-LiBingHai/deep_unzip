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
/// 比 `ArchiveType` 细：`ArchiveType` 是给 UI 显示用的粗分类，这里需要区分
/// RAR4/RAR5、以及各种压缩包装容器，因为它们的解压路径不同。
///
/// ## 这张表与引擎的关系
///
/// 引擎（内置的 7-Zip 核心）打开时**不限格式**，会把编进去的 handler 逐个试
/// 一遍；真正的闸门在 Dart 这边 —— 嗅探认不出的文件，扫描时根本不会送到引擎
/// （`SniffResult.isArchive` 为假，`scanner._emitPlain` 直接丢掉）。所以「app
/// 能解哪些格式」＝ **这张表里有哪些值**，不是引擎能做什么。
///
/// 收录原则：**有可靠签名的**才收。7-Zip 还编进了一批没有可靠签名的东西
/// （FAT / MBR / GPT / ext / HFS / APFS 这类裸分区，签名只有 2 字节且在文件深处；
/// Base64 / Intel HEX / 裸 LZMA 干脆没有签名；PE / ELF / Mach-O 是可执行文件），
/// 它们**刻意不收**：收了就会把目录里一大批不相干的文件当成压缩包列出来。
enum SniffFormat {
  // ---- 压缩包 / 压缩流 ----
  zip('ZIP 压缩包', 'ZIP', ArchiveType.zip),
  rar4('RAR 压缩包', 'RAR', ArchiveType.rar),
  rar5('RAR5 压缩包', 'RAR', ArchiveType.rar),
  sevenZ('7-Zip 压缩包', '7Z', ArchiveType.sevenz),
  tar('TAR 归档', 'TAR', ArchiveType.tar),
  gzip('GZIP 压缩', 'GZIP', ArchiveType.gzip),
  bzip2('BZIP2 压缩', 'BZIP2', ArchiveType.bzip2),
  xz('XZ 压缩', 'XZ', ArchiveType.xz),
  zstd('ZSTD 压缩', 'ZSTD', ArchiveType.zstd),
  cab('CAB 归档', 'CAB', ArchiveType.other),
  lzh('LHA 归档', 'LHA', ArchiveType.other),
  arj('ARJ 归档', 'ARJ', ArchiveType.other),
  cpio('CPIO 归档', 'CPIO', ArchiveType.other),
  z('Unix compress 压缩', 'Z', ArchiveType.other),
  ppmd('PPMd 压缩', 'PMD', ArchiveType.other),
  mslz('MS 压缩（SZDD）', 'SZDD', ArchiveType.other),
  // ---- 软件包 / 安装包 / 文档包 ----
  rpm('RPM 软件包', 'RPM', ArchiveType.other),
  ar('AR / DEB 归档', 'AR', ArchiveType.other),
  xar('XAR 归档', 'XAR', ArchiveType.other),
  chm('CHM / LIT 电子书', 'CHM', ArchiveType.other),
  wim('WIM 系统映像', 'WIM', ArchiveType.other),
  // ---- 光盘 / 磁盘映像 ----
  iso('ISO 光盘映像', 'ISO', ArchiveType.other),
  udf('UDF 光盘映像', 'UDF', ArchiveType.other),
  dmg('DMG 磁盘映像', 'DMG', ArchiveType.other),
  squashfs('SquashFS 映像', 'SQFS', ArchiveType.other),
  cramfs('CramFS 映像', 'CRFS', ArchiveType.other),
  qcow('QCOW 磁盘映像', 'QCOW', ArchiveType.other),
  vdi('VDI 磁盘映像', 'VDI', ArchiveType.other),
  vmdk('VMDK 磁盘映像', 'VMDK', ArchiveType.other),
  vhd('VHD 磁盘映像', 'VHD', ArchiveType.other),
  vhdx('VHDX 磁盘映像', 'VHDX', ArchiveType.other),
  sparse('Android Sparse 映像', 'SPRS', ArchiveType.other),
  ntfs('NTFS 卷映像', 'NTFS', ArchiveType.other),
  unknown('未知格式', 'UNKNOWN', ArchiveType.unknown);

  const SniffFormat(this.label, this.badge, this.archiveType);

  /// 给 `FormatDetectModal` 的 `realFormat` 参数用，例如「ZIP 压缩包」。
  final String label;

  /// 列表里那块 32px 见方的类型角标上的字，**最多 5 个字符**（9px 等宽字，再多
  /// 就溢出）。与 [archiveType] 分开是因为后者只是粗分类：二十几种「已识别但
  /// 没有专属类型」的格式都归 [ArchiveType.other]，角标却得各写各的名字。
  final String badge;

  /// 映射回 UI 层已有的 `ArchiveType`（颜色分组用）。
  ///
  /// 多对一是有意为之：rar4/rar5 在列表上都叫 RAR；认得出但没有专属分类的都
  /// 归 [ArchiveType.other]。压缩类（gzip/bzip2/xz/zstd）曾经也挤在 `tar` 上，
  /// 2026-10 拆成了各自的值。以后再加格式时，**别往已有的专属值上塞**：那是
  /// 角标显示错的根源 —— 归 `other`，再给它自己的 [badge]。
  ///
  /// 注意 `unknown` 现在**只**留给真正认不出的东西（它在列表里不会出现，只给
  /// `SniffResult.unknown` 用）；从前 cab/lzh/arj/cpio 也落在它上面，列表里会
  /// 显示一块红色的「UNKNOWN」，那是在把已识别的格式说成不认识。
  final ArchiveType archiveType;
}

/// 各类格式「正常」应有的后缀集合，用于判断后缀是否被篡改。
///
/// 故意宽松：把同族后缀都列上，避免把 `tar.gz`、`tgz` 这类正常写法误判成
/// 篡改而弹窗骚扰用户。没有列出的格式（cab/lzh/arj/cpio/mslz）不做后缀判定。
///
/// 新收的那批格式，后缀集合**抄 7-Zip 自己注册的那份**（`REGISTER_ARC_I` 的
/// 第二个字符串）：官方认的后缀都放行，才不会把合法文件误弹成「后缀被篡改」。
/// `img` 在多个格式里都出现 —— 那是各家映像工具共用的通名，不是笔误。
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
  SniffFormat.z: {'z', 'taz'},
  SniffFormat.ppmd: {'pmd'},
  SniffFormat.rpm: {'rpm', 'srpm'},
  SniffFormat.ar: {'ar', 'a', 'deb', 'udeb', 'lib'},
  SniffFormat.xar: {'xar', 'pkg', 'xip'},
  SniffFormat.chm: {
    'chm', 'chi', 'chq', 'chw', 'hxs', 'hxi', 'hxr', 'hxq', 'hxw', 'lit',
  },
  SniffFormat.wim: {'wim', 'swm', 'esd', 'ppkg'},
  SniffFormat.iso: {'iso', 'img', 'udf', 'bin'},
  SniffFormat.udf: {'iso', 'img', 'udf', 'bin'},
  SniffFormat.dmg: {'dmg'},
  SniffFormat.squashfs: {'squashfs', 'sqfs', 'sfs', 'img'},
  SniffFormat.cramfs: {'cramfs', 'img'},
  SniffFormat.qcow: {'qcow', 'qcow2', 'qcow2c'},
  SniffFormat.vdi: {'vdi'},
  SniffFormat.vmdk: {'vmdk'},
  SniffFormat.vhd: {'vhd'},
  SniffFormat.vhdx: {'vhdx', 'avhdx'},
  SniffFormat.sparse: {'simg', 'img'},
  SniffFormat.ntfs: {'ntfs', 'img'},
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
    this.encrypted,
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

  /// 这个包要不要密码才解得开。**三态，别压成 `bool`**：
  ///
  /// - `true`  —— 确认要（条目加密位、或归档头整体加密到根本打不开）
  /// - `false` —— 确认不要
  /// - `null`  —— **没查出来**：没嗅探到能判断的地方，或这会儿问不到引擎
  ///
  /// 「不知道」必须能得到表达：压成 `false` 就等于替引擎撒了谎，用户会在
  /// 首页看到「需密码 0」而那个包其实是锁着的 —— 真机上就是这么被发现的。
  /// 调用方（`scanner.dart` 的 `_flagsFor`）也只在**确认**为真时才打标，
  /// `null` 不打。
  ///
  /// 谁来填：ZIP 由 `_withContainer` 从中央目录的通用位里白捡（已经在读了），
  /// 7z / RAR 要真开一次归档，由扫描方注入的探针负责（见 `EncryptedProbe`）。
  final bool? encrypted;

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
    this.pruneDirs = kDefaultPruneDirs,
  });

  /// 认出的伪后缀包要不要**拦下来问一句**（对应设置项 `fakeExtDetect`，
  /// 设置页上叫「伪后缀时暂停」）。
  ///
  /// 名字里的 "detect" 是历史遗留：魔术字节**永远**会读 —— 扫描就是靠它把
  /// `fake.pdf` 认成压缩包的，关掉这一项它照样进列表、照样按 ZIP 解。这一项
  /// 只决定要不要打 [`ArchiveFlag.fakeExtension`]，而那正是解压期弹格式弹窗
  /// 的触发条件（见 `app_state.dart` 的 `askFormat`）。所以 false = 不打扰，
  /// 不是不认。
  final bool detectFakeExtension;

  // 这里曾有一项 `mergeSplitVolumes`（设置页上叫「分片自动合并」），2026-10
  // 删掉了。分卷**总是**合并：关掉它不是换一种做法，是把 `.zip.002` 当普通
  // 文件走一遍嗅探、认不出格式就地静默丢掉（`_emitPlain` 的
  // `if (!sniff.isArchive) return;`，三个计数一个都不记），最后只留一行
  // 残缺的 `.001` 给用户去解。删它的完整账见 `persist.dart` 的
  // `kDefaultToggles`。

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
