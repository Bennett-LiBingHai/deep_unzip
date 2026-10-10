/// 取消解压之后的空目录清理（`lib/engine/output_cleanup.dart`）。
///
/// 这一组全部跑在真临时目录上 —— 纯 `dart:io`，不碰引擎也不碰 FFI，宿主机上
/// 就能跑（解压那边只能真机验，见 memory `android-only-cpp-verification`）。
///
/// 盯着的东西只有一条：**只删这次解压新建的空目录，收工前就存在的一个都不动。**
/// 这一条一旦错，用户自己建的目录会被静默吃掉 —— 所以边界那两条用例是重点。
library;

import 'dart:io';

import 'package:deep_unzip/engine/output_cleanup.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'zip_fixtures.dart';

void main() {
  late Directory root;
  setUp(() => root = makeTempDir('cleanup'));
  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  // 全部路径都过 p.join —— 这一组也跑在 Windows 上，写死 '/' 的拼接必挂。
  Directory dir(String rel) =>
      Directory(p.joinAll([root.path, ...rel.split('/')]));
  String pathOf(String rel) => p.joinAll([root.path, ...rel.split('/')]);
  bool hasDir(String rel) => dir(rel).existsSync();

  File writeFile(String rel) {
    final f = File(pathOf(rel));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync('x');
    return f;
  }

  group('existingBoundary', () {
    test('目录已存在 → 就是它自己（那种情况什么都不该删）', () {
      final d = dir('a/b')..createSync(recursive: true);
      expect(existingBoundary(d), d.path);
    });

    test('目录还不存在 → 返回最近的已存在祖先', () {
      dir('a').createSync(recursive: true);
      expect(existingBoundary(dir('a/b/c')), dir('a').path);
    });
  });

  group('pruneCreatedDirs', () {
    test('新建的空链整条删掉，边界以上一个不动', () {
      dir('keep').createSync(recursive: true);
      writeFile('keep/other.txt');

      final target = dir('keep/new/sub');
      final boundary = existingBoundary(target); // 建之前量 = keep
      target.createSync(recursive: true);

      pruneCreatedDirs(target, boundary);

      expect(hasDir('keep/new'), isFalse, reason: '新建的中间层也是这次解压留的');
      expect(hasDir('keep'), isTrue);
      expect(File(pathOf('keep/other.txt')).existsSync(), isTrue);
    });

    test('什么都没解出来时，输出目录自己也删掉 —— 不留痕', () {
      final target = dir('out');
      final boundary = existingBoundary(target); // 建之前量 = root
      target.createSync(recursive: true);

      pruneCreatedDirs(target, boundary);

      expect(hasDir('out'), isFalse);
      expect(root.existsSync(), isTrue, reason: '边界是 root，绝不能被一起删');
    });

    test('解出过文件的目录留着，只删空的兄弟', () {
      final target = dir('out');
      final boundary = existingBoundary(target);
      target.createSync(recursive: true);
      writeFile('out/doc/a.txt');
      dir('out/empt/deeper').createSync(recursive: true);

      pruneCreatedDirs(target, boundary);

      expect(File(pathOf('out/doc/a.txt')).existsSync(), isTrue,
          reason: '取消前完整解出的文件是用户的成果');
      expect(hasDir('out/empt'), isFalse, reason: '空的兄弟才删');
      expect(hasDir('out'), isTrue, reason: '里面有东西 → 输出目录留着');
    });

    test('边界那层是空的也不删 —— 那是用户自己的目录', () {
      dir('userdir').createSync(recursive: true);

      final target = dir('userdir/arch');
      final boundary = existingBoundary(target); // 建之前量 = userdir
      target.createSync(recursive: true);

      pruneCreatedDirs(target, boundary);

      expect(hasDir('userdir/arch'), isFalse);
      expect(hasDir('userdir'), isTrue,
          reason: '收工前就存在，一个字节都不该动');
    });

    test('符号链接算「有东西」，不当空目录删掉', () {
      final target = dir('out');
      final boundary = existingBoundary(target);
      target.createSync(recursive: true);

      final link = Link(pathOf('out/link'));
      try {
        // Windows 上建链接常要管理员权限，建不成这条就跳过（Android 上没这问题）。
        link.createSync(pathOf('out/nowhere'));
      } on FileSystemException {
        return;
      }

      pruneCreatedDirs(target, boundary);

      expect(link.existsSync(), isTrue);
      expect(hasDir('out'), isTrue);
    });
  });
}
