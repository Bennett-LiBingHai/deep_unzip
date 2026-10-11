import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import 'bottom_modal.dart';
import 'modal_button.dart';

/// 开启「解压成功后自动删除源压缩包」之前的确认弹窗。
///
/// 为什么值得挡一道：这颗开关一旦打开，后面每一次解压成功都会**真的删掉用户的
/// 源压缩包** —— 没有回收站、没有备份，本软件也从不往网络上送东西，所以删掉
/// 就是删掉。用户此刻多半只是顺手拨一下开关，未必意识到这一点，值得一次确认。
///
/// 注意**只在「开」的方向弹**：关掉不造成任何后果，不该挡（见
/// `settings_screen.dart` 里那个方法）。
///
/// 结构与 [ClearLogsModal] 一致：红底卡片、标签「将删除」、红色实心主操作、
/// 灰色描边取消、滑掉算取消。
class AutoDeleteSourceModal extends StatelessWidget {
  const AutoDeleteSourceModal({super.key});

  /// 返回用户是否确认开启。**滑掉弹窗返回 false** —— 这一步不可逆，手滑关掉
  /// 不该等于同意（理由同 [ClearLogsModal.show]）。
  static Future<bool> show({required BuildContext context}) async {
    final result = await showBottomModal<bool>(
      context: context,
      child: const AutoDeleteSourceModal(),
    );
    return result ?? false;
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.delete_sweep_outlined,
                  color: AppTheme.neonRed, size: 20),
              const SizedBox(width: 10),
              const Text(
                '开启自动删除源压缩包',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.textPrimary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            '删除不可撤销，本软件没有回收站',
            style: TextStyle(
              fontSize: 12,
              color: AppTheme.textDim,
              fontFamily: 'monospace',
              height: 1.5,
            ),
          ),
          const SizedBox(height: 18),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppTheme.neonRed.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(12),
              border:
                  Border.all(color: AppTheme.neonRed.withValues(alpha: 0.15)),
            ),
            child: const Text(
              '每个解压成功的源压缩包及其分卷',
              style: TextStyle(
                fontSize: 12,
                fontFamily: 'monospace',
                fontWeight: FontWeight.w600,
                color: AppTheme.neonRed,
              ),
            ),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: ModalButton(
                  label: '取消',
                  color: AppTheme.textSecondary,
                  onTap: () => Navigator.pop(context, false),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ModalButton(
                  label: '开启',
                  gradient: AppTheme.dangerGradient,
                  onTap: () => Navigator.pop(context, true),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
