/// Android 13+ 的通知权限。**它只为「正在解压」那条通知而存在。**
///
/// ## 为什么值得单独为它申请一次权限
///
/// 没有它，前台服务照样能起、进程照样保得住 —— 真机实测过：`dumpsys activity
/// services` 里那条通知记录完整地挂在服务上（渠道 `duz_extract_progress`、
/// 带 `ONGOING_EVENT`），只是通知栏里不显示。但**锁屏期间用户能看到的只剩这条
/// 通知**：界面上的进度条走的是前后台节流那条路，后台期间整条掐掉（见
/// `EngineController.onExtractTickBackground`），通知再不显示，用户就完全瞎了
/// —— 一个跑了十几分钟的活，看起来像是卡住了。
///
/// ## 申请时机
///
/// 第一次「开始解压」时（`AppState._runExtractBatch` 里）。选那一刻的理由有
/// 三条：
///
/// 1. 用户刚表达完「我要干活了」，不是开屏就弹；
/// 2. 应用在前台 —— 不在前台这个弹窗根本出不来；
/// 3. 它**必然晚于**「选择文件夹」那次存储权限申请，而那次已经是允许申请权限
///    的最早点（`AndroidManifest.xml` 里 9.2 那条规矩），所以「隐私政策同意前
///    不申请任何权限」天然满足。
///
/// 调用方式上有一条硬约束，写在调用点那边：**起前台服务排在它前面，而且不等
/// 它的结果**。把服务吊在一次用户交互后面，等于让「这一批有保活」这件事由用户
/// 什么时候点弹窗决定。顺序的代价是权限往往在 `startForeground` 之后才落地
/// （那时这条通知在 Android 13+ 上会被先压住），由调用点在拿到结果后补推一次
/// 通知来兜。
///
/// ## 拒绝的后果只有一个：少一条通知
///
/// 所以 [ensureAsked] 返回 `void` 而不是「有没有拿到」。返回布尔只会诱使某个
/// 调用点写出「没给就不解压」—— 那是绝不许可的。与 `keep_alive.dart`、
/// `disk_space.dart` 同一条原则：**加固件坏了不能把主流程带下去。**
library;

import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:permission_handler/permission_handler.dart';

/// 问一次通知权限。方法幂等，重复调用不会重复弹窗。
///
/// 类刻意可以继承、方法刻意不是 final：测试要拿一个记账的假实现换掉它
/// （见 `test/support/fake_notification_permission.dart`）—— 通道那一层在
/// 无设备的 `flutter test` 里根本注册不着，而「第一次开始解压时问了一次、
/// 而且拒绝不拦解压」这件事必须钉住。
class NotificationPermission {
  /// [isAndroid] 只给测试注入用。生产代码一律用默认值。
  ///
  /// 需要它是因为「问过一次就不再问」那道闸门只有在**真的走到通道**时才有
  /// 观察得到的效果，而宿主机上默认值恒为 false、第一步就返回了
  /// （见 `test/services/notification_permission_test.dart`）。
  NotificationPermission({bool? isAndroid})
      : _isAndroid = isAndroid ?? (!kIsWeb && Platform.isAndroid);

  final bool _isAndroid;

  /// 这一次进程里问过没有了。
  ///
  /// 光靠系统不够：Android 13 允许 App 连问两次，用户第一次点拒绝之后，第二次
  /// 还会再弹一个一模一样的窗。用户眼里那就是「它又来了」。在同一个应用会话里
  /// 问过一次就不再问，是这一段最省的克制方式（跨会话的克制由「不再询问」兜着，
  /// 见 [ensureAsked] 里那句 `isPermanentlyDenied`）。
  bool _asked = false;

  /// 问一次，**最多一次**。已经拿到、已经拒绝到底、或者这次进程里问过了，
  /// 都直接返回。
  Future<void> ensureAsked() async {
    if (_asked) return;
    _asked = true;
    if (!_isAndroid) return;
    try {
      final permission = Permission.notification;
      // **状态只取一次**：`isGranted` 与 `isPermanentlyDenied` 是两个各自都要
      // 过一次通道的 getter，分开写就是同一件事朝系统问两遍 —— 通道往返比一次
      // 枚举比较贵得多，而这里一个字都没多花。
      final status = await permission.status;
      if (status.isGranted) return;
      // 「不再询问」之后系统也不会再弹了，问了等于白跑一趟通道。
      //
      // 这一句**不会**把「第一次申请」吃掉：它在首次申请之前是 false。插件判
      // 「不再询问」靠的是自己记的 `wasPermissionDeniedBefore`（SharedPreferences，
      // 跨会话），不是裸的 `shouldShowRequestPermissionRationale` —— 后者在第一次
      // 申请之前恰好也是 false，直接拿它当判据就会永远问不出去。
      if (status.isPermanentlyDenied) return;
      await permission.request();
    } catch (_) {
      // 通道没注册（桌面目标、热重载中途）或插件内部出错：少一条通知，别的照旧。
      // 这里**不能**往上抛：调用点在 `_runExtractBatch` 里，抛出去就是「通知
      // 权限没问到 → 这一批解压没了」。
    }
  }
}
