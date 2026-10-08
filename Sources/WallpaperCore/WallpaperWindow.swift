import AppKit
import MetalKit

/// Full-screen borderless window pinned at the desktop level — the classic macOS
/// "live wallpaper" technique (same approach as Plash): the window sits behind
/// desktop icons and in front of the static wallpaper image, on every Space.
public final class WallpaperWindowController {
    private var windows: [NSWindow] = []
    public let view: MTKView
    /// 屏幕休眠期间暂停渲染循环（DisplayLink 停发回调本应自然省电，但 MTKView
    /// 常驻 timer 仍可能空转；显式 isPaused 兜底，唤醒即恢复）。
    private var sleepObserver: (Any, NSObjectProtocol)?

    public init(device: MTLDevice, floating: Bool = false) {
        view = MTKView(frame: .zero, device: device)
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

    public func hide() {
        for win in windows { win.orderOut(nil) }
        windows.removeAll()
        if let (center, token) = sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
            sleepObserver = nil
        }
    }
}
