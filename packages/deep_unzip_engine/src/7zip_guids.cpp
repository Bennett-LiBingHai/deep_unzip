// 7-Zip 全部 COM 接口 GUID 的定义单元 —— 全工程只能有这一个。
//
// 为什么需要它：7-Zip 的 IID（IID_IInArchive、IID_ISequentialInStream ……）不是
// 写死在某个 .cpp 里的，而是由 CPP/7zip/IDecl.h 的宏在**头文件里**生成：
//   - 未定义 INITGUID 时，`Z7_DEFINE_GUID` 只产出 `extern const GUID`（声明）；
//   - 定义了 INITGUID 时，它才产出真正的定义。
// 所以必须恰好有一个编译单元，在包含这些接口头之前先包含 Common/MyInitGuid.h。
//
// 官方构建里这个角色由 CPP/7zip/UI/Console/Main.cpp 担任（它是 7zz 的 console
// 入口）。而 Main.cpp 属于 CONSOLE_OBJS，为了不把 main() 和整块控制台 UI 拖进来，
// 我们的源清单刻意没有收它 —— 代价就是必须自己补上这个单元，否则链接期会报
// 20 个 IID_* undefined symbol。
//
// 反过来也不能把 Main.cpp 一起编进来充数：那样会多出一个 main()，且与我们的
// 入口冲突；更重要的是「只有一个定义单元」这条规则会被破坏。
//
// 新增用到的 7-Zip 接口头时，记得同步加到这里 —— 漏了就是链接期的
// undefined symbol，而报错信息只会说「IID_XXX 未定义」，不会告诉你该加哪个头。

#include "Common/MyInitGuid.h"  // 必须最先，且不能移到任何接口头之后

#include "7zip/Archive/IArchive.h"
#include "7zip/ICoder.h"
#include "7zip/IPassword.h"
#include "7zip/IProgress.h"
#include "7zip/IStream.h"
#include "7zip/UI/Common/IFileExtractCallback.h"
