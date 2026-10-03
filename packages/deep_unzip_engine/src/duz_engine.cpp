// duz_engine.h 的实现 —— 接上 7-Zip 核心。
//
// 分工：
//   - 打开与格式级联：UI/Common/OpenArchive.h 的 CArchiveLink::Open2()，它内部
//     会用 COpenCallbackImp 处理**分卷**（IArchiveOpenVolumeCallback）和
//     **密码**（ICryptoGetTextPassword）。传空的 types 向量 = 不限格式，
//     7-Zip 会逐个 handler 试探 —— 这正是「后缀被篡改也能识别」的实现。
//   - 落盘：复用 UI/Common/ArchiveExtractCallback.cpp 的 CArchiveExtractCallback。
//     自己再写一份 IArchiveExtractCallback 是重复劳动，而且要重新实现目录创建、
//     覆盖策略、时间戳、符号链接、以及最要紧的 zip-slip 防护
//     （它内部走 Correct_FsPath，把 "." ".." 和空路径段替换掉）。
//     我们只实现它需要的 IFolderArchiveExtractCallback（6 个方法）来收进度、
//     报错、给密码。
//
// 只在 Android 上编 7-Zip：源清单取自官方 gcc makefile（非 MSVC 配置，不含
// DLL/Registry/MemoryLock 这些 Windows 专用对象）。其余平台走骨架实现，
// 明说「未编入核心」，不会静默给出错误结果。

#include "duz_engine.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// 原生侧的诊断日志。
//
// 为什么非要有它：这个文件原先一行日志都没有，于是「解压卡住、进程随后消失」
// 在 Dart 侧是完全不可观测的 —— 只在「进去了」和「没出来」之间猜，而这两点
// 之间隔着一整个 7-Zip。真机上唯一能用的观测手段就是 logcat：
//
//   - 它是 logd 托管的环形缓冲，**进程被杀之后日志还在**；
//   - tombstone 只在 SIGSEGV/SIGABRT 时产生。被 LMK 杀掉、或者自己的线程跑飞
//     之后被系统回收，是安静地消失，什么都不留 —— 冒烟测试第一次跑就是这种。
//
// 只在 Android 上编进去，其它平台是空实现。
#if defined(__ANDROID__)
  #include <android/log.h>
  #define DUZ_LOG(...) \
    __android_log_print(ANDROID_LOG_INFO, "DUZ", __VA_ARGS__)
#else
  #define DUZ_LOG(...) ((void)0)
#endif

#if defined(__ANDROID__) && !defined(DUZ_FORCE_SKELETON)
  #define DUZ_HAS_7ZIP 1
#else
  #define DUZ_HAS_7ZIP 0
#endif

// 每线程一条错误文案 + 一个错误码，避免调用方 free、也避免跨线程踩踏。
namespace {
thread_local char g_openError[512] = "尚未接上 7-Zip 核心";
thread_local int32_t g_openErrorCode = DUZ_ERR_OPEN;

void SetOpenError(int32_t code, const char* msg) {
  g_openErrorCode = code;
  if (!msg) msg = "";
  strncpy(g_openError, msg, sizeof(g_openError) - 1);
  g_openError[sizeof(g_openError) - 1] = '\0';
}
}  // namespace

#if !DUZ_HAS_7ZIP

// ---------------------------------------------------------------------------
// 骨架实现（非 Android）
// ---------------------------------------------------------------------------

struct duz_ctx {
  int placeholder = 0;
};

extern "C" {

duz_ctx* duz_open(const char* const* parts, int32_t n, const char* pwd) {
  (void)parts;
  (void)pwd;
  if (!parts || n <= 0) {
    SetOpenError(DUZ_ERR_ARG, "duz_open: parts 为空");
    return nullptr;
  }
  SetOpenError(DUZ_ERR_UNSUPPORTED, "本构建未编入 7-Zip 核心（当前为骨架实现）");
  return nullptr;
}

const char* duz_last_open_error(void) { return g_openError; }
int32_t duz_last_open_error_code(void) { return g_openErrorCode; }

int32_t duz_list(duz_ctx* ctx, duz_entry** out, int32_t* count) {
  (void)ctx;
  if (out) *out = nullptr;
  if (count) *count = 0;
  return DUZ_ERR_UNSUPPORTED;
}

void duz_free_entries(duz_entry* entries, int32_t count) {
  (void)count;
  free(entries);
}

int32_t duz_verify_password(duz_ctx* ctx, const char* pwd) {
  (void)ctx;
  (void)pwd;
  return DUZ_ERR_UNSUPPORTED;
}

int32_t duz_extract_all(duz_ctx* ctx, const char* outDir, duz_progress_cb cb,
                        void* userData) {
  (void)ctx;
  (void)outDir;
  (void)cb;
  (void)userData;
  return DUZ_ERR_UNSUPPORTED;
}

void duz_close(duz_ctx* ctx) { delete ctx; }

int32_t duz_version(char* buf, int32_t bufLen) {
  static const char kVersion[] = "DeepUnzip engine (skeleton)";
  const int32_t n = (int32_t)sizeof(kVersion) - 1;
  if (buf && bufLen > 0) {
    const int32_t c = (n < bufLen - 1) ? n : (bufLen - 1);
    memcpy(buf, kVersion, (size_t)c);
    buf[c] = '\0';
    return c;
  }
  return n;
}

}  // extern "C"

#else  // DUZ_HAS_7ZIP

// ---------------------------------------------------------------------------
// 真实实现（Android）
// ---------------------------------------------------------------------------

#include <deque>
#include <mutex>
#include <string>

#include "7zVersion.h"  // 7-Zip 自己的版本宏，免得我们手抄一份还写歪

#include "Common/MyWindows.h"
#include "Common/MyCom.h"
#include "Common/MyString.h"
#include "Common/StringConvert.h"

#include "Windows/FileDir.h"
#include "Windows/FileFind.h"
#include "Windows/PropVariant.h"
#include "Windows/PropVariantConv.h"

#include "7zip/Archive/IArchive.h"
#include "7zip/IPassword.h"
#include "7zip/IProgress.h"
#include "7zip/PropID.h"
#include "7zip/UI/Common/ArchiveExtractCallback.h"
#include "7zip/UI/Common/ExtractMode.h"
#include "7zip/UI/Common/LoadCodecs.h"
#include "7zip/UI/Common/OpenArchive.h"

using namespace NWindows;
using namespace NFile;

namespace {

// 单次解压允许 7-Zip 申请的内存上限（炸弹防护的第一道闸；总展开量的阈值
// 在 Dart 侧 limits.dart，因为那边才知道用户设的限额）。
const UInt64 kMemLimit = (UInt64)512 << 20;

// ---- UTF-8 ↔ 7-Zip 字符串 ----
// Android 上 FString == AString == UTF-8 字节串，UString 是 32 位 wchar_t。
// 7-Zip 的非 Windows 构建把 g_ForceToUTF8 默认置 true，所以 fs2us/us2fs 就是
// UTF-8 ↔ UTF-32 的转换，正好对齐我们 ABI 的 UTF-8 char*。
// 刻意不走 GetCurrentCodePage()/CP_ACP 那条路 —— 那条在非 Windows 上是
// 由 locale 推出来的，而 app 里没人设过 locale。
UString Utf8ToU(const char* s) { return s ? fs2us(s) : UString(); }
std::string UToUtf8(const UString& u) {
  const AString a = us2fs(u);
  return std::string(a.Ptr(), a.Len());
}
FString Utf8ToFs(const char* s) { return us2fs(Utf8ToU(s)); }

// FString -> UTF-8。与 UToUtf8 的区别只在于入口已经是文件系统形态：
// Android 上 FString 就是 UTF-8 字节串（见上面那段注释），所以不需要再转码，
// 直接按 Len() 取字节。单独写一个是为了不在调用处散落 `std::string(p, n)`。
std::string FToUtf8(const FString& f) {
  return f.Ptr() ? std::string(f.Ptr(), f.Len()) : std::string();
}

// ---- 进程级 CCodecs 单例 ----
// CCodecs::Load() 只是把静态注册表（各 handler 的 REGISTER_ARC_* 产生的
// 静态对象）收进 Formats 向量，不做 IO，但也没必要每次 duz_open 重来一遍。
//
// 故意让它泄漏到进程结束，也不去动引用计数：AddRef/Release 在本头里是
// private（Z7_COM_UNKNOWN_IMP_0 展开出来的），而 CCodecs::Load() 自己根本不碰
// 引用计数 —— 我们只把裸指针交给 COpenOptions::codecs，没有任何一方会去
// Release 它。这样最省事，也避开了跨线程析构的竞态。
CCodecs* GetCodecs() {
  static std::once_flag once;
  static CCodecs* s = nullptr;
  std::call_once(once, [] {
    CCodecs* c = new CCodecs;
    if (c->Load() == S_OK)
      s = c;
    else
      delete c;
  });
  return s;
}

bool HasErrorFlag(const CArcErrorInfo& info, UInt32 flag) {
  return info.ErrorFlags_Defined && (info.ErrorFlags & flag) != 0;
}

}  // namespace

// 前向声明：回调要用到 ctx 的字段
struct duz_ctx;

namespace {

// ---- 打开阶段的回调 ----
// COpenCallbackImp 把 IArchiveOpenCallback / IArchiveOpenVolumeCallback /
// ICryptoGetTextPassword 三种 COM 口都转到这一个 C++ 口上。我们只关心
// 「要不要中断」和「密码是什么」。
class DuzOpenCallback final : public IOpenCallbackUI {
  duz_ctx* _ctx;
 public:
  explicit DuzOpenCallback(duz_ctx* ctx) : _ctx(ctx) {}

  HRESULT Open_CheckBreak() override { return S_OK; }
  HRESULT Open_SetTotal(const UInt64* /*files*/, const UInt64* /*bytes*/) override {
    return S_OK;
  }
  HRESULT Open_SetCompleted(const UInt64* /*files*/, const UInt64* /*bytes*/) override {
    return S_OK;
  }
  HRESULT Open_Finished() override { return S_OK; }
  HRESULT Open_CryptoGetTextPassword(BSTR* password) override;
};

// ---- 解压阶段的回调 ----
class DuzExtractCallback final : public IFolderArchiveExtractCallback,
                                 public IFolderArchiveExtractCallback2,
                                 public ICryptoGetTextPassword,
                                 public CMyUnknownImp {
  Z7_COM_QI_BEGIN2(IFolderArchiveExtractCallback)
  Z7_COM_QI_ENTRY(IFolderArchiveExtractCallback2)
  Z7_COM_QI_ENTRY(ICryptoGetTextPassword)
  Z7_COM_QI_END
  Z7_COM_ADDREF_RELEASE

  Z7_COM7F_IMP(SetTotal(UInt64 total))
  Z7_COM7F_IMP(SetCompleted(const UInt64* completeValue))
  Z7_IFACE_COM7_IMP(IFolderArchiveExtractCallback)
  Z7_IFACE_COM7_IMP(IFolderArchiveExtractCallback2)
  Z7_IFACE_COM7_IMP(ICryptoGetTextPassword)

 public:
  duz_ctx* Ctx;
  duz_progress_cb Progress;
  void* UserData;

  UInt64 UnpackTotal;
  std::string CurrentName;  // UTF-8，给 progress 回调用
  UInt32 FailedCount;
  bool SawWrongPassword;
  bool Cancelled;
  std::string FirstError;  // UTF-8

  // 7-Zip 那个真正的落盘回调。条目失败时要靠它问出「刚写的那个文件在哪」——
  // 见 ArchiveExtractCallback.h 里 Get_DiskFilePath 的说明。由 duz_extract_all
  // 在两边都构造完之后接上，所以这里给 nullptr 兜底。
  CArchiveExtractCallback* Ecs = nullptr;

  // 失败清理的战果，用于如实汇报（见 duz_extract_all 结尾）。
  UInt32 RemovedCount = 0;        // 删掉的损坏文件数
  UInt32 RemoveFailedCount = 0;   // 想删但没删掉的（不是文件不存在）

  // 只给日志用：7-Zip 报进度的频率可以很高，全量打会把 logcat 淹掉、也拖慢
  // 解压。但**开头几条必须全留** —— 卡死的位置几乎总在最前面。
  unsigned long long ReportCalls;

  DuzExtractCallback(duz_ctx* ctx, duz_progress_cb cb, void* userData)
      : Ctx(ctx),
        Progress(cb),
        UserData(userData),
        UnpackTotal(0),
        FailedCount(0),
        SawWrongPassword(false),
        Cancelled(false),
        ReportCalls(0) {}

  /// 条目失败之后，把已经写下去的那份**残档**删掉。
  ///
  /// 为什么非删不可：7-Zip 是「先写文件、再比 CRC」，所以校验失败的那一刻，
  /// 一个**内容错误、长度正确**的文件已经躺在输出目录里了。真机验收时
  /// `broken.zip` 就是这么留了个坏 `ok.txt` 下来的 —— 文件名、大小、时间戳
  /// 全都正常，用户没有任何办法看出它是坏的。**静默给出错误数据比解压失败
  /// 严重得多**，所以宁可目录里什么都没有。
  ///
  /// 只删**这一个文件**，不碰同批解出来的好文件：一个 4GB 的包里有 1 个坏
  /// 条目，把其余全删掉是另一种伤害。
  void RemoveFailedOutput();

  HRESULT Report(UInt64 done) {
    if (!Progress) return S_OK;
    ++ReportCalls;
    if (ReportCalls <= 8 || (ReportCalls % 500) == 0) {
      DUZ_LOG("Report #%llu done=%llu total=%llu name=%s", ReportCalls,
              (unsigned long long)done, (unsigned long long)UnpackTotal,
              CurrentName.empty() ? "(none)" : CurrentName.c_str());
    }
    if (Progress(UserData, done, UnpackTotal,
                 CurrentName.empty() ? nullptr : CurrentName.c_str()) != 0) {
      DUZ_LOG("Report: 回调要求取消");
      Cancelled = true;
      return E_ABORT;
    }
    return S_OK;
  }
};

}  // namespace

// ---------------------------------------------------------------------------
// ctx
// ---------------------------------------------------------------------------

struct duz_ctx {
  CArchiveLink arcLink;
  CObjectVector<COpenType> types;        // 留空 = 不限格式，逐 handler 试探
  CIntVector excludedFormats;
  UString filePath;                      // 首卷路径（UString）
  std::string password;                  // UTF-8
  bool passwordGiven = false;

  // duz_list 产出的名字字节；entry.name 指进来，所以必须用地址稳定的容器。
  std::deque<std::string> nameStore;

  UInt64 packTotal = 0;                  // 首卷 + 所有被用到的后续卷的字节数
  UInt64 unpackTotal = 0;                // 所有条目原始大小之和（列条目时算）
  bool unpackTotalKnown = false;

  bool AnyArchiveOpen() const { return arcLink.Arcs.Size() > 0; }
  IInArchive* Archive() const {
    return arcLink.Arcs.IsEmpty() ? nullptr : arcLink.Arcs.Back().Archive;
  }
};

namespace {

HRESULT DuzOpenCallback::Open_CryptoGetTextPassword(BSTR* password) {
  *password = nullptr;  // 7-Zip 的约定：无论成败都先置空
  if (!_ctx->passwordGiven) {
    // 没有候选密码就如实说「没有」。7-Zip 会因此把头加密的包判为打不开，
    // 我们据此返回 DUZ_ERR_PASSWORD，让 Dart 换下一个候选密码重试。
    return E_NOTIMPL;
  }
  return StringToBstr(fs2us(_ctx->password.c_str()), password);
}

// ---- IFolderArchiveExtractCallback ----

Z7_COM7F_IMF(DuzExtractCallback::SetTotal(UInt64 total)) {
  // 7-Zip 报的 total 是「未压缩总量」，与我们的进度语义一致，直接转发。
  DUZ_LOG("SetTotal total=%llu", (unsigned long long)total);
  UnpackTotal = total;
  return Report(0);
}

Z7_COM7F_IMF(DuzExtractCallback::SetCompleted(const UInt64* completeValue)) {
  if (!completeValue) return S_OK;
  return Report(*completeValue);
}

Z7_COM7F_IMF(DuzExtractCallback::AskOverwrite(
    const wchar_t* /*existName*/, const FILETIME* /*existTime*/,
    const UInt64* /*existSize*/, const wchar_t* /*newName*/,
    const FILETIME* /*newTime*/, const UInt64* /*newSize*/, Int32* answer)) {
  // kOverwrite 模式下不会被调用；真被调到就选覆盖（解压到我们自己新建的
  // 输出目录，覆盖是预期行为）。P3 接「暂停/跳过」时这里换成问用户。
  *answer = NOverwriteAnswer::kYes;
  return S_OK;
}

Z7_COM7F_IMF(DuzExtractCallback::PrepareOperation(
    const wchar_t* name, Int32 isFolder, Int32 askExtractMode,
    const UInt64* position)) {
  CurrentName = name ? UToUtf8(UString(name)) : std::string();
  DUZ_LOG("PrepareOperation mode=%d folder=%d pos=%d name=%s", (int)askExtractMode,
          (int)isFolder,
          position ? (int)*position : -1,
          CurrentName.empty() ? "(none)" : CurrentName.c_str());
  return S_OK;
}

Z7_COM7F_IMF(DuzExtractCallback::MessageError(const wchar_t* message)) {
  ++FailedCount;
  const std::string m = message ? UToUtf8(UString(message)) : std::string();
  DUZ_LOG("MessageError: %s", m.empty() ? "(empty)" : m.c_str());
  if (FirstError.empty() && !m.empty()) FirstError = m;
  return S_OK;
}

Z7_COM7F_IMF(DuzExtractCallback::SetOperationResult(Int32 opRes, Int32 encrypted)) {
  DUZ_LOG("SetOperationResult opRes=%d enc=%d name=%s", (int)opRes, (int)encrypted,
          CurrentName.empty() ? "(none)" : CurrentName.c_str());
  if (opRes == NArchive::NExtract::NOperationResult::kOK) return S_OK;
  if (opRes == NArchive::NExtract::NOperationResult::kWrongPassword)
    SawWrongPassword = true;
  ++FailedCount;
  if (FirstError.empty()) {
    switch (opRes) {
      case NArchive::NExtract::NOperationResult::kUnsupportedMethod:
        FirstError = "压缩方法不受支持";
        break;
      case NArchive::NExtract::NOperationResult::kCRCError:
        FirstError = "CRC 校验失败（文件已损坏）";
        break;
      case NArchive::NExtract::NOperationResult::kDataError:
        FirstError = "数据错误（文件已损坏）";
        break;
      case NArchive::NExtract::NOperationResult::kUnexpectedEnd:
        FirstError = "数据意外结束（文件被截断）";
        break;
      case NArchive::NExtract::NOperationResult::kWrongPassword:
        FirstError = "密码错误";
        break;
      default:
        FirstError = "解压失败";
        break;
    }
  }

  // 到这里这个条目的输出已经在盘上了（7-Zip 在调用我们之前跑过
  // CloseReparseAndFile），而它已经被判为坏的 —— 清掉。
  RemoveFailedOutput();
  return S_OK;
}

void DuzExtractCallback::RemoveFailedOutput() {
  if (!Ecs) return;

  // 必须是 7-Zip 记的那份磁盘路径，不能用条目名自己拼 —— 两者在名字需要
  // 清洗时不一致（见 Get_DiskFilePath 的说明）。
  const FString& path = Ecs->Get_DiskFilePath();
  if (path.IsEmpty()) return;  // 还没定下落盘位置（目录条目、流模式等）

  // 先看有没有：方法不受支持、或加密条目根本没解出内容时，7-Zip 压根没建
  // 文件，这时**不是**清理失败，不该计进 RemoveFailedCount 去吓用户。
  if (!NFind::DoesFileExist_Raw(path)) return;

  if (NDir::DeleteFileAlways(path)) {
    ++RemovedCount;
    DUZ_LOG("已删除损坏输出 %s", FToUtf8(path).c_str());
  } else {
    // 立刻取错误码：后面任何一次系统调用都会把它冲掉。
    const unsigned long err = (unsigned long)GetLastError();
    ++RemoveFailedCount;
    DUZ_LOG("删不掉损坏输出 %s 错误码=%lu", FToUtf8(path).c_str(), err);
  }
}

// ---- IFolderArchiveExtractCallback2 ----

Z7_COM7F_IMF(DuzExtractCallback::ReportExtractResult(
    Int32 opRes, Int32 /*encrypted*/, const wchar_t* /*name*/)) {
  if (opRes != NArchive::NExtract::NOperationResult::kOK) ++FailedCount;
  return S_OK;
}

// ---- ICryptoGetTextPassword ----

Z7_COM7F_IMF(DuzExtractCallback::CryptoGetTextPassword(BSTR* password)) {
  *password = nullptr;
  if (!Ctx->passwordGiven) return E_NOTIMPL;
  return StringToBstr(fs2us(Ctx->password.c_str()), password);
}

// ---- 公用出口 ----

// 7-Zip **打不开文件本身**时（不是打不开归档，是连文件都没读到），返回的是
// `GetLastError_noZero_HRESULT()` —— 见 UI/Common/OpenArchive.cpp 的
// `CArc::OpenStreamOrFile`：它自己 new 一个 CInFileStream 去 Open 那个路径，
// 失败就直接 return，**完全不往 NonOpen_ErrorInfo 里写任何字段**。
//
// 后果是「文件不存在」和「没权限读」这两类最常见的失败全都会落进下面的兜底
// 分支，变成一句没有信息量的「打开失败」。真机上这极易被误读成「格式不支持」
// 或「引擎坏了」，然后朝完全错误的方向排查 —— 冒烟测试第一次跑就撞上了这个坑，
// 当时只能靠翻 7-Zip 源码才定位到「根本没读到文件」。
//
// 那个 HRESULT 的低 16 位就是原始错误值：POSIX 下是 errno，Windows 下是 Win32
// 错误码（facility 分别是 MY_FACILITY_ERRNO=0x800 和 FACILITY_WIN32=7）。解出来
// 就能说人话。
std::string DescribeIoFailure(HRESULT res) {
  const unsigned long code = static_cast<unsigned long>(res) & 0xFFFFu;
  if (code == 0) return "打开失败（7-Zip 未给出具体原因）";

#ifdef _WIN32
  switch (code) {
    case ERROR_FILE_NOT_FOUND: return "文件不存在";
    case ERROR_PATH_NOT_FOUND: return "路径不存在";
    case ERROR_ACCESS_DENIED: return "无权读取该文件";
    case ERROR_SHARING_VIOLATION: return "文件正被其它程序占用";
    default: break;
  }
#else
  switch (code) {
    case ENOENT:
      return "文件不存在：路径不对，或者文件还没传到设备上";
    case EACCES:
    case EPERM:
      return "无权读取该文件：请在系统设置里给本应用打开「所有文件访问权限」";
    case EISDIR:
      return "这是一个目录，不是文件";
    case ENOTDIR:
      return "路径中间有一段不是目录";
    case ENAMETOOLONG:
      return "路径过长";
    case ELOOP:
      return "符号链接层数过多";
    default: break;
  }
#endif

  // 认不出来也别退回「打开失败」—— 把原始码带上，下一次至少不用再猜一轮。
  char buf[64];
  snprintf(buf, sizeof(buf), "打开文件失败（错误码 %lu）", code);
  return buf;
}

// 把非 S_OK 的 HRESULT 变成人能看的一句话，写进 g_openError。
void DescribeOpenFailure(const CArchiveLink& arcLink, HRESULT res) {
  const CArcErrorInfo& info = arcLink.NonOpen_ErrorInfo;

  int32_t code = DUZ_ERR_OPEN;
  if (arcLink.PasswordWasAsked ||
      HasErrorFlag(info, kpv_ErrorFlags_EncryptedHeadersError)) {
    code = DUZ_ERR_PASSWORD;
  } else if (HasErrorFlag(info, kpv_ErrorFlags_UnsupportedMethod) ||
             HasErrorFlag(info, kpv_ErrorFlags_UnsupportedFeature)) {
    code = DUZ_ERR_UNSUPPORTED;
  }

  std::string msg;
  if (!info.ErrorMessage.IsEmpty()) {
    msg = UToUtf8(info.ErrorMessage);
  } else if (!info.WarningMessage.IsEmpty()) {
    msg = UToUtf8(info.WarningMessage);
  } else if (info.ErrorFlags_Defined) {
    if (info.ErrorFlags & kpv_ErrorFlags_IsNotArc)
      msg = "无法识别的归档格式（已逐个格式试探过）";
    else if (info.ErrorFlags & kpv_ErrorFlags_EncryptedHeadersError)
      msg = "归档头已加密，需要密码";
    else if (info.ErrorFlags & kpv_ErrorFlags_UnexpectedEnd)
      msg = "数据意外结束：文件被截断，或分卷不齐";
    else if (info.ErrorFlags & kpv_ErrorFlags_UnsupportedMethod)
      msg = "使用了本引擎不支持的方法";
    else
      msg = "打开失败";
  } else if (res == E_ABORT) {
    msg = "已取消";
  } else {
    // 走到这里基本就是「连文件都没打开」—— 见 DescribeIoFailure 的说明。
    msg = DescribeIoFailure(res);
  }

  if (msg.size() > sizeof(g_openError) - 1) msg.resize(sizeof(g_openError) - 1);
  SetOpenError(code, msg.c_str());
}

}  // namespace

extern "C" {

duz_ctx* duz_open(const char* const* parts, int32_t n, const char* pwd) {
  if (!parts || n <= 0 || !parts[0]) {
    SetOpenError(DUZ_ERR_ARG, "duz_open: parts 为空");
    return nullptr;
  }
  CCodecs* codecs = GetCodecs();
  if (!codecs) {
    SetOpenError(DUZ_ERR_UNSUPPORTED, "7-Zip 格式表加载失败");
    return nullptr;
  }

  duz_ctx* ctx = new duz_ctx;
  ctx->filePath = Utf8ToU(parts[0]);
  if (pwd && pwd[0]) {
    ctx->password = pwd;
    ctx->passwordGiven = true;
  }

  COpenOptions op;
  op.codecs = codecs;
  op.types = &ctx->types;  // 空 -> 不限格式，逐 handler 试探
  op.excludedFormats = &ctx->excludedFormats;
  op.stdInMode = false;
  op.stream = nullptr;
  op.filePath = ctx->filePath;

  // `props` 必须显式置空。**这一行是拿一次真机崩溃换来的，别删。**
  //
  // `COpenOptions` 是 POD 风格的结构体，但它的默认构造函数只初始化了
  // codecs/types/excludedFormats/stream/seqStream/callback/callbackSpec/stdInMode
  // 八个字段 —— `props`（`OPEN_PROPS_DECL` 展开成
  // `const CObjectVector<CProperty>*`，一个**裸指针**）不在其中。
  // 于是默认构造出来的是**未定义的栈垃圾**，不是 nullptr。
  //
  // 而 `CArc::PrepareToOpen` 是这么用的（OpenArchive.cpp:1365）：
  //
  //     if (op.props)
  //       RINOK(SetProperties(archive, *op.props))
  //
  // 「留空 = 不设属性」这个语义**靠的就是 nullptr**，垃圾值一样能通过那个
  // if。接下来的 `SetProperties` 会先 `properties.IsEmpty()` 去读垃圾指针
  // 指向的 `_size`，再 `CPropPropetiesVector values(properties.Size())` ->
  // `new CPropVariant[num]`。
  //
  // 两种结局，我们两种都撞上了：
  //   - 垃圾指针指向未映射的页 -> SIGSEGV。符号化后的调用栈是
  //     duz_open -> CArchiveLink::Open2 -> ... -> SetProperties -> IsEmpty，
  //     崩在 `CRecordVector::IsEmpty()` 读 `_size` 那一条。
  //   - 落在一块恰好映射着的内存上 -> `Size()` 返回天文数字 ->
  //     `new CPropVariant[num]` 直接申请几个 GB，随后主循环继续拿垃圾名字
  //     调 SetProperties。表现是 RSS 每秒涨几百 MB，直到被 LMK 杀掉 ——
  //     「卡在 0% 然后进程消失」，跟崩溃看着完全是两码事。
  //
  // 同一个 .so，同一条代码路径，两个 app 一个正常一个炸，就是因为这块栈
  // 内存的内容取决于调用方在此之前压了什么。**未初始化的栈值不可复现**，
  // 这正是它当初能骗过冒烟测试的原因。7-Zip 自己的调用方（Agent.cpp:1676
  // 的 `options.props = NULL;`）都老老实实写了这一行。
  op.props = nullptr;

  DuzOpenCallback cb(ctx);
  const HRESULT res = ctx->arcLink.Open2(op, &cb);

  // 权威判据是 Arcs 是否非空，不是 HRESULT：归档能开但内部嵌套包没开成时，
  // Open() 会返回 S_FALSE 却仍然 IsOpen == true（见 OpenArchive.cpp:3382）。
  if (!ctx->AnyArchiveOpen()) {
    DescribeOpenFailure(ctx->arcLink, res);
    delete ctx;
    return nullptr;
  }

  // 打包总量 = 首卷大小 + 7-Zip 实际取用到的后续卷大小。它既是进度分母的
  // 参照，也是「分卷是否齐全」的一个侧面证据。
  UInt64 mainSize = 0;
  NFind::CFileInfo fi;
  if (fi.Find_FollowLink(us2fs(ctx->filePath))) mainSize = fi.Size;
  ctx->packTotal = mainSize + ctx->arcLink.VolumesSize;

  return ctx;
}

const char* duz_last_open_error(void) { return g_openError; }
int32_t duz_last_open_error_code(void) { return g_openErrorCode; }

int32_t duz_list(duz_ctx* ctx, duz_entry** out, int32_t* count) {
  if (out) *out = nullptr;
  if (count) *count = 0;
  if (!ctx || !out || !count || !ctx->AnyArchiveOpen()) return DUZ_ERR_ARG;

  IInArchive* archive = ctx->Archive();
  UInt32 numItems = 0;
  if (archive->GetNumberOfItems(&numItems) != S_OK) return DUZ_ERR_OPEN;
  if (numItems == 0) return DUZ_OK;

  ctx->nameStore.clear();
  duz_entry* arr = (duz_entry*)calloc(numItems, sizeof(duz_entry));
  if (!arr) return DUZ_ERR_NOMEM;

  const CArc& arc = ctx->arcLink.Arcs.Back();
  UInt64 unpackTotal = 0;

  for (UInt32 i = 0; i < numItems; ++i) {
    CReadArcItem item;
    if (arc.GetItem(i, item) != S_OK) continue;

    std::string name = UToUtf8(item.Path);
    if (item.IsDir && (name.empty() || name.back() != '/')) name.push_back('/');

    UInt64 size = 0;
    {
      NCOM::CPropVariant prop;
      if (archive->GetProperty(i, kpidSize, &prop) == S_OK)
        ConvertPropVariantToUInt64(prop, size);
    }

    UInt64 crc = 0;
    {
      NCOM::CPropVariant prop;
      if (archive->GetProperty(i, kpidCRC, &prop) == S_OK)
        ConvertPropVariantToUInt64(prop, crc);
    }

    bool encrypted = false;
    {
      NCOM::CPropVariant prop;
      // 没有 ConvertPropVariantToBool 这个帮手，自己判 VT_BOOL。
      if (archive->GetProperty(i, kpidEncrypted, &prop) == S_OK &&
          prop.vt == VT_BOOL)
        encrypted = (prop.boolVal != 0);
    }

    ctx->nameStore.push_back(name);
    duz_entry& e = arr[i];
    e.name = nullptr;  // 下面统一取地址，避免 deque 扩容期取到失效指针
    e.size = size;
    e.crc = (uint32_t)crc;
    e.is_dir = item.IsDir ? 1 : 0;
    e.encrypted = encrypted ? 1 : 0;
    e.index = (int32_t)i;

    if (!item.IsDir) unpackTotal += size;
  }

  // nameStore 的地址在 push_back 期间是稳定的（deque 不做整体搬移），
  // 但为了不依赖这个细节，统一在这一步才取 c_str()。
  {
    size_t k = 0;
    for (std::deque<std::string>::iterator it = ctx->nameStore.begin();
         it != ctx->nameStore.end() && k < numItems; ++it, ++k)
      arr[k].name = it->c_str();
  }

  ctx->unpackTotal = unpackTotal;
  ctx->unpackTotalKnown = true;

  *out = arr;
  *count = (int32_t)numItems;
  return DUZ_OK;
}

void duz_free_entries(duz_entry* entries, int32_t count) {
  (void)count;
  free(entries);
}

int32_t duz_verify_password(duz_ctx* ctx, const char* pwd) {
  // P4 落地。要做对必须按最小条目做廉价校验（ZIP 用加密头 1 字节 + 最小条目
  // CRC；7z 看头 CRC；RAR 用最小条目 CRC），而不是整包试解 —— 那是密码库
  // 自动试密码的性能前提。这里先明确返回「未实现」，不假装成功。
  (void)ctx;
  (void)pwd;
  return DUZ_ERR_UNSUPPORTED;
}

int32_t duz_extract_all(duz_ctx* ctx, const char* outDir, duz_progress_cb cb,
                        void* userData) {
  if (!ctx || !outDir || !outDir[0] || !ctx->AnyArchiveOpen()) return DUZ_ERR_ARG;

  const CArc& arc = ctx->arcLink.Arcs.Back();
  IInArchive* archive = arc.Archive;

  DUZ_LOG("== duz_extract_all 进入 outDir=%s packTotal=%llu arcs=%u cb=%p", outDir,
          (unsigned long long)ctx->packTotal, (unsigned)ctx->arcLink.Arcs.Size(),
          (void*)cb);

  DuzExtractCallback* spec = new DuzExtractCallback(ctx, cb, userData);
  CMyComPtr<IFolderArchiveExtractCallback> specRef = spec;

  CArchiveExtractCallback* ecs = new CArchiveExtractCallback;
  CMyComPtr<IArchiveExtractCallback> ecRef = ecs;

  // 接上落盘回调：条目失败时要靠它问出真实磁盘路径（见 RemoveFailedOutput）。
  spec->Ecs = ecs;

  // kCurPaths：条目名按「相对输出目录」处理，配合 Correct_FsPath 的清洗，
  // zip-slip（../、绝对路径、盘符）在这一层就被拦掉。
  ecs->InitForMulti(false, NExtract::NPathMode::kCurPaths,
                    NExtract::NOverwriteMode::kOverwrite,
                    NExtract::NZoneIdMode::kNone, false);

  CExtractNtOptions nt;
  // 一期策略：不建符号链接、不还原硬链接、不处理备用数据流。
  // 逃逸到输出目录外的链接是最难审的一类风险，解析器再好也不如不建。
  nt.SymLinks.Val = false;
  nt.HardLinks.Val = false;
  nt.AltStreams.Val = false;
  nt.MemLimit = kMemLimit;

  const FString outDirFs = Utf8ToFs(outDir);
  // outDir 是 UTF-8 进来的，outDirFs 是 7-Zip 内部的文件系统形态。两者字节数
  // 应当一致（POSIX 下 FString 就是 UTF-8）；不一致说明 us2fs/fs2us 那一层
  // 转坏了，后面所有落盘路径都会跟着歪。
  DUZ_LOG("outDirFs len=%u%s", (unsigned)outDirFs.Len(),
#ifndef _WIN32
          outDirFs.Ptr() ? outDirFs.Ptr() : "(null)"
#else
          "(win)"
#endif
  );

  DUZ_LOG("Init 之前");
  ecs->Init(nt, nullptr, &arc, spec, false /*stdOut*/, false /*testMode*/,
            outDirFs, UStringVector() /*removePathParts*/, false,
            ctx->packTotal);
  DUZ_LOG("Init 之后");

  CArchiveExtractCallback_Closer closer(ecs);

  // 7-Zip 的约定：解压前把完成量归零（Open 阶段可能已经报过一些）。
  IArchiveExtractCallback* aec = ecs;
  const UInt64 zero = 0;
  DUZ_LOG("Extract 之前的 SetCompleted(&0)");
  aec->SetCompleted(&zero);
  DUZ_LOG("Extract 之前的 SetCompleted(&0) 返回了");

  DUZ_LOG("archive->Extract 调用");
  HRESULT res = archive->Extract(nullptr, (UInt32)(Int32)-1, 0, aec);
  DUZ_LOG("archive->Extract 返回 res=0x%08X", (unsigned)res);
  const HRESULT res2 = closer.Close();
  DUZ_LOG("closer.Close() 返回 res2=0x%08X", (unsigned)res2);
  if (res == S_OK) res = res2;

  int32_t code = DUZ_OK;
  std::string msg;
  if (spec->Cancelled) {
    code = DUZ_ERR_EXTRACT;
    msg = "已取消";
  } else if (res == E_ABORT) {
    code = DUZ_ERR_EXTRACT;
    msg = "已取消";
  } else if (spec->SawWrongPassword) {
    code = DUZ_ERR_PASSWORD;
    msg = "密码错误";
  } else if (spec->FailedCount > 0) {
    code = DUZ_ERR_EXTRACT;
    msg = spec->FirstError.empty() ? "解压过程中有条目失败" : spec->FirstError;
  } else if (res != S_OK) {
    code = DUZ_ERR_EXTRACT;
    msg = "解压失败";
  }

  // 接上失败清理的战果。**必须如实说**：文案在讲「失败了」，可目录里到底还剩
  // 什么、坏的那份清掉没有，只有这几句能告诉用户 —— 他没有任何别的渠道看出来。
  if (spec->RemovedCount > 0) {
    msg += "，已删除 " + std::to_string(spec->RemovedCount) + " 个损坏文件";
  }
  if (spec->RemoveFailedCount > 0) {
    msg += "，另有 " + std::to_string(spec->RemoveFailedCount) +
           " 个损坏文件未能删除，请手动清理输出目录";
  }

  if (code != DUZ_OK) SetOpenError(code, msg.c_str());
  DUZ_LOG("== duz_extract_all 退出 code=%d Report回调=%llu 失败条目=%u",
          (int)code, (unsigned long long)spec->ReportCalls,
          (unsigned)spec->FailedCount);
  return code;
}

void duz_close(duz_ctx* ctx) {
  if (!ctx) return;
  ctx->arcLink.Close();
  delete ctx;
}

int32_t duz_version(char* buf, int32_t bufLen) {
  static const char kVersion[] = "7-Zip " MY_VERSION_NUMBERS;
  const int32_t n = (int32_t)sizeof(kVersion) - 1;
  if (buf && bufLen > 0) {
    const int32_t c = (n < bufLen - 1) ? n : (bufLen - 1);
    memcpy(buf, kVersion, (size_t)c);
    buf[c] = '\0';
    return c;
  }
  return n;
}

}  // extern "C"

#endif  // DUZ_HAS_7ZIP
