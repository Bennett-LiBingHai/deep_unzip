"""生成真机「密码解锁与弹窗」验收用的夹具（需求 2）。

## 为什么是 Python 而不是 Dart

仓库里另外两个夹具工具都是 Dart（`make_keepalive_fixtures.dart`、
`make_fixtures.dart`），因为 `package:archive` 就够了。加密包它不够：

- **ZipCrypto 写不了**。`archive` 4.3 只能*读*传统加密，写只有 WinZip AES
  一条路（`ZipEncoder(password:)`）。
- **它写的 AES 不是 WinZip 的标准写法**。`zip_encoder.dart` 里写的是
  「AE 版本 = 1、强度 = 3（256 位）」，而 WinZip 规范里 AE-1 配 128 位、
  AE-2 配 256 位 —— 这个组合属于规范里没定义的那一格。7-Zip 愿不愿意收它，
  只能拿到真机上试；真机那一轮是**最贵的一次验证**，不能拿来赌一个不标准的
  夹具。所以 AES 走 `pyzipper`（WinZip AES 的参考实现，写出来就是 AE-2）。

ZipCrypto 那一个干脆手写：算法只有三个 32 位状态字，写完用 Python 自己的
`zipfile` 读回来 —— 它按传统加密逐字节校验并核对 CRC32，读得过就说明密文是
对的，**在本机就能定死**，不用等真机。

## 装依赖

    python -m pip install pyzipper        # 只为了写 AES 那两个

## 产物（build/devfix/pwd/）

夹具刻意只有两三个二百字节的小文件：真机上 /sdcard 走 FUSE，每建一个小文件
要 6~17 毫秒（见 `make_keepalive_fixtures.dart` 的量账），而密码这一轮要连着
跑好几批。包一大，用户等的就是磁盘而不是功能。

    1_manual/locked_horse.zip   AES-256，密码 `correct-horse`（**故意不在库里的
                                那一轮由用户手敲**），后面跟一个 plain.zip
    2_skip/  locked_spring.zip  AES-256，密码 `spring-2026`（永远不进密码库）
    3_stop/  locked_spring.zip  同上 —— 与 2_skip 分开一份，是因为「停止」那条
                                出口要验的是「后面的包**根本没被解出来**」，
                                而 2_skip 那一趟已经把 plain 解出来了
    4_vault/ locked_horse.zip   AES-256，密码 `correct-horse`（已进密码库）
             locked_1999.zip    ZipCrypto，密码 `backup-1999`（已进密码库）

用法：

    python tool/make_password_fixtures.py
"""

import os
import struct
import zipfile
import zlib

import pyzipper

# 条目内容：小、好认、肉眼能确认解出来的是对的。
ENTRIES = {
    "readme.txt": "这是加密压缩包里的正文，能看到它就说明密码对了。\n",
    "data/log.txt": "second entry\n",
    "data/note.txt": "third entry\n",
}

# ZipCrypto 的 12 字节加密头里前 11 个字节照规范是随机的。这里写死 —— 夹具要
# 可复现，重跑一次应该得到同一个文件（也让 diff 有意义）。
ZC_SALT = bytes.fromhex("0102030405060708090a0b")


# ---------------------------------------------------------------------------
# WinZip AES（AE-2，256 位）
# ---------------------------------------------------------------------------


def write_aes_zip(path, password, entries=ENTRIES):
    with pyzipper.AESZipFile(
        path,
        "w",
        compression=pyzipper.ZIP_DEFLATED,
        encryption=pyzipper.WZ_AES,
    ) as z:
        z.setpassword(password.encode())
        z.setencryption(pyzipper.WZ_AES, nbits=256)
        for name, text in entries.items():
            z.writestr(name, text)

    # 读回来：密文对不对、密码有没有写错，本机就能定死。
    with pyzipper.AESZipFile(path) as z:
        z.setpassword(password.encode())
        for name, text in entries.items():
            assert z.read(name).decode() == text, name


# ---------------------------------------------------------------------------
# ZipCrypto（PKWARE 传统加密）
#
# 三个 32 位状态字 + 一条 CRC32 表，规范原文见 APPNOTE 6.1 的
# 「Traditional PKWARE Encryption」。写的是 **stored**（不压缩）：压缩算法与
# 加密无关，而 stored 少一层可能出错的地方。
# ---------------------------------------------------------------------------


def _gen_crc(crc):
    for _ in range(8):
        crc = 0xEDB88320 ^ (crc >> 1) if crc & 1 else crc >> 1
    return crc


_CRCTABLE = [_gen_crc(i) for i in range(256)]


class ZipCrypto:
    """**密钥调度里的 CRC 不是 `zlib.crc32`。**

    这两个太像了，第一版就栽在这里：`zlib.crc32` 在算之前把值取反、算完再取反
    （`crc ^ 0xFFFFFFFF` 进、`^ 0xFFFFFFFF` 出），而 ZIP 加密用的那张表是**裸**
    的 —— `(crc >> 8) ^ table[(crc ^ ch) & 0xFF]`，进出都不取反。混用之后密文
    结构完全合法、密码也是对的，就是校验字节对不上，读的人只会说「密码错」。

    （条目头里那个 `CRC` 字段用的是**标准** zlib 校验值 —— 那是另一回事，
    下面照用 `zlib.crc32`。同一个文件里两种 CRC 并存，别把它们当成一个。）
    """

    def __init__(self, password):
        self.k0, self.k1, self.k2 = 0x12345678, 0x23456789, 0x34567890
        for c in password.encode():
            self._update(c)

    @staticmethod
    def _crc(ch, crc):
        return (crc >> 8) ^ _CRCTABLE[(crc ^ ch) & 0xFF]

    def _update(self, c):
        self.k0 = self._crc(c, self.k0)
        self.k1 = (self.k1 + (self.k0 & 0xFF)) & 0xFFFFFFFF
        self.k1 = (self.k1 * 134775813 + 1) & 0xFFFFFFFF
        self.k2 = self._crc(self.k1 >> 24, self.k2)

    def _byte(self):
        t = (self.k2 | 2) & 0xFFFF
        return ((t * (t ^ 1)) >> 8) & 0xFF

    def encrypt(self, data):
        """明文 → 密文。**更新状态字用的是明文**，这一步很容易写反。"""
        out = bytearray()
        for p in data:
            c = p ^ self._byte()
            self._update(p)
            out.append(c)
        return bytes(out)


# 固定的 DOS 时间（2026-01-01 00:00），让产物可复现。
DOS_TIME, DOS_DATE = 0x0000, 0x2A01


def write_zipcrypto_zip(path, password, entries=ENTRIES):
    local, central, offset = [], [], 0

    for name, text in entries.items():
        raw = text.encode()
        crc = zlib.crc32(raw) & 0xFFFFFFFF
        name_b = name.encode()

        # 加密头 12 字节，最后一字节是校验：
        #   通用位 3 **没置位**（尺寸与 CRC 都写在头里）→ 校验字节 = CRC 高字节。
        # 置了位 3 的话就得改用 DOS 时间的高字节 —— 两条路都合规范，Python 与
        # 7-Zip 读的也是同一个字段，这里选信息量更大的那条。
        header = ZC_SALT + bytes([(crc >> 24) & 0xFF])
        blob = ZipCrypto(password).encrypt(header + raw)

        local.append(
            struct.pack(
                "<IHHHHHIIIHH",
                0x04034B50,
                20,           # version needed
                0x0001,       # flags: 加密
                0,            # method: stored
                DOS_TIME,
                DOS_DATE,
                crc,
                len(blob),
                len(raw),
                len(name_b),
                0,
            )
            + name_b
            + blob
        )

        central.append(
            struct.pack(
                "<IHHHHHHIIIHHHHHII",
                0x02014B50,
                20,           # version made by
                20,           # version needed
                0x0001,
                0,            # stored
                DOS_TIME,
                DOS_DATE,
                crc,
                len(blob),
                len(raw),
                len(name_b),
                0,            # extra
                0,            # comment
                0,            # disk
                0,            # internal attrs
                0,            # external attrs
                offset,
            )
            + name_b
        )
        offset += len(local[-1])

    body = b"".join(local)
    cd = b"".join(central)
    eocd = struct.pack(
        "<IHHHHIIH",
        0x06054B50,
        0,
        0,
        len(entries),
        len(entries),
        len(cd),
        len(body),
        0,
    )

    with open(path, "wb") as f:
        f.write(body + cd + eocd)

    # 本地校验：Python 的 `zipfile` 会逐字节验加密头、再核对 CRC32。
    # 它读得过 = 密文是对的，不必等真机。
    with zipfile.ZipFile(path) as z:
        z.setpassword(password.encode())
        for name, text in entries.items():
            assert z.read(name).decode() == text, name


# ---------------------------------------------------------------------------

ROOT = os.path.join("build", "devfix", "pwd")

PLAN = [
    ("1_manual/locked_horse.zip", "correct-horse", "aes"),
    ("1_manual/plain.zip", None, "plain"),
    ("2_skip/locked_spring.zip", "spring-2026", "aes"),
    ("2_skip/plain.zip", None, "plain"),
    ("3_stop/locked_spring.zip", "spring-2026", "aes"),
    ("3_stop/plain.zip", None, "plain"),
    ("4_vault/locked_horse.zip", "correct-horse", "aes"),
    ("4_vault/locked_1999.zip", "backup-1999", "zipcrypto"),
]


def main():
    for rel, pwd, kind in PLAN:
        path = os.path.join(ROOT, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        if kind == "aes":
            write_aes_zip(path, pwd)
        elif kind == "zipcrypto":
            write_zipcrypto_zip(path, pwd)
        else:
            with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
                for name, text in ENTRIES.items():
                    z.writestr(name, text)
        size = os.path.getsize(path)
        print(f"  {rel:<32} {kind:<10} {pwd or '-':<14} {size} B")

    print("\n都在本机读回来验过了（AES 用 pyzipper、ZipCrypto 与明文用 zipfile）。")


if __name__ == "__main__":
    main()
