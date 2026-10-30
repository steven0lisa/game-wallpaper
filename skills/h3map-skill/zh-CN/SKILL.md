# h3map-skill：HoMM3 地图解析与渲染·可移植实现指南

本指南是「用任意语言（Rust/Go/C++/Swift…）重新实现 HoMM3 冒险地图渲染」的施工
路线图。它给出经本仓库三套独立渲染器（macOS Metal / web Canvas / Android GLES2）
逐像素互证的**不可妥协语义**，以及耗费最多调试时间的坑。字节级布局见
[`docs/formats.md`](../../../docs/zh-CN/formats.md)；绘制顺序语义见
[`docs/rendering.md`](../../../docs/zh-CN/rendering.md)；完整踩坑日志见
[`docs/pitfalls.md`](../../../docs/zh-CN/pitfalls.md)。

[English](../SKILL.md) | 中文

---

## 0. 五种产物

| 产物 | 是什么 | 用途 |
|---|---|---|
| `H3sprite.lod` | zlib 压缩的精灵归档 | 全部视觉资源 |
| `*.def` | 索引色精灵（帧 + 调色板） | 地形瓦片、物件、道路 |
| `*.h3m` | gzip 压缩的地图（版本 14/21/28/29 = RoE/AB/SoD/HotA） | 地形布局、物件放置 |
| scene | 内存场景：图层单元 → 帧 id | 解耦解析与绘制 |
| atlas | 解码帧打包的 RGBA 图集页 | GPU 上传 |

按依赖顺序实现：**LOD → DEF → h3m → scene → atlas → renderer**。
每一级都可对上一级独立测试。

## 1. LOD 读取

索引表 → 条目 `{ name, uncompressedSize, compressedSize, type }`；
载荷为原始或 zlib。无坑。见 formats.md §1。

## 2. DEF 解码

文件头：`type, fullWidth, fullHeight, groupsCount, palette[768]`。
每组：`groupType, framesCount, unknown[8], filenames[13×n], offsets[n]`。
偏移处每帧：`size, compression, fullW, fullH, w, h, x, y`，后接像素。

核心概念——**帧不只是像素**：

```
帧 = 数据矩形（w×h 像素）放置在逻辑画布 (fullW×fullH) 的 (x, y) 处
```

道路/地形渲染按**画布**区域裁剪，因此 `x, y, fullW, fullH` 必须与像素一起保留。

坑（formats.md §2.3–2.4）：

- **旧格式交换**：`compression==1 && w>fullW && h>fullH` 表示头部把 `w,h`
  与边距存反了——置 `w=fullW, h=fullH, x=0, y=0` 且数据起点前移 16 字节（VCMI 规则）。
- 四种像素编码：0 = 原始索引，1 = 逐行偏移 RLE，2 = 打包 RLE，3 = 逐 32px 段 RLE。
  行序自顶向下。
- 索引 0 = 透明（color-key 模式）。地形 def 不透明；`*RVR`/`*RD` 走 color-key；
  其余经调色板特殊索引携带阴影（formats.md §2.5）。
- 调色板动画：部分 def 轮转调色板区间（WATRTL、LAVATL、CLRRVR、MUDRVR、LAVRVR
  ——formats.md §2.6）。轮转周期 = 各区间长度的最小公倍数；每个周期步是一个
  *变体帧*。

## 3. h3m 解析

先解 `gzip`（95% 的文件带压缩）。顺序读取——解析器是一长串有序字段走查，
formats.md §3 是逐字段契约。以下部分对渲染至关重要。

### 3.1 地形瓦片

头部之后是 `size² × levels` 个瓦片（有地下层时 levels=2），每瓦片 7 字节：

```
terrain u8, terView u8, river u8, riverDir u8, road u8, roadDir u8, flags u8
```

- `terrain` ∈ 0..9 索引地形 def 列表（DIRTTL…ROCKTL）。
- `terView` / `riverDir` / `roadDir` 是对应 def 内的**帧索引**（从 0 起）。
- `river`/`road` = 0 表示无；否则 1..3 选择 def（道路为 DIRTRD/GRAVRD/COBBRD）。

### 3.2 翻转位（头号大坑）

`flags` 打包三个 2 位域：

| 位 | 图层 | 含义 |
|---|---|---|
| 0–1 | 地形 | bit0 = 水平翻转，bit1 = 垂直翻转 |
| 2–3 | 河流 | 同上 |
| 4–5 | 道路 | 同上 |

**bit0 = 水平，bit1 = 垂直**——我们用艺术自洽 A/B 验证（交换两轴会打碎道路
路口、海岸线棋盘化）。**不要**照搬 VCMI 的 `animation[1]->verticalFlip()`
命名：其图像内存布局不同，索引到轴的映射不可迁移。h3lwp 的
`mirrorConfig.get(4)=flipH` 与我们一致。

### 3.3 def 表与 objects

def 表给出每项的精灵名 + `objectId/subId/placementOrder`。objects 为
`x, y, z, defIndex` + 与类型相关的载荷——渲染可整体跳过（formats.md §3.4
有跳过表）。

## 4. 场景构建

一个场景层 = 5 个图层，严格按此顺序绘制（rendering.md §1）：

```
边界 (EDG) → 地形 → 河流 → 道路 → 物件
```

- **边界**：地图外瓦片按边/角索引取 EDG 帧（36 帧，formats.md §5）。
- **地形/河流**：每格一个全瓦片帧。
- **道路**：见 §5——半格裁剪。
- **物件**：画家序。按 `placementOrder` 降序（先画=靠后），再 `y` 升序，
  英雄（objectId 34/70/62）最后画，再 `x` 升序，最后 def 索引（formats.md §4）。
  物件精灵右下角锚定锚格：画布矩形 `((x+1)*32 - fw, (y+1)*32 - fh)`。

把动画帧编成**集（set）**：一个 set = 一个逻辑精灵的调色板轮转/动画帧序列；
格子存 `(setId, flip)`，绘制时选帧 `set[(animStep + phase) % set.length]`
（地形/河流）或 `set[animStep % set.length]`（物件带随机稳定 `phase`）。
动画节拍 = **180 ms**。

## 5. 道路渲染（半格拆分）——第二大坑

H3 道路精灵是 32×32 画布，可见带跨越瓦片边界。VCMI 的
`MapRendererRoad::renderTile` 是参考语义；我们逐像素互证的等价写法：

```
对每个可见格 (x, y)：
    若 (x, y-1) 有路 f：
        裁 f 画布行 [16, 32) → 画到格 (x,y) 行 [ 0, 16)   // 上半
    若 (x, y)   有路 f：
        裁 f 画布行 [ 0, 16) → 画到格 (x,y) 行 [16, 32)   // 下半
```

等价说法：整帧道路**下移 16px** 绘制，跨两格拆开。两个后果：

1. 一格可见道路 = *上格*道路帧的上半 + *本格*道路帧的下半。帧间边界必须
   吻合——美术就是按此设计的。
2. 目的半格高 **16 世界像素**。若缩放系数 `k`（屏幕 px / 世界 px），裁剪映射到
   `32k × 16k` 的目的矩形。我们曾把 `ky` 误写成 `32k/16 = 2k`，每个道路半格
   纵向拉伸 2 倍、跨缝重叠——视觉上就是"道路路口断裂"。半格缩放是 **k，
   不是 2k**。

### 5.1 镜像裁剪数学（翻转正确的源矩形）

帧翻转时其数据矩形在画布内移动，裁剪必须**先在画布空间镜像**，再在采样时
**二次镜像**。双重镜像正是斜弯能对上的原因。逐字契约（viewer.js
`drawFrameCanvas`）：

```
fullW = f.fullW, fullH = f.fullH
dxF = flipH ? fullW - f.x - f.w : f.x
dyF = flipV ? fullH - f.y - f.h : f.y
ix0 = max(canvasX, dxF), iy0 = max(canvasY, dyF)         # 裁剪区与数据取交集
ix1 = min(canvasX+canvasW, dxF+f.w), iy1 = min(canvasY+canvasH, dyF+f.h)
若为空：跳过
lx0 = ix0 - dxF, ly0 = iy0 - dyF                         # 数据矩形内偏移
sx  = f.atlasX + (flipH ? f.w - lx0 - w : lx0)           # 图集内源位置
sy  = f.atlasY + (flipV ? f.h - ly0 - h : ly0)
dest = (ix0 - canvasX, iy0 - canvasY) 按 k 缩放          # 翻转时采样镜像
```

## 6. 图集打包

- 把解码帧数据矩形打包进 2048² RGBA 页（货架式打包即可）。帧按
  `def:block:index:step` 建键并**全局去重**——本仓库 127 张图共享后仅 1.2 万帧
  /16 页（每图独立打包会到约 400MB）。
- 每帧外扩 **1px 边缘复制（pad=1）**。线性过滤下，裸帧边会与相邻帧混合
  （渗色缝）；一圈复制边即可修复且保留柔边。最近邻过滤是安全替代但观感生硬。
- 采样用 `GL_LINEAR` + pad（mac 同款）或 `GL_NEAREST`。若平台用 RGBA4444
  存储（VRAM 减半，像素艺术无损），nibble 打包**R 在最高 4 位，后 G、B、A**
  ——与 RGB565 的 R15-11 同约定。把 A 放高位会在采样时互换 R/B，蓝水渲成血红。
- UV 映射：若上传把图像第 0 行放在 `v = 0`（GLUtils/texImage2D 约定），
  直接 `v = y / pageSize`——**不要**做 GL 式 `1 - v` 翻转。

## 7. 渲染器检查单（以 GLES2 为参照）

每帧按 §4 顺序。全瓦片层画 32×32 目的四边形、源镜像；道路走 §5。深度隐含
（画序，无 z-buffer）。相机：视口矩形保持在地图内——
`centerX ∈ [viewW/2, world - viewW/2]`（这样夹持永远不会露出虚空）。
动画 180ms 步进；滑移用 smoothstep。

## 8. 验证方法论（照做，所有 bug 都是它抓到的）

1. **解析交叉校验**：在真实地图语料上跑你的解析器，与已知正确解析器
   （h3lwp 或本仓库 `H3mFile.js`）对比计数/字段。
2. **道路层逐像素对拍**：只渲染道路层，两条路径（你的 scene vs 可信参考）
   全图对比，要求 **0 像素差异**。（注意画布数学——混用瓦片/像素单位的
   涂抹式工装会伪造差异；用 1 世界 px = 1 px。）
3. **艺术自洽 A/B**：语义存疑时（如翻转轴）渲染两个变体；错的那个会明显
   打碎路口、毁掉海岸线。美术是自检的。
4. **跨引擎对比**：同机位 vs mac CLI snapshot 或 VCMI 本体。地形必须一致；
   只有随机物件可以不同。
5. **海岸/路口放大审查**：截图或美术出货前 2 倍放大检查海岸线与路口。

### 8.1 黄金基准套件（`benchmarks/`）

`benchmarks/` 目录内置六张由本仓库 macOS CLI 生成的黄金渲染图，
渲染参数见 `benchmarks/manifest.json`。元素覆盖：

| 用例 | 覆盖 |
|---|---|
| `st_coast_roads` | 海岸线、海洋、道路网、船、农田物件 |
| `st_junction_fg_bg` | 道路斜弯/路口、前后景遮挡（怪物压路） |
| `bfr_crossroads` | 道路十字路口（半格拆分）、生物、建筑纵深 |
| `bfr_snow_coast` | 雪地地形、雪地海岸、城镇/英雄锚定、道路 |
| `bfr_lava_coast` | 熔岩调色板动画（时序敏感）、悬崖、道路 |
| `moh_inland` | 混合地形、海岸、城镇精灵、树下道路 |

每个用例用 manifest 里的 `map / center / zoom / size / time_ms` 在你的
渲染器上出图（`time_ms` 必须一致——水面/熔岩的调色板动画帧依赖时钟），
然后比对：

```
python3 benchmarks/compare.py your_render.png benchmarks/golden/<id>.png --out diff.png
```

判定：**PASS** 差异 < 3.2%，**WARN** < 8%（看热图自查），**FAIL** ≥ 8%。
随机物件（怪物/英雄变体）每次运行都会变——热图里散落的色块即使渲染器
正确也会出现。**绝不允许**出现的是沿道路、海岸、瓦片缝呈**连续带状**的
差异：那是半格偏移、翻转轴或裁剪数学 bug（§5/§9），无论整体百分比多小。

**数据源**——按测试目标区分：

- **渲染器测试**（主要用途）：`benchmarks/data/bench-scenes.zip` 是三张
  基准地图的预烘焙场景包（scenes.bin v2 + 图集页）。自行实现场景包读取
  （格式见 §4/§6 与 bake.js 头注释）并直接从该包渲染——**不需要任何版权
  游戏文件**。黄金图正是由这份数据生成，渲染器正确即可复现（随机物件
  除外）。
- **解析器测试**：需要你自备的真实游戏数据——自有 HoMM3 安装里的
  `H3sprite.lod` 及其 Maps 目录下的三张地图文件。本仓库永不散发版权
  资产。用你自己的任意地图也行，只要对照 h3lwp 或 VCMI 的输出比对
  （而非这些黄金图）。

## 9. 十大坑速览

1. 翻转位：bit0 = 水平，bit1 = 垂直（`flags` 内每个 2 位域）。
2. 道路自格半块目的偏移：下半格 `+16` 世界像素。
3. 道路半格缩放 = k（不是 2k）——见 §5。
4. DEF 旧格式 `w/h` 交换规则（compression 1 且 w > fullW）。
5. UV：行 0 → v0，不翻转。
6. RGBA4444 nibble：R 先，A 最后。
7. 图集 pad=1 + 线性过滤（否则渗色缝）。
8. 镜像裁剪 = 画布空间镜像 + 采样镜像，两步都要。
9. h3m 外层 gzip；版本号（14/21/28/29）决定字段宽度。
10. 物件画家序，英雄最后画。

---

*事实源：本仓库 `web/server/engines/heroes3/*`（解析器）、
`android/bake/*`（图集 + 离线测试）、`Sources/Heroes3Engine/*`（Metal 渲染器）。
存疑时以逐像素对拍为准。*
