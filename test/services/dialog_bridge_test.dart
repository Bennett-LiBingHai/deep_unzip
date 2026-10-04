import 'package:deep_unzip/app_navigator.dart';
import 'package:deep_unzip/engine/limits.dart';
import 'package:deep_unzip/services/prompts.dart';
import 'package:deep_unzip/services/dialog_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// `DialogBridge` 唯一难的地方是 **future 一定会完成**。
///
/// `showBottomModal` 没有 `isDismissible: false` / `enableDrag: false`，
/// 所以用户点遮罩或下滑能直接把弹窗关掉，而两条回调一个都不触发。少了
/// `.then` 里的兜底，`Completer` 就永远悬着 —— 表现是整批解压停在原地，
/// 而且没有任何报错。所以「滑走」这条用例是这组里最重要的一个。
void main() {
  const breach = LimitBreach(
    kind: LimitKind.diskSpace,
    tag: '空间不足',
    message: '解压后需要 12.0 GB，设备只剩 3.2 GB，装不下，已放弃',
  );

  /// 挂一个带 [AppNavigator.key] 的壳 —— 桥接就是靠它拿 context 的。
  ///
  /// `navigatorKey` 传 null 时用来测「拿不到 context」那条分支。
  Future<void> mount(WidgetTester tester, {bool withKey = true}) async {
    await tester.pumpWidget(MaterialApp(
      navigatorKey: withKey ? AppNavigator.key : null,
      home: const Scaffold(body: Center(child: Text('底下的页面'))),
    ));
  }

  /// 弹一次窗，返回「用户会做出的那个决断」的 future。
  ///
  /// 返回的 future 此刻**还没完成**（要等对话框上的点击），调用方点完再 await
  /// 它。`await` 的这个 helper 只等服务弹窗动画结束 —— 别把这两件事写混了，
  /// 混了就会撞上 `pumpAndSettle` 未完成又调 `expect` 的 guarded conflict。
  Future<Future<BlockedDecision?>> askAndSettle(WidgetTester tester) async {
    final decision = const DialogBridge().askArchiveBlocked('a.zip', breach);
    await tester.pumpAndSettle();
    return decision;
  }

  testWidgets('点「停止这批」→ stop', (tester) async {
    await mount(tester);
    final future = await askAndSettle(tester);

    expect(find.text('a.zip'), findsOneWidget, reason: '爆的是哪个包要写在弹窗上');
    expect(find.text(breach.message), findsOneWidget);
    // 左边那颗**不能**叫「暂停任务」：暂停是可恢复的，而这一档把剩余队列丢掉。
    expect(find.text('暂停任务'), findsNothing);

    await tester.tap(find.text('停止这批'));
    await tester.pumpAndSettle();

    expect(await future, BlockedDecision.stop);
  });

  testWidgets('点「跳过继续」→ skip', (tester) async {
    await mount(tester);
    final future = await askAndSettle(tester);

    await tester.tap(find.text('跳过继续'));
    await tester.pumpAndSettle();

    expect(await future, BlockedDecision.skip);
  });

  testWidgets('点遮罩滑走 → 兜底成 skip，future 不会永远悬着', (tester) async {
    await mount(tester);
    final future = await askAndSettle(tester);

    // 遮罩铺在弹窗上方，点最上角必中遮罩。
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    expect(find.text('停止这批'), findsNothing, reason: '前提：弹窗真的被关掉了');
    expect(await future, BlockedDecision.skip,
        reason: '误滑一下不该废掉整批 —— 所以兜底是继续跑，不是停');
  });

  testWidgets('拿不到 context → 返回 null，不弹也不等', (tester) async {
    // MaterialApp 没挂 AppNavigator.key 时 currentContext 恒为 null。
    await mount(tester, withKey: false);

    // 外层的 await 只等挂载，内层那个才是决断 —— 而它应当**已经**是 null，
    // 不是悬着的（context 拿不到时桥接直接返回，不弹也不等）。
    final decision = await (await askAndSettle(tester));

    expect(decision, isNull,
        reason: 'null = 没弹。调用方据此补 toast，而不是当成用户选了某一项');
    expect(find.text('跳过继续'), findsNothing);
  });

  // -------------------------------------------------------------------------
  // 解压出错（需求 3）。与上面那个共用 ErrorModal，只有左边那颗的字不一样，
  // 而那个区别正是全部要害：「暂停任务」停得回来，「停止这批」停不回来。
  // -------------------------------------------------------------------------

  Future<Future<ExtractErrorDecision?>> askErrorAndSettle(
    WidgetTester tester,
  ) async {
    final decision =
        const DialogBridge().askExtractError('broken.zip', '文件损坏，读不出来');
    await tester.pumpAndSettle();
    return decision;
  }

  testWidgets('出错弹窗：左边那颗是「暂停任务」，且点了真的回 pause', (tester) async {
    await mount(tester);
    final future = await askErrorAndSettle(tester);

    expect(find.text('broken.zip'), findsOneWidget, reason: '要说清是哪个包');
    expect(find.text('文件损坏，读不出来'), findsOneWidget);
    expect(find.text('暂停任务'), findsOneWidget);
    // 这一档的暂停是**可恢复**的（复用 pauseExtract 那道闸门），所以绝不能
    // 复用闸门弹窗那颗「停止这批」—— 那两个弹窗长得一模一样，只有字不一样。
    expect(find.text('停止这批'), findsNothing);

    await tester.tap(find.text('暂停任务'));
    await tester.pumpAndSettle();

    expect(await future, ExtractErrorDecision.pause);
  });

  testWidgets('出错弹窗：点「跳过继续」→ skip', (tester) async {
    await mount(tester);
    final future = await askErrorAndSettle(tester);

    await tester.tap(find.text('跳过继续'));
    await tester.pumpAndSettle();

    expect(await future, ExtractErrorDecision.skip);
  });

  testWidgets('出错弹窗：滑走 → 兜底成 pause', (tester) async {
    await mount(tester);
    final future = await askErrorAndSettle(tester);

    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    expect(find.text('暂停任务'), findsNothing, reason: '前提：弹窗真的被关掉了');
    // 与闸门弹窗**相反**的兜底，而且这不是笔误：那一档的另一边是丢了队列的
    // 停止，误滑代价太大所以兜「继续跑」；这一档的暂停队列还在、点一下就回来，
    // 所以兜「可恢复的那个」。判据是同一个 —— 默认挑不会丢东西的。
    expect(await future, ExtractErrorDecision.pause);
  });

  testWidgets('出错弹窗：拿不到 context → null', (tester) async {
    await mount(tester, withKey: false);

    final decision = await (await askErrorAndSettle(tester));

    expect(decision, isNull);
    expect(find.text('暂停任务'), findsNothing);
  });

  // -------------------------------------------------------------------------
  // 后缀被篡改（需求 5）
  // -------------------------------------------------------------------------

  const info = FormatDetectInfo(
    fileName: 'fake.pdf',
    fakeExt: 'pdf',
    fileHeader: '0x504B0304',
    realFormat: 'ZIP 压缩包',
    action: '按 ZIP 压缩包 解压',
    hexPreview: '50 4B 03 04 14 00 00 00',
  );

  Future<Future<bool?>> askFormatAndSettle(WidgetTester tester) async {
    final decision = const DialogBridge().askFormatDetect(info);
    await tester.pumpAndSettle();
    return decision;
  }

  testWidgets('格式弹窗：把文件名和五项事实都摆出来', (tester) async {
    await mount(tester);
    final future = await askFormatAndSettle(tester);

    // 文件名必须显示：这个弹窗在一批几十个包的途中随时会弹出来，不说是在说
    // 哪个文件，用户不知道眼前这一下影响的是谁。
    expect(find.text('fake.pdf'), findsOneWidget);
    expect(find.text('pdf'), findsOneWidget);
    expect(find.text('0x504B0304'), findsOneWidget);
    expect(find.text('ZIP 压缩包'), findsOneWidget);
    expect(find.text('按 ZIP 压缩包 解压'), findsOneWidget);
    expect(find.text('50 4B 03 04 14 00 00 00'), findsOneWidget);

    await tester.tap(find.text('确认解压'));
    await tester.pumpAndSettle();
    expect(await future, isTrue);
  });

  testWidgets('格式弹窗：点「取消」→ false（明确不要这个包了）', (tester) async {
    await mount(tester);
    final future = await askFormatAndSettle(tester);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(await future, isFalse,
        reason: 'false 与 null 必须分得开：一个是不解，一个是没问成');
  });

  testWidgets('格式弹窗：滑走 → 兜底成 true（照原样解）', (tester) async {
    await mount(tester);
    final future = await askFormatAndSettle(tester);

    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    expect(find.text('确认解压'), findsNothing, reason: '前提：弹窗真的被关掉了');
    // 这个弹窗只是个**通报**：扫描阶段已经认定它是个压缩包、用户也选了要解。
    // 让「手滑一下」把包从批次里抹掉太狠了，所以兜底是退回加特性之前的行为。
    expect(await future, isTrue);
  });

  testWidgets('格式弹窗：拿不到 context → null（绝不能兜成 false）', (tester) async {
    await mount(tester, withKey: false);

    final decision = await (await askFormatAndSettle(tester));

    // 这条是这组里最要紧的一个：null 兜成 false 的话，弹窗因为拿不到 context
    // 而没能出现时，用户的压缩包会**凭空从批次里消失**，且没有任何解释。
    expect(decision, isNull);
  });
}
