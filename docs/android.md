English | [中文](zh-CN/android.md)

# Android live wallpaper (org.feichao.h3wallpaper)

A self-contained re-implementation of the Heroes of Might & Magic III live
wallpaper for Android, sharing this repo's map-rendering semantics (same parsers
and draw order as the web viewer and the macOS Metal renderer).

## What it does

- **Zero setup** — three XL maps are baked into the APK (`scenes.bin` + 17 atlas
  pages). Install → pick the wallpaper in the system picker → done. There is no
  settings screen at all: one launcher screen with **Start / Pause**, **About**,
  and **Check for updates** (queries the GitHub Releases API and links here).
- **Same engine semantics as mac/web** — `android/bake/bake.js` reuses the web
  engine parsers (h3m/lod/def + scene builder) to emit a compact little-endian
  bundle; the GLES2 renderer ports `web/public/viewer.js` line by line
  (border → terrain → rivers → roads with VCMI half-tile crop → objects in
  painter order).

## Battery design (vs the original h3lwp APK)

The original renders continuously through libGDX (~60fps whenever visible). This
implementation draws **only when something can change**:

| State | Behavior |
|---|---|
| Wallpaper invisible (screen off / app covering / locked) | **0 fps** — the render thread parks; last frame stays |
| User pressed Pause | **0 fps** (frozen frame) |
| Camera dwelling (≈179 of every 180 s) | redraw **only on 180 ms animation-step boundaries** ≈ 5.5 fps — the minimum rate at which H3 sprites change |
| Camera hop transition (1.6 s) | 30 fps |
| `Surface.setFrameRate` hint | tells the compositor the current cadence so LTPO panels can downclock |

The visible region at the default DPI-scale zoom is only ~411×914 world px
(~13×29 tiles), so each redraw is a few hundred textured quads. Between 180 ms
boundaries the render thread sleeps with zero CPU/GPU work.

Measured on a Xiaomi 14-class device (300 s, screen on, home screen, wallpaper
visible): original APK ≈ 10.6% CPU, this APK ≈ 1% CPU (see
`scripts/android_battery_bench.sh`).

## Build

```bash
# dev machine (needs the game's H3sprite.lod + decrypted bundled maps)
./scripts/build_android.sh            # debug APK -> build/GameWallpaper.apk
./scripts/android_scenes.sh encrypt   # refresh Resources/AndroidScenes.enc after renderer/map changes

# CI (no game assets available): unpacks the encrypted bundle, builds signed APK
./scripts/android_scenes.sh unpack
BUNDLED_MAPS_PASS=... ./scripts/android_scenes.sh unpack
```

- **Copyright**: the baked scene data derives from the original game's sprites
  and maps. Like `Resources/BundledMaps/*.h3m.enc`, it is stored in the repo
  **only AES-encrypted** (`Resources/AndroidScenes.enc`, password = the
  `BUNDLED_MAPS_PASS` secret) and decrypted at build time; plaintext never
  enters git. The APK itself necessarily contains the rendered art.
- Signing: release APKs are signed with a keystore supplied via GitHub secrets
  (`ANDROID_KEYSTORE_B64` / passwords). Debug builds use the debug keystore.
- Releasing: push tag `v{major}.{minor}` — CI builds the dmg **and** the APK and
  attaches both to the same GitHub Release.

## Source layout

```
android/
├── bake/bake.js                  # h3m+LOD -> scenes.bin + atlas PNGs (web-engine reuse)
├── app/src/main/java/org/feichao/h3wallpaper/
│   ├── SceneData.java            # scenes.bin parser (struct-of-arrays)
│   ├── wp/Renderer.java          # GLES2 draw (viewer.js port: layers, road crop, flips)
│   ├── wp/Camera.java            # hop camera (port of Sources/WallpaperCore/Camera.swift)
│   ├── wp/RenderThread.java      # EGL + on-demand frame loop (the battery core)
│   ├── wp/H3WallpaperService.java# WallpaperService engine (visibility/pause wiring)
│   └── ui/MainActivity.java      # start/pause + About + update check (zero deps, no androidx)
└── app/src/main/assets/scenes/   # baked output (gitignored; encrypted copy committed)
```

Runtime deps: **none** (pure framework APIs, no androidx/libgdx).
minSdk 26 / targetSdk 35; OpenGL ES 2.0.
