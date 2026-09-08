import AppKit

/// heroes3 风格 About 对话框。
///
/// 视觉还原自 VCMI `CMessage::drawBorder`（client/windows/CMessage.cpp）：
/// DIALGBOX.def 的帧按 4 角 + 4 边平铺成边框（角贴、边沿轴步进），内部平铺
/// DIBOXBCK.PCX 棕纸作背景；中央循环播放 cangel.def 的天使待机动画；
/// 下方 IOKAY32 精灵作 OK 按钮。文案走系统本地化。
final class AboutWindowController: NSWindowController {
    private let content = AboutContent()

    init() {
        // 窗口 = DIALGBOX 边框画布，尺寸取 64px 网格（128 + 64k）：512×448。
        // 边条恰好铺满：上下各 6 条、左右各 5 条、四角各一，无裁切、无重叠、无缝隙。
        // 内容区 = 内缩 左右 14 / 上下 15 → 484×418。
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 512, height: 448),
                           styleMask: .borderless,
                           backing: .buffered,
                           defer: false)
        win.isReleasedWhenClosed = false
        win.level = .floating
        win.styleMask.insert(.nonactivatingPanel)
        win.animationBehavior = .utilityWindow
        win.isMovableByWindowBackground = true
        win.hasShadow = true
        let view = AboutView(content: content)
        win.contentView = view
        win.contentMinSize = NSSize(width: 400, height: 320)
        win.center()
        super.init(window: win)
    }

    required init?(coder: NSCoder) { nil }

    func show() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        debugLog("ABOUT show() window=\(String(describing: window)) logoCount=\(content.logoCount) borderFrames=\(content.borderFrames.count) okFrames=\(content.okFrames.count) appName=\(content.appName) version=\(content.version)")
        // 打开瞬间就开始循环动画
        (window?.contentView as? AboutView)?.startAnimation()
    }
}

/// About 窗口的内容数据源：从打包资源加载精灵帧 + 本地化文案。
final class AboutContent {
    /// 天使 Logo 帧序列（cangel.def block 0 的 7 帧 idle 动画）。
    private(set) var logoFrames: [NSImage] = []
    /// 边框：DIALGBOX.def block 0。索引 0..3 = 四角，4/5 = 左右边，6/7 = 上下边，8 = 内部填充。
    private(set) var borderFrames: [Int: NSImage] = [:]
    /// OK 按钮 4 帧（released / pressed / disabled / blocked）。
    private(set) var okFrames: [NSImage] = []
    /// 对话框内部棕色纸底（DIBOXBCK.PCX，平铺）。
    private(set) var background: NSImage?

    let appName: String
    let version: String
    let copyright: String

    init() {
        let bundle = Bundle.main
        appName = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Heroes 3 Wallpaper"
        let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        version = "\(short)-\(build)"   // x.y.z-build_number
        copyright = bundle.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String ?? ""
        loadAssets()
    }

    private func loadAssets() {
        let base = Bundle.main.resourceURL?.appendingPathComponent("about")
        func img(_ name: String) -> NSImage? {
            guard let url = base?.appendingPathComponent(name + ".png"),
                  let img = NSImage(contentsOf: url) else { return nil }
            return img
        }
        for i in 0..<7 {
            if let im = img("logo_\(i)") { logoFrames.append(im) }
        }
        for i in 0..<11 {
            if let im = img("dialogbox_\(i)") { borderFrames[i] = im }
        }
        for i in 0..<4 {
            if let im = img("iokay32_\(i)") { okFrames.append(im) }
        }
        background = img("background")
    }

    var logoCount: Int { max(logoFrames.count, 1) }
    func logoFrame(_ i: Int) -> NSImage? { logoFrames.isEmpty ? nil : logoFrames[i % logoFrames.count] }
}

/// heroes3 对话框绘制：还原 VCMI BORDERED 窗口布局——
/// 边框（DIALGBOX box[0..7]）围在内容区四周（外扩 左右 14px / 上下 15px），
/// 内部是 DIBOXBCK.PCX 棕纸纹理平铺（CFilledTexture），box[8..10] 不参与。
/// 与 VCMI 的差异：窗口尺寸取 64px 网格对齐（128+64k），边条恰好铺满，
/// 故无需 VCMI drawBorder 里 bottom/right 的 +1 重叠补缝。
final class Heroes3BorderView: NSView {
    var content: AboutContent?
    var borderColor: NSColor = #colorLiteral(red: 0.22, green: 0.30, blue: 0.55, alpha: 1) { didSet { needsDisplay = true } }

    /// VCMI BORDERED 的边框外扩量：左右 14px、上下 15px（角 64 覆盖其上）。
    static let borderLeft: CGFloat = 14
    static let borderTop: CGFloat = 15

    override func draw(_ dirtyRect: NSRect) {
        guard let content else {
            NSColor.windowBackgroundColor.setFill(); bounds.fill()
            return
        }
        let w = bounds.width, h = bounds.height
        let bx = Self.borderLeft, by = Self.borderTop          // 内容区内缩：左右 14 / 上下 15
        let cw = w - 2 * bx, ch = h - 2 * by                   // 内容区尺寸

        // 0) 整窗兜底：边框贴图透明缝隙处不能露窗口白底，用取自 DIBOXBCK 的深棕色
        NSColor(calibratedRed: 0.19, green: 0.13, blue: 0.08, alpha: 1).setFill()
        bounds.fill()

        // 1) 内容区：DIBOXBCK 棕纸平铺（限内容区，VCMI CFilledTexture 在 pos 内）
        if let bg = content.background {
            let tile = bg.size
            var y = by
            while y < by + ch {
                var x = bx
                while x < bx + cw {
                    bg.draw(in: NSRect(x: x, y: y, width: tile.width, height: tile.height),
                            from: NSRect(origin: .zero, size: tile), operation: .sourceOver, fraction: 1)
                    x += tile.width
                }
                y += tile.height
            }
        }

        // 2) 边框：以整窗为画布，SDL 顶左坐标（y 向下）标注贴图位置，
        //    drawSDL 负责翻转到 NSView 底左坐标；透明像素必须 sourceOver
        //    （.copy 会把色键打穿露底）。
        func drawSDL(_ frame: NSImage?, _ sdlX: CGFloat, _ sdlY: CGFloat) {
            guard let frame else { return }
            let size = frame.size
            frame.draw(in: NSRect(x: sdlX, y: h - sdlY - size.height,
                                  width: size.width, height: size.height),
                       from: NSRect(origin: .zero, size: size),
                       operation: .sourceOver, fraction: 1)
        }

        // 上下边（box[6]/box[7]，64×15）：x 从 64 到 w-128，网格对齐恰好铺满
        var sx: CGFloat = 64
        while sx < w - 64 {
            drawSDL(content.borderFrames[6], sx, 0)
            drawSDL(content.borderFrames[7], sx, h - 15)
            sx += 64
        }

        // 左右边（box[4]/box[5]，14×64）：y 从 64 到 h-128，网格对齐恰好铺满
        var sy: CGFloat = 64
        while sy < h - 64 {
            drawSDL(content.borderFrames[4], 0, sy)
            drawSDL(content.borderFrames[5], w - 14, sy)
            sy += 64
        }

        // 四角（box[0..3]，64×64）
        drawSDL(content.borderFrames[0], 0, 0)
        drawSDL(content.borderFrames[1], w - 64, 0)
        drawSDL(content.borderFrames[2], 0, h - 64)
        drawSDL(content.borderFrames[3], w - 64, h - 64)
    }
}

/// About 窗口主视图：背景边框 + Logo 动画 + 文案 + OK 按钮。
final class AboutView: NSView {
    private let content: AboutContent
    private let borderView = Heroes3BorderView()
    private let logoView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let versionLabel = NSTextField(labelWithString: "")
    private let copyrightLabel = NSTextField(labelWithString: "")
    private let okButton = NSButton()
    private var timer: Timer?
    private var frameIndex = 0

    init(content: AboutContent) {
        self.content = content
        super.init(frame: .zero)
        wantsLayer = true
        setup()
    }

    required init?(coder: NSCoder) { nil }

    private func setup() {
        borderView.content = content
        borderView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(borderView)

        // 文案（本地化）
        nameLabel.font = NSFont.boldSystemFont(ofSize: 20)
        nameLabel.textColor = #colorLiteral(red: 0.98, green: 0.86, blue: 0.55, alpha: 1)
        nameLabel.stringValue = content.appName
        nameLabel.alignment = .center

        versionLabel.font = NSFont.systemFont(ofSize: 12)
        versionLabel.stringValue = "v\(content.version)"
        versionLabel.textColor = #colorLiteral(red: 0.75, green: 0.72, blue: 0.62, alpha: 1)

        copyrightLabel.font = NSFont.systemFont(ofSize: 11)
        copyrightLabel.stringValue = content.copyright
        copyrightLabel.textColor = #colorLiteral(red: 0.6, green: 0.58, blue: 0.5, alpha: 1)

        logoView.imageScaling = .scaleNone
        logoView.imageFrameStyle = .none
        logoView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(logoView)

        for v in [nameLabel, versionLabel, copyrightLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }

        // OK 按钮：用 IOKAY32 0 帧作图片
        okButton.bezelStyle = .regularSquare
        okButton.isBordered = false
        okButton.imagePosition = .imageOnly
        if let ok = content.okFrames.first {
            okButton.image = ok   // IOKAY32 帧自带金色对勾，不再叠文字
        }
        okButton.controlSize = .large
        okButton.target = self
        okButton.action = #selector(okPressed)
        okButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(okButton)

        NSLayoutConstraint.activate([
            borderView.topAnchor.constraint(equalTo: topAnchor),
            borderView.bottomAnchor.constraint(equalTo: bottomAnchor),
            borderView.leadingAnchor.constraint(equalTo: leadingAnchor),
            borderView.trailingAnchor.constraint(equalTo: trailingAnchor),

            // 以下内容都落在边框内的内容区（上/下让出 borderTop=15，左右让出 14）
            logoView.centerXAnchor.constraint(equalTo: centerXAnchor),
            logoView.topAnchor.constraint(equalTo: topAnchor,
                                          constant: 74 + Heroes3BorderView.borderTop),
            logoView.widthAnchor.constraint(equalToConstant: 128),
            logoView.heightAnchor.constraint(equalToConstant: 103),

            nameLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            nameLabel.topAnchor.constraint(equalTo: logoView.bottomAnchor, constant: 18),
            nameLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor,
                                               constant: 70 + Heroes3BorderView.borderLeft),

            versionLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            versionLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 4),

            copyrightLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            copyrightLabel.topAnchor.constraint(equalTo: versionLabel.bottomAnchor, constant: 12),

            okButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            okButton.bottomAnchor.constraint(equalTo: bottomAnchor,
                                             constant: -24 - Heroes3BorderView.borderTop),
            okButton.widthAnchor.constraint(equalToConstant: 66),
            okButton.heightAnchor.constraint(equalToConstant: 32),
        ])
    }

    /// 开始循环播放天使动画。
    func startAnimation() {
        guard content.logoCount > 1 else { return }
        frameIndex = 0
        showFrame()
        timer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: true) { [weak self] _ in
            self?.frameIndex += 1
            self?.showFrame()
        }
    }

    private func showFrame() {
        logoView.image = content.logoFrame(frameIndex)
    }

    @objc private func okPressed() {
        window?.close()
    }

    func stopAnimation() {
        timer?.invalidate()
        timer = nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // 窗口显示时启动、关闭时停止，避免后台timer空转
    }
}
