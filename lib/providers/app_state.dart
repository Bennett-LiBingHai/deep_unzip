import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';

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
import '../models/log_entry.dart';
import '../models/password_entry.dart';
import '../services/disk_space.dart';
import '../services/keep_alive.dart';
import '../services/notification_permission.dart';
import '../services/password_prompt.dart';
import '../services/prompts.dart';

/// 这批解压**最后是怎么收场的**。总结卡片的标题、配色、图标全看它。
///
/// ## 为什么是一个枚举，而不是几个 bool
///
/// 从前这里是三样东西：`completed`（= 全部成功）、`stopReason`（= 为什么停的）、
/// `batchRun`（= 跑过没有）。而界面拿 `completed` 去问「该不该出总结卡片」——
/// 于是整批都失败时它一张卡片都不出（`completed` 是 false），界面退回扫描结果
/// 那张表，像这批压根没跑过。真机验收时用户点了出来：关掉「错误时暂停」之后，
/// 失败不再弹窗、直接记一条失败接着跑，整批打完就正好落在那个洞里。
///
/// 病根是 `completed` 被当成了「这批跑完了」用，而它一直说的是「全部成功」。
/// 更早一版还漏过另一半：**部分**失败时卡片出得来，却顶着「全部解压完成」这个
/// 标题 —— 同样是假话。
///
/// 所以现在只有这一个枚举，`null` = 这份快照还没跑过（等价于旧的
/// `batchRun == false`，见 [AppState.batchRun]）。
enum BatchOutcome {
  /// 一个没失败，也没被停。
  clean,

  /// 跑完了，但有些包没解开。
  partial,

  /// 跑完了，处理过的包一个都没解开。
  allFailed,

  /// 用户按了主按钮那颗「停止解压」。
  stopped,

  /// 「解不开」弹窗里那颗「停止」。这一档**总是**伴随一次解压失败 ——
  /// 弹窗就是被那个失败引爆的。
  errored,
}

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
    KeepAlive? keepAlive,
    NotificationPermission? notifications,
    ArchivePrompt? prompt,
    FormatDetectPrompt? formatPrompt,
    PasswordPrompt? passwordPrompt,
    // 参数名与字段名（`_store`）**不止差一个下划线** —— 与上面那条同因：
    // 叫 `store` 会换来一条 Dart 根本没法照做的假警告。
    PersistStore? persistStore,
    AppSnapshot? restore,
  })  : _injectedEngine = engine,
        _diskSpace = diskSpace ?? DiskSpaceProbe(),
        _keepAlive = keepAlive ?? KeepAlive(),
        _notifications = notifications ?? NotificationPermission(),
        _onPrompt = prompt,
        _onFormatDetect = formatPrompt,
        _onPassword = passwordPrompt,
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

  /// 解压期间让系统别回收我们。同样走平台通道，同样只在主 isolate 上用。
  ///
  /// **它是尽力而为的加强，失败了不影响解压** —— 见 `services/keep_alive.dart`
  /// 开头那段。所以这里不做任何状态回读，界面也不需要知道它有没有起来。
  final KeepAlive _keepAlive;

  /// 问通知权限（Android 13+）。同样只在主 isolate 上用，同样是尽力而为 ——
  /// 拒绝了只是少一条通知，解压绝不因此被拦（见 `services/notification_permission.dart`）。
  final NotificationPermission _notifications;

  /// 上一次往通知上推进度的时间。
  ///
  /// 进度事件被控制器节流到 8Hz，而**改一条通知不是免费的**：每次 notify 都要
  /// 过一次系统通知服务，各家 ROM 上还会触发通知栏重排。8Hz 地推等于拿解压的
  /// IO 去抢一个用户根本看不清的刷新率。所以通知自己再节一层，两秒够用了 ——
  /// 它显示的是「还在动，到哪了」，不是毫秒级读数。
  DateTime? _lastKeepAliveAt;

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

  /// 密码库试不出来时问用户「停止 / 跳过 / 手动输入」（需求 2）。
  ///
  /// **为 null 时的行为等同于那颗开关关掉**：静默跳过这个包。不是「当作用户
  /// 选了跳过」——调用方分得清（见下面 [_PasswordVerdict.autoSkipped]），
  /// 日志上一个是「已按选择跳过」，一个是「密码未匹配」。
  final PasswordPrompt? _onPassword;

  // 文件夹
  bool _folderSelected = false;
  String _folderName = '';
  String _folderPath = '';
  bool get folderSelected => _folderSelected;
  String get folderName => _folderName;
  String get folderPath => _folderPath;

  /// 「输出到」那一格该显示什么。
  ///
  /// **对称输出时输出落在源所在的目录**，所以这一格说的永远是那个目录 ——
  /// 选了单个文件时 [folderName] 是**文件名**（卡片标题要它），拿它去填
  /// 「输出到」就是一句假话。
  String get outputDirName => p.basename(_folderPath);

  /// 「自定义输出目录」开着时用户选的那个根目录；空串 = 没选。
  ///
  /// **只活在内存里**：按用户的要求，根目录不落盘，每次点「开始解压」重选一遍。
  /// 所以它没有 `_persistSettings`/`_applySnapshot` 的份 —— 别顺手把它加进去。
  String _outputRoot = '';
  String get outputRoot => _outputRoot;

  /// 这个会话里**选过**的根目录。扫描时要跳过它们，否则输出会被当成下一轮的
  /// 输入（`解压 → 重扫 → 再解压` 自噬）。记一个**集合**而不是只记当前那个：
  /// 用户可能这批选 A、下批选 B，A 底下那棵树还留在磁盘上。
  ///
  /// 同样不落盘。代价是重启之后那次扫描认不出上一轮的输出 —— 已知、刻意，
  /// 是「根目录不持久化」那条要求的直接产物。
  final Set<String> _outputRootsSeen = {};

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
  /// 否则用户在设置里关掉的 `fakeExtDetect` 会在嵌套那一层悄悄复活，
  /// 表现为「设置好像不生效」。
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
  String _completeDetail = '';

  /// 这一批是怎么收场的；`null` = 这份扫描快照还没跑过。见 [BatchOutcome]。
  ///
  /// 它是**唯一**的收场标志：界面出不出总结卡片、卡片写什么标题、主按钮是
  /// 「开始解压」还是「更换目标」，全部由它派生 —— 见 [batchRun]。
  ///
  /// 从前这里是 `_completed` + `_stopReason` + `_batchRun` 三份状态，而界面
  /// 拿 `_completed`（= 全部成功）去问「该不该出卡片」，全批失败时卡片就不见了。
  /// 合成一个枚举之后，「跑过了」与「跑得怎么样」再无可能对不上。
  BatchOutcome? _outcome;

  /// 这一批处理过、**砸掉**的包数。收场判定要用（见 [BatchOutcome]）。
  int _failedCount = 0;

  /// 停止是用户按主按钮按出来的，而不是弹窗里那颗「停止」。
  ///
  /// `_cancelRequested` 两条路共用（见 [stopExtract]），收场时靠这一个 bit
  /// 把 `stopped`（「已停止」）与 `errored`（「解压出错，已停止」）分开 ——
  /// 后者总是伴随一次解压失败，标题里必须点出来。
  bool _stoppedByUser = false;

  /// 用户在弹窗里明确放掉的包数（「跳过」/ 格式弹窗的「取消」）。
  ///
  /// 与自动跳过（自引用、超出递归深度）分开数：前者是用户做的决定，写进总结
  /// 是「手动跳过 N 个」；后者是我们自己拦的。混成一句的话，用户没法知道
  /// 这批里有几个包是自己放掉的。见 [_summarize]。
  int _manualSkips = 0;

  // 解压批次（一次 startExtract 覆盖的一整批包）
  //
  // 这几个都是**批次级**而不是「当前包」级的：进度条要在整批的尺度上单调
  // 前进，而每个包的字节计数是各自从 0 开始的。
  int _batchTotal = 0;

  /// 进度条的分子分母，单位是**压缩包在磁盘上的字节数**（[ScanItem.sizeBytes]）。
  ///
  /// 用磁盘字节而不是包数：一个 1 KB 的包和一个 2 GB 的包不该各占一半进度条。
  /// 用磁盘字节而不是未压缩字节：排队中的包只知道前者，后者要开包才知道，
  /// 两者混着算量纲不一致。当前包内部的比例由 7-Zip 的未压缩计数给出，
  /// 乘上这个包的权重折算进来（见 [_recomputeProgress]）。
  ///
  /// 分母随嵌套发现而变大（见 [_enqueueNested]），进度条会**如实回退** ——
  /// 这是刻意的：只进不退的版本在「单个包里套了嵌套包」时会停在 100% 不动，
  /// 那比倒退更像坏了。
  int _bytesTotal = 0;
  int _bytesDone = 0;

  /// 正在解的那个包的权重（同 [_bytesTotal] 的单位）。
  int _currentWeight = 0;
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
  String get completeDetail => _completeDetail;

  /// 这批解压最后是怎么收场的；`null` = 这份扫描快照还没跑过。
  ///
  /// 总结卡片的标题、配色、图标全看它。**界面不该再自己去推**「算不算完成」
  /// —— 那正是上一版出错的来路（见 [BatchOutcome]）。
  BatchOutcome? get outcome => _outcome;

  /// 这批处理过、砸掉的包数。
  int get failedCount => _failedCount;

  /// 这批扫描结果已经解压过了（无论成败、包括被停掉的）。为真时主按钮应换成
  /// 「更换目标」，不能再是「开始解压」—— 一旦这批跑过，再点就等于把
  /// 同一个队列重排一遍，而输出目录重名会追加 `_1`/`_2`（见 output_paths.dart），
  /// 结果不是「重新解一遍」而是往磁盘里撒重复目录。
  ///
  /// **停止也算跑过了**（原先是例外，真机验收时改的）：停下来的那一批现在会
  /// 落在总结卡片上，卡片上写清「已完成 1/3 个压缩包」，主按钮是「更换目标」
  /// —— 那是一条明确的出路。留着「开始解压」反而像什么都没发生过，用户会
  /// 以为按下就能接着解剩下那两个，实际却是把已解过的重解一遍。
  ///
  /// 它与 [outcome] 是同一个事实的两种问法（「跑过没有」/「跑得怎么样」），
  /// 所以直接派生，不另存一个字段 —— 两份状态迟早会对不上，那正是上一版的 bug。
  bool get batchRun => _outcome != null;

  // 密码库。**空库起步** —— 之前从 mock 数据播种是为了演示观感，但那会让
  // 用户第一次打开就看到四条「别人的」密码（还带假的命中次数）。真实做法是
  // 让用户自己攒；P4 接上 `flutter_secure_storage` 后这里改成从 `vault_v1` 读。
  final List<PasswordEntry> _passwords = [];
  List<PasswordEntry> get passwords => List.unmodifiable(_passwords);

  // 日志。同样空库起步：历史应当只记录**本机真的解压过**的东西。
  final List<LogEntry> _logs = [];
  List<LogEntry> get logs => List.unmodifiable(_logs);

  /// 条数。单独开一个 getter 而不是让界面写 `logs.length` —— `logs` 每次都
  /// `List.unmodifiable` 复制一份，日志页头部每帧都要这个数，为了读个长度
  /// 把整张表复制一遍不值当。
  int get logCount => _logs.length;

  LogStatus? _logFilter;
  LogStatus? get logFilter => _logFilter;

  List<LogEntry> get filteredLogs {
    if (_logFilter == null) return _logs;
    return _logs.where((l) => l.status == _logFilter).toList();
  }

  /// 清空全部日志。**不可撤**，所以日志页那边得先弹一道确认再调这里。
  ///
  /// 空的时候直接返回：没有记录可清却弹一条「已清空 0 条」，是在拿假动作
  /// 回应真点击。
  void clearLogs() {
    final n = _logs.length;
    if (n == 0) return;
    _logs.clear();
    _persistLogs();
    // 删的是用户自己的历史，出声（`showToast` 内部会 notify）。
    showToast('已清空 $n 条日志记录');
  }

  /// 日志封顶。纯追加写、又要在退出时整份落盘，不封顶会无限长。
  ///
  /// 这个数是**权威**：`LogRepo` 只管把这里交出去的那一份原样写盘，不再自己
  /// 截一刀（它的构造函数默认顶在 `kMaxMaxLogs`，见那边的注释）。所以调小它
  /// 必须**当场**把多出来的砍掉，否则内存里那 300 条会在下一次自然边界又整份
  /// 写回去。
  int _maxLogs = kDefaultMaxLogs;
  int get maxLogs => _maxLogs;

  /// 改日志保留条数。自由输入，界外由 `coerceMaxLogs` 夹回
  /// [kMinMaxLogs]–[kMaxMaxLogs]（弹窗那边也会先拦一道，这里是第二道）。
  void setMaxLogs(int value) {
    _maxLogs = coerceMaxLogs(value);

    // 调大时 dropped 是 0，什么都不用做；调小就是**当场**丢，见 [_maxLogs] 那段。
    final dropped = _trimLogsToCap();
    _persistSettings();
    if (dropped == 0) {
      _notify();
      return;
    }
    // 丢的是用户自己的历史，不能悄无声息。走 toast 那条路（它内部会 notify）。
    _persistLogs();
    showToast('日志上限 $_maxLogs 条，已丢弃最早的 $dropped 条', type: 'warn');
  }

  /// 把 `_logs` 砍到 [_maxLogs] 以内，返回丢掉了几条。
  ///
  /// 只在**队尾**砍：最新的一条在队首，砍尾巴丢的是最早的，正是该丢的那头。
  int _trimLogsToCap() {
    if (_logs.length <= _maxLogs) return 0;
    final dropped = _logs.length - _maxLogs;
    _logs.removeRange(_maxLogs, _logs.length);
    return dropped;
  }

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

  int _maxDepth = kDefaultMaxDepth; // 0 = 不递归
  int get maxDepth => _maxDepth;

  /// 改递归深度。**`0` 就是不递归。**
  ///
  /// 2026-10 之前这里叫 `cycleMaxDepth`，在一张固定档位表 `[0,5,10,20]` 上
  /// 转圈，而 `0` 那一档的含义是「无限制」。同月两颗一起改了：档位表换成
  /// 自由输入（与日志条数同一个理由 —— 几张别人挑好的档，不如让自己填），
  /// `0` 的含义翻成「关」，那颗与它重复的「递归解压」开关删掉。
  ///
  /// 界外由 `coerceMaxDepth` 夹回 [kMinMaxDepth]–[kMaxMaxDepth]：弹窗那边
  /// 先拦一道，这里是第二道。与 [setMaxLogs] 同一个写法。
  void setMaxDepth(int value) {
    _maxDepth = coerceMaxDepth(value);
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
    _maxLogs = coerceMaxLogs(s.settings.maxLogs);
    // 档位下标收敛到合法区间；超界的归到「自定义」那档而不是 0。
    _limitPreset = s.settings.limitPreset.clamp(0, kLimitPresets.length);
    _limits = s.settings.limits;

    _passwords
      ..clear()
      ..addAll(s.vault);
    _logs
      ..clear()
      ..addAll(s.logs);
    // 磁盘上那份可能比现在的上限多（上次调小之前写的、或者被手改过）。
    // `LogRepo` 只封到 `kLogHardCeiling`，用户档位比它低，剩下的在这儿砍。
    _trimLogsToCap();
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
      maxLogs: _maxLogs,
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
    // 后台那一份只喂通知。少了这一句，锁屏期间进度条和通知**一起**冻住 ——
    // 而通知本来正是为了「用户看不见界面」才存在的。
    controller.onExtractTickBackground = _onExtractTickBackground;
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

  /// 扫描指定目录。
  ///
  /// 「选一个目录」这个动作（需要 `BuildContext`）在屏幕层 —— 自建的文件浏览器
  /// 是个页面，而这一层**不 import `package:flutter`**（要能跑在 isolate 里、
  /// 能纯单测）。所以这里只收已经选好的路径；将来的「最近使用」「用 DeepUnzip
  /// 打开」这类入口也走这里。
  Future<void> selectFolderPath(String path) async {
    final name = p.basename(path);
    await _runScan(
      sourceRoot: path,
      displayName: name.isEmpty ? path : name,
      start: (engine, options) => engine.scan(
        rootPath: path,
        options: options,
        // 跳过这个会话里选过的输出根。管子（`CmdScan.skipDirs` → scanner 的
        // `_shouldSkipDir`）一直是通的，只是从前没人传 —— 因为从前没有「用户
        // 指定的输出根」这个概念，输出一律在包旁边。
        //
        // 传一个**集合**：用户可能这批选 A、下批选 B（根目录不落盘，每次重选），
        // A 底下那棵树还在磁盘上。不跳的话下一轮扫描会把上一轮的输出当输入，
        // 解出来的东西再被解一遍 —— 那正是 `scanner.dart` 里 `kSelfOutputDirs`
        // 想防的自噬，只是那个名单只认名前缀，认不出任意路径。
        // 传一份**拷贝**：`_outputRootsSeen` 是活的可变集合，而这条命令要跨
        // isolate 边界送出去，送一个还会被就地改动的对象不是个好主意。
        skipDirs: {..._outputRootsSeen},
      ),
    );
  }

  /// 扫描**用户点名的那个文件**，不管同目录里别的文件。
  ///
  /// 两处与 [selectFolderPath] 不同，都在引擎那侧（见 `CmdScanFiles`）：
  /// 容器防线让位（用户点了一个 `.docx` 就是想要它）、分卷在同目录里自动补齐
  /// （`x.zip.001` 单独一片在解码器眼里什么都不是）。
  ///
  /// **`_folderPath` 取父目录**：它同时是自定义输出目录的镜像基准、剩余空间
  /// 探测的目标卷、「打开输出目录」的兜底。单选文件时设成父目录，这三个角色
  /// 全都仍然成立 —— 镜像时 relative 得到文件名本身、dirname 是 `.`，于是输出
  /// 落在输出根上；探测的是正确的卷；打开的是父目录。
  Future<void> selectFilePath(String path) async {
    final name = p.basename(path);
    await _runScan(
      sourceRoot: p.dirname(path),
      displayName: name.isEmpty ? path : name,
      start: (engine, options) =>
          engine.scanFiles(paths: [path], options: options),
    );
  }

  /// 两条扫描入口共用的那一段：状态迁移、取消、落结果、出错收尾。
  ///
  /// 抽出来是因为「选文件夹」与「选文件」只在**引擎那条命令**和**源根从哪来**
  /// 上不同，其余（清空上一轮、置扫描态、取消语义、失败也要记一条日志）一字
  /// 不差。复制一份的话，将来改一处必然漏另一处。
  Future<void> _runScan({
    required String sourceRoot,
    required String displayName,
    required Future<ScanOutcome> Function(EngineController, ScanOptions) start,
  }) async {
    if (_scanning) return;

    _folderPath = sourceRoot;
    _folderName = displayName;
    _folderSelected = true;
    _resetExtractState();
    _clearScanResult();
    _cancelRequested = false;
    _scanning = true;
    _scanFound = 0;
    _scanCurrent = '';
    _notify();
    showToast('正在扫描压缩包…');

    try {
      final engine = await _ensureEngine();
      // 快照下来，嵌套扫描（解压期发现的新包）要用同一份，见 [_scanOptions]。
      final options = ScanOptions(
        detectFakeExtension: setting('fakeExtDetect'),
      );
      _scanOptions = options;
      final pending = start(engine, options);
      if (_cancelRequested) {
        // 先发任务再发取消，顺序不能反：控制器的取消只作用于「正在跑的
        // 任务」（`_activeJob == null` 时直接返回），worker 也只在 runScan
        // 捕获 epoch 之后才认这个信号。两条消息走同一个端口，顺序有保证。
        unawaited(engine.cancel());
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
          badge: item.sniff.format.badge,
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
    unawaited(_engine?.cancel() ?? Future<void>.value());
  }

  /// Android 上递归读目录需要「所有文件访问权限」（API 30+）或
  /// 读写外部存储（API ≤ 29）。非 Android 直接放行。
  ///
  /// 权限被拒**不能**让应用不可用：返回 false，由调用方给一句提示。
  /// 存储权限前置。**公开**：选目录 / 选文件 / 选输出根三个动作都搬到了屏幕层
  /// （自建的文件浏览器是个页面，需要 `BuildContext`），而权限**必须在打开它
  /// 之前**拿到 —— 没有权限时那个页面列出来的每个目录都会是「读不了」，用户会
  /// 以为是浏览器坏了。
  Future<bool> ensureStoragePermission() async {
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
    _completeDetail = '';
    _outcome = null;
    _failedCount = 0;
    _stoppedByUser = false;
    _manualSkips = 0;
  }

  /// 记下这次的输出根。**不碰平台通道**，所以测试可以直接调。
  ///
  /// 同时并进 [_outputRootsSeen]，供扫描跳过（见那个字段）。
  void setOutputRoot(String path) {
    if (path.isEmpty) return;
    _outputRoot = path;
    _outputRootsSeen.add(path);
    _notify();
  }

  /// 开始把扫描到的压缩包逐个解开。
  ///
  /// 输出目录默认与源同级（`A/B/c.zip` → `A/B/c/`），重名追加 `_1`；
  /// 「自定义输出目录」开着时改成「用户选的根目录 + 源目录结构的镜像」。
  void startExtract() {
    if (_extracting) return;
    if (_archives.isEmpty) {
      showToast('请先选择目标文件或文件夹并完成扫描', type: 'warn');
      return;
    }
    // 开着自定义输出目录却没选根 = 不知道该往哪写。界面上那条路（`_onStart`）
    // 会先把选择器弹出来，走不到这儿；但这是**公开方法**，测试和其它调用点
    // 得自己站得住 —— 真让它跑下去，`_outputRoot` 是空串，输出会静默退回
    // 「解到包旁边」，与用户以为的完全相反。
    if (setting('customOutput') && _outputRoot.isEmpty) {
      showToast('请先指定输出根目录', type: 'warn');
      return;
    }
    // 这份快照已经跑过一轮了。**这道闸门是必须的，不能只靠界面上把按钮改个
    // 名字** —— 重跑不会「再解一遍」，而是把同一个队列重排一次，输出目录
    // 重名时会追加 `_1`/`_2`，等于往磁盘里撒重复目录（见 output_paths.dart）。
    // 想再来一遍就重新选一次目标，那会重新扫描，拿到的是新快照。
    if (batchRun) {
      showToast('本批已解压完成，请重新选择目标', type: 'warn');
      return;
    }
    unawaited(_runExtractBatch());
  }

  /// 停下这一批。**当前这个包会被真正打断**，不用等它解完。
  ///
  /// 之所以现在做得到：解压跑在原生侧自己的线程上，worker 只是轮询，所以
  /// `cancel()` 的信号在下一轮轮询就送到引擎，7-Zip 在下一个进度点 unwind
  /// （见 [CmdExtract] 的说明）。粒度是条目/块边界，不是字节级 —— 已解好的
  /// 完整文件都留着，写到一半的那一个由原生侧删掉，所以停下之后不会留下
  /// 一个长度不对的文件。
  ///
  /// 仍然**不是瞬间**的：7-Zip 要在下一个进度点才看得到标志，大块头的包可能
  /// 要几百毫秒。所以按钮文案是「停止解压」而不是「已停止」。
  ///
  /// **停下就是停下，没有「继续」。** 剩下没解的包直接丢掉，用户想接着来
  /// 只能重新选文件夹（那会重新扫描，拿到一份新快照）。原先这里是一对
  /// `pauseExtract`/`resumeExtract`，暂停闸门让队列原封不动地等着；用户
  /// 明确要求「不需要暂停，要么继续、要么停止」，于是收敛成这一条不可恢复
  /// 的停止 —— 与弹窗里那颗「停止」走的是同一条路（都是 `_cancelRequested`）。
  ///
  /// 那颗按钮按下去时会走的另一条路是 [cancelScan]（正在扫的时候），两者
  /// 共用 `_cancelRequested` 这一个位。
  void stopExtract() {
    if (!_extracting || _cancelRequested) return;
    _cancelRequested = true;
    _stoppedByUser = true;
    // **真的要引擎停**，不能只置标志 —— 从前这里只置标志是因为引擎收不到，
    // 而现在收得到（见上面那段）。没起来时是空操作，与 [cancelScan] 同一个写法。
    unawaited(_engine?.cancel() ?? Future<void>.value());
    _notify();
    showToast('正在停止当前压缩包…');
  }

  // ---------------------------------------------------------------------------
  // 密码（需求 2）
  // ---------------------------------------------------------------------------

  /// 本次解压里已经**用成功过**的密码，最近成功的在最前面。
  ///
  /// 「一批里有一个包能被某个密码打开，同一批的其它包大概率也是它」—— 同一次
  /// 备份切出来的一组包、同一个来源的压缩包，基本都是。有了它，这批里剩下的包
  /// 不必再从头把密码库撸一遍。
  ///
  /// **只活在内存里，每批开始清空**（见 `_runExtractBatch` 那段重置）。不落盘
  /// 有两个理由：一是计划里那条「该目录上次成功的密码优先」要 journal，等
  /// `JournalRepo` 落地再谈持久化；二是密码多存一份就多一处要守的东西，而密码库
  /// 本身已经在 `flutter_secure_storage` 里了。真要跨批，把 `.clear()` 挪出
  /// `_runExtractBatch` 即可 —— 但那样「上礼拜试出来过的一个密码」会排到所有
  /// 候选前面去，先试错一次的成本就从「这批」变成「一直」。
  ///
  /// 手输的密码**同样记**：那是用户刚亲手证明能用的，比库里任何一条都更该被优先
  /// 试。空密码那次不记 —— 它回答的是「这个包压根不要密码」，而且那一次本来就
  /// 排在全部候选前面。
  ///
  /// 这份记忆**不跟着密码库走**：用户中途把某条从库里删掉，这批里剩下的包还是会
  /// 先试它。这是刻意的 —— 它是这批里**试出来过**的，不是库里的。
  final List<String> _runGoodPasswords = [];

  /// 按顺序该试哪些密码。
  ///
  /// 两层：**本次解压命中过的**在最前（见 [_runGoodPasswords]），后面才是密码库
  /// 按 `hitCount` 排出来的。第一层为空时它什么也不占。
  ///
  /// 排的是**视图**不是 `_passwords` 本身：密码库页面按插入序渲染（最新加的
  /// 在最上面），在这里就地排序会让页面上的条目自己跳来跳去。
  ///
  /// 库那一层的排序键只有 `hitCount` 一个，并列时按插入序。计划里还写了
  /// 「该目录上次成功的密码优先」和「`lastUsed` 降序」——前者要 journal
  /// （`JournalRepo` 还没做），后者不行：`lastUsed` 是**已经格式化好的展示串**
  /// （「今天 14:32」这种），拿它排序等于拿一句文案当时间戳用，换个格式就全错。
  /// 少这两条不影响正确性，只影响第一次命中的快慢。
  List<String> _vaultCandidates() {
    final order = List<int>.generate(_passwords.length, (i) => i);
    // 并列时回落到下标升序 —— `List.sort` **不保证稳定**，而「同分的密码每次
    // 试的顺序不一样」会让问题没法复现。
    order.sort((a, b) {
      final byHits = _passwords[b].hitCount.compareTo(_passwords[a].hitCount);
      return byHits != 0 ? byHits : a.compareTo(b);
    });
    // 命中过的不再从库里排一遍：同一个候选试两次不是错，只是白跑一趟解压。
    return [
      ..._runGoodPasswords,
      for (final i in order)
        if (!_runGoodPasswords.contains(_passwords[i].value))
          _passwords[i].value,
    ];
  }

  /// 记下本次解压里用成功过的密码，挪到最前面。见 [_runGoodPasswords]。
  void _rememberGoodPassword(String value) {
    _runGoodPasswords
      ..remove(value)
      ..insert(0, value);
  }

  /// 密码验证通过之后把它存进密码库，由设置页的「手输密码存入密码库」决定
  /// 开不开（[kDefaultToggles] 里叫 `pwdAutoSave`，默认开）。
  ///
  /// 调它的地方只有 `attempt` 成功那一刻 —— 与 [_rememberGoodPassword] 同一个
  /// 挂点、同一个理由。两条路看起来只关心手输，但挂在那里同时也覆盖密码库命中
  /// 那一支：那种情况下这条**必然**在库里，于是原地空转（下面那个 dedupe），
  /// 行为与不挂一模一样。真在调用点上按「是不是手输」分叉反而要多写两个 return
  /// 点，还要各自判断一次。
  ///
  /// **静静地跳过，不弹「密码已存在」**：密码库自己命中的那些包不该每命中一次
  /// 就冒一句。进库了才出 toast，而且用的是与 `addPassword` 不同的文案
  /// （「已存入」不是「已添加」）—— 用户没点过任何按钮，日志和提示里得看得出
  /// 这是自动的。
  ///
  /// 开关读的是**活值**：用户解压途中去设置页关掉它，这一批剩下的包就不再入库
  /// 了。与 `pwdPrompt` 同一条（那颗也是就地读的），而不是像 `errorPause` 那样
  /// 在批次开始时锁定 —— 它管的是「下一个包怎么办」，用户改完立刻生效才符合直觉。
  void _maybeAutoImportPassword(String value) {
    if (value.isEmpty) return;
    if (!setting('pwdAutoSave')) return;
    if (_passwords.any((p) => p.value == value)) return;
    // `hitCount: 1` 不是笔误：它刚刚**真的**解开了一个包。从 0 开始记等于把
    // 这份证据丢掉，而库里的排序正是按命中数来的。
    _passwords.insert(
      0,
      PasswordEntry(value: value, hitCount: 1, lastUsed: '今天'),
    );
    _notify();
    _persistVault();
    showToast('密码已存入密码库', type: 'success');
  }

  /// 记一次命中：用过的密码往前排，下次先试它。
  void _markVaultHit(String value) {
    final i = _passwords.indexWhere((p) => p.value == value);
    // 找不到说明这一趟里用户把密码删了（弹窗开着的时候）。不是错，忽略即可
    // —— 不能因此崩在 `removeAt(-1)` 上。
    if (i < 0) return;
    _passwords[i] =
        _passwords[i].copyWith(hitCount: _passwords[i].hitCount + 1, lastUsed: '今天');
    _persistVault();
  }

  /// 解开这个包，带密码的那部分。
  ///
  /// 顺序是：**先空密码试一次** → 候选逐个试（本次解压命中过的在最前，然后才是
  /// 密码库按 `hitCount` 排的，见 [_vaultCandidates]）→ 还不行就问用户（或者按
  /// 设置直接跳过）。空密码那一次不是浪费：它回答的是「这个包到底要不要密码」。
  /// 只有它以 `DUZ_ERR_PASSWORD` 失败，后面那一串才有必要跑。头加密的包在这里
  /// 一个字节都写不出来（`duz_open` 就失败了），条目加密的包会写出前半段明文
  /// 条目再撞上第一个加密条目 —— 那点重复写有代价，但换来的是不必给 C++ 加
  /// 探测接口（见 `password_prompt.dart` 里 `verify` 那段）。
  ///
  /// 非密码类的失败（包坏了、被闸门拦下）**立刻原样抛出**，绝不接着试密码
  /// —— 换十个密码也修不好一个 CRC 坏掉的包，而密码库长得有几十条时，那种
  /// 「每个坏包都要白试几十遍」会变成肉眼可见的卡顿。
  /// 返回值里除了结局还带着**密码的来源**，供日志记「密码库 / 手输密码」
  /// 用 —— 那件事只有这条路上知道，而且用户正是靠它回头去密码库找是哪一条。
  Future<_PwdUnlocked> _extractResolvingPassword({
    required ScanItem item,
    required String outDir,
    required int depth,
    required bool recursive,
    required ScanOptions options,
    required LimitThresholds limits,
    required int? availableBytes,
    required EngineController engine,
  }) async {
    Future<_PwdAttempt> attempt(String? password) async {
      try {
        final outcome = await engine.extract(
          parts: item.parts,
          outDir: outDir,
          // `null` 在这里必须换成空串 —— 见 [_kEmptyPassword]。
          password: password ?? _kEmptyPassword,
          depth: depth,
          recursive: recursive,
          options: options,
          limits: limits,
          availableBytes: availableBytes,
        );
        // **被中止的解压绝不是「成功」，必须变成异常再往外走。**
        //
        // 这条不能省成「把 outcome 原样返回上去、上层看 `cancelled`」：上面那段
        // `verify` 闭包把「拿到 outcome」直接当成「这个密码是对的」，而试密码
        // 本身就是一次 `engine.extract`（`duz_verify_password` 仍是
        // UNSUPPORTED）。返回值式取消走到那里，弹窗会认定「这个密码对」并记
        // 一次密码库命中 —— **静默假绿**。
        //
        // 抛异常之后它穿过本函数的六个成功出口自动传播，一处都不用逐个改；
        // 又因为 `ExtractCancelled` 刻意不继承 [EngineException]，下面那条
        // `on EngineException` 和 `verify` 里的 `outcome == null` 都接不住它。
        //
        // 位置也很要紧：**必须在下面那段「成功即记」之前** —— 一次被中止的
        // 解压什么都没验证，不该往密码库里塞东西。
        if (outcome.cancelled) throw const ExtractCancelled();

        // 成功即记 —— 这里是**唯一**知道「哪个密码真的管用」的地方：密码库
        // 命中、手输验过、手输兜底重试三条路都从这儿过，所以挂一次就全盖住了。
        // 空密码那次不记（它回答的是「压根不要密码」，而它本来就排在全部候选
        // 前面）。两件事都见各自的说明：
        if (password != null && password.isNotEmpty) {
          // 1. 本次解压的候选记忆（[_runGoodPasswords]）
          _rememberGoodPassword(password);
          // 2. 存进密码库（[_maybeAutoImportPassword]，认设置页那颗开关）
          _maybeAutoImportPassword(password);
        }
        return _PwdAttempt.done(outcome);
      } on EngineException catch (e) {
        return _PwdAttempt.failed(e);
      }
    }

    var first = await attempt(null);
    // 开局那一次带的是**空密码**，所以它就成了说明这个包压根不用密码 ——
    // 来源记 `null`，日志上不该出现「密码库」这种没发生过的事。
    if (first.outcome != null) return _PwdUnlocked(first.outcome!);
    if (!first.isPasswordError) throw first.error!;

    final candidates = _vaultCandidates();
    // 只记**个数**，不记那些密码本身：弹窗只需要知道「试过几条」来区分
    // 「空库」和「试了 N 条都没通过」，而它的内容一个都不摆（见
    // `PasswordAsk.triedCount`）。攒一串明文再交给控件层是白给的暴露面。
    var triedCount = 0;
    for (final cand in candidates) {
      final r = await attempt(cand);
      if (r.outcome != null) {
        _markVaultHit(cand);
        return _PwdUnlocked(r.outcome!, PasswordSource.vault);
      }
      // 试到一半包彻底坏了：这时候报的是「坏」而不是「密码没对上」，
      // 否则日志会指着一个修不好的包说「密码未匹配」，用户回去翻密码库。
      if (!r.isPasswordError) throw r.error!;
      triedCount++;
    }

    // 密码库用光了。开关连着的那一档是「问用户」，关掉那一档是「跳过」。
    //
    // 两档的**判据是那颗开关，不是「拿不拿得到弹窗」** —— 后者是把两种完全
    // 不同的处境混成一种：用户明确说了「别问，跳过」，和用户说了「问一句」
    // 而这一问没问成（没接桥、这一刻没有 `BuildContext`）。后一种里用户什么
    // 都没看到，包却没了 —— 与 `prompts.dart` 反复警告的「把没弹当成用户的
    // 选择」是同一个坑。所以没弹成时按**失败**记，让日志和 toast 把话说出来。
    if (!setting('pwdPrompt')) {
      // 带上 `uncertain`：静默跳过时那句 reason 是用户唯一能看到的说法，
      // 而这个包说不说得清是**包的属性**，与「问不问」这颗开关无关。
      //
      // 取值只能来自 `first`（开局那次空密码）：它是这个包第一次露底，也是
      // 唯一「没带任何候选密码、纯看这个包本身」的一次尝试。后面每一次
      // 失败都掺了「我们给错了密码」这个变量，不该拿它们的说法覆盖它。
      throw _PasswordVerdict(
        _PwdOutcomeEnum.autoSkipped,
        uncertain: first.error?.uncertain ?? false,
      );
    }
    final ask = _onPassword;
    if (ask == null) throw first.error!;

    // 手输那一支的结果从这个闭包取。`verify` 的定义就是「拿它真解一遍」，
    // 所以 true 的那一刻 outcome 一定在（见 `password_prompt.dart`）。
    ExtractOutcome? manualOutcome;
    final resolution = await ask(PasswordAsk(
      fileName: item.fileName,
      triedCount: triedCount,
      // 同 `autoSkipped`：说法来自 `first`，且**不影响路由** —— 有它没它都
      // 照样去密码库试、照样弹这个窗，弹窗只是别替用户在「密码错」上拍板。
      uncertain: first.error?.uncertain ?? false,
      verify: (cand) async {
        final r = await attempt(cand);
        if (r.outcome == null) return false;
        manualOutcome = r.outcome;
        return true;
      },
    ));

    switch (resolution?.verdict) {
      case PasswordVerdict.manual:
        // 兜底那一句：正常情况下 `manualOutcome` 必定在（弹窗验过了才回
        // manual）。真要是空着（比如桥接层被改坏、弹窗没验就回了 manual），
        // 宁可拿那个密码多解一遍，也不能把「解完了但没记日志」这种状态留下来
        // —— 那会变成一条凭空消失的包。
        final settled = manualOutcome;
        if (settled != null) return _PwdUnlocked(settled, PasswordSource.manual);
        final retry = await attempt(resolution?.password);
        if (retry.outcome != null) {
          return _PwdUnlocked(retry.outcome!, PasswordSource.manual);
        }
        throw retry.error!;
      case PasswordVerdict.skip:
        throw const _PasswordVerdict(_PwdOutcomeEnum.userSkipped);
      case PasswordVerdict.stop:
        throw const _PasswordVerdict(_PwdOutcomeEnum.userStopped);
      case null:
        // **没弹成**（拿不到 BuildContext）。不是用户的选择，所以不能当跳过：
        // 用户什么都没看见，包却没了。按失败记，与没有这个特性时一致。
        throw first.error!;
    }
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
    // 设置在批次开始时锁定。跑的过程中用户去设置页改开关不该影响这一批
    // 已经排好的任务 —— 那会让同一批里前后两半的行为不一致。
    //
    // 递归与深度现在是**同一个开关**：深度 0 就是不递归（那颗「递归解压」
    // 开关 2026-10 删掉了，见 `setMaxDepth`）。`recursive` 这个参数在这一层
    // 的意思是「让引擎顺手扫一下刚解出来的东西里有没有包」—— 深度为 0 时
    // 那些包一个都用不上，扫一遍再全丢掉是白付的 IO，所以它跟着深度走。
    final maxDepth = _maxDepth;
    final recursive = maxDepth > 0;

    // 输出根同样锁定成局部量。用户在设置页关掉「自定义输出目录」、或者（在
    // 别的入口上）重选一个根，都不该让**这一批**的后半个包换个地方落盘 ——
    // 一批东西被劈成两处，日志上没法解释。
    //
    // 空串 = 老规矩（解到包旁边）。这也是**没开自定义时唯一的取值**，所以
    // 下面不需要再查那开关一次。
    final outputRoot = _outputRoot;
    final sourceRoot = _folderPath;

    // **顶层的包也要过这道闸门**（2026-10 补的）。
    //
    // 以前这里是无条件把 `_scanItems` 全排进队列的，理由是「被选目录里的
    // 东西都是输入」。**那条理由是错的**：深度数的是「从被选目录往下走了
    // 几步」，而走到 `子目录/` 里已经是**一步**了 —— 不管那一步是进子目录
    // 还是解压出来的，都算一层。所以 `maxDepth = 0` 时，躺在子目录里的包
    // 与躺在深处的嵌套包一样，都不该解。
    //
    // 不这么改的话，两条路会互相矛盾：`maxDepth = 0` 拦得住包**里面**的
    // 嵌套包，却拦不住**目录里面**的包 —— 而按上面那条规则，后者离被选
    // 目录更远。
    //
    // 拦下的不进队列，但**仍然留在列表里**（它们是扫描结果，用户要看得见
    // 目录里有什么），只记一条「超出递归深度」，与 `_enqueueNested` 那边
    // 的处理一致。
    final queue = Queue<_ExtractTask>();
    final tooDeep = <ScanItem>[];
    for (final item in _scanItems) {
      if (!withinDepthLimit(item.depth, maxDepth)) {
        tooDeep.add(item);
        continue;
      }
      queue.add(_ExtractTask(
        item: item,
        ancestors: const {},
        // 自定义输出目录：把包在源目录下的相对位置搬到用户选的根底下。
        // 只有顶层任务要算 —— 嵌套任务的父包已经落在镜像位置上了，见
        // `_ExtractTask.outputBaseDir` 那段。
        outputBaseDir: outputRoot.isEmpty
            ? null
            : mirroredBaseDir(sourceRoot, item.entryPath, outputRoot),
      ));
    }

    // **整批一个都排不进来**。这条要单独走：底下 `_currentFile =
    // queue.first.item.fileName` 会在空队列上直接抛，而且此时什么都没做，
    // 不该算「这批跑过了」（`batchRun` 由 `_outcome` 派生，这里不设它就
    // 自动是 false）—— 用户把深度调大之后要能原地点「开始解压」再来一次。
    if (queue.isEmpty) {
      for (final item in tooDeep) {
        _addLog(buildExtractLog(
          item: item,
          skippedReason: '超出递归深度',
          now: DateTime.now(),
        ));
      }
      if (tooDeep.isNotEmpty) {
        _persistLogs();
        showToast(
          '${tooDeep.length} 个压缩包超出「最大递归深度」$maxDepth，请调大后重试',
          type: 'warn',
        );
      }
      return;
    }

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
    _completeDetail = '';
    _outcome = null;
    _failedCount = 0;
    _stoppedByUser = false;
    _manualSkips = 0;
    _cancelRequested = false;
    // 上一批试出来过的密码不带过来 —— 那是**本次解压**的记忆，见
    // [_runGoodPasswords]。
    _runGoodPasswords.clear();
    _batchTotal = queue.length;
    _bytesTotal = queue.fold(0, (sum, t) => sum + _weightOf(t.item));
    _bytesDone = 0;
    _currentWeight = 0;
    _doneCount = 0;
    _progress = 0;
    _speed = 0;
    _depth = 0;
    _eta = '--';
    _currentFile = queue.first.item.fileName;
    _entryName = '';
    _meter = ProgressMeter();
    _batchStart = DateTime.now();
    _notify();

    var failed = 0;
    // 顶层就被深度拦下的那些，与嵌套里被拦下的一样计入 `skipped` —— 两边
    // 在日志与总结卡片上要长得一样，用户不必去分辨是「哪一层」拦的。
    // （它们不进 `_batchTotal`：那份分母是「这一批要处理的包」，而它们是
    // 压根没轮到处理的。）
    var skipped = tooDeep.length;
    for (final item in tooDeep) {
      _addLog(buildExtractLog(
        item: item,
        skippedReason: '超出递归深度',
        now: DateTime.now(),
      ));
    }

    try {
      // **第一件事就起前台服务**，排在 `_ensureEngine` 前面：起引擎可能要拉起
      // 原生库，而「这一批开始了」这句话对系统越早说越好。晚一步的窗口里正好
      // 锁屏，那一批就是裸奔的。
      //
      // 放在 `try` 里面而不是前面：万一它抛了（它自己吞掉了平台异常，这里防的是
      // 别的意外），`finally` 里的 stop 才能兜住 —— 起了没人停的前台服务会留下
      // 一条撤不掉的常驻通知。
      _lastKeepAliveAt = DateTime.now();
      await _keepAlive.start(title: '正在解压', text: _keepAliveText());

      // 第一次「开始解压」时问一次通知权限（Android 13+）。
      //
      // **排在起服务之后、而且不 await。** 起前台服务是这一批最不能拖的一步：
      // 晚一步的那个窗口里正好锁屏，这一批就是裸奔的。把服务吊在一次用户交互
      // 后面，等于把那个窗口敞开到无限长 —— 弹窗没人答的时候活儿压根还没开始
      // 跑，那比裸奔更糟：什么都没发生，而用户以为在解压。
      //
      // 代价是权限往往在 `startForeground` 之后才落地，Android 13+ 会把这条
      // 通知先压住（记录在服务上、通知栏里没有）。这里**不为那一段加特判**：
      // 解压期间每两秒就有一条进度要推（见 [_lastKeepAliveAt]），权限一落地，
      // 最多两秒后的那一条就该把它顶出来。短到跑不完两秒的那一批不需要通知：
      // 用户正盯着屏幕。
      //
      // **待真机确认**：一条已经被压住的常驻通知，后来重新 `notify` 能不能让
      // 它显形。不能的话，就得在授权之后再 `startForeground` 一次（这条路要
      // 等真机上那条通知到底出不出现才敢加）。
      unawaited(_notifications.ensureAsked());

      final engine = await _ensureEngine();

      while (queue.isNotEmpty) {
        // 用户按了「停止解压」或弹窗里那颗「停止」，就到这儿为止。
        // `_disposed` 那一半是另一回事：释放之后没必要再往下跑，引擎已经没了，
        // 剩下的每个包都会以「控制器已释放」失败，白记一屏失败日志。
        if (_cancelRequested || _disposed) break;

        final task = queue.removeFirst();
        final item = task.item;
        // 上一个包（无论成败跳过）已经处理完，它的权重整个算进分子。
        _bytesDone += _currentWeight;
        _currentWeight = _weightOf(item);
        _currentFile = item.fileName;
        _entryName = '';
        _depth = item.depth;
        // 剩余时间是**这个包**的：上一个包的那个数到这里已经作废。
        _eta = '--';
        // 每个包重开一次表：包的字节计数是各自从 0 开始的，
        // 不重开的话下一个包的第一条 tick 会被当成「计数器回退」。
        _meter.reset();
        _recomputeProgress(0);
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
            showToast('${item.fileName}：与上层压缩包相同，已跳过', type: 'warn');
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
            _manualSkips++;
            _doneCount++;
            _addLog(buildExtractLog(
              item: item,
              skippedReason: '用户取消',
              now: DateTime.now(),
            ));
            showToast('${item.fileName}：已按选择跳过', type: 'warn');
            _notify();
            continue;
          }
        }

        // 后缀是假的（需求 5）时要把那段假后缀剥掉，否则输出目录会跟源文件
        // 同名 —— 见 deriveOutputName 里那段说明，真机上就是这么整包失败的。
        //
        // `baseDir` 为空 = 老规矩「写在包自己旁边」；自定义输出目录时由
        // `_ExtractTask.outputBaseDir` 给出用户根下的那个位置。
        final outDir = resolveOutputDir(
          item.entryPath,
          spoofedExtension: item.sniff.isExtensionSpoofed,
          baseDir: task.outputBaseDir,
        );

        // 剩余空间只能在这层量（主 isolate）—— worker 那边够不着平台通道，
        // 所以量好随命令带过去，见 `CmdExtract.availableBytes`。
        //
        // **每个任务量一次**而不是每批一次：空间在缩，一批几百个包的时候，
        // 开头那个数到后半程早就作废了，会放行一个其实装不下的包。
        //
        // 量的是**这一批真正要写进去的那个卷**：自定义输出目录时是用户选的
        // 根，否则是源目录（输出跟在包旁边）。从前这里写死 `_folderPath`，
        // 那时两者恒等；现在不等于了，量错卷等于没量。
        //
        // 量不到（null）时 worker 会跳过这条检查 —— 不当成 0。见
        // `disk_space.dart` 里为什么这两者绝不能混。
        final availableBytes = await _diskSpace.availableBytes(
          outputRoot.isEmpty ? sourceRoot : outputRoot,
        );

        try {
          final unlocked = await _extractResolvingPassword(
            engine: engine,
            item: item,
            outDir: outDir,
            depth: item.depth,
            recursive: recursive,
            options: options,
            limits: limits,
            availableBytes: availableBytes,
          );
          final outcome = unlocked.outcome;
          _doneCount++;
          _addLog(buildExtractLog(
            item: item,
            outcome: outcome,
            // 密码是从哪来的。没用到密码就是 null，那一格不出标签。
            passwordSource: unlocked.source,
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
        } on ExtractCancelled {
          // 用户按了「停止」，**当前这个包被真的打断了**（不是等它解完）。
          //
          // 它既不是失败、也不算完成：
          //   - 不计 `_doneCount` —— 那个数在界面上是「已完成 N 个」，而它只在
          //     磁盘上留了半棵树，算完成是句假话；
          //   - 不 `failed++` —— 这是我们照着用户的命令办的，不是程序坏了。
          //
          // 日志如实记一条「用户停止」，让用户回头能看出这批断在哪里。
          _addLog(buildExtractLog(
            item: item,
            skippedReason: '用户停止',
            now: DateTime.now(),
          ));
          // 防御性置位：正常情况下它早就为真了（取消是从 [stopExtract] /
          // `cancelScan` 那条路来的），但**收场性质完全由它派生** —— 万一有一
          // 条路没置位，这里不补的话，一批被打断的解压会显示成「全部完成」。
          _cancelRequested = true;
          break;
        } on _PasswordVerdict catch (v) {
          // 密码这条路走完之后的三种非成功收场。**走异常而不走返回值**，是为了
          // 让下面那段 `on EngineException catch`（坏包、闸门、弹窗问跳过/停止）
          // 原样不动 —— 成功仍是返回值，失败仍是异常，这里只是把「密码没解开」
          // 也归到失败那条路上。
          _doneCount++;
          switch (v.kind) {
            case _PwdOutcomeEnum.autoSkipped:
              // 开关关掉（或压根没接弹窗桥）：试过密码库、跳过这个包。
              // 记**跳过**而不是失败 —— 我们确实没解开它，但这是照着「不问
              // 用户」这个设置办的，不是程序坏了。
              skipped++;
              _addLog(buildExtractLog(
                item: item,
                // 与解压失败那条走**同一个** `passwordTag`，两处措辞不会
                // 各改一半（见那边的注释）。
                skippedReason: passwordTag(uncertain: v.uncertain),
                now: DateTime.now(),
              ));
              // 说不清的时候不能只说「需要密码」—— 那是在用户唯一能看到的那行
              // 字上替他把「就是密码的事」拍板了，而这正是本轮要改掉的事。
              showToast(
                v.uncertain
                    ? '${item.fileName}：可能密码错误或文件损坏，已跳过'
                    : '${item.fileName}：需要密码，已跳过',
                type: 'warn',
              );
            case _PwdOutcomeEnum.userSkipped:
              skipped++;
              _manualSkips++;
              _addLog(buildExtractLog(
                item: item,
                skippedReason: '用户跳过',
                now: DateTime.now(),
              ));
              showToast('${item.fileName}：已按选择跳过', type: 'warn');
            case _PwdOutcomeEnum.userStopped:
              // 与 `ErrorModal` 那颗「停止」同一条路：复用 `_cancelRequested`，
              // 收尾那块据此把卡片换成「解压出错，已停止」（见 `BatchOutcome`）。
              failed++;
              _cancelRequested = true;
          }
        } on EngineException catch (e) {
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
          // 两档共用同一个弹窗与同一组按钮（「跳过 / 停止」）。原先后者问的是
          // 「暂停 / 跳过」，走 `pauseExtract` 那道闸门、停得回来；用户明确要求
          // 去掉暂停，于是两边合并 —— 详见 `prompts.dart` 那张表。
          final ask = _onPrompt;
          if ((breach != null || pauseOnError) && ask != null) {
            final decision = await ask(
              item.fileName,
              breach?.message ?? e.message,
            );
            if (decision == ArchiveDecision.stop) {
              // 复用 `_cancelRequested`：收尾那块按它认「这一批被停过」，
              // 总结卡片据此换成「解压出错，已停止」而不是「全部解压完成」。
              // `_stoppedByUser` **不置位** —— 这一档是弹窗里按的，标题要
              // 把那句「解压出错」写出来（见 [BatchOutcome]）。
              //
              // 失败的这个包本身不重试：「停止」是关于整批的，不是「留着这个
              // 包等下再试」，它已经记了一条失败日志。
              _cancelRequested = true;
              failed++;
              break;
            }
            // null = 弹窗没弹成（拿不到 BuildContext）。那不是用户的决定，
            // 用户什么都没看到，得补一条 toast 兜底。
            shown = decision != null;
            if (decision == ArchiveDecision.skip) {
              // 用户明确说了「跳过这个包」，那它记**跳过**而不是失败 ——
              // 总结里的「1 个失败」读起来像程序坏了，而这里只是我们照用户的
              // 决定办事。分成两个数，卡片才说得清这批到底怎么了。
              _manualSkips++;
            } else {
              failed++;
            }
          } else {
            failed++;
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
      _failedCount = failed;
      // 一次定下收场性质。**每一批跑完都落在总结卡片上**，没有例外 ——
      // 被停掉的那批（真机验收时用户点出来的）、整批都失败的那批（关掉
      // 「错误时暂停」之后失败不再弹窗，全败变得很容易撞上），一样出卡片。
      // 界面上再没有「这批好像压根没跑过」这个状态（见 [BatchOutcome]）。
      _outcome = _outcomeOf(
        cancelled: cancelled,
        failed: failed,
        done: _doneCount,
      );
      // `batchRun` 由 `_outcome` 派生，所以「跑过了」这件事到这里自动成立：
      // 主按钮换成「更换目标」（见 [batchRun]）。停掉之后想接着解剩下那几个，
      // 就重新选一次目录 —— 那会重新扫描、拿到一份新快照。
      //
      // 代价说清楚：重新选目录会把**已经解好的**再解一遍，输出目录重名时撒出
      // `_1`/`_2` 的重复目录。真正的续传要等 journal（条目 3）。
      final elapsed = _batchStart == null
          ? Duration.zero
          : DateTime.now().difference(_batchStart!);
      _completeDetail = _summarize(
        total: _batchTotal,
        done: _doneCount,
        failed: failed,
        skipped: skipped,
        manualSkips: _manualSkips,
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

      // 撤前台服务。**放在 `finally` 的最后**，因为这里有三条路都会走到：
      // 正常跑完、用户中止（`_cancelRequested`）、以及半路抛异常。
      //
      // 少了这一句的后果不是「多一条通知」那么轻：那条通知是 `setOngoing(true)`
      // 的，用户**划不掉**它 —— 只能看着一条写着「正在解压」的假通知，直到
      // 手动来杀进程。所以这里宁可放在 toast 之后、日志落盘之后，也不能提前
      // return 跳过它。
      await _keepAlive.stop();
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
      _bytesTotal += _weightOf(child);
    }

    // 分母跟着长，进度条会因此如实回退（见 [_bytesTotal]）。
    _batchTotal = _doneCount + queue.length;
    return skipped;
  }

  /// 把一个嵌套包追加到两条并列列表的**末尾**（保持等长同序）。
  void _appendNested(ScanItem item) {
    _scanItems.add(item);
    _archives.add(ArchiveFile(
      name: item.fileName,
      type: item.sniff.format.archiveType,
      badge: item.sniff.format.badge,
      size: formatBytes(item.sizeBytes),
      // 打上 nested 角标，与顶层那批区分开 —— 深度已经在 item 里了，
      // 列表里靠它缩进显示。
      flags: {...item.flags, ArchiveFlag.nested}.toList(),
      depth: item.depth,
    ));
  }

  /// 给这一批定收场性质。**唯一的判据来源** —— 界面不再自己推。
  ///
  /// [done] 是处理过的包数（成 / 败 / 跳过都算）。用**它**而不是 `_batchTotal`
  /// 当「全败」的分母：被停掉的那批 `done` 可能远小于 `total`，而递归跑出来的
  /// 嵌套包又会让它变大。判「处理过的里面有没有一个活的」，[done] 才是那个分母。
  ///
  /// 跳过不算失败：用户自己在弹窗上放掉的包（`_manualSkips`）和程序拦下的
  /// （自引用、超深）都不该让这一批显示成「全部失败」。
  BatchOutcome _outcomeOf({
    required bool cancelled,
    required int failed,
    required int done,
  }) {
    if (cancelled) {
      // 两条路的差别只在标题：主按钮那颗是「已停止」，弹窗那颗是
      // 「解压出错，已停止」—— 后者总是伴随一次失败，瞒着不说等于骗人。
      return _stoppedByUser ? BatchOutcome.stopped : BatchOutcome.errored;
    }
    if (failed == 0) return BatchOutcome.clean;
    return failed >= done ? BatchOutcome.allFailed : BatchOutcome.partial;
  }

  /// 收尾文案：`N 个压缩包 · 耗时 Xs [· F 个失败] [· 手动跳过 N 个] [· N 个自动跳过]`。
  ///
  /// 被停掉的那批第一段换成 `已完成 N/M 个压缩包` —— 停下来的时候「还剩几个
  /// 没动」本身就是用户最想知道的那个数，只说「共 3 个包」等于没说。
  ///
  /// [skipped] 是**总数**，[manualSkips] 是其中用户自己放掉的；两者之差就是
  /// 我们拦下的（自引用、超出递归深度）。分开列而不是合并成「N 个已跳过」：
  /// 用户按过「跳过」的包和程序不认识的包，对他来说完全是两件事。
  ///
  /// [done] 是**处理过的包数**（成 / 败 / 跳过都算），所以真正解开的个数是
  /// 它减掉失败与跳过 —— 别拿 [done] 当「成功数」用。
  String _summarize({
    required int total,
    required int done,
    required int failed,
    required Duration elapsed,
    required bool cancelled,
    int skipped = 0,
    int manualSkips = 0,
  }) {
    final autoSkips = skipped - manualSkips;
    final parts = <String>[
      if (cancelled) '已完成 ${done - failed - skipped}/$total 个压缩包'
      else '$total 个压缩包',
      '耗时 ${formatDuration(elapsed)}',
      if (failed > 0) '$failed 个失败',
      if (manualSkips > 0) '手动跳过 $manualSkips 个',
      if (autoSkips > 0) '$autoSkips 个自动跳过',
    ];
    return parts.join(' · ');
  }

  /// 通知上那行字。形状：`42% · 3/12 · 备份.zip`。
  ///
  /// 三段都是用户一眼要的：还剩多少（百分比）、这一批的第几个、眼下解的是谁。
  /// **用 `·` 连接而不是换行**：通知的正文在各家 ROM 上常常只剩一两行，
  /// 换行会把后面两段直接吃掉。
  String _keepAliveText() {
    final percent = (_progress * 100).round().clamp(0, 100);
    return [
      '$percent%',
      // 只有一个包时「1/1」是废话，摆着反而让人以为还有别的。
      if (_batchTotal > 1) '${(_doneCount + 1).clamp(1, _batchTotal)}/$_batchTotal',
      if (_currentFile.isNotEmpty) _currentFile,
    ].join(' · ');
  }

  /// 把这行字推到通知上。**节流由调用方负责**（见 [_lastKeepAliveAt]）。
  void _pushKeepAlive() {
    _lastKeepAliveAt = DateTime.now();
    // 不 await：`_onExtractTick` 是同步的，而且它是 8Hz 的进度回调 —— 让它去等
    // 一次跨进程的通道往返，等于把通道的延迟摊进解压的进度事件里。通知慢一拍
    // 无所谓，进度条慢一拍不是。
    unawaited(_keepAlive.update(_keepAliveText()));
  }

  /// 后台那一份进度：**只喂通知，不碰界面**。
  ///
  /// 与 [_onExtractTick] 是同一套数字，区别只在最后不发 `_notify()` —— 后台时
  /// 四棵页面树都不可见，重建了没人看（见 [EngineController.setForeground]）。
  /// 通知正好相反：那时它是用户唯一还看得见的东西。
  void _onExtractTickBackground(ExtractTick tick) =>
      _onExtractTick(tick, quiet: true);

  /// 一个包在进度条上占多少（单位见 [_bytesTotal]）。
  ///
  /// 至少记 1：量不到大小（0）的包也是一份活，不能让它在进度条上隐形。
  static int _weightOf(ScanItem item) => item.sizeBytes > 0 ? item.sizeBytes : 1;

  /// 整批进度 = (已处理完的包的权重 + 当前包权重 × 当前包内部比例) ÷ 总权重。
  ///
  /// 当前包的内部比例来自 7-Zip 的未压缩计数，与权重的量纲不同 —— 但它只是
  /// 个 0..1 的比例，乘上权重之后就回到同一个单位了。
  void _recomputeProgress(double currentFraction) {
    if (_bytesTotal <= 0) {
      _progress = 0;
      return;
    }
    final done = _bytesDone + _currentWeight * currentFraction.clamp(0.0, 1.0);
    _progress = (done / _bytesTotal).clamp(0.0, 1.0);
  }

  /// 引擎解压进度回调。已经被控制器按 8Hz 节流过。
  ///
  /// [quiet] 为真表示这份进度是从**后台**来的（见
  /// [EngineController.onExtractTickBackground]）：数字照算、通知照推，
  /// 唯独不发那个会重建四棵树的 `_notify()`。
  void _onExtractTick(ExtractTick tick, {bool quiet = false}) {
    final now = DateTime.now();
    // 表只跟踪**当前这个包**；整批的进度由 [_recomputeProgress] 按包的
    // 磁盘大小加权合成。
    _meter.update(
      doneBytes: tick.doneBytes,
      totalBytes: tick.totalBytes,
      entryName: tick.current,
      now: now,
    );
    final snap = _meter.snapshot();

    _recomputeProgress(snap.progress);
    // 表里存的是字节/秒，而页面拼的单位是 MB/s —— 从前这里直接塞字节数，
    // 于是界面上出现一个大得离谱的「MB/s」。
    _speed = bytesPerSecondToMBps(snap.speedBytesPerSecond);
    // 表每个包重开一次，所以这是**当前这个包**还剩多久，不是整批。
    _eta = formatEta(_meter.eta);
    _entryName = snap.entryName;
    if (!quiet) _notify();

    // 通知**另算一个节流**（见 [_lastKeepAliveAt]）：上面的 8Hz 是给屏幕上的
    // 进度条用的，通知那个位置两秒刷一次就够，也不该拿通道往返去挤解压的 IO。
    final last = _lastKeepAliveAt;
    if (last == null || now.difference(last) >= const Duration(seconds: 2)) {
      _pushKeepAlive();
    }
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
    showToast('密码已存入密码库', type: 'success');
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
    _trimLogsToCap();
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
  const _ExtractTask({
    required this.item,
    required this.ancestors,
    this.outputBaseDir,
  });

  final ScanItem item;

  /// 从根到**父**为止的全部祖先身份。根任务的这份是空的。
  final Set<String> ancestors;

  /// 这个包该往哪个目录里写（`resolveOutputDir` 的 `baseDir`）。
  ///
  /// `null` = 按老规矩「写在包自己旁边」，由 `resolveOutputDir` 自己算父目录。
  /// 只有**顶层任务**在「自定义输出目录」开着时会给它一个值。
  ///
  /// **嵌套任务刻意不给**：父包的输出目录本身就已经落在镜像位置上，
  /// worker 报回来的子包路径就在那个目录里面，于是老规矩（父目录 + 名字）
  /// 天然得到 `<根>/子目录/S1/S2/`。这是推导出来的，不是显式接的线 ——
  /// `test/providers/app_state_test.dart` 里「自定义输出目录」那组有一条专门钉它。
  final String? outputBaseDir;
}

// ---------------------------------------------------------------------------
// 密码那一档的内部类型
// ---------------------------------------------------------------------------

/// 试密码那条路上，「我这边没有密码」要写成**空串**，不能写成 `null`。
///
/// 引擎那边这两个值是**两件事**：`null` 是「给不出密码」（`duz_open` 传 NULL
/// → C 侧 `passwordGiven = false`），`''` 是「给了一个空密码」。区别在 ZIP
/// 这类**条目级加密**的包上会致命 —— 它不需要密码就能打开、能列条目，到
/// 解压时才问密码，而真问的时候：
///
/// - 答 `null`：`CryptoGetTextPassword` 只能返回 `E_NOTIMPL`，7-Zip 的
///   `ZipHandler` 对这个 HRESULT 用的是 `RINOK`（`ZipHandler.cpp` 里
///   `RINOK(getTextPassword->CryptoGetTextPassword(&password))`），于是**整个
///   `Extract()` 原样返回 E_NOTIMPL**：既没报 `kWrongPassword`，也没报条目
///   失败。我们 C 那边只看到「res != S_OK 且一条都没失败」，翻成一句笼统的
///   `DUZ_ERR_EXTRACT`（「解压失败」）。
/// - 答 `''`：7-Zip 照常走校验，AES 的 `Init_and_CheckPassword()` 或
///   ZipCrypto 的 12 字节头比对必然不过，报 `kWrongPassword` → 我们翻成
///   `DUZ_ERR_PASSWORD`。
///
/// 后果差别不是文案：只有拿到 `DUZ_ERR_PASSWORD`，[AppState] 才知道「这个包
/// 要密码」，才会去试密码库、才会弹那个窗。**传 `null` 的话整条路一次都不会被
/// 走到** —— 真机第一次验收就是栽在这里：AES 加密码库一个都没试，`locked_horse
/// .zip` 直接跳「解压失败」。头加密的包（7z / RAR 常见）反而看不出来，因为
/// 那种包在 `duz_open` 阶段就失败了，走的是另一条映射（`DescribeOpenFailure`）。
///
/// 名字刻意不省成一个裸 `''`：那样看起来像谁漏写了一个值，下一个人会「修」回去。
///
/// ## 这条契约有**两头**，改一头就把另一头废掉
///
/// C 侧 `duz_open` 必须同样认为「空串 = 给了密码」：它的守卫曾经写成
/// `if (pwd && pwd[0])`，于是 Dart 换了空串过去、那头又把它折叠回
/// `passwordGiven = false`，`E_NOTIMPL` 原样回来 —— **修了半天等于没修**，
/// 真机第二次验收才靠 logcat 里那句 `res=0x80004001` 定位到。
/// 现在的约定写死在 `duz_engine.cpp` 的 `duz_ctx::passwordGiven` 上：
/// `nullptr` = 没给，空串 = 密码就是空串。两边要一起改。
const String _kEmptyPassword = '';

/// 一次解压尝试的结果：要么成了，要么带着异常回来。
///
/// 做成值对象而不是让调用方 try/catch：试密码这件事天然要**问很多次**
/// （空密码一次、密码库 N 次、手输若干次），用异常控制这个循环等于把正常
/// 流程写成一片红。
class _PwdAttempt {
  const _PwdAttempt.done(ExtractOutcome this.outcome) : error = null;
  const _PwdAttempt.failed(EngineException this.error) : outcome = null;

  final ExtractOutcome? outcome;
  final EngineException? error;

  /// 这次失败是不是「密码不对」。**只有它为真才值得换下一个候选**。
  bool get isPasswordError => error?.code == DuzErrorCode.password;
}

/// 解开了：结局 + 这个包是**怎么打开的**（没用上密码就是 `null`）。
///
/// 打包成一个返回值，而不是给 `_extractResolvingPassword` 加个出参：密码的
/// 来源只有那条路上才知道，而那条路有**四个**成功出口（开局空密码就成、
/// 密码库命中、手输成功、手输兜底重试）。出参得在四处各写一遍，漏一处就是
/// 一条日志悄悄少一个标签 —— 而返回值只有一个，编译器会盯着。
class _PwdUnlocked {
  const _PwdUnlocked(this.outcome, [this.source]);

  final ExtractOutcome outcome;
  final PasswordSource? source;
}

/// 「密码这条路没走通」的三种收场，用异常在 `_runExtractBatch` 里传递。
///
/// 走异常是为了让那段已经写好的 `on EngineException catch`（坏包、闸门、
/// 弹窗）原样不动：成功仍是返回值，失败仍是异常，这里只是把密码这一档也
/// 归到失败那条路上。`EngineException` 之外单开一个类型，是因为这三种收场
/// **不该**再经过那段逻辑 —— 尤其不能再去问一次「跳过 / 停止」，用户刚在
/// 密码弹窗里回答过一模一样的问题。
class _PasswordVerdict implements Exception {
  const _PasswordVerdict(this.kind, {this.uncertain = false});

  final _PwdOutcomeEnum kind;

  /// 这个包**说不清**是密码不对还是数据已损坏（见 `EngineException.uncertain`）。
  ///
  /// 只有 [autoSkipped] 那一支用得上：另两支（用户跳过 / 用户停止）的说法是
  /// 「按你的选择」，压根不涉及「为什么没解开」。默认 false 让它不必在每个
  /// 构造点都写一遍。
  final bool uncertain;
}

enum _PwdOutcomeEnum {
  /// 密码库没试出来，而设置里关掉了弹窗 —— 静默跳过这个包。
  autoSkipped,

  /// 用户在弹窗里按了「跳过」。
  userSkipped,

  /// 用户在弹窗里按了「停止解压」—— 整批到此为止。
  userStopped,
}
