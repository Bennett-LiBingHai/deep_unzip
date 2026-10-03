import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:deep_unzip/engine/zip_dir.dart';
import 'package:flutter_test/flutter_test.dart';

import 'zip_fixtures.dart';

void main() {
  group('findEndOfCentralDirectory（纯函数）', () {
    test('空缓冲区返回 null', () {
      expect(
        findEndOfCentralDirectory(Uint8List(0), tailFileOffset: 0, fileSize: 0),
        isNull,
      );
    });

    test('全是垃圾字节时不误报', () {
      final tail = Uint8List.fromList(List.filled(4096, 0xA5));
      expect(
        findEndOfCentralDirectory(tail, tailFileOffset: 0, fileSize: 4096),
        isNull,
      );
    });

    test('注释里恰好出现 EOCD 签名，不会抢在真 EOCD 前面', () {
      // 注释里塞一个假的 EOCD 签名，再往后塞点内容 —— 反向扫描会先撞上它。
      final comment = <int>[
        ...utf8.encode('comment with a fake sig '),
        ...le32(kEndOfCentralDirSignature),
        ...utf8.encode(' trailing'),
      ];
      final bytes = zipFromCentralDirectory(
        [cdRecord(name: 'a.txt')],
        comment: comment,
      );

      final eocd = findEndOfCentralDirectory(
        bytes,
        tailFileOffset: 0,
        fileSize: bytes.length,
      );
      expect(eocd, isNotNull);
      // 自洽性检查（签名位置 + 22 + 注释长度 == 文件长度）必须选中真的那个。
      expect(eocd!.commentLength, comment.length);
      expect(eocd.eocdFileOffset, bytes.length - 22 - comment.length);
    });

    test('注释长度对不上时不认（防假阳性）', () {
      final bytes = Uint8List.fromList([
        ...le32(kEndOfCentralDirSignature),
        ...Uint8List(16),
        0xFF, 0xFF, // 声称注释长 65535，但后面什么都没有
      ]);
      expect(
        findEndOfCentralDirectory(bytes, tailFileOffset: 0, fileSize: bytes.length),
        isNull,
      );
    });

    test('非 0 的 tailFileOffset 能让绝对偏移算对', () {
      final zip = zipFromCentralDirectory(
        [cdRecord(name: 'a.txt')],
        prefixLength: 100,
      );
      // 只喂最后 22 字节，模拟「第一级窗口只探到尾巴」。
      final tail = Uint8List.sublistView(zip, zip.length - 22);
      final eocd = findEndOfCentralDirectory(
        tail,
        tailFileOffset: zip.length - 22,
        fileSize: zip.length,
      );
      expect(eocd, isNotNull);
      expect(eocd!.archiveStartOffset, 100);
    });
  });

  group('parseCentralDirectory（纯函数）', () {
    test('解析基本字段', () {
      final cd = cdBytes([
        cdRecord(
          name: 'hello.txt',
          method: 8,
          crc: 0xDEADBEEF,
          compSize: 42,
          uncompSize: 100,
          localOffset: 7,
        ),
      ]);

      final entries = parseCentralDirectory(cd);
      expect(entries, hasLength(1));
      final e = entries.single;
      expect(e.name, 'hello.txt');
      expect(e.method, 8);
      expect(e.crc32, 0xDEADBEEF);
      expect(e.compressedSize, 42);
      expect(e.uncompressedSize, 100);
      expect(e.localHeaderOffset, 7);
      expect(e.isEncrypted, isFalse);
      expect(e.isAes, isFalse);
      expect(e.isDirectory, isFalse);
    });

    test('多条记录按顺序解析', () {
      final cd = cdBytes([
        cdRecord(name: 'a.txt'),
        cdRecord(name: 'b/c.txt'),
        cdRecord(name: 'd/'),
      ]);

      final entries = parseCentralDirectory(cd);
      expect(entries.map((e) => e.name).toList(), ['a.txt', 'b/c.txt', 'd/']);
      expect(entries.last.isDirectory, isTrue);
    });

    test('缓冲区被截断时丢掉最后一条不完整的，不抛异常', () {
      final full = cdBytes([
        cdRecord(name: 'a.txt'),
        cdRecord(name: 'b.txt'),
      ]);

      final truncated = Uint8List.sublistView(full, 0, full.length - 10);
      final entries = parseCentralDirectory(truncated);
      expect(entries.map((e) => e.name).toList(), ['a.txt']);
    });

    test('maxEntries 生效', () {
      final cd = cdBytes([
        for (var i = 0; i < 10; i++) cdRecord(name: 'f$i.txt'),
      ]);
      final entries = parseCentralDirectory(cd, maxEntries: 3);
      expect(entries, hasLength(3));
      expect(entries.last.name, 'f2.txt');
    });

    test('签名不对就停（不把垃圾当条目）', () {
      expect(parseCentralDirectory(Uint8List(200)), isEmpty);
    });

    test('ZipCrypto 加密标志', () {
      final cd = cdBytes([
        cdRecord(name: 'secret.txt', flags: kFlagEncrypted, method: 8),
      ]);
      final e = parseCentralDirectory(cd).single;
      expect(e.isEncrypted, isTrue);
      expect(e.isAes, isFalse);
    });

    test('AES 额外字段：拿回真实压缩算法与密钥强度', () {
      final cd = cdBytes([
        cdRecord(
          name: 'secret.txt',
          // ZIP 规范要求 AES 条目的 method 字段写 99。
          method: 99,
          flags: kFlagEncrypted,
          extra: aesExtra(strength: 3, method: 8),
        ),
      ]);

      final e = parseCentralDirectory(cd).single;
      expect(e.isEncrypted, isTrue);
      expect(e.isAes, isTrue);
      expect(e.aesStrength, 3);
      expect(e.aesKeyBits, 256);
      expect(e.aesSaltBytes, 16);
      // method 必须被 0x9901 里的真值覆盖，否则 P4 会拿 99 去选解码器。
      expect(e.method, 8);
    });

    test('AES 强度 1 → 128 位 / 8 字节 salt', () {
      final cd = cdBytes([
        cdRecord(
          name: 's.txt',
          method: 99,
          flags: kFlagEncrypted,
          extra: aesExtra(strength: 1, method: 12),
        ),
      ]);
      final e = parseCentralDirectory(cd).single;
      expect(e.aesKeyBits, 128);
      expect(e.aesSaltBytes, 8);
      expect(e.method, 12);
    });

    test('Zip64 额外字段补齐三个溢出的 32 位字段', () {
      const bigUncomp = 0x100000000; // 4 GiB
      const bigComp = 0x80000000;
      const bigOffset = 0x200000000;

      final cd = cdBytes([
        cdRecord(
          name: 'huge.bin',
          method: 8,
          compSize: 0xFFFFFFFF,
          uncompSize: 0xFFFFFFFF,
          localOffset: 0xFFFFFFFF,
          extra: zip64Extra(
            uncompSize: bigUncomp,
            compSize: bigComp,
            localOffset: bigOffset,
          ),
        ),
      ]);

      final e = parseCentralDirectory(cd).single;
      expect(e.uncompressedSize, bigUncomp);
      expect(e.compressedSize, bigComp);
      expect(e.localHeaderOffset, bigOffset);
    });

    test('Zip64 额外字段只放需要的那一段（规范 4.5.3）', () {
      // 只有 uncompSize 溢出，压缩大小与偏移都正常。
      final cd = cdBytes([
        cdRecord(
          name: 'a.bin',
          compSize: 999,
          uncompSize: 0xFFFFFFFF,
          localOffset: 12345,
          extra: zip64Extra(uncompSize: 0x100000000),
        ),
      ]);

      final e = parseCentralDirectory(cd).single;
      expect(e.uncompressedSize, 0x100000000);
      // 这两个不能被额外字段里并不存在的段污染。
      expect(e.compressedSize, 999);
      expect(e.localHeaderOffset, 12345);
    });

    test('额外字段长度自相矛盾时不做越界读', () {
      final bad = (BytesBuilder()
            ..add(le16(kExtraAes))
            ..add(le16(9999))) // 声称 9999 字节，实际什么都没有
          .toBytes();

      final cd = cdBytes([cdRecord(name: 'x.txt', extra: bad)]);

      final e = parseCentralDirectory(cd).single;
      expect(e.name, 'x.txt');
      expect(e.isAes, isFalse);
    });

    test('符号链接：Unix mode 高 16 位 S_IFLNK', () {
      final cd = cdBytes([
        cdRecord(name: 'link', externalAttrs: 0xA1FF << 16),
      ]);
      expect(parseCentralDirectory(cd).single.isSymlink, isTrue);
    });

    test('UTF-8 名字（位 11）', () {
      final cd = cdBytes([
        cdRecord(name: '中文名字.txt', flags: kFlagUtf8Name),
      ]);
      expect(parseCentralDirectory(cd).single.name, '中文名字.txt');
    });
  });

  group('readZipListing（读文件）', () {
    late Directory dir;
    setUp(() => dir = makeTempDir('zdi'));
    tearDown(() => dir.deleteSync(recursive: true));

    Future<ZipListing?> listingOf(String path) async {
      final file = File(path);
      final raf = await file.open();
      try {
        return await readZipListing(raf, fileSize: await file.length());
      } finally {
        await raf.close();
      }
    }

    test('ZipEncoder 造的真 zip 能读出来（交叉验证）', () async {
      final bytes = realZip({
        'a.txt': 'hello world',
        'dir/b.txt': 'x' * 5000,
      });
      final path = writeTempFile(dir, 'real.zip', bytes);

      final listing = await listingOf(path);
      expect(listing, isNotNull);
      expect(listing!.archiveStartOffset, 0);
      expect(listing.entryCount, 2);
      expect(
        listing.entries.map((e) => e.name).toSet(),
        {'a.txt', 'dir/b.txt'},
      );

      final b = listing.entries.firstWhere((e) => e.name == 'dir/b.txt');
      expect(b.uncompressedSize, 5000);
      expect(b.compressedSize, greaterThan(0));
      expect(b.isEncrypted, isFalse);
    });

    test('压缩包注释不影响定位', () async {
      final path = writeTempFile(dir, 'c.zip', realZip({'a.txt': 'hi'}));
      final listing = await listingOf(path);
      expect(listing, isNotNull);
      expect(listing!.entryCount, 1);
    });

    test('前置数据（SFX 壳）→ archiveStartOffset 正确', () async {
      final zip = realZip({'a.txt': 'hello'});
      const prefixLen = 4096;
      final spoofed = Uint8List.fromList([
        ...Uint8List(prefixLen),
        ...zip,
      ]);
      final path = writeTempFile(dir, 'sfx.exe', spoofed);

      final listing = await listingOf(path);
      expect(listing, isNotNull);
      expect(listing!.archiveStartOffset, prefixLen);
      expect(listing.entries.single.name, 'a.txt');
    });

    test('不是 zip 的文件返回 null，不抛异常', () async {
      final path = writeTempFile(
        dir,
        'random.bin',
        List.generate(100000, (i) => (i * 37) % 256),
      );
      expect(await listingOf(path), isNull);
    });

    test('空文件返回 null', () async {
      final path = writeTempFile(dir, 'empty.bin', <int>[]);
      expect(await listingOf(path), isNull);
    });

    test('只有 EOCD 的空归档', () async {
      final bytes = zipFromCentralDirectory(<Uint8List>[], forcedCount: 0);
      final path = writeTempFile(dir, 'empty.zip', bytes);

      final listing = await listingOf(path);
      expect(listing, isNotNull);
      expect(listing!.entryCount, 0);
      expect(listing.declaredEntryCount, 0);
      expect(listing.isTruncated, isFalse);
    });

    test('中央目录偏移被改成垃圾 → null（校验挡住）', () async {
      final bytes = zipFromCentralDirectory(
        [cdRecord(name: 'a.txt')],
        forcedCdOffset: 3,
      );
      final path = writeTempFile(dir, 'broken.zip', bytes);
      expect(await listingOf(path), isNull);
    });

    test('声明有条目但中央目录为空 → null（自相矛盾）', () async {
      final bytes = zipFromCentralDirectory(<Uint8List>[], forcedCount: 5);
      final path = writeTempFile(dir, 'liar.zip', bytes);
      expect(await listingOf(path), isNull);
    });

    test('isTruncated：条目数超过 maxEntries 时如实标记', () async {
      final cd = cdBytes([
        for (var i = 0; i < 50; i++) cdRecord(name: 'f$i.txt'),
      ]);
      final bytes = Uint8List.fromList([
        ...cd,
        ...eocdRecord(count: 50, cdSize: cd.length, cdOffset: 0),
      ]);
      final path = writeTempFile(dir, 'many.zip', bytes);

      final raf = await File(path).open();
      try {
        final listing = await readZipListing(
          raf,
          fileSize: bytes.length,
          maxEntries: 10,
        );
        expect(listing!.entryCount, 10);
        expect(listing.declaredEntryCount, 50);
        expect(listing.isTruncated, isTrue);
      } finally {
        await raf.close();
      }
    });
  });

  group('readFully', () {
    late Directory dir;
    setUp(() => dir = makeTempDir('rf'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('一次读满大文件', () async {
      final path = writeTempFile(
        dir,
        'big.bin',
        List.generate(300000, (i) => i % 256),
      );
      final raf = await File(path).open();
      try {
        final b = await readFully(raf, 0, 300000);
        expect(b.length, 300000);
        expect(b[0], 0);
        expect(b[299999], 299999 % 256);
      } finally {
        await raf.close();
      }
    });

    test('请求超出文件尾 → 返回实际读到的部分', () async {
      final path = writeTempFile(dir, 'small.bin', [1, 2, 3]);
      final raf = await File(path).open();
      try {
        expect((await readFully(raf, 0, 100)).length, 3);
      } finally {
        await raf.close();
      }
    });

    test('length 为 0 或负数 → 空', () async {
      final path = writeTempFile(dir, 'x.bin', [1, 2, 3]);
      final raf = await File(path).open();
      try {
        expect(await readFully(raf, 0, 0), isEmpty);
        expect(await readFully(raf, 0, -5), isEmpty);
      } finally {
        await raf.close();
      }
    });
  });
}
