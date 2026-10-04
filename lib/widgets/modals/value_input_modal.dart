import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import 'bottom_modal.dart';
import 'modal_button.dart';

/// 一个数字的编辑弹窗：预填当前值、实时预览解析结果、确定后 `pop` 回数字。
///
/// ## 为什么是通用的，而不是每个设置各写一个
///
/// 它是从 `limit_value_modal.dart` 抽出来的 —— 那个弹窗的**排版**（图标 + 标题 +
/// 说明 + 输入框 + 预览行 + 两个按钮）跟「改哪一项数字」毫无关系，而右下角那颗
/// 按钮的置灰逻辑更是每个调用方都会踩的坑。各写一份的话，第一次改样式就要改
/// 三处，改漏一处的表现是「这个弹窗长得不太一样」—— 那种错没人会当 bug 报。
///
/// 所以这里只留「排版 + 交互」，**解析与校验由调用方给**：数字怎么认（字节？
/// 条数？）是那一项自己的事。
///
/// ## 解析失败不兜底
///
/// 认不出来就把「确定」置灰，**不**悄悄用默认值顶上 —— 那样用户会以为改成功
/// 了。输入框下方有实时预览把解析结果回显出来，歧义当场可见。
///
/// [check] 是解析成功之后的第二道（比如「不在 1–5000 里」）：它和解析失败走
/// 同一个展示位、同一种红字，因为对用户来说这两件事没区别 —— 都是「这个数现在
/// 不能提交，原因写在下面那一行」。
class ValueInputModal extends StatefulWidget {
  const ValueInputModal({
    super.key,
    required this.icon,
    required this.accent,
    required this.title,
    required this.subtitle,
    required this.initialText,
    required this.inputHint,
    required this.parse,
    required this.preview,
    this.check,
    this.keyboardType = TextInputType.text,
  });

  final IconData icon;
  final Color accent;
  final String title;
  final String subtitle;

  /// 打开时预填的文本。给**展示形态**（`8 GB` / `200,000`）而不是裸数字：
  /// 用户看到的就是设置页上那一行，改的是数字，单位原样留着。
  final String initialText;

  final String inputHint;

  /// 认不出返回 null。
  final int? Function(String text) parse;

  /// 解析成功时那一行预览怎么写。
  final String Function(int value) preview;

  /// 解析成功之后的额外校验。返回一句错误文案表示不接受；null 表示可以提交。
  final String? Function(int value)? check;

  final TextInputType keyboardType;

  /// 返回用户确定的新值；取消（含手势滑走）返回 null。
  static Future<int?> show({
    required BuildContext context,
    required IconData icon,
    required Color accent,
    required String title,
    required String subtitle,
    required String initialText,
    required String inputHint,
    required int? Function(String text) parse,
    required String Function(int value) preview,
    String? Function(int value)? check,
    TextInputType keyboardType = TextInputType.text,
  }) {
    return showBottomModal<int>(
      context: context,
      child: ValueInputModal(
        icon: icon,
        accent: accent,
        title: title,
        subtitle: subtitle,
        initialText: initialText,
        inputHint: inputHint,
        parse: parse,
        preview: preview,
        check: check,
        keyboardType: keyboardType,
      ),
    );
  }

  @override
  State<ValueInputModal> createState() => _ValueInputModalState();
}

class _ValueInputModalState extends State<ValueInputModal> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initialText);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  /// 当前输入解析出来的值；解析不出来为 null。
  int? get _parsed => widget.parse(_ctrl.text.trim());

  /// 预览行要说的话。null 表示这个值可以提交。
  String? get _error {
    final v = _parsed;
    if (v == null) return '无法识别，改完再试';
    return widget.check?.call(v);
  }

  void _save() {
    final v = _parsed;
    if (v == null || _error != null) return;
    Navigator.pop(context, v);
  }

  @override
  Widget build(BuildContext context) {
    final parsed = _parsed;
    final error = _error;
    final ok = error == null;

    // 分开写而不是三元：`ok` 是个独立的 bool，分析器不会据此把 `parsed` /
    // `error` 提升成非空，写在三元里就得靠 `!` 糊过去。
    final String line;
    if (error == null) {
      // 能提交才回显解析结果；`parsed` 在 `_error` 里已经验过非空。
      line = '= ${widget.preview(parsed!)}';
    } else {
      line = error;
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(widget.icon, color: widget.accent, size: 20),
              const SizedBox(width: 10),
              Text(
                widget.title,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.textPrimary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            widget.subtitle,
            style: const TextStyle(
              fontSize: 12,
              color: AppTheme.textDim,
              fontFamily: 'monospace',
            ),
          ),
          const SizedBox(height: 18),

          TextField(
            controller: _ctrl,
            autofocus: true,
            keyboardType: widget.keyboardType,
            style: const TextStyle(
              fontSize: 13,
              fontFamily: 'monospace',
              color: AppTheme.neonCyan,
            ),
            // 每敲一个字都要重算预览，所以不能只在提交时读值。
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _save(),
            decoration: InputDecoration(
              hintText: widget.inputHint,
              hintStyle: const TextStyle(
                fontSize: 12,
                fontFamily: 'monospace',
                color: AppTheme.textDim,
              ),
              filled: true,
              fillColor: Colors.black.withValues(alpha: 0.35),
              contentPadding: const EdgeInsets.all(12),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide:
                    BorderSide(color: widget.accent.withValues(alpha: 0.15)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide:
                    BorderSide(color: widget.accent.withValues(alpha: 0.15)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: widget.accent),
              ),
            ),
          ),
          const SizedBox(height: 8),

          // 实时预览。认不出来 / 不在范围内都在这一行说清楚，而不是留白让用户猜。
          Row(
            children: [
              Icon(
                ok ? Icons.check_circle_outline : Icons.error_outline,
                size: 12,
                color: ok ? AppTheme.neonGreen : AppTheme.neonRed,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  line,
                  style: TextStyle(
                    fontSize: 11,
                    fontFamily: 'monospace',
                    color: ok ? AppTheme.neonGreen : AppTheme.neonRed,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),

          Row(
            children: [
              Expanded(
                child: ModalButton(
                  label: '取消',
                  color: AppTheme.textDim,
                  onTap: () => Navigator.pop(context),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                // 解析不出来时**看起来就该按不动**：淡化 + 吞掉点击。
                // 反例是「按钮还在、点了没反应」，那会被当成卡死。
                //
                // 不用 ModalButton 的禁用态是因为它没有 —— 加一个 `enabled`
                // 参数就要动这个三个弹窗共用的组件，为一个局部需求改公共
                // 契约不划算，包一层 `Opacity` + `IgnorePointer` 就够。
                child: Opacity(
                  opacity: ok ? 1 : 0.4,
                  child: IgnorePointer(
                    ignoring: !ok,
                    child: ModalButton(
                      label: '确定',
                      gradient: AppTheme.primaryGradient,
                      onTap: _save,
                    ),
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
