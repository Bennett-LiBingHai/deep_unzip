import 'package:deep_unzip/services/file_manager_bridge.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// [FileManagerBridge] 只有两件事值得测：原生结果码 → 枚举的映射，以及
/// 「不该惊动原生时就别惊动」。剩下的降级链条在 `MainActivity.kt` 里，
/// 那边靠真机验收（无设备测不了 Intent 解析）。
void main() {
  // 本文件是纯 `test()`（没有 `testWidgets`），绑定不会自动初始化，
  // 而 `TestDefaultBinaryMessengerBinding.instance` 拿的就是它。
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('deep_unzip_test/bridge_only');
  late List<MethodCall> calls;

  setUp(() {
    calls = [];
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  /// 让原生侧回 [code]。`null` = 没注册处理器（模拟桌面/热重载）。
  void stub(Object? Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return handler(call);
    });
  }

  FileManagerBridge bridge() =>
      FileManagerBridge(channel: channel, isAndroid: true);

  group('结果码映射', () {
    for (final (code, expected) in const [
      ('opened', OpenFolderResult.opened),
      ('opened_generic', OpenFolderResult.openedGeneric),
      ('unsupported_path', OpenFolderResult.unsupportedPath),
      ('no_handler', OpenFolderResult.noHandler),
    ]) {
      test('$code → $expected', () async {
        stub((_) => code);
        expect(await bridge().openFolder('/sdcard/Download'), expected);
      });
    }

    test('认不出来的码当「没打开」，而不是假装成功', () async {
      // 原生化新增一档但忘了在这里登记时，宁可说「没打开」——
      // 反过来会把用户扔进一个不相干的目录。
      stub((_) => 'some_future_code');
      expect(await bridge().openFolder('/sdcard/Download'),
          OpenFolderResult.noHandler);
    });

    test('原生回 null 也当「没打开」', () async {
      stub((_) => null);
      expect(await bridge().openFolder('/sdcard/Download'),
          OpenFolderResult.noHandler);
    });
  });

  group('不惊动原生的路径', () {
    test('空路径直接判「打不开」，不走通道', () async {
      stub((_) => 'opened');
      expect(await bridge().openFolder(''), OpenFolderResult.unsupportedPath);
      expect(calls, isEmpty);
    });

    test('非 Android 平台返回 unavailable，不走通道', () async {
      stub((_) => 'opened');
      final b = FileManagerBridge(channel: channel, isAndroid: false);
      expect(await b.openFolder('/sdcard/Download'),
          OpenFolderResult.unavailable);
      expect(calls, isEmpty);
    });

    test('通道没注册 → unavailable（不是崩溃，也不是假成功）', () async {
      // 不 stub：默认 messenger 没这个通道的处理器，会抛 MissingPluginException。
      expect(await bridge().openFolder('/sdcard/Download'),
          OpenFolderResult.unavailable);
    });

    test('原生抛 PlatformException → noHandler', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'boom');
      });
      expect(await bridge().openFolder('/sdcard/Download'),
          OpenFolderResult.noHandler);
    });
  });

  test('方法名与参数名要和 MainActivity.kt 对齐', () async {
    // 这两个字面量对不上，真机上就是一句静默的「没打开」——
    // 而单测里因为手写的 stub 恰好也这么写，谁也发现不了。
    stub((_) => 'opened');
    await bridge().openFolder('/sdcard/Download');

    expect(calls.single.method, 'openFolderInFileManager');
    expect(calls.single.arguments, {'path': '/sdcard/Download'});
  });
}
