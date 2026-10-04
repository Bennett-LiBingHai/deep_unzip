import 'dart:io';

import 'package:deep_unzip/app_navigator.dart';
import 'package:deep_unzip/engine/limits.dart';
import 'package:deep_unzip/engine/protocol.dart';
import 'package:deep_unzip/models/log_entry.dart';
import 'package:deep_unzip/providers/app_state.dart';
import 'package:deep_unzip/services/dialog_bridge.dart';
import 'package:deep_unzip/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../engine/zip_fixtures.dart';
import '../support/fake_engine.dart';

/// 「闸门拦下 → 弹窗 → 用户的决断」，端到端走一遍。
///
/// ## 补的是哪一段缝
///
/// 闸门本身（`checkArchiveLimits`）住在 `limits.dart` 的纯函数里，已经被
/// `limits_test.dart` 逐档覆盖得很密。把它翻译成 `EngineException` 那一步住在
/// `native_backend.dart`，**要开真实归档，Windows 宿主上跑不了**（没有
/// `.so`，见 `fake_engine.dart` 开头那段）。所以中间这一段一直没人验：
///
/// > 闸门产出的那个 `LimitBreach`，真的能一路走到弹窗上、把**那句话**摆在
/// > 用户眼前吗？
///
/// 这里用假引擎把这段补上 —— 但**不是**再造一个假闸门：每个夹具都拿真的
/// `checkArchiveLimits` 算出真的 `LimitBreach`，再照 `native_backend.dart`
/// 那行的形状抛出去。剩下的一路（批次循环 → `DialogBridge` → `ErrorModal`）
/// 全是生产代码，`prompt` 用的也是 `main.dart` 里那一句
/// `const DialogBridge().askCantExtract`。
///
/// ## 为什么四种「上限」都要各自走一遍
///
/// 它们共用同一个弹窗、同一组按钮，看起来一条用例就够。但**用户能自己在
/// 设置页把上限调小**（这是最容易被撞上的那条路），四档的 `message` 文案各不
/// 相同、`tag` 有两档同名两档不同名。哪天有人给其中一档加个特判（「条目数
/// 超了就别弹了，直接把整个目录砍掉」之类），只测一档的那组用例不会红。
void main() {
  // 真弹窗挂上来之后 `tap` 打不中目标只打印警告、用例照过 —— 正是这个文件
  // 最容易踩的坑：「点了跳过之后批次继续了」在压根没点到的前提下也能过。
  setUpAll(() => WidgetController.hitTestWarningShouldBeFatal = true);

  late Directory root;
  late FakeEngine engine;
  late AppState state;

  /// 每个夹具都用**真** `checkArchiveLimits` 算出 breach，而不是手写一个。
  ///
  /// 手写的话，弹窗上挂的字和闸门真会说出的字就成了两份东西 —— 这条链想验的
  /// 恰恰是「它们是不是同一句」。
  LimitBreach breachFor(LimitKind kind) {
    final p = switch (kind) {
      // 条目数：比上限多一个就够了，别造一整个宇宙。
      LimitKind.entryCount => ArchiveProfile(
          entryCount: LimitThresholds.standard.maxEntries + 1,
          unpackedBytes: 1024,
          largestEntryBytes: 1024,
        ),
      LimitKind.entrySize => ArchiveProfile(
          entryCount: 1,
          unpackedBytes: LimitThresholds.standard.maxEntryBytes + 1,
          largestEntryBytes: LimitThresholds.standard.maxEntryBytes + 1,
        ),
      LimitKind.totalSize => ArchiveProfile(
          entryCount: 2,
          unpackedBytes: LimitThresholds.standard.maxTotalBytes + 1,
          largestEntryBytes: 1024,
        ),
      // 比值：又大又空，且大过地板（否则那一条整个跳过，见 limits.dart）。
      LimitKind.ratio => ArchiveProfile(
          entryCount: 1,
          unpackedBytes: 4 << 30, // 4 GiB，压缩后只有 1 MiB
          largestEntryBytes: 4 << 30,
          compressedBytes: 1 << 20,
        ),
      // 空间这条要的不是 profile 而是「机器现在有多少」，另做。
      LimitKind.diskSpace => throw ArgumentError('空间那条另走 availableBytes'),
    };
    final breach = checkArchiveLimits(p);
    expect(breach, isNotNull,
        reason: '夹具本身得真的越线，否则这个用例什么都没验');
    expect(breach!.kind, kind, reason: '要验哪一档就造哪一档，别串了');
    return breach;
  }

  setUp(() async {
    root = makeTempDir('limit_modal');
    // 两个包：一个用来撞闸门，一个用来验「跳过之后整批还在跑」。
    File(p.join(root.path, 'a.zip')).writeAsBytesSync(realZip({'x': 'y'}));
    File(p.join(root.path, 'b.zip')).writeAsBytesSync(realZip({'x': 'y'}));

    engine = FakeEngine();
    state = AppState(
      engine: engine,
      // 与 `main.dart` 里那句逐字一致。用别的实现就等于把最该验的桥接层
      // （Completer + 滑走兜底）换成假的了。
      prompt: const DialogBridge().askCantExtract,
    );
    // 扫描是真的（要起 isolate、读真文件），必须留在 `setUp` 里 ——
    // 测试体被 FakeAsync 包住，真 isolate 的消息排在假时钟外面推不动。
    // 详见 `home_screen_test.dart` 开头那段。
    await state.selectFolderPath(root.path);
  });

  tearDown(() {
    state.dispose();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  /// 挂一个带 [AppNavigator.key] 的壳 —— 桥接就是靠它拿 context 的。
  ///
  /// 不挂的话 `currentContext` 恒为 null，弹窗静默不出现、`askCantExtract`
  /// 直接返回 null，于是**每条用例都会以「用户没看到任何东西」通过**。
  Future<void> mountApp(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      navigatorKey: AppNavigator.key,
      theme: AppTheme.dark,
      home: const Scaffold(body: Center(child: Text('底下的页面'))),
    ));
  }

  /// `showToast` 会在 FakeAsync 区里挂一个 2 秒定时器，不排空的话
  /// `testWidgets` 收尾会判定「还有未完成的定时器」。
  Future<void> drainTimers(WidgetTester tester) =>
      tester.pump(const Duration(seconds: 3));

  /// 让第一个包撞闸门、第二个照常过。
  void gateFirst(LimitBreach breach) {
    engine.behavior = (e, outDir) async {
      if (e.rounds == 1) {
        // 与 `native_backend.dart` 里 `throw EngineException(breach.message,
        // breach: breach)` 同形。正文那句话必须是 breach 自带的，不是这里
        // 另编的 —— 弹窗上要看到的正是闸门说的那句。
        throw EngineException(breach.message, breach: breach);
      }
    };
  }

  // -------------------------------------------------------------------------
  // 四种「上限」各拦一次，弹窗上都是那句话
  // -------------------------------------------------------------------------

  const gated = <String, LimitKind>{
    '条目数超上限': LimitKind.entryCount,
    '单文件超上限': LimitKind.entrySize,
    '解压总量超上限': LimitKind.totalSize,
    '压缩比离谱': LimitKind.ratio,
  };

  gated.forEach((label, kind) {
    testWidgets('$label → 弹窗把闸门那句话原样摆出来', (tester) async {
      final breach = breachFor(kind);
      gateFirst(breach);
      await mountApp(tester);

      state.startExtract();
      // 弹窗要靠真实动画铺开，这里没有常驻的转圈控件（没挂首页），
      // `pumpAndSettle` 是安全的。
      await tester.pumpAndSettle();

      // 撞的是哪个包要写在弹窗上：一批几十个包的途中随时会弹，
      // 不说是在说哪个文件，用户不知道眼前这一下影响的是谁。
      expect(find.text('a.zip'), findsOneWidget);
      expect(find.text(breach.message), findsOneWidget,
          reason: '闸门说的话和弹窗上的话必须是同一句');
      // 两颗按钮，字与位置都不该随 kind 变 —— 用户要做的是同一个决断。
      expect(find.text('停止'), findsOneWidget);
      expect(find.text('跳过'), findsOneWidget);

      await tester.tap(find.text('跳过'));
      await tester.pumpAndSettle();
      // 放走这个包，整批还得接着跑完（放行 b.zip 之后批次才收尾）。
      await drainTimers(tester);

      expect(engine.rounds, 2, reason: '跳过 ≠ 停批');
      // 日志里那一档的角标照旧挂着 —— 弹窗问过了不代表这件事没发生过。
      final a = state.logs.firstWhere((l) => l.name == 'a.zip');
      expect(a.tags, contains(breach.tag));
    });
  });

  // -------------------------------------------------------------------------
  // 两颗按钮各自的后果
  // -------------------------------------------------------------------------

  testWidgets('点「停止」→ 剩下的包一个都不跑，落在总结页上', (tester) async {
    final breach = breachFor(LimitKind.entryCount);
    gateFirst(breach);
    await mountApp(tester);

    state.startExtract();
    await tester.pumpAndSettle();

    await tester.tap(find.text('停止'));
    await tester.pumpAndSettle();
    await drainTimers(tester);

    expect(engine.rounds, 1, reason: '停下去队列就没了，b.zip 一个字节都不该动');
    expect(state.extracting, isFalse);
    // 弹窗那档的标题要写「解压出错，已停止」而不是「已停止」—— 它总是
    // 伴随一次失败，瞒着不说等于骗人（见 `BatchOutcome`）。
    expect(state.outcome, BatchOutcome.errored);
    expect(state.completeDetail, contains('已完成 0/2 个压缩包'));
    expect(state.completeDetail, contains('1 个失败'));
  });

  testWidgets('滑走弹窗 → 兜底成「跳过」，整批不会因为误滑一下废掉', (tester) async {
    // 这条盯的是 `DialogBridge` 里那句 `.then((_) => finish(skip))`。
    // `showBottomModal` 没设 `isDismissible: false`，用户点遮罩就能把弹窗
    // 关掉而两条回调一个都不触发 —— 少了那句兜底，这个 future 永远不完成，
    // 整批解压停在原地，而且没有任何报错。
    //
    // 为什么这条属于本文件：闸门拦下时**必然**弹窗，所以「手滑」在解一个
    // 炸弹包时是最容易发生的。
    final breach = breachFor(LimitKind.ratio);
    gateFirst(breach);
    await mountApp(tester);

    state.startExtract();
    await tester.pumpAndSettle();

    // 遮罩铺在弹窗上方，点最上角必中遮罩。
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    expect(find.text('停止'), findsNothing, reason: '前提：弹窗真的被关掉了');
    await drainTimers(tester);

    expect(engine.rounds, 2,
        reason: '误滑一下的代价只能是「放掉这一个包」，不能是废掉整批');
    expect(state.extracting, isFalse, reason: '批次要真的收得了尾，不能悬着');
  });

  testWidgets('拿不到 context → 不弹也不等，补一条 toast 说清是哪个包', (tester) async {
    // `MaterialApp` 没挂 `AppNavigator.key` 时 `currentContext` 恒为 null。
    // 这条路径下弹窗静默不出现 —— 用户什么都没看见，程序得自己往下走，
    // 而不是把一个悬着的 future 留给整批。
    final breach = breachFor(LimitKind.totalSize);
    gateFirst(breach);

    // 故意不调 `mountApp`：挂一个没有 navigatorKey 的壳。
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.dark,
      home: const Scaffold(body: Center(child: Text('底下的页面'))),
    ));

    // 弹不出来时 `_onPrompt` 返回 null，AppState 走的是**补一条 toast** 那条
    // 兜底（见批次循环里 `if (!shown)`）。所以这里得记一串 toast —— 收尾那条
    // 汇总会把逐包的那句顶掉，只看 `state.toastMsg` 会认错人。
    final toasts = <String>[];
    state.addListener(() {
      final msg = state.toastMsg;
      if (msg != null && (toasts.isEmpty || toasts.last != msg)) toasts.add(msg);
    });

    state.startExtract();
    await tester.pumpAndSettle();
    await drainTimers(tester);

    expect(find.text(breach.message), findsNothing, reason: '拿不到 context 就弹不出来');
    expect(engine.rounds, 2, reason: '没弹成不该少解一个包');
    expect(state.extracting, isFalse, reason: '批次照样要收尾');
    // 用户总得知道刚才发生了什么 —— 否则那个包失败得无声无息。
    expect(toasts.join('\n'), contains('a.zip'));
    expect(toasts.join('\n'), contains(breach.message),
        reason: '兜底的 toast 要带上闸门说的那句，不能糊一句「解压失败」');
    // 日志那一侧也要留下痕迹：光有 toast 是一闪而过的。
    final a = state.logs.firstWhere((l) => l.name == 'a.zip');
    expect(a.status, LogStatus.failed);
    expect(a.tags, contains(breach.tag));
  });
}
