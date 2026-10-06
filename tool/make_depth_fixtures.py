r"""生成「递归深度」夹具 —— 一条纯 zip 链，层级数得清。

## 为什么不用 `make_type_fixtures.py` 里的 `nested/L1.zip`

那个的靶子是**钻得动**：三层各换一个格式（zip → 7z → tar.gz），证明引擎见到
别的格式也照样往下走。它只有**一条**链，而且 `L1.zip` 直接躺在被选目录下。

这一个的靶子是**深度这条线本身**（2026-10 深度从档位表改成自由输入之后）：链长
固定、每一层同名同格式，于是「解到第几层停下」一眼数得出来。另外它**特意**放了
第二条链在子目录里 —— 那条链现在会被少放行一层，见下。

## 两条链

    duz_depth/
      L1.zip          → L2.zip  → L3.zip  → 底.txt      （顶层，depth 0）
      子目录/
        S1.zip        → S2.zip  → S3.zip  → 子底.txt    （子目录里）

两条链**内容一样、格式一样、长度一样**，唯一的差别是**入口躺着的位置**。
所以「两条链在同一个 maxDepth 下表现不同」只可能是位置造成的。

## 两条链的差是**对的**：目录层级也算一层

用户 2026-10 定下的规则（原话）：

> 源目录向下，不管是不是压缩包解压出来的，每下一层子目录都算一层递归

`scanner.dart` 里 `ScanItem.depth` 写的就是 `baseDepth + 目录层级`，两半都算。
`scanner_test.dart` 的「depth 随目录层级递增，且与 baseDepth 相加」钉着它，
`app_state.dart` 的 `_runExtractBatch` 拿它过 `withinDepthLimit`。

于是**入口自己也占额度**：`子目录/S1.zip` 躺在第 1 层，maxDepth = 0 时它自己
都放行不了 —— 不是「解了但不往下走」，是**压根不解**。而 `L1.zip` 躺在第 0 层，
0 也放行。

| maxDepth | `L1.zip`（顶层） | `子目录/S1.zip`（子目录里） |
|---|---|---|
| 0 | 只解它自己，`L1/` 里 `L2.zip` 原样躺着 | **压根不解**，`S1.zip` 原样躺在 `子目录/` 里 |
| 1 | `L1/L2/` 出现，`L3.zip` 留着 | 只解它自己，`S1/` 里 `S2.zip` 原样躺着 |
| 2 | 到底 | `子目录/S1/S2/`，`S3.zip` 留着 |
| 3 | 到底 | 到底 |

（这张表在 2026-10 之前，`maxDepth = 0` 那行写的是「两条一致」—— 那正是漏掉
入口那道闸门时的样子。）

## 这个夹具上我连着错过两次（2026-10）

1. **先报了「行为与说明不符」**。错在哪儿：设置页那行当时只写了「解压出来的包
   再往下解几层」，按那半句读两条链确实该一致 —— 但缺的是**说法**的半句，不是
   行为。用户澄清后改的是文案。
2. **然后把结论反过来**，认定「行为是对的、只有文案不对」。**还是错**：用户
   再补一句「进入子目录没有算递归」（他是拿 `maxDepth = 0` 试的，看到
   `子目录/S1.zip` 照样被解），`dart run tool/scan_probe.dart build/depth/duz_depth`
   打出 `L1.zip 深度 0` / `S1.zip 深度 1` 证明扫描这一侧是**对的**，而
   `_runExtractBatch` 播种队列时**压根没过深度闸门** —— 顶层无条件全排进队列。
   所以确实有 bug，只是方向和第一次报的**正好相反**。

那两句不矛盾，是同一件事的两半：扫描器算对了深度，播种处没拿它做判断。两次
都错在**只拿半句说明去反推行为**。记在 memory `depth-counts-directories`。

## 产物（`build/depth/`）

    duz_depth/        推设备时整个目录推过去，在 app 里选**这一层**
    README.txt        对照表（跟着夹具一起推，纯文本，不是压缩包）

用法：

    py tool/make_depth_fixtures.py        （本机 `python` 没进 PATH，用 `py`）
"""

import os
import shutil
import zipfile

ROOT = os.path.abspath(os.path.join("build", "depth"))
FOLDER = "duz_depth"

# 链长 3：够看出「差一层」了，再长只是把同一件事重复一遍。
CHAIN = 3

# 链根名 + 代码里的文字。两串刻意不同名，免得撞上同一层里「重名抢目录」那条
# `_1` 兜底逻辑 —— 那要测的是另一件事，混在一起就分不清谁挂了。
CHAINS = [
    # (写进 zip 的基名, 最里层那个文件的正文, 放在哪个相对目录下)
    ("L", "最里面一层（顶层链）\n", ""),
    ("S", "最里面一层（子目录链）\n", "子目录"),
]


def build_chain(prefix, leaf_text, chain_dir, stage):
    """在 [stage] 里现造一条链：`<prefix>1.zip` 里装 `<prefix>2.zip` …

    从**最里层往外**造。这样每一层只要 `zipfile.write` 上一层的产物就行，
    不需要回头改已经写好的包。
    """
    work = os.path.join(stage, "_work")
    shutil.rmtree(work, ignore_errors=True)
    os.makedirs(work)

    # 最里层手里先攥一个普通文件，然后一层层往外套。
    inner_name = "底.txt" if prefix == "L" else "子底.txt"
    with open(os.path.join(work, inner_name), "w", encoding="utf-8") as f:
        f.write(leaf_text)

    produced = []  # 从里往外
    prev = inner_name
    for lvl in range(CHAIN, 0, -1):
        name = f"{prefix}{lvl}.zip"
        out = os.path.join(work, name)
        # **stored 不压缩**：这条夹具跟压缩率无关，而 stored 的包一眼能看出
        # 是「原样搬运」—— 排查时少一层猜测。
        with zipfile.ZipFile(out, "w", zipfile.ZIP_STORED) as z:
            z.write(os.path.join(work, prev), arcname=prev)
        produced.append(name)
        prev = name

    # 只有最外层那一个进夹具目录；里层那些已经**装进**它了，不该另外落一份
    # 在磁盘上 —— 落了就变成「同一层有两个包」，深度观测点会翻倍。
    top = produced[-1]
    dest_dir = os.path.join(stage, FOLDER, chain_dir) if chain_dir else os.path.join(stage, FOLDER)
    os.makedirs(dest_dir, exist_ok=True)
    shutil.move(os.path.join(work, top), os.path.join(dest_dir, top))

    levels = " → ".join(f"{prefix}{i}.zip" for i in range(1, CHAIN + 1))
    print(f"  {chain_dir or '(顶层)'}/{top:<10} {levels} → {inner_name}")

    # 入口自己躺在第几层目录里 —— **这就是那个偏差的来源**，所以跟 rel 一起交出去，
    # 别让 README 那边再去数字符串（那样数错了没人发现）。
    base = len([s for s in chain_dir.split("/") if s])
    return (f"{chain_dir}/{top}" if chain_dir else top), base


def write_readme(rows, out_dir):
    """写对照表。[out_dir] 是**夹具目录本身**（`…/duz_depth/`）——
    跟着夹具一起推设备，在文件管理器里点开就能对着数，不必回仓库翻。"""
    lines = [
        "递归深度夹具",
        "=" * 60,
        "",
        "在 app 里选 **duz_depth** 这一层，然后改设置页的「最大递归深度」重跑。",
        "",
        "两条链内容一模一样，只差**入口躺在哪**：",
        "",
        "  L1.zip            顶层（直接躺在被选目录下）",
        "  子目录/S1.zip      一层子目录里",
        "",
        "每层都是一个纯 zip，只装下一个 zip，最里面装一个 txt。",
        "所以 `L1/L2/` 这个目录存在 = 「往下解了两层」，数目录就行。",
        "",
        "对照表",
        "-" * 60,
        "",
        "**两条链不是等价的，这是有意为之**（下面解释）。`maxDepth` 数的是",
        "**从被选目录往下走了几步**，而「一步」有两种、**同等计入**：",
        "进一层子目录、解开一层嵌套包。`子目录/S1.zip` 自己已经占掉一层，",
        "所以它比 `L1.zip` 少一层预算。",
        "",
    ]
    for depth in (0, 1, 2, 3):
        lines.append(f"  maxDepth = {depth}")
        states = []
        for rel, base in rows:
            chained = rel.split("/")[-1][0]
            # **入口自己也要过同一道闸门**（2026-10 补上的）：它躺在第 base 层
            # 目录里，就得先花掉 base 层预算。花不起的话它是**压根不解** ——
            # 不是「解了但不往下走」，连 `S1/` 这个目录都不会出现。
            entered = base <= depth
            extra = max(0, min(depth - base, CHAIN - 1)) if entered else 0
            if not entered:
                where, tail = "(不解)", "原样躺着"
            else:
                where = f"{rel[:-4]}/" + "".join(
                    f"{chained}{i}/" for i in range(2, 2 + extra)
                )
                done = extra == CHAIN - 1
                tail = "到底（底.txt 出现）" if done else f"{chained}{extra + 2}.zip 原样留着"
            lines.append(f"    {rel:<16} → {where:<26} {tail}")
            states.append((extra, entered))
        lines.append("")

        # 两条链表现不一致时点一句。不一致有两种：入口被拦（压根没解）、或者
        # 解了但比顶层少下一步 —— 后者才是「差一层」。
        if states[0] != states[1]:
            if not states[1][1]:
                lines.append(
                    "      ↑ **不是「少解一层」，是压根没解**：入口自己躺在子目录里，"
                    "已经占掉一层，"
                )
                lines.append("        而这一档连它自己都放行不了")
            else:
                # 措辞避开「N 层」：这个夹具里「0」在设置页上是「不递归」，而
                # `extra` 是「解出了几个嵌套包」，同一个 0 两种意思，混读会串。
                lines.append(
                    f"      ↑ 差一层（**对的**）：入口自己躺在子目录里，已经占掉一层，"
                    f"所以它解出 {states[1][0]} 个嵌套包，顶层那条解出 {states[0][0]} 个"
                )
            # 上面被拦下的那个包，日志里都有一条。**maxDepth = 0 也照样有** ——
            # 拦下 `S1.zip` 的是的顶层那道闸门；从前没有这条日志，因为从前顶层
            # 压根不过闸门。
            lines.append("      （日志里有一条「超出递归深度」—— 就是上面被拦下的那个）")
        lines.append("")

    lines += [
        "为什么子目录那条总是差一档（**这是对的**，不是夹具坏了）",
        "-" * 60,
        "用户定的规则（原话）：",
        "",
        "    源目录向下，不管是不是压缩包解压出来的，每下一层子目录都算一层递归",
        "",
        "`scanner.dart` 里 `ScanItem.depth` 写的就是 `baseDepth + 目录层级` ——",
        "**两半都算**。`app_state.dart` 的 `_runExtractBatch` 拿它过",
        "`withinDepthLimit`，于是：",
        "",
        "  · 进一层子目录       +1",
        "  · 解开一层嵌套包     +1     ← 两者同等，没有谁优先",
        "",
        "所以「最大递归深度」是**相对被选目录**算的，不是相对「这个包自己」。",
        "`L1.zip` 躺在第 0 层、`子目录/S1.zip` 躺在第 1 层，差的就是这一层。",
        "`scanner_test.dart` 的「depth 随目录层级递增」那条钉着这条语义。",
        "",
        "**入口自己也占额度**，这一点 2026-10 才补上：在此之前",
        "`_runExtractBatch` 播种队列时是无条件把整份扫描结果排进去的，于是",
        "`maxDepth = 0` 拦得住包**里面**的嵌套包，却拦不住**目录里面**的包 ——",
        "而按上面这条规则，后者离被选目录更远。所以 `maxDepth = 0` 时",
        "`子目录/S1.zip` 从前照样被解，现在不会了。",
        "",
        "怎么读结果",
        "-" * 60,
        "  · 数**目录**的层数，别看文件在不在 —— 被拦住的那个包会原样躺在父目录里，",
        "    不数一下会以为它也解了。",
        "  · 每有一个包被拦下，日志里就有一条「超出递归深度」，**maxDepth = 0 也",
        "    照样有**（拦下 `子目录/S1.zip` 的是顶层那道闸门）。",
        "  · 改了深度：跑完的批次要**重新选目录**再跑；要是整批都被深度拦下",
        "    （一个都没排进队列），那不算「这批跑过了」，可以直接再点一次「开始解压」。",
        "",
        "重造",
        "-" * 60,
        "  py tool/make_depth_fixtures.py      （本机 `python` 没进 PATH，用 py）",
        "",
        "推设备",
        "-" * 60,
        f"  adb push build/depth/{FOLDER} /sdcard/Download/",
        f"  → 落到 /sdcard/Download/{FOLDER}/（app 里选**这一层**）",
        "",
        "  **在 Git Bash 里要先 `export MSYS_NO_PATHCONV=1`**：不设的话 `/sdcard/…`",
        "  会被改写成 `D:/MySoftware/Git/sdcard/…`，adb 报「No such file or directory」，",
        "  看着像设备上没这个目录，其实是本机 shell 干的。",
    ]

    path = os.path.join(out_dir, "README.txt")
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    print(f"\n对照表 → {path}")


def main():
    stage = os.path.abspath(os.path.join("build", "depth_src"))
    shutil.rmtree(stage, ignore_errors=True)
    shutil.rmtree(ROOT, ignore_errors=True)
    os.makedirs(stage)

    print(f"链长 {CHAIN}，产物 → {os.path.join(ROOT, FOLDER)}\n")

    rows = []
    for prefix, leaf_text, chain_dir in CHAINS:
        rows.append(build_chain(prefix, leaf_text, chain_dir, stage))

    # 一个非压缩包的陪衬：证明这一趟不碰普通文件（它不该出现在输出里）。
    out_dir = os.path.join(stage, FOLDER)
    with open(os.path.join(out_dir, "陪衬.txt"), "w", encoding="utf-8") as f:
        f.write("我不是压缩包，别动我。\n")
    print("  (顶层)/陪衬.txt")

    write_readme(rows, out_dir)

    # 整棵 `duz_depth/` 一起搬进产物目录 —— **不要**逐个文件搬：`子目录/`
    # 这层的存在本身就是观测对象，漏搬它就等于把要验的那条链弄没了。
    shutil.move(out_dir, os.path.join(ROOT, FOLDER))
    shutil.rmtree(stage, ignore_errors=True)
    print(f"\n源材料已删；夹具在 {os.path.join(ROOT, FOLDER)}/")


if __name__ == "__main__":
    main()
