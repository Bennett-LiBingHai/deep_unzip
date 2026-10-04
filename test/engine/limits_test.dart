/// 炸弹防护阈值。
///
/// 闸门本身住在 `native_backend.extractArchive` 里（要真归档才能跑），
/// 所以**这一层是它能被测到的全部**：判定逻辑被刻意抽成了纯函数，
/// 这里喂数字进来。
///
/// 边界用例是重点：阈值这种东西「刚好等于上限」和「超一点」的行为完全相反，
/// 而实现里写 `>` 还是 `>=` 是同一行代码的差别。
library;

import 'package:deep_unzip/engine/limits.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const gib = 1 << 30;

  /// 一个「什么都不超」的底子，各用例只改自己关心的那一项。
  ArchiveProfile profile({
    int entryCount = 10,
    int unpackedBytes = 1024,
    int largestEntryBytes = 512,
    int compressedBytes = 1024,
  }) {
    return ArchiveProfile(
      entryCount: entryCount,
      unpackedBytes: unpackedBytes,
      largestEntryBytes: largestEntryBytes,
      compressedBytes: compressedBytes,
    );
  }

  group('放行', () {
    test('一切正常时不拦', () {
      expect(checkArchiveLimits(profile()), isNull);
    });

    test('刚好等于上限也放行 —— 上限是「允许到这么多」', () {
      const limits = LimitThresholds();
      expect(
        checkArchiveLimits(
          profile(
            entryCount: limits.maxEntries,
            largestEntryBytes: limits.maxEntryBytes,
            unpackedBytes: limits.maxTotalBytes,
            compressedBytes: limits.maxTotalBytes, // 比值 1:1，不触发
          ),
          limits: limits,
        ),
        isNull,
      );
    });
  });

  group('条目数', () {
    test('超一个就拦', () {
      const limits = LimitThresholds(maxEntries: 100);
      final breach = checkArchiveLimits(
        profile(entryCount: 101),
        limits: limits,
      );

      expect(breach, isNotNull);
      expect(breach!.kind, LimitKind.entryCount);
      expect(breach.tag, '炸弹防护');
      // 两头的数字都要在文案里，否则用户不知道「超了多少」
      expect(breach.message, contains('101'));
      expect(breach.message, contains('100'));
    });
  });

  group('单文件', () {
    test('超一个字节就拦', () {
      const limits = LimitThresholds(maxEntryBytes: 1024);
      final breach = checkArchiveLimits(
        profile(largestEntryBytes: 1025, unpackedBytes: 1025),
        limits: limits,
      );

      expect(breach!.kind, LimitKind.entrySize);
      // 这个数必须是**单条**的，总量小也一样拦：单条炸弹正是靠总量看不出来
      expect(breach.message, contains('1.0 KB'));
    });

    test('总量很大但单条都不大 → 不触发这一条', () {
      const limits = LimitThresholds(maxEntryBytes: 1024, maxTotalBytes: 1 << 40);
      expect(
        checkArchiveLimits(
          profile(
            entryCount: 5000,
            largestEntryBytes: 1024,
            unpackedBytes: 5000 * 1024,
            compressedBytes: 5000 * 1024,
          ),
          limits: limits,
        ),
        isNull,
      );
    });
  });

  group('总量', () {
    test('超过上限就拦', () {
      const limits = LimitThresholds(maxTotalBytes: gib);
      final breach = checkArchiveLimits(
        profile(unpackedBytes: gib + 1, largestEntryBytes: 1, compressedBytes: gib),
        limits: limits,
      );

      expect(breach!.kind, LimitKind.totalSize);
    });
  });

  group('压缩比', () {
    // 比值检查排在最后，所以上面几条都得先不触发 —— 下面这些用例把
    // 单体与总量都给足，专测比值那一条。

    test('又大又空 → 拦', () {
      final breach = checkArchiveLimits(profile(
        entryCount: 1,
        largestEntryBytes: 4 * gib,
        unpackedBytes: 4 * gib,
        compressedBytes: 4 * 1024 * 1024, // 4 MiB → 1024:1
      ));

      expect(breach!.kind, LimitKind.ratio);
      expect(breach.message, contains('1,024:1'));
    });

    test('小文件的高比值不拦 —— 地板以下看不到比值', () {
      // 1000:1 但只有 100 MB。写出来也就 100 MB，不是威胁，
      // 而这类「小且重复」的文件在真实数据里并不罕见。
      expect(
        checkArchiveLimits(profile(
          unpackedBytes: 100 * 1024 * 1024,
          largestEntryBytes: 100 * 1024 * 1024,
          compressedBytes: 100 * 1024,
        )),
        isNull,
      );
    });

    test('地板本身（1 GiB）以上立刻恢复检查', () {
      final breach = checkArchiveLimits(profile(
        unpackedBytes: gib + 1,
        largestEntryBytes: gib + 1,
        compressedBytes: 1024 * 1024, // ≈1025:1
      ));

      expect(breach!.kind, LimitKind.ratio);
    });

    test('量不到磁盘占用（0）时整条跳过，不瞎判', () {
      expect(
        checkArchiveLimits(profile(
          unpackedBytes: 4 * gib,
          largestEntryBytes: 4 * gib,
          compressedBytes: 0,
        )),
        isNull,
      );
    });
  });

  group('顺序：先拦的必须是更确定的那条', () {
    test('条目数与比值同时超 → 报条目数', () {
      final breach = checkArchiveLimits(
        profile(
          entryCount: 999999,
          unpackedBytes: 8 * gib,
          largestEntryBytes: 1024,
          compressedBytes: 1024 * 1024,
        ),
        limits: const LimitThresholds(maxEntries: 100),
      );

      expect(breach!.kind, LimitKind.entryCount);
    });

    test('单条与总量同时超 → 报单条（更具体的那个）', () {
      final breach = checkArchiveLimits(
        profile(
          unpackedBytes: 100 * gib,
          largestEntryBytes: 100 * gib,
          compressedBytes: 100 * gib,
        ),
        limits: const LimitThresholds(maxTotalBytes: gib),
      );

      expect(breach!.kind, LimitKind.entrySize);
    });
  });

  group('ArchiveProfile.fromEntries', () {
    test('目录不计入大小，但要计入条目数', () {
      final p = ArchiveProfile.fromEntries(entries: const [
        (size: 0, isDir: true),
        (size: 100, isDir: false),
        (size: 300, isDir: false),
      ]);

      expect(p.entryCount, 3, reason: '目录也是中央目录里的条目，防洪要数它');
      expect(p.unpackedBytes, 400);
      expect(p.largestEntryBytes, 300);
    });

    test('空归档', () {
      final p = ArchiveProfile.fromEntries(entries: const []);
      expect(p.entryCount, 0);
      expect(p.unpackedBytes, 0);
      expect(p.largestEntryBytes, 0);
    });

    test('磁盘占用原样带过来', () {
      final p = ArchiveProfile.fromEntries(
        entries: const [(size: 1, isDir: false)],
        compressedBytes: 4096,
      );
      expect(p.compressedBytes, 4096);
    });

    test('目录的 size 不参与最大值的比较', () {
      // 有些打包器会给目录条目写个非零的 size。它不该被当成「单文件炸弹」。
      final p = ArchiveProfile.fromEntries(entries: const [
        (size: 999999999, isDir: true),
        (size: 10, isDir: false),
      ]);
      expect(p.largestEntryBytes, 10);
    });
  });

  group('档位', () {
    test('三档的松紧是单调的', () {
      // 这条防的是「改了某一档的数却改反了方向」——比如把 strict 的
      // 上限调得比 standard 还宽。用户按名字选的档，名字必须算数。
      expect(LimitThresholds.loose.maxEntries,
          greaterThan(LimitThresholds.standard.maxEntries));
      expect(LimitThresholds.standard.maxEntries,
          greaterThan(LimitThresholds.strict.maxEntries));

      expect(LimitThresholds.loose.maxTotalBytes,
          greaterThan(LimitThresholds.standard.maxTotalBytes));
      expect(LimitThresholds.standard.maxTotalBytes,
          greaterThan(LimitThresholds.strict.maxTotalBytes));

      expect(LimitThresholds.loose.maxRatio,
          greaterThan(LimitThresholds.standard.maxRatio));
      expect(LimitThresholds.standard.maxRatio,
          greaterThan(LimitThresholds.strict.maxRatio));
    });

    test('严格档真的更严：标准放行的量在严格档被拦', () {
      final p = profile(
        unpackedBytes: 16 * gib,
        largestEntryBytes: 2 * gib,
        compressedBytes: 16 * gib,
      );

      expect(checkArchiveLimits(p, limits: LimitThresholds.standard), isNull);
      expect(checkArchiveLimits(p, limits: LimitThresholds.strict), isNotNull);
    });

    test('kLimitPresets 与三档一致，顺序即点击顺序', () {
      expect(kLimitPresets.map((p) => p.label).toList(), ['宽松', '标准', '严格']);
      expect(kLimitPresets[0].thresholds, LimitThresholds.loose);
      expect(kLimitPresets[1].thresholds, LimitThresholds.standard);
      expect(kLimitPresets[2].thresholds, LimitThresholds.strict);
    });
  });

  group('值语义', () {
    test('相等的两套认作同一个对象 —— chip 靠它判断当前是哪档', () {
      expect(const LimitThresholds(), LimitThresholds.standard);
      expect(const LimitThresholds().hashCode, LimitThresholds.standard.hashCode);
      expect(const LimitThresholds(), isNot(LimitThresholds.strict));
    });

    test('copyWith 只改点名的那一项', () {
      final t = LimitThresholds.standard.copyWith(maxRatio: 42);
      expect(t.maxRatio, 42);
      expect(t.maxEntries, LimitThresholds.standard.maxEntries);
      expect(t.maxTotalBytes, LimitThresholds.standard.maxTotalBytes);
      expect(t, isNot(LimitThresholds.standard));
    });

    test('toString 里的数字是给人看的形态', () {
      expect(LimitThresholds.standard.toString(), contains('200,000'));
      expect(LimitThresholds.standard.toString(), contains('64 GB'));
    });
  });

  group('LimitField', () {
    test('四个字段各读各写，互不串门', () {
      const base = LimitThresholds.standard;
      expect(LimitField.entries.apply(base, 7).maxEntries, 7);
      expect(LimitField.entryBytes.apply(base, 7).maxEntryBytes, 7);
      expect(LimitField.totalBytes.apply(base, 7).maxTotalBytes, 7);
      expect(LimitField.ratio.apply(base, 7).maxRatio, 7);

      // 改一项不该动到别的
      expect(LimitField.entries.apply(base, 7).maxTotalBytes, base.maxTotalBytes);
    });

    test('read 与 apply 互为逆', () {
      for (final f in LimitField.values) {
        expect(f.read(f.apply(LimitThresholds.standard, 123)), 123);
      }
    });

    test('只有字节量那两项按字节展示', () {
      expect(LimitField.entries.isBytes, isFalse);
      expect(LimitField.ratio.isBytes, isFalse);
      expect(LimitField.entryBytes.isBytes, isTrue);
      expect(LimitField.totalBytes.isBytes, isTrue);

      expect(LimitField.entryBytes.display(LimitThresholds.standard), '8.0 GB');
      expect(LimitField.entries.display(LimitThresholds.standard), '200,000');
    });
  });
}
