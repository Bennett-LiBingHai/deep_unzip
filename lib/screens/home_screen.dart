import 'package:flutter/material.dart';

import '../engine/format.dart';
import '../theme/app_theme.dart';
import '../providers/app_state.dart';
import '../models/archive_file.dart';
import '../widgets/glass_card.dart';
import '../widgets/custom_button.dart';

/// 首页 —— 解压中心
class HomeScreen extends StatelessWidget {
  final AppState state;
  const HomeScreen({super.key, required this.state});

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
                !state.paused &&
                !state.completed &&
                !state.scanning) ...[
              const SizedBox(height: 16),
              _buildScanResult(),
            ],
            if (state.extracting || state.paused) ...[
              const SizedBox(height: 16),
              _buildProgressPanel(),
            ],
            if (state.completed) ...[
              const SizedBox(height: 16),
              _buildCompleteBanner(),
            ],
            const SizedBox(height: 16),
            PrimaryButton(
              label: _primaryLabel,
              icon: state.extracting ? Icons.pause : Icons.play_arrow,
              disabled: _primaryDisabled,
              onPressed: _onStart,
            ),
          ],
        );
      },
    );
  }

  /// 主按钮的文案。四态一目了然：扫描中 / 解压中 / 已暂停 / 待启动。
  String get _primaryLabel {
    if (state.scanning) return '正在扫描...';
    if (state.extracting) return '解压中...';
    if (state.paused) return '继续解压';
    return '开始智能解压';
  }

  /// 运行 / 暂停的状态灯颜色。
  Color get _liveColor =>
      state.paused ? AppTheme.neonOrange : AppTheme.neonGreen;

  /// 扫描中不能重复触发；暂停时反而必须可点（那就是「继续」）。
  bool get _primaryDisabled {
    if (state.scanning) return true;
    if (state.extracting || state.paused) return false;
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
          GestureDetector(
            onTap: () => state.selectFolder(),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: AppTheme.neonCyan.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: AppTheme.neonCyan.withValues(alpha: 0.3),
                ),
              ),
              child: const Text(
                '更换',
                style: TextStyle(fontSize: 12, color: AppTheme.neonCyan),
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
                      color: _liveColor.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.circle, size: 4, color: _liveColor),
                        const SizedBox(width: 4),
                        Text(
                          state.paused ? 'PAUSED' : 'LIVE',
                          style: TextStyle(
                            fontSize: 9,
                            fontFamily: 'monospace',
                            color: _liveColor,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    state.paused ? '已暂停' : '正在解压',
                    style: const TextStyle(
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

  Widget _buildCompleteBanner() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            AppTheme.neonGreen.withValues(alpha: 0.1),
            AppTheme.neonCyan.withValues(alpha: 0.05),
          ],
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppTheme.neonGreen.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: AppTheme.neonGreen.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(
              Icons.check_circle,
              color: AppTheme.neonGreen,
              size: 24,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '全部解压完成',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.neonGreen,
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
    );
  }

  /// 主按钮：同一个按钮在三个状态间切换语义。
  ///
  /// 原来这里是「2/5/8 秒后分别弹出密码、格式、错误三个弹窗」的假触发。
  /// 已删除：真弹窗必须由引擎在**真实事件**上驱动（P3 的 `dialog_bridge`
  /// 通过 `AppNavigator` 弹），而不是由定时器按秒表演一遍。
  void _onStart() {
    if (state.extracting) {
      state.pauseExtract();
    } else if (state.paused) {
      state.resumeExtract();
    } else {
      state.startExtract();
    }
  }
}
