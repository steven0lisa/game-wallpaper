<h1 align="center">🎮 GameWallpaper</h1>

<p align="center">
  <strong>Your desktop becomes a living game world.</strong><br>
  Classic game maps, rendered in real time, as your macOS wallpaper.<br>
  English | <a href="README.zh-CN.md">中文</a>
</p>

<p align="center">
  <img src="docs/wallpaper_final.png" alt="GameWallpaper running on a real desktop" width="720">
</p>

GameWallpaper currently ships with a **Heroes of Might & Magic III** engine: pick
any `.h3m` map and it plays behind your desktop icons — water and lava shimmering,
objects idling, a camera slowly roaming the battlefield, exactly like the in-game
adventure map. More game engines are on the roadmap (see
[Roadmap](#-roadmap)).

## ✨ Highlights

- **Alive, but out of your way** — the wallpaper sits *behind* your desktop icons
  and never intercepts clicks. Your desktop stays fully usable, on every Space
  and every display.
- **Set it and forget it** — a new map is picked automatically every 15 minutes;
  the camera jumps to a new viewpoint every few minutes. Or pause / skip / pick a
  map yourself from the menu bar.
- **3 XL maps bundled** — after install it just plays; add your own maps any time
  (drop a folder and point the app to it).
- **Gentle on your battery** — rendering pauses when the display sleeps and stops
  completely on battery power; the camera idles at 5 fps and only wakes up while
  moving.
- **Make it yours** — zoom 1×–4×, dim the scene 0–60% at night, pause anytime.
  English and Chinese UI, following your system language.
- **Map Viewer included** — explore the full map in your browser (pan, zoom,
  switch maps, watch the animations) via one menu click.

## 🚀 Getting Started

**1. Download** the latest `GameWallpaper.dmg` from the
[Releases page](https://github.com/steven0lisa/game-wallpaper/releases/latest),
open it and drag **GameWallpaper** into **Applications**.

**2. Point it at your game assets** (one time). Launch the app — a 🎮 icon
appears in the menu bar. On first launch, choose **Choose Data Folder…** and
select the folder that contains `Data/H3sprite.lod`. If you have
[VCMI](https://vcmi.eu) installed, that's simply
`~/Library/Application Support/vcmi`.

> The renderer needs the original HoMM3 sprite file (`H3sprite.lod`, ~65 MB).
> It is copyrighted by Ubisoft / New World Computing, so it is **not** included
> in the download — you need a copy of the game you already own. Installing the
> free [VCMI](https://vcmi.eu) client is the easiest way to get everything in
> place. **Maps** are optional: without a maps folder, three bundled XL maps
> start playing immediately.

**3. Enjoy.** Your desktop is now a living battle map. Use the 🎮 menu to switch
maps, adjust zoom/brightness, pause, or open the Map Viewer.

<details>
<summary><strong>System requirements & troubleshooting</strong></summary>

- macOS 13 or later, Apple Silicon or Intel.
- **"GameWallpaper can't be opened" (Gatekeeper)**: the build is unsigned. Right-click
  the app → **Open**, or run
  `xattr -d com.apple.quarantine /Applications/GameWallpaper.app`.
- **Menu bar icon is there but nothing renders**: no game assets found — use
  **Choose Data Folder…** to select the folder containing `Data/H3sprite.lod`.
- **The wallpaper is too distracting at night**: menu → Brightness → dim up to 60%.
- **Maps**: choose a folder of `.h3m` files via **Choose Maps Folder…**, or open
  individual maps with **Open Map…** (⌘O).
- To quit: 🎮 menu → Quit (⌘Q).

</details>

## 💬 Feedback

Found a bug, or want a game engine added? Please
[open an issue](https://github.com/steven0lisa/game-wallpaper/issues) — or use
the **Feedback** link inside the app (About window). Screenshots of your setup
make reports much easier to act on.

## 🗺 Roadmap

- [x] Heroes of Might & Magic III engine (macOS + web viewer)
- [ ] More engines — e.g. Chinese PAL (仙剑), StarCraft — via the plugin-style
      engine interface ([architecture guide](docs/architecture.md))
- [ ] Underground layer support, player-color tinting for heroes/flags

## 🛠 For Developers

The wallpaper runtime is engine-agnostic (SwiftPM: `WallpaperCore` shell +
pluggable engine targets); pushing a `v<major>.<minor>` tag builds and publishes
a release automatically. To build from source and to understand the rendering
semantics, see the docs:

| Document | Content |
|---|---|
| [docs/architecture.md](docs/architecture.md) | Engine protocol, how to add a new game |
| [docs/environment.md](docs/environment.md) | Asset layout, toolchain, command cheatsheet |
| [docs/rendering.md](docs/rendering.md) | Rendering semantics vs VCMI (the consistency baseline) |
| [docs/formats.md](docs/formats.md) | HoMM3 file-format reverse-engineering notes |
| [docs/pitfalls.md](docs/pitfalls.md) | 29 real-world lessons learned |
| [web/README.md](web/README.md) | The browser map viewer |

中文文档：[docs/zh-CN/](docs/zh-CN/)（每篇文档顶部可互相跳转）。

## 🙏 Credits

- [VCMI](https://github.com/vcmi/vcmi) — the rendering semantics and file-format
  authority this project aligns with
- [IlyaPomaskin/h3lwp](https://github.com/IlyaPomaskin/h3lwp) — the Android
  live-wallpaper that inspired the parsers and layer behavior

## 📄 License

Code is released under the [MIT License](LICENSE). Game assets are **not**
included in this repository or its releases and remain the property of their
respective owners.
