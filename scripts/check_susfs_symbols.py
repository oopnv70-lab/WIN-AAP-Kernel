#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
SUSFS 符号完整性核对 v2

修正 v1 的缺陷：
  1) 支持 __attribute__((hot)) 等前缀
  2) 支持 static struct cred *func(...)  返回指针
  3) 清除 // 注释后再匹配（避免注释里的 //void susfs_exit 被当成引用）
  4) 定义集覆盖全树（fs/namespace.c、security/selinux/*.c 里补丁新增的 static 函数也算）
"""
import re, os, glob, sys

KEYWORDS = ('if', 'while', 'for', 'switch', 'return', 'sizeof', 'else', 'do')

def strip_comments(s):
    s = re.sub(r'/\*.*?\*/', '', s, flags=re.S)
    # 逐行去 // 注释（避免吃掉 URL 里的 //，但内核代码里基本没有）
    out = []
    for line in s.split('\n'):
        idx = line.find('//')
        if idx >= 0:
            line = line[:idx]
        out.append(line)
    return '\n'.join(out)

# 类型前缀可选：__attribute__((...)) 、static 、const 等
TYPE_RE = r'(?:__attribute__\s*\(\(.*?\)\)\s*)?(?:static\s+)?(?:inline\s+)?(?:const\s+)?[A-Za-z_][\w\s\*]*?'

def func_defs(text):
    t = strip_comments(text).split('\n')
    out = []
    for i, l in enumerate(t):
        # 行首不能是空白（顶层定义）
        if not l or l[0] in ' \t#/}':
            continue
        m = re.match(r'^(' + TYPE_RE + r')\s*\*?\s*([a-zA-Z_]\w*)\s*\(', l)
        if not m:
            continue
        full, name = m.group(1), m.group(2)
        # 排除控制流
        words = full.replace('*', ' ').split()
        if any(w in KEYWORDS for w in words):
            continue
        if '{' in l:
            out.append((name, 'static' in words or full.strip().startswith('static')))
            continue
        for j in range(i + 1, min(i + 12, len(t))):
            if ';' in t[j]:
                break
            if '{' in t[j]:
                out.append((name, 'static' in words or full.strip().startswith('static')))
                break
    return out

def main():
    root_dir = os.sys.argv[1] if len(os.sys.argv) > 1 else '.'

    defs = {}
    for root, _, files in os.walk(root_dir):
        for f in sorted(files):
            if not f.endswith(('.c', '.h')) or f.endswith(('.orig', '.rej')):
                continue
            p = os.path.join(root, f)
            try:
                txt = open(p, encoding='utf-8', errors='ignore').read()
            except Exception:
                continue
            for name, is_static in func_defs(txt):
                if name.startswith('susfs_'):
                    defs[name] = (p, is_static)

    inl = set()
    # 从「被检查的内核树」里读 SUSFS 头文件，不能写死本地路径
    #（旧版硬编码 /tmp/sus612/...，CI 上该路径不存在，导致这项恒为 0）
    for h in (os.path.join(root_dir, 'include/linux/susfs.h'),
              os.path.join(root_dir, 'include/linux/susfs_def.h')):
        if not os.path.exists(h):
            continue
        txt = strip_comments(open(h, encoding='utf-8').read())
        for m in re.finditer(r'static\s+inline\s+[\w\s\*]+?\s+([a-zA-Z_]\w*)\s*\(', txt):
            inl.add(m.group(1))
        # 宏形式
        for m in re.finditer(r'#define\s+([a-zA-Z_]\w*)\s*\(', txt):
            if m.group(1).startswith('susfs_'):
                inl.add(m.group(1))

    refs = set()
    for root, _, files in os.walk(root_dir):
        for f in files:
            if not f.endswith(('.c', '.h')) or f.endswith('.orig'):
                continue
            txt = strip_comments(open(os.path.join(root, f), encoding='utf-8', errors='ignore').read())
            for m in re.finditer(r'\b(susfs_[a-zA-Z0-9_]+)\s*\(', txt):
                refs.add(m.group(1))

    ns = sum(1 for v in defs.values() if not v[1])
    st = sum(1 for v in defs.values() if v[1])
    print('全树 susfs_ 函数定义: %d  (非static=%d / static=%d)' % (len(defs), ns, st))
    print('头文件 static inline / 宏: %d' % len(inl))
    print('全树引用: %d' % len(refs))
    print()
    miss = sorted(refs - set(defs) - inl)
    print('=== 引用但无定义: %d ===' % len(miss))
    for x in miss:
        print('  !! ' + x)
    print()
    unused = sorted(set(defs) - refs)
    print('=== 定义但未被引用: %d ===' % len(unused))
    for x in unused:
        print('   - %s  (%s)' % (x, defs[x][0]))

    # 退出码：有任何「引用但无定义」即失败（编译期会 undefined reference）
    if miss:
        print('::error::SUSFS 符号核对失败：%d 个符号被引用但无定义' % len(miss))
        return 1
    return 0

if __name__ == '__main__':
    sys.exit(main())