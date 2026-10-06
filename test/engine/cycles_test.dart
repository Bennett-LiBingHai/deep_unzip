import 'dart:io';

import 'package:deep_unzip/engine/cycles.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'zip_fixtures.dart';

void main() {
  Directory tempRoot(String tag) {
    final d = makeTempDir(tag);
    addTearDown(() {
      if (d.existsSync()) d.deleteSync(recursive: true);
    });
    return d;
  }

  String put(Directory root, String rel, List<int> bytes) {
    final path = p.joinAll([root.path, ...rel.split('/')]);
    File(path).parent.createSync(recursive: true);
    File(path).writeAsBytesSync(bytes);
    return path;
  }

  group('身份指纹', () {
    test('同一个文件算两次得到同一个身份', () async {
      final root = tempRoot('cy_same');
      final a = put(root, 'a.zip', List.filled(300, 7));

      expect(await archiveIdentity(a), await archiveIdentity(a));
    });

    test('内容不同 → 身份不同', () async {
      final root = tempRoot('cy_diff');
      final a = put(root, 'a.zip', List.filled(300, 7));
      final b = put(root, 'b.zip', List.filled(300, 8));

      expect(await archiveIdentity(a), isNot(await archiveIdentity(b)));
    });

    test('内容相同但**文件名**不同 → 身份不同', () async {
      // 这是刻意的保守项：两份一模一样的副本被放进同一个目录时，它们是
      // 两个包，不该因为内容相同就被判成自引用而漏解一个。
      final root = tempRoot('cy_name');
      final a = put(root, 'a.zip', List.filled(300, 7));
      final b = put(root, 'b.zip', List.filled(300, 7));

      expect(await archiveIdentity(a), isNot(await archiveIdentity(b)));
    });

    test('内容相同、文件名也相同、只是目录不同 → 身份**相同**', () async {
      // 这才是自引用的真身：`a.zip` 里装着一份 `a.zip`。它落在子目录里，
      // 但内容与名字都与外层一致。
      final root = tempRoot('cy_nested');
      final outer = put(root, 'a.zip', List.filled(300, 7));
      final inner = put(root, 'sub/a.zip', List.filled(300, 7));

      expect(await archiveIdentity(outer), await archiveIdentity(inner));
    });

    test('同名但长度不同 → 身份不同', () async {
      final root = tempRoot('cy_len');
      final a = put(root, 'x/a.zip', List.filled(100, 7));
      final b = put(root, 'y/a.zip', List.filled(200, 7));

      expect(await archiveIdentity(a), isNot(await archiveIdentity(b)));
    });

    test('超过 64 KiB 只读头部：前缀相同则身份相同', () async {
      // 这条把上面那个「省 IO」的设计**当成契约锁住**，免得日后有人以为
      // 它是内容哈希。两份文件（同名、等长、前 64 KiB 一致、尾部不同）
      // 会得到同一个身份 —— 对自引用检测足够了（真自引用是同一份数据），
      // 但**不能**拿它去做去重或缓存键。
      final root = tempRoot('cy_big');
      final head = List.filled(kIdentityHeadBytes, 3);
      final a = put(root, 'x/a.zip', [...head, ...List.filled(5000, 1)]);
      final b = put(root, 'y/a.zip', [...head, ...List.filled(5000, 2)]);

      expect(await archiveIdentity(a), await archiveIdentity(b));
    });

    test('读不到的文件：身份独一无二，绝不与任何东西相等', () async {
      final root = tempRoot('cy_missing');
      final ghost = p.join(root.path, '没有这个文件.zip');

      final identity = await archiveIdentity(ghost);
      expect(identity, startsWith('unreadable:'));
      // 两个不存在的路径也不相等 —— 否则「读不到」会被误判成自引用。
      expect(
        identity,
        isNot(await archiveIdentity(p.join(root.path, '另一个也不存在.zip'))),
      );
      expect(isSelfReferential(identity, {identity}), isTrue);
    });
  });

  group('自引用判定', () {
    test('命中祖先集 → true；否则 false', () {
      const me = 'abc:100:a.zip';
      expect(isSelfReferential(me, {'def:200:b.zip', me}), isTrue);
      expect(isSelfReferential(me, {'def:200:b.zip'}), isFalse);
    });

    test('空祖先集永远不命中（顶层的包一个字节都不用读）', () {
      expect(isSelfReferential('anything', const {}), isFalse);
    });
  });

  group('深度顶', () {
    test('maxDepth = 0 → 不递归：任何内层包都进不来', () {
      // 顶层（depth 0）不由这里管 —— 它本来就要解，这里拦的是解出来的内层包，
      // 它们的 depth 从 1 起。所以 0 能过而 1 不能，正是「不递归」的形状。
      expect(withinDepthLimit(0, 0), isTrue, reason: '顶层不受这一档管');
      expect(withinDepthLimit(1, 0), isFalse);
      expect(withinDepthLimit(kHardDepthCeiling, 0), isFalse,
          reason: '0 不是「无限制」，别再放行任何内层包');
    });

    test('用户设了几就是几，不会被硬顶抬上去', () {
      expect(withinDepthLimit(5, 5), isTrue);
      expect(withinDepthLimit(6, 5), isFalse);
    });

    test('用户设得比硬顶还大时，取硬顶（硬顶不靠调用方自觉）', () {
      expect(withinDepthLimit(kHardDepthCeiling, 9999), isTrue);
      expect(withinDepthLimit(kHardDepthCeiling + 1, 9999), isFalse);
    });
  });

  group('调试用短身份', () {
    test('取哈希前 8 位', () {
      expect(shortIdentity('abcdef1234:100:a.zip'), 'abcdef12');
    });

    test('读不到的标成 unreadable', () {
      expect(shortIdentity('unreadable:/x/y.zip'), 'unreadable');
    });
  });
}
