import 'dart:io';
import 'dart:typed_data';

import 'package:deep_unzip/engine/log_builder.dart';
import 'package:deep_unzip/engine/scanner.dart';
import 'package:deep_unzip/models/log_entry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'zip_fixtures.dart';

/// 「部分成功」这条日志怎么才会出现 —— 钉住它，别让它变成永远见不到的状态。
///
/// ## 只有扫描会产生 partial，解压不会
///
/// `buildExtractLog` 的状态是个三选一（成功/失败/跳过），**没有** partial 这一档：
/// 一个包要么解开了、要么没解开。所以「部分成功」只可能来自 [`scanLogStatus`]，
/// 判据是「扫到了东西 **且** 有告警」。
///
/// 两个条件缺一不可，而且顺序不能反。先看有没有扫到东西：目录不存在时也是
/// 一条没扫到 + 带告警，那是彻底失败，记成 partial 就撒谎了（见 `log_builder.dart`
/// 那段注释）。
///
/// ## 为什么要专门造一个夹具
///
/// 这个状态**很容易变成永远见不到的**：告警只从几个很窄的口子漏出来（分片不连续、
/// 目录读不了、层级太深）。日常拿几个正常的 zip 去扫，永远是「成功」—— 于是
/// 用户在日志页看到一个「部分」筛选按钮，点进去永远空空如也，还以为是坏的。
/// 这条用例把「怎么让它出现」写死，将来谁改窄了告警的口子，这里会红。
void main() {
  late Directory root;

  setUp(() => root = makeTempDir('partial_log'));
  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  /// 把一个 zip 切成三片，只落地第 1、3 片 —— 中间缺一卷。
  ///
  /// 缺的那卷正是[分片连续性]要报的事，也就是我们要的那条告警。首片照常以
  /// `PK\x03\x04` 开头，免得被[首卷魔数校验]提前踢掉、变成另一条告警。
  void writeSplitWithGap(String stem) {
    final src = realZip({'x': 'y' * 5000});
    const pieces = 3;
    final len = (src.length / pieces).ceil();
    for (final i in [0, 2]) {
      final from = i * len;
      final to = (from + len).clamp(0, src.length);
      writeTempFile(
        root,
        '$stem.${(i + 1).toString().padLeft(3, '0')}',
        Uint8List.sublistView(src, from, to),
      );
    }
  }

  test('分片缺一卷 → 扫出了包、也带着告警 → 记成「部分成功」', () async {
    // 一个正常的包，保证 items 非空 —— 否则按 `scanLogStatus` 的判据会记成
    // 「失败」，这条用例就验不到 partial 了。
    writeTempFile(root, 'good.zip', realZip({'hello.txt': '你好'}));
    writeSplitWithGap('bad.zip');

    final summary = await scanDirectory(root.path);

    expect(summary.items, isNotEmpty, reason: '前提：确实扫出了东西');
    expect(summary.warnings, isNotEmpty, reason: '前提：确实有告警');
    expect(
      scanLogStatus(summary),
      LogStatus.partial,
      reason: '扫到东西 + 有告警 = 部分成功',
    );
    // 告警得说得出是哪一组分片出的问题。只说「有告警」而不说是谁，用户拿着
    // 一条「部分成功」也不知道该去看哪个包。
    expect(summary.warnings.join('\n'), contains('bad.zip'),
        reason: '告警要指名道姓，否则用户没法定位');
  });

  test('只有包、没有告警 → 记成「成功」', () async {
    // 反方向。少了这条，一个「恒返回 partial」的实现也能让上面那条变绿。
    writeTempFile(root, 'good.zip', realZip({'hello.txt': '你好'}));

    final summary = await scanDirectory(root.path);

    expect(summary.items, isNotEmpty);
    expect(summary.warnings, isEmpty, reason: '这条夹具不该带告警');
    expect(scanLogStatus(summary), LogStatus.success);
  });

  test('一个包都没扫到 + 有告警 → 记成「失败」，不是「部分成功」', () async {
    // 判据的边界。目录不存在时也是「没扫到 + 带告警」，但那不是部分成功 ——
    // 那是整个没跑起来。两条路都产出 warnings，分岔只在 items 空不空。
    final summary = await scanDirectory(p.join(root.path, '不存在的目录'));

    expect(summary.items, isEmpty);
    expect(summary.warnings, isNotEmpty);
    expect(scanLogStatus(summary), LogStatus.failed);
  });
}
