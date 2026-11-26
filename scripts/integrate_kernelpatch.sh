#!/usr/bin/env bash
# 集成 KernelPatch（KPM 内核补丁模块加载器）到荣耀 GKI 内核产物。
# 用法：integrate_kernelpatch.sh <KERNEL_PLATFORM> <IMAGE_PATH>
#   KERNEL_PLATFORM —— 含 common/ 的内核工程根（SukiSU-Nova 与 SUSFS 已先集成）
#   IMAGE_PATH      —— 已编译出的 Image 绝对路径（Kleaf 产物，未签名裸 Image）
#
# KernelPatch 本质（不是改内核源码重编译，而是对已编译 Image 后处理）：
#   kptools  一个工具干完所有事：解析 Image 拿符号偏移 + 打补丁 + 附加 kpimg。
#   kpimg    独立 freestanding 裸机 ELF，被 kptools 附加到 Image 末尾、替换启动入口。
#
# 编译：
#   kptools -> 纯 C，系统 gcc + zlib，make 一条命令，无需 NDK。
#   kpimg   -> 裸机 gcc aarch64-none-elf（workflow 按需下载，仅 enable_kpm=true 时）。
#
# 集成方式：CI 当场 git clone + 当场编，不本地打包上传二进制。
#   clone 源固定为 SukiSU-Nova 官方 fork（为 SukiSU 提供 KPM 支持，main 已含 6.12 的
#   CFI/BTI/MTE 修复）。

set -euo pipefail
ROOT="${1:?用法: integrate_kernelpatch.sh <KERNEL_PLATFORM> <IMAGE_PATH>}"
IMAGE="${2:?用法: integrate_kernelpatch.sh <KERNEL_PLATFORM> <IMAGE_PATH>}"
KP_REPO="https://github.com/SukiSU-Nova/SukiSU_KernelPatch_patch.git"
KP_BRANCH="1c5b608916357ac86a94cc736e235db1fac4a29d"  # main @ 1c5b6089（含 6.12 CFI/BTI/MTE 修复）
KP_DIR="${ROOT}/KernelPatch"

echo "==> KERNEL_PLATFORM = $ROOT"
echo "==> IMAGE = $IMAGE"
test -f "$IMAGE" || { echo "::error::找不到 Image ($IMAGE)"; exit 1; }

# ============ 1) 当场拉取 KernelPatch（main 分支，GPL-2.0）============
if [ ! -d "$KP_DIR/.git" ]; then
  echo "==> clone KernelPatch ($KP_BRANCH)"
  if git clone --depth 1 -b "$KP_BRANCH" "$KP_REPO" "$KP_DIR" 2>/dev/null; then
    :
  else
    echo "==> -b $KP_BRANCH 失败，改为浅克隆 + 按 sha 切换"
    rm -rf "$KP_DIR"
    git clone --depth 1 "$KP_REPO" "$KP_DIR"
    git -C "$KP_DIR" fetch --depth 1 origin "$KP_BRANCH"
    git -C "$KP_DIR" checkout "$KP_BRANCH"
  fi
else
  echo "==> KernelPatch 已存在，跳过 clone"
fi
test -f "$KP_DIR/LICENSE" || { echo "::error::KernelPatch/LICENSE 不存在"; exit 1; }
echo "    KernelPatch 版本: $(cat "$KP_DIR/version" 2>/dev/null | tr -d '\n')"
echo "    提交: $(cd "$KP_DIR" && git log -1 --format='%h %s' 2>/dev/null)"

# ============ 2) 许可证核验（GPL-2.0）============
if head -3 "$KP_DIR/LICENSE" | grep -q "GNU GENERAL PUBLIC LICENSE" \
   && grep -q "Version 2" "$KP_DIR/LICENSE"; then
  echo "  ✓ KernelPatch LICENSE = GPL-2.0（与内核主体一致）"
else
  echo "::error::KernelPatch LICENSE 不是 GPL-2.0，中止"; exit 1
fi

# ============ 3) 工具链探测 ============
echo "==> 工具链探测"
command -v gcc >/dev/null 2>&1 || { echo "::error::缺 gcc（kptools 编译需要）"; exit 1; }
command -v aarch64-none-elf-gcc >/dev/null 2>&1 || { echo "::error::缺 aarch64-none-elf-gcc（kpimg 编译需要）"; exit 1; }
echo "    gcc                 : OK ($(gcc --version | head -1))"
echo "    aarch64-none-elf-gcc: OK ($(aarch64-none-elf-gcc --version | head -1))"

# ============ 4) 前提核验（Image 侧）============
echo "==> 前提核验（Image 侧）"
if strings -a "$IMAGE" 2>/dev/null | grep -qE 'kallsyms_lookup_name|kallsyms_expand_symbol'; then
  echo "  ✓ Image 含 kallsyms 符号（CONFIG_KALLSYMS 已编入，KernelPatch 硬依赖满足）"
else
  echo "::error::Image 未检出 kallsyms 符号，CONFIG_KALLSYMS 可能未启用，KernelPatch 无法工作"; exit 1
fi
if strings -a "$IMAGE" 2>/dev/null | grep -qE '__arm64_sys_truncate'; then
  echo "  ✓ Image 含 __arm64_sys_truncate（KP hook 目标在位）"
else
  echo "::error::Image 未检出 __arm64_sys_truncate，syscall wrapper 可能缺失，KP 无法 hook"; exit 1
fi

# ============ 5) 编译 kptools（纯 C，系统 gcc）============
echo "==> 编译 kptools"
( cd "$KP_DIR/tools" && make -j"$(nproc)" ) || { echo "::error::kptools 编译失败"; exit 1; }
test -x "$KP_DIR/tools/kptools" || { echo "::error::kptools 未产出"; exit 1; }
echo "  ✓ kptools 编译完成: $KP_DIR/tools/kptools"

# ============ 6) 编译 kpimg（裸机 gcc aarch64-none-elf）============
echo "==> 编译 kpimg"
( cd "$KP_DIR/kernel" && make TARGET_COMPILE=aarch64-none-elf- -j"$(nproc)" ) || { echo "::error::kpimg 编译失败"; exit 1; }
test -f "$KP_DIR/kernel/kpimg" || { echo "::error::kpimg 未产出"; exit 1; }
echo "  ✓ kpimg 编译完成: $KP_DIR/kernel/kpimg"

# ============ 7) 后处理：kptools -p 打补丁 ============
echo "==> KernelPatch 注入（kptools -p）"
KPT="$KP_DIR/tools/kptools"
KPIMG="$KP_DIR/kernel/kpimg"
OUT="$IMAGE.kp"
BEFORE=$(stat -c%s "$IMAGE")
MAGIC=$(head -c 6 "$KPIMG")
SKEY=$(python3 -c "import secrets;print(secrets.token_hex(8))")
echo "  kpimg 魔数: $MAGIC"
echo "  Image 大小(打补丁前): $BEFORE B"
"$KPT" -p -i "$IMAGE" -k "$KPIMG" -o "$OUT" -s "$SKEY" 2>&1 | tee "$IMAGE.kptools.log" \
  || { echo "::error::kptools -p 失败"; tail -40 "$IMAGE.kptools.log"; exit 1; }
test -f "$OUT" || { echo "::error::kptools 未生成 $OUT"; exit 1; }
AFTER=$(stat -c%s "$OUT")
echo "  Image 大小: $BEFORE -> $AFTER (+$((AFTER-BEFORE)) B)"
[ "$AFTER" -gt "$BEFORE" ] || { echo "::error::patch 后 Image 未变大，注入失败"; exit 1; }
grep -a -qF "$MAGIC" "$OUT" \
  || { echo "::error::patched Image 里找不到 kpimg 魔数 $MAGIC，kpimg 没被追加"; exit 1; }

# ============ 8) 门禁：kptools -l 确认 patched=true ============
echo "==> kptools -l 门禁"
"$KPT" -l -i "$OUT" 2>&1 | tee "$IMAGE.kptools-list.log"
grep -q 'patched=true' "$IMAGE.kptools-list.log" \
  || { echo "::error::kptools -l 显示 patched 不为 true，注入未生效"; exit 1; }

# ============ 9) 替换原 Image，供 AnyKernel3 打包 ============
cp "$OUT" "$IMAGE"
rm -f "$OUT" "$IMAGE.kptools.log" "$IMAGE.kptools-list.log"
echo "  ✓ 已用 KP 补丁版 Image 替换原 Image（+$((AFTER-BEFORE)) B）"

{
  echo "### KernelPatch 注入（KPM 加载器）"
  echo "| 项 | 值 |"
  echo "|---|---|"
  echo "| KernelPatch 版本 | \`$(cat "$KP_DIR/version" | tr -d '\n')\` |"
  echo "| kpimg 魔数 | \`$MAGIC\` |"
  echo "| Image 大小 | $BEFORE → $AFTER 字节（+$((AFTER-BEFORE))） |"
  echo "| superkey | 随机生成、不打印 |"
} >> "$GITHUB_STEP_SUMMARY" 2>/dev/null || true
