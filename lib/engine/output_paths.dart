/// 输出路径的推导（需求 1 的「输出目录树与源目录对称」）。
///
/// 拆成两层是刻意的：
///
/// - [deriveOutputName] 是**纯函数**：只做字符串变换，不看文件系统。
/// - [resolveOutputDir] 才碰文件系统（用注入的 [dirExists] 而不是直接
///   `Directory.existsSync`，测试里就能喂一张假表）。
///
/// 规则：`A/B/c.zip` → `A/B/c/` —— 同级兄弟，剥掉**整个**压缩后缀。
/// 天真的 `substring(0, lastIndexOf('.'))` 在这三种情况上都会错：
///
/// | 输入 | 天真做法 | 这里 |
/// |---|---|---|
/// | `c.tar.gz` | `c.tar` | `c` |
/// | `x.zip.001` | `x.zip` | `x` |
/// | `backup.part01.rar` | `backup.part01` | `backup` |
///
/// 「自定义输出目录」（2026-10）开着时位置换成用户选的根目录，名字规则不变 ——
/// 那一半由 [mirroredBaseDir] 算父目录，再作为 `baseDir` 交给
/// [resolveOutputDir]。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

/// 会被剥掉的压缩后缀（都是**单段**）。
///
/// 必须逐个比对完整的段，不能是任意后缀 —— 否则 `报告.2026.zip` 会把
/// `.2026` 也一起吃掉。
const Set<String> _archiveExtensions = {
  'zip', 'zipx', '7z', 'rar', 'tar',
  'gz', 'tgz', 'bz2', 'tbz', 'tbz2',
  'xz', 'txz', 'zst', 'tzst',
  'cab', 'lzh', 'lha', 'arj', 'cpio',
  'cbz', 'cbr', 'cb7',
};

/// `x.zip.001` 末尾那种**卷号**：`001` / `z01` / `r00`。
///
/// 只认这两种形态，**不**认任意数字 —— 见 [deriveOutputName] 里为什么
/// 「任意数字」是错的。
bool _isVolumeSegment(String seg) {
  if (seg.isEmpty) return false;
  if (_allDigits(seg)) return true;

  // `z01`（Info-ZIP 跨卷）与 `r00`（RAR3 旧式卷）都是 1 个字母 + 数字。
  if (seg.length >= 2) {
    final head = seg[0];
    if ((head == 'z' || head == 'r') && _allDigits(seg.substring(1))) {
      return true;
    }
  }
  return false;
}

/// `backup.part01.rar` 里的 `part01`。
///
/// 和卷号分开处理：卷号一定在**最末尾**，`partNN` 则夹在中间
/// （后面永远跟着真正的格式后缀），所以剥离时机不同。
bool _isPartSegment(String seg) =>
    seg.length > 4 && seg.startsWith('part') && _allDigits(seg.substring(4));

bool _allDigits(String s) {
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    if (c < 0x30 || c > 0x39) return false;
  }
  return true;
}

/// 路径一律先归一成 `/`，再用 **posix** 上下文做 dirname/join/basename。
///
/// 为什么不用 `p.dirname` 而用 `p.posix.dirname`：`package:path` 的默认
/// 上下文是**当前平台**的。本 app 只在 Android 上跑，但单测跑在 Windows
/// 宿主机上 —— 宿主的 `p.join('/sdcard', 'c')` 会给出 `/sdcard\c`。
/// 「函数行为随宿主机而变」是不能接受的：同一条路径在不同机器上算出不同
/// 结果，而它还要被写进 journal、当作下次续传的依据。
///
/// 归一化之后 posix 规则对两种输入都成立：Android 的 `/a/b.zip` 原样，
/// Windows 的 `C:\a\b.zip` → `C:/a/b.zip` → dirname 得 `C:/a`（`Directory`
/// 在 Windows 上照样认 `C:/a/b`）。于是 `tool/engine_cli.dart` 那类桌面
/// harness 也能用同一份代码。
String _toPosix(String path) => path.replaceAll('\\', '/');

/// 末尾那一段（小写）；没有可剥的段时返回 null。
///
/// `dot <= 0` 覆盖两种情况：没有点，以及**点在开头** —— `.gitignore`、
/// `.zip` 这类隐藏文件没有「扩展名」，整个名字就是它的名字。
/// 这个判据必须和 [_stripLastSegment] 完全一致，否则会出现
/// 「说能剥、真去剥却拿到 null」的 `null!` 崩溃。
String? _lastSegment(String stem) {
  final dot = stem.lastIndexOf('.');
  if (dot <= 0 || dot == stem.length - 1) return null;
  return stem.substring(dot + 1).toLowerCase();
}

/// 剥掉末尾一段；调用方须先确认 [_lastSegment] 非 null。
String _stripLastSegment(String stem) =>
    stem.substring(0, stem.lastIndexOf('.'));

/// 从一个压缩包路径推出输出目录的**名字**（不含父目录）。
///
/// 三个阶段，**顺序不能换**（每一步的判据依赖前一步的结果）：
///
/// 1. 剥末尾的卷号 —— 只有它一定在最末，所以必须先剥。`x.zip.001` → `x.zip`
/// 2. 剥压缩后缀，可连剥（`tar.gz` 是两层）。`x.zip` → `x`
/// 3. 剥 `partNN` —— 到这里它才暴露成末段。`backup.part01` → `backup`
///
/// 若把 1 和 2 反过来，`backup.2026.zip` 会在剥掉 `.zip` 之后把 `.2026`
/// 当卷号剥掉，得到 `backup` —— 而那是文件的真实名字的一部分。
///
/// 全剥空时回退到 `extracted`，**绝不返回空串**：空串会让
/// `p.join(parent, '')` 得到父目录自身，那就把内容直接解进源目录了。
///
/// [spoofedExtension] 为真表示「末尾那段后缀是假的」（需求 5）。这时它不在
/// 压缩后缀表里，阶段 2 认不出来，于是它会**原样活到输出名里**
/// —— `fake.pdf`（实为 ZIP）推出 `fake.pdf/`，跟源文件自己同名。那个路径上
/// 已经有一个文件，后端 `createSync` 建目录直接抛 `FileSystemException`，
/// 整个包解不出来。真机上就是这么失败的，所以这一档必须显式剥掉。
String deriveOutputName(String archivePath, {bool spoofedExtension = false}) {
  var stem = p.posix.basename(_toPosix(archivePath));
  if (stem.isEmpty) return 'extracted';

  // 阶段 1：末尾卷号，最多两层（`x.tar.gz.001` 只会在末位有一个）。
  for (var i = 0; i < 2; i++) {
    final seg = _lastSegment(stem);
    if (seg == null || !_isVolumeSegment(seg)) break;
    stem = _stripLastSegment(stem);
  }

  // 阶段 1.5：剥掉那段假后缀。**必须排在阶段 2 之前**：`backup.zip.exe`
  // 的正确输出名是 `backup`，先剥 `.exe` 才能让阶段 2 接着认出 `.zip`。
  // 反过来做只会得到 `backup.zip`。
  if (spoofedExtension) {
    final seg = _lastSegment(stem);
    if (seg != null) stem = _stripLastSegment(stem);
  }

  // 阶段 2：压缩后缀，最多 3 层（`a.tar.bz2` / `a.tar.gz` 是两层，
  // 留一层余量；上限是为了防 `foo.zip.zip.zip…` 把名字剥空）。
  for (var i = 0; i < 3; i++) {
    final seg = _lastSegment(stem);
    if (seg == null || !_archiveExtensions.contains(seg)) break;
    stem = _stripLastSegment(stem);
  }

  // 阶段 3：`partNN`。
  final seg = _lastSegment(stem);
  if (seg != null && _isPartSegment(seg)) {
    stem = _stripLastSegment(stem);
  }

  return stem.isEmpty ? 'extracted' : stem;
}

/// 算出最终输出目录：`<源目录>/<名字>`，重名时追加 `_1`、`_2`…
///
/// [spoofedExtension] 原样透传给 [deriveOutputName]，见那里的说明。
///
/// [baseDir] 是**父目录的改写**。不给就是「压缩包自己所在的那个目录」（默认，
/// 也是本 app 从原型期到 2026-10 一直的行为）；给了就把输出放到那个目录底下
/// —— 「自定义输出目录」那条路走的就是它，父目录由 [mirroredBaseDir] 从
/// 用户选的根目录算出来。
///
/// **名字永远从压缩包自己的名字推**，不受 [baseDir] 影响：换的只是放置位置，
/// 不是命名规则。
///
/// [isTaken] 可注入，默认查真实文件系统。注入它有两个理由：单测不必碰
/// 磁盘；以及**一次任务内**同一基名可能出现多次而目录还没建出来 ——
/// 那时调用方传的是「本次已占用的路径」，而不是磁盘状态。
String resolveOutputDir(
  String archivePath, {
  bool spoofedExtension = false,
  String? baseDir,
  bool Function(String path)? isTaken,
}) {
  final normalized = _toPosix(archivePath);
  final parent =
      baseDir == null ? p.posix.dirname(normalized) : _stripTrailingSlash(_toPosix(baseDir));
  final base = deriveOutputName(normalized, spoofedExtension: spoofedExtension);
  final taken = isTaken ?? _anythingExists;

  var candidate = p.posix.join(parent, base);
  var n = 1;
  while (taken(candidate)) {
    candidate = p.posix.join(parent, '${base}_$n');
    n++;
  }
  return candidate;
}

/// 把压缩包在**源目录下的相对位置**搬到 `outputRoot` 底下，得到它该写进哪个
/// 目录。
///
/// 「自定义输出目录」开着时，`子目录/S1.zip` 要落到 `<outputRoot>/子目录/`，
/// 顶层的 `L1.zip` 落到 `<outputRoot>/` 自己 —— 也就是在用户选的根下面**镜像
/// 源目录的结构**，而不是把一堆包的名字平铺进根目录（那样不同子目录里的同名包
/// 会互相撞，只能靠 `_1` 兜底，用户看不出谁是谁）。
///
/// `outputRoot` 尾部的 `/` 会去掉：`p.posix.join` 自己会处理，留着反而让
/// 返回值在「根 / 根的某个子目录」两种情况下长得不一致，调用方做字符串比较时
/// 会踩到。
///
/// 与 [resolveOutputDir] 一样走 posix 上下文，理由见 [_toPosix]。
String mirroredBaseDir(String sourceRoot, String archivePath, String outputRoot) {
  final root = _toPosix(outputRoot);
  final rel = p.posix.relative(_toPosix(archivePath), from: _toPosix(sourceRoot));
  final dir = p.posix.dirname(rel);
  // `dirname` 在「同目录」时给 `.`，在 `relative` 失败（路径不相干）时可能给
  // `..` 之类。两种都不该被 join 进结果 —— 退回根目录本身。
  if (dir == '.' || dir.isEmpty || dir == '..' || dir.startsWith('../')) {
    return root;
  }
  return p.posix.join(root, dir);
}

String _stripTrailingSlash(String path) {
  var out = path;
  // 只剥一个：`//` 那种（UNC/根）在 Android 上不存在，剥一个足够，
  // 而 `while` 会把 `//` 剥成空串。
  if (out.length > 1 && out.endsWith('/')) out = out.substring(0, out.length - 1);
  return out;
}

/// 这个路径上**有没有东西** —— 文件、目录、链接都算占着。
///
/// 不能只看 `Directory(path).existsSync()`。那样「被一个同名**文件**占着」
/// 会被判成空闲，于是把一个根本建不出来的目录交给后端，`createSync` 抛
/// `FileSystemException`，整包失败。真机上 `fake.pdf` 就是这么死的
/// （伪后缀没剥掉时输出目录恰好等于源文件名）。
///
/// 剥掉伪后缀之后这条路仍然值得留着：**没有后缀**的压缩包（一个真名叫
/// `data` 的 zip）推出来的输出名就是 `data`，跟源文件自己撞上，一样要靠这里
/// 退到 `data_1`。
bool _anythingExists(String path) =>
    FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound;
