/// 解压期间的进程保活。
///
/// ## 它解决的问题
///
/// 解压是长任务，而它跑在**我们自己进程**里的 worker isolate 上。用户一旦锁屏
/// 或切走，应用就是后台进程，国产 ROM 随时可以把它回收 —— 表现是「解到一半
/// 回来一看什么都没了」，且没有任何报错，因为那不是我们的错。
///
/// 唯一的官方解法是前台服务：原生那边是 [ExtractKeepAliveService]，这一层只是
/// 它过方法通道的窄接口。
///
/// ## Android 13+ 上那条通知还差一道权限
///
/// 没有 `POST_NOTIFICATIONS`，上面说的前台服务照样起、进程照样保得住，只是通知
/// **不显示在通知栏里**（真机实测：`dumpsys` 里那条记录完整地挂在服务上）。补它
/// 是 [NotificationPermission] 的事，与这一层刻意分开：一个是「保住进程」，
/// 一个是「让用户看得见」，两者的失败后果完全不同。
///
/// ## 为什么这一层的失败**一律吞掉**
///
/// 保活是**尽力而为的加强**，不是解压的前置条件。拿不到就少一层保护，解压本身
/// 照跑。反过来，如果拿不到就抛，用户会看到「解压失败」—— 而其实什么都没坏。
/// 与 `disk_space.dart` 量不到就返回 `null`（`null` 语义是「不知道」，据此跳过
/// 检查）是同一条原则：**加固件坏了不能把主流程带下去**。
///
/// ## 为什么走方法通道而不是 C ABI
///
/// 与 `disk_space.dart` 同因：不动 C++、不重跑 ffigen，而且通道可以注入假实现，
/// 「批次开始时真的叫了它、结束时真的停了它」这件事能在 `flutter_test` 里验到。
/// 通知与 `startForeground` 都是纯 Java API，跟我们的引擎没有任何关系。
library;

import 'dart:io';

import 'package:flutter/services.dart';

import 'file_manager_bridge.dart' show kFileManagerChannel;

/// 解压期间让系统别杀我们。方法都是幂等的，重复调用不会出错。
///
/// 方法刻意**不是 final、类刻意可以继承**：测试要拿一个记账的假实现换掉它
/// （见 `test/support/fake_keep_alive.dart`）。这与 `DiskSpaceProbe` 靠注入
/// `MethodChannel` 的可测路子略有不同 —— 那边断言的是「发了哪个方法、带了什么
/// 参数」，这边断言的是**时序**（什么时候起、什么时候停、停了几次），
/// 记录时序比记录通道调用读起来清楚得多。
class KeepAlive {
  /// [channel] 与 [isAndroid] 只给测试注入用。生产代码一律用默认值。
  KeepAlive({MethodChannel? channel, bool? isAndroid})
      : _channel = channel ?? const MethodChannel(kFileManagerChannel),
        _isAndroid = isAndroid ?? Platform.isAndroid;

  final MethodChannel _channel;
  final bool _isAndroid;

  /// 通知标题。起服务时传入，之后每次 [update] 复用它 —— 标题在整批解压里
  /// 不会变，让调用方每次更新都重传一遍只是噪音。
  String _title = '';

  /// 起前台服务并挂上第一条通知。[text] 是那行会变的字。
  Future<void> start({required String title, required String text}) async {
    _title = title;
    await _invoke('startKeepAlive', title: title, text: text);
  }

  /// 只换那行字。**没起过服务时什么也不做** —— 服务不在，notify 出来的是一条
  /// 撤不掉的僵尸通知；原生那边也有一道同样的守卫。
  Future<void> update(String text) async {
    if (_title.isEmpty) return;
    await _invoke('updateKeepAlive', title: _title, text: text);
  }

  /// 停服务、撤通知。整批解压无论怎么收场都要走到这里（含异常与用户中止）。
  Future<void> stop() async {
    _title = '';
    await _invoke('stopKeepAlive');
  }

  Future<void> _invoke(String method, {String? title, String? text}) async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod<void>(method, <String, Object?>{
        'title': ?title,
        'text': ?text,
      });
    } on MissingPluginException {
      // 通道没注册（桌面目标、热重载中途）。少一层保活，别的照旧。
    } on PlatformException {
      // 原生那边没起来（比如 Android 12+ 的后台启动限制）。同上，吞掉。
    }
  }
}
