import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../theme/app_theme.dart';

/// 许可全文页：把一份 asset 里的纯文本原样读出来显示。
///
/// ## 为什么原文照搬，不做排版
///
/// 这是**法律文本**：换行、大写、`THIS SOFTWARE IS PROVIDED "AS IS"` 那一段的
/// 全大写都是条款的一部分。任何「美化」（重新折行、加小标题、翻译）都可能被
/// 说成改动了许可原文。所以整段塞进一个可滚动、可复制的 `SelectableText`，
/// 等宽字体，不改一个字。
///
/// 也**不翻译**：翻译件没有法律效力，摆一份译文只会让人分不清该信哪个。
class LicenseTextScreen extends StatefulWidget {
  /// 页面标题（组件名）。
  final String title;

  /// asset 路径。
  final String asset;

  const LicenseTextScreen({super.key, required this.title, required this.asset});

  /// 推一个全屏路由打开它。许可正文动辄几百行，底部弹窗装不下。
  static Future<void> show(
    BuildContext context, {
    required String title,
    required String asset,
  }) {
    return Navigator.of(context).push<void>(MaterialPageRoute(
      builder: (_) => LicenseTextScreen(title: title, asset: asset),
    ));
  }

  @override
  State<LicenseTextScreen> createState() => _LicenseTextScreenState();
}

class _LicenseTextScreenState extends State<LicenseTextScreen> {
  late final Future<String> _text = rootBundle.loadString(widget.asset);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgDeep,
      appBar: AppBar(
        backgroundColor: AppTheme.bgMid,
        elevation: 0,
        title: Text(
          widget.title,
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: AppTheme.textPrimary,
          ),
        ),
        iconTheme: const IconThemeData(color: AppTheme.textSecondary),
      ),
      body: FutureBuilder<String>(
        future: _text,
        builder: (context, snap) {
          if (snap.hasError) {
            // 读不出来就如实说。资产没打包进去是构建配置的问题，不是用户的
            // 操作问题 —— 但把「什么都没有」当成「没有许可要展示」是错的。
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  '许可文本读不出来：${snap.error}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppTheme.neonRed,
                    fontFamily: 'monospace',
                    height: 1.6,
                  ),
                ),
              ),
            );
          }
          if (!snap.hasData) {
            return const Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            );
          }
          return Scrollbar(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
              child: SelectableText(
                snap.data!,
                // 不做 `softWrap` 之类的调整：原文怎么断就怎么显示。
                style: const TextStyle(
                  fontSize: 11,
                  height: 1.6,
                  color: AppTheme.textSecondary,
                  fontFamily: 'monospace',
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
