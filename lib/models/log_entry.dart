/// 解压状态
enum LogStatus { success, failed, skipped, partial }

/// 解压日志条目
class LogEntry {
  final String name;
  final LogStatus status;
  final String size;

  /// 给用户看的时间串（`今天 14:32`）。**不是**用来计算的，见 [at]。
  final String time;
  final String duration;
  final List<String> tags;

  /// [time] 的来源时刻。
  ///
  /// 落盘要存的是这个，不是 [time]：`今天 14:32` 只在**写那条日志的当天**
  /// 成立，隔天读回来就又变成「今天」了 —— 一条三天前的失败会显示成今天
  /// 刚发生的，用户会以为刚才解压出了毛病。存 epoch、加载时用 `formatLogTime`
  /// 重新算一遍，才能得到「09-30 20:33」这种正确的样子。
  ///
  /// 可空是为了兼容手写的常量（UI 原型期的 `MockData`、测试夹具），那些条目
  /// 没有来源时刻，[time] 说什么就是什么。
  final DateTime? at;

  const LogEntry({
    required this.name,
    required this.status,
    required this.size,
    required this.time,
    required this.duration,
    this.tags = const [],
    this.at,
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
