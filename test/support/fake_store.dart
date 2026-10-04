/// 测试用的假持久化：把每一次落盘原样记下来，供用例断言。
///
/// 接的是纯 Dart 的 [PersistStore]，所以这组测试完全不碰
/// `shared_preferences` / `flutter_secure_storage` 的平台通道 ——
/// 那两样的真实读写由 `test/data/` 下各自的 repo 用例对着 mock 通道验。
/// 这里要盯的是另一半：**`AppState` 到底在什么时候、把什么内容交了出去**。
library;

import 'package:deep_unzip/data/persist.dart';
import 'package:deep_unzip/models/log_entry.dart';
import 'package:deep_unzip/models/password_entry.dart';

class FakeStore implements PersistStore {
  /// [load] 会返回的那一份。默认空档。
  AppSnapshot toLoad = AppSnapshot.empty;

  /// 每次 `saveSettings` 交上来的内容，按调用顺序。
  final List<SettingsData> settingsSaved = [];

  /// 每次 `saveVault` 交上来的整库快照。
  final List<List<PasswordEntry>> vaultSaved = [];

  /// 每次 `saveLogs` 交上来的整份日志。
  final List<List<LogEntry>> logsSaved = [];

  @override
  Future<AppSnapshot> load() async => toLoad;

  // 下面几个方法体里**没有 `await`**：Dart 的 async 函数会同步跑到第一个
  // `await` 才让出，所以 `AppState` 那边 `unawaited(...)` 发出来的调用，
  // 记录是**当场**落进列表的。用例里不必再 pump 一轮才看得到。
  @override
  Future<void> saveSettings(SettingsData data) async {
    settingsSaved.add(data);
  }

  @override
  Future<void> saveVault(List<PasswordEntry> entries) async {
    vaultSaved.add(entries);
  }

  @override
  Future<void> saveLogs(List<LogEntry> logs) async {
    logsSaved.add(logs);
  }

  /// 最后一次落盘的设置。没写过则为 null。
  SettingsData? get lastSettings =>
      settingsSaved.isEmpty ? null : settingsSaved.last;

  /// 最后一次落盘的日志。
  List<LogEntry>? get lastLogs => logsSaved.isEmpty ? null : logsSaved.last;

  /// 落盘的日志里有没有提到 [path]。
  ///
  /// 给「不存解压过的文件夹」那条产品约束用：日志里会出现**文件夹名**
  /// （扫描那条记的是 `$folderName（扫描）`），但**不该出现完整路径** ——
  /// 路径才是能拿来反查「这个目录解过了」的东西。
  bool savedLogsMentionPath(String path) =>
      logsSaved.any((batch) => batch.any((e) => e.name.contains(path)));
}
