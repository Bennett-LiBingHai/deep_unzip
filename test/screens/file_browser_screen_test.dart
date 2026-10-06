import 'dart:async';
import 'dart:io';

import 'package:deep_unzip/engine/format.dart';
import 'package:deep_unzip/screens/file_browser_screen.dart';
import 'package:deep_unzip/services/file_browser.dart';
import 'package:deep_unzip/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// 自建文件浏览器。**全部可测**是选这个方案的核心理由之一 —— 页面与
/// `listDirectory` 都是纯 Dart + `dart:io`，所以下面这些用例真的在临时目录树上
/// 建目录、点进去、退回来，而不是拿假数据骗自己。
///
/// 卷根是注入的（真机上从 `/storage` 发现），否则测试会去列宿主机真实的
/// `/storage`，那东西在 Windows 上根本不存在。
void main() {
  // 默认 `tap()` 打不中只警告不报错 —— 「点了没反应」会在没点到的前提下通过。
  setUpAll(() => WidgetController.hitTestWarningShouldBeFatal = true);

  /// 推帧 + **让真实的文件 I/O 落地**。
  ///
  /// 列目录走的是真 `dart:io`，而 `testWidgets` 的测试体包在 FakeAsync 里 ——
  /// 推假时钟推不动真 I/O，`pumpAndSettle` 会一直等到超时（见 memory
  /// `fakeasync-real-io-trap`）。`runAsync` 切回真事件循环，给它一点时间。
  ///
  /// 每个会触发重新列目录的交互（进目录、上一级、点快捷入口）后面都要用它，
  /// 不能只写 `pumpAndSettle`。
  Future<void> settle(WidgetTester tester, {int rounds = 8}) async {
    // 1. 先推一帧：`_boot` 挂在 post-frame 回调上，不推帧它根本不会开始，
    //    于是那次 I/O 也永远不会发出去。
    await tester.pump();
    // 2. 切回真事件循环，让 `dart:io` 真的跑完 —— 再推一帧把它的 continuation
    //    从 fake 区的微任务队列里排出来。这两步要交替来，**一次不够**：列目录
    //    与随后的逐条 stat 是两段分开的真 I/O，各自要一轮 runAsync 才跑得完，
    //    中间还得有 pump 把前一段的结果排出去。
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    // 3. 最后推帧，把结果渲染出来（顺带走完路由转场动画）。
    await tester.pumpAndSettle();
  }

  Directory tempRoot(String tag) {
    final d = Directory.systemTemp.createTempSync('duz_fb_$tag');
    addTearDown(() {
      if (d.existsSync()) d.deleteSync(recursive: true);
    });
    return d;
  }

  void touch(Directory root, String rel) {
    final path = p.joinAll([root.path, ...rel.split('/')]);
    File(path).parent.createSync(recursive: true);
    File(path).writeAsStringSync('x');
  }

  void mkdir(Directory root, String rel) =>
      Directory(p.joinAll([root.path, ...rel.split('/')])).createSync(recursive: true);

  /// 每一行里**名字**那一格，按屏幕顺序。
  ///
  /// 不能直接收 `ListView` 底下所有 `Text`：一行的右边还有大小和时间
  /// （`_metaColumn`），一起收进来就把顺序断言搅了。名字那一格是 [Expanded]
  /// 的子节点，而右边那两格在 [SizedBox] 里 —— 拿 `Expanded` 当边界正好。
  List<String> namesOnScreen(WidgetTester tester) {
    final cells = find.descendant(
      of: find.byType(ListView),
      matching: find.byType(Expanded),
    );
    return tester
        .widgetList<Text>(find.descendant(of: cells, matching: find.byType(Text)))
        .map((t) => t.data!)
        .toList();
  }

  /// 把浏览器当作一个被 push 出来的路由挂上，返回值写进 [result]。
  ///
  /// 必须走真的 push/pop：`Navigator.pop(...)` 的返回值是调用方唯一拿到结果的
  /// 途径，而「取消 = null」也正是靠这条路径体现的。
  ///
  /// [mode] 默认 `pickTarget` —— 大部分用例只关心「列得对、导航得对」，那是两档
  /// 共用的内核。
  Future<void> open(
    WidgetTester tester, {
    required String root,
    FileBrowserMode mode = FileBrowserMode.pickTarget,
    Completer<Picked?>? result,
    DirLister? lister,
    StatLister? statLister,
  }) async {
    await tester.binding.setSurfaceSize(const Size(800, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.dark,
      home: Builder(
        builder: (ctx) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () async {
                final r = await FileBrowserScreen.show(ctx,
                    mode: mode,
                    roots: [root],
                    lister: lister,
                    statLister: statLister);
                if (result != null && !result.isCompleted) result.complete(r);
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('打开'));
    await settle(tester);
  }

  group('列目录', () {
    testWidgets('目录在前、文件在后，各自自然序', (tester) async {
      final root = tempRoot('list');
      mkdir(root, 'zdir');
      mkdir(root, 'adir');
      touch(root, 'x10.zip');
      touch(root, 'x2.zip');

      await open(tester, root: root.path);

      expect(namesOnScreen(tester), ['adir', 'zdir', 'x2.zip', 'x10.zip']);
    });

    testWidgets('当前路径摆在顶部（可选中复制）', (tester) async {
      final root = tempRoot('cwd');
      await open(tester, root: root.path);

      expect(tester.widget<SelectableText>(find.byType(SelectableText)).data, root.path);
    });

    testWidgets('空目录给一句人话', (tester) async {
      final root = tempRoot('empty');
      await open(tester, root: root.path);

      expect(find.text('这个目录是空的'), findsOneWidget);
    });

    testWidgets('目录整个读不了 → 提示而不是崩', (tester) async {
      final root = tempRoot('gone');
      touch(root, 'a.zip');
      // `sub` 必须在打开页面**之前**就建好：页面只在导航时重新列目录，
      // 后面再造一个目录它不会自己发现。
      mkdir(root, 'sub');

      // 注入一个只对子目录抛错的列举器：`sub` 要能列出来（不然点不到），
      // 点进去才炸。真造一个无权限目录在 Windows 宿主机上做不到，
      // 而「目录在两次列举之间被删掉」这种时序在测试里没法稳定复现。
      final sub = p.join(root.path, 'sub');
      await open(
        tester,
        root: root.path,
        lister: (dir) => dir == sub
            ? Stream.error(const FileSystemException(
                'Permission denied', '', OSError('Permission denied', 13)))
            : Directory(dir).list(followLinks: false),
      );

      expect(find.text('a.zip'), findsOneWidget);
      await tester.tap(find.text('sub'));
      await settle(tester);

      // 注入的是 errno 13，所以应当是那条**权限**的说明，而不是笼统的那句。
      // 也不许把 `errno` 这种原始报错摆给用户看。
      expect(find.text('没有权限读取这个目录'), findsOneWidget);
      expect(find.textContaining('errno'), findsNothing);
      expect(find.text('选择此文件夹'), findsOneWidget,
          reason: '提示归提示，这一档仍然要能选当前目录 —— 否则用户被困在这里');
    });
  });

  group('导航', () {
    testWidgets('进子目录、上一级回来', (tester) async {
      final root = tempRoot('nav');
      touch(root, 'sub/inner.zip');
      touch(root, 'top.zip');

      await open(tester, root: root.path);
      expect(find.text('top.zip'), findsOneWidget);

      await tester.tap(find.text('sub'));
      await settle(tester);
      expect(find.text('inner.zip'), findsOneWidget);
      expect(find.text('top.zip'), findsNothing);
      expect(
        tester.widget<SelectableText>(find.byType(SelectableText)).data,
        p.join(root.path, 'sub'),
      );

      await tester.tap(find.text('上一级'));
      await settle(tester);
      expect(find.text('top.zip'), findsOneWidget);
    });

    testWidgets('到了卷根，「上一级」就不动了', (tester) async {
      final root = tempRoot('atroot');
      touch(root, 'a.zip');
      await open(tester, root: root.path);

      await tester.tap(find.text('上一级'));
      await settle(tester);

      expect(tester.widget<SelectableText>(find.byType(SelectableText)).data, root.path,
          reason: '不能一路退到 `/` —— 那里列出来的系统目录对用户没有意义');
    });

    testWidgets('系统返回手势逐级返回，到根才退出', (tester) async {
      final root = tempRoot('back');
      touch(root, 'sub/inner.zip');

      final result = Completer<Picked?>();
      await open(tester, root: root.path, result: result);

      await tester.tap(find.text('sub'));
      await settle(tester);
      expect(find.text('inner.zip'), findsOneWidget);

      // 第一次返回：退一层，页面还在。
      await tester.binding.handlePopRoute();
      await settle(tester); // `_up()` 也要重新列目录，同样是真 I/O
      expect(find.byType(FileBrowserScreen), findsOneWidget);
      expect(tester.widget<SelectableText>(find.byType(SelectableText)).data, root.path);

      // 第二次返回：已经在卷根，才真的退出。
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(FileBrowserScreen), findsNothing);
      expect(await result.future, isNull, reason: '返回手势退出 = 取消');
    });
  });

  group('隐藏文件', () {
    testWidgets('默认显示，点一下收起来', (tester) async {
      final root = tempRoot('hidden');
      touch(root, '.hidden.zip');
      touch(root, 'shown.zip');

      await open(tester, root: root.path);
      expect(find.text('.hidden.zip'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.visibility_outlined));
      await settle(tester);

      expect(find.text('.hidden.zip'), findsNothing);
      expect(find.text('shown.zip'), findsOneWidget, reason: '只藏隐藏文件，别的一起藏了就是 bug');
    });
  });

  // ---------------------------------------------------------------------------
  // 一个入口，两种结果 —— 首页只有一颗按钮，是解文件还是解目录由用户点了什么定。
  // 所以「点文件行」与「按选择此文件夹」这两条路都得真的走得通、交回的东西也得
  // 说清楚自己是什么。
  // ---------------------------------------------------------------------------
  group('选目标：点文件还是点文件夹', () {
    testWidgets('点文件行 → 交回那个文件，且标明它不是目录', (tester) async {
      final root = tempRoot('file');
      touch(root, 'a.zip');
      final target = p.join(root.path, 'a.zip');

      final result = Completer<Picked?>();
      await open(tester, root: root.path, result: result);

      await tester.tap(find.text('a.zip'));
      await tester.pumpAndSettle();

      expect(await result.future, (path: target, isDirectory: false));
      expect(find.byType(FileBrowserScreen), findsNothing);
    });

    testWidgets('按「选择此文件夹」 → 交回当前目录，且标明它是目录', (tester) async {
      final root = tempRoot('folder');
      touch(root, 'a.zip');

      final result = Completer<Picked?>();
      await open(tester, root: root.path, result: result);

      await tester.tap(find.text('选择此文件夹'));
      await tester.pumpAndSettle();

      expect(await result.future, (path: root.path, isDirectory: true));
    });

    testWidgets('也可以先钻进子目录再选它', (tester) async {
      final root = tempRoot('folder_sub');
      touch(root, 'sub/a.zip');

      final result = Completer<Picked?>();
      await open(tester, root: root.path, result: result);

      await tester.tap(find.text('sub'));
      await settle(tester);
      await tester.tap(find.text('选择此文件夹'));
      await tester.pumpAndSettle();

      expect(await result.future, (path: p.join(root.path, 'sub'), isDirectory: true));
    });
  });

  // ---------------------------------------------------------------------------
  // 元数据是**第二批**到的：列表先画出来，大小随后跳上去。这一组盯的是
  // 「第二批真的会到」以及「第二批没到 / 到不了的时候页面不会坏」。
  // ---------------------------------------------------------------------------
  group('大小与时间', () {
    testWidgets('文件行补上大小，目录行不摆大小', (tester) async {
      final root = tempRoot('meta');
      final big = p.join(root.path, 'big.zip');
      File(big).writeAsBytesSync(List.filled(2048, 0));
      mkdir(root, 'sub');

      await open(tester, root: root.path);

      // 这一条没注入 statLister，走的是生产那条 `dart:io`，所以量出来的是真值。
      expect(find.text('2.0 KB'), findsOneWidget, reason: '2048 字节');
      expect(find.text('1 B'), findsNothing,
          reason: '目录不给大小 —— `stat` 给的是目录项本身占的字节，摆出来是假话');

      // 时间两边都有。断言用**至少一条**而不是恰好一条：`formatLogTime` 精确到
      // 分钟，而这两个条目是同一分钟内造出来的，字符串会撞在一起。
      final when = formatLogTime(File(big).lastModifiedSync());
      expect(find.text(when), findsAtLeastNWidgets(1));
    });

    testWidgets('补不出来的那一条留空，页面不崩', (tester) async {
      // 真造一个 stat 会失败的条目在宿主机上做不到，所以注入。
      final root = tempRoot('meta_fail');
      touch(root, 'ok.zip');
      touch(root, 'bad.zip');

      await open(
        tester,
        root: root.path,
        statLister: (path) async {
          if (p.basename(path) == 'bad.zip') {
            throw const FileSystemException('nope', '', OSError('nope', 13));
          }
          return const StatResult(found: true, sizeBytes: 12345);
        },
      );

      // 好那条正常显示，坏那条只是空着 —— 不是整页报错，也不是 `0 B` 这种假话。
      expect(find.text('12 KB'), findsOneWidget);
      expect(find.text('ok.zip'), findsOneWidget);
      expect(find.text('bad.zip'), findsOneWidget);
      expect(find.text('0 B'), findsNothing);
    });
  });

  group('选输出根', () {
    testWidgets('带上「怎么关掉它」那句出路', (tester) async {
      final root = tempRoot('outroot');
      await open(tester, root: root.path, mode: FileBrowserMode.pickOutputRoot);

      expect(find.text('选择输出根目录'), findsOneWidget);
      expect(find.textContaining('关掉「自定义输出目录」'), findsOneWidget,
          reason: '嫌每次都要选的人，得当场看到怎么关 —— 这是原来那个说明弹窗的全部内容');
    });

    testWidgets('交回的也是目录', (tester) async {
      final root = tempRoot('outroot2');
      final result = Completer<Picked?>();
      await open(tester, root: root.path,
          mode: FileBrowserMode.pickOutputRoot, result: result);

      await tester.tap(find.text('选择此文件夹'));
      await tester.pumpAndSettle();
      expect(await result.future, (path: root.path, isDirectory: true));
    });

    testWidgets('点文件没反应 —— 这一档要的是目录', (tester) async {
      final root = tempRoot('outroot3');
      touch(root, 'a.zip');

      final result = Completer<Picked?>();
      await open(tester, root: root.path,
          mode: FileBrowserMode.pickOutputRoot, result: result);

      await tester.tap(find.text('a.zip'));
      await tester.pumpAndSettle();

      expect(find.byType(FileBrowserScreen), findsOneWidget,
          reason: '「换成这个文件所在的目录」不是用户想说的意思，别猜');
      expect(result.isCompleted, isFalse);
    });
  });
}
