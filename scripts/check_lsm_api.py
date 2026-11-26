#!/usr/bin/env python3
"""6.12 LSM API 门禁：拒绝 security_add_hooks() 的字符串第三参数。

6.12 起 security_add_hooks() 第三参数由 const char * 改为
const struct lsm_id *。旧写法（如 SukiSU-Nova builtin 分支的
security_add_hooks(ksu_hooks, ARRAY_SIZE(ksu_hooks), "ksu")）会报
incompatible pointer types passing 'char[4]' 并中断编译。

本检查只拒绝「第三参数是字符串字面量」的写法，不禁止未来正确的
struct lsm_id 用法，避免把正确实现误判为错误。

用法：check_lsm_api.py <kernelsu 源码目录>
退出码：0 = 通过，1 = 存在 6.12 不兼容调用。
"""
import os
import re
import sys


def split_top_level_args(inner):
    args, depth, cur = [], 0, ''
    for ch in inner:
        if ch in '([{':
            depth += 1
        elif ch in ')]}':
            depth -= 1
        if ch == ',' and depth == 0:
            args.append(cur)
            cur = ''
        else:
            cur += ch
    args.append(cur)
    return args


def main():
    if len(sys.argv) != 2:
        print('用法: check_lsm_api.py <kernelsu 源码目录>', file=sys.stderr)
        return 2
    root = sys.argv[1]
    if not os.path.isdir(root):
        print('::error::目录不存在: %s' % root, file=sys.stderr)
        return 2

    bad = []
    for dirpath, _, files in os.walk(root):
        for fn in files:
            if not fn.endswith('.c'):
                continue
            path = os.path.join(dirpath, fn)
            txt = open(path, encoding='utf-8', errors='ignore').read()
            for m in re.finditer(r'security_add_hooks\s*\(', txt):
                i = m.end()
                depth = 1
                while i < len(txt) and depth:
                    if txt[i] == '(':
                        depth += 1
                    elif txt[i] == ')':
                        depth -= 1
                    i += 1
                call = txt[m.start():i]
                inner = call[call.index('(') + 1:-1]
                args = split_top_level_args(inner)
                if len(args) >= 3 and re.match(r'^\s*"', args[2]):
                    line = txt[:m.start()].count('\n') + 1
                    bad.append('%s:%d: 第三参数是字符串字面量'
                               % (os.path.relpath(path, root), line))

    if bad:
        print('::error::security_add_hooks() 使用了 6.12 不兼容的字符串第三参数：')
        for b in bad:
            print('    ' + b)
        print('    → 该分支在 6.12 必然编译失败，请改用 builtin-new（6.8+ 走 arm64 bl hook）')
        return 1

    print('security_add_hooks() 无 6.12 不兼容的字符串第三参数')
    return 0


if __name__ == '__main__':
    sys.exit(main())
