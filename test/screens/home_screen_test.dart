import 'dart:async';
import 'dart:io';

import 'package:deep_unzip/engine/controller.dart';
import 'package:deep_unzip/engine/protocol.dart';
import 'package:deep_unzip/providers/app_state.dart';
import 'package:deep_unzip/screens/file_browser_screen.dart';
import 'package:deep_unzip/screens/home_screen.dart';
import 'package:deep_unzip/services/file_manager_bridge.dart';
import 'package:deep_unzip/theme/app_theme.dart';
import 'package:deep_unzip/widgets/custom_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../engine/zip_fixtures.dart';
import '../support/fake_engine.dart';

/// 给 [FileManagerBridge] 注入用的私有通道名。
///
/// 用独立的名字而不是生产那个 `com.bennett.deep_unzip/native`：生产名一旦被
/// 哪个测试钉上 mock 处理器却又忘了摘，会影响同文件里别的用例，而且看名字
/// 分不清这是真通道还是假的。
const MethodChannel _bridgeChannel = MethodChannel('deep_unzip_test/bridge');

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

  Widget app(AppState state, {FileManagerBridge? bridge, List<String>? roots}) =>
      MaterialApp(
        theme: AppTheme.dark,
        home: Scaffold(
          body: HomeScreen(state: state, bridge: bridge, browserRoots: roots),
        ),
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
  Future<void> pumpHome(WidgetTester tester, AppState state,
      {FileManagerBridge? bridge, List<String>? roots}) async {
    await tester.binding.setSurfaceSize(const Size(800, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(app(state, bridge: bridge, roots: roots));
  }

  /// `showToast` 会挂一个 2 秒定时器。在测试体里（FakeAsync 区）产生的
  /// 定时器不排空的话，`testWidgets` 收尾会判定「还有未完成的定时器」而失败。
  Future<void> drainTimers(WidgetTester tester) =>
      tester.pump(const Duration(seconds: 3));

  /// 推帧 + **让真实的文件 I/O 落地**。
  ///
  /// 自建浏览器的列目录走真 `dart:io`，而测试体包在 FakeAsync 里 —— 推假时钟
  /// 推不动真 I/O，只写 `pumpAndSettle` 会一直等到超时（见 memory
  /// `fakeasync-real-io-trap`）。`runAsync` 切回真事件循环，再推一帧把它的
  /// continuation 从 fake 区的微任务队列里排出来；这两步要交替做几次才够。
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  /// 手动推 [n] 帧，每帧 100ms。
  ///
  /// 解压中那颗转圈的 `CircularProgressIndicator`（`home_screen.dart:662`，
  /// 没给 `value` → 无限动画）会一直排下一帧，只要它在屏幕上 `pumpAndSettle`
  /// 就永远等不到头。批次跑得快时面板会自己消失、侥幸能 settle；一旦用例
  /// 故意把引擎卡住，面板就赖着不走，`pumpAndSettle` 必超时。这些用例只能
  /// 用固定帧数推进 —— 够走完弹窗那 ~250ms 的收场动画即可。
  Future<void> pumpFrames(WidgetTester tester, [int n = 8]) async {
    for (var i = 0; i < n; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  group('未选文件夹', () {
    late AppState state;

    setUp(() {
      state = AppState(engine: EngineController(throttle: Duration.zero));
    });
    tearDown(() => state.dispose());

    testWidgets('显示选择入口，主按钮禁用', (tester) async {
      await pumpHome(tester, state);

      // **一颗入口**，不是两颗。选的是文件还是文件夹由用户在浏览器里点的是什么
      // 决定（见 `HomeScreen._pickTarget`），所以这里不该出现「选文件夹 / 选文件」
      // 这种要用户先想清楚自己属于哪一种的分叉。
      expect(find.text('选择目标文件 / 文件夹'), findsOneWidget);
      expect(find.text('开始解压'), findsOneWidget);

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

    testWidgets('头部摆的是应用标记那张资源，不是通用图标', (tester) async {
      await pumpHome(tester, state);

      // 只读配置、不等它解码 —— 断言的是「挂的是哪张图」，而解码与否是
      // 资源打包的事，不归这条管。
      final logo = tester.widget<Image>(find.descendant(
        of: find.byType(HomeScreen),
        matching: find.byType(Image),
      ));
      expect((logo.image as AssetImage).assetName, 'assets/logo.png');
      expect(find.byIcon(Icons.layers), findsNothing,
          reason: '换掉了就别再留着那个通用图标');
    });
  });

  group('已扫描', () {
    late AppState state;
    late FakeEngine engine;
    late Directory root;

    setUp(() async {
      root = makeTempDir('home_scan');
      File(p.join(root.path, 'a.zip')).writeAsBytesSync(realZip({'x': 'y'}));
      File(p.join(root.path, 'b.zip')).writeAsBytesSync(realZip({'x': 'y'}));

      engine = FakeEngine();
      state = AppState(engine: engine);
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
      expect(button.label, '开始解压');

      await drainTimers(tester);
    });

    /// 走一遍「点主按钮 → 确认弹窗 → 整批跑完」。
    Future<void> runBatch(WidgetTester tester) async {
      await tester.tap(find.byType(PrimaryButton));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认解压'));
      await tester.pumpAndSettle();
    }

    testWidgets('点「开始解压」先弹确认，确认后才真的走引擎', (tester) async {
      await pumpHome(tester, state);

      await tester.tap(find.byType(PrimaryButton));
      await tester.pumpAndSettle();

      // 解压会真往磁盘写目录，重名时追加 `_1`/`_2` 而不是覆盖 —— 点错一次
      // 留下一堆重复目录只能人工删。所以写之前先让用户看一眼。
      expect(find.text('待解压'), findsOneWidget);
      expect(find.text('2 个压缩包'), findsNWidgets(2),
          reason: '扫描结果卡片里一个，确认弹窗里一个');
      expect(state.extracting, isFalse, reason: '确认之前不该开工');

      await tester.tap(find.text('确认解压'));
      await tester.pumpAndSettle();

      // 老实现是 2/5/8 秒后分别弹密码 / 格式 / 错误三个弹窗。
      // 把它们的时间点全走一遍，一个都不该出现。
      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(seconds: 3));
        expect(find.byType(BottomSheet), findsNothing, reason: '假弹窗应已删除');
      }

      // P1 之后这里不再是「什么都没发生」：引擎真的被驱动了，整批跑完，
      // 完成横幅亮出来。这一条同时锁住了「收尾不漏状态」。
      expect(state.extracting, isFalse);
      expect(state.outcome, BatchOutcome.clean);
      expect(find.text('全部解压完成'), findsOneWidget);
      expect(state.logs.first.name, anyOf('a.zip', 'b.zip'));

      // 跑过一轮之后主按钮换成「更换目标」。**不能再是「开始解压」**：
      // 再点一次不是重解，而是把同一个队列重排一遍，输出目录重名会撒出
      // `_1`/`_2` 的重复目录（见 output_paths.dart）。
      final button = tester.widget<PrimaryButton>(find.byType(PrimaryButton));
      expect(button.label, '更换目标');
      expect(button.disabled, isFalse, reason: '更换目标是脱困路径，不能禁用');

      await drainTimers(tester);
    });

    testWidgets('开了「自定义输出目录」→ 点开始先开选择页，并且那页上带着出路', (tester) async {
      // 顺序不能反：确认弹窗上那行「输出到」得是真的。反过来的话，用户是在
      // 一个还不知道往哪写的界面上点的「确认解压」。
      state.toggleSetting('customOutput');
      await pumpHome(tester, state, roots: [root.path]);

      await tester.tap(find.byType(PrimaryButton));
      await settle(tester);

      // 从前的流程是「先弹一页说明，再开**系统**选择器」—— 那页说明存在的唯一
      // 理由是系统选择器上写不了标题。自建浏览器自己有标题、页头里也写着怎么
      // 关掉这一档，所以那一页没了，顺手少一次点击。
      expect(find.byType(FileBrowserScreen), findsOneWidget);
      expect(find.text('选择输出根目录'), findsOneWidget);
      expect(find.textContaining('关掉「自定义输出目录」'), findsOneWidget,
          reason: '这一档每次都要选，嫌烦的人得能当场看到怎么关掉它');
      expect(find.text('待解压'), findsNothing, reason: '还没走到确认解压');
      expect(state.extracting, isFalse);
      expect(engine.rounds, 0);
    });

    testWidgets('选择页点返回退出 → 这批不解，而且要出声', (tester) async {
      state.toggleSetting('customOutput');
      await pumpHome(tester, state, roots: [root.path]);

      await tester.tap(find.byType(PrimaryButton));
      await settle(tester);
      await tester.binding.handlePopRoute();
      await settle(tester);

      expect(find.byType(FileBrowserScreen), findsNothing);
      // **与「说明页上按取消」不是一回事**：那是用户在自己的界面上明确点了取消，
      // 他知道自己放掉了什么；这里是按了「开始解压」、被推进一个选择页、又退出来
      // —— 一声不吭的话看着就像按钮坏了。所以这一档要出声。
      expect(state.toastType, 'info');
      expect(state.toastMsg, contains('未选择输出目录'));
      expect(state.extracting, isFalse);
      expect(engine.rounds, 0);

      await drainTimers(tester);
    });

    testWidgets('选择页里选了根 → 确认弹窗上「输出到」就是那个根', (tester) async {
      // 输出根**必须与源目录不同**：同一个路径的话，「输出到」那行和首页文件夹卡
      // 上那行是同一串字，`find.text` 会同时命中两处，断言就测不出东西了。
      final outRoot = makeTempDir('home_outroot');
      addTearDown(() {
        if (outRoot.existsSync()) outRoot.deleteSync(recursive: true);
      });
      state.toggleSetting('customOutput');
      await pumpHome(tester, state, roots: [outRoot.path]);

      await tester.tap(find.byType(PrimaryButton));
      await settle(tester);
      await tester.tap(find.text('选择此文件夹'));
      await settle(tester);

      // 这条同时钉住了「先问位置、再问确认」那个顺序：确认弹窗上显示的应当是刚选
      // 的那个根，而不是源目录。
      expect(state.outputRoot, outRoot.path);
      expect(find.text('待解压'), findsOneWidget);
      // **按弹窗圈着找**：首页那张文件夹卡还在弹窗底下，源目录那串字仍然在树里。
      final inModal = find.descendant(
        of: find.byType(BottomSheet),
        matching: find.text(outRoot.path),
      );
      expect(inModal, findsOneWidget, reason: '「输出到」那行应当是刚选的那个根');
      expect(
        find.descendant(
          of: find.byType(BottomSheet),
          matching: find.text(root.path),
        ),
        findsNothing,
        reason: '自定义输出目录时输出不在源目录，那行不该还写着源目录',
      );
      expect(state.extracting, isFalse, reason: '还没点确认');

      await drainTimers(tester);
    });

    testWidgets('确认弹窗点取消 → 不起任务，主按钮原样留着', (tester) async {
      await pumpHome(tester, state);

      await tester.tap(find.byType(PrimaryButton));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      expect(state.extracting, isFalse);
      expect(state.outcome, isNull, reason: '取消 = 这批压根没跑过');
      expect(state.batchRun, isFalse, reason: '取消不算「这批用掉了」');
      expect(find.text('全部解压完成'), findsNothing);

      final button = tester.widget<PrimaryButton>(find.byType(PrimaryButton));
      expect(button.label, '开始解压');

      await drainTimers(tester);
    });

    testWidgets('跑完一批后主按钮改成「更换目标」，且再点不会重排队列',
        (tester) async {
      await pumpHome(tester, state, roots: [root.path]);
      await runBatch(tester);

      expect(state.batchRun, isTrue);

      final rounds = engine.rounds;

      // 点它**不会重新解一遍**，而是弹出选择页 —— 那才是这次改动要堵的洞
      // （重排队列会往磁盘撒 `_1`/`_2` 重复目录）。
      await tester.tap(find.byType(PrimaryButton));
      await settle(tester);

      expect(engine.rounds, rounds, reason: '重排队列会往磁盘撒 _1/_2 重复目录');
      expect(find.byType(FileBrowserScreen), findsOneWidget,
          reason: '这一档的语义是「换一个」，所以该去选路径');

      await drainTimers(tester);
    });

    testWidgets('解压中点主按钮 → 请求停止，剩下的包不再开工', (tester) async {
      // 把批次卡在第一个包上，好让「解压中」这一刻停住 —— 否则整批会在一两个
      // pump 里跑完，压根没有「正在解压」可观察。
      final blocked = Completer<void>();
      engine.behavior = (_, outDir) => blocked.future;

      await pumpHome(tester, state, roots: [root.path]);
      await tester.tap(find.byType(PrimaryButton));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认解压'));
      // 从这里起进度面板就挂上去了，转圈那颗会一直排帧 —— 不能再 pumpAndSettle。
      await pumpFrames(tester);

      String label() =>
          tester.widget<PrimaryButton>(find.byType(PrimaryButton)).label;

      expect(state.extracting, isTrue);
      expect(label(), '停止解压');

      // 点一下 = 停止。**不是暂停** —— 这一档不可恢复，当前包被真正打断，
      // 队列里剩下的直接丢掉，所以按钮写的就是「停止」这两个字。从前这里
      // 是「暂停 / 继续」两颗交替，用户明确要求去掉：弹窗里那颗「继续」已经
      // 承担了「接着跑」的意思，主按钮再留一个「继续」就重了。
      await tester.tap(find.byType(PrimaryButton));
      await pumpFrames(tester, 4);

      // **取消真的送到引擎了**：不再是「只置一个标志、等当前包解完」。
      expect(engine.cancelCalls, 1);

      // 但**不是瞬间**：原生侧要在下一个进度点才 unwind，这期间按钮不变
      // —— 它只是不再重复发请求（`stopExtract` 开头就挡了回去）。
      expect(state.extracting, isTrue, reason: '引擎还没 unwind 完');
      expect(label(), '停止解压');
      await tester.tap(find.byType(PrimaryButton));
      await pumpFrames(tester, 2);
      expect(engine.cancelCalls, 1, reason: '重复点不该重复发取消');

      // 放行 —— 引擎到这里才走完一轮，且是**以「被中止」收场**，批次的收尾
      // 逻辑这才轮得到跑。
      blocked.complete();
      await pumpFrames(tester);

      expect(state.extracting, isFalse);
      expect(engine.rounds, 1, reason: '停止之后 b.zip 一个字节都不该动');

      // 停在半路也要落在**总结页**上（真机验收时用户要求的）：卡片标题写
      // 「已停止」，主按钮换成「更换目标」。从前这里退回「开始解压」，
      // 看起来像什么都没发生过 —— 用户会以为点下去能接着解剩下那个，
      // 而实际是把已经解好的重解一遍、撒出 `_1` 目录。
      expect(find.text('已停止'), findsOneWidget);
      expect(find.text('全部解压完成'), findsNothing,
          reason: '一个包都没解完却写「全部完成」是假话');
      // **被中止的那个包不算「已完成」**：磁盘上只有半棵树，算进去是假话。
      expect(find.textContaining('已完成 0/2 个压缩包'), findsOneWidget);
      expect(label(), '更换目标');

      await drainTimers(tester);
    });

    testWidgets('整批都失败 → 照样落在总结页上，标题是「全部失败」', (tester) async {
      // 真机上发现的洞：关掉「错误时暂停」之后，失败不再弹窗、直接记一条
      // 失败接着跑，于是整批打完时 `failed == total` —— 而总结卡片的显示
      // 条件当时挂的是 `completed`（= 全部成功），全败时是 false，于是
      // **一张卡片都不出**，界面退回扫描结果那张表，像什么都没发生过。
      //
      // 病根是 `completed` 被当成了「这批跑完了」用。它说的一直是「全部成功」，
      // 「跑完了」是 `batchRun` 的事（见 `app_state.dart` 里 `_batchRun` 的
      // 说明）。这条用例钉住两者各归各位。
      engine.behavior = (_, outDir) async {
        throw const EngineException('这个包坏了', code: DuzErrorCode.extract);
      };

      await pumpHome(tester, state);
      await tester.tap(find.byType(PrimaryButton));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认解压'));
      await tester.pumpAndSettle();

      expect(state.extracting, isFalse);
      expect(state.batchRun, isTrue, reason: '前提：这一批确实跑过了');
      // 全失败当然不是「全部解压完成」—— 绿色那张卡在这里是句假话。
      expect(find.text('全部解压完成'), findsNothing);
      expect(find.text('全部失败'), findsOneWidget);
      expect(find.textContaining('2 个失败'), findsOneWidget);

      final button = tester.widget<PrimaryButton>(find.byType(PrimaryButton));
      expect(button.label, '更换目标',
          reason: '总结页该带的脱困路径，全败时更要有');

      await drainTimers(tester);
    });

    testWidgets('部分失败 → 也落在总结页上，不说「全部完成」', (tester) async {
      // 全败是上面那条的极端。这条是「3 个里坏了 1 个」—— 从前它反而会出
      // 卡片，却顶着「全部解压完成」这个标题，同样是假话。
      engine.behavior = (e, outDir) async {
        if (e.rounds == 1) {
          throw const EngineException('第一个坏了', code: DuzErrorCode.extract);
        }
      };

      await pumpHome(tester, state);
      await tester.tap(find.byType(PrimaryButton));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认解压'));
      await tester.pumpAndSettle();

      expect(find.text('全部解压完成'), findsNothing);
      expect(find.text('部分失败'), findsOneWidget);
      expect(find.textContaining('1 个失败'), findsOneWidget);
      expect(find.textContaining('1/2 个压缩包'), findsNothing,
          reason: '跑完整批就不该写成「已完成 1/2」—— 那是被停下来的说法');

      await drainTimers(tester);
    });

    testWidgets('解压中「更换」按不动，跑完才解禁', (tester) async {
      // 解压是 `unawaited(_runExtractBatch())` 起的后台流程，跑起来之后谁也拦
      // 不住；这时候换目录会把 `_folderPath` 和扫描列表全清掉重建，而批次还在
      // 按**旧**队列往磁盘上写。真机验收时发现「解压的时候可以点更换」。
      final blocked = Completer<void>();
      engine.behavior = (_, outDir) => blocked.future;

      await pumpHome(tester, state);
      await tester.tap(find.byType(PrimaryButton));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认解压'));
      await pumpFrames(tester);

      // 前提：此刻「更换」还占着位置，只是不响应 —— 藏起来会让布局跳动。
      // 它是一个纯 `Text` 占位（`_buildFolderSelected` 的 extracting 分支），
      // 不是那颗可点的 `_replaceButton`；下面按下去没反应正是这条的证据。
      expect(find.text('更换'), findsOneWidget);
      final before = state.folderPath;
      await tester.tap(find.text('更换'));
      await pumpFrames(tester, 2);
      expect(state.folderPath, before, reason: '解压中换目录会把批次和界面对不上');
      expect(state.extracting, isTrue, reason: '更不该顺手把批次停掉');

      blocked.complete();
      await pumpFrames(tester);
      await drainTimers(tester); // 先让收尾那条 toast 过期，免得下面认错人

      // 跑完之后它得真的活过来 —— 检查一遍「只会禁用、忘了解禁」那种写法。
      //
      // 判据是「选择页真的弹出来了」：跑完之后那颗占位文字换成可点的「更换」，
      // 点下去会开浏览器。比只看灰不灰可靠 —— 灰掉却点不动的写法同样能骗过前者。
      expect(state.toastMsg, isNull, reason: '前提：上一条 toast 已经过期');
      await tester.tap(find.text('更换'));
      // **只推到「路由压上来了」就够，不等它列完目录**：这条要验的是「解禁」，
      // 而列举是真 I/O —— 推假时钟推不动它（要走 runAsync 那套，而这一条里
      // 刚跑完一批真解压，那套在这里不稳）。断言「按下去真的进了选择流程」，
      // 与从前断言「弹了那条选择器失败的 toast」是同一个意思。
      await pumpFrames(tester, 3);
      expect(find.byType(FileBrowserScreen), findsOneWidget,
          reason: '跑完之后「更换」要能按 —— 禁用只说了一半，还得会解禁');

      await drainTimers(tester);
    });
  });

  group('打开输出目录', () {
    late AppState state;
    late Directory root;
    late List<MethodCall> calls;

    setUp(() async {
      root = makeTempDir('home_open');
      File(p.join(root.path, 'a.zip')).writeAsBytesSync(realZip({'x': 'y'}));

      state = AppState(engine: FakeEngine());
      await state.selectFolderPath(root.path);
      calls = [];
    });

    tearDown(() {
      state.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_bridgeChannel, null);
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    /// 让原生通道回一个指定的结果码。
    void stubNative(String? code) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_bridgeChannel, (call) async {
        calls.add(call);
        return code;
      });
    }

    Future<void> pumpAndRun(WidgetTester tester, {bool isAndroid = true}) async {
      await pumpHome(
        tester,
        state,
        bridge: FileManagerBridge(channel: _bridgeChannel, isAndroid: isAndroid),
      );
      await tester.tap(find.byType(PrimaryButton));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认解压'));
      await tester.pumpAndSettle();
      expect(find.text('打开输出目录'), findsOneWidget);
    }

    testWidgets('opened → 只回 toast，不弹兜底弹窗', (tester) async {
      stubNative('opened');
      await pumpAndRun(tester);

      await tester.tap(find.text('打开输出目录'));
      await tester.pumpAndSettle();

      expect(calls.single.method, 'openFolderInFileManager');
      expect(calls.single.arguments['path'], root.path,
          reason: '要打开的是用户选的那个根目录');
      expect(state.toastType, 'ok');
      expect(find.byType(BottomSheet), findsNothing,
          reason: '真的打开了就别再拿路径烦用户');

      await drainTimers(tester);
    });

    testWidgets('opened_generic → 弹兜底弹窗，把路径原样交给用户', (tester) async {
      // 国产 ROM 上的常态：文件管理器开了，但没跳到目标目录。
      // 这时候假装成功，用户就会对着一个不相干的目录找半天。
      stubNative('opened_generic');
      await pumpAndRun(tester);

      await tester.tap(find.text('打开输出目录'));
      await tester.pumpAndSettle();

      expect(find.text('无法定位到目录'), findsOneWidget);
      // 用 SelectableText 而不是 `find.text(路径)`：路径在头部那张文件夹卡里
      // 也有一份（而且 SelectableText 自己会渲染成两个 widget），按文本找会
      // 命中一堆。直接看弹窗里那份的内容才是想验的事。
      expect(tester.widget<SelectableText>(find.byType(SelectableText)).data,
          root.path,
          reason: '路径要原样摆出来，能选中、能复制');
      expect(find.text('复制路径'), findsOneWidget);

      await drainTimers(tester);
    });

    testWidgets('no_handler → 同样给路径，不说「已打开」', (tester) async {
      stubNative('no_handler');
      await pumpAndRun(tester);

      await tester.tap(find.text('打开输出目录'));
      await tester.pumpAndSettle();

      expect(find.text('没有可用的文件管理器'), findsOneWidget);
      expect(tester.widget<SelectableText>(find.byType(SelectableText)).data,
          root.path);

      await drainTimers(tester);
    });

    testWidgets('通道不可用（unavailable）→ 也不静默失败', (tester) async {
      // 用「非 Android 平台」来构造 unavailable，而不是「通道没注册」——
      // 后者在 widget 测试里取决于 messenger 对无 handler 通道的处理，
      // 断起来不稳；平台分支是确定的，而且它和真机上的缺席走同一条出口。
      // `MissingPluginException` 那条路由 `file_manager_bridge_test.dart` 兜。
      await pumpAndRun(tester, isAndroid: false);

      await tester.tap(find.text('打开输出目录'));
      await tester.pumpAndSettle();

      expect(find.text('当前环境不支持'), findsOneWidget);
      expect(calls, isEmpty, reason: '平台不支持就不该去惊动原生');

      await drainTimers(tester);
    });
  });

  group('角标间距', () {
    late AppState state;
    late Directory root;

    setUp(() async {
      root = makeTempDir('home_badges');
      // 加密、但后缀被改成了 .dat → 一个条目上挂两个角标。真机上用户报
      // 「标签粘在一起」的就是这一格（`伪装成图片.dat`）。
      File(p.join(root.path, 'locked.dat'))
          .writeAsBytesSync(encryptedZip({'a.txt': 'x'}));

      state = AppState(engine: FakeEngine());
      await state.selectFolderPath(root.path);
    });

    tearDown(() {
      state.dispose();
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    testWidgets('一个条目上的多个角标之间留得出缝', (tester) async {
      await pumpHome(tester, state);

      // 角标的字必须**圈着角标找**：筛选芯片里也有「加密」两个字，
      // 直接 find.text('加密') 会连着芯片一起数进来。
      expect(
        find.descendant(
            of: find.byType(FlagBadge), matching: find.text('加密')),
        findsOneWidget,
      );
      expect(
        find.descendant(
            of: find.byType(FlagBadge), matching: find.text('伪后缀')),
        findsOneWidget,
      );

      final badges = find.byType(FlagBadge);
      expect(badges, findsNWidgets(2));
      final rects = [for (var i = 0; i < 2; i++) tester.getRect(badges.at(i))]
        ..sort((a, b) => a.left.compareTo(b.left));

      // 不断言缝**等于**几个像素 —— 那是实现细节，改样式就会误报。断言的是
      // 用户看得见的那件事：两个角标不重叠、之间留得出空。它们曾经严丝合缝地
      // 贴着，读起来像一个好长的词。
      for (var i = 1; i < rects.length; i++) {
        final gap = rects[i].left - rects[i - 1].right;
        expect(gap, greaterThan(0),
            reason: '第 $i 个角标跟左边那个粘在一起了（缝 = $gap）');
      }

      await drainTimers(tester);
    });
  });
}
