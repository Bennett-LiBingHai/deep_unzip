import 'package:flutter/material.dart';
import '../../theme/app_theme.dart';
import 'bottom_modal.dart';

/// 解压错误弹窗 —— 暂停 / 跳过
class ErrorModal extends StatelessWidget {
  final String fileName;
  final String reason;
  final VoidCallback onPause;
  final VoidCallback onSkip;

  const ErrorModal({
    super.key,
    required this.fileName,
    required this.reason,
    required this.onPause,
    required this.onSkip,
  });

  static Future<void> show({
    required BuildContext context,
    required String fileName,
    required String reason,
    required VoidCallback onPause,
    required VoidCallback onSkip,
  }) {
    return showBottomModal(
      context: context,
      child: ErrorModal(
        fileName: fileName,
        reason: reason,
        onPause: onPause,
        onSkip: onSkip,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
      child: Column(
        children: [
          Container(
            width: 56,
            height: 56,
            margin: const EdgeInsets.only(bottom: 16),
            decoration: BoxDecoration(
              color: AppTheme.neonRed.withOpacity(0.12),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppTheme.neonRed.withOpacity(0.3)),
            ),
            child: const Icon(Icons.error_outline,
                color: AppTheme.neonRed, size: 28),
          ),
          const Text('解压遇到问题',
              style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.textPrimary)),
          const SizedBox(height: 6),
          const Text('以下文件无法正常解压',
              style: TextStyle(
                  fontSize: 12,
                  color: AppTheme.textDim,
                  fontFamily: 'monospace')),
          const SizedBox(height: 18),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppTheme.neonRed.withOpacity(0.06),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.neonRed.withOpacity(0.15)),
            ),
            child: Text(fileName,
                style: const TextStyle(
                    fontSize: 12,
                    fontFamily: 'monospace',
                    color: AppTheme.neonRed)),
          ),
          const SizedBox(height: 12),
          Text(reason,
              style: const TextStyle(
                  fontSize: 12,
                  color: AppTheme.textSecondary,
                  height: 1.6)),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: _ModalBtn(
                  label: '暂停任务',
                  color: AppTheme.neonOrange,
                  onTap: () {
                    Navigator.pop(context);
                    onPause();
                  },
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _ModalBtn(
                  label: '跳过继续',
                  gradient: AppTheme.primaryGradient,
                  onTap: () {
                    Navigator.pop(context);
                    onSkip();
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ModalBtn extends StatelessWidget {
  final String label;
  final Color? color;
  final Gradient? gradient;
  final VoidCallback onTap;
  const _ModalBtn(
      {required this.label, this.color, this.gradient, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: gradient == null ? color!.withOpacity(0.12) : null,
          gradient: gradient,
          borderRadius: BorderRadius.circular(12),
          border: gradient == null
              ? Border.all(color: color!.withOpacity(0.3))
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
