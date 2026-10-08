English | [中文](zh-CN/rendering.md)

# Rendering Semantics and VCMI Cross-Reference (Visual Consistency Baseline)

This document records every rendering rule that determines "what the running map actually looks like", together with its provenance in the VCMI source code and how this project implements each one. Goal: make the wallpaper match the in-game adventure map picture.

---

## 1. Layers and Draw Order

Per-frame draw order (VCMI `MapRenderer.cpp` renderTile loop; the APK GameScreen matches):

```
EDG border → terrain → river → road → objects (sorted)
```

This project appends instances to the instance array in this order and completes the frame in a single instanced draw (translucent blending follows instance order).

## 2. Terrain

- Per tile: `DEF = terrains[terrainType].tiles`, frame = `terView`, flip = `extTileFlags & 3`.
- **Flip bit semantics (consistent across all three layers; verified pixel-by-pixel against vcmieditor)**: the 2-bit value is a "slot number"; bit0 (0x01) = **left-right mirror**, bit1 (0x02) = **top-bottom mirror**, 0x03 = both flips. VCMI `MapTileStorage::load` pre-flips each full frame into 4 slots — note that its `verticalFlip()` means "flip about the vertical axis" = left-right mirror; **the naming is by axis, not by direction**, so don't take it at face value (see pitfalls #14).
- **No client-side neighborhood computation exists**: whatever frame the h3m stores is what gets drawn (transition tiles are worked out by the map editor / RMG at map-write time using terrainViewPatterns). This is the single most important "pitfall avoided" conclusion on the rendering side.
- 32×32 px per tile; water/lava rotate one step through their palette animation ranges every 180ms.
- Terrain blit mode is OPAQUE (opaque; index 0 is drawn too).

## 3. Rivers and Roads

- River: frame = `riverDir`, flip = `(extTileFlags>>2)&3`, COLORKEY transparency (index 0 is transparent), with palette animation (CLRRVR/MUDRVR/LAVRVR), 180ms/step.
- Road: frame = `roadDir`, flip = `(extTileFlags>>4)&3`, COLORKEY, **no animation**.
- **The road half-tile offset** (exact algorithm from VCMI MapRendererRoad::renderTile): each tile's road image is drawn "shifted down 16px, spanning two tiles" — the **top 16px** of this tile's road image goes to the **bottom half** of this tile; the **bottom 16px** of the tile **above**'s road image goes to the **top half** of this tile:
  ```cpp
  target.draw(imageAbove, Point(0, 0),  Rect(0, 16, 32, 16));  // bottom half of tile above → top half of this tile
  target.draw(image,      Point(0, 16), Rect(0,  0, 32, 16));  // top half of this tile → bottom half of this tile
  ```
  In other words, the whole road sits visually half a tile below its logical tiles.
- **⚠️ Crop order when flipping (pitfall)**: VCMI does "**mirror the whole image first, then crop with a plain Rect**" (the slot image is already flipped); "crop first, flip after" on the sub-rectangle is not equivalent — once mirrored, the rectangle's position relative to the data has changed. Straight road strips are left-right symmetric, so the mistake slips through by luck; diagonal strips (22×22@(10,10)) break immediately. See Swift `Renderer.canvasCrop` (mirror the data rect into flipped-canvas space and intersect + the shader mirrors sampling within the quad per flags) and JS `viewer.drawFrameCanvas` (same order + scale(-1,1)); both sides verified pixel-by-pixel against vcmieditor (see pitfalls #15).

- **⚠️ Road traversal semantics (pitfall)**: VCMI calls renderTile for **every tile in the viewport**, **not** only for tiles that carry a road. When this tile has no road but the tile above does, you must still draw the bottom half of the tile above's road image — otherwise the road breaks at "terminates downward" junctions (the bottom half of a road image always lands on the next tile). The Viking map has 601 such tiles (20602 in total across 158 maps), every one of which lost road surface under the old implementation. Rivers do not have this problem (the whole frame is drawn on this tile; nothing extends across tiles).

- **⚠️ Margins of road/river frames (canvas semantics, pitfall)**: for frames such as DIRTRD/GRAVRD/COBBRD, the **canvas is 32×32 while the actual data carries a margin** (e.g. the horizontal dirt-road frames 12/13 hold 32×14 data with margin (0,9), i.e. the road surface is vertically centered at canvas y=9..23; the vertical frame is 14×32 with margin (9,0), horizontally centered). In VCMI's `draw(image, Point, Rect)` the Rect is in **canvas coordinates** — Rect(0,16,32,16) takes the bottom half of the canvas (the part left after the transparent margin intersects the data), **not** the bottom half in data coordinates. Cropping in data coordinates instead (drawing the 32×14 data straight into a 32×16 target area) stretches the road surface, shifts it half a tile overall, and leaves it straddling the gridline. Correct approach: intersect canvas rect ∩ data rect, then map the intersection to the target half-tile by its position inside the canvas (Swift `canvasCrop` / JS `drawFrameCanvas`).
  Terrain/river/object frames are drawn whole, so the margin takes effect naturally; only the "half-tile crop" path hits this pitfall.

## 4. Objects

- The anchor tile is anchored at the bottom-right corner of the canvas (see formats.md §4); frame data is offset inward by the margin.
- Frame loop: all frames of group 0 loop at 180ms per frame (idle animation); phases are staggered per object.
- Translucent shadows: index 1 = 25% black, 4 = 50% black (from placeholder-color substitution in the DEF palette, see formats.md §2.5).
- Sorting: placementOrder ↓ → y ↑ → heroes on top → x ↑ → file order.
- Invisible objects (VCMI getBaseAnimation returns empty): EVENT(26), GRAIL(36); random heroes / placeholders are not drawn in the wallpaper project either (no visual).

## 5. EDG Border

EDG.DEF's 36 frames + the `getIndexForTile` formula (formats.md §5).
In-game `showBorder()=true`: the ring just outside the map is drawn with a golden frame, and farther out with the dark rock pattern.

## 6. Animation Timing Summary (VCMI MapRendererContext)

| Content | Period | Source |
|---|---|---|
| Terrain/river palette animation | 180ms/step | `baseFrameTime = 180` |
| Object idle frames | 180ms/frame (phase = objectID) | same as above |
| Object moving frames (not applicable to the wallpaper) | 50ms/frame | AdventureMovingContext |
| Fades (not applicable) | 500ms / teleport 250ms | MapViewController |

The palette animation period = LCM of the individual rotation-range lengths (water: 12 steps = 2.16s per cycle; lava: 9 steps = 1.62s).

## 7. Camera and Zoom (custom to this project, modeled on VCMI behavior)

- VCMI game: default tileSize 32, zoom steps of `32 * 1.01^n`, panning clamped to the map range + border.
- This project's wallpaper: the roaming camera glides at constant speed (22 map px/s) toward random target points within the map range, dwelling 4-9s at each; viewport clamping allows up to 4 tiles of border to be revealed (±128px inside `clamp`).
- Zoom levels 1×/2×/3×/4× (screen pixels / map pixels); the Metal pipeline uses nearest sampling to preserve the pixel-art look.

## 8. Verification Methods and Results

| Verification item | Method | Result |
|---|---|---|
| Tile-by-tile comparison against the game | `vcmieditor` loads the same map (shares MapRenderer with the game); capture its canvas vs this project's `--snapshot` render from the same viewpoint, auto-align + 313-tile 8×8 sampled diff | All average differences come from the editor's RES/MON markers; terrain/river/road/object/shadow all match |
| Terrain type coverage | "A Warm and Familiar Place" (rough/lava/rock/dirt) + "Emerald Isles" (water/sand/grass/dirt) | All 7 terrain types + rivers + roads + border correct |
| Animation | Same-viewpoint diffs nonzero at t=0/540/1800ms; on-device 2s diff nonzero (3.72/px) | Palette animation + object animation + camera roaming all working |
| Frame rate | draw count at 60fps | Stable 60fps |
| Desktop integration | Desktop-layer window level -2147483623; the map shows through beneath the translucent menu bar | Pass |

Reproduce the comparison:
```bash
# This project's render (same pixel scale as the editor canvas)
.build/debug/GameWallpaper --snapshot "<map.h3m>" --out mine.png \
    --width 1152 --height 1152 --time-ms 0 --zoom 1 --center-x 0.5 --center-y 0.5
# Open the editor on the same map (vcmieditor shares the renderer with the game)
/Applications/VCMI.app/Contents/MacOS/vcmieditor "<map.h3m>"
```

## 9. About Dialog (heroes3-style UI, cross-referenced with VCMI CMessage)

The About window's dialog look is recreated after VCMI's info windows; three of the rules below were each once written wrong by assumption:

- **Border position — drawn on the rectangle expanded outward from the content area, not inset within the window**: VCMI `CWindowObject::showAll` (BORDERED) calls `CMessage::drawBorder(color, to, pos.w+28, pos.h+29, pos.x-14, pos.y-15)` — the border canvas is the content area **expanded by 14px left/right and 15px top/bottom**. Equivalent approach on the Swift side: window = content + 2×(14/15), with the whole window as the border's canvas (SDL top-left, y-down → NSView bottom-left, y-up; convert with `nsY = winH - sdlY - frameH`).
- **Border sprites**: `CMessage::drawBorder` (client/windows/CMessage.cpp) **uses only box[0..7] of DIALGBOX.DEF** — box[0..3], the four corners (64×64), go on the corners; box[4/5], the left/right edges (14×64), and box[6/7], the top/bottom edges (64×15), are tiled stepwise along their axes; draw order is "edges first, corners after" (corners cover edges). **box[8..10] take no part at all** (their inner pixels are color keys, not an inner background). The assumed "9-slice that tiles box[8] as the interior" was one root cause of the first version's cyan grid.
- **Window size on the 64px grid (128+64k)**: edge strips step 64px; at 512×448 the window gets exactly 6 top/bottom strips and exactly 5 left/right strips, with **no gaps and no overlaps**. The `+1` overlap patching for bottom/right inside VCMI's drawBorder is a fallback for arbitrary sizes; once grid-aligned it is unnecessary.
- **Interior background**: `CInfoWindow` uses `CFilledTexture(ImagePath::builtin("DiBoxBck"), pos)` (client/windows/InfoWindows.cpp), and `showAll` **tiles** it (x/y step by the tile size; not stretched) — the brown-paper texture DIBOXBCK.PCX fills the content area with the border drawn on top; the transparent gaps between border sprites need a whole-window fallback color (the dark brown taken from DIBOXBCK), otherwise a borderless window shows a white base.
- Colors: the border's player-color segment 224–255 is already the blue-player gradient in DIALGBOX's own palette (see formats.md §2.7), so no re-tinting is needed; the interior paper base color is `(116,75,42)`, a brown. The "dark blue interior" impression comes from later H3 UI or VCMI skins; the original DIALOG is a brown base with a blue frame.
- **OK button**: the IOKAY32 frame ships with a golden check mark; after setting `imagePosition = .imageOnly` on the NSButton, **do not set `.title` again** (title flips it back to text display mode); with no text, no localization key is needed either.

Implementation: `AboutWindowController.swift` (Heroes3BorderView: fallback color + tiled background + box[0..7] tiled with the whole window as canvas) and `scripts/export_about_assets.py` (DIALGBOX color-key transparency + DIBOXBCK.PCX → background.png); pitfalls recorded in full in pitfalls #22/#25.
