/// DeepUnzip 引擎的 Dart 封装 —— 对 `src/duz_engine.h` 那套 C ABI 的安全包装。
///
/// ## 分两层
///
/// - `deep_unzip_engine_bindings_generated.dart`（ffigen 生成）是**机械**绑定：
///   裸指针进、裸指针出，不懂所有权。
/// - 本文件是**语义**层：管内存、把 UTF-8 指针变成 Dart `String`、把错误码
///   变成异常、把轮询出来的字节数变成 Dart 闭包的一次调用。
///
/// 上层（`lib/engine/backends/native_backend.dart`）只该用本文件，不该直接碰
/// 生成的那层 —— 否则所有权规则（谁分配谁释放、哪个指针活多久）会散落各处。
///
/// ## 线程
///
/// **原生侧永不回调 Dart。** 解压走的是「C++ 起自己的线程干活 + Dart 轮询取
/// 快照」：`duz_extract_start` 立刻返回，这里用一个 `await` 的轮询循环
/// （[kExtractPollInterval]）取进度、送取消。
///
/// 这不是风格选择，是硬约束换来的：以前进度是 `NativeCallable.isolateLocal`
/// 回调，而 7-Zip 的多线程解码路径会从**它自己 `pthread_create` 出来的线程**上
/// 调 `ICompressProgressInfo` —— 从别的线程调 isolateLocal 回调会让 Dart VM
/// 直接 `FATAL("Cannot invoke native callback outside an isolate.")`、进程消失
/// （2026-10-10 真机实测，见 `src/duz_engine.h` 顶上那段线程约定）。
///
/// 所以 [DuzArchive.extractAll] 现在**不阻塞**调用它的 isolate。它仍然是个长
/// 任务，仍然该放在 worker isolate 里，但那是为了别让 UI 排队等它，而不是因为
/// 它会把事件循环堵死。
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'deep_unzip_engine_bindings_generated.dart';

// 只放出错误码常量。**不** export 那层生成绑定：它是实现细节，上层要用的是
// 本文件的 DuzArchive / DuzEntry。
export 'deep_unzip_engine_bindings_generated.dart'
    show
        DUZ_OK,
        DUZ_ERR_OPEN,
        DUZ_ERR_PASSWORD,
        DUZ_ERR_UNSUPPORTED,
        DUZ_ERR_ARG,
        DUZ_ERR_EXTRACT,
        DUZ_ERR_NOMEM;

const String _libName = 'deep_unzip_engine';

DynamicLibrary _openLibrary() {
  final String name;
  if (Platform.isAndroid || Platform.isLinux) {
    name = 'lib$_libName.so';
  } else if (Platform.isWindows) {
    name = '$_libName.dll';
  } else if (Platform.isMacOS || Platform.isIOS) {
    name = '$_libName.framework/$_libName';
  } else {
    throw UnsupportedError('不支持的平台：${Platform.operatingSystem}');
  }
  try {
    return DynamicLibrary.open(name);
  } on ArgumentError catch (e) {
    // 默认的报错是「Failed to load dynamic library 'libxxx.so'」，不说为什么。
    // 最常见的两个原因是：非 Android 构建走的是骨架 .so（那是预期内的），
    // 以及加固把符号表抽了（见计划 9.3）。这里把话说明白。
    throw DuzEngineException(
      DUZ_ERR_UNSUPPORTED,
      '无法加载原生引擎 $name：${e.message}',
    );
  }
}

/// 惰性加载：只有真正用到引擎时才去 dlopen，纯 Dart 的单测不会被它绊住。
final DeepUnzipEngineBindings _b = DeepUnzipEngineBindings(_openLibrary());

/// 引擎调用失败。[code] 是 `DUZ_ERR_*`。
///
/// 上层靠 [code] 决定策略（换密码重试 / 跳过这个包 / 报错），
/// [message] 只适合展示。
class DuzEngineException implements Exception {
  const DuzEngineException(this.code, this.message, {this.uncertain = false});

  final int code;
  final String message;

  /// 这次失败**说不清**是密码不对还是数据已损坏（见 `duz_last_error_uncertain`）。
  ///
  /// **它不是路由键**：策略仍然只看 [code]，`isPasswordError` 也不看它。有它没它
  /// 都一样要换下一个候选密码、一样要弹密码窗 —— 它只让上层的说法别在一个我们
  /// 并不知道的事实上替用户下结论。
  final bool uncertain;

  /// 归档头加密且密码不对 —— 换个候选密码重试 `DuzArchive.open` 就有意义。
  bool get isPasswordError => code == DUZ_ERR_PASSWORD;

  /// 本平台没编 7-Zip 核心（非 Android 的骨架实现）。
  bool get isUnsupported => code == DUZ_ERR_UNSUPPORTED;

  @override
  String toString() => 'DuzEngineException($code): $message';
}

/// 归档内的一条。字段是 [DuzArchive.entries] 那一刻从原生内存**拷贝**出来的，
/// 之后原生的数组和 ctx 再变都与它无关。
class DuzEntry {
  const DuzEntry({
    required this.index,
    required this.name,
    required this.size,
    required this.crc,
    required this.isDir,
    required this.encrypted,
  });

  /// 归档内的相对路径，UTF-8 已解码；目录以 `/` 结尾。
  final String name;

  /// 原始（未压缩）大小，字节。
  final int size;

  /// 7-Zip 报的 CRC32；不适用时为 0。
  final int crc;

  final bool isDir;

  /// 该条目是否加密。决定要不要去密码库里试。
  final bool encrypted;

  /// 在归档中的序号（`IInArchive` 的下标）。
  final int index;

  @override
  String toString() =>
      'DuzEntry($index, ${isDir ? 'dir' : '$size B'}, '
      '${encrypted ? 'encrypted' : 'plain'}, "$name")';
}

/// 进度回调。返回 `false` 表示请求取消。
///
/// **它跑在调用方的 isolate 上**（两次轮询之间），不在原生线程上 —— 新架构下
/// 原生侧永不回调 Dart。所以它可以碰 Dart 的一切，但**别在这里做重活**：每多
/// 花一毫秒，下一次轮询就晚一毫秒，取消也就晚一毫秒生效。
///
/// [name] 是当前条目名，可能为 `null`（7-Zip 在报总量时还没进到具体条目）。
/// `total` 为 0 表示未知，此时只该看 `done`。
typedef DuzProgressCallback = bool Function(int done, int total, String? name);

/// 轮询间隔。**刻意小于 worker 侧那个 `kExtractTickMerge`（120ms）**：三层节流
/// 里干活的是那个合并层，这里只是取样的网眼 —— 网眼比闸门大，合并层就白设了。
///
/// 这个数也只决定取消的**最坏**延迟（一个间隔），因为取消标志要等下一次 poll
/// 才送到原生侧。
const Duration kExtractPollInterval = Duration(milliseconds: 80);

/// 取条目名的缓冲长度。原生侧按 UTF-8 截断到 len-1，所以极端深的中文路径会被
/// 截断 —— 名字只用于显示，截断是可接受的代价（换指针方案要担心野地址）。
const int kExtractNameBufLen = 1024;

/// 解压轮询的一帧，[runExtractLoop] 的输入。
typedef ExtractTick = ({
  int done,
  int total,
  String? name,
  bool running,
  bool cancelled,
  int rc,
});

/// 解压轮询循环 —— **不碰 FFI**，三个动作 + 睡眠都由调用方注入。
///
/// 抽成顶层函数是为了能在宿主机上单测（照 `DiskSpaceProbe(channel)` 与
/// `listDirectory(path, lister)` 的先例）：这里能钉住 poll 的节奏、「返回 false
/// 只取消一次」、取消**不抛异常**、`rc != OK` 才抛。
///
/// [failure] 会在**读到 `running == 0` 的那一帧立刻**被调用（中间没有 await），
/// 因为失败原因存在原生侧的 thread_local 里，晚一步读就可能被别的调用冲掉。
///
/// 返回**这次解压是不是真的被中止了** —— 取自原生侧那个快照位，不是「我们送出
/// 过取消」这个事实。两者会不一致（请求取消时它可能刚好已经解完了），而只有
/// 前者的口径才对：否则一个好好解完的包会被报成「已停止」。
Future<bool> runExtractLoop({
  required ExtractTick Function() poll,
  required void Function() cancel,
  required DuzEngineException Function() failure,
  required Future<void> Function(Duration) sleep,
  DuzProgressCallback? onProgress,
  Duration interval = kExtractPollInterval,
}) async {
  var cancelSent = false;
  for (;;) {
    final tick = poll();
    if (!tick.running) {
      // 取消**不是**异常：用户按的是「停止」，不是「这个包坏了」。上层靠
      // `cancelled` 那位区分，别在这儿把它折成一个 DUZ_ERR_EXTRACT。
      if (tick.cancelled) return true;
      if (tick.rc != DUZ_OK) throw failure();
      return false;
    }
    // 只在第一次请求时送取消：原生侧那个标志本来就是幂等的，多送无害，但
    // 「送了几次」是我们自己的账，测试要能断言它恰好是 1。
    if (onProgress != null &&
        !onProgress(tick.done, tick.total, tick.name) &&
        !cancelSent) {
      cancelSent = true;
      cancel();
    }
    await sleep(interval);
  }
}

/// 一个已打开的归档。
///
/// 生命周期：`open` 出来的实例**必须** [close]。用 `try/finally` 包住，或者
/// 让上层在任务边界统一关。原生那边持有文件句柄与解压器的全部状态。
class DuzArchive {
  DuzArchive._(this._ctx, this.entries, this.version);

  final Pointer<duz_ctx> _ctx;
  bool _closed = false;

  /// 打开时一次性读出的条目表（已拷贝成 Dart 对象）。
  ///
  /// 之所以在 `open` 时就读完，而不是留个懒惰的 `list()`：头文件写明
  /// 「再次调用 duz_list 会让上一次返回的数组内容失效」，而且 `duz_close`
  /// 之后整个数组都不可用。拷贝一次、只留 Dart 对象，是最省心的所有权策略，
  /// 代价只是中央目录那点内存（`duz_list` 本来也只读中央目录）。
  final List<DuzEntry> entries;

  /// 引擎版本串，形如 `7-Zip 26.03`。
  final String version;

  /// 打开一个归档。
  ///
  /// [parts] 是分卷清单：单卷传长度为 1 的数组；多卷按**正确顺序**传全部路径
  /// （顺序由 `lib/engine/split.dart` 决定，原生侧不猜）。多卷必须与首卷同目录。
  ///
  /// [password] 可为 null，且 **null 与空串是两件事**：`null` 是「给不出密码」，
  /// `''` 是「密码就是空串」。后者是一个**真候选** —— 条目级加密的 ZIP（AES /
  /// ZipCrypto）就是靠它试出「这个包要密码」的，别把它当「没传」省掉。
  ///
  /// 失败抛 [DuzEngineException]；[DuzEngineException.isPasswordError]
  /// 为真时换下一个候选密码重试本方法即可。
  ///
  /// 注意密码有两种失败方式（见 duz_engine.h）：头加密的包在这里就失败，
  /// 只有条目加密的包能打开成功、到 [extractAll] 才报密码错。
  static DuzArchive open(List<String> parts, {String? password}) {
    if (parts.isEmpty) {
      throw const DuzEngineException(DUZ_ERR_ARG, 'parts 为空：至少要有一个分卷路径');
    }

    final arr = calloc<Pointer<Char>>(parts.length);
    final strings = <Pointer<Utf8>>[];
    Pointer<Utf8>? pwd;
    try {
      for (var i = 0; i < parts.length; i++) {
        final s = parts[i].toNativeUtf8();
        strings.add(s);
        arr[i] = s.cast<Char>();
      }
      // 只看 null，**不看长度**。这里曾经写的是
      // `password != null && password.isNotEmpty`，于是上层送下来的空串在这里
      // 又被折成 nullptr，C 侧 `duz_open` 只好判定「没给密码」，解压时
      // `CryptoGetTextPassword` 回 E_NOTIMPL、整个 Extract() 被短路 ——
      // 「需要密码」变成一句笼统的「解压失败」。空串必须原样落到 C 侧。
      if (password != null) {
        pwd = password.toNativeUtf8();
      }

      final ctx = _b.duz_open(arr, parts.length, pwd?.cast<Char>() ?? nullptr);
      if (ctx == nullptr) {
        // 这几个调用之间**不能有 await**：错误文案是 C++ 侧的 thread_local，
        // 一旦控制权交出去、isolate 有机会换线程，读到的就是别人的错误。
        //
        // 只在**失败分支**里读：那条路上 SetOpenError 一定刚跑过，所以读到的
        // 不是上一次调用留下的值。
        final code = _b.duz_last_open_error_code();
        throw DuzEngineException(code, _readLastError(),
            uncertain: _readLastErrorUncertain());
      }

      // 原生侧已经把路径拷进自己的 UString 了，下面 finally 里就能安全释放。
      final entries = _readEntries(ctx);
      return DuzArchive._(ctx, entries, _readVersion());
    } finally {
      for (final s in strings) {
        malloc.free(s);
      }
      if (pwd != null) malloc.free(pwd);
      calloc.free(arr);
    }
  }

  /// 归档里有没有加密条目 —— 决定要不要去密码库试。
  bool get hasEncryptedEntries => entries.any((e) => e.encrypted);

  /// 所有非目录条目的原始大小之和。
  int get unpackedSize => entries
      .where((e) => !e.isDir)
      .fold<int>(0, (sum, e) => sum + e.size);

  /// 全量解压到 [outDir]。`outDir` **必须已存在且可写**（原生侧不建它）。
  ///
  /// 路径安全（zip-slip、绝对路径、`..`）由 C++ 侧强制。
  ///
  /// **异步**：`duz_extract_start` 立刻返回，真正的解压跑在 C++ 自己的线程上，
  /// 这里用一个轮询循环（见 [runExtractLoop]）取进度、送取消。所以它**不阻塞**
  /// 调用方的 isolate，但仍然是长任务 —— 该放 worker isolate 里。
  ///
  /// [onProgress] 的返回值语义是「继续吗」：返回 `false` 会向原生侧送一次取消，
  /// 解压随即在下一个进度点 unwind。**取消是正常返回、不抛异常**（用户按的是
  /// 「停止」，不是「这个包坏了」）；只有真的失败才抛 [DuzEngineException]。
  ///
  /// **返回 `true` 表示这次解压确实被中止了** —— 取自原生侧那个快照位，而不是
  /// 「我们送出过取消」这个事实。两者会不一致（请求取消时它可能刚好已经解完），
  /// 而只有前者说得出口。取消之后写到一半的那个条目由原生侧删掉
  /// （见 `src/duz_engine.h` 的 `duz_extract_cancel`）。
  ///
  /// **解压期间不要 [close]**：那会 join 这条线程并释放 ctx。本方法返回之后再关。
  Future<bool> extractAll(String outDir, {DuzProgressCallback? onProgress}) async {
    _checkOpen();

    final dir = outDir.toNativeUtf8();
    final snap = calloc<duz_progress_snapshot>();
    final nameBuf = calloc<Char>(kExtractNameBufLen);
    try {
      final rc = _b.duz_extract_start(_ctx, dir.cast<Char>());
      if (rc != DUZ_OK) {
        // 这一档只有「起不来」：参数非法 / 已解过一次 / 本平台没编核心。
        // 同 `open`：紧挨着读，且只在失败分支里读。
        throw DuzEngineException(rc, _readLastError(),
            uncertain: _readLastErrorUncertain());
      }

      return await runExtractLoop(
        poll: () {
          final r = _b.duz_extract_poll(_ctx, snap, nameBuf, kExtractNameBufLen);
          if (r != DUZ_OK) throw DuzEngineException(r, _readLastError());
          final s = snap.ref;
          final n = nameBuf.cast<Utf8>().toDartString();
          return (
            done: s.done,
            total: s.total,
            name: n.isEmpty ? null : n,
            running: s.running != 0,
            cancelled: s.cancelled != 0,
            rc: s.rc,
          );
        },
        cancel: () => _b.duz_extract_cancel(_ctx),
        // 紧挨着那次「running == 0」的 poll 读三件套 —— 它们存在原生侧的
        // thread_local 里，是本线程取走的那一份（见 duz_engine.h 的 poll 说明）。
        failure: () => DuzEngineException(snap.ref.rc, _readLastError(),
            uncertain: _readLastErrorUncertain()),
        sleep: (d) => Future<void>.delayed(d),
        onProgress: onProgress,
      );
    } finally {
      calloc.free(snap);
      calloc.free(nameBuf);
      malloc.free(dir);
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _b.duz_close(_ctx);
  }

  void _checkOpen() {
    if (_closed) {
      throw const DuzEngineException(DUZ_ERR_ARG, '归档已关闭');
    }
  }

  // -------------------------------------------------------------------------
  // 内部：把原生数据搬进 Dart
  // -------------------------------------------------------------------------

  /// 读条目表。调用方的 `ctx` 必须有效。
  static List<DuzEntry> _readEntries(Pointer<duz_ctx> ctx) {
    final out = calloc<Pointer<duz_entry>>();
    final count = calloc<Int32>();
    try {
      final rc = _b.duz_list(ctx, out, count);
      // 这里**不读** uncertain：`duz_list` 失败时压根没碰过那两个 thread_local，
      // 读到的会是上一次解压失败留下的残留。「分不清」只在解压阶段有意义
      // （见 duz_engine.h），列条目这一路永远给 false 才是对的。
      if (rc != DUZ_OK) throw DuzEngineException(rc, _readLastError());

      final n = count.value;
      // 空归档：duz_list 返回 DUZ_OK 但 *out 保持 nullptr、count 为 0。
      if (n <= 0 || out.value == nullptr) return const [];

      final list = <DuzEntry>[];
      for (var i = 0; i < n; i++) {
        final e = out.value[i];
        // 名字是 ctx 的字节，必须**在此之前**拷成 Dart String：
        // 下面的 finally 会 free 数组，而 ctx 之后也会被 duz_close 掉。
        final p = e.name;
        list.add(
          DuzEntry(
            index: e.index,
            name: p == nullptr ? '' : p.cast<Utf8>().toDartString(),
            size: e.size,
            crc: e.crc,
            isDir: e.is_dir != 0,
            encrypted: e.encrypted != 0,
          ),
        );
      }
      return list;
    } finally {
      if (out.value != nullptr) _b.duz_free_entries(out.value, count.value);
      calloc.free(out);
      calloc.free(count);
    }
  }

  static String _readVersion() {
    const cap = 128;
    final buf = calloc<Char>(cap);
    try {
      final n = _b.duz_version(buf, cap);
      if (n <= 0) return '';
      return buf.cast<Utf8>().toDartString(length: n);
    } finally {
      calloc.free(buf);
    }
  }
}

/// thread_local 的错误文案，随取随用，**不要 free**。
String _readLastError() {
  final p = _b.duz_last_open_error();
  if (p == nullptr) return '未知错误';
  return p.cast<Utf8>().toDartString();
}

/// thread_local 的「分不清密码错还是数据坏」位（见 `DuzEngineException.uncertain`）。
///
/// 与 [_readLastError] 同源同生命周期：**紧挨着它读**，只在失败分支里读 ——
/// 成功返回时 C++ 侧没有刷新过这个位，读到的会是上一次失败的残留。
bool _readLastErrorUncertain() => _b.duz_last_error_uncertain() != 0;

/// 引擎版本短查询，不必打开任何归档。
///
/// 非 Android 平台会拿到 `DeepUnzip engine (skeleton)` —— 那是**正确的**答案，
/// 表示这个构建里没有 7-Zip 核心，不是失败。
String engineVersion() => DuzArchive._readVersion();
