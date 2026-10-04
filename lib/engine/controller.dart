/// 引擎控制器：主 isolate 一侧的接口。
///
/// 职责有三件，且只有三件：
///
/// 1. **管 isolate 的生命周期**。一个长驻 worker，握手后一直活着 ——
///    不用 `Isolate.run`，因为它只返回单个 Future，没法流式推进度，
///    也没法协作取消。
/// 2. **节流**。worker 侧已按文件数合并过一次，这里再按时间合并一次。
///    四个页面都在 `IndexedStack` 里、各自包了一层 `ListenableBuilder`，
///    每次 `notifyListeners` 都会重建全部四棵树 —— 不节流必然掉帧。
/// 3. **把回调式的事件翻译成可 await 的 Future**。UI 那边 `await` 一个扫描
///    比订阅事件流好懂；进度仍然是回调，因为它本质是流。
///
/// **不做**时间数学（EWMA / ETA）。进度快照里的数字怎么算由
/// [ProgressMeter] 负责，等 P1 有真实字节计数时接进来。
library;

import 'dart:async';
import 'dart:isolate';

import 'limits.dart';
import 'models.dart';
import 'protocol.dart';
import 'scanner.dart';
import 'worker.dart';

/// 进度节流间隔（8Hz）。
///
/// 尾沿（trailing-edge）而不是首沿：首沿会让「第一次进度」立刻显示，
/// 之后每 125ms 才更新一次，而尾沿保证**最后一条**进度一定会发出去，
/// 进度条不会停在半路。
const Duration kProgressThrottle = Duration(milliseconds: 125);

/// 一次扫描的最终结果。
typedef ScanOutcome = ({ScanSummary summary, Duration elapsed});

/// 尾沿节流器：窗口内多次 [add] 只会在窗口末尾发出**最后一条**。
///
/// 尾沿而不是首沿是刻意的。首沿会让第一条立刻显示、之后每 125ms 才更新，
/// 而尾沿保证最后一条进度一定会发出去 —— 否则进度条会停在半路（后面没有
/// 更多 tick 来把它顶到 100%）。
///
/// 抽成泛型类是因为扫描与解压都要它。两处各写一遍 20 行状态机，
/// 迟早会在其中一处修 bug 而忘了另一处。
class _TickThrottle<T extends Object> {
  _TickThrottle({
    required this.delay,
    required this.emit,
    required this.isForeground,
  });

  final Duration delay;
  final void Function(T tick) emit;

  /// 后台时不发，只标脏（见 [EngineController.setForeground] 的说明）。
  final bool Function() isForeground;

  T? _pending;
  Timer? _timer;

  void add(T tick) {
    _pending = tick;
    if (!isForeground()) return;

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

class EngineController {
  EngineController({this.throttle = kProgressThrottle});

  /// 进度节流间隔。传 [Duration.zero] 关闭节流（单测用，让事件同步到达）。
  final Duration throttle;

  /// 节流后的扫描进度回调。**在节流窗口内多次 tick 只会调一次，且参数是最新的那条。**
  void Function(ScanTick tick)? onScanTick;

  /// 节流后的解压进度回调，语义同 [onScanTick]。
  void Function(ExtractTick tick)? onExtractTick;

  ReceivePort? _inbox;
  ReceivePort? _errors;
  Isolate? _isolate;
  SendPort? _toWorker;
  final Completer<void> _ready = Completer<void>();
  bool _disposed = false;

  int _nextJobId = 1;
  int? _activeJob;
  final Map<int, Completer<void>> _pingWaiters = {};
  final Map<int, Completer<ScanOutcome>> _scanWaiters = {};
  final Map<int, Completer<ExtractOutcome>> _extractWaiters = {};

  bool _foreground = true;
  late final _scanThrottle = _TickThrottle<ScanTick>(
    delay: throttle,
    emit: (t) => onScanTick?.call(t),
    isForeground: () => _foreground,
  );
  late final _extractThrottle = _TickThrottle<ExtractTick>(
    delay: throttle,
    emit: (t) => onExtractTick?.call(t),
    isForeground: () => _foreground,
  );

  bool get isRunning => _isolate != null && !_disposed;

  /// 释放之后再用就是编程错误：`_toWorker` 已经是 null，不拦住会踩空断言。
  ///
  /// **必须在每个 `await` 之后调用**，不能只在方法开头调一次：`await` 是
  /// 挂起点，`dispose()` 完全可能在这期间跑完（调用方通常是
  /// `state.dispose(); controller.dispose();` 这种同步序列），
  /// 开头检查过、拿到锁之前对象就被释放了 —— 典型的 TOCTOU。
  void _ensureAlive() {
    if (_disposed) throw const EngineException('控制器已释放');
  }

  // -------------------------------------------------------------------------
  // 生命周期
  // -------------------------------------------------------------------------

  /// 启动 worker 并完成握手。重复调用是空操作。
  Future<void> start() async {
    if (_disposed) return;
    if (_isolate != null) return;

    final inbox = ReceivePort();
    _inbox = inbox;
    inbox.listen(_onMessage);

    // 单独的 error 端口：worker 如果在握手前就崩了，没有它的话
    // `_ready.future` 会永远挂着，界面表现为「点了没反应」。
    final errors = ReceivePort();
    _errors = errors;
    errors.listen((Object? e) {
      final text = e is List && e.isNotEmpty ? '${e.first}' : '$e';
      if (!_ready.isCompleted) {
        _ready.completeError(EngineException('工作线程启动失败：$text'));
      } else {
        _failActive(EngineException('工作线程异常：$text'));
      }
    });

    _isolate = await Isolate.spawn(
      workerMain,
      inbox.sendPort,
      debugName: 'duz_worker',
      onError: errors.sendPort,
      errorsAreFatal: false,
    );

    try {
      await _ready.future;
    } catch (_) {
      // 握手失败说明 worker 根本没起来，把端口收掉，别留着泄漏。
      // dispose 本身有幂等守卫，即使已经被释放过也不会出错。
      dispose();
      rethrow;
    }
  }

  /// 硬杀 worker。任务中途调用是安全的：worker 只读文件或写新文件，
  /// 被杀不会破坏已有数据（解压的临时文件清理在 P1 处理）。
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _scanThrottle.drop();
    _extractThrottle.drop();

    // 抛 EngineException 而不是 StateError：调用方只需要 catch 一种异常。
    for (final c in _scanWaiters.values) {
      if (!c.isCompleted) {
        c.completeError(const EngineException('控制器已释放，任务中断'));
      }
    }
    _scanWaiters.clear();
    for (final c in _extractWaiters.values) {
      if (!c.isCompleted) {
        c.completeError(const EngineException('控制器已释放，任务中断'));
      }
    }
    _extractWaiters.clear();
    _activeJob = null;
    for (final c in _pingWaiters.values) {
      if (!c.isCompleted) c.completeError(const EngineException('控制器已释放'));
    }
    _pingWaiters.clear();

    _inbox?.close();
    _errors?.close();
    _inbox = null;
    _errors = null;
    _toWorker = null;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
  }

  // -------------------------------------------------------------------------
  // 命令
  // -------------------------------------------------------------------------

  /// 往返一次存活探测。测试与「引擎是否还活着」的健康检查用。
  Future<void> ping([int token = 0]) async {
    await _ready.future;
    // 只能在这个 await **之后**检查：dispose 可能刚好在这期间跑完。
    _ensureAlive();
    final c = Completer<void>();
    _pingWaiters[token] = c;
    _toWorker!.send(CmdPing(token));
    return c.future;
  }

  /// 扫描一个目录，等到扫描结束。
  ///
  /// 取消**不是**异常：`cancelScan()` 之后这个 Future 正常完成，只是
  /// `summary.warnings` 里会多一条「已取消」。
  Future<ScanOutcome> scan({
    required String rootPath,
    ScanOptions options = const ScanOptions(),
    Set<String> skipDirs = const {},
    int depth = 0,
  }) async {
    await _ready.future;
    // 只能在这个 await **之后**检查：dispose 可能刚好在这期间跑完。
    _ensureAlive();
    if (_activeJob != null) {
      throw const EngineException('已有任务在运行');
    }

    final jobId = _nextJobId++;
    _activeJob = jobId;
    final c = Completer<ScanOutcome>();
    _scanWaiters[jobId] = c;

    _toWorker!.send(CmdScan(
      jobId: jobId,
      rootPath: rootPath,
      options: options,
      skipDirs: skipDirs,
      depth: depth,
    ));

    return c.future;
  }

  /// 解压一组分卷到 [outDir]，等到解压结束。
  ///
  /// 进度走 [onExtractTick]（已节流），失败以 [EngineException] 抛出 ——
  /// 注意 `code == DUZ_ERR_PASSWORD` 时值得换下一个候选密码重试，
  /// 而不是把它当成「这个包坏了」。
  ///
  /// **取消在解压期间不生效**（见 [CmdExtract] 的说明）：`cancelScan()` 发的
  /// 信号要等这次解压跑完才会被 worker 处理。所以别在 UI 上把「暂停」按钮
  /// 接到它上面假装能停 —— 那是个谎言。
  ///
  /// [recursive] 为真时，返回值的 [ExtractOutcome.nested] 会带上「刚解出来的
  /// 内容里又发现的压缩包」，层级已经抬到 `depth + 1`。**解不解它们由调用方
  /// 决定** —— 这个方法只负责报告，不负责继续。
  Future<ExtractOutcome> extract({
    required List<String> parts,
    required String outDir,
    String? password,
    int depth = 0,
    bool recursive = false,
    ScanOptions options = const ScanOptions(),
    LimitThresholds limits = LimitThresholds.standard,
    int? availableBytes,
  }) async {
    await _ready.future;
    // 只能在这个 await **之后**检查：dispose 可能刚好在这期间跑完。
    _ensureAlive();
    if (parts.isEmpty) {
      throw const EngineException('没有可解压的分卷');
    }
    if (_activeJob != null) {
      throw const EngineException('已有任务在运行');
    }

    final jobId = _nextJobId++;
    _activeJob = jobId;
    final c = Completer<ExtractOutcome>();
    _extractWaiters[jobId] = c;

    _toWorker!.send(CmdExtract(
      jobId: jobId,
      parts: parts,
      outDir: outDir,
      password: password,
      depth: depth,
      recursive: recursive,
      options: options,
      limits: limits,
      availableBytes: availableBytes,
    ));

    return c.future;
  }

  /// 请求中止当前任务。没有任务在跑时是空操作。
  ///
  /// 扫描能立即响应；**解压不能**（见 [extract] 的说明）。
  Future<void> cancelScan() async {
    await _ready.future;
    // 只能在这个 await **之后**检查：dispose 可能刚好在这期间跑完。
    _ensureAlive();
    if (_activeJob == null) return;
    _toWorker!.send(const CmdCancel());
  }

  // -------------------------------------------------------------------------
  // 前后台
  // -------------------------------------------------------------------------

  /// 切到后台时**只标脏不发事件**，回到前台立刻补发最后一条。
  ///
  /// 后台时 Activity 已经不可见，每一次 `notifyListeners` 白重建四棵树。
  void setForeground(bool value) {
    if (_foreground == value) return;
    _foreground = value;
    if (value) {
      _scanThrottle.flush();
      _extractThrottle.flush();
    }
  }

  // -------------------------------------------------------------------------
  // 事件
  // -------------------------------------------------------------------------

  void _onMessage(Object? message) {
    switch (message) {
      case EvReady(:final commandPort):
        _toWorker = commandPort;
        if (!_ready.isCompleted) _ready.complete();

      case EvPong(:final token):
        _pingWaiters.remove(token)?.complete();

      case EvScanTick(:final jobId, :final tick):
        // 上一个任务遗留的 tick 必须丢掉，否则会覆盖掉新任务的状态。
        if (jobId == _activeJob) _scanThrottle.add(tick);

      case EvScanDone(:final jobId, :final summary, :final elapsed):
        if (jobId != _activeJob) return;
        // **先丢掉攒着的 tick**：节流定时器可能还没触发，如果让它稍后再发，
        // 就会在「扫描完成」之后又把界面刷回旧进度。
        _scanThrottle.drop();
        _activeJob = null;
        _scanWaiters.remove(jobId)?.complete((summary: summary, elapsed: elapsed));

      case EvExtractTick(:final jobId, :final tick):
        if (jobId == _activeJob) _extractThrottle.add(tick);

      case EvExtractDone(:final jobId, :final outcome):
        if (jobId != _activeJob) return;
        _extractThrottle.drop();
        _activeJob = null;
        _extractWaiters.remove(jobId)?.complete(outcome);

      case EvFailed(
          :final jobId,
          :final message,
          :final detail,
          :final code,
          :final breach
        ):
        _failActive(
          EngineException(message, detail: detail, code: code, breach: breach),
          onlyJob: jobId == 0 ? null : jobId,
        );
    }
  }

  void _failActive(EngineException error, {int? onlyJob}) {
    final jobId = onlyJob ?? _activeJob;
    if (jobId == null) return;

    // 两个 waiter 表都要查：只有发起那个任务的那一侧会命中，另一侧是 null。
    final scanWaiter = _scanWaiters.remove(jobId);
    final extractWaiter = _extractWaiters.remove(jobId);
    if (jobId == _activeJob) {
      _scanThrottle.drop();
      _extractThrottle.drop();
      _activeJob = null;
    }

    if (scanWaiter != null && !scanWaiter.isCompleted) {
      scanWaiter.completeError(error);
    }
    if (extractWaiter != null && !extractWaiter.isCompleted) {
      extractWaiter.completeError(error);
    }
  }
}
