#!/usr/bin/env python3
"""挑选用于打包内置的地图：优先大地图（XL > L > M > S），相近名去重。

用法: pick_maps.py <out_dir> [count=20] <maps_dir> [more_maps_dir...]

规则：
  * 解析 h3m 头读取地图尺寸（XL=144 / L=108 / M=72 / S=36）；
  * 按【尺寸 → 文件字节】排序，先选完所有大尺寸组，再选下一组；
  * 与已选地图"标准化名字"相似度 >= 0.72 的跳过（很多地图只是改了逻辑换个名字），
    只保留最大那张。
"""
import os
import re
import shutil
import sys
import gzip
import struct
from difflib import SequenceMatcher


def h3m_size_and_path(p):
    """读取 h3m 头的 size 字段（地图边长格子数），失败返回 0。"""
    try:
        with open(p, "rb") as fp:
            raw = fp.read()
        if raw[:2] == b"\x1f\x8b":
            raw = gzip.decompress(raw)
        # h3m header: i32 version, i8 hasPlayers, i32 size(grid 边长), ...
        sz = struct.unpack_from("<i", raw, 5)[0]
        return int(sz)
    except Exception:
        return 0


def main() -> int:
    out_dir = sys.argv[1]
    count = int(sys.argv[2]) if len(sys.argv) > 2 else 20
    maps_dirs = sys.argv[3:]

    items = []  # (h3m_size, file_bytes, path, name, group)
    for md in maps_dirs:
        if not os.path.isdir(md):
            continue
        for f in os.listdir(md):
            if not f.lower().endswith(".h3m"):
                continue
            p = os.path.join(md, f)
            if not os.path.isfile(p):
                continue
            sz = h3m_size_and_path(p)
            if sz == 0:
                continue
            fs = os.path.getsize(p)
            if sz >= 144: group = 0   # XL
            elif sz >= 108: group = 1 # L
            elif sz >= 72: group = 2  # M
            elif sz >= 36: group = 3  # S
            else: group = 4
            items.append((sz, fs, p, f, group))

    # 优先 h3m 尺寸大（XL 排最前），同尺寸下再按文件字节
    items.sort(key=lambda x: (-x[0], -x[1]))

    # 用户要求：内置地图只保留 XL(144) 和 L(108)，踢出 M(72)/S(36)/XS
    items = [it for it in items if it[0] >= 108]

    seen_norm = set()
    selected = []
    for sz, fs, p, f, group in items:
        norm = re.sub(r"[^a-z0-9]", "", f.lower())
        if any(SequenceMatcher(None, norm, s).ratio() >= 0.72 for s in seen_norm):
            continue
        if len(selected) >= count:
            break
        selected.append((p, f, sz, fs, group))
        seen_norm.add(norm)

    os.makedirs(out_dir, exist_ok=True)
    total = 0
    by_group = {0: 0, 1: 0, 2: 0, 3: 0, 4: 0}
    group_names = {0: "XL", 1: "L ", 2: "M ", 3: "S ", 4: "XS"}
    for p, f, sz, fs, g in selected:
        for md in maps_dirs:
            src = os.path.join(md, f)
            if os.path.isfile(src):
                shutil.copy2(src, os.path.join(out_dir, f))
                break
        by_group[g] += 1
        total += fs
        print(f"  {group_names.get(g, '?')}  {f:<48s}  {fs // 1024:>5d} KB  ({sz}x{sz})")
    print(f"selected {len(selected)} maps, {total // 1024 // 1024} MB total -> {out_dir}")
    print("分布: XL={}  L={}  M={}  S={}  XS={}".format(*[by_group[i] for i in range(5)]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
