import 'dart:io';

import 'package:deep_unzip/engine/output_paths.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  group('deriveOutputName —— 基本后缀', () {
    test('单层后缀', () {
      expect(deriveOutputName('/sdcard/a.zip'), 'a');
      expect(deriveOutputName('/sdcard/a.7z'), 'a');
      expect(deriveOutputName('/sdcard/a.rar'), 'a');
    });

    test('双层组合后缀（tar 家族）', () {
      expect(deriveOutputName('/sdcard/c.tar.gz'), 'c');
      expect(deriveOutputName('/sdcard/c.tar.bz2'), 'c');
      expect(deriveOutputName('/sdcard/c.tar.xz'), 'c');
      expect(deriveOutputName('/sdcard/c.tar.zst'), 'c');
      // 简写形式也算一层，剥完就停。
      expect(deriveOutputName('/sdcard/c.tgz'), 'c');
    });

    test('纯 tar', () {
      expect(deriveOutputName('/sdcard/d.tar'), 'd');
    });
  });

  group('deriveOutputName —— 卷号（阶段 1）', () {
    test('裸切分：.001 / .002', () {
      expect(deriveOutputName('/sdcard/x.zip.001'), 'x');
      expect(deriveOutputName('/sdcard/x.7z.001'), 'x');
      // 没有格式后缀的裸切分：.001 剥掉就没了，再剥一层也没有可剥的。
      expect(deriveOutputName('/sdcard/x.001'), 'x');
    });

    test('Info-ZIP 跨卷的 z01 形态', () {
      expect(deriveOutputName('/sdcard/x.z01'), 'x');
    });

    test('RAR3 旧式卷 r00', () {
      expect(deriveOutputName('/sdcard/x.r00'), 'x');
      expect(deriveOutputName('/sdcard/x.r99'), 'x');
    });

    test('卷号 + 组合后缀', () {
      expect(deriveOutputName('/sdcard/x.tar.gz.001'), 'x');
    });
  });

  group('deriveOutputName —— partNN（阶段 3）', () {
    test('RAR5 新式卷', () {
      expect(deriveOutputName('/sdcard/backup.part1.rar'), 'backup');
      expect(deriveOutputName('/sdcard/backup.part01.rar'), 'backup');
      expect(deriveOutputName('/sdcard/backup.part123.rar'), 'backup');
    });

    test('partNN 后面没有格式后缀也认', () {
      expect(deriveOutputName('/sdcard/backup.part01'), 'backup');
    });
  });

  group('deriveOutputName —— 阶段顺序的回归用例', () {
    // 这三条是「把阶段 1 和 2 调换」会立刻挂掉的用例，
    // 留着是为了让人不敢动那个顺序。
    test('年份不能被当成卷号', () {
      expect(deriveOutputName('/sdcard/报告.2026.zip'), '报告.2026');
      expect(deriveOutputName('/sdcard/backup.2026.tar.gz'), 'backup.2026');
    });

    test('版本号段不能被当成卷号', () {
      expect(deriveOutputName('/sdcard/app-v2.10.zip'), 'app-v2.10');
    });

    test('点开头的隐藏文件不剥', () {
      // `.gitignore` 剥掉会得到空串 —— 那是「解进源目录」的前兆。
      expect(deriveOutputName('/sdcard/.zip'), '.zip');
    });
  });

  group('deriveOutputName —— 兜底', () {
    test('没有后缀时原样返回', () {
      expect(deriveOutputName('/sdcard/plainfile'), 'plainfile');
    });

    test('全是后缀时回退到 extracted，绝不返回空串', () {
      // `extracted.zip` 剥一层是 `extracted`，正常。
      expect(deriveOutputName('/sdcard/extracted.zip'), 'extracted');
      // 名字完全等于后缀：剥掉就空了。
      expect(deriveOutputName('/sdcard/zip'), 'zip');
      expect(deriveOutputName('/sdcard/.zip'), '.zip');
    });

    test('反斜杠路径也能取对 basename', () {
      expect(deriveOutputName(r'C:\Users\me\a.zip'), 'a');
    });

    test('超长后缀链不会把名字剥空', () {
      final name = deriveOutputName('/sdcard/${'a' * 3}${'.zip' * 10}');
      expect(name, isNotEmpty);
    });
  });

  group('resolveOutputDir', () {
    test('同级兄弟，不是子目录', () {
      expect(resolveOutputDir('/sdcard/A/B/c.zip'), '/sdcard/A/B/c');
    });

    test('重名时追加 _1、_2', () {
      final taken = {'/sdcard/c', '/sdcard/c_1'};
      final got = resolveOutputDir('/sdcard/c.zip', isTaken: taken.contains);
      expect(got, '/sdcard/c_2');
    });

    test('无冲突时不加后缀', () {
      final got = resolveOutputDir('/sdcard/c.zip', isTaken: (_) => false);
      expect(got, '/sdcard/c');
    });

    test('根目录下的文件', () {
      expect(resolveOutputDir('/a.zip', isTaken: (_) => false), '/a');
    });
  });

  // 需求 5 的伪后缀。真机上 `fake.pdf`（实为 ZIP）整包失败，根因就在这里：
  // 输出名跟源文件同名，后端建目录时撞上一个已经存在的**文件**。
  group('伪后缀的输出名', () {
    test('假后缀被剥掉，输出名不再等于源文件名', () {
      expect(deriveOutputName('/sdcard/fake.pdf', spoofedExtension: true),
          'fake');
      expect(deriveOutputName('/sdcard/photo.jpg', spoofedExtension: true),
          'photo');
      expect(deriveOutputName('/sdcard/movie.mp4', spoofedExtension: true),
          'movie');
    });

    test('不声明伪后缀时维持原样 —— 真 PDF 的名字不该被动', () {
      expect(deriveOutputName('/sdcard/fake.pdf'), 'fake.pdf');
    });

    test('先剥假后缀，才轮得到真后缀 —— backup.zip.exe → backup', () {
      // 反过来做只会得到 `backup.zip`：`.exe` 不剥掉，阶段 2 就看不见 `.zip`。
      expect(deriveOutputName('/sdcard/backup.zip.exe', spoofedExtension: true),
          'backup');
    });

    test('带卷号的伪后缀：movie.mkv.001 → movie', () {
      // 阶段 1 先剥 `.001`，阶段 1.5 再剥假后缀 `.mkv`。
      expect(deriveOutputName('/sdcard/movie.mkv.001', spoofedExtension: true),
          'movie');
    });

    test('剥空时仍然回退到 extracted，不返回空串', () {
      // `.pdf` 整个就是名字（点在开头，_lastSegment 给 null），无可剥，
      // 于是原样留着 —— 关键是**不能**变成空串。
      expect(deriveOutputName('/sdcard/.pdf', spoofedExtension: true), '.pdf');
    });

    test('resolveOutputDir 把伪后缀透传下去', () {
      expect(
        resolveOutputDir('/sdcard/fake.pdf',
            spoofedExtension: true, isTaken: (_) => false),
        '/sdcard/fake',
      );
    });
  });

  // 没有后缀的压缩包（真名就叫 `data` 的 zip）推出来的输出名就是 `data`，
  // 跟源文件撞上。占用判定必须把「文件」也算占着，否则后端建目录会抛。
  group('占用判定：同名文件也算占着', () {
    test('被同名文件占着时退到 _1', () {
      final got = resolveOutputDir('/sdcard/data',
          isTaken: (path) => path == '/sdcard/data');
      expect(got, '/sdcard/data_1');
    });

    test('真实文件系统上，同名文件确实算占用', () {
      final dir = Directory.systemTemp.createTempSync('duz_occupied');
      addTearDown(() => dir.deleteSync(recursive: true));

      // 在真正的磁盘上放一个**文件**，路径正好等于推导出的输出名。
      final src = File(p.join(dir.path, 'data'))..writeAsStringSync('not a dir');

      final got = resolveOutputDir(src.path);
      expect(got, isNot(src.path), reason: '不能把源文件自己的路径当输出目录');
      // 只比基名：返回值一律是 posix 形态（见 output_paths.dart 里
      // _toPosix 的说明），拿 `p.join` 拼出来的宿主形态路径比会栽在分隔符上。
      expect(p.basename(got), 'data_1');
    });
  });
}
