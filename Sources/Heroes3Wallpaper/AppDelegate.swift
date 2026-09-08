import AppKit
import MetalKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var windowController: WallpaperWindowController?
    private var presenter: MapPresenter?
    private var renderer: MapRenderer?

    private var webServer: MapWebServer?

    private var mapsFolder: URL {
        let saved = UserDefaults.standard.string(forKey: "mapsFolder")
        if let saved, FileManager.default.fileExists(atPath: saved) {
            return URL(fileURLWithPath: saved)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/vcmi/Maps")
    }

    private var dataDir: URL {
        let saved = UserDefaults.standard.string(forKey: "dataDir")
        if let saved, FileManager.default.fileExists(atPath: saved) {
            return URL(fileURLWithPath: saved)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/vcmi")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let renderer = try? MapRenderer(device: device) else {
            NSLog("Heroes3Wallpaper: Metal unavailable")
            return
        }
        self.renderer = renderer

        let presenter = MapPresenter(renderer: renderer)
        presenter.zoom = Float(UserDefaults.standard.double(forKey: "zoom").nonZero ?? 2.0) // 默认 2×
        presenter.brightness = Float(UserDefaults.standard.double(forKey: "brightness"))
        presenter.mapCycleInterval = UserDefaults.standard.double(forKey: "mapCycleSeconds").nonZero ?? 900
        let library = AssetLibrary(lodURL: dataDir.appendingPathComponent("Data/H3sprite.lod"))
        NSLog("Heroes3Wallpaper: library %@ mapsFolder=%@", library != nil ? "loaded" : "FAILED", mapsFolder.path)
        presenter.library = library
        self.presenter = presenter

        let floating = CommandLine.arguments.contains("--level-floating") // verification aid
        let controller = WallpaperWindowController(renderer: renderer, floating: floating)
        controller.view.delegate = presenter
        self.windowController = controller

        // Web 地图查看器：点击菜单项时才启动服务（省内存/CPU）
        self.webServer = MapWebServer(presenter: presenter)

        loadMaps()
        buildMenu()
    }

    private func loadMaps() {
        let folder = mapsFolder
        let urls = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? [])
            .filter { $0.pathExtension.lowercased() == "h3m" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        presenter?.setMaps(urls.isEmpty ? Self.bundledMaps() : urls)
        updateMenuTitle()
    }

    static func bundledMaps() -> [URL] {
        Bundle.main.urls(forResourcesWithExtension: "h3m", subdirectory: nil) ?? []
    }

    // MARK: - Status item menu

    private lazy var mapTitleItem = NSMenuItem(title: "Heroes 3 Wallpaper", action: nil, keyEquivalent: "")
    private var zoomItems: [NSMenuItem] = []
    private let pauseItem = NSMenuItem(title: "Pause", action: #selector(togglePause), keyEquivalent: "p")

    private func buildMenu() {
        let menu = NSMenu()

        mapTitleItem.isEnabled = false
        menu.addItem(mapTitleItem)
        menu.addItem(.separator())

        let next = NSMenuItem(title: "Next Map Now", action: #selector(nextMap), keyEquivalent: "n")
        next.target = self
        menu.addItem(next)

        pauseItem.target = self
        menu.addItem(pauseItem)
        menu.addItem(.separator())

        let zoomMenu = NSMenu()
        for (i, label) in ["1×", "2×", "3×", "4×"].enumerated() {
            let item = NSMenuItem(title: "Zoom \(label)", action: #selector(setZoom(_:)), keyEquivalent: "")
            item.tag = i
            item.target = self
            item.state = i == Int(presenter?.zoom ?? 2).clampedZoomIndex ? .on : .off
            zoomMenu.addItem(item)
            zoomItems.append(item)
        }
        let zoomRoot = NSMenuItem(title: "Zoom", action: nil, keyEquivalent: "")
        zoomRoot.submenu = zoomMenu
        menu.addItem(zoomRoot)

        let brightMenu = NSMenu()
        for (i, pct) in [0, 10, 20, 30, 40, 50, 60].enumerated() {
            let item = NSMenuItem(title: "\(pct)% darker", action: #selector(setBrightness(_:)), keyEquivalent: "")
            item.tag = i
            item.target = self
            brightMenu.addItem(item)
        }
        let brightRoot = NSMenuItem(title: "Brightness", action: nil, keyEquivalent: "")
        brightRoot.submenu = brightMenu
        menu.addItem(brightRoot)
        menu.addItem(.separator())

        let openFolder = NSMenuItem(title: "Choose Maps Folder…", action: #selector(chooseMapsFolder), keyEquivalent: "")
        openFolder.target = self
        menu.addItem(openFolder)

        let openMap = NSMenuItem(title: "Open Map…", action: #selector(chooseSingleMap), keyEquivalent: "o")
        openMap.target = self
        menu.addItem(openMap)

        let viewer = NSMenuItem(title: "Map Viewer（浏览器查看地图）", action: #selector(openMapViewer), keyEquivalent: "m")
        viewer.target = self
        menu.addItem(viewer)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Heroes 3 Wallpaper", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "🏰"
        item.menu = menu
        statusItem = item
    }

    private func updateMenuTitle() {
        let name = presenter?.current?.url.lastPathComponent
            ?? (presenter?.loading == true ? "Loading…" : "No map loaded")
        mapTitleItem.title = "Heroes 3 Wallpaper — \(name)"
    }

    @objc private func nextMap() {
        presenter?.nextMap()
        updateMenuTitle()
    }

    @objc private func togglePause() {
        guard let presenter else { return }
        presenter.paused.toggle()
        pauseItem.title = presenter.paused ? "Resume" : "Pause"
    }

    @objc private func setZoom(_ sender: NSMenuItem) {
        let zoom = Float([1.0, 2.0, 3.0, 4.0][sender.tag])
        presenter?.zoom = zoom // screen px per map px
        for (i, item) in zoomItems.enumerated() { item.state = i == sender.tag ? .on : .off }
        UserDefaults.standard.set(Double(zoom), forKey: "zoom")
    }

    @objc private func setBrightness(_ sender: NSMenuItem) {
        let pct = [0.0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6][sender.tag]
        presenter?.brightness = Float(pct)
        UserDefaults.standard.set(pct, forKey: "brightness")
    }

    @objc private func chooseMapsFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = mapsFolder
        if panel.runModal() == .OK, let url = panel.url {
            UserDefaults.standard.set(url.path, forKey: "mapsFolder")
            loadMaps()
        }
    }

    @objc private func chooseSingleMap() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedFileTypes = ["h3m"]
        if panel.runModal() == .OK {
            UserDefaults.standard.set(panel.urls.first?.deletingLastPathComponent().path ?? mapsFolder.path, forKey: "mapsFolder")
            presenter?.setMaps(Array(panel.urls))
            updateMenuTitle()
        }
    }

    @objc private func openMapViewer() {
        guard let webServer else { return }
        let url = webServer.startAndGetURL() // 首次点击时才 bind+listen
        NSWorkspace.shared.open(url)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

private extension Double {
    var nonZero: Double? { self != 0 ? self : nil }
}

private extension Int {
    var clampedZoomIndex: Int { Swift.min(Swift.max(self - 1, 0), 3) }
}
