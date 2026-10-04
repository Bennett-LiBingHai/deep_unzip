import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import 'bottom_modal.dart';
import 'modal_button.dart';

/// 清空日志前的确认弹窗。
///
/// 为什么值得挡一道：日志是**只在本机留存**的操作历史，删掉就再也找不回来
/// —— 没有云备份、没有回收站，`_persistLogs()` 一落盘，磁盘上那份就跟着没了。
/// 页面右上角那颗按钮又小又挨着标题，手滑点到的代价却是全部历史，这类不可逆
/// 的删除值得一次确认。
///
/// 确认按钮用红色实心、取消用灰色描边：把「哪一颗会造成后果」摆在颜色上，
/// 不指望用户去读两行字。红渐变就地定义而不进 `AppTheme` —— 目前只有这一处
/// 用，等第二处出现再往上提。
class ClearLogsModal extends StatelessWidget {
  /// 会被删掉的条数。摆出来是因为「清空」两个字没说是清多少 —— 用户可能在
  /// 筛选过的视图里点的，得让他知道删的是**全部**而不只是眼前这几条。
  final int count;

  const ClearLogsModal({super.key, required this.count});

  static const _dangerGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFFF43F5E), Color(0xFFFF7A8A)],
  );

  /// 返回用户是否确认。**滑掉弹窗返回 false**（`showBottomModal` 可被手势
  /// 关掉且不给结果，`showModalBottomSheet` 这时给的是 null）—— 默认取「取消」
  /// 而不是「清空」是因为这一步不可逆，手滑关掉不该等于同意。
  static Future<bool> show({
    required BuildContext context,
    required int count,
  }) async {
    final result = await showBottomModal<bool>(
      context: context,
      child: ClearLogsModal(count: count),
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
              const Icon(Icons.delete_forever_outlined,
                  color: AppTheme.neonRed, size: 20),
              const SizedBox(width: 10),
              const Text(
                '清空日志',
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
            '这是一份只在本机留存的操作历史，清空后无法恢复',
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
              border: Border.all(color: AppTheme.neonRed.withValues(alpha: 0.15)),
            ),
            child: Row(
              children: [
                const Text(
                  '将删除',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppTheme.textDim,
                    fontFamily: 'monospace',
                  ),
                ),
                const Spacer(),
                Text(
                  '$count 条记录',
                  style: const TextStyle(
                    fontSize: 12,
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.w600,
                    color: AppTheme.neonRed,
                  ),
                ),
              ],
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
                  label: '清空',
                  gradient: _dangerGradient,
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
