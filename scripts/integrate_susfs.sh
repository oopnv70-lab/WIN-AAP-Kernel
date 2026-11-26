#!/usr/bin/env bash
# 集成 SUSFS（susfs4ksu, gki-android16-6.12）到荣耀 AAP-AN00 6.12.58 内核树。
# 用法：integrate_susfs.sh <KERNEL_PLATFORM> [SUSFS_REF]
#   KERNEL_PLATFORM —— 含 common/ 的内核工程根（即 kp/）
#   SUSFS_REF       —— 分支名，默认 gki-android16-6.12
#
# 上游来源：GitLab simonpunk/susfs4ksu（GitHub 无此仓库；simonpunk/susfs4ksu 的 GitHub 地址 404）
#
# 本脚本做的三件事：
#   1) 取上游补丁 50_add_susfs_in_gki-android16-6.12.patch 与 3 个新增文件
#   2) 打补丁：26 个文件 patch 可干净应用；fs/proc/task_mmu.c 的 3 个 hunk 与荣耀树不符，
#      改由 scripts/shim_susfs_task_mmu.py 按语义等价位置插入（详见该脚本头部注释）
#   3) 校验：无 .rej / 无 FAILED；fs/Makefile 含 susfs.o；三个新增文件就位
set -euo pipefail

ROOT="${1:-}"
SUSFS_REF="${2:-gki-android16-6.12}"
if [ -z "$ROOT" ]; then
  echo "::error::用法: $0 <KERNEL_PLATFORM> [SUSFS_REF]" >&2
  exit 1
fi

SUSFS_URL="https://gitlab.com/simonpunk/susfs4ksu.git"
COMMON="${ROOT}/common"
WORK="${RUNNER_TEMP:-/tmp}/susfs4ksu"
PATCH_NAME="50_add_susfs_in_gki-android16-6.12.patch"

# 在 cd 之前解析脚本目录为绝对路径，否则后续 cd 到 common 后会找不到同目录脚本
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> KERNEL_PLATFORM = $ROOT"
echo "==> SUSFS ref = $SUSFS_REF"
test -d "$COMMON" || { echo "::error::找不到 common/ ($COMMON)"; exit 1; }

# ============ 1. 拉取上游 ============
rm -rf "$WORK"
mkdir -p "$WORK"
echo "==> clone $SUSFS_URL ($SUSFS_REF)"
git clone --depth 1 -b "$SUSFS_REF" "$SUSFS_URL" "$WORK/susfs4ksu"
SRC="$WORK/susfs4ksu"
PATCH="$SRC/kernel_patches/$PATCH_NAME"
test -f "$PATCH" || { echo "::error::找不到补丁 $PATCH"; exit 1; }
echo "  上游 commit: $(git -C "$SRC" log -1 --format='%h %s' 2>/dev/null || echo unknown)"
echo "  补丁大小: $(wc -c < "$PATCH") B"

# ============ 2. 放置新增文件（fs/susfs.c + 两个头文件）============
echo "==> 放置新增文件"
cp -v "$SRC/kernel_patches/fs/susfs.c"                 "$COMMON/fs/susfs.c"
cp -v "$SRC/kernel_patches/include/linux/susfs.h"      "$COMMON/include/linux/susfs.h"
cp -v "$SRC/kernel_patches/include/linux/susfs_def.h"  "$COMMON/include/linux/susfs_def.h"

# ============ 3. 打补丁：整份打，只允许 task_mmu.c 的 3 个 hunk 失败 ============
# 注意：不能把 task_mmu.c 整个排除。补丁对它有 8 个 hunk，其中 Hunk#1 是
#   +#include <linux/susfs_def.h>
# 正是 SUSFS_IS_INODE_SUS_MAP 等宏的来源；Hunk#2/#3 是 show_map_vma 的
# open_redirect / sus_kstat spoof；Hunk#7/#8 是 pagemap_read 的 SUS_MAP 判断。
# 这 5 个 hunk 在荣耀树上能干净应用，只有 #4/#5/#6 因函数名与循环结构差异失败。
# 早期版本把整个文件排除，导致 #1 没打上，编译报
#   error: call to undeclared function 'SUSFS_IS_INODE_SUS_MAP'
# 实测（run 45750958383）已复现，故改为：整份 patch -> 只接受 3 hunks FAILED -> 垫片补。
echo "==> 打补丁（全 27 个文件，整份应用）"
cd "$COMMON"
set +e
patch -p1 --forward --no-backup-if-mismatch < "$PATCH" > "$WORK/patch.log" 2>&1
PATCH_RC=$?
set -e
grep -E 'patching file|Hunk #[0-9]+ (succeeded|FAILED)|FAILED -- saving' "$WORK/patch.log" | tail -20
# 失败的必须只有 task_mmu.c 那一条：3 out of 8 hunks FAILED
if grep -q 'FAILED' "$WORK/patch.log"; then
  REJLIST=$(find . -name '*.rej' -printf '%p\n' 2>/dev/null | sort | tr '\n' ' ')
  echo "  ! 补丁有失败，.rej 清单=[$REJLIST]"
  # 只允许 fs/proc/task_mmu.c 一个 .rej，且失败数恰为 3/8
  if [ "$REJLIST" != "./fs/proc/task_mmu.c.rej " ] || ! grep -q '3 out of 8 hunks FAILED' "$WORK/patch.log"; then
    echo "::error::补丁失败范围超出预期（期望仅 fs/proc/task_mmu.c 的 3/8 hunks）"
    grep -B3 'FAILED' "$WORK/patch.log" | head -60
    exit 1
  fi
  echo "  ✓ task_mmu.c 恰好 3/8 hunks 失败（垫片负责补），其余 5 个 hunk 已落地"
else
  echo "  ✓ 全部 hunk 干净应用（无需垫片）"
fi
echo "  ✓ 27 个文件补丁应用完成（rc=$PATCH_RC）"

# ============ 4. task_mmu.c 垫片 ============
echo "==> 应用 task_mmu.c 垫片"
python3 "$SCRIPT_DIR/shim_susfs_task_mmu.py" "$COMMON/fs/proc/task_mmu.c"
# 垫片补完 3 个 hunk 后，task_mmu.c 的 .rej 已无意义，删除；随后自检会确认全树无 .rej 残留
if [ -f "$COMMON/fs/proc/task_mmu.c.rej" ]; then
  rm -f "$COMMON/fs/proc/task_mmu.c.rej"
  echo "  已删除 fs/proc/task_mmu.c.rej（3 个 hunk 已由垫片补齐）"
fi

# ============ 5. fs/Makefile 挂 susfs.o ============
MAKEFILE="$COMMON/fs/Makefile"
if grep -q 'susfs\.o' "$MAKEFILE"; then
  echo "==> fs/Makefile 已含 susfs.o，跳过"
else
  printf '\nobj-$(CONFIG_KSU_SUSFS) += susfs.o\n' >> "$MAKEFILE"
  echo "==> fs/Makefile 已追加 obj-\$(CONFIG_KSU_SUSFS) += susfs.o"
fi

# ============ 6. 自检 ============
echo "==> 自检"
fail=0
chk() { if eval "$2"; then echo "  ✓ $1"; else echo "  ✗ $1"; fail=1; fi; }
chk "fs/susfs.c 存在"            "test -f '$COMMON/fs/susfs.c'"
chk "include/linux/susfs.h 存在" "test -f '$COMMON/include/linux/susfs.h'"
chk "include/linux/susfs_def.h"  "test -f '$COMMON/include/linux/susfs_def.h'"
chk "fs/Makefile 含 susfs.o"     "grep -q 'susfs\\.o' '$MAKEFILE'"
chk "task_mmu.c 含 SUS_MAP 早退"  "grep -q 'SUSFS_IS_INODE_SUS_MAP' '$COMMON/fs/proc/task_mmu.c'"
chk "task_mmu.c 含 susfs_def.h 头文件" "grep -q '#include <linux/susfs_def.h>' '$COMMON/fs/proc/task_mmu.c'"
chk "task_mmu.c 含 show_map_vma open_redirect" "grep -q 'susfs_open_redirect_spoof_show_map_vma_srcu' '$COMMON/fs/proc/task_mmu.c'"
chk "task_mmu.c 含 pagemap SUS_MAP" "grep -q 'vma->vm_file && SUSFS_IS_INODE_SUS_MAP' '$COMMON/fs/proc/task_mmu.c'"
chk "task_mmu.c 含 continue 跳过" "grep -q 'continue;' '$COMMON/fs/proc/task_mmu.c'"
chk "namei.c 含 sus_path 判断"    "grep -q 'susfs_is_inode_sus_path' '$COMMON/fs/namei.c'"
chk "namespace.c 含 sus_mount"    "grep -q 'susfs_' '$COMMON/fs/namespace.c'"
chk "无 .rej 残留"                "[ -z \"\$(find '$COMMON' -name '*.rej' -print -quit)\" ]"

# SUSFS 定义 vs 引用双向核对
echo "==> 符号完整性核对（定义 vs 引用）"
python3 "$SCRIPT_DIR/check_susfs_symbols.py" "$COMMON" || fail=1

if [ "$fail" -ne 0 ]; then
  echo "::error::SUSFS 集成自检未通过"
  exit 1
fi
echo "==> SUSFS 集成完成（$SUSFS_REF）"