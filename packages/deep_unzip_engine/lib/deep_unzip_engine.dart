/// DeepUnzip 引擎的 Dart 封装 —— 对 `src/duz_engine.h` 那套 C ABI 的安全包装。
///
/// ## 分两层
///
/// - `deep_unzip_engine_bindings_generated.dart`（ffigen 生成）是**机械**绑定：
///   裸指针进、裸指针出，不懂所有权。
/// - 本文件是**语义**层：管内存、把 UTF-8 指针变成 Dart `String`、把错误码
///   变成异常、把 `duz_progress_cb` 变成 Dart 闭包。
///
/// 上层（`lib/engine/backends/native_backend.dart`）只该用本文件，不该直接碰
/// 生成的那层 —— 否则所有权规则（谁分配谁释放、哪个指针活多久）会散落各处。
///
/// ## 线程
///
/// [DuzArchive.extractAll] 会阻塞调用它的 isolate 直到解压完成。**绝不能在主
/// isolate 调用**（UI 会整个冻住），必须放在 worker isolate 里。
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
  const DuzEngineException(this.code, this.message);

  final int code;
  final String message;

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
/// [name] 是当前条目名，可能为 `null`（7-Zip 在报总量时还没进到具体条目）。
/// `total` 为 0 表示未知，此时只该看 `done`。
typedef DuzProgressCallback = bool Function(int done, int total, String? name);

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
  /// [password] 可为 null。失败抛 [DuzEngineException]；[DuzEngineException.isPasswordError]
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
      if (password != null && password.isNotEmpty) {
        pwd = password.toNativeUtf8();
      }

      final ctx = _b.duz_open(arr, parts.length, pwd?.cast<Char>() ?? nullptr);
      if (ctx == nullptr) {
        // 这两个调用之间**不能有 await**：错误文案是 C++ 侧的 thread_local，
        // 一旦控制权交出去、isolate 有机会换线程，读到的就是别人的错误。
        final code = _b.duz_last_open_error_code();
        throw DuzEngineException(code, _readLastError());
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
  /// [onProgress] 的返回值语义是「继续吗」：返回 `false` 会尽快中止，
  /// 然后本方法抛一个 `DUZ_ERR_EXTRACT` 的异常（文案「已取消」）。
  ///
  /// **会阻塞当前 isolate。只能在 worker isolate 里调。**
  void extractAll(String outDir, {DuzProgressCallback? onProgress}) {
    _checkOpen();

    final dir = outDir.toNativeUtf8();
    NativeCallable<duz_progress_cbFunction>? cb;
    try {
      if (onProgress != null) {
        // 必须是 isolateLocal 而不是 listener：前者同步回调在调用它的那条
        // 线程上，正好是 7-Zip 报进度的那条；后者会把调用投到主 isolate 的
        // 事件循环，而我们已经把它堵住了（更别说解压本来就在别的 isolate 里）。
        // 返回类型是 int，所以必须给 exceptionalReturn —— 那是**回调自己抛异常**
        // 时返回给 C++ 的值。取 1（取消）而不是 0（继续）：回调挂了还若无其事地
        // 接着解压，用户会看到一个不动却也不报错的进度条。中止更诚实，而且
        // 立刻可恢复（我们什么都没写坏，输出目录是新建的）。
        cb = NativeCallable<duz_progress_cbFunction>.isolateLocal(
          (Pointer<Void> _, int done, int total, Pointer<Char> name) {
            final n = name == nullptr ? null : name.cast<Utf8>().toDartString();
            return onProgress(done, total, n) ? 0 : 1;
          },
          exceptionalReturn: 1,
        );
      }

      final rc = _b.duz_extract_all(
        _ctx,
        dir.cast<Char>(),
        cb?.nativeFunction ?? nullptr,
        nullptr,
      );
      if (rc != DUZ_OK) {
        throw DuzEngineException(rc, _readLastError());
      }
    } finally {
      // 先关回调再放路径：duz_extract_all 已经返回，回调不可能再被调用。
      cb?.close();
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

/// 引擎版本短查询，不必打开任何归档。
///
/// 非 Android 平台会拿到 `DeepUnzip engine (skeleton)` —— 那是**正确的**答案，
/// 表示这个构建里没有 7-Zip 核心，不是失败。
String engineVersion() => DuzArchive._readVersion();
