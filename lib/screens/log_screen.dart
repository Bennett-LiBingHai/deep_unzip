import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../providers/app_state.dart';
import '../models/log_entry.dart';
import '../widgets/glass_card.dart';
import '../widgets/modals/clear_logs_modal.dart';

/// 解压日志页面
class LogScreen extends StatelessWidget {
  final AppState state;
  const LogScreen({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        // 筛选结果算一次给头部、列表、空态三处共用：`filteredLogs` 每次调用都
        // 过滤一遍并新开一张表，一帧里算三回不值当。
        final filtered = state.filteredLogs;
        return ListView(
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 100),
          children: [
            _buildHeader(context, filtered.length),
            const SizedBox(height: 16),
            _buildFilters(),
            const SizedBox(height: 16),
            ...filtered.map(
              (l) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _logItem(l),
              ),
            ),
            if (filtered.isEmpty) _buildEmpty(),
          ],
        );
      },
    );
  }

  Widget _buildHeader(BuildContext context, int shown) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            ShaderMask(
              shaderCallback: (bounds) =>
                  AppTheme.primaryGradient.createShader(bounds),
              child: const Text(
                '解压日志',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
            ),
            const SizedBox(width: 10),
            _countChip(shown),
            const Spacer(),
            _clearButton(context),
          ],
        ),
        const SizedBox(height: 4),
        const Text(
          'EXTRACTION HISTORY · 可追溯每一次操作',
          style: TextStyle(
            fontSize: 12,
            color: AppTheme.textDim,
            fontFamily: 'monospace',
          ),
        ),
      ],
    );
  }

  /// 视图是不是被筛选切窄了。
  ///
  /// 两个条件缺一不可：没筛不算；**筛了但一条记录都没有**也不算 —— 那时
  /// 「筛出 0 / 共 0 条」是白添一层，而「暂无记录」和它是同一个意思。头部计数
  /// 与空态文案共用这一个判断，免得两处各写各的、哪天走岔了。
  bool get _narrowedByFilter => state.logFilter != null && state.logCount > 0;

  /// 当前日志条数。摆在标题后面而不是塞进副标题 —— 副标题那串英文已经够长，
  /// 再往后接一个数会读成句子的一部分，跟标题并排才一眼看得出「这是个计数」。
  ///
  /// 筛选中时给的是「筛出 X / 共 Y」两个数：只报当前筛出来那几条，用户会以为
  /// 被筛掉的那些**没了**，而上面那颗清空按钮删的偏偏是全部。
  Widget _countChip(int shown) {
    final total = state.logCount;
    final label =
        _narrowedByFilter ? '筛出 $shown / 共 $total 条' : '共 $total 条';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: AppTheme.neonCyan.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppTheme.neonCyan.withValues(alpha: 0.15)),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 11,
          fontFamily: 'monospace',
          color: AppTheme.neonCyan,
        ),
      ),
    );
  }

  /// 清空。**一条都没有的时候是死的，且看起来就是死的** —— 接了点击却什么都
  /// 不发生比不接更让人困惑，所以干脆连手势都不接，用颜色说明它没事可做。
  Widget _clearButton(BuildContext context) {
    final idle = state.logCount == 0;
    final color = idle ? AppTheme.textDim : AppTheme.neonRed;
    return GestureDetector(
      onTap: idle ? null : () => _confirmClear(context),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
        decoration: BoxDecoration(
          color: color.withValues(alpha: idle ? 0.04 : 0.08),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withValues(alpha: idle ? 0.12 : 0.25)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.delete_outline, size: 13, color: color),
            const SizedBox(width: 5),
            Text(
              '清空',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                fontFamily: 'monospace',
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 弹确认再删。删的是全部 —— 即便此刻屏幕上是筛过的视图，弹窗里也把确切
  /// 条数报出来（见 [ClearLogsModal.count]）。
  Future<void> _confirmClear(BuildContext context) async {
    final ok = await ClearLogsModal.show(
      context: context,
      count: state.logCount,
    );
    if (ok) state.clearLogs();
  }

  /// 空态分两种。**这个区分是加了计数之后才必须的**：头部写着「共 128 条」，
  /// 底下却来一句「暂无记录」，看起来就像日志被谁弄丢了。
  Widget _buildEmpty() {
    final filtering = _narrowedByFilter;
    return Padding(
      padding: const EdgeInsets.only(top: 40),
      child: Center(
        child: Column(
          children: [
            const Icon(Icons.inbox_outlined, size: 48, color: AppTheme.textDim),
            const SizedBox(height: 12),
            Text(
              filtering ? '这个分类下没有记录' : '暂无记录',
              style: const TextStyle(
                fontSize: 14,
                color: AppTheme.textSecondary,
              ),
            ),
            if (filtering) ...[
              const SizedBox(height: 6),
              const Text(
                '切到「全部」看其他分类',
                style: TextStyle(
                  fontSize: 11,
                  color: AppTheme.textDim,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildFilters() {
    final filters = <String, LogStatus?>{
      '全部': null,
      '成功': LogStatus.success,
      '失败': LogStatus.failed,
      '跳过': LogStatus.skipped,
      '部分': LogStatus.partial,
    };
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: filters.entries.map((e) {
          final active = state.logFilter == e.value;
          return GestureDetector(
            onTap: () => state.setLogFilter(e.value),
            child: Container(
              margin: const EdgeInsets.only(right: 8),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              decoration: BoxDecoration(
                color: active
                    ? AppTheme.neonCyan.withValues(alpha: 0.1)
                    : Colors.white.withValues(alpha: 0.04),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: active
                      ? AppTheme.neonCyan.withValues(alpha: 0.3)
                      : Colors.white.withValues(alpha: 0.08),
                ),
              ),
              child: Text(
                e.key,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  fontFamily: 'monospace',
                  color: active ? AppTheme.neonCyan : AppTheme.textSecondary,
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _logItem(LogEntry log) {
    final statusColors = {
      LogStatus.success: AppTheme.neonGreen,
      LogStatus.failed: AppTheme.neonRed,
      LogStatus.skipped: AppTheme.neonOrange,
      LogStatus.partial: AppTheme.neonPurple,
    };
    final color = statusColors[log.status]!;

    return GlassCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  log.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.textPrimary,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: color.withValues(alpha: 0.2)),
                ),
                child: Text(
                  log.statusLabel,
                  style: TextStyle(
                    fontSize: 9,
                    fontFamily: 'monospace',
                    color: color,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text(
                log.size,
                style: const TextStyle(
                  fontSize: 11,
                  fontFamily: 'monospace',
                  color: AppTheme.textDim,
                ),
              ),
              const SizedBox(width: 12),
              Text(
                log.time,
                style: const TextStyle(
                  fontSize: 11,
                  fontFamily: 'monospace',
                  color: AppTheme.textDim,
                ),
              ),
              const SizedBox(width: 12),
              Text(
                '耗时 ${log.duration}',
                style: const TextStyle(
                  fontSize: 11,
                  fontFamily: 'monospace',
                  color: AppTheme.textDim,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: log.tags
                .map(
                  (t) => Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.04),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      t,
                      style: const TextStyle(
                        fontSize: 9,
                        fontFamily: 'monospace',
                        color: AppTheme.textSecondary,
                      ),
                    ),
                  ),
                )
                .toList(),
          ),
        ],
      ),
    );
  }
}
