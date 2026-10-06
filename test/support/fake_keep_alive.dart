/// 测试用的假保活：只记账，不碰方法通道。
///
/// ## 为什么不是「注入一条假 MethodChannel」
///
/// `DiskSpaceProbe` 走的是那条路 —— 它要钉的是「发了哪个方法、带了什么参数」，
/// 通道调用记录正好是那个问题的形状。保活这边要钉的是**时序**：「这一批开始
/// 时起了服务、无论怎么收场都恰好停一次、期间的通知被压到两秒一条」。这东西
/// 摊成一张通道调用流水，读的人得自己在脑子里排先后；写成一条有序的
/// [events] 就是一眼的事。
///
/// ## 与真实现的关系
///
/// 三个方法都覆盖掉，所以 `KeepAlive` 里那条通道**根本不会被走到**；构造时
/// 传 `isAndroid: false` 只是把这件事写明，免得读的人以为它会在 Windows 上
/// 试着 invoke 一把。
///
/// [update] 那道守卫照的是**原生**那一层（`if (!isRunning) return`），不是
/// Dart 层的 `_title.isEmpty`：要验的是「批次结束之后不会再有通知冒出来」，
/// 而那正是原生那道守卫在管的事。
library;

import 'package:deep_unzip/services/keep_alive.dart';

class FakeKeepAlive extends KeepAlive {
  FakeKeepAlive() : super(isAndroid: false);

  /// 按发生顺序记下的每一次调用，取值 `start` / `update` / `stop`。
  final List<String> events = [];

  /// 每次 [start] 带的那行字，与 [events] 里的 `start` 等长同序。
  final List<String> startedWith = [];

  /// 每次 [start] 带的标题。钉住那句「正在解压」没被改坏。
  final List<String> titles = [];

  /// 每次 [update] 带的那行字。**长度就是往通道上推了几条通知**。
  final List<String> updatedWith = [];

  /// [stop] 被调了几次。
  ///
  /// 计数而不是布尔：漏掉一次 stop 会留下一条用户划不掉的常驻通知，多调一次
  /// 倒是无害（原生那边忽略），所以这里宁可记得细一点让用例自己挑严格度。
  int stopCount = 0;

  /// 服务现在是不是活着。起来之后为 true，停过之后为 false。
  bool running = false;

  @override
  Future<void> start({required String title, required String text}) async {
    events.add('start');
    titles.add(title);
    startedWith.add(text);
    running = true;
  }

  @override
  Future<void> update(String text) async {
    // 见文件头：这里照的是原生那道 `isRunning` 守卫。
    if (!running) return;
    events.add('update');
    updatedWith.add(text);
  }

  @override
  Future<void> stop() async {
    // 与 Dart 层一致，**不**加「没在跑就忽略」的守卫：真实现会照样把
    // `stopKeepAlive` 发下去（原生忽略重复的）。假货加一层守卫的话，
    // 「这一批停了几次」这句断言就永远为真了。
    events.add('stop');
    stopCount++;
    running = false;
  }
}
