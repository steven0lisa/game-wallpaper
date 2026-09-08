// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Heroes3Wallpaper",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Heroes3Wallpaper",
            path: "Sources/Heroes3Wallpaper"
        )
    ]
)
