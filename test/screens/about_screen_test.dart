import 'dart:io';

import 'package:deep_unzip/app_info.dart';
import 'package:deep_unzip/data/third_party_notices.dart';
import 'package:deep_unzip/screens/about_screen.dart';
import 'package:deep_unzip/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「关于」页的一半是**合规材料**：LGPL 要求附上许可全文、注明用了哪个库、
/// 说明它是 LGPL；BSD 要求二进制分发时复现版权声明。这几条在 APK 里没有第二个
/// 地方能兑现，所以这一页里的每句话都得是真的。
///
/// 另一半是国内上架最值钱的那句「不联网、不收集个人信息」—— 它可以核查：Release
/// 包不声明 INTERNET 权限、没有任何统计/崩溃/广告 SDK。这条也是这里要钉的。
void main() {
  setUpAll(() => WidgetController.hitTestWarningShouldBeFatal = true);

  Future<void> pumpAbout(WidgetTester tester) async {
    // 页面比一屏长（头部 + 隐私卡 + 三条组件 + 三条许可入口），默认 800×600
    // 装不下 —— `ListView` 惰性挂载，没进视口的连 `find` 都找不到。
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const MaterialApp(
      home: AboutScreen(),
    ));
  }

  group('版本号不许漂', () {
    test('kAppVersion 与 pubspec.yaml 的 version 一致', () {
      // Flutter 在构建期把 `version:` 写进原生清单，Dart 侧读不到，所以那边手写
      // 了一份（见 `app_info.dart`）。这条就是那份手写值的防漂钉：改了
      // pubspec 忘了改它，这里立刻红，而不是等到用户在关于页看见一个上一版的号。
      final pubspec = File('pubspec.yaml').readAsStringSync();
      final m = RegExp(r'^version:\s*(\S+)', multiLine: true).firstMatch(pubspec);
      expect(m, isNotNull, reason: 'pubspec.yaml 里没找到 version:');

      // `1.0.0+1` 里的 `+1` 是构建号，不进关于页。
      final version = m!.group(1)!.split('+').first;
      expect(kAppVersion, version,
          reason: 'pubspec.yaml 是 $version，而关于页会显示 kAppVersion=$kAppVersion');
    });
  });

  group('应用名三处一致', () {
    // 商店那边明确要求「应用名 / 软著名 / 备案名」三者一致，而改名时要改的地方
    // 分散在 Dart 与 Android 两侧 —— 这条把能机器核对的两处拴在一起。
    test('Android 桌面显示名与 kAppName 一致', () {
      final xml = File('android/app/src/main/res/values/strings.xml');
      expect(xml.existsSync(), isTrue);
      final m = RegExp(r'<string name="app_name">([^<]*)</string>')
          .firstMatch(xml.readAsStringSync());
      expect(m, isNotNull, reason: 'strings.xml 里没有 app_name');
      expect(m!.group(1), kAppName);
    });

    test('清单引用的是那个资源，不是写死的名字', () {
      // 写死的话改名字要改两处，而漏掉的那一处只在装到手机上才看得出来。
      final manifest =
          File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
      expect(manifest, contains('android:label="@string/app_name"'),
          reason: '别退回写死的 android:label="..."');
      expect(manifest, isNot(contains('android:label="deep_unzip"')),
          reason: '`deep_unzip` 是包名，不是给人看的显示名');
    });
  });

  group('7-Zip 确实是独立动态库，不是静态链进去的', () {
    // 这一组钉的是「关于页那句『以独立的动态库随本应用分发』是不是真的」。
    //
    // 它为什么值得一条测试：**退回静态链接不会编译报错、也不会让任何测试变红**，
    // 只会让 LGPL 的义务从 §6b（库独立、用户能换）悄悄变成 §6a（要给重链接材料）。
    // 而这一页正是我们对外声明这件事的地方。
    const cmake = 'packages/deep_unzip_engine/src/CMakeLists.txt';

    test('引擎动态链接 duz_7zip，而不是把源文件塞进自己', () {
      final text = File(cmake).readAsStringSync();
      expect(text, contains('target_link_libraries(deep_unzip_engine PRIVATE duz_7zip)'),
          reason: '这一行是动态链接的来源（DT_NEEDED）。删了它，7-Zip 就不再是独立库了');
      expect(text, contains('add_library(duz_7zip SHARED'),
          reason: '7-Zip 必须是独立的 SHARED 目标');
    });

    test('7-Zip 那个目标不设隐藏可见性', () {
      // duz_engine.cpp 用的是 7-Zip 的一大片 C++ 内部，逐个列导出清单不现实；
      // 隐藏可见性下漏一个就是**运行期**加载失败（链接期看不出来）。
      final text = File(cmake).readAsStringSync();
      expect(text, contains('CXX_VISIBILITY_PRESET default'));
    });

    test('STL 用的是 c++_shared —— 有 C++ 对象跨 .so 边界，这不是可选项', () {
      // 默认的 c++_static 会让两个 .so 各嵌一份 libc++，同一类型的 typeinfo
      // 有两个互不相等的地址，跨边界 catch 接不住。症状是运行期随机崩。
      final gradle =
          File('packages/deep_unzip_engine/android/build.gradle').readAsStringSync();
      expect(gradle, contains('ANDROID_STL=c++_shared'));
    });
  });

  group('许可全文真的打进了包', () {
    test('两份许可文件都在，而且不是空壳', () {
      for (final path in [kSevenZipLicenseAsset, kLgpl21Asset]) {
        final f = File(path);
        expect(f.existsSync(), isTrue, reason: '$path 不在仓库里');
        expect(f.lengthSync(), greaterThan(1000),
            reason: '$path 只有 ${f.lengthSync()} 字节，像是占位符');
      }
    });

    test('LGPL 全文里有关键句 —— 别拿一份摘要冒充全文', () {
      // LGPL-2.1 §6 要的是「a copy of this License」，所以这里断的是正文里
      // 才有的句子，不是那份「This library is free software…」的声明。
      final text = File(kLgpl21Asset).readAsStringSync();
      expect(text, contains('GNU LESSER GENERAL PUBLIC LICENSE'));
      expect(text, contains('Version 2.1, February 1999'));
      expect(text, contains('TERMS AND CONDITIONS FOR COPYING, DISTRIBUTION'));
    });

    test('7-Zip 那份里有 unRAR 限制与两份 BSD 的正文', () {
      final text = File(kSevenZipLicenseAsset).readAsStringSync();
      expect(text, contains('unRAR license restriction'));
      expect(text, contains('GNU LGPL'));
      expect(text, contains('BSD 3-clause'));
      expect(text, contains('BSD 2-clause'));
      expect(text, contains('Igor Pavlov'));
      // 许可里明确禁止的那件事，要在正文里找得到，不能只靠我们的转述。
      expect(text, contains('cannot be used to re-create the RAR compression'));
    });

    test('打进去的 7-Zip 许可是 third_party 里那份的副本', () {
      // 升级 7-Zip 时 `DOC/License.txt` 会变（版权年份、组件清单都可能变），
      // 而 asset 是手拷的一份 —— 忘了重拷，关于页就会摆着上一版的许可。
      const vendored =
          'packages/deep_unzip_engine/third_party/7zip/DOC/License.txt';
      expect(File(vendored).existsSync(), isTrue);
      expect(
        File(kSevenZipLicenseAsset).readAsStringSync(),
        File(vendored).readAsStringSync(),
        reason: '重新执行：cp $vendored assets/licenses/7zip.txt',
      );
    });
  });

  group('关于页', () {
    testWidgets('摆出名字、版本与那句可核查的隐私声明', (tester) async {
      await pumpAbout(tester);

      expect(find.text(kAppName), findsOneWidget);
      expect(find.text('版本 $kAppVersion'), findsOneWidget);
      expect(find.text('不联网 · 不收集个人信息'), findsOneWidget);
      expect(find.textContaining('不申请网络权限'), findsOneWidget,
          reason: 'Release 包确实不声明 INTERNET，这句话是可核查的');
      expect(find.textContaining('Release 包不声明 INTERNET'), findsOneWidget);
    });

    testWidgets('第三方组件逐条列出，7-Zip 那条带着 unRAR 限制的说明', (tester) async {
      await pumpAbout(tester);

      for (final n in kThirdPartyNotices) {
        expect(find.text(n.name), findsOneWidget, reason: '少了 ${n.name}');
      }
      // 许可名必须在**正文里**说出来（`LGPL-2.1+ · unRAR 限制` 那个小标签已经
      // 去掉了）—— LGPL-2.1 §6 要的是「注明该库及其使用受本许可约束」，只给一个
      // 标签本来也不够，这句话才是那半句。
      expect(find.textContaining('受 GNU LGPL 2.1'), findsOneWidget);
      expect(find.textContaining('不用于制作 RAR 压缩包'), findsOneWidget,
          reason: 'unRAR 那条限制必须原样交代 —— 它正是允许我们解压 RAR 的依据');
      expect(find.textContaining('**'), findsNothing,
          reason: '卡片里的是纯文本，Markdown 的星号会原样显示出来');
    });

    testWidgets('组件卡不可点 —— 声明归声明，全文归全文', (tester) async {
      // 从前两边都能点，指向同一批文档：`7zip.txt` 三个入口、Flutter 许可页两个。
      // 更糟的是 `LZFSE / ZSTD / XXH64` 那张点开后标题写着这几个名字、内容却是
      // 整份 7-Zip 许可（那三个 BSD 组件的正文本来就嵌在里面、没有独立文件）。
      await pumpAbout(tester);

      expect(find.byType(InkWell), findsNWidgets(3),
          reason: '只有「许可全文」那一区三行可点；组件声明那三张不该有水波纹');

      // 真按一下：点了组件卡之后应当**还在关于页**，没有跳走。
      await tester.tap(find.text('7-Zip 解压核心'));
      await tester.pumpAndSettle();
      expect(find.text('第三方组件'), findsOneWidget, reason: '点了组件卡不该跳走');
      expect(find.textContaining('GNU LESSER GENERAL PUBLIC LICENSE'), findsNothing);
    });

    testWidgets('许可全文的入口都在', (tester) async {
      await pumpAbout(tester);

      expect(find.text('7-Zip 许可与限制（含 BSD 全文）'), findsOneWidget);
      expect(find.text('GNU LGPL 2.1 全文'), findsOneWidget);
      expect(find.text('Dart / Flutter 组件许可（自动收集）'), findsOneWidget);
    });

    testWidgets('点进 LGPL 全文 → 真的读到正文', (tester) async {
      await pumpAbout(tester);

      await tester.tap(find.text('GNU LGPL 2.1 全文'));
      await tester.pumpAndSettle();

      // 走的是 `rootBundle.loadString`。这条同时钉住「asset 声明在 pubspec 里」
      // 和「读取路径没写错」—— 少了任一个，这里会是那句读不出来的错误文案。
      expect(find.textContaining('GNU LESSER GENERAL PUBLIC LICENSE'),
          findsOneWidget);
      expect(find.textContaining('许可文本读不出来'), findsNothing);
    });

    testWidgets('点进 7-Zip 许可 → unRAR 那段限制读得到', (tester) async {
      await pumpAbout(tester);

      await tester.tap(find.text('7-Zip 许可与限制（含 BSD 全文）'));
      await tester.pumpAndSettle();

      expect(find.textContaining('unRAR license restriction'), findsOneWidget);
    });

    testWidgets('Dart 组件那条走 Flutter 自带的许可页', (tester) async {
      await pumpAbout(tester);

      await tester.tap(find.text('Dart / Flutter 组件许可（自动收集）'));
      await tester.pumpAndSettle();

      // `showLicensePage` 是 Material 标准页，标题取自传进去的应用名。
      expect(find.byType(LicensePage), findsOneWidget);
      expect(find.textContaining(kAppName), findsWidgets);
    });
  });

  testWidgets('关于页用的主题是应用自己的，不是 Material 默认', (tester) async {
    // 这页有一半是给**用户和外审**看的，白底蓝按钮会很突兀 —— 顺手钉一下。
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.dark,
      home: const AboutScreen(),
    ));

    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
    expect(scaffold.backgroundColor, AppTheme.bgDeep);
  });
}
