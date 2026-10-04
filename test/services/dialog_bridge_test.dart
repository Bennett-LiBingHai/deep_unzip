import 'package:deep_unzip/app_navigator.dart';
import 'package:deep_unzip/engine/limits.dart';
import 'package:deep_unzip/services/blocked_prompt.dart';
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
}
