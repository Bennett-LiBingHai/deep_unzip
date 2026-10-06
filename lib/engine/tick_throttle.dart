/// 三层节流的**第二层**：主 isolate 上的尾沿节流器。
///
/// ## 为什么是一个公开的单独文件
///
/// 理由与 `tick_merge.dart` 一模一样：这一层的行为**在 Windows 上驱动不起来**
/// —— 真正要被它处理的是解压进度，而解压要过原生引擎（只有 Android 有 `.so`）。
/// 把它从 `controller.dart` 里挪出来做成公开类，就能像 `TickMerger` 那样直接
/// 喂事件进去断言，不必为了验「后台那一路还走不走」去等一台真机。
///
/// ## 后台那一档：不是「什么都不做」
///
/// 后台时 `emit` 整条掐掉（见 [isForeground]），但 [background] 那一路照走。
/// 两路的区别是**给谁看**：
///
/// - `emit` 喂的是界面。四个页面都在 `IndexedStack` 里、各自包了一层
///   `ListenableBuilder`，发一次就重建四棵树 —— 而此刻 Activity 不可见，
///   重建了没人看，纯是白烧电。
/// - `background` 喂的是**前台服务那条常驻通知**。它恰恰相反：后台时界面全
///   黑了，这条通知是用户唯一还能看到「它还在动」的地方。断了它，锁屏期间的
///   进度就冻在锁屏那一刻的数字上，一冻十几分钟。
///
/// [background] 为 `null` 表示这一档不存在的（扫描就是这一档：扫描没有常驻
/// 通知，后台时界面和通知都没人看，发出去纯是浪费）。
///
/// ## 一次只喂一路
///
/// 前台时走 `emit` 不走 `background`，后台时反过来 —— 同一份进度不会在两边各
/// 被处理一遍（否则回到前台的那一瞬间，通知会被同一份进度推两条内容一模一样的
/// 更新）。回到前台时 [TickThrottle.flush] 会把后台期间攒下的最后一条补发给
/// `emit`，界面因此追上进度，不会停在锁屏那一刻。
library;

import 'dart:async';

/// 尾沿节流器：窗口内多次 [add] 只会在窗口末尾发出**最后一条**。
///
/// 尾沿而不是首沿是刻意的。首沿会让第一条立刻显示、之后每 125ms 才更新，
/// 而尾沿保证最后一条进度一定会发出去 —— 否则进度条会停在半路（后面没有
/// 更多 tick 来把它顶到 100%）。
///
/// 抽成泛型类是因为扫描与解压都要它。两处各写一遍 20 行状态机，
/// 迟早会在其中一处修 bug 而忘了另一处。
class TickThrottle<T extends Object> {
  TickThrottle({
    required this.delay,
    required this.emit,
    required this.isForeground,
    this.background,
  });

  final Duration delay;
  final void Function(T tick) emit;

  /// 后台时走的那一路。为 `null` 时后台什么都不发（见文件头）。
  final void Function(T tick)? background;

  /// 后台时 `emit` 不发，只标脏（见 [EngineController.setForeground] 的说明）。
  final bool Function() isForeground;

  T? _pending;
  Timer? _timer;

  void add(T tick) {
    // 攒着的那一份两种情况下都要更新：回到前台时它会被补发出去，
    // 后台时它是通知的下一条内容。
    _pending = tick;

    if (!isForeground()) {
      background?.call(tick);
      return;
    }

    if (delay <= Duration.zero) {
      flush();
      return;
    }
    _timer ??= Timer(delay, flush);
  }

  void flush() {
    _timer?.cancel();
    _timer = null;
    final tick = _pending;
    _pending = null;
    if (tick != null) emit(tick);
  }

  /// 丢掉攒着的 tick。任务的结束事件到来时**必须**调：否则定时器稍后触发，
  /// 会把界面刷回上一个任务的旧进度。
  void drop() {
    _timer?.cancel();
    _timer = null;
    _pending = null;
  }
}
