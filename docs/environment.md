# Environment & Assets

English | [中文](zh-CN/environment.md)

Where the assets this project needs to run/build live and how to obtain them.
**Original game assets are copyrighted by Ubisoft / New World Computing; the
repository — and its git history — contain none of them.** Bring your own.

---

## Game assets (required by the Heroes3 engine, from the original HoMM3)

| Path | Purpose |
|---|---|
| `<data dir>/Data/H3sprite.lod` | **The sole art source for map rendering**: terrain/rivers/roads/border/all adventure-map object defs (4013 entries, 2565 defs); the About-window angel animation (cangel.def), DIALGBOX and IOKAY32 are also exported from it |
| `H3bitmap.lod` in the same dir | PCX/UI assets. **Needed at build time**: About-dialog paper background `DIBOXBCK.PCX`, player-color table `PLAYERS.PAL` (not yet exported, see formats.md §2.7/§2.8) |
| `<data dir>/Maps/*.h3m` | Maps. VCMI ships 189 `.h3m` files (RoE/AB/SoD) |

The easiest way to obtain these files is installing
[VCMI](https://github.com/vcmi/vcmi) (its installer copies them from the
original game).

**Runtime data-dir resolution order** (`AppDelegate.dataDir` /
`Heroes3Engine.defaultDataDir`):
1. User-chosen `dataDir` (UserDefaults, via 「Choose Data Folder…」);
2. **Bundled app resources** `GameWallpaper.app/Contents/Resources/Data/H3sprite.lod`
   (copied in by `build_app.sh` on machines that have them — the self-contained
   distribution prerequisite);
3. `~/Library/Application Support/vcmi` (development fallback).

**Bundled maps**: 3 XL maps listed in `scripts/bundled_maps.txt` are packed into
the app. If no maps folder was set (「Choose Maps Folder…」), the bundled maps are
loaded automatically. The map files are stored in the repo only as AES-encrypted
copies (`Resources/BundledMaps/*.h3m.enc`); password = local
`~/.config/gamewallpaper/bundled-maps-pass` = GitHub secret `BUNDLED_MAPS_PASS`.
Plain-text maps, if present in a local VCMI `Maps` dir, are copied directly.

**Packaging policy**: `scripts/build_app.sh` requires local assets by default
(missing assets abort the build rather than silently produce an empty package);
with `REQUIRE_ASSETS=0` it packages without sprite assets (the CI release mode)
— bundled maps are still decrypted in via the secret when available.

## Reference repositories

| Path | Notes |
|---|---|
| [VCMI](https://github.com/vcmi/vcmi) (v1.7.3 checkout) | Authoritative reference for formats and rendering semantics; key files: `lib/mapping/MapFormatH3M.cpp`, `lib/constants/EntityIdentifiers.h` (Obj enum), `client/render/CDefFile.cpp`, `client/mapView/MapRenderer.cpp`, `config/terrains.json`/`rivers.json` (palette-animation ranges) |
| [IlyaPomaskin/h3lwp](https://github.com/IlyaPomaskin/h3lwp) | Android Heroes 3 live wallpaper; baseline for this project's parsers/layer behavior (`base.apk` is its build artifact — local reverse-engineering reference only, never committed) |

## Toolchain

- Xcode / SwiftPM (`Package.swift`, macOS 13+); build script `scripts/build_app.sh`.
- Node (web map viewer, zero dependencies): `cd web && npm start`.
- Verification tools: jadx (APK decompilation, local), Python Pillow (pixel
  diffing), Quartz (offscreen window compositing), `screencapture`.

## Command cheatsheet

```bash
./scripts/build_app.sh            # release build + .app/.dmg packaging (local mode: bundles LOD + maps + About assets)
REQUIRE_ASSETS=0 ./scripts/build_app.sh   # sprite-asset-free mode (CI release; bundled maps still decrypted via secret)
open build/GameWallpaper.app      # launch the wallpaper (menu bar 🎮)

# Headless About-window verification: auto-opens About 0.9s after launch
# (combine with Quartz window enumeration + screencapture -l<id>)
open build/GameWallpaper.app --args --about

# Re-export About sprites manually (normally invoked by build_app.sh;
# needs H3bitmap.lod next to H3sprite.lod)
python3 scripts/export_about_assets.py \
    "$HOME/Library/Application Support/vcmi/Data/H3sprite.lod" \
    build/GameWallpaper.app/Contents/Resources/about

# Headless single-frame render (verification/debugging)
.build/release/GameWallpaper --snapshot "<map.h3m>" --out out.png \
    [--data-dir <dir>] [--width W --height H] [--time-ms ms] [--zoom z] \
    [--center-x 0..1 --center-y 0..1] [--level 0|1]

# Diagnostic probes
.build/release/GameWallpaper --probe-def GRASTL.DEF          # def structure/palette
.build/release/GameWallpaper --tile 6 1 --snapshot <map>     # h3m data of one tile

# Rendering comparison baseline (editor and game share the renderer)
/Applications/VCMI.app/Contents/MacOS/vcmieditor "<map.h3m>"
```

## Versioning

- Release version = **git tag `v<major>.<minor>`** (e.g. `v1.0`); pushing a tag
  triggers GitHub Actions to build the dmg and publish the Release
  (`.github/workflows/release.yml`).
- `CFBundleShortVersionString` = tag without the `v` (e.g. `1.0`);
  `CFBundleVersion` = build number (commit count + short sha), derived from git
  by build_app.sh; override locally with `MARKETING_VERSION=` / `BUILD_NUMBER=`.
  The About window shows `x.y-build`.
- Release notes are generated by the workflow from commits since the previous
  tag, grouped as feat/fix/other.
- i18n: `Resources/{en,zh-Hans}.lproj/Localizable.strings`; menu/About strings go
  through NSLocalizedString and follow the system language. Documentation is
  bilingual: English at `docs/`, Chinese mirror at `docs/zh-CN/`.
