import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../providers/app_state.dart';
import '../models/password_entry.dart';
import '../widgets/glass_card.dart';

/// 密码库页面
class VaultScreen extends StatefulWidget {
  final AppState state;
  const VaultScreen({super.key, required this.state});

  @override
  State<VaultScreen> createState() => _VaultScreenState();
}

class _VaultScreenState extends State<VaultScreen> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.state,
      builder: (context, _) {
        return ListView(
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 100),
          children: [
            _buildHeader(),
            const SizedBox(height: 16),
            _buildSummary(),
            const SizedBox(height: 16),
            _buildAddForm(),
            const SizedBox(height: 16),
            ...widget.state.passwords.asMap().entries.map((e) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _pwdItem(e.value, e.key),
              );
            }).toList(),
          ],
        );
      },
    );
  }

  Widget _buildHeader() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ShaderMask(
          shaderCallback: (bounds) =>
              AppTheme.primaryGradient.createShader(bounds),
          child: const Text(
            '密码库',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
        ),
        const SizedBox(height: 4),
        const Text(
          'PASSWORD VAULT · 自动匹配加密压缩包',
          style: TextStyle(
            fontSize: 12,
            color: AppTheme.textDim,
            fontFamily: 'monospace',
          ),
        ),
      ],
    );
  }

  Widget _buildSummary() {
    return GlassCard(
      padding: const EdgeInsets.all(16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${widget.state.passwords.length}',
                style: const TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                  fontFamily: 'monospace',
                  color: AppTheme.neonPurple,
                ),
              ),
              const SizedBox(height: 2),
              const Text(
                '已保存密码',
                style: TextStyle(fontSize: 11, color: AppTheme.textDim),
              ),
            ],
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              const Text(
                '87%',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  fontFamily: 'monospace',
                  color: AppTheme.neonGreen,
                ),
              ),
              const SizedBox(height: 2),
              const Text(
                '历史匹配率',
                style: TextStyle(fontSize: 11, color: AppTheme.textDim),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildAddForm() {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _ctrl,
            style: const TextStyle(
              fontSize: 13,
              fontFamily: 'monospace',
              color: AppTheme.textPrimary,
            ),
            decoration: InputDecoration(
              hintText: '输入密码...',
              hintStyle: const TextStyle(
                fontSize: 13,
                fontFamily: 'monospace',
                color: AppTheme.textDim,
              ),
              filled: true,
              fillColor: Colors.white.withValues(alpha: 0.04),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 12,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(
                  color: AppTheme.neonCyan.withValues(alpha: 0.15),
                ),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(
                  color: AppTheme.neonCyan.withValues(alpha: 0.15),
                ),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: AppTheme.neonCyan),
              ),
            ),
            onSubmitted: (_) => _add(),
          ),
        ),
        const SizedBox(width: 10),
        GestureDetector(
          onTap: _add,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            decoration: BoxDecoration(
              gradient: AppTheme.primaryGradient,
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Text(
              '添加',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: AppTheme.bgDeep,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _pwdItem(PasswordEntry p, int index) {
    return GlassCard(
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              gradient: AppTheme.cardGradient,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: AppTheme.neonPurple.withValues(alpha: 0.2),
              ),
            ),
            child: const Icon(
              Icons.lock_outline,
              color: AppTheme.neonPurple,
              size: 18,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  p.value,
                  style: const TextStyle(
                    fontSize: 14,
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.w600,
                    color: AppTheme.textPrimary,
                    letterSpacing: 1,
                  ),
                ),
                const SizedBox(height: 3),
                Row(
                  children: [
                    Text(
                      '匹配 ${p.hitCount} 次',
                      style: const TextStyle(
                        fontSize: 10,
                        fontFamily: 'monospace',
                        color: AppTheme.neonGreen,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      '最近: ${p.lastUsed}',
                      style: const TextStyle(
                        fontSize: 10,
                        fontFamily: 'monospace',
                        color: AppTheme.textDim,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          GestureDetector(
            onTap: () => widget.state.deletePassword(index),
            child: Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: AppTheme.neonRed.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: AppTheme.neonRed.withValues(alpha: 0.2),
                ),
              ),
              child: const Icon(
                Icons.delete_outline,
                color: AppTheme.neonRed,
                size: 14,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _add() {
    widget.state.addPassword(_ctrl.text.trim());
    _ctrl.clear();
  }
}
