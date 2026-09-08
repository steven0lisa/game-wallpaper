import AppKit

/// heroes3 风格 About 对话框。
///
/// 视觉还原自 VCMI `CMessage::drawBorder`（client/windows/CMessage.cpp）：
/// DIALGBOX.def 的帧按 4 角 + 4 边平铺成边框（角贴、边沿轴步进），内部用
/// dialogbox_8（深蓝）平铺作背景；中央循环播放 cangel.def 的天使待机动画；
/// 下方 IOKAY32 精灵作 OK 按钮。文案走系统本地化。
final class AboutWindowController: NSWindowController {
    private let content = AboutContent()

    init() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 380),
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

    let author = "steven0lisa"
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

/// heroes3 对话框边框绘制：内部 DIBOXBCK 纸底平铺 + DIALGBOX 四角/四边
/// （对齐 VCMI CMessage::drawBorder——box[0..7]，box[8..10] 的内部是色键不作背景）。
final class Heroes3BorderView: NSView {
    var content: AboutContent?
    var borderColor: NSColor = #colorLiteral(red: 0.22, green: 0.30, blue: 0.55, alpha: 1) { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        guard let content else {
            NSColor.windowBackgroundColor.setFill(); bounds.fill()
            return
        }
        let w = bounds.width, h = bounds.height
        // 内部填充：DIBOXBCK.PCX 棕色纸纹理平铺（VCMI CFilledTexture::showAll 同款；
        // drawBorder 只画边框 box[0..7]，box[8..10] 不是内部背景，其内部是色键）
        if let bg = content.background {
            let tile = bg.size
            var y: CGFloat = 0
            while y < h {
                var x: CGFloat = 0
                while x < w {
                    bg.draw(in: NSRect(x: x, y: y, width: tile.width, height: tile.height),
                             from: NSRect(origin: .zero, size: tile), operation: .copy, fraction: 1)
                    x += tile.width
                }
                y += tile.height
            }
        } else {
            NSColor(calibratedRed: 0.19, green: 0.13, blue: 0.08, alpha: 1).setFill()
            bounds.fill()
        }

        // 定义边框厚度
        let cornerW: CGFloat = 64, cornerH: CGFloat = 64
        let topH: CGFloat = 15, sideW: CGFloat = 14

        func draw(_ frame: NSImage?, in rect: NSRect) {
            guard let frame else { return }
            let size = frame.size
            frame.draw(in: rect,
                       from: NSRect(origin: .zero, size: size), operation: .copy, fraction: 1)
        }

        // 4 角
        draw(content.borderFrames[0], in: NSRect(x: 0, y: 0, width: cornerW, height: cornerH))
        draw(content.borderFrames[1], in: NSRect(x: w - cornerW, y: 0, width: cornerW, height: cornerH))
        draw(content.borderFrames[2], in: NSRect(x: 0, y: h - cornerH, width: cornerW, height: cornerH))
        draw(content.borderFrames[3], in: NSRect(x: w - cornerW, y: h - cornerH, width: cornerW, height: cornerH))

        // 上下边（沿 x 步进到 stop，tile 顶部/底部中央段）
        let stopX = w - cornerW
        var sx = cornerW
        while sx < stopX {
            draw(content.borderFrames[6], in: NSRect(x: sx, y: 0, width: 64, height: topH))
            draw(content.borderFrames[7], in: NSRect(x: sx, y: h - topH, width: 64, height: topH))
            sx += 64
        }

        // 左右边（沿 y 步进）
        let stopY = h - cornerH
        var sy = cornerH
        while sy < stopY {
            draw(content.borderFrames[4], in: NSRect(x: 0, y: sy, width: sideW, height: 64))
            draw(content.borderFrames[5], in: NSRect(x: w - sideW, y: sy, width: sideW, height: 64))
            sy += 64
        }
    }
}

/// About 窗口主视图：背景边框 + Logo 动画 + 文案 + OK 按钮。
final class AboutView: NSView {
    private let content: AboutContent
    private let borderView = Heroes3BorderView()
    private let logoView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let versionLabel = NSTextField(labelWithString: "")
    private let authorLabel = NSTextField(labelWithString: "")
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

        authorLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        authorLabel.stringValue = NSLocalizedString("About.Author", value: "By steven0lisa", comment: "作者")

        copyrightLabel.font = NSFont.systemFont(ofSize: 11)
        copyrightLabel.stringValue = content.copyright
        copyrightLabel.textColor = #colorLiteral(red: 0.6, green: 0.58, blue: 0.5, alpha: 1)

        logoView.imageScaling = .scaleNone
        logoView.imageFrameStyle = .none
        logoView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(logoView)

        for v in [nameLabel, versionLabel, authorLabel, copyrightLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }

        // OK 按钮：用 IOKAY32 0 帧作图片
        okButton.bezelStyle = .regularSquare
        okButton.isBordered = false
        okButton.imagePosition = .imageOnly
        if let ok = content.okFrames.first {
            okButton.image = ok
        }
        okButton.title = NSLocalizedString("About.OK", value: "OK", comment: "OK")
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

            logoView.centerXAnchor.constraint(equalTo: centerXAnchor),
            logoView.topAnchor.constraint(equalTo: topAnchor, constant: 74),
            logoView.widthAnchor.constraint(equalToConstant: 128),
            logoView.heightAnchor.constraint(equalToConstant: 103),

            nameLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            nameLabel.topAnchor.constraint(equalTo: logoView.bottomAnchor, constant: 18),
            nameLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 70),

            versionLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            versionLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 4),

            authorLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            authorLabel.topAnchor.constraint(equalTo: versionLabel.bottomAnchor, constant: 12),

            copyrightLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            copyrightLabel.topAnchor.constraint(equalTo: authorLabel.bottomAnchor, constant: 6),

            okButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            okButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -24),
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
