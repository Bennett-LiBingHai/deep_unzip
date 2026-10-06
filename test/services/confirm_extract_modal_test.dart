import 'package:deep_unzip/theme/app_theme.dart';
import 'package:deep_unzip/widgets/modals/confirm_extract_modal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 确认弹窗上那行「输出到」是用户**唯一**能核对「这次会往哪写」的地方。
///
/// 「自定义输出目录」开着时它必须显示用户刚选的**整条路径**，而不是源目录的
/// 名字 —— 这一档输出压根不在源目录里，摆着源目录名就是在撒谎。摆整条路径还有
/// 另一个理由：用户可能有好几个都叫 `out` 的目录，只给名字等于没说。
///
/// 这一档为什么值得单独测：它跨了两个文件（`home_screen._onStart` 负责先问位
/// 置、`ConfirmExtractModal` 负责显示），而**顺序反了界面照样能渲染出来**，
/// 只是那行字会指向一个错的目录。
void main() {
  Future<void> pumpModal(
    WidgetTester tester, {
    required String outputRoot,
    String folderName = '来源目录',
  }) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.dark,
      home: Scaffold(
        body: ConfirmExtractModal(
          archiveCount: 2,
          encryptedCount: 0,
          splitCount: 0,
          folderName: folderName,
          outputRoot: outputRoot,
        ),
      ),
    ));
  }

  testWidgets('默认（对称输出）：输出到那一行摆源目录，说明说的是「旁边」', (tester) async {
    await pumpModal(tester, outputRoot: '');

    expect(find.text('输出到'), findsOneWidget);
    expect(find.text('来源目录'), findsOneWidget);
    expect(find.textContaining('每个压缩包旁边'), findsOneWidget);
    expect(find.textContaining('你指定的输出目录'), findsNothing,
        reason: '没开自定义就不该出现那一档的说法');
  });

  testWidgets('自定义：摆用户刚选的整条路径，源目录不再出现', (tester) async {
    await pumpModal(tester, outputRoot: '/sdcard/Download/duz_out');

    expect(find.text('输出到'), findsOneWidget);
    expect(find.text('/sdcard/Download/duz_out'), findsOneWidget,
        reason: '给整条路径 —— 只给 basename 的话，「out」有好几个也分不出来');
    expect(find.text('来源目录'), findsNothing,
        reason: '这一档输出不在源目录里，还摆着它就是在撒谎');
    expect(find.textContaining('你指定的输出目录'), findsOneWidget);
  });
}
