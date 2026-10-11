import 'package:flutter/material.dart';

import '../../data/persist.dart';
import '../../engine/format.dart';
import '../../theme/app_theme.dart';
import 'value_input_modal.dart';

/// 改「前置数据搜索窗口」。确定后 `pop` 回新的字节数；取消（含手势滑走）回 `null`。
///
/// 与 [MaxDepthModal] 同构，只是把解析换成**字节量**（`parseSize` /
/// `formatBytes`）—— 这一项的单位是字节，用户想填 `8 MB` 而不是 `8388608`。
///
/// ## 为什么下界要说清「不是调到这儿会坏」
///
/// 可填范围是 [kMinSniffWindow]–[kMaxSniffWindow]，但下界的含义与别处不同：
/// 它**不是**「再小程序就出问题」，而是「再小对分享包的封面就没意义了」。这条
/// 搜索只服务「图片等文件后面追加的压缩包」这一种场景，够不着自解压包那条既有的
/// 路 —— 所以窗口调到多小，今天能认出的东西明天照样认得出。说明里要写这一句，
/// 否则用户会以为调小是在冒险。
class SniffWindowModal {
  const SniffWindowModal._();

  static const String kTitle = '前置数据搜索窗口';

  static const String kSubtitle =
      '压缩包整段追加在图片等文件后面时，向前搜索的深度。'
      '只影响这一条搜索，自解压包那条路不受影响';

  static Future<int?> show({
    required BuildContext context,
    required int current,
  }) {
    return ValueInputModal.show(
      context: context,
      icon: Icons.travel_explore_outlined,
      accent: AppTheme.neonCyan,
      title: kTitle,
      subtitle: kSubtitle,
      // 预填**展示形态**（`1.0 MB`）而不是裸字节数：用户看到的就是设置页那一行。
      initialText: formatBytes(current),
      inputHint: '如：1 MB、8 MB',
      parse: parseSize,
      preview: formatBytes,
      // 界外**不夹**，直接不给提交 —— 夹一下用户会以为自己填的数生效了。
      check: (v) => v < kMinSniffWindow
          ? '最小 ${formatBytes(kMinSniffWindow)}'
          : v > kMaxSniffWindow
              ? '最大 ${formatBytes(kMaxSniffWindow)}'
              : null,
      keyboardType: TextInputType.text,
    );
  }
}
