import 'package:flutter/material.dart';

import '../../engine/format.dart';
import '../../engine/limits.dart';
import '../../theme/app_theme.dart';
import 'bottom_modal.dart';
import 'modal_button.dart';

/// 改一项炸弹防护阈值。确定后 `pop` 回解析好的数字；取消（含手势滑走）
/// 回 `null`。
///
/// ## 为什么不做成一个「四个输入框」的大表单
///
/// 那样要一次校验四行、一起提交，用户改错一项没法只退一项。一次一行、
/// 即改即生效，跟设置页其它控件的节奏一致。
///
/// ## 解析失败不兜底
///
/// 认不出来就把「确定」置灰，**不**悄悄用默认值顶上 —— 那样用户会以为改
/// 成功了。输入框下方有实时预览把解析结果回显出来，歧义当场可见。
class LimitValueModal extends StatefulWidget {
  const LimitValueModal({super.key, required this.field, required this.current});

  final LimitField field;

  /// 当前这套阈值，用来取预填值。
  final LimitThresholds current;

  /// 返回 [field] 的新值；取消时返回 null。
  static Future<int?> show({
    required BuildContext context,
    required LimitField field,
    required LimitThresholds current,
  }) {
    return showBottomModal<int>(
      context: context,
      child: LimitValueModal(field: field, current: current),
    );
  }

  @override
  State<LimitValueModal> createState() => _LimitValueModalState();
}

class _LimitValueModalState extends State<LimitValueModal> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    // 预填当前值的**展示形态**（`8 GB` / `200,000`）而不是裸字节数：
    // 用户看到的就是设置页上那一行，改的是数字，单位原样留着。
    _ctrl = TextEditingController(text: widget.field.display(widget.current));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  /// 当前输入解析出来的值；解析不出来为 null。
  int? get _parsed {
    final text = _ctrl.text.trim();
    if (text.isEmpty) return null;
    return widget.field.isBytes ? parseSize(text) : parseCount(text);
  }

  void _save() {
    final v = _parsed;
    if (v == null) return;
    Navigator.pop(context, v);
  }

  @override
  Widget build(BuildContext context) {
    final parsed = _parsed;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.shield_outlined,
                  color: AppTheme.neonPurple, size: 20),
              const SizedBox(width: 10),
              Text(
                widget.field.label,
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
            widget.field.hint,
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
            keyboardType: TextInputType.text,
            style: const TextStyle(
              fontSize: 13,
              fontFamily: 'monospace',
              color: AppTheme.neonCyan,
            ),
            // 每敲一个字都要重算预览，所以不能只在提交时读值。
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _save(),
            decoration: InputDecoration(
              hintText: widget.field.isBytes ? '如：8 GB、512 MB' : '如：200000',
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
                    BorderSide(color: AppTheme.neonPurple.withValues(alpha: 0.15)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide:
                    BorderSide(color: AppTheme.neonPurple.withValues(alpha: 0.15)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: AppTheme.neonPurple),
              ),
            ),
          ),
          const SizedBox(height: 8),

          // 实时预览。解析不出来时说清楚「认不出来」，而不是留白让用户猜。
          Row(
            children: [
              Icon(
                parsed == null ? Icons.error_outline : Icons.check_circle_outline,
                size: 12,
                color: parsed == null ? AppTheme.neonRed : AppTheme.neonGreen,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  parsed == null
                      ? '无法识别，改完再试'
                      : '= ${widget.field.isBytes ? formatBytes(parsed) : formatCount(parsed)}',
                  style: TextStyle(
                    fontSize: 11,
                    fontFamily: 'monospace',
                    color: parsed == null ? AppTheme.neonRed : AppTheme.neonGreen,
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
                  opacity: parsed == null ? 0.4 : 1,
                  child: IgnorePointer(
                    ignoring: parsed == null,
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
