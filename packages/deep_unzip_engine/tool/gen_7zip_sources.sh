#!/usr/bin/env bash
# 从 7-Zip 官方 makefile 生成 CMake 的源文件清单。
#
# 为什么不手抄：7-Zip 的 Format7zF 目标有 300+ 个目标文件，散在 Arc_gcc.mak 与
# Alone2/makefile.gcc 的 ~25 个变量里，手抄必错。而 makefile 里的
# `$O/Xxx.o: ../../../Common/Xxx.cpp` 类规则把「目标文件 ← 源文件」写全了，
# 且实测 basename 在本树里无歧义，所以可以机械映射。
#
# 本机没有 make（Windows + Git Bash），所以这里不是跑 make，而是**定向求值**：
# 只实现这份 makefile 用到的方言（行续接、`=` / `+=`、ifdef/ifndef/else/endif），
# 并把配置假设显式写死如下：
#
#   - 非 MinGW（目标为 Android/Linux，SYS_OBJS 只取 MyWindows.o）
#   - ST_MODE 未启用 → 采用 MT_OBJS（多线程）。注意 MT_OBJS 定义在 Arc_gcc.mak
#     第 20/27 行，位于下面的抽取区间之外，所以是**手工追加**进来的，见 MT_OBJS 段。
#   - DISABLE_RAR / DISABLE_RAR_COMPRESS 均未定义 → RAR 解码器与 RAR 加密参与编译。
#     7-Zip 不含任何 RAR 编码器，故这是 unRAR 条款允许的「只解不压」用法。
#
# 用法: gen_7zip_sources.sh <7zip源码根> <输出.cmake>

set -euo pipefail

SRC=${1:?用法: gen_7zip_sources.sh <7zip源码根> <输出.cmake>}
OUT=${2:?用法: gen_7zip_sources.sh <7zip源码根> <输出.cmake>}

ARC="$SRC/CPP/7zip/Bundles/Format7zF/Arc_gcc.mak"
ALONE="$SRC/CPP/7zip/Bundles/Alone2/makefile.gcc"
for f in "$ARC" "$ALONE"; do
  [ -f "$f" ] || { echo "找不到 $f" >&2; exit 1; }
done

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# ---- 1. Arc_gcc.mak：从 COMMON_OBJS 起到 ARC_OBJS 前，取出所有 $O/*.o ----
# 该区间内的条件块只有 283-285（ifdef DISABLE_RAR，未定义故不生效），且它不含
# 任何 .o 条目，因此区间抽取在此配置下是安全的（已逐块核对）。
sed -n '/^COMMON_OBJS = /,/^ARC_OBJS = /p' "$ARC" \
  | grep -oE '\$O/[A-Za-z0-9_]+\.(o|obj)' >> "$tmp/objs"

# ---- 2. MT_OBJS：多线程对象，定义在抽取区间之外，手工追加 ----
# 对照 Arc_gcc.mak 第 27-40 行（`else` 分支，即未定义 ST_MODE 时）。
cat >> "$tmp/objs" <<'EOF'
$O/LzFindMt.o
$O/LzFindOpt.o
$O/Threads.o
$O/MemBlocks.o
$O/OutMemStream.o
$O/ProgressMt.o
$O/StreamBinder.o
$O/Synchronization.o
$O/VirtThread.o
EOF

# ---- 3. Alone2/makefile.gcc：只取非 MinGW 分支 ----
# SYS_OBJS 在 ifdef IS_MINGW 的两个分支里各定义一次，直接区间抽取会把 Windows
# 专用的 DLL/Registry/MemoryLock/FileSystem/DllSecur/resource 一起收进来
# （它们都能在树里找到同名文件，所以"路径存在"这种校验查不出来，只会炸在编译期）。
# 这里只取 `else` 之后那一份。
# 注意 `else`/`endif` 这两行必须 next 掉：它们先改了标志位，随后会被
# `nm{print}` 匹配到而把自己当成条目输出（踩过一次）。
awk '/^ifdef IS_MINGW/{m=1}
     /^else/  {if(m){m=0; nm=1}; next}
     /^endif/ {nm=0; m=0; next}
     nm{print}' "$ALONE" >> "$tmp/objs"
# 其余几组是无条件定义的，直接抽。
for v in UI_COMMON_OBJS COMMON_OBJS_2 WIN_OBJS_2 7ZIP_COMMON_OBJS_2; do
  sed -n "/^$v = /,/^$/p" "$ALONE" >> "$tmp/objs"
done

# ---- 4. basename 去重 ----
# 必须先用 -o 把 `$O/Xxx.o` 抠成独立片段再处理：makefile 的行尾带续行反斜杠
# （`$O/FileDir.o \`），若先做替换，`.o` 不在行尾就去不掉，后面任何严格匹配
# 都会一条都匹配不到（这里踩过一次，且当时正好有条被误当条目的 `else` 行
# 喂饱了 grep，把问题掩盖了）。
# 去掉后缀用两次显式替换：本机 GNU sed 4.9 里 `s|\.\(o\|obj\)$||` 的 `\|` 交替
# 不会被当作交替（实测输出仍带 `.o`），只有拆成两条才生效。
grep -oE '\$O/[A-Za-z0-9_]+\.(o|obj)' "$tmp/objs" \
  | sed 's|^\$O/||; s|\.obj$||; s|\.o$||' \
  | sort -u > "$tmp/need"

# ---- 5. 映射到源文件，歧义/缺失一律硬失败 ----
: > "$tmp/sources"; amb=0; miss=0
while read -r n; do
  hits=$(find "$SRC/C" "$SRC/CPP" \( -name "$n.cpp" -o -name "$n.c" \) | sort)
  cnt=$(printf '%s' "$hits" | grep -c . || true)
  if [ "$cnt" -eq 0 ]; then
    echo "  [缺失] $n 找不到源文件" >&2; miss=$((miss+1))
  elif [ "$cnt" -gt 1 ]; then
    echo "  [歧义] $n 命中多个: $(echo "$hits" | tr '\n' ' ')" >&2; amb=$((amb+1))
  else
    printf '%s\n' "$hits" >> "$tmp/sources"
  fi
done < "$tmp/need"
[ "$amb" -eq 0 ] && [ "$miss" -eq 0 ] || { echo "映射失败（歧义 $amb / 缺失 $miss），拒绝生成" >&2; exit 1; }

# ---- 6. 输出 cmake ----
{
  echo "# 本文件由 tool/gen_7zip_sources.sh 生成，请勿手改。"
  echo "# 重新生成： bash tool/gen_7zip_sources.sh third_party/7zip src/7zip_sources.cmake"
  echo "#"
  echo "# 源文件数: $(wc -l < "$tmp/sources")"
  echo "set(DUZ_7ZIP_SOURCES"
  sed "s|^$SRC/||" "$tmp/sources" | sed 's|^|  ${DUZ_7ZIP_ROOT}/|'
  echo ")"
} > "$OUT"

echo "已生成 $OUT（$(wc -l < "$tmp/sources") 个源文件）"
