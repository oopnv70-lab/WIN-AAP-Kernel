#!/usr/bin/env bash
# 合规留痕：盘点荣耀源码树内的开源项目与许可证声明，打印成日志。
# 用途：在「拉取荣耀源码」之后、「覆盖/集成」之前调用，证明「我们清楚源码里有哪些开源组件」。
# 用法：audit_licenses.sh <SRC_ROOT>
#   SRC_ROOT = Code_Opensource 根目录（含 kernel/ external/ vendor/）
set -uo pipefail

SRC="${1:-}"
if [ -z "$SRC" ] || [ ! -d "$SRC/kernel" ]; then
  echo "::error::用法: $0 <Code_Opensource 根目录（须含 kernel/）>" >&2
  exit 1
fi

echo "================================================================"
echo "== 荣耀源码许可证盘点（合规留痕） =="
echo "== 源码根 : $SRC"
echo "== 时间    : $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "================================================================"

# ---------- [1] 顶层结构 ----------
echo
echo "== [1] 顶层目录结构 =="
ls -1 "$SRC" 2>/dev/null | sed 's/^/    /'

# ---------- [2] 内核树 SPDX 分布 ----------
echo
echo "== [2] kernel/ 树 SPDX-License-Identifier 分布 =="
grep -rhoE 'SPDX-License-Identifier:[[:space:]]*[A-Za-z0-9.+-]+' "$SRC/kernel" 2>/dev/null \
  | sed 's/.*Identifier:[[:space:]]*//' | sort | uniq -c | sort -rn \
  | sed 's/^/    /'

# ---------- [3] 内核模块许可证 + 专有检查 ----------
echo
echo "== [3] kernel/ 树 MODULE_LICENSE 取值分布 =="
grep -rhoE 'MODULE_LICENSE\([[:space:]]*"[^"]*"' "$SRC/kernel" 2>/dev/null \
  | sed 's/.*"//;s/"//' | sort | uniq -c | sort -rn \
  | sed 's/^/    /'

echo
echo "== [3b] 专有(Proprietary)模块声明检查 =="
if grep -rnE 'MODULE_LICENSE[[:space:]]*\([[:space:]]*"[Pp]roprietary' "$SRC" 2>/dev/null | head -20; then
  echo "    ⚠️ 发现 Proprietary 声明（见上，需人工复核）"
else
  echo "    ✓ 未发现 Proprietary 专有模块声明"
fi

# ---------- [4] 源码树自带 LICENSES ----------
echo
echo "== [4] 源码树自带 LICENSES/ 清单（kernel/） =="
if [ -d "$SRC/kernel/LICENSES" ]; then
  find "$SRC/kernel/LICENSES" -type f 2>/dev/null | sed "s#$SRC/kernel/##" | sort | sed 's/^/    /'
else
  echo "    (kernel/ 无 LICENSES 目录)"
fi

# ---------- [5] external/ 第三方项目 ----------
echo
echo "== [5] external/ 第三方项目清单 =="
if [ -d "$SRC/external" ]; then
  for d in "$SRC"/external/*/; do
    [ -d "$d" ] || continue
    n=$(basename "$d")
    lic=""
    [ -f "$d/LICENSE" ] && lic="LICENSE"
    [ -f "$d/COPYING" ] && lic="${lic:+$lic,}COPYING"
    [ -f "$d/NOTICE" ] && lic="${lic:+$lic,}NOTICE"
    printf '    %-28s %s\n' "$n" "${lic:+[$lic]}"
  done
else
  echo "    (无 external/ 目录)"
fi

# ---------- [6] vendor/ ----------
echo
echo "== [6] vendor/ 结构与 SPDX 分布 =="
if [ -d "$SRC/vendor" ]; then
  echo "    顶层："
  ls -1 "$SRC/vendor" 2>/dev/null | sed 's/^/      /'
  echo "    SPDX 分布："
  grep -rhoE 'SPDX-License-Identifier:[[:space:]]*[A-Za-z0-9.+-]+' "$SRC/vendor" 2>/dev/null \
    | sed 's/.*Identifier:[[:space:]]*//' | sort | uniq -c | sort -rn \
    | sed 's/^/      /'
  [ "$(grep -rhoE 'SPDX-License-Identifier:' "$SRC/vendor" 2>/dev/null | wc -l)" -eq 0 ] \
    && echo "      (vendor/ 无 SPDX 标识文件)"
else
  echo "    (无 vendor/ 目录)"
fi

echo
echo "================================================================"
echo "== 许可证盘点完成 =="
echo "================================================================"
