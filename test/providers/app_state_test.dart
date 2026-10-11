import 'dart:async';
import 'dart:io';

import 'package:deep_unzip/data/persist.dart';
import 'package:deep_unzip/engine/controller.dart';
import 'package:deep_unzip/engine/limits.dart';
import 'package:deep_unzip/engine/models.dart';
import 'package:deep_unzip/engine/output_paths.dart';
import 'package:deep_unzip/engine/protocol.dart';
import 'package:deep_unzip/models/archive_file.dart';
import 'package:deep_unzip/models/log_entry.dart';
import 'package:deep_unzip/models/password_entry.dart';
import 'package:deep_unzip/providers/app_state.dart';
import 'package:deep_unzip/services/password_prompt.dart';
import 'package:deep_unzip/services/prompts.dart';
import 'package:deep_unzip/services/disk_space.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../engine/zip_fixtures.dart';
import '../support/fake_engine.dart';
import '../support/fake_keep_alive.dart';
import '../support/fake_notification_permission.dart';
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
  Future<void> drainExtract(AppState state, {int budget = 500}) async {
    for (var i = 0; i < budget; i++) {
      if (!state.extracting) return;
      await Future<void>.delayed(Duration.zero);
    }
    fail('解压批次没在预期轮次内收尾');
  }

  /// 推到 [predicate] 为真为止（最多 [budget] 轮）。
  ///
  /// [settle] 那种「推固定轮数」只够穿过几个纯内存的 `await`；批次里夹着
  /// **真文件 IO** 的几步（最典型的是出队时算包指纹的 `archiveIdentity`）
  /// 就不是推得动的 —— `Duration.zero` 的定时器只管让出事件循环，真 IO 什么
  /// 时候完成取决于机器忙不忙。测试机上一跑全量（多个测试文件并发）就够不上
  /// 了，表现成「批次卡在第一个包」。所以这种地方等**条件**，不等轮数。
  Future<void> waitUntil(bool Function() predicate, {int budget = 2000}) async {
    for (var i = 0; i < budget; i++) {
      if (predicate()) return;
      await Future<void>.delayed(Duration.zero);
    }
    fail('等待的条件没在预期轮次内成立');
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

  // ---------------------------------------------------------------------------
  // 首页「选择文件」那条路（`selectFilePath`）
  //
  // 与「选文件夹」的全部差别就在于：**只解点名的那一个**，同目录里没被选的
  // 不算。这条走的是真引擎（`booted()` 起的是真 worker isolate），所以下面
  // 断的是端到端结果，不是某个函数的返回值。
  // ---------------------------------------------------------------------------
  group('选单个文件', () {
    t('只解点名的那一个，同目录其它包不出现', () async {
      final root = tempRoot('as_onefile');
      // 同一个目录里放三个包，只点中间那个；子目录里再塞一个。
      put(root, 'a.zip', realZip({'x': 'y'}));
      final picked = put(root, 'b.zip', realZip({'x': 'y'}));
      put(root, 'c.zip', realZip({'x': 'y'}));
      put(root, 'sub/d.zip', realZip({'x': 'y'}));

      final state = booted();
      await state.selectFilePath(picked);

      expect([for (final a in state.archives) a.name], ['b.zip'],
          reason: '这就是这条入口存在的理由 —— 不算上同目录里没选的那些，'
              '也不递归进子目录');
      expect(state.hasScanned, isTrue);
    });

    t('源根取父目录，卡片名取文件名', () async {
      // `_folderPath` 同时是「自定义输出目录」的镜像基准、剩余空间所在的卷、
      // 「打开输出目录」的兜底。单选文件时设成**父目录**，三个角色全都仍然成立。
      final root = tempRoot('as_onefile_paths');
      put(root, 'sub/inner.zip', realZip({'x': 'y'}));

      final state = booted();
      await state.selectFilePath(p.join(root.path, 'sub', 'inner.zip'));

      expect(state.folderPath, p.join(root.path, 'sub'));
      expect(state.folderName, 'inner.zip',
          reason: '卡片标题说的是「选了什么」，所以是文件名');
      expect(state.outputDirName, 'sub',
          reason: '而「输出到」那行说的是输出落在哪 —— 对称输出时是父目录，'
              '拿文件名去填那句就是假话');
    });

    t('明确选中的容器格式文件照样解（.docx 也是 zip）', () async {
      final root = tempRoot('as_onefile_docx');
      final docx = put(
        root,
        '报告.docx',
        realZip({
          '[Content_Types].xml': '<Types/>',
          'word/document.xml': '<w:document/>',
        }),
      );

      final state = booted();
      await state.selectFilePath(docx);

      expect([for (final a in state.archives) a.name], ['报告.docx'],
          reason: '用户点了它就是要它 —— 那条容器防线是为「扫一整个目录」设计的');
    });

    t('对照：同一个文件走「选文件夹」时被容器防线拦下', () async {
      final root = tempRoot('as_onefile_docx_ctrl');
      put(
        root,
        '报告.docx',
        realZip({
          '[Content_Types].xml': '<Types/>',
          'word/document.xml': '<w:document/>',
        }),
      );

      final state = booted();
      await state.selectFolderPath(root.path);

      expect(state.archives, isEmpty, reason: '这条防线在目录扫描里不能松');
      expect(state.lastScan!.containerSkipped, 1);
    });

    t('点中的是分卷的一片 → 同目录的其余分片自动补齐', () async {
      final root = tempRoot('as_onefile_split');
      final zip = realZip({'hello.txt': 'world'});
      final half = zip.length ~/ 2;
      final first = put(root, 'big.zip.001', zip.sublist(0, half));
      put(root, 'big.zip.002', zip.sublist(half));

      final state = booted();
      await state.selectFilePath(first);

      // 列表上是一条（分卷合并成一行），但它的 parts 得是两片 —— 只拿一片
      // 在解码器眼里什么都不是。
      expect(state.archives, hasLength(1));
      expect(state.archives.single.flags, contains(ArchiveFlag.split),
          reason: '补齐之后它才是一个完整的分卷家族');
    });

    t('文件不存在 → 记一条失败日志，不崩', () async {
      final root = tempRoot('as_onefile_missing');
      final state = booted();

      await state.selectFilePath(p.join(root.path, '没有这个.zip'));

      expect(state.archives, isEmpty);
      expect(state.logs.first.status, LogStatus.failed);
      expect(state.toastType, 'warn');
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

  group('日志保留条数', () {
    LogEntry numbered(int i) => LogEntry(
          name: '第 $i 个',
          status: LogStatus.success,
          size: '-',
          time: 'x',
          duration: '-',
          tags: const [],
        );

    t('setMaxLogs 填多少就是多少，不吸附到档位', () {
      final store = FakeStore();
      final state = AppState(engine: FakeEngine(), persistStore: store);
      addTearDown(state.dispose);

      expect(state.maxLogs, kDefaultMaxLogs);
      expect(store.settingsSaved, isEmpty, reason: '还没动过，一次都不该写盘');

      state.setMaxLogs(347);
      expect(state.maxLogs, 347, reason: '347 就该是 347，不该被挪成 300 或 500');
      expect(store.lastSettings?.maxLogs, 347,
          reason: '改完要立刻交出去，不能等下次顺手写');
    });

    t('越界夹回区间 —— 弹窗那边先拦一道，这是第二道', () {
      final state = AppState(engine: FakeEngine());
      addTearDown(state.dispose);

      state.setMaxLogs(0);
      expect(state.maxLogs, kMinMaxLogs);
      state.setMaxLogs(999999);
      expect(state.maxLogs, kMaxMaxLogs);
    });

    t('调小上限 → 当场丢掉最早的，并立刻落盘 + 出声', () async {
      final root = tempRoot('as_logcap_shrink');
      put(root, 'a.zip', realZip({'x': 'y'}));

      final store = FakeStore();
      final state = AppState(
        engine: EngineController(throttle: Duration.zero),
        persistStore: store,
      );
      addTearDown(state.dispose);

      // 攒到比最小档（100）多几条。每条扫描收尾都会落盘一次，所以这期间
      // `store.lastLogs` 一直是满的 —— 正好用来验「调小之后它跟着缩」。
      for (var i = 0; i < 105; i++) {
        await state.selectFolderPath(root.path);
      }
      expect(state.logs, hasLength(105));
      final before = List.of(state.logs);

      state.setMaxLogs(1000);
      expect(state.logs, hasLength(105), reason: '往大调不该丢东西');
      state.setMaxLogs(100);
      expect(state.maxLogs, 100);

      expect(state.logs, hasLength(100));
      expect(identical(state.logs.first, before.first), isTrue,
          reason: '最新的在队首，必须留着');
      expect(identical(state.logs.last, before[99]), isTrue,
          reason: '砍的是队尾 —— 留下的正好是队首那 100 条');
      expect(store.lastLogs, hasLength(100),
          reason: '砍掉不能只砍内存：下一次落盘又会把 105 条写回去');
      expect(store.lastSettings?.maxLogs, 100);
      expect(state.toastType, 'warn', reason: '丢的是用户自己的历史，得说一声');
      expect(state.toastMsg, contains('已丢弃最早的 5 条'));
    });

    t('读回来的档位生效，磁盘上多出来的当场砍掉', () {
      final store = FakeStore()
        ..toLoad = AppSnapshot(
          settings: const SettingsData(maxLogs: 100),
          // 140 条：比用户设的 100 多，但远没到 `kMaxMaxLogs` —— 仓库那一层
          // 不会替我们砍，只有 `AppState` 知道用户其实只要 100 条。
          logs: [for (var i = 0; i < 140; i++) numbered(i)],
        );

      final state = AppState(
        engine: FakeEngine(),
        persistStore: store,
        restore: store.toLoad,
      );
      addTearDown(state.dispose);

      expect(state.maxLogs, 100);
      expect(state.logs, hasLength(100));
      expect(state.logs.first.name, '第 0 个', reason: '最新的在前，从头留');
      expect(state.logs.last.name, '第 99 个');
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
      expect(state.outcome, isNull, reason: '还没跑过任何一批');
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
      expect(state.outcome, BatchOutcome.clean);
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

    t('speed 单位是 MB/s；剩余时间是当前包的，换包时清掉', () async {
      final root = tempRoot('as_speed');
      put(root, 'a.zip', realZip({'x': 'y'}));
      put(root, 'b.zip', realZip({'x': 'y'}));

      const mb = 1024 * 1024;
      final gate = Completer<void>();
      late AppState state;
      String? etaAtSecondStart;
      final engine = FakeEngine()
        ..behavior = (e, outDir) async {
          if (e.rounds == 1) {
            e.onExtractTick?.call(const ExtractTick(
                doneBytes: 0, totalBytes: 100 * mb, current: 'x'));
            await Future<void>.delayed(const Duration(milliseconds: 200));
            e.onExtractTick?.call(const ExtractTick(
                doneBytes: 10 * mb, totalBytes: 100 * mb, current: 'x'));
            await gate.future;
          } else {
            etaAtSecondStart = state.eta;
          }
        };
      state = AppState(engine: engine);
      addTearDown(state.dispose);

      await state.selectFolderPath(root.path);
      state.startExtract();
      await settle();
      await Future<void>.delayed(const Duration(milliseconds: 300));

      // 10 MB / ~0.2 s ≈ 50 MB/s。宽一点的区间是给测试机的调度抖动留的；
      // 关键是它不再是字节/秒（那会是 5e7 量级）。
      expect(state.speed, inInclusiveRange(5, 100));
      // 剩下 90 MB 按 ~50 MB/s 算，几秒的量级 —— 只属于 a.zip。
      expect(state.eta, isNot('--'));

      gate.complete();
      await drainExtract(state);
      expect(etaAtSecondStart, '--', reason: '上一个包的剩余时间不该带到下一个包');
    });

    t('停止解压：当前包被真正打断，剩下的包不再开工', () async {
      final root = tempRoot('as_stop');
      put(root, 'a.zip', realZip({'x': 'y'}));
      put(root, 'b.zip', realZip({'x': 'y'}));
      put(root, 'c.zip', realZip({'x': 'y'}));

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

      state.stopExtract();
      // **取消真的送到引擎了**。从前这里只置一个标志位，因为同步 FFI 期间
      // worker 收不到命令；现在原生侧自己起线程、worker 只是轮询，所以
      // `cancel()` 的信号在下一轮轮询就传下去了。
      expect(engine.cancelCalls, 1, reason: '按下停止必须真的去叫引擎停');
      expect(state.extracting, isTrue, reason: '不是瞬间：要等原生侧在下一个进度点 unwind');
      expect(state.toastMsg, contains('正在停止当前压缩包'));

      gate.complete(); // 原生侧 unwind 完，这一次解压以「被中止」返回
      await drainExtract(state);

      expect(engine.rounds, 1, reason: '剩下两个包不该再开工 —— 停止没有「继续」');
      expect(state.extracting, isFalse);
      // 停在半路也要出总结卡片，而且标题必须说「停了」而不是「完成了」
      // （见 `home_screen.dart` 的 `_bannerTitle`）。那句「完成」是假话：三个
      // 包一个都没解完。
      expect(state.outcome, BatchOutcome.stopped);
      // **被中止的那个包不算「已完成」。** 它只在磁盘上留了半棵树（写到一半
      // 的那个条目由原生侧删掉，但前面的条目已经落地），算进「已完成 N 个」
      // 是句假话。所以这里是 0 而不是旧语义的 1。
      expect(state.completeDetail, contains('已完成 0/3 个压缩包'));
      // 也不是失败：这是我们照着用户的命令办的，不是程序坏了。
      expect(state.failedCount, 0);
      expect(
        state.logs.any((l) => l.status == LogStatus.failed),
        isFalse,
        reason: '停止不是失败 —— 用户看到一排红字会以为程序坏了',
      );
      expect(
        state.logs.any((l) => l.status == LogStatus.skipped),
        isTrue,
        reason: '日志要留下一条「用户停止」，让人回头能看出这批断在哪里',
      );
      // 停止**也消费**这份快照：主按钮换成「更换目标」。真机验收时用户要求的
      // —— 从前的做法是放开闸门、回到「开始解压」，可那看起来像什么都没
      // 发生过，用户会以为点下去能接着解剩下两个。
      expect(state.batchRun, isTrue);
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

    t('没在解压时点「停止」是空操作', () {
      final state = booted();
      state.stopExtract();
      expect(state.extracting, isFalse);
      expect(state.toastMsg, isNull, reason: '没活儿在跑就不该冒一句「正在停止当前压缩包」出来');
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

    t('停止之后又被 dispose：不崩，也不会卡住', () async {
      // 这条原先守的是「dispose 必须放行暂停闸门，否则那一帧永远悬着」。
      // 暂停闸门已经随「不要暂停」一起删了，但这两个动作凑在一起仍然是
      // 用户真会走到的路径（按了停止、随即离开页面），值得留一条守着。
      final root = tempRoot('as_dispose_stopped');
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

      state.stopExtract();
      gate.complete();
      await settle();
      expect(state.extracting, isFalse, reason: '停止请求发出后当前包被打断就该收尾');

      state.dispose();
      await settle(60);

      expect(state.extracting, isFalse);
      expect(engine.rounds, 1, reason: '停止之后剩下的包不该再开工');
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
    t('setMaxDepth 是自由输入：区间内的值原样生效，界外才夹', () {
      final state = booted();

      state.setMaxDepth(7);
      expect(state.maxDepth, 7, reason: '不再是 {0,5,10,20} 那张档位表');

      state.setMaxDepth(0);
      expect(state.maxDepth, 0, reason: '0 = 不递归，是语义而不是「填错了」');

      state.setMaxDepth(kMaxMaxDepth + 1);
      expect(state.maxDepth, kMaxMaxDepth, reason: '上界就是实现层那道硬顶');
    });

    t('setSniffWindow 同样是自由输入：区间内原样，界外才夹', () {
      final state = booted();

      state.setSniffWindow(2 << 20);
      expect(state.sniffWindow, 2 << 20);

      state.setSniffWindow(kMinSniffWindow - 1);
      expect(state.sniffWindow, kMinSniffWindow,
          reason: '下界不是「填到这儿会坏」—— 自解压包那条路不读这一项');

      state.setSniffWindow(kMaxSniffWindow + 1);
      expect(state.sniffWindow, kMaxSniffWindow,
          reason: '上界对齐 7-Zip 客户端自己的向前搜索上限');
    });

    t('扫描时把当前的搜索窗口交给引擎', () async {
      final root = tempRoot('as_window');
      put(root, 'a.zip', realZip({'x': 'y'}));

      final engine = FakeEngine();
      final state = AppState(engine: engine);
      addTearDown(state.dispose);

      state.setSniffWindow(3 << 20);
      await state.selectFolderPath(root.path);

      expect(engine.scanOptionsSeen.single.sniffWindowBytes, 3 << 20,
          reason: '设置页那一行必须真的随扫描命令流到 sniffFile 手上');
    });

    t('toggleSetting 翻转指定 key，未登记的 key 读作 false', () {
      final state = booted();
      final before = state.setting('errorPause');
      state.toggleSetting('errorPause');

      expect(state.setting('errorPause'), !before);
      expect(state.setting('不存在的key'), isFalse);
      // 「递归解压」那颗 2026-10 与 maxDepth 合并后删了。键还留在表里的话，
      // `setting('recursive')` 会静默读成 false（也就是「关着」），而深度那
      // 一档同时在说另一件事 —— 没人看得出这里有两个开关在打架。
      expect(kDefaultToggles.containsKey('recursive'), isFalse);
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

    // 这里原来还有三条「注册 / 删除解压方式」的用例。那个入口 2026-10 撤了：它
    // 从来没接到引擎上（`addExtractor` 只往列表里加一行，识别靠嗅探表、解压靠
    // 内置 7-Zip 核心，没有任何一边读它），注册成功的 toast 是假的。现在格式
    // 清单是只读的，见 `test/data/builtin_extractors_test.dart`。
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
      expect(state.outcome, BatchOutcome.clean);
      expect(state.progress, 1.0);
    });

    t('解嵌套包时「递归层」跟着走；分母变大时进度如实回退', () async {
      final root = tempRoot('as_nest_depth');
      final outer = put(root, 'nested.zip', realZip({'readme.txt': 'x'}));
      final innerPath = put(payload, 'inner.zip', realZip({'deep.txt': 'y'}));
      final outerSize = File(outer).lengthSync();

      final depthsDuring = <int>[];
      final progressDuring = <double>[];
      final gate = Completer<void>();
      late AppState state;
      final engine = FakeEngine()
        ..nestedFor[resolveOutputDir(outer)] = [itemAt(innerPath, depth: 1)]
        ..behavior = (e, outDir) async {
          depthsDuring.add(state.depth);
          progressDuring.add(state.progress);
          if (e.rounds == 2) await gate.future;
        };
      state = AppState(engine: engine);
      addTearDown(state.dispose);

      await state.selectFolderPath(root.path);
      state.startExtract();
      // **不能只「推几轮微任务」**：外层解完到内层开工之间夹着一次真文件读
      // —— 内层包有祖先集，出队时要 `archiveIdentity` 算指纹（见
      // `app_state.dart` 里那段「身份是懒算的」）。真 IO 不是推 20 轮
      // `Duration.zero` 定时器能盖住的，机器一忙就够不上（memory
      // `fakeasync-real-io-trap` 是同一个坑）。所以等**条件**，不等轮数。
      await waitUntil(() => depthsDuring.length == 2);

      expect(depthsDuring, [0, 1], reason: '从前 _depth 从没被赋值过，界面恒为 0');
      // 外层解完时是 100%，发现内层（100 B）之后分母变成 outer + 100。
      expect(progressDuring.last, closeTo(outerSize / (outerSize + 100), 1e-9),
          reason: '只进不退会让它卡在 100%，这正是用户看到的「进度条不对」');

      gate.complete();
      await drainExtract(state);
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
      // 「自动」那半句是钉「这不是用户干的」：自引用是**我们**判出来的，
      // 用户没在弹窗上按过任何东西。写进「手动跳过」会凭空多出一个他做过的决定。
      expect(state.completeDetail, contains('1 个自动跳过'));
      expect(state.completeDetail, isNot(contains('手动跳过')));
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

      state.setMaxDepth(5); // 内层包的 depth 是 6 —— 差一级，必须被拦

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

    t('深度 0 = 不递归 → 内层包既不进列表也不解，连扫都不扫', () async {
      // 这条原来测的是那颗「递归解压」开关，2026-10 那颗与深度合并后删了：
      // 现在让内层包不出现的手段就是深度填 0。
      final root = tempRoot('as_norec');
      final outer = put(root, 'a.zip', realZip({'x': 'y'}));
      final inner = put(payload, 'inner.zip', realZip({'y': 'z'}));

      final engine = FakeEngine()
        ..nestedFor[resolveOutputDir(outer)] = [itemAt(inner, depth: 1)];
      final state = AppState(engine: engine);
      addTearDown(state.dispose);

      state.setMaxDepth(0);

      await state.selectFolderPath(root.path);
      state.startExtract();
      await drainExtract(state);

      expect(engine.rounds, 1, reason: '顶层那个照解，只是不再往下走');
      expect(engine.recursiveSeen, [isFalse],
          reason: '不递归时连「扫一下里面有没有包」都不该让引擎做 —— 扫了也全丢');
      expect(state.archives.map((a) => a.name), ['a.zip']);
    });

    // ---- 顶层扫描也要过同一道闸门（2026-10 补的）-----------------------
    //
    // 深度数的是「**从被选目录**往下走了几步」，而「一步」有两种、同等计入：
    // 进一层子目录、解开一层嵌套包。
    //
    // 之前只有第二种被闸门管着（`_enqueueNested`），顶层那批是无条件排队的，
    // 于是 `maxDepth = 0` 拦得住包**里面**的嵌套包，却拦不住**目录里面**的
    // 包 —— 而按上面那条规则，后者离被选目录更远。

    t('子目录里的包也占额度：maxDepth = 0 时它不进队列，但仍然列出来', () async {
      final root = tempRoot('as_topsub');
      put(root, 'a.zip', realZip({'x': 'y'}));
      put(root, 'sub/b.zip', realZip({'x': 'y'}));

      final engine = FakeEngine();
      final state = AppState(engine: engine);
      addTearDown(state.dispose);

      state.setMaxDepth(0);

      await state.selectFolderPath(root.path);
      state.startExtract();
      await drainExtract(state);

      expect(engine.rounds, 1, reason: '只有躺在被选目录下那一个该被解');
      expect(engine.recursiveSeen, [isFalse]);
      expect(
        state.archives.map((a) => a.name),
        ['a.zip', 'b.zip'],
        reason: '子目录里那个仍然要列出来 —— 它是扫描结果，用户得看得见目录里有什么，'
            '只是这一批轮不到它',
      );
      expect(
        state.logs.map((l) => l.tags).expand((t) => t),
        contains('超出递归深度'),
        reason: '被拦下要留一条记录，跟嵌套包那条路长一样',
      );
    });

    t('maxDepth = 1 → 子目录里的包正好占那一层，照样解', () async {
      // 与上一条只差一个数：深度填 1 时，`sub/b.zip` 自己在第 1 层，
      // 正好在闸门之内。这条钉住「不是被一刀切掉」，而是真的按层级算。
      final root = tempRoot('as_topsub1');
      put(root, 'a.zip', realZip({'x': 'y'}));
      put(root, 'sub/b.zip', realZip({'x': 'y'}));

      final engine = FakeEngine();
      final state = AppState(engine: engine);
      addTearDown(state.dispose);

      state.setMaxDepth(1);

      await state.selectFolderPath(root.path);
      state.startExtract();
      await drainExtract(state);

      expect(engine.rounds, 2, reason: '两个都在第 1 层之内，都该解');
      expect(
        state.logs.map((l) => l.tags).expand((t) => t),
        isNot(contains('超出递归深度')),
      );
    });

    t('顶层一个都排不进来 → 这批不算跑过，调大深度后原地点得动', () async {
      final root = tempRoot('as_topall');
      put(root, 'sub/b.zip', realZip({'x': 'y'}));

      final engine = FakeEngine();
      final state = AppState(engine: engine);
      addTearDown(state.dispose);

      state.setMaxDepth(0);

      await state.selectFolderPath(root.path);
      state.startExtract();
      await drainExtract(state);

      expect(engine.rounds, 0, reason: '一个都不该送去解');
      // `batchRun` 由 `_outcome` 派生。空批次要是也把它置上，主按钮会变成
      // 「更换目标」，用户把深度调大之后**同一个快照就再也跑不了**了。
      expect(state.batchRun, isFalse, reason: '什么都没跑，不算「这批跑过了」');
      expect(state.logs.first.status, LogStatus.skipped);
      expect(state.logs.first.tags, contains('超出递归深度'));

      // 调大之后原地再来一次 —— 这条路必须通，否则用户只有一个选择：
      // 重新选目录（那会把已经解好的再解一遍）。
      state.setMaxDepth(1);
      state.startExtract();
      await drainExtract(state);

      expect(engine.rounds, 1, reason: '调大深度后同一份快照该能接着跑');
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

  // ---------------------------------------------------------------------------
  // 自定义输出目录（2026-10，由那颗「目录对称输出」改名而来）
  //
  // 旧那颗是**死开关**：全仓库只有设置页写它，`resolveOutputDir` 从不读设置，
  // 所以它的值对磁盘没有任何影响（账见 `persist.dart` 的 `kDefaultToggles`）。
  // 这一组盯的是新语义真的接到了磁盘上 —— 关着与从前逐字一致，开着则把根换成
  // 用户选的那个，并且**按源目录结构镜像**写进去。
  // ---------------------------------------------------------------------------
  group('自定义输出目录', () {
    /// `resolveOutputDir` 一律返回 posix 形态（见 `output_paths.dart` 的
    /// `_toPosix`），而 `tempRoot` 给的是宿主形态。断言前统一成 `/`。
    String slash(String s) => s.replaceAll(r'\', '/');

    /// 造一个假扫描项，只给嵌套那两条用例用。
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

    AppState opened({
      required FakeEngine engine,
      required String outRoot,
    }) {
      final state = AppState(engine: engine);
      addTearDown(state.dispose);
      state.toggleSetting('customOutput');
      state.setOutputRoot(outRoot);
      return state;
    }

    t('关着（出厂默认）→ 照旧解到包旁边', () async {
      final root = tempRoot('as_custom_off');
      put(root, 'sub/a.zip', realZip({'x': 'y'}));

      final engine = FakeEngine();
      final state = AppState(engine: engine);
      addTearDown(state.dispose);

      await state.selectFolderPath(root.path);
      state.startExtract();
      await drainExtract(state);

      expect(slash(engine.outDirs.single), slash(p.join(root.path, 'sub', 'a')));
    });

    t('开着 + 指定了根 → 按源目录结构镜像写进根里', () async {
      final root = tempRoot('as_custom_mirror');
      final outRoot = tempRoot('as_custom_mirror_out');
      put(root, 'top.zip', realZip({'x': 'y'}));
      put(root, 'sub/a.zip', realZip({'x': 'y'}));

      final engine = FakeEngine();
      final state = opened(engine: engine, outRoot: outRoot.path);

      await state.selectFolderPath(root.path);
      state.startExtract();
      await drainExtract(state);

      expect(
        engine.outDirs.map(slash),
        containsAll([
          slash(p.join(outRoot.path, 'top')),
          slash(p.join(outRoot.path, 'sub', 'a')),
        ]),
        reason: '顶层包落在根自己身上，子目录里的包带上那一段目录',
      );
      expect(
        engine.outDirs.map(slash),
        everyElement(startsWith(slash(outRoot.path))),
        reason: '没有一个包该跑到根外面去',
      );
      expect(
        slash(engine.outDirs.first),
        isNot(startsWith(slash(root.path))),
        reason: '一个都不该留在源目录里',
      );
    });

    t('嵌套包落在镜像位置底下 —— 父包的输出目录本身就是镜像出来的', () async {
      final root = tempRoot('as_custom_nest');
      final outRoot = tempRoot('as_custom_nest_out');
      put(root, 'sub/outer.zip', realZip({'x': 'y'}));

      // 父包该落到的位置**独立算一遍**，不复用生产代码 —— 复用的话它算错时
      // 这条用例会跟着一起错，钉不住任何东西。
      //
      // 内层包**照实造在父包输出目录里面**（真引擎里 worker 就是在那里扫到的），
      // 但不落盘：`_enqueueNested` 只读 `outcome.nested` 里那些条目的路径，不碰
      // 文件本身（身份指纹是拿**父包**算的）。落盘反而会让父包那个目录先存在，
      // 于是 `resolveOutputDir` 的占用判定把它退成 `outer_1`，台子就搭歪了。
      final parentOut = '${slash(outRoot.path)}/sub/outer';
      final engine = FakeEngine()
        ..nestedFor[parentOut] = [itemAt('$parentOut/inner.zip', depth: 1)];
      final state = opened(engine: engine, outRoot: outRoot.path);

      await state.selectFolderPath(root.path);
      state.startExtract();
      await drainExtract(state);

      expect(engine.outDirs, hasLength(2), reason: '内层包也要真的解一次');
      expect(engine.outDirs[0], parentOut);
      expect(
        engine.outDirs[1],
        '$parentOut/inner',
        reason: '嵌套任务**不带** outputBaseDir（`_enqueueNested` 不设它），'
            '全靠父包已经落在镜像位置上这件事天然继承。它要是跑到源目录旁边，'
            '就说明这条推导错了',
      );
    });

    t('开着却没设根 → startExtract 直接拒绝，不去惊动引擎', () async {
      final root = tempRoot('as_custom_noroot');
      put(root, 'a.zip', realZip({'x': 'y'}));

      final engine = FakeEngine();
      final state = AppState(engine: engine);
      addTearDown(state.dispose);
      state.toggleSetting('customOutput');

      await state.selectFolderPath(root.path);
      state.startExtract();
      await settle();

      expect(engine.rounds, 0, reason: '不知道往哪写就不该写');
      expect(state.extracting, isFalse);
      expect(state.toastType, 'warn');
      expect(state.toastMsg, contains('输出根目录'));
    });

    t('批次跑到一半改根 → 这一批仍按开始时锁定的那个走', () async {
      final root = tempRoot('as_custom_lock');
      final outA = tempRoot('as_custom_lock_a');
      final outB = tempRoot('as_custom_lock_b');
      put(root, 'a.zip', realZip({'x': 'y'}));
      put(root, 'b.zip', realZip({'x': 'y'}));

      final gate = Completer<void>();
      final engine = FakeEngine()
        ..behavior = (e, outDir) async {
          if (e.rounds == 1) await gate.future;
        };
      final state = opened(engine: engine, outRoot: outA.path);

      await state.selectFolderPath(root.path);
      state.startExtract();
      await settle();
      expect(engine.rounds, 1, reason: '前提：第一个包还卡着');

      state.setOutputRoot(outB.path); // 用户在解压途中换了根
      gate.complete();
      await drainExtract(state);

      expect(
        engine.outDirs.map(slash),
        everyElement(startsWith(slash(outA.path))),
        reason: '同一批里前半个包写在 A、后半个写在 B，结果没法解释 —— '
            '与 `maxDepth`/`limits` 那条锁定是一个道理',
      );
    });

    t('选过的根会进下一次扫描的 skipDirs —— 防自噬', () async {
      final root = tempRoot('as_custom_skip');
      final outRoot = tempRoot('as_custom_skip_out');
      put(root, 'a.zip', realZip({'x': 'y'}));

      final engine = FakeEngine();
      final state = AppState(engine: engine);
      addTearDown(state.dispose);
      state.setOutputRoot(outRoot.path);

      await state.selectFolderPath(root.path);

      expect(engine.skipDirsSeen, hasLength(1));
      expect(
        engine.skipDirsSeen.single,
        contains(outRoot.path),
        reason: '把根选在源目录里面时必须跳过它，否则「解压 → 重扫」会把 '
            '自己刚写出去的东西当成新包再解一遍',
      );
    });

    t('开局那次扫描的 skipDirs 是空的 —— 没选过根就没什么可跳', () async {
      final root = tempRoot('as_custom_skip_empty');
      put(root, 'a.zip', realZip({'x': 'y'}));

      final engine = FakeEngine();
      final state = AppState(engine: engine);
      addTearDown(state.dispose);

      await state.selectFolderPath(root.path);

      expect(engine.skipDirsSeen.single, isEmpty);
    });
  });

  group('解压成功后自动删除源压缩包', () {
    /// 开着那颗开关的 `AppState`。`FakeEngine` 不产出任何输出文件，所以磁盘上
    /// 只有源包 —— 删没删一眼可辨。
    AppState armed(FakeEngine engine) {
      final state = AppState(engine: engine);
      addTearDown(state.dispose);
      state.toggleSetting('autoDeleteSource');
      return state;
    }

    t('默认关着 → 解完源包原样留着', () async {
      final root = tempRoot('as_delsrc_off');
      final src = put(root, 'a.zip', realZip({'x': 'y'}));

      final engine = FakeEngine();
      final state = AppState(engine: engine);
      addTearDown(state.dispose);

      await state.selectFolderPath(root.path);
      state.startExtract();
      await drainExtract(state);

      expect(File(src).existsSync(), isTrue, reason: '出厂不删，用户没开就不该动他的文件');
      expect(state.completeDetail, isNot(contains('已删源包')));
      expect(state.logs.first.tags, isNot(contains('已删源')));
    });

    t('开着 + 成功 → 源包没了，日志挂「已删源」、总结报「已删源包」', () async {
      final root = tempRoot('as_delsrc_on');
      final src = put(root, 'a.zip', realZip({'x': 'y'}));

      final engine = FakeEngine();
      final state = armed(engine);

      await state.selectFolderPath(root.path);
      state.startExtract();
      await drainExtract(state);

      expect(File(src).existsSync(), isFalse, reason: '解压成功就该把源包删掉');
      expect(state.logs.first.status, LogStatus.success);
      expect(state.logs.first.tags, contains('已删源'));
      expect(state.completeDetail, contains('已删源包 1 个'));
      expect(state.toastType, 'ok', reason: '全删净了，不该是黄条');
    });

    t('失败 → 源包必须还在（不能把丢数据的失败当省空间）', () async {
      final root = tempRoot('as_delsrc_fail');
      final src = put(root, 'a.zip', realZip({'x': 'y'}));

      final engine = FakeEngine()
        ..behavior = (e, outDir) async {
          throw EngineException('包坏了');
        };
      final state = armed(engine);

      await state.selectFolderPath(root.path);
      state.startExtract();
      await drainExtract(state);

      expect(File(src).existsSync(), isTrue,
          reason: '失败等于什么都没解出来，删源包就是纯丢数据');
      expect(state.logs.first.status, LogStatus.failed);
      expect(state.logs.first.tags, isNot(contains('已删源')));
      expect(state.completeDetail, isNot(contains('已删源包')));
    });

    t('中途停止 → 源包必须还在', () async {
      final root = tempRoot('as_delsrc_stop');
      final src = put(root, 'a.zip', realZip({'x': 'y'}));
      put(root, 'b.zip', realZip({'x': 'y'}));

      final gate = Completer<void>();
      final engine = FakeEngine()
        ..behavior = (e, outDir) async {
          if (e.rounds == 1) await gate.future;
        };
      final state = armed(engine);

      await state.selectFolderPath(root.path);
      state.startExtract();
      await settle();

      state.stopExtract();
      gate.complete();
      await drainExtract(state);

      expect(File(src).existsSync(), isTrue,
          reason: '被中止的包只在磁盘上留了半棵树，源包不能跟着删');
      expect(state.outcome, BatchOutcome.stopped);
      expect(state.completeDetail, isNot(contains('已删源包')));
    });

    t('分卷包 → 所有分卷一起删掉', () async {
      final root = tempRoot('as_delsrc_split');
      final zip = realZip({'hello.txt': 'world'});
      final half = zip.length ~/ 2;
      final v1 = put(root, '备份.rar.001', zip.sublist(0, half));
      final v2 = put(root, '备份.rar.002', zip.sublist(half));

      final engine = FakeEngine();
      final state = armed(engine);

      await state.selectFolderPath(root.path);
      expect(state.lastScan!.items.single.split!.parts, hasLength(2),
          reason: '前提：它得先被扫成一个两片的包，否则这条测的不是分卷');

      state.startExtract();
      await drainExtract(state);

      expect(File(v1).existsSync(), isFalse);
      expect(File(v2).existsSync(), isFalse, reason: '缺一片这个包就废了，必须一起删');
      expect(state.completeDetail, contains('已删源包 1 个'),
          reason: '一个逻辑包只删一次，报的是包数不是卷数');
    });

    t('嵌套解出来的内层包也删', () async {
      final root = tempRoot('as_delsrc_nested');
      final payload = tempRoot('as_delsrc_nested_payload');
      final outer = put(root, 'nested.zip', realZip({'readme.txt': 'x'}));
      final innerPath = put(payload, 'inner.zip', realZip({'deep.txt': 'y'}));

      final engine = FakeEngine()
        ..nestedFor[resolveOutputDir(outer)] = [
          ScanItem(
            entryPath: innerPath,
            parts: [innerPath],
            sniff: const SniffResult(
              format: SniffFormat.zip,
              confidence: SniffConfidence.high,
              declaredExt: 'zip',
            ),
            sizeBytes: 100,
            flags: const {},
            depth: 1,
          ),
        ];
      final state = armed(engine);

      await state.selectFolderPath(root.path);
      state.startExtract();
      await drainExtract(state);

      expect(engine.rounds, 2, reason: '前提：内层包真的被解了一次');
      expect(File(outer).existsSync(), isFalse, reason: '外层包解成功 → 删');
      expect(File(innerPath).existsSync(), isFalse, reason: '内层包解成功 → 也删');
      expect(state.completeDetail, contains('已删源包 2 个'));
    });

    t('开关在批次开始时锁定：途中改它不影响这一批剩下的包', () async {
      final root = tempRoot('as_delsrc_lock');
      final a = put(root, 'a.zip', realZip({'x': 'y'}));
      final b = put(root, 'b.zip', realZip({'x': 'y'}));

      final gate = Completer<void>();
      final engine = FakeEngine()
        ..behavior = (e, outDir) async {
          if (e.rounds == 1) await gate.future;
        };
      final state = armed(engine);

      await state.selectFolderPath(root.path);
      state.startExtract();
      await settle();

      // 第一个包还卡在半路，用户去把它关掉。
      expect(state.setting('autoDeleteSource'), isTrue);
      state.toggleSetting('autoDeleteSource');

      gate.complete();
      await drainExtract(state);

      expect(File(a).existsSync(), isFalse, reason: '锁定的值是「开」');
      expect(File(b).existsSync(), isFalse,
          reason: '同一批里行为必须一致 —— 前半删后半不删是没法解释的');
    });
  });

  group('被拦弹窗与剩余空间', () {
    // 这一组盯的是「闸门之后」那条新加的链：EngineException.breach → 问用户
    // → 用户的决断怎么影响整批。闸门本身住在 native_backend 里（假引擎整个
    // 绕过它），所以这里手动抛同形状的异常，测的是上层。

    const breach = LimitBreach(
      kind: LimitKind.diskSpace,
      tag: '空间不足',
      message: '解压后需要 12.0 GB，设备仅剩 3.2 GB，装不下，已放弃',
    );

    /// 记下每次被问到的 (文件名, 原因那句话)。
    ///
    /// 原因是个**字符串**而不是 `LimitBreach`：弹窗只渲染这一句话，让它多拿
    /// 一个用不上的对象等于给「弹窗开始按 kind 分支」留了个口子（见
    /// `prompts.dart` 里 `ArchivePrompt` 的说明）。所以这里也顺带钉住
    /// 「闸门那一路传的确实是 breach.message」。
    final asked = <({String name, String reason})>[];

    setUp(asked.clear);

    /// 只拦第一个包，第二个照常成功 —— 这样「跳过」与「停止」的差别才看得出来。
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
        prompt: (name, reason) async {
          asked.add((name: name, reason: reason));
          return ArchiveDecision.skip;
        },
      );
      addTearDown(state.dispose);

      await state.selectFolderPath(twoPacks('as_prompt_skip').path);
      state.startExtract();
      await drainExtract(state);

      expect(asked.single.name, 'a.zip');
      // 闸门那一路要把 `breach.message` 传下去，不能糊一句泛泛的「解压失败」
      // —— 弹窗正文就是这句话，它得说清是「装不下」还是「包太大」。
      expect(asked.single.reason, breach.message);
      expect(engine.rounds, 2, reason: '跳过 ≠ 停批');
      final byName = {for (final l in state.logs) l.name: l};
      expect(byName['a.zip']!.tags, contains('空间不足'));
      expect(byName['b.zip']!.status, LogStatus.success);
      expect(state.batchRun, isTrue, reason: '跑完的批次照常消费快照');
    });

    t('停下来 → 剩余任务一个都不跑，且落在总结页上', () async {
      final engine = gatedEngine();
      final state = AppState(
        engine: engine,
        prompt: (name, reason) async => ArchiveDecision.stop,
      );
      addTearDown(state.dispose);

      await state.selectFolderPath(twoPacks('as_prompt_stop').path);
      state.startExtract();
      await drainExtract(state);

      expect(engine.rounds, 1, reason: '停了就不该接着解 b.zip');
      expect(state.extracting, isFalse);
      // 停止也要出总结卡片，且 `outcome` 表明是**哪一档**停的 ——
      // 弹窗那档总是伴随一次解压失败，标题要写「解压出错」而不是「已停止」。
      expect(state.outcome, BatchOutcome.errored);
      expect(state.completeDetail, contains('已完成 0/2 个压缩包'));
    });

    t('弹窗没弹成（决断为 null）→ 按没问处理，整批继续', () async {
      // DialogBridge 拿不到 BuildContext 时就是这么返回的。那不是用户的
      // 决定，用户什么都没看见 —— 既不能当停下，也不能当跳过，得补一条 toast。
      final engine = gatedEngine();
      final state = AppState(
        engine: engine,
        prompt: (name, reason) async => null,
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

    t('普通失败（没有 breach）走同一个弹窗，正文是引擎给的原因', () async {
      // 这条原先叫「普通失败不弹窗」，后来又改成「不落进闸门那个弹窗」——
      // 两版的区别都建立在「闸门和出错是两条线」上。现在合并成一条了
      // （见 `prompts.dart` 的表），所以它验的是**剩下的那点差别**：正文。
      //
      // 正文由 `breach?.message ?? e.message` 一句决定。写反成 `??` 左边优先，
      // 弹窗上就会给一个坏包配一句与它无关的「设备仅剩 3.2 GB」，而用户会
      // 真的去清磁盘。
      final root = tempRoot('as_prompt_plain');
      put(root, 'a.zip', realZip({'x': 'y'}));

      final engine = FakeEngine()
        ..behavior = (e, outDir) async {
          throw const EngineException('坏了', code: DuzErrorCode.extract);
        };
      final state = AppState(
        engine: engine,
        prompt: (name, reason) async {
          asked.add((name: name, reason: reason));
          return ArchiveDecision.skip;
        },
      );
      addTearDown(state.dispose);
      final toasts = toastTrail(state);

      await state.selectFolderPath(root.path);
      state.startExtract();
      await drainExtract(state);

      expect(asked.single.name, 'a.zip');
      expect(asked.single.reason, '坏了', reason: '没有 breach 时用引擎那句');
      expect(toasts.join('\n'), isNot(contains('坏了')),
          reason: '弹窗已经把这句给用户看了，不该再补一条一模一样的 toast');
    });

    t('没注入 prompt → 与没有这个特性时逐字节一致', () async {
      // 闸门那一路也走这个（同一条线）：没人可问就只记日志 + toast 兜底。
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

  group('出错弹窗与 errorPause 开关（需求 3）', () {
    // 这一组盯的是 `errorPause` 那个开关**真的有人读**。加这一组之前它是个
    // 死开关：界面上写着「无法解压时弹窗询问，而非自动跳过」，而全仓库除了
    // 默认值定义和那行 UI，没有任何地方读过它。
    //
    // 这一档与「被闸门拦下」共用同一个回调、同一个弹窗（见 `prompts.dart`
    // 的表）：两边的两个决断含义完全一样，都是「跳过 / 停止」—— 右边那颗叫
    // 过「继续」，真机验收时用户要求改成「跳过」（它的作用是**放掉这个包**，
    // 不是「再试一次这个包」）。开关只决定**问不问**，不改变弹窗长什么样。

    /// 只让第一个包炸，第二个照常成 —— 这样「跳过」与「停止」才分得开。
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

    t('开着 errorPause → 出错时问，选「跳过」→ 整批接着跑', () async {
      final engine = brokenFirst();
      final asked = <String>[];
      final state = AppState(
        engine: engine,
        prompt: (name, reason) async {
          asked.add('$name|$reason');
          return ArchiveDecision.skip;
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
      expect(state.batchRun, isTrue, reason: '跑完的批次照常消费快照');
    });

    t('选「停止」→ 剩下的包一个都不跑，落在总结页上', () async {
      final engine = brokenFirst();
      final state = AppState(
        engine: engine,
        prompt: (name, reason) async => ArchiveDecision.stop,
      );
      addTearDown(state.dispose);

      await state.selectFolderPath(twoPacks('as_err_stop').path);
      state.startExtract();
      await drainExtract(state);

      // 这条就是这次改动的要害：从前这一档选的是「暂停」，批次挂起、resume
      // 之后还能接着解；现在它和闸门那颗「停止」是同一条不可恢复的路，剩下
      // 的包直接丢掉。
      expect(engine.rounds, 1, reason: '停了就不该接着解 b.zip');
      expect(state.extracting, isFalse);
      // 停在半路也要出总结卡片（真机验收时用户要求的），`outcome` 指明
      // 是弹窗那一档 —— 卡片标题据此写「解压出错，已停止」而不是「已停止」。
      expect(state.outcome, BatchOutcome.errored);
      // 炸掉的那个算失败、不算「完成」，所以是 0/2。
      expect(state.completeDetail, contains('已完成 0/2 个压缩包'));
      expect(state.completeDetail, contains('1 个失败'));
      expect(state.batchRun, isTrue, reason: '停止也消费快照，主按钮换成「更换目标」');
    });

    t('选「跳过」→ 记一条**手动跳过**，不算失败，整批接着跑', () async {
      // 用户明确表过态的东西不该在总结里再算成「程序坏了」—— 那是我们照他的
      // 决定办事。「手动跳过 N 个」与「N 个失败」是两回事，卡片要分开说。
      final engine = brokenFirst();
      final state = AppState(
        engine: engine,
        prompt: (name, reason) async => ArchiveDecision.skip,
      );
      addTearDown(state.dispose);

      await state.selectFolderPath(twoPacks('as_err_skip2').path);
      state.startExtract();
      await drainExtract(state);

      expect(engine.rounds, 2, reason: '跳过 ≠ 停批');
      expect(state.completeDetail, contains('2 个压缩包'));
      expect(state.completeDetail, contains('手动跳过 1 个'));
      expect(state.completeDetail, isNot(contains('失败')));
      expect(state.completeDetail, isNot(contains('自动跳过')));
      expect(state.outcome, BatchOutcome.clean,
          reason: '手动跳过一个包不算失败，这一批仍是一个没砸');
    });

    t('关掉 errorPause → 不问了，照旧记一条失败接着跑', () async {
      final engine = brokenFirst();
      final asked = <String>[];
      final state = AppState(
        engine: engine,
        prompt: (name, reason) async {
          asked.add(name);
          return ArchiveDecision.stop;
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
      expect(engine.rounds, 2);
      expect(toasts.join('\n'), contains('这个包坏了'),
          reason: '不问不等于不报 —— 得有 toast 兜底');
    });

    t('没注入 prompt → 与加这个特性之前一致', () async {
      final engine = brokenFirst();
      final state = AppState(engine: engine);
      addTearDown(state.dispose);
      final toasts = toastTrail(state);

      await state.selectFolderPath(twoPacks('as_err_absent').path);
      state.startExtract();
      await drainExtract(state);

      expect(engine.rounds, 2);
      expect(state.batchRun, isTrue);
      expect(toasts.join('\n'), contains('这个包坏了'));
    });

    t('弹窗没弹成（决断为 null）→ 补一条 toast，也不该少解一个包', () async {
      // DialogBridge 拿不到 BuildContext 时就是这么返回的。用户什么都没看见，
      // 那不是他的决定 —— 当成「停止」会凭空停住整批，当成「跳过」倒还好，
      // 但两者都不该由我们替他选，所以只补一条 toast。
      final engine = brokenFirst();
      final state = AppState(
        engine: engine,
        prompt: (name, reason) async => null,
      );
      addTearDown(state.dispose);
      final toasts = toastTrail(state);

      await state.selectFolderPath(twoPacks('as_err_null').path);
      state.startExtract();
      await drainExtract(state);

      expect(engine.rounds, 2, reason: '没弹成不该少解一个包');
      expect(state.batchRun, isTrue);
      expect(toasts.join('\n'), contains('这个包坏了'),
          reason: '没弹成 = 用户什么都没看见，必须给一条提示');
    });

    t('关掉 errorPause 也挡不住闸门那一路 —— 它永远问', () async {
      // 两档合并成一条线之后，最容易写坏的就是这个条件：写成只判断
      // `pauseOnError`，闸门就会跟着开关一起沉默 —— 而我们是在「主动放弃一个
      // 其实可能解得开的包」，这种事不该因为用户关了另一个开关就悄悄发生。
      //
      // 顺带钉住正文的来路：闸门这档要传 `breach.message`，不是兜底那句。
      const breach = LimitBreach(
        kind: LimitKind.entryCount,
        tag: '条目数超限',
        message: '条目太多，已放弃',
      );
      final engine = FakeEngine()
        ..behavior = (e, outDir) async {
          throw EngineException(breach.message, breach: breach);
        };
      final asked = <({String name, String reason})>[];
      final state = AppState(
        engine: engine,
        prompt: (name, reason) async {
          asked.add((name: name, reason: reason));
          return ArchiveDecision.skip;
        },
      );
      addTearDown(state.dispose);

      state.toggleSetting('errorPause'); // 关掉

      await state.selectFolderPath(twoPacks('as_err_breach').path);
      state.startExtract();
      await drainExtract(state);

      expect(asked, hasLength(2), reason: '两个包都被闸门拦下，两个都要问');
      expect(asked.first.reason, breach.message,
          reason: '闸门那档的正文是 breach.message，不是兜底文案');
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

    t('关掉「伪后缀时暂停」→ 一次都不问，但**照样按 ZIP 解出来**', () async {
      // 设置页上那颗开关（key 仍是 `fakeExtDetect`）控制的只是**问不问**，
      // 不是**认不认**：魔术字节永远会读 —— 扫描就是靠它把 `fake.pdf` 认成
      // 压缩包的。关掉之后用户要是发现那个 .pdf 压根没被解出来，才是 bug。
      //
      // 这条同时钉住了「关掉 = 不打扰」这条对外承诺：一次都不问，包里也没有
      // 「伪后缀」那个角标（不提这回事），但引擎确实被喂了这一个包。
      final engine = FakeEngine();
      final asked = <String>[];
      final state = AppState(
        engine: engine,
        formatPrompt: (info) async {
          asked.add(info.fileName);
          return true;
        },
      );
      addTearDown(state.dispose);

      state.toggleSetting('fakeExtDetect'); // true → false，即「伪后缀时暂停」关

      await state.selectFolderPath(spoofed('as_fmt_off').path);
      state.startExtract();
      await drainExtract(state);

      expect(asked, isEmpty, reason: '关掉了就别再打扰');
      expect(engine.rounds, 1, reason: '不打扰 ≠ 不解 —— 它照样得被解出来');
      expect(extractLogFor(state, 'fake.pdf').status, LogStatus.success);
      expect(extractLogFor(state, 'fake.pdf').tags, isNot(contains('伪后缀')),
          reason: '用户说了不要提，日志里也别挂这个角标');
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

  /// 「这批用掉了」这道闸门。
  ///
  /// 它和 [BatchOutcome.clean] 是两件事：`clean` 说的是「一个没失败」，有任何
  /// 一个包失败它就不成立。而重跑的危害与成败无关 —— 输出目录重名会追加
  /// `_1`/`_2`（见 output_paths.dart），再点一次不是「重新解一遍」而是往磁盘里
  /// 撒重复目录。所以闸门必须挂在「跑过」（`batchRun`）而不是「成功」上。
  group('密码库自动尝试与弹窗（需求 2）', () {
    // 这一组盯的是「密码库真的被拿去试了，而且试的顺序、试的结果都被认得」。
    //
    // 关键约定（见 `password_prompt.dart` 里 `PasswordAsk.verify` 那段）：
    // 「验一个候选」的实现就是**拿它真解一遍**，所以每次 `extract` 都是一次
    // 尝试，`engine.passwordsSeen` 就是完整流水账 —— 真引擎在 Android 上，
    // 本地只能靠这张表钉。
    //
    // `pwdPrompt` 这颗开关控制的**不是**「要不要试密码库」（一直要试），而是
    // 「试不出来之后问不问」。它是从 `pwdAutoTry` 改名过来的，那个名字指的是
    // 两边共有的那一半。
    //
    // 流水账里的**第一项永远是空串 `''`**（开局那次「空密码」），不是 `null`。
    // 这不是风格问题：`null` 会让原生 ZIP 路径直接放弃整次解压、答一个笼统的
    // 「解压失败」，密码库与弹窗就都不会被走到。第一条用例专门钉这件事。

    /// 只有给对密码才解得开。
    ///
    /// 用 `passwordsSeen.last` 而不是闭包里的计数器：`passwordsSeen` 在
    /// `behavior` 之前就记好了，所以这里读到的就是「这次带的哪个密码」。
    ///
    /// [uncertain] 为真时失败带上「分不清是密码错还是文件坏」那一位 —— 模拟
    /// 7z 的内容加密 / RAR3（没有校验字）。**它只该改说法，不该改流水账**，
    /// 下面两条用例就是拿 `passwordsSeen` 钉这件事。
    FakeEngine locked(String right, {bool uncertain = false}) => FakeEngine()
      ..behavior = (e, outDir) async {
        if (e.passwordsSeen.last != right) {
          throw EngineException(
            uncertain ? '密码不对，或加密数据已损坏' : 'Wrong password',
            code: DuzErrorCode.password,
            uncertain: uncertain,
          );
        }
      };

    Directory onePack(String tag) {
      final root = tempRoot(tag);
      put(root, 'a.zip', realZip({'x': 'y'}));
      return root;
    }

    Directory twoPacks(String tag) {
      final root = tempRoot(tag);
      put(root, 'a.zip', realZip({'x': 'y'}));
      put(root, 'b.zip', realZip({'x': 'y'}));
      return root;
    }

    AppState withVault(
      FakeEngine engine, {
      List<PasswordEntry> vault = const [],
      PasswordPrompt? prompt,
      PersistStore? store,
    }) {
      final state = AppState(
        engine: engine,
        persistStore: store,
        restore: AppSnapshot(vault: vault),
        passwordPrompt: prompt,
      );
      addTearDown(state.dispose);
      return state;
    }

    t('开局那次空密码送的是空串，不是 null', () async {
      // 这条钉的是一个**只在真机上才暴露**的坑（见 `app_state.dart` 里
      // `_kEmptyPassword` 那段）：`null` 与 `''` 在原生 ZIP 路径上是两件事。
      // 传 `null`，7-Zip 的 `Extract()` 直接返回 `E_NOTIMPL`，C 那边只好翻成
      // 笼统的 `DUZ_ERR_EXTRACT` —— `_PwdAttempt.isPasswordError` 为假，密码库
      // 与弹窗整条路一次都不会被走到。真机第一次验收就是这么栽的。
      //
      // 为什么非得在这里钉：假引擎的错误码是它自己给的，它认不出「引擎收到
      // null 会改答别的」这件事。能钉的只有**送给引擎的那个值**本身。
      final engine = locked('pw-ok');
      final state = withVault(
        engine,
        vault: const [PasswordEntry(value: 'pw-ok')],
      );

      await state.selectFolderPath(onePack('as_pw_empty').path);
      state.startExtract();
      await drainExtract(state);

      expect(engine.passwordsSeen, ['', 'pw-ok']);
      expect(engine.passwordsSeen, isNot(contains(null)),
          reason: '只要出现一次 null，这个包在真机上就会变成一句「解压失败」');
    });

    t('库里有对的密码 → 自动解开，不惊动用户', () async {
      // 顺序也是这条用例的一部分：先空密码（回答「要不要密码」），再按
      // `hitCount` 排下来的候选。
      final engine = locked('pw-ok');
      final asked = <PasswordAsk>[];
      final state = withVault(
        engine,
        vault: const [
          PasswordEntry(value: 'pw-bad'),
          PasswordEntry(value: 'pw-ok'),
        ],
        prompt: (ask) async {
          asked.add(ask);
          return const PasswordResolution.skip();
        },
      );

      await state.selectFolderPath(onePack('as_pw_hit').path);
      state.startExtract();
      await drainExtract(state);

      expect(engine.passwordsSeen, ['', 'pw-bad', 'pw-ok']);
      expect(asked, isEmpty, reason: '密码库解开了就别再问用户');
      // `logs.first` 才是刚解这个包记的 —— 扫描收尾往前面塞了一条
      // 「扫描完成」，它排在后面。
      expect(state.logs.first.status, LogStatus.success);
      expect(state.completeDetail, contains('1 个压缩包'));
      expect(state.completeDetail, isNot(contains('失败')));
    });

    t('命中的密码记一次「用过」并落盘 —— 下次它排最前', () async {
      final store = FakeStore();
      final engine = locked('pw-ok');
      final state = withVault(
        engine,
        vault: const [
          PasswordEntry(value: 'pw-ok'),
          PasswordEntry(value: 'pw-used'),
          PasswordEntry(value: 'pw-new'),
        ],
        store: store,
      );

      await state.selectFolderPath(onePack('as_pw_count').path);
      state.startExtract();
      await drainExtract(state);

      final hit = state.passwords.firstWhere((p) => p.value == 'pw-ok');
      expect(hit.hitCount, 1);
      expect(hit.lastUsed, '今天');
      expect(store.vaultSaved, isNotEmpty, reason: '命中数得写回去，不然下次白试');
      expect(store.vaultSaved.last.firstWhere((p) => p.value == 'pw-ok').hitCount,
          1);
    });

    t('命中数高的先试 —— 库是按「哪个常有用」排的，不是按插入序', () async {
      final engine = locked('pw-hot');
      final state = withVault(
        engine,
        vault: const [
          PasswordEntry(value: 'pw-cold'),
          PasswordEntry(value: 'pw-hot', hitCount: 3),
        ],
      );

      await state.selectFolderPath(onePack('as_pw_order').path);
      state.startExtract();
      await drainExtract(state);

      expect(engine.passwordsSeen, ['', 'pw-hot'],
          reason: '只试了一个说明排序生效了；试的顺序反了说明排反了');
    });

    t('并列时按插入序 —— 同分的密码每次试的顺序都不一样就没法复现', () async {
      final engine = locked('pw-c');
      final state = withVault(
        engine,
        vault: const [
          PasswordEntry(value: 'pw-a'),
          PasswordEntry(value: 'pw-b'),
          PasswordEntry(value: 'pw-c'),
        ],
      );

      await state.selectFolderPath(onePack('as_pw_tie').path);
      state.startExtract();
      await drainExtract(state);

      expect(engine.passwordsSeen, ['', 'pw-a', 'pw-b', 'pw-c']);
    });

    t('本批命中过的密码，后面的包第一次就试它', () async {
      // 「本次解压优先尝试成功过的密码」：一批里有一个包被某个密码打开，剩下的包
      // 大概率是同一个 —— 同一次备份切出来的一组包就是。
      //
      // 判据得挑一个**排序本来给不出这个顺序**的库：让命中的那条 `hitCount`
      // 明显低于另一条。否则光靠既有的「命中就加一」也能让第二个包先试对它，
      // 这条用例就成了永远绿的假测试。
      final engine = locked('pw-low');
      final state = withVault(
        engine,
        vault: const [
          PasswordEntry(value: 'pw-low'),
          PasswordEntry(value: 'pw-high', hitCount: 5),
        ],
      );

      await state.selectFolderPath(twoPacks('as_pw_runmem').path);
      state.startExtract();
      await drainExtract(state);

      expect(
        engine.passwordsSeen,
        ['', 'pw-high', 'pw-low', '', 'pw-low'],
        reason: 'a.zip 照旧从命中数高的试起；b.zip 的第二个候选该是本批刚用上的 '
            'pw-low，而不是又回到库里排第一的 pw-high',
      );
    });

    t('手输的密码也算「本次成功过」→ 后面的包不用再问一遍', () async {
      // 手输走的是同一个 `attempt`，所以它同样进这份记忆 —— 用户刚亲手证明能用
      // 的密码，比库里任何一条都更该被先试。
      final engine = locked('typed');
      final asked = <PasswordAsk>[];
      final state = withVault(
        engine, // 空密码库
        prompt: (ask) async {
          asked.add(ask);
          final ok = await ask.verify('typed');
          expect(ok, isTrue);
          return const PasswordResolution.manual('typed');
        },
      );

      await state.selectFolderPath(twoPacks('as_pw_runmem_manual').path);
      state.startExtract();
      await drainExtract(state);

      expect(engine.passwordsSeen, ['', 'typed', '', 'typed'],
          reason: 'b.zip 第一次尝试（空密码）之后就该轮到 typed');
      expect(asked, hasLength(1), reason: '只该为 a.zip 弹这一次');
    });

    t('记忆不跨批 —— 它是「本次解压」的，换一份快照就归零', () async {
      // 这一条钉的是**范围**：`_runGoodPasswords` 在每批开头清空。不清的话，
      // 「上礼拜试出来过的一个密码」会永远排在候选最前面，代价从「这批白试
      // 一次」变成「以后每次解压的每个包都白试一次」。
      final engine = locked('pw-low');
      final state = withVault(
        engine,
        vault: const [
          PasswordEntry(value: 'pw-low'),
          PasswordEntry(value: 'pw-high', hitCount: 5),
        ],
      );

      await state.selectFolderPath(onePack('as_pw_runmem_b1').path);
      state.startExtract();
      await drainExtract(state);
      expect(engine.passwordsSeen, ['', 'pw-high', 'pw-low']);

      // 换一份快照 = 新的一批（见 `startExtract` 那道「跑过就不让再跑」的闸门）。
      await state.selectFolderPath(onePack('as_pw_runmem_b2').path);
      state.startExtract();
      await drainExtract(state);

      expect(
        engine.passwordsSeen,
        ['', 'pw-high', 'pw-low', '', 'pw-high', 'pw-low'],
        reason: '第二批又该回到库的顺序：pw-low 的命中数（1）压不过 5',
      );
    });

    t('库里没有 → 弹窗；把用户手敲的密码验通即解完', () async {
      final engine = locked('typed-by-user');
      final asked = <PasswordAsk>[];
      final state = withVault(
        engine,
        vault: const [PasswordEntry(value: 'pw-bad')],
        prompt: (ask) async {
          asked.add(ask);
          // 弹窗拿到的就是「该验谁」。验真一遍 —— 这正是真弹窗干的事。
          final ok = await ask.verify('typed-by-user');
          expect(ok, isTrue);
          return const PasswordResolution.manual('typed-by-user');
        },
      );

      await state.selectFolderPath(onePack('as_pw_manual_ok').path);
      state.startExtract();
      await drainExtract(state);

      expect(asked, hasLength(1));
      expect(asked.single.fileName, 'a.zip');
      expect(asked.single.triedCount, 1,
          reason: '弹窗要知道刚才试过几条 —— 它现在只拿得到这个数，不拿密码本身');
      expect(engine.passwordsSeen, ['', 'pw-bad', 'typed-by-user']);
      expect(state.logs.first.status, LogStatus.success,
          reason: '手输成功就是成功，不该因为绕过密码库就显得低人一等');
    });

    t('手输的密码不对 → verify 给 false，AppState 不开后门', () async {
      // 「输了留在弹窗页面」是弹窗自己的事（它拿到 false 就不关），这里钉的是
      // 它**能**拿到 false —— verify 必须如实回答，不能因为「用户都手输了」
      // 就默认放行。
      final engine = locked('right');
      final verdicts = <bool>[];
      final state = withVault(
        engine,
        prompt: (ask) async {
          verdicts.add(await ask.verify('wrong-1'));
          verdicts.add(await ask.verify('wrong-2'));
          verdicts.add(await ask.verify('right'));
          return const PasswordResolution.manual('right');
        },
      );

      await state.selectFolderPath(onePack('as_pw_manual_retry').path);
      state.startExtract();
      await drainExtract(state);

      expect(verdicts, [false, false, true]);
      expect(engine.passwordsSeen, ['', 'wrong-1', 'wrong-2', 'right'],
          reason: '空库也要先试一次空密码');
    });

    t('手输的密码验通过 → 自动存进密码库（默认开）', () async {
      final store = FakeStore();
      final engine = locked('typed');
      final state = withVault(
        engine, // 空库起步
        store: store,
        prompt: (ask) async {
          expect(await ask.verify('typed'), isTrue);
          return const PasswordResolution.manual('typed');
        },
      );

      await state.selectFolderPath(onePack('as_pw_autosave').path);
      state.startExtract();
      await drainExtract(state);

      final saved = state.passwords.firstWhere((p) => p.value == 'typed');
      expect(saved.hitCount, 1,
          reason: '它刚刚真的解开了一个包 —— 从 0 记起等于把这份证据丢了');
      expect(store.vaultSaved, isNotEmpty, reason: '得落盘，不然重启就没了');
      expect(store.vaultSaved.last.map((p) => p.value), contains('typed'));
    });

    t('关掉「手输密码存入密码库」→ 不进库，但本批的候选记忆照样生效', () async {
      // 这两件事是**分开的**，这条用例专门把它们分开钉：一条活在内存里、只服务
      // 这一批（`_runGoodPasswords`），一条写进密码库、服务以后每一次解压。
      // 关掉后者不该让同一批里的下一个包重新去问用户。
      final engine = locked('typed');
      final asked = <PasswordAsk>[];
      final state = withVault(
        engine,
        prompt: (ask) async {
          asked.add(ask);
          expect(await ask.verify('typed'), isTrue);
          return const PasswordResolution.manual('typed');
        },
      );
      state.toggleSetting('pwdAutoSave'); // 默认开，这里关掉

      await state.selectFolderPath(twoPacks('as_pw_autosave_off').path);
      state.startExtract();
      await drainExtract(state);

      expect(state.passwords, isEmpty, reason: '关掉了就不该进库');
      expect(asked, hasLength(1), reason: '但 b.zip 也不该再问一遍');
      expect(engine.passwordsSeen, ['', 'typed', '', 'typed'],
          reason: 'b.zip 靠的是本批的记忆，不是密码库');
    });

    t('密码库自己命中的包不会重复入库，也不会冒一句提示', () async {
      // 「成功就入库」的挂点在 `attempt` 里，密码库命中也从那儿过。那种情况下
      // 这条必然在库里 —— 该原地空转，而不是每命中一个包就多一条记录、多一句
      // toast（那会把提示刷成噪音，还把用户的库越撑越长）。
      final engine = locked('pw-ok');
      final toasts = <String>[];
      final state = withVault(
        engine,
        vault: const [PasswordEntry(value: 'pw-ok')],
      );
      state.addListener(() {
        final m = state.toastMsg;
        if (m != null && (toasts.isEmpty || toasts.last != m)) toasts.add(m);
      });

      await state.selectFolderPath(onePack('as_pw_autosave_dup').path);
      state.startExtract();
      await drainExtract(state);

      expect(state.passwords, hasLength(1));
      expect(toasts, isNot(contains('密码已存入密码库')));
    });

    t('密码库解开 → 日志说得出是「密码库」给的钥匙', () async {
      // 用户回头要查的是「这个包是谁打开的」—— 密码库长起来之后，光看一条
      // 「1 项」完全对不上号。标签只记来源不记密码本身（见 `PasswordSource`）。
      final engine = locked('pw-ok');
      final state = withVault(
        engine,
        vault: const [PasswordEntry(value: 'pw-ok')],
      );

      await state.selectFolderPath(onePack('as_log_src_vault').path);
      state.startExtract();
      await drainExtract(state);

      expect(state.logs.first.status, LogStatus.success);
      expect(state.logs.first.tags, contains('密码库'));
      expect(state.logs.first.tags, isNot(contains('手输密码')));
    });

    t('手输解开 → 日志说「手输密码」，与密码库命中的那条分得开', () async {
      final engine = locked('typed-by-user');
      final state = withVault(
        engine,
        vault: const [PasswordEntry(value: 'pw-bad')],
        prompt: (ask) async {
          await ask.verify('typed-by-user');
          return const PasswordResolution.manual('typed-by-user');
        },
      );

      await state.selectFolderPath(onePack('as_log_src_manual').path);
      state.startExtract();
      await drainExtract(state);

      expect(state.logs.first.status, LogStatus.success);
      expect(state.logs.first.tags, contains('手输密码'));
      expect(state.logs.first.tags, isNot(contains('密码库')),
          reason: '手输的密码没进库，说成「密码库」用户会去库里翻一条不存在的记录');
    });

    t('没用上密码的包，日志里一个密码标签都没有', () async {
      // `null` 与「有来源」必须分得开：写 `''` 或者给个默认值都会让每个普通
      // 包都挂上「密码库」。
      final engine = FakeEngine();
      final state = withVault(engine);

      await state.selectFolderPath(onePack('as_log_src_none').path);
      state.startExtract();
      await drainExtract(state);

      expect(engine.passwordsSeen, [''], reason: '前提：一次空密码就成了');
      expect(state.logs.first.status, LogStatus.success);
      expect(state.logs.first.tags, ['1 项']);
    });

    t('密码库试过但没试出来（跳过）→ 也不会说「密码库」', () async {
      // 跳过那条路上 `passwordSource` 是空的：包**没解开**，说「密码库」
      // 等于替一次失败的尝试记账。
      final engine = locked('never');
      final state = withVault(
        engine,
        vault: const [PasswordEntry(value: 'pw-bad')],
      );

      await state.selectFolderPath(onePack('as_log_src_skip').path);
      state.startExtract();
      await drainExtract(state);

      expect(state.logs.first.tags, ['密码未匹配']);
    });

    t('弹窗选「跳过」→ 记手动跳过，接着解下一个', () async {
      // 只锁第一个包，第二个让过 —— 这样「跳过」与「停止」才分得开。
      final engine = FakeEngine()
        ..behavior = (e, outDir) async {
          if (e.outDirs.length == 1) {
            throw const EngineException(
              'Wrong password',
              code: DuzErrorCode.password,
            );
          }
        };
      final state = withVault(
        engine,
        prompt: (ask) async => const PasswordResolution.skip(),
      );

      await state.selectFolderPath(twoPacks('as_pw_skip').path);
      state.startExtract();
      await drainExtract(state);

      expect(state.completeDetail, contains('手动跳过 1 个'));
      expect(state.completeDetail, isNot(contains('失败')));
      expect(state.outcome, BatchOutcome.clean,
          reason: '用户自己放掉的包不算这批砸了');
      expect(state.logs.first.name, 'b.zip', reason: 'b.zip 才是最后解的那个');
      final a = state.logs.lastWhere((l) => l.name == 'a.zip');
      expect(a.status, LogStatus.skipped, reason: '按用户的选择跳过，不该记成失败');
      expect(a.tags, ['用户跳过']);
    });

    t('弹窗选「停止」→ 剩下的包一个都不跑', () async {
      final engine = locked('pw-ok');
      final state = withVault(
        engine,
        prompt: (ask) async => const PasswordResolution.stop(),
      );

      await state.selectFolderPath(twoPacks('as_pw_stop').path);
      state.startExtract();
      await drainExtract(state);

      expect(state.extracting, isFalse);
      expect(state.outcome, BatchOutcome.errored,
          reason: '弹窗那颗「停止」总是伴随一次失败，标题要说出来');
      expect(state.completeDetail, contains('已完成 0/2 个压缩包'));
      expect(state.batchRun, isTrue);
      expect(engine.outDirs, hasLength(1),
          reason: '空库里没候选可试，一次空密码之后就停了，b.zip 不该开工');
    });

    t('关掉这颗开关 → 不弹窗，记「跳过」而不是失败', () async {
      final engine = locked('pw-ok');
      final asked = <PasswordAsk>[];
      final state = withVault(
        engine,
        vault: const [PasswordEntry(value: 'pw-bad')],
        prompt: (ask) async {
          asked.add(ask);
          return const PasswordResolution.skip();
        },
      );
      final toasts = <String>[];
      state.addListener(() {
        final m = state.toastMsg;
        if (m != null && (toasts.isEmpty || toasts.last != m)) toasts.add(m);
      });

      // 默认是 true（弹窗），这里显式关掉。
      state.toggleSetting('pwdPrompt');

      await state.selectFolderPath(onePack('as_pw_off').path);
      state.startExtract();
      await drainExtract(state);

      expect(asked, isEmpty, reason: '关掉了就别再打扰用户');
      expect(engine.passwordsSeen, ['', 'pw-bad'], reason: '开关管的是问不问，不是试不试');
      expect(state.logs.first.status, LogStatus.skipped);
      expect(state.logs.first.tags, ['密码未匹配']);
      expect(toasts.join('\n'), contains('需要密码，已跳过'));
      expect(state.completeDetail, isNot(contains('失败')));
    });

    t('说不清的包静默跳过 → 标签与 toast 都不再断言「就是密码的事」', () async {
      // 与上一条并排，唯一差别是引擎多带了 `uncertain`。这条路上用户看不到
      // 弹窗，日志与 toast 是他**唯一**能看到的说法，所以说诚实这件事在这
      // 一档比在弹窗那一档更要紧。
      final engine = locked('pw-ok', uncertain: true);
      final state = withVault(
        engine,
        vault: const [PasswordEntry(value: 'pw-bad')],
      );
      final toasts = <String>[];
      state.addListener(() {
        final m = state.toastMsg;
        if (m != null && (toasts.isEmpty || toasts.last != m)) toasts.add(m);
      });

      state.toggleSetting('pwdPrompt');

      await state.selectFolderPath(onePack('as_pw_off_unc').path);
      state.startExtract();
      await drainExtract(state);

      expect(state.logs.first.tags, ['密码或损坏']);
      expect(toasts.join('\n'), contains('可能密码错误或文件损坏，已跳过'));
      expect(toasts.join('\n'), isNot(contains('需要密码，已跳过')),
          reason: '「需要密码」是在替用户把「就是密码的事」拍板');
    });

    t('没接弹窗（回调为 null）→ 与关掉开关一致，不崩', () async {
      final engine = locked('pw-ok');
      final state = withVault(engine); // 不注入 prompt

      await state.selectFolderPath(onePack('as_pw_nobridge').path);
      state.startExtract();
      await drainExtract(state);

      expect(state.extracting, isFalse);
      expect(state.logs.first.status, LogStatus.failed,
          reason: '开关开着却说不出话 —— 那是失败，不是「用户选的跳过」');
      expect(state.logs.first.tags, ['密码未匹配']);
    });

    t('弹窗没弹成（拿不到 context）→ 记失败并出声，别让包凭空消失', () async {
      // 桥接层拿不到 `BuildContext` 时返回 null，那不是用户的选择。与上面
      // 「压根没接桥」是同一种处境，所以收场也一样：失败 + toast。
      final engine = locked('pw-ok');
      final state = withVault(
        engine,
        prompt: (ask) async => null,
      );

      await state.selectFolderPath(onePack('as_pw_noshow').path);
      state.startExtract();
      await drainExtract(state);

      expect(state.logs.first.status, LogStatus.failed);
      expect(state.logs.first.tags, ['密码未匹配']);
    });

    t('密码库是空的 → 照样弹窗，并且告诉弹窗「没得试」', () async {
      final engine = locked('typed');
      final asked = <PasswordAsk>[];
      final state = withVault(
        engine,
        vault: const [],
        prompt: (ask) async {
          asked.add(ask);
          return const PasswordResolution.skip();
        },
      );

      await state.selectFolderPath(onePack('as_pw_empty').path);
      state.startExtract();
      await drainExtract(state);

      expect(asked.single.triedCount, 0,
          reason: '空库和「试了 3 个」是两回事，弹窗的文案要分得开');
      expect(engine.passwordsSeen, [''], reason: '空库没有候选，只剩那次空密码');
    });

    t('说不清的包 → 路由一个字不改，只是把这一位交给弹窗', () async {
      // **这条是本轮的核心不变量**：`uncertain` 是「说法」不是「策略」。
      // 流水账必须与能确定的那一档逐字一致（照样空密码一次、照样按库里的
      // 顺序试、照样试完才弹窗），否则就是把一个措辞问题做成了行为回归 ——
      // 这条路上漏一处，表现就是「加密包不再试密码库」。
      final engine = locked('typed', uncertain: true);
      final asked = <PasswordAsk>[];
      final state = withVault(
        engine,
        vault: const [PasswordEntry(value: 'pw-bad')],
        prompt: (ask) async {
          asked.add(ask);
          return const PasswordResolution.skip();
        },
      );

      await state.selectFolderPath(onePack('as_pw_unc_route').path);
      state.startExtract();
      await drainExtract(state);

      expect(engine.passwordsSeen, ['', 'pw-bad'],
          reason: '与能确定的密码错走的是同一条路');
      expect(asked, hasLength(1), reason: '照样弹窗要密码');
      expect(asked.single.uncertain, isTrue);
      expect(asked.single.triedCount, 1);
    });

    t('能确定的密码错（ZIP-AES / RAR5）→ 交给弹窗的那一位是 false', () async {
      // 少了这条，把 `uncertain` 一路写死成 true 也照样全绿 —— 而那样每张
      // 密码弹窗都会挂上「分不出来」，包括那些 7-Zip 亲口说了「密码不对」的包。
      final engine = locked('typed');
      final asked = <PasswordAsk>[];
      final state = withVault(
        engine,
        vault: const [PasswordEntry(value: 'pw-bad')],
        prompt: (ask) async {
          asked.add(ask);
          return const PasswordResolution.skip();
        },
      );

      await state.selectFolderPath(onePack('as_pw_cert_route').path);
      state.startExtract();
      await drainExtract(state);

      expect(asked.single.uncertain, isFalse);
    });

    t('坏包不该被当成密码问题 → 一个候选都不试', () async {
      // 换十个密码也修不好一个 CRC 坏掉的包。密码库长起来之后，「每个坏包都
      // 白试几十遍」会变成肉眼可见的卡顿。
      final engine = FakeEngine()
        ..behavior = (e, outDir) async {
          throw const EngineException('CRC 校验失败', code: DuzErrorCode.extract);
        };
      final state = withVault(
        engine,
        vault: const [
          PasswordEntry(value: 'pw1'),
          PasswordEntry(value: 'pw2'),
        ],
      );

      await state.selectFolderPath(onePack('as_pw_broken').path);
      state.startExtract();
      await drainExtract(state);

      expect(engine.passwordsSeen, [''], reason: '非密码类失败该立刻收手');
      expect(state.logs.first.tags, ['解压失败'],
          reason: '不能因为带了个密码就记成「密码未匹配」');
      expect(state.logs.first.status, LogStatus.failed);
    });

    t('试密码途中包坏了 → 说它坏了，别接着说「密码没对上」', () async {
      final engine = FakeEngine()
        ..behavior = (e, outDir) async {
          if (e.passwordsSeen.last == '') {
            throw const EngineException(
              'Wrong password',
              code: DuzErrorCode.password,
            );
          }
          throw const EngineException('CRC 校验失败', code: DuzErrorCode.extract);
        };
      final state = withVault(
        engine,
        vault: const [
          PasswordEntry(value: 'pw1'),
          PasswordEntry(value: 'pw2'),
        ],
      );

      await state.selectFolderPath(onePack('as_pw_mid_break').path);
      state.startExtract();
      await drainExtract(state);

      expect(engine.passwordsSeen, ['', 'pw1'],
          reason: '第一个候选把包试坏了，后面那个不必再试');
      expect(state.logs.first.tags, ['解压失败']);
    });
  });

  group('保活（前台服务）', () {
    // 这一组盯的是**时序**：起了没有、停了几次、通知多久推一条。
    //
    // 真机上的效果（锁屏、切后台之后进程还在）只能靠真机验收；这里能钉住的是
    // 「我们确实在最该说的那一刻对系统说了」。解压本身走假引擎，而假保活
    // 见 `test/support/fake_keep_alive.dart`。

    t('一批跑完：起一次、停一次，而且停在收尾的最后一步', () async {
      final root = tempRoot('as_ka_clean');
      put(root, 'a.zip', realZip({'x': 'y'}));

      final keep = FakeKeepAlive();
      final state = AppState(engine: FakeEngine(), keepAlive: keep);
      addTearDown(state.dispose);

      await state.selectFolderPath(root.path);
      state.startExtract();

      // 起服务排在 `_ensureEngine` 前面，所以「已经进入解压态」时它必须**已经**
      // 在跑 —— 晚一步的那个窗口里正好锁屏，这一批就是裸奔的。
      expect(keep.events, ['start'], reason: '批次一开就起服务，不等引擎');
      expect(keep.running, isTrue);

      await drainExtract(state);

      expect(keep.events.first, 'start');
      expect(keep.events.last, 'stop');
      expect(keep.stopCount, 1, reason: '起了一次就得停一次，不多不少');
      expect(keep.running, isFalse,
          reason: '批次结束了还挂着一条用户划不掉的常驻通知，是最糟的收场');

      expect(keep.titles.single, '正在解压');
      // 形状 `42% · 3/12 · 备份.zip`。只有一个包时中间那段是没用的「1/1」，
      // 摆着反而让人以为还有别的，所以它得**不在**。
      expect(keep.startedWith.single, '0% · a.zip');
    });

    t('通知节流：两秒内的连跳不推，过了两秒才推一条', () async {
      final root = tempRoot('as_ka_throttle');
      put(root, 'a.zip', realZip({'x': 'y'}));
      put(root, 'b.zip', realZip({'x': 'y'}));

      final keep = FakeKeepAlive();
      final engine = FakeEngine()
        ..behavior = (e, outDir) async {
          if (e.rounds != 1) return;
          void tick(int done) => e.onExtractTick?.call(ExtractTick(
                doneBytes: done,
                totalBytes: 1000,
                current: 'inner.txt',
              ));

          // 起服务那一刻刚记过时间戳，所以头几跳都该被压在它下面。
          tick(100);
          tick(200);

          // 真实地等过那条线。**这是整个文件里唯一一个真等秒的用例** ——
          // 换假时钟救不了：节流比的是 `DateTime.now()` 的差值，不是定时器。
          await Future<void>.delayed(const Duration(milliseconds: 2100));
          tick(900); // 过了线 → 该推第 1 条
          tick(950); // 紧跟着的一跳 → 该被**刚推过的那一次**压住

          await Future<void>.delayed(const Duration(milliseconds: 2100));
          tick(1000); // 又过线了 → 该推第 2 条
        };
      final state = AppState(engine: engine, keepAlive: keep);
      addTearDown(state.dispose);

      await state.selectFolderPath(root.path);
      state.startExtract();

      // **不能用 `drainExtract`**：它是「推 500 轮零延迟」的推法，那 500 轮
      // 在这四秒里早跑完了，会在批次真正收尾之前就 fail 掉。
      for (var i = 0; i < 100 && state.extracting; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(state.extracting, isFalse, reason: '前提：这一批得跑完');

      // 两条，而且**正好是那两跳过线的**：
      //
      // - 头两跳被「起服务时那个时间戳」压住；
      // - 第 2 条推出去之后，`tick(950)` 又被顶过的新时间戳压住 —— 这一半
      //   专门盯着「推完要记得把时间戳顶上去」；漏了那一句的话，从第一次
      //   推开始，8Hz 的每一跳都会去敲一次方法通道。
      // 两个数都钉住整批比例：90% ÷ 2 个包 = 45%，100% ÷ 2 = 50%，不是当前包
      // 自己的 90% —— 用户要的是「这一批还剩多少」。
      expect(keep.updatedWith, ['45% · 1/2 · a.zip', '50% · 1/2 · a.zip']);
    });

    t('用户按「停止解压」→ 服务照样停', () async {
      final root = tempRoot('as_ka_stop');
      put(root, 'a.zip', realZip({'x': 'y'}));
      put(root, 'b.zip', realZip({'x': 'y'}));

      final gate = Completer<void>();
      final keep = FakeKeepAlive();
      final engine = FakeEngine()
        ..behavior = (e, outDir) async {
          if (e.rounds == 1) await gate.future;
        };
      final state = AppState(engine: engine, keepAlive: keep);
      addTearDown(state.dispose);

      await state.selectFolderPath(root.path);
      state.startExtract();
      await settle();
      state.stopExtract();
      gate.complete();
      await drainExtract(state);

      expect(engine.rounds, 1, reason: '前提：确实是被停下来的，不是跑完的');
      expect(state.outcome, BatchOutcome.stopped);
      expect(keep.stopCount, 1);
      expect(keep.events.last, 'stop');
      expect(keep.running, isFalse);
    });

    t('引擎抛异常 → 服务照样停', () async {
      final root = tempRoot('as_ka_error');
      put(root, 'a.zip', realZip({'x': 'y'}));

      final keep = FakeKeepAlive();
      final engine = FakeEngine()
        ..behavior = (e, outDir) async {
          throw const EngineException('坏了', code: DuzErrorCode.open);
        };
      final state = AppState(engine: engine, keepAlive: keep);
      addTearDown(state.dispose);

      await state.selectFolderPath(root.path);
      state.startExtract();
      await drainExtract(state);

      expect(state.logs.first.status, LogStatus.failed,
          reason: '前提：这一批真的走了异常那条路');
      expect(keep.stopCount, 1,
          reason: '异常那条路最容易被漏掉，漏了就是一条永远撤不掉的常驻通知');
      expect(keep.running, isFalse);
    });

    t('连着两批：第一批停了第二批才起，中间不串', () async {
      final root = tempRoot('as_ka_twice');
      put(root, 'a.zip', realZip({'x': 'y'}));

      final keep = FakeKeepAlive();
      final state = AppState(engine: FakeEngine(), keepAlive: keep);
      addTearDown(state.dispose);

      await state.selectFolderPath(root.path);
      state.startExtract();
      await drainExtract(state);

      // 再选一次目录 = 重新扫描、开新一批（主按钮那颗「更换目标」）。
      await state.selectFolderPath(root.path);
      state.startExtract();
      await drainExtract(state);

      expect(keep.events.where((e) => e == 'start'), hasLength(2));
      expect(keep.stopCount, 2);
      expect(keep.events.first, 'start');
      expect(keep.events.last, 'stop');
      expect(keep.running, isFalse);
    });

    t('切到后台：通知那一路照推，界面那一路不动', () async {
      final root = tempRoot('as_ka_bg');
      put(root, 'a.zip', realZip({'x': 'y'}));

      final gate = Completer<void>();
      final keep = FakeKeepAlive();
      final engine = FakeEngine()..behavior = (e, outDir) => gate.future;
      final state = AppState(engine: engine, keepAlive: keep);
      addTearDown(state.dispose);
      var rebuilds = 0;
      state.addListener(() => rebuilds++);

      await state.selectFolderPath(root.path);
      state.startExtract();
      await settle();

      // 起服务那一刻刚记过通知的时间戳，得先等过那条两秒的线，
      // 否则这一跳会被压在它下面、什么也验不出来。
      await Future<void>.delayed(const Duration(milliseconds: 2100));

      final before = rebuilds;

      // 后台那一份进度：控制器在后台走的就是这个回调（见 `tick_throttle.dart`）。
      // 假引擎整个绕过了控制器里的节流器，所以要在这里手动递一次 ——
      // 递完之后这一刻的状态，与真机上锁屏时的一模一样。
      engine.onExtractTickBackground?.call(ExtractTick(
        doneBytes: 500,
        totalBytes: 1000,
        current: 'inner.txt',
      ));

      expect(rebuilds, before,
          reason: '后台送来的进度不该重建界面 —— 四棵树都不可见，重建了没人看');
      expect(state.progress, 0.5, reason: '数字照算，只是不发那条通知事件');
      expect(keep.updatedWith, ['50% · a.zip'],
          reason: '通知恰恰相反：后台时它是唯一还看得见的东西，必须跟着往前走');

      gate.complete();
      await drainExtract(state);
    });

    t('通知权限：第一次开始解压时问一次，且不拖住起服务', () async {
      final root = tempRoot('as_ka_notif');
      put(root, 'a.zip', realZip({'x': 'y'}));

      final keep = FakeKeepAlive();
      var startedWhenAsked = -1;
      final notif = FakeNotificationPermission()
        ..onEnsure = () => startedWhenAsked = keep.startedWith.length;
      final state = AppState(
        engine: FakeEngine(),
        keepAlive: keep,
        notifications: notif,
      );
      addTearDown(state.dispose);

      await state.selectFolderPath(root.path);
      state.startExtract();
      // `startExtract()` **返回时**服务就该起着 —— 问权限这件事排在它后面，
      // 而且没被 await，所以它吊不住这一步。
      expect(keep.events, ['start'], reason: '一批的开工不能吊在一次用户交互后面');

      await drainExtract(state);

      expect(notif.ensureCount, 1);
      expect(startedWhenAsked, 1,
          reason: '问权限时服务必须已经起来了 —— 反过来（把服务吊在弹窗后面）'
              '就有一整段「活儿没开始跑、也没有保活」的窗口');
      // 「同一个会话里只打扰用户一次」**不在这里断言**：调用方每一批都来问
      // 一次（它本来就该来问 —— 上一批没授权的话这一批还有机会），压制重复
      // 弹窗是 [NotificationPermission] 自己那道 `_asked` 的事，它在
      // `test/services/notification_permission_test.dart` 里验。
    });

    t('没注入保活 → 照常跑完，不抛也不卡', () async {
      // 默认那个 `KeepAlive` 在 Windows 上 `Platform.isAndroid` 为 false，
      // 三个方法一律空转。这正是「加固件没条件就少一层保护、主流程照走」
      // 那条契约在桌面上的样子 —— 它坏了**不能**把解压带下去。
      final root = tempRoot('as_ka_none');
      put(root, 'a.zip', realZip({'x': 'y'}));

      final state = AppState(engine: FakeEngine());
      addTearDown(state.dispose);

      await state.selectFolderPath(root.path);
      state.startExtract();
      await drainExtract(state);

      expect(state.outcome, BatchOutcome.clean);
      expect(state.progress, 1.0);
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
      expect(state.batchRun, isFalse, reason: '刚扫完还没跑，按钮该是「开始解压」');

      state.startExtract();
      await drainExtract(state);

      expect(state.outcome, BatchOutcome.clean);
      expect(state.batchRun, isTrue);
    });

    t('整批都失败也是「用掉了」—— 而且照样出总结卡片', () async {
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

      // 全砸了当然不是「完成」，但它绝对不是「什么都没发生」：卡片照样出，
      // 标题是「全部失败」。从前这里 `completed` 为假，界面连卡片都不出 ——
      // 真机验收时关掉「错误时暂停」的路径上撞出来的那个洞。
      expect(state.outcome, BatchOutcome.allFailed);
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
      expect(state.toastMsg, contains('重新选择目标'));
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
      expect(state.outcome, isNull, reason: '新快照还没跑过');

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
              // 跟出厂默认（关）不同，这样才证明值是真的从档里读回来的。
              'customOutput': true,
              'fakeExtDetect': false,
              'pwdPrompt': true,
              'errorPause': false,
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

      expect(state.setting('fakeExtDetect'), isFalse);
      expect(state.setting('errorPause'), isFalse);
      expect(state.setting('customOutput'), isTrue,
          reason: '出厂是关的 —— 这里为真才说明是读回来的而不是碰巧');
      expect(state.maxDepth, 10);
      expect(state.limitPreset, 3);
      expect(state.limits.maxEntries, 4242);
      expect(state.passwords.single.value, '从磁盘读回来的');
      expect(state.passwords.single.hitCount, 5);
      expect(state.logs.first.name, '上次那个包.zip');
      expect(state.logs.first.status, LogStatus.failed);
    });

    t('档位不越界、深度夹回区间、日志封顶夹回 —— 读回来的坏值不能让设置页崩', () {
      // `limitPreset` 是设置页的芯片直接拿去 `indexOf` 的：越界就是数组下标
      // -1，打开设置页即崩。收敛在 `SettingsRepo` 里也做了一遍，这里是第二道。
      //
      // `maxDepth`/`maxLogs` 走的是**另一条**路：都是自由输入框，所以只夹回
      // 区间、**不吸附到档位**。7 是合法值，就该是 7 —— 把它挪到某个「最近的
      // 档」正是用户明确否掉的做法。
      final store = FakeStore()
        ..toLoad = const AppSnapshot(
          settings: SettingsData(maxDepth: 999, limitPreset: 88, maxLogs: 7),
        );

      final state = AppState(
        engine: FakeEngine(),
        persistStore: store,
        restore: store.toLoad,
      );
      addTearDown(state.dispose);

      expect(state.maxDepth, kMaxMaxDepth, reason: '999 夹回上界（就是那道硬顶）');
      expect(state.limitPreset, kLimitPresets.length, reason: '夹到「自定义」档');
      expect(state.limitsCustom, isTrue);
      expect(state.maxLogs, 7, reason: '自由输入不吸附 —— 合法值原样留着');
    });

    t('日志封顶是负的 / 是 0 → 夹回下界，别让它变成一条都不留', () {
      // 0 会被夹到 [kMinMaxLogs]，而不是被当成「不记录日志」—— 那是另一个
      // 语义，该由一个独立的开关来表意，不该跟「手滑填了个 0」混在一起。
      for (final raw in [-3, 0]) {
        final store = FakeStore()
          ..toLoad = AppSnapshot(settings: SettingsData(maxLogs: raw));

        final state = AppState(
          engine: FakeEngine(),
          persistStore: store,
          restore: store.toLoad,
        );
        addTearDown(state.dispose);

        expect(state.maxLogs, kMinMaxLogs, reason: '$raw 该夹到 $kMinMaxLogs');
      }
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

      expect(state.setting('errorPause'), isTrue);
      expect(state.setting('pwdAutoSave'), isTrue, reason: '两颗出厂都是开的');
      expect(state.setting('customOutput'), isFalse, reason: '新那颗出厂就是关的');
    });

    t('没注入 store → 一切照出厂默认，不崩', () {
      final state = AppState(engine: FakeEngine());
      addTearDown(state.dispose);

      expect(state.setting('customOutput'), isFalse, reason: '出厂默认是关');
      expect(state.maxDepth, kDefaultMaxDepth);
      expect(state.passwords, isEmpty);
      expect(state.logs, isEmpty);
    });

    t('恢复一份「什么都有」的档，也不会把「解压过」带过来', () {
      // **这是那条产品约束的机器判据。** 磁盘上要是记了「哪些目录解过了」，
      // 它就会在这里体现成 `folderSelected` 为真、`batchRun` 为真 —— 用户
      // 一开 app 就看见「更换目标」，想重解一个目录却被挡在外面。
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
      state.toggleSetting('errorPause');

      expect(store.lastSettings, isNotNull);
      expect(store.lastSettings!.toggles['errorPause'], isFalse);
      expect(store.lastSettings!.toggles['customOutput'], isFalse,
          reason: '别的开关要带上');
    });

    t('深度 / 档位 / 单项阈值都会落盘', () {
      state.setMaxDepth(5);
      expect(store.lastSettings!.maxDepth, 5);

      state.setLimitPreset(2);
      expect(store.lastSettings!.limitPreset, 2);
      expect(store.lastSettings!.limits, LimitThresholds.strict);

      state.setLimit(LimitField.entries, 777);
      expect(store.lastSettings!.limits.maxEntries, 777);
      expect(store.lastSettings!.limitPreset, kLimitPresets.length,
          reason: '手改一项就落到「自定义」，这一条也要跟着存');

      state.setSniffWindow(6 << 20);
      expect(store.lastSettings!.sniffWindow, 6 << 20,
          reason: '搜索窗口也是数值型设置，与深度、条数走同一条落盘路');
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

