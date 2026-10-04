/// 把「引擎想问你一句话」接到真弹窗上。
///
/// ## 为什么是 Completer 而不是让弹窗返回值
///
/// `ErrorModal.show` 返回 `Future<void>`，用户的选择只通过 `onPause`/`onSkip`
/// 两个回调传出来（见 `error_modal.dart`）。要 await 一个结果，就得自己拿
/// `Completer` 把回调转成 future。
///
/// 而**光包一层 Completer 会挂死**：`showBottomModal` 没设
/// `isDismissible: false`/`enableDrag: false`，弹窗能被遮罩点击或下滑直接关掉，
/// 两条回调都不触发，`.then` 里的兜底就成了唯一的出口。少了那一句，用户随手滑
/// 一下，这个 future 就永远不完成，整批解压停在原地 —— 而且没有任何报错。
/// （`app_navigator.dart` 的注释里也点了这个坑。）
///
/// ## 滑走默认 = 跳过，不是主计划里写的「暂停」
///
/// 主计划写那条时的默认是「暂停（保守、可恢复）」。现在第二档叫 [stop]，
/// 而**停下这一批会丢掉剩余队列，没有续传**（真要续传得等 journal）。这时候
/// 还把「误滑一下」默认成停止，就等于随手一滑废掉整批 —— 比继续跑危险得多。
/// 所以默认反过来了：不确定时，让它接着跑。
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../app_navigator.dart';
import '../engine/limits.dart';
import '../widgets/modals/error_modal.dart';
import '../widgets/modals/format_detect_modal.dart';
import 'prompts.dart';

class DialogBridge {
  const DialogBridge();

  /// 拿不到 context 时统一走这里返回 null。
  ///
  /// `MaterialApp` 没挂 `AppNavigator.key`、或者此刻正在重建时，
  /// `key.currentContext` 为 null：这时去弹等于什么都不会发生，而一个永远不
  /// 完成的 future 会把整批解压钉死。让调用方按「没弹」处理，行为退回成
  /// 加特性之前的样子 —— 比卡住好。
  BuildContext? get _context => AppNavigator.context;

  /// 弹「这个包被拦下了」，等用户选。
  Future<BlockedDecision?> askArchiveBlocked(
    String fileName,
    LimitBreach breach,
  ) async {
    final context = _context;
    if (context == null) return null;

    final completer = Completer<BlockedDecision?>();

    void finish(BlockedDecision? decision) {
      if (!completer.isCompleted) completer.complete(decision);
    }

    unawaited(ErrorModal.show(
      context: context,
      fileName: fileName,
      reason: breach.message,
      // 左边那颗的默认文案是「暂停任务」，而这里它是**不可恢复**的：
      // 停掉的是整批，剩下没解的包直接丢掉。暂停键却按下后整批没了，
      // 是比继续跑更糟的意外，所以必须改名。
      pauseLabel: '停止这批',
      onPause: () => finish(BlockedDecision.stop),
      onSkip: () => finish(BlockedDecision.skip),
    ).then((_) => finish(BlockedDecision.skip)));

    return completer.future;
  }

  /// 弹「这个包解不开，暂停还是跳过」（需求 3）。
  ///
  /// ## 滑走默认 = **暂停**，与上面那个反过来
  ///
  /// 上面 [askArchiveBlocked] 滑走默认是「跳过」，因为那一档的另一边是
  /// **不可恢复**的停止，误触代价是整批活儿没了。这里反过来：这档的「暂停」
  /// 是真暂停（复用 `pauseExtract` 那道闸门），队列原封不动、「继续解压」
  /// 接得回来。所以回到主计划原本那条判据 —— **默认挑可恢复的那个**。
  Future<ExtractErrorDecision?> askExtractError(
    String fileName,
    String reason,
  ) async {
    final context = _context;
    if (context == null) return null;

    final completer = Completer<ExtractErrorDecision?>();

    void finish(ExtractErrorDecision? decision) {
      if (!completer.isCompleted) completer.complete(decision);
    }

    unawaited(ErrorModal.show(
      context: context,
      fileName: fileName,
      reason: reason,
      // 「暂停任务」是 `ErrorModal` 的默认文案，这里显式写出来是因为它**必须**
      // 与上面那句「停止这批」形成对照 —— 两个弹窗长得一模一样，只有这两个字
      // 不一样，而它们一个是能回来的、一个不是。
      pauseLabel: '暂停任务',
      onPause: () => finish(ExtractErrorDecision.pause),
      onSkip: () => finish(ExtractErrorDecision.skip),
    ).then((_) => finish(ExtractErrorDecision.pause)));

    return completer.future;
  }

  /// 弹「后缀对不上，按真实格式解吗」（需求 5）。
  ///
  /// ## 返回三态，滑走默认 = **确认**
  ///
  /// `null` 是「压根没弹」（拿不到 context）。调用方必须把它与 `false`
  /// （用户按了取消）分开：把「没弹」当成取消，用户就会看到自己的压缩包
  /// **凭空从批次里消失**，而且没有任何解释。
  ///
  /// 滑走默认取 `true` 而不是主计划里写的取消：这个弹窗只是个**通报**，
  /// 扫描阶段已经认定它确实是个压缩包、用户也确实选了要解。让「手滑一下」
  /// 去改掉这个结果（把包从批次里抹掉）太狠了；想跳过请明确按「取消」。
  /// 这样滑走的行为就等于「这个特性压根没上线」，是个安全的退路。
  Future<bool?> askFormatDetect(FormatDetectInfo info) async {
    final context = _context;
    if (context == null) return null;

    final completer = Completer<bool?>();

    void finish(bool? confirmed) {
      if (!completer.isCompleted) completer.complete(confirmed);
    }

    unawaited(FormatDetectModal.show(
      context: context,
      fileName: info.fileName,
      fakeExt: info.fakeExt,
      fileHeader: info.fileHeader,
      realFormat: info.realFormat,
      action: info.action,
      hexPreview: info.hexPreview,
      onConfirm: () => finish(true),
      onCancel: () => finish(false),
    ).then((_) => finish(true)));

    return completer.future;
  }
}
