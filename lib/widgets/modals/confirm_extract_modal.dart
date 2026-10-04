import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import 'bottom_modal.dart';
import 'modal_button.dart';

/// 点「开始智能解压」时的确认弹窗。
///
/// 为什么值得挡一道：解压会**真的往磁盘写目录**，而输出目录重名时会追加
/// `_1`/`_2`（见 `output_paths.dart`）—— 也就是说点错一次不会「覆盖」，而是
/// 留下一堆重复目录，只能人工去删。这类不可逆的写操作值得一次确认。
///
/// 页面里滚一下就能数出有几个包，但用户不会去数；把份数和里面有没有加密/
/// 分卷直接摆在按钮上面，比让他自己回忆更省事。
class ConfirmExtractModal extends StatelessWidget {
  /// 本次要解的压缩包个数。
  final int archiveCount;

  /// 其中带密码、需要走密码库试解的个数。
  final int encryptedCount;

  /// 其中是分片的个数。
  final int splitCount;

  /// 用户选的那个根目录，用来说明输出落在哪。
  final String folderName;

  const ConfirmExtractModal({
    super.key,
    required this.archiveCount,
    required this.encryptedCount,
    required this.splitCount,
    required this.folderName,
  });

  /// 返回用户是否确认。**滑掉弹窗返回 false**（`showBottomModal` 可被手势
  /// 关掉且不给结果，`showModalBottomSheet` 这时给的是 null）—— 默认取「取消」
  /// 而不是「确认」是因为后面的动作会写盘，手滑关掉不该等于同意。
  static Future<bool> show({
    required BuildContext context,
    required int archiveCount,
    required int encryptedCount,
    required int splitCount,
    required String folderName,
  }) async {
    final result = await showBottomModal<bool>(
      context: context,
      child: ConfirmExtractModal(
        archiveCount: archiveCount,
        encryptedCount: encryptedCount,
        splitCount: splitCount,
        folderName: folderName,
      ),
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
              const Icon(Icons.inventory_2_outlined,
                  color: AppTheme.neonCyan, size: 20),
              const SizedBox(width: 10),
              const Text(
                '开始解压',
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
            '解压结果会写到每个压缩包旁边，目录结构与源目录一致',
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
              color: AppTheme.neonCyan.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.neonCyan.withValues(alpha: 0.15)),
            ),
            child: Column(
              children: [
                _row('待解压', '$archiveCount 个压缩包'),
                if (encryptedCount > 0) ...[
                  _divider(),
                  _row('需要密码', '$encryptedCount 个（将自动尝试密码库）',
                      color: AppTheme.neonOrange),
                ],
                if (splitCount > 0) ...[
                  _divider(),
                  _row('分片', '$splitCount 个（将自动合并）',
                      color: AppTheme.neonOrange),
                ],
                _divider(),
                _row('输出到', folderName.isEmpty ? '所选目录' : folderName),
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
                  label: '确认解压',
                  gradient: AppTheme.primaryGradient,
                  onTap: () => Navigator.pop(context, true),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _row(String k, String v, {Color? color}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Text(
            k,
            style: const TextStyle(
              fontSize: 12,
              color: AppTheme.textDim,
              fontFamily: 'monospace',
            ),
          ),
          const Spacer(),
          Flexible(
            child: Text(
              v,
              textAlign: TextAlign.right,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontFamily: 'monospace',
                fontWeight: FontWeight.w600,
                color: color ?? AppTheme.neonCyan,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _divider() => Divider(
      color: Colors.white.withValues(alpha: 0.04), height: 1, thickness: 1);
}
