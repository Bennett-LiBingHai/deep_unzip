import 'package:flutter/material.dart';
import '../../theme/app_theme.dart';
import 'bottom_modal.dart';
import 'modal_button.dart';

/// 解压问题弹窗 —— 继续 / 停止
///
/// 左边那颗是**不可恢复**的停止：停掉这一批，队列里剩下的包全丢（真要续传得
/// 等 journal）。右边那颗是「这个包不要了，接着解下一个」。
///
/// 两种场景复用同一个形状：炸弹/空间闸门拦下，和解压途中出错 —— 两边的两个
/// 决断含义完全一样（见 `prompts.dart` 的表），所以文案也一样。
///
/// 回调名从 `onPause`/`onSkip` 改成了 [onStop]/[onContinue]：在这两档里本来
/// 就没有「暂停」这回事，旧名字会让人以为左边那颗停得回来 —— 那正是这次要
/// 消掉的误会。文案仍走参数（默认就是「停止 / 继续」），由 `dialog_bridge`
/// 这边统一给，改一处即可。
class ErrorModal extends StatelessWidget {
  final String fileName;
  final String reason;
  final VoidCallback onStop;
  final VoidCallback onContinue;
  final String stopLabel;
  final String continueLabel;

  const ErrorModal({
    super.key,
    required this.fileName,
    required this.reason,
    required this.onStop,
    required this.onContinue,
    this.stopLabel = '停止',
    this.continueLabel = '继续',
  });

  static Future<void> show({
    required BuildContext context,
    required String fileName,
    required String reason,
    required VoidCallback onStop,
    required VoidCallback onContinue,
    String stopLabel = '停止',
    String continueLabel = '继续',
  }) {
    return showBottomModal(
      context: context,
      child: ErrorModal(
        fileName: fileName,
        reason: reason,
        onStop: onStop,
        onContinue: onContinue,
        stopLabel: stopLabel,
        continueLabel: continueLabel,
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
                  label: stopLabel,
                  color: AppTheme.neonOrange,
                  onTap: () {
                    Navigator.pop(context);
                    onStop();
                  },
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ModalButton(
                  label: continueLabel,
                  gradient: AppTheme.primaryGradient,
                  onTap: () {
                    Navigator.pop(context);
                    onContinue();
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
