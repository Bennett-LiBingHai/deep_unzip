/// 查一个路径所在卷还剩多少字节。
///
/// ## 为什么非走原生
///
/// `dart:io` **没有**任何查询剩余空间的 API —— `File.lengthSync()` 是文件大小，
/// `FileStat` 里也没有卷信息。能落地的只有两条：读 `statvfs`（我们自己那个
/// `.so` 里加个导出函数），或者问系统（这条）。选了后者，理由是它同时满足
/// 「不动 C++」和「能在本机测」：探针可以注入假通道，整条链路（含弹窗）
/// 在 `flutter_test` 里就能跑完。
///
/// ## 为什么返回 `int?` 而不是 `int`
///
/// 量不到的情况有一堆而且都很正常：非 Android、通道没注册（热重载中途、
/// 桌面目标）、路径不可达。把它们压成 `0` 是**灾难性**的 —— 「剩余 0 字节」
/// 会让每一个包都被判为装不下。所以量不到一律 `null`，语义是「不知道」，
/// 调用方据此**跳过**空间检查。与 `native_backend._bytesOnDisk` 量不到就返回
/// 0（表示未知）是同一条原则：量不出来的东西不能拿来当判据。
library;

import 'dart:io';

import 'package:flutter/services.dart';

import 'file_manager_bridge.dart' show kFileManagerChannel;

/// 通道名与 `file_manager_bridge` 共用一条 —— 它们都是「宿主 Activity 提供的
/// 系统能力」，没有理由拆成两条。方法名不同就够了。
class DiskSpaceProbe {
  /// [channel] 与 [isAndroid] 只给测试注入用。生产代码一律用默认值。
  DiskSpaceProbe({MethodChannel? channel, bool? isAndroid})
      : _channel = channel ?? const MethodChannel(kFileManagerChannel),
        _isAndroid = isAndroid ?? Platform.isAndroid;

  final MethodChannel _channel;
  final bool _isAndroid;

  /// [path] 所在卷的剩余字节数；量不到返回 null。
  ///
  /// [path] 可以**还不存在** —— 闸门刻意排在建输出目录之前，原生侧会向上找
  /// 最近的已存在祖先再量。所以这里不做任何存在性检查。
  Future<int?> availableBytes(String path) async {
    if (path.isEmpty) return null;
    if (!_isAndroid) return null;
    try {
      final bytes = await _channel.invokeMethod<int>(
        'freeSpace',
        <String, Object?>{'path': path},
      );
      // 负数是不可能的，真收到说明原生那边算错了 —— 当未知处理，别拿它去拦。
      if (bytes == null || bytes < 0) return null;
      return bytes;
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}
