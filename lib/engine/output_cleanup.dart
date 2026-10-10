/// 取消解压之后，把这次新建、又没留下任何东西的空目录收掉。
///
/// ## 为什么需要它
///
/// 取消是在**条目写入中途** unwind 的（`E_ABORT`），原生侧只保证删掉那个
/// 「名字对、长度不对」的截断文件（见 `duz_engine.cpp` 的 `RemoveFailedOutput`）。
/// 但**目录**是另一回事：输出目录本身、以及为深层条目按需建出来的各级子目录
/// 都留在盘上。结果是用户按了「停止」，磁盘上却多出一个空文件夹 —— 一眼看去
/// 像是「干了点什么又没干完」，比什么都没有更让人不安。
///
/// ## 边界（这条最要紧）
///
/// **只碰这次解压新建的那条目录链。** 收工前就存在的目录，一个都不删 ——
/// 那是用户自己的东西（他可能特意建了个空目录等着放东西）。所以
/// [pruneCreatedDirs] 要一个 `stopAt`：从 [dir] 往上收，走到它为止。
/// 那个值由 [existingBoundary] 在**建目录之前**量出来，这是本模块唯一的契约：
/// 忘了先量、或量晚了，边界就退化成「整条链都不删」或者「连用户目录一起删」。
///
/// ## 为什么是「删空目录」而不是「直接删输出目录」
///
/// 取消之前可能已经完整解出了几个文件，那些是用户的成果。所以只能自底向上地
/// 删**空**目录：任何一层只要有东西（文件、链接、非空目录），它和它上面的
/// 一律留着 —— 输出目录自然也就跟着留下。
library;

import 'dart:io';

/// 从 [dir] 往上数，**第一个已经存在**的目录路径。
///
/// 必须在 `createSync` **之前**调用：它量的正是「这次解压可能新建哪些层」的
/// 上界。[dir] 自己已存在时返回的就是它自己 —— 那种情况我们什么都不该删。
String existingBoundary(Directory dir) {
  var cur = dir;
  while (true) {
    if (cur.existsSync()) return cur.path;
    final parent = cur.parent;
    if (parent.path == cur.path) return cur.path; // 到根了（正常走不到）
    cur = parent;
  }
}

/// 删掉这次解压新建、且现在是空的那些目录：[dir] 自己，以及它到 [stopAt]
/// 之间的各级父目录。[stopAt] 本身**不动**（见文件头那段边界说明）。
///
/// 这条链上若有一层不是空的（说明里面留着解好的文件），收敛到此为止 ——
/// 它和它上面的都不删。
void pruneCreatedDirs(Directory dir, String stopAt) {
  var cur = dir;
  while (cur.path != stopAt) {
    if (!_pruneEmptyDirsInside(cur)) return; // 里面还有东西 → 到此为止
    try {
      cur.deleteSync();
    } catch (_) {
      return; // 删不掉（权限、被占用）就放弃，不硬来
    }
    final parent = cur.parent;
    if (parent.path == cur.path) return;
    cur = parent;
  }
}

/// 递归删掉 [dir] 里面的空目录，返回「删完之后 [dir] 自己是不是空的」。
bool _pruneEmptyDirsInside(Directory dir) {
  final List<FileSystemEntity> children;
  try {
    children = dir.listSync(followLinks: false);
  } catch (_) {
    return false; // 列不出来就当它有东西，绝不动
  }

  var empty = true;
  for (final child in children) {
    if (child is! Directory) {
      // 文件和**符号链接**都算「有东西」。链接尤其不能当空目录删掉：它链到
      // 哪儿我们没看，也不该看（`followLinks: false` 正是为了不看）。
      empty = false;
      continue;
    }
    if (!_pruneEmptyDirsInside(child)) {
      empty = false;
      continue;
    }
    try {
      child.deleteSync();
    } catch (_) {
      empty = false;
    }
  }
  return empty;
}
