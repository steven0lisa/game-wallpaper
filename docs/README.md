# docs/ — Multi-Game-Engine Live Wallpaper

English | [中文](zh-CN/README.md)

Turn classic game maps into live desktop wallpapers. The wallpaper runtime is decoupled from game engines; currently ships with a **Heroes of Might & Magic III** engine, with more games planned (PAL, StarCraft, …).

| Platform | Technology | Entry |
|---|---|---|
| macOS | Swift + Metal (desktop-level window), 3-target SwiftPM | `scripts/build_app.sh` → `build/GameWallpaper.app` |
| Web | Zero-dependency Node server + HTML Canvas (map viewer) | `cd web && npm start` |

- Architecture and engine integration guide: [architecture.md](architecture.md) — **start here**
- Data/asset locations, toolchain and command cheatsheet: [environment.md](environment.md)
- Research notes accumulated during development (suggested reading order: formats → rendering → pitfalls → reference-h3lwp):

| Document | Content |
|---|---|
| [formats.md](formats.md) | **HoMM3 file-format reverse-engineering notes**: .lod archive layout, .def sprite format (header / 4 RLE modes / palette semantics incl. player-color segment 224–255 and color-key placeholder colors / animation ranges), H3-style PCX (DIBOXBCK.PCX), .h3m map format, EDG border formula, byte-level evidence for every pitfall |
| [rendering.md](rendering.md) | **Rendering semantics vs VCMI**: layer order, exact draw rules for terrain/rivers/roads (incl. the road half-tile offset algorithm), object anchoring & sort order, animation timing table, camera behavior, About dialog (drawBorder corners+edges with DIBOXBCK tiling), verification methods and results |
| [pitfalls.md](pitfalls.md) | **Lessons learned**: 24+ real bugs (DEF block-header length, magenta/cyan placeholder colors, color-key transparency, 9-slice assumptions, PNG filter byte, NSWindow constraint common ancestor, cache poisoning, Metal tearing, …) with the debugging process and fixes, plus the occluded-window verification methodology |
| [reference-h3lwp.md](reference-h3lwp.md) | **Android reference implementation reverse-engineering**: h3lwp (base.apk) architecture, offline asset conversion pipeline, differences vs this project, jadx decompilation traps |
| [environment.md](environment.md) | **Environment & assets**: asset locations (incl. H3bitmap.lod build-time usage), key files in reference repos, toolchain, command cheatsheet (packaging / --about verification / About asset export), versioning and i18n |

Wallpaper verification screenshot: [wallpaper_final.png](wallpaper_final.png) (real desktop-level rendering).
