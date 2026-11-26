#!/usr/bin/env bash
# 集成 SukiSU-Nova（builtin-new 分支，CONFIG_KSU=y 内置）到荣耀 GKI 内核树（android16-6.12 / kleaf）。
# 用法：integrate_sukisu.sh <KERNEL_PLATFORM> [SUKISU_REF]
#   KERNEL_PLATFORM —— 含 common/ 的内核工程根（即 kp/）
#   SUKISU_REF      —— SukiSU-Nova 分支/tag/commit，默认 builtin-new
#
# 为什么从 builtin 换成 builtin-new（2026-11-26 实测）：
#   builtin 分支的 kernel/hook/lsm_hook.c:192 调用
#     security_add_hooks(ksu_hooks, ARRAY_SIZE(ksu_hooks), "ksu");
#   而 6.12 起该函数第三参数从 const char * 改为 const struct lsm_id *，
#   编译直接报 incompatible pointer types passing 'char[4]'，且 builtin 分支
#   没有任何 Kconfig 开关能绕开（ksu_main.c 直接 #include 了 lsm_hook.c）。
#   builtin-new 全仓 security_add_hooks 出现次数为 0：6.8+ 改用 arm64 bl 指令
#   改写（branch-link hook）挂 LSM，代码里有 4 处显式 6.12 版本分支，
#   INTERNAL.md 声明支持 k3.0 ~ mainline(7.2)，且持续 sync Upstream。
#
# 为什么不能是 main：
#   main（=dev）的 kernel/Kconfig 只有 64 行，只有 KSU/KSU_DEBUG/KSU_MANUAL_SU/KPM/
#   KSU_DISABLE_MANAGER/KSU_DISABLE_POLICY/KSU_X86_PATCH_SYSCALL_DISPATCHER，
#   全树没有任何 susfs 字样 —— 没有 CONFIG_KSU_SUSFS 这个符号，也没有
#   kernel/extension/susfs_extension.c。若在 main 上写 CONFIG_KSU_SUSFS=y，
#   Kconfig 里该符号不存在，kleaf 的配置校验会报
#   「CONFIG_KSU_SUSFS: actual '', expected 'y'」并中止构建（实测已发生一次）。
#   builtin 分支：kernel/Kconfig 137 行、含 KSU_SUSFS 及 10 个子项；
#   builtin-new 分支：Kconfig 259 行、含 KSU_SUSFS 及 11 个子项（另有 INLINE_HOOK）。
#   两者都有 kernel/extension/susfs_extension.c。但 builtin 因 6.12 LSM API 不可用，
#   本项目固定用 builtin-new。
#
# 路线依据（SukiSU-Nova 官方集成文档）：
#   - main 分支：kprobes/kretprobes/tracepoint 运行时注册，不需要改内核源码（不手动 hook）。
#   - CONFIG_KSU 是 tristate，选 y = 内置（GKI 内置模式），选 m = LKM。本项目选 y。
#   - 依赖 CONFIG_KPROBES=y 与 CONFIG_EXT4_FS=y（荣耀 6.12 gki_defconfig 已满足，见自检）。
#
# 与 AAK(android15-6.6) 的关键差异（本脚本针对 6.12 编写，不照抄 6.6）：
#   - 6.12 的 common/BUILD.bazel 用 common_kernel() 宏，且已有
#     post_defconfig_fragments = [":arch/arm64/configs/ogki.fragment"]。
#   - 因此 KSU 的 CONFIG_KSU=y 以「追加一个 fragment 到 post_defconfig_fragments 列表」的方式注入，
#     而不是像 6.6 那样往 kernel_aarch64 字典硬插 defconfig_fragments 字段。
set -euo pipefail

ROOT="${1:-}"
SUKISU_REF="${2:-builtin-new}"
if [ -z "$ROOT" ]; then
  echo "::error::用法: $0 <KERNEL_PLATFORM> [SUKISU_REF]" >&2
  exit 1
fi

COMMON="${ROOT}/common"
DRI="${COMMON}/drivers"
MAKEFILE="${DRI}/Makefile"
KCONFIG="${DRI}/Kconfig"
BUILD_BAZEL="${COMMON}/BUILD.bazel"
FRAGMENT="${COMMON}/arch/arm64/configs/ksu.fragment"

# 管理器身份写死（无实机，不做映射表）
PKG_NAME="com.sukisu.nova"

echo "==> KERNEL_PLATFORM = $ROOT"
echo "==> SukiSU ref = $SUKISU_REF"
echo "==> 管理器包名 = $PKG_NAME"
test -d "$COMMON" || { echo "::error::找不到 common/ ($COMMON)"; exit 1; }
test -d "$DRI" || { echo "::error::找不到 drivers/ ($DRI)"; exit 1; }
test -f "$BUILD_BAZEL" || { echo "::error::找不到 common/BUILD.bazel ($BUILD_BAZEL)"; exit 1; }

# ============ A. 内核源码侧：clone + 软链 + Makefile/Kconfig 注入 ============
# A1) clone SukiSU-Nova（main 分支，GitHub 源）
if [ ! -d "$ROOT/KernelSU/.git" ]; then
  echo "==> clone SukiSU-Nova ($SUKISU_REF)"
  if git clone --depth 1 -b "$SUKISU_REF" https://github.com/SukiSU-Nova/SukiSU-Nova.git "$ROOT/KernelSU" 2>/dev/null; then
    :
  else
    # 不是分支/tag时（如 commit sha），克隆后再切换
    echo "==> -b $SUKISU_REF 失败，改为按 commit 切换"
    rm -rf "$ROOT/KernelSU"
    git clone https://github.com/SukiSU-Nova/SukiSU-Nova.git "$ROOT/KernelSU"
    git -C "$ROOT/KernelSU" checkout "$SUKISU_REF"
  fi
else
  echo "==> KernelSU 已存在，跳过 clone"
fi
test -d "$ROOT/KernelSU/kernel" || { echo "::error::KernelSU/kernel 不存在"; exit 1; }
echo "    内置版本: $(cd "$ROOT/KernelSU" && git log -1 --format='%h %s' 2>/dev/null)"

# A2) 软链 KernelSU/kernel -> drivers/kernelsu
if [ -L "$DRI/kernelsu" ] || [ -e "$DRI/kernelsu" ]; then
  echo "==> drivers/kernelsu 已存在，先移除"
  rm -rf "$DRI/kernelsu"
fi
ln -sf "$(realpath --relative-to="$DRI" "$ROOT/KernelSU/kernel")" "$DRI/kernelsu"
echo "==> 软链: $DRI/kernelsu -> $(readlink -f "$DRI/kernelsu")"

# A2.5) 改写 kernel/Makefile 管理器包名（main 分支的 KSU_PACKAGE_NAME 常量）
KSU_MAKEFILE="$DRI/kernelsu/Makefile"
test -f "$KSU_MAKEFILE" || { echo "::error::找不到 kernelsu/Makefile ($KSU_MAKEFILE)"; exit 1; }
if grep -q '^KSU_PACKAGE_NAME' "$KSU_MAKEFILE"; then
  sed -i "s|^KSU_PACKAGE_NAME := .*|KSU_PACKAGE_NAME := ${PKG_NAME}|" "$KSU_MAKEFILE"
  echo "==> 已写死包名到 kernelsu/Makefile"
  grep -E '^KSU_PACKAGE_NAME' "$KSU_MAKEFILE" || true
else
  echo "==> 注意：kernelsu/Makefile 无 KSU_PACKAGE_NAME 常量，跳过（main 分支可能用别的方式传包名）"
fi

# A3) Makefile 注入
if grep -q "CONFIG_KSU" "$MAKEFILE"; then
  echo "==> Makefile 已有 kernelsu 条目，跳过"
else
  printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> "$MAKEFILE"
  echo "==> Makefile 已追加 obj-\$(CONFIG_KSU) += kernelsu/"
fi

# A4) Kconfig 注入（endmenu 前）
if grep -q 'drivers/kernelsu/Kconfig' "$KCONFIG"; then
  echo "==> Kconfig 已有 kernelsu 条目，跳过"
else
  sed -i '/^endmenu/i\source "drivers/kernelsu/Kconfig"' "$KCONFIG"
  echo "==> Kconfig 已插入 source \"drivers/kernelsu/Kconfig\""
fi

# ============ B. Kleaf 配置侧：生成 fragment + 追加到 post_defconfig_fragments ============
# B1) 生成 ksu.fragment（不改 gki_defconfig 本体）
cat > "$FRAGMENT" <<'EOF'
# SukiSU-Nova defconfig fragment —— 通过 common_kernel 的
# post_defconfig_fragments 注入，不直接改 gki_defconfig（Kleaf minimized 校验要求本体干净）。
CONFIG_KSU=y
# 荣耀 6.12 开了 CONFIG_GENDWARFKSYMS=y（靠 DWARF 生成模块符号表），
# 而 SukiSU-Nova builtin-new 的 Makefile 在 KSU_DEBUG 未开启时会往 ksu.o 加 -g0
# 去掉调试信息，导致 gendwarfksyms 报 "dwarf_get_units failed: no debugging information?"。
# 这里强制开 KSU_DEBUG=y，让 Makefile 跳过 -g0（副作用仅是打开调试日志）。
CONFIG_KSU_DEBUG=y
EOF
# 若启用 SUSFS，追加其 12 个配置项（Kconfig 中均为 default y，但显式写更稳妥）
if [ "${ENABLE_SUSFS:-false}" = "true" ]; then
  cat >> "$FRAGMENT" <<'EOF'
# ---- SUSFS ----
CONFIG_KSU_SUSFS=y
CONFIG_KSU_SUSFS_INLINE_HOOK=y
CONFIG_KSU_SUSFS_SUS_PATH=y
CONFIG_KSU_SUSFS_SUS_MOUNT=y
CONFIG_KSU_SUSFS_SUS_KSTAT=y
CONFIG_KSU_SUSFS_SPOOF_UNAME=y
CONFIG_KSU_SUSFS_ENABLE_LOG=y
CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y
CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y
CONFIG_KSU_SUSFS_OPEN_REDIRECT=y
CONFIG_KSU_SUSFS_SUS_MAP=y
CONFIG_KSU_SUSFS_PRIORITY_UID_FILTER=y
EOF
  echo "==> 已在 fragment 中启用 SUSFS 12 项"
fi
echo "==> 已生成 fragment: $FRAGMENT"
cat "$FRAGMENT"

# B2) 往 common_kernel(name="kernel_aarch64") 的 post_defconfig_fragments 列表追加 ksu.fragment
#     目标形态：post_defconfig_fragments = [":arch/arm64/configs/ogki.fragment"],
#     追加后：  post_defconfig_fragments = [":arch/arm64/configs/ogki.fragment", ":arch/arm64/configs/ksu.fragment"],
if grep -q 'arch/arm64/configs/ksu.fragment' "$BUILD_BAZEL"; then
  echo "==> BUILD.bazel 已含 ksu.fragment，跳过"
else
  python3 - "$BUILD_BAZEL" <<'PY'
import sys, re
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
# 定位 kernel_aarch64 的 common_kernel 块里的 post_defconfig_fragments 行
# 匹配形如：    post_defconfig_fragments = ["...ogki.fragment"],
pattern = re.compile(r'(\n(\s*)post_defconfig_fragments\s*=\s*\[)([^\]]*)(\])')
m = pattern.search(s)
if not m:
    print('::error::未找到 post_defconfig_fragments 行', file=sys.stderr)
    sys.exit(1)
indent = m.group(2)
inner = m.group(3).rstrip()
if 'ksu.fragment' in inner:
    print('已含 ksu.fragment，跳过')
    sys.exit(0)
# 去掉尾随逗号/空白，追加新项
inner_clean = inner.rstrip().rstrip(',')
if inner_clean.strip():
    new_inner = inner_clean + ', "' + 'arch/arm64/configs/ksu.fragment' + '"'
else:
    new_inner = '"' + 'arch/arm64/configs/ksu.fragment' + '"'
newline = '\n' + indent + 'post_defconfig_fragments = [' + new_inner + ']'
s = s[:m.start()] + newline + s[m.end():]
open(p, 'w', encoding='utf-8').write(s)
print('已追加 ksu.fragment 到 post_defconfig_fragments')
PY
  echo "==> BUILD.bazel 已追加 ksu.fragment"
fi

# ============ 自检 ============
echo "==> 自检"
grep -q "kernelsu/" "$MAKEFILE" && echo "  ✓ Makefile 有 kernelsu 条目" || { echo "  ✗ Makefile 缺条目"; exit 1; }
grep -q 'drivers/kernelsu/Kconfig' "$KCONFIG" && echo "  ✓ Kconfig 有 source 条目" || { echo "  ✗ Kconfig 缺条目"; exit 1; }
test -f "$DRI/kernelsu/Kconfig" && echo "  ✓ drivers/kernelsu/Kconfig 存在" || { echo "  ✗ 软链未生效"; exit 1; }
test -f "$DRI/kernelsu/Makefile" && echo "  ✓ drivers/kernelsu/Makefile 存在" || { echo "  ✗ 软链未生效"; exit 1; }
test -f "$FRAGMENT" && echo "  ✓ ksu.fragment 存在" || { echo "  ✗ fragment 缺失"; exit 1; }
grep -q 'ksu.fragment' "$BUILD_BAZEL" && echo "  ✓ BUILD.bazel 已引用 ksu.fragment" || { echo "  ✗ BUILD.bazel 缺 ksu.fragment 引用"; exit 1; }
grep -q '^CONFIG_KSU=' "${COMMON}/arch/arm64/configs/gki_defconfig" && { echo "  ✗ gki_defconfig 被污染（含 CONFIG_KSU），不允许"; exit 1; } || echo "  ✓ gki_defconfig 本体干净（无 CONFIG_KSU）"
# KSU 依赖确认（main 分支要求 KPROBES=y + EXT4_FS=y）
grep -q '^CONFIG_EXT4_FS=y' "${COMMON}/arch/arm64/configs/gki_defconfig" && echo "  ✓ CONFIG_EXT4_FS=y" || echo "  ⚠ 未在 gki_defconfig 找到 CONFIG_EXT4_FS=y（可能在别的 fragment）"
# SUSFS 能力自检：Kconfig 里必须真的存在该符号，否则 kleaf 配置校验必然报
# 「CONFIG_KSU_SUSFS: actual '', expected 'y'」。main 分支就是这种情况，这里提前拦住。
if [ "${ENABLE_SUSFS:-false}" = "true" ]; then
  if grep -q '^config KSU_SUSFS$' "$DRI/kernelsu/Kconfig"; then
    echo "  ✓ 该分支 Kconfig 定义 config KSU_SUSFS"
  else
    echo "  ✗ 该分支 Kconfig 没有 config KSU_SUSFS —— 分支选错（main 分支不支持 SUSFS），终止"
    exit 1
  fi
  if [ -f "$DRI/kernelsu/extension/susfs_extension.c" ]; then
    echo "  ✓ 存在 extension/susfs_extension.c"
  else
    echo "  ✗ 缺 extension/susfs_extension.c —— 该分支无 SUSFS 集成代码，终止"
    exit 1
  fi
  if grep -q '^config KSU_SUSFS_INLINE_HOOK$' "$DRI/kernelsu/Kconfig"; then
    echo "  ✓ 该分支 Kconfig 定义 config KSU_SUSFS_INLINE_HOOK"
  else
    echo "  ✗ 该分支缺 KSU_SUSFS_INLINE_HOOK —— 不是 builtin-new 布局，SUSFS 后端不可用，终止"
    exit 1
  fi
fi

# 6.12 LSM API 硬门禁：security_add_hooks() 的第三参数在 6.12 起由
# const char * 改为 const struct lsm_id *。只拒绝「第三参数是字符串字面量」
# 的旧写法（builtin 分支即此写法，实测报 incompatible pointer types
# passing 'char[4]'），不禁止未来正确的 lsm_id 用法。
if python3 "$(dirname "$0")/check_lsm_api.py" "$DRI/kernelsu"; then
  echo "  ✓ LSM API 检查通过"
else
  echo "::error::该分支在 6.12 上存在 security_add_hooks 字符串参数，必然编译失败"
  exit 1
fi
echo "==> SukiSU-Nova 集成完成（$SUKISU_REF 分支，CONFIG_KSU=y 内置，包名=$PKG_NAME）"
