// 生成一个「条目极多」的 zip，用来在真机上造一个能持续几秒的解压批次。
//
// 为什么需要它：主按钮那颗「停止解压」的粒度是「当前压缩包解完之后」，而
// 普通的几 MB 压缩包在真机上不到一秒就解完了，根本来不及点。条目数比字节数
// 更能拖时间 —— 每个条目都要开文件、写、关文件，2 万个就是 2 万次系统调用。
//
// 用法：dart run tool/make_slow_fixture.dart
import 'dart:io';

import 'package:archive/archive.dart';

void main() {
  final archive = Archive();
  final payload = List<int>.filled(200, 0x41); // 'A'
  for (var d = 0; d < 200; d++) {
    for (var i = 0; i < 100; i++) {
      final name = 'd${d.toString().padLeft(3, '0')}'
          '/f${i.toString().padLeft(4, '0')}.txt';
      archive.addFile(ArchiveFile(name, payload.length, payload));
    }
  }

  final bytes = ZipEncoder().encode(archive);
  final out = File('build/devfix/1_many.zip');
  out.parent.createSync(recursive: true);
  out.writeAsBytesSync(bytes);
  stdout.writeln('${out.path} ${bytes.length}');
}
