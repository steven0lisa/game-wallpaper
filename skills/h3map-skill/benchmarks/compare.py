#!/usr/bin/env python3
"""Compare a candidate renderer output against a golden benchmark image.

Usage:
    python3 compare.py <candidate.png> <golden.png> [--out diff.png] [--threshold 8.0]

Output:
    diff pixel percentage, PASS/WARN/FAIL verdict, and (with --out) a
    red-scale heat map of where the two renders diverge.

How to read the verdict:
    - Random objects (monsters, treasure variants, animated creatures) are
      materialized randomly per run, so a few percent of scattered diff is
      EXPECTED even for a correct renderer. This tool therefore warns
      rather than fails up to --threshold.
    - What must NOT appear: diff forming continuous bands along roads,
      coastlines or tile seams. Those are implementation bugs (half-tile
      offset, flip axis, crop math) regardless of the overall percentage.
      Check the heat map: isolated blobs = random objects (ok); ribbons
      along roads/shores = broken (see SKILL.md §5/§9).

Reference engine for the goldens: this repo's macOS CLI
(GameWallpaper --snapshot). Animation phase is pinned via time-ms in
manifest.json — render the same time or the palette-animated water/lava
will differ everywhere.
"""
import sys
from PIL import Image


def main():
    args = sys.argv[1:]
    if len(args) < 2:
        print(__doc__)
        sys.exit(2)
    cand_path, golden_path = args[0], args[1]
    out_path, threshold = None, 8.0
    for i in range(2, len(args), 2):
        if args[i] == '--out':
            out_path = args[i + 1]
        elif args[i] == '--threshold':
            threshold = float(args[i + 1])

    a = Image.open(cand_path).convert('RGB')
    b = Image.open(golden_path).convert('RGB')
    if a.size != b.size:
        print(f'FAIL size mismatch: candidate {a.size} vs golden {b.size}')
        sys.exit(1)

    pa, pb = a.load(), b.load()
    w, h = a.size
    heat = Image.new('L', (w, h), 0)
    ph = heat.load()
    diff = 0
    for y in range(h):
        for x in range(w):
            ra, ga, ba = pa[x, y]
            rb, gb, bb = pb[x, y]
            d = abs(ra - rb) + abs(ga - gb) + abs(ba - bb)
            if d > 90:  # ~30/channel — beyond palette-rotation noise
                diff += 1
                ph[x, y] = min(255, d // 3)
    pct = 100.0 * diff / (w * h)

    verdict = 'PASS' if pct < threshold * 0.4 else ('WARN' if pct < threshold else 'FAIL')
    print(f'{verdict}  diff={pct:.2f}%  ({diff} of {w*h} px, threshold {threshold}%)')
    if verdict != 'PASS':
        print('check heat map: isolated blobs = random objects (ok);')
        print('ribbons along roads/coasts = implementation bug (SKILL.md §5/§9)')
    if out_path:
        heat.save(out_path)
        print(f'heat map: {out_path}')
    sys.exit(0 if verdict != 'FAIL' else 1)


if __name__ == '__main__':
    main()
