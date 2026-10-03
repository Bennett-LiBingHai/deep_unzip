import 'dart:io';
import 'dart:typed_data';

import 'package:deep_unzip/engine/models.dart';
import 'package:deep_unzip/engine/sniff.dart';
import 'package:deep_unzip/engine/zip_dir.dart';
import 'package:flutter_test/flutter_test.dart';

import 'zip_fixtures.dart';

/// 把签名补到 512 字节（模拟文件头读取窗口）。
Uint8List head(List<int> magic, {int total = 512, int at = 0}) {
  final b = Uint8List(total);
  for (var i = 0; i < magic.length; i++) {
    b[at + i] = magic[i];
  }
  return b;
}

void main() {
  group('extensionOf', () {
    test('取最后一段后缀并小写化', () {
      expect(extensionOf('a/b/c.ZIP'), 'zip');
      expect(extensionOf('x.tar.gz'), 'gz');
      expect(extensionOf(r'd:\dir\f.Rar'), 'rar');
      expect(extensionOf('/sdcard/Download/备份.7z'), '7z');
    });

    test('无后缀 / 纯 dotfile → 空串', () {
      expect(extensionOf('/a/b/README'), '');
      expect(extensionOf('/a/b/.gitignore'), '');
      expect(extensionOf(''), '');
    });

    test('结尾是点 → 空串（不是后缀）', () {
      expect(extensionOf('/a/b/weird.'), '');
    });

    test('目录名里的点不算数', () {
      expect(extensionOf('/a.b/file'), '');
    });
  });

  group('sniffHeadBytes：魔术字节表', () {
    void expectFormat(List<int> magic, SniffFormat f, {int at = 0}) {
      final r = sniffHeadBytes(head(magic, at: at));
      expect(r.format, f, reason: 'magic=$magic at=$at');
    }

    test('ZIP 三种签名', () {
      expectFormat([0x50, 0x4B, 0x03, 0x04], SniffFormat.zip);
      expectFormat([0x50, 0x4B, 0x05, 0x06], SniffFormat.zip);
      expectFormat([0x50, 0x4B, 0x07, 0x08], SniffFormat.zip);
    });

    test('RAR4 与 RAR5 不混淆', () {
      expectFormat([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00], SniffFormat.rar4);
      expectFormat(
        [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00],
        SniffFormat.rar5,
      );
    });

    test('7z / XZ / ZSTD / CAB / CPIO / ARJ / BZIP2 / GZIP', () {
      expectFormat([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C], SniffFormat.sevenZ);
      expectFormat([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00], SniffFormat.xz);
      expectFormat([0x28, 0xB5, 0x2F, 0xFD], SniffFormat.zstd);
      expectFormat([0x4D, 0x53, 0x43, 0x46], SniffFormat.cab);
      expectFormat([0x30, 0x37, 0x30, 0x37, 0x30, 0x37], SniffFormat.cpio);
      expectFormat([0x30, 0x37, 0x30, 0x37, 0x30, 0x31], SniffFormat.cpio);
      expectFormat([0xC7, 0x71], SniffFormat.cpio);
      expectFormat([0x60, 0xEA], SniffFormat.arj);
      expectFormat([0x42, 0x5A, 0x68], SniffFormat.bzip2);
      expectFormat([0x1F, 0x8B], SniffFormat.gzip);
    });

    test('TAR 的 ustar 在偏移 257', () {
      expectFormat([0x75, 0x73, 0x74, 0x61, 0x72], SniffFormat.tar, at: 257);
    });

    test('LHA 的 -lh 在偏移 2', () {
      expectFormat([0x2D, 0x6C, 0x68, 0x35, 0x2D], SniffFormat.lzh, at: 2);
    });

    test('偏移 0 的签名优先于固定偏移的签名', () {
      // 造一个开头是 ZIP、257 处又是 ustar 的头 —— 必须判 ZIP。
      final b = Uint8List(512);
      b[0] = 0x50;
      b[1] = 0x4B;
      b[2] = 0x03;
      b[3] = 0x04;
      for (var i = 0; i < 5; i++) {
        b[257 + i] = [0x75, 0x73, 0x74, 0x61, 0x72][i];
      }
      expect(sniffHeadBytes(b).format, SniffFormat.zip);
    });

    test('什么都没有 → unknown / none', () {
      final r = sniffHeadBytes(Uint8List(512));
      expect(r.format, SniffFormat.unknown);
      expect(r.confidence, SniffConfidence.none);
      expect(r.isArchive, isFalse);
    });

    test('头太短不足以匹配固定偏移签名 → unknown，不越界', () {
      final short = Uint8List.fromList([0x75, 0x73, 0x74, 0x61]); // 只有 "usta"
      expect(sniffHeadBytes(short).format, SniffFormat.unknown);
    });

    test('空头不抛异常', () {
      expect(sniffHeadBytes(Uint8List(0)).format, SniffFormat.unknown);
    });

    test('置信度分层：强签名 high，2~3 字节签名 medium', () {
      expect(
        sniffHeadBytes(head([0x50, 0x4B, 0x03, 0x04])).confidence,
        SniffConfidence.high,
      );
      expect(
        sniffHeadBytes(head([0x1F, 0x8B])).confidence,
        SniffConfidence.medium,
      );
      // CPIO 的 ASCII 变体是低熵串，刻意降级。
      expect(
        sniffHeadBytes(head([0x30, 0x37, 0x30, 0x37, 0x30, 0x37])).confidence,
        SniffConfidence.medium,
      );
    });

    test('header 只保留前 16 字节', () {
      final b = Uint8List(512);
      b[0] = 0x50;
      b[1] = 0x4B;
      b[2] = 0x03;
      b[3] = 0x04;
      expect(sniffHeadBytes(b).header.length, kHexPreviewBytes);
    });
  });

  group('looksLikeMz', () {
    test('MZ 开头', () {
      expect(looksLikeMz(Uint8List.fromList([0x4D, 0x5A, 0x90, 0x00])), isTrue);
      expect(looksLikeMz(Uint8List.fromList([0x4D, 0x5B])), isFalse);
      expect(looksLikeMz(Uint8List.fromList([0x4D])), isFalse);
      expect(looksLikeMz(Uint8List(0)), isFalse);
    });
  });

  group('isExtensionSpoofed（模型层）', () {
    test('后缀与真实格式不符 → 判定篡改', () {
      const r = SniffResult(
        format: SniffFormat.zip,
        confidence: SniffConfidence.high,
        declaredExt: 'pdf',
      );
      expect(r.isExtensionSpoofed, isTrue);
    });

    test('同族后缀不算篡改（tar.gz / tgz）', () {
      expect(
        const SniffResult(
          format: SniffFormat.gzip,
          confidence: SniffConfidence.high,
          declaredExt: 'tgz',
        ).isExtensionSpoofed,
        isFalse,
      );
      expect(
        const SniffResult(
          format: SniffFormat.zip,
          confidence: SniffConfidence.high,
          declaredExt: 'apk',
        ).isExtensionSpoofed,
        isFalse,
      );
    });

    test('无后缀不算篡改（静默按真实格式解压）', () {
      expect(
        const SniffResult(
          format: SniffFormat.zip,
          confidence: SniffConfidence.high,
        ).isExtensionSpoofed,
        isFalse,
      );
    });

    test('认不出真实格式就不谈篡改', () {
      expect(
        const SniffResult(
          format: SniffFormat.unknown,
          confidence: SniffConfidence.none,
          declaredExt: 'zip',
        ).isExtensionSpoofed,
        isFalse,
      );
    });

    test('该格式没维护后缀表 → 不做判定（cab/lzh/arj/cpio）', () {
      for (final f in [
        SniffFormat.cab,
        SniffFormat.lzh,
        SniffFormat.arj,
        SniffFormat.cpio,
      ]) {
        expect(
          SniffResult(
            format: f,
            confidence: SniffConfidence.high,
            declaredExt: 'txt',
          ).isExtensionSpoofed,
          isFalse,
          reason: '$f',
        );
      }
    });
  });

  group('detectContainer（纯函数）', () {
    List<ZipEntry> entriesOf(List<String> names) => [
          for (final n in names) cdRecord(name: n),
        ].map((b) => parseCentralDirectory(b).single).toList();

    test('OOXML', () {
      expect(
        detectContainer(entriesOf([
          '[Content_Types].xml',
          '_rels/.rels',
          'word/document.xml',
        ])),
        ContainerKind.ooxml,
      );
      expect(
        detectContainer(entriesOf([
          '[Content_Types].xml',
          'xl/workbook.xml',
        ])),
        ContainerKind.ooxml,
      );
    });

    test('有 [Content_Types].xml 但没有 word/xl/ppt → 不判容器', () {
      expect(
        detectContainer(entriesOf(['[Content_Types].xml', 'foo.txt'])),
        ContainerKind.none,
      );
    });

    test('EPUB 与 ODF 都靠首条 mimetype，再靠 META-INF 区分', () {
      expect(
        detectContainer(entriesOf([
          'mimetype',
          'META-INF/container.xml',
          'OEBPS/content.opf',
        ])),
        ContainerKind.epub,
      );
      expect(
        detectContainer(entriesOf([
          'mimetype',
          'META-INF/manifest.xml',
          'content.xml',
        ])),
        ContainerKind.odf,
      );
    });

    test('mimetype 不在第一条 → 不算 EPUB/ODF', () {
      expect(
        detectContainer(entriesOf([
          'META-INF/container.xml',
          'mimetype',
        ])),
        ContainerKind.none,
      );
    });

    test('APK 需要 AndroidManifest.xml + classes.dex', () {
      expect(
        detectContainer(entriesOf([
          'AndroidManifest.xml',
          'classes.dex',
          'META-INF/MANIFEST.MF',
          'res/layout/main.xml',
        ])),
        ContainerKind.apk,
      );
      // 缺 classes.dex（比如 AAR）不判 APK。
      expect(
        detectContainer(entriesOf(['AndroidManifest.xml', 'classes.jar'])),
        ContainerKind.none,
      );
    });

    test('AAB 优先于 APK', () {
      expect(
        detectContainer(entriesOf([
          'BundleConfig.pb',
          'base/manifest/AndroidManifest.xml',
          'base/dex/classes.dex',
        ])),
        ContainerKind.aab,
      );
    });

    test('IPA', () {
      expect(
        detectContainer(entriesOf([
          'Payload/Demo.app/Demo',
          'Payload/Demo.app/Info.plist',
        ])),
        ContainerKind.ipa,
      );
    });

    test('JAR 需要 MANIFEST.MF + .class', () {
      expect(
        detectContainer(entriesOf([
          'META-INF/MANIFEST.MF',
          'com/example/Main.class',
        ])),
        ContainerKind.jar,
      );
      expect(
        detectContainer(entriesOf(['META-INF/MANIFEST.MF', 'src/Main.java'])),
        ContainerKind.none,
      );
    });

    test('NUPKG 看根目录 .nuspec', () {
      expect(
        detectContainer(entriesOf(['MyLib.nuspec', 'lib/net8.0/MyLib.dll'])),
        ContainerKind.nupkg,
      );
      // 嵌套路径下的 .nuspec 不算。
      expect(
        detectContainer(entriesOf(['tools/MyLib.nuspec'])),
        ContainerKind.none,
      );
    });

    test('KMZ 看根目录 doc.kml', () {
      expect(
        detectContainer(entriesOf(['doc.kml', 'images/a.png'])),
        ContainerKind.kmz,
      );
    });

    test('浏览器扩展：根 manifest.json 必须配 _locales', () {
      expect(
        detectContainer(entriesOf(['manifest.json', '_locales/en/messages.json'])),
        ContainerKind.browserExt,
      );
      // 只有 manifest.json 太容易误伤 —— 不判。
      expect(
        detectContainer(entriesOf(['manifest.json', 'index.html'])),
        ContainerKind.none,
      );
    });

    test('普通压缩包 / 空归档 → none', () {
      expect(detectContainer(entriesOf(['a.txt', 'b/c.jpg'])), ContainerKind.none);
      expect(detectContainer(const []), ContainerKind.none);
    });

    test('cbz 漫画包不被当容器（用户真心想解压）', () {
      expect(
        kContainerExtensions.containsKey('cbz'),
        isFalse,
      );
      expect(
        kContainerExtensions.containsKey('cbr'),
        isFalse,
      );
    });

    // 回归：ZIP 规范只说路径分隔符 SHOULD 用正斜杠，Windows 自带的
    // `Compress-Archive` 实测写的就是反斜杠。曾因只匹配 `word/` 而把这类
    // 合法 OOXML 漏判成普通压缩包。
    test('反斜杠分隔符的条目名同样能识破容器', () {
      expect(
        detectContainer(entriesOf([
          '[Content_Types].xml',
          r'_rels\.rels',
          r'word\document.xml',
        ])),
        ContainerKind.ooxml,
        reason: 'Windows 工具链产出的 OOXML',
      );
      expect(
        detectContainer(entriesOf([
          r'Payload\Demo.app\Info.plist',
        ])),
        ContainerKind.ipa,
      );
      expect(
        detectContainer(entriesOf([
          r'base\manifest\AndroidManifest.xml',
          'BundleConfig.pb',
        ])),
        ContainerKind.aab,
      );
      expect(
        detectContainer(entriesOf([
          r'META-INF\MANIFEST.MF',
          r'com\demo\Main.class',
        ])),
        ContainerKind.jar,
      );
      // 根目录 nuspec 的前提是「名字里没有目录」，反斜杠也得算目录。
      expect(
        detectContainer(entriesOf([r'lib\foo.nuspec'])),
        ContainerKind.none,
      );
    });
  });

  group('sniffFile（真文件）', () {
    late Directory dir;
    setUp(() => dir = makeTempDir('sniff'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('后缀在跳过表里 → 不读文件，直接判容器', () async {
      // 内容是垃圾也不要紧：这条路根本不该打开文件。
      final path = writeTempFile(dir, 'report.docx', [1, 2, 3, 4]);
      final r = await sniffFile(path);
      expect(r.container, ContainerKind.ooxml);
      expect(r.isArchive, isFalse);
      expect(r.declaredExt, 'docx');
    });

    test('真 zip 命名为 .zip → 无容器，可解压', () async {
      final path = writeTempFile(dir, 'a.zip', realZip({'a.txt': 'hi'}));
      final r = await sniffFile(path);
      expect(r.format, SniffFormat.zip);
      expect(r.container, ContainerKind.none);
      expect(r.isArchive, isTrue);
      expect(r.baseOffset, 0);
    });

    test('需求 5：真 OOXML 内容伪装成 .zip → 中央目录标记识破', () async {
      final bytes = realZip({
        '[Content_Types].xml': '<Types/>',
        'word/document.xml': '<w:document/>',
      });
      final path = writeTempFile(dir, 'looks_innocent.zip', bytes);

      final r = await sniffFile(path);
      expect(r.format, SniffFormat.zip);
      expect(r.container, ContainerKind.ooxml);
      expect(r.isArchive, isFalse);
      // 后缀是 zip、真实是 zip，所以不算「后缀篡改」——
      // 是容器标记检测把它拦下来的，不是后缀比对。
      expect(r.isExtensionSpoofed, isFalse);
    });

    test('伪装成 .zip 的 APK 同样被识破', () async {
      final bytes = realZip({
        'AndroidManifest.xml': 'binary',
        'classes.dex': 'dex',
      });
      final path = writeTempFile(dir, 'release.zip', bytes);
      final r = await sniffFile(path);
      expect(r.container, ContainerKind.apk);
      expect(r.isArchive, isFalse);
    });

    test('需求 5：ZIP 改名成 .pdf → 报后缀篡改', () async {
      final path = writeTempFile(dir, '发票.pdf', realZip({'a.txt': 'hi'}));
      final r = await sniffFile(path);
      expect(r.format, SniffFormat.zip);
      expect(r.declaredExt, 'pdf');
      expect(r.isExtensionSpoofed, isTrue);
      expect(r.isArchive, isTrue);
    });

    test('需求 5 + SFX：MZ 壳包着 ZIP → 找到内嵌签名与 baseOffset', () async {
      final zip = realZip({'a.txt': 'hello'});
      const prefix = 2048;
      final path = writeTempFile(
        dir,
        'setup.exe',
        Uint8List.fromList([0x4D, 0x5A, ...List.filled(prefix - 2, 0), ...zip]),
      );

      final r = await sniffFile(path);
      expect(r.format, SniffFormat.zip);
      expect(r.confidence, SniffConfidence.medium);
      expect(r.baseOffset, prefix);
      expect(r.container, ContainerKind.none);
      expect(r.isArchive, isTrue);
    });

    test('需求 5：无 MZ 的前置数据 → 从尾部 EOCD 反推 baseOffset', () async {
      final zip = realZip({'a.txt': 'hello'});
      const prefix = 3000;
      // 前置数据是随机噪声且不以 MZ 开头，走 EOCD 回退那条路。
      final path = writeTempFile(
        dir,
        'mystery.bin',
        Uint8List.fromList([
          ...List.generate(prefix, (i) => (i * 131 + 7) % 256),
          ...zip,
        ]),
      );

      final r = await sniffFile(path);
      expect(r.format, SniffFormat.zip);
      expect(r.baseOffset, prefix);
      expect(r.isArchive, isTrue);
      expect(r.declaredExt, 'bin');
      expect(r.isExtensionSpoofed, isTrue);
    });

    test('随机二进制不会被误判成 ZIP', () async {
      final path = writeTempFile(
        dir,
        'noise.dat',
        List.generate(200000, (i) => (i * 37 + 11) % 256),
      );
      final r = await sniffFile(path);
      expect(r.format, SniffFormat.unknown);
      expect(r.isArchive, isFalse);
    });

    test('空文件 → unknown，不抛异常', () async {
      final path = writeTempFile(dir, 'zero.bin', <int>[]);
      final r = await sniffFile(path);
      expect(r.format, SniffFormat.unknown);
      expect(r.confidence, SniffConfidence.none);
    });

    test('7z 头文件按 7z 返回', () async {
      final path = writeTempFile(
        dir,
        'x.7z',
        [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C, ...List.filled(100, 0)],
      );
      final r = await sniffFile(path);
      expect(r.format, SniffFormat.sevenZ);
      expect(r.isArchive, isTrue);
    });

    test('文件不存在 → 抛 FileSystemException（由调用方计入 unreadable）',
        () async {
      await expectLater(
        sniffFile('${dir.path}/does_not_exist.zip'),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('declaredExt 显式传入时覆盖从路径推断的值', () async {
      final path = writeTempFile(dir, 'a.zip', realZip({'a.txt': 'hi'}));
      final r = await sniffFile(path, declaredExt: 'jpg');
      expect(r.declaredExt, 'jpg');
      expect(r.isExtensionSpoofed, isTrue);
    });
  });

  group('展示格式化', () {
    test('hexPreview：空格分隔的大写十六进制', () {
      expect(
        hexPreview([0x50, 0x4B, 0x03, 0x04]),
        '50 4B 03 04',
      );
    });

    test('hexPreview 截到 16 字节', () {
      expect(hexPreview(List.filled(40, 0xAB)).split(' ').length, 16);
    });

    test('hexWord：FormatDetectModal.fileHeader 的形状', () {
      expect(hexWord([0x50, 0x4B, 0x03, 0x04, 0x99]), '0x504B0304');
    });

    test('hexWord 不足 4 字节也不越界', () {
      expect(hexWord([0x1F, 0x8B]), '0x1F8B');
      expect(hexWord([]), '0x');
    });
  });
}
