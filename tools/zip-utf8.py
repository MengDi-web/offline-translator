#!/usr/bin/env python3
# zip-utf8.py — 用 Python zipfile 打包目录为 zip：
#  - 非 ASCII 文件名自动设置 UTF-8 标志位 (0x800)，Windows 资源管理器可正确显示中文名
#  - 排除 AppleDouble ._* 与 __MACOSX 垃圾条目
# 用法: python3 tools/zip-utf8.py <源目录> <输出zip> [顶层条目名]
import os, sys, zipfile

src = sys.argv[1]
out = sys.argv[2]
top = sys.argv[3] if len(sys.argv) > 3 else None  # 可选：包一层顶层目录名

os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
if os.path.exists(out):
    os.remove(out)

base = os.path.abspath(src)
count = 0
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as zf:
    def add(path, arcname):
        global count
        if os.path.isdir(path):
            for entry in sorted(os.listdir(path)):
                if entry.startswith("._") or entry == "__MACOSX":
                    continue
                add(os.path.join(path, entry), arcname + "/" + entry if arcname else entry)
        else:
            zf.write(path, arcname)
            count += 1
    if top:
        add(base, top)
    else:
        add(base, "")
print(f"OK: {out} ({count} 个文件)")
