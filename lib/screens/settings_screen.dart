import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../providers/app_state.dart';
import '../engine/limits.dart';
import '../app_info.dart';
import '../data/builtin_extractors.dart';
import '../models/extractor.dart';
import 'about_screen.dart';
import '../widgets/glass_card.dart';
import '../widgets/custom_button.dart';
import '../widgets/modals/limit_value_modal.dart';
import '../widgets/modals/log_limit_modal.dart';
import '../widgets/modals/max_depth_modal.dart';

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
              // 这里原来还有一颗「递归解压」开关，2026-10 删了：它跟下面那个
              // 深度管的是同一件事，摆在一起必然对不上 —— 开关开着而深度填 0、
              // 或者反过来，用户没办法知道该信哪个。深度现在是唯一入口，
              // `0` 就是不递归。账见 `persist.dart` 的 `kDefaultToggles`。
              // 这一行原来叫「目录对称输出」，2026-10 换成现在这颗。
              //
              // **旧名字在骗人**：它描述的是**布局**（输出与源目录结构一致），
              // 而那个布局从来就是唯一的行为 —— `resolveOutputDir` 不读任何
              // 开关，永远解到包旁边。所以那颗开关的值对磁盘没有任何影响，
              // 是颗死开关（账见 `persist.dart` 的 `kDefaultToggles`）。
              //
              // 现在这颗管的是**位置**：开着 = 每次解压前自己选一个根目录，
              // 输出按源目录结构镜像写进去；关着 = 解到包旁边（默认，也就是
              // 从前**实际**发生的那件事，所以老用户升级过来行为不变）。
              //
              // 右边**没有 chip**：根目录每次重选、不落盘，没有任何值可以摆在
              // 这里。别为了对称硬加一个显示「未选择」的 chip。
              _settingItem(
                icon: Icons.create_new_folder_outlined,
                iconColor: AppTheme.neonPurple,
                title: '自定义输出目录',
                desc: '解压前选择输出根目录，按源目录结构写入；关闭后解压到各压缩包同级',
                toggle: true,
                value: state.setting('customOutput'),
                onToggle: () => state.toggleSetting('customOutput'),
              ),
              _settingItem(
                icon: Icons.layers_outlined,
                iconColor: AppTheme.neonGreen,
                title: '最大递归深度',
                desc: '每进一层子目录、每解一层嵌套包各算一层；0 表示不递归',
                trailing: _depthSelector(context),
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
                desc: '检测到后缀被篡改时先提示确认；关闭则直接按真实格式解压',
                toggle: true,
                value: state.setting('fakeExtDetect'),
                onToggle: () => state.toggleSetting('fakeExtDetect'),
              ),
              // 这颗开关**不决定「要不要自动试密码库」**（那件事一直做），
              // 它决定的是「试不出来之后问不问」。名字跟着后者走 —— 原先叫
              // 「密码库自动尝试」，说的是两边共有的那一半，读起来会以为关掉
              // 就不试了。键名同样改过，见 `persist.dart` 的 `kRenamedToggles`。
              _settingItem(
                icon: Icons.lock_outline,
                iconColor: AppTheme.neonCyan,
                title: '无法解密时弹窗',
                desc: '先用密码库自动尝试；均未通过时弹窗询问，关闭则直接跳过该文件',
                toggle: true,
                value: state.setting('pwdPrompt'),
                onToggle: () => state.toggleSetting('pwdPrompt'),
              ),
              // 与上面那颗成套：上面管「试不出来问不问」，这颗管「问出来的密码
              // 要不要留下来」。默认开 —— 用户肯去手敲一遍，本意就是要再用它。
              _settingItem(
                icon: Icons.save_outlined,
                iconColor: AppTheme.neonGreen,
                title: '手输密码存入密码库',
                desc: '手动输入的密码验证通过后自动存入密码库，供后续自动尝试',
                toggle: true,
                value: state.setting('pwdAutoSave'),
                onToggle: () => state.toggleSetting('pwdAutoSave'),
              ),
            ]),
            const SizedBox(height: 16),
            _group('错误处理', [
              _settingItem(
                icon: Icons.error_outline,
                iconColor: AppTheme.neonRed,
                title: '错误时暂停',
                desc: '无法解压时弹窗询问，不自动跳过',
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
                desc: '超出后丢弃最早的记录，调小立即生效',
                trailing: _valueChip(
                  label: '${state.maxLogs} 条',
                  color: AppTheme.neonCyan,
                  editable: true,
                  onTap: () => _editMaxLogs(context),
                ),
              ),
            ]),
            const SizedBox(height: 16),
            _buildExtractorSection(context),
            const SizedBox(height: 16),
            _group('关于', [
              // 这一行不只是「看一眼版本」：开源许可全文只能从这里到达，而那是
              // LGPL / BSD 要求分发时必须能拿到的东西（见 `about_screen.dart`）。
              GestureDetector(
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const AboutScreen()),
                ),
                child: _settingItem(
                  icon: Icons.info_outline,
                  iconColor: AppTheme.neonCyan,
                  title: '关于 $kAppName',
                  desc: '版本 · 隐私说明 · 第三方组件与许可全文',
                  trailing: const Icon(Icons.chevron_right,
                      size: 18, color: AppTheme.textDim),
                ),
              ),
            ]),
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
          const SizedBox(width: 12),
          if (toggle)
            NeonToggle(value: value, onChanged: (_) => onToggle?.call()),
          ?trailing,
        ],
      ),
    );
  }

  /// 深度那颗 chip。**自由输入**，与「日志保留条数」同一套：点开填数字。
  ///
  /// 这里原来是一颗在 `[0,5,10,20]` 上循环的 chip（"∞ 无限制 / 5 层 / …"），
  /// 2026-10 换成自由输入，`0` 的含义也从「无限制」翻成「不递归」。随之而去
  /// 的是那个把设置页打崩的隐患：原实现用 `indexOf` 定位档位、`-1` 时取到
  /// `opts[-1]` 越界 —— 自由输入没有"档位"可定位，这个坑连同它一起没了。
  ///
  /// `0` 显示成「不递归」而不是「0 层」：后者读起来像是「浅浅地解一层」的
  /// 中间态，而它其实是关。
  Widget _depthSelector(BuildContext context) {
    final n = state.maxDepth;
    return _valueChip(
      label: n == 0 ? '不递归' : '$n 层',
      color: AppTheme.neonCyan,
      editable: true,
      onTap: () => _editMaxDepth(context),
    );
  }

  /// 一行右侧那颗值的 chip。深度、炸弹防护、日志条数三处共用，免得样式各走各的。
  ///
  /// [editable] 决定点下去是「切下一档」还是「打开输入框」，用一支笔标出来 ——
  /// 同样是可点的文字，但一个是循环换值、另一个是让你自己填，不说清楚的话
  /// 用户点开之前不知道会碰上什么。
  Widget _valueChip({
    required String label,
    required Color color,
    required VoidCallback onTap,
    bool editable = false,
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
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontFamily: 'monospace',
                color: color,
              ),
            ),
            if (editable) ...[
              const SizedBox(width: 5),
              Icon(Icons.edit_outlined, size: 11, color: color),
            ],
          ],
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
        desc: '超限即放弃该压缩包，避免压缩炸弹耗尽磁盘空间',
        trailing: _valueChip(
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

  /// 打开递归深度的输入框。自由填写，界外的值弹窗自己拦（不给提交）。
  ///
  /// 与 [_editMaxLogs] 连界外提示都是同一套做法 —— 拦在弹窗里、**不夹值**：
  /// 夹一下用户会以为自己填的数生效了。
  Future<void> _editMaxDepth(BuildContext context) async {
    final value = await MaxDepthModal.show(
      context: context,
      current: state.maxDepth,
    );
    if (value != null) state.setMaxDepth(value);
  }

  /// 打开日志条数的输入框。自由填写，界外的值弹窗自己拦（不给提交）。
  Future<void> _editMaxLogs(BuildContext context) async {
    final value = await LogLimitModal.show(
      context: context,
      current: state.maxLogs,
    );
    if (value != null) state.setMaxLogs(value);
  }

  Widget _buildExtractorSection(BuildContext context) => const _SupportedFormats();
}

/// 「支持的格式」：只读清单，默认折叠。
///
/// 这一栏原来叫「解压方式扩展」，底下还有个「注册新的解压方式」入口，让用户自己
/// 填判断函数和解压函数 —— 那个入口从来没接到引擎上（识别靠嗅探表、解压靠内置
/// 7-Zip 核心，没有任何一边读它），2026-10 整个撤掉了。现在要支持新格式只有一条
/// 路：改 `SniffFormat` 与嗅探签名表（见 `engine/models.dart`）。
///
/// **默认折叠**：三十来种格式、每张卡片三四行，展开就是两三千像素，把设置页最后
/// 一屏撑得很长。绝大多数人只想确认一眼「我这个格式在不在」，点开再看。
///
/// 折叠状态是**自己的局部状态**，所以单独做成 [StatefulWidget]：`SettingsScreen`
/// 是无状态的，且外面套着 `ListenableBuilder`，每次 `AppState` 通知都会整段重建 ——
/// 把折叠位放在它的方法里，每次重建都会被重置回折叠。
class _SupportedFormats extends StatefulWidget {
  const _SupportedFormats();

  @override
  State<_SupportedFormats> createState() => _SupportedFormatsState();
}

class _SupportedFormatsState extends State<_SupportedFormats> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final all = BuiltinExtractors.all;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(left: 4, bottom: 10),
          child: Text(
            '支持的格式',
            style: TextStyle(
              fontSize: 11,
              color: AppTheme.textDim,
              fontFamily: 'monospace',
              letterSpacing: 1.5,
            ),
          ),
        ),
        GestureDetector(
          onTap: () => setState(() => _expanded = !_expanded),
          behavior: HitTestBehavior.opaque,
          child: GlassCard(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                const Icon(Icons.inventory_2_outlined,
                    size: 16, color: AppTheme.neonCyan),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${all.length} 种格式',
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      // 这一句是整栏存在的理由：下面每一行都在说「引擎真能做什么」，
                      // 而「识别」与「解压」两栏不看这句话容易被当成示意代码。
                      const Text(
                        '识别靠文件头（魔术字节），解压一律走内置的 7-Zip 核心，'
                        '不调用任何外部命令。任何格式都能按 *.001 裸切分',
                        style: TextStyle(
                          fontSize: 10,
                          color: AppTheme.textDim,
                          fontFamily: 'monospace',
                          height: 1.5,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  _expanded ? Icons.expand_less : Icons.expand_more,
                  size: 20,
                  color: AppTheme.textDim,
                ),
              ],
            ),
          ),
        ),
        if (_expanded) ...[
          const SizedBox(height: 8),
          for (final e in all)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _item(e),
            ),
        ],
      ],
    );
  }

  /// 一行格式。
  ///
  /// 「识别 / 解压 / 分卷」三行都是**真数据**，不是示意：识别那行照
  /// `engine/sniff.dart` 的签名表抄，解压那行只有「内置 7-Zip 核心」一种答案。
  Widget _item(Extractor e) {
    const color = AppTheme.neonCyan;
    return GlassCard(
      padding: const EdgeInsets.all(12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
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
              e.tag,
              style: const TextStyle(
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
                Text(
                  e.name,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.textPrimary,
                  ),
                ),
                const SizedBox(height: 4),
                _line('识别', e.detectLogic),
                _line('解压', e.extractLogic),
                // 只有**格式特有**的分卷命名才单独列一行。通用裸切分对任何格式
                // 都成立，写在这里是重复噪音，统一放在折叠头那句说明里。
                if (e.split != null) _line('分卷', e.split!),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 卡片里的一行「标签 + 值」。
  ///
  /// 值用 [Expanded] 而不是 `maxLines: 1` + 省略号：这些字符串是**判据本身**
  /// （`52 61 72 21 1A 07 00` 剪掉尾巴就没意义了），宁可折行也不许截断。
  Widget _line(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 30,
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 10,
                color: AppTheme.textDim,
                fontFamily: 'monospace',
                height: 1.5,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                fontSize: 10,
                color: AppTheme.textSecondary,
                fontFamily: 'monospace',
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
