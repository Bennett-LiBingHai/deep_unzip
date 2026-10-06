r"""生成「所有类型」真机验收夹具 —— 一个密码走到底（`duz-test`）。

## 为什么又写一个（而不是扩 `make_password_fixtures.py`）

那个脚本的靶子是**密码弹窗的三种出口**（手输 / 跳过 / 停止），夹具刻意只有
zip 一种格式。这一个的靶子是**格式与加密方式的组合**：解压引擎对每一种组合
该走哪条路、该说什么话，一次跑完就能对照。两者目的不同，产物也不该混在
`build/devfix/` 里。

## Info-ZIP 跨卷（`.z01`…+`.zip`）也不在这一批里（实测，附证据）

`split.dart` 把它单列成一个家族（`infoZipSpanned`），入口是 **`.zip`（最后一份）**，
与裸切分的 `.001`（第一份）**正好相反** —— 所以它值得有夹具。但本机造不出来，
而且「改个名」是假的：

    (a) 7-Zip 自己切（`-tzip -v`）得到 `x.zip.001/.002/.003`  → 7z t ✔ 读得过
    (b) 把它改名成 `.z01/.z02/.zip`                          → 7z t ✘ Open Errors 1
    (c) 把 (b) 三份按序拼起来                                 → 7z t ✔ 读得过

(b) 失败不是改名改坏了，而是**改出来的东西根本不是 Info-ZIP spanning**：
7-Zip 的 `-v` 切的是**一个字节流**，而 `models.dart:192-194` 说得对 ——
真 spanning 的**每一卷自带局部中央目录**（各卷是各自独立的 zip，EOCD 里的
disk 字段标明它是第几卷）。(c) 读得过正说明 (b) 是三份**字节切片**，不是三卷 zip。

所以这一格只能靠外部样本验。顺带一个 app 侧的已知缺口（源码里写着）：
`scanner.dart:489-494` 说「分卷的 ZIP 这一格谁都答不上来……要补得先有一条跨卷的
虚拟拼接读取，那是解压期的东西」—— 拿真 spanning 样本去测时，先看这条补上没有。

## RAR3 不在这一批里（2026-10-06 亲手验过，不是想当然）

本机装了 WinRAR 7.11（`C:\Program Files\WinRAR\Rar.exe`），看起来 RAR 就能造了。
**但 RAR 7 已经不能创建 RAR4/RAR3 格式**：

    Rar.exe a -ma5 ...   → 认（产物签名 52 61 72 21 1A 07 01 00 = RAR5）
    Rar.exe a -ma4 ...   → 错误: 未知选项: ma4

那个开关没了，RAR 7 只写 RAR5。所以 `enc/` 里那几个 `rar3*` **造不出来**，
这批夹具里也没有它们。想要真机上验 RAR3 只有三条路：换一个 6.x 的
Rar.exe、从别处拿一个真 RAR3 文件、或者继续按源码推（
`duz_engine.cpp` 里 `SetOperationResult` 的注释写了 RAR3 的三条失败路，
它们的机理与 `7z_stored_加密.7z` / `7z_压缩_加密.7z` 这两份**各自对应**）。

> 这里差点写错：一度以为「WinRAR 装了 = RAR3 能造」，还准备据此推翻内存里
> 「本机造不出 RAR3」那条结论。**那条结论是对的** —— `7z.exe` 不能压 RAR、
> RAR 7 不能造 RAR4，两件事叠加才是全部原因。

## 密码

**全部 `duz-test`。** 写在这里 = 仓库里有记录，不是又一批没人知道密码的包
（`build/devfix/` 那批加密 7z/rar5 就吃过这个亏）。`WRONG_PASSWORD` 是给本机
自检用的对照，不落进夹具。

## 产物（`build/types/`）

    plain/    未加密，每种格式一个
    enc/      加密，**全是 duz-test**
    split/    分卷（四族）
    fake/     伪后缀 / 前置数据
    corrupt/  真损坏 —— 与 `enc/` 里同类型的「密码错」互为对照
    nested/   嵌套（递归解压）
    README.txt 自检跑出来的对照表（含每个文件的期望表现）

## 本机自检

每个夹具都拿 `7z t` 过两遍：对密码一遍、错一遍，把**实际报出来的那句话**
写进 `README.txt`。这一步不只是记文档：`corrupt/` 那两份是**改坏一个字节
再自证改的是数据区**（见 `corrupt_copy`），头被改坏的话夹具就废了。

用法：

    python tool/make_type_fixtures.py
"""

import os
import random
import shutil
import struct
import subprocess
import sys
import zlib
from zipfile import ZipFile

SEVEN_ZIP = os.environ.get("SEVEN_ZIP", r"D:\MySoftware\7-Zip\7z.exe")
RAR = os.environ.get("RAR", r"C:\Program Files\WinRAR\Rar.exe")

PASSWORD = "duz-test"
WRONG_PASSWORD = "wrong-on-purpose"

# 一律绝对路径：这些会当成 7z.exe / Rar.exe 的 cwd 或输出路径用，相对路径会被
# 它们按**自己的** cwd 再解析一层（踩过两次：产物落到 build/types_src/build/…）。
ROOT = os.path.abspath(os.path.join("build", "types"))
SRC = os.path.abspath(os.path.join("build", "types_src"))  # 源材料，跑完删

# 200 KB 伪随机（可复现）——**不可压缩**，这样「stored 与压缩」在同一份内容上
# 差别看得出来；小文件在 /sdcard 上建得慢（FUSE 每个 6~17 ms），别塞太多。
PAYLOAD_BYTES = 200 * 1024
VOLUME = "100k"  # 分卷阈值：200 KB 的料刚好切成 3 卷

ENTRIES = [
    "readme.txt",
    "data/log.txt",
    "中文目录/文件 名.txt",
]


# ---------------------------------------------------------------------------
# 跑外部程序
# ---------------------------------------------------------------------------


def _decode(raw):
    """7z.exe 说 ASCII 英文，Rar.exe 跟系统语言（这台是 GBK）。"""
    for enc in ("utf-8", "gbk"):
        try:
            return raw.decode(enc)
        except UnicodeDecodeError:
            continue
    return raw.decode("utf-8", "replace")


def run(exe, args, cwd=None):
    """跑一个外部程序，返回 (returncode, 合并后的输出)。**不抛异常。**"""
    p = subprocess.run([exe, *args], cwd=cwd, capture_output=True)
    return p.returncode, (_decode(p.stdout) + _decode(p.stderr)).strip()


def must(exe, args, cwd=None):
    rc, out = run(exe, args, cwd=cwd)
    if rc != 0:
        raise SystemExit(f"{os.path.basename(exe)} {args} 失败（rc={rc}）：\n{out}")
    return out


def sz(args, cwd=None):
    return must(SEVEN_ZIP, args, cwd=cwd)


def rar(args, cwd=None):
    return must(RAR, args, cwd=cwd)


# ---------------------------------------------------------------------------
# 源材料
# ---------------------------------------------------------------------------


def p(rel):
    """产物路径一律给**绝对**路径。

    造包时 7z.exe / Rar.exe 的 cwd 是源目录（那样条目名才不带前缀），于是相对
    输出路径会被它们按**源目录**解析 —— 第一次跑就栽在这：包全造到
    `build/types_src/build/types/` 底下去了，脚本自己还在原地找不到。
    """
    return os.path.abspath(os.path.join(ROOT, rel))


def build_src():
    """一份内容，所有格式共用 —— 这样「同一个包换个格式」的差别只有格式本身。

    返回给「能装多个文件」的格式用的清单；单文件格式（gz/bz2/xz）只能用
    `SINGLE_FILE` —— 那三种容器规范里就只放得下一个文件，塞多了 7-Zip 直接报错。
    """
    shutil.rmtree(SRC, ignore_errors=True)
    os.makedirs(os.path.join(SRC, "data"))
    os.makedirs(os.path.join(SRC, "中文目录"))

    # `random` 的固定种子 + `randbytes`：可复现（重跑得到同一个文件，diff 有意义），
    # 且 LZMA 压不动它 —— 压缩与 stored 的差别才显出来。
    with open(os.path.join(SRC, "random.bin"), "wb") as f:
        f.write(random.Random(20261006).randbytes(PAYLOAD_BYTES))

    text = "这是压缩包里的正文，能看到它就说明解出来了。\n"
    with open(os.path.join(SRC, "readme.txt"), "w", encoding="utf-8") as f:
        f.write(text)
    with open(os.path.join(SRC, "data", "log.txt"), "w", encoding="utf-8") as f:
        f.write("second entry\n")
    with open(os.path.join(SRC, "中文目录", "文件 名.txt"), "w", encoding="utf-8") as f:
        f.write("带空格和中文的路径\n")

    return ENTRIES + ["random.bin"]


# ---------------------------------------------------------------------------
# 各族的生成
# ---------------------------------------------------------------------------

# (相对路径, 怎么造, 需要哪些源文件)
# 造法函数签名统一是 (out_abs, files) —— files 是相对 SRC 的名字。


def seven_zip_factory(type_arg, extra=()):
    def make(out, files, cwd=SRC):
        sz(["a", f"-t{type_arg}", *extra, out, *files], cwd=cwd)

    return make


def tar_then(compressor):
    """`tar.gz` 这类两层包：先出 tar，再压一层。**两层都要真的存在** ——
    「c.tar.gz 解出来该叫 c」这条就靠它验。

    里面那层 tar 叫 `plain.tar`（= 输出名去掉 `.gz` / `.bz2` / `.xz`），不是
    随便一个临时名 —— 真机上看输出树时，「解 gz 得到 tar、再解 tar 得到文件」
    这条链子要认得出来。
    """

    def make(out, files, cwd=SRC):
        inner = os.path.basename(out).split(".")[0] + ".tar"
        # 两步的 cwd 都是源目录，tar 也就在源目录里现产现用，不落进产物目录。
        sz(["a", "-ttar", inner, *files], cwd=cwd)
        sz(["a", f"-t{compressor}", out, inner], cwd=cwd)
        os.remove(os.path.join(cwd, inner))

    return make


def rar_factory(method, extra=()):
    """`method` 只能是 `-ma5`（RAR5）。

    **`-ma4` 在 RAR 7 上已经不认识**（「未知选项」），RAR4/RAR3 造不出来 ——
    见文件头那段。留着这个参数是为了让「RAR 只写 RAR5」这件事在调用处看得见，
    不是暗示还能传别的值。
    """

    def make(out, files, cwd=SRC):
        rar(["a", "-y", "-idq", method, *extra, out, *files], cwd=cwd)

    return make


def copy_of(rel):
    def make(out, files):
        shutil.copyfile(os.path.join(ROOT, rel), out)

    return make


# 单文件容器的清单：gz / bz2 / xz 规范里就只装得下一个文件。
SINGLE_FILE = ["random.bin"]

# (相对路径, 造法, 源文件清单) —— 清单为 None 时用默认的那份多文件内容
PLAIN = [
    ("plain/plain.zip", seven_zip_factory("zip"), None),
    ("plain/plain.7z", seven_zip_factory("7z"), None),
    ("plain/plain.tar", seven_zip_factory("tar"), None),
    ("plain/plain.tar.gz", tar_then("gzip"), None),
    ("plain/plain.tar.bz2", tar_then("bzip2"), None),
    ("plain/plain.tar.xz", tar_then("xz"), None),
    ("plain/plain.gz", seven_zip_factory("gzip"), SINGLE_FILE),
    ("plain/plain.bz2", seven_zip_factory("bzip2"), SINGLE_FILE),
    ("plain/plain.xz", seven_zip_factory("xz"), SINGLE_FILE),
]

ENCRYPTED = [
    # —— 有密码校验字：错密码在解码**之前**就被拦下（7-Zip 亲口报 kWrongPassword）
    ("enc/zip_aes256.zip", seven_zip_factory("zip", ["-mem=AES256", f"-p{PASSWORD}"])),
    ("enc/zip_zipcrypto.zip", seven_zip_factory("zip", ["-mem=ZipCrypto", f"-p{PASSWORD}"])),
    ("enc/rar5_加密.rar", rar_factory("-ma5", [f"-p{PASSWORD}"])),
    ("enc/rar5_头加密.rar", rar_factory("-ma5", [f"-hp{PASSWORD}"])),
    # —— 没有校验字：错了只能从下游症状猜（这就是「分不清」那一档）
    ("enc/7z_压缩_加密.7z", seven_zip_factory("7z", ["-mx5", "-mhe=off", f"-p{PASSWORD}"])),
    ("enc/7z_stored_加密.7z", seven_zip_factory("7z", ["-mx0", "-mhe=off", f"-p{PASSWORD}"])),
    # RAR5 有 psw check（能确定），但它 **stored** 那条仍值得单独放一份：
    # 拿它对照 7z 的 stored，就能看出「有没有校验字」才是分岔点，而不是
    # 「是不是 stored」。RAR3 的对应物造不出来，见文件头。
    ("enc/rar5_stored_加密.rar", rar_factory("-ma5", ["-m0", f"-p{PASSWORD}"])),
    # —— 头加密：打开阶段就判死，最确定的一档
    ("enc/7z_头加密.7z", seven_zip_factory("7z", ["-mhe=on", f"-p{PASSWORD}"])),
]

# 分卷里**加了密码**的那些（自检时才有「错密码」那一列可言）
ENCRYPTED_SPLIT = {"split/enc.7z.001"}

# (输出**基名**, 造法, 入口卷) —— 卷名是 7z / Rar 自己起的，我们只给基名：
# 传 `x.7z` 加 `-v` 会得到 `x.7z.001` / `.002`…（**不是**传 `x.7z.001`，
# 那样会得到 `x.7z.001.001`）。所以「入口卷是哪个」必须显式写出来，
# 主流程里还有一句 assert 兜着 —— 起名规则变了要当场炸，不是静默测错文件。
SPLIT = [
    # 裸字节切分：入口是 `.001`（**第一份**）
    ("split/naked.7z", seven_zip_factory("7z", [f"-v{VOLUME}"]), "naked.7z.001"),
    # Info-ZIP 跨卷（`.z01`…+`.zip`）**故意不在这一批里**，理由见文件头 ——
    # 一句话：7-Zip 不产生那种命名，而「按它的命名改个名」造出来的**不是**
    # Info-ZIP spanning（那个每卷自带局部中央目录），改完 7-Zip 也读不了。
    # RAR5 分卷：`part1.rar` / `part2.rar`，入口是 part1
    ("split/r5.rar", rar_factory("-ma5", [f"-v{VOLUME}"]), "r5.part1.rar"),
    # 分卷 + 密码
    ("split/enc.7z", seven_zip_factory("7z", [f"-v{VOLUME}", f"-p{PASSWORD}"]), "enc.7z.001"),
]

# 「声称是别的格式」——需求 5。`.jpg` / `.bin` 里装的都是真压缩包。
FAKE = [
    ("fake/伪装成图片.jpg", seven_zip_factory("7z")),
    ("fake/伪装成备份.bin", seven_zip_factory("7z", ["-mx0"])),
]


def make_prefixed_zip(out, files):
    """zip 前面垫 512 字节垃圾 —— 模仿 SFX / 「文件头前面还有别的东西」。

    入口点的魔数不在偏移 0，要引擎自己找（`baseOffset`）。

    **必须把 zip 里的偏移全部改写**：光拼接的话中央目录里的
    `relative offset of local header` 还是老值，7-Zip 会按它去读，找到的是
    垃圾 —— 那样测到的就不是「跳过前置数据」，而是「包坏了」。
    """
    inner = out + ".inner.zip"
    sz(["a", "-tzip", "-mx0", inner, *files], cwd=SRC)
    data = bytearray(open(inner, "rb").read())
    os.remove(inner)

    prefix = b"JUNK" * 128  # 512 字节
    assert len(prefix) == 512

    # EOCD 里那个「中央目录起始偏移」+ 每条中央目录记录的 local header 偏移
    eocd = data.rindex(b"PK\x05\x06")
    cd_start = struct.unpack_from("<I", data, eocd + 16)[0]
    cd_size = struct.unpack_from("<I", data, eocd + 12)[0]

    at = cd_start
    while at < cd_start + cd_size:
        assert data[at : at + 4] == b"PK\x01\x02", "中央目录签名对不上"
        local_off = struct.unpack_from("<I", data, at + 42)[0]
        struct.pack_into("<I", data, at + 42, local_off + len(prefix))
        name_len, extra_len, cmt_len = struct.unpack_from("<HHH", data, at + 28)
        at += 46 + name_len + extra_len + cmt_len
    struct.pack_into("<I", data, eocd + 16, cd_start + len(prefix))

    with open(out, "wb") as f:
        f.write(prefix + bytes(data))


def build_nested():
    """三层，每层换个格式 —— 递归解压要连着钻到底：

        L1.zip  →  a.7z, note.txt
          a.7z  →  b.tar.gz
            b.tar.gz  →  deepest.txt

    三个名字（L1 / a / b）刻意都不重样：重名要测的是「同一层里两个包抢一个
    目录名」那条 `_1` 兜底逻辑，跟「递归钻得动」是两件事，混在一起就分不清谁挂了。
    """
    out = p("nested/L1.zip")
    os.makedirs(os.path.dirname(out), exist_ok=True)

    stage = os.path.join(SRC, "_nested")
    shutil.rmtree(stage, ignore_errors=True)
    os.makedirs(stage)

    # 最里层：b.tar.gz 装一个 txt
    with open(os.path.join(stage, "deepest.txt"), "w", encoding="utf-8") as f:
        f.write("最里面一层\n")
    sz(["a", "-ttar", "b.tar", "deepest.txt"], cwd=stage)
    sz(["a", "-tgzip", "b.tar.gz", "b.tar"], cwd=stage)
    os.remove(os.path.join(stage, "b.tar"))

    # 中间层：a.7z 里只装 b.tar.gz —— 解完 a.7z 还得再往下钻一层
    sz(["a", "-t7z", "a.7z", "b.tar.gz"], cwd=stage)

    # 最外层
    with open(os.path.join(stage, "note.txt"), "w", encoding="utf-8") as f:
        f.write("L1 里的一层小文件\n")
    sz(["a", "-tzip", "L1.zip", "a.7z", "note.txt"], cwd=stage)
    shutil.move(os.path.join(stage, "L1.zip"), out)


# ---------------------------------------------------------------------------
# 真损坏：改坏一个字节，**并自证改的是数据区**
# ---------------------------------------------------------------------------

DATA_ERROR_HINTS = ("CRC", "Data Error", "数据错误", "校验失败")
HEADER_ERROR_HINTS = (
    "Headers Error",
    "头错误",
    "is not archive",
    "Cannot open",
    "Unexpected end",
    "意外结束",
)


def probe(path, pwd=None):
    """`7z t` 的一句话结论 —— 就是 README 表里那列。

    用 7z.exe 而不是 Rar.exe 测：**引擎里跑的就是 7-Zip 的这套 handler**，
    而 Rar.exe 是另一份实现、说另一套话。要对照的是前者的症状。

    `ERROR:` 那一行**常常只有路径**（头加密那种：「ERROR: D:\\…\\x.7z」），真正
    的信息在**下一行**（「Can not open file as archive」/「Cannot open encrypted
    archive. Wrong password?」）。所以把 ERROR 起始的那一小段连起来报，别只取一行。
    """
    args = ["t", "-y"]
    if pwd is not None:
        args.append(f"-p{pwd}")
    _, out = run(SEVEN_ZIP, [*args, path])
    lines = [ln.strip() for ln in out.splitlines() if ln.strip()]

    for i, ln in enumerate(lines):
        if not ln.startswith("ERROR:"):
            continue
        # 只把紧跟着的那一行捎上：再往后就是统计块（Files/Size），不是诊断
        tail = lines[i + 1] if i + 1 < len(lines) else ""
        if tail and not tail.startswith(("ERROR:", "Files:")):
            # 路径那一行去掉前缀目录，读表时眼睛不用跳
            head = ln.replace(os.path.dirname(path) + os.sep, "")
            return f"{head} | {tail}"
        return ln

    # 没有 ERROR 就是成功。优先报条目数 —— 单流的格式（gz/bz2/xz/tar.gz）7-Zip
    # 只给 Size:，不给 Files:，那样表里一行是「Files: 4」一行是「Size: …」，
    # 看着像两种结果，其实是同一件事（读过了）。
    for prefix in ("Files:", "Size:", "Compressed:"):
        for ln in lines:
            if ln.startswith(prefix) and "=" not in ln:
                return ln
    return lines[-1] if lines else "(没有输出)"


def corrupt_copy(src_rel, dst_rel, pwd):
    """把**数据区**里一个字节改坏，头一个字节都不碰。

    头坏了的话这个夹具测的就是「打不开」而不是「解出来发现对不上」，性质完全不同。
    所以从文件正中往后逐个位置试，只有当 `7z t` 报的是**数据/CRC 错**时才认；
    报头错误就复原、换下一个位置再试。
    """
    src = p(src_rel)
    dst = p(dst_rel)
    os.makedirs(os.path.dirname(dst), exist_ok=True)

    data = bytearray(open(src, "rb").read())
    mid = len(data) // 2
    for delta in range(len(data) - mid):
        i = mid + delta
        data[i] ^= 0xFF
        with open(dst, "wb") as f:
            f.write(data)
        msg = probe(dst, pwd)
        if any(h in msg for h in DATA_ERROR_HINTS) and not any(
            h in msg for h in HEADER_ERROR_HINTS
        ):
            print(f"      （字节 #{i} / 共 {len(data)} 改坏 → {msg}）")
            return msg
        data[i] ^= 0xFF  # 复原

    raise SystemExit(f"{dst_rel}：从正中到文件尾都没找到能造出「数据错」的位置")


# ---------------------------------------------------------------------------
# 对照表
# ---------------------------------------------------------------------------

# 每个文件「在 app 里该看到什么」。这张表是人工写的判断（不是自检跑出来的）：
# 自检给的是 **7-Zip 的症状**，这里写的是 **我们的路由**。两者对不上的地方，
# 就是 bug 所在 —— 这正是这组夹具存在的意义。
EXPECT = {
    "plain": "不该出任何密码/错误弹窗，直接解压成功",
    "enc": "见下方分档（同一种「错密码」，不同格式落点不同）",
    "split": f"从入口卷点起，一次解出整包（切点 {VOLUME}）",
    "fake": "嗅探出真格式 → 弹「格式检测」→ 按真格式解",
    "nested": "解完 L1 自动接着解 a.7z 与 b.tar.gz（连钻两层）",
    "corrupt": "见下方「刻意的不对称」",
}

# 加密那批按「有没有密码校验字」分档 —— 与 `duz_engine.cpp` 的
# `HasPasswordCheck()` 是同一份判据。**校验字 = 谁会在解码前报 kWrongPassword**。
NO_CHECK_WORD = (
    "enc/7z_压缩_加密.7z",
    "enc/7z_stored_加密.7z",
)
HEADER_ENCRYPTED = (
    "enc/7z_头加密.7z",
    "enc/rar5_头加密.rar",
)


def expectation_of(rel):
    if rel in NO_CHECK_WORD:
        return "错密码 → **「密码或损坏」**（分不清）→ 会去试密码库"
    if rel in HEADER_ENCRYPTED:
        return "错密码 → 打不开，「密码未匹配」（头加密，最确定的一档）"
    if rel.startswith("enc/"):
        return "错密码 → 「密码未匹配」（**有校验字，能确定**）→ 会去试密码库"
    if rel == "corrupt/zip_aes256_坏数据.zip":
        return "密码是**对的**、坏的是数据 → 「文件已损坏」，**不**试密码库"
    if rel == "corrupt/7z_stored_坏数据.7z":
        return "密码对、数据坏 → 仍说**「密码或损坏」**（没校验字，我们分不出来）"
    return EXPECT.get(rel.split("/")[0], "")


def write_readme(rows):
    def col(rows, rel, idx):
        for r in rows:
            if r[0] == rel:
                return r[idx]
        return "-"

    lines = [
        "DeepUnzip 真机验收夹具 —— 一个密码走到底",
        "=" * 60,
        "",
        f"密码：{PASSWORD}    （所有加密包都是它）",
        f"错密码对照用的是 {WRONG_PASSWORD}，没写进任何夹具。",
        "",
        "**密码库现在是空库起步**，所以先在设置/密码库页把这个密码加进去，",
        "「自动试密码库」那条路才有东西可试。想验「库里也没有」的表现，",
        "再加进去之前先解一遍即可。",
        "",
        "每份里「对密码 / 错密码」两行是**本机 7z.exe 实测**报出来的原话",
        "（`7z t`，与引擎跑的同一份 7-Zip handler），「预期」那行是**预期在 app 里",
        "该看到什么**。",
        "",
        "推设备：adb push build/types /sdcard/Download/duz_types",
        "（解压时输出目录同级生成，别把夹具放在你自己要用的目录里）",
        "",
        "怎么读这张表",
        "-" * 60,
        "错密码的落点只有三档：",
        "",
        "  1. 「密码未匹配」—— 有密码校验字（ZIP 的 AES 校验字 / ZipCrypto 的头校验、",
        "     RAR5 的 psw check）。密码错在**解码之前**就被拒了，能确定。",
        "  2. 「密码或损坏」—— 没有校验字（7z、RAR3 的内容加密）。错密码解出来是",
        "     噪声，只能从下游症状猜，**我们不知道是哪一种**，所以如实说。会去试",
        "     密码库。",
        "  3. 打不开 / 头错误 —— 头加密（`-mhe` / `-hp`）。头自带校验，也是确定的。",
        "",
        "「刻意的不对称」（`corrupt/` 与 `enc/` 对照着看）",
        "-" * 60,
        "**同样是「CRC 对不上」，有校验字的格式上说明密码是对的、坏的是数据**",
        "（密码错根本走不到 CRC）；**没校验字的格式上就分不清了**。所以我们只对",
        "后者放宽成「密码或损坏」，前者照旧记「文件已损坏」。这组夹具就是来钉这条的：",
        "",
        f"  corrupt/zip_aes256_坏数据.zip   密码对 → {col(rows, 'corrupt/zip_aes256_坏数据.zip', 2)}",
        f"                                 密码错 → {col(rows, 'corrupt/zip_aes256_坏数据.zip', 3)}",
        f"  corrupt/7z_stored_坏数据.7z     密码对 → {col(rows, 'corrupt/7z_stored_坏数据.7z', 2)}",
        f"                                 密码错 → {col(rows, 'corrupt/7z_stored_坏数据.7z', 3)}",
        "",
        "两个「坏数据」夹具在 7-Zip 眼里症状相同（都是 CRC 错），**但我们的落点该",
        "不同** —— 前者「文件已损坏」，后者「密码或损坏」。",
        "",
        "顺带一提：**7-Zip 自己的图形界面在这里是猜的**（对所有加密失败都追加",
        "「Wrong password?」，含 CRC 错）。我们比它多说一句「分不出来」，不是功能",
        "更强，是说法更诚实。",
        "",
        "全部文件（按目录分组）",
        "-" * 60,
        "每份三行：对密码时 7-Zip 说什么、错密码时说什么、预期在 app 里看到什么。",
        "第一列是**实测原话**，第三列是**我们的路由** —— 两者对不上就是 bug。",
    ]

    # **不排成一张宽表**：那些报错原话动不动上百字符，还会撞上「中文算两格」
    # 的老问题，列对齐一崩就成了一坨（第一版就是这样，自己都读不下去）。
    last_dir = None
    for rel, kind, right, wrong in rows:
        top = rel.split("/")[0]
        if top != last_dir:
            lines.append("")
            lines.append(f"[{top}]")
            last_dir = top
        lines.append(f"  {rel}")
        lines.append(f"      对密码 : {right}")
        if wrong != "-":
            lines.append(f"      错密码 : {wrong}")
        lines.append(f"      预期   : {expectation_of(rel)}")

    lines += [
        "",
        "分卷的入口卷",
        "-" * 60,
        "  裸切分（7z / zip 都是这套命名）  .7z.001 / .zip.001  ← 从 001 开始",
        "  RAR5                            .part1.rar           ← 从 part1 开始",
        "  RAR3                            .rar                 ← 从 .rar 开始（.r00 在后）",
        "",
        "点入口卷，其余同族卷应当被自动带上；缺一卷应当报「分片不连续」。",
        "",
        "**没有 Info-ZIP 跨卷（`.z01`…+`.zip`）的夹具**，见上面那一节 —— 本机造不出",
        "真的那种（7-Zip 只切字节流、不产 spanning），改名造出来的会被 7-Zip 判成",
        "「Unavailable data」，测了也是白测。要验得从外部拿一个真样本。",
        "",
        "注意 `.zip.001` 这套命名 7-Zip 是**认**的（实测 `7z t` 读得过），所以 zip",
        "的裸切分和 7z 的走同一条路，不需要单独特殊处理。",
        "",
        "重造",
        "-" * 60,
        "  python tool/make_type_fixtures.py",
        "  （密码在这个脚本的 PASSWORD 常量里 —— 仓库里有记录，不会像 build/devfix",
        "   那批加密 7z/rar5 一样，过几天就没人知道密码了）",
        "",
        "RAR3 为什么不在这一批里",
        "-" * 60,
        "RAR 7 **不能创建** RAR4/RAR3 格式：",
        "",
        "  Rar.exe a -ma5 out.rar <files>   OK（产物签名 ...0701 00 = RAR5）",
        "  Rar.exe a -ma4 out.rar <files>   错误: 未知选项: ma4",
        "",
        "所以本机**造不出 RAR3 夹具**（`7z.exe` 也不能压 RAR）。要验 RAR3 那三条",
        "失败路，只能：① 换一个 6.x 的 Rar.exe；② 从别处拿一个真 RAR3 文件；",
        "③ 按源码推 —— 它的机理与 enc/7z_压缩_加密.7z（压缩条目 → kDataError）",
        "和 enc/7z_stored_加密.7z（stored 条目 → kCRCError）各自对应。",
        "",
        "（写这段时差点搞错一次：以为「装了 WinRAR = RAR3 能造」。不能。）",
    ]

    path = p("README.txt")
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    print(f"\n对照表 → {path}")


# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------


def main():
    for exe in (SEVEN_ZIP, RAR):
        if not os.path.exists(exe):
            raise SystemExit(f"找不到 {exe}（用环境变量 SEVEN_ZIP / RAR 指定）")

    files = build_src()
    shutil.rmtree(ROOT, ignore_errors=True)

    print(f"7z  {SEVEN_ZIP}")
    print(f"rar {RAR}")
    print(f"密码 {PASSWORD}（错密码对照用 {WRONG_PASSWORD}）\n")

    made = {}  # 相对路径 -> 造法（给 README 分节用）

    print("[plain] 未加密")
    for rel, make, override in PLAIN:
        out = p(rel)
        os.makedirs(os.path.dirname(out), exist_ok=True)
        make(out, override if override is not None else files)
        made[rel] = "plain"
        print(f"  {rel:<32} {os.path.getsize(out):>8} B")

    print("\n[enc] 加密（全 duz-test）")
    for rel, make in ENCRYPTED:
        out = p(rel)
        os.makedirs(os.path.dirname(out), exist_ok=True)
        make(out, files)
        made[rel] = "enc"
        print(f"  {rel:<32} {os.path.getsize(out):>8} B")

    print("\n[split] 分卷")
    split_dir = p("split")
    os.makedirs(split_dir, exist_ok=True)
    listed = set()  # 已经归过类的卷名，用来认「这一次新出来的」
    for base_rel, make, entry in SPLIT:
        make(p(base_rel), files)
        produced = sorted(set(os.listdir(split_dir)) - listed)
        listed |= set(produced)
        for name in produced:
            rel = f"split/{name}"
            made[rel] = "split" if name == entry else "split-part"
            mark = "  ← 入口卷" if name == entry else ""
            print(f"  {rel:<32} {os.path.getsize(p(rel)):>8} B{mark}")
        # 起名规则变了（7z 换个版本就换了）要当场炸，别静默去测一个不存在的入口
        assert f"split/{entry}" in made, (
            f"{base_rel} 没造出预期入口卷 {entry} —— 实际产物：{produced}"
        )

    print("\n[fake] 伪后缀 / 前置数据")
    for rel, make in FAKE:
        out = p(rel)
        os.makedirs(os.path.dirname(out), exist_ok=True)
        make(out, files)
        made[rel] = "fake"
        print(f"  {rel:<32} {os.path.getsize(out):>8} B")
    rel = "fake/前置数据.zip"
    os.makedirs(os.path.dirname(p(rel)), exist_ok=True)
    make_prefixed_zip(p(rel), files)
    made[rel] = "fake"
    print(f"  {rel:<32} {os.path.getsize(p(rel)):>8} B")

    print("\n[nested] 嵌套")
    build_nested()
    made["nested/L1.zip"] = "nested"
    print(f"  {'nested/L1.zip':<32} {os.path.getsize(p('nested/L1.zip')):>8} B")

    print("\n[corrupt] 真损坏（对照 enc/ 里同类型的「密码错」）")
    corrupt = []
    for src, dst in (
        ("enc/zip_aes256.zip", "corrupt/zip_aes256_坏数据.zip"),
        ("enc/7z_stored_加密.7z", "corrupt/7z_stored_坏数据.7z"),
    ):
        print(f"  {dst}")
        msg = corrupt_copy(src, dst, PASSWORD)
        made[dst] = "corrupt"
        corrupt.append((src, dst, msg))

    # ---- 本机自检 + README ----
    print("\n[自检] 每个包都拿 7z t 过一遍（对密码 / 错密码）")
    rows = []
    for rel in sorted(made):
        if made[rel] == "split-part":
            continue  # 伴生卷单独测没意义，入口卷已经把整包测了
        path = p(rel)
        kind = made[rel]
        # **只给真的要密码的包喂密码**：未加密的分卷（naked/r5）喂什么都「成功」，
        # 那样「错密码」那一列会显示成通过，读表的人会以为夹具坏了。
        locked = kind in ("enc", "corrupt") or rel in ENCRYPTED_SPLIT
        right = probe(path, PASSWORD if locked else None)
        wrong = probe(path, WRONG_PASSWORD) if locked else "-"
        rows.append((rel, kind, right, wrong))
        print(f"  {rel:<34} 对: {right[:46]:<46} 错: {wrong[:44] if wrong != '-' else '-'}")

    print("\n自检里出现过的四种说法：")
    for token in ("CRC", "Data Error", "Wrong password", "Cannot open"):
        hits = sum(1 for _, _, _, w in rows if token.lower() in w.lower())
        print(f"  {token:<16} {hits} 个")

    write_readme(rows)
    shutil.rmtree(SRC, ignore_errors=True)
    print(f"\n源材料已删（{SRC}）；夹具与对照表在 {ROOT}/")


if __name__ == "__main__":
    main()
