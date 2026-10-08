import Foundation
import Metal
import WallpaperCore

/// Heroes of Might & Magic III 引擎：.lod 精灵库 + .h3m 地图解析 + Metal 场景渲染。
/// 壳层只见 GameEngine/WallpaperScene 协议；本类是 H3 世界与壁纸壳的边界。
public final class Heroes3Engine: GameEngine {
    public static let engineID = "heroes3"
    public static let displayName = "Heroes of Might & Magic III"
    public static let sceneExtensions = ["h3m"]

    public enum EngineError: Error, CustomStringConvertible {
        case missingAssets(path: String)
        public var description: String {
            switch self {
            case .missingAssets(let p): return "Heroes3 assets not found at \(p) (need Data/H3sprite.lod)"
            }
        }
    }

    let library: AssetLibrary
    /// 引擎级共享渲染器（管线/纹理槽单实例；换场景时整体重传图集）
    private let renderer: MapRenderer

    public init(device: MTLDevice, dataDir: URL) throws {
        let lodURL = dataDir.appendingPathComponent("Data/H3sprite.lod")
        guard let library = AssetLibrary(lodURL: lodURL) else {
            throw EngineError.missingAssets(path: lodURL.path)
        }
        self.library = library
        self.renderer = try MapRenderer(device: device)
    }

    public func loadScene(at url: URL, level: Int) throws -> WallpaperScene {
        let h3m = try H3mFile(url: url)
        let map = GameMap(h3m: h3m, library: library, level: level)
        NSLog("GameWallpaper: heroes3 parsed %@ objects=%d missing=%d",
              url.lastPathComponent, map.objects.count, library.missingDefs.count)
        let atlas = AtlasBuilder.build(map: map, library: library)
        return Heroes3Scene(map: map, atlas: atlas, renderer: renderer)
    }

    /// 资源根目录解析顺序：用户显式指定 > app 内置资源（自包含分发）> 开发机 vcmi 目录。
    public static func defaultDataDir(_ override: String = "") -> URL {
        if !override.isEmpty { return URL(fileURLWithPath: override) }
        if let res = Bundle.main.resourceURL,
           FileManager.default.fileExists(atPath: res.appendingPathComponent("Data/H3sprite.lod").path) {
            return res
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Application Support/vcmi")
    }
}

/// WallpaperScene 实现：把壳层的 SceneViewport/prepare/render 翻译成 MapRenderer 调用。
/// 图集上传延迟到首帧 prepare（主线程），与壳层"后台线程 loadScene"的约定配套。
public final class Heroes3Scene: WallpaperScene {
    let map: GameMap
    let atlas: FrameAtlas
    let renderer: MapRenderer
    private var uploaded = false

    init(map: GameMap, atlas: FrameAtlas, renderer: MapRenderer) {
        self.map = map
        self.atlas = atlas
        self.renderer = renderer
    }

    public var worldSizePx: Float { Float(map.size * 32) }

    public var brightness: Float {
        get { renderer.currentBrightness }
        set { renderer.currentBrightness = newValue }
    }

    public func prepare(viewport: SceneViewport, timeMs: Double, cameraAtRest: Bool) {
        if !uploaded {
            renderer.uploadAtlas(atlas)
            uploaded = true
        }
        renderer.buildFrame(map: map, atlas: atlas,
                            view: MapRenderer.Viewport(viewLeft: viewport.viewLeft,
                                                       viewTop: viewport.viewTop,
                                                       viewWidth: viewport.viewWidth,
                                                       viewHeight: viewport.viewHeight),
                            timeMs: timeMs,
                            cameraAtRest: cameraAtRest)
    }

    public func render(to renderPassDescriptor: MTLRenderPassDescriptor, wait: Bool) {
        renderer.draw(to: renderPassDescriptor, wait: wait)
    }
}
