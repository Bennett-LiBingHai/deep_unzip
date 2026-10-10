// DeepUnzip 引擎的 C ABI。
//
// 这是 Dart(FFI) 与 7-Zip C++ 核心之间唯一的界面：刻意做得很薄，只暴露
// 「打开 / 列举 / 验证密码 / 全量解压 / 关闭」这一组动作，其余全部留在 C++ 侧。
// 薄的理由有两个：一是 ffigen 生成的绑定不必了解 7-Zip 的任何类型；二是将来
// 换后端（比如把 RAR 换成另一个实现）不用动 Dart 侧一个字节。
//
// 线程约定：**原生侧永不回调 Dart**，所有跨线程的信息都靠轮询取。
//
// 这条是硬约束，不是风格选择：7-Zip 的多线程解码路径会从它自己
// pthread_create 出来的工作线程里调 ICompressProgressInfo，而
// NativeCallable.isolateLocal 造出来的回调只能被 isolate 所在线程调用 ——
// 从别的线程调用会让 Dart VM 直接 FATAL，进程消失（2026-10-10 实测，
// 见 7zip-mt-worker-callback-crash 那条记录）。所以解压做成了
// start / poll / cancel 三段式：原生侧起自己的线程干活，Dart 用普通 FFI
// 轮询取进度。**任何时刻都不存在「原生 → Dart」这一步。**
//
// duz_open / duz_list 仍然是同步的（它们不回调）。duz_extract_start 立刻返回，
// 真正的解压跑在 C++ 自己的线程上。
//
// 生命周期：duz_open 返回的 ctx 归调用方所有，必须用 duz_close 释放；
// duz_list 返回的数组必须用 duz_free_entries 释放。duz_close 会先取消并
// join 可能还在跑的解压线程，所以随时调都安全。

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

// 解压进度的一次采样。由 duz_extract_poll 填。
typedef struct {
  uint64_t done;      // 已写出的字节数（单调不减）
  uint64_t total;     // 未压缩总量；0 = 未知（此时只看 done）
  int32_t running;    // 1 = 还在解压；0 = 已结束，下面两个字段才有意义
  int32_t cancelled;  // 1 = 这次解压是被 duz_extract_cancel 中止的
  int32_t rc;         // 结束时的 DUZ_ERR_*；cancelled 为 1 时恒为 DUZ_OK
} duz_progress_snapshot;

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
//     到解压（duz_extract_start 起、poll 出结局）才报 DUZ_ERR_PASSWORD。
//     这样 UI 可以先展示条目再去要密码。
//
// 失败返回 NULL，此时没有 ctx，用 duz_last_open_error()/…_code() 取原因。
DUZ_EXPORT duz_ctx* duz_open(const char* const* parts, int32_t n, const char* pwd);

// 上面失败时的错误文案（线程本地，复制即用，不要 free）。
DUZ_EXPORT const char* duz_last_open_error(void);

// 上面失败时的错误码（DUZ_ERR_* 之一）。单独给一个函数是因为文案只适合展示，
// 调用方要靠错误码决定「换个密码重试」还是「放弃这个包」。
DUZ_EXPORT int32_t duz_last_open_error_code(void);

// 上一次失败是不是「密码不对**或**数据已损坏，这两者分不出来」。1 = 分不出来。
//
// 只有 DUZ_ERR_PASSWORD 这一档才可能为 1，且**只有解压阶段**可能为 1。两种情形
// 都要求「这个格式没有密码校验字」：ZIP（AES 的校验字 / ZipCrypto 的头校验）和
// RAR5 有校验字，7-Zip 亲口报 kWrongPassword，那一档恒为 0 —— 它们是**能确定**的。
//
//   - 加密条目的**数据压根没解开**（kDataError）—— 压缩条目的 7z / RAR3；
//   - 加密条目的 **CRC 对不上**（kCRCError）—— **stored 条目**，那里没有解码器、
//     只有一次透明拷贝，密码错和坏数据都只能表现为 CRC 不匹配（2026-10-05 用
//     `7z a -mx0 -p` 造的包实测过，与 `-mx5` 那条的报错不同）。
//
// 反过来说：**有校验字的格式上 kCRCError 不算这一档**。那里密码错在解码之前就被
// 校验字拦下了，走不到 CRC —— CRC 失败恰恰证明密码是对的、坏的确实是数据。
//
// 它只影响**说法**，不影响**策略**：DUZ_ERR_PASSWORD 的含义与处置（换下一个
// 候选密码重试 duz_open / 弹密码窗）有它没它完全一样。做成一个单独的位而不是
// 新错误码，正是因为「分不清」不是一个路由概念 —— 写成错误码就等于让每个判
// DUZ_ERR_PASSWORD 的地方都得再多认一个值，漏一处就表现成「加密包不再试密码库」。
//
// 与 duz_last_open_error()/…_code() 同源同生命周期：紧挨着它们读，不要跨
// await，也不要拿一次成功调用的结果去用。
DUZ_EXPORT int32_t duz_last_error_uncertain(void);

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

// 开始全量解压到 outDir。outDir 必须已存在且可写。
// 路径安全（zip-slip、绝对路径、`..`）由 C++ 侧强制，Dart 侧还会再校验一次。
//
// **立刻返回**：解压跑在 C++ 自己的线程上（所以允许多线程解码器从它的工作
// 线程报进度，那条路碰不到 Dart）。返回值只说「有没有起得来」（DUZ_OK /
// DUZ_ERR_ARG / DUZ_ERR_UNSUPPORTED），解压的结局在 poll 的快照里。
//
// 一个 ctx 只解一次：重复调用返回 DUZ_ERR_ARG。
DUZ_EXPORT int32_t duz_extract_start(duz_ctx* ctx, const char* outDir);

// 取一次进度快照。**调用方自带名字缓冲**（nameBuf/nameBufLen）而不是让原生
// 返回内部指针 —— 那样的指针会在下一次写入时失效，Dart 读到的是野地址。
// 当前条目名以 UTF-8 写进 nameBuf（截断到 nameBufLen-1 字节），没有名字或
// nameBufLen <= 0 时写空串。
//
// 快照的 running 由 1 变 0 的**那一次**会顺手 join 解压线程，并把它的失败
// 原因搬进**调用线程**的 thread_local —— 于是 duz_last_open_error() 与
// duz_last_error_uncertain() 在 poll 出结局之后立刻就读得到，与 duz_open
// 失败时完全同源。之后每次 poll 仍返回 running=0 与同一个 rc（幂等）。
//
// 返回值只表示「这次查询本身有没有问题」（DUZ_OK / DUZ_ERR_ARG），
// 解压的结局在 out 里。
DUZ_EXPORT int32_t duz_extract_poll(duz_ctx* ctx, duz_progress_snapshot* out,
                                    char* nameBuf, int32_t nameBufLen);

// 请求中止正在跑的解压。可从任意线程调，幂等。
//
// 粒度是**条目/块边界**：7-Zip 在下一个进度点看到标志后返回 E_ABORT 并
// unwind。所以正在写的那个条目会被删掉（宁可留个空目录也不留一个长度不对的
// 文件），之前已解好的完整文件一个都不动。
//
// 如果解压恰在此前已经跑完，这次取消落空 —— 快照会给 cancelled=0、
// rc=DUZ_OK，调用方该把它当成功。
DUZ_EXPORT void duz_extract_cancel(duz_ctx* ctx);

DUZ_EXPORT void duz_close(duz_ctx* ctx);

// 取引擎版本串（形如 "7-Zip 26.03"），写进 buf。返回写入长度（不含结尾 0）。
DUZ_EXPORT int32_t duz_version(char* buf, int32_t bufLen);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // DUZ_ENGINE_H
