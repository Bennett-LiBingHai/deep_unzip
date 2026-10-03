// DeepUnzip 引擎的 C ABI。
//
// 这是 Dart(FFI) 与 7-Zip C++ 核心之间唯一的界面：刻意做得很薄，只暴露
// 「打开 / 列举 / 验证密码 / 全量解压 / 关闭」这一组动作，其余全部留在 C++ 侧。
// 薄的理由有两个：一是 ffigen 生成的绑定不必了解 7-Zip 的任何类型；二是将来
// 换后端（比如把 RAR 换成另一个实现）不用动 Dart 侧一个字节。
//
// 线程约定：所有函数都可能阻塞（解压大包是分钟级的），调用方必须放在
// 非主 isolate 里。
//
// 生命周期：duz_open 返回的 ctx 归调用方所有，必须用 duz_close 释放；
// duz_list 返回的数组必须用 duz_free_entries 释放。

#ifndef DUZ_ENGINE_H
#define DUZ_ENGINE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32)
#define DUZ_EXPORT __declspec(dllexport)
#else
#define DUZ_EXPORT __attribute__((visibility("default")))
#endif

// 错误码。0 为成功，负数为失败；具体文案用 duz_last_error 取。
enum {
  DUZ_OK = 0,
  DUZ_ERR_OPEN = -1,        // 打不开：格式不识别 / 分片缺失 / 文件损坏
  DUZ_ERR_PASSWORD = -2,    // 需要密码或密码错误
  DUZ_ERR_UNSUPPORTED = -3, // 该平台未编译 7-Zip 核心（非 Android 的占位实现）
  DUZ_ERR_ARG = -4,         // 参数非法
  DUZ_ERR_EXTRACT = -5,     // 解压中途失败
  DUZ_ERR_NOMEM = -6,
};

typedef struct duz_ctx duz_ctx;

// 一条目录项。name 是 UTF-8，归 ctx 所有，duz_close 前一直有效。
typedef struct {
  const char* name;   // 归档内的相对路径；目录以 '/' 结尾
  uint64_t size;      // 原始（未压缩）大小
  uint32_t crc;       // 7-Zip 报的 CRC32；不适用时为 0
  int32_t is_dir;
  int32_t encrypted;  // 该条目是否加密（决定了要不要试密码库）
  int32_t index;      // 在归档中的序号（IInArchive 的下标），单条操作时用
} duz_entry;

// 进度回调。done/total 为字节；total 为 0 表示未知（此时只报 done）。
// currentEntry 是当前条目名，可为 NULL。
// 返回非 0 表示请求取消，解压会尽快中止并返回 DUZ_ERR_EXTRACT。
typedef int (*duz_progress_cb)(void* userData, uint64_t done, uint64_t total,
                               const char* currentEntry);

// 打开一个归档。
//
// parts/n 描述分卷：单卷传长度为 1 的数组；多卷按**正确的顺序**传全部路径
// （顺序由 Dart 侧的 split.dart 决定，C++ 侧不猜）。实现上以 parts[0] 所在
// 目录为基准目录，7-Zip 通过 IArchiveOpenVolumeCallback 按需取后续卷，因此
// 分卷必须与首卷同目录（本 app 的场景都满足）。
//
// pwd 可为 NULL。密码有**两种**失效方式，返回值能把它们分开：
//   - 归档头加密（7-Zip 常见）：没给密码或密码错时**打不开**，duz_open 返回
//     NULL，duz_last_open_error_code() 给 DUZ_ERR_PASSWORD。调用方应换下一个
//     候选密码重试 duz_open。
//   - 仅条目加密（ZIP 常见）：不打密码也能打开并列出条目，duz_open 成功；
//     到 duz_extract_all 才返回 DUZ_ERR_PASSWORD。这样 UI 可以先展示条目
//     再去要密码。
//
// 失败返回 NULL，此时没有 ctx，用 duz_last_open_error()/…_code() 取原因。
DUZ_EXPORT duz_ctx* duz_open(const char* const* parts, int32_t n, const char* pwd);

// 上面失败时的错误文案（线程本地，复制即用，不要 free）。
DUZ_EXPORT const char* duz_last_open_error(void);

// 上面失败时的错误码（DUZ_ERR_* 之一）。单独给一个函数是因为文案只适合展示，
// 调用方要靠错误码决定「换个密码重试」还是「放弃这个包」。
DUZ_EXPORT int32_t duz_last_open_error_code(void);

// 列条目。成功时 *out 指向 malloc 出来的数组（count 个），调用方用
// duz_free_entries 释放。只读中央目录，不解压任何数据。
//
// 注意所有权被切开：数组本身归调用方（用 duz_free_entries 释放），但
// entry.name 指向的字节归 ctx。因此**再次调用 duz_list 会让上一次返回的
// 数组内容失效**，而 duz_close 之后整个数组都不再可用。
DUZ_EXPORT int32_t duz_list(duz_ctx* ctx, duz_entry** out, int32_t* count);

DUZ_EXPORT void duz_free_entries(duz_entry* entries, int32_t count);

// 廉价验证密码：只解最小的一条/用格式自带的校验位，**绝不整包试解**。
// 返回 DUZ_OK 表示密码正确，DUZ_ERR_PASSWORD 表示错误。
DUZ_EXPORT int32_t duz_verify_password(duz_ctx* ctx, const char* pwd);

// 全量解压到 outDir。outDir 必须已存在且可写。
// 路径安全（zip-slip、绝对路径、`..`）由 C++ 侧强制，Dart 侧还会再校验一次。
DUZ_EXPORT int32_t duz_extract_all(duz_ctx* ctx, const char* outDir,
                                   duz_progress_cb cb, void* userData);

DUZ_EXPORT void duz_close(duz_ctx* ctx);

// 取引擎版本串（形如 "7-Zip 26.03"），写进 buf。返回写入长度（不含结尾 0）。
DUZ_EXPORT int32_t duz_version(char* buf, int32_t bufLen);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // DUZ_ENGINE_H
