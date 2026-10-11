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

// ---------------------------------------------------------------------------
// 「图片后面追加压缩包」的夹具
// ---------------------------------------------------------------------------
//
// 7z / RAR5 / RAR4 的签名都在偏移 0，所以这些夹具**故意**把签名垫在一段
// 「像图片的前置数据」后面，逼着 `sniffFile` 走那条「向前搜签名 + 块头 CRC
// 校验」的新路。
//
// CRC 用本文件自己的一份表算，**不复用被测代码里的那份** —— 复用的话，我要是
// 把规则记错了，夹具就照着错的规则造，两边一起绿、真样本照样认不出。这里独立
// 算一遍，才让「夹具」与「实现」互相印证。

Uint32List? _fixtureCrcTable;

Uint32List get _fixtureCrc => _fixtureCrcTable ??= () {
      final t = Uint32List(256);
      for (var i = 0; i < 256; i++) {
        var c = i;
        for (var k = 0; k < 8; k++) {
          c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
        }
        t[i] = c;
      }
      return t;
    }();

/// 标准 CRC32（多项式 0xEDB88320），覆盖 `[start, end)`。
int fixtureCrc32(List<int> b, int start, int end) {
  final t = _fixtureCrc;
  var crc = 0xFFFFFFFF;
  for (var i = start; i < end; i++) {
    crc = t[(crc ^ b[i]) & 0xFF] ^ (crc >> 8);
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

/// 一段「像图片」的前置数据：PNG 签名 + 填充。
///
/// 填充刻意**避开 0**，也避开任何签名的首字节序列 —— 全 0 的字节在 `_scanWindow`
/// 与深探测里都可能撞上别的判据，那种夹具测出来的不是我们想测的东西。
List<int> imagePrefix(int length) {
  final b = List<int>.filled(length, 0);
  if (length >= 8) {
    b.setRange(0, 8, [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  }
  for (var i = 8; i < length; i++) {
    b[i] = (i * 37 + 11) & 0xFF;
  }
  return b;
}

/// 7z 签名头 32 字节：`sig6 + ver2 + StartHeaderCRC4 + StartHeader20`，
/// CRC 按 `7zIn.cpp` 的 `TestStartCrc` 算（覆盖 12..31 那 20 字节）。
List<int> sevenZBlock() {
  final b = List<int>.filled(32, 0);
  b.setRange(0, 6, [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]);
  b[7] = 4; // version minor；major 是 0
  // StartHeader 的内容本身随便填 —— 校验只看 CRC。
  for (var i = 12; i < 32; i++) {
    b[i] = 0x40 + i;
  }
  b.setRange(8, 12, le32(fixtureCrc32(b, 12, 32)));
  return b;
}

/// RAR5：marker 8 字节 + 块头 —— 4 字节 CRC32，再是块长的 vint，再是块体。
///
/// 块长取最小合法值 2（`Rar5Handler.cpp` 的 `size < 2` 会拒），块体写成
/// 「归档主头」：type=1、flags=0。
List<int> rar5Block() {
  const marker = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00];
  final head = [0x02, 0x01, 0x00]; // 单字节 vint(2) + 2 字节块体
  return [...marker, ...le32(fixtureCrc32(head, 0, head.length)), ...head];
}

/// RAR4：marker 7 字节 + 13 字节主头（`kArchiveHeaderSize`）。
///
/// 头里前 2 字节存的是 CRC32 的低 16 位，覆盖 `[2, 13)`；`h[2]` 是块类型，
/// 合法值 0x73（`NBlockType::kArchiveHeader`）。[type] 用来造反例。
List<int> rar4Block({int type = 0x73}) {
  const marker = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00];
  final h = List<int>.filled(13, 0);
  h[2] = type;
  h[5] = 13; // blockSize 低字节；高字节留 0
  for (var i = 7; i < 13; i++) {
    h[i] = i;
  }
  final crc = fixtureCrc32(h, 2, 13) & 0xFFFF;
  h[0] = crc & 0xFF;
  h[1] = (crc >> 8) & 0xFF;
  return [...marker, ...h];
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

    // ---- 软件包 / 光盘与磁盘映像那一批（2026-10 补）-----------------------
    //
    // 每一串都照 7-Zip 自己的 `REGISTER_ARC_I`（各 `*Handler.cpp` 的
    // `k_Signature`）抄。这里**逐格式单独断言**，不写成一个循环：哪个签名抄
    // 错了，失败信息要能直接指到是哪个格式。

    test('WIM / RPM / AR / XAR', () {
      expectFormat([0x4D, 0x53, 0x57, 0x49, 0x4D, 0, 0, 0], SniffFormat.wim);
      expectFormat([0xED, 0xAB, 0xEE, 0xDB], SniffFormat.rpm);
      expectFormat(
        [0x21, 0x3C, 0x61, 0x72, 0x63, 0x68, 0x3E, 0x0A],
        SniffFormat.ar,
      );
      expectFormat([0x78, 0x61, 0x72, 0x21, 0x00], SniffFormat.xar);
    });

    test('CHM 与 LIT 都归 chm', () {
      expectFormat(
        [0x49, 0x54, 0x53, 0x46, 3, 0, 0, 0, 0x60, 0, 0, 0],
        SniffFormat.chm,
      );
      expectFormat(
        [0x49, 0x54, 0x4F, 0x4C, 0x49, 0x54, 0x4C, 0x53, 1, 0, 0, 0, 0x28, 0, 0, 0],
        SniffFormat.chm,
      );
    });

    test('SquashFS 四种写法', () {
      for (final magic in ['hsqs', 'sqsh', 'shsq', 'qshs']) {
        expectFormat(magic.codeUnits, SniffFormat.squashfs);
      }
    });

    test('QCOW / VMDK / VHD / VHDX / Android Sparse', () {
      expectFormat([0x51, 0x46, 0x49, 0xFB, 0, 0, 0], SniffFormat.qcow);
      expectFormat([0x4B, 0x44, 0x4D, 0x56], SniffFormat.vmdk);
      expectFormat('conectix'.codeUnits + [0, 0], SniffFormat.vhd);
      expectFormat('vhdxfile'.codeUnits, SniffFormat.vhdx);
      expectFormat([0x3A, 0xFF, 0x26, 0xED, 1, 0], SniffFormat.sparse);
    });

    test('PPMd / SZDD / Unix compress', () {
      expectFormat([0x8F, 0xAF, 0xAC, 0x84], SniffFormat.ppmd);
      expectFormat(
        [0x53, 0x5A, 0x44, 0x44, 0x88, 0xF0, 0x27, 0x33, 0x41],
        SniffFormat.mslz,
      );
      expectFormat([0x1F, 0x9D], SniffFormat.z);
    });

    test('固定偏移的：CramFS 在 16、VDI 在 0x40、NTFS 在 3', () {
      expectFormat('Compressed ROMFS'.codeUnits, SniffFormat.cramfs, at: 16);
      expectFormat([0x7F, 0x10, 0xDA, 0xBE], SniffFormat.vdi, at: 0x40);
      expectFormat('NTFS    '.codeUnits + [0], SniffFormat.ntfs, at: 3);
    });

    test('偏移上的签名放到偏移 0 不算数', () {
      // `Compressed ROMFS` 在偏移 0 不是 cramfs —— 位置也是判据的一部分，
      // 否则任何文本文件里的一句话都会把它判成映像。
      expectFormat('Compressed ROMFS'.codeUnits, SniffFormat.unknown);
      expectFormat('NTFS    '.codeUnits + [0], SniffFormat.unknown);
    });

    test('新收的那批置信度：偏移 0 且够长 → high；2 字节与固定偏移 → medium', () {
      SniffConfidence conf(List<int> magic, {int at = 0}) =>
          sniffHeadBytes(head(magic, at: at)).confidence;
      expect(conf([0xED, 0xAB, 0xEE, 0xDB]), SniffConfidence.high);
      expect(conf([0x1F, 0x9D]), SniffConfidence.medium);
      expect(conf('Compressed ROMFS'.codeUnits, at: 16), SniffConfidence.medium);
      expect(conf([0x7F, 0x10, 0xDA, 0xBE], at: 0x40), SniffConfidence.medium);
    });

    test('老签名不被新签名抢走', () {
      // 新表排在最后，且 `1F 9D`（compress）与 `1F 8B`（gzip）只差第二个字节。
      expectFormat([0x1F, 0x8B], SniffFormat.gzip);
      expectFormat([0x50, 0x4B, 0x03, 0x04], SniffFormat.zip);
      expectFormat([0x75, 0x73, 0x74, 0x61, 0x72], SniffFormat.tar, at: 257);
    });

    test('新格式的后缀判定：官方认的后缀放行，别的才算篡改', () {
      SniffResult r(SniffFormat f, String ext) => SniffResult(
            format: f,
            confidence: SniffConfidence.high,
            declaredExt: ext,
          );
      expect(r(SniffFormat.iso, 'iso').isExtensionSpoofed, isFalse);
      expect(r(SniffFormat.iso, 'img').isExtensionSpoofed, isFalse,
          reason: '`img` 是各家映像工具共用的通名');
      expect(r(SniffFormat.ar, 'deb').isExtensionSpoofed, isFalse);
      expect(r(SniffFormat.wim, 'esd').isExtensionSpoofed, isFalse);
      expect(r(SniffFormat.qcow, 'qcow2').isExtensionSpoofed, isFalse);
      expect(r(SniffFormat.iso, 'zip').isExtensionSpoofed, isTrue,
          reason: 'ISO 披着 .zip —— 这才是该弹窗问一句的');
      expect(r(SniffFormat.rpm, 'png').isExtensionSpoofed, isTrue);
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

    // ---- 头窗口之外的两处：ISO / UDF 的卷描述符，DMG 的文件尾页脚 ----------
    //
    // 这两个必须用**真文件**测：它们的全部意义就是「头 512 字节里什么都看不出来」，
    // 纯函数那一层（`matchVolumeDescriptor` / `matchDmgTrailer`）只能证明字节判对了，
    // 证明不了 `sniffFile` 真的去读了那两个位置。

    List<int> blob(int length, void Function(List<int> b) poke) {
      final b = List<int>.filled(length, 0);
      poke(b);
      return b;
    }

    test('ISO：头窗口全是引导码，0x8000 处的 CD001 才是证据', () async {
      final bytes = blob(0x8000 + 4096, (b) {
        // 头 512 字节塞满非零垃圾（混合 ISO 的 MBR 引导码），确保它不会被
        // 头窗口里任何一条签名撞上。
        for (var i = 0; i < 512; i++) {
          b[i] = 0xEB;
        }
        b.setRange(0x8000, 0x8006, [1, 0x43, 0x44, 0x30, 0x30, 0x31]);
      });
      final path = writeTempFile(dir, 'disc.iso', bytes);

      final r = await sniffFile(path);
      expect(r.format, SniffFormat.iso);
      expect(r.isArchive, isTrue);
      expect(r.isExtensionSpoofed, isFalse);
    });

    test('ISO 改了后缀照样认出来 —— 这是需求 5 在映像上的样子', () async {
      final bytes = blob(0x8000 + 64, (b) {
        b.setRange(0x8000, 0x8006, [1, 0x43, 0x44, 0x30, 0x30, 0x31]);
      });
      final r = await sniffFile(writeTempFile(dir, 'photo.jpg', bytes));
      expect(r.format, SniffFormat.iso);
      expect(r.isExtensionSpoofed, isTrue);
    });

    test('纯 UDF（没有 ISO 桥）：BEA01', () async {
      final bytes = blob(0x8000 + 64, (b) {
        b.setRange(0x8000, 0x8008, [0, 0x42, 0x45, 0x41, 0x30, 0x31, 1, 0]);
      });
      final r = await sniffFile(writeTempFile(dir, 'x.udf', bytes));
      expect(r.format, SniffFormat.udf);
    });

    test('0x8000 处只有 CD001 的后五个字节、没有类型字节 1 → 不认', () async {
      final bytes = blob(0x8000 + 64, (b) {
        b.setRange(0x8000, 0x8006, [0, 0x43, 0x44, 0x30, 0x30, 0x31]);
      });
      final r = await sniffFile(writeTempFile(dir, 'x.bin', bytes));
      expect(r.format, SniffFormat.unknown,
          reason: '类型字节也是签名的一部分（7-Zip 就是整串比的）');
    });

    test('文件不足 0x8008 字节 → 不去读那个位置，也不越界', () async {
      final r = await sniffFile(writeTempFile(dir, 'tiny.iso', [1, 2, 3]));
      expect(r.format, SniffFormat.unknown);
    });

    test('DMG：签名在文件尾 512 字节页脚的开头', () async {
      final bytes = blob(8192, (b) {
        b.setRange(8192 - 512, 8192 - 512 + 12,
            [0x6B, 0x6F, 0x6C, 0x79, 0, 0, 0, 4, 0, 0, 2, 0]);
      });
      final r = await sniffFile(writeTempFile(dir, 'app.dmg', bytes));
      expect(r.format, SniffFormat.dmg);
      expect(r.isExtensionSpoofed, isFalse);
    });

    test('DMG：只有 koly 四个字母、后面对不上 → 不认', () async {
      // 文件尾碰巧出现四个字母并不罕见，所以签名取的是完整的 12 字节。
      final bytes = blob(8192, (b) {
        b.setRange(8192 - 512, 8192 - 512 + 4, [0x6B, 0x6F, 0x6C, 0x79]);
      });
      final r = await sniffFile(writeTempFile(dir, 'x.dat', bytes));
      expect(r.format, SniffFormat.unknown);
    });

    test('深探测排在 ZIP 之后：ZIP 里恰好带着 CD001 也还是 ZIP', () async {
      // 头窗口先认出 ZIP，根本走不到深探测 —— 这条钉住「深探测只给认不出的」。
      final zip = realZip({'a.txt': 'hi'});
      final padded = [...zip, ...List<int>.filled(0x9000, 0)];
      padded.setRange(0x8000, 0x8006, [1, 0x43, 0x44, 0x30, 0x30, 0x31]);
      final r = await sniffFile(writeTempFile(dir, 'a.zip', padded));
      expect(r.format, SniffFormat.zip);
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

    // ---- 第 4 级：向前搜「图片等文件后面追加的压缩包」 --------------------

    test('PNG 后面追加 RAR5 → 认出 rar5、high、baseOffset 指向追加点', () async {
      const prefix = 9000;
      final path = writeTempFile(
        dir,
        '提弗炸卸_差分.png',
        [...imagePrefix(prefix), ...rar5Block()],
      );

      final r = await sniffFile(path);
      expect(r.format, SniffFormat.rar5);
      expect(r.confidence, SniffConfidence.high,
          reason: '块头 CRC 验过的，比 MZ 那条裸搜的 medium 强');
      expect(r.baseOffset, prefix);
      expect(r.isArchive, isTrue);
      expect(r.declaredExt, 'png');
      expect(r.isExtensionSpoofed, isTrue, reason: '这顺带点亮伪后缀弹窗');
    });

    test('PNG 后面追加 7z → 认出 sevenZ', () async {
      const prefix = 7000;
      final path = writeTempFile(
        dir,
        'photo.jpg',
        [...imagePrefix(prefix), ...sevenZBlock()],
      );

      final r = await sniffFile(path);
      expect(r.format, SniffFormat.sevenZ);
      expect(r.confidence, SniffConfidence.high);
      expect(r.baseOffset, prefix);
      expect(r.isArchive, isTrue);
      expect(r.isExtensionSpoofed, isTrue);
    });

    test('追加点在窗口之外 → 认不出；把窗口调大 → 认得出', () async {
      const window = 1024;
      const prefix = window + 512; // 追加点落在窗口外
      final path = writeTempFile(
        dir,
        'over_window.png',
        [...imagePrefix(prefix), ...rar5Block()],
      );

      final miss = await sniffFile(path, windowBytes: window);
      expect(miss.format, SniffFormat.unknown,
          reason: '窗口只读到 $window 字节，追加点在 $prefix');

      final hit = await sniffFile(path, windowBytes: prefix + 64);
      expect(hit.format, SniffFormat.rar5);
      expect(hit.baseOffset, prefix);
    });

    test('伪造的签名（块头 CRC 对不上）不误判', () async {
      // 裸搜一个 1 MB 窗口必然撞上这两串字节；能挡住它们的只有块头校验。
      final fake7z = [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C, ...List.filled(64, 0xEE)];
      final fakeRar5 = [
        0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00, ...List.filled(64, 0xEE),
      ];
      final path = writeTempFile(
        dir,
        'noise.png',
        [...imagePrefix(8000), ...fake7z, ...fakeRar5],
      );

      final r = await sniffFile(path);
      expect(r.format, SniffFormat.unknown,
          reason: '签名只是候选，块头 CRC 才是判据');
      expect(r.isArchive, isFalse);
    });

    test('RAR4 主头（我们自算的 CRC16）→ 认出 rar4', () async {
      const prefix = 6000;
      final path = writeTempFile(
        dir,
        'x.png',
        [...imagePrefix(prefix), ...rar4Block()],
      );

      final r = await sniffFile(path);
      expect(r.format, SniffFormat.rar4);
      expect(r.confidence, SniffConfidence.high);
      expect(r.baseOffset, prefix);
      // 如实说明：本机造不出真 RAR4 样本（RAR 7 没有 -ma4），这条是
      // 「我们的编码器 ↔ 我们的校验器」自洽，不是对厂商样本的验证。
    });

    test('RAR4 块类型不是 0x73 → 认不出（CRC 本身是对的）', () async {
      final path = writeTempFile(
        dir,
        'x2.png',
        [...imagePrefix(6000), ...rar4Block(type: 0x74)],
      );
      final r = await sniffFile(path);
      expect(r.format, SniffFormat.unknown,
          reason: '类型字节先于 CRC 被检查，这条把那个检查单独钉住');
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
