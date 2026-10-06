/// 在**宿主机**上把一次扫描的结果打出来，验完再上真机。
///
/// ## 为什么值得有这么个东西
///
/// 扫描器、嗅探器、分卷识别全是纯 Dart（`engine/` 里除 `backends/` 外不准
/// import flutter），所以它们在本机就能跑 —— 而真机那一轮是最贵的一次验证
/// （要装包、要点 UI、还要占着用户的手机）。凡是本机能定死的，就别留到真机。
///
/// 本机定不死的是**要引擎的那部分**：7z / RAR 的加密位只能真开一次归档才问
/// 得出来（见 `native_backend.dart` 的 `probeEncrypted`），Windows 上没有
/// `libdeep_unzip_engine.so`。所以本工具**不注入探针** —— ZIP 的加密位是嗅探
/// 侧白捡的，照样看得见；7z / RAR 在这一趟里就只会是「不知道」。
///
/// 用法：
///
///     dart run tool/scan_probe.dart build/devfix/enc
library;

import 'dart:io';

import 'package:deep_unzip/engine/scanner.dart';
import 'package:deep_unzip/models/archive_file.dart' show ArchiveFlag;

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('用法：dart run tool/scan_probe.dart <目录>');
    exit(2);
  }

  final root = args.first;
  if (!Directory(root).existsSync()) {
    stderr.writeln('目录不存在：$root');
    exit(2);
  }

  final summary = await scanDirectory(
    root,
    onTick: (t) => stdout.write('\r  扫描中… ${t.files} 个文件'),
  );
  stdout.write('\r${' ' * 40}\r');

  for (final item in summary.items) {
    final flags = item.flags.isEmpty
        ? '-'
        : (item.flags.map((f) => f.name).toList()..sort()).join(',');
    stdout.writeln(
      '${item.fileName}\n'
      '    格式 ${item.sniff.format.name}  置信度 ${item.sniff.confidence.name}\n'
      '    加密 ${_tri(item.sniff.encrypted)}  角标 $flags\n'
      '    卷数 ${item.parts.length}  深度 ${item.depth}  ${item.sizeBytes} B',
    );
  }

  final encrypted =
      summary.items.where((i) => i.flags.contains(ArchiveFlag.encrypted)).length;
  stdout.writeln('----');
  stdout.writeln('条目 ${summary.items.length}，其中带「加密」角标 $encrypted 个');
  stdout.writeln('容器跳过 ${summary.containerSkipped}，读不到 ${summary.unreadable}');
  for (final w in summary.warnings) {
    stdout.writeln('警告：$w');
  }
}

/// 三态如实显示 —— 把「不知道」写成「否」正是首页那个计数会撒谎的原因。
String _tri(bool? v) => switch (v) { true => '要', false => '不要', null => '不知道' };
