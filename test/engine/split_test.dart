import 'package:deep_unzip/engine/models.dart';
import 'package:deep_unzip/engine/split.dart';
import 'package:flutter_test/flutter_test.dart';

/// 造输入。目录用 `/d/` 以示区分。
List<SplitInput> files(List<String> names, {int size = 0}) =>
    [for (final n in names) (path: '/d/$n', size: size)];

/// 取唯一家族的简称，便于断言。
SplitFamily? only(SplitScan s) => s.families.length == 1 ? s.families.single : null;

List<String> namesOf(SplitFamily f) =>
    f.parts.map((p) => p.split('/').last).toList();

void main() {
  group('compareNatural', () {
    test('数字段按数值比，不是字典序', () {
      expect(compareNatural('part2.rar', 'part10.rar'), lessThan(0));
      expect(compareNatural('x.001', 'x.010'), lessThan(0));
      expect(compareNatural('x.009', 'x.010'), lessThan(0));
      expect(compareNatural('x.100', 'x.099'), greaterThan(0));
    });

    test('数值相同则位宽短的在前（保证确定性）', () {
      expect(compareNatural('x.1', 'x.01'), lessThan(0));
    });

    test('非数字段按码元比', () {
      expect(compareNatural('a.txt', 'b.txt'), lessThan(0));
      expect(compareNatural('a.txt', 'a.txt'), 0);
      expect(compareNatural('ab', 'a'), greaterThan(0));
    });

    test('超长数字串不抛异常（不可能是分卷号）', () {
      expect(
        () => compareNatural(
          'x.${'9' * 30}',
          'x.${'9' * 31}',
        ),
        returnsNormally,
      );
    });

    test('前导零不影响数值序', () {
      final list = ['x.003', 'x.001', 'x.002']..sort(compareNatural);
      expect(list, ['x.001', 'x.002', 'x.003']);
    });
  });

  group('裸字节切分（x.zip.001 / x.7z.001 / x.001）', () {
    test('基本识别与排序', () {
      final s = groupSplitVolumes(files(['b.zip.002', 'b.zip.001', 'b.zip.003']));
      final f = only(s)!;
      expect(f.kind, SplitKind.rawSplit);
      expect(namesOf(f), ['b.zip.001', 'b.zip.002', 'b.zip.003']);
      // 入口点是第一个卷。
      expect(f.entryPath, '/d/b.zip.001');
      expect(f.partCount, 3);
    });

    test('被收编的文件全部进 consumed', () {
      final s = groupSplitVolumes(files(['b.7z.001', 'b.7z.002']));
      expect(s.consumed, {'/d/b.7z.001', '/d/b.7z.002'});
    });

    test('缺起始卷 → 不分组并给警告', () {
      final s = groupSplitVolumes(files(['b.zip.002', 'b.zip.003']));
      expect(s.families, isEmpty);
      expect(s.warnings.single, contains('起始序号是 2'));
    });

    test('中段缺号 → 不分组并指出缺哪一卷', () {
      final s = groupSplitVolumes(files(['b.zip.001', 'b.zip.003']));
      expect(s.families, isEmpty);
      expect(s.warnings.single, contains('缺少第 2 卷'));
    });

    test('序号重复（位数不同）→ 不分组', () {
      final s = groupSplitVolumes(files(['b.zip.01', 'b.zip.001']));
      expect(s.families, isEmpty);
      expect(s.warnings.single, contains('重复'));
    });

    test('只有一片 → 不算分卷（交回普通文件处理）', () {
      final s = groupSplitVolumes(files(['b.zip.001']));
      expect(s.families, isEmpty);
      expect(s.consumed, isEmpty);
    });

    test('两位数字段也认（x.01 起）', () {
      final s = groupSplitVolumes(files(['b.001', 'b.02', 'b.03']));
      // .001 与 .02 位宽不同但序号连续（1,2,3），仍应成组。
      final f = only(s)!;
      expect(namesOf(f), ['b.001', 'b.02', 'b.03']);
    });

    test('位宽变化（第 999 卷之后是 4 位）仍能成组', () {
      // 序号是 1,2,3 —— 位宽不同不该影响连续性判定。
      final s = groupSplitVolumes(files(['b.001', 'b.0002', 'b.0003']));
      final f = only(s)!;
      expect(namesOf(f), ['b.001', 'b.0002', 'b.0003']);
    });

    test('序号 999/1000/1001 从 999 起 → 拒绝（不是从 1 开始）', () {
      final s = groupSplitVolumes(files(['b.999', 'b.1000', 'b.1001']));
      expect(s.families, isEmpty);
      expect(s.warnings.single, contains('起始序号是 999'));
    });

    test('入口点带伪后缀时，分组仍然成立（格式校验交给扫描器）', () {
      // 备份.rar.001 其实是 zip —— 分组只看名字。
      final s = groupSplitVolumes(files(['备份.rar.001', '备份.rar.002']));
      final f = only(s)!;
      expect(f.kind, SplitKind.rawSplit);
      expect(f.entryPath, '/d/备份.rar.001');
    });

    test('非末卷不等长 → 只警告，仍然成组', () {
      final s = groupSplitVolumes([
        (path: '/d/b.001', size: 1000),
        (path: '/d/b.002', size: 500), // 中间这片短了
        (path: '/d/b.003', size: 300),
      ]);
      final f = only(s)!;
      expect(f.parts, hasLength(3));
      expect(f.warnings, contains('分片尺寸异常：非末卷不等长'));
    });

    test('末卷短是正常的，不告警', () {
      final s = groupSplitVolumes([
        (path: '/d/b.001', size: 1000),
        (path: '/d/b.002', size: 300),
      ]);
      expect(only(s)!.warnings, isEmpty);
    });

    test('尺寸未知（0）时不做等长检查', () {
      final s = groupSplitVolumes(files(['b.001', 'b.002']));
      expect(only(s)!.warnings, isEmpty);
    });

    test('名字里带数字但不以数字结尾的文件不受影响', () {
      final s = groupSplitVolumes(files(['2026.rar', 'report-v2.zip']));
      expect(s.families, isEmpty);
    });

    test('两个相同序号的文件不误组（report.2026 / report.2027）', () {
      final s = groupSplitVolumes(files(['report.2026', 'report.2027']));
      // 起始序号不是 1 → 拒绝。
      expect(s.families, isEmpty);
      expect(s.warnings.single, contains('起始序号'));
    });

    test('不同目录的同名分卷不会被混到一起', () {
      final s = groupSplitVolumes([
        (path: '/a/b.zip.001', size: 0),
        (path: '/c/b.zip.002', size: 0),
      ]);
      expect(s.families, isEmpty);
    });
  });

  group('Info-ZIP 跨卷（x.z01… + x.zip）', () {
    test('入口点是 .zip，且排在最后', () {
      final s = groupSplitVolumes(files(['c.z02', 'c.zip', 'c.z01']));
      final f = only(s)!;
      expect(f.kind, SplitKind.infoZipSpanned);
      expect(f.entryPath, '/d/c.zip');
      // 顺序：z01 → z02 → zip（.zip 在最后！）
      expect(namesOf(f), ['c.z01', 'c.z02', 'c.zip']);
    });

    test('缺少 .zip 卷 → 不分组（中央目录在最末卷里）', () {
      final s = groupSplitVolumes(files(['c.z01', 'c.z02']));
      expect(s.families, isEmpty);
      expect(s.warnings.single, contains('缺少对应的 .zip 卷'));
    });

    test('缺 .z01 → 不分组', () {
      final s = groupSplitVolumes(files(['c.z02', 'c.zip']));
      expect(s.families, isEmpty);
      expect(s.warnings.single, contains('起始序号是 2'));
    });

    test('单独一个 c.zip 不会被当成跨卷', () {
      final s = groupSplitVolumes(files(['c.zip']));
      expect(s.families, isEmpty);
    });

    test('大小写混用也能配对', () {
      final s = groupSplitVolumes(files(['C.Z01', 'c.ZIP']));
      final f = only(s)!;
      expect(f.kind, SplitKind.infoZipSpanned);
      expect(f.partCount, 2);
    });
  });

  group('RAR3 卷（x.rar + x.r00…）', () {
    test('入口点是 .rar，且排在最前', () {
      final s = groupSplitVolumes(files(['r.r01', 'r.rar', 'r.r00']));
      final f = only(s)!;
      expect(f.kind, SplitKind.rarVolumes);
      expect(f.entryPath, '/d/r.rar');
      expect(namesOf(f), ['r.rar', 'r.r00', 'r.r01']);
    });

    test('缺 .rar 首卷 → 不分组', () {
      final s = groupSplitVolumes(files(['r.r00', 'r.r01']));
      expect(s.families, isEmpty);
      expect(s.warnings.single, contains('缺少起始的 .rar 卷'));
    });

    test('续卷从 .r00 起（序号 0），不是 .r01', () {
      // 只有 .rar + .r01 而没有 .r00 → 缺号，拒绝。
      final s = groupSplitVolumes(files(['r.rar', 'r.r01']));
      expect(s.families, isEmpty);
      expect(s.warnings.single, contains('起始序号是 1'));
    });

    test('单独一个 .rar 不是分卷', () {
      final s = groupSplitVolumes(files(['r.rar']));
      expect(s.families, isEmpty);
    });
  });

  group('RAR5 卷（x.part1.rar / x.part01.rar）', () {
    test('基本识别', () {
      final s = groupSplitVolumes(files(['p.part2.rar', 'p.part1.rar']));
      final f = only(s)!;
      expect(f.kind, SplitKind.rar5Volumes);
      expect(f.entryPath, '/d/p.part1.rar');
      expect(namesOf(f), ['p.part1.rar', 'p.part2.rar']);
    });

    test('零填充写法（part01）', () {
      final s = groupSplitVolumes(files(['p.part01.rar', 'p.part02.rar']));
      final f = only(s)!;
      expect(namesOf(f), ['p.part01.rar', 'p.part02.rar']);
    });

    test('首卷是 SFX 的 .part1.exe', () {
      final s = groupSplitVolumes(files(['p.part1.exe', 'p.part2.rar']));
      final f = only(s)!;
      expect(f.kind, SplitKind.rar5Volumes);
      expect(namesOf(f), ['p.part1.exe', 'p.part2.rar']);
    });

    test('part2 排在 part10 之前（自然序，字典序会排反）', () {
      // 输入刻意打乱，且让 part10 排在 part2 前面。
      final input = [
        'p.part10.rar',
        for (var i = 9; i >= 1; i--) 'p.part$i.rar',
      ];
      final s = groupSplitVolumes(files(input));
      expect(
        namesOf(only(s)!),
        [for (var i = 1; i <= 10; i++) 'p.part$i.rar'],
      );
    });

    test('part 集合不连续（缺 part3）→ 拒绝', () {
      final s = groupSplitVolumes(files(
        ['p.part1.rar', 'p.part2.rar', 'p.part4.rar'],
      ));
      expect(s.families, isEmpty);
      expect(s.warnings.single, contains('缺少第 3 卷'));
    });

    test('缺 part1 → 不分组', () {
      final s = groupSplitVolumes(files(['p.part2.rar', 'p.part3.rar']));
      expect(s.families, isEmpty);
      expect(s.warnings.single, contains('起始序号是 2'));
    });

    test('单独一个 part1.rar 不是分卷', () {
      final s = groupSplitVolumes(files(['p.part1.rar']));
      expect(s.families, isEmpty);
      expect(s.consumed, isEmpty);
    });

    test('part1.rar 不会被 RAR3 抢走', () {
      // RAR3 的 ^(.*)\.rar$ 也能匹配 p.part1.rar，所以 RAR5 必须先跑。
      final s = groupSplitVolumes(files(['p.part1.rar', 'p.part2.rar']));
      expect(only(s)!.kind, SplitKind.rar5Volumes);
    });
  });

  group('混合场景', () {
    test('同一目录里多个家族互不干扰', () {
      final s = groupSplitVolumes(files([
        'a.zip.001', 'a.zip.002',
        'b.part1.rar', 'b.part2.rar',
        'c.rar', 'c.r00',
        'd.z01', 'd.zip',
        'normal.zip',
        'photo.jpg',
      ]));

      expect(s.families, hasLength(4));
      final kinds = s.families.map((f) => f.kind).toSet();
      expect(kinds, {
        SplitKind.rawSplit,
        SplitKind.rar5Volumes,
        SplitKind.rarVolumes,
        SplitKind.infoZipSpanned,
      });

      // 普通文件与图片没被收编。
      expect(s.consumed.contains('/d/normal.zip'), isFalse);
      expect(s.consumed.contains('/d/photo.jpg'), isFalse);
      expect(s.consumed, hasLength(8));
    });

    test('空输入', () {
      final s = groupSplitVolumes([]);
      expect(s.families, isEmpty);
      expect(s.consumed, isEmpty);
      expect(s.isEmpty, isTrue);
    });

    test('全是普通文件', () {
      final s = groupSplitVolumes(files(['a.zip', 'b.7z', 'c.txt']));
      expect(s.families, isEmpty);
      expect(s.warnings, isEmpty);
    });
  });

  group('firstVolumeLooksValid（首卷校验）', () {
    const zip = SniffResult(
      format: SniffFormat.zip,
      confidence: SniffConfidence.high,
    );

    test('认得出是压缩包 → 放行', () {
      expect(firstVolumeLooksValid(zip), isTrue);
    });

    test('认不出 → 整组不算分卷', () {
      expect(firstVolumeLooksValid(SniffResult.unknown), isFalse);
    });

    test('是容器格式（docx/apk）→ 也不算分卷', () {
      expect(
        firstVolumeLooksValid(const SniffResult(
          format: SniffFormat.zip,
          confidence: SniffConfidence.high,
          container: ContainerKind.ooxml,
        )),
        isFalse,
      );
    });

    test('格式与名字不符不影响放行（伪后缀由 P5 处理）', () {
      const rarNamedZip = SniffResult(
        format: SniffFormat.zip,
        confidence: SniffConfidence.high,
        declaredExt: 'rar',
      );
      expect(rarNamedZip.isExtensionSpoofed, isTrue);
      expect(firstVolumeLooksValid(rarNamedZip), isTrue);
    });
  });
}
