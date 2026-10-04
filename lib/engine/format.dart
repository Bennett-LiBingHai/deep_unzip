/// 展示格式化。
///
/// 集中在这里的唯一理由：UI 的 `ArchiveFile.size` / `LogEntry.duration` /
/// `LogEntry.size` 都是**预格式化字符串**，页面按固定形状渲染，真实数据必须
/// 长成一样，否则列表会出现 `245 MB` 与 `245.0MB` 混排。
///
/// 已确认的既有形状（来自三个页面的渲染，并由 `test/engine/format_test.dart` 钉住）：
///
/// | 用法 | 形状 |
/// |---|---|
/// | `ArchiveFile.size` / `LogEntry.size` | `245 MB` / `1.2 GB` / `88 MB` |
/// | `LogEntry.duration` | `12.8s` / `45.1s` / `-`（未知） |
/// | `AppState.eta` | `12s` / `--`（未知） |
/// | `AppState.speed` | 双精度 MB/s，页面自己拼 `MB/s` |
/// | `home_screen` 的进度百分比 | `87%` |
library;

/// 1024 进制单位。
const List<String> _kUnits = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];

/// `245 MB` / `1.2 GB` / `512 B`。
///
/// 规则与既有形状一致：数值 < 10 保留一位小数，否则取整。
/// 字节级别不带小数（`512 B` 而不是 `512.0 B`）。
String formatBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  if (bytes < 1024) return '$bytes B';

  var v = bytes.toDouble();
  var u = 0;
  while (v >= 1024 && u < _kUnits.length - 1) {
    v /= 1024;
    u++;
  }
  final text = v < 10 ? v.toStringAsFixed(1) : v.toStringAsFixed(0);
  return '$text ${_kUnits[u]}';
}

/// `12.8s` / `1m23s` / `2h05m`；传 null 得 `-`（与 mock 里那条跳过记录的写法一致）。
String formatDuration(Duration? d) {
  if (d == null || d.isNegative) return '-';

  final seconds = d.inMilliseconds / 1000.0;
  if (seconds < 60) return '${seconds.toStringAsFixed(1)}s';

  final totalMinutes = d.inMinutes;
  if (totalMinutes < 60) {
    final rest = d.inSeconds - totalMinutes * 60;
    return '${totalMinutes}m${rest.toString().padLeft(2, '0')}s';
  }

  final hours = d.inHours;
  final minutes = totalMinutes - hours * 60;
  return '${hours}h${minutes.toString().padLeft(2, '0')}m';
}

/// ETA：整数秒（Home 的 `12s`），未知得 `--`。
String formatEta(Duration? d) {
  if (d == null || d.isNegative) return '--';

  final s = d.inSeconds;
  if (s < 60) return '${s}s';
  if (s < 3600) return '${s ~/ 60}m${(s % 60).toString().padLeft(2, '0')}s';
  return '${s ~/ 3600}h${((s % 3600) ~/ 60).toString().padLeft(2, '0')}m';
}

/// `87%`。入参按 0..1 给，越界会被夹住。
///
/// NaN 必须单独拦：`num.clamp` 内部用 `compareTo`，而 `NaN.compareTo(x)` 恒为正
/// （NaN 被定义为大于一切），所以 `double.nan.clamp(0, 1)` 返回的是 **1.0** 而不是
/// 0.0 —— 不拦的话「进度算不出来」会显示成自信的 `100%`。
String formatPercent(double fraction) {
  if (fraction.isNaN) return '0%';
  final pct = (fraction.clamp(0.0, 1.0) * 100).round();
  return '$pct%';
}

/// 千分位分组：`12345` → `12,345`。
///
/// 用于「N 个文件」这类计数 —— 递归解压很容易出现五位数条目，
/// 不分隔读不出来。
String formatCount(int n) {
  final negative = n < 0;
  final digits = n.abs().toString();
  final sb = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) sb.write(',');
    sb.write(digits[i]);
  }
  return negative ? '-$sb' : sb.toString();
}

/// 把字节/秒换算成 MB/s，供 `AppState.speed` 用（页面自己拼 `MB/s` 字样）。
double bytesPerSecondToMBps(double bytesPerSecond) =>
    bytesPerSecond <= 0 ? 0 : bytesPerSecond / (1024 * 1024);

/// `今天 14:32` / `昨天 22:18` / `09-30 20:33` — `LogEntry.time` 的既有形状。
///
/// [now] 显式传入是为了可测；页面调用时不传，取当前时间。
String formatLogTime(DateTime t, {DateTime? now}) {
  final ref = now ?? DateTime.now();
  final today = DateTime(ref.year, ref.month, ref.day);
  final that = DateTime(t.year, t.month, t.day);
  final diffDays = today.difference(that).inDays;

  final hh = t.hour.toString().padLeft(2, '0');
  final mm = t.minute.toString().padLeft(2, '0');

  if (diffDays == 0) return '今天 $hh:$mm';
  if (diffDays == 1) return '昨天 $hh:$mm';

  final mo = t.month.toString().padLeft(2, '0');
  final dd = t.day.toString().padLeft(2, '0');
  return '$mo-$dd $hh:$mm';
}

/// `2026-10-02` — 给密码库条目的 `lastUsed` 用。
String formatDate(DateTime t) {
  final mo = t.month.toString().padLeft(2, '0');
  final dd = t.day.toString().padLeft(2, '0');
  return '${t.year}-$mo-$dd';
}
