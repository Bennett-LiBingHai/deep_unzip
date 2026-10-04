/// 「这个包被拦下了，怎么办」的契约。
///
/// ## 为什么单独一个文件，而不是塞进 `dialog_bridge.dart`
///
/// `AppState` 要持有这个回调，而 `AppState` 是**刻意不 import 任何 widget 的**
/// （见 `app_state.dart` 的类注释）。`dialog_bridge.dart` 必然要 import
/// material，`AppState` 一旦 import 它，那条边界就破了 —— 而且破得悄无声息。
/// 所以「什么形状」放这儿（零 UI 依赖），「怎么弹」放那边。
///
/// 与 `engine/limits.dart` 里的 [LimitBreach] 一样，本文件是纯 Dart：不碰
/// 磁盘、不 import 插件，`flutter_test` 里可以直接造一个假实现喂进去。
library;

import '../engine/limits.dart';

/// 用户对被拦下的压缩包做的决定。
enum BlockedDecision {
  /// 这个包不要了，继续解队列里剩下的。
  skip,

  /// 停下这一批。**不是「暂停」** —— 剩余队列会被丢掉，没有续传（见下）。
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
