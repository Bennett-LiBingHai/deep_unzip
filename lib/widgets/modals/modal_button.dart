import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// 弹窗底部的操作按钮。两种形态二选一：
///
/// - 传 [gradient]：实心主操作（通常是「确认 / 继续」这类正向前进的动作用）。
/// - 传 [color]：描边弱操作（「取消 / 暂停」这类）。
///
/// 本来它是 `error_modal.dart` 里的私有类，确认弹窗要第二份时才提出来 ——
/// 三份就该改成组件了，两份的时候抄一遍也还行，但抄出来的那份迟早会和另一份
/// 长得不一样。
class ModalButton extends StatelessWidget {
  final String label;
  final Color? color;
  final Gradient? gradient;
  final VoidCallback onTap;

  const ModalButton({
    super.key,
    required this.label,
    this.color,
    this.gradient,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    assert(
      (color == null) != (gradient == null),
      'ModalButton 必须二选一：要么给 color（描边），要么给 gradient（实心）',
    );
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: gradient == null ? color!.withValues(alpha: 0.12) : null,
          gradient: gradient,
          borderRadius: BorderRadius.circular(12),
          border: gradient == null
              ? Border.all(color: color!.withValues(alpha: 0.3))
              : null,
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: gradient != null ? AppTheme.bgDeep : color,
          ),
        ),
      ),
    );
  }
}
