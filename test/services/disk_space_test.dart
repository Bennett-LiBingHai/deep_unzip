import 'package:deep_unzip/services/disk_space.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// [DiskSpaceProbe] 只有两件事值得测：数怎么落地成 `int?`，以及
/// 「量不到」的那几条路是不是真的走了 null 而不是 0。
///
/// 后者是这组测试的重点。`0` 与 `null` 在调用方眼里是两个相反的结论：
/// null = 不知道 → 跳过检查；0 = 一格不剩 → 每一个包都被判装不下。
/// 这里任何一条回落到 0，真机上就是「所有压缩包都解不开」。
///
/// 原生的 `StatFs` 那一半（向上找已存在祖先、可移动卷）在 `MainActivity.kt`
/// 里，无设备测不了，靠真机验收。
void main() {
  // 纯 `test()` 不会自动初始化绑定，而 `TestDefaultBinaryMessengerBinding`
  // 依赖它。照抄 `file_manager_bridge_test.dart` 的开头。
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('deep_unzip_test/disk_space');
  late List<MethodCall> calls;

  setUp(() {
    calls = [];
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  /// 让原生侧回 [handler] 的结果。不调 = 没注册处理器（模拟桌面 / 热重载）。
  void stub(Object? Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return handler(call);
    });
  }

  DiskSpaceProbe probe({bool isAndroid = true}) =>
      DiskSpaceProbe(channel: channel, isAndroid: isAndroid);

  group('量得到', () {
    test('原样返回字节数', () async {
      stub((_) => 12 * 1024 * 1024 * 1024);
      expect(await probe().availableBytes('/sdcard/Download'),
          12 * 1024 * 1024 * 1024);
    });

    test('0 是合法答案 —— 真的满了', () async {
      // 与「量不到」必须分得开：这条会让闸门拦下每一个包，而 null 放行。
      stub((_) => 0);
      expect(await probe().availableBytes('/sdcard/Download'), 0);
    });

    test('方法名与参数名要和 MainActivity.kt 对齐', () async {
      // 对不上就是真机上一句静默的「量不到」→ 空间检查整个失效，而且因为
      // 是静默的（平台通道没这个方法会抛），单测里不钉住谁也不会发现。
      stub((_) => 1);
      await probe().availableBytes('/sdcard/Download');

      expect(calls.single.method, 'freeSpace');
      expect(calls.single.arguments, {'path': '/sdcard/Download'});
    });
  });

  group('量不到一律 null，绝不回落成 0', () {
    test('原生回 null', () async {
      stub((_) => null);
      expect(await probe().availableBytes('/sdcard/Download'), isNull);
    });

    test('原生回负数 —— 那是它算错了，当未知处理', () async {
      stub((_) => -1);
      expect(await probe().availableBytes('/sdcard/Download'), isNull);
    });

    test('通道没注册（缺处理器）→ MissingPluginException 被吃掉', () async {
      // 不 stub：默认 messenger 没这个通道的处理器。
      expect(await probe().availableBytes('/sdcard/Download'), isNull);
    });

    test('原生抛 PlatformException', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'boom');
      });
      expect(await probe().availableBytes('/sdcard/Download'), isNull);
    });
  });

  group('不惊动原生', () {
    test('空路径', () async {
      stub((_) => 1);
      expect(await probe().availableBytes(''), isNull);
      expect(calls, isEmpty);
    });

    test('非 Android 平台', () async {
      // 桌面 / 测试宿主上没有 StatFs 这回事，硬发只会得到 MissingPluginException。
      stub((_) => 1);
      expect(await probe(isAndroid: false).availableBytes('/sdcard/Download'),
          isNull);
      expect(calls, isEmpty);
    });
  });
}
