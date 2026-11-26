#!/usr/bin/env bash
# 集成 Baseband-guard（防格机 LSM）到荣耀 GKI 内核树（android16-6.12 / kleaf）。
# 用法：integrate_bbg.sh <KERNEL_PLATFORM> [BBG_REF]
#   KERNEL_PLATFORM —— 含 common/ 的内核工程根（即 kp/）
#   BBG_REF        —— Baseband-guard 的 commit，默认锁定
#
# Baseband-guard 是什么（vc-teahouse/Baseband-guard，GPL-2.0，302★）：
#   一个内核 LSM 模块，用「默认拒绝」策略防格机——只允许写 allowlist_names
#   白名单里的分区（boot/init_boot/vendor_boot/userdata/vbmeta/recovery 等），
#   不在白名单的分区（modem/fsg/modemst/dsp 等基带分区）一律拒绝写；
#   拦截 file_permission 写、file_ioctl 的 BLKDISCARD/BLKZEROOUT 等破坏性 ioctl。
#   只对 root 进程（su/ksu/magisk SELinux domain）生效。
#
# 关键决策（保证「能刷内核」）：
#   - 不设 CONFIG_BBG_BLOCK_BOOT / CONFIG_BBG_BLOCK_RECOVERY（默认 n），
#     使 boot/recovery 留在白名单，AnyKernel3 刷 boot 不被拦。
#   - CONFIG_LSM 必须含 baseband_guard，否则 BBG 的 Makefile 会 $(error)。
#   - 6.12 上 BBG 走 DEFINE_LSM 注册（新 LSM API），与 SUSFS/SELinux 叠加不冲突。
set -euo pipefail

ROOT="${1:-}"
BBG_REF="${2:-48d9fdea643bcb41d204541400e9d8656b97a54f}"
if [ -z "$ROOT" ]; then
  echo "::error::用法: $0 <KERNEL_PLATFORM> [BBG_REF]" >&2
  exit 1
fi

COMMON="${ROOT}/common"
SECURITY_DIR="${COMMON}/security"
BBG_DIR="${COMMON}/Baseband-guard"
SYMLINK="${SECURITY_DIR}/baseband-guard"
SEC_MAKEFILE="${SECURITY_DIR}/Makefile"
SEC_KCONFIG="${SECURITY_DIR}/Kconfig"
BUILD_BAZEL="${COMMON}/BUILD.bazel"
FRAGMENT="${COMMON}/arch/arm64/configs/bbg.fragment"
BBG_REPO="https://github.com/vc-teahouse/Baseband-guard.git"

echo "==> KERNEL_PLATFORM = $ROOT"
echo "==> Baseband-guard ref = $BBG_REF"
test -d "$COMMON" || { echo "::error::找不到 common/ ($COMMON)"; exit 1; }
test -d "$SECURITY_DIR" || { echo "::error::找不到 security/ ($SECURITY_DIR)"; exit 1; }
test -f "$BUILD_BAZEL" || { echo "::error::找不到 common/BUILD.bazel ($BUILD_BAZEL)"; exit 1; }

# ============ 1) clone Baseband-guard（锁 commit）============
if [ ! -d "$BBG_DIR/.git" ]; then
  echo "==> clone Baseband-guard ($BBG_REF)"
  if git clone --depth 1 -b "$BBG_REF" "$BBG_REPO" "$BBG_DIR" 2>/dev/null; then
    :
  else
    echo "==> -b $BBG_REF 失败，改为浅克隆 + 按 sha 切换"
    rm -rf "$BBG_DIR"
    git clone --depth 1 "$BBG_REPO" "$BBG_DIR"
    git -C "$BBG_DIR" fetch --depth 1 origin "$BBG_REF"
    git -C "$BBG_DIR" checkout "$BBG_REF"
  fi
else
  echo "==> Baseband-guard 已存在，跳过 clone"
fi
test -f "$BBG_DIR/LICENSE" || { echo "::error::Baseband-guard/LICENSE 不存在"; exit 1; }
echo "    版本: $(cd "$BBG_DIR" && git log -1 --format='%h %s' 2>/dev/null)"

# ============ 2) 许可证核验（GPL-2.0）============
if head -3 "$BBG_DIR/LICENSE" | grep -q "GNU GENERAL PUBLIC LICENSE" \
   && grep -q "Version 2" "$BBG_DIR/LICENSE"; then
  echo "  ✓ Baseband-guard LICENSE = GPL-2.0"
else
  echo "::error::Baseband-guard LICENSE 不是 GPL-2.0，中止"; exit 1
fi

# ============ 3) 软链 security/baseband-guard -> ../Baseband-guard ============
ln -sfn ../Baseband-guard "$SYMLINK"
echo "==> 软链: $SYMLINK -> $(readlink "$SYMLINK")"

# ============ 4) security/Makefile 注入 ============
if grep -q 'baseband-guard/' "$SEC_MAKEFILE"; then
  echo "==> security/Makefile 已有 baseband-guard 条目，跳过"
else
  printf '\nobj-$(CONFIG_BBG) += baseband-guard/\n' >> "$SEC_MAKEFILE"
  echo "==> security/Makefile 已追加 obj-\$(CONFIG_BBG) += baseband-guard/"
fi

# ============ 5) security/Kconfig 注入（最后一个 endmenu 前）============
if grep -q 'security/baseband-guard/Kconfig' "$SEC_KCONFIG"; then
  echo "==> security/Kconfig 已有 baseband-guard source，跳过"
else
  awk '
    { a[NR]=$0 }
    END {
      last=0; for(i=1;i<=NR;i++) if(a[i] ~ /^endmenu[[:space:]]*$/) last=i;
      for(i=1;i<=NR;i++){
        if(i==last) print "source \"security/baseband-guard/Kconfig\"";
        print a[i];
      }
    }' "$SEC_KCONFIG" > "$SEC_KCONFIG.tmp" && mv "$SEC_KCONFIG.tmp" "$SEC_KCONFIG"
  echo "==> security/Kconfig 已插入 source \"security/baseband-guard/Kconfig\""
fi

# ============ 6) CONFIG_LSM 注入 baseband_guard ============
# 把 security/Kconfig 里 config LSM 块的 default 值中的 selinux 改为 selinux,baseband_guard
# （BBG 的 Makefile 会在 CONFIG_BBG=y 但 CONFIG_LSM 无 baseband_guard 时 $(error)）
sed -i '/^config LSM$/,/^help$/{ /^[[:space:]]*default/ { /baseband_guard/! s/selinux/selinux,baseband_guard/ } }' "$SEC_KCONFIG"
grep -q 'selinux,baseband_guard' "$SEC_KCONFIG" \
  && echo "==> CONFIG_LSM default 已含 baseband_guard" \
  || { echo "::error::CONFIG_LSM 注入 baseband_guard 失败"; exit 1; }

# ============ 7) 生成 bbg.fragment ============
cat > "$FRAGMENT" <<'EOF'
# Baseband-guard defconfig fragment —— 通过 common_kernel 的
# post_defconfig_fragments 注入，不直接改 gki_defconfig（Kleaf minimized 校验要求本体干净）。
CONFIG_BBG=y
# 注意：不设 CONFIG_BBG_BLOCK_BOOT / CONFIG_BBG_BLOCK_RECOVERY（默认 n），
# 以保持 boot/recovery 在白名单、AnyKernel3 刷 boot 不被拦截。
EOF
echo "==> 已生成 fragment: $FRAGMENT"

# ============ 8) BUILD.bazel 追加 bbg.fragment 到 post_defconfig_fragments ============
if grep -q 'arch/arm64/configs/bbg.fragment' "$BUILD_BAZEL"; then
  echo "==> BUILD.bazel 已含 bbg.fragment，跳过"
else
  python3 - "$BUILD_BAZEL" <<'PY'
import sys, re
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
pattern = re.compile(r'(\n(\s*)post_defconfig_fragments\s*=\s*\[)([^\]]*)(\])')
m = pattern.search(s)
if not m:
    print('::error::未找到 post_defconfig_fragments 行', file=sys.stderr)
    sys.exit(1)
indent = m.group(2)
inner = m.group(3).rstrip()
if 'bbg.fragment' in inner:
    print('已含 bbg.fragment，跳过')
    sys.exit(0)
inner_clean = inner.rstrip().rstrip(',')
if inner_clean.strip():
    new_inner = inner_clean + ', "' + 'arch/arm64/configs/bbg.fragment' + '"'
else:
    new_inner = '"' + 'arch/arm64/configs/bbg.fragment' + '"'
newline = '\n' + indent + 'post_defconfig_fragments = [' + new_inner + ']'
s = s[:m.start()] + newline + s[m.end():]
open(p, 'w', encoding='utf-8').write(s)
print('已追加 bbg.fragment 到 post_defconfig_fragments')
PY
  echo "==> BUILD.bazel 已追加 bbg.fragment"
fi

# ============ 9) 自检 ============
echo "==> 自检"
[ -L "$SYMLINK" ] && echo "  ✓ 软链 security/baseband-guard 存在" || { echo "  ✗ 软链缺失"; exit 1; }
test -f "$BBG_DIR/baseband_guard.c" && echo "  ✓ baseband_guard.c 存在" || { echo "  ✗ baseband_guard.c 缺失"; exit 1; }
grep -q 'baseband-guard/' "$SEC_MAKEFILE" && echo "  ✓ security/Makefile 有 baseband-guard 条目" || { echo "  ✗ Makefile 缺条目"; exit 1; }
grep -q 'security/baseband-guard/Kconfig' "$SEC_KCONFIG" && echo "  ✓ security/Kconfig 有 source" || { echo "  ✗ Kconfig 缺 source"; exit 1; }
grep -q 'selinux,baseband_guard' "$SEC_KCONFIG" && echo "  ✓ CONFIG_LSM 含 baseband_guard" || { echo "  ✗ CONFIG_LSM 缺 baseband_guard"; exit 1; }
test -f "$FRAGMENT" && echo "  ✓ bbg.fragment 存在" || { echo "  ✗ bbg.fragment 缺失"; exit 1; }
grep -q 'bbg.fragment' "$BUILD_BAZEL" && echo "  ✓ BUILD.bazel 已引用 bbg.fragment" || { echo "  ✗ BUILD.bazel 缺 bbg.fragment 引用"; exit 1; }
grep -q '^CONFIG_BBG' "${COMMON}/arch/arm64/configs/gki_defconfig" && { echo "  ✗ gki_defconfig 被污染（含 CONFIG_BBG），不允许"; exit 1; } || echo "  ✓ gki_defconfig 本体干净（无 CONFIG_BBG）"
echo "==> Baseband-guard 集成完成（$BBG_REF，防格机 LSM）"
