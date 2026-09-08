# 参考实现调研：h3lwp（Android 版 Heroes 3 动态壁纸）

`base.apk`（9.9MB，versionName 3.0.7）是开源项目
[IlyaPomaskin/h3lwp](https://github.com/IlyaPomaskin/h3lwp) 的构建产物
（`com.homm3.livewallpaper`）。本项目的 h3m 解析器与图层行为以它为基线移植，
再按 VCMI 语义校正。本文记录逆向（jadx 反编译）得到的架构与关键实现。

---

## 1. 应用架构

```
com.homm3.livewallpaper/
├── android/   LiveWallpaperService（Android WallpaperService 引擎）、MainActivity（设置界面）
├── core/      libGDX 引擎层（跨平台，桌面端可直接跑）
│   ├── Engine.kt             屏幕/资源生命周期，地图列表管理
│   ├── GameScreen.kt         OrthogonalTiledMapRenderer + 定时换图（10min/2h/24h）
│   ├── Camera.kt             随机视口 + 视差滚动（桌面端 offset*96px）
│   ├── Assets.kt             AssetManager 封装：atlas 加载、地图排序（按文件大小升序）
│   ├── ObjectsRandomizer.kt  随机物件具象化（见 formats.md §4）
│   ├── Sprite.kt             单物件动画（0.18s/帧，随机初始相位）
│   └── layers/               TerrainGroupLayer（地形/河/路三层 TiledMapTileLayer）
│                            ├ ObjectsLayer（按视口收集 + 索引排序绘制）
│                            └ BorderLayer（EDG 帧）
└── parser/    资产转换器（一次性离线）
    ├── AssetsConverter.kt    lod → 2048² RGBA4444 texture atlas（PixmapPacker）
    ├── AssetsReader.kt       lod 条目筛选：全部 TERRAIN 类 + av* SPRITE + MAP 类 def
    ├── AssetsPacker.kt       帧打包 + 调色板轮转变体生成（rotatePalette 直到回到原调色板）
    ├── AssetsWriter.kt       atlas + 索引落盘
    └── formats/              LodReader / DefReader / H3mReader / PngWriter / Reader
```

**关键设计**：用户首次启动时从原版游戏选一个 `.lod`（实为 H3sprite.lod），
转换器把渲染所需 def 全部解出打成一张 texture atlas 存到应用私有目录；
之后壁纸直接加载 atlas，不再碰 lod。本项目改为运行时直接读 lod + 自建图集，
免去预转换步骤。

## 2. 与本项目的实现差异对照

| 方面 | h3lwp（APK） | 本项目（macOS） |
|---|---|---|
| 渲染 | libGDX OrthogonalTiledMapRenderer（CPU 组 batch） | Metal instanced quads + texture2d array |
| 图集 | 2048² RGBA4444，离线一次性生成 | 2048² RGBA8，每图构建（~1s/图） |
| 调色板动画 | 预生成 N 个变体帧（rotate 到复原为止） | 同样预生成变体帧（atlas key 带 step） |
| 动画相位 | 每物件随机初始 stateTime | phase += 7 确定性步进 |
| 阴影索引 | fixedPalette 覆盖 + PNG tRNS | rgba() 直接映射索引语义 |
| 换图 | 10min/2h/24h 定时 | 15min（可调） |
| 相机 | 随机视口 + 页面切换视差 | 漫游相机（目标点滑动 + 驻留） |
| 地图层 | 仅地表 | 仅地表（地下层已解析可切换） |

## 3. 反编译中的坑（对本项目移植有直接影响）

1. **libGDX 按键常量内联**：jadx 把 `Input.Keys.NUMPAD_LEFT_PAREN`（=162）等常量
   直接数值化，随机怪 L5/L6/L7 的枚举值看起来是 162/163/164——这部分恰好是对的；
   但 `ObjectsRandomizer.randomArtifact` 里的 `nextInt(CONTROL_LEFT, F11)`（=129..129+）
   这类代码必须对照 [h3lwp 源码](https://github.com/IlyaPomaskin/h3lwp) 或语义
   （relic 段 129-139）还原，不能照抄字面。
2. **Def.java 数据类**：块头 unknown 字节数在反编译里易读错（实际 8 字节，见 formats.md §2.2）。
3. **Lod.FileType**：枚举 TERRAIN/SPRITE/MAP 的 value 来自 lod 条目的分类字段，
   AssetsReader 只取 `TERRAIN 类 + av* 前缀 SPRITE 类 + MAP 类`——即地形与冒险物件，
   界面素材（0x47 INTERFACE 类）不进 atlas。本项目直接按地图 def 表取用，更精确。

## 4. 可借鉴但未采纳的行为

- APK 的地图列表按**文件大小升序**排序（先加载小图快速出画面）——本项目按文件名排序，
  因为本机地图全量预载无压力。
- APK 的 `ObjectsLayer` 用 y/x 网格索引 + 视口扩张 4 格做可见性收集；
  本项目物件数量（<3.5k）全量排序遍历即可，留了视口 AABB 裁剪。
- APK 桌面端（LWJGL）支持按键/点击换视角；本项目为无交互壁纸，用菜单栏控制。
