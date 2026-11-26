#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
SUSFS 6.12 补丁 fs/proc/task_mmu.c 垫片 —— 荣耀 AAP-AN00 (6.12.58)

上游补丁 Hunk#4/#5/#6 与荣耀树不兼容：
  Hunk#4: 期望 `if (!vma_data_pages(vma))`，荣耀为 `if (!vma_pages(vma))`，仅函数名不同
  Hunk#5/#6: 上游基于 for_each_vma 宏 + goto out_unlock；荣耀改写为
             `do {...} for_each_vma(...)` 结构，last_vma_end 赋值移到循环开头

荣耀树 show_smaps_rollup 实际结构：
    do {                                    tab=1
        smap_gather_stats(vma, &mss, 0);    tab=2  <- Hunk#5 插在这之前
        last_vma_end = vma->vm_end;         tab=2
        if (mmap_lock_is_contended(mm)) {
            ...
        }                                   tab=2  <- Hunk#6 标签插在这个 } 之前
    } for_each_vma(vmi, vma);               tab=1

用 `continue` 而非 goto 实现跳过：
  SUS_MAP 命中 -> 直接进入下一轮，不统计不输出，与上游 bypass_orig_flow 语义一致。
  因荣耀把 last_vma_end 赋值放在循环开头，continue 前它已被赋值，不存在陈旧值问题。
"""
import sys

def fail(msg):
    print("::error:: " + msg)
    sys.exit(1)

path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/patchtest/task_mmu.c"
lines = open(path, encoding="utf-8").read().split("\n")

def find_unique(needle, start=0, end=None, desc=""):
    end = len(lines) if end is None else end
    hits = [i for i in range(start, end) if needle in lines[i]]
    if len(hits) != 1:
        fail(f"锚点不唯一/未找到: {desc or needle!r} -> {hits}")
    return hits[0]

def tabs(l):
    return len(l) - len(l.lstrip("\t"))

# ================= Hunk #4 =================
sm_start = find_unique("static int show_smap(struct seq_file *m, void *v)")
sm_end   = find_unique("static int show_smaps_rollup(struct", start=sm_start + 1)
mss      = find_unique("struct mem_size_stats mss = {};", start=sm_start, end=sm_end)

guard = None
for i in range(mss + 1, sm_end):
    s = lines[i].strip()
    if s.startswith("if (!vma") and "pages(vma)" in s:
        guard = i
        break
if guard is None:
    fail("show_smap 内未找到 vma pages 判断锚点")

HUNK4 = [
    "#ifdef CONFIG_KSU_SUSFS_SUS_MAP",
    "\tif (vma->vm_file) {",
    "\t\tif (SUSFS_IS_INODE_SUS_MAP(file_inode(vma->vm_file)))",
    "\t\t\treturn 0;",
    "\t}",
    "#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MAP",
    "",
]
lines[guard:guard] = HUNK4
print(f"[Hunk#4] show_smap 早退 -> 插入于第 {guard+1} 行前")

# ================= 定位 show_smaps_rollup 的 do 循环 =================
sr_start = find_unique("static int show_smaps_rollup(struct")
sr_end = None
for i in range(sr_start + 1, len(lines)):
    if lines[i].startswith("#undef SEQ_PUT_DEC"):
        sr_end = i
        break
if sr_end is None:
    fail("未找到 show_smaps_rollup 结束锚点 #undef SEQ_PUT_DEC")

do_line = None
for i in range(sr_start, sr_end):
    if lines[i].strip() == "do {" and tabs(lines[i]) == 1:
        do_line = i
        break
if do_line is None:
    fail("未找到 tab=1 的 `do {` 锚点")

loop_close = None
for i in range(do_line, sr_end):
    if "for_each_vma(vmi, vma);" in lines[i]:
        loop_close = i
        break
if loop_close is None:
    fail("未找到 `for_each_vma(vmi, vma);` 锚点")

# 循环体首条语句（tab=2）
first_stmt = None
for i in range(do_line + 1, loop_close):
    if lines[i].strip() and not lines[i].strip().startswith("/*"):
        if tabs(lines[i]) == 2:
            first_stmt = i
        break
if first_stmt is None:
    fail("未找到 do 循环体首条语句")

# ================= Hunk #5 =================
HUNK5 = [
    "#ifdef CONFIG_KSU_SUSFS_SUS_MAP",
    "\t\tif (vma->vm_file && SUSFS_IS_INODE_SUS_MAP(file_inode(vma->vm_file)))",
    "\t\t\tcontinue;",
    "#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MAP",
]
lines[first_stmt:first_stmt] = HUNK5
print(f"[Hunk#5] SUS_MAP continue -> 插入于第 {first_stmt+1} 行前（循环体首条语句前）")

# ================= Hunk #6 =================
# Hunk#5 插入后行号已偏移：重新定位 do_line / loop_close
do_line2 = None
for i in range(sr_start, len(lines)):
    if lines[i].strip() == "do {" and tabs(lines[i]) == 1:
        do_line2 = i
        break
if do_line2 is None:
    fail("Hunk#6: 未找到 tab=1 的 `do {` 锚点")

loop_close2 = None
for i in range(do_line2, len(lines)):
    if "for_each_vma(vmi, vma);" in lines[i]:
        loop_close2 = i
        break
if loop_close2 is None:
    fail("Hunk#6: 未找到 `for_each_vma(vmi, vma);` 锚点")

# 循环体最后一个 tab=2 的 `}`（即 loop_close2 之前最近的 tab=2 的 }）
insert_at = None
for i in range(loop_close2 - 1, do_line2, -1):
    st = lines[i].strip()
    if st == "}" and tabs(lines[i]) == 2:
        insert_at = i
        break
if insert_at is None:
    fail("未找到 do 循环体内 tab=2 的 `}` 锚点")

# 说明性注释 + 空语句，避免空标签告警；实际跳过由 continue 完成，标签仅用于日后对齐上游
HUNK6 = [
    "\t\t/* SUSFS SUS_MAP: 命中项已在循环开头 continue 跳过，此处无需额外处理 */",
]
lines[insert_at:insert_at] = HUNK6
print(f"[Hunk#6] 说明注释 -> 插入于第 {insert_at+1} 行前（循环体末尾右花括号之前）")

open(path, "w", encoding="utf-8").write("\n".join(lines))
print("✓ 垫片写入完成:", path)