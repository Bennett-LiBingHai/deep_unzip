/// [probeEncrypted] 的宿主机安全性与格式闸。
///
/// 这个探针**只在 Android 上真的能答出话来** —— 宿主机上 `dlopen` 拿不到
/// `libdeep_unzip_engine.so`。所以这里能测的不是「答案对不对」，而是两条
/// 更要紧的：
///
/// 1. **它永不抛异常**。扫描跑在 worker isolate 里，探针一抛就把整次扫描带
///    下水；而在 `flutter test` 里扫描是**真的会跑**的（真实 IO + 真实
///    worker），所以这条不成立的话整个 widget 测试套件都会跟着红。
/// 2. **它只问该问的格式**。ZIP 的加密位由嗅探侧白捡，tar/gz/xz 这些压根
///    没有加密的概念 —— 为它们去开归档是白花的时间。
library;

import 'package:deep_unzip/engine/backends/native_backend.dart';
import 'package:deep_unzip/engine/models.dart';
import 'package:flutter_test/flutter_test.dart';

/// 一个不存在的路径就够：格式闸要是漏了，下面这些调用会真的去 `dlopen`。
const List<String> _whatever = ['/nowhere/locked.7z'];

void main() {
  group('probeEncrypted：格式闸', () {
    test('ZIP 不问 —— 加密位在中央目录里白捡', () {
      expect(probeEncrypted(_whatever, SniffFormat.zip), isNull);
    });

    test('没有加密概念的格式一概不问', () {
      for (final f in [
        SniffFormat.tar,
        SniffFormat.gzip,
        SniffFormat.bzip2,
        SniffFormat.xz,
        SniffFormat.zstd,
        SniffFormat.cab,
        SniffFormat.unknown,
      ]) {
        expect(probeEncrypted(_whatever, f), isNull, reason: '$f 不该被问');
      }
    });

    test('7z 与 RAR4/RAR5 在闸里 —— 它们真的会去开归档', () {
      // 闸内 = 走到引擎；宿主机上引擎加载不了，结果仍是 null，但**不是**
      // 被格式闸挡回来的。这里只断言「没抛」这一条，因为「有没有真的试」在
      // 宿主机上无从观测 —— 而下一条测试正靠这一点保证宿主机的安全。
      for (final f in [SniffFormat.sevenZ, SniffFormat.rar4, SniffFormat.rar5]) {
        expect(() => probeEncrypted(_whatever, f), returnsNormally);
      }
    });
  });

  test('引擎加载不了（宿主机 / 未编入）时回 null，绝不抛出去', () {
    // 这条就是「widget 测试套件没被这个探针打挂」的凭据：同一台 Windows 上，
    // 扫描会走到这里。抛出去的话整次扫描会变成 EvFailed。
    bool? result;
    expect(() => result = probeEncrypted(_whatever, SniffFormat.sevenZ),
        returnsNormally);
    expect(result, isNull);
  });
}
