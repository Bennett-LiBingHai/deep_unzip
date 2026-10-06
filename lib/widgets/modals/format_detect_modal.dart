import 'package:flutter/material.dart';
import '../../theme/app_theme.dart';
import 'bottom_modal.dart';

/// 智能格式识别弹窗。
///
/// [fileName] 是**必须**显示的：这个弹窗在一批几十个包的解压途中随时可能弹
/// 出来，只写「检测到后缀名与真实格式不符」而不说是在说哪个文件，用户根本
/// 不知道眼前这一下影响的是谁 —— 尤其当他刚点了「开始解压」就去做了别的。
/// 形状照 `ErrorModal` 那个红框来，只是换成青色（这个不是错误，是个通报）。
class FormatDetectModal extends StatelessWidget {
  final String fileName;
  final String fakeExt;
  final String fileHeader;
  final String realFormat;
  final String action;
  final String hexPreview;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  const FormatDetectModal({
    super.key,
    required this.fileName,
    required this.fakeExt,
    required this.fileHeader,
    required this.realFormat,
    required this.action,
    required this.hexPreview,
    required this.onConfirm,
    required this.onCancel,
  });

  static Future<void> show({
    required BuildContext context,
    required String fileName,
    required String fakeExt,
    required String fileHeader,
    required String realFormat,
    required String action,
    required String hexPreview,
    required VoidCallback onConfirm,
    required VoidCallback onCancel,
  }) {
    return showBottomModal(
      context: context,
      child: FormatDetectModal(
        fileName: fileName,
        fakeExt: fakeExt,
        fileHeader: fileHeader,
        realFormat: realFormat,
        action: action,
        hexPreview: hexPreview,
        onConfirm: onConfirm,
        onCancel: onCancel,
      ),
    );
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
              const Icon(Icons.search, color: AppTheme.neonCyan, size: 20),
              const SizedBox(width: 10),
              const Text('智能格式识别',
                  style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.textPrimary)),
            ],
          ),
          const SizedBox(height: 6),
          const Text('检测到文件后缀与真实格式不符',
              style: TextStyle(
                  fontSize: 12,
                  color: AppTheme.textDim,
                  fontFamily: 'monospace')),
          const SizedBox(height: 12),
          // 是哪个文件。放在十六进制预览上面，比塞进「声明后缀」那一行好读
          // —— 那一行是字段表，一行长文件名会把右侧的值挤得没法看。
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppTheme.neonCyan.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: AppTheme.neonCyan.withValues(alpha: 0.15),
              ),
            ),
            child: Text(fileName,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 12,
                    fontFamily: 'monospace',
                    color: AppTheme.neonCyan)),
          ),
          const SizedBox(height: 14),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(hexPreview,
                style: const TextStyle(
                    fontSize: 11,
                    fontFamily: 'monospace',
                    color: AppTheme.neonGreen,
                    letterSpacing: 1)),
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppTheme.neonCyan.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.neonCyan.withValues(alpha: 0.15)),
            ),
            child: Column(
              children: [
                _row('声明后缀', fakeExt, isFake: true),
                _divider(),
                _row('文件头', fileHeader),
                _divider(),
                _row('真实格式', realFormat),
                _divider(),
                _row('处理方式', action),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: GestureDetector(
                  onTap: () {
                    Navigator.pop(context);
                    onCancel();
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
                    ),
                    alignment: Alignment.center,
                    child: const Text('取消',
                        style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.textSecondary)),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: GestureDetector(
                  onTap: () {
                    Navigator.pop(context);
                    onConfirm();
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    decoration: BoxDecoration(
                      gradient: AppTheme.primaryGradient,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    alignment: Alignment.center,
                    child: const Text('确认解压',
                        style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.bgDeep)),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _row(String k, String v, {bool isFake = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(k,
              style: const TextStyle(
                  fontSize: 12,
                  color: AppTheme.textDim,
                  fontFamily: 'monospace')),
          Text(v,
              style: TextStyle(
                  fontSize: 12,
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.w600,
                  color: isFake ? AppTheme.neonRed : AppTheme.neonCyan)),
        ],
      ),
    );
  }

  Widget _divider() => Divider(
      color: Colors.white.withValues(alpha: 0.04), height: 1, thickness: 1);
}
