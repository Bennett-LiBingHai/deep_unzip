/// 发现「可以从哪里开始浏览」—— 也就是存储卷的根目录。
///
/// ## 为什么不写死 `/storage/emulated/0`
///
/// 那只是**主卷**在多用户设备上的默认形态。实际上：
///
/// - 工作资料（Work Profile）的卷是 `/storage/emulated/10`；
/// - 可移动存储（SD 卡）是 `/storage/XXXX-XXXX`（卷 UUID），不是 `emulated` 下的一档；
/// - 少数 ROM 上主卷号也不一定是 0。
///
/// 写死一个的后果是「SD 卡里的包在这个 app 里根本选不到」，而且用户没有任何
/// 提示 —— 他只会以为这个 app 不支持 SD 卡。
///
/// ## 为什么不用原生那条
///
/// `MainActivity.kt` 里已有一个 `externalVolumeRoots()`（给「用文件管理器打开
/// 输出目录」用的），加一条平台通道把它暴露出来会更权威。**没走那条**：多一个
/// 本机验不了的原生方法（见 memory `android-only-cpp-verification`），而下面这条
/// 纯 Dart 的路能单测、失败时还能退到一个算出来的默认值。真碰上个认不出的 ROM
/// 再加通道不迟。
library;

import 'dart:io';

/// 列出一个目录的子项绝对路径。默认走 `dart:io`，测试注入假的。
typedef ChildLister = Future<List<String>> Function(String dir);

Future<List<String>> _ioChildren(String dir) async {
  final out = <String>[];
  await for (final e in Directory(dir).list(followLinks: false)) {
    out.add(e.path);
  }
  return out;
}

/// 只认 Android 那条命名：可移动卷是 4 位十六进制 + `-` + 4 位（如 `1A2B-3C4D`）。
///
/// **别放宽成「看起来像 UUID 就行」**：`/storage` 下还有 `self`（指向当前用户的
/// 主卷，是个符号链接）这类东西，放进来会让用户在同一个物理卷上看到两个入口。
final _removable = RegExp(r'^[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}$');

/// 列出可用的卷根，**主卷排在最前**。
///
/// 返回的路径一定存在且是个目录；一个都找不到时回落到 `['/']`（浏览根目录总比
/// 什么都不给强，虽然那里大半读不了）。
Future<List<String>> discoverStorageRoots({ChildLister? lister}) async {
  final children = lister ?? _ioChildren;

  Future<List<String>> under(String dir) async {
    try {
      return await children(dir);
    } on FileSystemException {
      return const [];
    }
  }

  final roots = <String>[];
  final storage = await under('/storage');

  // emulated 先展开一层：`/storage/emulated/0`、`/storage/emulated/10`…
  for (final e in storage.where((p) => _name(p) == 'emulated')) {
    final users = await under(e);
    users.sort(_byTrailingNumber);
    roots.addAll(users);
  }
  // 再是可移动卷。它们排在主卷后面 —— 绝大多数人要找的东西在主卷上。
  roots.addAll(storage.where((p) => _removable.hasMatch(_name(p))));

  final existing = <String>[];
  for (final r in roots) {
    if (_isDir(r)) existing.add(r);
  }
  if (existing.isNotEmpty) return existing;

  // 发现失败（非 Android、或 ROM 太怪）时的两条退路，从具体到笼统。
  for (final fallback in ['/storage/emulated/0', '/sdcard']) {
    if (_isDir(fallback)) return [fallback];
  }
  return const ['/'];
}

bool _isDir(String path) {
  try {
    return Directory(path).existsSync();
  } on FileSystemException {
    return false;
  }
}

/// 取最后一段。**两种分隔符都要认** —— 真机上是 `/`，但测试跑在 Windows 宿主机
/// 上，临时目录给出来的是 `\`。只认一种的话，这整套逻辑在测试里等于没跑
/// （`_name` 返回整条路径，`emulated` 与卷名的判断**全都匹配不上**），
/// 用例会以「什么都没认出来」的形式静默退化。
final _sep = RegExp(r'[/\\]');

String _name(String path) {
  final i = path.lastIndexOf(_sep);
  return i < 0 ? path : path.substring(i + 1);
}

/// `/storage/emulated/0` 排在 `/storage/emulated/10` 前面。
int _byTrailingNumber(String a, String b) {
  final na = int.tryParse(_name(a));
  final nb = int.tryParse(_name(b));
  if (na == null || nb == null) return a.compareTo(b);
  return na.compareTo(nb);
}
