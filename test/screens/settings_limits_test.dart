import 'package:deep_unzip/engine/limits.dart';
import 'package:deep_unzip/providers/app_state.dart';
import 'package:deep_unzip/screens/settings_screen.dart';
import 'package:deep_unzip/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_engine.dart';

/// 炸弹防护的设置界面：一个 chip 选档，选到「自定义」才展开成四行数值。
///
/// ## 为什么要专门给这截 UI 写 widget 测试
///
/// `app_state_test.dart` 里那一组已经钉住了 `setLimitPreset`/`setLimit` 的
/// 语义，`limits_test.dart` 钉住了阈值本身的判定。**两样都绿，这截 UI 仍然可以
/// 是坏的** —— 展开的条件写错、弹窗回参没接、行上的值没跟着刷新，全都不在
/// 那两个文件的覆盖范围内。而且这截 UI 的展开条件（认 chip 那一档，不认
/// 「值是不是等于某个预设」）正是最容易在重构里被"顺手简化"掉的地方。
void main() {
  // 和 home_screen_test 同样的理由：默认 `tap()` 打不中只警告不报错，
  // 「点了没反应」会在压根没点到的前提下通过。
  setUpAll(() => WidgetController.hitTestWarningShouldBeFatal = true);

  late AppState state;

  setUp(() {
    state = AppState(engine: FakeEngine());
  });

  tearDown(() => state.dispose());

  Future<void> pumpSettings(WidgetTester tester) async {
    // 设置页比一屏长得多（递归/识别/错误/炸弹/扩展五组），默认 800×600 会把
    // 炸弹防护那组整个挤出视口。调高画布让五组全部落在视口内。
    await tester.binding.setSurfaceSize(const Size(800, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.dark,
      home: Scaffold(body: SettingsScreen(state: state)),
    ));
  }

  /// 点 chip 切档。返回落在哪一档靠调用方断言，这里只负责点。
  Future<void> tapChip(WidgetTester tester, String label) async {
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
  }

  /// 打开某一行的数值弹窗。
  Future<void> openRow(WidgetTester tester, LimitField field) async {
    await tester.tap(find.text(field.label));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget, reason: '${field.label} 的弹窗没打开');
  }

  testWidgets('默认「标准」且不展开明细', (tester) async {
    await pumpSettings(tester);

    expect(find.text('解压上限'), findsOneWidget);
    expect(find.text('标准'), findsOneWidget);
    for (final field in LimitField.values) {
      expect(find.text(field.label), findsNothing,
          reason: '没切到自定义就不该有 ${field.label} 这一行');
    }

    expect(state.limits, LimitThresholds.standard);
  });

  testWidgets('切到「自定义」才展开四行，且值就是当前那套阈值', (tester) async {
    await pumpSettings(tester);

    // 标准 → 严格 → 自定义。**展开前两跳都要空着**，这是「展开只认 chip
    // 那一档、不认值」的外部表现。
    await tapChip(tester, '标准');
    expect(find.text('严格'), findsOneWidget);
    expect(find.text(LimitField.totalBytes.label), findsNothing,
        reason: '切到「严格」只是换预设，不该展开明细');

    await tapChip(tester, '严格');
    expect(find.text('自定义'), findsOneWidget);
    expect(state.limits, LimitThresholds.strict,
        reason: '进「自定义」时带过去的应该是上一档的值');

    for (final field in LimitField.values) {
      expect(find.text(field.label), findsOneWidget);
      expect(find.text(field.display(state.limits)), findsOneWidget,
          reason: '${field.label} 行上显示的值与 state 不一致');
    }
  });

  testWidgets('改一项：弹窗预填当前值，确定后落到 state 并刷新行上的字', (tester) async {
    await pumpSettings(tester);
    await tapChip(tester, '标准');
    await tapChip(tester, '严格');

    const field = LimitField.totalBytes;
    await openRow(tester, field);

    // 预填的是**展示形态**，不是裸字节数：用户看到的就是设置页那一行。
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        field.display(LimitThresholds.strict));

    await tester.enterText(find.byType(TextField), '4 GB');
    await tester.pump();
    expect(find.text('= 4.0 GB'), findsOneWidget, reason: '实时预览没跟上输入');

    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsNothing, reason: '确定之后弹窗该关掉');
    expect(state.limits.maxTotalBytes, 4 << 30);
    expect(find.text('4.0 GB'), findsOneWidget, reason: '行上的值没跟着刷新');
    expect(find.text('自定义'), findsOneWidget, reason: '手改一项之后 chip 该停在自定义');
  });

  testWidgets('认不出来的输入：确定按不动，值不变，弹窗留着', (tester) async {
    await pumpSettings(tester);
    await tapChip(tester, '标准');
    await tapChip(tester, '严格');
    final before = state.limits;

    await openRow(tester, LimitField.entries);
    await tester.enterText(find.byType(TextField), '十万');
    await tester.pump();

    expect(find.text('无法识别，改完再试'), findsOneWidget);

    // `warnIfMissed: false` 是**必须**的，不是图省事：置灰的实现是
    // `IgnorePointer`，所以这颗按钮真的收不到指针事件 —— 打不中正是要验的
    // 行为本身。用默认值会和上面那个 `hitTestWarningShouldBeFatal` 打架。
    await tester.tap(find.text('确定'), warnIfMissed: false);
    await tester.pumpAndSettle();

    // 悄悄兜成默认值会让用户以为自己改成功了 —— 所以宁可什么都不发生。
    expect(state.limits, before);
    expect(find.byType(TextField), findsOneWidget, reason: '没救回来就不该关弹窗');
  });

  testWidgets('手势滑走弹窗 → 当作取消，不改值', (tester) async {
    await pumpSettings(tester);
    await tapChip(tester, '标准');
    await tapChip(tester, '严格');
    final before = state.limits;

    await openRow(tester, LimitField.ratio);

    // 点弹窗外（遮罩区）关掉。`showBottomModal` 刻意没设
    // `isDismissible: false`/`enableDrag: false`，所以这条路真的走得通。
    await tester.tapAt(const Offset(400, 20));
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsNothing);
    expect(state.limits, before);
    expect(find.text('自定义'), findsOneWidget,
        reason: '取消不该把 chip 弹回预设');
  });

  testWidgets('切回预设档 → 明细收起来', (tester) async {
    await pumpSettings(tester);
    await tapChip(tester, '标准');
    await tapChip(tester, '严格');
    expect(find.text(LimitField.ratio.label), findsOneWidget);

    await tapChip(tester, '自定义'); // 自定义 → 宽松
    expect(find.text('宽松'), findsOneWidget);

    for (final field in LimitField.values) {
      expect(find.text(field.label), findsNothing,
          reason: '离开自定义就该收起 ${field.label}');
    }
    expect(state.limits, LimitThresholds.loose);
  });

  testWidgets('改动只落在这一项：同一次弹窗不许顺手带走别的阈值', (tester) async {
    await pumpSettings(tester);
    await tapChip(tester, '标准');
    await tapChip(tester, '严格');
    final before = state.limits;

    const field = LimitField.entryBytes;
    await openRow(tester, field);
    await tester.enterText(find.byType(TextField), '2 GB');
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(state.limits, before.copyWith(maxEntryBytes: 2 << 30));
  });
}
