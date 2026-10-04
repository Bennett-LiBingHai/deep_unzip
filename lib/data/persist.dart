/// 持久化的**数据契约**：落盘的那几样东西长什么样、以及 `AppState` 通过
/// 哪个接口把它们交出去。
///
/// ## 这里刻意没有一样东西：解压过的文件夹
///
/// 需求是「选一个目录 → 解压 → 下次还能重解」，因为**目录内容会变**（用户往
/// 里面丢了新包），而一个「这个目录解过了」的记录会把重解挡在门外 —— 用户
/// 看到的是「明明有新包，它却说都解过了」。判断「该不该解」的依据只能是
/// **当下这一份扫描结果**，不是上一轮存下来的结论。
///
/// 所以：不存源目录路径、不存「已解压目录」清单、不存任务续传 journal。
/// `AppState` 里那个 `_batchRun` 闸门是**纯内存**的，换一次文件夹就归零
/// （见 `app_state.dart` 的 [_resetExtractState]）—— 它防的是「同一份快照
/// 被重排一遍撒出 `_1`/`_2` 目录」，不是「这个目录被解过」。
///
/// 这一条是**产品约束**，不只是实现细节：以后谁想加「最近解压过的目录」，
/// 先回来读这段。
///
/// ## 为什么单独一个文件、且不 import 任何插件
///
/// `AppState` 要 import 本文件（构造函数里接一个 [PersistStore]），而
/// `AppState` 是能跑在 `flutter_test` 里的：它要是顺着这里 import 到
/// `shared_preferences` / `flutter_secure_storage`，每个单测都得先初始化
/// 平台通道。把「接口 + 数据类」和「具体实现」（`device_store.dart`）分家，
/// 单测注入 null 或一个假实现就完全绕开插件。
library;

import '../engine/limits.dart';
import '../models/log_entry.dart';
import '../models/password_entry.dart';

/// 出厂默认的六个开关。
///
/// 从 `AppState` 搬到这里，是为了让「默认值」只有一个出处：`AppState` 的
/// 初值和「第一次启动、磁盘上什么都没有」时必须给出同一套，否则「没存过档」
/// 和「存过一份默认档」会跑出两种行为，最难查。
///
/// **const，别改它。** 要改的是 `AppState` 里 `Map.of(...)` 出来的那一份。
///
/// 没有 `crcCheck`：那颗开关 2026-10 删掉了。它从原型期起就是个死开关
/// （全仓库只有设置页在读它），但**接上它反而是错的** —— 7-Zip 逐条目比对
/// CRC32 是解压流程的一部分、顺带算出来的，关掉省不下时间；关了唯一的
/// 效果是坏文件静默解成乱码、日志还写 success。而且 C ABI
/// （`duz_extract_all`）根本没有这个参数，要接得改 C++ 重编 `.so`。
/// CRC 校验的效果一直在：对不上就是 `EngineException`，走的就是那颗
/// 「跳过 / 停止」弹窗。
const Map<String, bool> kDefaultToggles = {
  'recursive': true,
  'symmetricOutput': true,
  'fakeExtDetect': true,
  'splitMerge': true,
  'pwdAutoTry': true,
  'errorPause': true,
};

/// 深度默认「无限制」。
const int kDefaultMaxDepth = 0;

/// 深度芯片依次走过的档位。`0` = 无限制。
///
/// 放在这里是为了让 `AppState.cycleMaxDepth`、设置页的芯片、以及加载时的
/// 收敛（[coerceMaxDepth]）读同一张表 —— 三处各写一份 `[0, 5, 10, 20]`，
/// 改动时漏掉一处就是一个只在特定路径上才炸的 bug。
const List<int> kMaxDepthOptions = [0, 5, 10, 20];

/// 日志封顶的默认值。与原型期行为一致（那时候是 `AppState._maxLogs = 300`）。
const int kDefaultMaxLogs = 300;

/// 日志封顶的可填范围。**自由输入**，不是几档固定值 —— 这个数只跟用户的存储
/// 习惯有关，没有「大就是好」或「小就是省」的说法，替他挑三档等于让他在三个
/// 别人的答案里选。
///
/// 下界取 1 而不是 0：0 是**另一个语义**（「不记录日志」），那该是一个独立的
/// 开关；一个能填 0 的条数框会把「我不想留历史」和「我填错了」混成同一种表现。
const int kMinMaxLogs = 1;

/// 上界。它同时就是 `LogRepo` 那道硬顶：任何一份**合法的**日志都不可能超过
/// 用户能设的最大值，所以「用户能填多少」和「磁盘上那份最多有多少」是同一个
/// 数，不必各写一份、再靠测试盯着它们别走散。
///
/// 5000 条 ≈ 400 KB 的 JSON，启动时读一遍毫无压力；再往上就纯是「用户其实想
/// 要一个不封顶的选项」，而那件事该由「不记录」那个开关来表达，不是把上限调到
/// 一百万。
const int kMaxMaxLogs = 5000;

/// 把磁盘上读回来的深度收敛到 [kMaxDepthOptions] 里。
///
/// **必须收敛**：`settings_screen` 的芯片用 `kMaxDepthOptions.indexOf(maxDepth)`
/// 定位，表外的值给出 `-1`，再拿去索引标签数组就是越界 —— 设置页直接打崩。
/// 老版本写的档位、被人手改过的文件，都可能给出表外的值。
int coerceMaxDepth(int? raw) => _nearest(kMaxDepthOptions, raw, kDefaultMaxDepth);

/// 把磁盘上读回来的日志封顶夹进 [kMinMaxLogs]–[kMaxMaxLogs]。
///
/// 与 [coerceMaxDepth] 的「取最近的合法档」不同，这里**不吸附**：条数是自由
/// 输入，磁盘上那个数就是用户自己填的，没有一张表可以让它「最近」到哪儿去。
/// 越界只能是手改文件或跨版本残留，夹回边界是唯一说得过去的解释。
int coerceMaxLogs(int? raw) =>
    raw == null ? kDefaultMaxLogs : raw.clamp(kMinMaxLogs, kMaxMaxLogs);

/// 取表里离 [raw] 最近的一档；[raw] 为 null 或表是空的时给 [fallback]。
///
/// 取**最近的合法档**而不是无脑归零：用户真设过 20 层，值要是恰好落在表外，
/// 归零等于把他设的限制悄悄放开。距离相等时留先遇到的那个（表里靠前的档）。
int _nearest(List<int> options, int? raw, int fallback) {
  if (raw == null) return fallback;
  if (options.contains(raw)) return raw;
  var best = options.first;
  for (final v in options) {
    if ((v - raw).abs() < (best - raw).abs()) best = v;
  }
  return best;
}

/// 炸弹防护默认停在 `kLimitPresets` 里「标准」那档。
///
/// 字面量 `1` 而不是 `kLimitPresets.length - 2`：const 表达式里取不了
/// `List.length`。改 `kLimitPresets` 的顺序时要跟着改这里。
const int kDefaultLimitPreset = 1;

/// 需要落盘的那部分设置。
class SettingsData {
  const SettingsData({
    this.toggles = kDefaultToggles,
    this.maxDepth = kDefaultMaxDepth,
    this.limitPreset = kDefaultLimitPreset,
    this.limits = LimitThresholds.standard,
    this.maxLogs = kDefaultMaxLogs,
  });

  final Map<String, bool> toggles;
  final int maxDepth;

  /// 日志保留条数。**权威在 `AppState._maxLogs`**，这个字段只是把它带过
  /// 磁盘这一趟：`LogRepo` 不再自己封顶（见那边的注释），内存里留多少条
  /// 完全由这个数说了算，落盘只是把内存那一份原样写出去。
  final int maxLogs;

  /// chip 停在哪一档：`kLimitPresets` 的下标，或 `kLimitPresets.length`
  /// 表示「自定义」。**必须与 [limits] 一起存**，理由见 `app_state.dart`
  /// 里那个字段的注释（从值反推档位会让编辑器在编辑途中自己合上）。
  final int limitPreset;

  /// 当前这套阈值。`limitPreset` 不是「自定义」时，加载器会用预设值覆盖它
  /// —— 预设档位本身就是权威，没必要再从磁盘上读一份可能对不上的。
  final LimitThresholds limits;

  static const SettingsData defaults = SettingsData();
}

/// 启动时一次性读回来的全部东西。
///
/// 做成「一次读完再 `runApp`」而不是「界面起来之后异步补」，是因为设置、
/// 密码库、日志都是**同步 getter**（`setting('recursive')` 之类）—— 它们被
/// 页面在 `build` 里直接读。异步补的话，第一帧就会用默认值渲染一遍，用户
/// 会看到开关自己跳一下。
class AppSnapshot {
  const AppSnapshot({
    this.settings = SettingsData.defaults,
    this.vault = const [],
    this.logs = const [],
  });

  final SettingsData settings;
  final List<PasswordEntry> vault;
  final List<LogEntry> logs;

  /// 第一次启动（或磁盘上读不出任何东西）时的那一份。
  static const AppSnapshot empty = AppSnapshot();
}

/// `AppState` 唯一认识的持久化接口。
///
/// 全部方法是 `Future` 但调用方**不等**（`unawaited`）：改一个开关就同步
/// `notifyListeners()` 让界面立刻响应，落盘在后台慢慢来。等的话，一次
/// 慢磁盘扫描就会让开关看起来卡住。
///
/// 失败一律吞掉（返回 void 而非抛异常 / bool）：一次设置没写进去不值得
/// 打断用户手里的解压。真要排查，实现里自己 debugPrint。
abstract class PersistStore {
  /// 启动时的预加载。读不出来就吐 [AppSnapshot.empty]，**不要抛**。
  Future<AppSnapshot> load();

  Future<void> saveSettings(SettingsData data);
  Future<void> saveVault(List<PasswordEntry> entries);
  Future<void> saveLogs(List<LogEntry> logs);
}
