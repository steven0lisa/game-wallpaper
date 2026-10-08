English | [中文](zh-CN/pitfalls.md)

# Development Pitfalls Log

A chronological record of the problems encountered while implementing this project, how each was diagnosed, and the conclusions reached.
Every entry has been fixed and verified; written down to avoid repeating them.

---

## 1. Length of the unknown field in the DEF block header (the most elusive)

**Symptom**: All objects render correctly, but terrain frames are shifted by one tile overall — tile (x,y) draws the content of a neighboring tile, and some tiles have scrambled colors.
**Diagnosis**: Hex-dumped GRASTL.DEF and hand-computed the offset table at the two candidate positions: with unknown=8, all 79 frame offsets are valid; with unknown=12, the whole offset table shifts left by one frame.
**Conclusion**: The block header's unknown field is **8 bytes** (per the VCMI source comment "8 unknown bytes - skipping"; the jadx-decompiled Def.java data class declaration is misleading).

## 2. Magenta placeholder colors at the shadow indices

**Symptom**: Magenta (255,0,255 family) patches appeared below/around objects; in the editor the same locations show dark shadows.
**Diagnosis**: Extracted the magenta pixel colors → checked the def palette → indices 1/4/6/7 are exactly magenta placeholder colors.
**Conclusion**: Force-map them to semi-transparent black at render time (VCMI ScalableImage semantics); see formats.md §2.5.

## 3. Terrain def name mismatch with the LOD entry name

**Symptom**: Objects all correct, terrain all black (terrainHit=0/1296).
**Diagnosis**: Logs showed a non-empty missingDefs; the render key was the bare name "GRASTL" while the LOD entry was "GRASTL.DEF".
**Conclusion**: AssetLibrary appends a `.DEF` suffix to keys that lack a `.` during lookup (case-insensitive).

## 4. Negative modulo and check ordering for boundary frame indices

**Symptom**: Golden frames broken at the map's four corners; tiles like (-2,-1) drawn incorrectly.
**Diagnosis**: Cross-checked the VCMI getIndexForTile source: check "far outside the map" first, then edges; and Swift's `%` keeps the sign for negative operands (-2 % 4 = -2), so frame indices went negative.
**Conclusion**: Reorder the checks + `abs()`; see formats.md §5.

## 5. OOM / infinite loop caused by a corrupted def

**Symptom**: `--snapshot` occasionally failed with `failed to allocate 1.5e16 bytes` (OOM) or hung at 99% CPU.
**Diagnosis**: lldb + sample profiling: DefFile.init was stuck in the offsets loop; the root cause was upstream decompression failure producing garbage data → framesCount parsed as an astronomically large number.
**Conclusion**: Three layers of defense — groupsCount ≤ 64, framesCount ≤ 100k, frame dimensions 1..4096;
the legacy probe's "copy the whole byte stream per frame" was replaced with O(1) direct indexed reads (it was the root of the O(N²) hang).

## 6. MTKView does not present automatically (macOS desktop-level window)

**Symptom**: In GUI mode the window was entirely black, but the render loop was fine (draw count increasing, CPU usage normal).
**Diagnosis**: A red-screen test (setting clearColor to pure red) stayed black → ruled out drawing-content issues and pinned it on the drawable never being committed to the window surface.
**Conclusion**: Explicitly call `view.currentDrawable?.present()` before `draw(in:)` returns.
This is MTKView behavior under a specific configuration (no CAMetalLayer delegate involvement + a desktop-level window);
with the explicit present everything works.
**Note**: `screencapture -l<winid>` cannot get the contents of an occluded Metal window (black image);
use Quartz `CGWindowListCreateImage` for offscreen compositing, or temporarily raise the window to the floating level
(this repo keeps the `--level-floating` launch argument as a verification aid).

## 7. Screenshot verification methodology for occluded windows

A desktop wallpaper is naturally occluded by every application window. The verification chain:
1. **Headless CLI render** (`--snapshot`) to verify rendering correctness — compared tile-by-tile against the editor canvas;
2. **Quartz offscreen compositing** (`CGWindowListCreateImage` + `kCGWindowListOptionIncludingWindow`)
   to verify the real window's bitmap contents;
3. **Translucent menu bar screenshot**: the menu bar area is forced translucent by the system, so the wallpaper shows through in screenshots,
   as final evidence that "the wallpaper really renders at the desktop level";
4. `--level-floating` to temporarily raise the window for direct visual inspection (turned off after verification).

## 8. Browser-cached stale atlas causing "map edge anomalies" (Web version)

**Symptom**: Users reported that on the Web version the map edges (the out-of-map area) showed dark-green vegetation plus golden mottled textures; outside the L-shaped golden frame was not dark rock.
**Diagnosis**: Incognito mode (cache disabled) rendered the same view perfectly correctly, pixel-identical to the Swift version (diff 4.45);
and frames EDG 0-15 were verified by decoding to be pure gray-black rock tones (no green pixels, no high-saturation yellow) — they could not possibly produce the texture the user saw.
The root cause: the atlas generation logic changed during development, but the browser still held a cached copy of the old atlas PNG
(max-age=3600 was set at the time).
**Fix**: Fingerprint the atlas URL with content — `/atlas/<map>/level<L>-<mtime>-<frame count>-<object count>/atlas-N.png` —
and change the cache header to `immutable, max-age=31536000`: whenever the content changes the URL necessarily changes, so a stale atlas is never used;
the server stores directories per fingerprint, and old directories only waste disk, not correctness.
**Lesson**: Static assets produced by a build pipeline must use content-addressed URLs,
especially during development; otherwise any fix on the generation side gets "rolled back" by the browser cache.

## 9. Roads "broken at the joints" — wrong traversal target (lower half of roads missing)

**Symptom**: Roads were missing half a tile where they terminated downward — visually the road broke at tile edges; junctions were discontinuous.
**Diagnosis**: A line-by-line comparison with VCMI `MapRendererRoad::renderTile` revealed a traversal-semantics difference:
VCMI renders **every tile** in the viewport (this tile has no road but the tile above does → still draw the lower half of the upper tile's road image),
while my implementation only iterated tiles that have roads → tiles where "the tile above has a road but this one doesn't" were skipped.
601 tiles affected on the Viking map; 20602 tiles across 158 maps in total.
**Fix**: Changed the road layer to a double loop over viewport tiles (Swift `Renderer.swift` / JS `viewer.js` updated in sync).
**Lesson**: When porting a render loop, "which tiles to render" matters as much as "what to draw";
VCMI's per-tile renderTile model means every sub-renderer applies to all tiles,
skipping only the drawing when data is absent — not driving the traversal from data existence.

## 10. Atlas immutable-cache "poisoning" (Web, the most elusive)

**Symptom**: After fixing the atlas generation logic, developer verification passed (incognito/cleared cache), but in users' browsers it "still wasn't fixed" — half the map rendered wrong content (terrain displaced into dark colors).
**Root-cause chain**: The atlas URL only contained `map mtime - frame count - object count`. After the generation code changed, the same map's
frame/object counts could stay exactly the same → URL unchanged → while the atlas response header was
`Cache-Control: public, max-age=31536000, immutable` → the browser reused the old atlas [forever].
The scene JSON (no cache header) was new and the atlas was old → frame coordinates pointed at wrong content in the old atlas.
**Fix**: Appended a [server code fingerprint] to atlasVersion (the first 8 hex chars of the md5 over mtime+size of Scene/DefFile/H3m/Lod/Reader/Server) — any code change forces a URL change, and the cache invalidates automatically.
**Lesson**: The "content" of a content-addressed URL must cover **all inputs that affect the artifact** (data + code),
otherwise the immutable cache will "roll back" the fix. Always verify with both an incognito window and server-side content spot checks.

## 11. headless Chrome screenshots miss a fixed-size canvas (verification tooling pitfall)

**Symptom**: After giving the canvas a fixed CSS size (the `&win=WxH` automated comparison mode),
the canvas area in `--screenshot` output showed a dark ghost, while the page actually rendered correctly.
**Diagnosis**: POSTed `canvas.toDataURL()` from the page back to the server (canvas dump) for comparison —
the canvas content was perfectly correct (diff 5.25 vs Swift), proving it was a screenshot-pipeline issue rather than a rendering issue
(under virtual time, a fixed-size canvas's presentation timing is out of sync with the screenshot).
**Lesson**: headless screenshots may not match the page's real rendering; for automated canvas verification,
prefer `toDataURL` round-trips with screenshots as an auxiliary; fixed-viewport mode is only for precise alignment math.

## 12. Roads riding the tile gridlines — canvas semantics of frame margin

**Symptom**: Roads were offset by half a tile overall with stretched textures; road surfaces straddled the middle of two tile rows, misaligned with the terrain grid.
**Diagnosis**: Dumping the DIRTRD.DEF frame structure showed a 32×32 canvas with data carrying a margin (horizontal road 32×14@margin(0,9),
vertical road 14×32@margin(9,0)). When implementing the half-tile crop I treated VCMI's `Rect(0,16,32,16)` as **data coordinates**
(cropping the lower half of the data, 32×7, plus stretching), when it is **canvas coordinates** (the intersection of the canvas's lower half with the data).
**Fix**: Added canvas-space cropping (intersection) — mirror the canvas rectangle per the flip bits, intersect it with the data rectangle [ox,oy,w,h],
take the intersection's UVs directly from the atlas, and compute the screen position as tile origin + cropped-region origin + the intersection's offset within the cropped region.
Swift `Renderer.canvasCrop` / JS `viewer.drawFrameCanvas`; both ends verified the road row distribution offset as 0px.
**Lesson**: When a def frame's fullWidth/fullHeight differ from the data width/height (true for all roads),
any cropping/positioning must be done in canvas coordinates; all VCMI `Rect` parameters are canvas coordinates.

## 13. Byte reconciliation method for h3m parsing

The h3m format has many version-dependent sections; the way to localize parsing drift is **checkpoint byte offsets**:
record `reader.pos` at the end of each of the header/terrain/defs/objects sections and compare against the total file length.
- End of the terrain section = 1296 tiles × 7 bytes (36×36 map), directly verifiable;
- End of the objects section ≈ end of file (only small sections like events remain after it).
If any section's computed "next byte" fails to match the actual content (e.g. the defs section does not start with a plausible defCount),
you can localize the payload-skipping error to a specific object type. This project once used the method to discover that victory condition
case 3 skipped 1 byte too few (it should be 5 bytes: 3 coordinates + 2 parameters).

## 14. extTileFlags flip bits: bit0 = left-right mirror (VCMI names by "axis", not "direction")

**Symptom**: Coastlines showed blocky mis-joins (water transition frames with wrong orientation), and road corners/diagonal segments broke into dangling short strips.
The user observed "the texture would match if rotated 90°/180°" — in fact the mirror was applied backwards: on a 45° diagonal frame, swapping H/V mirrors
looks approximately like "rotated by 90°".

**Diagnosis**: VCMI `MapTileStorage::load` (MapRenderer.cpp) loads the same def into 4 slots:
slot 1 calls `verticalFlip()`, slot 2 calls `horizontalFlip()`, slot 3 both; at render time
`rotationIndex = extTileFlags % 4` (terrain) / `>>2` (river) / `>>4` (road) is used directly as the slot number.
Reading the names literally suggests "bit0 = up-down flip", but VCMI's `verticalFlip()` is **flip around the vertical axis = left-right mirror**.
Empirical method: take one tile (e.g. Viking map tile(94,28) dir=5 flags=0x2), exhaustively compare all 16 frames × 4 flips against vcmieditor's pixels for the same tile;
the only combination with 0.0 error = frame5 + up-down mirror ⇒ bit1 = up-down mirror,
bit0 = left-right mirror (consistent across the terrain/river/road layers, each verified down to zero error at pixel level against the editor).

**Fix**: `flipH = bits & 1`, `flipV = bits & 2` (same for all three layers).

**Lesson**: Function names in open-source code are the first-hand semantics you copy, but naming may follow axis or direction inconsistently;
whenever geometry orientation is involved, settle it in one shot with a pixel-level exhaustive reconciliation against real map tiles.

## 15. Sub-rectangle cropping with flips must "flip first, crop second"

**Symptom**: After the flip-bit semantics were corrected, straight roads were fully fine, but diagonal/corner roads still broke into two misaligned short strips.

**Diagnosis**: VCMI's order is — `MapTileStorage::load` first mirrors **the whole frame** into the 4 slots,
then `MapRendererRoad::renderTile` applies an ordinary `Rect(0,16,32,16)` crop to **the already-flipped image**.
Our `canvasCrop`/`drawFrameCanvas`, however, did "mirror the canvas rectangle + sample the unflipped data":
after mirroring the rectangle and intersecting with the data, the sampling coordinates did not follow the mirror, and no pixel mirroring was applied either. Straight road strips are left-right symmetric
(14px centered) and survived by luck; diagonal strips (22×22@(10,10)) land in a different quadrant when mirrored and broke immediately.

**Fix**: Rewrote in VCMI's order — mirror the **data rectangle** into flipped-canvas space and intersect there (the intersection coordinates are screen
coordinates), sample the unflipped atlas data, then: Metal mirrors UVs inside the quad via shader flags (canvasCrop
returns flags, replacing the previously hard-coded 0); Canvas2D wraps drawImage in `translate+scale(-1,1)`.
After the fix, same-tile error vs the editor is 0.0.

**Lesson**: `flip then crop` and `crop then flip` are equivalent for a **whole frame** but not for a **sub-rectangle**
(after mirroring, the rectangle's position relative to the data changes). When copying VCMI's homework, copy the entire pipeline — not just the crop formula.

## 16. Three kinds of measurement contamination in screen-level verification (differencing/template matching)

While building automated verification of "is the picture slowly moving" for the dynamic wallpaper, three pitfalls hit in a row:
1. **`screencapture` captures the whole screen** — foreground IDE/editor windows enter the frame, and the measured displacement actually belonged to the foreground window
   (static UI → phase correlation constant at 0.00 with response 0.999, deeply misleading).
   You must use `CGWindowListCreateImage` with the window ID to capture the target window itself.
2. **Template-matching false peaks on pixel art** — grass textures repeat periodically and the map has many identical-looking castles; a 400px template
   can produce a spurious "rigid displacement" with score≈1.0 at 100~200px offsets, and successive measurements contradicted each other.
   Anchors must be **isolated and unique** structures (e.g. the snow-mountain castle cluster, the arena), with consistency required across multiple points.
3. **Alignment direction/sign errors over and over**: np.roll's shift semantics are opposite to the direction of "content displacement"; work it out once
   with arrows on a small image before using it. Final closed loop: log viewLeft/viewTop, read one line before and after the screenshots,
   align the two frames by the logged delta × effZoom; the residual should contain only water/object animation.

## 17. Metal single instance buffer overwritten by the next frame → occasional one-frame wrong texture (flicker)

**Symptom**: The wallpaper occasionally flickered in small areas / showed white bars (captured once: a white horizontal bar appearing out of nowhere on the upper edge of a road), recovering after a single flash, at varying positions. The user described it as "like a texture error during refresh".

**Diagnosis**: `Renderer` had a single 12.8MB `instanceBuffer` (storageModeShared) +
`uniformBuffer`, overwritten each frame by a CPU `memcpy`, followed by a `draw(wait:false)` submission that **does not wait for the GPU**.
With tens of thousands of instances across the whole map plus overdraw, one GPU frame could take over 16.7ms — the next frame's memcpy would
overwrite the buffer while the GPU was still reading it, and the GPU read **torn data mixing old and new**: some quad's position/UV was the old frame's
first half + the new frame's second half, painting white texels from elsewhere in the atlas onto the road for one frame.

**Fix**: Apple's standard triple-buffer ring + semaphore back-pressure — 3 copies each of `instanceBuffers/uniformBuffers`,
a `DispatchSemaphore(value:3)` that waits at the start of draw() and signals in the command buffer's `addCompletedHandler`;
a slot is only reused after its command buffer completes. Building (buildFrame) only fills the CPU-side arrays and
pendingUniforms; the memcpy moved to after draw() selects the slot. Two renders of the same view should diff to 0
(any difference comes only from the randomElement of random object materialization; see GameMap).

**Lesson**: When `waitUntilCompleted` is absent (asynchronous submission), every CPU-side shared buffer overwritten per frame
must be grouped and reused by "frames in flight"; the symptom of such races is a **low-probability single-frame artifact**, hard to catch by screenshot or screen recording;
localize it by auditing "who writes before the GPU has finished reading".

## 18. Linear sampling must be paired with premultiplied alpha, or every sprite gets a faint outline

**Symptom**: After enabling GPU linear sampling for smooth scrolling, a faint dark outline appeared around monsters/buildings/roads
(absent in the real game). Reproducible from the user's screenshots.

**Diagnosis**: The atlas stored **straight alpha** (RGB not premultiplied); linear sampling interpolated between
the sprite's opaque edge and its transparent neighbor (RGB=0, A=0), producing transition pixels with halved RGB and halved A;
after sourceAlpha blending, the transition pixel was darker than both sides → a dark halo around every sprite's edge.
At zoom ≥2 each sprite edge necessarily lands mid-pixel, so the outline is constantly visible.

**Fix**: Premultiply at atlas write time (RGB×A/255) and change the blend mode to
`sourceRGB = ONE, destRGB = ONE_MINUS_SRC_ALPHA` (the standard premultiplied-compositing form).
Black shadow pixels (A=64/128, RGB=0) are unchanged by premultiplication — no visual regression.
The Web-exported PNG needs to be un-premultiplied back to straight alpha (this project's atlas shadows are all black, so visually indistinguishable).

**Lesson**: Decide the alpha-premultiplication strategy the moment you enable linear texture filtering; "dark edges from blending" is
the signature artifact of non-premultiplied + linear filtering.

## 21. h3m header parsing: the size field's offset is not 0

**Symptom**: Reading the h3m header (version, ?, size) with `struct.unpack("<iiI", raw)` produced an absurd size of one-to-two million
(far beyond the actual h3m map edge lengths of 36~144), scrambling all grouping/sorting.

**Diagnosis**: Cross-checked with Swift `H3mFile.swift` — the header is i32 version, **i8** hasPlayers, i32 size, i8 hasUnder.
Python must use `struct.unpack_from("<i", raw, 5)` (the i32 starts at offset 5, skipping the hasPlayers byte).

## 22. Cyan grid in the About dialog — color key not made transparent + box[8] mistaken for the interior background (dual root causes)

**Symptom**: The interior of the About dialog was covered in a cyan (0,255,255) grid; the original heroes3
dialog should be a brown paper background + a blue carved border. Straight from the user's screenshot.

**Diagnosis** (per-frame statistics + cross-checking three VCMI source files):
- Per-frame statistics over DIALGBOX's 11 frames: box[0..3] 59% cyan, box[8] 58%, box[4..7] 0%
  → the cyan concentrated in two places: "outside the border" and "inside the frame".
- `CBitmapHandler`/`CDefFile`: **cyan = the color at DEF palette index 0** (DIALGBOX's
  palette[0] is pure cyan), i.e. the color key; VCMI loads with `EImageBlitMode::COLORKEY` making idx0
  fully transparent. The export script's `colorKey` branch was never implemented at all (only shadows semantics existed), so color-key pixels
  were painted opaque cyan — this is "why the cyan is visible".
- `CMessage::drawBorder` (client/windows/CMessage.cpp): **draws only box[0..7]** (four corners
  box[0..3] + four edges: box[4/5] left/right 14×64, box[6/7] top/bottom 64×15); box[8..10] are not used;
  `CInfoWindow`'s interior background is `CFilledTexture("DiBoxBck")` (InfoWindows.cpp),
  and `showAll` tiles the **DIBOXBCK.PCX** brown-paper texture. Treating box[8] as the "9-slice interior" and tiling it was
  the first assumption taken for granted — box[8]'s interior is 58% color key, so tiling it necessarily produces a grid — this is "why the interior got covered".

**Fix**: Added the `colorKey` branch to `frame_to_rgba` (idx0 → alpha 0); added H3-style PCX
decoding (formats.md §2.8) and exported `background.png` from H3bitmap.lod; changed `Heroes3BorderView`
to background tiling + drawing only box[0..7]. Screenshot re-verification showed the brown background and blue border correct.

**Lessons**:
1. **There are two kinds of placeholder color** — the magenta family (255,0,255) occupies the shadow indices 1/4/6/7, while cyan (0,255,255)
   is the index-0 color key; UI sprites (COLORKEY mode) and object sprites (WITH_SHADOW mode) have different
   transparency semantics, and the export tool must branch on sprite type.
2. "9-slice" was imagination: VCMI's `drawBorder` assembles the frame from "4 corners + 4 edges" and tiles a separate
   texture for the interior; before copying a UI layout, read the rendering function itself — don't apply generic graphics folklore.
3. When a large area of "eerie solid color" appears, immediately check the palette index distribution (which index, what share);
   that is far faster than "tweak the code and see".

## 23. Black image from PNG export — missing per-scanline filter byte (write_png)

**Symptom**: PIL rejected the exported about PNG with `OSError: unrecognized data stream contents`; NSImage failed to decode, and the About window was entirely black/blank.
**Diagnosis**: The hand-written PNG's IDAT contained raw RGBA data directly. The PNG spec requires **one filter-type byte before every scanline**
(0x00=None suffices); if missing, the entire stream is invalid.
**Fix**: `append(0)` per line before concatenating that line's RGBA; `zlib.compress(..., 9)`.
**Lesson**: When hand-writing a PNG encoder, the filter byte is the easiest thing to miss; the symptom of omitting it is
"the decoder rejects it outright" rather than "the image is wrong". Using PIL `Image.open(...).load()` as an export self-check
(which also counts non-transparent pixels) catches it before packaging.

## 24. NSWindow content constraint crash — subview enters NSLayoutConstraint without addSubview

**Symptom**: `--about` crashed at launch with no window; running the binary directly showed
`NSGenericException: unable to satisfy constraints ... because they have no common ancestor`.
**Diagnosis**: `logoView` was only referenced by constraints (`logoView.centerXAnchor == centerXAnchor`);
`addSubview(logoView)` was missing — constraint pairs with no common ancestor throw on activate.
**Fix**: Added the missing `addSubview` before activating constraints (the labels loop already had it; only the logo was missed).
**Lesson**: AppKit has no "declare to attach" like SwiftUI; the NSView hierarchy accumulates imperatively —
addSubview first, then constraints. Crash logs of LSUIElement apps don't land in Console.app's
usual place; running the binary from the command line and watching stderr is fastest.

## 25. About border "corners misaligned" — border drawn in window coordinates instead of the expanded rectangle, and the window not on the 64px grid

**Symptom**: The four corner ornaments pointed the right way, but a ring of fallback color showed between the entire border and the window edges (it looked like "the border
doesn't fit the window"); an earlier version also had white-block broken bands at the top/side edge junctions.
**Root causes** (two layers):
1. VCMI BORDERED's border canvas is the content rectangle **expanded** by 14 left/right and 15 top/bottom
   (`CWindowObject::showAll`: `drawBorder(to, w+28, h+29, x-14, y-15)`).
   The first version drew the border in "content-relative coordinates" — `drawSDL`'s y conversion missed adding the background origin for horizontal edges,
   and the next version shrank everything inward instead — wrong in both directions, whose only visible result was "the border doesn't coincide with the window edges".
2. The window 508×409 (content 480×380 + 28/29) is not on the 64px grid: stepping 64px along the top/bottom edges fits only
   `(508-128)/64 = 5.9375` segments, leaving the tail uncovered → transparent gaps inside the border band, and a borderless
   window shows white straight through.
**Fix**:
- Draw the border with **the whole window as the canvas** (no more content-relative conversion), SDL top-left coordinates → NSView bottom-left:
  `nsY = winH - sdlY - frameH`; take the window size as **512×448 (a 128+64k grid)** — exactly 6 segments on top/bottom,
  5 left/right, one per corner, zero cropping, zero gaps, and VCMI's +1 gap-filler is no longer needed.
- First lay a dark-brown fallback color taken from DIBOXBCK across the whole window, then tile the content background, then stack the border —
  the texture's transparent (color-key) pixels no longer reveal the window's white background.
- Texture draws must use `.sourceOver`: `.copy` bitwise-replaces color-key transparent pixels, punching holes
  (same origin as pitfalls #22, but here it shows as "white blocks / background bleeding through" rather than cyan).
**Lesson**: To reproduce a VCMI layout, read `CWindowObject::showAll` first, not just `CMessage::drawBorder`
— **the rectangle passed by the caller is the truth**; the border texture's 64px step means the window size should align to the 64px
grid — arbitrary sizes only force gap-filling logic.

## 26. dmg only 2MB — the LOD was never bundled; rendering depended on the dev machine's vcmi directory

**Symptom**: The dmg was only 2MB. The user pointed out "the lod and maps must be bundled".
**Root cause**: `build_app.sh` bundled only 20 small maps (1MB) + the About PNG; `AppDelegate.dataDir`
and `main.defaultDataDir` hard-coded `~/Library/Application Support/vcmi/Data/H3sprite.lod`
— it ran on this machine only because VCMI was installed on the dev machine; on any other machine it went straight to `library FAILED` black screen.
**Fix**:
- `build_app.sh` copies `H3sprite.lod` (62MB, all terrain/object sprites) into
  `Resources/Data/`; if missing, it errors out and refuses to package (same for the maps directory).
- `dataDir`/`defaultDataDir` gained a bundled-first fallback chain: UserDefaults dataDir >
  **bundle Resources/Data/H3sprite.lod** > `~/Library/.../vcmi`.
- `pick_maps.py` limit parameters accept both bytes (`80MB`) and map count; full-set XL/L
  deduplicated copy of maps (38 maps, 3MB).
**Lesson**: An abnormally small package artifact is a strong signal that resources never made it in; self-contained distribution must be verified by
"still renders after wiping UserDefaults" (simulating a target machine without vcmi) — passing only on this machine doesn't count.

## 27. Wallpaper memory keeps growing (245→412MB) — DefFile cache and viewer scene cache grow without eviction

**Symptom**: After 4 hours of running, footprint grew from 245MB to 412MB; `sample` showed all threads idle
(not a CPU hotspot) — i.e. an accumulation that "increments on map change and never falls back", not a runtime leak.
**Root causes** (map-change cycle 15 minutes; +10MB per map matches the 4-hour growth):
1. **`AssetLibrary.cache` grows without eviction** (primary): `AtlasBuilder.build` stuffed every DEF
   (decompressed frame data) each map uses into the cache and never evicted on map change. def data is only needed while building the atlas
   (baked into 2048×2048 pixel atlases); after baking it is dead weight.
2. **`MapWebServer.cachedScene` never invalidated on map change**: it held full RGBA copies of the atlas pages
   (16MB per page); the old map's copies stayed resident until the next viewer request or the 30-minute idle shutdown.
**Fix**:
- `library.purgeDefCache()` at the end of `AtlasBuilder.build` — cleared as soon as the atlas is baked;
  on concurrent rebuild `def()` automatically re-reads the lod, costing only a redundant decompression, no correctness issue.
- `MapPresenter.onMapChanged` callback (wired in AppDelegate to
  `webServer.invalidateSceneCache()`); the old scene copy is invalidated on every map change.
- `MapPresenter.logFootprint(_:)` prints phys_footprint on every map ready,
  so long-run observation has data to check ("no logs means guessing blindly").
**Verification**: rotating 78 different maps at 30s intervals (about 40 minutes), footprint
min=286 / median=400 / max=612 MB, no monotonic growth; the residual fluctuation comes from atlas
size differences between maps and malloc pages not yet returned — normal.
**Lesson**: Use `sample` to rule out CPU hotspots first, then hunt for "collections that grow without eviction" —
in a long-lived app, every cache without an eviction policy becomes the slope of the memory curve.

## 28. Battery-mode strategy: from "1fps slow-down" to "fully stop rendering" (0fps)

**Original design**: On battery, 1fps + frozen camera (`camera.setFrozen`), re-checking power every 3 seconds in the draw callback.
**Problem**: a draw-callback-driven power check stops working once rendering pauses; and at 1fps the angel animation,
the map-change timer and jumps kept running — not "saving all the way".
**New design** (2026-09-08):
- `MapPresenter` holds an independent `powerCheckTimer` (60s interval, main loop common modes) —
  **the power re-check must never depend on the draw callback**, otherwise once rendering stops it can never detect the return of power;
- On battery detected: `renderView.isPaused = true` (stops MTKView's display-link timer too;
  early-returning from draw merely skips submission, and the timer would still wake up at the old frame rate) + `lastTimestamp = nil` (resets dt);
  the picture is fully static: no map change, no jumps; plugging in restores rendering and timing.
- `onBattery` became a `private(set)` cached value; draw only reads it, never clears it (the original 3s polling inside draw was deleted).
**Lesson**: Whenever a "state-driven load reduction" relies on the reduced path's own callback for its recovery check, the check must move
to an independent timer/event source; isPaused is the correct switch for stopping the display-link (preferredFramesPerSecond=0
doesn't work, and early-returning from draw doesn't save the timer wakeups either).
