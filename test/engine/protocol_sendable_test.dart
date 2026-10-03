/// 守住「isolate 消息必须是平凡数据」这条不变量。
///
/// `protocol.dart` 的文档里白纸黑字写着「**不能**传闭包、`File`/`RandomAccessFile`
/// 句柄、`Completer`、`Timer`」，但在这之前**没有任何东西真的检查过它**。而这类
/// 错误是所有 bug 里最难查的一种：
///
/// - 编译期完全合法 —— 给消息加个字段，没人拦得住；
/// - 单测碰不到 —— 消息在同一个 isolate 里构造、断言、扔掉，从不过边界；
/// - 只有真机上跑起来才炸，而且**报错文案指向的对象通常是错的**。
///
/// 最后一条值得展开，因为它是实际踩过的：2026-10-03 的冒烟测试里，
/// `packages/deep_unzip_engine/example/lib/main.dart` 用
/// `Isolate.run(() => _probe(path))` 探测归档，真机报的是
///
/// ```
/// Illegal argument in isolate message: object is unsendable -
/// Library:'dart:async' Class: _AsyncCompleter
/// ```
///
/// 而 `_AsyncCompleter` **跟我们写的任何东西都无关**。真实原因是 `Isolate.run`
/// 要送出去的是那个闭包，而闭包的 context 带父链 —— 即便正文只用到局部 `path`，
/// 父链上仍挂着捕获了 `this` 的外层 async 闭包，于是整个 `_SmokeState` 被拖进
/// 消息。`_AsyncCompleter` 只是 VM 遍历对象图时**第一个**撞上的不可发送对象，
/// 换个字段顺序报的就是别的名字了。照着报错里那个类名去查，只会白费一轮。
///
/// 所以这里不测「某个具体对象能不能发」，而是把协议里**每一条**消息真的发一遍。
///
/// ## 判据为什么用同步 `send`
///
/// `SendPort.send` 在发送那一刻就校验整个对象图，不可发送当场抛 `ArgumentError`；
/// 发给自己所在的 isolate 也照样校验，嵌在 `Map`/`List` 里的也拦得住。
/// 所以不必真的 spawn 一个 isolate 再等回执 —— 那是几百毫秒，这是几微秒。
library;

import 'dart:async';
import 'dart:isolate';

import 'package:deep_unzip/engine/models.dart';
import 'package:deep_unzip/engine/protocol.dart';
import 'package:deep_unzip/engine/scanner.dart';
// `models.dart` 只是 import 了它、没有 export，所以 `ArchiveFlag` 得单独引。
import 'package:deep_unzip/models/archive_file.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late ReceivePort port;

  setUp(() => port = ReceivePort());
  // 不关的话 ReceivePort 会吊住 isolate，测试进程退不出去。
  tearDown(() => port.close());

  test('协议里每一条消息都能跨 isolate 发送', () {
    // 两个穷尽 switch 一起保证「样本没有漏掉变体」：
    // 协议新增变体时，下面两个函数会**编译不过**，逼你回头补样本。
    // 这是编译期强制的，不是靠自觉。
    for (final cmd in _cmdSamples) {
      _coverEveryCmd(cmd);
      expect(
        () => port.sendPort.send(cmd),
        returnsNormally,
        reason: '${cmd.runtimeType} 不可发送 —— 它的某个字段（可能是嵌套的）'
            '不是平凡数据。注意真机上报出的类名往往不是真正写错的那个字段。',
      );
    }

    for (final event in _eventSamples(port.sendPort)) {
      _coverEveryEvent(event);
      expect(
        () => port.sendPort.send(event),
        returnsNormally,
        reason: '${event.runtimeType} 不可发送 —— 见上一条的说明。',
      );
    }
  });

  test('嵌套的不可发送对象也拦得住（判据自检）', () {
    // 这是**判据本身**的测试。如果哪天同步 `send` 不再校验可发送性（比如被
    // 优化成同 isolate 直接传引用），上面那条测试就会退化成永远绿的假测试 ——
    // 那比没有测试更糟。所以这里拿一个已知不可发送的对象证明它确实会抛。
    //
    // 用 `Completer` 而不是别的：它正是真机那次报错里点名的类型，构造又不需要
    // 任何资源，不会像 `Timer` 那样吊住 isolate。
    final unsendable = Completer<void>();
    expect(
      () => port.sendPort.send(<String, Object?>{'k': unsendable}),
      throwsA(isA<ArgumentError>()),
      reason: '同步 send 不再校验可发送性 —— 上面那条测试已经失去意义，'
          '需要改成真 spawn 一个 isolate 再等回执才作数。',
    );
  });
}

// ---------------------------------------------------------------------------
// 样本：字段尽量填满
//
// 空集合 / null 会让很多分支根本走不到，那样的样本等于没测。所以每个可选字段
// 都给了非默认值，`flags` 也把四个都塞进去。
// ---------------------------------------------------------------------------

final _sniff = SniffResult(
  format: SniffFormat.rar5,
  confidence: SniffConfidence.high,
  declaredExt: 'zip',
  baseOffset: 512,
  container: ContainerKind.none,
  header: const [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00],
);

final _split = SplitFamily(
  kind: SplitKind.rar5Volumes,
  entryPath: '/sdcard/Download/a.part1.rar',
  parts: const [
    '/sdcard/Download/a.part1.rar',
    '/sdcard/Download/a.part2.rar',
  ],
  warnings: const ['分片尺寸异常'],
);

final _item = ScanItem(
  entryPath: '/sdcard/Download/a.part1.rar',
  parts: _split.parts,
  sniff: _sniff,
  sizeBytes: 4096,
  flags: const {
    ArchiveFlag.encrypted,
    ArchiveFlag.split,
    ArchiveFlag.fakeExtension,
    ArchiveFlag.nested,
  },
  depth: 2,
  split: _split,
);

final _summary = ScanSummary(
  items: [_item],
  containerSkipped: 4,
  unreadable: 2,
  warnings: const ['已忽略 4 个容器格式文件'],
);

final _outcome = ExtractOutcome(
  outDir: '/sdcard/Download/a',
  entryCount: 12,
  unpackedBytes: 1048576,
  elapsed: const Duration(milliseconds: 1500),
);

/// 协议里**全部** `WorkerCmd`。见 `_coverEveryCmd` 的穷尽 switch。
const _cmdSamples = <WorkerCmd>[
  CmdPing(42),
  CmdScan(
    jobId: 1,
    rootPath: '/sdcard/Download',
    options: ScanOptions(
      detectFakeExtension: false,
      mergeSplitVolumes: false,
      pruneDirs: {'node_modules', '.git', 'Android/data'},
    ),
    skipDirs: {'/sdcard/Download/duz_out'},
    depth: 3,
  ),
  CmdExtract(
    jobId: 2,
    parts: ['/sdcard/Download/a.zip.001', '/sdcard/Download/a.zip.002'],
    outDir: '/sdcard/Download/a',
    password: 'hunter2',
  ),
  CmdCancel(),
  CmdShutdown(),
];

/// 协议里**全部** `WorkerEvent`。见 `_coverEveryEvent` 的穷尽 switch。
///
/// 写成函数而不是常量：`EvReady` 需要一个真的 `SendPort`，而那个 port 的生命
/// 周期由测试管（`tearDown` 里关）。
List<WorkerEvent> _eventSamples(SendPort commandPort) => [
  EvReady(commandPort),
  const EvPong(42),
  EvScanTick(
    jobId: 1,
    tick: const ScanTick(
      dirs: 3,
      files: 120,
      found: 7,
      current: '/sdcard/Download/资料',
    ),
  ),
  EvScanDone(
    jobId: 1,
    summary: _summary,
    elapsed: const Duration(seconds: 2),
  ),
  const EvExtractTick(
    jobId: 2,
    tick: ExtractTick(doneBytes: 512, totalBytes: 4096, current: '资料/b.txt'),
  ),
  EvExtractDone(jobId: 2, outcome: _outcome),
  const EvFailed(
    jobId: 3,
    message: '归档损坏，无法读取中央目录',
    detail: 'DuzEngineException(-1): ...',
    code: DuzErrorCode.extract,
  ),
];

// ---------------------------------------------------------------------------
// 穷尽性守卫
//
// 这两个 switch **没有兜底分支**（`_` / `default`）。协议里加了新变体而这里
// 没补，编译期就会红 —— 用编译器代替「记得更新测试」的自觉。
//
// 它们不产生断言，只负责让上面的样本列表保持完整。
// ---------------------------------------------------------------------------

Null _coverEveryCmd(WorkerCmd c) => switch (c) {
  CmdPing() => null,
  CmdScan() => null,
  CmdExtract() => null,
  CmdCancel() => null,
  CmdShutdown() => null,
};

Null _coverEveryEvent(WorkerEvent e) => switch (e) {
  EvReady() => null,
  EvPong() => null,
  EvScanTick() => null,
  EvScanDone() => null,
  EvExtractTick() => null,
  EvExtractDone() => null,
  EvFailed() => null,
};
