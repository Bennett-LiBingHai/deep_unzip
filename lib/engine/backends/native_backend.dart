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
/// ## 长任务警告
///
/// 本文件的函数都是**长任务**，该在 worker isolate 里调。但它们**不阻塞**
/// 调用方的 isolate：[extractArchive] 是异步的，原生侧的解压跑在 C++ 自己的
/// 线程上，这里只是轮询取进度（见 `packages/deep_unzip_engine` 顶上那段线程约定）。
/// 换句话说，worker 在解压期间照样能收命令 —— 「解压中途取消」就是这么成立的。
///
/// 唯一的例外是 [peekArchive] / [probeEncrypted]：`duz_open` 仍是同步的，
/// 但那是列中央目录级的活，不减压。
library;

import 'dart:io';

import 'package:deep_unzip_engine/deep_unzip_engine.dart' as engine;

import '../limits.dart';
import '../models.dart';
import '../output_cleanup.dart';
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

/// 扫描期的加密探针，喂给 `scanner.dart` 的 `EncryptedProbe`。
///
/// ## 为什么只有 7z 与 RAR 走这里
///
/// ZIP **不用问**：它的通用位就摊在中央目录的每条条目上，而扫描期为了认容器
/// 格式**已经在读**那份条目录了，加密位是白捡的（见 `sniff.dart` 的
/// `_withContainer`）。
///
/// 7z 与 RAR 则**没有**随手可读的加密位：7z 的头自己可能就被 LZMA 压着，
/// RAR 的头部块要过 CRC 才算得上数。纯 Dart 去认等于手搓半个解析器，而手写
/// 解析器在这个仓库里已经翻过一次车（`tool/make_password_fixtures.py` 里那套
/// 自己写的 ZipCrypto）。所以这两种老实开一次归档问引擎 —— 代价是每见到一个
/// 7z/RAR 就多一次 `duz_open`，但那本来就是列条目级的活，不减压。
///
/// 底下那个格式判断是**策略，不是机制**。机制上这条路对谁都成立：加密位来自
/// 每个条目的 `kpidEncrypted`（见 `duz_engine.cpp` 的 `duz_list`），那是引擎
/// 的通用属性，ZIP/7z/RAR/CAB… 谁实现了谁有。闸只开给 7z 与 RAR，是因为
/// **别的格式没验过** —— CAB 与 LZH 规范上也能带密码，但引擎报不报得出加密位、
/// 报出来准不准，这一格没有夹具可造（本机没有 CAB 写入器），也没在真机上见过
/// 一个加密 CAB。没验过就先不标：标错的代价是用户看着「需密码」去解压、结果
/// 根本不问密码；不标的代价只是少一个角标。要扩就是往上面那个条件里加格式，
/// 但加之前先拿一个真的加密夹具把这两件事都验过。
///
/// ## 绝不把异常抛出去
///
/// 答不出来时回 `null`（「不知道」），扫描照常继续：**一个包的加密探测失败不该
/// 把整次扫描带下水**。上层也只认 `true`（`scanner.dart` 的 `_flagsFor` 只在
/// `encrypted == true` 时打标），所以这里含糊一点是安全的，撒谎才危险。
///
/// 同步的 —— 原生 `peekArchive` 本来就是同步的，探针签名也是同步的。别在这里
/// await：扫描期每条目 await 一次会把并发扫描的节奏全打乱。
bool? probeEncrypted(List<String> parts, SniffFormat format) {
  // `rar4` / `rar5` 是两套头结构，但「要不要密码」这一问两边走的是同一条路。
  if (format != SniffFormat.sevenZ &&
      format != SniffFormat.rar4 &&
      format != SniffFormat.rar5) {
    return null;
  }
  if (_engineUnusable) return null;
  try {
    return peekArchive(parts).hasEncryptedEntries;
  } on EngineException catch (e) {
    if (e.code == DuzErrorCode.password) {
      // 归档头整体加密时**连打开都打不开**，而那正是「要密码」最硬的证据：
      // 这种包连条目清单都给不出来。见 `duz_engine.cpp` 的
      // `DescribeOpenFailure` —— 它把 `PasswordWasAsked ||
      // kpv_ErrorFlags_EncryptedHeadersError` 映射成 `DUZ_ERR_PASSWORD`。
      return true;
    }
    // `unsupported` = 这个构建压根没编入引擎（宿主机上跑扫描就是这种）。那
    // 是**整趟**都不成立的前提，记下来别再试；而「包坏了 / 格式不认识」是
    // **这个包**自己的问题，别的包照样值得一问，所以不能复用那个结论。
    if (e.code == DuzErrorCode.unsupported) _engineUnusable = true;
    return null;
  } catch (_) {
    // 引擎整个加载不了 —— 宿主机上跑 `flutter test` 就是这种情况，Windows 没有
    // `libdeep_unzip_engine.so`。置位后这一趟里其余的包就不再白试一遍。
    _engineUnusable = true;
    return null;
  }
}

/// 原生库加载不了时置位，见 [probeEncrypted]。
///
/// 只在 worker isolate 里活 —— 扫描就是在那儿跑的，跨 isolate 也不需要共享。
bool _engineUnusable = false;

/// 解压 [parts]（顺序已定）到 [outDir]。
///
/// [outDir] 不存在时会被创建 —— 原生侧只往里写、不建目录，而调用方
/// （递归解压里算出来的输出路径）往往还没建。
///
/// [onTick] 每轮轮询就调一次，**不做合并也不做节流**：合并是 worker 的职责
/// （它有那个时间预算），节流是主 isolate 的职责（它知道 UI 频率）。本层如实转发。
///
/// [shouldCancel] 每轮轮询问一次，返回 true 即向原生侧送一次取消、并在解压
/// unwind 之后**正常返回**一个 `cancelled: true` 的 [ExtractOutcome] —— 取消
/// **不是**异常（用户按的是「停止」）。实现必须是**纯内存判断**：它跑在 worker
/// isolate 的事件循环上，在这里 await 什么只会把下一轮轮询推后，进而推迟取消
/// 生效的时刻。
///
/// [availableBytes] 是目标卷的剩余字节数，由主 isolate 量好传进来（这一层
/// 跑在 worker isolate，够不着平台通道）。`null` = 量不到 → 跳过空间检查。
Future<ExtractOutcome> extractArchive({
  required List<String> parts,
  required String outDir,
  String? password,
  void Function(ExtractTick tick)? onTick,
  bool Function()? shouldCancel,
  LimitThresholds limits = LimitThresholds.standard,
  int? availableBytes,
}) async {
  // 顺序是刻意的：**先开归档、过闸门，再建输出目录**。
  //
  // 反过来（先建目录再开）会在炸弹被拒时留下一个空目录 —— 用户看到的是
  // 「多出来一个空文件夹」，而日志说那个包被放弃了。而且那道闸门本来就是
  // 「一个字节都还没写」的时刻，建目录算第一次落盘，不该在它前面。
  final a = _open(parts, password);
  final watch = Stopwatch()..start();
  try {
    final breach = checkArchiveLimits(
      _profileOf(a, parts),
      limits: limits,
      availableBytes: availableBytes,
    );
    if (breach != null) {
      // 抛的是 EngineException 而不是原生码：这条判定整个住在 Dart 侧，
      // 原生根本不知道「炸弹」这回事。详见 EngineException.breach 的说明。
      throw EngineException(breach.message, breach: breach);
    }

    final dir = Directory(outDir);
    // **建目录之前**先量出「这次解压可能新建哪些层」的上界：取消时要靠它把
    // 空目录收干净，又绝不能把用户早先就有的目录一起收掉。见 output_cleanup.dart。
    final boundary = existingBoundary(dir);
    if (boundary != dir.path) dir.createSync(recursive: true);

    String last = '';
    // 取消**不是**异常：`extractAll` 在被中止时正常返回，这里如实把 `cancelled`
    // 报上去。谁是「用户按了停止」谁是「这个包坏了」，上层靠它分。
    //
    // 这个 bool **取自原生侧的快照**，不是「我们请求过取消」—— 请求取消的那一刻
    // 包可能刚好解完了，那种情况该记成功。见 `DuzArchive.extractAll` 的说明。
    final cancelled = await a.extractAll(
      outDir,
      onProgress: (done, total, name) {
        if (name != null) last = name;
        onTick?.call(
          ExtractTick(doneBytes: done, totalBytes: total, current: last),
        );
        // 返回 false = 请求取消；原生侧在下一个进度点 unwind。
        return !(shouldCancel?.call() ?? false);
      },
    );
    // 被中止时把这次新建、又什么都没留下的空目录收掉 —— 原生侧只管删那个
    // 写了一半的**文件**，目录是这一层建的，也该由这一层收。见 output_cleanup.dart。
    if (cancelled) pruneCreatedDirs(dir, boundary);
    return ExtractOutcome(
      outDir: outDir,
      entryCount: a.entries.length,
      unpackedBytes: a.unpackedSize,
      elapsed: watch.elapsed,
      cancelled: cancelled,
    );
  } on engine.DuzEngineException catch (e) {
    throw _translate(e);
  } finally {
    a.close();
  }
}

/// 把已打开的归档量成一个 [ArchiveProfile]。
///
/// 量磁盘那一步（[ArchiveProfile.compressedBytes]）有几个刻意的取舍：
///
/// - **量的是分卷在磁盘上的字节数之和**，不是压缩流本身的长度。对单卷就是文件
///   大小，对分卷是各卷之和，正是「这个包占了用户多少空间」。
/// - **不减 `baseOffset`**。SFX 或带前置数据的包，其前置部分（最多 1 MiB）
///   算进了分母，让比值偏小一点点 —— 偏保守的方向，宁可漏判不可误判。
/// - 任一卷量不到（`lengthSync` 抛）就当**未知**（0），整条比值检查跳过。
///   量不出来的东西不能拿来当判据。
ArchiveProfile _profileOf(engine.DuzArchive a, List<String> parts) {
  // 数条目那半交给 limits.dart 的纯函数 —— 它能在 `flutter_test` 里被喂数字
  // 单测，而这里（要碰真实归档与磁盘）不能。本函数只剩量磁盘这一件事。
  return ArchiveProfile.fromEntries(
    entries: a.entries.map((e) => (size: e.size, isDir: e.isDir)),
    compressedBytes: _bytesOnDisk(parts),
  );
}

/// 这些分卷在磁盘上一共占多少字节。任一卷量不到就返回 0（= 未知）。
int _bytesOnDisk(List<String> parts) {
  var total = 0;
  for (final p in parts) {
    try {
      total += File(p).lengthSync();
    } on FileSystemException {
      return 0;
    }
  }
  return total;
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
    // 分不清的那一档（7z 的内容加密、RAR3）不能说成「密码不对」—— 那是把
    // 我们并不知道的事说成结论。原生文案本来就写着「或加密数据已损坏」，
    // 这里只把「分不出来」这层补上。
    DuzErrorCode.password => e.uncertain
        ? '（可能密码错误，也可能加密数据已损坏，两者无法区分）'
        : '（归档需要密码，或密码错误）',
    DuzErrorCode.unsupported => '（本构建未编入 7-Zip 核心，或格式不被支持）',
    DuzErrorCode.noMem => '（内存不足）',
    DuzErrorCode.arg => '（参数无效）',
    _ => '',
  };
  return EngineException('${e.message}$hint',
      code: e.code, uncertain: e.uncertain);
}
