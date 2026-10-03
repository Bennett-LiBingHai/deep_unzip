/// 原生后端：把 `package:deep_unzip_engine` 那套 C ABI 接到引擎自己的类型上。
///
/// ## 为什么要这一层，而不是让 worker 直接用插件
///
/// 1. **错误分类只在这一处**。插件的 `DuzEngineException(code, message)` 是
///    原生视角的；上层要的是「这属于密码问题吗 / 值不值得换下一个候选密码」。
///    翻译集中在这里，别处不必认识 `DUZ_ERR_*`。
/// 2. **换后端时改动收敛**。桌面/测试环境将来会有一个纯 Dart 的
///    `dart_zip_backend`（`package:archive`），它们共用这套入口签名。
/// 3. **`engine/` 里只有本文件 import 插件包**。这和 `models.dart` 顶上那条
///    「除 native_backend 外不得 import package:flutter」是同一条纪律的延伸：
///    依赖外部世界的口子越少越好，而这个口子本来就无法避免。
///
/// ## 阻塞警告
///
/// 本文件两个函数都会**阻塞调用它的 isolate**（原生侧同步跑完整个解压）。
/// 只能在 worker isolate 里调，绝不要在 UI isolate 调。
library;

import 'dart:io';

import 'package:deep_unzip_engine/deep_unzip_engine.dart' as engine;

import '../models.dart';
import '../protocol.dart';

/// 一个归档的概览，给「先看要不要密码」这类判断用。
class ArchivePeek {
  const ArchivePeek({
    required this.entryCount,
    required this.unpackedBytes,
    required this.hasEncryptedEntries,
    required this.engineVersion,
  });

  final int entryCount;
  final int unpackedBytes;

  /// 有加密条目 —— 决定要不要去密码库里试。注意：**为 false 也不代表
  /// 不用密码**，归档头整体加密（7z 常见）的包在这里根本打不开。
  final bool hasEncryptedEntries;

  final String engineVersion;
}

/// 打开归档看一眼中央目录，不解压任何数据。
///
/// 打不开就抛 [EngineException]（`code` 已翻译成 `DUZ_ERR_*`）。
ArchivePeek peekArchive(List<String> parts, {String? password}) {
  final a = _open(parts, password);
  try {
    return ArchivePeek(
      entryCount: a.entries.length,
      unpackedBytes: a.unpackedSize,
      hasEncryptedEntries: a.hasEncryptedEntries,
      engineVersion: a.version,
    );
  } finally {
    a.close();
  }
}

/// 解压 [parts]（顺序已定）到 [outDir]。
///
/// [outDir] 不存在时会被创建 —— 原生侧只往里写、不建目录，而调用方
/// （递归解压里算出来的输出路径）往往还没建。
///
/// [onTick] 每次原生报进度就调一次，**不做合并也不做节流**：合并是 worker
/// 的职责（它有那个时间预算），节流是主 isolate 的职责（它知道 UI 频率）。
/// 本层如实转发。
///
/// [shouldCancel] 每次报进度时问一次，返回 true 即中止并抛 [EngineException]。
/// **注意它同步执行在同一线程上**，所以实现必须是纯内存判断 —— 在这里 await
/// 什么或者等另一个 isolate 回消息，会把解压卡死。
ExtractOutcome extractArchive({
  required List<String> parts,
  required String outDir,
  String? password,
  void Function(ExtractTick tick)? onTick,
  bool Function()? shouldCancel,
}) {
  final dir = Directory(outDir);
  if (!dir.existsSync()) dir.createSync(recursive: true);

  final a = _open(parts, password);
  final watch = Stopwatch()..start();
  try {
    String last = '';
    a.extractAll(
      outDir,
      onProgress: (done, total, name) {
        if (name != null) last = name;
        onTick?.call(
          ExtractTick(doneBytes: done, totalBytes: total, current: last),
        );
        return !(shouldCancel?.call() ?? false);
      },
    );
    return ExtractOutcome(
      outDir: outDir,
      entryCount: a.entries.length,
      unpackedBytes: a.unpackedSize,
      elapsed: watch.elapsed,
    );
  } on engine.DuzEngineException catch (e) {
    throw _translate(e);
  } finally {
    a.close();
  }
}

// ---------------------------------------------------------------------------
// 内部
// ---------------------------------------------------------------------------

engine.DuzArchive _open(List<String> parts, String? password) {
  try {
    return engine.DuzArchive.open(parts, password: password);
  } on engine.DuzEngineException catch (e) {
    throw _translate(e);
  }
}

/// 插件错误 → 引擎错误。
///
/// `code` 原样带过去（两边都是 `DUZ_ERR_*` 的整数），文案补一句「该怎么办」：
/// 原生那边的文案是给人看的事实描述，这里加上的是策略建议。
///
/// switch 用的是 [DuzErrorCode] 而不是插件自己的常量 —— `engine/` 里只认
/// 那套镜像，插件常量仅在本文件出现。两边数值一致由
/// `test/engine/error_codes_test.dart` 保证。
EngineException _translate(engine.DuzEngineException e) {
  final hint = switch (e.code) {
    DuzErrorCode.password => '（归档需要密码，或给的密码不对）',
    DuzErrorCode.unsupported => '（本构建未编入 7-Zip 核心，或格式不被支持）',
    DuzErrorCode.noMem => '（内存不足）',
    DuzErrorCode.arg => '（参数非法）',
    _ => '',
  };
  return EngineException('${e.message}$hint', code: e.code);
}
