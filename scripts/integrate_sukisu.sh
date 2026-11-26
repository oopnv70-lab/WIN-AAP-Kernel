#!/usr/bin/env bash
# 集成 SukiSU-Nova（main 分支，CONFIG_KSU=y 内置）到荣耀 GKI 内核树（android16-6.12 / kleaf）。
# 用法：integrate_sukisu.sh <KERNEL_PLATFORM> [SUKISU_REF]
#   KERNEL_PLATFORM —— 含 common/ 的内核工程根（即 kp/）
#   SUKISU_REF      —— SukiSU-Nova 分支/tag/commit，默认 main
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
SUKISU_REF="${2:-main}"
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
# SukiSU-Nova (main) defconfig fragment —— 通过 common_kernel 的
# post_defconfig_fragments 注入，不直接改 gki_defconfig（Kleaf minimized 校验要求本体干净）。
CONFIG_KSU=y
EOF
# 若启用 SUSFS，追加其 11 个配置项（Kconfig 中均为 default y，但显式写更稳妥）
if [ "${ENABLE_SUSFS:-false}" = "true" ]; then
  cat >> "$FRAGMENT" <<'EOF'
# ---- SUSFS ----
CONFIG_KSU_SUSFS=y
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
  echo "==> 已在 fragment 中启用 SUSFS 11 项"
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
grep -q '^CONFIG_KPROBES=y' "${COMMON}/arch/arm64/configs/gki_defconfig" && echo "  ✓ CONFIG_KPROBES=y" || echo "  ⚠ 未在 gki_defconfig 找到 CONFIG_KPROBES=y（可能在别的 fragment）"
grep -q '^CONFIG_EXT4_FS=y' "${COMMON}/arch/arm64/configs/gki_defconfig" && echo "  ✓ CONFIG_EXT4_FS=y" || echo "  ⚠ 未在 gki_defconfig 找到 CONFIG_EXT4_FS=y"
echo "==> SukiSU-Nova 集成完成（main 分支，CONFIG_KSU=y 内置，包名=$PKG_NAME）"
