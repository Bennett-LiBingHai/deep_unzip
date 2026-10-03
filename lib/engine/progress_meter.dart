/// 进度数学：EWMA 速度、ETA、单调进度。
///
/// ## 为什么在**主** isolate 算，而不是在 worker 里
///
/// worker 只发原始计数（`doneBytes` / `totalBytes` / `entryName`），一切时间
/// 数学都在这里做。理由有两个：
///
/// 1. **可测**。worker 里跑的东西依赖 isolate 消息，单测要搭一整套夹具；
///    这里只要喂「字节数 + 时间戳」就能断言。
/// 2. **节流**。worker 的采样频率与 UI 的刷新频率本来就不同（worker 侧
///    ≥120ms 合并，控制器 8Hz trailing-edge），把时间判断放在消费端才不会
///    出现「生产得快、消费得慢」的抖动。
///
/// ## 单调进度是刻意的取舍
///
/// 递归解压边解边发现嵌套压缩包，**分母会中途变大**：解完 100/100 之后
/// 冒出个嵌套包，分母变成 200，原始比率会掉回 50%。为了不让进度条倒退，
/// [progress] 取历史最大值。
///
/// 代价是它可能长时间停在 100% 而任务还没结束。所以诚实的进度指标是
/// [ScanProgress.depth]（递归到第几层）和 `doneCount`（已完成几个包），
/// 进度条只是「尽力而为」的观感。UI 上不要用它做「还剩多久」的承诺 ——
/// 那才是 [eta] 的事，而 [eta] 用剩余字节算，会随分母增长而变长。
library;

/// 一次进度的快照。
class ScanProgress {
  const ScanProgress({
    required this.doneBytes,
    required this.totalBytes,
    required this.progress,
    required this.speedBytesPerSecond,
    required this.depth,
    required this.doneCount,
    required this.entryName,
    required this.denominatorGrew,
  });

  const ScanProgress.idle()
      : doneBytes = 0,
        totalBytes = 0,
        progress = 0,
        speedBytesPerSecond = 0,
        depth = 0,
        doneCount = 0,
        entryName = '',
        denominatorGrew = false;

  final int doneBytes;
  final int totalBytes;

  /// 0..1，**单调不减**。
  final double progress;

  final double speedBytesPerSecond;

  /// 当前递归层级。
  final int depth;

  /// 已完成的压缩包个数（比字节数诚实得多的指标）。
  final int doneCount;

  /// 当前正在处理的条目名，用于进度面板的副标题。
  final String entryName;

  /// 分母是否在过程中变大过。为真时 UI 可以给进度条加个 `~` 提示它是估算。
  final bool denominatorGrew;

  bool get isIdle => totalBytes <= 0 && doneCount == 0;

  @override
  String toString() => 'ScanProgress($doneBytes/$totalBytes, '
      '${(progress * 100).toStringAsFixed(1)}%, depth=$depth, done=$doneCount)';
}

/// 把 worker 的原始计数累积成给 UI 的进度。
///
/// 时间由调用方通过 [update] 的 `now` 传入 —— 内部**不调** `DateTime.now()`，
/// 否则单测只能靠 sleep 来推进时间。
class ProgressMeter {
  ProgressMeter({this.alpha = 0.25})
      : assert(alpha > 0 && alpha <= 1, 'EWMA 系数必须在 (0, 1] 内');

  /// EWMA 平滑系数。越大越跟手、越抖；0.25 是「8Hz 刷新下看着稳、变了能立刻跟上」。
  final double alpha;

  /// 低于这个间隔的采样直接丢弃：节流后的连续两次回调可能只差几百微秒，
  /// 用它算瞬时速度会得到一个天文数字，把 EWMA 带飞。
  static const Duration minSampleInterval = Duration(milliseconds: 5);

  int _doneBytes = 0;
  int _totalBytes = 0;
  double _progress = 0;
  double _speed = 0;
  int _depth = 0;
  int _doneCount = 0;
  String _entryName = '';
  bool _denominatorGrew = false;

  DateTime? _lastAt;
  int _lastDoneBytes = 0;
  bool _hasSample = false;

  /// 喂一个新的原始计数。
  ///
  /// [doneBytes] / [totalBytes] 是**整个任务**的累计值（不是增量）；
  /// 计数器回退会被识别为「换了一个任务」，速度平滑随之重置。
  void update({
    required int doneBytes,
    required int totalBytes,
    int? depth,
    int? doneCount,
    String? entryName,
    DateTime? now,
  }) {
    if (doneBytes < 0) doneBytes = 0;
    if (totalBytes < 0) totalBytes = 0;

    // 只认 `doneBytes` 回退 = 换了个任务。
    // **不能**把 `totalBytes` 变小也当成换任务：跳过某个包时总工作量会缩小，
    // 那仍属同一个任务，把进度归零会让进度条毫无理由地跳回去。
    if (doneBytes < _doneBytes) _restart();

    // 进度已经到过 100%，分母又变大 ⇒ 后面还有活，进度条只是估算。
    if (totalBytes > _totalBytes && _progress >= 1.0) _denominatorGrew = true;

    _doneBytes = doneBytes;
    _totalBytes = totalBytes;
    if (depth != null) _depth = depth;
    if (doneCount != null) _doneCount = doneCount;
    if (entryName != null) _entryName = entryName;

    _sample(now ?? DateTime.now());

    if (_totalBytes > 0) {
      final raw = _doneBytes / _totalBytes;
      final clamped = raw.clamp(0.0, 1.0);
      // 单调：分母长大时不让进度条倒退。
      if (clamped > _progress) _progress = clamped;
    }
  }

  /// 检测到计数器回退，按「新任务」清空速度与进度。
  void _restart() {
    _speed = 0;
    _lastAt = null;
    _hasSample = false;
    _progress = 0;
    _denominatorGrew = false;
  }

  void _sample(DateTime now) {
    if (!_hasSample) {
      _lastAt = now;
      _lastDoneBytes = _doneBytes;
      _hasSample = true;
      return;
    }

    final last = _lastAt!;
    final elapsed = now.difference(last);
    if (elapsed < minSampleInterval) return;

    final deltaBytes = _doneBytes - _lastDoneBytes;
    final seconds = elapsed.inMicroseconds / 1e6;
    final instant = seconds > 0 ? deltaBytes / seconds : 0.0;

    // 只对正向吞吐做平滑；停滞时让速度自然衰减到 0，
    // 否则「卡住了」会一直显示上一次的漂亮速度，ETA 也一直乐观。
    if (instant > 0) {
      _speed = _speed == 0 ? instant : alpha * instant + (1 - alpha) * _speed;
    } else {
      _speed = _speed * (1 - alpha);
      if (_speed < 1) _speed = 0;
    }

    _lastAt = now;
    _lastDoneBytes = _doneBytes;
  }

  /// 0..1，单调不减。
  double get progress => _progress;

  double get speedBytesPerSecond => _speed;

  /// 剩余时间。速度未知或分母未知时返回 null（UI 显示 `--`）。
  Duration? get eta {
    if (_speed <= 0 || _totalBytes <= 0) return null;
    final remaining = _totalBytes - _doneBytes;
    if (remaining <= 0) return Duration.zero;
    final seconds = remaining / _speed;
    // 超过一天基本等于「算不出来」，别显示一个荒唐的数字。
    if (seconds > 86400) return null;
    return Duration(milliseconds: (seconds * 1000).round());
  }

  /// 已用时间。没采样过时返回 null。
  Duration? elapsedSince(DateTime start, {DateTime? now}) {
    if (!_hasSample) return null;
    return (now ?? DateTime.now()).difference(start);
  }

  ScanProgress snapshot() => ScanProgress(
        doneBytes: _doneBytes,
        totalBytes: _totalBytes,
        progress: _progress,
        speedBytesPerSecond: _speed,
        depth: _depth,
        doneCount: _doneCount,
        entryName: _entryName,
        denominatorGrew: _denominatorGrew,
      );

  /// 清空，供下一次任务复用同一个实例。
  void reset() {
    _doneBytes = 0;
    _totalBytes = 0;
    _progress = 0;
    _speed = 0;
    _depth = 0;
    _doneCount = 0;
    _entryName = '';
    _denominatorGrew = false;
    _lastAt = null;
    _lastDoneBytes = 0;
    _hasSample = false;
  }
}
