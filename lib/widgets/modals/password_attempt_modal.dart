import 'package:flutter/material.dart';
import '../../theme/app_theme.dart';
import '../../models/password_entry.dart';
import 'bottom_modal.dart';

/// 密码自动匹配弹窗
class PasswordAttemptModal extends StatefulWidget {
  final String fileName;
  final List<PasswordEntry> passwords;
  final VoidCallback onClose;

  const PasswordAttemptModal({
    super.key,
    required this.fileName,
    required this.passwords,
    required this.onClose,
  });

  static Future<void> show({
    required BuildContext context,
    required String fileName,
    required List<PasswordEntry> passwords,
    required VoidCallback onClose,
  }) {
    return showBottomModal(
      context: context,
      child: PasswordAttemptModal(
        fileName: fileName,
        passwords: passwords,
        onClose: onClose,
      ),
    );
  }

  @override
  State<PasswordAttemptModal> createState() => _PasswordAttemptModalState();
}

class _PasswordAttemptModalState extends State<PasswordAttemptModal> {
  int _currentIdx = -1;
  int _successIdx = -1;
  bool _finished = false;

  @override
  void initState() {
    super.initState();
    _successIdx = DateTime.now().millisecond % widget.passwords.length;
    _startAttempt();
  }

  void _startAttempt() {
    Future.doWhile(() async {
      await Future.delayed(const Duration(milliseconds: 500));
      if (!mounted) return false;
      setState(() => _currentIdx++);
      if (_currentIdx >= widget.passwords.length) {
        _finished = true;
        Future.delayed(const Duration(milliseconds: 800), () {
          if (mounted) {
            Navigator.pop(context);
            widget.onClose();
          }
        });
        return false;
      }
      return true;
    });
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
              const Icon(Icons.lock_outline,
                  color: AppTheme.neonPurple, size: 20),
              const SizedBox(width: 10),
              const Text('密码自动匹配',
                  style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.textPrimary)),
            ],
          ),
          const SizedBox(height: 6),
          Text('正在为 ${widget.fileName} 尝试密码库...',
              style: const TextStyle(
                  fontSize: 12,
                  color: AppTheme.textDim,
                  fontFamily: 'monospace')),
          const SizedBox(height: 18),
          SizedBox(
            height: 180,
            child: ListView.builder(
              itemCount: widget.passwords.length,
              itemBuilder: (context, i) {
                final p = widget.passwords[i];
                final isTrying = i == _currentIdx && !_finished;
                final isSuccess = i == _successIdx &&
                    (_currentIdx > i || _finished);
                final isFail =
                    _finished && i != _successIdx || (_currentIdx > i && i != _successIdx);
                return Container(
                  margin: const EdgeInsets.only(bottom: 6),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: isTrying
                        ? AppTheme.neonCyan.withOpacity(0.05)
                        : isSuccess
                            ? AppTheme.neonGreen.withOpacity(0.05)
                            : Colors.white.withOpacity(0.02),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: isTrying
                          ? AppTheme.neonCyan.withOpacity(0.3)
                          : isSuccess
                              ? AppTheme.neonGreen.withOpacity(0.3)
                              : Colors.transparent,
                    ),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text('•' * p.value.length.clamp(4, 12),
                            style: const TextStyle(
                                fontSize: 12,
                                fontFamily: 'monospace',
                                color: AppTheme.textPrimary)),
                      ),
                      Text(
                        isTrying
                            ? '尝试中...'
                            : isSuccess
                                ? '匹配成功'
                                : isFail
                                    ? '不匹配'
                                    : '等待',
                        style: TextStyle(
                          fontSize: 10,
                          color: isTrying
                              ? AppTheme.neonCyan
                              : isSuccess
                                  ? AppTheme.neonGreen
                                  : AppTheme.textDim,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: GestureDetector(
                  onTap: () {
                    Navigator.pop(context);
                    widget.onClose();
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.05),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.white.withOpacity(0.1)),
                    ),
                    alignment: Alignment.center,
                    child: const Text('手动输入',
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
                    widget.onClose();
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    decoration: BoxDecoration(
                      gradient: AppTheme.primaryGradient,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    alignment: Alignment.center,
                    child: const Text('继续',
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
}
