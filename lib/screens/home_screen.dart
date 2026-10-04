import 'package:flutter/material.dart';

import '../engine/format.dart';
import '../theme/app_theme.dart';
import '../providers/app_state.dart';
import '../models/archive_file.dart';
import '../services/file_manager_bridge.dart';
import '../widgets/glass_card.dart';
import '../widgets/custom_button.dart';
import '../widgets/modals/confirm_extract_modal.dart';
import '../widgets/modals/path_fallback_modal.dart';

/// 首页 —— 解压中心
class HomeScreen extends StatelessWidget {
  final AppState state;

  /// 打开输出目录要过原生通道。[bridge] 只给测试注入用。
  final FileManagerBridge _bridge;

  HomeScreen({super.key, required this.state, FileManagerBridge? bridge})
      : _bridge = bridge ?? FileManagerBridge();

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
            if (!state.folderSelected) _buildFolderPicker(context),
            if (state.folderSelected) _buildFolderSelected(context),
            if (state.scanning) ...[
              const SizedBox(height: 16),
              _buildScanningPanel(),
            ],
            if (state.hasScanned &&
                !state.extracting &&
                !state.completed &&
                !state.scanning) ...[
              const SizedBox(height: 16),
              _buildScanResult(),
            ],
            if (state.extracting) ...[
              const SizedBox(height: 16),
              _buildProgressPanel(),
            ],
            if (state.completed) ...[
              const SizedBox(height: 16),
              _buildCompleteBanner(context),
            ],
            const SizedBox(height: 16),
            PrimaryButton(
              label: _primaryLabel,
              icon: _primaryIcon,
              disabled: _primaryDisabled,
              onPressed: () => _onStart(context),
            ),
          ],
        );
      },
    );
  }

  /// 主按钮的文案。四态：扫描中 / 停止解压 / 这批已跑过 / 待启动。
  ///
  /// **没有「继续」这一态。** 界面上唯一会「停下来」的地方是错误弹窗，而那
  /// 个弹窗自己带着「跳过 / 停止」两颗按钮 —— 用户在那儿点「跳过」就等于
  /// 接着解下一个了，主按钮没有任何机会需要承担这个语义（见 `app_state.dart`
  /// 的 `stopExtract`）。所以解压中这颗唯一有意义的动作是**停下**。
  ///
  /// 「这批已跑过」必须单独一态：那批扫描结果一旦解过，再点不会「重新解一遍」
  /// —— 输出目录重名会追加 `_1`/`_2`（见 `output_paths.dart`），等于往磁盘里
  /// 撒重复目录。所以按钮改成「换个文件夹」，让它去干真正有用的事。
  String get _primaryLabel {
    if (state.scanning) return '正在扫描...';
    if (state.extracting) return '停止解压';
    if (state.batchRun) return '换个文件夹';
    return '开始智能解压';
  }

  IconData get _primaryIcon {
    // `stop` 而不是 `pause`：这一颗按下去队列就丢了，画成两根竖条会让人以为
    // 还能接回来（见 [_primaryLabel]）。
    if (state.extracting) return Icons.stop;
    if (state.batchRun) return Icons.folder_open;
    return Icons.play_arrow;
  }


  /// 扫描中不能重复触发（解压中那颗是「停止」，恰恰必须可点）。
  ///
  /// 「换个文件夹」永远可点 —— 它是脱困路径，禁用它等于把用户困在一批
  /// 已经跑过的结果里。
  bool get _primaryDisabled {
    if (state.scanning) return true;
    if (state.extracting) return false;
    if (state.batchRun) return false;
    return !state.hasScanned;
  }

  Widget _buildHeader() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                gradient: AppTheme.primaryGradient,
                borderRadius: BorderRadius.circular(12),
                boxShadow: AppTheme.neonGlow(AppTheme.neonCyan),
              ),
              child: const Icon(Icons.layers, color: AppTheme.bgDeep, size: 24),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ShaderMask(
                  shaderCallback: (bounds) =>
                      AppTheme.primaryGradient.createShader(bounds),
                  child: const Text(
                    'DeepUnzip',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ),
                const Text(
                  'INTELLIGENT EXTRACTION ENGINE v2.4',
                  style: TextStyle(
                    fontSize: 11,
                    color: AppTheme.textDim,
                    fontFamily: 'monospace',
                    letterSpacing: 1,
                  ),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: AppTheme.neonGreen.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: AppTheme.neonGreen.withValues(alpha: 0.2),
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 6,
                height: 6,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppTheme.neonGreen,
                  boxShadow: [
                    BoxShadow(color: AppTheme.neonGreen, blurRadius: 8),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Text(
                '解压引擎就绪 · 支持 12 种格式 · 递归深度 ∞',
                style: TextStyle(
                  fontSize: 12,
                  fontFamily: 'monospace',
                  color: AppTheme.neonGreen,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildFolderPicker(BuildContext context) {
    return GlassCard(
      onTap: () => state.selectFolder(),
      padding: const EdgeInsets.symmetric(vertical: 20),
      radius: 18,
      child: Column(
        children: [
          Container(
            width: 56,
            height: 56,
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              gradient: AppTheme.cardGradient,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: AppTheme.neonCyan.withValues(alpha: 0.2),
              ),
            ),
            child: const Icon(
              Icons.folder_open,
              color: AppTheme.neonCyan,
              size: 28,
            ),
          ),
          const Text(
            '选择目标文件夹',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: AppTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            '递归扫描所有压缩包 · 自动识别嵌套结构',
            style: TextStyle(
              fontSize: 12,
              color: AppTheme.textDim,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFolderSelected(BuildContext context) {
    return GlassCard(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              gradient: AppTheme.cardGradient,
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.folder, color: AppTheme.neonCyan, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  state.folderName,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  state.folderPath,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppTheme.textDim,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
          ),
          // 解压中不许换目录。**这是一个真洞**，真机验收时发现的：解压是
          // `unawaited(_runExtractBatch())` 起的后台流程，跑起来之后谁也拦不住
          // 它；这时候换目录会把 `_folderPath` 和两条扫描列表全清掉重建，而批次
          // 还在按**旧**的队列往磁盘上写 —— 进度条、日志、总结卡片说的都是新目录
          // 的事，实际解的是旧目录的包。想换就等这一批停下来（主按钮左上那颗）。
          //
          // 禁用而不是隐藏：按钮忽然消失会让布局跳动，而且用户会以为界面坏了。
          // 灰掉 + 不响应，配着旁边那颗「停止解压」，路径是清楚的。
          GestureDetector(
            onTap: state.extracting ? null : () => state.selectFolder(),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: AppTheme.neonCyan
                    .withValues(alpha: state.extracting ? 0.03 : 0.08),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: AppTheme.neonCyan
                      .withValues(alpha: state.extracting ? 0.1 : 0.3),
                ),
              ),
              child: Text(
                '更换',
                style: TextStyle(
                  fontSize: 12,
                  color: state.extracting
                      ? AppTheme.textDim
                      : AppTheme.neonCyan,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildScanResult() {
    final archives = state.archives;
    final pwdCount = archives
        .where((a) => a.flags.contains(ArchiveFlag.encrypted))
        .length;
    final specialCount = archives
        .where(
          (a) =>
              a.flags.contains(ArchiveFlag.split) ||
              a.flags.contains(ArchiveFlag.fakeExtension) ||
              a.flags.contains(ArchiveFlag.nested),
        )
        .length;

    return GlassCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                '扫描结果',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textPrimary,
                ),
              ),
              Text(
                '${archives.length} 个压缩包',
                style: const TextStyle(
                  fontSize: 11,
                  fontFamily: 'monospace',
                  color: AppTheme.neonCyan,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              _statItem('${archives.length}', '总文件', AppTheme.neonCyan),
              _statItem('$pwdCount', '需密码', AppTheme.neonPurple),
              _statItem('$specialCount', '特殊格式', AppTheme.neonOrange),
            ],
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: 200,
            child: ListView.builder(
              itemCount: archives.length,
              itemBuilder: (context, i) => _fileItem(archives[i]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _statItem(String num, String label, Color color) {
    return Expanded(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 4),
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.02),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white.withValues(alpha: 0.04)),
        ),
        child: Column(
          children: [
            Text(
              num,
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w700,
                fontFamily: 'monospace',
                color: color,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: const TextStyle(fontSize: 10, color: AppTheme.textDim),
            ),
          ],
        ),
      ),
    );
  }

  Widget _fileItem(ArchiveFile f) {
    final typeColors = {
      ArchiveType.zip: AppTheme.neonCyan,
      ArchiveType.rar: AppTheme.neonPurple,
      ArchiveType.sevenz: AppTheme.neonOrange,
      ArchiveType.tar: AppTheme.neonGreen,
      ArchiveType.unknown: AppTheme.neonRed,
    };
    final color = typeColors[f.type]!;
    final flagMap = {
      ArchiveFlag.encrypted: ('加密', AppTheme.neonOrange),
      ArchiveFlag.split: ('分片', AppTheme.neonPurple),
      ArchiveFlag.fakeExtension: ('伪后缀', AppTheme.neonRed),
      ArchiveFlag.nested: ('嵌套', AppTheme.neonGreen),
    };

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
      decoration: BoxDecoration(
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
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: color.withValues(alpha: 0.2)),
            ),
            alignment: Alignment.center,
            child: Text(
              f.typeLabel,
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w700,
                fontFamily: 'monospace',
                color: color,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  f.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: AppTheme.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${f.size} · 深度 ${f.depth}',
                  style: const TextStyle(
                    fontSize: 10,
                    color: AppTheme.textDim,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Row(
            children: f.flags
                .map(
                  (fl) =>
                      FlagBadge(text: flagMap[fl]!.$1, color: flagMap[fl]!.$2),
                )
                .toList(),
          ),
        ],
      ),
    );
  }

  /// 扫描中的反馈。
  ///
  /// 刻意**不用百分比**：扫描是没有分母的 —— 目录里到底有几个压缩包，
  /// 只有扫完才知道。任何「37%」都只能是编的，所以这里用不确定指示器 +
  /// 已发现数。
  Widget _buildScanningPanel() {
    return GlassCard(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Row(
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation(AppTheme.neonCyan),
                    ),
                  ),
                  SizedBox(width: 10),
                  Text(
                    '正在递归扫描',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.textPrimary,
                    ),
                  ),
                ],
              ),
              Text(
                '已发现 ${state.scanFound} 个',
                style: const TextStyle(
                  fontSize: 12,
                  fontFamily: 'monospace',
                  color: AppTheme.neonCyan,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: AppTheme.neonCyan.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: AppTheme.neonCyan.withValues(alpha: 0.1),
              ),
            ),
            child: Row(
              children: [
                const Icon(Icons.search, size: 15, color: AppTheme.neonCyan),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    state.scanCurrent.isEmpty ? '准备中...' : state.scanCurrent,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11,
                      fontFamily: 'monospace',
                      color: AppTheme.neonCyan,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              GestureDetector(
                onTap: state.cancelScan,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: AppTheme.neonOrange.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: AppTheme.neonOrange.withValues(alpha: 0.3),
                    ),
                  ),
                  child: const Text(
                    '取消扫描',
                    style: TextStyle(fontSize: 12, color: AppTheme.neonOrange),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildProgressPanel() {
    return GlassCard(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: AppTheme.neonGreen.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.circle, size: 4, color: AppTheme.neonGreen),
                        SizedBox(width: 4),
                        Text(
                          'LIVE',
                          style: TextStyle(
                            fontSize: 9,
                            fontFamily: 'monospace',
                            color: AppTheme.neonGreen,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Text(
                    '正在解压',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.textPrimary,
                    ),
                  ),
                ],
              ),
              Text(
                formatPercent(state.progress),
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  fontFamily: 'monospace',
                  color: AppTheme.neonCyan,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: state.progress,
              minHeight: 8,
              backgroundColor: Colors.white.withValues(alpha: 0.05),
              valueColor: const AlwaysStoppedAnimation(AppTheme.neonCyan),
            ),
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: AppTheme.neonCyan.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: AppTheme.neonCyan.withValues(alpha: 0.1),
              ),
            ),
            child: Row(
              children: [
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation(AppTheme.neonCyan),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    state.currentFile,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      fontFamily: 'monospace',
                      color: AppTheme.neonCyan,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              _psItem('${state.doneCount}', '已完成'),
              _psItem(state.speed.toStringAsFixed(1), 'MB/s'),
              _psItem('${state.depth}', '递归层'),
              _psItem(state.eta, '剩余'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _psItem(String v, String l) {
    return Expanded(
      child: Column(
        children: [
          Text(
            v,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              fontFamily: 'monospace',
              color: AppTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 2),
          Text(l, style: const TextStyle(fontSize: 9, color: AppTheme.textDim)),
        ],
      ),
    );
  }

  /// 这一批收尾后的总结卡片。
  ///
  /// 三档标题，由 [AppState.stopReason] 决定 —— **被停掉的那两档绝不能显示
  /// 「全部解压完成」**：剩下的包一个都没解，绿卡片上写「完成」是直接骗人。
  /// 真机验收时用户要求停止后也落在这张卡片上（并且主按钮是「换个文件夹」），
  /// 说法是「像格式弹窗一样，不管点哪个都能跳到总结页」。
  String get _bannerTitle {
    switch (state.stopReason) {
      case null:
        return '全部解压完成';
      case StopSource.user:
        return '已停止';
      case StopSource.error:
        return '解压出错，已停止';
    }
  }

  Widget _buildCompleteBanner(BuildContext context) {
    // 停下来用暖色 + 停止图标：绿勾配「已停止」是个自相矛盾的画面。
    final stopped = state.stopReason != null;
    final accent = stopped ? AppTheme.neonOrange : AppTheme.neonGreen;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            accent.withValues(alpha: 0.1),
            AppTheme.neonCyan.withValues(alpha: 0.05),
          ],
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: accent.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  stopped ? Icons.stop_circle : Icons.check_circle,
                  color: accent,
                  size: 24,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _bannerTitle,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: accent,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      state.completeDetail,
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppTheme.textDim,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          // 解压默认是「后台作业」：跑完只给你一行字，文件在哪还得自己去翻。
          // 给个直达入口 —— 打开根目录就能看到那棵与源目录对称的树。
          if (state.folderPath.isNotEmpty) ...[
            const SizedBox(height: 14),
            GestureDetector(
              onTap: () => _openOutputDir(context),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: accent.withValues(alpha: 0.3)),
                ),
                // 停下来那两档这条也要留着：已经解好的那部分是真的解好了，
                // 半路停下的人最想干的事就是去看看到底解出来了什么。
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.folder_open, size: 16, color: accent),
                    const SizedBox(width: 8),
                    Text(
                      '打开输出目录',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: accent,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 主按钮：同一个按钮在四个状态间切换语义。
  ///
  /// 原来这里是「2/5/8 秒后分别弹出密码、格式、错误三个弹窗」的假触发。
  /// 已删除：真弹窗必须由引擎在**真实事件**上驱动（P3 的 `dialog_bridge`
  /// 通过 `AppNavigator` 弹），而不是由定时器按秒表演一遍。
  Future<void> _onStart(BuildContext context) async {
    if (state.extracting) {
      state.stopExtract();
      return;
    }
    // 这批已经跑过一轮。按钮的语义是「换个文件夹」，不是「再来一遍」——
    // 重跑不覆盖而是追加 `_1`/`_2`，见 [_primaryLabel]。走 selectFolder 而不是
    // 在这里直接清状态：**先选、选到了再清**，用户取消选择器时原来那批结果
    // 还在（`selectFolderPath` 内部才 `_resetExtractState`）。
    if (state.batchRun) {
      state.selectFolder();
      return;
    }
    if (state.archives.isEmpty) {
      state.showToast('先选择一个文件夹并完成扫描', type: 'warn');
      return;
    }
    final archives = state.archives;
    final confirmed = await ConfirmExtractModal.show(
      context: context,
      archiveCount: archives.length,
      encryptedCount: archives
          .where((a) => a.flags.contains(ArchiveFlag.encrypted))
          .length,
      splitCount:
          archives.where((a) => a.flags.contains(ArchiveFlag.split)).length,
      folderName: state.folderName,
    );
    // 滑掉 = false（见 ConfirmExtractModal.show）：写盘前手滑关掉不该等于同意。
    if (!confirmed) return;
    state.startExtract();
  }

  /// 请系统文件管理器打开解压出来的那棵树。
  ///
  /// 输出目录是**每个压缩包各自同级**的，所以没有单一「输出根」；但整个树都在
  /// 所选根目录底下，打开根目录就能看到。这里传的就是 `state.folderPath`。
  ///
  /// 只有 [OpenFolderResult.opened] 是真成功。其余几档都**必须如实告诉用户**，
  /// 尤其是 `openedGeneric` —— 它表示「文件管理器开了，但没跳到那个目录」，
  /// 国产 ROM 上是常态；假装成功的话用户会对着一个不相干的目录找半天。
  Future<void> _openOutputDir(BuildContext context) async {
    final path = state.folderPath;
    if (path.isEmpty) return;
    final result = await _bridge.openFolder(path);
    if (!context.mounted) return;
    switch (result) {
      case OpenFolderResult.opened:
        state.showToast('已打开输出目录', type: 'ok');
      case OpenFolderResult.openedGeneric:
        await PathFallbackModal.show(
          context: context,
          headline: '没能定位到目录',
          detail: '文件管理器已经打开，但这台设备的文件管理器不支持直接跳到指定目录。'
              '可以复制下面的路径，在里面粘贴访问。',
          path: path,
        );
      case OpenFolderResult.unsupportedPath:
        await PathFallbackModal.show(
          context: context,
          headline: '这个位置打不开',
          detail: '该路径不在外部存储上，系统文件管理器表达不了它。请用下面这个路径访问。',
          path: path,
        );
      case OpenFolderResult.noHandler:
        await PathFallbackModal.show(
          context: context,
          headline: '没有可用的文件管理器',
          detail: '这台设备上找不到能打开文件夹的应用。请用下面这个路径访问。',
          path: path,
        );
      case OpenFolderResult.unavailable:
        await PathFallbackModal.show(
          context: context,
          headline: '当前环境不支持',
          detail: '打开目录依赖 Android 系统能力，当前环境没有这条通道。'
              '请用下面这个路径访问。',
          path: path,
        );
    }
  }
}
