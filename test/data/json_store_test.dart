import 'dart:convert';
import 'dart:io';

import 'package:deep_unzip/data/json_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../engine/zip_fixtures.dart';

/// [JsonStore] 的两件事：**写要原子**、**读要耐操**。
///
/// 「原子」测不出真正的时序（那要拔电），能测的是它的**可观察后果**：
/// 目标文件永远不是半截的，`rename` 之后 `.tmp` 不残留，同期多次写不会
/// 写出交织的内容。
///
/// 「耐操」直接测：文件不存在 / 空 / 截断 / 是别的东西，都该是 null 而不是
/// 异常 —— `main()` 是等着它读完才 `runApp` 的，抛一个出去就是启动白屏。
void main() {
  late Directory root;
  late JsonStore store;

  setUp(() {
    root = makeTempDir('json_store');
    store = JsonStore();
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  File file(String name) => File(p.join(root.path, name));

  group('读写往返', () {
    test('写进去什么就读出来什么', () async {
      final f = file('a.json');
      expect(await store.write(f, {'v': 1, 'list': [1, 2, 3]}), isTrue);

      expect(await store.read(f), {'v': 1, 'list': [1, 2, 3]});
    });

    test('覆盖写：旧内容不会留下任何碎片', () async {
      final f = file('a.json');
      await store.write(f, {'v': 1, 'big': 'x' * 200});
      await store.write(f, {'v': 2});

      final text = await f.readAsString();
      expect(jsonDecode(text), {'v': 2});
      // 直接看原始字节：旧那份的 200 个 x 一个都不该留 —— `writeAsString`
      // 是截断写的，但只有走 rename 才谈得上「保证」。
      expect(text.contains('x' * 200), isFalse);
    });

    test('目标目录不存在时会自己建', () async {
      final f = File(p.join(root.path, 'nested', 'deep', 'a.json'));
      expect(await store.write(f, {'v': 1}), isTrue);
      expect(await store.read(f), {'v': 1});
    });

    test('落盘后不留 .tmp', () async {
      final f = file('a.json');
      await store.write(f, {'v': 1});

      expect(File('${f.path}.tmp').existsSync(), isFalse);
      expect(
        root.listSync().map((e) => p.basename(e.path)).toList(),
        ['a.json'],
        reason: '目录里只该有目标文件一个',
      );
    });
  });

  group('读不回来一律 null，不抛', () {
    test('文件不存在', () async {
      expect(await store.read(file('nope.json')), isNull);
    });

    test('空文件', () async {
      final f = file('empty.json');
      f.writeAsStringSync('   \n');
      expect(await store.read(f), isNull);
    });

    test('截断的 JSON —— 写到一半被杀留下的那种', () async {
      final f = file('trunc.json');
      f.writeAsStringSync('{"v":1,"list":[1,2');
      expect(await store.read(f), isNull);
    });

    test('顶层不是 JSON 的文本', () async {
      final f = file('junk.json');
      f.writeAsStringSync('这不是 JSON');
      expect(await store.read(f), isNull);
    });
  });

  group('同期多次写不会互相踩', () {
    test('并发写同一路径 → 结果是最后发的那一次，且是完整的一份', () async {
      final f = file('race.json');

      // **先写大后写小**，而且要确定它们真的重叠：串行化一旦失效，先发的
      // 大写入会在后发的小写入 rename 之后再 rename 一次，读回来就是大的
      // 那份（顺序错乱），或者干脆是一段交织的垃圾。
      final futures = [
        store.write(f, {'seq': 0, 'pad': 'A' * 5000}),
        store.write(f, {'seq': 1, 'pad': 'B' * 5000}),
        store.write(f, {'seq': 2, 'pad': 'C' * 5000}),
        store.write(f, {'seq': 3, 'pad': 'D' * 5000}),
      ];
      expect(await Future.wait(futures), everyElement(isTrue));

      final decoded = await store.read(f) as Map;
      expect(decoded['seq'], 3, reason: '最后发的那次必须最后落盘');
      // 内容必须**自洽**：`seq` 与那串填充字符要来自同一次调用。
      expect(decoded['pad'], 'D' * 5000, reason: '写交织了：seq 与内容不是同一次写的');
    });

    test('一次写失败之后，后面每一次写都还正常', () async {
      // 用一个「目录」冒充文件路径：`rename` 到它上面必失败，而失败又不能
      // 把等待链卡死 —— 链上存的是已消化异常的 future，否则第一次失败会让
      // 后面每一次写都跟着短路，表现为「日志从此再也不落盘」。
      final dirAsFile = Directory(p.join(root.path, 'iamadir'))..createSync();
      expect(await store.write(File(dirAsFile.path), {'v': 1}), isFalse);

      final good = file('after.json');
      expect(await store.write(good, {'v': 2}), isTrue);
      expect(await store.read(good), {'v': 2});
    });

    test('写失败不抛，只回 false，且不残留 .tmp', () async {
      final dirAsFile = Directory(p.join(root.path, 'iamadir'))..createSync();

      expect(await store.write(File(dirAsFile.path), {'v': 1}), isFalse);
      expect(File('${dirAsFile.path}.tmp').existsSync(), isFalse);
    });
  });
}
