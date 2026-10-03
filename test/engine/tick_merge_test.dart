/// 三层节流的第一层：worker 侧的按时间丢样。
///
/// 第二层（主 isolate 的 8Hz 尾沿节流）在 `controller_test.dart` 的
/// 「节流」组里测 —— 扫描与解压共用同一个泛型 `_TickThrottle`，所以那组用例
/// 结论对两条路径都成立。
library;

import 'package:deep_unzip/engine/controller.dart' show kProgressThrottle;
import 'package:deep_unzip/engine/tick_merge.dart';
import 'package:deep_unzip/engine/worker.dart' show kExtractTickMerge;
import 'package:flutter_test/flutter_test.dart';

void main() {
  // 用真实值而不是造一个：`kExtractTickMerge` 与 `kProgressThrottle` 的
  // 大小关系本身是有约束的（见 worker.dart 里那条注释），拿真值测才能
  // 顺带盯住它。
  const window = Duration(milliseconds: 120);

  /// 从 [times] 里挑出会被发出的那些下标。
  List<int> emitted(List<Duration> times) {
    final m = TickMerger(window);
    final out = <int>[];
    for (var i = 0; i < times.length; i++) {
      if (m.shouldEmit(times[i])) out.add(i);
    }
    return out;
  }

  group('TickMerger', () {
    test('第一条必发 —— 哪怕它落在窗口之内', () {
      // 起点是 0 的话，天真的实现会把它当成「刚发过一条」而全部吃掉，
      // 于是一个 50ms 就跑完的任务一条进度都没有。
      expect(emitted([Duration.zero]), [0]);
      expect(emitted([const Duration(milliseconds: 1)]), [0]);
    });

    test('窗口内的后续采样被吃掉，窗口一满就放行', () {
      expect(
        emitted(const [
          Duration.zero,
          Duration(milliseconds: 10),
          Duration(milliseconds: 100),
          Duration(milliseconds: 119),
          Duration(milliseconds: 120),
        ]),
        [0, 4],
        reason: '恰好等于窗口间隔算「够了」，用 < 而不是 <= 判据',
      );
    });

    test('放行之后窗口从**放行那一刻**重新起算，不是从采样时刻', () {
      // 0 发了 → 100ms 的这条被吃掉 → 120ms 的这条发了。
      // 若错误地让被吃掉的那条也更新基准，250ms 这条就要等到 220ms 才发；
      // 这里的实现下，基准是 120ms，所以 240ms 就能发。
      expect(
        emitted(const [
          Duration.zero,
          Duration(milliseconds: 100),
          Duration(milliseconds: 120),
          Duration(milliseconds: 239),
          Duration(milliseconds: 240),
        ]),
        [0, 2, 4],
      );
    });

    test('密集采样下，发出的条数约等于 总时长 / 窗口', () {
      // 7-Zip 大文件里每写几 MB 报一次，实测量级在毫秒级间隔。这里模拟
      // 「每 5ms 一条、跑 1 秒」，发出的应该是个位数而不是 200 条。
      final times = [
        for (var ms = 0; ms <= 1000; ms += 5) Duration(milliseconds: ms),
      ];
      final got = emitted(times);
      expect(got.length, inInclusiveRange(8, 10));
      expect(times[got.first], Duration.zero);
      // 最后**发出去**的那条未必是最后**采样**的那条：尾部的残留样本要等
      // 窗口满。真实场景里这个尾巴由任务结束时的收尾补上（`EvExtractDone`
      // 会带来终值），所以丢样层不需要「末尾必发」。
      expect(times[got.last], greaterThanOrEqualTo(Duration(milliseconds: 880)));
      expect(times[got.last], lessThanOrEqualTo(const Duration(seconds: 1)));
    });

    test('单调递增的采样序列：发出的时刻间隔都 >= 窗口', () {
      final times = [
        for (var ms = 0; ms <= 2000; ms += 3) Duration(milliseconds: ms),
      ];
      final stamps = emitted(times).map((i) => times[i]).toList();
      for (var i = 1; i < stamps.length; i++) {
        expect(stamps[i] - stamps[i - 1], greaterThanOrEqualTo(window));
      }
    });

    test('够稀疏的采样一条都不丢', () {
      expect(
        emitted(const [
          Duration(seconds: 0),
          Duration(milliseconds: 500),
          Duration(seconds: 1),
          Duration(milliseconds: 1500),
          Duration(seconds: 2),
        ]),
        [0, 1, 2, 3, 4],
      );
    });

    test('换任务就换个实例 —— 新任务的第一条不会被旧实例吃掉', () {
      // 这正是「不提供 reset()，让实例生命周期等于任务生命周期」要保证的事。
      final m = TickMerger(window);
      expect(m.shouldEmit(Duration.zero), isTrue);
      expect(m.shouldEmit(const Duration(milliseconds: 10)), isFalse);

      // 新任务：换一个实例。同一个 10ms 的时刻在前一个实例里是被吃掉的。
      final next = TickMerger(window);
      expect(next.shouldEmit(const Duration(milliseconds: 10)), isTrue);
    });

    test('窗口为 0 时等于不合并', () {
      final m = TickMerger(Duration.zero);
      for (var ms = 0; ms < 5; ms++) {
        expect(m.shouldEmit(Duration(milliseconds: ms)), isTrue);
      }
    });

    test('前提：`now` 必须单调不减；时间倒流会让进度静默到追平为止', () {
      // 这不是「期望的行为」，是**已知且接受**的边界：`now` 的来源是
      // `Stopwatch.elapsed`，它单调不减，所以这条路径在真实调用里到不了。
      // 写出来是为了让「差值为负」这件事有据可查 —— 免得日后有人看到
      // `now - last < interval` 时以为漏了绝对值，顺手加一个反而把
      // 正常的快节奏丢样给放开了。
      final m = TickMerger(window);
      expect(m.shouldEmit(const Duration(seconds: 10)), isTrue);
      expect(m.shouldEmit(Duration.zero), isFalse, reason: '倒流期间不发声');
      expect(
        m.shouldEmit(const Duration(milliseconds: 10_120)),
        isTrue,
        reason: '追上 10s + 窗口 之后恢复',
      );
    });
  });

  group('与第二层的参数关系', () {
    test('第一层的窗口必须小于第二层', () {
      // 见 worker.dart 里 kExtractTickMerge 的说明：两层取同一个值的话，
      // 窗口边界会长期重合，某些 tick 会被两层连着吃掉。
      expect(
        kExtractTickMerge,
        lessThan(kProgressThrottle),
        reason: 'worker 合并窗口要比重建 Widget 树的那个间隔短一点',
      );
    });
  });
}
