import 'package:deep_unzip/engine/progress_meter.dart';
import 'package:flutter_test/flutter_test.dart';

/// 时间从 t0 起的第 n 次调用用这个。
DateTime at(DateTime t0, Duration d) => t0.add(d);

void main() {
  final t0 = DateTime(2026, 10, 2, 12, 0, 0);

  group('构造与断言', () {
    test('alpha 必须落在 (0, 1]', () {
      expect(() => ProgressMeter(alpha: 0), throwsA(isA<AssertionError>()));
      expect(() => ProgressMeter(alpha: -0.1), throwsA(isA<AssertionError>()));
      expect(() => ProgressMeter(alpha: 1.5), throwsA(isA<AssertionError>()));
      expect(() => ProgressMeter(alpha: 1), returnsNormally);
    });

    test('初始状态', () {
      final m = ProgressMeter();
      expect(m.progress, 0);
      expect(m.speedBytesPerSecond, 0);
      expect(m.eta, isNull);
      expect(m.elapsedSince(t0), isNull);
      expect(m.snapshot().isIdle, isTrue);
      expect(m.snapshot().entryName, '');
      expect(m.snapshot().denominatorGrew, isFalse);
    });

    test('ScanProgress.idle 常量', () {
      const s = ScanProgress.idle();
      expect(s.isIdle, isTrue);
      expect(s.progress, 0);
      expect(s.denominatorGrew, isFalse);
    });
  });

  group('速度采样', () {
    test('第一次采样只立基准，不算速度', () {
      final m = ProgressMeter();
      m.update(doneBytes: 500, totalBytes: 1000, now: t0);
      expect(m.speedBytesPerSecond, 0);
      // 但进度是立刻可用的：速度需要两次采样，进度不需要。
      expect(m.progress, 0.5);
    });

    test('EWMA 平滑：alpha=0.5 时新值占一半', () {
      final m = ProgressMeter(alpha: 0.5);
      m.update(doneBytes: 0, totalBytes: 1000, now: t0);
      m.update(doneBytes: 500, totalBytes: 1000, now: at(t0, const Duration(seconds: 1)));
      expect(m.speedBytesPerSecond, 500); // 首个瞬时值直接采用

      m.update(doneBytes: 900, totalBytes: 1000, now: at(t0, const Duration(seconds: 2)));
      // 瞬时 400，0.5*400 + 0.5*500 = 450
      expect(m.speedBytesPerSecond, 450);
    });

    test('alpha=1 时不平滑，完全跟手', () {
      final m = ProgressMeter(alpha: 1);
      m.update(doneBytes: 0, totalBytes: 1000, now: t0);
      m.update(doneBytes: 500, totalBytes: 1000, now: at(t0, const Duration(seconds: 1)));
      m.update(doneBytes: 600, totalBytes: 1000, now: at(t0, const Duration(seconds: 2)));
      expect(m.speedBytesPerSecond, 100);
    });

    test('间隔小于 5ms 的采样被丢弃，且不推进基准时刻', () {
      final m = ProgressMeter(alpha: 1);
      m.update(doneBytes: 0, totalBytes: 100000, now: t0);

      // 100µs 后 —— 太近，丢弃。
      m.update(
        doneBytes: 90000,
        totalBytes: 100000,
        now: at(t0, const Duration(microseconds: 100)),
      );
      expect(m.speedBytesPerSecond, 0);
      // 但计数已经更新了（丢弃的只是时间数学，不是数据）。
      expect(m.snapshot().doneBytes, 90000);

      // 基准时刻仍是 t0，所以这里的间隔按整整 1s 算。
      m.update(
        doneBytes: 100000,
        totalBytes: 100000,
        now: at(t0, const Duration(seconds: 1)),
      );
      expect(m.speedBytesPerSecond, 100000);
    });

    test('恰好 5ms 的间隔不算「太近」', () {
      final m = ProgressMeter(alpha: 1);
      m.update(doneBytes: 0, totalBytes: 1000, now: t0);
      m.update(
        doneBytes: 5,
        totalBytes: 1000,
        now: at(t0, ProgressMeter.minSampleInterval),
      );
      expect(m.speedBytesPerSecond, 1000); // 5B / 0.005s
    });

    test('停滞时速度衰减到 0，不会一直显示上一个漂亮数字', () {
      final m = ProgressMeter(alpha: 0.5);
      m.update(doneBytes: 0, totalBytes: 100000, now: t0);
      m.update(doneBytes: 200, totalBytes: 100000, now: at(t0, const Duration(seconds: 1)));
      expect(m.speedBytesPerSecond, 200);

      m.update(doneBytes: 200, totalBytes: 100000, now: at(t0, const Duration(seconds: 2)));
      expect(m.speedBytesPerSecond, 100);

      m.update(doneBytes: 200, totalBytes: 100000, now: at(t0, const Duration(seconds: 3)));
      expect(m.speedBytesPerSecond, 50);

      // 一直停着 → 最终归零（中间会先掉到 1 以下被钳掉）。
      for (var i = 4; i < 20; i++) {
        m.update(doneBytes: 200, totalBytes: 100000, now: at(t0, Duration(seconds: i)));
      }
      expect(m.speedBytesPerSecond, 0);
    });

    test('整秒无间隔推进不会除以零', () {
      final m = ProgressMeter(alpha: 1);
      m.update(doneBytes: 0, totalBytes: 1000, now: t0);
      // 同一时刻（间隔 0 < 5ms）→ 丢
      m.update(doneBytes: 100, totalBytes: 1000, now: t0);
      expect(m.speedBytesPerSecond, 0);
    });
  });

  group('单调进度', () {
    test('分母变大时进度不倒退', () {
      final m = ProgressMeter();
      m.update(doneBytes: 100, totalBytes: 100, now: t0);
      expect(m.progress, 1.0);

      // 解完 100/100 之后冒出一个嵌套包，分母变成 200。
      m.update(doneBytes: 100, totalBytes: 200, now: at(t0, const Duration(seconds: 1)));
      expect(m.progress, 1.0, reason: '不能从 100% 掉回 50%');
      expect(m.snapshot().denominatorGrew, isTrue);
    });

    test('分母增长标记只在「已经到过 100%」时置位', () {
      final m = ProgressMeter();
      m.update(doneBytes: 50, totalBytes: 100, now: t0);
      m.update(doneBytes: 150, totalBytes: 300, now: at(t0, const Duration(seconds: 1)));
      expect(m.progress, closeTo(0.5, 1e-9));
      expect(m.snapshot().denominatorGrew, isFalse);
    });

    test('分母增长后能继续正常推进', () {
      final m = ProgressMeter();
      m.update(doneBytes: 100, totalBytes: 100, now: t0);
      m.update(doneBytes: 100, totalBytes: 200, now: at(t0, const Duration(seconds: 1)));
      m.update(doneBytes: 150, totalBytes: 200, now: at(t0, const Duration(seconds: 2)));
      expect(m.progress, 1.0); // 0.75 < 1.0，仍停在历史最高
      m.update(doneBytes: 200, totalBytes: 200, now: at(t0, const Duration(seconds: 3)));
      expect(m.progress, 1.0);
    });

    test('分母变*小*不算换任务，进度不归零、速度不清空', () {
      final m = ProgressMeter(alpha: 1);
      m.update(doneBytes: 0, totalBytes: 1000, now: t0);
      m.update(doneBytes: 400, totalBytes: 1000, now: at(t0, const Duration(seconds: 1)));
      expect(m.progress, 0.4);
      expect(m.speedBytesPerSecond, 400);

      // 跳过某个包 → 总工作量下调。这仍是同一个任务。
      m.update(doneBytes: 450, totalBytes: 500, now: at(t0, const Duration(seconds: 2)));
      expect(m.progress, 0.9, reason: '分母下调不该把进度打回 0');
      expect(m.speedBytesPerSecond, 50, reason: '速度也不该被重置');
    });

    test('totalBytes 为 0 时不产生进度', () {
      final m = ProgressMeter();
      m.update(doneBytes: 500, totalBytes: 0, now: t0);
      expect(m.progress, 0);
    });
  });

  group('计数器回退 = 换任务', () {
    test('doneBytes 回退后进度与速度都从零开始', () {
      final m = ProgressMeter(alpha: 1);
      m.update(doneBytes: 0, totalBytes: 1000, now: t0);
      m.update(doneBytes: 500, totalBytes: 1000, now: at(t0, const Duration(seconds: 1)));
      expect(m.progress, 0.5);
      expect(m.speedBytesPerSecond, 500);

      m.update(doneBytes: 10, totalBytes: 2000, now: at(t0, const Duration(seconds: 2)));
      expect(m.speedBytesPerSecond, 0, reason: '重启后第一次采样只立基准');
      expect(m.progress, closeTo(10 / 2000, 1e-9));
      expect(m.snapshot().denominatorGrew, isFalse);
    });

    test('重启后本次采样会重新立基准，elapsedSince 仍可用', () {
      final m = ProgressMeter();
      m.update(doneBytes: 100, totalBytes: 1000, now: t0);
      expect(m.elapsedSince(t0), isNotNull);
      m.update(doneBytes: 5, totalBytes: 1000, now: at(t0, const Duration(seconds: 1)));
      // 重启 + 本次采样 → 本次采样已立基准，所以又非 null 了。
      expect(m.elapsedSince(t0), isNotNull);
    });
  });

  group('ETA', () {
    test('速度为 0 时为 null（UI 显示 --）', () {
      final m = ProgressMeter();
      expect(m.eta, isNull);
      m.update(doneBytes: 0, totalBytes: 1000, now: t0);
      expect(m.eta, isNull);
    });

    test('分母为 0 时为 null', () {
      final m = ProgressMeter(alpha: 1);
      m.update(doneBytes: 0, totalBytes: 0, now: t0);
      m.update(doneBytes: 10, totalBytes: 0, now: at(t0, const Duration(seconds: 1)));
      expect(m.eta, isNull);
    });

    test('按剩余字节算', () {
      final m = ProgressMeter(alpha: 1);
      m.update(doneBytes: 0, totalBytes: 1000, now: t0);
      m.update(doneBytes: 100, totalBytes: 1000, now: at(t0, const Duration(seconds: 1)));
      // 100 B/s，剩 900 → 9s
      expect(m.eta, const Duration(seconds: 9));
    });

    test('已完成的瞬间是 Duration.zero 而不是 null', () {
      final m = ProgressMeter(alpha: 1);
      m.update(doneBytes: 0, totalBytes: 1000, now: t0);
      m.update(doneBytes: 1000, totalBytes: 1000, now: at(t0, const Duration(seconds: 1)));
      expect(m.eta, Duration.zero);
    });

    test('超过一天视为「算不出来」→ null', () {
      final m = ProgressMeter(alpha: 1);
      const total = 1000 * 86400 * 2;
      m.update(doneBytes: 0, totalBytes: total, now: t0);
      m.update(doneBytes: 1, totalBytes: total, now: at(t0, const Duration(seconds: 1)));
      expect(m.eta, isNull);
    });

    test('分母增长后 ETA 会变长（与单调进度相反，这是诚实的那个）', () {
      final m = ProgressMeter(alpha: 0.5);
      m.update(doneBytes: 0, totalBytes: 100, now: t0);
      m.update(doneBytes: 100, totalBytes: 100, now: at(t0, const Duration(seconds: 1)));
      expect(m.speedBytesPerSecond, 100);
      expect(m.eta, Duration.zero);

      // 冒出嵌套包：分母翻倍，进度条还停在 100%（单调），但 ETA 诚实地变长。
      m.update(doneBytes: 100, totalBytes: 200, now: at(t0, const Duration(seconds: 2)));
      expect(m.progress, 1.0);
      expect(m.speedBytesPerSecond, 50, reason: '这一秒没产出，速度衰减一半');
      expect(m.eta, const Duration(seconds: 2), reason: '还剩 100B / 50Bps');
    });
  });

  group('附属字段', () {
    test('不传的字段保留上一次的值', () {
      final m = ProgressMeter();
      m.update(
        doneBytes: 0,
        totalBytes: 100,
        depth: 2,
        doneCount: 3,
        entryName: 'a/b.txt',
        now: t0,
      );
      expect(m.snapshot().entryName, 'a/b.txt');
      expect(m.snapshot().depth, 2);
      expect(m.snapshot().doneCount, 3);

      m.update(doneBytes: 50, totalBytes: 100, now: at(t0, const Duration(seconds: 1)));
      expect(m.snapshot().entryName, 'a/b.txt');
      expect(m.snapshot().depth, 2);
      expect(m.snapshot().doneCount, 3);
    });

    test('传了空串 / 0 就真的改成空串 / 0', () {
      final m = ProgressMeter();
      m.update(doneBytes: 0, totalBytes: 100, depth: 2, entryName: 'x', now: t0);
      m.update(
        doneBytes: 0,
        totalBytes: 100,
        depth: 0,
        entryName: '',
        now: at(t0, const Duration(seconds: 1)),
      );
      expect(m.snapshot().entryName, '');
      expect(m.snapshot().depth, 0);
    });

    test('负数入参被钳到 0', () {
      final m = ProgressMeter();
      m.update(doneBytes: -5, totalBytes: -5, now: t0);
      expect(m.snapshot().doneBytes, 0);
      expect(m.snapshot().totalBytes, 0);
    });

    test('isIdle 的判据是「没有总量且没完成过任何包」', () {
      final m = ProgressMeter();
      expect(m.snapshot().isIdle, isTrue);
      m.update(doneBytes: 0, totalBytes: 100, doneCount: 0, now: t0);
      expect(m.snapshot().isIdle, isFalse);
    });
  });

  group('elapsedSince', () {
    test('采样前为 null，采样后按传入的 now 算', () {
      final m = ProgressMeter();
      expect(m.elapsedSince(t0), isNull);

      m.update(doneBytes: 0, totalBytes: 100, now: t0);
      // 不传 now 时取真实当前时间，所以要断言具体数值就必须自己传。
      expect(m.elapsedSince(t0, now: t0), Duration.zero);
      expect(
        m.elapsedSince(t0, now: at(t0, const Duration(seconds: 7))),
        const Duration(seconds: 7),
      );
    });
  });

  group('snapshot 与 reset', () {
    test('snapshot 是一份快照，之后 update 不影响它', () {
      final m = ProgressMeter(alpha: 1);
      m.update(doneBytes: 100, totalBytes: 1000, entryName: 'a', now: t0);
      final s = m.snapshot();
      expect(s.doneBytes, 100);
      expect(s.entryName, 'a');

      m.update(doneBytes: 900, totalBytes: 1000, entryName: 'b', now: at(t0, const Duration(seconds: 1)));
      expect(s.doneBytes, 100, reason: '快照必须与实例脱钩');
      expect(s.entryName, 'a');
      expect(m.snapshot().entryName, 'b');
    });

    test('reset 回到初始状态，可复用实例', () {
      final m = ProgressMeter(alpha: 1);
      m.update(doneBytes: 500, totalBytes: 1000, entryName: 'a', depth: 3, now: t0);
      m.update(doneBytes: 900, totalBytes: 1000, now: at(t0, const Duration(seconds: 1)));

      m.reset();
      expect(m.progress, 0);
      expect(m.speedBytesPerSecond, 0);
      expect(m.eta, isNull);
      expect(m.elapsedSince(t0), isNull);
      final s = m.snapshot();
      expect(s.doneBytes, 0);
      expect(s.totalBytes, 0);
      expect(s.entryName, '');
      expect(s.depth, 0);
      expect(s.doneCount, 0);
      expect(s.denominatorGrew, isFalse);
      expect(s.isIdle, isTrue);
    });

    test('reset 后能正常接新任务', () {
      final m = ProgressMeter(alpha: 1);
      m.update(doneBytes: 800, totalBytes: 1000, now: t0);
      m.reset();
      m.update(doneBytes: 0, totalBytes: 200, now: t0);
      m.update(doneBytes: 200, totalBytes: 200, now: at(t0, const Duration(seconds: 1)));
      expect(m.progress, 1.0);
      expect(m.speedBytesPerSecond, 200);
    });
  });

  group('toString', () {
    test('带上百分比与层级', () {
      final m = ProgressMeter();
      m.update(doneBytes: 25, totalBytes: 100, depth: 1, doneCount: 2, now: t0);
      final s = m.snapshot().toString();
      expect(s, contains('25/100'));
      expect(s, contains('25.0%'));
      expect(s, contains('depth=1'));
      expect(s, contains('done=2'));
    });
  });
}
