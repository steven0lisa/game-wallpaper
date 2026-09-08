import AppKit
import MetalKit
import IOKit.ps

/// Full-screen borderless window pinned at the desktop level — the classic macOS
/// "live wallpaper" technique (same approach as Plash): the window sits behind
/// desktop icons and in front of the static wallpaper image, on every Space.
final class WallpaperWindowController {
    private var windows: [NSWindow] = []
    let view: MTKView
    /// 屏幕休眠期间暂停渲染循环（DisplayLink 停发回调本应自然省电，但 MTKView
    /// 常驻 timer 仍可能空转；显式 isPaused 兜底，唤醒即恢复）。
    private var sleepObserver: (Any, NSObjectProtocol)?

    init(renderer: MapRenderer, floating: Bool = false) {
        view = MTKView(frame: .zero, device: renderer.device)
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .invalid
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.preferredFramesPerSecond = 30

        for screen in NSScreen.screens {
            let win = NSWindow(contentRect: screen.frame,
                               styleMask: .borderless,
                               backing: .buffered,
                               defer: false)
            if floating {
                win.level = .floating
                win.ignoresMouseEvents = false
            } else {
                win.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
            }
            win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            win.isOpaque = false
            win.backgroundColor = .clear
            win.hasShadow = false
            win.ignoresMouseEvents = true
            win.contentView = view
            win.orderFrontRegardless()
            windows.append(win)
        }

        // 屏幕休眠（显示器关闭）时暂停 Metal 渲染循环，唤醒后自动恢复。
        // 定义队列 nil = 投递到主线程，与 MTKView 的线程约束一致。
        let center = NSWorkspace.shared.notificationCenter
        sleepObserver = (center,
                         center.addObserver(forName: NSWorkspace.screensDidSleepNotification,
                                            object: nil, queue: .main) { [weak view] _ in
            view?.isPaused = true
        })
        center.addObserver(forName: NSWorkspace.screensDidWakeNotification,
                           object: nil, queue: .main) { [weak view] _ in
            view?.isPaused = false
        }
    }

    func hide() {
        for win in windows { win.orderOut(nil) }
        windows.removeAll()
        if let (center, token) = sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
            sleepObserver = nil
        }
    }
}

/// Owns the loaded maps, the camera, and the render loop.
final class MapPresenter: NSObject, MTKViewDelegate {
    /// 诊断：首帧输出一次 drawable/zoom 数据，定位壁纸未铺满问题
    fileprivate static var _diagCount = 0
    let renderer: MapRenderer
    private(set) var current: CurrentMap?
    var paused = false
    /// User zoom preference (1 = 1×, 2 = 2×, …). The effective zoom never drops below the
    /// cover zoom for the current map/screen, so the wallpaper always fills the screen
    /// without stretching (aspect ratio preserved).
    var zoom: Float = 1
    var brightness: Float {
        get { renderer.currentBrightness }
        set { renderer.currentBrightness = newValue }
    }
    var mapCycleInterval: TimeInterval = 900
    /// 跳点间隔（秒）—— 默认 3 分钟，电池模式不跳
    var cameraJumpInterval: TimeInterval = 180
    private var cycleElapsed: TimeInterval = 0

    struct CurrentMap {
        var url: URL
        var map: GameMap
        var atlas: FrameAtlas
    }

    var camera = Camera()
    /// 相机初始化参数（变化时才 reset —— 每帧 reset 会把跳点计时器和位置钉死在初始值）
    private struct CameraConfig: Equatable {
        var mapPx: Float
        var w: Float
        var h: Float
        var interval: TimeInterval
    }
    private var cameraConfig: CameraConfig?
    private var elapsedMs: Double = 0
    private var onBattery = false
    private var lastPowerCheck: CFTimeInterval = 0
    private var lastTimestamp: CFTimeInterval?
    private(set) var mapURLs: [URL] = []
    private var currentIndex = 0
    private(set) var loading = false
    /// 换图时回调（作废 WebViewer 场景缓存等）；由 AppDelegate 装配。
    var onMapChanged: (() -> Void)?

    init(renderer: MapRenderer) {
        self.renderer = renderer
    }

    /// Effective zoom: at least the cover zoom, so the map always covers the full view.
    private func effectiveZoom(mapSizePx: Float, viewW: Float, viewH: Float) -> Float {
        max(zoom, max(viewW / mapSizePx, viewH / mapSizePx))
    }

    // MARK: - Power source

    /// 电池供电（未接电源）返回 true；台式机/接电源返回 false
    static func onBatteryPower() -> Bool {
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

    // MARK: - Map loading

    func setMaps(_ urls: [URL], startAt index: Int = 0) {
        mapURLs = urls
        currentIndex = min(index, max(urls.count - 1, 0))
        if !mapURLs.isEmpty { loadCurrent() }
    }

    func nextMap() {
        guard mapURLs.count > 1 else { return }
        currentIndex = (currentIndex + 1) % mapURLs.count
        loadCurrent()
    }

    private func loadCurrent() {
        loading = true
        current = nil
        let url = mapURLs[currentIndex]
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let h3m = try H3mFile(url: url)
                guard let library = self.library else {
                    NSLog("Heroes3Wallpaper: no asset library")
                    return
                }
                let map = GameMap(h3m: h3m, library: library, level: 0)
                NSLog("Heroes3Wallpaper: parsed %@ objects=%d missing=%d", url.lastPathComponent, map.objects.count, library.missingDefs.count)
                let atlas = AtlasBuilder.build(map: map, library: library)
                DispatchQueue.main.async {
                    self.current = CurrentMap(url: url, map: map, atlas: atlas)
                    self.renderer.uploadAtlas(atlas)
                    self.camera = Camera()
                    // 旧地图的 viewer 场景副本（图集页像素拷贝）一并作废
                    self.onMapChanged?()
                    // mapSize/viewW/viewH 在第一次 draw 时会调用 reset()，无需传
                    self.cycleElapsed = 0
                    self.loading = false
                    NSLog("Heroes3Wallpaper: map ready, frames=%d", atlas.packedCount)
                    Self.logFootprint("map ready")
                }
            } catch {
                NSLog("Heroes3Wallpaper: failed to load %@: %@", url.lastPathComponent, String(describing: error))
                DispatchQueue.main.async {
                    self.loading = false
                    self.nextMap()
                }
            }
        }
    }

    /// 进程物理内存占用（footprint），用于观察换图周期内的内存回落。
    static func logFootprint(_ tag: String) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        guard task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO),
                        withUnsafeMutableBytes(of: &info) { $0.bindMemory(to: integer_t.self).baseAddress! },
                        &count) == KERN_SUCCESS else { return }
        NSLog("Heroes3Wallpaper: footprint %@ = %.0f MB", tag, Double(info.phys_footprint) / 1048576.0)
    }

    var library: AssetLibrary?

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = lastTimestamp.map { min(now - $0, 0.25) } ?? 0
        lastTimestamp = now

        // 电池供电：冻结漫游、刷新率降到 1fps 省电；每 3 秒复查供电状态
        if now - lastPowerCheck > 3 {
            lastPowerCheck = now
            onBattery = Self.onBatteryPower()
        }
        // 相机停留期（占绝大头）动画每 180ms 才变一步，5fps（200ms）采样足够覆盖每一步
        // 且消除约一半的重复帧提交；平移过渡保持 30fps，电池模式 1fps。
        let targetFps: Int
        if onBattery {
            targetFps = 1
        } else if camera.isAtRest {
            targetFps = 5
        } else {
            targetFps = 30
        }
        if view.preferredFramesPerSecond != targetFps {
            view.preferredFramesPerSecond = targetFps
        }

        if !paused, let cm = current {
            elapsedMs += dt * 1000
            cycleElapsed += dt
            if cycleElapsed >= mapCycleInterval {
                cycleElapsed = 0
                nextMap()
            }
            let drawableSize = view.drawableSize
            let mapSizePx = Float(cm.map.size * 32)
            // Cover zoom: the map always spans the entire screen (no letterboxing,
            // no border tiles), aspect ratio preserved.
            let effZoom = effectiveZoom(mapSizePx: mapSizePx,
                                        viewW: Float(drawableSize.width),
                                        viewH: Float(drawableSize.height))
            let viewW = Float(drawableSize.width) / effZoom
            let viewH = Float(drawableSize.height) / effZoom
            if Self._diagCount == 0 {
                Self._diagCount += 1
                debugLog("DIAG drawable=\(Int(drawableSize.width))x\(Int(drawableSize.height)) bounds=\(Int(view.bounds.width))x\(Int(view.bounds.height)) scale=\(view.window?.backingScaleFactor ?? 0) mapPx=\(Int(mapSizePx)) effZoom=\(effZoom) viewW=\(Int(viewW)) viewH=\(Int(viewH)) zoom=\(zoom) window=\(view.window?.frame.size.width ?? 0)x\(view.window?.frame.size.height ?? 0)")
            }
            // 相机只在地图/窗口尺寸/间隔变化时重设（每帧 reset 会导致永不跳点）
            if cameraJumpInterval != 0 {
                let cfg = CameraConfig(mapPx: mapSizePx, w: viewW, h: viewH, interval: cameraJumpInterval)
                if cameraConfig != cfg {
                    cameraConfig = cfg
                    self.camera.reset(mapSizePx: mapSizePx, viewW: viewW, viewH: viewH,
                                      switchInterval: cameraJumpInterval)
                }
            }
            // 电池模式：冻镜
            self.camera.setFrozen(onBattery)
            self.camera.update(dt: onBattery ? 0 : dt, mapSizePx: mapSizePx, viewW: viewW, viewH: viewH)
            if onBattery { self.camera.setFrozen(false) } // 恢复标志位（update 内已生效）
            renderer.buildFrame(map: cm.map, atlas: cm.atlas,
                                view: MapRenderer.Viewport(
                                    viewLeft: camera.center.x - viewW / 2,
                                    viewTop: camera.center.y - viewH / 2,
                                    viewWidth: viewW,
                                    viewHeight: viewH),
                                timeMs: elapsedMs,
                                cameraAtRest: camera.isAtRest)
        }

        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable else { return }
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        renderer.draw(to: pass, wait: false)
        view.currentDrawable?.present()
    }
}
