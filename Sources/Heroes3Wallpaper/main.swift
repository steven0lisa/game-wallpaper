import AppKit
import MetalKit

// MARK: - Entry point
//
// Two modes:
//   GUI (default): menu-bar app that renders the animated map as the desktop wallpaper.
//   CLI:   Heroes3Wallpaper --snapshot <map.h3m> --out <png> [--data-dir <vcmi dir>]
//                 [--width 1920 --height 1080 --time-ms 0 --zoom 1 --center-x 0.5 --center-y 0.5 --level 0]
//          Headless single-frame render for end-to-end verification.

let arguments = CommandLine.arguments

if let tileIdx = arguments.firstIndex(of: "--tile"), tileIdx + 2 < arguments.count {
    SnapshotCLI.probeTile(Int(arguments[tileIdx+1]) ?? 0, Int(arguments[tileIdx+2]) ?? 0, arguments)
    exit(0)
}

if let probeIdx = arguments.firstIndex(of: "--probe-def"), probeIdx + 1 < arguments.count {
    SnapshotCLI.probeDef(arguments[probeIdx + 1], arguments)
    exit(0)
}

if arguments.contains("--snapshot") {
    SnapshotCLI.run(arguments)
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

// MARK: - Snapshot CLI

enum SnapshotCLI {
    static func value(_ args: [String], _ flag: String, _ fallback: String) -> String {
        if let i = args.firstIndex(of: flag), i + 1 < args.count { return args[i + 1] }
        return fallback
    }

    static func run(_ args: [String]) {
        let mapPath = value(args, "--snapshot", "")
        let out = value(args, "--out", "snapshot.png")
        let dataDir = value(args, "--data-dir", "")
        let width = Int(value(args, "--width", "1920")) ?? 1920
        let height = Int(value(args, "--height", "1080")) ?? 1080
        let timeMs = Double(value(args, "--time-ms", "0")) ?? 0
        let zoom = Float(value(args, "--zoom", "1")) ?? 1
        let centerX = Float(value(args, "--center-x", "-1")) ?? -1
        let centerY = Float(value(args, "--center-y", "-1")) ?? -1
        let level = Int(value(args, "--level", "0")) ?? 0

        guard !mapPath.isEmpty, FileManager.default.fileExists(atPath: mapPath) else {
            FileHandle.standardError.write("snapshot: map file not found: \(mapPath)\n".data(using: .utf8)!)
            exit(2)
        }

        let defaults = Self.defaultDataDir(dataDir)
        let lodURL = defaults.appendingPathComponent("Data/H3sprite.lod")
        guard let library = AssetLibrary(lodURL: lodURL) else {
            FileHandle.standardError.write("snapshot: cannot open \(lodURL.path)\n".data(using: .utf8)!)
            exit(2)
        }

        do {
            let h3m = try H3mFile(url: URL(fileURLWithPath: mapPath))
            let cps = h3m.checkpoints.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
            NSLog("parse: version=\(h3m.version) size=\(h3m.size) checkpoints \(cps)")
            let map = GameMap(h3m: h3m, library: library, level: level)
            let atlas = AtlasBuilder.build(map: map, library: library)

            guard let device = MTLCreateSystemDefaultDevice(),
                  let renderer = try? MapRenderer(device: device) else {
                FileHandle.standardError.write("snapshot: Metal init failed\n".data(using: .utf8)!)
                exit(2)
            }
            renderer.uploadAtlas(atlas)

            let mapSizePx = Float(map.size * 32)
            let viewW = Float(width) / zoom, viewH = Float(height) / zoom
            let cx = centerX >= 0 ? centerX * mapSizePx : mapSizePx / 2
            let cy = centerY >= 0 ? centerY * mapSizePx : mapSizePx / 2

            renderer.buildFrame(map: map, atlas: atlas,
                                view: MapRenderer.Viewport(viewLeft: cx - viewW / 2, viewTop: cy - viewH / 2,
                                                           viewWidth: viewW, viewHeight: viewH),
                                timeMs: timeMs)
            guard let image = renderer.snapshot(width: width, height: height) else {
                FileHandle.standardError.write("snapshot: render failed\n".data(using: .utf8)!)
                exit(3)
            }
            try MapRenderer.writePNG(image, to: URL(fileURLWithPath: out))

            let missing = library.missingDefs.count
            var terrainMiss = 0, terrainHit = 0, indexOverflow = 0
            for cell in map.terrain {
                if cell.index >= 240 { indexOverflow += 1 }
                if atlas.frame(FrameKey(def: cell.def, block: 0, index: cell.index, step: 0)) != nil { terrainHit += 1 } else { terrainMiss += 1 }
            }
            var terrainTypes: [UInt8: Int] = [:]
            for t in h3m.tiles { terrainTypes[t.terrain, default: 0] += 1 }
            NSLog("snapshot: missingObjectDefs(%d)=%@", map.missingObjectDefs.count, map.missingObjectDefs.prefix(8).joined(separator: ", "))
            NSLog("snapshot: wrote %@ | map %dx%d defs=%d objects=%d atlasFrames=%d missingDefs=%d terrainHit=%d miss=%d idxOverflow=%d terrains=%@",
                  out, map.size, map.size, h3m.defs.count, map.objects.count, atlas.packedCount, missing,
                  terrainHit, terrainMiss, indexOverflow,
                  terrainTypes.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ","))
        } catch {
            FileHandle.standardError.write("snapshot: \(error)\n".data(using: .utf8)!)
            exit(4)
        }
    }

    static func probeTile(_ tx: Int, _ ty: Int, _ args: [String]) {
        let mapPath = value(args, "--snapshot", "")
        let lodURL = defaultDataDir(value(args, "--data-dir", "")).appendingPathComponent("Data/H3sprite.lod")
        guard let h3m = try? H3mFile(url: URL(fileURLWithPath: mapPath)),
              let library = AssetLibrary(lodURL: lodURL),
              let tile = h3m.tile(x: tx, y: ty, level: 0) else {
            print("tile probe failed")
            return
        }
        let defName = terrainDefNames[Int(tile.terrain)]
        print("tile(\(tx),\(ty)): terrain=\(tile.terrain)(\(defName)) terView=\(tile.terrainImageIndex) river=\(tile.river)/\(tile.riverImageIndex) road=\(tile.road)/\(tile.roadImageIndex) mirror=0x\(String(tile.mirrorConfig, radix: 2))")
        guard let def = library.def(named: defName) else { print("def missing"); return }
        print("def frames: \(def.blocks.map { $0.count })")
        if Int(tile.terrainImageIndex) < def.blocks[0].count {
            let f = def.blocks[0][Int(tile.terrainImageIndex)]
            print("frame: \(f.width)x\(f.height) at (\(f.x),\(f.y)) comp-check indices=\(f.indices.count)/\(f.width*f.height)")
            let brightMagenta = f.indices.prefix(200).filter { [246,247,248,249,250,251,252,253,254].contains(Int($0)) }.count
            print("first200 in palette-rotation range [246,255): \(brightMagenta)")
            var paletteHits: [UInt8: Int] = [:]
            for i in f.indices { paletteHits[i, default: 0] += 1 }
            print("top indices:", paletteHits.sorted { $0.value > $1.value }.prefix(8).map { "\($0.key)x\($0.value)" }.joined(separator: " "))
        } else {
            print("terView \(tile.terrainImageIndex) OUT OF RANGE")
        }
    }

    static func probeDef(_ name: String, _ args: [String]) {
        let lodURL = defaultDataDir(value(args, "--data-dir", "")).appendingPathComponent("Data/H3sprite.lod")
        guard let library = AssetLibrary(lodURL: lodURL), let def = library.def(named: name) else {
            print("probe: cannot load \(name)")
            return
        }
        print("def \(name): type=0x\(String(def.type, radix: 16)) full=\(def.fullWidth)x\(def.fullHeight) blocks=\(def.blocks.count) mode=\(DefRaster.mode(forDefName: name))")
        // 每个索引对应的 RGB（前 200 索引），便于判断"用到的索引是不是白/品红/亮色"
        func idxRGB(_ i: Int) -> String {
            let p = i * 3
            guard p + 2 < def.palette.count else { return "?" }
            return "(\(def.palette[p]),\(def.palette[p+1]),\(def.palette[p+2]))"
        }
        for (bi, block) in def.blocks.prefix(3).enumerated() {
            print("  block \(bi): frames=\(block.count)")
            if let f = block.first {
                print("    frame0: \(f.width)x\(f.height) at (\(f.x),\(f.y)) full=\(f.fullWidth)x\(f.fullHeight) indices=\(f.indices.count)")
            }
            // 关键诊断：每帧用到的全部非0索引直方图 + 这些索引的RGB，限前几帧和最高频
            for (fi, f) in block.enumerated() {
                var hist: [UInt8: Int] = [:]
                for i in f.indices where i != 0 { hist[i, default: 0] += 1 }
                if fi < 2 || hist.count > 0 {
                    let top = hist.sorted { $0.value > $1.value }.prefix(12)
                    let desc = top.map { "i\($0.key)x\($0.value)@\(idxRGB(Int($0.key)))" }.joined(separator: " ")
                    print("    frame\(fi): topNonZeroIndices \(desc)")
                    // 低索引 1..15 是否被用到（可能是白/品红占位）
                    let low = hist.keys.filter { $0 >= 1 && $0 <= 15 }.sorted()
                    if !low.isEmpty {
                        print("      LOW-idx used: \(low.map { "i\($0)=\(idxRGB(Int($0)))" }.joined(separator: " "))")
                    }
                }
            }
        }
        print("  palette[0..31]: \(Array(def.palette.prefix(96)))")
    }

    static func defaultDataDir(_ override: String) -> URL {
        if !override.isEmpty { return URL(fileURLWithPath: override) }
        // app 内置资源（自包含分发）：Resources/Data/H3sprite.lod
        if let res = Bundle.main.resourceURL,
           FileManager.default.fileExists(atPath: res.appendingPathComponent("Data/H3sprite.lod").path) {
            return res
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Application Support/vcmi")
    }
}
