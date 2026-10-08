import AppKit
import MetalKit
import IOKit.ps

/// Owns the loaded scenes, the camera, and the render loop. 与具体游戏无关：
/// 场景由注册的 GameEngine 构建为 WallpaperScene，壳层只负责换图节拍、
/// 相机漫游、电源/休眠策略和把帧送进 MTKView。
public final class WallpaperPresenter: NSObject, MTKViewDelegate {
    /// 诊断：首帧输出一次 drawable/zoom 数据，定位壁纸未铺满问题
    fileprivate static var _diagCount = 0
    private let engine: GameEngine
    public private(set) var current: CurrentScene?
    public var paused = false
    /// User zoom preference (1 = 1×, 2 = 2×, …). The effective zoom never drops below the
    /// cover zoom for the current map/screen, so the wallpaper always fills the screen
    /// without stretching (aspect ratio preserved).
    public var zoom: Float = 1
    /// 亮度偏好；场景加载后每帧同步给 scene.brightness
    public var brightness: Float = 0
    public var mapCycleInterval: TimeInterval = 900
    /// 跳点间隔（秒）—— 默认 3 分钟，电池模式不跳
    public var cameraJumpInterval: TimeInterval = 180
    private var cycleElapsed: TimeInterval = 0

    public struct CurrentScene {
        public var url: URL
        public var scene: WallpaperScene
    }

    public var camera = Camera()
    /// 相机初始化参数（变化时才 reset —— 每帧 reset 会把跳点计时器和位置钉死在初始值）
    private struct CameraConfig: Equatable {
        var worldPx: Float
        var w: Float
        var h: Float
        var interval: TimeInterval
    }
    private var cameraConfig: CameraConfig?
    private var elapsedMs: Double = 0
    public private(set) var mapURLs: [URL] = []
    private var currentIndex = 0
    public private(set) var loading = false
    /// 电池供电：暂停渲染循环（0fps、画面完全静止），不换图不跳点
    public private(set) var onBattery = false
    /// 电源复查定时器（电池时 draw 不再执行，检查必须独立于渲染循环）
    private var powerCheckTimer: Timer?
    private var lastTimestamp: CFTimeInterval?
    /// 渲染视图弱引用（电池时 isPaused 停掉 MTKView 的 display-link timer）
    public weak var renderView: MTKView?
    /// 换图时回调（作废 WebViewer 场景缓存等）；由 AppDelegate 装配。
    public var onSceneChanged: (() -> Void)?
    /// 换图/加载失败时输出引擎名与场景名（日志先行）
    private var engineStarted = false

    public init(engine: GameEngine) {
        self.engine = engine
        super.init()
        startPowerCheckTimer()
    }

    /// 每分钟复查供电状态：电池 → isPaused 停渲染循环；插电 → 恢复。
    /// 定时器在主循环（common modes）上，休眠期间不触发，唤醒后立即纠正。
    private func startPowerCheckTimer() {
        powerCheckTimer?.invalidate()
        powerCheckTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            let battery = Self.onBatteryPower()
            guard battery != self.onBattery else { return }
            self.onBattery = battery
            self.lastTimestamp = nil // 复位 dt，避免恢复瞬间跳变
            self.renderView?.isPaused = battery   // 电池：连 MTKView 的 timer 一起停
            NSLog("GameWallpaper: power %@ → render %@",
                  battery ? "on battery" : "restored",
                  battery ? "paused" : "resumed")
        }
    }

    /// Effective zoom: at least the cover zoom, so the map always covers the full view.
    private func effectiveZoom(worldPx: Float, viewW: Float, viewH: Float) -> Float {
        max(zoom, max(viewW / worldPx, viewH / worldPx))
    }

    // MARK: - Power source

    /// 电池供电（未接电源）返回 true；台式机/接电源返回 false
    public static func onBatteryPower() -> Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return false }
        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue()
                    as? [String: Any],
                  let state = desc[kIOPSPowerSourceStateKey] as? String else { continue }
            if state == kIOPSBatteryPowerValue { return true }
        }
        return false
    }

    // MARK: - Scene loading

    public func setMaps(_ urls: [URL], startAt index: Int = 0) {
        mapURLs = urls
        currentIndex = min(index, max(urls.count - 1, 0))
        if !mapURLs.isEmpty { loadCurrent() }
    }

    public func nextMap() {
        guard mapURLs.count > 1 else { return }
        currentIndex = (currentIndex + 1) % mapURLs.count
        loadCurrent()
    }

    private func loadCurrent() {
        loading = true
        current = nil
        let url = mapURLs[currentIndex]
        let engineName = type(of: engine).engineID
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let scene = try self.engine.loadScene(at: url, level: 0)
                if !self.engineStarted {
                    self.engineStarted = true
                    NSLog("GameWallpaper: engine %@ ready (%@)",
                          engineName, type(of: self.engine).displayName)
                }
                DispatchQueue.main.async {
                    self.current = CurrentScene(url: url, scene: scene)
                    self.camera = Camera()
                    // 旧地图的 viewer 场景副本（图集页像素拷贝）一并作废
                    self.onSceneChanged?()
                    // worldPx/viewW/viewH 在第一次 draw 时会调用 reset()，无需传
                    self.cycleElapsed = 0
                    self.loading = false
                    Self.logFootprint("scene ready")
                }
            } catch {
                NSLog("GameWallpaper: %@ failed to load %@: %@", engineName,
                      url.lastPathComponent, String(describing: error))
                DispatchQueue.main.async {
                    self.loading = false
                    self.nextMap()
                }
            }
        }
    }

    /// 进程物理内存占用（footprint），用于观察换图周期内的内存回落。
    public static func logFootprint(_ tag: String) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        guard task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO),
                        withUnsafeMutableBytes(of: &info) { $0.bindMemory(to: integer_t.self).baseAddress! },
                        &count) == KERN_SUCCESS else { return }
        NSLog("GameWallpaper: footprint %@ = %.0f MB", tag, Double(info.phys_footprint) / 1048576.0)
    }

    // MARK: - MTKViewDelegate

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    public func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = lastTimestamp.map { min(now - $0, 0.25) } ?? 0
        lastTimestamp = now

        // 电池供电：画面完全静止（暂停渲染循环）、不换图、不跳点；
        // 电源复查不依赖 draw 回调（见 powerCheckTimer），此处只读缓存值。
        if onBattery {
            return
        }

        // 相机停留期动画多为低频步进，5fps 采样足够；平移过渡保持 30fps。
        let targetFps = camera.isAtRest ? 5 : 30
        if view.preferredFramesPerSecond != targetFps {
            view.preferredFramesPerSecond = targetFps
        }

        if !paused, let cs = current {
            elapsedMs += dt * 1000
            cycleElapsed += dt
            if cycleElapsed >= mapCycleInterval {
                cycleElapsed = 0
                nextMap()
            }
            let drawableSize = view.drawableSize
            let worldPx = cs.scene.worldSizePx
            // Cover zoom: the scene always spans the entire screen (no letterboxing,
            // no border tiles), aspect ratio preserved.
            let effZoom = effectiveZoom(worldPx: worldPx,
                                        viewW: Float(drawableSize.width),
                                        viewH: Float(drawableSize.height))
            let viewW = Float(drawableSize.width) / effZoom
            let viewH = Float(drawableSize.height) / effZoom
            if Self._diagCount == 0 {
                Self._diagCount += 1
                debugLog("DIAG drawable=\(Int(drawableSize.width))x\(Int(drawableSize.height)) bounds=\(Int(view.bounds.width))x\(Int(view.bounds.height)) scale=\(view.window?.backingScaleFactor ?? 0) worldPx=\(Int(worldPx)) effZoom=\(effZoom) viewW=\(Int(viewW)) viewH=\(Int(viewH)) zoom=\(zoom) window=\(view.window?.frame.size.width ?? 0)x\(view.window?.frame.size.height ?? 0)")
            }
            // 相机只在场景/窗口尺寸/间隔变化时重设（每帧 reset 会导致永不跳点）
            if cameraJumpInterval != 0 {
                let cfg = CameraConfig(worldPx: worldPx, w: viewW, h: viewH, interval: cameraJumpInterval)
                if cameraConfig != cfg {
                    cameraConfig = cfg
                    self.camera.reset(mapSizePx: worldPx, viewW: viewW, viewH: viewH,
                                      switchInterval: cameraJumpInterval)
                }
            }
            self.camera.update(dt: dt, mapSizePx: worldPx, viewW: viewW, viewH: viewH)
            cs.scene.brightness = brightness
            cs.scene.prepare(viewport: SceneViewport(
                                 viewLeft: camera.center.x - viewW / 2,
                                 viewTop: camera.center.y - viewH / 2,
                                 viewWidth: viewW,
                                 viewHeight: viewH),
                             timeMs: elapsedMs,
                             cameraAtRest: camera.isAtRest)
        }

        if let cs = current, let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable {
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            cs.scene.render(to: pass, wait: false)
            drawable.present()
        }
    }
}
