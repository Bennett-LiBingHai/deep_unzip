/// 历史日志的读写。落在应用私有目录里的一份 JSON 上。
///
/// ## 为什么不放 shared_preferences
///
/// 一个 XML 里塞 300 条带标签的日志，每次读都要把整个 XML 解析成内存里的
/// Map —— 而它只增不减地长。独立文件 + 原子写（[JsonStore]）更合适：读是
/// 启动时一次，写是追加一条时整份覆盖，两者都不需要随机访问。
///
/// ## 时间存的是 epoch，不是那串「今天 14:32」
///
/// 理由见 `LogEntry.at` 的注释：格式化后的串只在当天成立。这里额外把
/// 原始串也存下来当兜底 —— 万一 `at` 缺失（更早的版本写的、被手改过的
/// 文件），至少还能显示原样，而不是「今天 00:00」。
library;

import 'dart:io';

import '../engine/format.dart';
import '../models/log_entry.dart';
import 'json_store.dart';
import 'persist.dart';

class LogRepo {
  /// 具名参数写在 `_maxEntries` 上、调用点却用公开名 `maxEntries:` ——
  /// 这是 Dart 对私有字段形参的写法（`{this._maxEntries}` 声明合法，暴露给
  /// 调用点的名字去掉下划线）。
  ///
  /// 默认值取 [kMaxMaxLogs]（用户能填的最大条数），不是另设一道数。理由：没有
  /// 哪一个**合法**的档能超过它，所以「用户填得出多少」和「磁盘上那份最多能
  /// 有多少」是同一件事 —— 各写一个数就得靠注释和测试盯着它们别走散。
  LogRepo(this._store, this._file, {this._maxEntries = kMaxMaxLogs});

  final JsonStore _store;
  final File _file;

  /// 封顶条数。它跟用户设的保留条数**不是**一回事 ——
  /// 「留几条」由 `AppState._maxLogs` 说了算，这里只防一种情况：**磁盘上那份
  /// 文件被手改过**。没有它的话，一个一百万条的文件会在 `main()` 等 `runApp`
  /// 的那条路上被整个解析进内存。
  ///
  /// 测试里会传一个小值来验封顶本身。
  final int _maxEntries;

  static const int _schemaVersion = 1;

  /// 读回日志，最新的在前。
  ///
  /// 任何读不出来的情况都返回空列表：日志是**诊断材料**，为它把启动流程
  /// 拖垮是本末倒置（`main()` 是等着它才 `runApp` 的）。
  Future<List<LogEntry>> load() async {
    final decoded = await _store.read(_file);
    if (decoded is! Map) return const [];
    if (decoded['v'] != _schemaVersion) return const [];
    final raw = decoded['entries'];
    if (raw is! List) return const [];

    final out = <LogEntry>[];
    for (final e in raw) {
      if (e is! Map) continue;
      final entry = _decodeEntry(e);
      if (entry != null) out.add(entry);
      if (out.length >= _maxEntries) break;
    }
    return out;
  }

  /// 整份覆盖写。失败会抛，由 `DeviceStore` 决定要不要吞。
  ///
  /// 交上来多少写多少 —— 该留几条是调用方（`AppState`）已经决定过的事，
  /// 这里再截一刀只会让「用户设了 1000 条、磁盘上却只有 300」这种账对不上。
  /// 唯一的例外是 [_maxEntries] 那道硬顶。
  Future<void> save(List<LogEntry> logs) {
    final capped = logs.length > _maxEntries ? logs.sublist(0, _maxEntries) : logs;
    return _store.write(_file, {
      'v': _schemaVersion,
      'entries': [
        for (final e in capped)
          {
            'name': e.name,
            'status': e.status.name,
            'size': e.size,
            // 时间的**两个**表示：epoch 用来重算，原串用来兜底。
            if (e.at != null) 'at': e.at!.millisecondsSinceEpoch,
            'time': e.time,
            'duration': e.duration,
            'tags': e.tags,
          },
      ],
    }).then((ok) {
      if (!ok) throw const FileSystemException('日志落盘失败');
    });
  }

  LogEntry? _decodeEntry(Map raw) {
    final name = raw['name'];
    if (name is! String) return null;

    final status = _decodeStatus(raw['status']);
    if (status == null) return null;

    final size = raw['size'];
    final duration = raw['duration'];
    final tags = raw['tags'];
    final atMs = raw['at'];

    // `at` 在就重算 —— 这是跨天之后仍显示正确日期的唯一途径。
    final at = atMs is int ? DateTime.fromMillisecondsSinceEpoch(atMs) : null;
    final storedTime = raw['time'];
    final time = at != null
        ? formatLogTime(at)
        : (storedTime is String ? storedTime : '');

    return LogEntry(
      name: name,
      status: status,
      size: size is String ? size : '-',
      time: time,
      duration: duration is String ? duration : '-',
      tags: tags is List
          ? [for (final t in tags) if (t is String) t]
          : const [],
      at: at,
    );
  }

  /// 认不出的状态直接丢这条，不猜。
  ///
  /// 猜的代价是：日志页按状态筛选时出现一批「既不是成功也不是失败」的条目，
  /// 而筛选按钮里根本没有它们 —— 用户永远点不到、也清不掉。
  LogStatus? _decodeStatus(Object? raw) {
    if (raw is! String) return null;
    for (final s in LogStatus.values) {
      if (s.name == raw) return s;
    }
    return null;
  }
}
