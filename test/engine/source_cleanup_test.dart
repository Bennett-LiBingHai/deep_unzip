/// 解压成功后删源压缩包（`lib/engine/source_cleanup.dart`）。
///
/// 纯 `dart:io`，跑在真临时文件上，宿主机上就能验。
///
/// 盯着的东西只有一条：**只删 `parts` 里那些普通文件，删不掉如实报，别的一概
/// 不碰。** 这是本软件唯一会删用户自己文件的地方，所以「目录不删」「无关文件
/// 不动」「缺号不报错」这三条是重点。
library;

import 'dart:io';

import 'package:deep_unzip/engine/source_cleanup.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'zip_fixtures.dart';

void main() {
  late Directory root;
  setUp(() => root = makeTempDir('src_cleanup'));
  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  // 全部路径过 p.join —— 这一组也跑在 Windows 上，写死 '/' 的拼接必挂。
  String pathOf(String rel) => p.joinAll([root.path, ...rel.split('/')]);

  File writeFile(String rel) {
    final f = File(pathOf(rel));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync('x');
    return f;
  }

  test('全部都是普通文件 → 全删掉，missing/failed 都是 0', () {
    final a = writeFile('a.zip');
    final b = writeFile('b.zip');

    final r = removeSourceFiles([a.path, b.path]);

    expect(r.deleted, 2);
    expect(r.failed, 0);
    expect(r.missing, 0);
    expect(a.existsSync(), isFalse);
    expect(b.existsSync(), isFalse);
  });

  test('有一个卷不在盘上 → 记 missing，其余照删', () {
    final a = writeFile('bak.7z.001');
    final gone = pathOf('bak.7z.002'); // 故意不建
    final c = writeFile('bak.7z.003');

    final r = removeSourceFiles([a.path, gone, c.path]);

    expect(r.deleted, 2);
    expect(r.missing, 1);
    expect(r.failed, 0, reason: '缺号是「目标状态已达成」，不是失败');
    expect(a.existsSync(), isFalse);
    expect(c.existsSync(), isFalse);
  });

  test('某个卷的位置换成了目录 → failed，而且那个目录原封不动', () {
    final a = writeFile('x.zip');
    final dir = Directory(pathOf('y.zip'))..createSync(recursive: true);
    writeFile('y.zip/inner.txt');

    final r = removeSourceFiles([a.path, dir.path]);

    expect(r.deleted, 1);
    expect(r.failed, 1, reason: '类型不符 = 没删掉，要报出来');
    expect(a.existsSync(), isFalse);
    expect(dir.existsSync(), isTrue, reason: '绝不递归删目录 —— 那可能是一整棵输出树');
    expect(File(pathOf('y.zip/inner.txt')).existsSync(), isTrue);
  });

  test('同一个目录里的无关文件不受影响', () {
    final source = writeFile('keep/backup.zip');
    final bystander = writeFile('keep/other.zip');

    final r = removeSourceFiles([source.path]);

    expect(r.deleted, 1);
    expect(bystander.existsSync(), isTrue, reason: '只删 parts 里列出的那些');
  });

  test('全都不存在 → 不抛，计数正确', () {
    final r = removeSourceFiles(
        [pathOf('nope.a'), pathOf('nope.b'), pathOf('nope.c')]);

    expect(r, isA<SourceRemoval>());
    expect(r.deleted, 0);
    expect(r.failed, 0);
    expect(r.missing, 3);
  });

  test('parts 是空的 → 三个数都是 0', () {
    final r = removeSourceFiles(const []);

    expect(r.deleted, 0);
    expect(r.failed, 0);
    expect(r.missing, 0);
  });

  test('空串算 failed，不拿它去碰文件系统', () {
    final r = removeSourceFiles(['']);

    expect(r.failed, 1);
    expect(r.deleted, 0);
  });

  test('+ 把两次结果按桶相加', () {
    final sum = const SourceRemoval(deleted: 2, failed: 1, missing: 3) +
        const SourceRemoval(deleted: 1, failed: 4, missing: 0);

    expect(sum.deleted, 3);
    expect(sum.failed, 5);
    expect(sum.missing, 3);
  });
}
