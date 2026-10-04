import 'dart:convert';
import 'dart:io';

import 'package:deep_unzip/data/json_store.dart';
import 'package:deep_unzip/data/log_repo.dart';
import 'package:deep_unzip/data/persist.dart';
import 'package:deep_unzip/models/log_entry.dart';
import 'package:flutter_test/flutter_test.dart';

import '../engine/zip_fixtures.dart';

/// 日志这份数据最要紧的一条是**时间**。
///
/// `LogEntry.time` 是给人看的串，`今天 14:32` 只在**写那条日志的当天**成立。
/// 直接把它存下来、隔天读回来，一条三天前的失败会显示成今天刚发生的 ——
/// 用户会以为刚才解压出了毛病，跑去重装。所以存的是 epoch，加载时重算。
/// 这组测试的重心就在这里。
void main() {
  late Directory root;
  late File file;
  late LogRepo repo;

  setUp(() {
    root = makeTempDir('log_repo');
    file = File('${root.path}${Platform.pathSeparator}logs.json');
    repo = LogRepo(JsonStore(), file);
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  /// 把日志按「给用户看」的形状造一条。
  LogEntry entry(
    String name, {
    LogStatus status = LogStatus.success,
    String time = '今天 14:32',
    DateTime? at,
    List<String> tags = const ['3 项'],
  }) {
    return LogEntry(
      name: name,
      status: status,
      size: '1.2 MB',
      time: time,
      duration: '0.8s',
      tags: tags,
      at: at,
    );
  }

  group('往返', () {
    test('没有文件时是空列表，不是异常', () async {
      expect(await repo.load(), isEmpty);
    });

    test('六个字段原样回来', () async {
      await repo.save([
        entry('a.zip', status: LogStatus.failed, tags: ['炸弹防护', '解压失败']),
      ]);

      final back = await repo.load();
      expect(back, hasLength(1));
      expect(back.single.name, 'a.zip');
      expect(back.single.status, LogStatus.failed);
      expect(back.single.size, '1.2 MB');
      expect(back.single.duration, '0.8s');
      expect(back.single.tags, ['炸弹防护', '解压失败']);
    });

    test('顺序不动 —— 最新的在前是靠顺序表达的', () async {
      await repo.save([entry('新'), entry('中'), entry('旧')]);
      expect((await repo.load()).map((e) => e.name).toList(), ['新', '中', '旧']);
    });
  });

  group('时间是重点：存 epoch，读回来重算', () {
    test('三天前的日志不会显示成「今天」', () async {
      final at = DateTime.now().subtract(const Duration(days: 3));
      // `time` 故意写成写那条日志当天的样子 —— 正是存 str 会踩的坑。
      await repo.save([entry('旧包.7z', time: '今天 09:15', at: at)]);

      final back = await repo.load();
      expect(back.single.time, isNot(contains('今天')),
          reason: '存字符串的话，三天前的失败会显示成今天刚发生的');
      expect(back.single.time, isNot(contains('昨天')));

      // 钉住实际形状：`MM-DD HH:mm`，日期取自 `at`。
      final mo = at.month.toString().padLeft(2, '0');
      final dd = at.day.toString().padLeft(2, '0');
      final hh = at.hour.toString().padLeft(2, '0');
      final mm = at.minute.toString().padLeft(2, '0');
      expect(back.single.time, '$mo-$dd $hh:$mm');
    });

    test('今天的日志仍然是「今天 HH:mm」', () async {
      final at = DateTime.now();
      await repo.save([entry('刚解的.zip', time: '别的内容', at: at)]);

      final hh = at.hour.toString().padLeft(2, '0');
      final mm = at.minute.toString().padLeft(2, '0');
      expect((await repo.load()).single.time, '今天 $hh:$mm');
    });

    test('没有 at 的老条目 → 用存下来的那串兜底，不显示成 00:00', () async {
      await repo.save([entry('老条目', time: '今天 14:32')]); // at 为 null
      expect((await repo.load()).single.time, '今天 14:32');
    });

    test('epoch 是真的落进了文件，不是只存在内存里', () async {
      final at = DateTime.fromMillisecondsSinceEpoch(1759500000000);
      await repo.save([entry('x.zip', at: at)]);

      final decoded =
          jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
      final raw = (decoded['entries'] as List).single as Map;
      expect(raw['at'], 1759500000000);
    });
  });

  group('硬顶 —— 与用户设的保留条数无关的那道', () {
    test('默认不按 300 截：用户调到 1000 时磁盘上必须真有那么多', () async {
      // 「留几条」的权威在 `AppState._maxLogs`（跟着设置走）。仓库这一层要是
      // 还自己截一刀，用户把上限调到 1000 之后会发现磁盘上永远只有 300 ——
      // 重启一次就少掉 700 条，而且看不出是谁丢的。
      await repo.save([for (var i = 0; i < 500; i++) entry('第 $i 个')]);

      final decoded =
          jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
      expect(decoded['entries'] as List, hasLength(500));
    });

    test('默认硬顶 = 用户能填的最大条数 —— 撞不到用户没设过的上限', () async {
      // 这两个数**就是同一个**（仓库的默认值取 `kMaxMaxLogs`）。要是有人给
      // 仓库另设一个更小的数，用户把上限拉到 5000 之后会发现磁盘上永远只有
      // 那个数那么多 —— 重启一次少一批，还看不出是谁丢的。
      await repo.save([
        for (var i = 0; i < kMaxMaxLogs + 500; i++) entry('第 $i 个'),
      ]);

      final decoded =
          jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
      expect(decoded['entries'] as List, hasLength(kMaxMaxLogs));
    });

    test('超过硬顶的那部分不写盘，留最新的', () async {
      final capped = LogRepo(JsonStore(), file, maxEntries: 300);
      await capped.save([for (var i = 0; i < 350; i++) entry('第 $i 个')]);

      final decoded =
          jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
      final entries = decoded['entries'] as List;
      expect(entries, hasLength(300));
      expect((entries.first as Map)['name'], '第 0 个', reason: '最新的在前，从头留');
      expect((entries.last as Map)['name'], '第 299 个');
    });

    test('读的时候也封顶 —— 文件被手改成一万条也不炸', () async {
      // 封顶的理由：`main()` 是等这份日志读完才 `runApp` 的，照着一个被手改
      // 过的文件分配内存就是启动即死。
      file.writeAsStringSync(jsonEncode({
        'v': 1,
        'entries': [
          for (var i = 0; i < kMaxMaxLogs + 2000; i++)
            {'name': '第 $i 个', 'status': 'success', 'size': '-', 'time': 'x',
             'duration': '-', 'tags': <String>[]},
        ],
      }));

      expect(await repo.load(), hasLength(kMaxMaxLogs));
    });
  });

  group('坏数据丢掉，不牵连别的', () {
    test('认不出的状态整条丢 —— 猜出来会造出永远筛不到的条目', () async {
      file.writeAsStringSync(jsonEncode({
        'v': 1,
        'entries': [
          {'name': '好的', 'status': 'failed', 'size': '-', 'time': 't',
           'duration': '-', 'tags': <String>[]},
          {'name': '状态没见过的', 'status': 'exploded', 'size': '-',
           'time': 't', 'duration': '-', 'tags': <String>[]},
          {'name': '没有状态的', 'size': '-', 'time': 't', 'duration': '-',
           'tags': <String>[]},
        ],
      }));

      final back = await repo.load();
      expect(back.map((e) => e.name).toList(), ['好的']);
    });

    test('版本号对不上 → 空列表', () async {
      file.writeAsStringSync(jsonEncode({'v': 99, 'entries': []}));
      expect(await repo.load(), isEmpty);
    });

    test('文件截断 → 空列表，不抛', () async {
      file.writeAsStringSync('{"v":1,"entries":[{"name":"a"');
      expect(await repo.load(), isEmpty);
    });
  });
}
