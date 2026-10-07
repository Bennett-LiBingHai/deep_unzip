# DeepUnzip

纯本地的 Android 解压工具。选一个文件夹或一个压缩包，它负责递归解开、认格式、
试密码，把结果写到该去的地方。

**不联网，不收集任何个人信息。** Release 包不声明 `INTERNET` 权限，不接任何统计 /
崩溃 / 广告 SDK。

面向国内应用商店分发。

---

## 功能

- **递归解压** —— 压缩包里的压缩包继续解，深度上限可设
- **格式识别** —— 按文件头嗅探，后缀被改过也能认出来（`报告.pdf` 实为 ZIP 这类）
- **分卷压缩包** —— 裸字节切分（`x.zip.001`）、Info-ZIP 跨卷（`x.z01` + `x.zip`）、
  RAR3（`x.r00`）、RAR5（`x.part1.rar`）四种家族
- **密码库** —— 存在 Android Keystore 支持的加密存储里（`flutter_secure_storage`，
  不是明文的 `shared_preferences`），加密包自动逐个候选试
- **输出位置** —— 默认解到压缩包旁边（目录结构对称）；打开「自定义输出目录」后，
  按源目录结构镜像到你指定的根目录
- **出错时不猜** —— 解不开就问「停止 / 跳过」；分不清是「密码错」还是「文件坏了」
  的时候，如实说分不清
- **长任务保活** —— 前台服务 + 通知栏进度，切后台 / 锁屏不会被系统回收
- **日志** —— 每个包一条，保留条数可设
- **自建文件浏览器** —— 不依赖系统选择器（它会把整个文件复制进应用缓存）

## 支持的 Android 版本

| | |
|---|---|
| 最低 | Android 7.0（API 24） |
| 目标 / 编译 | Android 16（API 36） |
| ABI | `arm64-v8a`、`armeabi-v7a`、`x86_64` |
| 16 KB 页大小 | 支持 —— `arm64-v8a` / `x86_64` 的全部 `.so` 都是 16 KB 对齐 |

存储权限在这个区间里分三档，对应三条不同的路：

| Android | 走什么 |
|---|---|
| 7.0 – 9 | `READ_EXTERNAL_STORAGE` / `WRITE_EXTERNAL_STORAGE` |
| 10 | 同上，另加 `requestLegacyExternalStorage` —— API 29 是唯一「分区存储已经强制、
而 `MANAGE_EXTERNAL_STORAGE` 还没出生（API 30 才有）」的版本 |
| 11+ | `MANAGE_EXTERNAL_STORAGE`（「所有文件访问」）。核心功能靠它 |

通知权限（Android 13+）与前台服务类型（Android 14+）另有声明。逐条的清单见
[`android/app/src/main/AndroidManifest.xml`](android/app/src/main/AndroidManifest.xml)。

## 构建

需要 Flutter 3.47、Dart 3.13、JDK 17、Android SDK 36、NDK 28.2.13676358。

```bash
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn   # 国内拉 Flutter 构件
flutter pub get
flutter build apk --release
```

Gradle 的发行包走腾讯云镜像，配置在
`android/gradle/wrapper/gradle-wrapper.properties` 里。

**发布签名**：把 `android/key.properties.example` 复制成 `android/key.properties`
再填上（模板里写了生成 keystore 的命令和几个坑）。**没有它也能编过** ——
会退回 debug 签名，只是那样的包不能上架。

`flutter test` 跑全部用例，**不需要设备或模拟器**。

## 发布

```bash
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
flutter build apk --release

"$ANDROID_HOME/build-tools/<版本>/apksigner" verify --print-certs \
  build/app/outputs/flutter-apk/app-release.apk
```

`apksigner` 那一步不能省：**没有 `android/key.properties` 时构建不报错**，
只会静默退回 debug 签名。输出里是 `CN=Android Debug, O=Android, C=US`，说明这个包
不能上架；看到自己填的 `CN` 才算真签上了。签名与 keystore 的说明见上面「构建」。

**APK 不进仓库。** 整个 `build/` 都在 `.gitignore` 里，而要让 git 放行里面某一个
文件，得逐层绕开 `/build/`（父目录被忽略时否定规则看不见），且 `flutter clean`
一跑就变成一条待提交的删除记录 —— 二进制还会永久留在历史里，发一版涨一份体积。
发布走 Gitee 的**发行版**：建一个版本、把 APK 作为附件传上去。不占 git 历史、
有版本号和更新说明、下载走 Gitee 的 CDN。

版本号在 `pubspec.yaml` 的 `version:` 一行：`+` 前面是 `versionName`（给人看的），
后面是 `versionCode` —— 商店判断新旧用的是这个整数，**每次发版必须递增**。

## 目录结构

```
lib/
  engine/      引擎的 Dart 侧：扫描、嗅探、分卷、限额、worker 协议。
               除 backends/native_backend.dart 外都是纯 Dart，不 import
               package:flutter —— 所以能跑在 isolate 里，也能无设备单测。
  data/        设置与密码库的持久化
  services/    平台通道、权限、文件浏览、保活、弹窗桥接
  providers/   AppState —— 引擎与界面之间的瘦适配层
  screens/     首页 / 日志 / 密码库 / 设置 / 关于 / 文件浏览器
packages/deep_unzip_engine/   本地 FFI 插件（C++），见下
tool/         夹具生成脚本（造各种畸形与攻击性压缩包）
test/         全部用例；纯 Dart + dart:io，跑在宿主机上
```

## 解压引擎

[`packages/deep_unzip_engine`](packages/deep_unzip_engine/) 是一层薄 C ABI，把
7-Zip 核心包起来。它编译成**两个** `.so`：

- `libduz7zip.so` —— 7-Zip 本体
- `libdeep_unzip_engine.so` —— 我们的包装层，运行期动态链接前者

分成两个是为了 LGPL 的重链接义务（LGPL-2.1 §6b）：库保持独立、用户能自行替换，
我们就不必交出自己那部分的目标码。完整理由写在
`packages/deep_unzip_engine/src/CMakeLists.txt` 顶部。

7-Zip 的源码是固定快照，放在 `third_party/7zip/`，**含我们对它的改动** ——
逐条记在 [`packages/deep_unzip_engine/PATCHES.md`](packages/deep_unzip_engine/PATCHES.md)。

## 许可

本项目以 **Apache-2.0** 发布，全文见 [LICENSE](LICENSE)。

第三方组件：

- **7-Zip** —— LGPL-2.1 加 unRAR 限制。源码随本仓库分发于 `third_party/7zip/`。
  unRAR 那部分仅用于**解压** RAR、不用于制作 RAR 压缩包 —— 这正是该许可明确允许
  的用途。
- **LZFSE / ZSTD / XXH64** —— BSD 许可，正文嵌在 7-Zip 的许可文件里。
- **Dart / Flutter 组件**（`shared_preferences`、`flutter_secure_storage`、
  `permission_handler`、`archive`、`path`、`path_provider`、`crypto` 等）——
  许可由 Flutter 在构建期自动收集。

许可全文随应用分发（`assets/licenses/`），在应用内「关于」页可以读到。

## 隐私

- 不联网。Release 包不声明 `INTERNET` 权限。
- 不收集个人信息，不接任何统计 / 崩溃 / 广告 SDK。
- 密码存在 Android Keystore 支持的加密存储里，不是明文 XML。
- 历史日志不记完整路径。
