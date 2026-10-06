# DeepUnzip 引擎的本地构建脚本。
#
# 本文件同时被 android/ 与 windows/ 的 Gradle/CMake 复用，所以要显式区分平台：
# **7-Zip 的源清单取自官方 gcc makefile（CPP/7zip/Bundles/Format7zF/Arc_gcc.mak
# 与 Bundles/Alone2/makefile.gcc），那是非 Windows 配置，不含 DLL/Registry/
# MemoryLock/FileSystem 这些 Windows 专用对象。** 拿它去编 Windows 桌面版必然会
# 缺符号。所以这里只在 ANDROID 下链入 7-Zip；其余平台编出来的 duz_engine 是个
# 明说「未编入核心」的占位实现（见 duz_engine.cpp），不会静默给出错误结果。
#
# ## 为什么是两个 .so（2026-10 拆的）
#
# 从前 7-Zip 的 313 个源文件和 duz_engine.cpp 全静态链进**同一个**
# `libdeep_unzip_engine.so`。那属于 LGPL-2.1 第 6 条说的「静态链接」：库的机器码
# 被编进了我们的二进制，用户没法替换它 —— 于是我们必须额外交出「能改库再重新
# 链接」的材料（§6a 要求连「使用库的作品」的目标码一起给）。
#
# 拆成两个 .so、让引擎**动态链接** 7-Zip 之后，落进的是 §6b：库在运行期是一个
# 独立的文件，用户自己编一个新的 `libduz7zip.so` 覆盖上去就行，不用碰我们的代码，
# 那套材料义务随之消失。顺带的好处是 7-Zip 可以单独升级、单独替换。
#
# **代价是必须换用 `c++_shared`**（见 android/build.gradle 的 ANDROID_STL）：
# 现在有 C++ 对象（`UString`、`CArchiveLink`、异常）跨 .so 边界，两份静态 libc++
# 会让 typeinfo 对不上，`catch` 接不住那边抛出来的异常。这是拆分的前提，不是可选项。
#
# cmake_minimum_required 定在 3.13：用到 target_link_options(3.13+)，而本机
# Android SDK 自带的是 3.22.1。这是私有插件、不上架 pub，不必迁就 3.10。

cmake_minimum_required(VERSION 3.13)

project(deep_unzip_engine_library VERSION 0.0.1 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(DUZ_7ZIP_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/7zip")

# 与 7-Zip 官方 gcc makefile 的 CFLAGS_BASE 对齐：
#   _FILE_OFFSET_BITS=64 / _LARGEFILE_SOURCE —— 大文件（>2G）与 64 位偏移
#   _REENTRANT                             —— MT 模式下的线程安全声明
#   NDEBUG                                 —— 关掉 assert（release 语义）
# 注意**不传 -Werror**：官方 makefile 里有 -Werror -Wall -Wextra，那是给
# 官方 CI 用的；NDK 的 clang 版本与之不同，一堆新告警会把构建打死。
#
# 两个目标**必须**拿到同一组宏：它们之间传的是 C++ 对象（`UString` 的布局、
# `CArchiveLink` 的 ABI），一边开着 `_FILE_OFFSET_BITS=64` 而另一边没开，就会出现
# 那种「编译能过、运行期读到垃圾」的问题。
set(DUZ_COMMON_DEFS
  $<$<CONFIG:Release>:NDEBUG>
  _FILE_OFFSET_BITS=64
  _LARGEFILE_SOURCE
  _REENTRANT
  # Flutter 的 FFI 插件模板会带这个宏；保留它以维持与工具链既有约定的兼容。
  DART_SHARED_LIB
)

# 7-Zip 自己的头文件用相对包含；`CPP` 与 `C` 两个根必须在搜索路径上。
# 两个目标都要 —— duz_engine.cpp 直接 include 7-Zip 的头。
set(DUZ_INCLUDE_DIRS
  "${CMAKE_CURRENT_SOURCE_DIR}"
  "${DUZ_7ZIP_ROOT}/CPP"
  "${DUZ_7ZIP_ROOT}/C"
)

if(ANDROID)
  if(NOT EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/7zip_sources.cmake")
    message(FATAL_ERROR
      "缺少 src/7zip_sources.cmake。请在 packages/deep_unzip_engine 下执行：\n"
      "  bash tool/gen_7zip_sources.sh third_party/7zip src/7zip_sources.cmake")
  endif()
  include("${CMAKE_CURRENT_SOURCE_DIR}/7zip_sources.cmake")

  # ---------------------------------------------------------------------------
  # libduz7zip.so —— 7-Zip 本体
  # ---------------------------------------------------------------------------
  #
  # **不设隐藏可见性**，符号全导出。理由：duz_engine.cpp 用的不是几个固定入口，
  # 而是 7-Zip 的一大片 C++ 内部（`CCodecs::Load`、`CArchiveLink::Open2`、
  # `CArchiveExtractCallback`、`Windows/FileDir`、`FileFind`、`PropVariant`…）。
  # 全部列进版本脚本去导出，是一份会随 7-Zip 升级不断失效的手工清单；而
  # `-fvisibility=hidden` 下漏掉一个就是**运行期**加载失败（链接期看不出来），
  # 本机又编不了应用、只能打包后上真机才发现。
  #
  # 代价是 .dynsym 变大（几万个符号）。这是刻意的取舍：可靠 > 体积。
  #
  # `7zip_guids.cpp` 放这里，不放引擎那边：GUID 是 `EXTERN_C const GUID`，
  # 全程序只能有**一个**定义单元（见那个文件开头的长注释）。它跟着 7-Zip 走，
  # 由这里导出给引擎用。
  add_library(duz_7zip SHARED
    ${DUZ_7ZIP_SOURCES}
    "7zip_guids.cpp"
  )

  set_target_properties(duz_7zip PROPERTIES
    OUTPUT_NAME "duz7zip"
    C_VISIBILITY_PRESET default
    CXX_VISIBILITY_PRESET default
  )

  target_include_directories(duz_7zip PRIVATE ${DUZ_INCLUDE_DIRS})
  target_compile_definitions(duz_7zip PRIVATE ${DUZ_COMMON_DEFS})
  # 例外由 7-Zip 大量使用（错误传播全靠 throw），必须开。
  target_compile_options(duz_7zip PRIVATE -fexceptions)

  find_package(Threads REQUIRED)
  target_link_libraries(duz_7zip PRIVATE Threads::Threads)

  # ---------------------------------------------------------------------------
  # libdeep_unzip_engine.so —— 只有那一层薄 C ABI
  # ---------------------------------------------------------------------------
  add_library(deep_unzip_engine SHARED "duz_engine.cpp")

  set_target_properties(deep_unzip_engine PROPERTIES
    OUTPUT_NAME "deep_unzip_engine"
    C_VISIBILITY_PRESET hidden
    CXX_VISIBILITY_PRESET hidden
  )

  target_include_directories(deep_unzip_engine PRIVATE ${DUZ_INCLUDE_DIRS})
  target_compile_definitions(deep_unzip_engine PRIVATE ${DUZ_COMMON_DEFS})
  target_compile_options(deep_unzip_engine PRIVATE -fexceptions)

  # liblog 给 duz_engine.cpp 里的 DUZ_LOG 用（__android_log_print）。
  # bionic 里 liblog 是独立 .so，不显式链就是 undefined symbol，链接期就红。
  find_library(DUZ_LOG_LIB log REQUIRED)
  target_link_libraries(deep_unzip_engine PRIVATE Threads::Threads ${DUZ_LOG_LIB})

  # 关键的一行：**动态**链接 7-Zip。`PRIVATE` + 目标是 SHARED，CMake 会把它写成
  # DT_NEEDED 条目，运行期由系统的 linker 从同一个 lib 目录里找 `libduz7zip.so`
  # —— 那正是 §6b 要的「用户可以自己换掉这个库」。
  #
  # 别改成 `duz_7zip` 的静态库版本，也别把源文件列表直接塞进这个目标：那就退回
  # 静态链接，前面那段注释里说的问题会原样回来。
  target_link_libraries(deep_unzip_engine PRIVATE duz_7zip)

  # 面向 Android 16 设备的 16 KB 页对齐。NDK r28 默认已带，这里再显式声明一次，
  # 免得将来有人改了默认值而无人察觉（国内商店目前不要求，但成本为零）。
  # 两个 .so 都要对齐：页大小对不上的是**加载**，一个没对齐整包就起不来。
  target_link_options(duz_7zip PRIVATE "-Wl,-z,max-page-size=16384")
  target_link_options(deep_unzip_engine PRIVATE "-Wl,-z,max-page-size=16384")

  # 引擎这一侧只导出 duz_* 那十来个（见 duz_engine.h 的 DUZ_EXPORT）—— 7-Zip 的
  # 符号现在由 libduz7zip.so 负责导出，引擎自己的导出面仍然是一份可审计的短清单。
  target_link_options(deep_unzip_engine PRIVATE
    "-Wl,--exclude-libs,ALL"
  )
else()
  # 非 Android：只有那个明说「未编入核心」的占位实现，没有 7-Zip，也就没有第二个 .so。
  add_library(deep_unzip_engine SHARED "duz_engine.cpp")

  set_target_properties(deep_unzip_engine PROPERTIES
    OUTPUT_NAME "deep_unzip_engine"
    C_VISIBILITY_PRESET hidden
    CXX_VISIBILITY_PRESET hidden
  )

  target_include_directories(deep_unzip_engine PRIVATE ${DUZ_INCLUDE_DIRS})
  target_compile_definitions(deep_unzip_engine PRIVATE ${DUZ_COMMON_DEFS})
  target_compile_options(deep_unzip_engine PRIVATE -fexceptions)
endif()
