import 'package:flutter/material.dart';

import '../../models/password_entry.dart';
import '../../theme/app_theme.dart';
import 'bottom_modal.dart';
import 'modal_button.dart';

/// 从密码库里删掉一条之前的确认弹窗。
///
/// 为什么值得挡一道：库里这一条是**唯一一份** —— 没有回收站、没有备份，删掉
/// 之后下次再遇到那个加密包，弹窗里连一个候选都拿不出来，用户只能凭记忆手敲
/// （想不起来就是解不开）。而那颗垃圾桶按钮只有 14pt、紧挨着密码文本，手滑的
/// 代价可能是一个再也想不起来的密码，这类不可逆的删除值得一次确认。
///
/// 与 [ClearLogsModal] 同构：都摆出「将删除什么」，都用红色实心做主操作、
/// 灰色描边做取消，滑掉一律算取消。
class DeletePasswordModal extends StatelessWidget {
  /// 将被删掉的那一条。
  final PasswordEntry entry;

  const DeletePasswordModal({super.key, required this.entry});

  /// 返回用户是否确认。**滑掉弹窗返回 false**（`showBottomModal` 可被手势
  /// 关掉且不给结果，`showModalBottomSheet` 这时给的是 null）—— 默认取「取消」
  /// 而不是「删除」是因为删掉找不回来，手滑关掉不该等于同意。
  static Future<bool> show({
    required BuildContext context,
    required PasswordEntry entry,
  }) async {
    final result = await showBottomModal<bool>(
      context: context,
      child: DeletePasswordModal(entry: entry),
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
              const Icon(Icons.lock_open_outlined,
                  color: AppTheme.neonRed, size: 20),
              const SizedBox(width: 10),
              const Text(
                '删除这条密码',
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
            '密码仅保存在本机，删除后无法恢复',
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '将删除',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppTheme.textDim,
                    fontFamily: 'monospace',
                  ),
                ),
                const SizedBox(height: 6),
                // 把密码本身摆出来，不是多此一举：库里常有几条长得几乎一样的
                // （同一批包的一串口令），只说「确定删除吗」等于让用户猜自己点
                // 的是哪一条。列表里本来就是明文，这里也没有新泄露什么。
                Text(
                  entry.value,
                  style: const TextStyle(
                    fontSize: 14,
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.w600,
                    color: AppTheme.textPrimary,
                    letterSpacing: 1,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '已匹配 ${entry.hitCount} 次',
                  style: const TextStyle(
                    fontSize: 10,
                    fontFamily: 'monospace',
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
                  label: '删除',
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
