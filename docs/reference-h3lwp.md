English | [中文](zh-CN/reference-h3lwp.md)

# Reference Implementation Study: h3lwp (Heroes 3 Live Wallpaper for Android)

`base.apk` (9.9MB, versionName 3.0.7) is a build artifact of the open-source project
[IlyaPomaskin/h3lwp](https://github.com/IlyaPomaskin/h3lwp) (`com.homm3.livewallpaper`).
This project's h3m parser and layer behavior were ported from it as the baseline, then
corrected against VCMI semantics. This document records the architecture and key
implementation details recovered through reverse engineering (jadx decompilation).

---

## 1. Application Architecture

```
com.homm3.livewallpaper/
├── android/   LiveWallpaperService (Android WallpaperService engine), MainActivity (settings UI)
├── core/      libGDX engine layer (cross-platform, runs directly on desktop)
│   ├── Engine.kt             screen/asset lifecycle, map list management
│   ├── GameScreen.kt         OrthogonalTiledMapRenderer + timed map switching (10min/2h/24h)
│   ├── Camera.kt             random viewport + parallax scrolling (offset*96px on desktop)
│   ├── Assets.kt             AssetManager wrapper: atlas loading, map sorting (ascending by file size)
│   ├── ObjectsRandomizer.kt  random object materialization (see formats.md §4)
│   ├── Sprite.kt             per-object animation (0.18s/frame, random initial phase)
│   └── layers/               TerrainGroupLayer (three TiledMapTileLayers: terrain/river/road)
│                            ├ ObjectsLayer (visibility collected by viewport + drawn in index order)
│                            └ BorderLayer (EDG frames)
└── parser/    asset converter (one-shot, offline)
    ├── AssetsConverter.kt    lod → 2048² RGBA4444 texture atlas (PixmapPacker)
    ├── AssetsReader.kt       lod entry filtering: all TERRAIN entries + av* SPRITE + MAP defs
    ├── AssetsPacker.kt       frame packing + palette-rotation variant generation (rotatePalette until back to the original palette)
    ├── AssetsWriter.kt       writes atlas + index to disk
    └── formats/              LodReader / DefReader / H3mReader / PngWriter / Reader
```

**Key design**: on first launch the user picks a `.lod` file from the original game
(actually H3sprite.lod), and the converter extracts every def needed for rendering and
packs them into a single texture atlas stored in the app's private directory; the
wallpaper then loads the atlas directly and never touches the lod again. This project
instead reads the lod directly at runtime and builds its own atlas, removing the
pre-conversion step.

## 2. Implementation Differences from This Project

| Aspect | h3lwp (APK) | This project (macOS) |
|---|---|---|
| Rendering | libGDX OrthogonalTiledMapRenderer (CPU-grouped batch) | Metal instanced quads + texture2d array |
| Atlas | 2048² RGBA4444, generated once offline | 2048² RGBA8, built per map (~1s/map) |
| Palette animation | pre-generates N variant frames (rotate until back to the original) | also pre-generates variant frames (atlas key carries the step) |
| Animation phase | random initial stateTime per object | deterministic stepping via phase += 7 |
| Shadow index | fixedPalette override + PNG tRNS | rgba() directly maps index semantics |
| Map switching | timed 10min/2h/24h | 15min (adjustable) |
| Camera | random viewport + page-switch parallax | roaming camera (glide to target point + dwell) |
| Map layers | surface only | surface only (underground parsed and switchable) |

## 3. Decompilation Pitfalls (Directly Relevant to This Project's Port)

1. **libGDX key-constant inlining**: jadx turns constants such as
   `Input.Keys.NUMPAD_LEFT_PAREN` (=162) into bare numbers, so the enum values for the
   random monster tiers L5/L6/L7 look like 162/163/164 — and that part happens to be
   correct; but code such as `nextInt(CONTROL_LEFT, F11)` (=129..129+) in
   `ObjectsRandomizer.randomArtifact` must be reconstructed against the
   [h3lwp source](https://github.com/IlyaPomaskin/h3lwp) or by semantics (the relic
   range 129-139), not copied literally.
2. **Def.java data class**: the unknown byte count in the block header is easy to
   misread in the decompilation (it is actually 8 bytes, see formats.md §2.2).
3. **Lod.FileType**: the values of the TERRAIN/SPRITE/MAP enum come from the
   classification field of lod entries; AssetsReader only takes
   `TERRAIN entries + SPRITE entries with the av* prefix + MAP entries` — i.e. terrain
   and adventure map objects; interface assets (0x47 INTERFACE class) never enter the
   atlas. This project instead takes assets directly from the map's def table, which is
   more precise.

## 4. Behaviors Considered but Not Adopted

- The APK sorts its map list in **ascending order by file size** (loading small maps
  first so something appears on screen quickly) — this project sorts by filename, since
  preloading the full map set locally is no burden.
- The APK's `ObjectsLayer` uses a y/x grid index + a viewport expanded by 4 tiles for
  visibility collection; this project's object count (<3.5k) makes a full sorted
  traversal sufficient, with viewport AABB culling kept in place.
- The APK's desktop build (LWJGL) supports keyboard/click camera switching; this
  project is a non-interactive wallpaper and is controlled from the menu bar.
