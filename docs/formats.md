English | [中文](zh-CN/formats.md)

# HoMM3 File Format Research Notes

This document records all of the reverse-engineering conclusions on the Heroes of Might & Magic III data formats made by this project.
All offsets and semantics have been verified at byte level against real local files (`H3sprite.lod`, VCMI-bundled maps),
and cross-checked one by one against the VCMI source code (`~/work/personal/vcmi`, v1.7.3).

> Authoritative format references: VCMI `lib/mapping/MapFormatH3M.cpp`, `client/render/CDefFile.cpp`,
> `lib/filesystem/CArchiveLoader.cpp`.

---

## 1. `.lod` archives (H3sprite.lod / H3bitmap.lod)

| Offset | Size | Meaning |
|---|---|---|
| 0x00 | 4 | Magic number `LOD\0` |
| 0x04 | 4 | Version (observed: 0xC8) |
| 0x08 | 4 | Entry count `N` |
| 0x0C | 0x50 | Unused region |
| 0x5C | 32×N | Entry table |

Entry (32 bytes): `name[16]` (NUL-padded, case-insensitive), `offset u32`, `size u32`
(size after decompression), `unused u32`, `compressedSize u32`.

- `compressedSize > 0` → the entry is **raw deflate** (note: **no** zlib header; it is a bare deflate stream.
  When using Apple `compression_decode_buffer` with `COMPRESSION_ZLIB`, the two zlib header bytes must be stripped first for it to match —
  in practice, probing for the `0x78` prefix and then stripping 2 bytes makes both sources compatible).
- `compressedSize == 0` → stored as-is; read `size` bytes.
- H3sprite.lod has 4013 entries in total (2565 `.def` files) and is the sole asset source for adventure map rendering
  (terrain TIL files are also read from the lod as DEFs in VCMI; the repository contains no `.til` parsing code at all).
- H3bitmap.lod and H3ab_bmp.lod mainly hold UI assets such as PCX/MSK; map rendering does not use them, but
  **the build-time export of the About window needs H3bitmap.lod**: `DIBOXBCK.PCX` (the paper background inside the dialog box, §7)
  and `DATA/PLAYERS.PAL` (the player color table, §2.5).

## 2. `.def` sprite files

### 2.1 File header (little-endian)

```
u32 type        // 0x40 SPELL, 0x41 SPRITE, 0x42 CREATURE, 0x43 MAP, 0x44 MAP_HERO,
                // 0x45 TERRAIN, 0x46 CURSOR, 0x47 INTERFACE, 0x48 SPRITE_FRAME, 0x49 BATTLE_HERO
u32 fullWidth   // Reference canvas width of the whole animation (in single-frame defs usually equals the frame width)
u32 fullHeight
u32 blockCount  // Number of blocks (groups)
u8  palette[768]  // 256 × RGB, immediately after blockCount!
```

**⚠️ Key pitfall: the palette comes after `blockCount`** (i.e. at offset 16), not after reading the file header as 4 consecutive u32s.
The block table starts at offset `16 + 768 = 784`. The APK reference implementation (Kotlin) reads the 4 u32s in sequence and then the palette,
which is equivalent but can easily mislead porters.

### 2.2 Block table (per block)

```
u32 blockID           // Group number; the adventure map object idle animation = group 0
u32 totalEntries      // Number of frames
u8  unknown[8]        // 8 unused bytes (VCMI comment "8 unknown bytes - skipping")
u8  frameNames[13*totalEntries]  // Frame names (e.g. "000.pcx", "tgrd00.pcx"), unused
u32 frameOffsets[totalEntries]   // Frame offsets relative to the file header
```

**⚠️ Key pitfall: unknown is 8 bytes, not 12.** In the jadx-decompiled `Lod.java`/`Def.java` data classes,
`unknown` is declared as an array of length 3 (9 bytes) plus another offset elsewhere — very easy to misread. Verified on GRASTL.DEF (79 frames):
- unknown=8 → all 79 offsets land inside the file with valid frame headers;
- unknown=12 → the offset table shifts left by one frame as a whole: frame 0 renders as frame 1, and the last frame reads 0 out of bounds.

### 2.3 Frame header (32 bytes, located at the frame offset)

```
u32 size          // Frame data size (after compression)
u32 format        // 0-3 pixel format
u32 fullWidth     // Canvas width of this frame
u32 fullHeight
u32 width         // Actual pixel data width (<= fullWidth)
u32 height
u32 leftMargin    // x offset of the data within the canvas
u32 topMargin     // y offset
u8  data[]        // Pixel data (palette indices)
```

**Legacy frame special case** (VCMI comment: legacy formats such as SGTWMTA.DEF / SGTWMTB.DEF):
when `format==1 && width>fullWidth && height>fullHeight`, it is actually a 16-byte frame header
(no margin/size fields); the margins must be zeroed, width/height taken from fullWidth/fullHeight,
and the data start rolled back by 16 bytes. The APK version uses a different heuristic: check per frame whether
`frameOffset + 32 + size` exceeds the file length, and treat it as legacy if it does — the two methods are equivalent; this project adopts the APK heuristic (more general).

### 2.4 The four pixel formats

- **format 0**: no compression; `width*height` indices are read directly.
- **format 1**: the row offset table is a **u32 array** (`height` entries, relative to the frame header BaseOffset=32);
  each row's data segment: `type u8 + count u8`, where the actual length is `count+1`;
  `type==0xFF` → followed by count+1 raw indices; otherwise count+1 pixels all equal `type`.
- **format 2**: the data area starts at `BaseOffset + read_u16(BaseOffset)` (the first u16 is a self-referencing jump);
  no explicit row table (data order is row order). Segment: `code = byte>>5` (0-6 RLE index color, 7 raw data),
  `length = (byte&31)+1`.
- **format 3**: the same segment encoding as 2, but the row offset table is a u16 array;
  the entry for row i sits at `BaseOffset + i*2*(width/32)`.

Note that the "code" of format 2/3 has only 3 bits (0-7), so RLE can only expand solid-color rows of indices 0-6;
indices 7 and above must go through raw data segments — that is why many defs use format 2.

### 2.5 Fixed semantics of palette indices (at render time)

VCMI `client/renderSDL/ScalableImage.cpp`:

| Index | Meaning |
|---|---|
| 0 | Fully transparent |
| 1 | 25% black shadow (alpha 64) |
| 2, 3 | Fully transparent (alpha 64/128 variants exist only when they match the original color; in practice treated as transparent) |
| 4 | 50% black shadow (alpha 128) |
| 5 | Player flag color (replaced with the player color at render time) |
| 6 | 50% selection color |
| 7 | 25% selection color |

**⚠️ Key pitfall: colors 1/4/6/7 in a def's embedded palette are placeholder colors (commonly magenta 255,0,255) and must be forcibly replaced with
semi-transparent black, otherwise object shadow areas render as magenta blocks.** The APK version, before conversion, overwrites the first 8 palette entries with `fixedPalette`
(24 bytes: indices 0-14 all 0, 15-17 = 0x80,0x80,0x80) and then hands it to the PngWriter's
tRNS (transparent = `{0,64,0,0,128,255,128,64}`).

Three blit modes (corresponding to VCMI EImageBlitMode):
- **OPAQUE**: terrain/EDG border, all indices opaque;
- **COLORKEY**: rivers/roads, only index 0 transparent;
- **WITH_SHADOW**: objects, following the semantics of the table above.

### 2.6 Palette animation (paletteAnimation)

VCMI `config/terrains.json` / `rivers.json` declare rotation ranges for some defs
(frame timing 180ms/step, `MapRendererContext::terrainImageIndex`):

| def | Ranges [start, length) |
|---|---|
| WATRTL | [229,12) + [242,12) (period 12) |
| LAVATL | [246,9) (period 9) |
| CLRRVR | [183,12) + [195,6) |
| MUDRVR | [228,12) + [183,6) + [240,6) |
| LAVRVR | [240,9) |

Rotation formula (VCMI `shiftPalette`): each range is cyclically rotated right by d positions,
`new[(i+d) % len] = old[start+i]`. With multiple ranges, all of them rotate simultaneously at every step;
the total period = the least common multiple of the range lengths (water = 12, mud river = 12). The APK version uses another equivalent implementation:
copying the whole palette and calling `rotatePalette` repeatedly until it returns to the original palette (generating N variant frames).

### 2.7 Player color placeholder segment: palette indices 224–255 (32 colors)

The **224–255 segment of a DEF's embedded palette is a player color placeholder** (border/decoration colors of UI sprites).
At runtime, VCMI `Graphics::setPlayerPalette` (client/render/Graphics.cpp) replaces that segment wholesale with
`DATA/PLAYERS.PAL` (stored in H3bitmap.lod, 1168 bytes = 4B header + 8 players × 32 colors × 4B
BGRA, color data starting at offset 24):

```
SDL_SetPaletteColors(targetPalette, palette, 224, 32)   // 8 players in order: red/blue/tan/green/orange/purple/teal/pink
```

- Player i = the 32 RGBA entries starting at PLAYERS.PAL offset `24 + i*32*4` (the 4th byte of each entry is
  flags, not alpha). Blue (i=1) measured as deep-blue tones `(19,31,64)…(40,65,139)…(108,122,163)`.
- **The 224–255 segment of DIALGBOX.DEF's own palette happens to be exactly this blue gradient** (VCMI
  `CMessage::init` comment "assume blue color initially"; only `i != 1` gets re-tinted),
  so blue-box UI sprites can use the def's embedded palette directly and still get the original look, with no PLAYERS.PAL re-tint;
  only UI for the other player colors needs the replacement.
- Difference from index 5 (flag color): 5 is a **single-color** player flag color, while 224–255 is a **32-step gradient**
  of player-colored UI (the 3D feel of the borders comes from this gradient).
- Difference from the magenta placeholder colors in §2.5: the magenta (255,0,255) family occupies the index 1/4/6/7 shadow slots,
  while cyan (0,255,255) is the **color key placeholder color of index 0** — DIALGBOX's index 0 palette
  color is pure cyan, and about 58–59% of the pixels inside box[0..3]/box[8] reference idx0, all of them
  "to-be-transparent" areas (VCMI `EImageBlitMode::COLORKEY`). If the export tool does not handle the color key,
  whole cyan areas get painted opaque (the "cyan grid" in the first version of the About window was exactly this pitfall, see pitfalls #22).

### 2.8 H3-style PCX (.PCX inside the lod, e.g. DIBOXBCK.PCX)

The PCX files inside the lod are **not** the standard PCX file header (a fake header with man/version/bpp all 0); they use an
H3-private layout, parsed after decompression per VCMI `CBitmapHandler::loadH3PCX` (client/render/
CBitmapHandler.cpp):

```
Decompressed blob:
u32 fSize     // Validity check: == w*h → 8bit index mode; == w*h*3 → 24bit RGB mode
u32 width
u32 height
u8  data[]    // Starting at offset 0x0C. 8bit mode = w*h palette indices (row by row, no RLE);
              // 24bit mode = w*h*3 RGB bytes
u8  palette[768]  // 8bit mode only: a 256×BGR palette at the end of the file (starting at len-768)
```

- The lod entry itself is zlib-compressed (with a 0x78 header; Python `zlib.decompress` works directly);
  DIBOXBCK.PCX decompresses to 66316 = 12 + 65536 + 768 (an 8bit 256×256 image).
- **index 0 = color key transparency** (VCMI likewise loads PCX with COLORKEY semantics); the rest of DIBOXBCK
  is a brown paper texture (dominant color in the `(116,75,42)` family) — the original dialog box = brown paper background + blue border
  (not a dark-blue background, see rendering.md §9).
- The 24bit mode needs no palette (keep both branches in the code; some other PCX files are 24bit).

## 3. `.h3m` map files (RoE=14 / AB=21 / SoD=28)

The whole file is **gzip** (a 10-byte gzip header + deflate + an 8-byte trailer).

### 3.1 Header (in order)

```
u32 version                       // 14/21/28 (HD edition CHR=29 parsed as SoD)
u8  hasPlayers
u32 mapSize                       // Edge length (36/72/144)
u8  hasUnderground
str title                         // u32 length + UTF-8 bytes, truncated at NUL
str description
u8  difficulty
u8  heroLevelLimit (absent in RoE)
-- 8 player descriptions (byte counts below vary by version; for the full implementation see H3mFile.swift readPlayerInfo)
-- victory/loss conditions (missionType 0-10, each with a different field count; victory==10 is special)
-- team info: u8 count; when count>0, an 8-byte team mask
-- allowed heroes: RoE 16 bytes / AB+SoD 20 bytes + u32 length + garbage bytes
-- disposed heroes (SoD only): u8 count, each entry 1+1+str+1
-- 31 placeholder bytes (any difficulty)
-- allowed artifacts: none in RoE / AB 17 / SoD 18 bytes
-- allowed spells 9 bytes + secondary skills 4 bytes (SoD only)
-- rumors: u32 count, each entry str+str
-- predefined heroes (SoD only): 156 entries, each a u8 presence flag + a conditional substructure
```

### 3.2 Terrain section (z×y×x order)

Each tile is 7 bytes:

| Byte | Meaning |
|---|---|
| 0 | terrainType (0=dirt, 1=sand, 2=grass, 3=snow, 4=swamp, 5=rough, 6=subterranean, 7=lava, 8=water, 9=rock) |
| 1 | terView (frame index into the terrain DEF, ranging 0-78; **the client does no neighborhood computation at all and looks the frame up directly**) |
| 2 | riverType (0=none, 1=clear, 2=ice, 3=mud, 4=lava) |
| 3 | riverDir (frame index into the river DEF) |
| 4 | roadType (0=none, 1=dirt, 2=gravel, 3=cobblestone) |
| 5 | roadDir (frame index into the road DEF) |
| 6 | extTileFlags: bit0-1 terrain flip, bit2-3 river flip, bit4-5 road flip, bit6 coastal, bit7 favorable winds |

Flip bit meanings (VCMI MapTileStorage loads 4 flipped copies): 0=original, 1=vertical flip,
2=horizontal flip, 3=flip both. (VCMI extracts the bits with `%4`; the APK version uses
mirrorConfig's bit0/1→terrain, bit2/3→river, bit4/5→road — semantically identical.)

The 3×3 neighborhood patterns in `terrainViewPatterns.json` are **only used when the map editor/RMG writes maps**
(`CDrawTerrainOperation::updateTerrainViews`); the rendering side does not participate at all.

### 3.3 def table

```
u32 defCount
per entry:
  str spriteName            // e.g. "AVLwind0.def"
  u32+u16 passableCells     // mask + row count (unused by rendering)
  u32+u16 activeCells
  u16 terrainType           // placeable terrain
  u16 terrainGroup
  u32 objectId              // Object type (VCMI Obj enum, see below)
  u32 objectClassSubId      // Subtype (town faction / resource kind…)
  u8  objectsGroup          // Editor category
  u8  placementOrder        // Priority used for render ordering
  u8  placeholder[16]
```

### 3.4 Objects section

```
u32 objectCount
per entry:
  u8 x, u8 y, u8 z          // Anchor tile coordinates
  u32 defIndex              // Points into the def table
  u8  reserved[5]           // Always 0 (VCMI skipZero(5))
  ...payload dispatched by objectId (see below)...
```

**⚠️ Most object types have a 0-byte payload.** High-frequency types that do carry data (for the full table see
`Sources/Heroes3Engine/H3mFile.swift skipObjectPayload`, already cross-checked case by case against VCMI):

| objectId | Type | Payload |
|---|---|---|
| 26 | event | messageAndGuards + 7×u32 resources + mask + creatures + … (about 45+ bytes) |
| 34/70/62 | hero/random hero/prison | Full hero data (skills/stacks/artifacts/biography, ~50-200 bytes) |
| 54/71/72-75/162-164 | monster + random monsters L1-L7 | identifier(u32, AB+) + count(u16) + character + optional message + 2 bytes |
| 59/91 | ocean bottle/sign | str + 4 |
| 83 | seer hut | quest + reward |
| 6 | pandora's box | Same structure as event |
| 5/65-69/93 | artifact/random artifact/scroll | messageAndGuards (scroll additionally +u32 spell) |
| 76/79 | random resource/resource | messageAndGuards + u32 amount + 4 |
| 77/98 | random town/town | Full town data (buildings/garrison/event lists) |
| 53/220/17-20/88-90/87/42/36 | mine/abandoned mine/creature generator/shrine/shipyard/lighthouse/grail | **Always 4 bytes** (owner u32) |
| 33/219 | garrison | owner + garrison + 8 |
| 216-218 | random dwelling | 4 + conditional faction mask/level |
| 214 | hero placeholder | 1-2 |
| 215 | quest guard | quest |

**⚠️ Pitfall: the IDs of random monsters L5/L6 are 162/163** (not the 160/161 seen in the APK decompilation — those are
the values of the libGDX key constants `NUMPAD_*`; jadx inlined `Input.Keys.NUMPAD_LEFT_PAREN` directly).
160/161 are actually YUCCA_TREES/REEF (decorations with no payload). The authoritative VCMI enum is in
the Obj section of `lib/constants/EntityIdentifiers.h`.

### 3.5 Map tail

After the objects section come further sections such as events (map events), which this project does not read; parsing is considered complete at the end of the objects section,
but checkpoints (byte offsets of header/terrain/defs/objects) are used for health checks.

## 4. Object rendering: positioning and ordering

- **Canvas anchoring**: the **bottom-right corner** of an object def's `fullWidth×fullHeight` canvas aligns with the bottom-right corner of the anchor tile:
  `canvasLeft = (x+1)*32 - fullWidth`, `canvasTop = (y+1)*32 - fullHeight`;
  frame data is then offset within by leftMargin/topMargin. The APK Sprite's
  `getFrameX = (x+1)*32 + offsetX - originalWidth` is equivalent to this.
- **Frame animation**: the group 0 frame sequence loops at 180ms per frame; VCMI uses `objectID` as a phase offset to avoid desync,
  the APK uses a random initial stateTime, and this project uses `phase += 7` stepping to stagger the phases.
- **Ordering** (APK compareTo, i.e. the H3 render order):
  1. larger placementOrder draws first (further back);
  2. smaller y draws first;
  3. heroes on the same tile draw last (painted on top);
  4. smaller x draws first;
  5. otherwise keep h3m file order.
  VCMI's full version also has occlusion counting and printPriority; for a static wallpaper scene the APK simplified version is sufficient.
- **Concretization of random objects** (question-mark objects in the editor rendered with a concrete appearance):
  random monster → the random monster def of the corresponding level (AVW* series), random artifact → `ava%04d` (random within the level band),
  random resource → one of the 7 resource defs, random town → town/village def by faction, random dwelling → AVG* series.
  The full mapping table is in `GameMap.swift resolvedSpriteName` (ported from APK ObjectsRandomizer).

## 5. EDG border (EDG.DEF, 36 frames)

VCMI `MapRendererBorder::getIndexForTile` (the order of the checks must not be changed):

```
If x < -1 || x > size || y < -1 || y > size:   // far outside the map
    abs(x)%4 + 4*(abs(y)%4)                     // 0-15 dark rock pattern
If (x,y) == (-1,-1) → 16; (size,-1) → 17; (size,size) → 18; (-1,size) → 19   // four corners
If y == -1  → 20 + x%4     // top gold frame
If x == size → 24 + y%4    // right
If y == size → 28 + x%4    // bottom
If x == -1  → 32 + y%4     // left
```

**⚠️ Pitfall: the "far outside the map" check must come before the edge-ring checks**, otherwise tiles like (-2,-1) hit the `y==-1`
branch and negative modulo produces negative frame numbers. Swift's `%` keeps the sign, so `abs()` is required.

## 6. Fixed map assets

- Terrain def names (terView indexes into this table): `DIRTTL/SANDTL/GRASTL/SNOWTL/SWMPTL/ROUGTL/SUBBTL/LAVATL/WATRTL/ROCKTL`
- Rivers: `CLRRVR/ICYRVR/MUDRVR/LAVRVR`; roads: `DIRTRD/GRAVRD/COBBRD`
- EDG border: `EDG`
- All of them live in H3sprite.lod; lod entry names carry a `.DEF` suffix and are case-insensitive (**render keys use the bare name,
  the suffix must be appended at lookup** — one of this project's implementation pitfalls).
