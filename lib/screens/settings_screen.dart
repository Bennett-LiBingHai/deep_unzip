import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../providers/app_state.dart';
import '../engine/limits.dart';
import '../models/extractor.dart';
import '../widgets/glass_card.dart';
import '../widgets/custom_button.dart';
import '../widgets/modals/add_extractor_modal.dart';
import '../widgets/modals/limit_value_modal.dart';

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
              // 这一颗叫过「后缀篡改检测」，描述写的是「读取文件头魔术字节
              // 判断真实格式」—— 两句都是原型期写歪的。魔术字节**永远**会读
              // （扫描就是靠它认出压缩包的），关掉这颗照样认出 `fake.pdf`
              // 是个 ZIP，只是不问用户。它真正控制的是**问不问**，所以现在
              // 按它实际做的事命名。
              _settingItem(
                icon: Icons.description_outlined,
                iconColor: AppTheme.neonOrange,
                title: '伪后缀时暂停',
                desc: '检测到后缀被篡改时先问一句，关闭则直接按真实格式解压',
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
            ]),
            const SizedBox(height: 16),
            _buildLimitsSection(context),
            const SizedBox(height: 16),
            _group('日志', [
              _settingItem(
                icon: Icons.receipt_long_outlined,
                iconColor: AppTheme.neonCyan,
                title: '日志保留条数',
                desc: '超出后丢弃最早的记录，调小会立刻生效',
                trailing: _cyclerChip(
                  label: '${state.maxLogs} 条',
                  color: AppTheme.neonCyan,
                  onTap: () => state.cycleMaxLogs(),
                ),
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
    // `indexOf` 给出 -1 时（读回来的值不在表里）会取到 `opts[-1]` 直接抛异常
    // 把设置页打崩 —— 收口在这里，与计划里那条「加载时把 maxDepth 收敛到
    // {0,5,10,20}」是同一件事的两道防线。
    const opts = ['∞ 无限制', '5 层', '10 层', '20 层'];
    final idx = [0, 5, 10, 20].indexOf(state.maxDepth);
    return _cyclerChip(
      label: opts[idx < 0 ? 0 : idx],
      color: AppTheme.neonCyan,
      onTap: () => state.cycleMaxDepth(),
    );
  }

  /// 点一下切下一档的 chip。深度、炸弹防护、日志封顶三处共用，免得样式各走各的。
  Widget _cyclerChip({
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: color.withValues(alpha: 0.15)),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontFamily: 'monospace',
            color: color,
          ),
        ),
      ),
    );
  }

  /// 炸弹防护。一个 chip 选档位，选到「自定义」才展开成逐项数值。
  ///
  /// 展开与否只认 [AppState.limitsCustom]（即 chip 停在「自定义」那一档），
  /// **不**去看「当前值是不是等于某个预设」—— 后者会让用户在编辑途中被
  /// 弹出编辑器（把某项改回预设值的一瞬间四行就收起来了）。
  ///
  /// 预设档位下这四行**照常列出来**，只是不可点、不带笔。只写一个「标准」
  /// 等于让人在一组看不见的数字上做选择 —— 多严算严、多大算大，光看档名
  /// 谁也说不准，而数值本来就摆在手边，没有理由藏起来。
  Widget _buildLimitsSection(BuildContext context) {
    return _group('炸弹防护', [
      _settingItem(
        icon: Icons.shield_outlined,
        iconColor: AppTheme.neonPurple,
        title: '解压上限',
        desc: '超限就放弃这个包，避免压缩炸弹撑爆磁盘',
        trailing: _cyclerChip(
          label: state.limitPresetLabel,
          color: AppTheme.neonPurple,
          onTap: () => state.cycleLimitPreset(),
        ),
      ),
      for (final field in LimitField.values)
        _limitRow(context, field, editable: state.limitsCustom),
    ]);
  }

  /// 一行阈值：左边名字，右边当前值。[editable] 时点开改。
  ///
  /// 只读（预设档位）与可编辑（自定义）**刻意共用同一套排版**：切过去的时候
  /// 数值留在原位变得可点，用户不必重新找一遍自己刚才在看哪一行。区别只在
  /// 颜色和那支笔 —— 只读的行点名和数值都是 `textSecondary`，整行暗下去，
  /// 一眼能看出「这不是给你改的」。
  Widget _limitRow(
    BuildContext context,
    LimitField field, {
    required bool editable,
  }) {
    final row = Container(
      // 缩进一格，视觉上挂在「解压上限」那一项底下。
      padding: const EdgeInsets.fromLTRB(60, 11, 16, 11),
      decoration: BoxDecoration(
        color: AppTheme.glass,
        border: Border(
          bottom: BorderSide(color: Colors.white.withValues(alpha: 0.03)),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              field.label,
              style: const TextStyle(
                fontSize: 12,
                color: AppTheme.textSecondary,
              ),
            ),
          ),
          Text(
            field.display(state.limits),
            style: TextStyle(
              fontSize: 12,
              fontFamily: 'monospace',
              color: editable ? AppTheme.neonPurple : AppTheme.textSecondary,
            ),
          ),
          if (editable) ...[
            const SizedBox(width: 6),
            const Icon(Icons.edit_outlined, size: 12, color: AppTheme.textDim),
          ],
        ],
      ),
    );

    // 只读的行不接点击：接了却什么都不发生，比不接更让人困惑。
    // 想改数值就点右边的档位 chip 走到「自定义」，那一档会保留当前这组
    // 数字（见 `AppState.setLimitPreset`），是从这一档微调出去的。
    if (!editable) return row;
    return GestureDetector(onTap: () => _editLimit(context, field), child: row);
  }

  Future<void> _editLimit(BuildContext context, LimitField field) async {
    final value = await LimitValueModal.show(
      context: context,
      field: field,
      current: state.limits,
    );
    if (value != null) state.setLimit(field, value);
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
