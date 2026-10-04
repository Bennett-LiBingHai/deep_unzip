/// 引擎结果 → `LogEntry` 的字段拼装。
///
/// 这些判断原先长在 `AppState` 里，跟通知与批次状态机混着，测不到 ——
/// 而「什么时候算部分成功」「密码错该挂什么 tag」是会写错的那类规则。
library;

import 'package:deep_unzip/engine/log_builder.dart';
import 'package:deep_unzip/engine/models.dart';
import 'package:deep_unzip/engine/protocol.dart';
import 'package:deep_unzip/models/archive_file.dart';
import 'package:deep_unzip/models/log_entry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // 固定一个时刻：日志里的 `time` 是「今天 14:32」那种展示串，用固定值
  // 才能断言，也不必去猜 formatLogTime 的具体格式。
  final now = DateTime(2026, 10, 3, 14, 32);

  /// `isSplit` 的判据是 `split != null`（**不是** `parts.length > 1`），
  /// 所以造分片包必须把 [SplitFamily] 也给上。
  ScanItem item({
    String path = '/sdcard/a.zip',
    int sizeBytes = 2048,
    List<String>? parts,
    Set<ArchiveFlag> flags = const {},
    bool split = false,
  }) {
    final all = parts ?? [path];
    return ScanItem(
      entryPath: path,
      parts: all,
      split: split
          ? SplitFamily(
              kind: SplitKind.rawSplit,
              entryPath: path,
              parts: all,
            )
          : null,
      sizeBytes: sizeBytes,
      sniff: SniffResult.unknown,
      flags: flags,
      depth: 0,
    );
  }

  ScanSummary summary({
    List<ScanItem> items = const [],
    List<String> warnings = const [],
    int containerSkipped = 0,
    int unreadable = 0,
  }) =>
      ScanSummary(
        items: items,
        warnings: warnings,
        containerSkipped: containerSkipped,
        unreadable: unreadable,
      );

  group('scanLogStatus —— 状态推导', () {
    test('扫到东西且无告警 → 成功', () {
      expect(scanLogStatus(summary(items: [item()])), LogStatus.success);
    });

    test('扫到东西但有告警 → 部分成功', () {
      expect(
        scanLogStatus(summary(items: [item()], warnings: ['跳过 1 个目录'])),
        LogStatus.partial,
      );
    });

    test('一个都没扫到且无告警 → 成功（空目录不是失败）', () {
      expect(scanLogStatus(summary()), LogStatus.success);
    });

    test('一个都没扫到但**有**告警 → 失败', () {
      // 目录压根不存在时也是「一个都没找到 + 带告警」。那是彻底失败，
      // 记成「部分成功」会让用户以为解了一半。
      expect(
        scanLogStatus(summary(warnings: ['目录不存在'])),
        LogStatus.failed,
      );
    });
  });

  group('buildScanLog', () {
    test('size 是各包之和，且是预格式化串', () {
      final log = buildScanLog(
        folderName: 'Download',
        summary: summary(items: [item(sizeBytes: 1024), item(sizeBytes: 1024)]),
        elapsed: const Duration(seconds: 3),
        now: now,
      );

      expect(log.name, 'Download（扫描）');
      expect(log.size, '2.0 KB');
      expect(log.status, LogStatus.success);
      expect(log.time, isNotEmpty);
      expect(log.tags, contains('2 个压缩包'));
    });

    test('一个包都没有时 size 记 `-` 而不是 `0 B`', () {
      // `0 B` 会被读成「有个 0 字节的包」。
      final log = buildScanLog(
        folderName: '空目录',
        summary: summary(),
        elapsed: Duration.zero,
        now: now,
      );

      expect(log.size, '-');
    });

    test('容器跳过数与不可读数只在非零时进 tag', () {
      final clean = buildScanLog(
        folderName: 'x',
        summary: summary(items: [item()]),
        elapsed: Duration.zero,
        now: now,
      );
      expect(clean.tags.any((t) => t.contains('容器')), isFalse);
      expect(clean.tags.any((t) => t.contains('不可读')), isFalse);

      final dirty = buildScanLog(
        folderName: 'x',
        summary: summary(items: [item()], containerSkipped: 3, unreadable: 2),
        elapsed: Duration.zero,
        now: now,
      );
      expect(dirty.tags, contains('忽略 3 个容器'));
      expect(dirty.tags, contains('2 个不可读'));
    });

    test('duration 走 formatDuration，不是裸毫秒数', () {
      final log = buildScanLog(
        folderName: 'x',
        summary: summary(items: [item()]),
        elapsed: const Duration(seconds: 3),
        now: now,
      );
      expect(log.duration, '3.0s');
    });
  });

  group('buildScanFailureLog', () {
    test('记成 failed，大小为 `-`，耗时也是 `-`', () {
      final log = buildScanFailureLog(folderName: 'Download', now: now);

      expect(log.name, 'Download');
      expect(log.status, LogStatus.failed);
      expect(log.size, '-');
      expect(log.duration, '-');
      expect(log.tags, ['扫描失败']);
    });
  });

  group('buildExtractLog —— 成功', () {
    test('挂条目数，耗时取 outcome 的', () {
      final log = buildExtractLog(
        item: item(sizeBytes: 4096),
        outcome: const ExtractOutcome(
          outDir: '/sdcard/a',
          entryCount: 12,
          unpackedBytes: 999,
          elapsed: Duration(milliseconds: 2500),
        ),
        now: now,
      );

      expect(log.name, 'a.zip');
      expect(log.status, LogStatus.success);
      expect(log.size, '4.0 KB');
      expect(log.duration, '2.5s');
      expect(log.tags, contains('12 项'));
    });

    test('分片 / 嵌套 / 加密 三个 tag 按 item 的属性出现', () {
      final log = buildExtractLog(
        item: item(
          split: true,
          parts: const ['/sdcard/a.rar.001', '/sdcard/a.rar.002'],
          flags: {ArchiveFlag.nested, ArchiveFlag.encrypted},
        ),
        outcome: const ExtractOutcome(
          outDir: '/sdcard/a',
          entryCount: 1,
          unpackedBytes: 1,
          elapsed: Duration.zero,
        ),
        now: now,
      );

      expect(log.tags, contains('分片 ×2'));
      expect(log.tags, contains('嵌套'));
      expect(log.tags, contains('加密'));
    });

    test('普通单卷包不挂这三个 tag', () {
      final log = buildExtractLog(
        item: item(),
        outcome: const ExtractOutcome(
          outDir: '/sdcard/a',
          entryCount: 1,
          unpackedBytes: 1,
          elapsed: Duration.zero,
        ),
        now: now,
      );

      expect(log.tags, ['1 项']);
    });

    test('伪装后缀的包挂「伪后缀」—— 日志是唯一的留痕', () {
      // 这条**推翻了**原来的断言（原来期望 `['1 项']`，理由是「扫描期的标记，
      // 日志里不重复」）。那个理由不成立：`buildScanLog` 的 tag 只有
      // 「N 个压缩包 / 忽略 N 个容器 / N 个不可读」三个**聚合**数，没有逐文件
      // 的 flag。伪后缀只出现在首页那个列表上，而列表下次扫描就被清掉 ——
      // 解完 `fake.pdf` 再来翻日志，只有一个「1 项」，看不出它被当成什么解了。
      //
      // 而且它不是唯一一个被漏掉的：`ArchiveFlag` 四个值，日志里原来只映射了
      // 三个（分片 / 嵌套 / 加密）。一个枚举映射了三个值，第四个的缺席看不出
      // 是「有意不记」还是「忘了写」—— 事实上就是忘了。
      final log = buildExtractLog(
        item: item(flags: {ArchiveFlag.fakeExtension}),
        outcome: const ExtractOutcome(
          outDir: '/sdcard/a',
          entryCount: 1,
          unpackedBytes: 1,
          elapsed: Duration.zero,
        ),
        now: now,
      );

      expect(log.tags, ['伪后缀', '1 项']);
    });

    test('四个 flag 全挂上时四个 tag 都在，且顺序就是源码里的顺序', () {
      // 上一条只验了「漏掉的那个补上了」。这一条验的是**再也没有第五个能被
      // 漏掉**：`ArchiveFlag` 有几个值，这里就该有几个 tag。
      final log = buildExtractLog(
        item: item(
          flags: {
            ArchiveFlag.nested,
            ArchiveFlag.encrypted,
            ArchiveFlag.fakeExtension,
          },
          // 「分片 ×N」读的是 `item.isSplit`（即 `split != null`），
          // **不是** `flags` 里那个同名 flag —— 只挂 flag 不会让这一项出现。
          split: true,
          parts: const ['/sdcard/a.zip.001', '/sdcard/a.zip.002'],
        ),
        outcome: const ExtractOutcome(
          outDir: '/sdcard/a',
          entryCount: 3,
          unpackedBytes: 3,
          elapsed: Duration.zero,
        ),
        now: now,
      );

      expect(log.tags, ['分片 ×2', '嵌套', '加密', '伪后缀', '3 项']);
    });
  });

  group('buildExtractLog —— 失败', () {
    test('密码错 → 「密码未匹配」，耗时记 `-`', () {
      final log = buildExtractLog(
        item: item(),
        error: const EngineException('需要密码', code: DuzErrorCode.password),
        now: now,
      );

      expect(log.status, LogStatus.failed);
      expect(log.duration, '-');
      expect(log.tags, ['密码未匹配']);
    });

    test('其它原生错误 → 「解压失败」', () {
      final log = buildExtractLog(
        item: item(),
        error: const EngineException('文件损坏', code: DuzErrorCode.extract),
        now: now,
      );

      expect(log.tags, ['解压失败']);
    });

    test('没有错误码的非原生失败也记「解压失败」，不崩', () {
      // code 为 null 时若去读 `error.code == password` 之外的分支没问题，
      // 但实现里用的是裸 `error!` —— 这条用例守住那条路径。
      final log = buildExtractLog(
        item: item(),
        error: const EngineException('协议出错'),
        now: now,
      );

      expect(log.tags, ['解压失败']);
    });

    test('失败时 size 仍记压缩包大小（那是用户能对上号的数字）', () {
      final log = buildExtractLog(
        item: item(sizeBytes: 1536),
        error: const EngineException('坏了', code: DuzErrorCode.open),
        now: now,
      );

      expect(log.size, '1.5 KB');
    });
  });

  group('buildExtractLog —— 参数约束', () {
    test('outcome 与 error 必须恰好给一个', () {
      expect(
        () => buildExtractLog(item: item(), now: now),
        throwsA(isA<AssertionError>()),
        reason: '两个都不给 = 不知道成功还是失败',
      );
      expect(
        () => buildExtractLog(
          item: item(),
          outcome: const ExtractOutcome(
            outDir: '/x',
            entryCount: 0,
            unpackedBytes: 0,
            elapsed: Duration.zero,
          ),
          error: const EngineException('又成功又失败'),
          now: now,
        ),
        throwsA(isA<AssertionError>()),
      );
    });
  });
}
