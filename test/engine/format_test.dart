import 'package:deep_unzip/engine/format.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('formatBytes：必须与页面习惯的形状同形', () {
    test('UI 里出现过的每一个值都要还原得一模一样', () {
      // 这些是页面渲染时习惯的形状（原先由 mock 数据示范，那份数据已删；
      // 值本身是 UI 的既有契约，不能变）。
      expect(formatBytes(245 * 1024 * 1024), '245 MB');
      expect(formatBytes(88 * 1024 * 1024), '88 MB');
      expect(formatBytes(12 * 1024 * 1024), '12 MB');
      expect(formatBytes(320 * 1024 * 1024), '320 MB');
      expect(formatBytes(45 * 1024 * 1024), '45 MB');
      expect(formatBytes(56 * 1024 * 1024), '56 MB');
      expect(formatBytes((1.2 * 1024 * 1024 * 1024).round()), '1.2 GB');
    });

    test('小于 10 保留一位小数，否则取整', () {
      expect(formatBytes(1024 * 1024), '1.0 MB');
      expect(formatBytes(9.5 * 1024 * 1024 ~/ 1), '9.5 MB');
      expect(formatBytes(10 * 1024 * 1024), '10 MB');
      expect(formatBytes(1023 * 1024 * 1024), '1023 MB');
    });

    test('字节级别不带小数', () {
      expect(formatBytes(1), '1 B');
      expect(formatBytes(512), '512 B');
      expect(formatBytes(1023), '1023 B');
      expect(formatBytes(1024), '1.0 KB');
    });

    test('0 与负数', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(-1), '0 B');
    });

    test('单位递进到 TB', () {
      expect(formatBytes(1024 * 1024 * 1024 * 1024 * 2), '2.0 TB');
    });
  });

  group('formatDuration：LogEntry.duration 的形状', () {
    test('一分钟以内保留一位小数加 s', () {
      expect(formatDuration(const Duration(milliseconds: 12800)), '12.8s');
      expect(formatDuration(const Duration(milliseconds: 45100)), '45.1s');
      expect(formatDuration(const Duration(milliseconds: 2100)), '2.1s');
      expect(formatDuration(const Duration(milliseconds: 560)), '0.6s');
    });

    test('超过一分钟换成 m/s', () {
      expect(formatDuration(const Duration(seconds: 83)), '1m23s');
      expect(formatDuration(const Duration(seconds: 60)), '1m00s');
    });

    test('超过一小时换成 h/m', () {
      expect(formatDuration(const Duration(hours: 2, minutes: 5)), '2h05m');
    });

    test('null / 负数 → `-`（mock 里那条跳过记录就是 `-`）', () {
      expect(formatDuration(null), '-');
      expect(formatDuration(const Duration(seconds: -1)), '-');
    });
  });

  group('formatEta：AppState.eta 的形状', () {
    test('整数秒加 s', () {
      expect(formatEta(const Duration(seconds: 12)), '12s');
      expect(formatEta(const Duration(milliseconds: 12900)), '12s');
    });

    test('未知 → `--`（与 AppState 初值一致）', () {
      expect(formatEta(null), '--');
      expect(formatEta(const Duration(seconds: -1)), '--');
    });

    test('分钟与小时', () {
      expect(formatEta(const Duration(seconds: 83)), '1m23s');
      expect(formatEta(const Duration(seconds: 3700)), '1h01m');
    });

    test('0 秒', () {
      expect(formatEta(Duration.zero), '0s');
    });
  });

  group('formatPercent', () {
    test('四舍五入到整数', () {
      expect(formatPercent(0.87), '87%');
      expect(formatPercent(0), '0%');
      expect(formatPercent(1), '100%');
    });

    test('越界被夹住', () {
      expect(formatPercent(-0.5), '0%');
      expect(formatPercent(1.7), '100%');
      expect(formatPercent(double.nan), '0%');
    });
  });

  group('formatCount', () {
    test('千分位', () {
      expect(formatCount(0), '0');
      expect(formatCount(999), '999');
      expect(formatCount(1000), '1,000');
      expect(formatCount(12345), '12,345');
      expect(formatCount(1234567), '1,234,567');
    });

    test('负数', () {
      expect(formatCount(-1234), '-1,234');
    });
  });

  group('bytesPerSecondToMBps', () {
    test('换算', () {
      expect(bytesPerSecondToMBps(0), 0);
      expect(bytesPerSecondToMBps(-5), 0);
      expect(bytesPerSecondToMBps(1024 * 1024 * 5), 5.0);
    });

    test('Home 页面拼出的 `5.0 MB/s` 形状', () {
      final text = bytesPerSecondToMBps(1024 * 1024 * 5).toStringAsFixed(1);
      expect(text, '5.0');
    });
  });

  group('formatLogTime', () {
    final now = DateTime(2026, 10, 2, 15, 30);

    test('今天', () {
      expect(formatLogTime(DateTime(2026, 10, 2, 14, 32), now: now), '今天 14:32');
      expect(formatLogTime(DateTime(2026, 10, 2, 0, 5), now: now), '今天 00:05');
    });

    test('昨天', () {
      expect(formatLogTime(DateTime(2026, 10, 1, 22, 18), now: now), '昨天 22:18');
    });

    test('更早用 MM-DD', () {
      expect(formatLogTime(DateTime(2026, 9, 30, 20, 33), now: now), '09-30 20:33');
      expect(formatLogTime(DateTime(2026, 10, 1, 9, 15), now: now), '昨天 09:15');
    });

    test('跨天但不满 24 小时的边界（只比日历日）', () {
      // 昨天 23:59 距现在不到 24 小时，但按日历算就是「昨天」。
      final ref = DateTime(2026, 10, 2, 0, 30);
      expect(
        formatLogTime(DateTime(2026, 10, 1, 23, 59), now: ref),
        '昨天 23:59',
      );
    });
  });

  group('formatDate', () {
    test('YYYY-MM-DD', () {
      expect(formatDate(DateTime(2026, 10, 2)), '2026-10-02');
      expect(formatDate(DateTime(2026, 1, 9)), '2026-01-09');
    });
  });
}
