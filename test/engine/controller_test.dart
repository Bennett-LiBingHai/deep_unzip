import 'dart:io';

import 'package:deep_unzip/engine/controller.dart';
import 'package:deep_unzip/engine/models.dart';
import 'package:deep_unzip/engine/protocol.dart';
import 'package:deep_unzip/engine/scanner.dart';
import 'package:deep_unzip/models/archive_file.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'zip_fixtures.dart';

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

/// 启动一个控制器，测试结束自动释放。
Future<EngineController> booted({
  Duration throttle = Duration.zero,
}) async {
  final c = EngineController(throttle: throttle);
  addTearDown(c.dispose);
  await c.start();
  return c;
}

void main() {
  // 每个 isolate 的启动有真实开销，超时给宽一点。
  void t(String name, Future<void> Function() body) =>
      test(name, body, timeout: const Timeout(Duration(seconds: 30)));

  group('握手与存活', () {
    t('start 完成即握手成功', () async {
      final c = await booted();
      expect(c.isRunning, isTrue);
    });

    t('重复 start 是空操作', () async {
      final c = await booted();
      await c.start();
      expect(c.isRunning, isTrue);
    });

    t('ping 能往返，且不同的 token 不会串台', () async {
      final c = await booted();
      await c.ping(1);
      await c.ping(2);
      await c.ping(1);
    });

    t('多个 ping 并发也不会互相吞掉', () async {
      final c = await booted();
      await Future.wait([c.ping(1), c.ping(2), c.ping(3)]);
    });

    t('ping 可以当作存活探测反复调用', () async {
      final c = await booted();
      for (var i = 0; i < 20; i++) {
        await c.ping(i);
      }
      expect(c.isRunning, isTrue);
    });
  });

  group('扫描往返', () {
    t('真目录 → 结果与直接调 scanner 一致', () async {
      final root = tempRoot('ctl_scan');
      put(root, 'a.zip', realZip({'x': 'y'}));
      put(root, 'sub/b.zip', realZip({'x': 'y'}));
      put(root, 'notes.txt', 'hi'.codeUnits);

      final expected = await scanDirectory(root.path);

      final c = await booted();
      final out = await c.scan(rootPath: root.path);

      expect([for (final i in out.summary.items) i.fileName],
          [for (final i in expected.items) i.fileName]);
      expect(out.summary.items, hasLength(2));
      expect(out.summary.containerSkipped, expected.containerSkipped);
      expect(out.summary.warnings, expected.warnings);
    });

    t('ScanItem 的复杂字段能完整穿过 isolate 边界', () async {
      final root = tempRoot('ctl_roundtrip');
      final zip = realZip({'hello.txt': 'world'});
      final half = zip.length ~/ 2;
      put(root, '备份.rar.001', zip.sublist(0, half));
      put(root, '备份.rar.002', zip.sublist(half));

      final c = await booted();
      final out = await c.scan(rootPath: root.path);
      final item = out.summary.items.single;

      expect(item.sniff.format, SniffFormat.zip);
      expect(item.sniff.header, isNotEmpty, reason: 'List<int> 也要能传过来');
      expect(item.split, isNotNull);
      expect(item.split!.parts, hasLength(2));
      expect(item.split!.kind, SplitKind.rawSplit);
      expect(item.flags, {ArchiveFlag.split, ArchiveFlag.fakeExtension});
    });

    t('elapsed 是正数', () async {
      final root = tempRoot('ctl_elapsed');
      put(root, 'a.zip', realZip({'x': 'y'}));

      final c = await booted();
      final out = await c.scan(rootPath: root.path);
      expect(out.elapsed, greaterThanOrEqualTo(Duration.zero));
    });

    t('目录不存在 → 正常完成 + 告警（不是异常）', () async {
      final c = await booted();
      final out = await c.scan(
        rootPath: p.join(Directory.systemTemp.path, 'duz_绝对没有这个目录'),
      );
      expect(out.summary.items, isEmpty);
      expect(out.summary.warnings.single, contains('目录不存在'));
    });

    t('depth 参数传到 ScanItem', () async {
      final root = tempRoot('ctl_depth');
      put(root, 'a.zip', realZip({'x': 'y'}));

      final c = await booted();
      final out = await c.scan(rootPath: root.path, depth: 2);
      expect(out.summary.items.single.depth, 2);
    });

    t('skipDirs 穿过 isolate 生效', () async {
      final root = tempRoot('ctl_skip');
      put(root, 'a.zip', realZip({'x': 'y'}));
      put(root, 'out_1/b.zip', realZip({'x': 'y'}));

      final c = await booted();
      final out = await c.scan(
        rootPath: root.path,
        skipDirs: {p.join(root.path, 'out_1')},
      );
      expect([for (final i in out.summary.items) i.fileName], ['a.zip']);
    });

    t('连跑两次扫描都能正常返回', () async {
      final root = tempRoot('ctl_twice');
      put(root, 'a.zip', realZip({'x': 'y'}));

      final c = await booted();
      final first = await c.scan(rootPath: root.path);
      final second = await c.scan(rootPath: root.path);
      expect(first.summary.items, hasLength(1));
      expect(second.summary.items, hasLength(1));
    });
  });

  group('并发与取消', () {
    t('已有任务在跑时再发起 → 明确报错，不是静默排队', () async {
      final root = tempRoot('ctl_busy');
      for (var i = 0; i < 200; i++) {
        put(root, 'f$i.zip', realZip({'x': 'y'}));
      }

      final c = await booted();
      final first = c.scan(rootPath: root.path);
      await expectLater(
        c.scan(rootPath: root.path),
        throwsA(isA<EngineException>()),
      );
      await first;
    });

    t('取消：正常完成，只是结果里多一条「已取消」', () async {
      final root = tempRoot('ctl_cancel');
      for (var i = 0; i < 400; i++) {
        put(root, 'f$i.zip', realZip({'x': 'y'}));
      }

      final c = await booted();
      final pending = c.scan(rootPath: root.path);
      await c.cancelScan();
      final out = await pending;

      // 取消不是错误。
      expect(out.summary.warnings.any((w) => w.contains('已取消')), isTrue);
      expect(out.summary.items.length, lessThan(400));
    });

    t('没有任务时取消是空操作', () async {
      final c = await booted();
      await c.cancelScan();
      expect(c.isRunning, isTrue);
    });
  });

  group('节流', () {
    t('throttle=0 时逐条送达', () async {
      final root = tempRoot('ctl_tick0');
      for (var i = 0; i < 350; i++) {
        put(root, 'f$i.zip', realZip({'x': 'y'}));
      }

      final c = await booted();
      final ticks = <ScanTick>[];
      c.onScanTick = ticks.add;
      final out = await c.scan(rootPath: root.path);

      expect(ticks, isNotEmpty);
      expect(ticks.last.found, out.summary.items.length);
      for (var i = 1; i < ticks.length; i++) {
        expect(ticks[i].files, greaterThanOrEqualTo(ticks[i - 1].files));
      }
    });

    t('默认节流下快速扫描被合并，且完成之后不再有残留 tick', () async {
      final root = tempRoot('ctl_tick125');
      put(root, 'a.zip', realZip({'x': 'y'}));

      final c = await booted(throttle: kProgressThrottle);
      final ticks = <ScanTick>[];
      c.onScanTick = ticks.add;
      await c.scan(rootPath: root.path);

      // 扫描比 125ms 快得多，所有 tick 都被合并进一个待发槽位；
      // 任务结束时那个槽位被丢弃，于是回调一次都没触发。
      expect(ticks, isEmpty);

      // 再等两倍节流窗口，确认那个残留 tick 真的不会迟到。
      await Future<void>.delayed(kProgressThrottle * 2);
      expect(ticks, isEmpty, reason: '完成之后冒出来的旧进度会把界面刷回去');
    });

    t('后台时不发事件', () async {
      final root = tempRoot('ctl_bg');
      for (var i = 0; i < 350; i++) {
        put(root, 'f$i.zip', realZip({'x': 'y'}));
      }

      final c = await booted();
      final ticks = <ScanTick>[];
      c.onScanTick = ticks.add;
      c.setForeground(false);
      await c.scan(rootPath: root.path);
      expect(ticks, isEmpty);
    });
  });

  group('释放', () {
    t('dispose 后 isRunning 为假', () async {
      final c = EngineController();
      await c.start();
      c.dispose();
      expect(c.isRunning, isFalse);
    });

    t('dispose 后不再被踩空断言', () async {
      final c = EngineController();
      await c.start();
      c.dispose();
      await expectLater(c.ping(), throwsA(isA<EngineException>()));
      await expectLater(
        c.scan(rootPath: Directory.systemTemp.path),
        throwsA(isA<EngineException>()),
      );
    });

    t('任务跑到一半被 dispose → 该任务以异常结束', () async {
      final root = tempRoot('ctl_killmid');
      for (var i = 0; i < 400; i++) {
        put(root, 'f$i.zip', realZip({'x': 'y'}));
      }

      final c = EngineController();
      await c.start();
      final pending = c.scan(rootPath: root.path);
      c.dispose();
      await expectLater(pending, throwsA(isA<EngineException>()));
    });

    t('重复 dispose 是空操作', () async {
      final c = EngineController();
      await c.start();
      c.dispose();
      c.dispose();
      expect(c.isRunning, isFalse);
    });
  });
}
