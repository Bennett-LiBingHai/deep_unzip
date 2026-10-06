import 'dart:io';

import 'package:deep_unzip/services/file_browser.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// 建一个临时根目录，测试结束自动删。
Directory tempRoot(String tag) {
  final d = Directory.systemTemp.createTempSync('duz_browser_$tag');
  addTearDown(() {
    if (d.existsSync()) d.deleteSync(recursive: true);
  });
  return d;
}

void touch(Directory root, String rel) {
  final path = p.joinAll([root.path, ...rel.split('/')]);
  File(path).parent.createSync(recursive: true);
  File(path).writeAsStringSync('x');
}

void mkdir(Directory root, String rel) {
  Directory(p.joinAll([root.path, ...rel.split('/')])).createSync(recursive: true);
}

void main() {
  // 这些用例**真的碰磁盘**（造临时目录树），跑在宿主机的文件系统上。
  // 所以路径一律用 `p.join` / `p.basename` 拼，写死 `/` 在 Windows 上必挂。
  group('listDirectory', () {
    test('目录在前、文件在后，各自自然序（x2 在 x10 之前）', () async {
      final root = tempRoot('order');
      touch(root, 'x10.zip');
      touch(root, 'x2.zip');
      mkdir(root, 'zdir');
      mkdir(root, 'adir');

      final l = await listDirectory(root.path);

      expect(l.dirs.map((e) => e.name), ['adir', 'zdir']);
      expect(l.files.map((e) => e.name), ['x2.zip', 'x10.zip']);
      expect(l.error, isNull);
    });

    test('isDir 只对真目录为真，文件为假', () async {
      final root = tempRoot('isdir');
      mkdir(root, 'sub');
      touch(root, 'a.zip');

      final l = await listDirectory(root.path);

      expect(l.dirs.single.isDir, isTrue);
      expect(l.files.single.isDir, isFalse);
      expect(l.dirs.single.path, p.join(root.path, 'sub'));
      expect(l.files.single.name, 'a.zip');
    });

    test('空目录：两边都空，而且不是 error', () async {
      final l = await listDirectory(tempRoot('empty').path);
      expect(l.isEmpty, isTrue);
      expect(l.error, isNull);
    });

    test('隐藏文件照列 —— 用户要找的包可能在隐藏目录里', () async {
      final root = tempRoot('hidden');
      touch(root, '.hidden.zip');
      mkdir(root, '.gitdir');

      final l = await listDirectory(root.path);

      expect(l.files.map((e) => e.name), ['.hidden.zip']);
      expect(l.dirs.map((e) => e.name), ['.gitdir']);
    });

    test('不存在的目录 → 一句人话的 error，不抛', () async {
      final l = await listDirectory(p.join(tempRoot('gone').path, '没有这个'));
      expect(l.error, isNotNull);
      expect(l.dirs, isEmpty);
      expect(l.files, isEmpty);
    });

    test('底层抛 FileSystemException 时被接住（Android/data 那种常态）', () async {
      // 在 Windows 宿主机上造不出真的无权限目录，所以注入一个会抛的列举器。
      final l = await listDirectory(
        '/whatever',
        lister: (_) => Stream.error(
          const FileSystemException('Permission denied', '/whatever',
              OSError('Permission denied', 13)),
        ),
      );

      expect(l.error, contains('权限'));
      expect(l.error, isNot(contains('errno')));
      expect(l.error, isNot(contains('\$')));
    });

    test('清单里混进符号链接时当普通条目列出，不下钻', () async {
      final root = tempRoot('symlink');
      mkdir(root, 'real');
      touch(root, 'real/a.zip');
      try {
        Link(p.join(root.path, 'link')).createSync(p.join(root.path, 'real'));
      } on FileSystemException {
        // Windows 上建符号链接常要管理员权限 —— 建不出来就跳过这一条。
        return;
      }

      final l = await listDirectory(root.path);

      expect(l.dirs.map((e) => e.name), ['real'],
          reason: '符号链接不是 Directory，所以进不了子目录那一列');
      expect(l.files.map((e) => e.name), ['link']);
    });
  });

  // ---------------------------------------------------------------------------
  // 补元数据。列表先出来、大小后跳 —— 这两步分开是刻意的，所以这里测的是
  // 「第二步会不会把第一步的东西弄坏」，而不是「能不能拿到 size」。
  // ---------------------------------------------------------------------------
  group('enrichEntries', () {
    final stamp = DateTime(2026, 10, 6, 14, 32);

    /// 造一个假的 stat：给得出的路径回固定大小与时间；[fail] 里的路径抛
    /// `FileSystemException`（权限不足那一类），[missing] 里的回 `found: false`
    /// （`FileStat.stat` 对不存在的路径**不抛异常**，这一档是真实存在的行为）。
    StatLister fakeStat(
      Map<String, int> sizes, {
      Set<String> fail = const {},
      Set<String> missing = const {},
    }) {
      return (path) async {
        if (fail.contains(path)) {
          throw const FileSystemException('Permission denied', '', OSError('x', 13));
        }
        if (missing.contains(path)) return const StatResult(found: false);
        return StatResult(
            found: true, sizeBytes: sizes[path] ?? 0, modified: stamp);
      };
    }

    List<DirEntry> entriesOf(List<String> paths, {Set<String> dirs = const {}}) => [
          for (final path in paths)
              DirEntry(
                  path: path, name: p.basename(path), isDir: dirs.contains(path)),
        ];

    /// 收齐所有回调，拼成一张 path → meta 的表。
    Future<Map<String, FileMeta>> collect(
      List<DirEntry> entries, {
      StatLister? stat,
      bool Function()? isCancelled,
      int concurrency = kStatConcurrency,
      void Function(Map<String, FileMeta>)? onBatch,
    }) async {
      final all = <String, FileMeta>{};
      await enrichEntries(
        entries,
        concurrency: concurrency,
        stat: stat,
        isCancelled: isCancelled,
        onBatch: (batch) {
          onBatch?.call(batch);
          all.addAll(batch);
        },
      );
      return all;
    }

    test('文件补上大小与时间', () async {
      final entries = entriesOf(['/a.zip', '/b.zip']);
      final got = await collect(entries,
          stat: fakeStat({'/a.zip': 1234, '/b.zip': 5678}));

      expect(got['/a.zip']!.sizeBytes, 1234);
      expect(got['/b.zip']!.sizeBytes, 5678);
      expect(got['/a.zip']!.modified, stamp);
    });

    test('目录不给大小，但给时间', () async {
      // `stat` 对目录返回的是目录项本身占的字节，不是内容之和 —— 摆出去用户
      // 只会读成「这个文件夹才 4 KB，里面怎么有 3 GB」。
      final entries = entriesOf(['/sub'], dirs: {'/sub'});
      final got = await collect(entries, stat: fakeStat({'/sub': 4096}));

      expect(got['/sub']!.sizeBytes, isNull);
      expect(got['/sub']!.modified, stamp, reason: '时间对目录同样有意义');
    });

    test('单条 stat 抛异常 → 那条留空，其余照常', () async {
      final entries = entriesOf(['/bad', '/good']);
      final got = await collect(entries,
          stat: fakeStat({'/good': 7}, fail: {'/bad'}));

      expect(got, hasLength(2), reason: '失败的那条也要说出来，好让界面知道补过了');
      expect(got['/bad']!.sizeBytes, isNull);
      expect(got['/bad']!.modified, isNull);
      expect(got['/good']!.sizeBytes, 7, reason: '一条失败不该拖垮整批');
    });

    test('文件在两次调用之间被删 → 留空，不是 0 B / 1970', () async {
      // `FileStat.stat` 对不存在的路径**不抛**，回一个 `notFound`。不管这一档
      // 的话，刚删掉的文件会顶着 `0 B` 和 `1970-01-01` 显示出来。
      final entries = entriesOf(['/gone']);
      final got = await collect(entries, stat: fakeStat({}, missing: {'/gone'}));

      expect(got['/gone']!.sizeBytes, isNull);
      expect(got['/gone']!.modified, isNull);
    });

    test('攒批：不是每条一次回调', () async {
      final entries = entriesOf([for (var i = 0; i < 40; i++) '/f$i']);
      final batches = <int>[];
      final got = await collect(
        entries,
        concurrency: 1,
        stat: fakeStat({for (var i = 0; i < 40; i++) '/f$i': i}),
        onBatch: (b) => batches.add(b.length),
      );

      expect(got, hasLength(40));
      // 40 条、每批 16：16 / 16 / 8。
      expect(batches, [kMetaBatchSize, kMetaBatchSize, 40 - 2 * kMetaBatchSize]);
      expect(batches.fold<int>(0, (a, b) => a + b), 40, reason: '一条都不能丢');
    });

    test('isCancelled 之后立刻停手，不再往下 stat', () async {
      final entries = entriesOf([for (var i = 0; i < 200; i++) '/f$i']);
      var statCalls = 0;
      var done = 0;

      final got = await collect(
        entries,
        concurrency: 1,
        isCancelled: () => done >= 10,
        stat: (path) async {
          statCalls++;
          done++;
          return StatResult(found: true, sizeBytes: 1, modified: stamp);
        },
      );

      expect(statCalls, lessThan(200),
          reason: '取消之后不该把整目录 stat 完 —— 那正是这个参数的用处');
      expect(got.length, lessThan(200));
    });

    test('空列表：一条回调都不发', () async {
      var called = 0;
      await enrichEntries(const [], onBatch: (_) => called++);
      expect(called, 0);
    });

    test('真文件上跑一遍（宿主机文件系统）', () async {
      final root = tempRoot('real');
      File(p.join(root.path, 'a.zip')).writeAsBytesSync(List.filled(2048, 0));
      mkdir(root, 'sub');

      final listing = await listDirectory(root.path);
      final got = await collect([...listing.dirs, ...listing.files]);

      expect(got[p.join(root.path, 'a.zip')]!.sizeBytes, 2048);
      expect(got[p.join(root.path, 'a.zip')]!.modified, isNotNull);
      expect(got[p.join(root.path, 'sub')]!.sizeBytes, isNull);
    });
  });
}
