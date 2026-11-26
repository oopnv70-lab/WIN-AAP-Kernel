#!/usr/bin/env bash
# 门禁A：编译前校验 SukiSU-Nova 内核集成是否成功
#
# 目的：把「集成脚本说成功」升级为「可验证的事实」。
# 集成脚本自身自检有两个盲点：
#   1) BUILD.bazel 只 grep 字符串，不管 fragment 挂在哪个 target 上；
#   2) 软链是否指向真实存在的文件没查。
# 本脚本只做确定性文件检查，不依赖任何编译产物。
#
# 用法: check_integration.sh <KERNEL_PLATFORM>
set -uo pipefail

ROOT="${1:-}"
if [ -z "$ROOT" ]; then
  echo "::error::用法: $0 <KERNEL_PLATFORM>" >&2
  exit 1
fi

COMMON="$ROOT/common"
DRI="$COMMON/drivers"
FAIL=0

ok()   { echo "  ✓ $1"; }
bad()  { echo "::error::门禁A 失败: $1"; FAIL=1; }

echo "==== 门禁A：SukiSU-Nova 集成校验 ===="

# ---------- 1) 软链/目录真实可用 ----------
echo "[1] drivers/kernelsu 是否真实可用"
for f in Makefile Kconfig; do
  if [ -f "$DRI/kernelsu/$f" ]; then
    ok "drivers/kernelsu/$f 存在"
  else
    bad "drivers/kernelsu/$f 缺失（软链未生效或指向空）"
  fi
done
if [ -L "$DRI/kernelsu" ]; then
  echo "    （drivers/kernelsu 是符号链接 -> $(readlink "$DRI/kernelsu" 2>/dev/null || echo '?')）"
fi

# ---------- 2) Kbuild 挂载 ----------
echo "[2] drivers/Makefile 是否挂载 kernelsu"
if grep -qE 'obj-\$\(CONFIG_KSU\)[[:space:]]*\+=[[:space:]]*kernelsu/' "$DRI/Makefile" 2>/dev/null; then
  ok "drivers/Makefile 含 obj-\$(CONFIG_KSU) += kernelsu/"
else
  bad "drivers/Makefile 缺少 obj-\$(CONFIG_KSU) += kernelsu/"
fi

echo "[3] drivers/Kconfig 是否 source kernelsu/Kconfig"
if grep -qE 'source[[:space:]]+"drivers/kernelsu/Kconfig"' "$DRI/Kconfig" 2>/dev/null; then
  ok "drivers/Kconfig 含 source \"drivers/kernelsu/Kconfig\""
else
  bad "drivers/Kconfig 缺少 source \"drivers/kernelsu/Kconfig\""
fi

# ---------- 4) fragment 内容 ----------
FRAG="$COMMON/arch/arm64/configs/ksu.fragment"
echo "[4] ksu.fragment 内容"
if [ -f "$FRAG" ]; then
  if grep -qE 'CONFIG_KSU=y' "$FRAG"; then
    ok "ksu.fragment 含 CONFIG_KSU=y"
  else
    bad "ksu.fragment 存在但没有 CONFIG_KSU=y"
    sed -n '1,20p' "$FRAG"
  fi
  if grep -qE '^CONFIG_KSU_DEBUG=y' "$FRAG"; then
    ok "ksu.fragment 含 CONFIG_KSU_DEBUG=y（绕过 builtin-new 的 -g0，满足 gendwarfksyms）"
  else
    bad "ksu.fragment 缺 CONFIG_KSU_DEBUG=y（gendwarfksyms 会因 ksu.o 无调试信息而失败）"
  fi
else
  bad "ksu.fragment 不存在: $FRAG"
fi

# ---------- 5) 关键：fragment 是否挂在 kernel_aarch64 这个 target 上 ----------
# BUILD.bazel 里 common_kernel() 可能被调用多次（kernel_aarch64 / _16k / x86_64 ...），
# 每个块的 post_defconfig_fragments 各自独立。必须确认 kernel_aarch64 那一块引用了 ksu.fragment，
# 否则 CONFIG_KSU=y 会加到别的 target 上，编译 kernel_aarch64 时根本不生效。
echo "[5] ksu.fragment 是否挂到 kernel_aarch64 target（关键项）"
BB="$COMMON/BUILD.bazel"
if [ ! -f "$BB" ]; then
  bad "BUILD.bazel 不存在: $BB"
else
  PYC="$(dirname "$0")/_check_fragment_target.py"
  RES=$(python3 "$PYC" "$BB" 2>&1)
  RC=$?
  # Python 已输出 ::error:: 行，这里只补 pass 标记，避免重复报错
  printf '%s\n' "$RES" | grep -v '^::error::' || true
  case "$RC" in
    0) ok "kernel_aarch64 块已引用 ksu.fragment" ;;
    1) bad "kernel_aarch64 块没有引用 ksu.fragment（CONFIG_KSU=y 不会生效！）" ;;
    *) bad "BUILD.bazel 结构解析失败（找不到 kernel_aarch64 的 common_kernel 块）" ;;
  esac
fi

# ---------- 6) 包名没有被意外改坏 ----------
echo "[6] 包名定义"
# main 分支：Kbuild 里 KSU_PACKAGE_NAME ?= ...
# builtin 分支：没有 Kbuild，包名在 Makefile 里（KSU_PACKAGE_NAME ?= com.sukisu.nova）
PKG_SRC=""
if [ -f "$DRI/kernelsu/Kbuild" ]; then
  PKG_SRC="$DRI/kernelsu/Kbuild"
elif [ -f "$DRI/kernelsu/Makefile" ]; then
  PKG_SRC="$DRI/kernelsu/Makefile"
fi
if [ -n "$PKG_SRC" ]; then
  # 兼容 main 的 ?= 与 builtin/builtin-new 的 :=
  PN=$(grep -E 'KSU_PACKAGE_NAME[[:space:]]*[?:]?=' "$PKG_SRC" 2>/dev/null | head -1 | sed 's/.*=[[:space:]]*//')
  if [ -n "$PN" ]; then
    echo "    $(basename "$PKG_SRC") 中默认包名 = $PN"
    case "$PN" in
      com.sukisu.nova*) ok "包名为 $PN（nova 系列）" ;;
      *) bad "包名异常: $PN（期望 com.sukisu.nova）" ;;
    esac
  else
    echo "    ::warning::$(basename "$PKG_SRC") 未找到 KSU_PACKAGE_NAME 行（可能定义在别处，非致命）"
  fi
else
  bad "drivers/kernelsu 下既无 Kbuild 也无 Makefile"
fi

# ---------- 7) SUSFS（仅当启用时校验） ----------
if [ "${ENABLE_SUSFS:-false}" = "true" ]; then
  echo "[7] SUSFS 集成校验"
  # 前置条件：KSU 的 Kconfig 里必须真的存在 config KSU_SUSFS，否则 kleaf 配置校验必失败
  # （main 分支就缺这个符号，实测报 CONFIG_KSU_SUSFS: actual '', expected 'y'）
  if grep -q '^config KSU_SUSFS$' "$DRI/kernelsu/Kconfig" 2>/dev/null; then
    ok "KSU Kconfig 定义 config KSU_SUSFS"
  else
    bad "KSU Kconfig 缺 config KSU_SUSFS（SukiSU-Nova 分支选错，main 不支持 SUSFS）"
  fi
  if [ -f "$DRI/kernelsu/extension/susfs_extension.c" ]; then
    ok "KSU 侧 susfs_extension.c 存在"
  else
    bad "KSU 侧缺 extension/susfs_extension.c（该分支无 SUSFS 集成代码）"
  fi
  if grep -q '^config KSU_SUSFS_INLINE_HOOK$' "$DRI/kernelsu/Kconfig" 2>/dev/null; then
    ok "KSU Kconfig 定义 config KSU_SUSFS_INLINE_HOOK（builtin-new 布局）"
  else
    bad "KSU Kconfig 缺 config KSU_SUSFS_INLINE_HOOK（不是 builtin-new 布局，SUSFS 后端不可用）"
  fi
  for f in fs/susfs.c include/linux/susfs.h include/linux/susfs_def.h; do
    if [ -f "$COMMON/$f" ]; then ok "$f 存在"; else bad "$f 缺失"; fi
  done
  if grep -qE 'obj-\$\(CONFIG_KSU_SUSFS\)[[:space:]]*\+=[[:space:]]*susfs\.o' "$COMMON/fs/Makefile" 2>/dev/null; then
    ok "fs/Makefile 挂载 susfs.o"
  else
    bad "fs/Makefile 缺 obj-\$(CONFIG_KSU_SUSFS) += susfs.o"
  fi
  # task_mmu.c 垫片落位
  if grep -q 'SUSFS_IS_INODE_SUS_MAP' "$COMMON/fs/proc/task_mmu.c" 2>/dev/null; then
    ok "task_mmu.c 含 SUSFS SUS_MAP 钩子"
  else
    bad "task_mmu.c 缺 SUSFS SUS_MAP 钩子（垫片未应用）"
  fi
  # 只补 SUS_MAP 三个 hunk 是不够的：补丁对 task_mmu.c 共有 8 个 hunk，
  # 其中 Hunk#1 是 #include <linux/susfs_def.h>（SUSFS_IS_INODE_SUS_MAP 宏的来源），
  # Hunk#2/#3 是 show_map_vma 的 open_redirect / sus_kstat spoof，#7/#8 是 pagemap。
  # 少了 include 会直接编译失败：call to undeclared function 'SUSFS_IS_INODE_SUS_MAP'。
  if grep -q '#include <linux/susfs_def.h>' "$COMMON/fs/proc/task_mmu.c" 2>/dev/null; then
    ok "task_mmu.c 含 #include <linux/susfs_def.h>"
  else
    bad "task_mmu.c 缺 <linux/susfs_def.h> 包含（会导致 SUSFS_IS_INODE_SUS_MAP 未声明）"
  fi
  if grep -q 'susfs_open_redirect_spoof_show_map_vma_srcu' "$COMMON/fs/proc/task_mmu.c" 2>/dev/null; then
    ok "task_mmu.c 含 show_map_vma open_redirect spoof"
  else
    bad "task_mmu.c 缺 show_map_vma open_redirect spoof（Hunk#2/#3 未落地）"
  fi
  if grep -q 'vma->vm_file && SUSFS_IS_INODE_SUS_MAP' "$COMMON/fs/proc/task_mmu.c" 2>/dev/null; then
    ok "task_mmu.c 含 pagemap SUS_MAP 判断"
  else
    bad "task_mmu.c 缺 pagemap SUS_MAP 判断（Hunk#7/#8 未落地）"
  fi
  # fragment 里的 SUSFS 开关
  MISS=0
  for c in CONFIG_KSU_SUSFS CONFIG_KSU_SUSFS_INLINE_HOOK CONFIG_KSU_SUSFS_SUS_PATH CONFIG_KSU_SUSFS_SUS_MOUNT \
           CONFIG_KSU_SUSFS_SUS_KSTAT CONFIG_KSU_SUSFS_SPOOF_UNAME CONFIG_KSU_SUSFS_ENABLE_LOG \
           CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG \
           CONFIG_KSU_SUSFS_OPEN_REDIRECT CONFIG_KSU_SUSFS_SUS_MAP CONFIG_KSU_SUSFS_PRIORITY_UID_FILTER; do
    grep -qE "^${c}=y" "$FRAG" 2>/dev/null || { bad "fragment 缺 ${c}=y"; MISS=$((MISS+1)); }
  done
  [ "$MISS" -eq 0 ] && ok "fragment 含全部 12 项 CONFIG_KSU_SUSFS*=y"
  # 符号定义 vs 引用双向核对
  SYMC="$(dirname "$0")/check_susfs_symbols.py"
  if [ -f "$SYMC" ]; then
    if python3 "$SYMC" "$COMMON" > /tmp/susfs_symbols.log 2>&1; then
      ok "SUSFS 符号完整性核对通过"
      grep -E '定义|引用|无定义' /tmp/susfs_symbols.log | sed 's/^/    /'
    else
      bad "SUSFS 符号核对未通过"
      tail -20 /tmp/susfs_symbols.log | sed 's/^/    /'
    fi
  else
    bad "check_susfs_symbols.py 不存在"
  fi
fi

# ---------- 8) 6.12 LSM API 兼容性 ----------
# security_add_hooks() 第三参数在 6.12 起由 const char * 改为 const struct lsm_id *。
# builtin 分支传字符串 "ksu"，实测编译报 incompatible pointer types passing 'char[4]'。
echo "[8] 6.12 LSM API 兼容性"
LSMC="$(dirname "$0")/check_lsm_api.py"
if [ -f "$LSMC" ]; then
  if python3 "$LSMC" "$DRI/kernelsu" > /tmp/lsm_api.log 2>&1; then
    ok "$(cat /tmp/lsm_api.log)"
  else
    bad "security_add_hooks() 存在 6.12 不兼容的字符串第三参数"
    sed 's/^/    /' /tmp/lsm_api.log
  fi
else
  bad "check_lsm_api.py 不存在"
fi

echo "==== 门禁A 结果 ===="
if [ "$FAIL" -ne 0 ]; then
  echo "::error::门禁A 未通过，终止构建（避免产出一个看似成功但无 root 的包）"
  exit 1
fi
echo "✓ 门禁A 全部通过"