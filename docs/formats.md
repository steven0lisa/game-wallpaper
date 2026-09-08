# HoMM3 文件格式调研笔记

本文档记录本项目对 Heroes of Might & Magic III 数据格式的全部逆向调研结论。
所有偏移与语义均已用本机真实文件（`H3sprite.lod`、VCMI 自带地图）字节级验证，
并与 VCMI 源码（`~/work/personal/vcmi`，v1.7.3）逐一核对。

> 格式权威参考：VCMI `lib/mapping/MapFormatH3M.cpp`、`client/render/CDefFile.cpp`、
> `lib/filesystem/CArchiveLoader.cpp`。

---

## 1. `.lod` 归档（H3sprite.lod / H3bitmap.lod）

| 偏移 | 大小 | 含义 |
|---|---|---|
| 0x00 | 4 | 魔数 `LOD\0` |
| 0x04 | 4 | 版本（观察到 0xC8） |
| 0x08 | 4 | 条目数 `N` |
| 0x0C | 0x50 | 未用区 |
| 0x5C | 32×N | 条目表 |

条目（32 字节）：`name[16]`（NUL 填充，大小写不敏感）、`offset u32`、`size u32`
（解压后大小）、`unused u32`、`compressedSize u32`。

- `compressedSize > 0` → 条目是 **raw deflate**（注意：**无** zlib 头，直接是 deflate 流；
  Apple `compression_decode_buffer` 用 `COMPRESSION_ZLIB` 时需先剥掉 zlib 头的两个字节才能对上——
  实测先探测 `0x78` 前缀再剥 2 字节即可兼容两种来源）。
- `compressedSize == 0` → 原样存储，读 `size` 字节。
- H3sprite.lod 共 4013 条目（2565 个 `.def`），是冒险地图渲染的唯一素材来源
  （地形 TIL 文件在 VCMI 中也以 DEF 形式从 lod 读取，仓库内不存在任何 `.til` 解析代码）。
- H3bitmap.lod 与 H3ab_bmp.lod 主要放 PCX/MSK 等界面素材；地图渲染不用它们，但
  **About 窗口的构建期导出需要 H3bitmap.lod**：`DIBOXBCK.PCX`（对话框内部纸底，§7）
  与 `DATA/PLAYERS.PAL`（玩家色表，§2.5）。

## 2. `.def` 精灵文件

### 2.1 文件头（小端）

```
u32 type        // 0x40 SPELL, 0x41 SPRITE, 0x42 CREATURE, 0x43 MAP, 0x44 MAP_HERO,
                // 0x45 TERRAIN, 0x46 CURSOR, 0x47 INTERFACE, 0x48 SPRITE_FRAME, 0x49 BATTLE_HERO
u32 fullWidth   // 整个动画的参考画布宽（单帧 def 中通常等于帧宽）
u32 fullHeight
u32 blockCount  // 块（组）数量
u8  palette[768]  // 256 × RGB，紧跟在 blockCount 之后！
```

**⚠️ 关键坑：调色板在 `blockCount` 之后**（即偏移 16），而不是文件头 4 个 u32 连读后。
块表从偏移 `16 + 768 = 784` 开始。APK 版参考实现（Kotlin）顺序读 4 个 u32 再读调色板，
等效但易误导移植者。

### 2.2 块表（每个块）

```
u32 blockID           // 组号；冒险地图物件 idle 动画 = 组 0
u32 totalEntries      // 帧数
u8  unknown[8]        // 8 字节未用（VCMI 注释 "8 unknown bytes - skipping"）
u8  frameNames[13*totalEntries]  // 帧名（如 "000.pcx"、"tgrd00.pcx"），不使用
u32 frameOffsets[totalEntries]   // 相对文件头的帧偏移
```

**⚠️ 关键坑：unknown 是 8 字节，不是 12。** jadx 反编译的 `Lod.java`/`Def.java` 数据类里
`unknown` 声明成长度 3 的数组（9 字节）+ 另一处偏移，极易读错。实测 GRASTL.DEF（79 帧）：
- unknown=8 → 79 个偏移全部落在文件内、帧头合法；
- unknown=12 → 偏移表整体左移一帧，第 0 帧渲染成第 1 帧且最后一帧越界读 0。

### 2.3 帧头（32 字节，位于帧偏移处）

```
u32 size          // 帧数据大小（压缩后）
u32 format        // 0-3 像素格式
u32 fullWidth     // 该帧画布宽
u32 fullHeight
u32 width         // 实际像素数据宽（<= fullWidth）
u32 height
u32 leftMargin    // 数据在画布中的 x 偏移
u32 topMargin     // y 偏移
u8  data[]        // 像素数据（调色板索引）
```

**Legacy 帧特例**（VCMI 注释：SGTWMTA.DEF / SGTWMTB.DEF 等旧格式）：
当 `format==1 && width>fullWidth && height>fullHeight` 时，实际是 16 字节帧头
（无 margin/size 字段），需 margin 清零、width/height 取 fullWidth/fullHeight、
数据起点回退 16 字节。APK 版用另一种启发式：逐帧检查 `帧偏移 + 32 + size` 是否超出
文件长度，超出则判 legacy —— 两种方法等价，本项目采用 APK 版启发式（更通用）。

### 2.4 四种像素格式

- **format 0**：无压缩，`width*height` 个索引直接读。
- **format 1**：行偏移表为 **u32 数组**（`height` 项，相对帧头 BaseOffset=32）；
  每行数据段：`type u8 + count u8`，`count` 实际长度为 `count+1`；
  `type==0xFF` → 后跟 count+1 个原始索引；否则 count+1 个像素全为 `type`。
- **format 2**：数据区起点 = `BaseOffset + read_u16(BaseOffset)`（首 u16 自指跳转）；
  无显式行表（数据顺序即行序）。段：`code = byte>>5`（0-6 RLE 索引色，7 原始数据），
  `length = (byte&31)+1`。
- **format 3**：与 2 相同的段编码，但行偏移表为 u16 数组，
  行 i 的表项位于 `BaseOffset + i*2*(width/32)`。

注意 format 2/3 的"code"只有 3 位（0-7），所以 RLE 只能展开索引 0-6 的纯色行，
索引 7 以上必须走原始数据段——这就是为什么很多 def 用 format 2。

### 2.5 调色板索引的固定语义（渲染时）

VCMI `client/renderSDL/ScalableImage.cpp`：

| 索引 | 含义 |
|---|---|
| 0 | 全透明 |
| 1 | 25% 黑阴影（alpha 64） |
| 2, 3 | 全透明（仅当与原始色一致时才有 alpha 64/128 的变体，实践中按透明处理） |
| 4 | 50% 黑阴影（alpha 128） |
| 5 | 玩家旗帜色（渲染时替换为玩家色） |
| 6 | 50% 选中色 |
| 7 | 25% 选中色 |

**⚠️ 关键坑：def 内嵌调色板的 1/4/6/7 号颜色是占位色（常见品红 255,0,255），必须强制替换成
半透明黑，否则物件阴影区域渲染成品红斑块。** APK 版的做法是转换前用 `fixedPalette`
（24 字节：索引 0-14 全 0，15-17 = 0x80,0x80,0x80）覆盖调色板头 8 项再交给 PngWriter 的
tRNS（transparent = `{0,64,0,0,128,255,128,64}`）。

三种 blit 模式（对应 VCMI EImageBlitMode）：
- **OPAQUE**：地形/边界，所有索引不透明；
- **COLORKEY**：河流/道路，仅索引 0 透明；
- **WITH_SHADOW**：物件，按上表语义。

### 2.6 调色板动画（paletteAnimation）

VCMI `config/terrains.json` / `rivers.json` 为部分 def 声明轮转区间
（帧计时 180ms/步，`MapRendererContext::terrainImageIndex`）：

| def | 区间 [start, length) |
|---|---|
| WATRTL | [229,12) + [242,12)（周期 12） |
| LAVATL | [246,9)（周期 9） |
| CLRRVR | [183,12) + [195,6) |
| MUDRVR | [228,12) + [183,6) + [240,6) |
| LAVRVR | [240,9) |

轮转公式（VCMI `shiftPalette`）：区间循环右移 d 位，
`new[(i+d) % len] = old[start+i]`。多区间时每步同时对所有区间轮转；
总周期 = 各区间长度的最小公倍数（水 = 12，泥河 = 12）。APK 版用另一种等价实现：
把调色板整体复制后反复 `rotatePalette` 直到回到原调色板（生成 N 个变体帧）。

### 2.7 玩家色占位段：调色板索引 224–255（32 色）

DEF 内嵌调色板的 **224–255 段是玩家色占位符**（界面精灵的边框/装饰色）。
VCMI `Graphics::setPlayerPalette`（client/render/Graphics.cpp）运行时用
`DATA/PLAYERS.PAL`（存于 H3bitmap.lod，1168 字节 = 4B 头 + 8 玩家 × 32 色 × 4B
BGRA，颜色数据从偏移 24 起）整体替换该段：

```
SDL_SetPaletteColors(targetPalette, palette, 224, 32)   // 8 玩家按序：红/蓝/棕/绿/橙/紫/青/粉
```

- 第 i 玩家 = PLAYERS.PAL 偏移 `24 + i*32*4` 起的 32 个 RGBA（每项第 4 字节是
  flags 非 alpha）。蓝方（i=1）实测深蓝系 `(19,31,64)…(40,65,139)…(108,122,163)`。
- **DIALGBOX.DEF 自带调色板的 224–255 段恰好就是蓝方这组渐变**（VCMI
  `CMessage::init` 注释 "assume blue color initially"、仅 `i != 1` 才重染），
  所以蓝框 UI 精灵直接用 def 内嵌调色板即得原版观感，无需 PLAYERS.PAL 重染；
  其余玩家色的 UI 才需要替换。
- 与 index 5（旗帜色）的区别：5 是**单色**玩家旗色，224–255 是 **32 阶渐变**
  的玩家色界面（边框立体感靠这组渐变）。
- 与 §2.5 品红占位色的区别：品红 (255,0,255) 系是 index 1/4/6/7 阴影位，
  青色 (0,255,255) 是 **index 0 的色键占位色**——DIALGBOX 的 index 0 调色板
  颜色就是纯青，box[0..3]/box[8] 内部约 58–59% 像素引用 idx0，全部是
  "待透明"区域（VCMI `EImageBlitMode::COLORKEY`）。导出工具若不处理色键，
  整片青色会被画成不透明（About 窗口首版"青色网格"即此坑，见 pitfalls #22）。

### 2.8 H3 式 PCX（lod 内的 .PCX，如 DIBOXBCK.PCX）

lod 里的 PCX **不是**标准 PCX 文件头（man/version/bpp 全为 0 的假头），是
H3 私有布局，解压后按 VCMI `CBitmapHandler::loadH3PCX`（client/render/
CBitmapHandler.cpp）解析：

```
解压后 blob:
u32 fSize     // 有效判定：== w*h → 8bit 索引模式；== w*h*3 → 24bit RGB 模式
u32 width
u32 height
u8  data[]    // 从偏移 0x0C 起。8bit 模式 = w*h 个调色板索引（逐行，无 RLE）；
              // 24bit 模式 = w*h*3 个 RGB 字节
u8  palette[768]  // 仅 8bit 模式：文件末尾 256×BGR 调色板（起始于 len-768）
```

- lod 条目本身 zlib 压缩（带 0x78 头，Python `zlib.decompress` 直接可用）；
  DIBOXBCK.PCX 解压后 66316 = 12 + 65536 + 768（256×256 的 8bit 图）。
- **index 0 = 色键透明**（VCMI 同样以 COLORKEY 语义加载 PCX）；DIBOXBCK 其余
  为棕色纸纹理（主色 `(116,75,42)` 系）——原版对话框 = 棕纸底 + 蓝边框
  （非深蓝底，见 rendering.md §9）。
- 24bit 模式无需调色板（代码里两分支都要保留，其他 PCX 有 24bit 的）。

## 3. `.h3m` 地图文件（RoE=14 / AB=21 / SoD=28）

整文件是 **gzip**（含 10 字节 gzip 头 + deflate + 8 字节 trailer）。

### 3.1 头部（按序）

```
u32 version                       // 14/21/28（HD 版 CHR=29 按 SoD 解析）
u8  hasPlayers
u32 mapSize                       // 边长（36/72/144）
u8  hasUnderground
str title                         // u32 长度 + UTF-8 字节，遇 NUL 截断
str description
u8  difficulty
u8  heroLevelLimit (RoE 无此字段)
-- 8 个玩家描述（下面字节数随版本变化，完整实现见 H3mFile.swift readPlayerInfo）
-- victory/loss 条件（missionType 0-10 各自字段数不同；victory==10 特殊）
-- team info: u8 count, count>0 时 8 字节队伍掩码
-- allowed heroes: RoE 16 字节 / AB+SoD 20 字节 + u32 长度 + 乱码字节
-- disposed heroes（仅 SoD）: u8 count, 每项 1+1+str+1
-- 31 字节占位（任意难度）
-- allowed artifacts: RoE 无 / AB 17 / SoD 18 字节
-- allowed spells 9 字节 + secondary skills 4 字节（仅 SoD）
-- rumors: u32 count, 每项 str+str
-- predefined heroes（仅 SoD）: 156 项，每项 u8 存在标志 + 条件子结构
```

### 3.2 地形段（z×y×x 顺序）

每格 7 字节：

| 字节 | 含义 |
|---|---|
| 0 | terrainType（0=dirt, 1=sand, 2=grass, 3=snow, 4=swamp, 5=rough, 6=subterranean, 7=lava, 8=water, 9=rock） |
| 1 | terView（地形 DEF 内的帧索引，0-78 不等，**客户端不做任何邻域计算，直接查帧**） |
| 2 | riverType（0=无, 1=clear, 2=ice, 3=mud, 4=lava） |
| 3 | riverDir（河流 DEF 帧索引） |
| 4 | roadType（0=无, 1=dirt, 2=gravel, 3=cobblestone） |
| 5 | roadDir（道路 DEF 帧索引） |
| 6 | extTileFlags：bit0-1 地形翻转，bit2-3 河流翻转，bit4-5 道路翻转，bit6 coastal，bit7 favorable winds |

翻转位含义（VCMI MapTileStorage 加载 4 份翻转副本）：0=原图，1=垂直翻转，
2=水平翻转，3=双向翻转。（VCMI 用 `%4` 取位；APK 版用 mirrorConfig 的
bit0/1→地形、bit2/3→河流、bit4/5→道路，语义一致。）

`terrainViewPatterns.json` 中的 3×3 邻域 pattern **只在地图编辑器/RMG 写图时使用**
（`CDrawTerrainOperation::updateTerrainViews`），渲染端完全不参与。

### 3.3 def 表

```
u32 defCount
每项:
  str spriteName            // 如 "AVLwind0.def"
  u32+u16 passableCells     // 掩码+行数（渲染不用）
  u32+u16 activeCells
  u16 terrainType           // 可放置地形
  u16 terrainGroup
  u32 objectId              // 对象类型（VCMI Obj 枚举，见下）
  u32 objectClassSubId      // 子类型（城镇阵营/资源种类…）
  u8  objectsGroup          // 编辑器分类
  u8  placementOrder        // 渲染排序用优先级
  u8  placeholder[16]
```

### 3.4 对象段

```
u32 objectCount
每项:
  u8 x, u8 y, u8 z          // anchor 格坐标
  u32 defIndex              // 指向 def 表
  u8  reserved[5]           // 恒 0（VCMI skipZero(5)）
  ...按 objectId 分派的 payload（见下）...
```

**⚠️ 大多数对象类型 payload 为 0 字节。** 需要读数据的高频类型（完整表见
`Sources/Heroes3Wallpaper/H3mFile.swift skipObjectPayload`，已与 VCMI 逐 case 核对）：

| objectId | 类型 | payload |
|---|---|---|
| 26 | event | messageAndGuards + 7×u32 资源 + 掩码 + creatures + …（约 45+ 字节） |
| 34/70/62 | hero/random hero/prison | 英雄全量（技能/兵种/宝物/传记，~50-200 字节） |
| 54/71/72-75/162-164 | monster + 随机怪 L1-L7 | identifier(u32, AB+) + count(u16) + character + 可选 message + 2 字节 |
| 59/91 | ocean bottle/sign | str + 4 |
| 83 | seer hut | quest + reward |
| 6 | pandora's box | 同 event 结构 |
| 5/65-69/93 | artifact/随机宝物/卷轴 | messageAndGuards（卷轴 +u32 法术） |
| 76/79 | 随机资源/资源 | messageAndGuards + u32 数量 + 4 |
| 77/98 | 随机城镇/城镇 | 城镇全量（建筑/驻军/事件列表） |
| 53/220/17-20/88-90/87/42/36 | 矿/废矿/兵营/神龛/船坞/灯塔/圣杯 | **恒 4 字节**（owner u32） |
| 33/219 | garrison | owner+驻军+8 |
| 216-218 | random dwelling | 4 + 条件 faction 掩码/等级 |
| 214 | hero placeholder | 1-2 |
| 215 | quest guard | quest |

**⚠️ 坑：随机怪 L5/L6 的 ID 是 162/163**（不是 APK 反编译里看到的 160/161——那是
libGDX 按键常量 `NUMPAD_*` 的数值，jadx 把 `Input.Keys.NUMPAD_LEFT_PAREN` 直接内联了）。
160/161 实际是 YUCCA_TREES/REEF（无 payload 的装饰物）。VCMI 权威枚举见
`lib/constants/EntityIdentifiers.h` Obj 节。

### 3.5 地图尾部

对象段之后还有 events（地图事件）等段，本项目不读；解析以对象段结束为完成点，
但用 checkpoints（header/terrain/defs/objects 的字节偏移）做健康检查。

## 4. 对象渲染的定位与排序

- **画布锚定**：物件 def 的 `fullWidth×fullHeight` 画布**右下角**对齐 anchor 格的右下角：
  `canvasLeft = (x+1)*32 - fullWidth`，`canvasTop = (y+1)*32 - fullHeight`；
  帧数据再按 leftMargin/topMargin 内偏移。APK 版 Sprite 的
  `getFrameX = (x+1)*32 + offsetX - originalWidth` 与此等价。
- **帧动画**：组 0 帧序列循环，180ms/帧；VCMI 用 `objectID` 做相位偏移防同步，
  APK 用随机初始 stateTime，本项目用 `phase += 7` 步进错相。
- **排序**（APK compareTo，即 H3 渲染序）：
  1. placementOrder 大者先画（更靠后）；
  2. y 小者先画；
  3. 同格英雄最后画（画在最上）；
  4. x 小者先画；
  5. 保持 h3m 文件顺序。
  VCMI 的完整版还有遮挡计数与 printPriority，对静态壁纸场景 APK 简化版已够用。
- **随机物件具象化**（编辑器里的问号物件渲染成具体外观）：
  随机怪→对应等级随机怪 def（AVW* 系列）、随机宝物→`ava%04d`（等级段随机）、
  随机资源→7 种资源 def、随机城镇→按阵营 town/village def、随机 dwelling→AVG* 系列。
  完整映射表见 `GameMap.swift resolvedSpriteName`（移植自 APK ObjectsRandomizer）。

## 5. 边界（EDG.DEF，36 帧）

VCMI `MapRendererBorder::getIndexForTile`（顺序不可换）：

```
若 x < -1 || x > size || y < -1 || y > size:   // 图外远处
    abs(x)%4 + 4*(abs(y)%4)                     // 0-15 暗岩图案
若 (x,y) == (-1,-1) → 16; (size,-1) → 17; (size,size) → 18; (-1,size) → 19   // 四角
若 y == -1  → 20 + x%4     // 上边金框
若 x == size → 24 + y%4    // 右
若 y == size → 28 + x%4    // 下
若 x == -1  → 32 + y%4     // 左
```

**⚠️ 坑：必须先判"图外远处"再判边缘环**，否则 (-2,-1) 这类格子会命中 `y==-1`
分支且负数取模产生负帧号。Swift 的 `%` 保留符号，须 `abs()`。

## 6. 地图内固定资源

- 地形 def 名（terView 查此表）：`DIRTTL/SANDTL/GRASTL/SNOWTL/SWMPTL/ROUGTL/SUBBTL/LAVATL/WATRTL/ROCKTL`
- 河流：`CLRRVR/ICYRVR/MUDRVR/LAVRVR`；道路：`DIRTRD/GRAVRD/COBBRD`
- 边界：`EDG`
- 全部位于 H3sprite.lod；lod 条目名带 `.DEF` 后缀且大小写不敏感（**渲染键用裸名，
  查找时需补后缀**——本项目的实现坑之一）。
