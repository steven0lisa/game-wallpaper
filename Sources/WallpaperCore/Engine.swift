import Foundation
import Metal
import CoreGraphics

/// 引擎接入协议：壁纸壳（WallpaperCore）只依赖这两个协议，不认识任何具体游戏。
/// 一个"游戏引擎"= 资产解析 + 场景构建 + 每帧渲染数据准备，实现方挂在 Heroes3Engine
/// 这类独立 target 里，由装配层（executable）注册进 Presenter。
///
/// 抽象刻意保持很小（见 docs/architecture.md）：壳层只要求引擎能回答
/// "世界多大、这一帧画什么"；地图渲染方式、动画方式、展示内容全部由引擎自持。

/// 相机/渲染共用的世界坐标视口（单位：世界像素，原点左上，y 向下）。
public struct SceneViewport {
    public var viewLeft: Float
    public var viewTop: Float
    public var viewWidth: Float
    public var viewHeight: Float

    public init(viewLeft: Float, viewTop: Float, viewWidth: Float, viewHeight: Float) {
        self.viewLeft = viewLeft
        self.viewTop = viewTop
        self.viewWidth = viewWidth
        self.viewHeight = viewHeight
    }
}

/// 一个已加载、可渲染的场景（通常对应一张地图/关卡）。
/// 实现方内部自持渲染器与资产；`prepare` 之后 `render`。
public protocol WallpaperScene: AnyObject {
    /// 场景世界尺寸（正方形边长，世界像素）。相机漫游范围依据。
    var worldSizePx: Float { get }
    /// 亮度压暗 0...1（0 = 原亮度）
    var brightness: Float { get set }
    /// 每帧调用（主线程）：推进动画、按视口构建本帧绘制数据。
    /// 实现可在此做惰性上传/缓存，首次调用务必完成 GPU 资源上传。
    func prepare(viewport: SceneViewport, timeMs: Double, cameraAtRest: Bool)
    /// 将当前帧渲染进 render pass（与 MTKView 的 drawable 绑定）。
    func render(to renderPassDescriptor: MTLRenderPassDescriptor, wait: Bool)
}

/// 一个游戏引擎。生命周期：注册 → init（加载引擎级资产，失败即弃用）→ loadScene。
public protocol GameEngine: AnyObject {
    /// 引擎标识（小写，用于偏好/日志/目录名）
    static var engineID: String { get }
    /// 引擎显示名（菜单/About 用）
    static var displayName: String { get }
    /// 支持的场景文件扩展名（小写、不含点，如 ["h3m"]）
    static var sceneExtensions: [String] { get }
    /// 加载引擎级全局资产（如精灵库）。资源缺失时 throw，壳层跳过该引擎。
    init(device: MTLDevice, dataDir: URL) throws
    /// 加载一个场景。可能在后台线程调用，实现需自行保证线程安全；
    /// GPU 资源上传建议延迟到 WallpaperScene.prepare 首帧（主线程）。
    func loadScene(at url: URL, level: Int) throws -> WallpaperScene
}

/// 诊断文件日志：LSUIElement 应用的 NSLog 不落到标准输出，排查渲染/缓存问题时
/// 追加到 /tmp/gamewallpaper.log，便于按"日志先行"原则复现。
public func debugLog(_ msg: String) {
    let line = "\(Date()) \(msg)\n"
    if let d = line.data(using: .utf8),
       let fh = FileHandle(forWritingAtPath: "/tmp/gamewallpaper.log") {
        _ = try? fh.seekToEnd()
        _ = try? fh.write(contentsOf: d)
        _ = try? fh.close()
    } else {
        _ = try? line.write(toFile: "/tmp/gamewallpaper.log", atomically: true, encoding: .utf8)
    }
}
