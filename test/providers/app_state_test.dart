import 'dart:async';
import 'dart:io';

import 'package:deep_unzip/engine/controller.dart';
import 'package:deep_unzip/engine/models.dart';
import 'package:deep_unzip/engine/output_paths.dart';
import 'package:deep_unzip/engine/protocol.dart';
import 'package:deep_unzip/models/archive_file.dart';
import 'package:deep_unzip/models/extractor.dart';
import 'package:deep_unzip/models/log_entry.dart';
import 'package:deep_unzip/providers/app_state.dart';
import 'package:deep_unzip/utils/mock_data.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../engine/zip_fixtures.dart';
import '../support/fake_engine.dart';

/// `AppState` 是整个 UI 的契约面：4 个页面 + 4 个弹窗都直接读它的 getter。
/// 这组测试盯的是「适配层翻译得对不对」，不是引擎本身（那在 engine/ 测过）。
///
/// 用 `selectFolderPath`（而不是 `selectFolder`）驱动：后者要走
/// `FilePicker` 与 `permission_handler` 的平台通道，在无设备的 `flutter test`
/// 里拿不到。
void main() {
  // 收 `dynamic Function()`：本文件里同步用例与异步用例混着写，
  // 只收 `Future<void> Function()` 的话同步那批要全加上 `async`。
  void t(String name, dynamic Function() body) => test(
        name,
        () async => await body(),
        timeout: const Timeout(Duration(seconds: 30)),
      );

  Directory tempRoot(String tag) {
    final d = makeTempDir(tag);
    addTearDown(() {
      if (d.existsSync()) d.deleteSync(recursive: true);
    });
    return d;
  }

  String put(Directory root, String rel, List<int> bytes) {
    final path = p.joinAll([root.path, ...rel.split('/')]);
    File(path).parent.createSync(recursive: true);
    File(path).writeAsBytesSync(bytes);
    return path;
  }

  /// 真的引擎 + 零节流，测试结束自动释放。
  AppState booted() {
    final state = AppState(engine: EngineController(throttle: Duration.zero));
    addTearDown(state.dispose);
    return state;
  }

  /// 让出事件循环若干轮。
  ///
  /// `startExtract` 是 `void`（UI 的调用点就长这样），拿不到可 await 的
  /// Future，只能「推一下调度器 + 看状态」。`Duration.zero` 的定时器会排到
  /// 微任务之后，连着推几轮足够穿过批次里的几个 await。
  Future<void> settle([int rounds = 20]) async {
    for (var i = 0; i < rounds; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// 等一批解压跑完。
  ///
  /// 不用「等固定轮数」：批次里每包一次 `await`，包数变了轮数就变了。
  /// **没有竞态**——`_runExtractBatch` 的同步前缀在 `startExtract()` 返回前
  /// 就跑完了，所以第一次检查 `extracting` 时它必然是 true。
  ///
  /// 暂停时 [AppState.extracting] 会一直为 true，所以暂停的用例必须先
  /// `resumeExtract()` 再调这里。
  Future<void> drainExtract(AppState state, {int budget = 500}) async {
    for (var i = 0; i < budget; i++) {
      if (!state.extracting) return;
      await Future<void>.delayed(Duration.zero);
    }
    fail('解压批次没在预期轮次内收尾');
  }

  group('扫描结果映射到 UI 模型', () {
    t('真目录 → archives 非空，folder* 与 hasScanned 就位', () async {
      final root = tempRoot('as_basic');
      put(root, 'a.zip', realZip({'x': 'y'}));

      final state = booted();
      await state.selectFolderPath(root.path);

      expect(state.folderSelected, isTrue);
      expect(state.folderPath, root.path);
      expect(state.folderName, p.basename(root.path));
      expect(state.hasScanned, isTrue);
      expect(state.scanning, isFalse, reason: '扫描结束必须把标志放下');
      expect(state.archives.single.name, 'a.zip');
    });

    t('ArchiveFile.size 是预格式化字符串，不是裸字节数', () async {
      final root = tempRoot('as_size');
      put(root, 'a.zip', realZip({'x': 'y'}));

      final state = booted();
      await state.selectFolderPath(root.path);

      final size = state.archives.single.size;
      expect(size, isNot(matches(RegExp(r'^\d+$'))), reason: '裸数字说明没走 formatBytes');
      expect(size, matches(RegExp(r'[\d.]+\s?(B|KB|MB|GB)')));
    });

    t('type 由嗅探结果决定，不是由后缀猜的', () async {
      final root = tempRoot('as_type');
      // 后缀叫 .rar，内容是 zip。
      put(root, '假.rar', realZip({'x': 'y'}));

      final state = booted();
      await state.selectFolderPath(root.path);

      expect(state.archives.single.type, ArchiveType.zip);
      expect(state.archives.single.typeLabel, 'ZIP');
    });

    t('伪装后缀的标记传到 ArchiveFile.flags', () async {
      final root = tempRoot('as_flags');
      put(root, '假.pdf', realZip({'x': 'y'}));

      final state = booted();
      await state.selectFolderPath(root.path);

      expect(state.archives.single.flags, contains(ArchiveFlag.fakeExtension));
    });

    t('分卷家族算作一行，size 是各卷之和', () async {
      final root = tempRoot('as_split');
      final zip = realZip({'hello.txt': 'world'});
      final half = zip.length ~/ 2;
      put(root, '备份.rar.001', zip.sublist(0, half));
      put(root, '备份.rar.002', zip.sublist(half));

      final state = booted();
      await state.selectFolderPath(root.path);

      expect(state.archives, hasLength(1), reason: '一个逻辑压缩包一行');
      expect(state.archives.single.flags, contains(ArchiveFlag.split));
      expect(state.lastScan!.items.single.split!.parts, hasLength(2));
    });

    t('lastScan 与 archives 等长同序 —— 下标 i 一一对应', () async {
      final root = tempRoot('as_align');
      put(root, 'a.zip', realZip({'x': 'y'}));
      put(root, 'sub/b.zip', realZip({'x': 'y'}));
      put(root, 'sub/deep/c.zip', realZip({'x': 'y'}));

      final state = booted();
      await state.selectFolderPath(root.path);

      final items = state.lastScan!.items;
      expect(items, hasLength(state.archives.length));
      for (var i = 0; i < items.length; i++) {
        expect(state.archives[i].name, items[i].fileName,
            reason: '第 $i 行对不上：两条列表必须同序');
        expect(state.archives[i].depth, items[i].depth);
      }
    });

    t('目录树顺序：文件在子目录之前，同层按自然序', () async {
      final root = tempRoot('as_order');
      put(root, 'x10.zip', realZip({'x': 'y'}));
      put(root, 'x2.zip', realZip({'x': 'y'}));
      put(root, 'sub/inner.zip', realZip({'x': 'y'}));

      final state = booted();
      await state.selectFolderPath(root.path);

      expect([for (final a in state.archives) a.name],
          ['x2.zip', 'x10.zip', 'inner.zip']);
    });
  });

  group('空结果与失败', () {
    t('空目录 → hasScanned 保持 false，但必须给 warn toast', () async {
      final root = tempRoot('as_empty');

      final state = booted();
      await state.selectFolderPath(root.path);

      expect(state.hasScanned, isFalse);
      expect(state.archives, isEmpty);
      // `hasScanned` 为 false 会让主按钮一直禁用；没有 toast 用户会以为卡住。
      expect(state.toastMsg, isNotNull);
      expect(state.toastType, 'warn');
    });

    t('全是容器格式 → 在 toast 里说明忽略了多少', () async {
      final root = tempRoot('as_container');
      // OOXML 改后缀成 .zip：是合法 ZIP，但应被识别为容器而忽略。
      put(root, 'doc.zip', realZip({
        '[Content_Types].xml': '<Types/>',
        'word/document.xml': '<w/>',
      }));

      final state = booted();
      await state.selectFolderPath(root.path);

      expect(state.archives, isEmpty);
      expect(state.lastScan!.containerSkipped, 1);
      expect(state.toastMsg, contains('容器'));
    });

    t('换目录后扫描失败 → 不留上一个目录的结果', () async {
      final root = tempRoot('as_stale');
      put(root, 'a.zip', realZip({'x': 'y'}));

      final state = booted();
      await state.selectFolderPath(root.path);
      expect(state.hasScanned, isTrue);

      await state.selectFolderPath(
        p.join(Directory.systemTemp.path, 'duz_as_也绝对没有这个目录'),
      );

      // 关键：folderName 已经换成新目录了，若 archives 还留着旧数据，
      // 界面就会把上一个目录的压缩包挂在新目录名下。
      expect(state.archives, isEmpty);
      expect(state.hasScanned, isFalse);
      // 目录不存在不算异常（扫描器当告警正常返回），所以 lastScan 是那份
      // 「扫了但一个都没找到」的真实结果，而不是 null。
      expect(state.lastScan!.items, isEmpty);
      expect(state.lastScan!.warnings, isNotEmpty);
    });

    t('目录不存在 → 不抛异常，落一条 failed 日志', () async {
      final state = booted();
      final before = state.logs.length;

      await state.selectFolderPath(
        p.join(Directory.systemTemp.path, 'duz_as_绝对没有这个目录'),
      );

      expect(state.hasScanned, isFalse);
      expect(state.scanning, isFalse);
      expect(state.logs.length, before + 1);
      expect(state.logs.first.status, LogStatus.failed);
    });
  });

  group('日志与 toast', () {
    t('每次扫描落一条日志，成功的在最上面', () async {
      final root = tempRoot('as_log');
      put(root, 'a.zip', realZip({'x': 'y'}));

      final state = booted();
      await state.selectFolderPath(root.path);

      final top = state.logs.first;
      expect(top.status, LogStatus.success);
      expect(top.name, contains(p.basename(root.path)));
      expect(top.tags.first, '1 个压缩包');
    });

    t('日志封顶 300 条，不会无限长', () async {
      final root = tempRoot('as_logcap');
      put(root, 'a.zip', realZip({'x': 'y'}));

      final state = booted();
      for (var i = 0; i < 340; i++) {
        await state.selectFolderPath(root.path);
      }

      expect(state.logs.length, 300);
    });

    t('filteredLogs 按状态筛，null 时返回全部', () async {
      final state = booted();
      expect(state.filteredLogs.length, state.logs.length);

      state.setLogFilter(LogStatus.success);
      expect(state.filteredLogs.every((l) => l.status == LogStatus.success),
          isTrue);

      state.setLogFilter(null);
      expect(state.filteredLogs.length, state.logs.length);
    });

    t('第二条 toast 不会被第一条的定时器提前清掉', () async {
      final state = booted();

      state.showToast('第一条'); // 定时器 @ 2000ms
      await Future<void>.delayed(const Duration(milliseconds: 500));
      state.showToast('第二条'); // 定时器 @ 2500ms

      // t≈2200ms：第一条的定时器已经跑过（它不该动第二条），
      // 第二条自己的还没到。两侧各留 200ms/300ms 余量。
      await Future<void>.delayed(const Duration(milliseconds: 1700));
      expect(state.toastMsg, '第二条');

      // 再等到 2700ms：这次轮到第二条自己的定时器收尾。
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(state.toastMsg, isNull);
    });

    t('没有任何新 toast 时，定时器到点会清空', () async {
      final state = booted();
      state.showToast('只有一条');
      await Future<void>.delayed(const Duration(milliseconds: 2100));

      expect(state.toastMsg, isNull);
      expect(state.toastType, isNull);
    });
  });

  group('扫描期间的状态', () {
    t('新一轮扫描作废上一轮的解压统计', () async {
      final root = tempRoot('as_reset');
      put(root, 'a.zip', realZip({'x': 'y'}));

      final state = booted();
      await state.selectFolderPath(root.path);

      expect(state.progress, 0.0);
      expect(state.doneCount, 0);
      expect(state.eta, '--');
      expect(state.completed, isFalse);
      expect(state.extracting, isFalse);
    });

    t('扫描中再点一次选择文件夹 → 直接忽略，不会起第二个任务', () async {
      final root = tempRoot('as_reentrant');
      for (var i = 0; i < 300; i++) {
        put(root, 'f$i.zip', realZip({'x': 'y'}));
      }

      final state = booted();
      final first = state.selectFolderPath(root.path);
      final second = state.selectFolderPath(root.path); // 应立刻返回

      await Future.wait([first, second]);
      expect(state.archives, hasLength(300));
    });

    t('cancelScan 中止后仍正常收尾：scanning 归位 + 有部分结果', () async {
      final root = tempRoot('as_cancel');
      for (var i = 0; i < 400; i++) {
        put(root, 'f$i.zip', realZip({'x': 'y'}));
      }

      final state = booted();
      final pending = state.selectFolderPath(root.path);
      state.cancelScan();
      await pending;

      expect(state.scanning, isFalse);
      expect(state.lastScan!.warnings.any((w) => w.contains('已取消')), isTrue);
    });
  });

  group('解压入口', () {
    t('没扫描过就点开始 → 不起任务，只提示', () {
      final engine = FakeEngine();
      final state = AppState(engine: engine);
      addTearDown(state.dispose);

      state.startExtract();

      expect(state.extracting, isFalse);
      expect(engine.rounds, 0, reason: '没有东西可解时不该去惊动引擎');
      expect(state.toastType, 'warn');
    });

    t('扫描完成后点开始 → 走引擎，输出目录与源同级，收尾文案就位', () async {
      final root = tempRoot('as_start');
      put(root, 'sub/a.zip', realZip({'x': 'y'}));

      final engine = FakeEngine();
      final state = AppState(engine: engine);
      addTearDown(state.dispose);

      await state.selectFolderPath(root.path);
      state.startExtract();

      // `_runExtractBatch` 的同步前缀在 `startExtract()` 返回前就跑完了，
      // 所以这里读到的一定是「已进入解压态」而不是「还没开始」。
      expect(state.extracting, isTrue);
      expect(state.currentFile, 'a.zip');

      await drainExtract(state);

      expect(engine.rounds, 1);
      expect(
        engine.outDirs.single.replaceAll(r'\', '/'),
        endsWith('/sub/a'),
        reason: 'A/B/c.zip → A/B/c/，剥掉整个压缩后缀',
      );
      expect(state.completed, isTrue);
      expect(state.progress, 1.0);
      expect(state.completeDetail, contains('1 个压缩包'));
      expect(state.logs.first.name, 'a.zip');
      expect(state.logs.first.status, LogStatus.success);
      expect(state.toastType, 'ok');
    });

    t('引擎报密码错 → 记失败、标密码未匹配、不中断整批', () async {
      final root = tempRoot('as_pwd');
      put(root, 'a.zip', realZip({'x': 'y'}));
      put(root, 'b.zip', realZip({'x': 'y'}));

      final engine = FakeEngine()
        ..behavior = (e, outDir) async {
          if (e.rounds == 1) {
            throw const EngineException('需要密码', code: DuzErrorCode.password);
          }
        };
      final state = AppState(engine: engine);
      addTearDown(state.dispose);

      await state.selectFolderPath(root.path);
      state.startExtract();
      await drainExtract(state);

      expect(engine.rounds, 2, reason: '一个坏包不该让整批停下');
      expect(state.doneCount, 2);

      final byName = {for (final l in state.logs) l.name: l};
      expect(byName['a.zip']!.status, LogStatus.failed);
      expect(byName['a.zip']!.tags, contains('密码未匹配'));
      expect(byName['b.zip']!.status, LogStatus.success);

      // 有失败就不该把进度顶到 100% —— 那是「全部解开」的意思。
      expect(state.progress, isNot(1.0));
      expect(state.completeDetail, contains('1 个失败'));
      expect(state.toastType, 'warn');
    });

    t('进度由引擎 tick 驱动：整批比例 = (已完成包数 + 当前包比例) / 总包数', () async {
      final root = tempRoot('as_tick');
      put(root, 'a.zip', realZip({'x': 'y'}));
      put(root, 'b.zip', realZip({'x': 'y'}));

      final gate = Completer<void>();
      final engine = FakeEngine()
        ..behavior = (e, outDir) async {
          if (e.rounds == 1) {
            e.onExtractTick?.call(const ExtractTick(
              doneBytes: 50,
              totalBytes: 100,
              current: 'inner.txt',
            ));
            await gate.future; // 卡住第一个包，好观察中途状态
          }
        };
      final state = AppState(engine: engine);
      addTearDown(state.dispose);

      await state.selectFolderPath(root.path);
      state.startExtract();
      await settle();

      expect(state.currentFile, 'a.zip', reason: 'currentFile 是压缩包名');
      expect(state.currentEntry, 'inner.txt', reason: 'currentEntry 是包里的条目名');
      // 不能用未压缩字节当整批分母：扫描时拿到的是**压缩后**大小，两个数
      // 不同量纲。所以整批进度只能由「包数」和「当前包内部比例」合成。
      expect(state.progress, closeTo(0.25, 1e-9));

      gate.complete();
      await drainExtract(state);

      expect(state.doneCount, 2);
      expect(state.progress, 1.0);
    });

    t('暂停停在包与包之间，继续后跑完', () async {
      final root = tempRoot('as_pause');
      put(root, 'a.zip', realZip({'x': 'y'}));
      put(root, 'b.zip', realZip({'x': 'y'}));

      final gate = Completer<void>();
      final engine = FakeEngine()
        ..behavior = (e, outDir) async {
          if (e.rounds == 1) await gate.future;
        };
      final state = AppState(engine: engine);
      addTearDown(state.dispose);

      await state.selectFolderPath(root.path);
      state.startExtract();
      await settle();

      state.pauseExtract();
      expect(state.paused, isTrue);
      expect(state.extracting, isTrue, reason: '暂停不等于结束');
      expect(state.toastMsg, contains('解完后暂停'), reason: '粒度要如实说，别让人以为按下去就冻住');

      gate.complete(); // 第一个包解完
      await settle();

      expect(engine.rounds, 1, reason: '闸门应该卡在第二个包之前');
      expect(state.paused, isTrue);

      state.resumeExtract();
      expect(state.paused, isFalse);
      await drainExtract(state);

      expect(engine.rounds, 2);
      expect(state.completed, isTrue);
    });

    t('解压中再点开始不重复起任务', () async {
      final root = tempRoot('as_dup');
      put(root, 'a.zip', realZip({'x': 'y'}));

      final gate = Completer<void>();
      final engine = FakeEngine()..behavior = (e, outDir) => gate.future;
      final state = AppState(engine: engine);
      addTearDown(state.dispose);

      await state.selectFolderPath(root.path);
      state.startExtract();
      await settle();
      state.startExtract();
      state.startExtract();
      await settle();

      expect(engine.rounds, 1);

      gate.complete();
      await drainExtract(state);
    });

    t('暂停 / 继续在无任务时都是空操作', () {
      final state = booted();
      state.pauseExtract();
      expect(state.paused, isFalse);

      state.resumeExtract();
      expect(state.paused, isFalse);
    });

    t('解压途中被 dispose：不崩，批次正常收尾', () async {
      // 用户解压到一半离开页面是这个架构里的常态：解压是
      // `unawaited(_runExtractBatch())` 起的后台流程，`dispose()` 拦不住它。
      // `ChangeNotifier` 释放后再 `notifyListeners` 会直接断言崩溃 ——
      // 这条用例守的就是那道守卫。
      final root = tempRoot('as_dispose_mid');
      put(root, 'a.zip', realZip({'x': 'y'}));
      put(root, 'b.zip', realZip({'x': 'y'}));
      put(root, 'c.zip', realZip({'x': 'y'}));

      final gate = Completer<void>();
      final engine = FakeEngine()..behavior = (e, outDir) => gate.future;
      final state = AppState(engine: engine);

      await state.selectFolderPath(root.path);
      state.startExtract();
      await settle();
      expect(state.extracting, isTrue);

      state.dispose(); // 用户离开页面
      gate.complete(); // 正在解的那个包这时候才结束
      await settle(60);

      expect(state.extracting, isFalse, reason: '批次要收尾，不能永远挂着');
      expect(
        engine.rounds,
        1,
        reason: '释放之后剩下的包不该再开工 —— 每个都只会以「控制器已释放」失败',
      );
    });

    t('暂停中被 dispose：闸门被放行，批次不会永远挂着', () async {
      final root = tempRoot('as_dispose_paused');
      put(root, 'a.zip', realZip({'x': 'y'}));
      put(root, 'b.zip', realZip({'x': 'y'}));

      final gate = Completer<void>();
      final engine = FakeEngine()
        ..behavior = (e, outDir) async {
          if (e.rounds == 1) await gate.future;
        };
      final state = AppState(engine: engine);

      await state.selectFolderPath(root.path);
      state.startExtract();
      await settle();

      state.pauseExtract();
      gate.complete();
      await settle();
      expect(state.paused, isTrue, reason: '闸门应该已经卡在第二个包之前');

      state.dispose();
      await settle(60);

      // `_paused` 不会被重置，所以卡住与否只能看 `extracting`。
      expect(
        state.extracting,
        isFalse,
        reason: 'dispose 必须放行暂停闸门，否则那一帧永远悬着',
      );
      expect(engine.rounds, 1);
    });

    t('AppState 把自己接上了两条 tick 回调', () async {
      // 这不是「测内部实现」，而是回填一个真实的坑：`onExtractTick` 曾经漏了
      // 赋值（只接了 `onScanTick`），症状是解压进度条永远停在 0 —— 而其它
      // 用例全都照过，因为没有哪条 tick 会真的送到 AppState 手上。
      final root = tempRoot('as_wired');
      put(root, 'a.zip', realZip({'x': 'y'}));

      final engine = FakeEngine();
      final state = AppState(engine: engine);
      addTearDown(state.dispose);

      await state.selectFolderPath(root.path);

      expect(engine.onScanTick, isNotNull);
      expect(engine.onExtractTick, isNotNull,
          reason: '漏了这条，解压进度条会一直停在 0');
    });
  });

  group('设置、密码库、解压器', () {
    t('cycleMaxDepth 只在 {0,5,10,20} 里转', () {
      final state = booted();
      final seen = <int>{};
      for (var i = 0; i < 4; i++) {
        seen.add(state.maxDepth);
        state.cycleMaxDepth();
      }
      expect(seen, {0, 5, 10, 20});
      expect(state.maxDepth, 0, reason: '转一圈回到起点');
    });

    t('toggleSetting 翻转指定 key，未登记的 key 读作 false', () {
      final state = booted();
      final before = state.setting('recursive');
      state.toggleSetting('recursive');

      expect(state.setting('recursive'), !before);
      expect(state.setting('不存在的key'), isFalse);
    });

    t('addPassword 拒绝空串与重复', () {
      final state = booted();
      final before = state.passwords.length;

      state.addPassword('');
      expect(state.passwords.length, before);

      state.addPassword(MockData.passwords.first.value);
      expect(state.passwords.length, before, reason: '重复密码不该进库');
    });

    t('addPassword 成功的插到队首', () {
      final state = booted();
      state.addPassword('全新密码');

      expect(state.passwords.first.value, '全新密码');
      expect(state.passwords.first.lastUsed, isNotEmpty);
    });

    t('deletePassword 按下标删', () {
      final state = booted();
      final target = state.passwords[1].value;

      state.deletePassword(1);

      expect(state.passwords.any((p) => p.value == target), isFalse);
    });

    t('内置解压器删不掉', () {
      final state = booted();
      final builtin = state.extractors.indexWhere((e) => e.isBuiltin);
      expect(builtin, isNot(-1), reason: '夹具前提：存在内置解压器');
      final before = state.extractors.length;

      state.deleteExtractor(builtin);

      expect(state.extractors.length, before);
    });

    t('注册重名解压器被拒（大小写不敏感）', () {
      final state = booted();
      final before = state.extractors.length;

      state.addExtractor(const Extractor(
        name: 'zip',
        type: ExtractorType.single,
        detectLogic: '',
        extractLogic: '',
      ));

      expect(state.extractors.length, before);
      expect(state.toastType, 'warn');
    });

    t('custom 解压器能注册也能删', () {
      final state = booted();
      const custom = Extractor(
        name: 'FOO',
        type: ExtractorType.split,
        detectLogic: 'readHeader(4) === 0x464F4F00',
        extractLogic: 'foo x {file} {dir}',
      );

      state.addExtractor(custom);
      final idx = state.extractors.indexWhere((e) => e.name == 'FOO');
      expect(idx, isNot(-1));

      state.deleteExtractor(idx);
      expect(state.extractors.any((e) => e.name == 'FOO'), isFalse);
    });
  });

  group('递归解压（需求 1）', () {
    /// 存放「内层包」的目录，**刻意在被扫描的目录之外**。
    ///
    /// 若把它们摆进 `root` 里，`selectFolderPath` 那次递归扫描会**自己也
    /// 扫到它们**，于是它们作为顶层项被解一遍、又作为嵌套项被解一遍 ——
    /// 用例里数出来的 `rounds` 会比预期多 1，而那是测试搭错了台子，
    /// 不是被测逻辑有问题。真实场景里内层包是解压的产物，扫描时还不存在。
    late Directory payload;

    setUp(() => payload = tempRoot('as_payload'));

    /// 造一个假扫描项。`sniff` 给全，其余字段取最小值 —— 这组用例盯的是
    /// 队列与准入判定，不是嗅探。
    ScanItem itemAt(String path, {int depth = 0}) => ScanItem(
          entryPath: path,
          parts: [path],
          sniff: const SniffResult(
            format: SniffFormat.zip,
            confidence: SniffConfidence.high,
            declaredExt: 'zip',
          ),
          sizeBytes: 100,
          flags: const {},
          depth: depth,
        );

    t('嵌套包被排进队列：层级 +1，列表跟着边长', () async {
      final root = tempRoot('as_nest');
      final outer = put(root, 'nested.zip', realZip({'readme.txt': 'x'}));
      // 内层包要与外层**内容不同**，否则会被自引用判定拦下（那是下一条用例）。
      final innerPath = put(payload, 'inner.zip', realZip({'deep.txt': 'y'}));

      final engine = FakeEngine()
        ..nestedFor[resolveOutputDir(outer)] = [itemAt(innerPath, depth: 1)];
      final state = AppState(engine: engine);
      addTearDown(state.dispose);

      await state.selectFolderPath(root.path);
      state.startExtract();
      await drainExtract(state);

      expect(engine.rounds, 2, reason: '内层包也要真的被解一次');
      expect(engine.depthsSeen, [0, 1], reason: '内层任务的 depth 是父的 +1');
      expect(engine.recursiveSeen, everyElement(isTrue));

      expect(state.archives.map((a) => a.name), ['nested.zip', 'inner.zip']);
      final nestedRow = state.archives.last;
      expect(nestedRow.depth, 1);
      expect(nestedRow.flags, contains(ArchiveFlag.nested));

      // 分母跟着长：收尾必须报 2 个，不能只说开头那 1 个。
      expect(state.completeDetail, contains('2 个压缩包'));
      expect(state.completed, isTrue);
      expect(state.progress, 1.0);
    });

    t('自引用（内容与名字都相同的内层包）→ 跳过，不去解', () async {
      final root = tempRoot('as_cycle');
      final bytes = realZip({'x': 'y'});
      final outer = put(root, 'a.zip', bytes);
      // 同一份数据、同一个文件名 —— 身份指纹完全一致，正是自引用的形态。
      final innerPath = put(payload, 'a.zip', bytes);

      final engine = FakeEngine()
        ..nestedFor[resolveOutputDir(outer)] = [itemAt(innerPath, depth: 1)];
      final state = AppState(engine: engine);
      addTearDown(state.dispose);

      await state.selectFolderPath(root.path);
      state.startExtract();
      await drainExtract(state);

      expect(engine.rounds, 1, reason: '自引用的那个不该被送去解压');
      expect(state.logs.first.status, LogStatus.skipped);
      expect(state.logs.first.tags, contains('自引用'));

      // 收尾报 **2 个**压缩包而不是 1 个：自引用的那个确实进了批次、也确实
      // 被处理了（处理方式就是「判断出不值得解」），它和「超深被拦在门外」
      // 那条用例的差别正在这里 —— 那个压根没进列表，所以分母只有 1。
      expect(state.completeDetail, contains('2 个压缩包'));
      expect(state.completeDetail, contains('1 个已跳过'));
      expect(state.completeDetail, isNot(contains('失败')));
    });

    t('超过 maxDepth 的内层包在入队前就被丢掉，不进列表', () async {
      final root = tempRoot('as_deep');
      final outer = put(root, 'a.zip', realZip({'x': 'y'}));
      final deep = put(payload, 'deep.zip', realZip({'y': 'z'}));

      final engine = FakeEngine()
        // depth 6 而 maxDepth 会设成 5 —— 差一级，必须被拦。
        ..nestedFor[resolveOutputDir(outer)] = [itemAt(deep, depth: 6)];
      final state = AppState(engine: engine);
      addTearDown(state.dispose);

      state.cycleMaxDepth(); // 0 → 5

      await state.selectFolderPath(root.path);
      state.startExtract();
      await drainExtract(state);

      expect(engine.rounds, 1);
      expect(
        state.archives.map((a) => a.name),
        ['a.zip'],
        reason: '被深度顶拦下的包不该出现在列表里 —— 它永远等不到执行',
      );
      expect(state.logs.first.tags, contains('超出递归深度'));
      expect(state.logs.first.status, LogStatus.skipped);
    });

    t('关掉 recursive → 内层包既不进列表也不解', () async {
      final root = tempRoot('as_norec');
      final outer = put(root, 'a.zip', realZip({'x': 'y'}));
      final inner = put(payload, 'inner.zip', realZip({'y': 'z'}));

      final engine = FakeEngine()
        ..nestedFor[resolveOutputDir(outer)] = [itemAt(inner, depth: 1)];
      final state = AppState(engine: engine);
      addTearDown(state.dispose);

      state.toggleSetting('recursive'); // true → false

      await state.selectFolderPath(root.path);
      state.startExtract();
      await drainExtract(state);

      expect(engine.rounds, 1);
      expect(engine.recursiveSeen, [isFalse], reason: '关掉时连扫都不该扫');
      expect(state.archives.map((a) => a.name), ['a.zip']);
    });

    t('内层包失败 → 记失败但不影响批次收尾', () async {
      final root = tempRoot('as_nestfail');
      final outer = put(root, 'a.zip', realZip({'x': 'y'}));
      final inner = put(payload, 'inner.zip', realZip({'y': 'z'}));

      final engine = FakeEngine()
        ..nestedFor[resolveOutputDir(outer)] = [itemAt(inner, depth: 1)]
        ..behavior = (e, outDir) async {
          if (e.rounds == 2) {
            throw const EngineException('内层坏了', code: DuzErrorCode.extract);
          }
        };
      final state = AppState(engine: engine);
      addTearDown(state.dispose);

      await state.selectFolderPath(root.path);
      state.startExtract();
      await drainExtract(state);

      expect(engine.rounds, 2);
      expect(state.logs.first.name, 'inner.zip');
      expect(state.logs.first.status, LogStatus.failed);
      expect(state.completeDetail, contains('1 个失败'));
      expect(state.extracting, isFalse);
    });
  });

  group('释放', () {
    t('dispose 之后重复 dispose 不炸', () {
      final state = AppState(engine: EngineController());
      state.dispose();
      state.dispose();
    });
  });
}

// 假引擎定义在 `test/support/fake_engine.dart` —— 首页那组 widget 测试也要用，
// 所以不能是本文件的私有类。

