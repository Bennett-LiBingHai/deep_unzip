/// 应用自身的名字与版本。
///
/// ## 版本号为什么是手写的
///
/// Flutter 在**构建期**把 `pubspec.yaml` 的 `version:` 写进原生清单，Dart 侧读
/// 不到它 —— 要么引 `package_info_plus`（一条新的平台通道 + 一个依赖）、要么在
/// 这里写一份。选了后者，因为**漂移由测试兜着**：`about_screen_test.dart` 会打开
/// `pubspec.yaml` 把两个字符串比一遍，对不上就红。这比「多一个依赖」便宜。
///
/// 所以：**改 `pubspec.yaml` 的版本号时，这里必须一起改** —— 否则测试会拦下来，
/// 而如果哪天有人把那条测试删了，就会出现「关于页写着 1.0.0、安装包里是 1.2.0」
/// 这种最难查的错。别删那条测试。
library;

/// 显示名。与 `pubspec.yaml` 的 `name`（`deep_unzip`）、Android 的应用名、
/// 软著登记名三处必须一致 —— 商店那边改名要三处同改。
const String kAppName = 'DeepUnzip';

/// 与 `pubspec.yaml` 的 `version:` 前半段一致（不含 `+构建号`）。
const String kAppVersion = '1.0.0';

/// 一句话说明这个 app 是干什么的。
const String kAppTagline = '纯本地解压工具 · 不联网、不收集个人信息';
