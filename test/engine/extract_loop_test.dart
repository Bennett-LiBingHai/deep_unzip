/// 解压轮询循环（`package:deep_unzip_engine` 的 [runExtractLoop]）。
///
/// 它是刻意抽出来的**可注入 seam**：`poll`/`cancel`/`failure`/`sleep` 四个动作
/// 全由调用方给，所以这一整套**不碰 FFI**，在 Windows 宿主机上就能跑（与
/// `DiskSpaceProbe(channel)`、`listDirectory(path, lister)` 同一个先例）。
///
/// 真 FFI 那半边 —— `DuzArchive.extractAll` 把 `duz_extract_start` /
/// `duz_extract_poll` / `duz_extract_cancel` 三个真实调用包成闭包 —— 只能在
/// Android 上验（本机 C++ 编不了，见 memory `android-only-cpp-verification`）。
/// 本文件钉的是那两个之间那层纯逻辑：poll 的节奏、「请求取消只送一次」、
/// **取消不是异常**、`rc != OK` 才抛、`running == 0` 之后不再 poll。
///
/// 为什么要盯这么紧：轮询循环是「7z 多线程解码闪退」那个 bug 的修法本身
/// （原生侧永不回调 Dart，改成 Dart 主动轮询），它一旦把取消折成异常，上层的
/// `verify` 闭包就会把「被中止」当成「密码对的」—— 静默假绿，见
/// `lib/engine/protocol.dart` 里 `ExtractCancelled` 那段。
library;

import 'package:deep_unzip_engine/deep_unzip_engine.dart';
import 'package:flutter_test/flutter_test.dart';

/// 造一帧。[running] 默认 true（解压中），其余按需给。
ExtractTick frame({
  int done = 0,
  int total = 100,
  String? name,
  bool running = true,
  bool cancelled = false,
  int rc = DUZ_OK,
}) => (
  done: done,
  total: total,
  name: name,
  running: running,
  cancelled: cancelled,
  rc: rc,
);

/// 把 [runExtractLoop] 的四个依赖都接成可观察的假动作。
///
/// [frames] 是脚本：第 i 次 poll 返回第 i 帧。**最后一帧必须 `running: false`**
/// —— 循环只在读到收工那一帧才退出，脚本没写结尾就是死循环。多要的 poll 会
/// 重复给最后一帧（正常用例走不到；走到了也会因为那帧 `running: false` 立刻
/// 退出，于是「poll 了几次」这个断言会先炸）。
class _Rig {
  _Rig(this.frames);

  final List<ExtractTick> frames;

  int polls = 0;
  final List<int> pollsAtCancel = [];
  int cancels = 0;
  int failures = 0;
  final List<Duration> slept = [];
  final List<String> progress = [];

  /// `onProgress` 的返回值。设为 false 即「请求取消」。
  bool progressVerdict = true;

  /// `failure()` 抛的那个异常。
  DuzEngineException failureError =
      const DuzEngineException(DUZ_ERR_EXTRACT, '解压失败');

  ExtractTick poll() {
    final i = polls < frames.length ? polls : frames.length - 1;
    polls++;
    return frames[i];
  }

  void cancel() {
    cancels++;
    pollsAtCancel.add(polls);
  }

  DuzEngineException failure() {
    failures++;
    return failureError;
  }

  Future<void> sleep(Duration d) async {
    slept.add(d);
  }

  bool onProgress(int done, int total, String? name) {
    progress.add('$done/$total/${name ?? '-'}');
    return progressVerdict;
  }

  Future<bool> run({
    bool withProgress = true,
    Duration interval = kExtractPollInterval,
  }) => runExtractLoop(
    poll: poll,
    cancel: cancel,
    failure: failure,
    sleep: sleep,
    onProgress: withProgress ? onProgress : null,
    interval: interval,
  );
}

void main() {
  group('正常跑完', () {
    test('读到 running == 0 就收工，返回 false（没被中止）', () async {
      final rig = _Rig([
        frame(done: 30, name: 'a.txt'),
        frame(done: 70, name: 'b.txt'),
        frame(done: 100, running: false),
      ]);

      expect(await rig.run(), isFalse, reason: '解完了不是「被中止」');
      expect(rig.polls, 3, reason: '收工那一帧之后不该再 poll');
      expect(rig.cancels, 0);
      expect(rig.failures, 0);
      expect(rig.progress, ['30/100/a.txt', '70/100/b.txt']);
    });

    test('每一轮之间都 sleep 一个 interval，隔多少由调用方定', () async {
      final rig = _Rig([
        frame(done: 10),
        frame(done: 20),
        frame(done: 30, running: false),
      ]);

      await rig.run(interval: const Duration(milliseconds: 25));
      // 3 帧 = 前两帧各睡一次，收工那一帧不睡。
      expect(rig.slept, const [
        Duration(milliseconds: 25),
        Duration(milliseconds: 25),
      ]);
    });

    test('默认间隔就是 kExtractPollInterval —— 那个数有约束，别被改走', () async {
      // 它必须**小于** worker 侧的 `kExtractTickMerge`(120ms)：三层节流里干活
      // 的是那个合并层，这里只是取样的网眼，网眼比闸门大就白设了。
      expect(kExtractPollInterval, const Duration(milliseconds: 80));
      expect(kExtractPollInterval.inMilliseconds, lessThan(120));

      final rig = _Rig([frame(), frame(running: false)]);
      await rig.run();
      expect(rig.slept, [kExtractPollInterval]);
    });
  });

  group('取消', () {
    test('onProgress 返回 false → 请求取消，且**只请求一次**', () async {
      final rig = _Rig([
        frame(done: 10),
        frame(done: 20),
        frame(done: 30),
        frame(done: 30, cancelled: true, running: false),
      ])
        ..progressVerdict = false;

      // 取消**不是**异常：用户按的是「停止」，不是「这个包坏了」。
      expect(await rig.run(), isTrue);
      expect(rig.cancels, 1, reason: '原生侧那个标志幂等，但我们自己的账要准');
      expect(rig.pollsAtCancel, [1],
          reason: '第一帧就送出去，不是攒着等收工 —— 那等于没取消');
      // 请求过之后每一帧照样 poll（原生侧 unwind 要时间），但不重复送。
      expect(rig.polls, 4);
      expect(rig.failures, 0);
    });

    test('取消标志是在 pin 住的：请求过就不再重复请求', () async {
      final rig = _Rig([
        frame(done: 1),
        frame(done: 2),
        frame(done: 3),
        frame(done: 4),
        frame(running: false, cancelled: true),
      ])
        ..progressVerdict = false;

      expect(await rig.run(), isTrue);
      expect(rig.cancels, 1);
    });

    test('**请求取消但包刚好解完了** → 记成功，不记「已停止」', () async {
      // 这是 `cancelled` 那位取自原生快照、而不是「我们送出过取消」的理由：
      // 请求的那一刻它可能已经在收尾了，那种情况该记成功。
      final rig = _Rig([
        frame(done: 50),
        frame(done: 100, running: false), // cancelled 是 false
      ])
        ..progressVerdict = false;

      expect(await rig.run(), isFalse, reason: '快照说没被中止，就是没被中止');
      expect(rig.cancels, 1, reason: '取消确实送出去过 —— 只是没赶上');
    });

    test('没有 onProgress 就没人能请求取消', () async {
      final rig = _Rig([frame(done: 1), frame(running: false, cancelled: true)]);

      // 注意：这里 `cancelled` 来自快照，所以仍报 true；关键是**我们自己**
      // 一次都没送过取消。
      expect(await rig.run(withProgress: false), isTrue);
      expect(rig.cancels, 0);
      expect(rig.progress, isEmpty);
    });
  });

  group('失败', () {
    test('rc != DUZ_OK → 抛 failure() 给的那个异常', () async {
      final rig = _Rig([
        frame(done: 40),
        frame(done: 40, running: false, rc: DUZ_ERR_EXTRACT),
      ])..failureError =
          const DuzEngineException(DUZ_ERR_EXTRACT, 'CRC 对不上');

      await expectLater(rig.run(), throwsA(isA<DuzEngineException>()));
      expect(rig.failures, 1);
      expect(rig.cancels, 0);
    });

    test('`failure` 只在收工那一帧被调，中间那些帧一次都不调', () async {
      // 原因存在原生侧的 thread_local 里：晚一步读就可能被别的调用冲掉，
      // 所以它必须在「读到 running == 0」的**那一帧立刻**取。反过来，
      // 还在跑的帧上取它只会读到上一次调用留下的值。
      final rig = _Rig([
        frame(done: 10),
        frame(done: 20),
        frame(done: 30),
        frame(running: false, rc: DUZ_ERR_PASSWORD),
      ])..failureError =
          const DuzEngineException(DUZ_ERR_PASSWORD, '密码不对');

      await expectLater(rig.run(), throwsA(isA<DuzEngineException>()));
      expect(rig.polls, 4);
      expect(rig.failures, 1, reason: '前面三帧一次都不该取');
    });

    test('被中止优先于失败：cancelled 那一位压过 rc', () async {
      // 原生侧保证 `cancelled == 1` 时 `rc == DUZ_OK`，但万一不是，
      // 「用户按了停止」这条语义更该赢 —— 否则一个被用户停掉的包会走
      // 失败那条路，日志上红一条。
      final rig = _Rig([
        frame(done: 1),
        frame(running: false, cancelled: true, rc: DUZ_ERR_EXTRACT),
      ]);

      expect(await rig.run(), isTrue);
      expect(rig.failures, 0);
    });
  });
}
