---
name: h3map-skill
description: Portable implementation guide for parsing and rendering Heroes of Might & Magic 3 adventure maps (.lod/.def/.h3m) — the layer semantics, frame math, atlas packing and pixel-level pitfalls any language port must follow, distilled from the verified mac/web/Android triple implementation of this repo.
---

# h3map-skill: HoMM3 Map Parsing & Rendering, Portably

This is the build-order map for reimplementing HoMM3 adventure-map
rendering in any language (Rust/Go/C++/Swift…). It states the
**non-negotiable semantics** we verified pixel-for-pixel across three
independent renderers (macOS Metal, web Canvas, Android GLES2), plus the
pitfalls that cost us the most debugging time. Byte-level layouts live
in [`docs/formats.md`](../../docs/formats.md); draw-order semantics in
[`docs/rendering.md`](../../docs/rendering.md); the full trap log in
[`docs/pitfalls.md`](../../docs/pitfalls.md).

English | [中文](zh-CN/SKILL.md)

---

## 0. The five artifacts

| Artifact | What it is | You need it for |
|---|---|---|
| `H3sprite.lod` | zlib-packed sprite archive | every visual asset |
| `*.def` | indexed-color sprite (frames + palette) | terrain tiles, objects, roads |
| `*.h3m` | gzip-compressed map (version 14/21/28/29 = RoE/AB/SoD/HotA) | terrain layout, object placement |
| scene | your in-memory build: layers of cells → frame ids | decouples parsing from drawing |
| atlas | packed RGBA pages of decoded frames | GPU upload |

Build in this order: **LOD → DEF → h3m → scene → atlas → renderer**.
Each stage is independently testable against the previous one.

## 1. LOD reader

Index table → entries `{ name, uncompressedSize, compressedSize, type }`;
payload is raw or zlib. Nothing tricky. See formats.md §1.

## 2. DEF decoder

Header: `type, fullWidth, fullHeight, groupsCount, palette[768]`.
Per group: `groupType, framesCount, unknown[8], filenames[13×n], offsets[n]`.
Per frame at offset: `size, compression, fullW, fullH, w, h, x, y` then pixels.

Key concepts — a frame is **not** just pixels:

```
frame = data rect (w×h pixels) placed at (x, y) on a logical canvas (fullW×fullH)
```

Road/terrain rendering crops *canvas* regions, so you must keep `x, y,
fullW, fullH` alongside the pixels.

Pitfalls (formats.md §2.3–2.4):

- **Old-format swap**: `compression==1 && w>fullW && h>fullH` means the
  header stored `w,h` swapped with the margins — set `w=fullW, h=fullH,
  x=0, y=0` and re-read the data 16 bytes earlier (VCMI's rule).
- Four pixel encodings: 0 = raw indices, 1 = per-row offset RLE,
  2 = packed RLE, 3 = per-32px-segment RLE. Rows are top-down.
- Index 0 = transparent (color-key mode). Terrain defs are opaque; `*RVR`
  / `*RD` are color-key; everything else carries shadows via special
  palette indices (formats.md §2.5).
- Palette animation: some defs rotate palette ranges (WATRTL, LAVATL,
  CLRRVR, MUDRVR, LAVRVR — formats.md §2.6). The rotation cycle length
  is the LCM of range lengths; each cycle step is a *variant frame*.

## 3. h3m parser

`gzip` first (95% of files are gzipped). Read sequentially; the parser
is a long ordered walk — formats.md §3 is the field-by-field contract.
Only the parts below are load-bearing for rendering.

### 3.1 Terrain tiles

After the header, `size² × levels` tiles (levels = 2 when underground
exists), each 7 bytes:

```
terrain u8, terView u8, river u8, riverDir u8, road u8, roadDir u8, flags u8
```

- `terrain` ∈ 0..9 indexes the terrain def list (DIRTTL…ROCKTL).
- `terView` / `riverDir` / `roadDir` are **frame indices** within the
  corresponding def (0-based).
- `river`/`road` = 0 means none; else 1..3 select the def
  (DIRTRD/GRAVRD/COBBRD for roads).

### 3.2 The flip bits (the #1 trap)

`flags` packs three 2-bit fields:

| bits | layer | meaning |
|---|---|---|
| 0–1 | terrain | bit0 = flip horizontal, bit1 = flip vertical |
| 2–3 | river | same |
| 4–5 | road | same |

**bit0 = horizontal, bit1 = vertical** — we verified this by
art-consistency A/B (swapping axes shatters road junctions and
checkerboards coastlines). Do **not** copy VCMI's
`animation[1]->verticalFlip()` naming: its internal image memory layout
differs, so its index-to-axis mapping does not transfer. h3lwp's
`mirrorConfig.get(4)=flipH` agrees with us.

### 3.3 defs and objects

Def table gives sprite name + `objectId/subId/placementOrder` per entry.
Objects are `x, y, z, defIndex` + a type-dependent payload you can skip
entirely for rendering (formats.md §3.4 has the skip table).

## 4. Scene build

One scene level = 5 layers, painted in this exact order
(rendering.md §1):

```
border (EDG) → terrain → rivers → roads → objects
```

- **border**: outside-the-map tiles get EDG frames by edge/corner index
  (36 frames, formats.md §5).
- **terrain/rivers**: one full-tile frame per cell.
- **roads**: see §5 — half-tile crops.
- **objects**: painter's order. Sort by `placementOrder` DESC (drawn
  first = behind), then `y` ASC, heroes (objectId 34/70/62) drawn last,
  then `x` ASC, then def index (formats.md §4). Object sprites anchor
  bottom-right on the anchor cell: canvas rect
  `((x+1)*32 - fw, (y+1)*32 - fh)`.

Group animation frames into **sets**: a set = one logical sprite's
palette-rotation/animation frames; a cell stores `(setId, flip)` and the
frame is chosen at draw time as `set[(animStep + phase) % set.length]`
(terrain/river) or `set[animStep % set.length]` (objects get a random
stable `phase`). Animation tick = **180 ms**.

## 5. Road rendering (half-tile split) — the second-biggest trap

H3 road sprites are 32×32 canvases whose visible band straddles the tile
border. VCMI's `MapRendererRoad::renderTile` is the reference semantics;
our verified equivalent:

```
for each visible cell (x, y):
    if tile(x, y-1) has road f above:
        crop f's canvas rows [16, 32)  → draw at cell (x,y) rows [ 0, 16)   // top half
    if tile(x, y)   has road f:
        crop f's canvas rows [ 0, 16)  → draw at cell (x,y) rows [16, 32)   // bottom half
```

Equivalently: the whole road frame is drawn **shifted down 16px**, split
across two cells. Two consequences:

1. A cell's visible road = upper half from the *road in the cell above*
   + lower half from *its own* road frame. Borders must match across
   frames — the art is designed for this.
2. The destination half is **16 world px tall**. If your scale factor is
   `k` (screen px per world px), the crop maps to a dest rect of
   `32k × 16k`. We shipped a bug where `ky = 32k/16 = 2k`, stretching
   every road half 2× vertically and overlapping the seam — visually
   "broken road junctions". The half-crop scale is **k, not 2k**.

### 5.1 Mirrored-crop math (flip-correct source rect)

When a frame is flipped, its data rect moves inside the canvas, and the
crop must be mirrored *in canvas space first*, then mirrored *again*
while sampling. The double mirror is what makes flipped turns line up.
Verbatim contract (viewer.js `drawFrameCanvas`):

```
fullW = f.fullW, fullH = f.fullH
dxF = flipH ? fullW - f.x - f.w : f.x
dyF = flipV ? fullH - f.y - f.h : f.y
ix0 = max(canvasX, dxF), iy0 = max(canvasY, dyF)         # intersect crop with data
ix1 = min(canvasX+canvasW, dxF+f.w), iy1 = min(canvasY+canvasH, dyF+f.h)
if empty: skip
lx0 = ix0 - dxF, ly0 = iy0 - dyF                         # offset inside data rect
sx  = f.atlasX + (flipH ? f.w - lx0 - w : lx0)           # source in atlas
sy  = f.atlasY + (flipV ? f.h - ly0 - h : ly0)
dest = (ix0 - canvasX, iy0 - canvasY) scaled by k        # then sample mirrored if flipped
```

## 6. Atlas packing

- Pack decoded frame data rects into 2048² RGBA pages (shelf packer is
  fine). Key frames by `def:block:index:step` and **dedupe globally** —
  127 maps shared only 12k frames / 16 pages in this repo (per-map
  packing would have been ~400 MB).
- **Pad = 1 px edge-replicate** around every frame. With linear
  filtering, a bare frame edge blends against neighbouring frames
  (colour bleed seams); one replicated border row/column fixes it while
  keeping soft edges. Nearest filtering is the safe alternative but
  looks harsher.
- Sample textures with `GL_LINEAR` + the pad (mac parity) or
  `GL_NEAREST`. If your platform stores RGBA4444 (half the VRAM, fine
  for pixel art), pack nibbles **R in the top 4 bits, then G, B, A** —
  the same convention as RGB565's R15-11. Packing A first swaps R/B at
  sample time and renders blue water blood red.
- UV mapping: if your upload puts image row 0 at `v = 0`
  (GLUtils/texImage2D convention), map `v = y / pageSize` directly — do
  **not** apply a GL-style `1 - v` flip.

## 7. Renderer checklist (GLES2 as reference)

Per frame, in order (§4). Full-tile layers draw 32×32 dest quads with
mirror-on-source; roads use §5. Depth is implicit (paint order, no
z-buffer). Camera: keep the view rect inside the map —
`centerX ∈ [viewW/2, world - viewW/2]` (clamp like this and you can
never show the void). Animate at 180 ms steps; glides use smoothstep.

## 8. Verification methodology (do this, it caught everything)

1. **Parse cross-check**: run your parser on a corpus of real maps and
   compare counts/fields against a known-good parser (h3lwp or this
   repo's `H3mFile.js`).
2. **Road-layer pixel diff**: render the roads layer only, two ways
   (your scene vs a trusted reference), full map, demand **0 diff
   pixels**. (Mind the canvas math — a smear-style harness with mixed
   tile/pixel units can fake diffs; use 1 world px = 1 px.)
3. **Art-consistency A/B** for ambiguous semantics (e.g. flip axes):
   render both variants; the wrong one visibly breaks junctions and
   coastlines. The art is self-checking.
4. **Cross-engine comparison**: same camera vs the mac CLI snapshot or
   VCMI itself. Terrain must match; only random objects may differ.
5. **Coast/road zoom audit**: 2× magnify coastlines and junctions before
   shipping screenshots or art.

### 8.1 Golden benchmark suite (`benchmarks/`)

The `benchmarks/` directory ships six golden renders produced by this
repo's macOS CLI, with the exact render parameters in
`benchmarks/manifest.json`. Element coverage:

| case | covers |
|---|---|
| `st_coast_roads` | coastline, ocean, road network, ships, farmland |
| `st_junction_fg_bg` | road diagonals/junctions, fg/bg occlusion (creatures over roads) |
| `bfr_crossroads` | road crossroads (half-tile split), creatures, buildings depth |
| `bfr_snow_coast` | snow terrain, snow coast, town/hero anchoring, roads |
| `bfr_lava_coast` | lava palette animation (timing-sensitive), cliffs, roads |
| `moh_inland` | mixed terrain, coast, town sprite, roads under trees |

Run every case through your renderer with the manifest's
`map / center / zoom / size / time_ms` (keep `time_ms` identical — the
palette-animated water/lava frames depend on it), then compare:

```
python3 benchmarks/compare.py your_render.png benchmarks/golden/<id>.png --out diff.png
```

Verdicts: **PASS** < 3.2% diff, **WARN** < 8% (inspect the heat map),
**FAIL** ≥ 8%. Random object materialization (monster/hero variants)
differs per run — scattered blobs in the heat map are expected even for
a correct renderer. What must never appear is diff forming **continuous
ribbons along roads, coastlines or tile seams**: that is a half-tile
offset, flip-axis or crop-math bug (§5/§9) no matter how small the
overall percentage.

**Data sources** — what you need depends on what you are testing:

- **Renderer testing** (the main use): `benchmarks/data/bench-scenes.zip`
  is a pre-baked scene bundle (scenes.bin v2 + atlas pages) for the three
  benchmark maps. Read it (layout is in the bake.js header and §6) and
  render from it directly — **no copyrighted game files required**. The
  goldens were produced from this exact data, so a correct renderer
  reproduces them modulo random objects.
- **Parser testing**: you need real game data you provide yourself —
  `H3sprite.lod` from an owned HoMM3 installation and the three map
  files from its Maps folder. Copyrighted assets are never distributed
  with this repo. Any of your own maps work too if you compare against
  h3lwp or VCMI output instead of these goldens.

## 9. Top-10 pitfall speed run

1. Flip bits: bit0 = H, bit1 = V (per 2-bit field in `flags`).
2. Road own-half dest offset: bottom half, `+16` world px.
3. Road half-crop scale = k (not 2k) — see §5.
4. DEF old-format `w/h` swap rule (compression 1 + w > fullW).
5. UV: row 0 → v0, no flip.
6. RGBA4444 nibbles: R first, A last.
7. Atlas pad=1 with linear filtering (else bleed seams).
8. Mirrored crop = mirror in canvas space, then mirror sampling.
9. h3m is gzip-wrapped; version int (14/21/28/29) gates field widths.
10. Object painter order with heroes drawn last.

---

*Source of truth: this repo's `web/server/engines/heroes3/*` (parsers),
`android/bake/*` (atlas + offline tests), `Sources/Heroes3Engine/*`
(Metal renderer). When in doubt, the pixel-diff tests decide.*
