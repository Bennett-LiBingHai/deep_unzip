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

import '../engine/cycles.dart';
import '../engine/limits.dart';
import '../models/log_entry.dart';
import '../models/password_entry.dart';

/// 出厂默认的开关。**故意不在这里写条数** —— 这个数字漂过一次（删 `splitMerge`
/// 时漏改），而「表就在下面几行」本来也不需要数出来。
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
/// （`duz_extract_start`）根本没有这个参数，要接得改 C++ 重编 `.so`。
/// CRC 校验的效果一直在：对不上就是 `EngineException`，走的就是那颗
/// 「跳过 / 停止」弹窗。
///
/// 也没有 `splitMerge`（设置页上叫「分片自动合并」），同样 2026-10 删的，
/// 但**来路和 crcCheck 正好相反**：它不是死开关，链路一直是通的（扫描分组
/// → `ScanItem.parts` → `duz_open` 多卷），删掉的是「关」那一档 —— 关掉
/// 之后 `.zip.002` 会因为嗅探不出格式在 `_emitPlain` 里被静默丢掉
/// （`unreadable` / `containerSkipped` / `warnings` 一个都不记），只剩一行
/// 没有分片角标、也没有任何提示的 `.001`，用户点下去解的是残缺的包。
/// 一个开关的两档不该是「能用 / 悄悄丢一半」。而它本来想防的那种误合并，
/// `scanner.dart` 的「首卷不是压缩包 ⇒ 整组否决、退回普通文件」已经兜住了。
///
/// 也没有 `recursive`（设置页上叫「递归解压」），2026-10 删的。这颗跟上面两颗
/// 都不一样：它不是死开关，也不是「关掉就丢一半」，而是**与 `maxDepth` 管着
/// 同一件事**。深度填 0 就是不递归，那么再放一颗「递归解压」开关，两者必然
/// 对不上 —— 开关开着而深度是 0、或者反过来，用户没有任何办法知道该信哪个。
/// 删掉开关之后深度是唯一入口，`0` 的语义同时从「无限制」翻成了「不递归」
/// （见 [kDefaultMaxDepth]）。
/// 也没有 `symmetricOutput`（设置页上原来叫「目录对称输出」），2026-10 改成
/// `customOutput`（「自定义输出目录」）。**那次改名刻意没有走
/// [kRenamedToggles]** —— 那颗旧开关从接线到删除**一次都没被读过**（全仓库
/// 只有设置页写它，`resolveOutputDir` 永远走「解到包旁边」那条路），所以它的
/// `true` 不承载任何用户意图。照 [kRenamedToggles] 把 `true` 搬过来，只会让新
/// 语义变成「自定义输出目录 = 开」，**正好反了**。改名要带旧值过来，前提是旧值
/// 有意义；这里没有，所以旧键直接按「删掉的开关」处理（`settings_repo.load`
/// 只认本表的键，旧键读都不读）。
const Map<String, bool> kDefaultToggles = {
  // 开着 = 每次点「开始解压」先让用户选一个根输出目录，解出来的东西按源目录
  // 结构镜像写进去（`output_paths.mirroredBaseDir`）；关着 = 解到每个压缩包
  // 旁边，同级对称（默认）。根目录**不落盘**，每次重选 —— 见 `AppState._outputRoot`。
  'customOutput': false,
  'fakeExtDetect': true,
  'pwdPrompt': true,
  // 手输的密码验通过之后自动存进密码库。**默认开**：用户会去手敲一个密码，
  // 本身多半就说明这个包他还要再解（同一次备份切出来的一组包、下次还会拿到的
  // 存档），敲完就丢等于让他重敲。想「这次只是临时看一眼」的人可以关掉它。
  // 落地在 `AppState._maybeAutoImportPassword`。
  'pwdAutoSave': true,
  'errorPause': true,
};

/// 改过名的开关：新键 → 它曾经用过的旧键（按新→旧排序，取第一个有值的）。
///
/// `pwdPrompt` 原叫 `pwdAutoTry`（「密码库自动尝试」）。那个名字说的是**两边
/// 共有**的那一半 —— 现在无论开关开还是关，密码库都会先自动试一遍；这颗开关
/// 真正决定的是**试不出来之后问不问**，所以按它实际做的事改了名。不改的话，
/// 键名会一直指着那个恒为真的动作，下一个读代码的人得先被骗一次。
///
/// 与 `settings_repo.dart` 里「老版本删掉的开关一律不读」**不冲突**：那条防
/// 的是死开关复活，而这个开关一直在，只是名字不再准确 —— 用户的取舍（开还是
/// 关）要跟过来，不能让他升级一次就发现设置自己变了。
const Map<String, List<String>> kRenamedToggles = {
  'pwdPrompt': ['pwdAutoTry'],
};

/// 递归深度的默认值。**`0` = 不递归**。
///
/// ## 「一层」怎么数
///
/// 数的是**从被选目录往下走了几步**，「一步」有两种、**同等计入**：
/// **进一层子目录**、**解开一层嵌套包**（`scanner.dart` 里 `ScanItem.depth`
/// 写的就是 `baseDepth + 目录层级`）。所以 `子目录/a.zip` 比 `a.zip` 少一层
/// 预算 —— 它自己已经占掉一层了。这条是**有意为之**，`scanner_test.dart` 里
/// 「depth 随目录层级递增」那条钉着它。
///
/// **顶层那批包也走同一道闸门**（2026-10 补的，见
/// `AppState._runExtractBatch` 播种那段）：在那之前顶层是无条件排队的，
/// 于是 `0` 拦得住包**里面**的嵌套包，却拦不住**目录里面**的包 —— 而按上面
/// 那条规则，后者离被选目录更远。现在两者一视同仁。
///
/// 名字里那个「递归」只描述了后一种，念起来容易以为前一种不算 —— 设置页与
/// 弹窗的说明都把两种写全了，别缩回只提嵌套包那半句。
///
/// 这个语义 2026-10 翻过面：原来是「`0` = 无限制」（上界只在实现层
/// `kHardDepthCeiling` 兜着）。翻面的原因是那颗「递归解压」开关被删了 ——
/// 它和深度管着同一件事，留两个入口必然对不上（见 [kDefaultToggles] 里
/// 那一段）。现在深度是唯一入口，`0` 就该是「关」。
///
/// 默认取 20 而不是 0：删开关是为了去掉重复，不是为了把递归解压默认关掉。
/// 20 是原来档位表里最大的一档，实际效果等于解到底 —— 真线上没有会嵌套到
/// 20 层的包 —— 所以老用户升级过来行为不变。
const int kDefaultMaxDepth = 20;

/// 递归深度可填范围的**下界**，同时也是「不递归」那一档。
///
/// 0 在这里是**语义**而不是「填错了」，所以合法 —— 与 [kMinMaxLogs] 恰好
/// 相反，那边 0 被排除是因为「不记录日志」该是另一个开关（见那边的注释）。
const int kMinMaxDepth = 0;

/// 递归深度可填范围的**上界**，直接用实现层那道硬顶
/// （[kHardDepthCeiling]）。「用户能填多少」与「代码真正允许多深」是同一个
/// 数，不必各写一份、再靠测试盯着它们别走散 —— 与 [kMaxMaxLogs] 同一个写法。
const int kMaxMaxDepth = kHardDepthCeiling;

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

/// 把磁盘上读回来的深度夹进 [kMinMaxDepth]–[kMaxMaxDepth]。
///
/// 与 [coerceMaxLogs] 一样**不吸附**：深度已经是自由输入，磁盘上那个数就是
/// 用户自己填的，没有一张档位表可以让它「最近」到哪儿去。越界只可能是手改
/// 文件、或更早的版本留下的残值 —— 夹回边界是唯一说得过去的解释。
///
/// **老档里的 `0` 会照读成「不递归」**，这确实是语义翻面带来的一次行为变化：
/// 旧版本里 `0` 是「无限制」，而当时它同时是出厂默认值。这里**不替用户翻译**
/// —— 无法区分「旧版写的 0」和「用户刚照着新语义设的 0」，猜错的方向是把人
/// 特意关掉的递归又打开。本 app 尚未上架，没有真实用户档要迁移；真要迁移，
/// 得换键名（`maxDepthV2`）而不是在这里猜。
int coerceMaxDepth(int? raw) =>
    raw == null ? kDefaultMaxDepth : raw.clamp(kMinMaxDepth, kMaxMaxDepth);

/// 把磁盘上读回来的日志封顶夹进 [kMinMaxLogs]–[kMaxMaxLogs]。
///
/// 与 [coerceMaxDepth] 的「取最近的合法档」不同，这里**不吸附**：条数是自由
/// 输入，磁盘上那个数就是用户自己填的，没有一张表可以让它「最近」到哪儿去。
/// 越界只能是手改文件或跨版本残留，夹回边界是唯一说得过去的解释。
int coerceMaxLogs(int? raw) =>
    raw == null ? kDefaultMaxLogs : raw.clamp(kMinMaxLogs, kMaxMaxLogs);

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
