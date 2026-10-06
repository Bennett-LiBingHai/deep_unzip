/// 通知权限那道闸门。
///
/// ## 为什么这里要注入 `isAndroid: true` 并桩掉 `permission_handler` 的通道
///
/// 真实现的头一句是 `!_isAndroid → return`，而 `flutter test` 跑在 Windows 上
/// —— 不注入的话，这个类**一行通道都走不到**，于是它唯一的核心行为
/// （「一个会话里只打扰用户一次」）在本机就完全测不出来。
///
/// 通道名与那几个方法名是从 `permission_handler_platform_interface` 的实现里
/// 抄来的（`flutter.baseflow.com/permissions/methods`，方法
/// `checkPermissionStatus` / `requestPermissions`）。它们是**插件内部**的东西，
/// 升大版本时可能变 —— 变了这里会红，那正好：红了说明「问过就不再问」这件事
/// 需要重新验一遍，而不是说明测试写错了。
library;

import 'package:deep_unzip/services/notification_permission.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // 纯 `test()` 不会自动初始化绑定，而 `TestDefaultBinaryMessengerBinding`
  // 依赖它。照抄 `disk_space_test.dart` 的开头。
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('flutter.baseflow.com/permissions/methods');
  late List<MethodCall> calls;

  /// `permission_handler` 的状态码：0 拒绝 / 1 已授权 / 4 拒绝到底。
  const denied = 0;
  const granted = 1;
  const permanentlyDenied = 4;

  setUp(() => calls = []);

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  /// 让原生侧按 [status] 作答。`requestPermissions` 回那张表的同一个状态。
  void stub(int Function() status) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'checkPermissionStatus':
          return status();
        case 'requestPermissions':
          // 入参是 `List<int>` 的权限码，回一张 `权限码 → 状态` 的表。
          final asked = (call.arguments as List<Object?>).first! as int;
          return <int, int>{asked: status()};
        default:
          return null;
      }
    });
  }

  NotificationPermission permission() => NotificationPermission(isAndroid: true);

  List<String> methods() => [for (final c in calls) c.method];

  group('该问的时候问', () {
    test('没授权 → 查一次、申请一次', () async {
      stub(() => denied);
      await permission().ensureAsked();

      expect(methods(), ['checkPermissionStatus', 'requestPermissions']);
    });

    test('已经授权 → 连申请都不发', () async {
      stub(() => granted);
      await permission().ensureAsked();

      expect(methods(), ['checkPermissionStatus'],
          reason: '已经拿到就别再去敲一次系统弹窗了');
    });

    test('「不再询问」→ 也不发申请（系统不会再弹，问了是白跑一趟通道）', () async {
      stub(() => permanentlyDenied);
      await permission().ensureAsked();

      expect(methods(), ['checkPermissionStatus']);
    });
  });

  group('一个会话里只打扰一次', () {
    test('第二次调用连查都不查了', () async {
      stub(() => denied);
      final p = permission();
      await p.ensureAsked();
      final afterFirst = methods().length;
      expect(afterFirst, 2, reason: '前提：第一次真的走了通道');

      await p.ensureAsked();
      await p.ensureAsked();
      expect(methods().length, afterFirst,
          reason: 'Android 13 允许连问两次 —— 用户拒绝之后再来一个一模一样的窗，'
              '在他眼里就是「它又来了」');
    });

    test('换一个实例（= 换一次进程运行）会重新问 —— 拒绝不是终局', () async {
      // 「只问一次」的范围是**这一次进程运行**，不是永久。用户这次拒绝了、
      // 后来想开了，下次打开应用还有机会；真正的「永远别再问」由系统那条
      // 「不再询问」兜着（见上一组最后一条）。
      stub(() => denied);
      await permission().ensureAsked();
      await permission().ensureAsked();

      expect(methods(), [
        'checkPermissionStatus',
        'requestPermissions',
        'checkPermissionStatus',
        'requestPermissions',
      ]);
    });
  });

  group('绝不把主流程带下去', () {
    test('通道没注册（桌面 / 热重载中途）→ 一声不响地过去', () async {
      // 不 stub：默认 messenger 上没这个通道的处理器。
      await permission().ensureAsked();
    });

    test('原生抛 PlatformException → 一样不抛出去', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'boom');
      });

      // 调用点在 `_runExtractBatch` 里：这里抛出去就是「通知权限没问到 →
      // 这一批解压没了」，而这条权限的收益只是「多一条通知」。
      await permission().ensureAsked();
    });
  });

  group('不惊动原生', () {
    test('非 Android 平台一个字都不发', () async {
      stub(() => denied);
      await NotificationPermission(isAndroid: false).ensureAsked();

      expect(calls, isEmpty);
    });
  });
}
