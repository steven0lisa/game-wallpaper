# Web Map Viewer (Node + HTML Canvas)

English | [中文](README.zh-CN.md)

Browser sibling of the macOS wallpaper app, same parsing logic and semantics:
a Node backend parses the original game files into scene data + atlas pages,
and a Canvas front end renders the **full map** (pan/zoom/switch maps/watch
animation). Pixel-compared against the Swift/Metal renderer (mean diff 5.7/765
for the same viewport — the difference comes from Canvas bilinear filtering;
content is identical).

## Run

```bash
cd web
npm start            # or: node server/Server.js
# open http://localhost:8765/
```

- Assets and maps default to `~/Library/Application Support/vcmi/`
  (`Data/H3sprite.lod` + `Maps/`); point `H3_DATA_DIR` at another VCMI data dir,
  and `PORT` changes the port.
- Zero npm dependencies (pure Node built-ins + native Canvas).

## Interaction

- Drag to pan, wheel to zoom (mouse-centered), ＋/− buttons, fit-to-window
- Map dropdown (158 maps), Surface/Underground layer switch (for maps that have one)
- Pause/play animation (water/lava/river palette animation at 180 ms/step, object idle animation)

## API

| Route | Description |
|---|---|
| `GET /` | Viewer page |
| `GET /api/maps` | Available map list |
| `GET /api/scene?map=X.h3m&level=0` | Scene JSON (terrain/river/road/object arrays + frame table) |
| `GET /atlas/<map>/<levelVer>/atlas-N.png` | Atlas page (2048² RGBA PNG; `levelVer` contains a content fingerprint `level0-<mtime>-<frames>-<objects>` — any content change changes the URL, so the browser never uses a stale atlas) |

URL parameters (for automated comparison): `?map=`, `&level=`, `&cx=0.5&cy=0.5`
(viewport center 0..1), `&zoom=1` (CSS px per map px), `&t=0` (fixed animation
time in ms), `&win=WxH` (fixed canvas viewport size, working around headless
Chrome's innerHeight jitter; note that in this mode `--screenshot` may fail to
capture the canvas — use a canvas dump for verification instead).

Caching policy: atlas URLs embed a [content + code] fingerprint
(`level0-<map mtime>-<frames>-<objects>-<code hash>`) and are served with
`immutable, max-age=31536000` — any change to map data or generation code
changes the URL, so the browser never uses a stale atlas
(see docs/pitfalls.md #10).

## Architecture

```
web/
├── server/            pure Node, zero dependencies
│   ├── Reader.js      binary reader (Swift counterpart: Reader.swift)
│   ├── LodFile.js     .lod archive (LodFile.swift)
│   ├── DefFile.js     .def decoding + palette animation (DefFile.swift)
│   ├── H3mFile.js     .h3m parsing (H3mFile.swift)
│   ├── Scene.js       scene building: atlas packing/borders/random objects/sorting (GameMap.swift + AssetLibrary.swift)
│   └── Server.js      HTTP server + scene cache (cache/, one dir per map/level)
└── public/
    ├── index.html     viewer page
    └── viewer.js      Canvas renderer (layer order / road half-tile offset / animation timing match the Swift version)
```

Engine code lives at `server/engines/heroes3/` (game-agnostic shell code stays
at `server/`, mirroring the macOS target split).

Full format/rendering-semantics documentation: [docs/](../docs/)
(formats.md / rendering.md).

## Verification (headless Chrome)

```bash
# Fixed viewport and animation time, compared against the Swift CLI with the same parameters
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new \
  --window-size=1280,832 --virtual-time-budget=8000 --screenshot=web.png \
  "http://localhost:8765/?map=Emerald%20Isles.h3m&cx=0.5&cy=0.5&zoom=1&t=0"
# Note: headless innerHeight = 832-87 (chrome UI); the Swift side matches with --height 745.
# Result: mean diff 5.7/765, >60-diff pixels 2.2% (panel occlusion + filtering).
```
