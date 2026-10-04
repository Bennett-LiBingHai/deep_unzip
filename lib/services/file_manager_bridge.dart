/// 让系统文件管理器打开一个目录（解压结果的根）。
///
/// ## 为什么非走原生
///
/// Android **没有**「打开这个文件夹」的标准 Intent。往上找得到的写法大致三类，
/// 两类是坑：
///
/// - `ACTION_VIEW` + `file://` + `resource/folder`：targetSdk ≥ 24 的 app 把
///   `file://` 交给别的 app 会抛 `FileUriExposedException`，**直接崩**。网上
///   大把示例还在这么写，因为它们多半是 targetSdk 23 时代留下的。
/// - `FileProvider`：它只服务单个文件，不实现 `queryChildDocuments`，交给别的
///   app 一个**目录**它列不出来 —— 拿它开目录是走不通的，别浪费时间去加
///   `file_paths.xml`。
/// - `DocumentsContract` + 系统 `ExternalStorageProvider`：这条是对的。URI 是
///   `content://`，不触发上面那个异常；而且它是系统的 provider，接收方不用认识
///   我们。docId 形如 `primary:Download/foo`。
///
/// 但光有 URI 还不够 —— **还得点名 DocumentsUI 组件**，因为真机上
/// `VIEW + vnd.android.document/directory` 有 7 个处理者（夸克、百度网盘、UC…），
/// 隐式发出去是个「用哪个应用打开」的选择器。细节与两条踩过的坑（小米塞的是
/// **Google 版** DocumentsUI，包名与 AOSP 不同；以及 `<queries>` 不声明就连
/// 一个处理者都看不见）都写在 `MainActivity.kt` 的类注释里。
///
/// ## 这个桥为什么返回枚举而不是 bool
///
/// 因为「打开成功」有好几档含义。系统里真正认识那个 URI 的文件管理器是 AOSP
/// 的 DocumentsUI，而**国产 ROM 经常把它换掉或包一层**；换掉之后只剩
/// 「随便打开一个文件管理器」这条兜底 —— 那也是"成功"，但用户眼前的界面根本
/// 没定位到他想要的目录。把这两种情况压成一个 bool，界面就只能假装成功，
/// 用户对着一个不相干的目录发呆。所以降级到哪一档要如实往上传。
library;

import 'dart:io';

import 'package:flutter/services.dart';

/// 原生方法通道名。**必须与 `MainActivity.kt` 里注册的逐字一致。**
const String kFileManagerChannel = 'com.example.deep_unzip/native';

/// 打开目录的结果。
enum OpenFolderResult {
  /// 精确打开到了目标目录。
  opened,

  /// 只打开了某个文件管理器，**没有**定位到目标目录（国产 ROM 上的常见结局）。
  /// 界面应把路径给用户，让他自己点进去。
  openedGeneric,

  /// 路径不在任何外部存储卷上（比如应用私有目录），`ExternalStorageProvider`
  /// 表达不了它，原生侧连试都没试。
  unsupportedPath,

  /// 设备上没有能处理它的文件管理器。
  noHandler,

  /// 当前平台没有这条通道（桌面/测试环境），或者通道没注册上。
  unavailable,
}

class FileManagerBridge {
  /// [channel] 与 [isAndroid] 只给测试注入用。生产代码一律用默认值。
  FileManagerBridge({MethodChannel? channel, bool? isAndroid})
      : _channel = channel ?? const MethodChannel(kFileManagerChannel),
        _isAndroid = isAndroid ?? Platform.isAndroid;

  final MethodChannel _channel;
  final bool _isAndroid;

  /// 打开 [path] 所在的目录。
  ///
  /// 不抛异常：所有失败都折进 [OpenFolderResult]，调用方按枚举分支即可。
  Future<OpenFolderResult> openFolder(String path) async {
    if (path.isEmpty) return OpenFolderResult.unsupportedPath;
    if (!_isAndroid) return OpenFolderResult.unavailable;
    try {
      final code = await _channel.invokeMethod<String>(
        'openFolderInFileManager',
        <String, Object?>{'path': path},
      );
      return _parse(code);
    } on MissingPluginException {
      // 通道没注册（比如热重载到一半、或者跑在桌面目标上）。
      return OpenFolderResult.unavailable;
    } on PlatformException {
      return OpenFolderResult.noHandler;
    }
  }

  /// 原生返回的字符串 → 枚举。
  ///
  /// 认不出来的一律当 [OpenFolderResult.noHandler]：新增一档原生结果却忘了
  /// 在这里登记时，宁可说「没打开」也不要假装打开成功。
  static OpenFolderResult _parse(String? code) => switch (code) {
        'opened' => OpenFolderResult.opened,
        'opened_generic' => OpenFolderResult.openedGeneric,
        'unsupported_path' => OpenFolderResult.unsupportedPath,
        _ => OpenFolderResult.noHandler,
      };
}
