import 'package:deep_unzip/data/persist.dart';
import 'package:deep_unzip/models/password_entry.dart';
import 'package:deep_unzip/providers/app_state.dart';
import 'package:deep_unzip/screens/vault_screen.dart';
import 'package:deep_unzip/theme/app_theme.dart';
import 'package:deep_unzip/widgets/glass_card.dart';
import 'package:deep_unzip/widgets/modals/delete_password_modal.dart';
import 'package:deep_unzip/widgets/modals/modal_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_engine.dart';
import '../support/fake_store.dart';

/// 密码库点垃圾桶：**先问一道**。
///
/// 这组要盯的是一步不可逆的删除，所以断言的重点不是「有没有弹窗」，而是：
/// 弹窗说清了删的是哪一条、取消之后是不是真的没动、确认之后删掉的是**被点的
/// 那一条**（库里几条长得像的时候，这条最容易写错 —— 用下标删、而弹窗又允许
/// 划走的写法，很容易删到隔壁）。
void main() {
  // 与 log_screen_test 同样的理由：默认 `tap()` 打不中只警告不报错，
  // 「点了没反应」会在压根没点到的前提下通过。
  setUpAll(() => WidgetController.hitTestWarningShouldBeFatal = true);

  late FakeStore store;
  late AppState state;

  /// 挂上密码库，库里预置 [passwords]（按给的顺序）。
  Future<void> pumpVault(
    WidgetTester tester, {
    List<String> passwords = const [],
  }) async {
    store = FakeStore()
      ..toLoad = AppSnapshot(
        vault: [
          for (final v in passwords) PasswordEntry(value: v, lastUsed: '今天'),
        ],
      );
    state = AppState(
      engine: FakeEngine(),
      persistStore: store,
      restore: store.toLoad,
    );
    addTearDown(state.dispose);

    await tester.binding.setSurfaceSize(const Size(800, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.dark,
      home: Scaffold(body: VaultScreen(state: state)),
    ));
  }

  /// [pwd] 那一行右边那颗垃圾桶。
  ///
  /// **必须圈到那张卡片里找**：库里不止一条时全页有好几颗一模一样的图标，
  /// 不圈就是「找到 2 个」。圈在 `GlassCard` 里还有个副作用是正好排除了
  /// 弹窗里的那颗（弹窗不是卡片），所以弹窗开着时这个 Finder 照样唯一。
  Finder trashOf(String pwd) => find.descendant(
        of: find.ancestor(of: find.text(pwd), matching: find.byType(GlassCard)),
        matching: find.byIcon(Icons.delete_outline),
      );

  /// 点某一条的垃圾桶，等弹窗起来。
  Future<void> tapDelete(WidgetTester tester, String pwd) async {
    await tester.tap(trashOf(pwd));
    await tester.pumpAndSettle();
  }

  /// 弹窗里的按钮。页面上的「添加」和卡片里的图标都不会撞上这个名字。
  Finder modalButton(String label) => find.widgetWithText(ModalButton, label);

  testWidgets('点垃圾桶只弹窗，密码还在库里', (tester) async {
    await pumpVault(tester, passwords: ['correct-horse']);

    await tapDelete(tester, 'correct-horse');

    expect(find.byType(DeletePasswordModal), findsOneWidget);
    expect(
      state.passwords.map((p) => p.value),
      ['correct-horse'],
      reason: '弹窗还没确认，这一条不该已经没了',
    );
  });

  testWidgets('弹窗里认得出是哪一条 —— 摆出密码本身，不是一句「确定吗」', (tester) async {
    // 同一批压缩包的一串口令长得很像，只说「确定删除吗」等于让用户猜自己点的是
    // 哪一条。所以把值摆出来，顺便带上它被用过几次。
    await pumpVault(tester, passwords: ['correct-horse', 'backup-1999']);

    await tapDelete(tester, 'backup-1999');

    expect(
      find.descendant(
        of: find.byType(DeletePasswordModal),
        matching: find.text('backup-1999'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(DeletePasswordModal),
        matching: find.text('correct-horse'),
      ),
      findsNothing,
      reason: '弹窗里出现另一条，用户会以为要删的是它',
    );
    expect(find.text('已匹配 0 次'), findsOneWidget);
  });

  testWidgets('取消 → 一条没少，也没落盘', (tester) async {
    await pumpVault(tester, passwords: ['correct-horse']);
    final writesBefore = store.vaultSaved.length;

    await tapDelete(tester, 'correct-horse');
    await tester.tap(modalButton('取消'));
    await tester.pumpAndSettle();

    expect(find.byType(DeletePasswordModal), findsNothing);
    expect(state.passwords, hasLength(1));
    expect(store.vaultSaved, hasLength(writesBefore), reason: '取消不该写盘');
  });

  testWidgets('手势滑走 = 取消 —— 手滑关掉不该等于同意', (tester) async {
    await pumpVault(tester, passwords: ['correct-horse']);

    await tapDelete(tester, 'correct-horse');
    await tester.tapAt(const Offset(400, 20));
    await tester.pumpAndSettle();

    expect(find.byType(DeletePasswordModal), findsNothing);
    expect(state.passwords, hasLength(1));
  });

  testWidgets('确认 → 删掉的是**被点的**那一条，不是第一条', (tester) async {
    // 「按值重新定位」那段代码存在的全部理由。库里两条长得像的口令，
    // 点第二条的垃圾桶、确认，剩下必须是第一条。
    await pumpVault(tester, passwords: ['correct-horse', 'backup-1999']);

    await tapDelete(tester, 'backup-1999');
    await tester.tap(modalButton('删除'));
    await tester.pumpAndSettle();

    expect(find.byType(DeletePasswordModal), findsNothing, reason: '确定之后弹窗该关掉');
    expect(
      state.passwords.map((p) => p.value),
      ['correct-horse'],
      reason: '删的是被点的那条，不是列表里的第一条',
    );
    expect(find.text('backup-1999'), findsNothing, reason: '页面上该跟着刷新');
    expect(store.lastVault?.map((p) => p.value), ['correct-horse'],
        reason: '删完得把剩下的那份写出去');
    expect(state.toastMsg, '密码已删除');

    // 收尾：`showToast` 挂了个 2 秒后清空自己的定时器，`testWidgets` 结束时会
    // 检查有没有未完成的定时器 —— 不收掉就是一条跟被测行为无关的假失败。
    // 断言必须排在前面：真让这 2 秒走完，toast 会把自己清成 null。
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('库里最后一条也能删干净 —— 删完落盘的是空库，不是没写', (tester) async {
    // 「按值重新定位」的失败模式是这个：`indexWhere` 找不着时如果放任下标为
    // -1，`removeAt(-1)` 会抛 RangeError 把页面打崩。这里守住找得着的那一半，
    // 顺带确认删除会写盘（不然重启后那条又回来了）。
    await pumpVault(tester, passwords: ['correct-horse']);

    await tapDelete(tester, 'correct-horse');
    await tester.tap(modalButton('删除'));
    await tester.pumpAndSettle();

    expect(state.passwords, isEmpty);
    expect(store.lastVault, isEmpty);
    // 摘要卡上「0」有两个：左边的已保存密码数（紫）、右边的累计命中（绿）。
    // 删掉唯一一条之后两个都是 0，所以 `find.text('0')` 会找到两个。
    //
    // **靠颜色认人，别靠字号也别靠位置。** 字号这条踩过一次：右边那格原本是
    // 18pt，换成真计数之后统一成 28pt（两格一样大），按字号筛会一次命中共两个。
    // 位置是渲染顺序，改一次布局就错；颜色是这两格的固有区别。
    expect(
      find.byWidgetPredicate(
        (w) =>
            w is Text && w.data == '0' && w.style?.color == AppTheme.neonPurple,
      ),
      findsOneWidget,
      reason: '摘要卡上的「已保存密码」该归零',
    );

    await tester.pump(const Duration(seconds: 2));
  });
}
