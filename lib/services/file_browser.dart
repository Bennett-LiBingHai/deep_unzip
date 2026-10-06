/// 文件浏览器的**纯逻辑层**：把「列一个目录」与「补元数据」从页面里拆出来。
///
/// ## 为什么单独一层
///
/// 这一层不 import `package:flutter`，所以能纯单测；而 `dart:io` 在
/// **Windows 宿主机**上也能真跑 —— 测试直接造一个临时目录树就行。这是「自建浏览器」
/// 相对「加一个 Kotlin 原生方法」的主要好处：整条路都能在本机验。
///
/// ## 分两步：先是名字，再是大小
///
/// `Directory.list()` 走 `readdir`，一次就把整个目录的名字拿回来（多数文件系统
/// 在 dirent 里连类型都带了，所以目录/文件的分拣也是免费的）。**但大小和修改
/// 时间不在里面** —— 那两个只有 `stat()` 有，而且是**逐条**的。
///
/// 在这个 app 的目标场景（`/sdcard`，FUSE）上逐条 stat 是慢的那一头（memory
/// `fuse-small-files-are-slow`：6~17ms/个），500 条就是好几秒。文件系统没有
/// 「批量 stat」这个 API —— 原生的文件管理器之所以快，是因为 Downloads/Pictures
/// 那类根底下它查的是 **MediaStore 索引**（系统在后台维护的一份 SQLite），不是
/// 真去碰文件系统。那个索引我们够不着，所以只能选**在什么时候等**：
///
/// [listDirectory] 立刻返回名字（列表马上画出来），[enrichEntries] 在后台逐条补
/// 大小/时间、补好一批回调一批。用户看见的是「列表先出来，大小一行行跳出来」，
/// 而不是盯着一片空白等几秒。
library;

import 'dart:io';

import '../engine/split.dart' show compareNatural;

/// 一个目录项。
class DirEntry {
  /// 绝对路径。
  final String path;

  /// 最后一段（显示用的名字）。
  final String name;

  /// 是不是目录。符号链接按 [listDirectory] 的说明**一律算文件**。
  final bool isDir;

  const DirEntry({
    required this.path,
    required this.name,
    required this.isDir,
  });
}

/// 一次列举的结果。
class DirListing {
  /// 子目录，已按自然序排好。
  final List<DirEntry> dirs;

  /// 文件，已按自然序排好。
  final List<DirEntry> files;

  /// 整个目录**读不了**时的说明（权限不足 / 目录被删 / 根本不是目录）。
  /// 非 null 时 [dirs] 与 [files] 都是空的。
  final String? error;

  const DirListing({
    this.dirs = const [],
    this.files = const [],
    this.error,
  });

  bool get isEmpty => dirs.isEmpty && files.isEmpty && error == null;
}

/// 底层列举器。默认是 `dart:io`；测试注入一个假的来造「这个目录读不了」
/// —— 在 Windows 宿主机上没法真的造出一个无权限目录。
typedef DirLister = Stream<FileSystemEntity> Function(String path);

Stream<FileSystemEntity> _ioLister(String path) =>
    Directory(path).list(followLinks: false);

/// 列一个目录：目录在前、文件在后，各自按 [compareNatural] 排
/// —— 与扫描器同一个排序，用户在浏览器里看到的顺序和扫描结果里的顺序一致。
///
/// ## 符号链接一律当文件
///
/// `followLinks: false` 下符号链接是 `Link` 而不是 `Directory`，于是它进不了
/// 子目录列表、点它也不会下钻。这是刻意的，与扫描器同一条规矩（见
/// `scanner.dart` 里那段）。`/sdcard` 本身就是符号链接 —— 拿它当根的话，
/// 「上一级」会绕回自己。
Future<DirListing> listDirectory(String path, {DirLister? lister}) async {
  final list = lister ?? _ioLister;

  final dirs = <DirEntry>[];
  final files = <DirEntry>[];
  try {
    await for (final e in list(path)) {
      final name = _baseName(e.path);
      final entry = DirEntry(path: e.path, name: name, isDir: e is Directory);
      (entry.isDir ? dirs : files).add(entry);
    }
  } on FileSystemException catch (e) {
    // Android 11+ 的 `/Android/data`、`/Android/obb` 在部分 OEM 上即使持有
    // `MANAGE_EXTERNAL_STORAGE` 也照样拒绝 —— 那是**常态**，不是异常情况，
    // 所以这里给一句人话，而不是把异常抛给页面去崩。
    return DirListing(error: _reason(e));
  }

  dirs.sort((a, b) => compareNatural(a.name, b.name));
  files.sort((a, b) => compareNatural(a.name, b.name));
  return DirListing(dirs: dirs, files: files);
}

/// 把 `FileSystemException` 翻成一句能给用户看的话。
///
/// 不把 `e.toString()` 直接摆出去：那串东西带着 `errno` 与本机路径，
/// 对用户没有任何意义。
String _reason(FileSystemException e) {
  final os = e.osError;
  if (os != null && (os.errorCode == 13 || os.errorCode == 1)) {
    return '没有权限读取这个目录';
  }
  return '这个目录读不了（可能已被删除或移走）';
}

String _baseName(String path) {
  final i = path.lastIndexOf(RegExp(r'[/\\]'));
  return i < 0 ? path : path.substring(i + 1);
}

// ---------------------------------------------------------------------------
// 元数据（大小 / 修改时间）
// ---------------------------------------------------------------------------

/// 一个条目的元数据。拿不到的一律是 null。
///
/// **补不上不是错误。** 文件可能在这两次调用之间被删了、被移走了，也可能权限
/// 不足 —— 列目录本身已经成功了，不该因为某一条补不出大小就把整页判成失败。
/// 两个字段都 null 就是「补过了，没有」，界面那一栏留空。
class FileMeta {
  /// 字节数。目录恒为 null —— 见 [enrichEntries] 的说明。
  final int? sizeBytes;

  /// 最后修改时间。
  final DateTime? modified;

  const FileMeta({this.sizeBytes, this.modified});
}

/// 单条 `stat` 的结果。
///
/// **刻意不直接用 `FileStat`**：它是 `interface class`、只有私有构造函数，测试里
/// 根本造不出来 —— 而「这条 stat 报错」和「这条已经不存在了」恰恰是宿主机上没
/// 法稳定复现、最需要注入的两档。
class StatResult {
  /// `stat` 到底看没看到这个东西。
  ///
  /// **这一位必须显式带着**：`FileStat.stat` 对不存在的路径**不抛异常**，而是
  /// 回一个 `notFound`。不区分的话，一个刚被删掉的文件会顶着 `0 B` 和
  /// `1970-01-01` 显示出来 —— 那比什么都不显示更坏。
  final bool found;

  final int sizeBytes;
  final DateTime? modified;

  const StatResult({required this.found, this.sizeBytes = 0, this.modified});
}

/// 底层 stat。默认走 `dart:io`；测试注入一个假的。
typedef StatLister = Future<StatResult> Function(String path);

Future<StatResult> _ioStat(String path) async {
  final s = await FileStat.stat(path);
  return StatResult(
    found: s.type != FileSystemEntityType.notFound,
    sizeBytes: s.size,
    modified: s.modified,
  );
}

/// 并发档位。
///
/// 与扫描器的 `kSniffConcurrency` 取同一个值：同一类活儿（在一个 FUSE 目录上
/// 大批逐条 stat），同一个机器上量出来的合理值。**再调高不会更快** —— 瓶颈在
/// FUSE 守护进程那边的往返，不在我们的并发度，开太大只会让它排队更长。
const int kStatConcurrency = 8;

/// 攒够这么多条才回调一次。
///
/// 逐条回调等于每个文件一次 `setState`，一个两千条的目录足以把主 isolate 淹掉，
/// 而用户看到的只是数字在跳。攒批之后回调次数降到 1/[kMetaBatchSize]。
const int kMetaBatchSize = 16;

/// 给 [entries] 补 size/mtime，**补好一批就回调一批**。
///
/// ## 顺序
///
/// 回调顺序**不保证**与 [entries] 的顺序一致 —— 并发 stat 谁先回来谁先进批。
/// 调用方按 path 收（`Map<String, FileMeta>`），不要按下标对。
///
/// ## 目录不给 size
///
/// `stat` 对目录返回的是**目录项本身**占的字节，不是内容之和。摆出去用户只会
/// 读成「这个文件夹才 4 KB，里面怎么有 3 GB」—— 所以目录的 [FileMeta.sizeBytes]
/// 恒为 null，界面那一栏留空。修改时间照给。
///
/// ## 取消
///
/// [isCancelled] 每补一条前问一次。页面在用户导航去别的目录、或离开这个页面时
/// 把它置真 —— 否则一个慢目录会在用户走了之后继续 stat 几百个文件，还把结果
/// 往一个已经销毁的 State 上写。
Future<void> enrichEntries(
  List<DirEntry> entries, {
  required void Function(Map<String, FileMeta> batch) onBatch,
  int concurrency = kStatConcurrency,
  StatLister? stat,
  bool Function()? isCancelled,
}) async {
  if (entries.isEmpty) return;
  final doStat = stat ?? _ioStat;

  final pending = <String, FileMeta>{};
  var next = 0;

  void flush() {
    if (pending.isEmpty) return;
    final batch = Map<String, FileMeta>.from(pending);
    pending.clear();
    onBatch(batch);
  }

  Future<void> worker() async {
    while (true) {
      if (isCancelled?.call() ?? false) return;
      // 同 isolate 内没有真正的并发：取号与自增之间没有 await，不会撞号。
      final i = next;
      if (i >= entries.length) return;
      next = i + 1;

      final e = entries[i];
      var meta = const FileMeta();
      try {
        final s = await doStat(e.path);
        // `found` 为假 = 这东西在我们问之前已经没了（见 [StatResult]）。留空，
        // 不要拿 `0 B` / `1970` 去填。
        if (s.found) {
          meta = FileMeta(
            // 目录的「大小」是目录项本身占的字节，不是里面内容之和，摆出去
            // 只会让人以为文件夹是空的（见函数说明）。
            sizeBytes: e.isDir ? null : s.sizeBytes,
            modified: s.modified,
          );
        }
      } on FileSystemException {
        // 权限不足之类。读不到就是没有（见 [FileMeta]）。**不吞别的异常** ——
        // 这里唯一预期中的失败就是文件系统那一类。
      }
      if (isCancelled?.call() ?? false) return;

      pending[e.path] = meta;
      // 从 `pending[...] =` 到这里没有 await，所以这一批是自洽的。
      if (pending.length >= kMetaBatchSize) flush();
    }
  }

  final n = concurrency < entries.length ? concurrency : entries.length;
  await Future.wait([for (var i = 0; i < n; i++) worker()]);
  flush();
}
