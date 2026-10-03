import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../providers/app_state.dart';
import '../models/extractor.dart';
import '../widgets/glass_card.dart';
import '../widgets/custom_button.dart';
import '../widgets/modals/add_extractor_modal.dart';

/// 设置页面
class SettingsScreen extends StatelessWidget {
  final AppState state;
  const SettingsScreen({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        return ListView(
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 100),
          children: [
            _buildHeader(),
            const SizedBox(height: 16),
            _group('递归与目录', [
              _settingItem(
                icon: Icons.swap_horiz,
                iconColor: AppTheme.neonCyan,
                title: '递归解压',
                desc: '解压出的压缩包继续解压',
                toggle: true,
                value: state.setting('recursive'),
                onToggle: () => state.toggleSetting('recursive'),
              ),
              _settingItem(
                icon: Icons.home_outlined,
                iconColor: AppTheme.neonPurple,
                title: '目录对称输出',
                desc: '解压目录与原目录结构一致',
                toggle: true,
                value: state.setting('symmetricOutput'),
                onToggle: () => state.toggleSetting('symmetricOutput'),
              ),
              _settingItem(
                icon: Icons.info_outline,
                iconColor: AppTheme.neonGreen,
                title: '最大递归深度',
                desc: '防止无限递归炸弹',
                trailing: _depthSelector(),
              ),
            ]),
            const SizedBox(height: 16),
            _group('智能识别', [
              _settingItem(
                icon: Icons.description_outlined,
                iconColor: AppTheme.neonOrange,
                title: '后缀篡改检测',
                desc: '读取文件头魔术字节判断真实格式',
                toggle: true,
                value: state.setting('fakeExtDetect'),
                onToggle: () => state.toggleSetting('fakeExtDetect'),
              ),
              _settingItem(
                icon: Icons.grid_view,
                iconColor: AppTheme.neonPink,
                title: '分片自动合并',
                desc: '识别 .001/.part1.rar 等分卷并合并解压',
                toggle: true,
                value: state.setting('splitMerge'),
                onToggle: () => state.toggleSetting('splitMerge'),
              ),
              _settingItem(
                icon: Icons.lock_outline,
                iconColor: AppTheme.neonCyan,
                title: '密码库自动尝试',
                desc: '遇加密包自动遍历密码库',
                toggle: true,
                value: state.setting('pwdAutoTry'),
                onToggle: () => state.toggleSetting('pwdAutoTry'),
              ),
            ]),
            const SizedBox(height: 16),
            _group('错误处理', [
              _settingItem(
                icon: Icons.error_outline,
                iconColor: AppTheme.neonRed,
                title: '错误时暂停',
                desc: '无法解压时弹窗询问，而非自动跳过',
                toggle: true,
                value: state.setting('errorPause'),
                onToggle: () => state.toggleSetting('errorPause'),
              ),
              _settingItem(
                icon: Icons.check_circle_outline,
                iconColor: AppTheme.neonGreen,
                title: 'CRC 校验',
                desc: '解压后校验文件完整性',
                toggle: true,
                value: state.setting('crcCheck'),
                onToggle: () => state.toggleSetting('crcCheck'),
              ),
            ]),
            const SizedBox(height: 16),
            _buildExtractorSection(context),
            const SizedBox(height: 20),
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
            '引擎设置',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
        ),
        const SizedBox(height: 4),
        const Text(
          'ENGINE CONFIGURATION · 精细控制解压行为',
          style: TextStyle(
            fontSize: 12,
            color: AppTheme.textDim,
            fontFamily: 'monospace',
          ),
        ),
      ],
    );
  }

  Widget _group(String title, List<Widget> children) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 10),
          child: Text(
            title.toUpperCase(),
            style: const TextStyle(
              fontSize: 11,
              color: AppTheme.textDim,
              fontFamily: 'monospace',
              letterSpacing: 1.5,
            ),
          ),
        ),
        ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: Column(children: children),
        ),
      ],
    );
  }

  Widget _settingItem({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String desc,
    bool toggle = false,
    bool value = false,
    VoidCallback? onToggle,
    Widget? trailing,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: AppTheme.glass,
        border: Border(
          bottom: BorderSide(color: Colors.white.withValues(alpha: 0.03)),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: iconColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, size: 16, color: iconColor),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: AppTheme.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  desc,
                  style: const TextStyle(
                    fontSize: 10,
                    color: AppTheme.textDim,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
          ),
          if (toggle)
            NeonToggle(value: value, onChanged: (_) => onToggle?.call()),
          if (trailing != null) trailing,
        ],
      ),
    );
  }

  Widget _depthSelector() {
    const opts = ['∞ 无限制', '5 层', '10 层', '20 层'];
    final idx = [0, 5, 10, 20].indexOf(state.maxDepth);
    return GestureDetector(
      onTap: () => state.cycleMaxDepth(),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: AppTheme.neonCyan.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: AppTheme.neonCyan.withValues(alpha: 0.15)),
        ),
        child: Text(
          opts[idx],
          style: const TextStyle(
            fontSize: 12,
            fontFamily: 'monospace',
            color: AppTheme.neonCyan,
          ),
        ),
      ),
    );
  }

  Widget _buildExtractorSection(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(left: 4, bottom: 10),
          child: Text(
            '解压方式扩展',
            style: TextStyle(
              fontSize: 11,
              color: AppTheme.textDim,
              fontFamily: 'monospace',
              letterSpacing: 1.5,
            ),
          ),
        ),
        ...state.extractors.asMap().entries.map((e) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _extractorItem(e.value, e.key),
          );
        }).toList(),
        const SizedBox(height: 8),
        GestureDetector(
          onTap: () => AddExtractorModal.show(
            context: context,
            onSave: (ext) => state.addExtractor(ext),
          ),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
              color: AppTheme.neonCyan.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: AppTheme.neonCyan.withValues(alpha: 0.25),
                style: BorderStyle.solid,
                width: 1.5,
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: const [
                Icon(Icons.add, size: 16, color: AppTheme.neonCyan),
                SizedBox(width: 8),
                Text(
                  '注册新的解压方式',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    fontFamily: 'monospace',
                    color: AppTheme.neonCyan,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _extractorItem(Extractor e, int index) {
    final color = e.type == ExtractorType.single
        ? AppTheme.neonCyan
        : AppTheme.neonPurple;
    return GlassCard(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: color.withValues(alpha: 0.2)),
            ),
            alignment: Alignment.center,
            child: Text(
              e.typeName,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                fontFamily: 'monospace',
                color: color,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      e.name,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.textPrimary,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        e.typeLabel,
                        style: TextStyle(
                          fontSize: 9,
                          fontFamily: 'monospace',
                          color: color,
                        ),
                      ),
                    ),
                    if (e.isBuiltin) ...[
                      const SizedBox(width: 6),
                      const Text(
                        'BUILTIN',
                        style: TextStyle(
                          fontSize: 9,
                          fontFamily: 'monospace',
                          color: AppTheme.textDim,
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  e.detectLogic,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 10,
                    color: AppTheme.textDim,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
          ),
          if (!e.isBuiltin)
            GestureDetector(
              onTap: () => state.deleteExtractor(index),
              child: Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: AppTheme.neonRed.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(7),
                  border: Border.all(
                    color: AppTheme.neonRed.withValues(alpha: 0.15),
                  ),
                ),
                child: const Icon(
                  Icons.delete_outline,
                  size: 13,
                  color: AppTheme.neonRed,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
