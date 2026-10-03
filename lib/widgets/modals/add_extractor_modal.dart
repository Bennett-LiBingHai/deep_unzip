import 'package:flutter/material.dart';
import '../../theme/app_theme.dart';
import '../../models/extractor.dart';
import 'bottom_modal.dart';

/// 注册解压方式弹窗
class AddExtractorModal extends StatefulWidget {
  final void Function(Extractor) onSave;

  const AddExtractorModal({super.key, required this.onSave});

  static Future<void> show({
    required BuildContext context,
    required void Function(Extractor) onSave,
  }) {
    return showBottomModal(
      context: context,
      child: AddExtractorModal(onSave: onSave),
    );
  }

  @override
  State<AddExtractorModal> createState() => _AddExtractorModalState();
}

class _AddExtractorModalState extends State<AddExtractorModal> {
  final _nameCtrl = TextEditingController();
  final _detectCtrl = TextEditingController();
  final _extractCtrl = TextEditingController();
  ExtractorType _type = ExtractorType.single;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _detectCtrl.dispose();
    _extractCtrl.dispose();
    super.dispose();
  }

  void _save() {
    final name = _nameCtrl.text.trim();
    final detect = _detectCtrl.text.trim();
    final extract = _extractCtrl.text.trim();
    if (name.isEmpty || detect.isEmpty || extract.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请填写完整信息')),
      );
      return;
    }
    widget.onSave(Extractor(
      name: name.toUpperCase(),
      type: _type,
      detectLogic: detect.length > 60 ? '${detect.substring(0, 60)}...' : detect,
      extractLogic: extract,
    ));
    Navigator.pop(context);
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
              const Icon(Icons.code, color: AppTheme.neonCyan, size: 20),
              const SizedBox(width: 10),
              const Text('注册解压方式',
                  style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.textPrimary)),
            ],
          ),
          const SizedBox(height: 6),
          const Text('扩展引擎支持的压缩格式 · 函数参数均为文件地址',
              style: TextStyle(
                  fontSize: 12,
                  color: AppTheme.textDim,
                  fontFamily: 'monospace')),
          const SizedBox(height: 18),

          // 类型名称
          const _Label('类型名称', required: true),
          const SizedBox(height: 6),
          _codeField(_nameCtrl, '如：ZSTD、LHA、ACE', maxLines: 1),
          const SizedBox(height: 14),

          // 解压类型
          const _Label('解压类型', required: true),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: _segBtn(
                  '单文件解压',
                  ExtractorType.single,
                  AppTheme.neonCyan,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _segBtn(
                  '分片文件解压',
                  ExtractorType.split,
                  AppTheme.neonPurple,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),

          // 判断函数
          const _Label('判断函数', required: true),
          const SizedBox(height: 4),
          const Text('isType(filePath) → boolean',
              style: TextStyle(
                  fontSize: 10,
                  color: AppTheme.textDim,
                  fontFamily: 'monospace')),
          const SizedBox(height: 6),
          _codeField(
            _detectCtrl,
            '// 根据文件头/后缀判断是否为此类型\nfunction isType(filePath) {\n  const header = readFileHeader(filePath, 4);\n  return header === \'0x28B52FFD\';\n}',
            maxLines: 5,
          ),
          const SizedBox(height: 14),

          // 解压函数
          const _Label('解压函数', required: true),
          const SizedBox(height: 4),
          const Text('extract(filePath, outputDir) → result',
              style: TextStyle(
                  fontSize: 10,
                  color: AppTheme.textDim,
                  fontFamily: 'monospace')),
          const SizedBox(height: 6),
          _codeField(
            _extractCtrl,
            '// 执行解压，返回结果对象\nfunction extract(filePath, outputDir) {\n  return invokeExternalTool(\'zstd\', [\n    \'-d\', filePath, \'-o\', outputDir\n  ]);\n}',
            maxLines: 5,
          ),
          const SizedBox(height: 20),

          Row(
            children: [
              Expanded(
                child: GestureDetector(
                  onTap: () => Navigator.pop(context),
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
                  onTap: _save,
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    decoration: BoxDecoration(
                      gradient: AppTheme.primaryGradient,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    alignment: Alignment.center,
                    child: const Text('注册',
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

  Widget _segBtn(String label, ExtractorType type, Color color) {
    final active = _type == type;
    return GestureDetector(
      onTap: () => setState(() => _type = type),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: active ? color.withOpacity(0.1) : Colors.white.withOpacity(0.03),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: active ? color.withOpacity(0.3) : Colors.white.withOpacity(0.08),
          ),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: active ? color : AppTheme.textDim,
            fontFamily: 'monospace',
          ),
        ),
      ),
    );
  }

  Widget _codeField(TextEditingController ctrl, String hint, {int maxLines = 1}) {
    return TextField(
      controller: ctrl,
      maxLines: maxLines,
      style: const TextStyle(
          fontSize: 11,
          fontFamily: 'monospace',
          color: AppTheme.neonGreen,
          height: 1.6),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(
            fontSize: 11,
            fontFamily: 'monospace',
            color: AppTheme.textDim,
            height: 1.6),
        filled: true,
        fillColor: Colors.black.withOpacity(0.35),
        contentPadding: const EdgeInsets.all(12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: AppTheme.neonCyan.withOpacity(0.15)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: AppTheme.neonCyan.withOpacity(0.15)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppTheme.neonCyan),
        ),
      ),
    );
  }
}

class _Label extends StatelessWidget {
  final String text;
  final bool required;
  const _Label(this.text, {this.required = false});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(text,
            style: const TextStyle(
                fontSize: 11,
                color: AppTheme.textSecondary,
                fontWeight: FontWeight.w600,
                fontFamily: 'monospace')),
        if (required)
          const Text(' *', style: TextStyle(color: AppTheme.neonRed)),
      ],
    );
  }
}
