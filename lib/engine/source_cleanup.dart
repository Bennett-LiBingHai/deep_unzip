/// 解压成功之后，删掉那些**刚刚被解开的**源压缩包。
///
/// ## 为什么需要它
///
/// 这是设置页那颗「解压成功后自动删除源压缩包」开关的执行端。用户开它是为了
/// 省空间、不留双份 —— 解出来的内容留下了，源包没有存在的理由。
///
/// ## 边界（这条最要紧）
///
/// **这是本软件唯一会删用户自己文件的地方。** 别的删除都只碰我们自己刚造出来
/// 的东西（`output_cleanup.dart` 收空目录、原生侧 `RemoveFailedOutput` 删半截
/// 文件），只有这里删的是用户原本就有的文件 —— 没有回收站、没有备份，删掉就是
/// 删掉。所以调用它的前提必须是「这个包确实解压成功了」，那条判断在
/// `AppState._runExtractBatch` 里，本模块只负责删得准、删得少、删不掉的如实报。
///
/// 三条纪律：
///
/// 1. **只删 [parts] 里列出的路径。** 那是扫描器认定的、有序的、绝对路径的
///    分卷全集（单文件时就是 `[entryPath]`）。Dart 侧刻意没有 `safe_paths.dart`，
///    绝不能自己按 `.001`/`.002` 去猜分卷 —— 猜错一个就是误删。
/// 2. **只删普通文件。** 目录、符号链接、其它类型一律不碰。一次类型误判就能
///    端掉一整棵目录树，而代价是不可逆的。
/// 3. **删不掉就如实说，不重试也不硬来。** 与 `output_cleanup.dart` 同一条
///    纪律：被占用、没权限（某些 ROM 上 `MANAGE_EXTERNAL_STORAGE` 也挡不住）
///    都算 `failed`，交给上层去报。
library;

import 'dart:io';

/// 一次删除的结果。三个数**互斥且完备**：每个传入的路径恰好落进一个桶。
///
/// - [deleted]：确实删掉了的卷数。
/// - [failed]：**在盘上、但没删掉**（类型不符 / 被占用 / 没权限）。这一档要向
///   用户报出来 —— 「说好删了却没删」比不删更糟。
/// - [missing]：本来就不在盘上（分卷缺号、已被手动删过）。**不算失败**，
///   目标状态已经达成，不重建也不报错。
class SourceRemoval {
  const SourceRemoval({this.deleted = 0, this.failed = 0, this.missing = 0});

  final int deleted;
  final int failed;
  final int missing;

  SourceRemoval operator +(SourceRemoval o) => SourceRemoval(
        deleted: deleted + o.deleted,
        failed: failed + o.failed,
        missing: missing + o.missing,
      );

  @override
  String toString() =>
      'SourceRemoval(deleted: $deleted, failed: $failed, missing: $missing)';
}

/// 删掉 [parts] 里的每一个卷。见文件头那段边界说明。
SourceRemoval removeSourceFiles(Iterable<String> parts) {
  var result = const SourceRemoval();
  for (final path in parts) {
    result = result + _removeOne(path);
  }
  return result;
}

SourceRemoval _removeOne(String path) {
  if (path.isEmpty) return const SourceRemoval(failed: 1);

  final FileSystemEntityType type;
  try {
    // `followLinks: false`：链接**自己**是什么类型就按什么类型判，不去看它
    // 指向哪儿。链接落进下面那个 `_` 分支，当「不碰」处理。
    type = FileSystemEntity.typeSync(path, followLinks: false);
  } catch (_) {
    return const SourceRemoval(failed: 1);
  }

  if (type == FileSystemEntityType.notFound) {
    return const SourceRemoval(missing: 1);
  }
  if (type != FileSystemEntityType.file) {
    // 目录 / 链接 / 其它 —— 绝不递归删，这不是我们要删的那个东西。
    return const SourceRemoval(failed: 1);
  }

  try {
    File(path).deleteSync();
    return const SourceRemoval(deleted: 1);
  } catch (_) {
    return const SourceRemoval(failed: 1);
  }
}
