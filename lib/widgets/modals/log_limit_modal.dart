import 'package:flutter/material.dart';

import '../../data/persist.dart';
import '../../engine/format.dart';
import '../../theme/app_theme.dart';
import 'value_input_modal.dart';

/// 改日志保留条数。确定后 `pop` 回新的条数；取消（含手势滑走）回 `null`。
///
/// 条数是**自由输入**而不是几档固定值：这个数只跟用户的存储习惯有关，没有
/// 「大就是好」或「小就是省」的说法，替他挑三档等于让他从三个别人的答案里选。
/// 唯一的边界是 [kMinMaxLogs]–[kMaxMaxLogs]（见 `persist.dart`），填到界外
/// 会在预览行上直说，而不是悄悄夹一下。
class LogLimitModal {
  const LogLimitModal._();

  static Future<int?> show({
    required BuildContext context,
    required int current,
  }) {
    return ValueInputModal.show(
      context: context,
      icon: Icons.receipt_long_outlined,
      accent: AppTheme.neonCyan,
      title: '日志保留条数',
      subtitle: '超出后丢弃最早的记录；调小会立刻生效',
      initialText: '$current',
      inputHint: '如：300',
      parse: parseCount,
      preview: (v) => '$v 条',
      // 界外**不夹**，直接不给提交：夹一下用户会以为自己填的数生效了。
      check: (v) => v < kMinMaxLogs || v > kMaxMaxLogs
          ? '范围 $kMinMaxLogs – $kMaxMaxLogs 条'
          : null,
      keyboardType: TextInputType.number,
    );
  }
}
