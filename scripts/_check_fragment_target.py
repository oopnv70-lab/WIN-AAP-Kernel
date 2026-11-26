import re
import sys

path = sys.argv[1]
src = open(path, encoding='utf-8', errors='replace').read()

# 逐个提取 common_kernel( ... ) 调用块，按括号配平
blocks = []
i = 0
pat = re.compile(r'common_kernel\s*\(')
while True:
    m = pat.search(src, i)
    if not m:
        break
    start = m.end() - 1  # 指向 '('
    depth = 0
    j = start
    while j < len(src):
        c = src[j]
        if c == '(':
            depth += 1
        elif c == ')':
            depth -= 1
            if depth == 0:
                break
        j += 1
    blocks.append(src[start:j + 1])
    i = j + 1

def field(blk, key):
    m = re.search(key + r'\s*=\s*"([^"]*)"', blk)
    return m.group(1) if m else None

results = []
for blk in blocks:
    nm = field(blk, 'name')
    has_ksu = 'ksu.fragment' in blk
    if nm:
        results.append((nm, has_ksu))

for nm, has in results:
    print("      %s | ksu.fragment=%s" % (nm, "YES" if has else "no"))

hit = [x for x in results if x[0] == 'kernel_aarch64']
if not hit:
    print("::error::门禁A 失败: BUILD.bazel 中找不到 name=\"kernel_aarch64\" 的 common_kernel 块")
    sys.exit(2)
if any(h for _, h in hit):
    print("  OK kernel_aarch64 块已引用 ksu.fragment")
    sys.exit(0)
else:
    print("::error::门禁A 失败: kernel_aarch64 块没有引用 ksu.fragment（CONFIG_KSU=y 不会生效！）")
    sys.exit(1)
