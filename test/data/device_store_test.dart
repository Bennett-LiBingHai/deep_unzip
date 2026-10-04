import 'dart:io';

import 'package:deep_unzip/data/device_store.dart';
import 'package:deep_unzip/data/json_store.dart';
import 'package:deep_unzip/data/log_repo.dart';
import 'package:deep_unzip/data/persist.dart';
import 'package:deep_unzip/data/settings_repo.dart';
import 'package:deep_unzip/data/vault_repo.dart';
import 'package:deep_unzip/models/log_entry.dart';
import 'package:deep_unzip/models/password_entry.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../engine/zip_fixtures.dart';

/// [DeviceStore] 是三个 repo 的**拼装层**，自己没有什么逻辑 —— 值得测的只有
/// 两件拼装才会出错的事：
///
/// 1. **三份要各归各位**：设置读成密码、日志读成设置这类错误，在类型系统里
///    被 `record` 的 `.wait` 挡住了，但「哪个 repo 交给哪个字段」还是可能写反。
/// 2. **一份失败不能拖垮另外两份**：`save` 在 repo 层是会抛的（写失败是
///    「用户的改动没了」），到这里必须被接住 —— `AppState` 那边发的是
///    `unawaited(...)`，一个漏出去的异常就是**未捕获的异步错误**。
///
/// `DeviceStore.open()` 那一半要走 `path_provider` 的通道，无设备测不了，
/// 靠真机验收（它只是算一个路径，逻辑全在这里测的这半边）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late File logFile;
  late DeviceStore store;

  setUp(() {
    root = makeTempDir('device_store');
    logFile = File('${root.path}${Platform.pathSeparator}logs.json');
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});

    store = DeviceStore(
      settingsRepo: const SettingsRepo(),
      vaultRepo: const VaultRepo(),
      logRepo: LogRepo(JsonStore(), logFile),
    );
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  LogEntry log(String name) => LogEntry(
        name: name,
        status: LogStatus.success,
        size: '1.0 MB',
        time: '今天 14:32',
        duration: '0.5s',
        tags: const ['3 项'],
      );

  group('三份各归各位', () {
    test('空设备 → 一份出厂档，不抛', () async {
      final snapshot = await store.load();

      expect(snapshot.settings.toggles, kDefaultToggles);
      expect(snapshot.settings.maxDepth, kDefaultMaxDepth);
      expect(snapshot.vault, isEmpty);
      expect(snapshot.logs, isEmpty);
    });

    test('三样都存过 → 三样都读得回来，且没有串位', () async {
      await store.saveSettings(const SettingsData(maxDepth: 5));
      await store.saveVault(const [PasswordEntry(value: '口令')]);
      await store.saveLogs([log('a.zip')]);

      final snapshot = await store.load();

      expect(snapshot.settings.maxDepth, 5);
      expect(snapshot.vault.single.value, '口令');
      expect(snapshot.logs.single.name, 'a.zip');
    });
  });

  group('一份坏了不拖垮另外两份', () {
    test('日志读不出来 → 设置和密码库照常', () async {
      await store.saveSettings(const SettingsData(maxDepth: 10));
      await store.saveVault(const [PasswordEntry(value: '还在')]);
      logFile.writeAsStringSync('{"v":1,"entries":[[['); // 截断

      final snapshot = await store.load();

      expect(snapshot.logs, isEmpty);
      expect(snapshot.settings.maxDepth, 10, reason: '日志坏了不该把设置也带崩');
      expect(snapshot.vault.single.value, '还在');
    });

    test('日志写不进去 → save 不抛，设置和密码库照样落盘', () async {
      // 拿一个「目录」冒充日志路径：`rename` 到它上面必失败。
      final dirAsLog = Directory('${root.path}${Platform.pathSeparator}fake')
        ..createSync();
      final broken = DeviceStore(
        settingsRepo: const SettingsRepo(),
        vaultRepo: const VaultRepo(),
        logRepo: LogRepo(JsonStore(), File(dirAsLog.path)),
      );

      // 这三条**一条都不该抛** —— `AppState` 发的是 unawaited，抛出去就是
      // 未捕获的异步错误，红屏级别的。
      await broken.saveLogs([log('写不进去的')]);
      await broken.saveSettings(const SettingsData(maxDepth: 10));
      await broken.saveVault(const [PasswordEntry(value: '也要写进去')]);

      final snapshot = await store.load();
      expect(snapshot.settings.maxDepth, 10);
      expect(snapshot.vault.single.value, '也要写进去');
    });

    test('日志目录都拿不到（logRepo 为 null）→ 其余两样照常', () async {
      // `DeviceStore.open()` 在 `getApplicationSupportDirectory` 失败时就走
      // 这条 —— 宁可少一份诊断材料，也不要启动就崩。
      final noLogs = DeviceStore(
        settingsRepo: const SettingsRepo(),
        vaultRepo: const VaultRepo(),
        logRepo: null,
      );

      await noLogs.saveLogs([log('没人接')]);
      await noLogs.saveSettings(const SettingsData(maxDepth: 20));

      final snapshot = await noLogs.load();
      expect(snapshot.logs, isEmpty);
      expect(snapshot.settings.maxDepth, 20);
      expect(logFile.existsSync(), isFalse, reason: '没给日志文件就不该凭空造一个');
    });
  });
}
