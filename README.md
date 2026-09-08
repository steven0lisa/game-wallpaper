# Heroes3Wallpaper — 英雄无敌 3 动态壁纸（macOS + Windows）

把 HoMM3 的 `.h3m` 地图实时渲染成桌面动态壁纸：原版游戏素材（`H3sprite.lod`）驱动，
水面/岩浆调色板动画、物件待机动画、相机自动漫游，与 VCMI 引擎的实际游戏画面一致。

| 平台 | 技术 | 入口 |
|---|---|---|
| macOS | Swift + Metal（桌面层窗口） | `scripts/build_app.sh` → `build/Heroes3Wallpaper.app` |
| Windows | 可移植 C++17 软光栅 + Win32 WorkerW 注入 | `windows/build-windows.sh` → `windows/dist/Heroes3Wallpaper.exe`（见 [windows/README.md](windows/README.md)）|

两平台共享同一套解析/渲染语义（Windows 为软光栅实现），已互相做像素级对账。
默认缩放 2×（保证铺满屏幕、不形变的前提下），镜头漫游速度极缓（0.3 地图px/s）。

## 内置 Map Viewer（浏览器看图）

- **macOS**：菜单栏 → 「Map Viewer（浏览器查看地图）」，内置 HTTP 服务（127.0.0.1:8766 起）
- **Windows**：托盘图标 → 右键 → 「Map Viewer」，内置 HTTP 服务（127.0.0.1:8767 起）
- 与独立 web 版（`web/`，Node）同一套 API：`/api/maps`、`/api/scene`、`/atlas/...`，
  拖拽平移、滚轮缩放、地图下拉切换。
- 打包内置地图：`scripts/pick_maps.py` 按"体积最大 + 相近名去重"选 20 张。

把 HoMM3 的 `.h3m` 地图实时渲染成 macOS 桌面动态壁纸：原版游戏素材（`H3sprite.lod`）驱动，
Metal 渲染，水面/岩浆调色板动画、物件待机动画、相机自动漫游，与 VCMI 引擎的实际游戏画面一致。

![screenshot](docs/wallpaper_final.png)

## 使用

```bash
# 构建（需要 Xcode，macOS 13+）
./scripts/build_app.sh
open build/Heroes3Wallpaper.app   # 菜单栏出现 🏰 图标
```

- **地图来源**：默认加载 `~/Library/Application Support/vcmi/Maps/` 下全部 `.h3m`（即 VCMI 的地图目录），
  每 15 分钟自动换一张；菜单栏可「Next Map Now」「Open Map…」「Choose Maps Folder…」。
- **游戏素材**：默认读取 `~/Library/Application Support/vcmi/Data/H3sprite.lod`（需拥有原版游戏文件）。
- **菜单栏设置**：缩放 1×–4×、亮度压暗 0–60%、暂停/恢复、立即切换地图。
- **渲染层级**：窗口钉在桌面层（kCGDesktopWindowLevel，Plash 同款方案）——位于壁纸之上、桌面图标之下，
  所有 Space 可见；不抢占鼠标点击。
- **退出**：菜单栏 → Quit。

### 验证用 CLI（无头单帧渲染）

```bash
.build/release/Heroes3Wallpaper --snapshot <map.h3m> --out snap.png \
    [--data-dir <vcmi 目录>] [--width 1920 --height 1080] [--time-ms 3000] \
    [--zoom 1] [--center-x 0.5 --center-y 0.5] [--level 0]
```

## 架构

```
Sources/Heroes3Wallpaper/
├── LodFile.swift      .lod 归档（H3sprite.lod，zlib 条目，VCMI 同款 0x5C 目录布局）
├── DefFile.swift      .def 精灵解码（4 种 RLE 压缩 + legacy 侦测 + 调色板动画 + 阴影/色键语义）
├── H3mFile.swift      .h3m 地图解析（RoE/AB/SoD：头部、地形 7 字节组、def 表、对象 payload 跳读）
├── AssetLibrary.swift 资产库 + FrameAtlas 纹理图集（2048² 分页 shelf packing，RGBA8）
├── GameMap.swift      图层构建：地形/河流/道路/边界(EDG)/物件（含随机物件具象化）
├── Renderer.swift     Metal 渲染器（实例化四边形 + texture2d_array + 亮度叠加）
├── Camera.swift       自动漫游相机（随机目标点 + 匀速滑动 + 驻留）
├── App.swift          桌面层窗口（每屏一个）+ MTKView 驱动循环
├── AppDelegate.swift  菜单栏 UI 与偏好（UserDefaults）
└── main.swift         入口（GUI / --snapshot CLI / --probe-def / --tile 诊断）
```

### 渲染语义（与 VCMI 对齐的关键常量）

- **地形**：`terView`（h3m 存的帧号）+ `extTileFlags&3` 翻转（1=V、2=H），直接查 DEF 帧，客户端不做邻域计算。
- **动画**：地形/河流调色板轮转与物件待机帧统一 **180ms/帧**；
  轮转区间取自 VCMI `terrains.json`/`rivers.json`（水 `[229,12)+[242,12)`、岩浆 `[246,9)` 等）。
- **河流/道路**：`riverDir/roadDir` + 高位翻转位；道路图整体下移 16px 跨两格绘制、无动画；绘制序 地形→河→路→物件。
- **物件**：def 表自带 spriteName（随机物件按 APK ObjectsRandomizer 具象化）；
  画布右下角对齐 anchor 格，阴影索引 1/4=25%/50% 黑、5 号索引=玩家色占位；
  排序 printPriority↓ → y↑ → 英雄置顶 → x↑。
- **边界**：EDG.DEF，VCMI `getIndexForTile` 公式（先判图外远处，再四角/四边）。
- **透明索引**（DEF 内嵌调色板）：0=透明、1=25% 阴影、4=50% 阴影、5=旗帜色、6/7=选中色。

## 端到端验证

1. **与 VCMI 引擎逐格对比**：用 `vcmieditor`（与游戏共用 MapRenderer）加载同一张
   《A Warm and Familiar Place》，截取编辑器画布与本项目渲染做自动对齐 + 313 格 8×8 采样比对，
   平均差异主要来自编辑器专属的 RES/MON 标记 UI；地形过渡、岩浆河、道路、物件、阴影全部一致。
2. **边界与动画**：地图四角 EDG 金框 + 图外暗岩与游戏一致；
   同视角 t=0/540/1800ms 渲染差分非零（调色板动画生效），实时运行时 2s 差分同样非零（物件动画+相机漫游）。
3. **真机桌面验证**：app 启动后桌面层窗口（level -2147483623）在真实桌面持续渲染
   （半透明菜单栏下可见地图、多 Space 生效），GUI 渲染循环 60fps。

## 已知限制 / 后续

- 只渲染地表层（underground 层已解析，可在 `MapPresenter` 里切换 level=1）。
- 英雄/旗帜未做玩家色染色（def 索引 5 已留位）；每 15 分钟换图时可加 underground 轮换。
- 战争迷雾、英雄移动动画不适用（壁纸无游戏状态）。

## Web 版地图查看器

[`web/`](web/README.md) 是同源逻辑的浏览器版：Node 后端（零依赖，移植同一套 lod/def/h3m
解析器）+ HTML Canvas 前端，渲染完整地图，支持拖拽/缩放/切图/动画，已与 Swift 版做过
像素级对比（同视角平均差 5.7/765，内容一致）。

```bash
cd web && npm start   # http://localhost:8765/
```

## 参考

- [VCMI](https://github.com/vcmi/vcmi)（渲染语义与格式权威参考，源码在 `~/work/personal/vcmi`）
- [IlyaPomaskin/h3lwp](https://github.com/IlyaPomaskin/h3lwp)（Android 版 Heroes 3 live wallpaper，本项目的解析器/图层行为基线，`base.apk` 即其构建产物）
