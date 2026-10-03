import 'package:flutter/material.dart';
import '../../theme/app_theme.dart';
import 'bottom_modal.dart';

/// 智能格式识别弹窗
class FormatDetectModal extends StatelessWidget {
  final String fakeExt;
  final String fileHeader;
  final String realFormat;
  final String action;
  final String hexPreview;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  const FormatDetectModal({
    super.key,
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
          const Text('检测到后缀名与真实格式不符，已自动修正',
              style: TextStyle(
                  fontSize: 12,
                  color: AppTheme.textDim,
                  fontFamily: 'monospace')),
          const SizedBox(height: 18),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.3),
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
              color: AppTheme.neonCyan.withOpacity(0.05),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.neonCyan.withOpacity(0.15)),
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
                      color: Colors.white.withOpacity(0.05),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.white.withOpacity(0.1)),
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
      color: Colors.white.withOpacity(0.04), height: 1, thickness: 1);
}
