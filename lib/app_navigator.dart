import 'package:flutter/widgets.dart';

/// 全局导航 key。
///
/// 存在的唯一理由：**worker isolate 那一侧没有 `BuildContext`**。
/// 引擎跑到需要用户决断的地方（错误弹窗的「暂停 / 跳过」、格式识别的
/// 「确认 / 取消」）时，只能通过这个 key 拿到一个 context 去 `showModalBottomSheet`。
///
/// 所以 [key] 必须在 `MaterialApp` 上挂一次，否则 `currentContext` 恒为 null，
/// 弹窗会静默不出现、等待用户决断的 Completer 永久挂起。
///
/// 单独一个文件而不是塞在 `main.dart` 里：`services/dialog_bridge.dart`（P3）
/// 要 import 它，而让一个 service 反向 import `main.dart` 会把依赖方向搞乱。
abstract final class AppNavigator {
  static final GlobalKey<NavigatorState> key = GlobalKey<NavigatorState>();

  /// 当前可用的 context。引擎侧一律用这个，不要缓存它的返回值 ——
  /// `MaterialApp` 重建后 key 不变但 context 指向的 element 可能已换。
  static BuildContext? get context => key.currentContext;
}
