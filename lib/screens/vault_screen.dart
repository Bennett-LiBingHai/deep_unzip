import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../providers/app_state.dart';
import '../models/password_entry.dart';
import '../widgets/glass_card.dart';
import '../widgets/modals/delete_password_modal.dart';

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
            ...widget.state.passwords.map((p) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _pwdItem(p),
              );
            }),
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
    final hits = widget.state.passwords.fold<int>(
      0,
      (sum, p) => sum + p.hitCount,
    );

    return GlassCard(
      padding: const EdgeInsets.all(16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.center,
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
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(
                '$hits',
                style: const TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                  fontFamily: 'monospace',
                  color: AppTheme.neonGreen,
                ),
              ),
              const SizedBox(height: 2),
              const Text(
                '累计命中',
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
              hintText: '输入密码',
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

  Widget _pwdItem(PasswordEntry p) {
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
            onTap: () => _confirmDelete(p),
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

  /// 删之前先弹确认（见 [DeletePasswordModal]）。
  ///
  /// 确认回来之后**按值重新定位，而不是直接用传进来的 `index`**：弹窗是 await
  /// 的，中间隔着用户点一下的时长，而这期间解压可能正好命中一条密码 ——
  /// `_markVaultHit` 会把 `_passwords` 里那一条换成新对象（顺序没变，但「列表
  /// 还是当初那个列表」已经不是白给的了）。值在库里唯一（`addPassword` 拒重复），
  /// 所以按值找得到就一定是它；找不到就是那条已经不在了，此时**什么都不做** ——
  /// 拿一个过期的下标去 `removeAt`，删掉的是下一条。
  Future<void> _confirmDelete(PasswordEntry p) async {
    if (!await DeletePasswordModal.show(context: context, entry: p)) return;
    final at = widget.state.passwords.indexWhere((x) => x.value == p.value);
    if (at < 0) return;
    widget.state.deletePassword(at);
  }

  void _add() {
    widget.state.addPassword(_ctrl.text.trim());
    _ctrl.clear();
  }
}
