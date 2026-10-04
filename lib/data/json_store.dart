/// JSON 落盘：**原子写 + 容错读**。
///
/// ## 为什么不能直接 `writeAsString`
///
/// 解压 App 在手机上被 LMK 杀掉是常态（大包一跑就是几十秒、几百 MB），而
/// 日志是**边解边追加**的。写到一半进程没了，目标文件就成了一段截断的 JSON；
/// 下次启动 `jsonDecode` 直接抛 `FormatException`。跟着一起丢的还有密码库
/// 和设置 —— 那是用户一条条攒出来的东西，不该为一次断电陪葬。
///
/// 所以写在同目录的 `.tmp` 上、`flush` 落盘，最后 `rename` 覆盖。同一文件
/// 系统上的 `rename` 是原子的：读的那一侧要么看到完整的旧版本、要么看到完整
/// 的新版本，没有中间态。
///
/// ## 为什么写要串行
///
/// 原子写只保证「一次写是完整的」，不保证「两次写不互相踩」。同期两次
/// [_writeOnce] 都往同一个 `foo.json.tmp` 上写，一次 `truncate` 能把另一次
/// 刚写进去的字节抹掉，再 `rename` 出去的就是一份**两份内容交织**的东西 ——
/// 比不原子还糟。日志在解压期是连着写的，这个撞车不是理论问题。
///
/// 所以这里给每个路径挂一条 future 链，写请求排队。顺带拿到一个**顺序保证**：
/// 先发的写一定先落盘，不会出现「新的被旧的盖回去」。
///
/// 整个文件是纯 `dart:io`，没有 `package:flutter`，能在 `flutter test` 里
/// 直接对着临时目录跑。
library;

import 'dart:convert';
import 'dart:io';

class JsonStore {
  /// 每份文件一条等待链。key 是绝对路径。
  final Map<String, Future<void>> _chains = {};

  /// 读一份 JSON。
  ///
  /// **不抛异常**：文件不存在、内容截断、顶层类型不对，一律返回 null。
  /// 读不回来就当没有 —— 调用方（`main()` 里的预加载）是等着它才 `runApp`
  /// 的，这里漏一个异常出去就是白屏启动。
  Future<Object?> read(File file) async {
    try {
      if (!await file.exists()) return null;
      final text = await file.readAsString();
      if (text.trim().isEmpty) return null;
      return jsonDecode(text);
    } on FormatException {
      // 上次写到一半被杀留下的残档。当没有。
      return null;
    } on FileSystemException {
      return null;
    }
  }

  /// 原子写一份 JSON，返回是否落盘成功。**同样不抛**，理由同上。
  ///
  /// 失败返回 false 而不是抛出，是为了让调用方能选择「静默算了」——
  /// 一次日志没写进去不值得弹窗打断解压。
  Future<bool> write(File file, Object value) {
    // 排在这条路径上一个写请求之后。`_chains` 里存的永远是一个**已消化异常**
    // 的 future，否则一次失败会让后面每一次写都跟着短路。
    final prev = _chains[file.path] ?? Future<void>.value();
    final result = prev.then((_) => _writeOnce(file, value));
    _chains[file.path] = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<bool> _writeOnce(File file, Object value) async {
    final tmp = File('${file.path}.tmp');
    try {
      await file.parent.create(recursive: true);
      await tmp.writeAsString(jsonEncode(value), flush: true);
      await tmp.rename(file.path);
      return true;
    } on FileSystemException {
      // 尽力清掉残档：留一个 .tmp 在磁盘上除了碍眼没别的用。
      try {
        if (await tmp.exists()) await tmp.delete();
      } on FileSystemException {
        // 清理也失败就算了，别把上面那个真正的失败遮住。
      }
      return false;
    }
  }
}
