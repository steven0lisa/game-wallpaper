# 渲染语义与 VCMI 对照（视觉一致性基准）

本文档记录"地图实际运行画面长什么样"的每条渲染规则及其在 VCMI 源码中的出处，
以及本项目的实现对照。目标：让壁纸与游戏内冒险地图画面一致。

---

## 1. 图层与绘制顺序

每帧绘制顺序（VCMI `MapRenderer.cpp` renderTile 循环，APK GameScreen 一致）：

```
边界(EDG) → 地形 → 河流 → 道路 → 物件（按排序）
```

本项目在实例数组中按此顺序追加，单次 instanced draw 完成（半透明混合按实例序）。

## 2. 地形

- 每格：`DEF = terrains[terrainType].tiles`，帧 = `terView`，翻转 = `extTileFlags & 3`。
- **翻转位语义（三层一致，已对 vcmieditor 像素级验证）**：2-bit 值是"槽位号"，
  bit0(0x01)=**左右镜像**、bit1(0x02)=**上下镜像**、0x03=双翻转。VCMI
  `MapTileStorage::load` 把整张帧预翻转进 4 个槽位——注意其 `verticalFlip()` 是
  "绕竖直轴翻转"=左右镜像，**命名按轴不按方向**，勿望文生义（详见 pitfalls #14）。
- **不存在客户端邻域计算**：h3m 存什么帧就画什么帧（过渡瓦片是地图编辑器/RMG 写图时
  用 terrainViewPatterns 算好的）。这是渲染端最重要的"免坑"结论。
- 32×32 px/格；水/岩浆按调色板动画区间每 180ms 轮转一步。
- 地形 blit 模式 OPAQUE（不透明，索引 0 也画出来）。

## 3. 河流与道路

- 河流：帧 = `riverDir`，翻转 = `(extTileFlags>>2)&3`，COLORKEY 透明（索引 0 透明），
  带调色板动画（CLRRVR/MUDRVR/LAVRVR），180ms/步。
- 道路：帧 = `roadDir`，翻转 = `(extTileFlags>>4)&3`，COLORKEY，**无动画**。
- **道路的半格错位**（VCMI MapRendererRoad::renderTile 精确算法）：
  每格的道路图被"下移 16px 跨两格"绘制——本格道路图的**上半 16px** 画到
  本格的**下半**；**上方一格**道路图的**下半 16px** 画到本格的**上半**：
  ```cpp
  target.draw(imageAbove, Point(0, 0),  Rect(0, 16, 32, 16));  // 上格下半 → 本格上半
  target.draw(image,      Point(0, 16), Rect(0,  0, 32, 16));  // 本格上半 → 本格下半
  ```
  即整条路的视觉位置比逻辑格低半格。
- **⚠️ 带翻转的裁剪顺序（易错点）**：VCMI 是"**先整张镜像、后普通 Rect 裁剪**"
  （槽位图已翻转）；对子矩形做"先裁剪后翻转"不等价——矩形镜像后与数据的相对
  位置变了。直路条带左右对称所以侥幸无感，斜向条带（22×22@(10,10)）立刻断裂。
  实现见 Swift `Renderer.canvasCrop`（数据矩形镜像进翻转画布空间求交 + shader
  flags 在 quad 内镜像采样）与 JS `viewer.drawFrameCanvas`（同序 + scale(-1,1)），
  双端均已对 vcmieditor 像素级验证（详见 pitfalls #15）。

- **⚠️ 道路遍历语义（易错点）**：VCMI 对【视口内每个格子】调用 renderTile，而**不是**
  只遍历有路的格子。本格无路但上格有路时，仍要画上格道路图的下半——否则道路
  在"向下终止"的接驳处断裂（道路图的下半永远落在下一格）。Viking 地图有 601 个
  这样的格子（158 张地图共 20602 个），全部会导致旧实现丢路面。河流没有此问题
  （整帧画在本格，无跨格延伸）。

- **⚠️ 道路/河流帧的 margin（画布语义，易错点）**：DIRTRD/GRAVRD/COBBRD 等帧的
  **画布是 32×32，实际数据带 margin**（如横向泥路帧 12/13 是 32×14 数据、margin (0,9)，
  即路面在画布 y=9..23 垂直居中；纵向帧 14×32、margin (9,0) 水平居中）。
  VCMI 的 `draw(image, Point, Rect)` 中 Rect 是**画布坐标**——Rect(0,16,32,16) 取的是
  画布下半（含透明 margin 与数据相交后的部分），**不是**数据坐标的下半。
  若按数据坐标裁剪（把 32×14 数据直接画进 32×16 目标区），路面会被拉伸并整体
  错位半格、骑在格线上。正确做法：画布矩形 ∩ 数据矩形求交，交区按画布内位置
  映射到目标半格（Swift `canvasCrop` / JS `drawFrameCanvas`）。
  地形/河流/物件帧是整帧绘制、margin 天然生效，只有"半格裁剪"路径踩这个坑。

## 4. 物件

- 画布右下角锚定 anchor 格（见 formats.md §4）；帧数据按 margin 内偏移。
- 帧循环：组 0 全部帧按 180ms/帧循环（待机动画）；逐对象错相。
- 半透明阴影：索引 1 = 25% 黑、4 = 50% 黑（源自 def 调色板占位色替换，见 formats.md §2.5）。
- 排序：placementOrder ↓ → y ↑ → 英雄置顶 → x ↑ → 文件序。
- 不可见对象（VCMI getBaseAnimation 返回空）：EVENT(26)、GRAIL(36)；
  随机英雄/占位符壁纸项目里也不画（无外观）。

## 5. 边界

EDG.DEF 36 帧 + `getIndexForTile` 公式（formats.md §5）。
游戏内 `showBorder()=true`，图外一圈画金框、更远画暗岩图案。

## 6. 动画时序总表（VCMI MapRendererContext）

| 内容 | 周期 | 出处 |
|---|---|---|
| 地形/河流调色板动画 | 180ms/步 | `baseFrameTime = 180` |
| 物件待机帧 | 180ms/帧（相位 = objectID） | 同上 |
| 物件移动帧（不适用壁纸） | 50ms/帧 | AdventureMovingContext |
| 淡入淡出（不适用） | 500ms / 传送 250ms | MapViewController |

调色板动画周期 = 各轮转区间长度的 LCM（水 12 步 = 2.16s/循环，岩浆 9 步 = 1.62s）。

## 7. 相机与缩放（本项目自定义，参考 VCMI 行为）

- VCMI 游戏：默认 tileSize 32，缩放步进 `32 * 1.01^n`，平移钳制在地图范围 + 边界。
- 本项目壁纸：漫游相机在地图范围内随机目标点匀速滑动（22 map px/s）+ 驻留 4-9s；
  视口钳制允许露出最多 4 格边界（`clamp` 里 ±128px）。
- 缩放档 1×/2×/3×/4×（屏幕像素/地图像素），金属管线 nearest 采样保持像素风。

## 8. 验证方法与结论

| 验证项 | 方法 | 结果 |
|---|---|---|
| 与游戏画面逐格对比 | `vcmieditor` 加载同一地图（与游戏共用 MapRenderer），截取画布 vs 本项目 `--snapshot` 同视角渲染，自动对齐 + 313 格 8×8 采样差分 | 平均差异全部来自编辑器 RES/MON 标记；地形/河流/道路/物件/阴影一致 |
| 地形类型覆盖 | 《A Warm and Familiar Place》(rough/lava/rock/dirt) + 《Emerald Isles》(water/sand/grass/dirt) | 7 种地形 + 河流 + 道路 + 边界全部正确 |
| 动画 | 同视角 t=0/540/1800ms 差分非零；真机运行 2s 差分非零（3.72/px） | 调色板动画 + 物件动画 + 相机漫游均生效 |
| 帧率 | draw 计数 60fps | 60fps 稳定 |
| 桌面集成 | 桌面层窗口 level -2147483623，半透明菜单栏下透出地图 | 通过 |

复现对比：
```bash
# 本项目渲染（与编辑器画布同像素尺度）
.build/debug/Heroes3Wallpaper --snapshot "<map.h3m>" --out mine.png \
    --width 1152 --height 1152 --time-ms 0 --zoom 1 --center-x 0.5 --center-y 0.5
# 打开编辑器看同一地图（vcmieditor 与游戏共用渲染器）
/Applications/VCMI.app/Contents/MacOS/vcmieditor "<map.h3m>"
```

## 9. About 对话框（heroes3 风格 UI，VCMI CMessage 对照）

About 窗口的对话框观感按 VCMI 信息窗还原，两条规则都曾被想当然写错：

- **边框**：`CMessage::drawBorder`（client/windows/CMessage.cpp）**只用 DIALGBOX.DEF
  的 box[0..7]**——box[0..3] 四角（64×64）贴四角，box[4/5] 左右边（14×64）、
  box[6/7] 上下边（64×15）沿轴步进平铺；绘制顺序"先边后角"（角覆盖边）。
  **box[8..10] 完全不参与**（其内部像素是色键，不是内部背景）。
  想当然的"9-slice 把 box[8] 平铺当内部"是首版青色网格的根因之一。
- **内部背景**：`CInfoWindow` 用 `CFilledTexture(ImagePath::builtin("DiBoxBck"), pos)`
  （client/windows/InfoWindows.cpp），`showAll` 是**平铺**（x/y 按 tile 尺寸步进，
  非拉伸）——棕纸纹理 DIBOXBCK.PCX 铺满整个窗口，边框叠在其上。
- 颜色：边框的玩家色段 224–255 在 DIALGBOX 自带调色板里就是蓝方渐变
  （见 formats.md §2.7），无需重染；内部纸底主色 `(116,75,42)` 棕系。
  "深蓝内部"的印象来自 H3 后期 UI 或 VCMI 皮肤，原版 DIALOG 即棕底蓝框。

实现：`AboutWindowController.swift`（Heroes3BorderView：background 平铺 +
box[0..7] 平铺）与 `scripts/export_about_assets.py`（DIALGBOX 色键透明 +
DIBOXBCK.PCX → background.png）；坑详录 pitfalls #22。
