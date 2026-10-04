/// 生成**压缩比**那一条闸门的真机夹具。
///
/// ## 为什么单独一个工具
///
/// 其他夹具（`make_fixtures.dart` / `make_evil_fixtures.dart`）造出来的包，
/// 撞的是条目数、单文件、总量那几条 —— 它们的判据是「声明值 vs 阈值」，
/// 随便一个正常尺寸的包把阈值调小就能撞上。
///
/// 比值这条不行，它多了**一道地板**：
///
/// ```dart
/// if (p.compressedBytes > 0 && p.unpackedBytes >= limits.ratioFloorBytes) { ... }
/// ```
///
/// 地板以下整条检查**直接跳过**，跟 `maxRatio` 设成多少没关系。而地板是
/// [LimitThresholds.ratioFloorBytes]，**不在** `LimitField` 里 —— 设置页上
/// 看不到、也改不了。于是就有了这么个现象：把「压缩比上限」调到 1，拿手边
/// 任何一个包去试，什么都不发生，看着像功能坏了。其实是被地板挡住了。
///
/// 所以这个夹具的存在意义就一个：**让解压后的字节数越过地板**。越过之后
/// 比值检查才会真正跑起来，`maxRatio` 才第一次说话。
///
/// ## 地板有多高，以及 DEFLATE 的天花板
///
/// | 档位 | `maxRatio` | `ratioFloorBytes` | 这个夹具能不能撞上 |
/// |---|---|---|---|
/// | 宽松 | 5000 | 8 GiB | **不能** —— 见下 |
/// | 标准 | 1000 | 1 GiB | 要 ≥1 GiB 解压量，过了地板也只有 **2.7%** 余量 |
/// | 严格 | 200 | 128 MiB | 能，5 倍余量，默认大小就是冲着它来的 |
///
/// 还要知道 DEFLATE 自己的上限：最长匹配 258 字节、最近距离 1，所以一串
/// 相同字节**最多**压到约 **1027:1**（实测值，见下面「编码级别」那节），
/// 再高不可能。这带来两个不太好看的结论：
///
/// - 「宽松」档的 `maxRatio = 5000` 对任何 ZIP 都**物理上不可达** —— 那一行
///   永远不会触发。想验它，只能拿 7z/RAR 这类别的编码器，或者把值调下来。
/// - 「标准」档的 1000 只剩 2.7% 余量，只有近乎纯零的包才碰得到。真实文件
///   （文本 ~5:1、可执行文件 ~3:1）离它十万八千里。
///
/// 也就是说：**比值这条检查只在「人造的、近乎纯零的包」上才可能响** ——
/// 而那恰好就是压缩炸弹的形态，所以这个设计不算错，但「宽松」那一档是死的。
/// 这一点值得单独知道，别把它当成夹具的问题。
///
/// ## 编码级别（踩过的坑）
///
/// `ZipEncoder.encode` 的 `level` **默认是 `DeflateLevel.bestSpeed`（1）**，
/// 不是文档里那种「默认中等」。同一个 512 MiB 全零包，实测：
///
/// | level | 落盘 | 比值 |
/// |---|---|---|
/// | 1（默认） | 2288 KB | **229:1** |
/// | 6 / 9 | 510 KB | **1027:1** |
///
/// 差 4.5 倍。按默认值生成的话，夹具在严格档（200）上只剩 14% 余量 ——
/// 数值随编码器版本一抖就可能掉到线下，白忙一场。所以这里**必须**显式传
/// `bestCompression`，而且下面那条自检就是在钉这件事。
///
/// ## 零是怎么造的，以及为什么不会吃满内存
///
/// 全部 8 个条目**共用同一个 64 MiB 的零缓冲区**。`ZipEncoder` 是逐条目读
/// 内容、用完就往下走，不会回头改，所以别名是安全的。峰值内存是 64 MiB，
/// 不是 512 MiB。省下来的空间全在夹具文件里：解压后 512 MiB，落盘约 500 KB。
///
/// 用法：
/// ```
/// dart run tool/make_ratio_bomb.dart                    # build/fixtures_ratio
/// dart run tool/make_ratio_bomb.dart <输出目录>
/// dart run tool/make_ratio_bomb.dart <输出目录> <MiB>   # 默认 512
/// ```
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:deep_unzip/engine/limits.dart';
import 'package:path/path.dart' as p;

/// 单个条目的原始大小。够大才压得出高比值，又不至于让生成过程吃内存。
const int _chunkBytes = 64 << 20; // 64 MiB

void main(List<String> args) {
  final root = args.isNotEmpty ? args[0] : p.join('build', 'fixtures_ratio');
  final totalMib = args.length > 1 ? int.parse(args[1]) : 512;
  final totalBytes = totalMib << 20;

  if (totalBytes % _chunkBytes != 0) {
    stderr.writeln('总大小要是 ${_chunkBytes >> 20} MiB 的整数倍，'
        '否则最后一个条目会碎掉、比值也跟着变。');
    exitCode = 2;
    return;
  }
  final entryCount = totalBytes ~/ _chunkBytes;

  // 共用一份零缓冲区，见文件头的说明。
  final zeros = Uint8List(_chunkBytes);
  final archive = Archive();
  for (var i = 0; i < entryCount; i++) {
    // 条目名要有区分度：全同名的话有些解码器会当成重复条目。
    archive.addFile(ArchiveFile('zeros_$i.bin', zeros.length, zeros));
  }

  // `level` 必须显式给：默认是 `bestSpeed`，比值会从 1027:1 掉到 229:1，
  // 严格档上只剩 14% 余量。见文件头「编码级别」那节。
  final bytes = Uint8List.fromList(
    ZipEncoder().encode(archive, level: DeflateLevel.bestCompression),
  );
  final ratio = totalBytes ~/ bytes.length;

  stdout.writeln('解压后  $totalMib MiB（$entryCount 个条目 × '
      '${_chunkBytes >> 20} MiB 全零）');
  stdout.writeln('落盘    ${(bytes.length / 1024).toStringAsFixed(1)} KB');
  stdout.writeln('实测比  $ratio:1');

  // ---------------------------------------------------------------------
  // 自检
  //
  // 走 `make_fixtures.dart` 定下的规矩：**夹具得自己证明它能撞上闸门**，
  // 不能只生成了事。一个「造出来却撞不上」的炸弹，在真机上就是又一次假绿
  // —— 用户老老实实照文档操作，什么都没发生，然后以为是功能坏了。
  //
  // 判据用**真的** `checkArchiveLimits`，不是这里另写一套阈值比较：要验的
  // 恰恰是「这个夹具撞不撞得上真的那道闸门」。两边各写一套的话，闸门改了
  // 夹具不会红。
  // ---------------------------------------------------------------------

  // 先验夹具本身是不是它自称的那个东西。编码器写歪了（比如内部转成了
  // store 不压缩）的话，下面「撞上了」那条会以「比值 1:1」这种形式失败，
  // 但报出来的原因会指向闸门，误导人。
  final decoded = ZipDecoder().decodeBytes(bytes);
  final decodedTotal =
      decoded.files.fold<int>(0, (sum, f) => sum + f.size);
  if (decodedTotal != totalBytes) {
    throw StateError('解出来是 $decodedTotal 字节，不是 $totalBytes —— '
        '夹具没造对，别往下走。');
  }
  final first = decoded.files.first.content as List<int>;
  if (first.any((b) => b != 0)) {
    throw StateError('第一个条目里出现了非零字节 —— 它不全是零，'
        '压缩比当然也就不是预期那个数。');
  }
  // 解完就放手，别让它一直占着 512 MiB。
  decoded.clear();

  final profile = ArchiveProfile(
    entryCount: entryCount,
    unpackedBytes: totalBytes,
    largestEntryBytes: _chunkBytes,
    compressedBytes: bytes.length,
  );

  // 逐档报「这道闸门会怎么说」，同时把判据挂在严格档上 —— 那是这个夹具的
  // 指定目标（默认 512 MiB 只为严格档留了 4 倍余量，见文件头）。
  stdout.writeln('');
  stdout.writeln('各档判定：');
  for (final preset in kLimitPresets) {
    final breach = checkArchiveLimits(profile, limits: preset.thresholds);
    final verdict = switch (breach?.kind) {
      LimitKind.ratio => '撞上比值 ✓',
      LimitKind.entryCount => '先被条目数拦下',
      LimitKind.entrySize => '先被单文件拦下',
      LimitKind.totalSize => '先被总量拦下',
      LimitKind.diskSpace => '先被空间拦下',
      null => '没有拦住 ✗',
    };
    stdout.writeln('  ${preset.label.padRight(4)} $verdict');
  }

  final strict = checkArchiveLimits(profile, limits: LimitThresholds.strict);
  if (strict?.kind != LimitKind.ratio) {
    throw StateError(
      '这个夹具在**严格**档下撞的居然是 ${strict?.kind ?? "没有"}，不是比值。'
      '夹具没用 —— 它根本验不到那条闸门。改大小或改条目数，别改这条断言。',
    );
  }

  // 光「撞上了」还不够：`level` 掉回默认值（bestSpeed）时比值是 229:1，
  // 照样 > 200、上面那条断言照样绿 —— 但余量只剩 14%，夹具脆得没意义。
  // 所以再钉一道余量：至少是严格档阈值的 3 倍。掉回 bestSpeed 会立刻在这里红。
  final minRatio = LimitThresholds.strict.maxRatio * 3;
  if (ratio < minRatio) {
    throw StateError(
      '比值只有 $ratio:1，低于 $minRatio:1 这条底线。多半是 `level` 没传 —— '
      '`ZipEncoder.encode` 默认是 bestSpeed，会把这个夹具压回 229:1。',
    );
  }

  final dir = Directory(root);
  if (dir.existsSync()) dir.deleteSync(recursive: true);
  dir.createSync(recursive: true);
  final out = File(p.join(root, 'bomb.zip'));
  out.writeAsBytesSync(bytes);

  stdout.writeln('');
  stdout.writeln('已写出 ${out.absolute.path}');
  stdout.writeln('严格档下会弹：${strict!.message}');
}
