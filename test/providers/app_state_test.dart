import 'dart:async';
import 'dart:io';

import 'package:deep_unzip/data/persist.dart';
import 'package:deep_unzip/engine/controller.dart';
import 'package:deep_unzip/engine/limits.dart';
import 'package:deep_unzip/engine/models.dart';
import 'package:deep_unzip/engine/output_paths.dart';
import 'package:deep_unzip/engine/protocol.dart';
import 'package:deep_unzip/models/archive_file.dart';
import 'package:deep_unzip/models/extractor.dart';
import 'package:deep_unzip/models/log_entry.dart';
import 'package:deep_unzip/models/password_entry.dart';
import 'package:deep_unzip/providers/app_state.dart';
import 'package:deep_unzip/services/prompts.dart';
import 'package:deep_unzip/services/disk_space.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../engine/zip_fixtures.dart';
import '../support/fake_engine.dart';
import '../support/fake_store.dart';

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

    t('伪后缀包（需求 5）：解到 fake/ 而不是 fake.pdf/ —— 后者跟源文件撞名', () async {
      final root = tempRoot('as_spoof');
      // 真身是 ZIP，名字却叫 .pdf。这是真机上整包失败的那个形状。
      put(root, 'fake.pdf', realZip({'x': 'y'}));

      final engine = FakeEngine();
      final state = AppState(engine: engine);
      addTearDown(state.dispose);

      await state.selectFolderPath(root.path);
      expect(state.archives.single.name, 'fake.pdf',
          reason: '前提：它得先被当成一个包扫出来，否则这条测的不是伪后缀');

      state.startExtract();
      await drainExtract(state);

      final outDir = engine.outDirs.single.replaceAll(r'\', '/');
      expect(outDir, endsWith('/fake'),
          reason: '假后缀要剥掉。留着的话输出目录 = 源文件路径，'
              '后端 `createSync` 撞上一个已存在的文件，整包失败');
      expect(outDir, isNot(endsWith('/fake.pdf')));
    });

    t('没有后缀的包：靠占用判定退到 data_1，剥后缀那条路救不了它', () async {
      final root = tempRoot('as_noext');
      // 真名就叫 `data`，内容却是 ZIP。`isExtensionSpoofed` 对无后缀刻意返回
      // false（无后缀不算「被篡改」，见 models.dart），所以阶段 1.5 不会跑，
      // 推出来的名字还是 `data` —— 跟源文件自己同一个路径。救场的只能是
      // 「同名**文件**也算占着」那条占用判定。
      put(root, 'data', realZip({'x': 'y'}));

      final engine = FakeEngine();
      final state = AppState(engine: engine);
      addTearDown(state.dispose);

      await state.selectFolderPath(root.path);
      expect(state.archives, hasLength(1),
          reason: '前提：无后缀的文件也要靠魔术字节被认出来');

      state.startExtract();
      await drainExtract(state);

      final outDir = engine.outDirs.single.replaceAll(r'\', '/');
      expect(outDir, isNot(endsWith('/data')),
          reason: '输出目录 = 源文件路径，后端建目录会撞上那个文件');
      expect(outDir, endsWith('/data_1'));
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

    t('被炸弹防护拦下 → 记「炸弹防护」，别混进「解压失败」', () async {
      final root = tempRoot('as_bomb');
      put(root, 'a.zip', realZip({'x': 'y'}));
      put(root, 'b.zip', realZip({'x': 'y'}));

      const breach = LimitBreach(
        kind: LimitKind.totalSize,
        tag: '炸弹防护',
        message: '解压后共 8.0 GB，超过上限 1.0 GB，已放弃',
      );
      final engine = FakeEngine()
        ..behavior = (e, outDir) async {
          if (e.rounds == 1) {
            // 闸门住在 native_backend 里（假引擎整个绕过它），所以这里只能
            // 手动抛一条同样形状的异常，测的是**它之后**那半条链：
            // EngineException.breach → 日志 tag → 用户看到什么。
            throw EngineException(breach.message, breach: breach);
          }
        };
      final state = AppState(engine: engine);
      addTearDown(state.dispose);

      await state.selectFolderPath(root.path);
      state.startExtract();
      await drainExtract(state);

      expect(engine.rounds, 2, reason: '一个超限的包不该让整批停下');
      final byName = {for (final l in state.logs) l.name: l};
      expect(byName['a.zip']!.status, LogStatus.failed);
      // 用户得能一眼看出这是「我们主动放弃」而不是「包坏了」——
      // 前者他会想去调阈值，后者他只会去重下文件。
      expect(byName['a.zip']!.tags, contains('炸弹防护'));
      expect(byName['b.zip']!.status, LogStatus.success);
      // 收尾 toast 是整批的汇总（它会把逐包的 warn 顶掉），所以这里断言
      // 汇总而不是那条瞬时提示 —— 后者在批次跑完时已经没了。
      expect(state.completeDetail, contains('1 个失败'));
    });

    t('设置页改的阈值真的传到了引擎（这批任务全程用同一份快照）', () async {
      final root = tempRoot('as_limits');
      put(root, 'a.zip', realZip({'x': 'y'}));

      final engine = FakeEngine();
      final state = AppState(engine: engine);
      addTearDown(state.dispose);

      state.setLimitPreset(2); // 严格
      await state.selectFolderPath(root.path);
      state.startExtract();
      await drainExtract(state);

      expect(engine.limitsSeen.single, LimitThresholds.strict,
          reason: '闸门读的是命令里带上来的这份，不是 worker 自己再去读设置');
    });

    t('解压途中改阈值，不影响这一批已开工的部分', () async {
      final root = tempRoot('as_limits_snap');
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
      expect(engine.rounds, 1, reason: '前提：第一个包还卡在闸门上');

      // 用户在解压途中去设置页换了个档。
      state.setLimitPreset(0); // 宽松
      gate.complete();
      await drainExtract(state);

      expect(engine.limitsSeen, hasLength(2));
      expect(engine.limitsSeen, everyElement(LimitThresholds.standard),
          reason: '同一批里前半个包用旧值、后半个包用新值，会让结果没法解释');
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
      // 密码库空库起步（见 AppState 里的注释），所以先自己放一条进去，
      // 才有「重复」可谈。
      expect(state.passwords, isEmpty, reason: '夹具前提：不该再有播种数据');

      final before = state.passwords.length;

      state.addPassword('');
      expect(state.passwords.length, before, reason: '空串不该进库');

      state.addPassword('已存在');
      expect(state.passwords.length, before + 1);

      state.addPassword('已存在');
      expect(state.passwords.length, before + 1, reason: '重复密码不该进库');
    });

    t('addPassword 成功的插到队首', () {
      final state = booted();
      state.addPassword('全新密码');

      expect(state.passwords.first.value, '全新密码');
      expect(state.passwords.first.lastUsed, isNotEmpty);
    });

    t('deletePassword 按下标删', () {
      final state = booted();
      // addPassword 插队首，所以这里最终的顺序是 [第二条, 第一条]；
      // 下标 1 上应当是先加的那条。
      state.addPassword('第一条');
      state.addPassword('第二条');
      expect(state.passwords[1].value, '第一条');

      state.deletePassword(1);

      expect(state.passwords.any((p) => p.value == '第一条'), isFalse);
      expect(state.passwords.any((p) => p.value == '第二条'), isTrue,
          reason: '只该删掉下标 1 那条');
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

  group('炸弹防护阈值', () {
    t('默认是标准档', () {
      final state = booted();
      expect(state.limits, LimitThresholds.standard);
      expect(state.limitPresetLabel, '标准');
      expect(state.limitsCustom, isFalse);
    });

    t('chip 转一圈：从标准出发依次经过严格、自定义，回到宽松', () {
      final state = booted();
      final seen = <String>[];
      for (var i = 0; i < 4; i++) {
        seen.add(state.limitPresetLabel);
        state.cycleLimitPreset();
      }

      // 顺序就是 kLimitPresets 的顺序（宽松→标准→严格）再接一个「自定义」。
      // 起点是标准，所以第一跳去严格，绕完一圈回到宽松。
      expect(seen, ['标准', '严格', '自定义', '宽松']);
      expect(state.limitPresetLabel, '标准', reason: '四跳之后回到起点');
    });

    t('选到具体档位就整体换值', () {
      final state = booted();
      state.setLimitPreset(2); // 严格
      expect(state.limits, LimitThresholds.strict);
      expect(state.limitPresetLabel, '严格');

      state.setLimitPreset(0); // 宽松
      expect(state.limits, LimitThresholds.loose);
    });

    t('切进「自定义」保留当前值 —— 是去微调，不是从零开始', () {
      final state = booted();
      state.setLimitPreset(2); // 先到严格
      state.cycleLimitPreset(); // 再跳到自定义

      expect(state.limitsCustom, isTrue);
      expect(state.limits, LimitThresholds.strict,
          reason: '落在自定义那一刻的数值不该被清掉，否则用户看到四个空值');
    });

    t('setLimit 改一项、落到自定义、不动别的', () {
      final state = booted();
      state.setLimit(LimitField.ratio, 42);

      expect(state.limits.maxRatio, 42);
      expect(state.limits.maxTotalBytes, LimitThresholds.standard.maxTotalBytes,
          reason: '只该动被改的那一项');
      expect(state.limitsCustom, isTrue, reason: 'chip 必须如实显示「自定义」');
    });

    t('改回预设的数值**也不会**跳回该档 —— 否则编辑到一半编辑器就被收了', () {
      final state = booted();
      state.setLimit(LimitField.ratio, 42);
      expect(state.limitsCustom, isTrue);

      // 改回标准的 1000。值确实等于标准档了，但用户还在编辑。
      state.setLimit(LimitField.ratio, LimitThresholds.standard.maxRatio);

      expect(state.limits, LimitThresholds.standard, reason: '值确实回到了标准');
      expect(state.limitsCustom, isTrue,
          reason: 'chip 停在自定义：数值是手改出来的，不该替用户做这个判断');
    });

    t('转到自定义之后再点一下，回到宽松', () {
      final state = booted();
      state.setLimitPreset(3); // 自定义
      state.cycleLimitPreset();
      expect(state.limitPresetLabel, '宽松');
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

  /// 「这批用掉了」这道闸门。
  ///
  /// 它和 [AppState.completed] 是两件事：`completed` 说的是「全部成功」，
  /// 有任何一个包失败它就是 false。而重跑的危害与成败无关 —— 输出目录重名会
  /// 追加 `_1`/`_2`（见 output_paths.dart），再点一次不是「重新解一遍」而是
  /// 往磁盘里撒重复目录。所以闸门必须挂在「跑过」而不是「成功」上。
  group('被拦弹窗与剩余空间', () {
    // 这一组盯的是「闸门之后」那条新加的链：EngineException.breach → 问用户
    // → 用户的决断怎么影响整批。闸门本身住在 native_backend 里（假引擎整个
    // 绕过它），所以这里手动抛同形状的异常，测的是上层。

    const breach = LimitBreach(
      kind: LimitKind.diskSpace,
      tag: '空间不足',
      message: '解压后需要 12.0 GB，设备只剩 3.2 GB，装不下，已放弃',
    );

    /// 记下每次被问到的 (文件名, 原因)。
    final asked = <({String name, LimitBreach breach})>[];

    setUp(asked.clear);

    /// 只拦第一个包，第二个照常成功 —— 这样「继续」与「停下」的差别才看得出来。
    FakeEngine gatedEngine() => FakeEngine()
      ..behavior = (e, outDir) async {
        if (e.rounds == 1) {
          throw EngineException(breach.message, breach: breach);
        }
      };

    /// 记下这批里出现过的每一条 toast。
    ///
    /// **不能直接读 `state.toastMsg`**：批次收尾时那条汇总（`N 个压缩包 · 耗时
    /// …`）会把逐包的 warn 顶掉（既有用例里已经踩过这一点）。而这里要验的
    /// 正是那条**逐包**的兜底提示，它只在下一次 notify 之前是可见的。
    List<String> toastTrail(AppState state) {
      final seen = <String>[];
      state.addListener(() {
        final msg = state.toastMsg;
        if (msg != null && (seen.isEmpty || seen.last != msg)) seen.add(msg);
      });
      return seen;
    }

    /// 两个包，够看出整批是不是还在跑。
    Directory twoPacks(String tag) {
      final root = tempRoot(tag);
      put(root, 'a.zip', realZip({'x': 'y'}));
      put(root, 'b.zip', realZip({'x': 'y'}));
      return root;
    }

    t('跳过 → 只放弃这一个包，整批继续', () async {
      final engine = gatedEngine();
      final state = AppState(
        engine: engine,
        blockedPrompt: (name, b) async {
          asked.add((name: name, breach: b));
          return BlockedDecision.skip;
        },
      );
      addTearDown(state.dispose);

      await state.selectFolderPath(twoPacks('as_prompt_skip').path);
      state.startExtract();
      await drainExtract(state);

      expect(asked.single.name, 'a.zip');
      expect(asked.single.breach.kind, LimitKind.diskSpace,
          reason: '弹窗要拿到完整的 breach，否则正文没法写');
      expect(engine.rounds, 2, reason: '跳过 ≠ 停批');
      final byName = {for (final l in state.logs) l.name: l};
      expect(byName['a.zip']!.tags, contains('空间不足'));
      expect(byName['b.zip']!.status, LogStatus.success);
      expect(state.batchRun, isTrue, reason: '跑完的批次照常消费快照');
    });

    t('停下这批 → 剩余任务一个都不跑，且不消费批次闸门', () async {
      final engine = gatedEngine();
      final state = AppState(
        engine: engine,
        blockedPrompt: (name, b) async => BlockedDecision.stop,
      );
      addTearDown(state.dispose);

      await state.selectFolderPath(twoPacks('as_prompt_stop').path);
      state.startExtract();
      await drainExtract(state);

      expect(engine.rounds, 1, reason: '停了就不该接着解 b.zip');
      expect(state.extracting, isFalse);
      expect(state.completed, isFalse);
      expect(state.batchRun, isFalse,
          reason: '剩下的包还等着解，主按钮必须能再点（收尾注释里那条代价）');
      expect(state.completeDetail, contains('已中止'));
    });

    t('弹窗没弹成（决断为 null）→ 按没问处理，整批继续', () async {
      // DialogBridge 拿不到 BuildContext 时就是这么返回的。那不是用户的
      // 决定，用户什么都没看见 —— 既不能当停下，也不能当跳过，得补一条 toast。
      final engine = gatedEngine();
      final state = AppState(
        engine: engine,
        blockedPrompt: (name, b) async => null,
      );
      addTearDown(state.dispose);
      final toasts = toastTrail(state);

      await state.selectFolderPath(twoPacks('as_prompt_null').path);
      state.startExtract();
      await drainExtract(state);

      expect(engine.rounds, 2);
      expect(state.batchRun, isTrue);
      // 兜底 toast 用的是 breach.message（tag 是给日志用的，不在这条文案里）。
      expect(toasts.join('\n'), contains('装不下'),
          reason: '没弹成 = 用户什么都没看见，必须给一条提示');
    });

    t('普通失败（没有 breach）**不落进闸门那个弹窗**', () async {
      // 这条原来叫「普通失败不弹窗」，理由是「损坏、密码不匹配这些没有第二
      // 选择」。那个理由已经不作数了：需求 3 要的就是这些也问一句，由
      // `errorPause` 管着（见「解压出错弹窗」那一组）。
      //
      // 现在它验的是**另一件事**：这股失败不该被喂给闸门那条线。闸门弹窗的
      // 左边那颗是「停止这批」，会丢掉剩余队列；一个坏包触发它的话，用户
      // 会在一件本来只影响一个包的事情上看到一颗不可恢复的按钮。
      final root = tempRoot('as_prompt_plain');
      put(root, 'a.zip', realZip({'x': 'y'}));

      final engine = FakeEngine()
        ..behavior = (e, outDir) async {
          throw const EngineException('坏了', code: DuzErrorCode.extract);
        };
      final state = AppState(
        engine: engine,
        blockedPrompt: (name, b) async {
          asked.add((name: name, breach: b));
          return BlockedDecision.skip;
        },
      );
      addTearDown(state.dispose);
      final toasts = toastTrail(state);

      await state.selectFolderPath(root.path);
      state.startExtract();
      await drainExtract(state);

      expect(asked, isEmpty);
      expect(toasts.join('\n'), contains('坏了'), reason: '没弹窗就得有 toast 兜底');
    });

    t('没注入 prompt → 与没有这个特性时逐字节一致', () async {
      final engine = gatedEngine();
      final state = AppState(engine: engine);
      addTearDown(state.dispose);
      final toasts = toastTrail(state);

      await state.selectFolderPath(twoPacks('as_prompt_absent').path);
      state.startExtract();
      await drainExtract(state);

      expect(engine.rounds, 2, reason: '没人可问，就照旧记日志继续');
      expect(state.batchRun, isTrue);
      expect(toasts.join('\n'), contains('装不下'));
    });

    t('探针量到的剩余空间真的随每一条命令到了引擎', () async {
      final engine = FakeEngine();
      final probe = _StubProbe(12345);
      final state = AppState(engine: engine, diskSpace: probe);
      addTearDown(state.dispose);

      await state.selectFolderPath(twoPacks('as_space_wire').path);
      state.startExtract();
      await drainExtract(state);

      expect(probe.paths, everyElement(state.folderPath),
          reason: '量的是选中根：对称输出与非对称输出都在它之下、同一个卷');
      expect(engine.availableBytesSeen, [12345, 12345],
          reason: '每个任务量一次 —— 空间在缩，一批里只量一次会后半程失真');
    });

    t('探针量不到 → 传 null（跳过检查），不是 0', () async {
      final engine = FakeEngine();
      final state = AppState(engine: engine, diskSpace: _StubProbe(null));
      addTearDown(state.dispose);

      await state.selectFolderPath(twoPacks('as_space_null').path);
      state.startExtract();
      await drainExtract(state);

      expect(engine.availableBytesSeen, [null, null],
          reason: '0 会被判成「一格不剩」，每一个包都被拒绝');
    });

    t('默认探针在非 Android 宿主上不报错，一路 null 到底', () async {
      // flutter test 跑在 Windows 上，Platform.isAndroid 为 false，
      // 探针直接短路返回 null，压根不发通道消息。
      final engine = FakeEngine();
      final state = AppState(engine: engine);
      addTearDown(state.dispose);

      await state.selectFolderPath(twoPacks('as_space_default').path);
      state.startExtract();
      await drainExtract(state);

      expect(engine.availableBytesSeen, [null, null]);
    });
  });

  group('解压出错弹窗（需求 3）', () {
    // 这一组盯的是 `errorPause` 那个开关**真的有人读**。加这一组之前它是个
    // 死开关：界面上写着「无法解压时弹窗询问，而非自动跳过」，而全仓库除了
    // 默认值定义和那行 UI，没有任何地方读过它。
    //
    // 判据全在「暂停」两个字上：这一档的暂停复用 `pauseExtract` 那道闸门，
    // 队列原封不动、能接着解。所以下面最重要的断言不是「弹了窗」，而是
    // **暂停之后 `extracting` 还是 true、剩下几个包一个都没动**。

    /// 只让第一个包炸，第二个照常成 —— 这样「暂停」与「跳过」才分得开。
    FakeEngine brokenFirst() => FakeEngine()
      ..behavior = (e, outDir) async {
        if (e.rounds == 1) {
          throw const EngineException('这个包坏了', code: DuzErrorCode.extract);
        }
      };

    Directory twoPacks(String tag) {
      final root = tempRoot(tag);
      put(root, 'a.zip', realZip({'x': 'y'}));
      put(root, 'b.zip', realZip({'x': 'y'}));
      return root;
    }

    List<String> toastTrail(AppState state) {
      final seen = <String>[];
      state.addListener(() {
        final msg = state.toastMsg;
        if (msg != null && (seen.isEmpty || seen.last != msg)) seen.add(msg);
      });
      return seen;
    }

    t('开着 errorPause → 出错时问，选「跳过」→ 整批继续', () async {
      final engine = brokenFirst();
      final asked = <String>[];
      final state = AppState(
        engine: engine,
        errorPrompt: (name, reason) async {
          asked.add('$name|$reason');
          return ExtractErrorDecision.skip;
        },
      );
      addTearDown(state.dispose);

      await state.selectFolderPath(twoPacks('as_err_skip').path);
      state.startExtract();
      await drainExtract(state);

      expect(asked, hasLength(1));
      expect(asked.single, startsWith('a.zip|'));
      expect(asked.single, contains('这个包坏了'),
          reason: '弹窗正文要用引擎给的那句话，不是我们另编一句');
      expect(engine.rounds, 2, reason: '跳过 ≠ 停批');
      expect(state.paused, isFalse);
      expect(state.batchRun, isTrue, reason: '跑完的批次照常消费快照');
    });

    t('选「暂停」→ 批次挂起、剩下的包一个都没动；resume 之后接着解', () async {
      final engine = brokenFirst();
      final state = AppState(
        engine: engine,
        errorPrompt: (name, reason) async => ExtractErrorDecision.pause,
      );
      addTearDown(state.dispose);

      await state.selectFolderPath(twoPacks('as_err_pause').path);
      state.startExtract();
      await settle(30);

      expect(state.paused, isTrue, reason: '选了暂停，批次该挂起');
      expect(engine.rounds, 1, reason: '挂起之后 b.zip 一个字节都不该动');
      expect(state.extracting, isTrue,
          reason: '暂停不是结束 —— 这一条正是它与闸门弹窗那颗「停止这批」的分水岭');

      state.resumeExtract();
      await drainExtract(state);

      expect(engine.rounds, 2, reason: '继续之后剩下的包接着解');
      expect(state.batchRun, isTrue,
          reason: '暂停可恢复，所以这批照常算是跑过了（不消费快照的是「停止这批」那条路）');
    });

    t('关掉 errorPause → 不问了，照旧记一条失败接着跑', () async {
      final engine = brokenFirst();
      final asked = <String>[];
      final state = AppState(
        engine: engine,
        errorPrompt: (name, reason) async {
          asked.add(name);
          return ExtractErrorDecision.pause;
        },
      );
      addTearDown(state.dispose);
      final toasts = toastTrail(state);

      // 默认是 true，这里显式关掉。
      state.toggleSetting('errorPause');

      await state.selectFolderPath(twoPacks('as_err_off').path);
      state.startExtract();
      await drainExtract(state);

      expect(asked, isEmpty, reason: '关掉了就别再打扰用户');
      expect(state.paused, isFalse);
      expect(engine.rounds, 2);
      expect(toasts.join('\n'), contains('这个包坏了'),
          reason: '不问不等于不报 —— 得有 toast 兜底');
    });

    t('没注入 errorPrompt → 与加这个特性之前一致', () async {
      final engine = brokenFirst();
      final state = AppState(engine: engine);
      addTearDown(state.dispose);
      final toasts = toastTrail(state);

      await state.selectFolderPath(twoPacks('as_err_absent').path);
      state.startExtract();
      await drainExtract(state);

      expect(engine.rounds, 2);
      expect(state.paused, isFalse);
      expect(state.batchRun, isTrue);
      expect(toasts.join('\n'), contains('这个包坏了'));
    });

    t('弹窗没弹成（决断为 null）→ 补一条 toast，既不暂停也不当跳过', () async {
      // DialogBridge 拿不到 BuildContext 时就是这么返回的。用户什么都没看见，
      // 那不是他的决定 —— 当暂停会凭空停住整批，当跳过会凭空少一个包。
      final engine = brokenFirst();
      final state = AppState(
        engine: engine,
        errorPrompt: (name, reason) async => null,
      );
      addTearDown(state.dispose);
      final toasts = toastTrail(state);

      await state.selectFolderPath(twoPacks('as_err_null').path);
      state.startExtract();
      await drainExtract(state);

      expect(state.paused, isFalse, reason: '没弹成不该被当成用户选了暂停');
      expect(engine.rounds, 2, reason: '也不该少解一个包');
      expect(toasts.join('\n'), contains('这个包坏了'),
          reason: '没弹成 = 用户什么都没看见，必须给一条提示');
    });

    t('被闸门拦下时走闸门那条线，**不**落进 errorPause 这条', () async {
      // 两档的另一边不一样（一个停得回来、一个停不回来），所以是两个回调。
      // 这条钉的是「别把闸门的异常喂给错误弹窗」—— 那样用户会看到一颗写着
      // 「暂停任务」的按钮，按下去整批却没了。
      const breach = LimitBreach(
        kind: LimitKind.entryCount,
        tag: '条目数超限',
        message: '条目太多，已放弃',
      );
      final engine = FakeEngine()
        ..behavior = (e, outDir) async {
          throw EngineException(breach.message, breach: breach);
        };
      final blockedAsked = <String>[];
      final errorAsked = <String>[];
      final state = AppState(
        engine: engine,
        blockedPrompt: (name, b) async {
          blockedAsked.add(name);
          return BlockedDecision.skip;
        },
        errorPrompt: (name, reason) async {
          errorAsked.add(name);
          return ExtractErrorDecision.skip;
        },
      );
      addTearDown(state.dispose);

      await state.selectFolderPath(twoPacks('as_err_breach').path);
      state.startExtract();
      await drainExtract(state);

      expect(blockedAsked, hasLength(2));
      expect(errorAsked, isEmpty, reason: '闸门的裁决不该落到错误弹窗上');
    });
  });

  group('格式识别弹窗（需求 5）', () {
    // 触发条件是扫描期就算好的 `ArchiveFlag.fakeExtension`，所以这里必须走
    // 真的扫描器（`FakeEngine` 只换 `extract`，扫描是真的）—— 把一个真 ZIP
    // 写成 `.pdf`，让扫描器自己把它认出来。

    Directory spoofed(String tag) {
      final root = tempRoot(tag);
      put(root, 'fake.pdf', realZip({'x': 'y'}));
      return root;
    }

    /// 取某个包那一条解压日志。
    ///
    /// **不能用 `logs.single`**：扫描结束时会先记一条 `文件夹（扫描）` 的汇总，
    /// 它排在这条前面。用 `.single` 会抛 "Too many elements" —— 而且抛在一个
    /// 看着毫不相干的地方（断言个数的那一行）。
    LogEntry extractLogFor(AppState state, String fileName) =>
        state.logs.firstWhere((l) => l.name == fileName,
            orElse: () => fail('$fileName 没有对应的日志行'));

    t('伪后缀包解压前被问一次，确认 → 照常解', () async {
      final seen = <FormatDetectInfo>[];
      final engine = FakeEngine();
      final state = AppState(
        engine: engine,
        formatPrompt: (info) async {
          seen.add(info);
          return true;
        },
      );
      addTearDown(state.dispose);

      await state.selectFolderPath(spoofed('as_fmt_ok').path);
      state.startExtract();
      await drainExtract(state);

      expect(seen, hasLength(1));
      expect(seen.single.fileName, 'fake.pdf');
      expect(seen.single.fakeExt, 'pdf', reason: '声明后缀，弹窗里标红的那一项');
      expect(seen.single.realFormat, 'ZIP 压缩包');
      expect(engine.rounds, 1);
      // 按名字取，不能用 `logs.single` —— 扫描自己也记了一条汇总
      // （`文件夹（扫描）`），它排在这条前面。
      expect(extractLogFor(state, 'fake.pdf').tags, contains('伪后缀'));
    });

    t('取消 → 这个包不进引擎，记一条 skipped，整批照常收尾', () async {
      final engine = FakeEngine();
      final state = AppState(
        engine: engine,
        formatPrompt: (info) async => false,
      );
      addTearDown(state.dispose);

      await state.selectFolderPath(spoofed('as_fmt_cancel').path);
      state.startExtract();
      await drainExtract(state);

      expect(engine.rounds, 0, reason: '用户明确不要这个包了');
      expect(extractLogFor(state, 'fake.pdf').status, LogStatus.skipped,
          reason: '跳过不是失败 —— 记成红的会让用户以为程序坏了');
      expect(state.batchRun, isTrue);
    });

    t('弹窗没弹成（决断为 null）→ 照原样解，绝不静默丢包', () async {
      // 这条是整组里最要紧的：null 当成 false 的话，弹窗因为拿不到 context
      // 而没能出现时，用户的压缩包会凭空从批次里消失，且没有任何解释。
      final engine = FakeEngine();
      final state = AppState(
        engine: engine,
        formatPrompt: (info) async => null,
      );
      addTearDown(state.dispose);

      await state.selectFolderPath(spoofed('as_fmt_null').path);
      state.startExtract();
      await drainExtract(state);

      expect(engine.rounds, 1, reason: '没问成 = 退回加这个弹窗之前的行为');
      expect(extractLogFor(state, 'fake.pdf').status, LogStatus.success);
    });

    t('后缀没被篡改的包一次都不问', () async {
      // 这条挡的是「一见就弹」。真机上一批 8 个包要是每个都弹一次，用户会
      // 直接把这个功能关掉 —— 而它本该只在真有蹊跷时出现。
      //
      // 所以这里的夹具是**后缀与真实格式对得上**的：`.zip` 里装 ZIP。
      // 别的都别放进来（比如 `.7z` 里装 ZIP），那种确实该被问，混进这条
      // 只会让断言变成一句和用例名字无关的话。
      final root = tempRoot('as_fmt_clean');
      put(root, 'a.zip', realZip({'x': 'y'}));
      put(root, 'b.zip', realZip({'x': 'y'}));

      final seen = <String>[];
      final state = AppState(
        engine: FakeEngine(),
        formatPrompt: (info) async {
          seen.add(info.fileName);
          return true;
        },
      );
      addTearDown(state.dispose);

      await state.selectFolderPath(root.path);
      state.startExtract();
      await drainExtract(state);

      expect(seen, isEmpty, reason: '两个包的后缀都与真实格式相符，没有什么可通报的');
    });

    t('FormatDetectInfo：十六进制与前置数据的文案都照格式拼', () {
      // 弹窗上摆出来的五项里有两项是十六进制、一项带条件后缀，拼错了在界面上
      // 看着也像对的 —— 所以钉在纯函数上测。
      final item = ScanItem(
        entryPath: '/sdcard/dir/fake.pdf',
        parts: const ['/sdcard/dir/fake.pdf'],
        sniff: const SniffResult(
          format: SniffFormat.zip,
          confidence: SniffConfidence.high,
          declaredExt: 'pdf',
          baseOffset: 4096,
          header: [0x50, 0x4B, 0x03, 0x04],
        ),
        sizeBytes: 10,
        flags: const {ArchiveFlag.fakeExtension},
        depth: 0,
      );

      final info = FormatDetectInfo.fromItem(item);

      expect(info.fileName, 'fake.pdf');
      expect(info.fakeExt, 'pdf');
      expect(info.fileHeader, '0x504B0304');
      expect(info.realFormat, 'ZIP 压缩包');
      expect(info.action, '按 ZIP 压缩包 解压（前面有 4096 字节前置数据）');
      expect(info.hexPreview, '50 4B 03 04');
    });

    t('没有前置数据时 action 不带那半句', () {
      final item = ScanItem(
        entryPath: '/sdcard/fake.pdf',
        parts: const ['/sdcard/fake.pdf'],
        sniff: const SniffResult(
          format: SniffFormat.zip,
          confidence: SniffConfidence.high,
          declaredExt: 'pdf',
          header: [0x50, 0x4B],
        ),
        sizeBytes: 10,
        flags: const {ArchiveFlag.fakeExtension},
        depth: 0,
      );

      expect(FormatDetectInfo.fromItem(item).action, '按 ZIP 压缩包 解压');
    });
  });

  group('批次用尽（batchRun）', () {
    t('跑完一批 → batchRun 为真、completed 为真', () async {
      final root = tempRoot('as_batchrun_ok');
      put(root, 'a.zip', realZip({'x': 'y'}));

      final engine = FakeEngine();
      final state = AppState(engine: engine);
      addTearDown(state.dispose);

      await state.selectFolderPath(root.path);
      expect(state.batchRun, isFalse, reason: '刚扫完还没跑，按钮该是「开始智能解压」');

      state.startExtract();
      await drainExtract(state);

      expect(state.completed, isTrue);
      expect(state.batchRun, isTrue);
    });

    t('整批都失败也是「用掉了」—— 闸门不能挂在 completed 上', () async {
      final root = tempRoot('as_batchrun_fail');
      put(root, 'a.zip', realZip({'x': 'y'}));

      final engine = FakeEngine()
        ..behavior = (e, outDir) async {
          throw const EngineException('坏了', code: DuzErrorCode.extract);
        };
      final state = AppState(engine: engine);
      addTearDown(state.dispose);

      await state.selectFolderPath(root.path);
      state.startExtract();
      await drainExtract(state);

      expect(state.completed, isFalse, reason: '有失败时 completed 就是 false');
      expect(state.batchRun, isTrue,
          reason: '失败了也重跑不得：_1/_2 照样会撒出来');
    });

    t('跑过之后 startExtract 直接拒绝，不再惊动引擎', () async {
      final root = tempRoot('as_batchrun_guard');
      put(root, 'a.zip', realZip({'x': 'y'}));

      final engine = FakeEngine();
      final state = AppState(engine: engine);
      addTearDown(state.dispose);

      await state.selectFolderPath(root.path);
      state.startExtract();
      await drainExtract(state);
      expect(engine.rounds, 1);

      state.startExtract();
      await settle();

      expect(engine.rounds, 1, reason: '同一个队列不该被重排一遍');
      expect(state.toastType, 'warn');
      expect(state.toastMsg, contains('换个文件夹'));
    });

    t('重新选目录 → 闸门放开（新快照，可以再跑）', () async {
      final root = tempRoot('as_batchrun_reset');
      put(root, 'a.zip', realZip({'x': 'y'}));

      final engine = FakeEngine();
      final state = AppState(engine: engine);
      addTearDown(state.dispose);

      await state.selectFolderPath(root.path);
      state.startExtract();
      await drainExtract(state);
      expect(state.batchRun, isTrue);

      // selectFolderPath 会走 _resetExtractState + 重新扫描。
      await state.selectFolderPath(root.path);

      expect(state.batchRun, isFalse);
      expect(state.completed, isFalse);

      state.startExtract();
      await drainExtract(state);
      expect(engine.rounds, 2, reason: '新快照要能真的再跑一次');
    });
  });

  // ---------------------------------------------------------------------------
  // 持久化（条目 3）
  //
  // 插件的真实读写由 `test/data/` 下各自的 repo 用例对着 mock 通道验。这组盯
  // 的是另一半：**AppState 在什么时候、把什么内容交了出去**，以及一条产品
  // 约束 —— 磁盘上不能出现「哪些文件夹解压过」。
  // ---------------------------------------------------------------------------

  group('恢复：构造时把读回来的一份盖上去', () {
    t('设置 / 深度 / 档位 / 阈值 / 密码库 / 日志 全部就位', () {
      final store = FakeStore()
        ..toLoad = AppSnapshot(
          settings: const SettingsData(
            toggles: {
              'recursive': false,
              'symmetricOutput': true,
              'fakeExtDetect': true,
              'splitMerge': true,
              'pwdAutoTry': true,
              'errorPause': true,
              'crcCheck': false,
            },
            maxDepth: 10,
            limitPreset: 3,
            limits: LimitThresholds(maxEntries: 4242),
          ),
          vault: const [
            PasswordEntry(value: '从磁盘读回来的', hitCount: 5, lastUsed: '2026-09-30'),
          ],
          logs: const [
            LogEntry(
              name: '上次那个包.zip',
              status: LogStatus.failed,
              size: '1.0 MB',
              time: '09-30 20:33',
              duration: '-',
              tags: ['解压失败'],
            ),
          ],
        );

      final state = AppState(
        engine: FakeEngine(),
        persistStore: store,
        restore: store.toLoad,
      );
      addTearDown(state.dispose);

      expect(state.setting('recursive'), isFalse);
      expect(state.setting('crcCheck'), isFalse);
      expect(state.setting('splitMerge'), isTrue);
      expect(state.maxDepth, 10);
      expect(state.limitPreset, 3);
      expect(state.limits.maxEntries, 4242);
      expect(state.passwords.single.value, '从磁盘读回来的');
      expect(state.passwords.single.hitCount, 5);
      expect(state.logs.single.name, '上次那个包.zip');
      expect(state.logs.single.status, LogStatus.failed);
    });

    t('档位不越界、深度收敛 —— 读回来的坏值不能让设置页崩', () {
      // 这两个字段是设置页的芯片直接拿去 `indexOf` 的：越界就是数组下标 -1，
      // 打开设置页即崩。收敛在 `SettingsRepo` 里也做了一遍，这里是第二道。
      final store = FakeStore()
        ..toLoad = const AppSnapshot(
          settings: SettingsData(maxDepth: 999, limitPreset: 88),
        );

      final state = AppState(
        engine: FakeEngine(),
        persistStore: store,
        restore: store.toLoad,
      );
      addTearDown(state.dispose);

      expect(state.maxDepth, 20, reason: '收敛到最近的合法档');
      expect(state.limitPreset, kLimitPresets.length, reason: '夹到「自定义」档');
      expect(state.limitsCustom, isTrue);
    });

    t('档里缺一个开关的键 → 那一个回出厂默认，不变成 false', () {
      // 整份替换（而不是从出厂值起步再覆盖）的话，缺的键会悄悄变成 false，
      // 表现为「升级 app 之后某个功能自己关了」。
      final store = FakeStore()
        ..toLoad = const AppSnapshot(settings: SettingsData(toggles: {}));

      final state = AppState(
        engine: FakeEngine(),
        persistStore: store,
        restore: store.toLoad,
      );
      addTearDown(state.dispose);

      expect(state.setting('recursive'), isTrue);
      expect(state.setting('crcCheck'), isTrue);
    });

    t('没注入 store → 一切照出厂默认，不崩', () {
      final state = AppState(engine: FakeEngine());
      addTearDown(state.dispose);

      expect(state.setting('recursive'), isTrue);
      expect(state.maxDepth, kDefaultMaxDepth);
      expect(state.passwords, isEmpty);
      expect(state.logs, isEmpty);
    });

    t('恢复一份「什么都有」的档，也不会把「解压过」带过来', () {
      // **这是那条产品约束的机器判据。** 磁盘上要是记了「哪些目录解过了」，
      // 它就会在这里体现成 `folderSelected` 为真、`batchRun` 为真 —— 用户
      // 一开 app 就看见「换个文件夹」，想重解一个目录却被挡在外面。
      //
      // 恢复的只有设置、密码、日志；源目录**不在** `AppSnapshot` 里
      // （见 persist.dart 的库注释）。所以起点必须仍是「没选过文件夹」。
      final store = FakeStore()..toLoad = AppSnapshot.empty;
      final state = AppState(
        engine: FakeEngine(),
        persistStore: store,
        restore: store.toLoad,
      );
      addTearDown(state.dispose);

      expect(state.folderSelected, isFalse);
      expect(state.folderPath, '');
      expect(state.archives, isEmpty);
      expect(state.batchRun, isFalse, reason: '闸门是纯内存的，不该从磁盘上活过来');
      expect(state.hasScanned, isFalse);
    });
  });

  group('落盘：改了什么就写什么', () {
    late FakeStore store;
    late AppState state;

    setUp(() {
      store = FakeStore();
      state = AppState(engine: FakeEngine(), persistStore: store);
    });
    tearDown(() => state.dispose());

    t('切开关 → 当场交出一份带新值的设置', () {
      state.toggleSetting('recursive');

      expect(store.lastSettings, isNotNull);
      expect(store.lastSettings!.toggles['recursive'], isFalse);
      expect(store.lastSettings!.toggles['crcCheck'], isTrue, reason: '别的开关要带上');
    });

    t('深度 / 档位 / 单项阈值都会落盘', () {
      state.cycleMaxDepth();
      expect(store.lastSettings!.maxDepth, 5);

      state.setLimitPreset(2);
      expect(store.lastSettings!.limitPreset, 2);
      expect(store.lastSettings!.limits, LimitThresholds.strict);

      state.setLimit(LimitField.entries, 777);
      expect(store.lastSettings!.limits.maxEntries, 777);
      expect(store.lastSettings!.limitPreset, kLimitPresets.length,
          reason: '手改一项就落到「自定义」，这一条也要跟着存');
    });

    t('增删密码 → 交出整库快照', () {
      state.addPassword('新密码');
      expect(store.vaultSaved, hasLength(1));
      expect(store.vaultSaved.last.single.value, '新密码');

      state.deletePassword(0);
      expect(store.vaultSaved, hasLength(2));
      expect(store.vaultSaved.last, isEmpty);
    });

    t('往空密码库加同一个密码两次只落一次盘', () {
      state.addPassword('同一个');
      state.addPassword('同一个');
      expect(store.vaultSaved, hasLength(1));
    });

    t('日志只在自然边界写 —— 不是每解一个包写一次', () async {
      final root = tempRoot('as_persist_logs');
      put(root, 'a.zip', realZip({'x': 'y'}));
      put(root, 'b.zip', realZip({'x': 'y'}));

      await state.selectFolderPath(root.path);
      expect(store.logsSaved, hasLength(1), reason: '扫描收尾写一次');
      expect(store.lastLogs!.single.name, contains('（扫描）'));

      final before = store.logsSaved.length;
      state.startExtract();
      await drainExtract(state);

      expect(store.logsSaved, hasLength(before + 1),
          reason: '两个包也只该有整批收尾那一次，不是每包一次');
      // 收尾这一次要含上逐包的两条 —— 攒到边界一起写，不等于丢掉它们。
      expect(store.lastLogs!.length, 3, reason: '两条解压 + 一条扫描');
      expect(store.lastLogs!.map((e) => e.name), containsAll(['a.zip', 'b.zip']));
    });

    t('落盘的日志里没有完整路径 —— 那才是能反查「解过了」的东西', () async {
      final root = tempRoot('as_persist_nopath');
      put(root, 'sub/a.zip', realZip({'x': 'y'}));

      await state.selectFolderPath(root.path);
      state.startExtract();
      await drainExtract(state);

      expect(store.logsSaved, isNotEmpty, reason: '前提：确实写过了');
      expect(store.savedLogsMentionPath(root.path), isFalse);
      expect(store.lastLogs!.map((e) => e.name), contains('a.zip'));
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

/// 固定返回一个数的空间探针，顺带记下被问过哪些路径。
///
/// 继承而不是走真通道：`DiskSpaceProbe` 的默认实现依赖 `Platform.isAndroid`
/// 与 `MethodChannel`，前者在 Windows 宿主上是 false、后者要
/// `TestDefaultBinaryMessengerBinding` 才有响应。这里要验的是「AppState 把这
/// 个数原样交给引擎」，通道那头另有 `disk_space_test.dart` 管。
class _StubProbe extends DiskSpaceProbe {
  _StubProbe(this.answer);

  /// 要返回的数；`null` 表示量不到。
  final int? answer;

  final List<String> paths = [];

  @override
  Future<int?> availableBytes(String path) async {
    paths.add(path);
    return answer;
  }
}

