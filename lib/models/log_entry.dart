/// 解压状态
enum LogStatus { success, failed, skipped, partial }

/// 解压日志条目
class LogEntry {
  final String name;
  final LogStatus status;
  final String size;
  final String time;
  final String duration;
  final List<String> tags;

  const LogEntry({
    required this.name,
    required this.status,
    required this.size,
    required this.time,
    required this.duration,
    this.tags = const [],
  });

  String get statusLabel {
    switch (status) {
      case LogStatus.success:
        return '成功';
      case LogStatus.failed:
        return '失败';
      case LogStatus.skipped:
        return '跳过';
      case LogStatus.partial:
        return '部分成功';
    }
  }
}
