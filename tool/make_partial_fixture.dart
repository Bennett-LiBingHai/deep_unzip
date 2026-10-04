/// 生成一个**能产出「部分成功」日志**的夹具目录。
///
/// ## 为什么需要它
///
/// 「部分成功」（`LogStatus.partial`）是日志页五个筛选里最不容易撞上的一个。
/// 它只从 [`scanLogStatus`] 一处产出，判据是「扫到了东西 **且** 有告警」；
/// 而告警只从几个很窄的口子漏出来。拿几个正常的 zip 去扫，永远是「成功」
/// —— 于是那个筛选按钮点进去永远空空如也，看着像坏的。
///
/// 这个夹具把那个状态**稳定地造出来**：
///
/// | 文件 | 作用 |
/// |---|---|
/// | `good.zip` | 保证「扫到了东西」这半边成立 |
/// | `bad.zip.001` / `bad.zip.003` | 缺了第 2 卷 → 分片连续性报一条告警 |
///
/// 两样缺一不可。只有坏分片的话一个包都扫不出来，那会记成**失败**而不是
/// 部分成功（见 `log_builder.dart` 里那段「先看有没有东西被扫出来」）。
///
/// 首片照常以 `PK\x03\x04` 开头，免得被首卷魔数校验提前踢掉、告警换成另一条。
///
/// ## 自检
///
/// 生成完**当场扫一遍**，把真实的结果打出来，而不是只写文件了事。理由和
/// `make_fixtures.dart` 一样：夹具最坏的失败方式不是「没生成」，是「生成了
/// 但撞不上」—— 那样用户照文档操作一遍，什么都没看到，还以为功能坏了。
/// 这里直接调真的 `scanDirectory` + `scanLogStatus`，判据不是另写一套。
///
/// 用法：
/// ```
/// dart run tool/make_partial_fixture.dart            # build/fixtures_partial
/// dart run tool/make_partial_fixture.dart <输出目录>
/// ```
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:deep_unzip/engine/log_builder.dart';
import 'package:deep_unzip/engine/scanner.dart';
import 'package:deep_unzip/models/log_entry.dart';
import 'package:path/path.dart' as p;

void main(List<String> args) async {
  final root = args.isNotEmpty ? args[0] : p.join('build', 'fixtures_partial');
  final dir = Directory(root);
  if (dir.existsSync()) dir.deleteSync(recursive: true);
  dir.createSync(recursive: true);

  _write(p.join(root, 'good.zip'), _zip({'hello.txt': '你好，这个包是好的'}));

  // 切成三片，只落第 1、3 片。
  final src = Uint8List.fromList(_zip({'x': 'y' * 5000}));
  const pieces = 3;
  final len = (src.length / pieces).ceil();
  for (final i in [0, 2]) {
    final from = i * len;
    final to = (from + len).clamp(0, src.length);
    _write(
      p.join(root, 'bad.zip.${(i + 1).toString().padLeft(3, '0')}'),
      Uint8List.sublistView(src, from, to),
    );
  }

  stdout.writeln('夹具已写到 ${dir.absolute.path}:');
  for (final f in dir.listSync().whereType<File>()) {
    stdout.writeln('  ${p.basename(f.path)}  (${f.lengthSync()} B)');
  }

  // ---------------------------------------------------------------------
  // 自检：当场扫一遍，确认它真的产出「部分成功」
  // ---------------------------------------------------------------------
  final summary = await scanDirectory(dir.absolute.path);
  final status = scanLogStatus(summary);

  stdout.writeln('');
  stdout.writeln('当场扫一遍的结果：');
  stdout.writeln('  扫出条目  ${summary.items.length} 个'
      '（${summary.items.map((i) => i.fileName).join("、")}）');
  stdout.writeln('  告警      ${summary.warnings.length} 条');
  for (final w in summary.warnings) {
    stdout.writeln('            · $w');
  }
  stdout.writeln('  记成      ${status.name}');

  if (summary.items.isEmpty) {
    throw StateError('一个包都没扫出来 —— 按判据这会记成失败而不是部分成功，'
        '夹具没造对（good.zip 是不是没写进去？）');
  }
  if (summary.warnings.isEmpty) {
    throw StateError('一条告警都没有 —— 那会记成成功，撞不到「部分成功」。'
        '检查 bad.zip.001/.003 的切分与命名。');
  }
  if (status != LogStatus.partial) {
    throw StateError('扫出来是 ${status.name}，不是 partial —— 夹具没用。');
  }

  stdout.writeln('');
  stdout.writeln('日志页上会多出这样一条（点「部分」筛选就能看到）：');
  final now = DateTime(2026, 1, 1);
  final entry = buildScanLog(
    folderName: p.basename(dir.absolute.path),
    summary: summary,
    elapsed: Duration.zero,
    now: now,
  );
  stdout.writeln('  标题  ${entry.name}');
  stdout.writeln('  状态  ${entry.statusLabel}');
  stdout.writeln('  标签  ${entry.tags.join("  ")}');
}

List<int> _zip(Map<String, String> entries) {
  final archive = Archive();
  entries.forEach((name, content) {
    // 字符串一律走 utf8，不能用 `codeUnits` —— 理由见 `make_fixtures.dart`
    // 里那处长注释（汉字被砍成单字节垃圾，会让校验判据永远比不中）。
    final bytes = Uint8List.fromList(utf8.encode(content));
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  return ZipEncoder().encode(archive, level: DeflateLevel.bestCompression);
}

void _write(String path, List<int> bytes) {
  final f = File(path);
  f.parent.createSync(recursive: true);
  f.writeAsBytesSync(bytes);
}
