# GameWallpaper — Multi-Game-Engine Live Wallpaper (macOS + Web)

English | [中文](README.zh-CN.md)

Turn classic game maps into live desktop wallpapers. The wallpaper runtime is
decoupled from game engines: it currently ships with a **Heroes of Might & Magic
III** engine, and more games (PAL, StarCraft, …) can be plugged in — see
[docs/architecture.md](docs/architecture.md).

The Heroes3 engine renders `.h3m` maps in real time, driven by the original game
assets (`H3sprite.lod`): water/lava palette animation, object idle animation and
an auto-roaming camera, matching VCMI's actual in-game rendering.

| Platform | Technology | Entry |
|---|---|---|
| macOS | Swift + Metal (desktop-level window), 3-target SwiftPM | `scripts/build_app.sh` → `build/GameWallpaper.app` |
| Web | Zero-dependency Node server + HTML Canvas (map viewer) | `cd web && npm start` → http://localhost:8765 |

> Original game assets (`.lod`/`.h3m`) are copyrighted by Ubisoft / New World
> Computing. **This repository contains no game asset files** (three bundled XL
> maps are stored AES-encrypted); bring your own — installing
> [VCMI](https://github.com/vcmi/vcmi) is the easiest way.

![screenshot](docs/wallpaper_final.png)

## Architecture

```
Sources/
├── WallpaperCore/       Wallpaper shell (game-agnostic): engine protocols, desktop-level
│                        window, render loop, battery/sleep power policy, jump camera,
│                        About window
├── Heroes3Engine/       Heroes3 engine: lod/def/h3m parsing, atlas, Metal rendering,
│                        built-in web viewer, headless CLI
└── GameWallpaper/       Assembly (executable): engine registration + menu bar UI
```

Engine protocol and how to add a new game: **[docs/architecture.md](docs/architecture.md)**.
Rendering semantics (VCMI-aligned constants/formulas): [docs/rendering.md](docs/rendering.md);
file-format reverse-engineering notes: [docs/formats.md](docs/formats.md);
lessons learned: [docs/pitfalls.md](docs/pitfalls.md).

## Usage (macOS)

```bash
# Build (requires Xcode, macOS 13+; H3sprite.lod must be present locally,
# see docs/environment.md)
./scripts/build_app.sh
open build/GameWallpaper.app   # a 🎮 icon appears in the menu bar
```

- **Map source**: if a maps folder was set (「Choose Maps Folder…」), maps are
  loaded from it; otherwise the **3 bundled XL maps** are used automatically.
- **Game assets**: `Data/H3sprite.lod` inside the data folder (VCMI's directory
  by default); pick it via 「Choose Data Folder…」 if the app starts without assets.
- **Menu bar settings**: zoom 1×–4×, brightness dim 0–60%, pause/resume, next map now.
- **Window level**: pinned at the desktop level (kCGDesktopWindowLevel, same
  approach as Plash) — above the wallpaper image, below desktop icons, visible
  on every Space, never intercepting mouse clicks.
- **Power saving**: rendering pauses when displays sleep; on battery power it
  stops completely (0 fps) and resumes when plugged in.
- **Quit**: menu bar → Quit.

### Headless CLI (single-frame verification)

```bash
.build/release/GameWallpaper --snapshot <map.h3m> --out snap.png \
    [--data-dir <vcmi dir>] [--width 1920 --height 1080] [--time-ms 3000] \
    [--zoom 1] [--center-x 0.5 --center-y 0.5] [--level 0]
```

## Web Map Viewer

`web/` is the browser sibling sharing the same parsing logic: a zero-dependency
Node backend (same lod/def/h3m parsers, at `web/server/engines/heroes3/`) plus
an HTML Canvas front end that renders full maps with pan/zoom/switch/animation.
The macOS app's「Map Viewer」menu item serves the same HTTP API (`/api/maps`,
`/api/scene`, `/atlas/...`).

```bash
cd web && npm start   # http://localhost:8765/
```

## Versioning & Release

- Version format: **`v<major>.<minor>`** git tags (e.g. `v1.0`); each tag maps
  1:1 to a Release.
- Pushing a tag triggers GitHub Actions: universal build → dmg packaging
  (with the 3 bundled XL maps decrypted from a repo secret; sprite assets are
  still bring-your-own) → release notes grouped by feat/fix/other since the
  previous tag → GitHub Release. See
  [.github/workflows/release.yml](.github/workflows/release.yml).
- Release flow:

  ```bash
  git tag v1.1 && git push origin v1.1
  ```

- Bundled maps maintenance: list them in `scripts/bundled_maps.txt`, then run
  `scripts/bundle_maps.sh encrypt` (password file: `~/.config/gamewallpaper/bundled-maps-pass`,
  also configured as the `BUNDLED_MAPS_PASS` repo secret).
- Local build version overrides: `MARKETING_VERSION=1.1 BUILD_NUMBER=42 ./scripts/build_app.sh`.

## Known Limitations / Roadmap

- Only the surface layer is rendered (the underground layer is parsed already;
  switchable via `level=1` in WallpaperPresenter).
- Heroes/flags are not player-color tinted yet (def index 5 reserved).
- Fog of war and hero movement animation do not apply (no game state in a wallpaper).
- The dmg is an unsigned build: if Gatekeeper blocks the first launch, right-click
  → Open, or `xattr -d com.apple.quarantine /Applications/GameWallpaper.app`.

## References

- [VCMI](https://github.com/vcmi/vcmi) (authoritative reference for rendering
  semantics and formats)
- [IlyaPomaskin/h3lwp](https://github.com/IlyaPomaskin/h3lwp) (Android Heroes 3
  live wallpaper; baseline for this project's parsers/layer behavior)
