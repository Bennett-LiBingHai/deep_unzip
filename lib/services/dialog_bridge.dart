/// 把「引擎想问你一句话」接到真弹窗上。
///
/// ## 为什么是 Completer 而不是让弹窗返回值
///
/// `ErrorModal.show` 返回 `Future<void>`，用户的选择只通过
/// `onStop`/`onSkip` 两个回调传出来（见 `error_modal.dart`）。要 await
/// 一个结果，就得自己拿 `Completer` 把回调转成 future。
///
/// 而**光包一层 Completer 会挂死**：`showBottomModal` 没设
/// `isDismissible: false`/`enableDrag: false`，弹窗能被遮罩点击或下滑直接关掉，
/// 两条回调都不触发，`.then` 里的兜底就成了唯一的出口。少了那一句，用户随手滑
/// 一下，这个 future 就永远不完成，整批解压停在原地 —— 而且没有任何报错。
/// （`app_navigator.dart` 的注释里也点了这个坑。）
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../app_navigator.dart';
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

  /// 弹「这个包处理不了」，等用户选「跳过」还是「停止」。
  ///
  /// 闸门拦下（炸弹 / 空间不够）和解压出错共用这一个弹窗、同一组按钮 ——
  /// 那两种情况下两个决断的含义完全一样（见 `prompts.dart` 的表）。区别只在
  /// [reason] 那句话由谁给：前者是 `LimitBreach.message`，后者是引擎的失败原因。
  ///
  /// ## 滑走默认 = **跳过**，不是停止
  ///
  /// 主计划最早写的是「默认暂停（保守、可恢复）」，那时候左边那颗叫「暂停」，
  /// 按下去队列还在、点一下就回来。现在它叫「停止」，而且**停掉这一批会把剩余
  /// 队列丢掉，没有续传**（真要续传得等 journal）—— 这时候还把「误滑一下」
  /// 默认成停止，就等于随手一滑废掉整批。所以默认反过来：不确定时让它接着跑。
  Future<ArchiveDecision?> askCantExtract(
    String fileName,
    String reason,
  ) async {
    final context = _context;
    if (context == null) return null;

    final completer = Completer<ArchiveDecision?>();

    void finish(ArchiveDecision? decision) {
      if (!completer.isCompleted) completer.complete(decision);
    }

    unawaited(ErrorModal.show(
      context: context,
      fileName: fileName,
      reason: reason,
      // 「停止」在左、暖色，「跳过」在右、主色渐变。两颗字号一样，只有颜色与
      // 两个字不同 —— 点了哪颗决定了整批活儿还在不在，所以左边那颗刻意叫
      // 「停止」不叫别的：它代价大，名字要吓人一点。
      onStop: () => finish(ArchiveDecision.stop),
      onSkip: () => finish(ArchiveDecision.skip),
    ).then((_) => finish(ArchiveDecision.skip)));

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
