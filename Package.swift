// swift-tools-version:5.9
import PackageDescription

// 多引擎动态壁纸（macOS）：
//   WallpaperCore  壁纸壳——桌面层窗口、渲染循环、电源/休眠策略、相机、引擎协议
//   Heroes3Engine  Heroes3 引擎——.lod/.def/.h3m 解析、图集、Metal 场景、Web 查看器
//   GameWallpaper  装配层（executable）——注册引擎 + 菜单栏 UI + 引擎 CLI 分发
// 接入新引擎：新建 Sources/<Game>Engine 依赖 WallpaperCore 实现 GameEngine，
// 并在 GameWallpaper 装配处注册（见 docs/architecture.md）。
let package = Package(
    name: "GameWallpaper",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "WallpaperCore"),
        .target(name: "Heroes3Engine", dependencies: ["WallpaperCore"]),
        .executableTarget(
            name: "GameWallpaper",
            dependencies: ["WallpaperCore", "Heroes3Engine"]
        )
    ]
)
