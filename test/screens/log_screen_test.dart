import 'package:deep_unzip/data/persist.dart';
import 'package:deep_unzip/models/log_entry.dart';
import 'package:deep_unzip/providers/app_state.dart';
import 'package:deep_unzip/screens/log_screen.dart';
import 'package:deep_unzip/theme/app_theme.dart';
import 'package:deep_unzip/widgets/modals/clear_logs_modal.dart';
import 'package:deep_unzip/widgets/modals/modal_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_engine.dart';
import '../support/fake_store.dart';

/// 日志页列表上方那条工具条：**当前条数**和**清空**（摆在筛选条下面）。
///
/// ## 为什么要专门给这截 UI 写 widget 测试
///
/// 条数这件事最容易写歪的地方是「数的是什么」——全部？当前筛选出来的？空态和
/// 计数打架的时候用户会以为日志丢了。清空则是一步**不可逆**的删除，测试要钉
/// 住的不是「按钮在不在」，而是「它有没有先问一道、问的是不是全部、取消之后
/// 是不是真的没动」。
void main() {
  // 和 home_screen_test 同样的理由：默认 `tap()` 打不中只警告不报错，
  // 「点了没反应」会在压根没点到的前提下通过。
  setUpAll(() => WidgetController.hitTestWarningShouldBeFatal = true);

  late FakeStore store;
  late AppState state;

  LogEntry entry(String name, LogStatus status) => LogEntry(
        name: name,
        status: status,
        size: '1.2 MB',
        time: '今天 14:32',
        duration: '0.8s',
        tags: const ['3 项'],
      );

  /// 挂上日志页，库存里预置 [logs]。
  Future<void> pumpLogs(
    WidgetTester tester, {
    List<LogEntry> logs = const [],
  }) async {
    store = FakeStore()..toLoad = AppSnapshot(logs: logs);
    state = AppState(
      engine: FakeEngine(),
      persistStore: store,
      restore: store.toLoad,
    );
    addTearDown(state.dispose);

    // 默认 800×600 放不下「头部 + 筛选条 + 三张卡」，`ListView` 按视口惰性
    // 挂载，没进视口的那几条连 `find` 都找不到。
    await tester.binding.setSurfaceSize(const Size(800, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.dark,
      home: Scaffold(body: LogScreen(state: state)),
    ));
  }

  /// 弹窗里的那颗按钮 —— 头部也有一颗写着「清空」的，全页找会撞上。
  Finder modalButton(String label) =>
      find.widgetWithText(ModalButton, label);

  /// 筛选条上那颗芯片。
  ///
  /// **必须圈到筛选条里找**：卡片右侧的状态角标用的是同一批字（`失败`、`跳过`
  /// ……），全页 `find.text('失败')` 会同时命中芯片和角标，`tap()` 直接报
  /// 「找到 2 个」。「全部」倒是满页独一份，但那个只是碰巧 —— 统一从这条路走。
  Finder filterChip(String label) => find.descendant(
        of: find.byType(SingleChildScrollView),
        matching: find.text(label),
      );

  /// 切一次筛选。
  Future<void> tapFilter(WidgetTester tester, String label) async {
    await tester.tap(filterChip(label));
    await tester.pumpAndSettle();
  }

  /// 页面上那颗清空按钮。
  Future<void> tapClear(WidgetTester tester) async {
    await tester.tap(find.text('清空'));
    await tester.pumpAndSettle();
  }

  group('当前条数', () {
    testWidgets('一条都没有 → 共 0 条，空态说「暂无记录」', (tester) async {
      await pumpLogs(tester);

      expect(find.text('共 0 条'), findsOneWidget);
      expect(find.text('暂无记录'), findsOneWidget);
    });

    testWidgets('有几条报几条 —— 数的是全部，不是当前筛选出来的', (tester) async {
      await pumpLogs(tester, logs: [
        entry('a.zip', LogStatus.success),
        entry('b.zip', LogStatus.failed),
        entry('c.zip', LogStatus.success),
      ]);

      expect(find.text('共 3 条'), findsOneWidget);
      expect(find.text('a.zip'), findsOneWidget);
    });

    testWidgets('筛选中给两个数 —— 只报筛出来那几条会让人以为别的被删了', (tester) async {
      await pumpLogs(tester, logs: [
        entry('a.zip', LogStatus.success),
        entry('b.zip', LogStatus.failed),
        entry('c.zip', LogStatus.success),
      ]);

      await tapFilter(tester, '失败');

      expect(find.text('筛出 1 / 共 3 条'), findsOneWidget);
      expect(find.text('b.zip'), findsOneWidget);
      expect(find.text('a.zip'), findsNothing, reason: '筛掉了就该不在正文里');
    });

    testWidgets('筛到空：说「这个分类下没有」而不是「暂无记录」', (tester) async {
      // 头部写着共 3 条、底下却说「暂无记录」，看起来就像日志被谁弄丢了。
      await pumpLogs(tester, logs: [
        entry('a.zip', LogStatus.success),
        entry('b.zip', LogStatus.failed),
      ]);

      await tapFilter(tester, '跳过');

      expect(find.text('筛出 0 / 共 2 条'), findsOneWidget);
      expect(find.text('该分类下暂无记录'), findsOneWidget);
      expect(find.text('暂无记录'), findsNothing);
    });
  });

  group('清空', () {
    testWidgets('一条都没有 → 按钮是死的，点了不弹任何东西', (tester) async {
      await pumpLogs(tester);

      // `warnIfMissed: false` 是**必须**的：置灰的实现是 `onTap: null`，
      // 那颗按钮真的收不到指针事件 —— 打不中正是要验的行为本身。
      await tester.tap(find.text('清空'), warnIfMissed: false);
      await tester.pumpAndSettle();

      expect(find.byType(ClearLogsModal), findsNothing);
    });

    testWidgets('先问一道 —— 弹窗里报出确切条数，并说明不可恢复', (tester) async {
      await pumpLogs(tester, logs: [
        entry('a.zip', LogStatus.success),
        entry('b.zip', LogStatus.failed),
      ]);

      await tapClear(tester);

      expect(find.byType(ClearLogsModal), findsOneWidget);
      expect(find.text('2 条记录'), findsOneWidget);
      expect(find.text('日志仅保存在本机，清空后无法恢复'), findsOneWidget);
    });

    testWidgets('筛选状态下点清空，弹窗报的是**全部**条数', (tester) async {
      // 屏幕上只看得见 1 张卡，删的却是 3 条 —— 问的那句话必须说全，
      // 否则用户以为只删眼前这一条。
      await pumpLogs(tester, logs: [
        entry('a.zip', LogStatus.success),
        entry('b.zip', LogStatus.failed),
        entry('c.zip', LogStatus.success),
      ]);

      await tapFilter(tester, '失败');
      await tapClear(tester);

      expect(find.text('3 条记录'), findsOneWidget, reason: '删的是全部，不是筛出来的那 1 条');
    });

    testWidgets('取消 → 一条没少，也没落盘', (tester) async {
      await pumpLogs(tester, logs: [entry('a.zip', LogStatus.success)]);
      final writesBefore = store.logsSaved.length;

      await tapClear(tester);
      await tester.tap(modalButton('取消'));
      await tester.pumpAndSettle();

      expect(state.logCount, 1);
      expect(find.text('共 1 条'), findsOneWidget);
      expect(store.logsSaved, hasLength(writesBefore), reason: '取消不该写盘');
    });

    testWidgets('手势滑走 = 取消 —— 手滑关掉不该等于同意', (tester) async {
      await pumpLogs(tester, logs: [entry('a.zip', LogStatus.success)]);

      await tapClear(tester);
      await tester.tapAt(const Offset(400, 20));
      await tester.pumpAndSettle();

      expect(find.byType(ClearLogsModal), findsNothing);
      expect(state.logCount, 1);
    });

    testWidgets('确认 → 当场清空 + 落盘 + 出声', (tester) async {
      await pumpLogs(tester, logs: [
        entry('a.zip', LogStatus.success),
        entry('b.zip', LogStatus.failed),
      ]);

      await tapClear(tester);
      await tester.tap(modalButton('清空'));
      await tester.pumpAndSettle();

      expect(find.byType(ClearLogsModal), findsNothing, reason: '确定之后弹窗该关掉');
      expect(state.logCount, 0);
      expect(find.text('共 0 条'), findsOneWidget, reason: '头部没跟着刷新');
      expect(find.text('暂无记录'), findsOneWidget);
      expect(store.lastLogs, isEmpty, reason: '删完得把空的那一份写出去');
      expect(state.toastMsg, '已清空 2 条日志记录');

      // 收尾：`showToast` 挂了个 2 秒后清空自己的定时器，`testWidgets` 结束时会
      // 检查有没有未完成的定时器 —— 不收掉就是一条跟被测行为无关的假失败。
      // 断言必须排在前面：真让这 2 秒走完，toast 会把自己清成 null。
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('清完停在筛选上也不打架 —— 空态说「暂无记录」，不是「这个分类下没有」',
        (tester) async {
      await pumpLogs(tester, logs: [entry('b.zip', LogStatus.failed)]);

      await tapFilter(tester, '失败');
      await tapClear(tester);
      await tester.tap(modalButton('清空'));
      await tester.pumpAndSettle();

      expect(state.logFilter, LogStatus.failed, reason: '清空不该顺手把筛选也重置了');
      expect(find.text('共 0 条'), findsOneWidget);
      expect(find.text('暂无记录'), findsOneWidget,
          reason: '一条都不剩了，这时「这个分类下没有」才是错的');

      await tester.pump(const Duration(seconds: 2)); // 收掉 toast 的定时器
    });
  });
}
