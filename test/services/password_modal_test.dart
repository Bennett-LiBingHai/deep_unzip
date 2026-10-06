import 'dart:io';

import 'package:deep_unzip/app_navigator.dart';
import 'package:deep_unzip/engine/protocol.dart';
import 'package:deep_unzip/models/log_entry.dart';
import 'package:deep_unzip/providers/app_state.dart';
import 'package:deep_unzip/services/dialog_bridge.dart';
import 'package:deep_unzip/theme/app_theme.dart';
import 'package:deep_unzip/widgets/modals/password_attempt_modal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../engine/zip_fixtures.dart';
import '../support/fake_engine.dart';

/// 「密码库试不出来 → 弹窗 → 用户的决断」，端到端走一遍。
///
/// ## 补的是哪一段缝
///
/// `app_state_test.dart` 里的密码那一组把 `passwordPrompt` 换成了假闭包，验的
/// 是「调用方怎么用这个结果」；弹窗本体（手输错了留不留在原地）则只有这一段
/// 缝两边都够不着。这里两样一起验 —— 用的是**生产里那句**
/// `const DialogBridge().askPassword`，所以桥接层那套 Completer + 滑走兜底也
/// 在覆盖范围里。
///
/// ## 为什么每条用例都要走整个批次
///
/// 弹窗不是孤立的控件：它开在批次的中间，用户在它上面按的每一颗按钮都决定
/// 「剩下那几个包还跑不跑」。只验「点了一下弹窗关了」等于没验 —— 真正会出
/// 事的是批次那头：`_cancelRequested` 有没有置位、剩下的包有没有被丢掉、
/// 用户手输的密码有没有真的拿去解。所以这里每条都从 `startExtract()` 开始。
void main() {
  // 真弹窗挂上来之后 `tap` 打不中目标只打印警告、用例照过 —— 正是这个文件
  // 最容易踩的坑：「点了跳过之后批次继续了」在压根没点到的前提下也能过。
  setUpAll(() => WidgetController.hitTestWarningShouldBeFatal = true);

  /// 用户会手敲的那个 —— 只有它解得开 a.zip。
  const rightPassword = 'correct-horse';

  /// 让 `a.zip` 的失败带上「分不清是密码错还是文件坏」那一位（7z 的内容加密 /
  /// RAR3 那种没有校验字的）。默认 false —— 也就是其余用例跑的都是**能确定**
  /// 的那一档（ZIP-AES / RAR5），它们逐字不该变。
  var uncertainLock = false;

  late Directory root;
  late FakeEngine engine;
  late AppState state;

  setUp(() async {
    uncertainLock = false;
    root = makeTempDir('pwd_modal');
    // 两个包：`a.zip` 锁着（撞密码那一档），`b.zip` 不锁。扫描输出是**按名字
    // 自然序**的（见 `scanner.dart` 的顺序契约），所以 a 一定先跑 ——
    // 「跳过之后整批还在跑」这条才立得住。
    File(p.join(root.path, 'a.zip')).writeAsBytesSync(realZip({'x': 'y'}));
    File(p.join(root.path, 'b.zip')).writeAsBytesSync(realZip({'x': 'y'}));

    engine = FakeEngine()
      ..behavior = (e, outDir) async {
        // 只按**文件名**判，不按「第几次调用」判：密码这条路一个包会被试很多
        // 次（空密码、每个候选、用户手敲的每一次），次数的语义每隔一行就变。
        final locked = e.partsSeen.last.any((s) => s.endsWith('a.zip'));
        if (locked && e.passwordsSeen.last != rightPassword) {
          throw EngineException(
            uncertainLock ? '密码不对，或加密数据已损坏' : 'Wrong password',
            code: DuzErrorCode.password,
            uncertain: uncertainLock,
          );
        }
      };

    state = AppState(
      engine: engine,
      // 与 `main.dart` 里那句逐字一致。换成别的实现就等于把最该验的桥接层
      // 换成假的了。
      passwordPrompt: const DialogBridge().askPassword,
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

  /// 起一批、等锁着的那个包把弹窗顶出来。
  Future<void> startAndWaitModal(WidgetTester tester) async {
    await mountApp(tester);
    // 返回 void（内部那个 Future 是 fire-and-forget），所以这里 await 不了，
    // 只能靠 pump 把它推到底 —— 与 `limit_breach_modal_test.dart` 同法。
    state.startExtract();
    await tester.pumpAndSettle();
    expect(find.byType(PasswordAttemptModal), findsOneWidget,
        reason: '前提：弹窗真的弹出来了，否则下面每一条断言都在验空气');
  }

  /// 在弹窗里手敲一个密码并提交。
  Future<void> typeAndSubmit(WidgetTester tester, String pwd) async {
    await tester.enterText(find.byType(TextField), pwd);
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();
  }

  // -------------------------------------------------------------------------
  // 弹窗长什么样
  // -------------------------------------------------------------------------

  testWidgets('顶上写着是哪个包，并说明密码库试过了几个', (tester) async {
    state.addPassword('pw-one');
    state.addPassword('vault-second-password');
    await startAndWaitModal(tester);

    expect(find.text('a.zip'), findsOneWidget,
        reason: '一批几十个包的途中随时会弹，不说哪个文件用户不知道眼前影响的是谁');
    expect(find.text('需要密码'), findsOneWidget);
    expect(find.text('密码库未能解开该压缩包'), findsOneWidget);
    // 能确定的这一档（ZIP-AES / RAR5）不该冒出「分不出来」那句 —— 它会让
    // 本可以确定的失败变得含糊。
    expect(find.textContaining('两者无法区分'), findsNothing);
    expect(find.text('密码库中的 2 个密码均未通过'), findsOneWidget);

    // 试过的那两个**一条都不摆**。这里钉的是「没有一行是多余的」—— 那一屏上
    // 的每一条都必然不匹配（对得上的早就解开了，走不到这儿），所以「不匹配」
    // 是恒真的废话；而遮罩把长度也压平了，一排点彼此之间看不出区别。
    expect(find.text('不匹配'), findsNothing);
    expect(find.textContaining('•'), findsNothing, reason: '连一个点都不该剩');
    expect(find.text('pw-one'), findsNothing, reason: '密码库里的密码不该明文摆出来');
    expect(find.text('vault-second-password'), findsNothing);

    // 三条出路，一颗不少。
    expect(find.text('手动输入密码'), findsOneWidget);
    expect(find.text('跳过'), findsOneWidget);
    expect(find.text('停止解压'), findsOneWidget);

    await drainTimers(tester);
  });

  testWidgets('密码库是空的 → 文案不一样（不是「试了 0 个」）', (tester) async {
    // 「试了 0 个都没通过」读起来像我们偷懒；空库是另一件事，得说清楚。这也
    // 正是那条**个数**留下来、而条目列表没留下来的理由：个数区分了两种处境，
    // 条目不区分。
    await startAndWaitModal(tester);

    expect(find.text('密码库为空，无可用密码'), findsOneWidget);

    await drainTimers(tester);
  });

  // -------------------------------------------------------------------------
  // 三条出路
  // -------------------------------------------------------------------------

  testWidgets('点「跳过」→ 放掉这个包，整批接着跑', (tester) async {
    await startAndWaitModal(tester);

    await tester.tap(find.text('跳过'));
    await tester.pumpAndSettle();
    await drainTimers(tester);

    expect(find.byType(PasswordAttemptModal), findsNothing);
    expect(engine.passwordsSeen, ['', ''],
        reason: '空密码库每个包只试了空密码那一次 —— 一颗都没解开的包不该被反复解');
    final a = state.logs.firstWhere((l) => l.name == 'a.zip');
    expect(a.status, LogStatus.skipped);
    expect(a.tags, ['用户跳过']);
    final b = state.logs.firstWhere((l) => l.name == 'b.zip');
    expect(b.status, LogStatus.success, reason: '跳过 ≠ 停批');
  });

  testWidgets('点「停止解压」→ 剩下的包一个都不跑', (tester) async {
    await startAndWaitModal(tester);

    await tester.tap(find.text('停止解压'));
    await tester.pumpAndSettle();
    await drainTimers(tester);

    expect(state.extracting, isFalse);
    expect(state.logs.any((l) => l.name == 'b.zip'), isFalse,
        reason: '停下去队列就没了');
    // 弹窗里那颗「停止」不置 `_stoppedByUser`（那是主按钮那条路），所以标题
    // 走「解压出错，已停止」而不是「已停止」—— 这一档确实伴随一次失败。
    expect(state.outcome, BatchOutcome.errored);
    expect(state.completeDetail, contains('已完成 0/2 个压缩包'));
  });

  testWidgets('手输对了 → 弹窗关掉，解压继续走到成功', (tester) async {
    await startAndWaitModal(tester);

    await tester.tap(find.text('手动输入密码'));
    await tester.pumpAndSettle();
    await typeAndSubmit(tester, rightPassword);

    expect(find.byType(PasswordAttemptModal), findsNothing);

    await drainTimers(tester);

    final a = state.logs.firstWhere((l) => l.name == 'a.zip');
    expect(a.status, LogStatus.success,
        reason: '手输对了就是解开了，不该还挂着失败');
    expect(engine.passwordsSeen, contains(rightPassword),
        reason: '用户敲的那个密码得真的拿去解，不能只记一笔');
  });

  testWidgets('眼睛画的是当前状态 —— 遮着的时候是带斜杠的眼，不是睁眼', (tester) async {
    // 这颗按钮曾经画反了：默认密码遮着，画的却是**睁眼**，用户看到睁眼去点，
    // 期待看明文，结果什么都没变。两套约定（画状态 / 画动作）都有人用，但
    // 「画反」是唯一没有辩护的说法。这里连「点了真的会变明文」一起钉。
    await startAndWaitModal(tester);
    await tester.tap(find.text('手动输入密码'));
    await tester.pumpAndSettle();

    EditableText field() =>
        tester.widget<EditableText>(find.byType(EditableText));

    expect(field().obscureText, isTrue, reason: '前提：默认是遮着的');
    expect(find.byIcon(Icons.visibility_off_outlined), findsOneWidget,
        reason: '遮着的时候画的是「看不见」那双眼');
    expect(find.byIcon(Icons.visibility_outlined), findsNothing,
        reason: '睁眼只属于已经亮出来的状态');

    await tester.tap(find.byIcon(Icons.visibility_off_outlined));
    await tester.pumpAndSettle();

    expect(field().obscureText, isFalse, reason: '点一下才该亮出来');
    expect(find.byIcon(Icons.visibility_outlined), findsOneWidget);
    expect(find.byIcon(Icons.visibility_off_outlined), findsNothing);

    // 再点一次收回去 —— 只验单向的话，画成「永远睁眼」也能过。
    await tester.tap(find.byIcon(Icons.visibility_outlined));
    await tester.pumpAndSettle();
    expect(field().obscureText, isTrue);
    expect(find.byIcon(Icons.visibility_off_outlined), findsOneWidget);

    await drainTimers(tester);
  });

  // -------------------------------------------------------------------------
  // 「如果失败就提示失败，保留在弹窗页面」
  // -------------------------------------------------------------------------

  testWidgets('手输错了 → 弹窗不关，就地提示「密码不正确」', (tester) async {
    await startAndWaitModal(tester);

    await tester.tap(find.text('手动输入密码'));
    await tester.pumpAndSettle();
    // 「返回」只在手输那一屏，「停止解压」只在选择那一屏 —— 拿这两颗按钮当
    // 屏幕判据，比找那句两句屏都有的说明文字可靠。
    expect(find.text('返回'), findsOneWidget, reason: '前提：已经进到手输那一屏');

    await typeAndSubmit(tester, 'typo');

    // 这一条是用户明确要求的：**留在弹窗页面**。关掉的话用户以为自己输进去
    // 了，其实什么都没发生 —— 而外面那个包已经没了。
    expect(find.byType(PasswordAttemptModal), findsOneWidget,
        reason: '输错了不该把弹窗关掉');
    expect(find.text('密码错误，请重试'), findsOneWidget);
    expect(find.text('停止解压'), findsNothing,
        reason: '前提：真的还在手输那一屏，不是回到了选择屏');

    // 再输错一次，提示还在（不是只提示一次就哑了）。
    await typeAndSubmit(tester, 'typo-again');
    expect(find.byType(PasswordAttemptModal), findsOneWidget);
    expect(find.text('密码错误，请重试'), findsOneWidget);

    // 输对了才关。
    await typeAndSubmit(tester, rightPassword);
    expect(find.byType(PasswordAttemptModal), findsNothing);
    await drainTimers(tester);
    expect(state.logs.firstWhere((l) => l.name == 'a.zip').status,
        LogStatus.success);
  });

  testWidgets('手输那屏能退回选择屏 —— 试了两下不想试了，还有跳过可点', (tester) async {
    await startAndWaitModal(tester);

    await tester.tap(find.text('手动输入密码'));
    await tester.pumpAndSettle();
    expect(find.text('返回'), findsOneWidget, reason: '前提：已经进到手输那一屏');

    await tester.tap(find.text('返回'));
    await tester.pumpAndSettle();

    expect(find.text('返回'), findsNothing);
    expect(find.text('停止解压'), findsOneWidget);

    await tester.tap(find.text('跳过'));
    await tester.pumpAndSettle();
    await drainTimers(tester);

    expect(state.logs.firstWhere((l) => l.name == 'a.zip').status,
        LogStatus.skipped);
  });

  testWidgets('空着直接点「确认」→ 提示，不当作「没输入」吞掉', (tester) async {
    await startAndWaitModal(tester);

    await tester.tap(find.text('手动输入密码'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();

    expect(find.byType(PasswordAttemptModal), findsOneWidget);
    expect(find.text('密码错误，请重试'), findsOneWidget);
    expect(engine.passwordsSeen, [''],
        reason: '空框里的那个空串不值得再拿引擎去试一次 —— 那会白解一遍整个包；'
            '流水账停在「开局那次空密码」上就说明没多试');
  });

  // -------------------------------------------------------------------------
  // 分不清「密码错」还是「文件坏」
  // -------------------------------------------------------------------------

  testWidgets('说不清的包 → 弹窗上明说两者无法区分', (tester) async {
    // 7z 的内容加密 / RAR3 没有校验字，错密码和坏数据在解码器眼里一模一样。
    // 「密码库未能解开该压缩包」读起来就是在说「密码的事」，而我们并不知道 ——
    // 这一档要**并列两种可能**，并且承认我们不知道。
    uncertainLock = true;
    await startAndWaitModal(tester);

    expect(
      find.text('密码库未能解开该压缩包，也可能是文件已损坏，两者无法区分'),
      findsOneWidget,
    );
    expect(find.text('密码库未能解开该压缩包'), findsNothing,
        reason: '原来那句话一个字都不该留在这一档上');

    // 手输那一屏同理：真拿它解过一遍之后，也不能断言「密码不正确」。
    await tester.tap(find.text('手动输入密码'));
    await tester.pumpAndSettle();
    await typeAndSubmit(tester, 'typo');

    expect(find.text('验证未通过：可能密码错误，也可能文件已损坏'), findsOneWidget);
    expect(find.text('密码错误，请重试'), findsNothing);

    await drainTimers(tester);
  });

  testWidgets('空框点「确认」→ 说不清的包也照旧说「密码不正确」', (tester) async {
    // 「没通过」是一句**断言试过**的话，而这条路上一次 `verify` 都没跑过。
    // 分不清的那一位不该把一次压根没发生的尝试说成发生过 —— 这是把
    // `bool _failed` 拆成 `emptyInput` / `rejected` 的唯一理由。
    uncertainLock = true;
    await startAndWaitModal(tester);

    await tester.tap(find.text('手动输入密码'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();

    expect(find.text('密码错误，请重试'), findsOneWidget);
    expect(find.text('验证未通过：可能密码错误，也可能文件已损坏'), findsNothing);

    await drainTimers(tester);
  });

  // -------------------------------------------------------------------------
  // 兜底
  // -------------------------------------------------------------------------

  testWidgets('滑走弹窗 → 兜底成「跳过」，整批不会因为误滑一下废掉', (tester) async {
    // 这条盯的是 `DialogBridge.askPassword` 里那句 `.then((_) => finish(skip))`。
    // `showBottomModal` 没设 `isDismissible: false`，点遮罩就能把弹窗关掉而
    // 三条回调一个都不触发 —— 少了那句兜底，这个 future 永远不完成，整批
    // 解压停在原地，而且没有任何报错。
    await startAndWaitModal(tester);

    // 遮罩铺在弹窗上方，点最上角必中遮罩。
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(find.byType(PasswordAttemptModal), findsNothing,
        reason: '前提：弹窗真的被关掉了');
    await drainTimers(tester);

    expect(state.extracting, isFalse, reason: '批次要真的收得了尾，不能悬着');
    expect(state.logs.firstWhere((l) => l.name == 'b.zip').status,
        LogStatus.success,
        reason: '误滑一下的代价只能是「放掉这一个包」');
  });
}
