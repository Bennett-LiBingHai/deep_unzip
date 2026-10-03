/// 目录扫描：递归遍历 → 分卷分组 → 嗅探 → `ScanItem` 列表。
///
/// 只做 IO 与判定，**不做时间数学**（进度百分比/ETA 在控制器里算），也不碰
/// `package:flutter`。扫完一遍的产出是 [ScanSummary]，与 UI 的 `ArchiveFile`
/// 列表在下标上一一对应。
///
/// ## 顺序契约
///
/// 输出顺序是**按名字自然排序的深度优先前序遍历**（文件与子目录混排），
/// 和文件管理器里看到的顺序一致。排序用 [compareNatural] 而不是字典序，
/// 所以 `part2 < part10`。顺序确定意味着测试可以直接断言整个列表。
///
/// ## 一个逻辑压缩包 = 一行
///
/// 分卷家族的多个分片在 `items` 里只占一项，位置落在**入口点**在自然序中
/// 出现的地方。已被收编的非入口分片不再单独出现。首卷嗅探失败时整组被否决，
/// 分片退回普通文件各自处理（需求 5 的组合场景：`备份.rar.001` 可能压根不是
/// 压缩包，只是碰巧叫这个名字）。
library;

import 'dart:async';
import 'dart:io';

import '../models/archive_file.dart';
import 'models.dart';
import 'sniff.dart';
import 'split.dart';

// ---------------------------------------------------------------------------
// 常量
// ---------------------------------------------------------------------------

/// 我们自己产出的输出目录名，扫描时必须跳过。
///
/// 否则「扫描 → 解压 → 再扫描」会自噬：解出来的内容又被当成待解压的输入。
/// journal 里记录过的输出目录由调用方通过 `skipDirs` 传进来（那些路径是
/// 带 `_1`/`_2` 后缀的重名结果，光靠名字认不出来）。
const Set<String> kSelfOutputDirs = {'_extracted'};

/// 单次扫描的文件数硬顶。超了就停下并告警 —— 静默截断会被读成「扫完了」。
const int kMaxScannedFiles = 200000;

/// 文件系统递归深度硬顶。正常目录树远达不到，纯粹防意外。
const int kMaxScanDepth = 64;

/// 默认嗅探并发度。嗅探只读 512 字节，主要成本是 open/close 的系统调用，
/// 并行 8 个足够吃掉延迟又不会在低端机上把 IO 队列压垮。
const int kSniffConcurrency = 8;

/// 每处理这么多文件报一次进度（目录结束时也一定报一次）。
///
/// 报得太密会让 isolate 消息成为瓶颈，太疏则大目录里进度条会长时间不动。
const int kTickEveryFiles = 200;

// ---------------------------------------------------------------------------
// 进度与入口
// ---------------------------------------------------------------------------

/// 一次扫描进度。**原始计数**：时间数学（EWMA 速度、ETA）在控制器里做，
/// 那里才有可测的时钟。
class ScanTick {
  const ScanTick({
    required this.dirs,
    required this.files,
    required this.found,
    required this.current,
  });

  /// 已遍历的目录数（不含根目录本身）。
  final int dirs;

  /// 已查看的文件数（分卷的每一片都算一个）。
  final int files;

  /// 已确认为压缩包的条目数。
  final int found;

  /// 当前正在处理的路径，给进度面板做副标题。
  final String current;

  @override
  String toString() => 'ScanTick(dirs=$dirs, files=$files, found=$found)';
}

typedef ScanTickCallback = void Function(ScanTick tick);

/// 扫描一个目录（递归），返回可解压的条目。
///
/// [skipDirs] 是绝对路径集合，命中的目录整个跳过（journal 记录的历史输出目录）。
/// [baseDepth] 用于嵌套场景：解压过程中发现的新压缩包要以 `depth + 1` 入队。
/// [isCancelled] 每次进入目录与每条目之间检查，返回 true 即停止扫描（返回
/// 已扫到的部分并附一条告警）。
Future<ScanSummary> scanDirectory(
  String rootPath, {
  ScanOptions options = const ScanOptions(),
  Set<String> skipDirs = const {},
  int baseDepth = 0,
  ScanTickCallback? onTick,
  bool Function()? isCancelled,
}) async {
  final root = Directory(rootPath);
  if (!await root.exists()) {
    return ScanSummary(items: const [], warnings: ['目录不存在：$rootPath']);
  }

  final st = _ScanState(onTick: onTick, isCancelled: isCancelled);
  // 根目录本身不参与剪枝 —— 用户明确选了它，哪怕它叫 node_modules 也要扫。
  await _visitDir(st, root, '', 0, options, skipDirs, baseDepth);

  final warnings = [...st.warnings];
  if (st.cancelled) {
    warnings.add('扫描已取消，结果可能不完整');
  }
  if (st.truncated) {
    warnings.add('文件数超过 $kMaxScannedFiles 上限，已停止扫描，结果不完整');
  }
  if (st.unreadable > 0) {
    warnings.add('${st.unreadable} 个文件无法读取（权限不足或已被删除）');
  }

  return ScanSummary(
    items: st.items,
    containerSkipped: st.containerSkipped,
    unreadable: st.unreadable,
    warnings: warnings,
  );
}

/// 单独扫描一批已知文件（不遍历目录）。
///
/// 解压过程中发现的新压缩包走这条路：它们已经在刚解出来的目录里，而且
/// 那次解压自己产出的东西不该被重新递归（会自噬）。同样按目录分组做分卷识别。
Future<ScanSummary> scanFileList(
  List<String> paths, {
  ScanOptions options = const ScanOptions(),
  int baseDepth = 1,
  ScanTickCallback? onTick,
  bool Function()? isCancelled,
}) async {
  final st = _ScanState(onTick: onTick, isCancelled: isCancelled);

  // 按目录分组：分卷只在同一目录内成组。
  final byDir = <String, List<String>>{};
  for (final p in paths) {
    byDir.putIfAbsent(_dirName(p), () => []).add(p);
  }
  for (final dir in byDir.keys) {
    final group = byDir[dir]!..sort(compareNatural);
    await _processFiles(st, group, options, baseDepth);
    if (st.stopped) break;
  }

  final warnings = [...st.warnings];
  if (st.cancelled) warnings.add('扫描已取消，结果可能不完整');
  if (st.truncated) {
    warnings.add('文件数超过 $kMaxScannedFiles 上限，已停止扫描，结果不完整');
  }
  if (st.unreadable > 0) {
    warnings.add('${st.unreadable} 个文件无法读取（权限不足或已被删除）');
  }
  return ScanSummary(
    items: st.items,
    containerSkipped: st.containerSkipped,
    unreadable: st.unreadable,
    warnings: warnings,
  );
}

// ---------------------------------------------------------------------------
// 遍历
// ---------------------------------------------------------------------------

class _ScanState {
  _ScanState({this.onTick, this.isCancelled});

  final ScanTickCallback? onTick;
  final bool Function()? isCancelled;

  final List<ScanItem> items = [];
  final List<String> warnings = [];
  int containerSkipped = 0;
  int unreadable = 0;
  int filesSeen = 0;
  int dirsSeen = 0;
  bool truncated = false;
  bool cancelled = false;

  bool get stopped => truncated || cancelled;

  /// 询问外部是否要取消。只在第一次为真时翻转，之后就不用再调回调了。
  void syncCancel() {
    if (cancelled) return;
    if (isCancelled?.call() ?? false) cancelled = true;
  }

  void tick(String current) {
    onTick?.call(ScanTick(
      dirs: dirsSeen,
      files: filesSeen,
      found: items.length,
      current: current,
    ));
  }
}

Future<void> _visitDir(
  _ScanState st,
  Directory dir,
  String rel,
  int depth,
  ScanOptions options,
  Set<String> skipDirs,
  int baseDepth,
) async {
  st.syncCancel();
  if (st.stopped) return;
  if (depth > kMaxScanDepth) {
    st.warnings.add('目录层级超过 $kMaxScanDepth，已跳过：${dir.path}');
    return;
  }

  List<FileSystemEntity> entries;
  try {
    entries = await dir.list(followLinks: false).toList();
  } on FileSystemException catch (e) {
    st.warnings.add('无法读取目录 ${dir.path}：${_ioMessage(e)}');
    return;
  }

  entries.sort((a, b) => compareNatural(_baseName(a.path), _baseName(b.path)));

  // 只认真正的文件。`followLinks: false` 下符号链接是 `Link` 而不是 `File`，
  // 于是链接被整体忽略 —— 这是刻意的：跟随链接既可能绕进系统目录，
  // 也可能构成环。需求里没有任何一条依赖跟随链接。
  final files = <String>[];
  for (final e in entries) {
    if (e is File) files.add(e.path);
  }

  // 同一目录下的文件一起处理：分卷只在同目录内成组。产出顺序仍是自然序。
  //
  // 层级必须写 `baseDepth + depth`，两个都要。`baseDepth` 在整趟扫描里是个
  // 常数（新鲜扫描为 0，嵌套发现为 1），目录的相对层级全在 `depth` 里；而
  // `depth` 此前只喂给了上面那条上限守卫，于是每一行都成了「深度 0」。
  if (files.isNotEmpty) {
    await _processFiles(st, files, options, baseDepth + depth);
  }

  // 再递归子目录 —— 「文件在前、子目录在后」保证同一目录的行连在一起，
  // 便于对照源目录树。
  for (final e in entries) {
    if (st.stopped) return;
    if (e is! Directory) continue;

    // 相对路径必须按**子目录自己**算：`Android/data` 这种两段模式
    // 只有拿到 `Android/data` 才认得出来。
    final childRel = rel.isEmpty ? _baseName(e.path) : '$rel/${_baseName(e.path)}';
    if (_shouldSkipDir(e.path, childRel, options.pruneDirs, skipDirs)) continue;

    st.dirsSeen++;
    await _visitDir(st, e, childRel, depth + 1, options, skipDirs, baseDepth);
  }
}

/// 处理同一个目录下的一批文件：取尺寸 → 分卷分组 → 嗅探 → 产出条目。
///
/// [files] 必须已经按自然序排好 —— 输出顺序就是它的顺序。
Future<void> _processFiles(
  _ScanState st,
  List<String> files,
  ScanOptions options,
  int baseDepth,
) async {
  st.syncCancel();
  if (files.isEmpty || st.stopped) return;

  // 上限只在这里拦：这是唯一知道「看了多少文件」的地方。
  final budget = kMaxScannedFiles - st.filesSeen;
  if (budget <= 0) {
    st.truncated = true;
    return;
  }
  final work = files.length > budget ? files.sublist(0, budget) : files;
  if (work.length < files.length) st.truncated = true;
  st.filesSeen += work.length;

  // ---- 1. 取尺寸 ----
  // 分卷「非末卷等长」检查与列表的 size 列都要用；`File.length` 顺便当作
  // 可读性探测。读不到的记 -1，下面按 0 参与分卷检查（0 = 未知，跳过检查）。
  final sizes = <String, int>{};
  await _forEachBounded(work, kSniffConcurrency, (path) async {
    if (st.stopped) return;
    try {
      sizes[path] = await File(path).length();
    } on FileSystemException {
      sizes[path] = -1;
    }
  });
  if (st.stopped) return;

  // ---- 2. 分卷分组 ----
  final splitScan = options.mergeSplitVolumes
      ? groupSplitVolumes([
          for (final p in work)
            (path: p, size: (sizes[p] ?? -1) < 0 ? 0 : sizes[p]!),
        ])
      : const SplitScan.empty();
  // 带上「分卷识别」前缀：这些告警是从文件名推的，可能只是名字碰巧长得像
  // 分卷（同名的两个 `backup.2026`/`backup.2027`）。前缀让用户明白这是
  // 猜测失败而不是真的坏了，且这些文件已经按普通文件处理过了。
  for (final w in splitScan.warnings) {
    st.warnings.add('分卷识别：$w');
  }

  // ---- 3. 嗅探 ----
  // 只嗅探「一定会用到的」：家族的入口点 + 没被任何家族收编的文件。
  // 被收编的非入口分片不嗅 —— 一个 100 卷的分卷包没必要读 100 次文件头。
  final sniffed = <String, SniffResult>{};
  final need = <String>[];
  for (final fam in splitScan.families) {
    need.add(fam.entryPath);
  }
  for (final p in work) {
    if (!splitScan.consumed.contains(p)) need.add(p);
  }
  await _sniffInto(st, need, sniffed);

  // ---- 4. 家族校验 ----
  // 首卷看不出是压缩包 ⇒ 整组否决，分片退回普通文件。必须在产出阶段之前
  // 定案：否则 `.z01`（排在 `.zip` 之前）会被当成「已收编」而漏掉。
  final families = <SplitFamily>[];
  final rejected = <String>[];
  for (final fam in splitScan.families) {
    final s = sniffed[fam.entryPath] ?? SniffResult.unknown;
    if (firstVolumeLooksValid(s)) {
      families.add(fam);
    } else {
      for (final p in fam.parts) {
        if (!sniffed.containsKey(p)) rejected.add(p);
      }
      st.warnings.add('${_baseName(fam.entryPath)}：分片首卷不是压缩包，已按普通文件处理');
    }
  }
  if (rejected.isNotEmpty) await _sniffInto(st, rejected, sniffed);

  final familyByEntry = {for (final f in families) f.entryPath: f};
  final consumed = {for (final f in families) ...f.parts};

  // ---- 5. 按自然序产出 ----
  var sinceTick = 0;
  for (final path in work) {
    if (st.stopped) return;

    final fam = familyByEntry[path];
    if (fam != null) {
      _emitFamily(st, fam, sniffed[path] ?? SniffResult.unknown, sizes, options, baseDepth);
    } else if (!consumed.contains(path)) {
      _emitPlain(st, path, sniffed[path] ?? SniffResult.unknown, sizes[path] ?? -1, options, baseDepth);
    }
    // 被收编的非入口分片：什么都不做，它已经在那一个条目里了。

    // 用「本批处理了几个」计数，不能用 st.filesSeen —— 那是整批预先加上的，
    // 在大目录里会让每个文件都命中取模而报一次。
    if (++sinceTick % kTickEveryFiles == 0) st.tick(path);
  }
  st.tick(work.last);
}

/// 嗅探一批路径，结果写进 [out]。IO 异常不吞掉整次扫描，记进 unreadable。
Future<void> _sniffInto(
  _ScanState st,
  List<String> paths,
  Map<String, SniffResult> out,
) async {
  if (paths.isEmpty) return;

  final todo = <String>[
    for (final p in paths)
      if (!out.containsKey(p)) p,
  ]..sort(compareNatural);

  await _forEachBounded(todo, kSniffConcurrency, (path) async {
    if (st.stopped) return;
    try {
      out[path] = await sniffFile(path, declaredExt: _declaredExtFor(path));
    } on FileSystemException {
      // 权限不足 / 文件在扫描途中被删除。`PathNotFoundException` 也是
      // `FileSystemException` 的子类，一并被这条接住。
      st.unreadable++;
      out[path] = SniffResult.unknown;
    }
  });
}

// ---------------------------------------------------------------------------
// 产出
// ---------------------------------------------------------------------------

void _emitPlain(
  _ScanState st,
  String path,
  SniffResult sniff,
  int size,
  ScanOptions options,
  int depth,
) {
  if (sniff.container != ContainerKind.none) {
    st.containerSkipped++;
    return;
  }
  if (!sniff.isArchive) return;

  st.items.add(ScanItem(
    entryPath: path,
    parts: [path],
    sniff: sniff,
    sizeBytes: size < 0 ? 0 : size,
    flags: _flagsFor(sniff, options, isSplit: false),
    depth: depth,
    // 注：`encrypted` 标记这里给不出来 —— 判断 ZIP 的加密位要读中央目录，
    // 判断 RAR/7z 的加密头要真的打开。留给 P1 拿到后端句柄时补。
  ));
}

void _emitFamily(
  _ScanState st,
  SplitFamily fam,
  SniffResult sniff,
  Map<String, int> sizes,
  ScanOptions options,
  int depth,
) {
  var total = 0;
  for (final p in fam.parts) {
    final s = sizes[p] ?? -1;
    if (s > 0) total += s;
  }

  // 家族自己的告警（非末卷不等长之类）必须冒到汇总里 —— 挂在
  // `ScanItem.split.warnings` 上只有能打开模型的人看得到，用户看不到。
  for (final w in fam.warnings) {
    st.warnings.add('分卷识别：$w');
  }

  st.items.add(ScanItem(
    entryPath: fam.entryPath,
    parts: fam.parts,
    sniff: sniff,
    sizeBytes: total,
    flags: _flagsFor(sniff, options, isSplit: true),
    depth: depth,
    split: fam,
  ));
}

Set<ArchiveFlag> _flagsFor(SniffResult sniff, ScanOptions options, {required bool isSplit}) {
  final flags = <ArchiveFlag>{};
  if (isSplit) flags.add(ArchiveFlag.split);
  if (options.detectFakeExtension && sniff.isExtensionSpoofed) {
    flags.add(ArchiveFlag.fakeExtension);
  }
  return flags;
}

/// 「声明后缀」：末尾的数字段是**分卷序号**，不是后缀。
///
/// 不剥掉的话 `b.zip.001` 的声明后缀会算成 `001`，而它显然不在
/// `kFormatExtensions[zip]` 里，于是**每一个分卷包**都会被判成伪后缀而误报。
///
/// 这条规则对分卷家族入口、孤立的分片、以及 `photo.2026` 这类只是名字里带
/// 数字的文件一律适用 —— 它说的是「名字里最靠后的那个数字段不代表格式」，
/// 与是否合并分卷无关。
String _declaredExtFor(String path) {
  final base = _baseName(path);
  final m = _reNumericSuffix.firstMatch(base);
  if (m == null) return extensionOf(path);
  return extensionOf(base.substring(0, m.start));
}

final RegExp _reNumericSuffix = RegExp(r'\.\d{2,}$');

// ---------------------------------------------------------------------------
// 剪枝
// ---------------------------------------------------------------------------

/// 目录是否该跳过。
///
/// [pruneDirs] 里既有单段名字（`node_modules`），也有两段的相对路径
/// （`Android/data`）—— 后者在一个 `Downloads` 根下是 `<root>/Android/data`，
/// 光比 basename 认不出来，所以按相对路径的**后缀**匹配。
bool shouldPruneDir(String relPath, String baseName, Set<String> pruneDirs) {
  final lowBase = baseName.toLowerCase();
  final lowRel = _normalizeSlashes(relPath).toLowerCase();
  for (final p in pruneDirs) {
    final pattern = _normalizeSlashes(p).toLowerCase();
    if (pattern.isEmpty) continue;
    if (pattern.contains('/')) {
      if (lowRel == pattern || lowRel.endsWith('/$pattern') || lowRel.startsWith('$pattern/')) {
        return true;
      }
    } else if (lowBase == pattern) {
      return true;
    }
  }
  return false;
}

bool _shouldSkipDir(String absPath, String rel, Set<String> pruneDirs, Set<String> skipDirs) {
  if (skipDirs.contains(absPath)) return true;
  final base = _baseName(absPath);
  if (kSelfOutputDirs.contains(base.toLowerCase())) return true;
  return shouldPruneDir(rel, base, pruneDirs);
}

// ---------------------------------------------------------------------------
// 小工具
// ---------------------------------------------------------------------------

/// 有界并发地跑一批任务。[fn] 必须自己吞掉异常，否则会打断其余 worker。
Future<void> _forEachBounded<T>(
  List<T> items,
  int limit,
  Future<void> Function(T item) fn,
) async {
  if (items.isEmpty) return;
  var next = 0;
  Future<void> worker() async {
    while (true) {
      // 同 isolate 内没有真正的并发：取号与自增之间没有 await，不会撞号。
      final i = next;
      if (i >= items.length) return;
      next = i + 1;
      await fn(items[i]);
    }
  }

  final n = limit < items.length ? limit : items.length;
  await Future.wait([for (var i = 0; i < n; i++) worker()]);
}

String _baseName(String path) {
  final i = path.lastIndexOf(RegExp(r'[/\\]'));
  return i >= 0 ? path.substring(i + 1) : path;
}

String _dirName(String path) {
  final i = path.lastIndexOf(RegExp(r'[/\\]'));
  return i > 0 ? path.substring(0, i) : path;
}

String _normalizeSlashes(String s) => s.replaceAll(r'\', '/');

String _ioMessage(FileSystemException e) => e.osError?.message ?? e.message;
