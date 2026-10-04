/// [PersistStore] 的真身：把三个 repo 拼起来，落到这台设备的磁盘上。
///
/// 这是**唯一** import 插件的那个文件，也只有 `main.dart` 会 import 它。
/// 分家的理由见 `persist.dart` 的库注释：`AppState` 只认那个纯 Dart 的接口，
/// 单测就不必先把 `shared_preferences` / `flutter_secure_storage` 的平台通道
/// 搭起来。
///
/// ## 失败一律吞掉
///
/// 三个 repo 的 `save` 都是会抛的（写失败是「用户的改动没了」，不该被就地
/// 抹平），由这里统一接住并降级成一句 `debugPrint`。`AppState` 那边调的都是
/// `unawaited(store.saveX(...))`，一个没接住的异常会变成**未捕获的异步错误**
/// —— 在 Flutter 里那是红屏级别的东西，为一次设置没写进去不值得。
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/log_entry.dart';
import '../models/password_entry.dart';
import 'json_store.dart';
import 'log_repo.dart';
import 'persist.dart';
import 'settings_repo.dart';
import 'vault_repo.dart';

class DeviceStore implements PersistStore {
  // 参数名与字段名（`_settings` 等）**不止差一个下划线**：Dart 不允许私有
  // 具名参数，所以 `this._settings` 这种初始化形参在这里根本写不出来，而
  // `prefer_initializing_formals` 只比对「去掉下划线之后是否同名」——叫
  // `settings` 会换来一条改不掉的假警告。与 `AppState` 构造函数同一回事。
  DeviceStore({
    required SettingsRepo settingsRepo,
    required VaultRepo vaultRepo,
    required LogRepo? logRepo,
  })  : _settings = settingsRepo,
        _vault = vaultRepo,
        _logs = logRepo;

  final SettingsRepo _settings;
  final VaultRepo _vault;

  /// 为 null 表示拿不到应用私有目录（见 [open]）。此时日志**不落盘**，
  /// 其余两样照常 —— 宁可少一份诊断材料，也不要启动就崩。
  final LogRepo? _logs;

  /// 备好这台设备上的落盘位置。
  ///
  /// `getApplicationSupportDirectory` 要过 `path_provider` 的通道，所以调用前
  /// 必须先 `WidgetsFlutterBinding.ensureInitialized()`（`main()` 里做了）。
  static Future<DeviceStore> open() async {
    LogRepo? logs;
    try {
      // 加超时，因为「抛异常」和「永远不回来」是两回事，而这一层对后者的
      // 兜法就是下面那个 `logRepo: null`。通道卡住时（插件没注册是抛，卡住
      // 是等），没有它启动就停在这里，`runApp` 永远轮不到 —— 白屏，且没有
      // 任何日志能指过来。`TimeoutException` 也实现 `Exception`，走同一个出口。
      final dir = await getApplicationSupportDirectory()
          .timeout(const Duration(seconds: 3));
      // 放 appSupport 而不是 appDocuments：日志是应用自己的东西，不该出现在
      // 用户能翻到的「文档」里，更不该被系统备份带回来（`logs.json` 会一直长）。
      logs = LogRepo(JsonStore(), File(p.join(dir.path, 'logs.json')));
    } on Exception catch (e) {
      debugPrint('拿不到应用私有目录，日志将不落盘：$e');
    }

    return DeviceStore(
      settingsRepo: const SettingsRepo(),
      vaultRepo: const VaultRepo(),
      logRepo: logs,
    );
  }

  /// 三份并行读。每份各自容错，一份坏了不影响另外两份。
  ///
  /// 用 record 的 `.wait` 而不是 `Future.wait`：三者的返回类型不一样，
  /// `Future.wait` 只能给一列 `Object`，拿回来还得逐个 downcast —— 那正是
  /// 「读设置的时候拿错了日志」这类错误最容易钻进去的地方。
  @override
  Future<AppSnapshot> load() async {
    final (settings, vault, logs) = await (
      _loadSettings(),
      _loadVault(),
      _loadLogs(),
    ).wait;

    return AppSnapshot(settings: settings, vault: vault, logs: logs);
  }

  Future<SettingsData> _loadSettings() async {
    try {
      return await _settings.load();
    } on Exception catch (e) {
      debugPrint('设置读取失败，用出厂默认：$e');
      return SettingsData.defaults;
    }
  }

  Future<List<PasswordEntry>> _loadVault() async {
    try {
      return await _vault.load();
    } on Exception catch (e) {
      debugPrint('密码库读取失败，按空库处理：$e');
      return const [];
    }
  }

  Future<List<LogEntry>> _loadLogs() async {
    try {
      return await _logs?.load() ?? const [];
    } on Exception catch (e) {
      debugPrint('日志读取失败：$e');
      return const [];
    }
  }

  @override
  Future<void> saveSettings(SettingsData data) =>
      _guard(() => _settings.save(data), '设置');

  @override
  Future<void> saveVault(List<PasswordEntry> entries) =>
      _guard(() => _vault.save(entries), '密码库');

  @override
  Future<void> saveLogs(List<LogEntry> logs) =>
      _guard(() => _logs?.save(logs) ?? Future<void>.value(), '日志');

  Future<void> _guard(Future<void> Function() body, String what) async {
    try {
      await body();
    } on Exception catch (e) {
      // 刻意只 catch Exception：真正的 Error（断言、类型错）是代码 bug，
      // 该炸出来，不该被这里伪装成「磁盘问题」。
      debugPrint('$what落盘失败：$e');
    }
  }
}
