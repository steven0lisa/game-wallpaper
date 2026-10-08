# Architecture: Multi-Game-Engine Live Wallpaper

English | [中文](zh-CN/architecture.md)

This project is a **live-wallpaper runtime that supports multiple game engines**:
the wallpaper shell owns everything game-agnostic, while each game plugs in as an
"engine" providing its own asset parsing, scene construction and rendering.

## Overview

```
┌──────────────────────── Assembly (Sources/GameWallpaper) ─────────────────────────┐
│  main.swift (entry + CLI dispatch)   AppDelegate.swift (menu bar, asset folders,   │
│                                      engine registration)                          │
└──────────────┬──────────────────────────────────────────────────┬────────────────┘
               │ depends on                                        │ depends on
┌──────────────▼──────────────────┐   ┌────────────────────────────▼─────────────────┐
│  WallpaperCore (wallpaper shell) │   │  Game engine targets (pluggable)              │
│  · Engine.swift  engine protocols│◄──┤  Heroes3Engine:                               │
│  · WallpaperWindow  desktop-level│impl│  · LodFile/DefFile/H3mFile/AssetLibrary     │
│    window                        │protocol  parsing                                  │
│  · WallpaperPresenter cycle/sleep│   │  · GameMap/AtlasBuilder scene & atlas         │
│  · Camera  jump roaming          │   │  · Heroes3Renderer Metal rendering            │
│  · battery/sleep power policy    │   │  · MapWebServer built-in web viewer           │
│  · AboutWindowController        │    │  · Heroes3CLI headless diagnostics            │
└─────────────────────────────────┘   └───────────────────────────────────────────────┘
```

Dependencies are strictly one-way: `Heroes3Engine → WallpaperCore`; the assembly
layer depends on both, and the shell knows nothing about any concrete game.

## Engine protocols (WallpaperCore/Engine.swift)

Deliberately tiny — the shell only asks an engine "how big is the world, what do
I draw this frame":

```swift
protocol GameEngine: AnyObject {
    static var engineID: String { get }          // "heroes3"
    static var displayName: String { get }
    static var sceneExtensions: [String] { get } // ["h3m"]
    init(device: MTLDevice, dataDir: URL) throws // engine-level asset loading; throw if missing
    func loadScene(at url: URL, level: Int) throws -> WallpaperScene
}

protocol WallpaperScene: AnyObject {
    var worldSizePx: Float { get }               // camera roaming range
    var brightness: Float { get set }
    func prepare(viewport: SceneViewport, timeMs: Double, cameraAtRest: Bool) // per-frame: animation + draw data
    func render(to: MTLRenderPassDescriptor, wait: Bool)
}
```

On abstraction size (important convention):
- **The shell only abstracts what must be shared**: window level, render-loop
  cadence (5 fps at rest / 30 fps panning), 0 fps on battery, sleep pause, map
  cycling, jump camera, brightness/zoom preferences, About window.
- **Never pre-design for a second engine**: map rendering, animation and content
  differ per game (PAL is a top-down tile map with sprite sequences, StarCraft is
  an isometric mixed-viewport…). Engines implement freely; when a second engine
  actually arrives, sink only then-repeated patterns into Core.
- Engine-internal types (AssetLibrary/GameMap/MapRenderer etc.) stay
  target-internal; across targets only the 4 public symbols required by the
  protocols are exposed (Heroes3Engine/Heroes3Scene/MapWebServer/Heroes3CLI).

## Adding a new engine (e.g. a hypothetical PAL/StarCraft engine)

1. Create `Sources/<Game>Engine/` depending on `WallpaperCore`:
   ```swift
   // Package.swift
   .target(name: "PalEngine", dependencies: ["WallpaperCore"]),
   ```
2. Implement `GameEngine` (asset library loading + `loadScene`) and
   `WallpaperScene` (worldSizePx / brightness / prepare / render). For Metal
   pipelines you can copy Heroes3Renderer's "instanced quads + atlas" pattern,
   or draw entirely your own way.
3. Assembly: construct and register the engine in
   `AppDelegate.applicationDidFinishLaunching`; hook CLI dispatch into `main.swift`.
4. Packaging: add an asset-copy section for the engine in `scripts/build_app.sh`
   (copyrighted assets never enter the repo — see the "reverse-engineered /
   original game assets" section of .gitignore).

## Platform matrix

| Platform | Form | Location |
|---|---|---|
| macOS (primary) | SwiftPM multi-target Metal wallpaper app | `Sources/` (see diagram above) |
| Web | Zero-dependency Node server + Canvas viewer (engine code at `web/server/engines/heroes3/`) | `web/` |
| ~~Windows~~ | Removed (Oct 2026) | git history |

## Versioning & release

- Version = git tag `v<major>.<minor>`; pushing a tag triggers GitHub Actions to
  build a dmg and publish a Release (with auto-generated notes). See
  `.github/workflows/release.yml` and [environment.md](environment.md).
