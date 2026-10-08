#!/usr/bin/env python3
"""Picks maps to bundle into the app: prefers larger maps (XL > L > M > S), dedupes similar names.

Usage: pick_maps.py <out_dir> [count=20 | size like 80MB] <maps_dir> [more_maps_dir...]

Rules:
  * Reads the h3m header for the map size (XL=144 / L=108 / M=72 / S=36);
  * Sorts by [size -> file bytes]; picks whole size groups, largest first;
  * Skips maps whose normalized name is >= 0.72 similar to an already-picked one
    (many maps are the same layout with tweaks), keeping only the largest.
"""
import os
import re
import shutil
import sys
import gzip
import struct
from difflib import SequenceMatcher


def h3m_size_and_path(p):
    """Reads the map size (grid edge, in tiles) from the h3m header; 0 on failure."""
    try:
        with open(p, "rb") as fp:
            raw = fp.read()
        if raw[:2] == b"\x1f\x8b":
            raw = gzip.decompress(raw)
        # h3m header: i32 version, i8 hasPlayers, i32 size (grid edge), ...
        sz = struct.unpack_from("<i", raw, 5)[0]
        return int(sz)
    except Exception:
        return 0


def main() -> int:
    out_dir = sys.argv[1]
    arg2 = sys.argv[2] if len(sys.argv) > 2 else "20"
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

    # Prefer larger h3m sizes (XL first), then by file bytes within a size
    items.sort(key=lambda x: (-x[0], -x[1]))

    # Bundled maps keep only XL(144) and L(108); drop M(72)/S(36)/XS
    items = [it for it in items if it[0] >= 108]

    # Budget: a bare number = map count; with a unit (e.g. 80MB) = total file bytes
    limit_bytes = None
    m = re.fullmatch(r"(\d+)([KMG]?)B?", arg2.upper())
    if m and m.group(2):
        mult = {"K": 1024, "M": 1024**2, "G": 1024**3}[m.group(2)]
        limit_bytes = int(m.group(1)) * mult
        count = 10**9
    else:
        count = int(arg2)

    seen_norm = set()
    selected = []
    total = 0
    for sz, fs, p, f, group in items:
        norm = re.sub(r"[^a-z0-9]", "", f.lower())
        if any(SequenceMatcher(None, norm, s).ratio() >= 0.72 for s in seen_norm):
            continue
        if len(selected) >= count:
            break
        if limit_bytes is not None and total + fs > limit_bytes:
            continue
        selected.append((p, f, sz, fs, group))
        seen_norm.add(norm)
        total += fs

    os.makedirs(out_dir, exist_ok=True)
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
    print("distribution: XL={}  L={}  M={}  S={}  XS={}".format(*[by_group[i] for i in range(5)]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
