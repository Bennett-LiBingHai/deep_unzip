import 'package:flutter/material.dart';

import '../../data/persist.dart';
import '../../engine/format.dart';
import '../../theme/app_theme.dart';
import 'value_input_modal.dart';

/// 改最大递归深度。确定后 `pop` 回新的层数；取消（含手势滑走）回 `null`。
///
/// 深度是**自由输入**而不是几档固定值，和日志保留条数同一个理由：这个数只跟
/// 用户的包有多深有关，替他挑几档等于让他从几个别人的答案里选。可填范围
/// [kMinMaxDepth]–[kMaxMaxDepth]（见 `persist.dart`），填到界外会在预览行上
/// 直说，而不是悄悄夹一下。
///
/// ## 「一层」是什么
///
/// 数的是**从被选目录往下走了几步**，而「一步」有两种、**同等计入**：
/// **进一层子目录**、**解开一层嵌套包**。名字里那个「递归」只描述了后一种，
/// 念起来容易以为前一种不算 —— 说明里**两个都必须写**。
///
/// 这条规则对**顶层那批包一视同仁**（2026-10 补上的，见
/// `AppState._runExtractBatch` 里播种那段）：`子目录/a.zip` 与 `a.zip` 的
/// 差别就是前者多占一层，所以 `maxDepth = 0` 时它压根不会被解。
/// 在那之前顶层是无条件排队的 —— `0` 拦得住包**里面**的嵌套包，却拦不住
/// **目录里面**的包，而按上面那条规则后者离被选目录更远。
///
/// **`0` 是这一档里唯一需要解释的值** —— 它表示「不递归」：只有**直接躺在
/// 被选目录下**的包会被解，再往下（进子目录、或包里面还有包）都不走了。
/// 所以预览行把 0 说成「不递归」而不是「0 层」，后者读起来像是「浅浅地解
/// 一层」，正好是反的。设置页那颗 chip 用的是同一套说法
/// （见 `settings_screen.dart`）。
class MaxDepthModal {
  const MaxDepthModal._();

  static Future<int?> show({
    required BuildContext context,
    required int current,
  }) {
    return ValueInputModal.show(
      context: context,
      icon: Icons.layers_outlined,
      accent: AppTheme.neonCyan,
      title: '最大递归深度',
      subtitle: '从选中的目录往下数：进一层子目录、解一层嵌套包各算一层；0 表示不递归',
      initialText: '$current',
      inputHint: '如：20',
      parse: parseNonNegativeCount,
      preview: (v) => v == 0 ? '不递归' : '最多 $v 层',
      // 界外**不夹**，直接不给提交：夹一下用户会以为自己填的数生效了。
      // 下界不用查 —— `parseNonNegativeCount` 只认非负整数。
      check: (v) => v > kMaxMaxDepth ? '最多 $kMaxMaxDepth 层' : null,
      keyboardType: TextInputType.number,
    );
  }
}
