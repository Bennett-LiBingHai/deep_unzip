import '../engine/models.dart';
import '../models/extractor.dart';

/// 设置页「支持的格式」清单 —— **照着嗅探表与引擎真实做的事写**。
///
/// ## 「支持」的意思
///
/// 扫描时嗅探认得出（`engine/sniff.dart`），并且内置的 7-Zip 核心打得开。引擎
/// 打开时不限格式，真正的闸门是嗅探表 —— 所以这张表与 [SniffFormat] 必须一一
/// 对上，`test/data/builtin_extractors_test.dart` 用机器判据钉着这一点：嗅探表
/// 里加了格式而这里漏了，测试直接红。
///
/// ## 这张表从前在撒谎
///
/// 旧版六条里有四条写着 `unzip -o {file} -d {dir}`、`unrar x -y`、`tar -xzf`
/// 这类外部命令。**这个 app 从头到尾没执行过它们**：解压只有一条路，走 FFI 调
/// 内置的 7-Zip 核心。识别那一栏也写歪了 —— `TAR.GZ` 配的判据是 `1F 8B`，那是
/// **GZIP** 的签名。
///
/// ## 刻意没收的
///
/// 7-Zip 核心里还编进了一批**没有可靠签名**的东西，它们能被引擎打开，但嗅探
/// 认不出，所以扫描时不会列出来：FAT / MBR / GPT / ext / HFS / APFS 这类裸分区
/// 与卷（签名只有 2 字节且在文件深处，收了会把一大批不相干的文件当压缩包）、
/// Base64 / Intel HEX / 裸 LZMA（根本没有签名）、PE / ELF / Mach-O（可执行文件）、
/// NSIS 安装包、SWF、FLV、OLE 复合文档（`.doc` / `.xls` / `.msi`）。
///
/// ## 分卷为什么只在两条上写
///
/// 任何格式都能按 `*.001` 裸切分（`split.dart` 的 rawSplit 家族，判据只是
/// `名字 + .数字`），所以不抄到每一行。只写**格式特有**的命名。
///
/// ## 一条已知缺口
///
/// Info-ZIP 跨卷（`x.z01`… + `x.zip`）**能被识别、能被分组**，但它到底能不能解
/// 出来，**没有验证过**：本机造不出真样本。所以那一行写「未验证」而不是
/// 「不支持」—— 两边都是我不敢替用户拍的板。
class BuiltinExtractors {
  static const String _core = '内置 7-Zip 核心';

  /// 分类顺序：压缩包 → 压缩流 → 软件包 → 光盘 / 磁盘映像。
  static const List<Extractor> all = [
    // ---- 压缩包 ----
    Extractor(
      name: 'ZIP',
      tag: 'ZIP',
      formats: {SniffFormat.zip},
      detectLogic: '文件头 50 4B 03 04；空归档 / 跨卷标记 50 4B 05 06 · 50 4B 07 08',
      extractLogic: _core,
      split: '*.zip.001 起；*.z01 + *.zip（未验证）',
    ),
    Extractor(
      name: 'RAR',
      tag: 'RAR',
      formats: {SniffFormat.rar4, SniffFormat.rar5},
      detectLogic: '文件头 52 61 72 21 1A 07 00；RAR5 多一个字节 01 00',
      extractLogic: _core,
      split: '*.part1.rar / *.part01.rar；旧式 *.rar + *.r00',
    ),
    Extractor(
      name: '7-Zip',
      tag: '7Z',
      formats: {SniffFormat.sevenZ},
      detectLogic: '文件头 37 7A BC AF 27 1C',
      extractLogic: _core,
    ),
    Extractor(
      name: 'TAR',
      tag: 'TAR',
      formats: {SniffFormat.tar},
      detectLogic: '偏移 257 处的 ustar',
      extractLogic: _core,
    ),
    Extractor(
      name: 'CAB',
      tag: 'CAB',
      formats: {SniffFormat.cab},
      detectLogic: '文件头 4D 53 43 46（MSCF）',
      extractLogic: _core,
    ),
    Extractor(
      name: 'LHA',
      tag: 'LHA',
      formats: {SniffFormat.lzh},
      detectLogic: '偏移 2 起为 -lh（如 -lh5-）',
      extractLogic: _core,
    ),
    Extractor(
      name: 'ARJ',
      tag: 'ARJ',
      formats: {SniffFormat.arj},
      detectLogic: '文件头 60 EA',
      extractLogic: _core,
    ),
    Extractor(
      name: 'CPIO',
      tag: 'CPI',
      formats: {SniffFormat.cpio},
      detectLogic: '文件头 070707 / 070701，或二进制变体 C7 71',
      extractLogic: _core,
    ),
    // ---- 压缩流 ----
    Extractor(
      name: 'GZIP',
      tag: 'GZ',
      formats: {SniffFormat.gzip},
      detectLogic: '文件头 1F 8B',
      extractLogic: _core,
    ),
    Extractor(
      name: 'BZIP2',
      tag: 'BZ2',
      formats: {SniffFormat.bzip2},
      detectLogic: '文件头 42 5A 68（BZh）',
      extractLogic: _core,
    ),
    Extractor(
      name: 'XZ',
      tag: 'XZ',
      formats: {SniffFormat.xz},
      detectLogic: '文件头 FD 37 7A 58 5A 00',
      extractLogic: _core,
    ),
    Extractor(
      name: 'ZSTD',
      tag: 'ZST',
      formats: {SniffFormat.zstd},
      detectLogic: '文件头 28 B5 2F FD',
      extractLogic: _core,
    ),
    Extractor(
      name: 'Unix compress',
      tag: 'Z',
      formats: {SniffFormat.z},
      detectLogic: '文件头 1F 9D',
      extractLogic: _core,
    ),
    Extractor(
      name: 'PPMd',
      tag: 'PMD',
      formats: {SniffFormat.ppmd},
      detectLogic: '文件头 8F AF AC 84',
      extractLogic: _core,
    ),
    Extractor(
      name: 'MS 压缩（SZDD）',
      tag: 'SZD',
      formats: {SniffFormat.mslz},
      detectLogic: '文件头 53 5A 44 44 88 F0 27 33 41（SZDD）',
      extractLogic: _core,
    ),
    // ---- 软件包 / 文档包 ----
    Extractor(
      name: 'RPM',
      tag: 'RPM',
      formats: {SniffFormat.rpm},
      detectLogic: '文件头 ED AB EE DB',
      extractLogic: _core,
    ),
    Extractor(
      name: 'AR / DEB',
      tag: 'AR',
      formats: {SniffFormat.ar},
      detectLogic: '文件头 !<arch>\\n（21 3C 61 72 63 68 3E 0A）',
      extractLogic: _core,
    ),
    Extractor(
      name: 'XAR',
      tag: 'XAR',
      formats: {SniffFormat.xar},
      detectLogic: '文件头 78 61 72 21 00（xar!）',
      extractLogic: _core,
    ),
    Extractor(
      name: 'CHM / LIT',
      tag: 'CHM',
      formats: {SniffFormat.chm},
      detectLogic: '文件头 ITSF（CHM），或 ITOLITLS（LIT）',
      extractLogic: _core,
    ),
    Extractor(
      name: 'WIM',
      tag: 'WIM',
      formats: {SniffFormat.wim},
      detectLogic: '文件头 4D 53 57 49 4D 00 00 00（MSWIM）',
      extractLogic: _core,
    ),
    // ---- 光盘 / 磁盘映像 ----
    Extractor(
      name: 'ISO',
      tag: 'ISO',
      formats: {SniffFormat.iso},
      detectLogic: '偏移 0x8000 处 01 43 44 30 30 31（CD001）',
      extractLogic: _core,
    ),
    Extractor(
      name: 'UDF',
      tag: 'UDF',
      formats: {SniffFormat.udf},
      detectLogic: '偏移 0x8000 处 00 42 45 41 30 31 01 00（BEA01）',
      extractLogic: _core,
    ),
    Extractor(
      name: 'DMG',
      tag: 'DMG',
      formats: {SniffFormat.dmg},
      detectLogic: '文件尾 512 字节页脚开头 6B 6F 6C 79（koly）',
      extractLogic: _core,
    ),
    Extractor(
      name: 'SquashFS',
      tag: 'SQF',
      formats: {SniffFormat.squashfs},
      detectLogic: '文件头 hsqs / sqsh / shsq / qshs 之一',
      extractLogic: _core,
    ),
    Extractor(
      name: 'CramFS',
      tag: 'CRF',
      formats: {SniffFormat.cramfs},
      detectLogic: '偏移 16 处 Compressed ROMFS',
      extractLogic: _core,
    ),
    Extractor(
      name: 'QCOW',
      tag: 'QCW',
      formats: {SniffFormat.qcow},
      detectLogic: '文件头 51 46 49 FB 00 00 00（QFI）',
      extractLogic: _core,
    ),
    Extractor(
      name: 'VDI',
      tag: 'VDI',
      formats: {SniffFormat.vdi},
      detectLogic: '偏移 0x40 处 7F 10 DA BE',
      extractLogic: _core,
    ),
    Extractor(
      name: 'VMDK',
      tag: 'VMK',
      formats: {SniffFormat.vmdk},
      detectLogic: '文件头 4B 44 4D 56（KDMV）',
      extractLogic: _core,
    ),
    Extractor(
      name: 'VHD',
      tag: 'VHD',
      formats: {SniffFormat.vhd},
      detectLogic: '文件头 conectix（动态盘；固定盘只有文件尾页脚，不识别）',
      extractLogic: _core,
    ),
    Extractor(
      name: 'VHDX',
      tag: 'VHX',
      formats: {SniffFormat.vhdx},
      detectLogic: '文件头 76 68 64 78 66 69 6C 65（vhdxfile）',
      extractLogic: _core,
    ),
    Extractor(
      name: 'Android Sparse',
      tag: 'SPR',
      formats: {SniffFormat.sparse},
      detectLogic: '文件头 3A FF 26 ED 01 00',
      extractLogic: _core,
    ),
    Extractor(
      name: 'NTFS 卷',
      tag: 'NTF',
      formats: {SniffFormat.ntfs},
      detectLogic: '偏移 3 处 NTFS 加四个空格',
      extractLogic: _core,
    ),
  ];
}
