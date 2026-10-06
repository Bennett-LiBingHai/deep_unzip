/// 测试用的假通知权限：只记账，不碰 `permission_handler`。
///
/// ## 为什么要一个假的
///
/// 真实现里第一句就是 `!_isAndroid → return`，而 `flutter test` 跑在 Windows
/// 上，于是**在宿主机上它永远走不到那两条通道调用**。也就是说：不换掉它，
/// 「第一次开始解压时问了一次权限」「问的时机排在起服务之前」这两件事在本机
/// 根本无从验起 —— 而那正是这个类存在的全部意义（`AndroidManifest.xml` 里
/// 那条 `POST_NOTIFICATIONS` 是不是真的被用上了）。
///
/// ## 与「注入一条假 MethodChannel」的分工
///
/// `disk_space_test.dart` 走的是那条路：它要钉的是「方法名和参数对不对」，而
/// 那正是通道记录的形状。这里要钉的是**次数与时序**，所以假的是整个类。
///
/// ## 为什么没有「拒绝」这个开关
///
/// 因为 [ensureAsked] 返回 `void`：调用方**读不到结果**，也就没有「被拒之后
/// 走哪条路」可以验。这不是漏了 —— 那正是设计（见
/// `services/notification_permission.dart`）。要塞「被拒绝」，就在真实现里
/// 塞，别指望这一层能测出来。
library;

import 'package:deep_unzip/services/notification_permission.dart';

class FakeNotificationPermission extends NotificationPermission {
  /// [ensureAsked] 被调了几次。**这不是「问了几次弹窗」**——真实现里第二次就
  /// 直接返回了（[NotificationPermission] 的 `_asked`），这里记的是「调用方
  /// 来找过它几次」。
  int ensureCount = 0;

  /// 每次 [ensureAsked] 被调用的**那一刻**。给用例一个观察时机的口子。
  ///
  /// 目前唯一的用处是验顺序：把 `keep.startedWith.length` 记下来，就能断言
  /// 「问权限的时候前台服务**还**没起来」—— 而这一点在 Android 13+ 上是会
  /// 影响通知显不显示得出来的。
  void Function()? onEnsure;

  @override
  Future<void> ensureAsked() async {
    ensureCount++;
    onEnsure?.call();
  }
}
