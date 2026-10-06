import 'dart:io';

import 'package:deep_unzip/theme/app_theme.dart';
import 'package:flutter_test/flutter_test.dart';

/// 原生资源与 Dart 主题**不许各走各的**。
///
/// 这几处抄的是 Dart 里的常量（原生看不见 `AppTheme`），抄错了**不会编译报错、
/// 也不会让任何别的测试变红**，症状只在真机上：冷启动时先闪一下别的颜色、或者
/// 启动画面上那块底色与界面不是同一个黑。
///
/// 与 `about_screen_test.dart` 里那条「kAppVersion 与 pubspec.yaml 一致」同一个
/// 思路：能把机器核对的，就别靠人记住。
void main() {
  const colorsXml = 'android/app/src/main/res/values/colors.xml';
  const v21Launch = 'android/app/src/main/res/drawable-v21/launch_background.xml';
  const launch = 'android/app/src/main/res/drawable/launch_background.xml';
  const v31Styles = 'android/app/src/main/res/values-v31/styles.xml';
  const nightStyles = 'android/app/src/main/res/values-night/styles.xml';

  /// `Color(0xFF050810)` → `#FF050810`（colors.xml 里写的那种形状）。
  String argbHex(int argb) =>
      '#${argb.toRadixString(16).padLeft(8, '0').toUpperCase()}';

  String read(String path) {
    final f = File(path);
    expect(f.existsSync(), isTrue, reason: '$path 不在仓库里');
    return f.readAsStringSync();
  }

  /// 去掉注释再断言。
  ///
  /// **必须去**：这些文件里的注释正好在解释「我们为什么不用
  /// `?android:colorBackground`」「为什么不能写 `postSplashScreenTheme`」——
  /// 直接在原文上搜这几个词，搜到的全是注释本身，断言会永远红。
  String readXml(String path) =>
      read(path).replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');

  group('窗口底色', () {
    test('colors.xml 的 duz_background 就是 AppTheme.bgDeep', () {
      // 这个值决定两件事：Dart 首帧之前铺满屏幕的那一色，以及 Android 12+
      // 系统启动画面的底色。和 bgDeep 不一致 = 冷启动闪一下。
      final xml = readXml(colorsXml);
      final m = RegExp(r'<color name="duz_background">([^<]*)</color>')
          .firstMatch(xml);
      expect(m, isNotNull, reason: 'colors.xml 里没有 duz_background');
      expect(m!.group(1), argbHex(AppTheme.bgDeep.toARGB32()),
          reason: 'app_theme.dart 是 ${argbHex(AppTheme.bgDeep.toARGB32())}，'
              '而原生侧会铺 ${m.group(1)}');
    });

    test('两份 launch_background 都引它，没人再写死白色或跟主题走', () {
      // `drawable-v21` 那份是 minSdk 24 下真正生效的（`-v21` 永远压过
      // `drawable/`），但两份都改才不至于下次有人改错文件。
      for (final path in [v21Launch, launch]) {
        final xml = readXml(path);
        expect(xml, contains('@color/duz_background'), reason: '$path 没引底色');
        expect(xml, isNot(contains('@android:color/white')),
            reason: '$path 退回白色了 —— 冷启动会闪白屏');
        expect(xml, isNot(contains('?android:colorBackground')),
            reason: '$path 跟主题走了 —— 白天会解析成白色');
      }
    });

    test('Android 12+ 的启动画面也引它，而不是又抄一遍字面值', () {
      final xml = readXml(v31Styles);
      expect(xml, contains('<item name="android:windowSplashScreenBackground">'
          '@color/duz_background</item>'));
      // 那个 attr 平台侧不存在（在 AndroidX 的兼容库那边）。写了会在 aapt2
      // 链接期直接失败，本机踩过一次 —— 在这儿留个记号。
      expect(xml, isNot(contains('postSplashScreenTheme')));
    });

    test('不再有 values-night —— 界面是纯深色的，两套会把白天那条路走歪', () {
      // `main.dart` 只给了 `theme: AppTheme.dark`，没有 darkTheme / themeMode。
      // 留着 night 那份的后果是：桌面白天亮着的机器（也就是大多数）走的是
      // values/styles.xml，而它出厂是 Theme.Light —— 闪白屏、状态栏图标在深色
      // 底上变成深色看不见。
      expect(File(nightStyles).existsSync(), isFalse,
          reason: '要重新加回来，先把 main.dart 的浅色主题也接上');
    });
  });

  group('图标', () {
    test('五档一个不少', () {
      // 少一档**不会报错**：系统会从别的密度缩放着用，结果是糊的 —— 而这种糊
      // 只在真机上、还得盯着看才发现。四类图各五档，摆在一起点名。
      const densities = ['mdpi', 'hdpi', 'xhdpi', 'xxhdpi', 'xxxhdpi'];
      for (final d in densities) {
        for (final name in [
          'ic_launcher.png',
          'ic_launcher_round.png',
          'ic_launcher_foreground.png',
        ]) {
          expect(File('android/app/src/main/res/mipmap-$d/$name').existsSync(),
              isTrue, reason: 'mipmap-$d/$name 缺了');
        }
        for (final name in ['ic_notification.png', 'splash_logo.png']) {
          expect(File('android/app/src/main/res/drawable-$d/$name').existsSync(),
              isTrue, reason: 'drawable-$d/$name 缺了');
        }
      }

      // 启动屏的 logo **不该**再有 mdpi 那一份兜底：medpi 桶里的 240px 图在
      // xxxhdpi 机器上会被系统放大 4 倍，糊 —— 那正是这一档被重做的原因。
      expect(File('android/app/src/main/res/drawable/splash_logo.png').existsSync(),
          isFalse,
          reason: '放回 drawable/ 就等于按 mdpi 算，高分屏会糊');
    });

    test('自适应图标的两个入口都在，引用的图层也真的存在', () {
      // 引一个不存在的资源是**链接期**报错（aapt2 会拦），所以这条主要防的是
      // 「谁把入口删了」—— 删掉之后 26+ 会退回那张铺满的方形 png，看不出坏了，
      // 只是在各家 ROM 的圆形/水滴蒙版下被裁。
      for (final f in ['ic_launcher.xml', 'ic_launcher_round.xml']) {
        expect(
            File('android/app/src/main/res/mipmap-anydpi-v26/$f').existsSync(),
            isTrue,
            reason: '$f 缺了，Android 8+ 会退回方形位图');
      }
      final xml = readXml('android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml');
      expect(xml, contains('@drawable/ic_launcher_background'));
      expect(xml, contains('@mipmap/ic_launcher_foreground'));
      expect(File('android/app/src/main/res/drawable/ic_launcher_background.xml')
          .existsSync(), isTrue);

      expect(read('android/app/src/main/AndroidManifest.xml'),
          contains('android:roundIcon="@mipmap/ic_launcher_round"'));
    });

    test('应用标记那条链没断：res 有图标、assets 有那份给 Flutter 读的', () {
      // Flutter **读不到** `android/app/src/main/res/` 下面的东西，所以首页头部
      // 那块标记是另外导的一份 `assets/logo.png`。两边没有自动关联 —— 换了图标
      // 忘了重导，首页会一直停在旧图形上，而没有任何地方会报错。
      expect(File('assets/logo.png').existsSync(), isTrue,
          reason: '首页头部要用它，见 home_screen 的 _buildHeader');
      expect(read('pubspec.yaml').replaceAll('\r\n', '\n'),
          contains('\n    - assets/logo.png'),
          reason: '文件在但没在 pubspec 里声明，打包时会被丢掉，运行期才炸');
    });

    test('通知小图标是专用的那一张，不是 launcher', () {
      // 拿 `ic_launcher` 当小图标出来的是**一个白方块**：小图标只取 alpha，
      // 而自适应图标的 `<background>` 是铺满的、只有前景会被蒙版裁。
      final kt = read('android/app/src/main/kotlin/com/example/deep_unzip/'
          'ExtractKeepAliveService.kt');
      expect(kt, contains('val SMALL_ICON_RES = R.drawable.ic_notification'),
          reason: '换了小图标就会变白方块，见那边的注释');
    });
  });
}
