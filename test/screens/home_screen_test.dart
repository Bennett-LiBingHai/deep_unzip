import 'dart:io';

import 'package:deep_unzip/engine/controller.dart';
import 'package:deep_unzip/providers/app_state.dart';
import 'package:deep_unzip/screens/home_screen.dart';
import 'package:deep_unzip/theme/app_theme.dart';
import 'package:deep_unzip/widgets/custom_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../engine/zip_fixtures.dart';
import '../support/fake_engine.dart';

/// 这组测试盯两件事：删掉的假弹窗真的没再出现，以及主按钮如实跟着引擎状态走
/// —— 静态分析查不出「点了之后不该弹的弹窗真的没弹」。
///
/// ## 为什么 `setUp` 里跑真扫描、`extract` 却用假引擎
///
/// 扫描要真的起 isolate、读真文件，本该放进 `tester.runAsync`。**但不能**：
/// `AppState` 若在测试体里构造，它内部的 `Completer` 就绑定在 `testWidgets`
/// 的 FakeAsync 区上，`complete()` 排出的微任务只在 `tester.pump()` 时才排空 ——
/// 而我们正阻塞在 `runAsync` 里等它完成，于是自锁，且测试级超时也不会触发
/// （假时钟不走）。把构造与扫描都挪到 `setUp` 就绕开了：`setUp` 跑在真实
/// 事件循环里（只有测试体被 FakeAsync 包住）。
///
/// 解压反过来：它一旦落进 FakeAsync 区就再也跑不完（真实 isolate 的消息排在
/// 假时钟外面，`pump` 推不动它），于是永远停在「解压中...」。用
/// [FakeEngine] 让整批解压在 `pump` 的几轮微任务里就跑完，测试体里观察到的
/// 才是「真的收尾了」而不是「卡住了」。
void main() {
  // 默认 `tap()` 打不中目标只打印警告、测试照过 —— 这正是本文件踩过的坑：
  // 「点了之后没有假弹窗」在压根没点到的前提下通过。改成致命。
  setUpAll(() => WidgetController.hitTestWarningShouldBeFatal = true);

  Widget app(AppState state) => MaterialApp(
        theme: AppTheme.dark,
        home: Scaffold(body: HomeScreen(state: state)),
      );

  /// 挂载首页。
  ///
  /// **必须先把画布调高**：默认 800×600 装不下「头部 + 文件夹卡 + 扫描结果 +
  /// 主按钮」，主按钮会落在视口外。`tester.tap` 打不中时只警告不报错，
  /// 于是「点了没有假弹窗」这类断言会在根本没点到的前提下通过 —— 假绿。
  ///
  /// 宽度保持默认的 800 不动：窄到手机宽度时头部那行等宽副标题会溢出，
  /// 但 `flutter test` 用的是固定宽度测试字体，比真机字体宽，溢出的 80px
  /// 大概率是这个假象而非真机问题 —— 拿不准的事不改 UI。
  Future<void> pumpHome(WidgetTester tester, AppState state) async {
    await tester.binding.setSurfaceSize(const Size(800, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(app(state));
  }

  /// `showToast` 会挂一个 2 秒定时器。在测试体里（FakeAsync 区）产生的
  /// 定时器不排空的话，`testWidgets` 收尾会判定「还有未完成的定时器」而失败。
  Future<void> drainTimers(WidgetTester tester) =>
      tester.pump(const Duration(seconds: 3));

  group('未选文件夹', () {
    late AppState state;

    setUp(() {
      state = AppState(engine: EngineController(throttle: Duration.zero));
    });
    tearDown(() => state.dispose());

    testWidgets('显示选择入口，主按钮禁用', (tester) async {
      await pumpHome(tester, state);

      expect(find.text('选择目标文件夹'), findsOneWidget);
      expect(find.text('开始智能解压'), findsOneWidget);

      final button = tester.widget<PrimaryButton>(find.byType(PrimaryButton));
      expect(button.disabled, isTrue, reason: '没扫描过就不该能点');
    });

    testWidgets('禁用态下点开始不会启动解压', (tester) async {
      await pumpHome(tester, state);

      // 禁用态下点击不该有任何副作用。
      await tester.tap(find.byType(PrimaryButton));
      await tester.pump();

      expect(state.extracting, isFalse);
      expect(find.byType(BottomSheet), findsNothing);
    });
  });

  group('已扫描', () {
    late AppState state;
    late Directory root;

    setUp(() async {
      root = makeTempDir('home_scan');
      File(p.join(root.path, 'a.zip')).writeAsBytesSync(realZip({'x': 'y'}));
      File(p.join(root.path, 'b.zip')).writeAsBytesSync(realZip({'x': 'y'}));

      state = AppState(engine: FakeEngine());
      await state.selectFolderPath(root.path);
    });

    tearDown(() {
      state.dispose();
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    testWidgets('显示扫描结果卡片，主按钮解除禁用', (tester) async {
      await pumpHome(tester, state);

      expect(find.text('扫描结果'), findsOneWidget);
      expect(find.text('2 个压缩包'), findsOneWidget);
      expect(find.text('a.zip'), findsOneWidget);

      final button = tester.widget<PrimaryButton>(find.byType(PrimaryButton));
      expect(button.disabled, isFalse);
      expect(button.label, '开始智能解压');

      await drainTimers(tester);
    });

    testWidgets('点「开始智能解压」真的走引擎：没有假弹窗，按钮如实跟着状态走',
        (tester) async {
      await pumpHome(tester, state);

      await tester.tap(find.byType(PrimaryButton));
      await tester.pump();

      // 老实现是 2/5/8 秒后分别弹密码 / 格式 / 错误三个弹窗。
      // 把它们的时间点全走一遍，一个都不该出现。
      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(seconds: 3));
        expect(find.byType(BottomSheet), findsNothing, reason: '假弹窗应已删除');
      }

      // P1 之后这里不再是「什么都没发生」：引擎真的被驱动了，整批跑完，
      // 按钮回到待启动态，完成横幅亮出来。这一条同时锁住了「收尾不漏状态」。
      expect(state.extracting, isFalse);
      expect(state.completed, isTrue);
      expect(state.logs.first.name, anyOf('a.zip', 'b.zip'));

      final button = tester.widget<PrimaryButton>(find.byType(PrimaryButton));
      expect(button.label, '开始智能解压');
      expect(button.disabled, isFalse, reason: '跑完了还能再点一次');

      await drainTimers(tester);
    });
  });
}
