/// 「引擎想问你一句话」的三种契约：被闸门拦下、解压出错、后缀被篡改。
///
/// ## 为什么单独一个文件，而不是塞进 `dialog_bridge.dart`
///
/// `AppState` 要持有这三个回调，而 `AppState` 是**刻意不 import 任何 widget 的**
/// （见 `app_state.dart` 的类注释）。`dialog_bridge.dart` 必然要 import
/// material，`AppState` 一旦 import 它，那条边界就破了 —— 而且破得悄无声息。
/// 所以「什么形状」放这儿（零 UI 依赖），「怎么弹」放那边。
///
/// 与 `engine/limits.dart` 里的 [LimitBreach] 一样，本文件是纯 Dart：不碰
/// 磁盘、不 import 插件，`flutter_test` 里可以直接造一个假实现喂进去。
///
/// ## 三种「问」的区别，别把它们合并成一个
///
/// | 场景 | 决断 | 另一个选项的后果 |
/// |---|---|---|
/// | 被闸门拦下（炸弹 / 装不下） | 跳过 / **停止这批** | 停止**不可恢复**，剩余队列丢掉 |
/// | 解压出错 | 跳过 / **暂停任务** | 暂停**可恢复**，队列还在，能接着解 |
/// | 后缀被篡改 | 取消 / **确认解压** | 取消只是不解这一个包 |
///
/// 第二行与第一行看着像，实际是两个不同的东西：一个停得回来，一个停不回来。
/// 合并成一个 `enum { skip, stop }` 的话，调用方迟早会把「暂停」接到那根
/// 不可恢复的线上 —— 而那个错误在界面上完全看不出来，直到用户的整批活儿没了。
library;

import '../engine/limits.dart';
import '../engine/models.dart';
// 带前缀是**必须**的，不是洁癖：本文件里 `hexPreview` 同时是一个字段名，
// 不加前缀时 [FormatDetectInfo.fromItem] 里那句 `hexPreview(...)` 会解析到
// 那个实例成员上（工厂构造里没有 this），报「不是一个函数」。
import '../engine/sniff.dart' as sniff;

// ---------------------------------------------------------------------------
// 被闸门拦下（炸弹防护 / 剩余空间）
// ---------------------------------------------------------------------------

/// 用户对被拦下的压缩包做的决定。
enum BlockedDecision {
  /// 这个包不要了，继续解队列里剩下的。
  skip,

  /// 停下这一批。**不是「暂停」** —— 剩余队列会被丢掉，没有续传（见上表）。
  stop,
}

/// 问用户「这个包被拦下了，跳过还是停下」。
///
/// 返回 null 表示**没弹**（比如拿不到 `BuildContext`，或者调用方压根没接
/// 这个回调）。调用方按「没弹」处理即可，不要把它当成用户的某个选择。
typedef ArchiveBlockedPrompt = Future<BlockedDecision?> Function(
  String fileName,
  LimitBreach breach,
);

// ---------------------------------------------------------------------------
// 解压出错（需求 3）
// ---------------------------------------------------------------------------

/// 用户在「这个包解不开」时做的决定。
enum ExtractErrorDecision {
  /// 暂停这一批。**真能恢复** —— 复用 [AppState.pauseExtract] 那道闸门，
  /// 队列原封不动留着，界面上的「继续解压」接得回来。
  pause,

  /// 这个包不要了，继续解队列里剩下的。
  skip,
}

/// 问用户「这个包解不开，暂停还是跳过」。
///
/// 只在设置里的 `errorPause` 开着时才被调用 —— 关着的时候引擎自己决断
/// （记一条失败日志、接着解下一个），不打扰用户。
///
/// 返回 null 表示**没弹**，与 [ArchiveBlockedPrompt] 同义。
typedef ArchiveErrorPrompt = Future<ExtractErrorDecision?> Function(
  String fileName,
  String reason,
);

// ---------------------------------------------------------------------------
// 后缀被篡改（需求 5）
// ---------------------------------------------------------------------------

/// 喂给格式识别弹窗的那组展示串。
///
/// 做成值对象而不是让桥接层自己去翻 [ScanItem]，是为了让「哪几个数、怎么
/// 格式化」这件事有一个能被单测钉住的落点 —— 弹窗上摆出来的六项有两项是
/// 十六进制、一项带条件后缀（前置数据），拼错了在界面上看着也像对的。
class FormatDetectInfo {
  const FormatDetectInfo({
    required this.fileName,
    required this.fakeExt,
    required this.fileHeader,
    required this.realFormat,
    required this.action,
    required this.hexPreview,
  });

  /// 从一条扫描结果拼出来。**只有**后缀确实被篡改的条目才该走到这里。
  ///
  /// [action] 里那句「前面有 N 字节前置数据」是**如实描述文件**，不是描述
  /// 我们要做什么：`CmdExtract` 并没有 `baseOffset` 这个参数，跳过前置数据
  /// 是 7-Zip 打开归档时自己试出来的（见 `native_backend.dart` 里
  /// `_bytesOnDisk` 那段对 SFW 的说明）。写成「已跳过」会是一句我们兑现不了
  /// 的承诺。
  factory FormatDetectInfo.fromItem(ScanItem item) {
    final s = item.sniff;
    final prefix =
        s.baseOffset > 0 ? '（前面有 ${s.baseOffset} 字节前置数据）' : '';
    return FormatDetectInfo(
      fileName: item.fileName,
      fakeExt: s.declaredExt,
      fileHeader: sniff.hexWord(s.header),
      realFormat: s.format.label,
      action: '按 ${s.format.label} 解压$prefix',
      hexPreview: sniff.hexPreview(s.header),
    );
  }

  final String fileName;

  /// 文件自己声明的后缀（小写、不带点），弹窗里标红的那一项。
  final String fakeExt;

  /// `0x504B0304` 这样的一小段十六进制。
  final String fileHeader;

  /// 「ZIP 压缩包」这类名字。
  final String realFormat;

  /// 「按 ZIP 压缩包 解压」。
  final String action;

  /// 文件头前 16 字节的 `50 4B 03 04 …`。
  final String hexPreview;
}

/// 问用户「这个包的后缀不对，按真实格式解吗」。
///
/// 返回 `true` = 确认解压，`false` = 取消（这个包跳过），
/// `null` = **没弹**（拿不到 context / 压根没接这个回调）。
///
/// 三态而不是两态：没弹和「用户按了取消」必须分得开。混成一种的话，弹窗
/// 因为拿不到 context 而没能出现时，用户会看到自己的包被**静默跳过** ——
/// 比什么都不做更糟。
typedef FormatDetectPrompt = Future<bool?> Function(FormatDetectInfo info);
