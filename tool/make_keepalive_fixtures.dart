// 生成真机「保活」验收用的夹具。
//
// 目标不是验证某个功能对不对，而是造一个**足够久的解压批次**：锁屏之后回来时
// 它还得在跑（或刚好跑完），才能说明前台服务真的把进程保住了。几 MB 的普通
// 压缩包在真机上不到一秒就解完，锁屏还没锁上就结束了 —— 那样什么都验不出来。
//
// ## 为什么用「条目极多」而不是「字节极大」
//
// 真机上解压的代价主要在**每个条目一次 open/write/close**（/sdcard 走
// /dev/fuse，比裸文件系统慢得多），而字节数受推送时间与设备空间两头夹着：
// 想把时间拉到分钟级得几个 GB。条目数则便宜得多 —— 这个配方（每条 200 字节
// 全 'A'）就是 `tool/make_slow_fixture.dart` 里验证过的那个。
//
// ## 每个包造多大：有实测的账，别拍脑袋
//
// 真机上量到的是**约 6~10 毫秒/条目**（10 万条的包跑了十几分钟；同一台机器上
// 原生 `toybox tar` 解 1 万个小文件是 2m47s，比我们还慢 —— 时间全花在 FUSE 的
// 往返上，不是引擎慢）。所以：
//
//   **1 万条 ≈ 2.5~3 分钟。**
//
// 上一版这里是 10 万条（十几分钟）。真机验收时没人跑得完 —— 锁屏几分钟回来
// 都还在解，验「通知里的百分比有没有往前走」根本不需要那么长。
//
// ## 产物（build/devfix/ka/）
//
//   quick/1_small.zip      3 个文件，几毫秒。先跑它确认流程与权限弹窗。
//   long/1_long.zip        1 万条（约 2.5~3 分钟）。单独一个长包，锁屏靠它。
//   batch/m1..m6.zip       各 2 千条（每个约 40 秒）。6 个包的一批，整批约 4 分钟，
//                          用来验「第几个/共几个」在通知里跟着走。
//
// 用法：dart run tool/make_keepalive_fixtures.dart
import 'dart:io';

import 'package:archive/archive.dart';

/// 条目内容。200 字节全 'A'，deflate 之后约 15 字节 —— 压缩比 13:1，
/// 离炸弹闸门那条 1000:1 差得远，不会自找麻烦。
final List<int> _payload = List<int>.filled(200, 0x41);

/// 造一个 [count] 条目的包，每个子目录 [perDir] 个文件。
///
/// 分目录是必须的：把 10 万个文件平铺进一个目录，解压时那一个目录的目录项
/// 会大到让 FUSE 侧每次 lookup 都变慢，测出来的就不是我们自己的速度了。
Archive manyArchive(int count, {int perDir = 200}) {
  final archive = Archive();
  for (var i = 0; i < count; i++) {
    final dir = (i ~/ perDir).toString().padLeft(4, '0');
    final idx = (i % perDir).toString().padLeft(4, '0');
    archive.addFile(ArchiveFile('d$dir/f$idx.txt', _payload.length, _payload));
  }
  return archive;
}

void write(String path, List<int> bytes) {
  final f = File(path);
  f.parent.createSync(recursive: true);
  f.writeAsBytesSync(bytes);
  stdout.writeln('  $path  ${bytes.length ~/ 1024} KB');
}

void main() {
  const root = 'build/devfix/ka';
  final sw = Stopwatch()..start();

  stdout.writeln('quick/');
  write('$root/quick/1_small.zip', ZipEncoder().encode(Archive()
    ..addFile(ArchiveFile.string('a.txt', 'hello'))
    ..addFile(ArchiveFile.string('sub/b.txt', 'world'))
    ..addFile(ArchiveFile.string('sub/c.txt', 'deep unzip'))));

  stdout.writeln('long/（1 万条，约 2.5~3 分钟）');
  write('$root/long/1_long.zip', ZipEncoder().encode(manyArchive(10000, perDir: 200)));

  stdout.writeln('batch/（6 × 2 千条，整批约 4 分钟）');
  for (var i = 1; i <= 6; i++) {
    write('$root/batch/m$i.zip', ZipEncoder().encode(manyArchive(2000, perDir: 100)));
  }

  stdout.writeln('共 ${sw.elapsed.inSeconds}s');
}
