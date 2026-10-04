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

import '../app_navigator.dart';
import '../engine/limits.dart';
import '../widgets/modals/error_modal.dart';
import 'blocked_prompt.dart';

class DialogBridge {
  const DialogBridge();

  /// 弹「这个包被拦下了」，等用户选。
  ///
  /// 拿不到 context（`MaterialApp` 没挂 `AppNavigator.key`，或者此刻正在重建）
  /// 时**直接返回 null 不弹**：`key.currentContext` 为 null 时去弹等于什么都不会
  /// 发生，而一个永远不完成的 future 会把整批解压钉死。让调用方按「没弹」处理，
  /// 行为就退回成只记日志 —— 比卡住好。
  Future<BlockedDecision?> askArchiveBlocked(
    String fileName,
    LimitBreach breach,
  ) async {
    final context = AppNavigator.context;
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
}
