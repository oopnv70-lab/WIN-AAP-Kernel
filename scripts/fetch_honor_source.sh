#!/bin/bash
# 拉取荣耀开源发布中心的指定机型开源源码并解压（CI / 本地通用）
# 解决两个问题：
#   1) 下载链接会过期 + 防盗链：每次实时查接口拿"当前有效"签名 URL，再带 Referer 下载。
#   2) 包是**双层嵌套**：外层 AAK-xxx_Opensource.zip 里装的是 Code_Opensource.tar.gz，
#      只 unzip 外层拿不到源码目录 —— 这里逐层递归展开，直到出现 Code_Opensource/。
#
# 用法: fetch_honor_source.sh [MODEL_CODE] [DEST_DIR]
#   默认 MODEL_CODE=AAK-AN00 (荣耀 WIN RT), DEST_DIR=$PWD/honor_src
# 产物: $DEST_DIR/Code_Opensource/{README_*.txt,kernel,external,vendor}
set -euo pipefail

MODEL="${1:-AAK-AN00}"
DEST="${2:-$PWD/honor_src}"
API='https://selfservice-cn.hihonor.com/ccpcmd/services/dispatch/secured/CCPC/EN/tkb/findDocKnow/1000'
REFERER='https://www.honor.com/global/opensource/'
UA='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120 Safari/537.36'

mkdir -p "$DEST"
WORK=$(mktemp -d)

echo "[*] 查询 $MODEL 的当前有效下载地址 ..."
URL=""
FN=""
TOTAL="?"
for p in $(seq 1 10); do
  curl -sG -A "$UA" --max-time 60 "$API" \
    --data-urlencode 'jsonp=cb' --data-urlencode 'siteCode=worldwide' \
    --data-urlencode 'regionCode=GB' --data-urlencode "curPage=$p" \
    --data-urlencode 'pageSize=50' --data-urlencode 'offeringCode=CMCG10000045' \
    --data-urlencode 'channelCode=10005' --data-urlencode 'countryCode=0' \
    --data-urlencode 'country=0' --data-urlencode 'langCode=en-gb' \
    --data-urlencode 'language=en-us' --data-urlencode 'knowledgeTypes=F34' \
    -o "$WORK/p.txt"
  parsed=$(python3 - "$WORK/p.txt" "$MODEL" <<'PY'
import json,re,sys
t=open(sys.argv[1],encoding='utf-8',errors='ignore').read()
code=sys.argv[2]
m=re.search(r'cb\((\{.*\})\)', t, re.S)
if not m:
    print('TOTAL=0'); sys.exit()
o=json.loads(m.group(1)); rd=o.get('responseData',{})
print('TOTAL='+str(rd.get('totalCount','?')))
for it in rd.get('rList',[]):
    if code in it.get('fileName',''):
        print('URL='+it['fileUrl']); print('FN='+it['fileName'])
        print('SIZE='+str(it.get('fileLen','?'))); print('DATE='+str(it.get('releaseDate','?')))
        break
PY
)
  TOTAL=$(echo "$parsed" | sed -n 's/^TOTAL=//p')
  URL=$(echo "$parsed" | sed -n 's/^URL=//p')
  if [ -n "$URL" ]; then
     FN=$(echo "$parsed" | sed -n 's/^FN=//p')
     SZ=$(echo "$parsed" | sed -n 's/^SIZE=//p')
     DT=$(echo "$parsed" | sed -n 's/^DATE=//p')
     echo "[+] 命中第 $p 页: $FN  ${SZ}KB  发布 $DT"
     break
  fi
  np=$(python3 -c "import math;print(math.ceil(int('$TOTAL')/50))" 2>/dev/null || echo 99)
  [ "$p" -ge "${np:-99}" ] && break
done

[ -z "$URL" ] && { echo "[x] 未找到 $MODEL"; exit 2; }

# 取会话 cookie（下载接口防盗链校验）
curl -s -A "$UA" -e "$REFERER" --max-time 30 "$REFERER" -c "$WORK/ck.txt" -o /dev/null || true

ZIP="$DEST/${FN:-$MODEL.zip}"
echo "[*] 下载源码包（多线程 aria2 + 单线程 curl 兜底）-> $ZIP"

# 荣耀下载服务器单连接限速约 2 MB/s，用 aria2 多连接分段并发拉取提速。
# 前提：服务器支持 Range（HTTP 206）。若不支持，aria2 只能拿到部分数据，
# 通过「校验下载字节数 vs 期望大小」来判定，失败则回退单线程 curl。
if command -v aria2c >/dev/null 2>&1; then
  echo "[*] 尝试 aria2c 多线程下载（16 连接 / 16 分段）..."
  T0=$(date +%s)
  # --header 每连接都带 Referer；--auto-file-renaming=false 避免改名；-x/-s 控制并发与分段
  aria2c -x 16 -s 16 \
    --header="Referer: $REFERER" \
    --header="User-Agent: $UA" \
    --auto-file-renaming=false \
    --allow-overwrite=true \
    --continue=true \
    --max-tries=3 --retry-wait=3 \
    --summary-interval=30 \
    "$URL" -d "$DEST" -o "$(basename "$ZIP")" 2>&1 | tail -20
  rc=${PIPESTATUS[0]}
  T1=$(date +%s)
  GOT=$(stat -c %s "$ZIP" 2>/dev/null || echo 0)
  echo "[+] aria2 结束 rc=$rc 耗时=$((T1-T0))s 下载=$GOT B"
  # 期望大小：接口返回的 fileLen 单位是 KB（日志里 562995.2KB ≈ 576,463,534 B）
  EXP=$(python3 -c "print(int(float('$SZ')*1000))" 2>/dev/null || echo 0)
  # 校验：rc=0 且字节数接近期望（允许千分之几误差，fileLen 是 KB 精度）
  if [ "$rc" -eq 0 ] && [ "$GOT" -gt 0 ] && { [ "$EXP" -eq 0 ] || [ "$GOT" -ge $((EXP * 99 / 100)) ]; }; then
    echo "[+] aria2 多线程下载完成，大小 $GOT B，速度约 $((GOT / (T1-T0+1) / 1024)) KB/s"
  else
    echo "[!] aria2 下载不完整或失败（got=$GOT expect≈$EXP），回退单线程 curl"
    rm -f "$ZIP"
    curl -L -A "$UA" -e "$REFERER" -b "$WORK/ck.txt" --max-time 3600 \
         --retry 3 --retry-delay 5 "$URL" -o "$ZIP" \
         -w '[+] curl HTTP=%{http_code} size=%{size_download}B time=%{time_total}s\n'
  fi
else
  echo "[*] 无 aria2c，单线程 curl 下载"
  curl -L -A "$UA" -e "$REFERER" -b "$WORK/ck.txt" --max-time 3600 \
       --retry 3 --retry-delay 5 "$URL" -o "$ZIP" \
       -w '[+] curl HTTP=%{http_code} size=%{size_download}B time=%{time_total}s\n'
fi

# 最终兜底校验：下载产物必须非空且可解压，否则直接失败（不让空包往下走）
test -s "$ZIP" || { echo "[x] 下载产物为空，下载失败"; exit 5; }
echo "[+] 最终下载产物: $(stat -c %s "$ZIP") B"

echo "[*] 解压外层 zip -> $DEST"
unzip -q -o "$ZIP" -d "$DEST"

# ---- 递归展开嵌套压缩包（zip 里套 tar.gz 是这家的常规操作）----
extract_one() { # $1 = archive path
  case "$1" in
    *.tar.gz|*.tgz) tar -xzf "$1" -C "$DEST" ;;
    *.tar)          tar -xf  "$1" -C "$DEST" ;;
    *.zip)          unzip -q -o "$1" -d "$DEST" ;;
    *) return 1 ;;
  esac
}
for round in 1 2 3 4 5; do
  # 找尚未展开的压缩包（排除最初下载的那个 ZIP 本体）
  arch=$(find "$DEST" -type f \
           \( -name '*.tar.gz' -o -name '*.tgz' -o -name '*.tar' -o -name '*.zip' \) \
           ! -path "$ZIP" ! -name '*.__done__' -print -quit)
  [ -z "$arch" ] && break
  echo "[*] 展开嵌套压缩包(第 $round 层): ${arch#$DEST/}"
  extract_one "$arch" || { echo "[!] 展开失败: $arch"; exit 4; }
  # 改后缀标记，避免下一轮重复解同一个包
  mv "$arch" "${arch}.__done__"
done

echo "[*] 校验源码目录 ..."
if [ -d "$DEST/Code_Opensource" ]; then
  SRC="$DEST/Code_Opensource"
else
  # 兜底：递归找一个 Code_Opensource 目录
  SRC=$(find "$DEST" -type d -name 'Code_Opensource' -print -quit 2>/dev/null || true)
fi
if [ -z "${SRC:-}" ] || [ ! -d "${SRC:-/nonexistent}" ]; then
  echo "[x] 解压后未见 Code_Opensource 目录，当前内容："
  ls -la "$DEST"
  exit 3
fi
# 如果是被多套了一层目录，搬正到 $DEST/Code_Opensource
if [ "$SRC" != "$DEST/Code_Opensource" ]; then
  echo "[*] 目录在 ${SRC}，移动到 $DEST/Code_Opensource"
  mv "$SRC" "$DEST/Code_Opensource"
fi

echo "[+] 完成，源码目录: $DEST/Code_Opensource"
ls -la "$DEST/Code_Opensource" | head
rm -rf "$WORK"