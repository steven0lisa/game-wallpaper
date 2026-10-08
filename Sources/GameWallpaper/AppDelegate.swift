import AppKit
import MetalKit
import WallpaperCore
import Heroes3Engine

/// 装配层：选择引擎（当前注册 Heroes3Engine）、创建壁纸壳组件、挂菜单栏 UI。
/// 接入新引擎时在 applicationDidFinishLaunching 里替换/扩展 engine 的构造即可。
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var windowController: WallpaperWindowController?
    private var presenter: WallpaperPresenter?
    private var aboutController: AboutWindowController?
    private var webServer: MapWebServer?
    private var engine: Heroes3Engine?

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
        return Heroes3Engine.defaultDataDir()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let engine = try? Heroes3Engine(device: device, dataDir: dataDir) else {
            NSLog("GameWallpaper: Metal unavailable or Heroes3 assets missing (dataDir=\(dataDir.path))")
            return
        }
        self.engine = engine

        let presenter = WallpaperPresenter(engine: engine)
        presenter.zoom = Float(UserDefaults.standard.double(forKey: "zoom").nonZero ?? 2.0) // 默认 2×
        presenter.brightness = Float(UserDefaults.standard.double(forKey: "brightness"))
        presenter.mapCycleInterval = UserDefaults.standard.double(forKey: "mapCycleSeconds").nonZero ?? 900
        NSLog("GameWallpaper: engine %@ ready, dataDir=%@ mapsFolder=%@",
              Heroes3Engine.engineID, dataDir.path, mapsFolder.path)
        self.presenter = presenter

        let floating = CommandLine.arguments.contains("--level-floating") // verification aid
        let controller = WallpaperWindowController(device: device, floating: floating)
        controller.view.delegate = presenter
        presenter.renderView = controller.view // 电池模式经此 isPaused 停/启渲染循环
        self.windowController = controller

        // Web 地图查看器：点击菜单项时才启动服务（省内存/CPU）
        self.webServer = MapWebServer(presenter: presenter, engine: engine)
        // 换图后作废 viewer 的场景缓存（持有整份图集页像素拷贝，不释放则驻留旧图内存）
        presenter.onSceneChanged = { [weak self] in
            self?.webServer?.invalidateSceneCache()
        }

        loadMaps()
        buildMenu()

        // 启动参数 --about：打开 app 后直接弹出 About 窗口（也用于无头验证）
        if CommandLine.arguments.contains("--about") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                self?.showAbout()
            }
        }
    }

    private func loadMaps() {
        let folder = mapsFolder
        let urls = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? [])
            .filter { Self.sceneExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        presenter?.setMaps(urls.isEmpty ? Self.bundledScenes() : urls)
        updateMenuTitle()
    }

    static let sceneExtensions = Heroes3Engine.sceneExtensions

    static func bundledScenes() -> [URL] {
        sceneExtensions.flatMap { ext in
            Bundle.main.urls(forResourcesWithExtension: ext, subdirectory: nil) ?? []
        }
    }

    // MARK: - Status item menu

    private lazy var sceneTitleItem = NSMenuItem(title: "Game Wallpaper", action: nil, keyEquivalent: "")
    private var zoomItems: [NSMenuItem] = []
    private let pauseItem = NSMenuItem(title: NSLocalizedString("Menu.Pause", value: "Pause", comment: ""), action: #selector(togglePause), keyEquivalent: "p")

    private let aboutItem = NSMenuItem(title: NSLocalizedString("Menu.About", value: "About Game Wallpaper…", comment: ""), action: #selector(showAbout), keyEquivalent: "")

    private func buildMenu() {
        let menu = NSMenu()

        sceneTitleItem.isEnabled = false
        menu.addItem(sceneTitleItem)
        menu.addItem(.separator())

        let next = NSMenuItem(title: NSLocalizedString("Menu.NextMap", value: "Next Map Now", comment: ""), action: #selector(nextMap), keyEquivalent: "n")
        next.target = self
        menu.addItem(next)

        pauseItem.target = self
        menu.addItem(pauseItem)
        menu.addItem(.separator())

        let zoomMenu = NSMenu()
        for (i, label) in ["1×", "2×", "3×", "4×"].enumerated() {
            let item = NSMenuItem(title: NSLocalizedString("Menu.Zoom", value: "Zoom", comment: "") + " \(label)", action: #selector(setZoom(_:)), keyEquivalent: "")
            item.tag = i
            item.target = self
            item.state = i == Int(presenter?.zoom ?? 2).clampedZoomIndex ? .on : .off
            zoomMenu.addItem(item)
            zoomItems.append(item)
        }
        let zoomRoot = NSMenuItem(title: NSLocalizedString("Menu.Zoom", value: "Zoom", comment: ""), action: nil, keyEquivalent: "")
        zoomRoot.submenu = zoomMenu
        menu.addItem(zoomRoot)

        let brightMenu = NSMenu()
        for (i, pct) in [0, 10, 20, 30, 40, 50, 60].enumerated() {
            let item = NSMenuItem(title: NSLocalizedString("Menu.Darker", value: "Darker", comment: "") + " \(pct)%", action: #selector(setBrightness(_:)), keyEquivalent: "")
            item.tag = i
            item.target = self
            brightMenu.addItem(item)
        }
        let brightRoot = NSMenuItem(title: NSLocalizedString("Menu.Brightness", value: "Brightness", comment: ""), action: nil, keyEquivalent: "")
        brightRoot.submenu = brightMenu
        menu.addItem(brightRoot)
        menu.addItem(.separator())

        let openFolder = NSMenuItem(title: NSLocalizedString("Menu.ChooseMapsFolder", value: "Choose Maps Folder…", comment: ""), action: #selector(chooseMapsFolder), keyEquivalent: "")
        openFolder.target = self
        menu.addItem(openFolder)

        let openMap = NSMenuItem(title: NSLocalizedString("Menu.OpenMap", value: "Open Map…", comment: ""), action: #selector(chooseSingleMap), keyEquivalent: "o")
        openMap.target = self
        menu.addItem(openMap)

        let viewer = NSMenuItem(title: NSLocalizedString("Menu.MapViewer", value: "Map Viewer", comment: ""), action: #selector(openMapViewer), keyEquivalent: "m")
        viewer.target = self
        menu.addItem(viewer)
        menu.addItem(.separator())

        aboutItem.target = self
        menu.addItem(aboutItem)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: NSLocalizedString("Menu.Quit", value: "Quit Game Wallpaper", comment: ""), action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "🎮"
        item.menu = menu
        statusItem = item
    }

    private func updateMenuTitle() {
        let engineName = engine.map { type(of: $0).displayName } ?? ""
        let name = presenter?.current?.url.lastPathComponent
            ?? (presenter?.loading == true ? NSLocalizedString("Menu.Loading", value: "Loading…", comment: "") : NSLocalizedString("Menu.NoMap", value: "No map loaded", comment: ""))
        sceneTitleItem.title = engineName.isEmpty ? "Game Wallpaper — \(name)" : "\(engineName) — \(name)"
    }

    @objc private func nextMap() {
        presenter?.nextMap()
        updateMenuTitle()
    }

    @objc private func togglePause() {
        guard let presenter else { return }
        presenter.paused.toggle()
        pauseItem.title = presenter.paused ? NSLocalizedString("Menu.Resume", value: "Resume", comment: "") : NSLocalizedString("Menu.Pause", value: "Pause", comment: "")
    }

    @objc private func showAbout() {
        if aboutController == nil {
            aboutController = AboutWindowController()
        }
        aboutController?.show()
    }

    @objc private func setZoom(_ sender: NSMenuItem) {
        let zoom = Float([1.0, 2.0, 3.0, 4.0][sender.tag])
        presenter?.zoom = zoom // screen px per world px
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
        panel.allowedFileTypes = Self.sceneExtensions
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
