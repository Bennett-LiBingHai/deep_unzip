import 'package:deep_unzip/data/builtin_extractors.dart';
import 'package:deep_unzip/engine/models.dart';
import 'package:deep_unzip/models/extractor.dart';
import 'package:flutter_test/flutter_test.dart';

/// 设置页那份「支持的格式」清单**说的必须是引擎真做的事**。
///
/// ## 补的是哪一段缝
///
/// 这张表里的字符串是**原样显示给用户**的，但没有任何代码读它 —— 识别靠
/// `engine/sniff.dart`，解压靠 7-Zip 核心。于是它可以静静地漂到跟现实毫无关系，
/// 而**所有测试照样绿**：从前那六条里写着 `unzip -o {file} -d {dir}`、
/// `tar -xzf`，这个 app 一次都没执行过；`TAR.GZ` 那行配的判据 `1F 8B` 其实是
/// GZIP 的签名；真正支持的格式一大半没列。
///
/// 所以这里把「这张表」和「嗅探表」用一条机器判据拴在一起。
void main() {
  Extractor byName(String name) =>
      BuiltinExtractors.all.firstWhere((e) => e.name == name,
          orElse: () => fail('清单里没有 $name'));

  group('这张表与嗅探表对得上', () {
    test('嗅探认得出的格式，一条都不能少', () {
      final covered = {for (final e in BuiltinExtractors.all) ...e.formats};
      final missing = SniffFormat.values
          .where((f) => f != SniffFormat.unknown && !covered.contains(f))
          .toList();

      expect(
        missing,
        isEmpty,
        reason: '这几个格式嗅探认得出、内置核心也解得开，清单里却没有 —— '
            '用户会以为它们不受支持。补进 `BuiltinExtractors.all` 再来。'
            '漏掉的：${missing.map((f) => f.label).toList()}',
      );
    });

    test('一个格式只归一行，不被两行同时认领', () {
      final seen = <SniffFormat, String>{};
      for (final e in BuiltinExtractors.all) {
        for (final f in e.formats) {
          expect(seen.containsKey(f), isFalse,
              reason: '$f 同时被「${seen[f]}」与「${e.name}」认领');
          seen[f] = e.name;
        }
      }
    });

    test('也不许认领嗅探认不出的格式', () {
      for (final e in BuiltinExtractors.all) {
        expect(e.formats, isNot(contains(SniffFormat.unknown)),
            reason: '${e.name} 认领了 unknown');
        expect(e.formats, isNotEmpty, reason: '${e.name} 一个格式都没认领');
      }
    });

    test('识别那栏抄的是真签名', () {
      // 这几串照 `engine/sniff.dart` 的签名表抄，`sniff_test.dart` 那边断的是同
      // 一组字节。两处都断同一件事，是因为**这边这串会原样显示给用户** ——
      // 旧版 `TAR.GZ` 配 `1F 8B`（GZIP 的签名）就是从这个位置漂出去的。
      expect(byName('ZIP').detectLogic, contains('50 4B 03 04'));
      expect(byName('RAR').detectLogic, contains('52 61 72 21 1A 07 00'));
      expect(byName('RAR').detectLogic, contains('01 00'),
          reason: 'RAR5 比 RAR4 多一个字节，嗅探时它必须排在前面');
      expect(byName('7-Zip').detectLogic, contains('37 7A BC AF 27 1C'));
      expect(byName('TAR').detectLogic, contains('ustar'));
      expect(byName('TAR').detectLogic, contains('257'),
          reason: 'tar 的签名不在偏移 0 —— 不写偏移就是在糊弄');
      expect(byName('GZIP').detectLogic, contains('1F 8B'));
      expect(byName('BZIP2').detectLogic, contains('42 5A 68'));
      expect(byName('XZ').detectLogic, contains('FD 37 7A 58 5A 00'));
      expect(byName('ZSTD').detectLogic, contains('28 B5 2F FD'));
      expect(byName('CAB').detectLogic, contains('4D 53 43 46'));
      expect(byName('LHA').detectLogic, contains('-lh'));
      expect(byName('ARJ').detectLogic, contains('60 EA'));
      expect(byName('CPIO').detectLogic, contains('070707'));
    });

    test('新收的那批：签名与偏移照 7-Zip 的写', () {
      expect(byName('Unix compress').detectLogic, contains('1F 9D'));
      expect(byName('PPMd').detectLogic, contains('8F AF AC 84'));
      expect(byName('MS 压缩（SZDD）').detectLogic, contains('53 5A 44 44'));
      expect(byName('RPM').detectLogic, contains('ED AB EE DB'));
      expect(byName('AR / DEB').detectLogic, contains('21 3C 61 72 63 68 3E 0A'));
      expect(byName('XAR').detectLogic, contains('78 61 72 21'));
      expect(byName('WIM').detectLogic, contains('4D 53 57 49 4D'));
      expect(byName('SquashFS').detectLogic, contains('hsqs'));
      expect(byName('QCOW').detectLogic, contains('51 46 49 FB'));
      expect(byName('VMDK').detectLogic, contains('4B 44 4D 56'));
      expect(byName('VHDX').detectLogic, contains('76 68 64 78'));
      expect(byName('Android Sparse').detectLogic, contains('3A FF 26 ED'));
    });

    test('签名不在文件头的几条必须把位置写出来', () {
      // 不写位置，用户拿十六进制编辑器看文件头永远对不上，还以为我们认错了。
      expect(byName('ISO').detectLogic, contains('0x8000'));
      expect(byName('UDF').detectLogic, contains('0x8000'));
      expect(byName('DMG').detectLogic, contains('文件尾'));
      expect(byName('CramFS').detectLogic, contains('偏移 16'));
      expect(byName('VDI').detectLogic, contains('0x40'));
      expect(byName('NTFS 卷').detectLogic, contains('偏移 3'));
    });
  });

  group('解压那栏说的是真后端', () {
    test('一条外部命令都不许有', () {
      // 从前这里写着 `unzip -o`、`unrar x -y`、`tar -xzf`、`zip -s-`。这个 app
      // 从头到尾没执行过它们 —— 真路径只有 FFI 调内置 7-Zip 核心一条。
      const banned = [
        'unzip',
        'unrar',
        'tar -',
        '7z x',
        'zip -s',
        'invokeexternaltool',
        'shell',
      ];
      for (final e in BuiltinExtractors.all) {
        for (final bad in banned) {
          expect(e.extractLogic.toLowerCase(), isNot(contains(bad)),
              reason: '${e.name} 那行写着「$bad」—— 但解压没有外部命令这条路');
        }
      }
    });

    test('全部都是同一条真路径', () {
      expect(
        BuiltinExtractors.all.map((e) => e.extractLogic).toSet(),
        {'内置 7-Zip 核心'},
        reason: '将来真接了第二种后端，回这里报到再改 —— 别让它悄悄变成「有的写这个、'
            '有的写那个」而没人核对',
      );
    });
  });

  group('分卷是属性，不是分类', () {
    test('同一个格式只出现一次', () {
      final names = BuiltinExtractors.all.map((e) => e.name).toList();
      expect(names.toSet().length, names.length,
          reason: '有重名。从前正是「ZIP / ZIP 分卷」这种按分卷拆出来的重复行');
    });

    test('支持分卷的格式不必独占一行，也不需要重新分一个类', () {
      // 分卷不是一种格式：ZIP、7z、RAR 都能分卷，而 `split.dart` 也是先把卷聚成
      // 一组、再整组交给格式后端的。所以清单里 ZIP 只有一行，分卷写在 `split` 上。
      final withSplit = BuiltinExtractors.all
          .where((e) => e.split != null)
          .map((e) => e.name);
      expect(withSplit, containsAll(['ZIP', 'RAR']));
      expect(byName('ZIP').formats, {SniffFormat.zip},
          reason: '一行 ZIP 同时管着单文件和分卷 —— 这正是拆掉那个二分的意义');
    });

    test('通用裸切分不往每一行抄一遍', () {
      // `*.001` 对任何格式都成立（`split.dart` 的 rawSplit 家族只认「名字 + 数字」），
      // 抄到三十行里是重复噪音，设置页折叠头那句说明里已经统一交代过。
      for (final e in BuiltinExtractors.all) {
        if (e.split == null) continue;
        expect(e.split, isNot(startsWith('*.001')),
            reason: '${e.name} 把通用裸切分写进了「特有命名」那一栏');
      }
    });

    test('已知缺口写在脸上：*.z01 跨卷标的是「未验证」', () {
      final zip = byName('ZIP');
      expect(zip.split, contains('.z01'),
          reason: 'Info-ZIP 跨卷能被识别、能被分组，不该装作不存在');
      expect(zip.split, contains('未验证'),
          reason: '那个形态到底能不能解，本机造不出真样本、没验证过 —— 写「不支持」'
              '是替用户拍板，干脆不提是隐瞒。');
    });
  });

  group('角标', () {
    test('方框标签放得下（最多三个字符）', () {
      // 设置页那个 38px 见方的框，10px 等宽字 —— 再多就溢出了。
      for (final e in BuiltinExtractors.all) {
        expect(e.tag.length, lessThanOrEqualTo(3),
            reason: '${e.name} 的标签「${e.tag}」太长');
        expect(e.tag, isNotEmpty);
      }
    });

    test('扫描结果列表的角标放得下（最多五个字符）', () {
      // 首页那块 32px 见方、9px 等宽字，装得下 5 个字符。
      for (final f in SniffFormat.values) {
        // `unknown` 不会出现在扫描结果里（认不出就不入列），它的角标不受这条限制。
        if (f == SniffFormat.unknown) continue;
        expect(f.badge.length, lessThanOrEqualTo(5),
            reason: '$f 的角标「${f.badge}」太长，会溢出');
        expect(f.badge, isNotEmpty);
        expect(f.badge, f.badge.toUpperCase(), reason: '角标统一大写');
      }
    });
  });
}
