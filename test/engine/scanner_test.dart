import 'dart:io';
import 'dart:typed_data';

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

/// 一个「像 7z 的文件」，够嗅探认出 [SniffFormat.sevenZ] 即可。
///
/// 探针是注入的，这些用例测的是**怎么用探针的答案**，不是引擎真能读出什么，
/// 所以内容只要签名对、长度够分卷切成两半就行。
List<int> _sevenZStub() => [
      0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C, // 7z 签名（版本号跟在后面）
      0x00, 0x04,
      ...List.filled(12, 0),
    ];

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

    // 这个开关在设置页上叫「伪后缀时暂停」，控制的只是**问不问**。
    // 测试名字保留 `detectFakeExtension` 是因为那是字段名 —— 但它不
    // 「关闭检测」，检测压根关不掉：扫描靠魔术字节认压缩包，关了这个
    // `发票.pdf` 照样进列表。这条钉的就是这个区别。
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

  group('加密包检测（「需密码」角标）', () {
    test('ZIP：中央目录的加密位直接认出来，一次都不开归档', () async {
      final root = tempRoot('enczip');
      put(root, 'locked.zip', encryptedZip({'a.txt': 'x'}));

      var probes = 0;
      final s = await scanDirectory(
        root.path,
        probeEncrypted: (parts, format) {
          probes++;
          return null;
        },
      );

      expect(s.items.single.flags, contains(ArchiveFlag.encrypted));
      expect(probes, 0, reason: 'ZIP 的加密位是白捡的，不该去问引擎');
    });

    test('没加密的 ZIP 不会被误标', () async {
      final root = tempRoot('plainzip');
      put(root, 'plain.zip', realZip({'a.txt': 'x'}));

      final s = await scanDirectory(root.path);
      expect(s.items.single.flags, isNot(contains(ArchiveFlag.encrypted)));
    });

    test('7z：格式闸放行，探针说 true 就打标', () async {
      final root = tempRoot('enc7z');
      put(root, 'locked.7z', _sevenZStub());

      final asked = <SniffFormat>[];
      final s = await scanDirectory(
        root.path,
        probeEncrypted: (parts, format) {
          asked.add(format);
          return true;
        },
      );

      expect(asked, [SniffFormat.sevenZ]);
      expect(s.items.single.flags, contains(ArchiveFlag.encrypted));
    });

    test('探针答「不知道」（null）时**不打标** —— 不知道不等于不要密码，'
        '但更不等于要', () async {
      final root = tempRoot('unknown7z');
      put(root, 'maybe.7z', _sevenZStub());

      final s = await scanDirectory(root.path, probeEncrypted: (_, _) => null);
      expect(s.items.single.flags, isNot(contains(ArchiveFlag.encrypted)));
    });

    test('探针说 false 也不打标（与 null 同一条出口）', () async {
      final root = tempRoot('plain7z');
      put(root, 'open.7z', _sevenZStub());

      final s = await scanDirectory(root.path, probeEncrypted: (_, _) => false);
      expect(s.items.single.flags, isNot(contains(ArchiveFlag.encrypted)));
    });

    test('分卷：把**全部**卷交给探针，不是只给首卷', () async {
      // 这条是探针契约里最容易写错的一点。ZIP 的中央目录在**末卷**上，
      // 只递首卷等于永远读不到；分卷的「要不要密码」也就永远答不出来。
      final root = tempRoot('encsplit');
      final stub = _sevenZStub();
      final half = stub.length ~/ 2;
      put(root, 'locked.7z.001', stub.sublist(0, half));
      put(root, 'locked.7z.002', stub.sublist(half));

      List<String>? seenParts;
      final s = await scanDirectory(
        root.path,
        probeEncrypted: (parts, format) {
          seenParts = parts;
          expect(format, SniffFormat.sevenZ);
          return true;
        },
      );

      expect(s.items.single.isSplit, isTrue);
      expect(seenParts, hasLength(2));
      expect(seenParts![0], endsWith('locked.7z.001'));
      expect(seenParts![1], endsWith('locked.7z.002'));
      expect(s.items.single.flags,
          containsAll([ArchiveFlag.split, ArchiveFlag.encrypted]));
    });

    test('分卷用探针的答案优先于首卷嗅探出来的（首卷读不出末卷的目录）',
        () async {
      // 首卷是 ZIP 的第一片：密位在末卷的中央目录里，首卷那份嗅探结果只能是
      // null。探针（真实实现里对 ZIP 会回 null，这里为了验优先级让它回 true）
      // 一旦答得出来，就该盖过首卷的结果。
      final root = tempRoot('splitprio');
      final zip = encryptedZip({'a.txt': 'x'});
      final half = zip.length ~/ 2;
      put(root, 'b.zip.001', zip.sublist(0, half));
      put(root, 'b.zip.002', zip.sublist(half));

      final noProbe = (await scanDirectory(root.path)).items.single;
      expect(noProbe.flags, isNot(contains(ArchiveFlag.encrypted)),
          reason: '前提：只嗅首卷时确实认不出来');

      final withProbe = (await scanDirectory(
        root.path,
        probeEncrypted: (_, _) => true,
      ))
          .items
          .single;
      expect(withProbe.flags, contains(ArchiveFlag.encrypted));
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

  // ---------------------------------------------------------------------------
  // 用户点名单个文件那条路（首页「选择文件」）
  // ---------------------------------------------------------------------------

  group('显式文件：忽略容器格式', () {
    /// 一份**真 OOXML 内容**的 zip：中央目录里有 `[Content_Types].xml` 与
    /// `word/`，正是 `detectContainer` 用来识破容器的标记。
    Uint8List ooxmlZip() => realZip({
          '[Content_Types].xml': '<Types/>',
          'word/document.xml': '<w:document/>',
        });

    test('对照组：目录扫描时它被容器防线拦下', () async {
      final root = tempRoot('explicit_dir');
      put(root, 'report.docx', ooxmlZip());

      final s = await scanDirectory(root.path);
      expect(s.items, isEmpty, reason: '这条防线是刻意的，别动它');
      expect(s.containerSkipped, 1);
    });

    test('ignoreContainers 时同一个文件被当成压缩包收下', () async {
      final root = tempRoot('explicit_file');
      final path = put(root, 'report.docx', ooxmlZip());

      final s = await scanFileList([path], baseDepth: 0, ignoreContainers: true);
      expect(s.items, hasLength(1),
          reason: '用户明确点了它，就该解它 —— 哪怕它叫 .docx');
      expect(s.items.single.sniff.format, SniffFormat.zip);
      expect(s.containerSkipped, 0);
    });

    test('让位的是「按名字判死」，不是「不看内容就收下」', () async {
      // 真身不是压缩包的 .docx（纯文本）让位之后仍然是 unknown，不入列。
      final root = tempRoot('explicit_txt');
      final path = put(root, 'notes.docx', '这不是一个压缩包'.codeUnits);

      final s = await scanFileList([path], baseDepth: 0, ignoreContainers: true);
      expect(s.items, isEmpty);
    });

    test('默认不开：不传这个参数就还是老样子', () async {
      final root = tempRoot('explicit_default');
      final path = put(root, 'report.docx', ooxmlZip());

      final s = await scanFileList([path], baseDepth: 0);
      expect(s.items, isEmpty, reason: '默认必须保留容器防线');
    });
  });

  group('显式文件：分卷自动补齐', () {
    /// 造一套 `.zip.001/.002`，返回 `(root, 001 的路径)`。
    (Directory, String) twoVolumes(String tag) {
      final root = tempRoot(tag);
      final zip = realZip({'hello.txt': 'world'});
      final half = zip.length ~/ 2;
      final p1 = put(root, 'big.zip.001', zip.sublist(0, half));
      put(root, 'big.zip.002', zip.sublist(half));
      return (root, p1);
    }

    test('只点了 .001，也把 .002 一起解', () async {
      final (_, first) = twoVolumes('siblings');

      final s = await scanFileList([first],
          baseDepth: 0, expandSplitVolumes: true);

      expect(s.items, hasLength(1));
      expect(s.items.single.isSplit, isTrue);
      expect(s.items.single.parts, hasLength(2),
          reason: '单独一片 .001 在解码器眼里什么都不是');
    });

    test('不带这个开关时就是孤零零一片（对照组）', () async {
      final (_, first) = twoVolumes('siblings_off');

      final s = await scanFileList([first], baseDepth: 0);
      expect(s.items.single.parts, hasLength(1));
    });

    test('绝不把同目录**别的**包捎带进来', () async {
      // 这条是「选了文件就只解它」那条要求的边界：补的是同一个分卷家族的
      // 兄弟，不是「这个目录里的所有压缩包」。
      final (root, first) = twoVolumes('siblings_only');
      put(root, 'other.zip', realZip({'x': 'y'}));
      put(root, 'another.zip.001', realZip({'z': 'w'}));

      final s = await scanFileList([first],
          baseDepth: 0, expandSplitVolumes: true);

      // 只有 `big` 这一个家族。注意分卷条的 `fileName` 是**第一片的文件名**
      // （`ScanItem.fileName` 就是 `entryPath` 的 basename），所以要按 parts 断言
      // ——列表上显示的那个「剥掉卷号」的名字是 `AppState` 另一处算的。
      expect(s.items, hasLength(1));
      expect(s.items.single.isSplit, isTrue);
      expect(
        s.items.single.parts.map(p.basename).toList(),
        ['big.zip.001', 'big.zip.002'],
        reason: '同目录的 other.zip 与 another.zip.001 都不该被捎带进来',
      );
    });

    test('点的是普通单文件时什么都不补', () async {
      final root = tempRoot('siblings_plain');
      final path = put(root, 'solo.zip', realZip({'x': 'y'}));
      put(root, 'neighbour.zip', realZip({'x': 'y'}));

      final s = await scanFileList([path],
          baseDepth: 0, expandSplitVolumes: true);

      expect(namesOf(s), ['solo.zip']);
    });

    test('兄弟文件读不到也不影响用户点名的那一个', () async {
      final root = tempRoot('siblings_missing');
      // 只有 .001，.002 不存在 —— 家族校验会失败，退回单片
      final zip = realZip({'hello.txt': 'world'});
      final first = put(root, 'lonely.zip.001', zip.sublist(0, zip.length ~/ 2));

      final s = await scanFileList([first],
          baseDepth: 0, expandSplitVolumes: true);

      expect(s.items.single.parts, hasLength(1));
    });
  });

  group('显式文件的 depth 必须是 0', () {
    test('baseDepth 0 时每一行都是顶层，不带嵌套标记', () async {
      // `scanFileList` 的默认 baseDepth 是 1（为嵌套发现调的）。顶层用默认值
      // 会让每一行都显示成缩进一层 —— 这条钉住调用方别忘了显式传 0。
      final root = tempRoot('explicit_depth');
      final path = put(root, 'a.zip', realZip({'x': 'y'}));

      expect((await scanFileList([path], baseDepth: 0)).items.single.depth, 0);
      expect((await scanFileList([path])).items.single.depth, 1,
          reason: '不传就是 1，这是嵌套那条路的约定');
    });
  });
}
