import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// 内置 Web 地图查看器服务：把当前地图（或按需加载的内置地图）以
/// 与 web/ 版完全兼容的 HTTP API 提供出去，浏览器直接打开即可查看。
/// 路由（与 web/server/Server.js 相同）：
///   /                     查看器页面（index.html + viewer.js，来自资源包 webviewer/）
///   /api/maps             内置地图列表
///   /api/scene?map=&level= 场景 JSON（frames/terrain/rivers/roads/objects/pages）
///   /atlas/<map>/level<N>-<ver>/atlas-N.png  图集页 PNG
final class MapWebServer {
    private weak var presenter: MapPresenter?
    private(set) var port = 0
    private var listenFD: Int32 = -1
    private var thread: Thread?
    private let lock = NSLock()
    /// 闲置超时：浏览器心跳（/api/ping，30s 间隔）停止超过该时长即退出服务省内存
    private let idleTimeout: TimeInterval = TimeInterval(UserDefaults.standard.integer(forKey: "viewerIdleSeconds") > 0 ? UserDefaults.standard.integer(forKey: "viewerIdleSeconds") : 1800)
    private var lastActivity: TimeInterval = 0

    /// 按需构建的场景缓存（只保留最近 1 个）
    private var cachedScene: ViewerScene?

    struct SceneBuildError: Error {}

    init(presenter: MapPresenter) {
        self.presenter = presenter
    }

    /// 启动（幂等），返回可打开的 URL
    func startAndGetURL() -> URL {
        lock.lock()
        if listenFD >= 0 {
            lock.unlock()
            return URL(string: "http://127.0.0.1:\(port)/?map=\(currentMapQuery())")!
        }
        lock.unlock()

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return URL(string: "http://127.0.0.1:0")! }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var port = 8766
        var bound = false
        for p in 8766...8786 {
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = UInt16(p).bigEndian
            addr.sin_addr = in_addr(s_addr: INADDR_ANY)
            let r = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if r == 0 { port = p; bound = true; break }
        }
        guard bound, listen(fd, 8) == 0 else { close(fd); return URL(string: "http://127.0.0.1:0")! }
        listenFD = fd
        self.port = port
        lastActivity = Date().timeIntervalSince1970

        let t = Thread { [weak self] in
            self?.acceptLoop()
        }
        t.name = "h3-webviewer"
        t.stackSize = 1 << 22
        t.start()
        thread = t
        NSLog("Heroes3Wallpaper: web viewer on http://127.0.0.1:%d", port)
        return URL(string: "http://127.0.0.1:\(port)/?map=\(currentMapQuery())")!
    }

    private func currentMapQuery() -> String {
        presenter?.current?.url.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
    }

    private func acceptLoop() {
        while listenFD >= 0 {
            // 闲置超时：浏览器心跳停止（页面关闭/机器休眠后不再点击）即退出服务
            if Date().timeIntervalSince1970 - lastActivity > idleTimeout {
                stopServer()
                return
            }
            var pfd = pollfd(fd: listenFD, events: Int16(POLLRDNORM), revents: 0)
            let r = poll(&pfd, 1, 1000)
            guard r > 0, listenFD >= 0 else { continue }
            var addr = sockaddr()
            var len = socklen_t(MemoryLayout<sockaddr>.size)
            let conn = accept(listenFD, &addr, &len)
            guard conn >= 0 else { continue }
            lastActivity = Date().timeIntervalSince1970
            handle(conn: conn)
            close(conn)
        }
    }

    /// 退出服务：关闭监听、释放场景缓存（图集页为大块内存）。下次点击菜单会重新启动。
    private func stopServer() {
        if listenFD >= 0 { close(listenFD) }
        listenFD = -1
        port = 0
        lock.lock()
        cachedScene = nil
        lock.unlock()
        NSLog("Heroes3Wallpaper: web viewer stopped (idle)")
    }

    private func handle(conn: Int32) {
        var buf = [UInt8](repeating: 0, count: 8192)
        var received = 0
        var headerDone = false
        while received < buf.count && !headerDone {
            let offset = received
            let cap = buf.count
            let n: Int = buf.withUnsafeMutableBytes { raw in
                recv(conn, raw.baseAddress!.advanced(by: offset), cap - offset, 0)
            }
            if n <= 0 { return }
            received += n
            let slice = buf[0..<received]
            let head = String(decoding: slice, as: UTF8.self)
            if head.contains("\r\n\r\n") { headerDone = true }
        }
        let head = String(decoding: buf[0..<received], as: UTF8.self)
        guard let line = head.split(separator: "\r\n").first else { return }
        let parts = line.split(separator: " ")
        guard parts.count >= 2 else { return }
        let rawPath = String(parts[1])

        guard let (status, type, body) = route(rawPath) else {
            respond(conn, status: "404 Not Found", type: "text/plain", body: Data("not found".utf8))
            return
        }
        respond(conn, status: status, type: type, body: body)
    }

    private func respond(_ conn: Int32, status: String, type: String, body: Data) {
        var head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        let hb = Data(head.utf8)
        _ = hb.withUnsafeBytes { send(conn, $0.baseAddress, hb.count, 0) }
        body.withUnsafeBytes { raw in
            var off = 0
            while off < body.count {
                let n = send(conn, raw.baseAddress!.advanced(by: off), body.count - off, 0)
                if n <= 0 { break }
                off += n
            }
        }
    }

    // MARK: - 路由

    private func route(_ rawPath: String) -> (String, String, Data)? {
        lastActivity = Date().timeIntervalSince1970
        guard let url = URLComponents(string: "http://x\(rawPath)") else { return nil }
        let path = url.path
        let query = url.queryItems ?? []

        if path == "/" || path.hasSuffix("/index.html") {
            return serveStatic("index.html", type: "text/html; charset=utf-8")
        }
        if path == "/viewer.js" {
            return serveStatic("viewer.js", type: "text/javascript; charset=utf-8")
        }
        if path == "/api/ping" {
            return ("200 OK", "text/plain", Data("pong".utf8))
        }
        if path == "/api/maps" {
            let names = (presenter?.mapURLs ?? []).map { $0.lastPathComponent }
            return ("200 OK", "application/json", Data("{\"maps\": [\(names.map { jsonStr($0) }.joined(separator: ","))]}".utf8))
        }
        if path == "/api/scene" {
            let name = query.first { $0.name == "map" }?.value ?? (presenter?.current?.url.lastPathComponent ?? "")
            let level = Int(query.first { $0.name == "level" }?.value ?? "0") ?? 0
            guard let scene = sceneForMap(named: name, level: level) else {
                return ("404 Not Found", "text/plain", Data("map not found".utf8))
            }
            return ("200 OK", "application/json", Data(scene.json.utf8))
        }
        if path.hasPrefix("/atlas/") {
            // /atlas/<map>/level<N>-<ver>/atlas-K.ext
            let parts = path.split(separator: "/").map(String.init)
            guard parts.count == 4, parts[0] == "atlas" else { return nil }
            let map = parts[1].removingPercentEncoding ?? parts[1]
            guard let scene = sceneForMap(named: map, level: 0) else { return nil }
            let file = parts[3]
            let idxStr = file.hasPrefix("atlas-") ? String(file.dropFirst("atlas-".count).dropLast(".png".count)) : ""
            guard let idx = Int(idxStr), idx < scene.pages.count else { return nil }
            let png = MapWebServer.encodePNG(width: FrameAtlas.pageSize, height: FrameAtlas.pageSize,
                                rgba: scene.pages[idx]) ?? Data()
            return ("200 OK", "image/png", png)
        }
        return nil
    }

    private func serveStatic(_ name: String, type: String) -> (String, String, Data)? {
        guard var url = Bundle.main.resourceURL?.appendingPathComponent("webviewer/" + name),
              let data = try? Data(contentsOf: url) else { return nil }
        return ("200 OK", type, data)
    }

    // MARK: - PNG 编码（ImageIO）

    static func encodePNG(width: Int, height: Int, rgba: [UInt8]) -> Data? {
        var px = rgba
        guard let ctx = CGContext(data: &px, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let img = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    // MARK: - 场景构建

    struct ViewerScene {
        var name: String
        var json: String
        var pages: [[UInt8]] // 每页 RGBA8
    }

    private func sceneForMap(named name: String, level: Int) -> ViewerScene? {
        lock.lock()
        defer { lock.unlock() }
        if let c = cachedScene, c.name == name { return c }

        var h3m: H3mFile?
        if let cur = presenter?.current, cur.url.lastPathComponent == name {
            // 当前地图：直接复用已构建的 Metal 图集（零额外开销）
            let frames = cur.atlas.packedEntries()
            let json = buildSceneJSON(map: cur.map, atlasPages: cur.atlas.pageCount,
                                      frames: frames.map { ($0.key, $0.pf) },
                                      objects: cur.map.objects, atlasVersion: atlasVersion(name: name, frames: frames.count, objects: cur.map.objects.count))
            let scene = ViewerScene(name: name, json: json, pages: (0..<cur.atlas.pageCount).map { cur.atlas.pageRGBA($0) })
            cachedScene = scene
            return scene
        }
        // 其他内置地图：按需解析 + 构图集
        guard let url = presenter?.mapURLs.first(where: { $0.lastPathComponent == name }),
              let parsed = try? H3mFile(url: url),
              let lib = presenter?.library else { return nil }
        h3m = parsed
        let gameMap = GameMap(h3m: parsed, library: lib, level: level)
        let atlas = AtlasBuilder.build(map: gameMap, library: lib)
        let frames = atlas.packedEntries()
        let json = buildSceneJSON(map: gameMap, atlasPages: atlas.pageCount,
                                  frames: frames.map { ($0.key, $0.pf) },
                                  objects: gameMap.objects,
                                  atlasVersion: atlasVersion(name: name, frames: frames.count, objects: gameMap.objects.count))
        let scene = ViewerScene(name: name, json: json, pages: (0..<atlas.pageCount).map { atlas.pageRGBA($0) })
        cachedScene = scene
        return scene
    }

    private func atlasVersion(name: String, frames: Int, objects: Int) -> String {
        "native-\(name.hashValue.magnitude % 100000)-\(frames)-\(objects)"
    }

    // MARK: - scene JSON（与 web/server/Scene.js 输出字段一一对应）

    private func buildSceneJSON(map: GameMap, atlasPages: Int,
                                frames: [(key: String, pf: PackedFrame)],
                                objects: [MapObject], atlasVersion: String) -> String {
        var o: [String] = []
        o.append("\"title\": \(jsonStr(map.title))")
        o.append("\"size\": \(map.size)")
        o.append("\"level\": \(map.level)")

        var pageArr: [String] = []
        for i in 0..<atlasPages {
            pageArr.append("{\"file\": \"atlas-\(i).png\", \"size\": \(FrameAtlas.pageSize)}")
        }
        o.append("\"pages\": [\(pageArr.joined(separator: ", "))]")

        var f: [String] = []
        let ps = Float(FrameAtlas.pageSize)
        for (key, pf) in frames {
            let x = Int(pf.u0 * ps), y = Int(pf.v0 * ps)
            f.append("\(jsonStr(key)): {\"p\": \(pf.page), \"x\": \(x), \"y\": \(y), \"w\": \(pf.width), \"h\": \(pf.height), \"ox\": \(pf.offsetX), \"oy\": \(pf.offsetY), \"fw\": \(pf.fullCanvasW), \"fh\": \(pf.fullCanvasH)}")
        }
        o.append("\"frames\": {\(f.joined(separator: ", "))}")

        func cellJSON(_ c: TerrainCell) -> String {
            let flip = (c.flipH ? 1 : 0) | (c.flipV ? 2 : 0)
            return "{\"x\": \(c.x), \"y\": \(c.y), \"def\": \(jsonStr(c.def)), \"i\": \(c.index), \"f\": \(flip), \"steps\": \(c.steps)}"
        }
        func roadJSON(_ r: RoadCell) -> String {
            let flip = (r.flipH ? 1 : 0) | (r.flipV ? 2 : 0)
            return "{\"x\": \(r.x), \"y\": \(r.y), \"def\": \(jsonStr(r.def)), \"i\": \(r.index), \"f\": \(flip)}"
        }
        o.append("\"terrain\": [\(map.terrain.map(cellJSON).joined(separator: ", "))]")
        o.append("\"rivers\": [\(map.rivers.map(cellJSON).joined(separator: ", "))]")
        o.append("\"roads\": [\(map.roads.map(roadJSON).joined(separator: ", "))]")

        let objs = objects.map { obj -> String in
            let frameCount = obj.frames.count
            return "{\"x\": \(obj.anchorX), \"y\": \(obj.anchorY), \"def\": \(jsonStr(obj.defName.uppercased())), \"fw\": \(obj.fullW), \"fh\": \(obj.fullH), \"frames\": \(frameCount), \"priority\": \(obj.priority), \"isHero\": \(obj.isHero), \"phase\": \(obj.phase)}"
        }
        o.append("\"objects\": [\(objs.joined(separator: ", "))]")
        o.append("\"missingDefs\": []")
        o.append("\"atlasVersion\": \(jsonStr(atlasVersion))")

        return "{\n" + o.joined(separator: ",\n") + "\n}"
    }

    private func jsonStr(_ s: String) -> String {
        var out = "\""
        for ch in s.unicodeScalars {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if ch.value < 0x20 { out += String(format: "\\u%04x", ch.value) }
                else { out.unicodeScalars.append(ch) }
            }
        }
        return out + "\""
    }
}
