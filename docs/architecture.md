# 架构：多游戏引擎动态壁纸

本项目的定位是一个**支持多种游戏引擎的动态壁纸运行时**：壁纸壳负责所有与游戏无关的
通用能力，每个游戏以"引擎"形式接入自己的资产解析、场景构建与渲染。

## 总览

```
┌────────────────────────── 装配层（Sources/GameWallpaper）──────────────────────────┐
│  main.swift（入口 + CLI 分发）   AppDelegate.swift（菜单栏、资源目录、引擎注册）      │
└──────────────┬──────────────────────────────────────────────────┬────────────────┘
               │ 依赖                                              │ 依赖
┌──────────────▼──────────────────┐   ┌────────────────────────────▼─────────────────┐
│  WallpaperCore（壁纸壳）          │   │  游戏引擎 target（可插拔）                     │
│  · Engine.swift  引擎协议         │◄──┤  Heroes3Engine：                              │
│  · WallpaperWindow  桌面层窗口    │实现│  · LodFile/DefFile/H3mFile/AssetLibrary 解析 │
│  · WallpaperPresenter 换图/循环  │协议│  · GameMap/AtlasBuilder 场景与图集            │
│  · Camera  跳点漫游              │    │  · Heroes3Renderer Metal 渲染                 │
│  · 电池/休眠电源策略              │    │  · MapWebServer 内置 Web 查看器服务           │
│  · AboutWindowController        │    │  · Heroes3CLI 无头诊断                        │
└─────────────────────────────────┘   └───────────────────────────────────────────────┘
```

依赖方向严格单向：`Heroes3Engine → WallpaperCore`，装配层依赖两者，壳层不认识任何具体游戏。

## 引擎协议（WallpaperCore/Engine.swift）

刻意保持很小——壳层只要求引擎回答"**世界多大、这一帧画什么**"：

```swift
protocol GameEngine: AnyObject {
    static var engineID: String { get }          // "heroes3"
    static var displayName: String { get }
    static var sceneExtensions: [String] { get } // ["h3m"]
    init(device: MTLDevice, dataDir: URL) throws // 引擎级资产加载，缺失即 throw
    func loadScene(at url: URL, level: Int) throws -> WallpaperScene
}

protocol WallpaperScene: AnyObject {
    var worldSizePx: Float { get }               // 相机漫游范围
    var brightness: Float { get set }
    func prepare(viewport: SceneViewport, timeMs: Double, cameraAtRest: Bool) // 每帧：动画+绘制数据
    func render(to: MTLRenderPassDescriptor, wait: Bool)
}
```

抽象尺寸的把握（重要约定）：
- **壳层只抽"必须共享"的**：窗口层级、渲染循环节拍（静止 5fps / 平移 30fps）、电池 0fps、
  休眠暂停、换图周期、跳点相机、亮度/缩放偏好、About 窗口。
- **不为第二个引擎预设计**：地图渲染方式、动画方式、展示内容千差万别（仙剑是俯视
  tile 地图+序列帧，星际是斜视角+贴图混排……），引擎内部想怎么实现都行；等第二个
  引擎真正出现时，再把已重复的模式下沉到 Core。
- 引擎内部类型（AssetLibrary/GameMap/MapRenderer 等）保持 target 内部可见，跨 target
  只暴露协议要求的 4 个 public 符号（Heroes3Engine/Heroes3Scene/MapWebServer/Heroes3CLI）。

## 接入新引擎（以假想的 PAL/StarCraft 为例）

1. `Sources/<Game>Engine/` 新建 target，依赖 `WallpaperCore`：
   ```swift
   // Package.swift
   .target(name: "Palengine", dependencies: ["WallpaperCore"]),
   ```
2. 实现 `GameEngine`（资产库加载 + `loadScene`）与 `WallpaperScene`（worldSizePx/
   brightness/prepare/render）；Metal 管线可直接复制 Heroes3Renderer 的"实例化四边形 +
   图集"模式，也可完全自绘。
3. 装配：`AppDelegate.applicationDidFinishLaunching` 里构造引擎并注册进
   `WallpaperPresenter`；CLI 挂到 `main.swift` 的分发链。
4. 打包：`scripts/build_app.sh` 为该引擎增加资源拷贝段（版权资源永不入库，见
   .gitignore 的"逆向/原版游戏资源"节）。

## 平台矩阵

| 平台 | 形态 | 位置 |
|---|---|---|
| macOS（主平台） | SwiftPM 多 target，Metal 壁纸 app | `Sources/`（见上图） |
| Web | Node 零依赖服务 + Canvas 查看器（引擎代码在 `web/server/engines/heroes3/`） | `web/` |
| ~~Windows~~ | 已移除（2026-10） | git 历史中 |

## 版本与发布

- 版本号 `v<major>.<minor>` git tag；push tag → GitHub Actions 构建 dmg → Release
  （含自动生成的更新说明）。见 `.github/workflows/release.yml` 与 docs/environment.md。
