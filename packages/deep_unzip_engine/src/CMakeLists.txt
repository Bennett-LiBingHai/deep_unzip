# DeepUnzip 引擎的本地构建脚本。
#
# 本文件同时被 android/ 与 windows/ 的 Gradle/CMake 复用，所以要显式区分平台：
# **7-Zip 的源清单取自官方 gcc makefile（CPP/7zip/Bundles/Format7zF/Arc_gcc.mak
# 与 Bundles/Alone2/makefile.gcc），那是非 Windows 配置，不含 DLL/Registry/
# MemoryLock/FileSystem 这些 Windows 专用对象。** 拿它去编 Windows 桌面版必然会
# 缺符号。所以这里只在 ANDROID 下链入 7-Zip；其余平台编出来的 duz_engine 是个
# 明说「未编入核心」的占位实现（见 duz_engine.cpp），不会静默给出错误结果。
#
# cmake_minimum_required 定在 3.13：用到 target_link_options(3.13+)，而本机
# Android SDK 自带的是 3.22.1。这是私有插件、不上架 pub，不必迁就 3.10。

cmake_minimum_required(VERSION 3.13)

project(deep_unzip_engine_library VERSION 0.0.1 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(DUZ_7ZIP_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/7zip")

set(DUZ_SOURCES
  "duz_engine.cpp"
)

if(ANDROID)
  if(NOT EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/7zip_sources.cmake")
    message(FATAL_ERROR
      "缺少 src/7zip_sources.cmake。请在 packages/deep_unzip_engine 下执行：\n"
      "  bash tool/gen_7zip_sources.sh third_party/7zip src/7zip_sources.cmake")
  endif()
  include("${CMAKE_CURRENT_SOURCE_DIR}/7zip_sources.cmake")
  list(APPEND DUZ_SOURCES ${DUZ_7ZIP_SOURCES})

  # 7-Zip 全部 COM 接口 GUID 的定义单元。官方的这个角色由 console 的 Main.cpp
  # 担任，而我们的清单刻意没收 Main.cpp（它有 main() 与整块控制台 UI），
  # 所以必须自己补一个 —— 否则链接期会报 20 个 IID_* undefined symbol。
  # 只在 ANDROID 下编，因为这种文件依赖 third_party 里的 7-Zip 头。
  list(APPEND DUZ_SOURCES "7zip_guids.cpp")
endif()

add_library(deep_unzip_engine SHARED ${DUZ_SOURCES})

set_target_properties(deep_unzip_engine PROPERTIES
  OUTPUT_NAME "deep_unzip_engine"
  C_VISIBILITY_PRESET hidden
  CXX_VISIBILITY_PRESET hidden
)

# 7-Zip 自己的头文件用相对包含；`CPP` 与 `C` 两个根必须在搜索路径上。
target_include_directories(deep_unzip_engine PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}"
  "${DUZ_7ZIP_ROOT}/CPP"
  "${DUZ_7ZIP_ROOT}/C"
)

# 与 7-Zip 官方 gcc makefile 的 CFLAGS_BASE 对齐：
#   _FILE_OFFSET_BITS=64 / _LARGEFILE_SOURCE —— 大文件（>2G）与 64 位偏移
#   _REENTRANT                             —— MT 模式下的线程安全声明
#   NDEBUG                                 —— 关掉 assert（release 语义）
# 注意**不传 -Werror**：官方 makefile 里有 -Werror -Wall -Wextra，那是给
# 官方 CI 用的；NDK 的 clang 版本与之不同，一堆新告警会把构建打死。
target_compile_definitions(deep_unzip_engine PRIVATE
  $<$<CONFIG:Release>:NDEBUG>
  _FILE_OFFSET_BITS=64
  _LARGEFILE_SOURCE
  _REENTRANT
  # Flutter 的 FFI 插件模板会带这个宏；保留它以维持与工具链既有约定的兼容。
  DART_SHARED_LIB
)

# 例外由 7-Zip 大量使用（错误传播全靠 throw），必须开。
target_compile_options(deep_unzip_engine PRIVATE -fexceptions)

if(ANDROID)
  # 多线程（MT）模式用了 pthread；bionic 里就在 libc，显式写上更清楚。
  find_package(Threads REQUIRED)
  # liblog 给 duz_engine.cpp 里的 DUZ_LOG 用（__android_log_print）。
  # bionic 里 liblog 是独立 .so，不显式链就是 undefined symbol，链接期就红。
  find_library(DUZ_LOG_LIB log REQUIRED)
  target_link_libraries(deep_unzip_engine PRIVATE Threads::Threads ${DUZ_LOG_LIB})

  # 面向 Android 16 设备的 16 KB 页对齐。NDK r28 默认已带，这里再显式声明一次，
  # 免得将来有人改了默认值而无人察觉（国内商店目前不要求，但成本为零）。
  target_link_options(deep_unzip_engine PRIVATE "-Wl,-z,max-page-size=16384")

  # 不导出 7-Zip 的符号，只留 duz_* 那十来个（见 duz_engine.h 的 DUZ_EXPORT）。
  # 这既是体积考虑，也让「引擎导出面」成为一个可审计的清单。
  target_link_options(deep_unzip_engine PRIVATE
    "-Wl,--exclude-libs,ALL"
  )
endif()
