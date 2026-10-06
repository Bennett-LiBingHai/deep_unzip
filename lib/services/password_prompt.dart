/// 「密码库试不出来」这件事的三方契约：`AppState` 提问、弹窗作答、桥接层搬运。
///
/// 与 `prompts.dart` 分成两个文件是同一个理由（见那边的注释）：`AppState`
/// 刻意不 import 任何 widget，所以「什么形状」放这儿（零 UI 依赖），
/// 「怎么弹」放 `dialog_bridge.dart`。本文件是纯 Dart：不碰磁盘、不 import
/// 插件，`flutter_test` 里可以直接造一个假实现喂进去。
///
/// ## 与「这个包处理不了」那条契约的区别
///
/// `ArchiveDecision` 是「跳过 / 停止」两选一；这里多出第三条路：**用户手敲
/// 一个密码**。多这一条不只是多一颗按钮 —— 它要求调用方能**验一个候选**，
/// 于是有了 [PasswordAsk.verify]，而「验」的实现是「真解一遍」。这笔账的
/// 理由写在 [PasswordAsk.verify] 上。
library;

/// 用户面对「密码库没试出来」时的三个去处。
enum PasswordVerdict {
  /// 停下这一批。**不可恢复**：剩余队列丢掉，没有续传
  /// （与 `ArchiveDecision.stop` 同义，见 `prompts.dart` 那张表）。
  stop,

  /// 放掉这个包，接着解队列里剩下的。
  skip,

  /// 用户手敲了一个密码，而且它**已经验过并通过了**（包已经解完，
  /// 见 [PasswordAsk.verify]）。
  manual,
}

/// 用户对「密码库没试出来」的答复。
///
/// 做成一个带字段的类而不是裸 `enum`：`manual` 那一支要**把密码带回来**，
/// 而 `stop`/`skip` 两支什么都没有。用 `enum` + 一个平行的 `String?` 参数
/// 就得在类型上留一个「skip 时这个字段无意义」的口子 —— 那种口子迟早有人
/// 在 skip 的分支里去读它。
class PasswordResolution {
  const PasswordResolution._(this.verdict, this.password);

  const PasswordResolution.stop() : this._(PasswordVerdict.stop, null);
  const PasswordResolution.skip() : this._(PasswordVerdict.skip, null);
  const PasswordResolution.manual(String password)
      : this._(PasswordVerdict.manual, password);

  final PasswordVerdict verdict;

  /// 只在 [PasswordVerdict.manual] 时有值，其余两支恒为 null。
  final String? password;
}

/// 问用户「这个包需要密码，密码库没试出来」。
class PasswordAsk {
  const PasswordAsk({
    required this.fileName,
    required this.triedCount,
    required this.verify,
    this.uncertain = false,
  });

  /// 要解的这个包。
  final String fileName;

  /// 在它之前已经按顺序试过、且**都没通过**的候选**个数**。
  ///
  /// **只给个数，不给那串密码。** 原来这里传的是 `List<String>`，弹窗拿它摆
  /// 一排「•」×长度、右边跟一句「不匹配」—— 可密码库里的每一条都**不可能**
  /// 匹配（能匹配上的根本走不到这个弹窗），于是一屏长得几乎一样的点，读不出
  /// 任何东西，只是把「该你出牌了」这一屏拖长。用户原话：「每条都是加密的
  /// 点号，没参考意义」。
  ///
  /// 个数则确实有信息量，它区分的是**两件不同的事**：`0` = 密码库本来就是空
  /// 的（一句「试了 0 个都没通过」读起来像我们偷懒），大于 0 = 试过这么多条。
  ///
  /// 顺带把密码明文从这条路线上摘掉了：`PasswordAsk` 是要交到控件层手里的，
  /// 一个不再需要内容的地方不该还攥着一串密码。
  final int triedCount;

  /// 这个包的失败**说不清**是密码不对还是数据已损坏（见
  /// `EngineException.uncertain`）。**与路由无关**：有它没它都照样去密码库
  /// 里试、照样弹这个窗、[verify] 照样真解一遍。它只决定弹窗上那句提示是
  /// 「密码库未能解开该压缩包」还是「……也可能是文件本身损坏，两者无法区分」。
  ///
  /// 默认 false 是因为**绝大多数密码失败是能确定的**（ZIP-AES / RAR5 有校验字，
  /// 7-Zip 亲口报 `kWrongPassword`），把它设成 required 只会让每一处构造点都
  /// 写一句一样的 `false`。
  ///
  /// 取值是**包的属性**，不是某一次尝试的属性：手输的每一次失败都同样说不清，
  /// 所以它由开局那次（`AppState` 里 `first.error`）定下，之后不再变。
  final bool uncertain;

  /// 验一个用户手敲的密码。**返回 true = 这个密码能用**。
  ///
  /// ## 实现是「真解一遍」，不是廉价校验
  ///
  /// `duz_verify_password`（C ABI 里有、头文件注释里也写了「P4 落地」）
  /// 今天仍然返回 `DUZ_ERR_UNSUPPORTED`（见 `duz_engine.cpp`），所以没有
  /// 「只验最小条目」这条便宜路可走。这里的 `verify` 实际是拿候选去
  /// `engine.extract` 一遍：错了会撞在第一个加密条目上失败（头加密的包更是
  /// 在 `duz_open` 就失败，一个字节都不写），对了——那正好就是我们要的结果，
  /// **不必再解第二次**。
  ///
  /// 所以调用方（`AppState`）在 `verify` 返回 true 的那一刻，把 outcome 存进
  /// 闭包捕获的变量里交回去。这是这个设计的**核心约定**：true 不只是「密码
  /// 对」，而是「**已经解完了**」。
  ///
  /// 代价说清楚：输错一次要白跑一趟解压。等 C++ 那边的廉价验证落地之后，
  /// 这里可以换实现而契约不动。
  final Future<bool> Function(String candidate) verify;
}

/// 问用户「这个包需要密码」。
///
/// 返回 null = **没弹**（拿不到 `BuildContext`，或者调用方压根没接这个回调）。
/// 调用方必须把它与「用户按了跳过」分开：把「没弹」当成跳过，用户会看到自己
/// 的包凭空从批次里消失，而且没有任何解释。这与 `ArchivePrompt` 的 null
/// 契约是同一条（见 `prompts.dart`）。
typedef PasswordPrompt = Future<PasswordResolution?> Function(PasswordAsk ask);
