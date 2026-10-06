import 'package:flutter/material.dart';

import '../app_info.dart';
import '../data/builtin_extractors.dart';
import '../data/third_party_notices.dart';
import '../theme/app_theme.dart';
import 'license_text_screen.dart';

/// 「关于」页：版本、隐私声明、第三方组件与许可全文。
///
/// ## 为什么这个页面非有不可
///
/// 本应用使用了 7-Zip（LGPL-2.1 + unRAR 限制）与三个 BSD 文件。LGPL-2.1 §6 要求
/// 「显著注明本作品使用了该库且其使用受本许可约束、附上本许可的一份副本」，BSD-3
/// 要求「二进制分发时复现版权声明与免责声明」—— 而 APK 里**没有第二个地方**能
/// 兑现它们：那些文本躺在 `third_party/7zip/DOC/` 里，用户看不到。所以这一页的
/// 一半是合规材料。
///
/// 另一半是国内上架最值钱的那句话：**不联网、不收集个人信息**。Release 包确实
/// 不声明 `INTERNET` 权限（只有 debug/profile 清单里有，那是 Flutter 调试要的），
/// 所以这句话是真的，而且可以写得很硬。
///
/// 页面结构刻意简单，两个区各管一头、**互不重叠**：
///
/// - 「第三方组件」是**声明**（哪些组件、什么许可、要交代的限制）—— 不可点。
///   §6 要的那个「注明」就是这一段显示出来的字，本来也不靠点。
/// - 「许可全文」是**文档** —— 每个落点只有一行进得去。
///
/// 从前两边都能点、指向同一批文档（`7zip.txt` 三个入口、Flutter 许可页两个），
/// 还有一张卡的名字和它点开的内容对不上。别把可点加回上面那一区。
class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgDeep,
      appBar: AppBar(
        backgroundColor: AppTheme.bgMid,
        elevation: 0,
        iconTheme: const IconThemeData(color: AppTheme.textSecondary),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 40),
        children: [
          _header(),
          const SizedBox(height: 20),
          _privacyCard(),
          const SizedBox(height: 20),
          _sectionTitle('第三方组件'),
          for (final n in kThirdPartyNotices)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _notice(n),
            ),
          const SizedBox(height: 10),
          _sectionTitle('许可全文'),
          _fullTextRow(
            context,
            label: '7-Zip 许可与限制（含 BSD 全文）',
            asset: kSevenZipLicenseAsset,
          ),
          const SizedBox(height: 8),
          _fullTextRow(context, label: 'GNU LGPL 2.1 全文', asset: kLgpl21Asset),
          const SizedBox(height: 8),
          _flutterLicensesRow(context),
        ],
      ),
    );
  }

  Widget _header() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ShaderMask(
          shaderCallback: (bounds) =>
              AppTheme.primaryGradient.createShader(bounds),
          child: const Text(
            kAppName,
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          kAppTagline,
          style: const TextStyle(
            fontSize: 12,
            color: AppTheme.textDim,
            fontFamily: 'monospace',
            height: 1.5,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          '版本 $kAppVersion',
          style: const TextStyle(
            fontSize: 12,
            color: AppTheme.textSecondary,
            fontFamily: 'monospace',
          ),
        ),
        const SizedBox(height: 2),
        Text(
          // 数量直接读清单，免得这里再手写一个数字慢慢跟现实脱节。
          '支持 ${BuiltinExtractors.all.length} 种格式（含光盘与磁盘映像）',
          style: const TextStyle(
            fontSize: 12,
            color: AppTheme.textDim,
            fontFamily: 'monospace',
          ),
        ),
      ],
    );
  }

  /// 那句最值钱的话。
  ///
  /// 写得很硬是因为它**可核查**：Release 包不声明 INTERNET 权限、没有任何统计/
  /// 崩溃/广告 SDK。哪天有人加了一个联网的东西，这一页就是第一个该改的地方 ——
  /// 也是审核与用户都盯着的一句。
  Widget _privacyCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.neonGreen.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.neonGreen.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.wifi_off_outlined,
                size: 16,
                color: AppTheme.neonGreen,
              ),
              const SizedBox(width: 8),
              const Text(
                '不联网 · 不收集个人信息',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.neonGreen,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            '本应用不申请网络权限（Release 包不声明 INTERNET），没有统计、崩溃上报'
            '或广告 SDK，也不会把任何文件内容、文件名或路径发出去。'
            '解压全程在本机完成。',
            style: TextStyle(
              fontSize: 11,
              color: AppTheme.textSecondary,
              fontFamily: 'monospace',
              height: 1.6,
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String text) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 10),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 11,
          color: AppTheme.textDim,
          fontFamily: 'monospace',
          letterSpacing: 1.5,
        ),
      ),
    );
  }

  /// 一张**不可点**的组件声明卡。
  ///
  /// 从前它可点、跳向许可全文，于是和下面「许可全文」那几行重叠：`7zip.txt`
  /// 三个入口、Flutter 许可页两个；而且 `LZFSE / ZSTD / XXH64` 那张点开后
  /// 标题写着这几个名字、内容是整份 7-Zip 许可。现在这一区只负责「注明」
  /// （§6 要的就是这段显示出来的字），全文只从下面那一区进。
  Widget _notice(ThirdPartyNotice n) {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            n.name,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AppTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            n.summary,
            style: const TextStyle(
              fontSize: 11,
              color: AppTheme.textDim,
              fontFamily: 'monospace',
              height: 1.6,
            ),
          ),
        ],
      ),
    );
  }

  Widget _fullTextRow(
    BuildContext context, {
    required String label,
    required String asset,
  }) {
    return _card(
      onTap: () => LicenseTextScreen.show(context, title: label, asset: asset),
      child: Row(
        children: [
          const Icon(
            Icons.description_outlined,
            size: 15,
            color: AppTheme.textSecondary,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(fontSize: 12, color: AppTheme.textPrimary),
            ),
          ),
          const Icon(Icons.chevron_right, size: 16, color: AppTheme.textDim),
        ],
      ),
    );
  }

  /// pub 依赖的许可交给 Flutter 自己收集的那一份（构建期从各包的 LICENSE 生成）。
  Widget _flutterLicensesRow(BuildContext context) {
    return _card(
      onTap: () => _showFlutterLicenses(context),
      child: Row(
        children: [
          const Icon(
            Icons.inventory_2_outlined,
            size: 15,
            color: AppTheme.textSecondary,
          ),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'Dart / Flutter 组件许可（自动收集）',
              style: TextStyle(fontSize: 12, color: AppTheme.textPrimary),
            ),
          ),
          const Icon(Icons.chevron_right, size: 16, color: AppTheme.textDim),
        ],
      ),
    );
  }

  void _showFlutterLicenses(BuildContext context) {
    showLicensePage(
      context: context,
      applicationName: kAppName,
      applicationVersion: '版本 $kAppVersion',
      applicationLegalese: kAppTagline,
    );
  }

  /// 页面上的卡片。`onTap` 为 null 时是一张**纯展示**的卡（组件声明那三张）——
  /// 不套 `InkWell`：给一张没有去处的卡加上水波纹，会让人以为点得动。
  Widget _card({VoidCallback? onTap, required Widget child}) {
    final box = Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.glass,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.glassBorder),
      ),
      child: child,
    );
    if (onTap == null) return box;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: box,
      ),
    );
  }
}
