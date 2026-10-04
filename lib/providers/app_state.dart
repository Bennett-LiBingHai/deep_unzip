import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';

import '../data/builtin_extractors.dart';
import '../data/persist.dart';
import '../engine/controller.dart';
import '../engine/cycles.dart';
import '../engine/format.dart';
import '../engine/limits.dart';
import '../engine/log_builder.dart';
import '../engine/models.dart';
import '../engine/output_paths.dart';
import '../engine/progress_meter.dart';
import '../engine/protocol.dart';
import '../engine/scanner.dart';
import '../models/archive_file.dart';
import '../models/extractor.dart';
import '../models/log_entry.dart';
import '../models/password_entry.dart';
import '../services/prompts.dart';
import '../services/disk_space.dart';

/// 全局应用状态。
///
/// ## 它现在的角色：引擎的**瘦适配层**
///
/// 4 个页面 + 4 个弹窗全部通过 `ListenableBuilder(listenable: state)` 直接读
/// 这里的 getter，所以**公开签名一个都不能动**（改名就会牵动整个 UI）。
/// 真实的活儿全在 `engine/` 里，这里只做三件事：
///
/// 1. 把 `ScanItem`（带真实路径、分片清单、嗅探结果）翻译成 UI 认得的
///    `ArchiveFile`（`size` 是预格式化字符串）。
/// 2. 把引擎回调写回下面的私有字段并通知（走 [_notify]，它拦住释放后的迟到回调）。
/// 3. 权限申请与目录选择。
///
/// ## 两条不变量
///
/// - `_archives` 与 `_scanItems` **等长同序**，下标 `i` 一一对应。只在
///   `_applyScan` 一处建立，别处只读。
/// - `engine/` 里没有 `package:flutter`，所以引擎能跑在 isolate 里；
///   这一层是唯一允许把两者接起来的地方。
class AppState extends ChangeNotifier {
  // 参数名故意与字段名（`_onPrompt`）**不止差一个下划线**：Dart 不允许私有
  // 具名参数，所以 `this._onPrompt` 这种初始化形参在这里根本写不出来，
  // 而 `prefer_initializing_formals` 只比对「去掉下划线之后是否同名」——
  // 叫 `onPrompt` 会换来一条改不掉的假警告。叫 `prompt` 就绕开了。
  AppState({
    EngineController? engine,
    DiskSpaceProbe? diskSpace,
    ArchivePrompt? prompt,
    FormatDetectPrompt? formatPrompt,
    // 参数名与字段名（`_store`）**不止差一个下划线** —— 与上面那条同因：
    // 叫 `store` 会换来一条 Dart 根本没法照做的假警告。
    PersistStore? persistStore,
    AppSnapshot? restore,
  })  : _injectedEngine = engine,
        _diskSpace = diskSpace ?? DiskSpaceProbe(),
        _onPrompt = prompt,
        _onFormatDetect = formatPrompt,
        _store = persistStore {
    // 出厂值在字段初始化时就位了（见下方 `_settings` 等），这里把磁盘上读回来
    // 的那份盖上去。**在构造函数体里做而不是让调用方改**，是为了让「读到的
    // 快照」和「出厂默认」走同一条装配路径 —— 分成两条路的话，某天加一个字段
    // 只改了其中一条，就会冒出「首次启动对、重启后错」这种最难查的 bug。
    if (restore != null) _applySnapshot(restore);
  }

  final EngineController? _injectedEngine;
  EngineController? _engine;

  /// 落盘的出海口。**为 null 时完全不持久化**，行为与没有这个特性时一致
  /// —— 单测默认就是这一档（真实现要过 `shared_preferences` /
  /// `flutter_secure_storage` 的平台通道，那是 `DeviceStore` 的事）。
  ///
  /// 类型是纯 Dart 的接口（见 `data/persist.dart`），所以这一层不必 import
  /// 任何插件，`app_state.dart` 那条「引擎侧不碰 package:flutter」的边界不破。
  final PersistStore? _store;

  /// 量目标卷剩余空间。走平台通道，所以要**在主 isolate** 上调用 ——
  /// `extractArchive` 跑在 worker isolate 里，够不着通道（见 `protocol.dart`
  /// 的 `CmdExtract.availableBytes`）。
  final DiskSpaceProbe _diskSpace;

  /// 一个包处理不了时问用户「继续 / 停止」。
  ///
  /// 两档共用这一个回调：炸弹/空间闸门拦下，和解压出错。原先是两个（`_onBlocked`
  /// / `_onError`），分开的理由是后者能「暂停」、停得回来 —— 那条路已经按用户
  /// 要求去掉了，剩下的两个决断在两边含义完全一样，见 `prompts.dart` 的表。
  ///
  /// 为 null 时行为与没有这个特性时**逐字节一致**：只记日志 + toast，不弹窗。
  /// 单元测试默认就是这一档 —— 真弹窗要 `MaterialApp` 挂上 `AppNavigator.key`，
  /// 那是 widget 测试的事（见 `test/services/dialog_bridge_test.dart`）。
  ///
  /// 类型是纯 Dart 的（见 `services/prompts.dart`），所以这一层不必
  /// import 任何 widget，`app_state.dart:43` 那条边界不破。
  final ArchivePrompt? _onPrompt;

  /// 后缀被篡改时问用户「按真实格式解吗」（需求 5）。同上，为 null 时
  /// 静默按真实格式解 —— 那正是加这个弹窗之前的行为。
  final FormatDetectPrompt? _onFormatDetect;

  // 文件夹
  bool _folderSelected = false;
  String _folderName = '';
  String _folderPath = '';
  bool get folderSelected => _folderSelected;
  String get folderName => _folderName;
  String get folderPath => _folderPath;

  // 扫描结果
  List<ArchiveFile> _archives = [];
  List<ArchiveFile> get archives => _archives;
  bool get hasScanned => _archives.isNotEmpty;

  /// 与 [archives] 等长同序的真实数据（路径、分片、嗅探结果）。
  /// 解压阶段要用它，UI 不直接读。
  final List<ScanItem> _scanItems = [];

  /// 本轮扫描用的参数快照。
  ///
  /// 存下来是给**嵌套扫描**用的：解压期发现的包要按同一份快照去识别，
  /// 否则用户在设置里关掉的 `splitMerge` / `fakeExtDetect` 会在嵌套那一层
  /// 悄悄复活，表现为「设置好像不生效」。
  ScanOptions _scanOptions = const ScanOptions();

  // 扫描进行中
  bool _scanning = false;
  int _scanFound = 0;
  String _scanCurrent = '';
  ScanSummary? _lastScan;

  /// 引擎还在启动时用户就按了取消。见 [cancelScan]。
  bool _cancelRequested = false;

  /// 是否正在扫描。与 [extracting] 是两个阶段，不要混用。
  bool get scanning => _scanning;

  /// 扫描中已发现的压缩包数（**没有分母**：目录里有多少压缩包要扫完才知道，
  /// 所以扫描阶段的进度是不确定的，只能给个已发现数）。
  int get scanFound => _scanFound;

  /// 扫描中当前正在看的路径，给副标题用。
  String get scanCurrent => _scanCurrent;

  /// 上一次扫描的完整结果（含告警与容器跳过数）。
  ScanSummary? get lastScan => _lastScan;

  // 解压状态
  bool _extracting = false;
  double _progress = 0.0;
  String _currentFile = '';
  int _doneCount = 0;
  double _speed = 0;
  int _depth = 0;
  String _eta = '--';
  bool _completed = false;
  String _completeDetail = '';

  /// 当前这份扫描结果**已经被解压过一轮了**（成功、失败、取消都算）。
  ///
  /// 和 [_completed] 是两件事，别合并：`_completed` 说的是「全部成功」，
  /// 有任何一个包失败它就是 false；而这里说的是「这份快照用掉了」。
  /// 界面要靠它决定主按钮该不该还是「开始智能解压」—— 一旦这批跑过，
  /// 再点就等于把同一个队列重排一遍，而输出目录重名会追加 `_1`/`_2`
  /// （见 output_paths.dart），结果不是「重新解一遍」而是往磁盘里撒重复目录。
  bool _batchRun = false;

  // 解压批次（一次 startExtract 覆盖的一整批包）
  //
  // 这几个都是**批次级**而不是「当前包」级的：进度条要在整批的尺度上单调
  // 前进，而每个包的字节计数是各自从 0 开始的。
  int _batchTotal = 0;
  DateTime? _batchStart;
  ProgressMeter _meter = ProgressMeter();

  /// 当前包内正在处理的条目名。UI 暂未使用，留着给进度面板做副标题。
  String _entryName = '';

  bool get extracting => _extracting;
  double get progress => _progress;
  String get currentFile => _currentFile;

  /// 当前正在解压的**条目**名（`currentFile` 是压缩包名，这个是包里的文件）。
  /// 进度面板的副标题用得上；没有在跑时为空串。
  String get currentEntry => _entryName;
  int get doneCount => _doneCount;
  double get speed => _speed;
  int get depth => _depth;
  String get eta => _eta;
  bool get completed => _completed;
  String get completeDetail => _completeDetail;

  /// 这批扫描结果已经解压过了（无论成败）。为真时主按钮应换成「换个文件夹」，
  /// 不能再是「开始智能解压」—— 理由见 [_batchRun]。
  bool get batchRun => _batchRun;

  // 密码库。**空库起步** —— 之前从 mock 数据播种是为了演示观感，但那会让
  // 用户第一次打开就看到四条「别人的」密码（还带假的命中次数）。真实做法是
  // 让用户自己攒；P4 接上 `flutter_secure_storage` 后这里改成从 `vault_v1` 读。
  final List<PasswordEntry> _passwords = [];
  List<PasswordEntry> get passwords => List.unmodifiable(_passwords);

  // 日志。同样空库起步：历史应当只记录**本机真的解压过**的东西。
  final List<LogEntry> _logs = [];
  List<LogEntry> get logs => List.unmodifiable(_logs);
  LogStatus? _logFilter;
  LogStatus? get logFilter => _logFilter;

  List<LogEntry> get filteredLogs {
    if (_logFilter == null) return _logs;
    return _logs.where((l) => l.status == _logFilter).toList();
  }

  /// 日志封顶。纯追加写、又要在退出时整份落盘，不封顶会无限长。
  static const int _maxLogs = 300;

  // 解压器。**内置那几条是真配置，不是演示数据** —— 见 BuiltinExtractors。
  // 从原来的 mock_data.dart 搬过来只是因为那里被整个删掉了。
  final List<Extractor> _extractors = List.from(BuiltinExtractors.all);
  List<Extractor> get extractors => List.unmodifiable(_extractors);

  // 设置开关。初值抄自 `data/persist.dart` 那张表 —— 与「磁盘上什么都没有」
  // （`AppSnapshot.empty`）时给的那一份必须是同一套，否则「首次启动」和
  // 「存过档」会跑出两种行为，最难查。
  final Map<String, bool> _settings = Map.of(kDefaultToggles);
  bool setting(String key) => _settings[key] ?? false;
  void toggleSetting(String key) {
    _settings[key] = !(_settings[key] ?? false);
    _notify();
    _persistSettings();
  }

  int _maxDepth = kDefaultMaxDepth; // 0 = 无限制
  int get maxDepth => _maxDepth;
  void cycleMaxDepth() {
    // 档位表在 `data/persist.dart`：设置页的芯片、加载时的收敛
    // （`coerceMaxDepth`）与这里读的是同一份。三处各写一份 `[0, 5, 10, 20]`
    // 的话，改动时漏掉一处就是一个只在特定路径上才炸的 bug。
    //
    // `indexOf` 给出 -1 时（值不在表里）取到 `kMaxDepthOptions[0]`，安全 ——
    // 加载时已经收敛过，这只是第二道防线。
    final idx = kMaxDepthOptions.indexOf(_maxDepth);
    _maxDepth = kMaxDepthOptions[(idx + 1) % kMaxDepthOptions.length];
    _notify();
    _persistSettings();
  }

  // ---- 炸弹防护阈值 ----

  LimitThresholds _limits = LimitThresholds.standard;
  LimitThresholds get limits => _limits;

  /// chip 停在哪一档：[kLimitPresets] 的下标，或 `kLimitPresets.length` 表示
  /// 「自定义」。
  ///
  /// **必须单独存，不能从 `_limits` 反推。** 反推的写法（「值等于哪个预设就
  /// 显示哪个」）有个死结：用户点进「自定义」时值还没变，chip 会立刻跳回
  /// 「标准」，刚展开的那几行又收回去 —— 于是永远改不了任何一项。
  int _limitPreset = 1; // 1 = 标准，与 _limits 的初值一致
  int get limitPreset => _limitPreset;

  bool get limitsCustom => _limitPreset >= kLimitPresets.length;

  String get limitPresetLabel =>
      limitsCustom ? kCustomLimitLabel : kLimitPresets[_limitPreset].label;

  /// 依次走过：宽松 → 标准 → 严格 → 自定义 → 宽松…
  void cycleLimitPreset() => setLimitPreset((_limitPreset + 1) % (kLimitPresets.length + 1));

  void setLimitPreset(int index) {
    _limitPreset = index.clamp(0, kLimitPresets.length);
    // 落到「自定义」时**保留当前值**：用户多半是想从这一档微调，而不是
    // 要一组空数字。落到具体档位时才整体替换。
    if (!limitsCustom) _limits = kLimitPresets[_limitPreset].thresholds;
    _notify();
    _persistSettings();
  }

  /// 改一项阈值，并自动落到「自定义」档。
  ///
  /// 这里**不**去反查「改完是不是正好等于某个预设，是的话就跳回去」：那同样
  /// 会让用户在编辑途中被弹出编辑器（把某一项改回预设值的一瞬间，四行就没了）。
  /// chip 显示「自定义」、而数值恰好等于某档 —— 这不矛盾，它确实是被手改过的。
  void setLimit(LimitField field, int value) {
    _limits = field.apply(_limits, value);
    _limitPreset = kLimitPresets.length;
    _notify();
    _persistSettings();
  }

  // Toast
  String? _toastMsg;
  String? _toastType;
  String? get toastMsg => _toastMsg;
  String? get toastType => _toastType;

  /// 递增 token：2 秒内出现的第二条 toast 不该被第一条的定时器提前抹掉。
  /// 原来的实现无条件清空，连续两条 toast 会让第一条的定时器把第二条吃掉。
  int _toastToken = 0;

  /// 已释放。`dispose` 的幂等守卫，也用来拦住滞后的定时器。
  bool _disposed = false;

  /// 唯一的通知出口。**所有** `notifyListeners` 都要走这里。
  ///
  /// `ChangeNotifier.notifyListeners` 在释放之后调用会直接断言崩溃，而
  /// 「释放之后还有回调跑」在这套架构里是常态而不是异常：解压是
  /// `unawaited(_runExtractBatch())` 起的后台流程，用户在解压途中离开页面
  /// → `dispose()` → `_engine.dispose()` 把在跑的任务以异常结束 →
  /// 那个 catch 分支照样会 `showToast` + 记日志。没有这道守卫，
  /// 「解压到一半退出」就是一个必崩的路径。
  void _notify() {
    if (_disposed) return;
    super.notifyListeners();
  }

  void showToast(String msg, {String type = 'info'}) {
    final token = ++_toastToken;
    _toastMsg = msg;
    _toastType = type;
    _notify();
    Future.delayed(const Duration(seconds: 2), () {
      // `_disposed` 的守卫在 [_notify] 里；这里提前返回是为了**别改字段**：
      // 定时器可能跨用例泄漏，上一条用例的 toast 不该把下一条的状态抹掉。
      if (_disposed) return;
      if (token != _toastToken) return; // 已经有更新的一条了，让它自己清
      _toastMsg = null;
      _toastType = null;
      _notify();
    });
  }

  // ---------------------------------------------------------------------------
  // 持久化
  // ---------------------------------------------------------------------------

  /// 把磁盘上读回来的那一份盖到出厂值上。
  ///
  /// 只在构造函数里跑一次。**不 `_notify()`**：此刻还没有监听者。
  void _applySnapshot(AppSnapshot s) {
    // 从出厂值起步再盖上读回来的键，而不是整份替换：磁盘上那份要是缺了某个
    // 键（更早的版本写的），整份替换会让那个开关悄悄变成 `false`。
    _settings
      ..clear()
      ..addAll(kDefaultToggles)
      ..addAll(s.settings.toggles);

    _maxDepth = coerceMaxDepth(s.settings.maxDepth);
    // 档位下标收敛到合法区间；超界的归到「自定义」那档而不是 0。
    _limitPreset = s.settings.limitPreset.clamp(0, kLimitPresets.length);
    _limits = s.settings.limits;

    _passwords
      ..clear()
      ..addAll(s.vault);
    _logs
      ..clear()
      ..addAll(s.logs);
  }

  /// 落盘当前设置。改一个开关就调用一次。
  ///
  /// 界面不等这次写（[PersistStore] 的方法都是 `unawaited`）：等的话，一次
  /// 慢磁盘就会让开关看起来卡住。失败由 `DeviceStore` 吞掉并 `debugPrint`。
  void _persistSettings() {
    final store = _store;
    if (store == null) return;
    unawaited(store.saveSettings(SettingsData(
      // 复制一份再交出去：`_settings` 是活的，异步写盘期间用户又点了别的开关
      // 的话，写出去的会是**编码那一刻**的内容而不是调用时的内容。
      toggles: Map.of(_settings),
      maxDepth: _maxDepth,
      limitPreset: _limitPreset,
      limits: _limits,
    )));
  }

  /// 落盘密码库。增删一条就调用一次。
  void _persistVault() {
    final store = _store;
    if (store == null) return;
    unawaited(store.saveVault(List.of(_passwords)));
  }

  /// 落盘日志。
  ///
  /// **刻意不在 [_addLog] 里调**：解压期每解完一个包就记一条日志，整批 200 个
  /// 包就是 200 次「整份覆盖写 + JSON 编码」，全压在 UI isolate 上 —— 而此刻
  /// 日志页根本没人看。改成只在**自然边界**写一次：扫描收尾、整批收尾。
  /// 代价是解压途中被杀会少掉这一批的逐包日志（那份收尾总结仍会写出去）。
  void _persistLogs() {
    final store = _store;
    if (store == null) return;
    unawaited(store.saveLogs(List.of(_logs)));
  }

  // ---------------------------------------------------------------------------
  // 引擎
  // ---------------------------------------------------------------------------

  /// 惰性启动 worker isolate。第一次真正需要时才付 isolate 启动的开销，
  /// 也让 `flutter test` 里不碰 `selectFolder` 的用例完全不启动它。
  Future<EngineController> _ensureEngine() async {
    final existing = _engine;
    if (existing != null) return existing;

    final controller = _injectedEngine ?? EngineController();
    controller.onScanTick = _onScanTick;
    controller.onExtractTick = _onExtractTick;
    try {
      await controller.start();
    } catch (_) {
      // 启动失败就把它丢掉。留着的话下一次调用会拿到一个半死的控制器，
      // 每个操作都抛「控制器已释放」，用户看不出真正的原因。
      if (_injectedEngine == null) controller.dispose();
      rethrow;
    }
    _engine = controller;
    return controller;
  }

  /// 前后台切换。后台时引擎只标脏不发进度事件（四个页面都在
  /// `IndexedStack` 里，每次 notify 都会重建全部四棵树）。
  void setForeground(bool foreground) {
    _engine?.setForeground(foreground);
  }

  // ---------------------------------------------------------------------------
  // 目录选择与扫描
  // ---------------------------------------------------------------------------

  /// 选一个文件夹并递归扫描。UI 现存调用点都长这样，所以保持 `void`，
  /// 真正的异步流程在 [_pickFolderAndScan] 里跑。
  void selectFolder() {
    unawaited(_pickFolderAndScan());
  }

  Future<void> _pickFolderAndScan() async {
    if (_scanning) return;

    if (!await _ensureStoragePermission()) {
      showToast('需要「所有文件访问权限」才能递归扫描目录', type: 'warn');
      return;
    }

    String? path;
    try {
      // file_picker 13 起全部改成静态方法（`FilePicker.platform` 已移除）。
      path = await FilePicker.getDirectoryPath(dialogTitle: '选择要扫描的文件夹');
    } catch (e) {
      showToast('打开目录选择器失败：$e', type: 'warn');
      return;
    }
    if (path == null || path.isEmpty) return; // 用户点了取消，不打扰

    await selectFolderPath(path);
  }

  /// 扫描指定目录。与 `selectFolder()` 分开是因为选目录流程依赖
  /// `FilePicker` 的平台通道，而这里只依赖引擎 —— 将来「最近使用」、
  /// 「用 DeepUnzip 打开」这类入口也走这里。
  Future<void> selectFolderPath(String path) async {
    if (_scanning) return;

    _folderPath = path;
    _folderName = p.basename(path);
    if (_folderName.isEmpty) _folderName = path;
    _folderSelected = true;
    _resetExtractState();
    _clearScanResult();
    _cancelRequested = false;
    _scanning = true;
    _scanFound = 0;
    _scanCurrent = '';
    _notify();
    showToast('正在递归扫描压缩包...');

    try {
      final engine = await _ensureEngine();
      // 快照下来，嵌套扫描（解压期发现的新包）要用同一份，见 [_scanOptions]。
      final options = ScanOptions(
        detectFakeExtension: setting('fakeExtDetect'),
        mergeSplitVolumes: setting('splitMerge'),
      );
      _scanOptions = options;
      final pending = engine.scan(rootPath: path, options: options);
      if (_cancelRequested) {
        // 先发任务再发取消，顺序不能反：控制器的取消只作用于「正在跑的
        // 任务」（`_activeJob == null` 时直接返回），worker 也只在 runScan
        // 捕获 epoch 之后才认这个信号。两条消息走同一个端口，顺序有保证。
        unawaited(engine.cancelScan());
      }
      final out = await pending;
      _applyScan(out.summary, out.elapsed);
    } catch (e) {
      // 捕 `Object` 而不是只捕 `EngineException`：isolate 启动失败抛的是
      // `IsolateSpawnException`，漏掉它就会变成 `unawaited` 的未处理错误，
      // 界面只表现为「点了没反应」。
      _scanning = false;
      _notify();
      showToast(e is EngineException ? e.message : '扫描失败：$e', type: 'warn');
      _addLog(buildScanFailureLog(
        folderName: _folderName,
        now: DateTime.now(),
      ));
      _persistLogs();
      return;
    }

    _scanning = false;
    _notify();

    _toastScanResult(_lastScan!);
    // 扫描收尾是日志的天然边界（见 [_persistLogs]）：这一批扫描相关的日志
    // 到此为止都记完了，写一次就够。
    _persistLogs();
  }

  void _toastScanResult(ScanSummary s) {
    final ignored =
        s.containerSkipped > 0 ? '（已忽略 ${s.containerSkipped} 个容器格式文件）' : '';

    if (s.items.isEmpty) {
      // `hasScanned` 是「有扫描结果」而不是「扫过了」，空结果时为 false，
      // 主按钮会一直禁用。所以这里必须给出明确反馈，否则用户以为卡住了。
      showToast('未发现可解压的压缩包$ignored', type: 'warn');
      return;
    }
    showToast('扫描完成，发现 ${s.items.length} 个压缩包$ignored', type: 'success');
  }

  /// 丢掉上一次的扫描结果。
  ///
  /// 开始新一轮扫描时必须先清：`folderName`/`folderPath` 立刻就换成新目录了，
  /// 若扫描随后失败（目录不可读、isolate 起不来），`_archives` 若还留着旧数据，
  /// 界面就会把**上一个目录**的压缩包挂在**新目录**名下 —— 那种错法用户看不出来。
  void _clearScanResult() {
    _scanItems.clear();
    _archives = [];
    _lastScan = null;
    _scanFound = 0;
    _scanCurrent = '';
  }

  /// 建立 `_archives` ↔ `_scanItems` 的等长同序不变量。
  void _applyScan(ScanSummary summary, Duration elapsed) {
    _lastScan = summary;

    _scanItems
      ..clear()
      ..addAll(summary.items);

    _archives = [
      for (final item in summary.items)
        ArchiveFile(
          name: item.fileName,
          type: item.sniff.format.archiveType,
          size: formatBytes(item.sizeBytes),
          flags: item.flags.toList(),
          depth: item.depth,
        ),
    ];

    assert(_archives.length == _scanItems.length, '两条列表必须等长同序');

    _addLog(buildScanLog(
      folderName: _folderName,
      summary: summary,
      elapsed: elapsed,
      now: DateTime.now(),
    ));
  }

  /// 引擎进度回调。已经被控制器按 8Hz 节流过。
  void _onScanTick(ScanTick tick) {
    _scanFound = tick.found;
    _scanCurrent = tick.current;
    _notify();
  }

  /// 中止当前扫描。已扫到的部分会正常返回（不是错误）。
  ///
  /// 会记住这次请求：`_scanning` 在 `await _ensureEngine()` **之前**就置位并
  /// 通知了 UI，所以取消按钮在 worker 还没起来时就已经可见。那一刻 `_engine`
  /// 仍是 null，只看 `_engine` 的话这次点击会被静默吞掉，用户看到的是
  /// 「按了取消，扫描照跑」。
  void cancelScan() {
    if (!_scanning) return;
    _cancelRequested = true;
    unawaited(_engine?.cancelScan() ?? Future<void>.value());
  }

  /// Android 上递归读目录需要「所有文件访问权限」（API 30+）或
  /// 读写外部存储（API ≤ 29）。非 Android 直接放行。
  ///
  /// 权限被拒**不能**让应用不可用：返回 false，由调用方给一句提示。
  Future<bool> _ensureStoragePermission() async {
    if (kIsWeb || !Platform.isAndroid) return true;

    try {
      if (await Permission.manageExternalStorage.isGranted) return true;
      if (await Permission.storage.isGranted) return true;

      // API 30+：跳系统「所有文件访问」授权页。
      if ((await Permission.manageExternalStorage.request()).isGranted) {
        return true;
      }
      // API ≤ 29：老路径。
      return (await Permission.storage.request()).isGranted;
    } catch (_) {
      // 平台通道出问题不该把选目录这条路彻底堵死 —— 让扫描自己去撞，
      // 撞出来的不可读文件会如实计入扫描告警。
      return true;
    }
  }

  // ---------------------------------------------------------------------------
  // 解压
  // ---------------------------------------------------------------------------

  /// 新一轮扫描开始时作废上一轮的解压统计。
  ///
  /// 不重置的话，换一个文件夹后进度条还停在旧任务的 73%、`doneCount` 还是
  /// 上一个目录的数字，看起来像是新任务立刻跑到那儿了。
  void _resetExtractState() {
    _extracting = false;
    _progress = 0.0;
    _currentFile = '';
    _doneCount = 0;
    _speed = 0;
    _depth = 0;
    _eta = '--';
    _completed = false;
    _completeDetail = '';
    _batchRun = false;
  }

  /// 开始把扫描到的压缩包逐个解开。
  ///
  /// 输出目录与源同级（`A/B/c.zip` → `A/B/c/`），重名追加 `_1`。递归解压
  /// （解出来的包里还有包）是 P2，这里只处理顶层的一批。
  void startExtract() {
    if (_extracting) return;
    if (_archives.isEmpty) {
      showToast('先选择一个文件夹并完成扫描', type: 'warn');
      return;
    }
    // 这份快照已经跑过一轮了。**这道闸门是必须的，不能只靠界面上把按钮改个
    // 名字** —— 重跑不会「再解一遍」，而是把同一个队列重排一次，输出目录
    // 重名时会追加 `_1`/`_2`，等于往磁盘里撒重复目录（见 output_paths.dart）。
    // 想再来一遍就重新选一次目录，那会重新扫描，拿到的是新快照。
    if (_batchRun) {
      showToast('这批已经解压过了，换个文件夹再试', type: 'warn');
      return;
    }
    unawaited(_runExtractBatch());
  }

  /// 停下这一批。**粒度是「包与包之间」**，不是条目级。
  ///
  /// 之所以做不到条目级：`duz_extract_all` 是一次同步 FFI 调用，跑起来就
  /// 不回头，中途没有任何 Dart 代码能被执行（见 [CmdExtract] 的说明）。
  /// 能做到的是「当前这个包解完就停」。对多数场景够用，但一个大包可能要
  /// 等上几十秒才真的停下来 —— UI 上要如实说这一点，别让用户以为按下去
  /// 就立刻停了（那颗按钮的文案因此是「停止解压」而不是「已停止」）。
  ///
  /// **停下就是停下，没有「继续」。** 剩下没解的包直接丢掉，用户想接着来
  /// 只能重新选文件夹（那会重新扫描，拿到一份新快照）。原先这里是一对
  /// `pauseExtract`/`resumeExtract`，暂停闸门让队列原封不动地等着；用户
  /// 明确要求「不需要暂停，要么继续、要么停止」，于是收敛成这一条不可恢复
  /// 的停止 —— 与弹窗里那颗「停止」走的是同一条路（都是 `_cancelRequested`）。
  void stopExtract() {
    if (!_extracting || _cancelRequested) return;
    _cancelRequested = true;
    _notify();
    showToast('将在当前压缩包解完后停止');
  }

  /// 逐个解压。批次开始时给扫描结果拍一张快照，之后**只往里追加** ——
  /// 需求 1 的「嵌套压缩包继续解压」会在跑的过程中不断发现新任务。
  ///
  /// 为什么是队列而不是固定列表：嵌套包的发现是**边解边发生**的，
  /// 解完 `nested.zip` 才知道里面躺着个 `inner.zip`，它得排到队尾去。
  ///
  /// 每一条任务都扛着**祖先身份集**，用来挡自引用（见 cycles.dart）。
  /// 身份是「父传子」的：解 `nested.zip` 之前先算好它自己的身份，把它并进
  /// 子任务的身份集里。所以每一层只需算**一次**哈希，不是每层重算一整条链。
  Future<void> _runExtractBatch() async {
    final queue = Queue<_ExtractTask>();
    for (final item in _scanItems) {
      queue.add(_ExtractTask(item: item, ancestors: const {}));
    }
    if (queue.isEmpty) return;

    // 设置在批次开始时锁定。跑的过程中用户去设置页改开关不该影响这一批
    // 已经排好的任务 —— 那会让同一批里前后两半的行为不一致。
    final recursive = setting('recursive');
    final maxDepth = _maxDepth;
    final options = _scanOptions;
    // 阈值同样要**在这里取好**。底下用的是 `limits` 这个 getter，它读的是
    // 活的 `_limits` —— 用户在解压途中去设置页换个档，同一批里前半个包按
    // 旧阈值、后半个按新阈值，日志上会显得同样的包有的过有的被拦。
    final limits = _limits;
    // 「解不开时问不问」同样锁定。这条尤其不能读活的：这个开关自己就会在
    // 弹窗来回的过程中被用户改（比如他想「先关掉别问了」），读到一半变了的话，
    // 同一批里会出现「问了三个、第四个开始不问了」这种没法解释的序列。
    final pauseOnError = setting('errorPause');

    _extracting = true;
    _completed = false;
    _completeDetail = '';
    _cancelRequested = false;
    _batchTotal = queue.length;
    _doneCount = 0;
    _progress = 0;
    _speed = 0;
    _eta = '--';
    _currentFile = queue.first.item.fileName;
    _entryName = '';
    _meter = ProgressMeter();
    _batchStart = DateTime.now();
    _notify();

    var failed = 0;
    var skipped = 0;

    try {
      final engine = await _ensureEngine();

      while (queue.isNotEmpty) {
        // 用户按了「停止解压」或弹窗里那颗「停止」，就到这儿为止。
        // `_disposed` 那一半是另一回事：释放之后没必要再往下跑，引擎已经没了，
        // 剩下的每个包都会以「控制器已释放」失败，白记一屏失败日志。
        if (_cancelRequested || _disposed) break;

        final task = queue.removeFirst();
        final item = task.item;
        _currentFile = item.fileName;
        _entryName = '';
        // 每个包重开一次表：包的字节计数是各自从 0 开始的，
        // 不重开的话下一个包的第一条 tick 会被当成「计数器回退」。
        _meter.reset();
        _notify();

        // 身份是**懒算**的，只有真用得上时才读文件。这个包自己的身份有两个
        // 用处，各自触发一次计算（算过就复用）：
        //
        // 1. 解**之前**跟祖先比，挡自引用。`a.zip` 里装着 `a.zip` 时，等解完
        //    再比就已经往磁盘上多写了一份真实拷贝 —— 那不是「检测到自引用」，
        //    那是已经中招了。
        // 2. 解**之后**传给子任务当祖先。没有子任务就白算了。
        //
        // 祖先集为空时第一条恒为假（空集不含任何元素），所以**顶层那批包
        // 一个字节都不用读** —— 那是绝大多数。只有嵌套包才付这份 IO。
        // 读不到文件时身份是独一无二的值，绝不会误判成自引用。
        String? identity;

        if (task.ancestors.isNotEmpty) {
          identity = await archiveIdentity(item.entryPath);
          if (isSelfReferential(identity, task.ancestors)) {
            skipped++;
            _doneCount++;
            _addLog(buildExtractLog(
              item: item,
              skippedReason: '自引用',
              now: DateTime.now(),
            ));
            showToast('${item.fileName}：与上级是同一个包，已跳过', type: 'warn');
            _notify();
            continue;
          }
        }

        // 后缀被篡改（需求 5）：先问一句再解。
        //
        // 触发条件读的是扫描时就算好的 `flags`，**不**在这里重算
        // `isExtensionSpoofed` 并重读设置：那一份是这批任务共用的快照
        // （见 `_scanOptions`），用户在解压途中去设置页关掉检测，不该让同一批
        // 里前半个包问、后半个包不问。
        //
        // 位置刻意在自引用判定**之后**：马上要被跳过的包不值得再弹一次窗。
        final askFormat = _onFormatDetect;
        if (askFormat != null &&
            item.flags.contains(ArchiveFlag.fakeExtension)) {
          final confirmed = await askFormat(FormatDetectInfo.fromItem(item));
          // **只有明确按了取消**（false）才跳过。null 是「弹窗没弹成」
          // （拿不到 context），那不是什么都没发生 —— 用户什么都没看见就把
          // 包从批次里抹掉，比多解一个包糟得多，所以按原样解。
          if (confirmed == false) {
            skipped++;
            _doneCount++;
            _addLog(buildExtractLog(
              item: item,
              skippedReason: '用户取消',
              now: DateTime.now(),
            ));
            showToast('${item.fileName}：按你的选择跳过', type: 'warn');
            _notify();
            continue;
          }
        }

        // 后缀是假的（需求 5）时要把那段假后缀剥掉，否则输出目录会跟源文件
        // 同名 —— 见 deriveOutputName 里那段说明，真机上就是这么整包失败的。
        final outDir = resolveOutputDir(
          item.entryPath,
          spoofedExtension: item.sniff.isExtensionSpoofed,
        );

        // 剩余空间只能在这层量（主 isolate）—— worker 那边够不着平台通道，
        // 所以量好随命令带过去，见 `CmdExtract.availableBytes`。
        //
        // **每个任务量一次**而不是每批一次：空间在缩，一批几百个包的时候，
        // 开头那个数到后半程早就作废了，会放行一个其实装不下的包。
        //
        // 量的是选中根目录。对称输出写回源目录旁、非对称写进
        // `<root>/_extracted/`，两者都在根之下、同一个卷，量根就够。
        //
        // 量不到（null）时 worker 会跳过这条检查 —— 不当成 0。见
        // `disk_space.dart` 里为什么这两者绝不能混。
        final availableBytes = await _diskSpace.availableBytes(_folderPath);

        try {
          final outcome = await engine.extract(
            parts: item.parts,
            outDir: outDir,
            depth: item.depth,
            recursive: recursive,
            options: options,
            limits: limits,
            availableBytes: availableBytes,
          );
          _doneCount++;
          _addLog(buildExtractLog(
            item: item,
            outcome: outcome,
            now: DateTime.now(),
          ));
          if (recursive && outcome.hasNested) {
            identity ??= await archiveIdentity(item.entryPath);
            skipped += _enqueueNested(
              queue: queue,
              outcome: outcome,
              parentIdentity: identity,
              parentAncestors: task.ancestors,
              maxDepth: maxDepth,
            );
          }
        } on EngineException catch (e) {
          failed++;
          _doneCount++;
          // 走到这里说明这个包整个没解开。一个坏包不该让整批停下 ——
          // 先如实记一条失败，再决定要不要问用户。
          _addLog(buildExtractLog(
            item: item,
            error: e,
            now: DateTime.now(),
          ));

          final breach = e.breach;
          // 弹窗真的弹出来了就不再补 toast —— 那句话用户刚在弹窗里看过。
          var shown = false;

          // 什么时候问：
          //
          // - **被闸门拦下永远问**，与 `errorPause` 无关。那是「我们主动放弃了
          //   一个其实可能解得开的包」，用户有权当场知道并决定。
          // - 普通解压失败（损坏 / 密码不匹配 / 格式不认）看 `errorPause` ——
          //   关着的时候引擎自己决断：记一条失败日志、接着解下一个，不打扰用户。
          //
          // 两档共用同一个弹窗与同一组按钮（「继续 / 停止」）。原先后者问的是
          // 「暂停 / 跳过」，走 `pauseExtract` 那道闸门、停得回来；用户明确要求
          // 去掉暂停，于是两边合并 —— 详见 `prompts.dart` 那张表。
          final ask = _onPrompt;
          if ((breach != null || pauseOnError) && ask != null) {
            final decision = await ask(
              item.fileName,
              breach?.message ?? e.message,
            );
            if (decision == ArchiveDecision.stop) {
              // 复用 `_cancelRequested`：收尾那块已经按它算 `cancelled`，
              // 于是文案换成「已中止」，而且**不消费**这批快照（见 finally）
              // —— 剩下的包还等着解，主按钮必须能再点。
              //
              // 失败的这个包本身不重试：「停止」是关于整批的，不是「留着这个
              // 包等下再试」，它已经记了一条失败日志。
              _cancelRequested = true;
              break;
            }
            // null = 弹窗没弹成（拿不到 BuildContext）。那不是用户的决定，
            // 用户什么都没看到，得补一条 toast 兜底。
            shown = decision != null;
          }
          if (!shown) {
            showToast('${item.fileName}：${e.message}', type: 'warn');
          }
        }
        _notify();
      }
    } catch (e) {
      // worker 起不来之类的整体性失败。
      failed = _batchTotal - _doneCount - skipped;
      showToast(e is EngineException ? e.message : '解压失败：$e', type: 'warn');
    } finally {
      _extracting = false;

      final cancelled = _cancelRequested;
      // 分母取**最终**的 `_batchTotal` 而不是开头那张快照：递归跑出来的
      // 嵌套包也是这一批的活儿，只算开头那 8 个的话，收尾会出现
      // 「已解 12 个 / 共 8 个」这种自相矛盾的文案。
      _completed = !cancelled && failed < _batchTotal;
      // 跑完的（无论成败）都算这份快照用掉了 —— 界面据此把主按钮换成
      // 「换个文件夹」，而不是留着「开始智能解压」等着被再点一次（见
      // [_batchRun]）。
      //
      // **中止是例外**：用户在半路按了「停止这批」，队列里剩下的包一个都
      // 没解。这时候还锁住快照，就等于把人困在「剩下的包解不了、也重跑不了」
      // 的死角里。放开它，主按钮回到「开始智能解压」。
      //
      // 代价要说清楚：重跑会把**已经解好的**再解一遍，输出目录重名时撒出
      // `_1`/`_2` 的重复目录。真正的续传要等 journal（条目 3）。
      _batchRun = !cancelled;
      final elapsed = _batchStart == null
          ? Duration.zero
          : DateTime.now().difference(_batchStart!);
      _completeDetail = _summarize(
        total: _batchTotal,
        done: _doneCount,
        failed: failed,
        skipped: skipped,
        elapsed: elapsed,
        cancelled: cancelled,
      );
      if (failed == 0 && !cancelled) {
        _progress = 1.0;
      }
      _notify();
      showToast(_completeDetail, type: failed > 0 ? 'warn' : 'ok');
      // 整批收尾 —— 逐包日志到这里全记完了，一次写出去（见 [_persistLogs]）。
      _persistLogs();
    }
  }

  /// 把刚解出来的目录里发现的嵌套包排进队列。返回**被跳过**的个数。
  ///
  /// 两道闸门，都在**入队前**拦：
  ///
  /// 1. **深度顶**（[withinDepthLimit]）：用户设的 `maxDepth` 之上还压着
  ///    一个硬顶。深度不对的直接丢掉，不进队列也不进列表 —— 一个永远不会
  ///    被解的任务挂在 UI 上只会让人困惑「为什么它一直不动」。
  /// 2. **自引用**是在**出队时**判的，不在这里：那需要算子包自己的身份，
  ///    而身份要读文件。放这里等于给每个发现的包都读一次头部，其中绝大多数
  ///    根本不是自引用，白读。出队时反正要解，那时读一次是顺手的。
  ///
  /// 入队的包同时**追加到 `_archives`/`_scanItems`**，让列表边长 —— 这是
  /// 「等长同序」那条不变量在运行期的延伸：两条列表在同一个方法里各加一条，
  /// 中间没有 await，所以不会出现只加了一边的中间态。
  int _enqueueNested({
    required Queue<_ExtractTask> queue,
    required ExtractOutcome outcome,
    required String parentIdentity,
    required Set<String> parentAncestors,
    required int maxDepth,
  }) {
    final childAncestors = {...parentAncestors, parentIdentity};
    var skipped = 0;

    for (final child in outcome.nested) {
      if (!withinDepthLimit(child.depth, maxDepth)) {
        skipped++;
        _addLog(buildExtractLog(
          item: child,
          skippedReason: '超出递归深度',
          now: DateTime.now(),
        ));
        continue;
      }
      queue.add(_ExtractTask(item: child, ancestors: childAncestors));
      _appendNested(child);
    }

    // 分母跟着长。进度条会因此回退，所以 [_onExtractTick] 里做了单调钳制。
    _batchTotal = _doneCount + queue.length;
    return skipped;
  }

  /// 把一个嵌套包追加到两条并列列表的**末尾**（保持等长同序）。
  void _appendNested(ScanItem item) {
    _scanItems.add(item);
    _archives.add(ArchiveFile(
      name: item.fileName,
      type: item.sniff.format.archiveType,
      size: formatBytes(item.sizeBytes),
      // 打上 nested 角标，与顶层那批区分开 —— 深度已经在 item 里了，
      // 列表里靠它缩进显示。
      flags: {...item.flags, ArchiveFlag.nested}.toList(),
      depth: item.depth,
    ));
  }

  /// 收尾文案，保持既有形状：`N 个压缩包 · 耗时 Xs · F 个失败`。
  ///
  /// [skipped] 只在非零时才出现，且单独成段 —— 它是「我们主动没解」，
  /// 与失败不是一回事，混在失败里会让人以为程序坏了。
  String _summarize({
    required int total,
    required int done,
    required int failed,
    required Duration elapsed,
    required bool cancelled,
    int skipped = 0,
  }) {
    final parts = <String>[
      if (cancelled) '已中止：$done/$total 个压缩包'
      else '$total 个压缩包',
      '耗时 ${formatDuration(elapsed)}',
      if (failed > 0) '$failed 个失败',
      if (skipped > 0) '$skipped 个已跳过',
    ];
    return parts.join(' · ');
  }

  /// 引擎解压进度回调。已经被控制器按 8Hz 节流过。
  void _onExtractTick(ExtractTick tick) {
    // 表只跟踪**当前这个包**，所以整批的进度是
    // 「已完成的包数 + 当前包的内部比例」÷ 总包数。
    // 直接用未压缩字节当整批分母是不行的：扫描时拿到的是**压缩后**大小，
    // 两个数不同量纲，比值会大于 1。
    _meter.update(
      doneBytes: tick.doneBytes,
      totalBytes: tick.totalBytes,
      entryName: tick.current,
      now: DateTime.now(),
    );
    final snap = _meter.snapshot();

    final inFlight =
        _batchTotal == 0 ? 0.0 : (_doneCount + snap.progress) / _batchTotal;
    // **单调**：分母会随嵌套发现而变大（见 [_enqueueNested]），原始比值
    // 因此会回退 —— 进度条倒着走比走得慢更像是坏了。所以只许前进。
    final clamped = inFlight.clamp(0.0, 1.0);
    if (clamped > _progress) _progress = clamped;
    _speed = snap.speedBytesPerSecond;
    _eta = formatEta(_meter.eta);
    _entryName = snap.entryName;
    _notify();
  }

  // ---------------------------------------------------------------------------
  // 密码库 / 日志 / 解压器
  // ---------------------------------------------------------------------------

  void addPassword(String value) {
    if (value.isEmpty) {
      showToast('请输入密码', type: 'warn');
      return;
    }
    if (_passwords.any((p) => p.value == value)) {
      showToast('密码已存在', type: 'warn');
      return;
    }
    _passwords.insert(0, PasswordEntry(value: value, lastUsed: '今天'));
    _notify();
    _persistVault();
    showToast('密码已添加到密码库', type: 'success');
  }

  void deletePassword(int index) {
    _passwords.removeAt(index);
    _notify();
    _persistVault();
    showToast('密码已删除');
  }

  void setLogFilter(LogStatus? status) {
    _logFilter = status;
    _notify();
  }

  /// 新日志进队首（最新的在最上面），并封顶。
  void _addLog(LogEntry entry) {
    _logs.insert(0, entry);
    if (_logs.length > _maxLogs) {
      _logs.removeRange(_maxLogs, _logs.length);
    }
  }

  void addExtractor(Extractor e) {
    if (_extractors.any((x) => x.name.toUpperCase() == e.name.toUpperCase())) {
      showToast('该类型已存在', type: 'warn');
      return;
    }
    _extractors.add(e);
    _notify();
    showToast('已注册 ${e.name} 解压方式', type: 'success');
  }

  void deleteExtractor(int index) {
    if (_extractors[index].isBuiltin) return;
    final name = _extractors[index].name;
    _extractors.removeAt(index);
    _notify();
    showToast('已移除 $name');
  }

  @override
  void dispose() {
    // `ChangeNotifier.dispose` 自己**不幂等**（第二次调用会断言），
    // 而重复释放的路径是真实存在的（页面 dispose + 应用级清理），所以自己守。
    if (_disposed) return;
    _disposed = true;

    // 引擎的 dispose 会把在跑的任务以异常结束，那条异常会走到
    // `_runExtractBatch` 的 catch 里记一条日志 —— 所以 `_disposed` 必须
    // **先**置位，[_notify] 才拦得住它。
    _engine?.dispose();
    _engine = null;
    super.dispose();
  }
}

/// 解压队列里的一条。
///
/// 除了一个 [ScanItem]，它还扛着**祖先身份集** —— 从根一路下来、到它的
/// 父为止，每个压缩包的身份指纹（见 cycles.dart）。自引用检测就是拿它
/// 和包自己的身份比。
///
/// 身份集随任务走而不是回查 `_scanItems`：队列里的条目一旦被消费就从
/// 队里没了，回查要靠「谁是我的父」倒推，而那个关系在 BFS 队列里并不显式
/// 存着。直接跟着任务传最省事，也最不容易错。
///
/// 共享的是**同一个不可变的 [Set]**：子任务拿到的是父的集合 ∪ 父自己，
/// 每次扩张新建一个（`{...parent, id}`），所以兄弟之间不会互相污染。
class _ExtractTask {
  const _ExtractTask({required this.item, required this.ancestors});

  final ScanItem item;

  /// 从根到**父**为止的全部祖先身份。根任务的这份是空的。
  final Set<String> ancestors;
}
