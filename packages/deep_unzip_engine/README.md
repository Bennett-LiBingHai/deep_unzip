# deep_unzip_engine

DeepUnzip 的本地 FFI 插件。一层薄 C ABI 把 7-Zip 核心包起来给 Dart 调用。

主仓库的背景、构建方式与许可见[根目录 README](../../README.md)；这里只讲这个包
自己的事。

## 两个 `.so`，不是一个

| | |
|---|---|
| `libduz7zip.so` | 7-Zip 本体，独立编译，`CXX_VISIBILITY_PRESET default` |
| `libdeep_unzip_engine.so` | 包装层，**动态链接**前者（`DT_NEEDED`） |

分开是**刻意的**，别为了图省事合并回去：LGPL-2.1 §6b 的「共享库机制」正是靠这个
成立的 —— 库保持独立、用户能自行替换，我们才不必交出自己那部分的目标码。合并成
一个 `.so` 就退回 §6a，义务完全不同。完整理由写在 `src/CMakeLists.txt` 顶部。

代价是必须用 `c++_shared`（`android/build.gradle` 里
`-DANDROID_STL=c++_shared`）：默认的 `c++_static` 会让两个 `.so` 各嵌一份 libc++，
同一类型的 `typeinfo` 有两个互不相等的地址，跨边界 `catch` 接不住，症状是运行期
随机崩。

## 目录

```
src/duz_engine.h            C ABI 声明（ffigen 读它）
src/duz_engine.cpp          实现
src/CMakeLists.txt          两个目标的构建方式 + LGPL 那段说明
src/7zip_sources.cmake      7-Zip 源文件清单（已入库，一般不用重生成）
src/7zip_guids.cpp          7-Zip 用到的 GUID 定义
tool/gen_7zip_sources.sh    从官方 Arc_gcc.mak 重新生成上面的源清单
third_party/7zip/           7-Zip 源码快照
PATCHES.md                  对 7-Zip 的改动清单 —— 升级时按它逐条重新施加
LGPL-2.1.txt / LICENSE      许可是怎么回事
ffigen.yaml                 生成 Dart 绑定的配置
lib/                        ffigen 生成的绑定 + 手写的 Dart 封装
```

## 改了 `duz_engine.h` 之后

```bash
cd packages/deep_unzip_engine && dart run ffigen --config ffigen.yaml
```

`ffigen.yaml` 里那条 `llvm-path` 是本机路径，换机器要改。

## 本机验不了 C++

`src/` 下的 C++ 只在 Android 上编译（没有 Windows / Linux 目标）。改完之后本机
能做的验证只有：`flutter build apk --release`，然后在产物 `.so` 里 `grep` 新加的
符号名，确认它真的进了二进制。运行时行为得上真机。
