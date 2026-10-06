import 'package:deep_unzip/engine/models.dart';
import 'package:deep_unzip/models/archive_file.dart';
import 'package:flutter_test/flutter_test.dart';

/// 列表里那一小块类型角标写的是什么字。
///
/// 这几条断言的存在理由都很具体：
///
/// - 「7Z」拼不出来。Dart 的枚举常量名是标识符，不能以数字开头，`7z` 是语法
///   错误，`_7z` 又会变成本库私有 —— 所以显示名只能挂在 `ArchiveType.label`
///   上。谁要是哪天把 `typeLabel` 改回 `name.toUpperCase()`，第七个用例会挂。
/// - 压缩流曾经全塌成 TAR。`SniffFormat` 到 `ArchiveType` 是多对一的，
///   2026-10 之前 gzip/bzip2/xz/zstd 四个都映射到 `ArchiveType.tar`，列表上
///   一律显示「TAR」，跟真实格式对不上。最后一个用例防它再塌回去。
void main() {
  group('ArchiveType.label', () {
    test('7-Zip 显示成 7Z，不是 SEVENZ', () {
      expect(ArchiveType.sevenz.label, '7Z');
      // 反面：`name.toUpperCase()` 会拼出这个，正是要避免的。
      expect(ArchiveType.sevenz.name.toUpperCase(), 'SEVENZ');
    });

    test('每种类型都有自己的显示名，没有空串', () {
      for (final t in ArchiveType.values) {
        expect(t.label, isNotEmpty, reason: '$t 没有显示名，角标会是一块空白');
        expect(t.label, t.label.toUpperCase(), reason: '角标统一大写');
      }
    });

    test('ArchiveFile.typeLabel 就是 type.label 的透传', () {
      const f = ArchiveFile(name: 'a.7z', type: ArchiveType.sevenz, size: '1 MB');
      expect(f.typeLabel, '7Z');
    });
  });

  group('SniffFormat → ArchiveType 的映射', () {
    test('四种压缩流各显示各的，不再塌成 TAR', () {
      expect(SniffFormat.gzip.archiveType, ArchiveType.gzip);
      expect(SniffFormat.bzip2.archiveType, ArchiveType.bzip2);
      expect(SniffFormat.xz.archiveType, ArchiveType.xz);
      expect(SniffFormat.zstd.archiveType, ArchiveType.zstd);

      expect(SniffFormat.gzip.archiveType.label, 'GZIP');
      expect(SniffFormat.bzip2.archiveType.label, 'BZIP2');
      expect(SniffFormat.xz.archiveType.label, 'XZ');
      expect(SniffFormat.zstd.archiveType.label, 'ZSTD');
    });

    test('rar4/rar5 仍是同一个 RAR —— 这一处多对一是故意的', () {
      expect(SniffFormat.rar4.archiveType, ArchiveType.rar);
      expect(SniffFormat.rar5.archiveType, ArchiveType.rar);
    });

    test('认得出但没有专属类型的，归 other —— 不借用邻居，也不冒充 unknown', () {
      // 从前 cab/lzh/arj/cpio 落在 `unknown` 上，列表里于是显示一块红色的
      // 「UNKNOWN」—— 把已经识别出来的格式说成不认识。
      for (final f in [
        SniffFormat.cab,
        SniffFormat.lzh,
        SniffFormat.arj,
        SniffFormat.cpio,
        SniffFormat.iso,
        SniffFormat.wim,
        SniffFormat.dmg,
        SniffFormat.rpm,
        SniffFormat.vhdx,
      ]) {
        expect(f.archiveType, ArchiveType.other, reason: '$f');
      }
    });

    test('`unknown` 只留给真正认不出的那一个', () {
      final onUnknown = SniffFormat.values
          .where((f) => f.archiveType == ArchiveType.unknown)
          .toList();
      expect(onUnknown, [SniffFormat.unknown],
          reason: '`unknown` 不会出现在扫描结果里；除了 SniffFormat.unknown，'
              '谁落在它上面谁就是又一块红色的「UNKNOWN」角标');
    });

    test('角标写的是各自的名字：ISO 就是 ISO，不是 OTHER', () {
      // `ArchiveType.other` 只管颜色分组；列表角标走 `ArchiveFile.badge`。
      const iso = ArchiveFile(
        name: 'a.iso',
        type: ArchiveType.other,
        size: '1 MB',
        badge: 'ISO',
      );
      expect(iso.typeLabel, 'ISO');
      expect(SniffFormat.iso.badge, 'ISO');
      expect(SniffFormat.vhdx.badge, 'VHDX');
      // 没给 badge 就退回类型名（老路径，ArchiveFile 的其它构造点不受影响）。
      const plain =
          ArchiveFile(name: 'a.zip', type: ArchiveType.zip, size: '1 MB');
      expect(plain.typeLabel, 'ZIP');
    });

    test('已有专属类型的格式，角标与类型名一致（没人被改名）', () {
      for (final f in SniffFormat.values) {
        final t = f.archiveType;
        if (t == ArchiveType.other || t == ArchiveType.unknown) continue;
        expect(f.badge, t.label, reason: '$f 的角标应当仍是 ${t.label}');
      }
    });

    test('除了 rar 与 other / unknown，没有两组格式挤在同一个 ArchiveType 上', () {
      // 塌陷的失败模式：新加一个格式图省事，映射到已经存在的值上 —— 类型角标
      // 从此对它撒谎，而且编译期不会有任何提示。只放行「本就该合并」的去处：
      // rar（rar4/rar5 在列表上都叫 RAR）、other（已识别但没有专属类型，角标靠
      // `badge` 各写各的名字）、unknown（上面那条单独钉）。
      final grouped = <ArchiveType, List<SniffFormat>>{};
      for (final f in SniffFormat.values) {
        grouped.putIfAbsent(f.archiveType, () => []).add(f);
      }
      for (final entry in grouped.entries) {
        if (entry.key == ArchiveType.rar ||
            entry.key == ArchiveType.other ||
            entry.key == ArchiveType.unknown) {
          continue;
        }
        expect(
          entry.value,
          hasLength(1),
          reason: '${entry.key} 上挤了 ${entry.value.join(" / ")}，'
              '它们该拆成不同的值（或都归到 other 并各给一个 badge）',
        );
      }
    });
  });
}
