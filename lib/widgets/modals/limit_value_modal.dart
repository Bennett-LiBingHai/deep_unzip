import 'package:flutter/material.dart';

import '../../engine/format.dart';
import '../../engine/limits.dart';
import '../../theme/app_theme.dart';
import 'value_input_modal.dart';

/// 改一项炸弹防护阈值。确定后 `pop` 回解析好的数字；取消（含手势滑走）回 `null`。
///
/// 排版与置灰逻辑都在 [ValueInputModal] 里（那个弹窗是通用的「一个数字的编辑
/// 框」），这里只负责把 [LimitField] 翻译成它认的那几个参数：标签当标题、提示
/// 当说明、`isBytes` 决定用 [parseSize] 还是 [parseCount] 解析。
///
/// ## 为什么不做成一个「四个输入框」的大表单
///
/// 那样要一次校验四行、一起提交，用户改错一项没法只退一项。一次一行、
/// 即改即生效，跟设置页其它控件的节奏一致。
class LimitValueModal {
  const LimitValueModal._();

  /// 返回 [field] 的新值；取消时返回 null。
  static Future<int?> show({
    required BuildContext context,
    required LimitField field,
    required LimitThresholds current,
  }) {
    return ValueInputModal.show(
      context: context,
      icon: Icons.shield_outlined,
      accent: AppTheme.neonPurple,
      title: field.label,
      subtitle: field.hint,
      // 预填当前值的**展示形态**（`8 GB` / `200,000`）而不是裸字节数：
      // 用户看到的就是设置页上那一行，改的是数字，单位原样留着。
      initialText: field.display(current),
      inputHint: field.isBytes ? '如：8 GB、512 MB' : '如：200000',
      parse: field.isBytes ? parseSize : parseCount,
      preview: field.isBytes ? formatBytes : formatCount,
    );
  }
}
