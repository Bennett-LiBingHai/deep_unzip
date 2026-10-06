import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 清单里几行**删掉不会报错、只会在某个特定版本的手机上坏掉**的东西。
///
/// 筛选标准就这一条：编译不报错、别的测试不红、静态分析也看不出来。会报错的
/// 不用写测试 —— 编译器会拦。
void main() {
  // 断言前先把注释剥掉：这些行的旁边正好在解释「为什么不能删」「为什么不能写
  // 某个值」，直接在原文上搜会搜到注释自己（`res_theme_test.dart` 踩过）。
  final manifest = File('android/app/src/main/AndroidManifest.xml')
      .readAsStringSync()
      .replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');

  String attr(String name) {
    final m = RegExp('android:$name="([^"]*)"').firstMatch(manifest);
    expect(m, isNotNull, reason: '清单里没有 android:$name');
    return m!.group(1)!;
  }

  test('requestLegacyExternalStorage 还在 —— Android 10 全靠它', () {
    // API 29 是唯一「分区存储已强制、而 MANAGE_EXTERNAL_STORAGE 还没出生
    // （API 30 才有）」的版本。少了这一行，那一档上递归遍历任意目录做不到，
    // 而症状是「选了目录什么都扫不到」—— 没有任何地方会报错。
    // 完整理由见清单里那段注释。
    expect(attr('requestLegacyExternalStorage'), 'true');
  });

  test('前台服务的类型与它配套的权限成对', () {
    // Android 14+ 不声明类型的话，`startForeground` 直接抛
    // `MissingForegroundServiceTypeException` —— 解压一开工就崩。
    expect(attr('foregroundServiceType'), 'dataSync');
    expect(manifest, contains('android.permission.FOREGROUND_SERVICE_DATA_SYNC'),
        reason: '声明了类型却漏了对应权限，同样是启动即抛');
  });

  test('平台通道名两端逐字一致', () {
    // 这条通道是**三件事共用**的：前台服务保活、剩余空间探测、「打开输出目录」。
    // 两端写的是各自语言里的字符串常量，没有任何地方保证它们相等 —— 改包名 /
    // 顺手改名时只改一边，三个功能会**一起静默失效**：保活不起、空间退化成
    // 「未知」、打开目录退回 generic 那一档。都只影响可用性，不报错。
    const ktPath = 'android/app/src/main/kotlin/com/bennett/deep_unzip/'
        'MainActivity.kt';
    final kt = File(ktPath).readAsStringSync()
        .replaceAll(RegExp(r'//.*$', multiLine: true), '');
    final m = RegExp(r'const val CHANNEL = "([^"]+)"').firstMatch(kt);
    expect(m, isNotNull, reason: '$ktPath 里没找到 CHANNEL');

    final dart = File('lib/services/file_manager_bridge.dart').readAsStringSync();
    final d = RegExp(r"kFileManagerChannel = '([^']+)'").firstMatch(dart);
    expect(d, isNotNull, reason: 'file_manager_bridge.dart 里没找到 kFileManagerChannel');

    expect(d!.group(1), m!.group(1),
        reason: 'Kotlin 是 "${m.group(1)}"，Dart 是 "${d.group(1)}" —— '
            '对不上的话保活 / 空间探测 / 打开输出目录会一起失效，而且不报错');
  });

  test('源码清单里没有 INTERNET', () {
    // 「不联网、不收集个人信息」是可核查的那句声明，也是「单机应用免备案」
    // 那条判断的依据。
    //
    // **这条只覆盖我们自己写进清单的东西。** 插件可以在自己的 manifest 里声明
    // 权限，合并之后才看得见 —— 所以它挡不住「引了一个带网络权限的插件」。
    // 那个只有看构建产物才算数：
    //
    //     aapt2 dump badging build/app/outputs/flutter-apk/app-release.apk | grep INTERNET
    //
    // 不去读合并后的中间产物：那一份的**新鲜度**是另一件事（memory
    // `merged-manifest-intermediate-is-stale` 记过这个坑，拿昨天的文件能得出
    // 反向结论），测试里读它比读源码清单更不可靠。
    expect(manifest, isNot(contains('android.permission.INTERNET')));
  });
}
