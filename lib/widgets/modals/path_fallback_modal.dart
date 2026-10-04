import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/app_theme.dart';
import 'bottom_modal.dart';
import 'modal_button.dart';

/// 「没能替你打开，路径在这儿，自己复制」的兜底弹窗。
///
/// 存在的理由：Android 没有「打开这个文件夹」的标准 Intent，我们走的
/// `DocumentsContract` + 系统 ExternalStorageProvider 这条路在 AOSP 上能精确定位，
/// 但**国产 ROM 常把 DocumentsUI 换掉或包一层**，那时只剩「随便开一个文件管理器」
/// 这一档（见 [OpenFolderResult.openedGeneric]），用户眼前的界面根本没定位到目标
/// 目录。与其假装成功，不如把路径原样交到用户手里 —— 让他手动点进去，
/// 总好过对着一个不相干的目录发呆。
///
/// 判定与降级逻辑在 `file_manager_bridge.dart`。
class PathFallbackModal extends StatefulWidget {
  /// 一句话说明为什么没能自动打开。
  final String headline;

  /// 补充说明，给个下一步动作。
  final String detail;

  /// 要交给用户的路径。
  final String path;

  const PathFallbackModal({
    super.key,
    required this.headline,
    required this.detail,
    required this.path,
  });

  static Future<void> show({
    required BuildContext context,
    required String headline,
    required String detail,
    required String path,
  }) {
    return showBottomModal(
      context: context,
      child: PathFallbackModal(
        headline: headline,
        detail: detail,
        path: path,
      ),
    );
  }

  @override
  State<PathFallbackModal> createState() => _PathFallbackModalState();
}

class _PathFallbackModalState extends State<PathFallbackModal> {
  /// 复制过了就把按钮文案换掉。剪贴板写成功在界面上**没有任何反馈**，
  /// 不给个回执用户会以为没点上、反复点。
  bool _copied = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.path));
    if (!mounted) return;
    setState(() => _copied = true);
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
              const Icon(Icons.folder_off_outlined,
                  color: AppTheme.neonOrange, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  widget.headline,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.textPrimary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            widget.detail,
            style: const TextStyle(
              fontSize: 12,
              color: AppTheme.textSecondary,
              height: 1.6,
            ),
          ),
          const SizedBox(height: 16),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(10),
            ),
            child: SelectableText(
              widget.path,
              style: const TextStyle(
                fontSize: 12,
                fontFamily: 'monospace',
                color: AppTheme.neonCyan,
                height: 1.5,
              ),
            ),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: ModalButton(
                  label: '关闭',
                  color: AppTheme.textSecondary,
                  onTap: () => Navigator.pop(context),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ModalButton(
                  label: _copied ? '已复制' : '复制路径',
                  gradient: AppTheme.primaryGradient,
                  onTap: _copy,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
