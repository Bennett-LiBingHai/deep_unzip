import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../engine/format.dart';
import '../services/file_browser.dart';
import '../services/storage_roots.dart';
import '../theme/app_theme.dart';

/// 浏览器为什么被打开。两种用途共用同一套「列举 + 导航」内核，差别只在标题、
/// 能不能点文件、以及页头那句提醒。
enum FileBrowserMode {
  /// 选解压目标：**点文件行 = 只解那一个，按「选择此文件夹」 = 递归扫这个目录**。
  /// 一条路覆盖两种目标 —— 用户不必先想清楚自己要的是哪种，按下去之后由他
  /// 点的是什么来定（见 [Picked]）。
  pickTarget,

  /// 选一个输出根目录（「自定义输出目录」开着时）。
  pickOutputRoot,
}

/// 浏览器交回的选中结果。
///
/// **「是文件还是文件夹」由浏览器来判**，而不是让调用方拿到路径再
/// `isDirectorySync` 反推一次：用户点的是哪一行在这里本来就是已知的（点文件行
/// = 选文件，按「选择此文件夹」 = 选目录）。反推要多一次可能失败的系统调用，
/// 还会得出与用户点的那一刻不一致的答案（路径在这中间被删掉、被换成目录）。
typedef Picked = ({String path, bool isDirectory});

/// 自建的文件浏览器。
///
/// ## 为什么不用 `file_picker`
///
/// 它在 Android 上选文件时会把**整份文件复制进应用缓存**再返回缓存里的路径
/// （`android_file_picker-2.0.0` 的 `processFiles → addFile → openFileStream`）。
/// 对一个解压软件是致命的：选个 4 GB 的 ISO 会先白复制 4 GB，而且「解到压缩包
/// 旁边」会把输出写进应用缓存。目录选择走的是另一条路、返回真路径，所以从前
/// 选文件夹一直是对的 —— 但既然要自己做文件选择，两处就该是同一套东西。
///
/// 这个 app 已经持有 `MANAGE_EXTERNAL_STORAGE`，`dart:io` 能直接读写真实路径，
/// 所以自己列目录是可行的，也不必再依赖任何平台选择器。
///
/// ## 全部可测
///
/// 页面与 [listDirectory] 都是纯 Dart + `dart:io`，widget 测试能在真临时目录
/// 上驱动它整条路（建树 → 下钻 → 上一级 → 选中）。[roots] 可注入正是为此 ——
/// 真机上它是从 `/storage` 发现出来的，测试里传一个临时目录当根。
class FileBrowserScreen extends StatefulWidget {
  final FileBrowserMode mode;

  /// 可选的卷根。给了就不再自己发现 —— 测试注入一个临时目录当根。
  final List<String>? roots;

  /// 起始目录（通常是上次用过的那个）。不属于任何卷根时会被忽略。
  final String? startPath;

  /// 底层列举器，透传给 [listDirectory]。只在测试里注入 —— 用来造「这个目录
  /// 读不了」这种在宿主机上没法真造出来的情况。
  final DirLister? lister;

  /// 底层 stat，透传给 [enrichEntries]。同上，只在测试里注入 —— 用来造
  /// 「这一条补不出大小」。
  final StatLister? statLister;

  const FileBrowserScreen({
    super.key,
    required this.mode,
    this.roots,
    this.startPath,
    this.lister,
    this.statLister,
  });

  /// 打开浏览器，返回用户选中的路径；**取消返回 null**。
  ///
  /// 调用方要**先**把存储权限拿到手（见 `AppState.ensureStoragePermission`）：
  /// 这个页面自己申请不了权限，而没有权限时它列出来的每个目录都会是「读不了」。
  static Future<Picked?> show(
    BuildContext context, {
    required FileBrowserMode mode,
    List<String>? roots,
    String? startPath,
    DirLister? lister,
    StatLister? statLister,
  }) {
    return Navigator.of(context).push<Picked>(MaterialPageRoute(
      builder: (_) => FileBrowserScreen(
        mode: mode,
        roots: roots,
        startPath: startPath,
        lister: lister,
        statLister: statLister,
      ),
    ));
  }

  @override
  State<FileBrowserScreen> createState() => _FileBrowserScreenState();
}

class _FileBrowserScreenState extends State<FileBrowserScreen> {
  List<String> _roots = const [];
  String _cwd = '';
  DirListing? _listing;
  bool _showHidden = true;
  bool _loading = true;

  /// 已经补回来的 size/mtime，按路径存。没补上的条目在这儿就是没有。
  ///
  /// 按 **path** 而不是下标存：补录是并发跑的，回来顺序与列表顺序无关（见
  /// [enrichEntries]）。
  final Map<String, FileMeta> _meta = {};

  /// 补录的版本号。每换一次目录就 +1，上一次的那趟补录于是在下一个检查点
  /// 自行退出（见 [_enrich] 的 `isCancelled`）。
  int _metaEpoch = 0;

  @override
  void initState() {
    super.initState();
    // **推迟到首帧之后再做**。`initState` 的同步段跑在 build 期间，而 `_boot`
    // 一上来就要 `setState`（把列举结果填进去）——在那儿调会撞上
    // 「setState() called during build」的断言。反正这一步要读磁盘，本来也不
    // 该挤在首帧里。
    WidgetsBinding.instance.addPostFrameCallback((_) => _boot());
  }

  Future<void> _boot() async {
    final roots = widget.roots ?? await discoverStorageRoots();
    if (!mounted) return;
    final start = widget.startPath;
    // 起始目录只在它确实落在某个卷根底下时才用 —— 否则会跳到一个卷外面去
    // （比如上一轮用的是 SD 卡，这一轮卡拔了）。
    final valid = start != null &&
        start.isNotEmpty &&
        roots.any((r) => start == r || start.startsWith('$r${Platform.pathSeparator}'));
    setState(() {
      _roots = roots.isEmpty ? const ['/'] : roots;
      _cwd = valid ? start : _roots.first;
    });
    await _load(_cwd);
  }

  Future<void> _load(String path) async {
    // 版本号**在这里取**，不是等列举回来再取：连续两次导航时谁先回来是不定的，
    // 按「取号顺序」作废才能保证最后那次导航说了算。
    final epoch = ++_metaEpoch;
    setState(() => _loading = true);
    final listing = await listDirectory(path, lister: widget.lister);
    // **必须查 mounted**：这个 await 可能跨过用户已经离开这个页面的一刻。
    if (!mounted) return;
    setState(() {
      _cwd = path;
      _listing = listing;
      _loading = false;
      // 换了目录，上一批元数据整批作废 —— 留着的话，新目录里同名的条目会
      // 顶着旧目录的大小显示。
      _meta.clear();
    });
    unawaited(_enrich(listing, epoch));
  }

  /// 后台把 [listing] 里各条的大小/时间补回来，补一批刷一批。
  ///
  /// 不 await：列表**现在**就该画出来（这正是分成两步的全部意义），补录在
  /// 后面慢慢跳。
  Future<void> _enrich(DirListing listing, int epoch) async {
    await enrichEntries(
      [...listing.dirs, ...listing.files],
      stat: widget.statLister,
      // 用户换目录 / 关掉这个页面之后就别再 stat 了 —— 否则一个慢目录会在
      // 人走了之后继续跑几百次系统调用，还往一个已经销毁的 State 上写。
      isCancelled: () => !mounted || epoch != _metaEpoch,
      onBatch: (batch) {
        if (!mounted || epoch != _metaEpoch) return;
        setState(() => _meta.addAll(batch));
      },
    );
  }

  /// `_cwd` 落在哪个卷根底下 —— 快捷入口按**这个**卷算，不是按第一个。
  String get _volumeRoot {
    for (final r in _roots) {
      if (_cwd == r || _cwd.startsWith('$r${Platform.pathSeparator}')) return r;
    }
    return _roots.isEmpty ? '/' : _roots.first;
  }

  bool get _atRoot => _roots.contains(_cwd);

  void _up() {
    if (_atRoot) return;
    final parent = _parentOf(_cwd);
    if (parent.isEmpty) return;
    _load(parent);
  }

  void _pickFile(String path) {
    Navigator.of(context).pop((path: path, isDirectory: false));
  }

  void _pickCurrentDir() {
    Navigator.of(context).pop((path: _cwd, isDirectory: true));
  }

  @override
  Widget build(BuildContext context) {
    final listing = _listing;
    return PopScope(
      // 退到卷根才允许真的退出这个页面。否则返回手势会一路把人甩回首页 ——
      // 而进了几层目录之后想回去一层，是这里最常用的动作。
      canPop: _atRoot,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _up();
      },
      child: Scaffold(
        backgroundColor: AppTheme.bgDeep,
        appBar: AppBar(
          backgroundColor: AppTheme.bgMid,
          elevation: 0,
          iconTheme: const IconThemeData(color: AppTheme.textSecondary),
          title: Text(
            _title,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: AppTheme.textPrimary,
            ),
          ),
          actions: [
            IconButton(
              tooltip: _showHidden ? '隐藏隐藏文件' : '显示隐藏文件',
              icon: Icon(
                _showHidden ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                size: 20,
                color: AppTheme.textDim,
              ),
              onPressed: () => setState(() => _showHidden = !_showHidden),
            ),
          ],
        ),
        body: Column(
          children: [
            _header(),
            Expanded(
              child: _loading
                  ? const Center(
                      child: SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : listing == null
                      ? const SizedBox.shrink()
                      : _list(listing),
            ),
            // 两档都要这句 —— `pickTarget` 下它是「扫这个目录」的唯一入口，
            // `pickOutputRoot` 下它就是唯一的选择方式。从前 `pickFile` 那档
            // 不显示它是因为那时选文件与选目录是两条互斥的路，现在合成一条了。
            _confirmBar(),
          ],
        ),
      ),
    );
  }

  String get _title => switch (widget.mode) {
        FileBrowserMode.pickTarget => '选择要解压的文件或文件夹',
        FileBrowserMode.pickOutputRoot => '选择输出根目录',
      };

  /// 顶部：当前路径 + 上一级 + 常用位置。
  ///
  /// 输出根那一档在下面多写一句 —— 这是原来那个独立说明弹窗的**全部内容**
  /// （它当年存在是因为系统选择器上写不了标题，自建页面自己有标题，那一页
  /// 就多余了）。用户第一次嫌烦时正好能在这儿看到出路。
  Widget _header() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: const BoxDecoration(
        color: AppTheme.glass,
        border: Border(bottom: BorderSide(color: AppTheme.glassBorder)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              GestureDetector(
                onTap: _atRoot ? null : _up,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: _atRoot
                        ? Colors.white.withValues(alpha: 0.02)
                        : AppTheme.neonCyan.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: _atRoot
                          ? Colors.white.withValues(alpha: 0.06)
                          : AppTheme.neonCyan.withValues(alpha: 0.2),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.arrow_upward,
                          size: 13,
                          color: _atRoot ? AppTheme.textDim : AppTheme.neonCyan),
                      const SizedBox(width: 5),
                      Text(
                        '上一级',
                        style: TextStyle(
                          fontSize: 12,
                          fontFamily: 'monospace',
                          color: _atRoot ? AppTheme.textDim : AppTheme.neonCyan,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 10),
              // 整条路径摆出来、可选中复制 —— 从这条里能看出自己在哪一层。
              Expanded(
                child: SelectableText(
                  _cwd,
                  maxLines: 2,
                  style: const TextStyle(
                    fontSize: 11,
                    height: 1.4,
                    color: AppTheme.textSecondary,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _shortcuts(),
          if (widget.mode == FileBrowserMode.pickOutputRoot) ...[
            const SizedBox(height: 10),
            const Text(
              '不想每次都选？到「设置 → 递归与目录」关掉「自定义输出目录」',
              style: TextStyle(
                fontSize: 10,
                height: 1.5,
                color: AppTheme.textDim,
                fontFamily: 'monospace',
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 常用位置：只在**真的存在**时才摆出来（新机器上 `Documents` 可能还没有）。
  Widget _shortcuts() {
    // 首帧里 `_boot` 还没跑完（`_cwd` 是空串、`_roots` 是空的），此时
    // `_volumeRoot` 会退回 `'/'`，拼出 `'/\\Download'` 这种非法路径 ——
    // 而 `existsSync` 对非法路径是**抛异常**，不是返回 false，于是整页 build
    // 直接炸。等 `_boot` 填好再算。
    if (_cwd.isEmpty || _roots.isEmpty) return const SizedBox.shrink();

    const names = ['Download', 'Documents', 'DCIM', 'Pictures'];
    final sep = Platform.pathSeparator;
    final chips = <Widget>[];
    for (final n in names) {
      final path = '$_volumeRoot$sep$n';
      if (!_exists(path)) continue;
      chips.add(GestureDetector(
        onTap: () => _load(path),
        child: Container(
          margin: const EdgeInsets.only(right: 8),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.04),
            borderRadius: BorderRadius.circular(5),
          ),
          child: Text(
            n,
            style: const TextStyle(
              fontSize: 11,
              fontFamily: 'monospace',
              color: AppTheme.textSecondary,
            ),
          ),
        ),
      ));
    }
    if (chips.isEmpty) return const SizedBox.shrink();
    return Wrap(spacing: 0, runSpacing: 6, children: chips);
  }

  Widget _list(DirListing listing) {
    if (listing.error != null) {
      return _notice(listing.error!);
    }
    final dirs = listing.dirs;
    final files = _showHidden
        ? listing.files
        : listing.files.where((e) => !e.name.startsWith('.')).toList();
    final shownDirs = _showHidden
        ? dirs
        : dirs.where((e) => !e.name.startsWith('.')).toList();

    if (shownDirs.isEmpty && files.isEmpty) {
      return _notice('这个目录是空的');
    }

    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: shownDirs.length + files.length,
      itemBuilder: (context, i) {
        if (i < shownDirs.length) {
          final d = shownDirs[i];
          return _row(
            icon: Icons.folder,
            color: AppTheme.neonCyan,
            entry: d,
            onTap: () => _load(d.path),
          );
        }
        final f = files[i - shownDirs.length];
        // `pickTarget` 下点文件就是选中它；选输出根那一档点文件没有意义，
        // 所以**不接点击** —— 接了却什么都不发生比不接更让人困惑。
        return _row(
          icon: Icons.insert_drive_file_outlined,
          color: AppTheme.textSecondary,
          entry: f,
          onTap: widget.mode == FileBrowserMode.pickTarget
              ? () => _pickFile(f.path)
              : null,
        );
      },
    );
  }

  Widget _row({
    required IconData icon,
    required Color color,
    required DirEntry entry,
    VoidCallback? onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: Colors.white.withValues(alpha: 0.03)),
          ),
        ),
        child: Row(
          children: [
            Icon(icon, size: 17, color: color),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                entry.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  color: onTap == null ? AppTheme.textDim : AppTheme.textPrimary,
                  height: 1.3,
                ),
              ),
            ),
            const SizedBox(width: 10),
            _metaColumn(entry, _meta[entry.path]),
          ],
        ),
      ),
    );
  }

  /// 右边那一栏：文件给大小，两者都给修改时间。
  ///
  /// **宽度写死**：元数据是一批批跳出来的，不固定的话每跳一行整行都会横向抖一下。
  /// 还没补上的时候这一栏是空的，位置也留着。
  Widget _metaColumn(DirEntry entry, FileMeta? meta) {
    // 目录不给大小（见 `enrichEntries`：那会是「目录项本身」的字节数，摆出来
    // 只会让人以为文件夹是空的）。
    final size = entry.isDir ? null : meta?.sizeBytes;
    final when = meta?.modified;

    return SizedBox(
      width: 96,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (size != null)
            Text(
              formatBytes(size),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 11,
                height: 1.3,
                color: AppTheme.textSecondary,
                fontFamily: 'monospace',
              ),
            ),
          if (when != null) ...[
            if (size != null) const SizedBox(height: 2),
            Text(
              formatLogTime(when),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 10,
                height: 1.3,
                color: AppTheme.textDim,
                fontFamily: 'monospace',
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _notice(String text) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 12,
            height: 1.6,
            color: AppTheme.textDim,
            fontFamily: 'monospace',
          ),
        ),
      ),
    );
  }

  Widget _confirmBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      decoration: const BoxDecoration(
        color: AppTheme.bgMid,
        border: Border(top: BorderSide(color: AppTheme.glassBorder)),
      ),
      child: GestureDetector(
        onTap: _pickCurrentDir,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 13),
          decoration: BoxDecoration(
            gradient: AppTheme.primaryGradient,
            borderRadius: BorderRadius.circular(12),
          ),
          alignment: Alignment.center,
          child: const Text(
            '选择此文件夹',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: AppTheme.bgDeep,
            ),
          ),
        ),
      ),
    );
  }
}

/// 路径存在吗。**非法路径也当不存在** —— `existsSync` 对非法路径是抛异常，
/// 而一个算坏了的路径不该把整页 build 带走。
bool _exists(String path) {
  try {
    return Directory(path).existsSync();
  } on FileSystemException {
    return false;
  }
}

/// 上一级目录。用 [Platform.pathSeparator] 而不是写死 `/` —— 测试跑在
/// Windows 宿主机上，写死一个在那边算出来的是垃圾。
String _parentOf(String path) {
  final sep = Platform.pathSeparator;
  final trimmed =
      path.endsWith(sep) && path.length > 1 ? path.substring(0, path.length - 1) : path;
  final i = trimmed.lastIndexOf(sep);
  if (i <= 0) return sep;
  return trimmed.substring(0, i);
}
