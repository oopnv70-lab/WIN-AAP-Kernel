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
KBLD="$DRI/kernelsu/Kbuild"
if [ -f "$KBLD" ]; then
  PN=$(grep -E 'KSU_PACKAGE_NAME[[:space:]]*\?=' "$KBLD" 2>/dev/null | head -1 | sed 's/.*=[[:space:]]*//')
  if [ -n "$PN" ]; then
    echo "    Kbuild 中默认包名 = $PN"
    case "$PN" in
      com.sukisu.nova*) ok "包名为 $PN（nova 系列）" ;;
      *) bad "包名异常: $PN（期望 com.sukisu.nova）" ;;
    esac
  else
    echo "    ::warning::Kbuild 未找到 KSU_PACKAGE_NAME ?= 行（可能定义在别处，非致命）"
  fi
else
  bad "drivers/kernelsu/Kbuild 不存在"
fi

echo "==== 门禁A 结果 ===="
if [ "$FAIL" -ne 0 ]; then
  echo "::error::门禁A 未通过，终止构建（避免产出一个看似成功但无 root 的包）"
  exit 1
fi
echo "✓ 门禁A 全部通过"