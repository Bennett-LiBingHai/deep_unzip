import 'package:flutter/material.dart';
import '../../theme/app_theme.dart';
import 'bottom_modal.dart';
import 'modal_button.dart';

/// 解压错误弹窗 —— 暂停 / 跳过
///
/// 两个按钮的**文案可以改**（[pauseLabel] / [skipLabel]），因为同一个弹窗形状
/// 被两种语义复用：解压途中出错时左边是「暂停任务」（暂停是真能恢复的，
/// 见 `AppState.pauseExtract`）；而炸弹/空间闸门拦下时左边是「停止这批」
/// —— 那一档会丢掉剩余队列、**不可恢复**（见 `dialog_bridge.dart` 里那段说明）。
/// 两种情况共用「左边橙、右边渐变」的排布，但要说的话不一样。回调参数名
/// 沿用 `onPause`/`onSkip` 不改：改它会牵动所有调用点，而它只描述位置。
class ErrorModal extends StatelessWidget {
  final String fileName;
  final String reason;
  final VoidCallback onPause;
  final VoidCallback onSkip;
  final String pauseLabel;
  final String skipLabel;

  const ErrorModal({
    super.key,
    required this.fileName,
    required this.reason,
    required this.onPause,
    required this.onSkip,
    this.pauseLabel = '暂停任务',
    this.skipLabel = '跳过继续',
  });

  static Future<void> show({
    required BuildContext context,
    required String fileName,
    required String reason,
    required VoidCallback onPause,
    required VoidCallback onSkip,
    String pauseLabel = '暂停任务',
    String skipLabel = '跳过继续',
  }) {
    return showBottomModal(
      context: context,
      child: ErrorModal(
        fileName: fileName,
        reason: reason,
        onPause: onPause,
        onSkip: onSkip,
        pauseLabel: pauseLabel,
        skipLabel: skipLabel,
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
                child: ModalButton(
                  label: pauseLabel,
                  color: AppTheme.neonOrange,
                  onTap: () {
                    Navigator.pop(context);
                    onPause();
                  },
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ModalButton(
                  label: skipLabel,
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
