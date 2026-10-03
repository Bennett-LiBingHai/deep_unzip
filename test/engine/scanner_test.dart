import 'dart:io';

import 'package:deep_unzip/engine/models.dart';
import 'package:deep_unzip/engine/scanner.dart';
import 'package:deep_unzip/models/archive_file.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'zip_fixtures.dart';

/// 建一个临时根目录，测试结束自动删。
Directory tempRoot(String tag) {
  final d = makeTempDir(tag);
  addTearDown(() {
    if (d.existsSync()) d.deleteSync(recursive: true);
  });
  return d;
}

/// 在 root 下写文件，自动建中间目录。返回绝对路径。
String put(Directory root, String rel, List<int> bytes) {
  final path = p.joinAll([root.path, ...rel.split('/')]);
  File(path).parent.createSync(recursive: true);
  File(path).writeAsBytesSync(bytes);
  return path;
}

List<String> namesOf(ScanSummary s) => [for (final i in s.items) i.fileName];

void main() {
  group('基本遍历', () {
    test('空目录', () async {
      final root = tempRoot('empty');
      final s = await scanDirectory(root.path);
      expect(s.items, isEmpty);
      expect(s.warnings, isEmpty);
      expect(s.containerSkipped, 0);
      expect(s.isEmpty, isTrue);
    });

    test('目录不存在 → 一条告警，不抛异常', () async {
      final s = await scanDirectory(p.join(Directory.systemTemp.path, 'duz_不存在的目录'));
      expect(s.items, isEmpty);
      expect(s.warnings.single, contains('目录不存在'));
    });

    test('一个真 zip → 一项，字段齐全', () async {
      final root = tempRoot('one');
      final path = put(root, 'a.zip', realZip({'hello.txt': 'hi'}));

      final s = await scanDirectory(root.path);
      final item = s.items.single;
      expect(item.entryPath, path);
      expect(item.fileName, 'a.zip');
      expect(item.parts, [path]);
      expect(item.sniff.format, SniffFormat.zip);
      expect(item.sniff.isArchive, isTrue);
      expect(item.sizeBytes, greaterThan(0));
      expect(item.flags, isEmpty);
      expect(item.depth, 0);
      expect(item.split, isNull);
      expect(item.isSplit, isFalse);
    });

    test('非压缩包被忽略（图片 / 文本 / 空文件）', () async {
      final root = tempRoot('junk');
      put(root, 'a.txt', 'hello'.codeUnits);
      put(root, 'b.jpg', [0xFF, 0xD8, 0xFF, 0xE0]);
      put(root, 'c.bin', []);
      put(root, 'd.zip', realZip({'x': 'y'}));

      final s = await scanDirectory(root.path);
      expect(namesOf(s), ['d.zip']);
    });

    test('没有后缀但是 zip → 照样识别，且不算篡改', () async {
      final root = tempRoot('noext');
      put(root, 'backup', realZip({'x': 'y'}));

      final s = await scanDirectory(root.path);
      final item = s.items.single;
      expect(item.sniff.format, SniffFormat.zip);
      expect(item.sniff.isExtensionSpoofed, isFalse);
      expect(item.flags, isEmpty);
    });
  });

  group('容器格式（不该被当成压缩包递归解压）', () {
    test('.docx 后缀直接被跳过（连文件都不开）', () async {
      final root = tempRoot('docx');
      put(root, '报告.docx', 'not really a zip'.codeUnits);

      final s = await scanDirectory(root.path);
      expect(s.items, isEmpty);
      expect(s.containerSkipped, 1);
    });

    test('真 OOXML 内容改名成 .zip → 中央目录标记识破', () async {
      final root = tempRoot('ooxml');
      put(root, 'innocent.zip', realZip({
        '[Content_Types].xml': '<Types/>',
        'word/document.xml': '<w:document/>',
      }));

      final s = await scanDirectory(root.path);
      expect(s.items, isEmpty);
      expect(s.containerSkipped, 1);
    });

    test('.cbz 漫画包**不是**容器，要正常解压', () async {
      final root = tempRoot('cbz');
      put(root, '漫画.cbz', realZip({'1.png': 'x'}));

      final s = await scanDirectory(root.path);
      expect(namesOf(s), ['漫画.cbz']);
      expect(s.containerSkipped, 0);
      expect(s.items.single.flags, isEmpty, reason: 'cbz 是正常后缀，不该报篡改');
    });
  });

  group('递归与顺序', () {
    test('depth 随目录层级递增，且与 baseDepth 相加', () async {
      final root = tempRoot('recurse');
      put(root, 'a.zip', realZip({'x': 'y'}));
      put(root, 'sub/b.zip', realZip({'x': 'y'}));
      put(root, 'sub/deep/c.zip', realZip({'x': 'y'}));

      // 层级是**目录**的层级，不是「在结果列表里排第几」。这里曾经断言过
      // [0, 0, 0]（用例名还写着「顶层 depth 一律是 0」），把 bug 当成了契约：
      // `_visitDir` 收到深度却只拿它做上限守卫，喂给 `_processFiles` 的一直是
      // 恒为 0 的 `baseDepth`，于是 UI 上每一行都显示「深度 0」。
      final s = await scanDirectory(root.path);
      expect(namesOf(s), ['a.zip', 'b.zip', 'c.zip']);
      expect([for (final i in s.items) i.depth], [0, 1, 2]);

      // 嵌套场景（`scanDirectory` 带 baseDepth 重入）是在目录层级之上再抬一个
      // 偏移，不是在旁边另算一套。两个数必须相加。
      final nested = await scanDirectory(root.path, baseDepth: 5);
      expect([for (final i in nested.items) i.depth], [5, 6, 7]);
    });

    test('顺序 = 文件在前、子目录在后，各自自然序（x2 在 x10 之前）', () async {
      final root = tempRoot('order');
      put(root, 'x10.zip', realZip({'x': 'y'}));
      put(root, 'x2.zip', realZip({'x': 'y'}));
      put(root, 'zz.zip', realZip({'x': 'y'}));
      put(root, 'sub/inner.zip', realZip({'x': 'y'}));

      final s = await scanDirectory(root.path);
      expect(namesOf(s), ['x2.zip', 'x10.zip', 'zz.zip', 'inner.zip']);
    });
  });

  group('剪枝', () {
    test('shouldPruneDir：单段名字按 basename 比', () {
      expect(shouldPruneDir('node_modules', 'node_modules', kDefaultPruneDirs), isTrue);
      expect(shouldPruneDir('a/b/node_modules', 'node_modules', kDefaultPruneDirs), isTrue);
      expect(shouldPruneDir('NODE_MODULES', 'NODE_MODULES', kDefaultPruneDirs), isTrue);
      expect(shouldPruneDir(r'$RECYCLE.BIN', r'$RECYCLE.BIN', kDefaultPruneDirs), isTrue);
      expect(shouldPruneDir('src', 'src', kDefaultPruneDirs), isFalse);
      expect(shouldPruneDir('lib', 'lib', kDefaultPruneDirs), isFalse);
    });

    test('shouldPruneDir：两段模式按相对路径后缀比，且不做前缀误匹配', () {
      expect(shouldPruneDir('Android/data', 'data', kDefaultPruneDirs), isTrue);
      expect(shouldPruneDir('x/Android/data', 'data', kDefaultPruneDirs), isTrue);
      expect(shouldPruneDir('Android/obb', 'obb', kDefaultPruneDirs), isTrue);
      expect(shouldPruneDir('Android/data2', 'data2', kDefaultPruneDirs), isFalse);
      expect(shouldPruneDir('MyAndroid/data', 'data', kDefaultPruneDirs), isFalse);
      expect(shouldPruneDir('Android', 'Android', kDefaultPruneDirs), isFalse);
    });

    test('默认剪枝表生效（node_modules）', () async {
      final root = tempRoot('prune');
      put(root, 'keep.zip', realZip({'x': 'y'}));
      put(root, 'node_modules/dep.zip', realZip({'x': 'y'}));

      final s = await scanDirectory(root.path);
      expect(namesOf(s), ['keep.zip']);
    });

    test('Android/data 与 Android/obb 被剪，Android 下其他目录照扫', () async {
      final root = tempRoot('androidd');
      put(root, 'Android/data/app.zip', realZip({'x': 'y'}));
      put(root, 'Android/obb/app.zip', realZip({'x': 'y'}));
      put(root, 'Android/media/keep.zip', realZip({'x': 'y'}));

      final s = await scanDirectory(root.path);
      expect(namesOf(s), ['keep.zip']);
    });

    test('自己的输出目录 _extracted 被跳过（防止自噬）', () async {
      final root = tempRoot('selfout');
      put(root, 'a.zip', realZip({'x': 'y'}));
      put(root, '_extracted/a/b.zip', realZip({'x': 'y'}));

      final s = await scanDirectory(root.path);
      expect(namesOf(s), ['a.zip']);
    });

    test('skipDirs 传绝对路径也能跳过（journal 记录的历史输出）', () async {
      final root = tempRoot('skipdirs');
      put(root, 'a.zip', realZip({'x': 'y'}));
      put(root, 'out_1/b.zip', realZip({'x': 'y'}));

      final s = await scanDirectory(
        root.path,
        skipDirs: {p.join(root.path, 'out_1')},
      );
      expect(namesOf(s), ['a.zip']);
    });

    test('根目录自己即使叫 node_modules 也照扫（用户明确选的）', () async {
      final root = tempRoot('rootprune');
      final sub = Directory(p.join(root.path, 'node_modules'))..createSync();
      File(p.join(sub.path, 'a.zip')).writeAsBytesSync(realZip({'x': 'y'}));

      final s = await scanDirectory(sub.path);
      expect(namesOf(s), ['a.zip']);
    });
  });

  group('分卷', () {
    test('两片合成一项，size 是两片之和，带 split 标记', () async {
      final root = tempRoot('split2');
      final zip = realZip({'hello.txt': 'world'});
      final half = zip.length ~/ 2;
      put(root, 'b.zip.001', zip.sublist(0, half));
      put(root, 'b.zip.002', zip.sublist(half));

      final s = await scanDirectory(root.path);
      final item = s.items.single;
      expect(item.fileName, 'b.zip.001');
      expect(item.parts, hasLength(2));
      expect(item.parts[0], endsWith('b.zip.001'));
      expect(item.parts[1], endsWith('b.zip.002'));
      expect(item.isSplit, isTrue);
      expect(item.split!.kind, SplitKind.rawSplit);
      expect(item.split!.partCount, 2);
      expect(item.flags, {ArchiveFlag.split});
      // 每一片只有一半，合起来才是整个 zip。
      expect(item.sizeBytes, zip.length);
    });

    test('回归：`.zip.001` 不该被误判成后缀篡改', () async {
      // `declaredExt` 如果直接取 `001`，它会不在 zip 的合法后缀集合里，
      // 于是每个分卷包都会冒出「后缀篡改」角标。
      final root = tempRoot('nosplitfalse');
      final zip = realZip({'hello.txt': 'world'});
      final half = zip.length ~/ 2;
      put(root, 'b.zip.001', zip.sublist(0, half));
      put(root, 'b.zip.002', zip.sublist(half));

      final item = (await scanDirectory(root.path)).items.single;
      expect(item.sniff.isExtensionSpoofed, isFalse);
      expect(item.flags.contains(ArchiveFlag.fakeExtension), isFalse);
    });

    test('首卷不是压缩包 → 整组否决，退回普通文件', () async {
      final root = tempRoot('splitbad');
      put(root, 'd.zip.001', 'this is just text'.codeUnits);
      put(root, 'd.zip.002', 'also just text'.codeUnits);

      final s = await scanDirectory(root.path);
      expect(s.items, isEmpty, reason: '文本不是压缩包');
      expect(s.warnings.any((w) => w.contains('首卷不是压缩包')), isTrue);
      expect(s.warnings.any((w) => w.startsWith('分卷识别')), isFalse,
          reason: '这不是分卷号的问题，是首卷内容的问题');
    });

    test('首卷是 zip 但名字是 .rar.001 → 分卷成立 + 伪后缀标记', () async {
      final root = tempRoot('splitfake');
      final zip = realZip({'hello.txt': 'world'});
      final half = zip.length ~/ 2;
      put(root, '备份.rar.001', zip.sublist(0, half));
      put(root, '备份.rar.002', zip.sublist(half));

      final item = (await scanDirectory(root.path)).items.single;
      expect(item.sniff.format, SniffFormat.zip);
      expect(item.sniff.declaredExt, 'rar');
      expect(item.sniff.isExtensionSpoofed, isTrue);
      expect(item.flags, {ArchiveFlag.split, ArchiveFlag.fakeExtension});
    });

    test('非末卷不等长 → 仍然成组，但带一条告警', () async {
      final root = tempRoot('splituneven');
      final zip = realZip({'hello.txt': 'world'});
      // 第一片必须是压缩包开头，后面拿零字节补齐到不同长度。
      put(root, 'c.001', [...zip, ...List.filled(900, 0)]);
      put(root, 'c.002', List.filled(3000, 7));
      put(root, 'c.003', List.filled(10, 7));

      final s = await scanDirectory(root.path);
      expect(s.items.single.split!.partCount, 3);
      expect(s.warnings.any((w) => w.contains('分片尺寸异常')), isTrue);
    });

    test('关闭 mergeSplitVolumes → 分片各自成行，且不误报伪后缀', () async {
      final root = tempRoot('splitoff');
      final zip = realZip({'hello.txt': 'world'});
      final half = zip.length ~/ 2;
      put(root, 'b.zip.001', zip.sublist(0, half));
      put(root, 'b.zip.002', zip.sublist(half));

      final s = await scanDirectory(
        root.path,
        options: const ScanOptions(mergeSplitVolumes: false),
      );
      // .002 是裸字节，嗅探认不出来，所以只剩 .001 一行。
      expect(namesOf(s), ['b.zip.001']);
      expect(s.items.single.split, isNull);
      expect(s.items.single.flags, isEmpty);
    });

    test('孤立的高序号分片不会凭空变成一项', () async {
      final root = tempRoot('orphan');
      put(root, 'e.zip.002', 'text'.codeUnits);

      final s = await scanDirectory(root.path);
      expect(s.items, isEmpty);
    });
  });

  group('伪后缀', () {
    test('zip 改名成 .pdf → 识别成功并带伪后缀标记', () async {
      final root = tempRoot('fakeext');
      put(root, '发票.pdf', realZip({'a.txt': 'hi'}));

      final s = await scanDirectory(root.path);
      final item = s.items.single;
      expect(item.sniff.format, SniffFormat.zip);
      expect(item.sniff.declaredExt, 'pdf');
      expect(item.flags, {ArchiveFlag.fakeExtension});
    });

    test('关掉 detectFakeExtension → 仍识别格式，但不打标记', () async {
      final root = tempRoot('fakeoff');
      put(root, '发票.pdf', realZip({'a.txt': 'hi'}));

      final s = await scanDirectory(
        root.path,
        options: const ScanOptions(detectFakeExtension: false),
      );
      expect(s.items.single.sniff.format, SniffFormat.zip);
      expect(s.items.single.flags, isEmpty);
    });

    test('SFX：MZ 壳包着的 zip 也算识别成功', () async {
      final root = tempRoot('sfx');
      put(root, 'setup.exe', [
        0x4D, 0x5A,
        ...List.filled(2046, 0),
        ...realZip({'a.txt': 'hi'}),
      ]);

      final s = await scanDirectory(root.path);
      final item = s.items.single;
      expect(item.sniff.format, SniffFormat.zip);
      expect(item.sniff.baseOffset, 2048);
      expect(item.sniff.declaredExt, 'exe');
    });
  });

  group('进度回调', () {
    test('每个目录结束时都报一次，计数单调不减', () async {
      final root = tempRoot('tick');
      put(root, 'a.zip', realZip({'x': 'y'}));
      put(root, 'sub/b.zip', realZip({'x': 'y'}));
      put(root, 'sub/deep/c.zip', realZip({'x': 'y'}));

      final ticks = <ScanTick>[];
      final s = await scanDirectory(root.path, onTick: ticks.add);

      expect(ticks, isNotEmpty);
      final last = ticks.last;
      expect(last.files, 3);
      expect(last.found, s.items.length);
      expect(last.dirs, 2, reason: 'sub 与 sub/deep');
      for (var i = 1; i < ticks.length; i++) {
        expect(ticks[i].files, greaterThanOrEqualTo(ticks[i - 1].files));
        expect(ticks[i].dirs, greaterThanOrEqualTo(ticks[i - 1].dirs));
      }
    });
  });

  group('取消', () {
    test('一开始就取消 → 空结果 + 一条告警', () async {
      final root = tempRoot('cancel');
      put(root, 'a.zip', realZip({'x': 'y'}));

      final s = await scanDirectory(root.path, isCancelled: () => true);
      expect(s.items, isEmpty);
      expect(s.warnings.single, contains('已取消'));
    });

    test('不取消时不受影响', () async {
      final root = tempRoot('nocancel');
      put(root, 'a.zip', realZip({'x': 'y'}));

      final s = await scanDirectory(root.path, isCancelled: () => false);
      expect(namesOf(s), ['a.zip']);
      expect(s.warnings, isEmpty);
    });
  });

  group('scanFileList（解压过程中发现的新压缩包）', () {
    test('只扫给定的文件，不递归目录', () async {
      final root = tempRoot('filelist');
      put(root, 'out/a.zip', realZip({'x': 'y'}));
      put(root, 'out/skip/b.zip', realZip({'x': 'y'}));

      final s = await scanFileList([p.join(root.path, 'out', 'a.zip')]);
      expect(namesOf(s), ['a.zip']);
    });

    test('同一目录的文件仍会做分卷合并', () async {
      final root = tempRoot('filelist2');
      final zip = realZip({'hello.txt': 'world'});
      final half = zip.length ~/ 2;
      final p1 = put(root, 'b.zip.001', zip.sublist(0, half));
      final p2 = put(root, 'b.zip.002', zip.sublist(half));

      final s = await scanFileList([p2, p1]);
      expect(s.items.single.isSplit, isTrue);
      expect(s.items.single.parts, hasLength(2));
    });

    test('baseDepth 传进 ScanItem.depth', () async {
      final root = tempRoot('filelist3');
      final path = put(root, 'a.zip', realZip({'x': 'y'}));

      final s = await scanFileList([path], baseDepth: 3);
      expect(s.items.single.depth, 3);
    });

    test('读不到的文件计入 unreadable 而不是炸掉', () async {
      final root = tempRoot('filelist4');
      final s = await scanFileList([p.join(root.path, '没有这个文件.zip')]);
      expect(s.items, isEmpty);
      expect(s.unreadable, 1);
      expect(s.warnings.single, contains('无法读取'));
    });
  });
}
