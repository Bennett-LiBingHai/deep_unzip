# 对 third_party/7zip 的改动清单

`third_party/7zip` 是 7-Zip 源码的**固定快照**，正常情况下一个字节都不该动。
下面每一条都是「上游没给这个口子，但我们非要有」的最小追加。升级 7-Zip 时
按本文件逐条重新施加 —— 升级后如果 `git diff` 里这些改动没了，就是漏了。

原则：**只加、不改、不删**。不碰任何既有函数的行为，这样「7-Zip 自身的解压
语义」永远等于上游语义，出问题时不至于分不清是谁的锅。

---

## 1. `CPP/7zip/UI/Common/ArchiveExtractCallback.h`

**加了什么**：`CArchiveExtractCallback` 的一个 public 只读访问器。

```cpp
const FString& Get_DiskFilePath() const { return _diskFilePath; }
```

**为什么**：`_diskFilePath` 是 private，而它是**唯一**知道「条目真正落到磁盘上
叫什么」的地方。条目在归档里叫 `name`，落盘叫
`Correct_FsPath(join(前缀, name))`，两者在名字含 `..`／绝对路径／盘符／控制
字符时并不相同。那套清洗是安全关键代码，在 `duz_engine.cpp` 里再抄一份只会
抄歪 —— 而失败清理必须删对文件。

**试过但走不通的两条路**（别再试一遍）：

- `IFolderArchiveExtractCallback2::ReportExtractResult(opRes, enc, name)`：传的是
  **归档内**路径（`item.Path`，见 ArchiveExtractCallback.cpp:2907），不是磁盘路径。
- `SendMessageError`：确实拿 `_diskFilePath` 去用，但它是把路径**拼进一句人读
  文案**再交给 `MessageError`（`AddPathToMessage`）。从格式化字符串里反解路径
  太脆，换个 locale 或分隔符就断。

**读它的时机**：只有在本类的 `SetOperationResult` 里读才是对的 ——
`PrepareOperation` 开头会 `Empty()`，随后 `GetFilePath` 赋值；等
`SetOperationResult` 被调到，`CloseReparseAndFile()` 已经跑过，文件已关闭、
确实在盘上。用的人是 `DuzExtractCallback::RemoveFailedOutput()`。

**上游兼容性**：纯追加的 const 访问器，不影响任何既有行为。类带 `Z7_final`，
所以不能靠继承绕开 —— 这也是必须改这里的原因。
