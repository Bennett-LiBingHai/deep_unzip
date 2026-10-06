import 'package:deep_unzip/data/builtin_extractors.dart';
import 'package:deep_unzip/data/persist.dart';
import 'package:deep_unzip/engine/limits.dart';
import 'package:deep_unzip/providers/app_state.dart';
import 'package:deep_unzip/screens/about_screen.dart';
import 'package:deep_unzip/screens/settings_screen.dart';
import 'package:deep_unzip/theme/app_theme.dart';
import 'package:deep_unzip/widgets/custom_button.dart';
import 'package:deep_unzip/widgets/modals/value_input_modal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_engine.dart';

/// 炸弹防护的设置界面：一个 chip 选档，四行阈值**始终**列着，「自定义」那一档
/// 才变成可编辑。
///
/// ## 为什么要专门给这截 UI 写 widget 测试
///
/// `app_state_test.dart` 里那一组已经钉住了 `setLimitPreset`/`setLimit` 的
/// 语义，`limits_test.dart` 钉住了阈值本身的判定。**两样都绿，这截 UI 仍然可以
/// 是坏的** —— 可编辑的条件写错、弹窗回参没接、行上的值没跟着刷新，全都不在
/// 那两个文件的覆盖范围内。而且这截 UI 的可编辑条件（认 chip 那一档，不认
/// 「值是不是等于某个预设」）正是最容易在重构里被"顺手简化"掉的地方。
///
/// 另外还有一条**很容易被"顺手简化"回去**的：预设档位下那四行也得在。
/// 只写一个「标准」，用户就是在看不见的数字上做选择。
void main() {
  // 和 home_screen_test 同样的理由：默认 `tap()` 打不中只警告不报错，
  // 「点了没反应」会在压根没点到的前提下通过。
  setUpAll(() => WidgetController.hitTestWarningShouldBeFatal = true);

  late AppState state;

  setUp(() {
    state = AppState(engine: FakeEngine());
  });

  tearDown(() => state.dispose());

  Future<void> pumpSettings(WidgetTester tester, {double height = 2800}) async {
    // 设置页比一屏长得多（递归/识别/错误/炸弹/日志/扩展六组），默认 800×600
    // 会把炸弹防护那组整个挤出视口。调高画布让六组全部落在视口内 ——
    // `ListView` 是按视口惰性挂载的，没进视口的那组连 `find` 都找不到。
    //
    // 解压方式那一组（十几张卡片）比其余几组加起来还长，盯它的用例得再高一截，
    // 所以留了这个口子。
    await tester.binding.setSurfaceSize(Size(800, height));
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

  /// 取某一行右侧那个数值。
  ///
  /// **必须按行取，不能全页 `find.text(value)`。** 标准档的「单文件上限」
  /// 是 8 GB，严格档的「解压总量上限」也是 8 GB —— 同一个字符串满页都是，
  /// 全页找会把两行串起来，于是「档位到底对不对」这件事根本验不出来。
  String rowValue(WidgetTester tester, LimitField field) {
    final row = find.ancestor(
      of: find.text(field.label),
      matching: find.byType(Row),
    );
    expect(row, findsOneWidget, reason: '${field.label} 那一行没找到');

    final texts = tester
        .widgetList<Text>(find.descendant(of: row, matching: find.byType(Text)))
        .map((t) => t.data)
        .whereType<String>()
        .toList();
    expect(texts, hasLength(2),
        reason: '${field.label} 那一行该只有「名字」和「数值」两个文本，实际是 $texts');
    return texts[1];
  }

  /// 打开某一行的数值弹窗。
  Future<void> openRow(WidgetTester tester, LimitField field) async {
    await tester.tap(find.text(field.label));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget, reason: '${field.label} 的弹窗没打开');
  }

  /// 某一行上有没有那支笔。
  ///
  /// **必须按行问**，不能全页 `find.byIcon(Icons.edit_outlined)` 数个数：设置页
  /// 上现在不止一行带笔（炸弹防护四行 + 日志条数那一行），全页计数会把别的行
  /// 算进来 —— 于是「预设档位下这几行不该带笔」会在笔跑到别的行上时照样通过。
  Finder pencilIn(String label) => find.descendant(
        of: find.ancestor(of: find.text(label), matching: find.byType(Row)),
        matching: find.byIcon(Icons.edit_outlined),
      );

  testWidgets('默认「标准」：四行照常列出来，但只读', (tester) async {
    await pumpSettings(tester);

    expect(find.text('解压上限'), findsOneWidget);
    expect(find.text('标准'), findsOneWidget);
    // 这一条是本次改动的核心：预设档位下数值也要摆出来。
    // 逐行比对而不是全页找 —— 见 [rowValue] 上面那段（严格档的 8 GB 与
    // 标准档的 8 GB 只差在哪一行）。
    for (final field in LimitField.values) {
      expect(rowValue(tester, field), field.display(LimitThresholds.standard),
          reason: '${field.label} 摆的不是「标准」这一档的数');
    }

    for (final field in LimitField.values) {
      expect(pencilIn(field.label), findsNothing,
          reason: '预设档位下 ${field.label} 不该带那支笔');
    }
    await tester.tap(find.text(LimitField.totalBytes.label));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing,
        reason: '只读的行点了不该弹编辑器 —— 接了点击却什么都不发生更让人困惑');

    expect(state.limits, LimitThresholds.standard);
  });

  testWidgets('切档只换数值，切到「自定义」才变成可编辑', (tester) async {
    await pumpSettings(tester);

    // 标准 → 严格：行还在，数值整体换成严格那一档，但仍然只读。
    await tapChip(tester, '标准');
    expect(find.text('严格'), findsOneWidget);
    expect(find.text(LimitField.totalBytes.label), findsOneWidget,
        reason: '换预设不等于把明细收起来');
    expect(rowValue(tester, LimitField.totalBytes),
        LimitField.totalBytes.display(LimitThresholds.strict),
        reason: '切到「严格」后行上的数该跟着换');
    for (final field in LimitField.values) {
      expect(pencilIn(field.label), findsNothing, reason: '换预设不等于变成可编辑');
    }

    // 严格 → 自定义：值带过去，且四行都长出笔来。
    await tapChip(tester, '严格');
    expect(find.text('自定义'), findsOneWidget);
    expect(state.limits, LimitThresholds.strict,
        reason: '进「自定义」时带过去的应该是上一档的值');
    for (final field in LimitField.values) {
      expect(pencilIn(field.label), findsOneWidget,
          reason: '自定义档位下 ${field.label} 该可编辑');
    }

    for (final field in LimitField.values) {
      expect(find.text(field.display(state.limits)), findsWidgets,
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

    expect(find.text('无法识别，请修改后重试'), findsOneWidget);

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

  testWidgets('切回预设档 → 行还在，只是变回只读并换成那一档的数', (tester) async {
    await pumpSettings(tester);
    await tapChip(tester, '标准');
    await tapChip(tester, '严格');
    for (final field in LimitField.values) {
      expect(pencilIn(field.label), findsOneWidget);
    }

    await tapChip(tester, '自定义'); // 自定义 → 宽松
    expect(find.text('宽松'), findsOneWidget);

    for (final field in LimitField.values) {
      expect(find.text(field.label), findsOneWidget,
          reason: '离开自定义不该把 ${field.label} 收起来 —— 那一档的数用户也得看得到');
      expect(rowValue(tester, field), field.display(LimitThresholds.loose),
          reason: '${field.label} 该换成「宽松」那一档的数');
    }
    for (final field in LimitField.values) {
      expect(pencilIn(field.label), findsNothing,
          reason: '离开自定义就该把 ${field.label} 那支笔收起来');
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

  // ---------------------------------------------------------------------------
  // 日志保留条数。和上面四行不一样：那是**选档**，这是**自由填数**。
  // ---------------------------------------------------------------------------

  /// 打开日志条数的输入框。返回时弹窗开着。
  Future<void> openLogLimit(WidgetTester tester) async {
    expect(find.text('$kDefaultMaxLogs 条'), findsOneWidget);
    await tester.tap(find.text('$kDefaultMaxLogs 条'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget, reason: '日志条数的弹窗没打开');
  }

  testWidgets('日志条数：预填当前值，填多少就是多少', (tester) async {
    await pumpSettings(tester);

    // 这一行带笔、四行阈值不带 —— 前者是点开填数，后者是点开选档。
    expect(pencilIn('日志保留条数'), findsOneWidget);
    expect(pencilIn(LimitField.totalBytes.label), findsNothing,
        reason: '炸弹防护那几行在默认档位下不该带笔');

    await openLogLimit(tester);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '$kDefaultMaxLogs', reason: '预填当前值，用户改的是数字不是重打一遍');

    await tester.enterText(find.byType(TextField), '347');
    await tester.pump();
    expect(find.text('= 347 条'), findsOneWidget, reason: '实时预览没跟上输入');

    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsNothing, reason: '确定之后弹窗该关掉');
    expect(state.maxLogs, 347, reason: '自由输入，347 不该被吸附成 300 或 500');
    expect(find.text('347 条'), findsOneWidget, reason: '行上的值没跟着刷新');
  });

  testWidgets('日志条数填到界外：说清范围，不给提交', (tester) async {
    await pumpSettings(tester);
    await openLogLimit(tester);

    await tester.enterText(find.byType(TextField), '999999');
    await tester.pump();
    expect(find.text('范围 $kMinMaxLogs – $kMaxMaxLogs 条'), findsOneWidget,
        reason: '越界要在预览行上直说');

    // `warnIfMissed: false` 的理由同「认不出来的输入」那条：置灰靠
    // `IgnorePointer`，打不中正是要验的行为本身。
    await tester.tap(find.text('确定'), warnIfMissed: false);
    await tester.pumpAndSettle();

    // 悄悄夹成 5000 会让用户以为自己填的数生效了。
    expect(state.maxLogs, kDefaultMaxLogs);
    expect(find.byType(TextField), findsOneWidget, reason: '没救回来就不该关弹窗');
  });

  // ---------------------------------------------------------------------------
  // 最大递归深度（2026-10 改的）
  // ---------------------------------------------------------------------------
  //
  // 这次一起动了两件事：那颗与它重复的「递归解压」开关撤掉，以及从「在
  // {0,5,10,20} 上循环」换成自由输入 —— `0` 的含义也从「无限制」翻成
  // 「不递归」。语义本身由 `cycles_test.dart` / `app_state_test.dart` 钉着，
  // 这里管的是**用户实际看到的那两颗字**：chip 上写什么、弹窗怎么回话。
  //
  // 「0 显示成『不递归』而不是『0 层』」是这截 UI 里唯一有歧义的地方 ——
  // 「0 层」读起来像是「浅浅地往下一层」，正好是反的。

  /// 「最大递归深度」那一行。
  Finder depthRow() => find.ancestor(
        of: find.text('最大递归深度'),
        matching: find.byType(Row),
      );

  /// 深度那一行上的三个文本：`[名字, 说明, chip 上的值]`。
  List<String> depthRowTexts(WidgetTester tester) {
    final texts = tester
        .widgetList<Text>(find.descendant(of: depthRow(), matching: find.byType(Text)))
        .map((t) => t.data)
        .whereType<String>()
        .toList();
    expect(texts, hasLength(3),
        reason: '深度那一行该有「名字 + 说明 + 值」三个文本，实际是 $texts');
    return texts;
  }

  /// 那一行右侧 chip 上的字。
  ///
  /// 取**最后一个**文本而不是第二个：与 [rowValue] 那几行不同，这一行有
  /// 「名字 + 说明 + 值」三个文本（阈值那几行没有说明）。
  String depthChipLabel(WidgetTester tester) => depthRowTexts(tester).last;

  /// 打开深度的输入框。返回时弹窗开着。
  Future<void> openDepth(WidgetTester tester) async {
    await tester.tap(find.text(depthChipLabel(tester)));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget, reason: '深度的弹窗没打开');
  }

  testWidgets('「递归解压」那颗开关整颗撤掉，取代它的是可填的深度 chip', (tester) async {
    await pumpSettings(tester);

    // 查的是**界面**而不是 `kDefaultToggles`：键从表里删了但界面还挂着一颗，
    // 那颗会静默读成 false（也就是「关着」）—— 表那半由 settings_repo_test
    // 钉，这里钉这一半。
    expect(find.text('递归解压'), findsNothing,
        reason: '与深度重复的那颗开关该整颗撤掉，不是只把行为接过去');

    expect(find.text('最大递归深度'), findsOneWidget);
    expect(depthChipLabel(tester), '$kDefaultMaxDepth 层');
    expect(pencilIn('最大递归深度'), findsOneWidget, reason: '自由输入的行才带笔');
  });

  testWidgets('「目录对称输出」换成了「自定义输出目录」，右边不带 chip', (tester) async {
    await pumpSettings(tester);

    // 旧名字描述的是**布局**（输出与源目录结构一致），而那个布局从来就是唯一
    // 的行为 —— `resolveOutputDir` 不读任何开关。所以那颗开关的值对磁盘没有
    // 任何影响，用户却以为自己关掉过什么。
    expect(find.text('目录对称输出'), findsNothing,
        reason: '描述「从来就如此」的开关是假开关，该整颗换掉');

    expect(find.text('自定义输出目录'), findsOneWidget);
    final row = find.ancestor(
      of: find.text('自定义输出目录'),
      matching: find.byType(Row),
    );
    final texts = tester
        .widgetList<Text>(find.descendant(of: row, matching: find.byType(Text)))
        .map((t) => t.data)
        .whereType<String>()
        .toList();
    expect(texts, hasLength(2),
        reason: '这一行该只有「名字 + 说明」——根目录每次重选、不落盘，'
            '没有任何值可以摆在右边，别硬加一个显示「未选择」的 chip');
    expect(texts[1], contains('根目录'));
    expect(texts[1], contains('同级'), reason: '关掉之后是什么行为也要交代');

    final toggle = find.descendant(of: row, matching: find.byType(NeonToggle));
    expect(tester.widget<NeonToggle>(toggle).value, isFalse,
        reason: '出厂关着 —— 也就是升级前**实际**发生的那件事');

    // 接线也要真接上，不能只摆一颗好看的开关。
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(state.setting('customOutput'), isTrue);
  });

  testWidgets('「支持的格式」默认折叠，只露出一个计数头', (tester) async {
    await pumpSettings(tester, height: 9000);

    // 三十来种格式、每张卡片三四行，展开就是两三千像素 —— 默认折叠，点开再看。
    expect(find.text('${BuiltinExtractors.all.length} 种格式'), findsOneWidget);
    expect(find.text('内置 7-Zip 核心'), findsNothing,
        reason: '折叠时一张卡片都不该渲染出来');
  });

  testWidgets('展开后每一条都摆出「识别」和「解压」，且没有 SINGLE/SPLIT', (tester) async {
    await pumpSettings(tester, height: 9000);
    await tester.tap(find.text('${BuiltinExtractors.all.length} 种格式'));
    await tester.pumpAndSettle();

    // 从前每张卡片只有一行被截到 60 字符的示意代码，**解压那栏压根没显示过**
    // —— 于是表里那句 `unzip -o {file} -d {dir}` 没有任何人会发现。
    expect(find.text('内置 7-Zip 核心'),
        findsNWidgets(BuiltinExtractors.all.length),
        reason: '每一条都该交代自己拿什么解，而答案只有这一个');

    // 那个假的二分整颗拆掉了：分卷是属性，不是跟「单文件」并列的一类。
    expect(find.text('SINGLE'), findsNothing);
    expect(find.text('SPLIT'), findsNothing);
    expect(find.text('单文件'), findsNothing);

    // 真支持的格式要看得见。用 `findsWidgets` 而不是 `findsOneWidget`：TAR 这类
    // 格式的方框标签跟名字是同一个字符串，会命中两个。
    expect(find.text('7-Zip'), findsWidgets);
    expect(find.text('CPIO'), findsWidgets);
    expect(find.text('ISO'), findsWidgets);
    expect(find.text('WIM'), findsWidgets);
    expect(find.text('DMG'), findsWidgets);

    // 再点一下收回去。
    await tester.tap(find.text('${BuiltinExtractors.all.length} 种格式'));
    await tester.pumpAndSettle();
    expect(find.text('内置 7-Zip 核心'), findsNothing);
  });

  testWidgets('展开状态不被 AppState 的通知冲掉', (tester) async {
    // `SettingsScreen` 外面套着 `ListenableBuilder`，每次 `AppState` 通知都整段
    // 重建。折叠位若放在它的方法里，任何一个开关一拨就会被重置回折叠 ——
    // 用户刚展开想看的东西自己合上了。
    await pumpSettings(tester, height: 9000);
    await tester.tap(find.text('${BuiltinExtractors.all.length} 种格式'));
    await tester.pumpAndSettle();
    expect(find.text('内置 7-Zip 核心'), findsWidgets);

    state.toggleSetting('errorPause');
    await tester.pumpAndSettle();

    expect(find.text('内置 7-Zip 核心'), findsWidgets,
        reason: '拨一个无关的开关，展开状态要原样留着');
  });

  testWidgets('注册新解压方式的入口已经撤掉', (tester) async {
    // 那个入口从来没接到引擎上：`addExtractor` 只往列表里加一行，识别靠嗅探表、
    // 解压靠内置 7-Zip 核心，没有任何一边读它，「已注册」的 toast 是假的。
    await pumpSettings(tester, height: 9000);
    await tester.tap(find.text('${BuiltinExtractors.all.length} 种格式'));
    await tester.pumpAndSettle();

    expect(find.text('注册新的解压方式'), findsNothing);
    expect(find.text('解压方式扩展'), findsNothing, reason: '旧栏目名');
    expect(find.text('支持的格式'), findsOneWidget);
    expect(find.byIcon(Icons.delete_outline), findsNothing,
        reason: '全部是内置的，没有哪一行删得掉');
  });

  testWidgets('「关于」入口在设置页最底下，点了能进关于页', (tester) async {
    // 这个入口不是「看一眼版本」那么简单：开源许可全文只能从这里到达，而那是
    // LGPL / BSD 要求分发时必须能拿到的东西。
    await pumpSettings(tester, height: 9000);

    await tester.drag(find.byType(ListView), const Offset(0, -6000));
    await tester.pumpAndSettle();

    expect(find.text('关于 DeepUnzip'), findsOneWidget);
    await tester.tap(find.text('关于 DeepUnzip'));
    await tester.pumpAndSettle();

    expect(find.byType(AboutScreen), findsOneWidget);
    expect(find.text('不联网 · 不收集个人信息'), findsOneWidget);
  });

  testWidgets('深度的说明把「子目录」和「嵌套包」两种都写出来', (tester) async {
    // 曾经只写了后半句（「解压出来的包再往下解几层」），而 `ScanItem.depth`
    // 实际是 `baseDepth + 目录层级` —— 两种**同等计入**。按那半句理解，用户
    // 会以为「子目录里的包被少解了一层」，而这其实是有意为之。
    //
    // 这条钉的是**说法本身**：字符串没写全就是 bug，不需要行为出错才叫 bug。
    await pumpSettings(tester);

    final desc = depthRowTexts(tester)[1];
    expect(desc, contains('子目录'), reason: '说明里少了「进子目录也算一层」这半句：$desc');
    expect(desc, contains('嵌套包'), reason: '说明里少了「解嵌套包算一层」那半句：$desc');

    await openDepth(tester);
    // 弹窗那份说明是**另一处**写的（`MaxDepthModal`），不是复用行上这句 ——
    // 所以两处都得钉。`find.descendant` 是必须的：行上那句还在树里（弹窗是
    // 浮在它上面的），全页找会同时撞上两个，看不出是哪一处漏了。
    final subtitle = find.descendant(
      of: find.byType(ValueInputModal),
      matching: find.textContaining('层'),
    );
    expect(
      tester.widgetList<Text>(subtitle).map((t) => t.data).join(),
      allOf(contains('子目录'), contains('嵌套包')),
      reason: '弹窗的说明与行上那句要写全同两件事',
    );
  });

  testWidgets('深度填 0 → chip 与弹窗都说「不递归」，不说「0 层」', (tester) async {
    await pumpSettings(tester);
    await openDepth(tester);

    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '$kDefaultMaxDepth', reason: '预填当前值');

    await tester.enterText(find.byType(TextField), '0');
    await tester.pump();
    expect(find.text('= 不递归'), findsOneWidget,
        reason: '0 是「关」而不是「浅浅地解一层」，预览行就得这么说');

    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsNothing, reason: '确定之后弹窗该关掉');
    expect(state.maxDepth, 0);
    expect(depthChipLabel(tester), '不递归',
        reason: 'chip 与弹窗必须是同一套说法，不然用户点开前不知道该信哪个');
  });

  testWidgets('深度是自由输入：填 7 就是 7，不吸附到档位', (tester) async {
    await pumpSettings(tester);
    await openDepth(tester);

    await tester.enterText(find.byType(TextField), '7');
    await tester.pump();
    expect(find.text('= 最多 7 层'), findsOneWidget);

    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(state.maxDepth, 7, reason: '不再是 {0,5,10,20} 那张表，7 不该被挪走');
    expect(depthChipLabel(tester), '7 层');
  });

  testWidgets('深度填到上界之外：说清上限，不给提交', (tester) async {
    await pumpSettings(tester);
    await openDepth(tester);

    await tester.enterText(find.byType(TextField), '${kMaxMaxDepth + 1}');
    await tester.pump();
    expect(find.text('最多 $kMaxMaxDepth 层'), findsOneWidget,
        reason: '越界要在预览行上直说');

    // `warnIfMissed: false` 的理由同上面两条：置灰靠 `IgnorePointer`。
    await tester.tap(find.text('确定'), warnIfMissed: false);
    await tester.pumpAndSettle();

    // 悄悄夹成 64 会让用户以为自己填的数生效了。
    expect(state.maxDepth, kDefaultMaxDepth);
    expect(find.byType(TextField), findsOneWidget, reason: '没救回来就不该关弹窗');
  });
}
