/// 三层节流的**第一层**：worker 侧的按时间丢样。
///
/// ## 三层各管一段，缺一不可
///
/// | 层 | 在哪 | 省的是什么 |
/// |---|---|---|
/// | 1. 丢样 | worker，[TickMerger] | **跨 isolate 消息**：每次 `send` 都要序列化、排队、唤醒对端 |
/// | 2. 节流 | 主 isolate，`TickThrottle` 的尾沿定时器（8Hz） | **重建四棵 Widget 树**：四个页面都在 `IndexedStack` 里，各自包了一层 `ListenableBuilder` |
/// | 3. 标脏 | 主 isolate，`setForeground(false)` | **后台时不重建界面**：Activity 不可见，重建了也没人看 |
///
/// 第 3 层有一个**例外**：解压进度还有一份喂前台服务通知的（`TickThrottle` 的
/// `background` 那一路）。它不重建任何东西，而且在后台比在前台更重要 —— 那时
/// 通知是用户唯一还看得见的东西。
///
/// 为什么 1 和 2 不能合并成一层：它们的**理由不同**，所以合理的参数也不同 ——
/// 第 1 层的成本随「7-Zip 报得有多密」变，第 2 层的成本随「界面上挂了多重的
/// 树」变。把两者调成同一个数，总有一边是被迫将就的。
///
/// ## 时间由调用方传入
///
/// 和 `ProgressMeter.update` 的 `now` 参数同一条思路：内部不调 `Stopwatch` /
/// `DateTime.now()`，单测才能喂假时间来断言，而不是靠 sleep 去等真实时间。
library;

/// 按时间窗口丢样：窗口内只发**第一条**。
///
/// 每次任务构造一个。上一个任务留下的采样时刻会让新任务的第一条进度被吃掉，
/// 所以刻意**不**提供 `reset()` —— 让实例的生命周期等于任务的生命周期，
/// 是比「记得调 reset」更不容易出错的写法。
class TickMerger {
  TickMerger(this.interval);

  /// 合并窗口。见 `kExtractTickMerge`。
  final Duration interval;

  Duration? _lastSent;

  /// [now] 这个时刻该不该发？该发则记下时刻并返回 true。
  ///
  /// **第一条必发**（`_lastSent` 为 null）。这一点是刻意的：天真的写法把起点
  /// 初始化成 `Duration.zero`，于是 `now - lastSent < interval` 对第一条永远
  /// 成立（`now` 从 0 开始计时）—— 总耗时不到一个窗口的短任务会**一条进度都
  /// 不发**，进度条从 0 直接跳到结束。发第一条的代价是每次任务多一条消息。
  ///
  /// **[`now`] 必须单调不减** —— 来源是 `Stopwatch.elapsed`，天然满足。
  /// 真的倒流的话差值算出来是负数，会一直 `false` 到时钟追平为止；刻意
  /// 不加绝对值兜底，因为那会把「采样变密」时的正常丢样一起放开
  /// （边界用例见 `tick_merge_test.dart`）。
  bool shouldEmit(Duration now) {
    final last = _lastSent;
    if (last != null && now - last < interval) return false;
    _lastSent = now;
    return true;
  }
}
