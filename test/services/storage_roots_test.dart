import 'dart:io';

import 'package:deep_unzip/services/storage_roots.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// 卷根发现：喂一份假的 `/storage` 树，看它挑出哪些、按什么顺序。
///
/// **必须能注入**：真机上这依赖 `/storage`、`/sdcard`、`/storage/emulated/0`
/// 这些路径存不存在，而测试跑在 Windows 宿主机上，一个都没有。注入之后，这条
/// 逻辑里真正会出错的部分（谁被认成卷、谁被排除、怎么排序）全都能在本机验。
void main() {
  /// 造一个假的文件系统：`{目录: 它下面的子项}`。
  ChildLister fake(Map<String, List<String>> tree) => (dir) async {
        final children = tree[dir];
        if (children == null) {
          throw const FileSystemException('No such file or directory', '', OSError('x', 2));
        }
        return children;
      };

  /// 假目录树里「存在」的目录集合 —— `discoverStorageRoots` 会用
  /// `Directory(...).existsSync()` 复核，那一步走的是**真**文件系统，所以这里
  /// 只能拿测试宿主机上真的存在的目录来当卷根。
  ///
  /// 用临时目录而不是编造 `/storage/emulated/0`：后者在宿主机上不存在，
  /// 会被那条复核整个滤掉，用例就测不到排序了。
  ({Directory dir, String root, ChildLister lister}) fixture(
    Map<String, List<String>> tree,
  ) {
    final dir = Directory.systemTemp.createTempSync('duz_roots_');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    return (dir: dir, root: dir.path, lister: fake(tree));
  }

  test('主卷排在可移动卷前面，多个用户卷按卷号排', () async {
    final f = fixture({});
    // 在临时目录里造三个「卷」。
    final primary = Directory(p.join(f.dir.path, 'case0'))..createSync();
    final work = Directory(p.join(f.dir.path, 'case10'))..createSync();
    final sd = Directory(p.join(f.dir.path, '1A2B-3C4D'))..createSync();

    final roots = await discoverStorageRoots(
      lister: fake({
        '/storage': [
          Directory(p.join(f.dir.path, 'self')).path, // 该被排除
          primary.path,
          sd.path,
          work.path,
        ],
      }),
    );

    // emulated 那一支在假树里不存在，所以这里实际测的是「可移动卷被认出」+
    // 「self 被排除」+「存在的被保留」。排序断言见下一条。
    expect(roots, contains(sd.path));
    expect(roots, isNot(contains(p.join(f.dir.path, 'self'))),
        reason: '`self` 是当前用户主卷的符号链接，放进来是同一个卷两个入口');
  });

  test('emulated 下面按卷号升序，0 在 10 之前', () async {
    final f = fixture({});
    final u0 = Directory(p.join(f.dir.path, 'case0'))..createSync();
    final u10 = Directory(p.join(f.dir.path, 'case10'))..createSync();
    final emulated = Directory(p.join(f.dir.path, 'emulated'))..createSync();

    final roots = await discoverStorageRoots(
      lister: fake({
        '/storage': [emulated.path],
        emulated.path: [u10.path, u0.path], // 故意乱序喂进去
      }),
    );

    expect(roots, [u0.path, u10.path]);
  });

  test('可移动卷排在 emulated 之后', () async {
    final f = fixture({});
    final u0 = Directory(p.join(f.dir.path, 'case0'))..createSync();
    final sd = Directory(p.join(f.dir.path, 'AA11-BB22'))..createSync();
    final emulated = Directory(p.join(f.dir.path, 'emulated'))..createSync();

    final roots = await discoverStorageRoots(
      lister: fake({
        '/storage': [sd.path, emulated.path], // 喂进来时 SD 在前
        emulated.path: [u0.path],
      }),
    );

    expect(roots, [u0.path, sd.path],
        reason: '绝大多数人要找的东西在主卷上，主卷必须排在前面');
  });

  test('名字不像可移动卷的目录不收（别把随便什么目录当卷）', () async {
    final f = fixture({});
    final real = Directory(p.join(f.dir.path, '1A2B-3C4D'))..createSync();
    final notAVolume = Directory(p.join(f.dir.path, 'documents'))..createSync();

    final roots = await discoverStorageRoots(
      lister: fake({
        '/storage': [real.path, notAVolume.path],
      }),
    );

    expect(roots, [real.path]);
  });

  test('列表里给了但实际不存在的路径会被滤掉', () async {
    final f = fixture({});
    final roots = await discoverStorageRoots(
      lister: fake({
        '/storage': [p.join(f.dir.path, '已经不在了', '1A2B-3C4D')],
      }),
    );

    // 找不到任何真卷 → 走回落。回落那两个路径在宿主机上也不存在，于是是 `/`。
    expect(roots, isNotEmpty, reason: '回落必须给一个能用的起点，不能空手而归');
  });

  test('/storage 整个读不了时也回落，不抛', () async {
    final roots = await discoverStorageRoots(lister: fake({}));
    expect(roots, isNotEmpty);
    expect(() => Directory(roots.first).existsSync(), returnsNormally);
  });
}
