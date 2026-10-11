import 'package:deep_unzip/theme/app_theme.dart';
import 'package:deep_unzip/widgets/modals/format_detect_modal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「处理方式」那一行是全卡片里**唯一**会随文件内容变长的一格。
///
/// 另外三行（声明后缀 / 文件头 / 真实格式）都是定长的小词，只有它会写成
/// `按 RAR 压缩包 解压（前面有 885788 字节前置数据）`—— 三十来个字符，其中
/// 大半是等宽字体下的全角字。窄屏上单行放不下，而从前这里是两个裸 `Text`
/// 加 `spaceBetween`，放不下就直接溢出成黄黑条纹。
///
/// 这一条为什么值得单独测：溢出不报错、不崩，只是把条纹画出来，代码看着也
/// 「对」；只有把屏幕压窄、把最长的那句摆进去才看得见。
void main() {
  /// 真机上最长的那一档：格式名 + 前置数据长度。
  const longestAction = '按 RAR 压缩包 解压（前面有 885788 字节前置数据）';

  Future<void> pumpModal(
    WidgetTester tester, {
    required String action,
    Size? surface,
  }) async {
    if (surface != null) {
      tester.view.devicePixelRatio = 3.0;
      tester.view.physicalSize = surface * 3.0;
      addTearDown(tester.view.reset);
    }
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.dark,
      home: Scaffold(
        body: FormatDetectModal(
          fileName: '提弗炸卸_差分.png',
          fakeExt: 'png',
          fileHeader: '0x504B0304',
          realFormat: 'RAR 压缩包',
          action: action,
          hexPreview: '50 4B 03 04 14 00 00 00',
          onConfirm: () {},
          onCancel: () {},
        ),
      ),
    ));
  }

  testWidgets('360dp 窄屏 + 最长的那句「处理方式」：折行，不溢出', (tester) async {
    // 360dp 是国产机里最窄的常见一档。放不下时 `RenderFlex` 会报 overflow，
    // 那个错误会让这条用例直接红 —— 所以这里不需要额外的断言来「证明没溢出」。
    await pumpModal(tester, action: longestAction,
        surface: const Size(360, 640));

    expect(find.text(longestAction), findsOneWidget,
        reason: '整句都要在卡片上，不能为了不溢出把它截成省略号 —— '
            '「前面有 885788 字节前置数据」正是用户要核对的那半句');
    expect(find.text('处理方式'), findsOneWidget);
  });

  testWidgets('短句仍然单行右对齐，与改动前长得一样', (tester) async {
    await pumpModal(tester, action: '按 ZIP 压缩包 解压',
        surface: const Size(360, 640));

    expect(find.text('按 ZIP 压缩包 解压'), findsOneWidget);
    expect(find.text('声明后缀'), findsOneWidget);
    expect(find.text('真实格式'), findsOneWidget);
  });

  testWidgets('四行标签一个不少（折行没有把别的行挤掉）', (tester) async {
    await pumpModal(tester, action: longestAction,
        surface: const Size(360, 640));

    for (final label in ['声明后缀', '文件头', '真实格式', '处理方式']) {
      expect(find.text(label), findsOneWidget);
    }
  });
}
