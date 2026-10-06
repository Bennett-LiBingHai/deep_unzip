/// 三层节流的第二层：主 isolate 上的尾沿节流器。
///
/// ## 为什么它有自己的测试文件，而扫描/解压两条路「共用同一个实例」这件事
///    还要在 `controller_test.dart` 里再验一遍
///
/// 这里测的是**机制**：窗口怎么合、后台怎么分岔、回到前台怎么补。那些用例不
/// 需要引擎，也不需要设备 —— 它们只喂 [TickThrottle] 一个 `int`。
///
/// `controller_test.dart` 里那组测的是**接线**：扫描的 tick 真的走到了它的
/// [TickThrottle.emit] 上。两件事分开验，是因为它们会各自坏：机制坏了（比如
/// 后台顺手把 `emit` 也发了）在这里红；接线坏了（比如控制器压根没把 tick 交给
/// 节流器）在那里红。中间那一段 —— 解压的后台那一路 —— 只有真机跑得起来
/// （要 `.so`），所以它只在 `AppState` 那一层用假引擎驱动（见
/// `test/providers/app_state_test.dart` 的「保活」组）。
library;

import 'package:deep_unzip/engine/tick_throttle.dart';
import 'package:flutter_test/flutter_test.dart';

/// 记账用的节流器：前后台可切，两条路各记各的。
class _Harness {
  _Harness({required bool background, required Duration delay}) {
    throttle = TickThrottle<int>(
      delay: delay,
      emit: ui.add,
      isForeground: () => _foreground,
      background: background ? notification.add : null,
    );
  }

  late final TickThrottle<int> throttle;

  /// 界面那一路收到的 tick。
  final List<int> ui = [];

  /// 后台那一路（前台服务通知）收到的 tick。
  final List<int> notification = [];

  bool _foreground = true;

  void setForeground(bool value) => _foreground = value;
}

void main() {
  // 真实的窗口是 125ms。这里取 20ms：够短，几个用例加起来等不到 0.5 秒；
  // 够长，不会被宿主机的调度抖动吃掉（等的是 40ms，两倍窗口）。
  const window = Duration(milliseconds: 20);
  const past = Duration(milliseconds: 40);

  /// 一个记账的节流器：前后台可切，两条路各记各的。
  _Harness build({bool background = true, Duration delay = window}) =>
      _Harness(background: background, delay: delay);

  group('前台：尾沿合并', () {
    test('窗口内的连跳只发最后一条', () async {
      final s = build();
      s.throttle.add(1);
      s.throttle.add(2);
      s.throttle.add(3);
      expect(s.ui, isEmpty, reason: '窗口没满之前一条都不发 —— 尾沿');

      await Future<void>.delayed(past);
      expect(s.ui, [3], reason: '发的是**最后**那条，不是第一条');
      expect(s.notification, isEmpty, reason: '前台时后台那一路不该被喂');
    });

    test('窗口为零时等于不合并（单测最爱的那一档）', () {
      final s = build(delay: Duration.zero);
      s.throttle.add(1);
      s.throttle.add(2);
      expect(s.ui, [1, 2]);
    });

    test('flush 把攒着的那条立刻发出去，之后的定时器不会再补一次', () async {
      final s = build();
      s.throttle.add(7);
      s.throttle.flush();
      expect(s.ui, [7]);

      await Future<void>.delayed(past);
      expect(s.ui, [7], reason: '定时器该被 flush 取消掉了，不能发第二条');
    });

    test('drop 之后攒着的那条永远不发（任务收尾必须调它）', () async {
      final s = build();
      s.throttle.add(9);
      s.throttle.drop();

      await Future<void>.delayed(past);
      expect(s.ui, isEmpty, reason: '晚到的旧进度会把界面刷回上一个任务');
    });
  });

  group('后台：界面那一路掐掉，通知那一路照走', () {
    test('后台时 emit 一条都不发，background 收到每一条', () async {
      final s = build();
      s.setForeground(false);
      s.throttle.add(1);
      s.throttle.add(2);

      await Future<void>.delayed(past);
      expect(s.ui, isEmpty, reason: '四棵树没人看，重建了是白烧电');
      // **每一条都到**，不做尾沿合并：合并是给「重建界面」省钱的，而这一路
      // 的消费者自己按两秒再节一层（见 AppState._lastKeepAliveAt）。在这里
      // 合并一次等于把用户看见的进度凭空延迟一个窗口。
      expect(s.notification, [1, 2]);
    });

    test('回到前台：flush 把后台期间的最后一条补发给界面，不是发给通知', () {
      final s = build();
      s.setForeground(false);
      s.throttle.add(1);
      s.throttle.add(2);
      expect(s.notification, [1, 2]);

      s.setForeground(true);
      s.throttle.flush();
      expect(s.ui, [2], reason: '界面追上锁屏那一刻的进度，不用等下一个 tick');
      expect(s.notification, [1, 2], reason: '补发的是**界面**那一路');
    });

    test('没配 background 时后台纯静默（扫描就是这一档）', () async {
      final s = build(background: false);
      s.setForeground(false);
      s.throttle.add(1);

      await Future<void>.delayed(past);
      expect(s.ui, isEmpty);
      expect(s.notification, isEmpty, reason: '扫描没有常驻通知可喂');
    });

    test('后台时 drop 掉，回到前台也不会把它补发出去', () {
      final s = build();
      s.setForeground(false);
      s.throttle.add(1);
      s.throttle.drop();

      s.setForeground(true);
      s.throttle.flush();
      expect(s.ui, isEmpty);
    });
  });
}
