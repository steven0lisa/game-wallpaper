import Foundation

/// Loads and caches DEF sprites from the game's H3sprite.lod.
final class AssetLibrary {
    let lod: LodFile
    private var cache: [String: DefFile] = [:]
    private(set) var missingDefs: Set<String> = []

    init?(lodURL: URL) {
        guard let lod = LodFile(url: lodURL) else { return nil }
        self.lod = lod
    }

    func def(named name: String) -> DefFile? {
        var key = name.uppercased()
        if let cached = cache[key] { return cached }
        // Terrain/river/road/border keys use bare names; lod entries carry the .DEF suffix.
        if !key.contains(".") { key += ".DEF" }
        if let cached = cache[key] { return cached }
        guard let data = lod.contents(named: name) ?? lod.contents(named: key) else {
            missingDefs.insert(key)
            return nil
        }
        guard let def = try? DefFile(data) else {
            missingDefs.insert(key)
            return nil
        }
        cache[key] = def
        return def
    }
}

/// Identifies one renderable frame: def name + block + frame index + palette rotation step.
struct FrameKey: Hashable {
    var def: String
    var block: Int
    var index: Int
    /// Palette rotation variant; 0 for non-animated defs.
    var step: Int
    /// web viewer 的帧 key（与 viewer.js 拼接格式一致）
    var webKey: String { "\(def):\(block):\(index):\(step)" }
}

/// A packed frame inside the atlas.
struct PackedFrame {
    var page: Int
    var u0: Float
    var v0: Float
    var u1: Float
    var v1: Float
    var width: Int
    var height: Int
    /// Data offset inside the def's full canvas (margins), for object anchoring.
    var offsetX: Int
    var offsetY: Int
    /// Full canvas size of the frame (def frame fullWidth/fullHeight).
    var fullCanvasW: Int
    var fullCanvasH: Int
}

/// Shelf-packing texture atlas of decoded frames (RGBA8).
final class FrameAtlas {
    static let pageSize = 2048

    struct Page {
        var pixels: [UInt8] // RGBA8
        var cursorX = 0
        var cursorY = 0
        var rowHeight = 0
    }

    private(set) var pages: [Page] = []
    private var packed: [FrameKey: PackedFrame] = [:]

    init() {
        pages.append(Page(pixels: [UInt8](repeating: 0, count: Self.pageSize * Self.pageSize * 4)))
    }

    var packedCount: Int { packed.count }

    func frame(_ key: FrameKey) -> PackedFrame? { packed[key] }

    // MARK: Web viewer 导出
    var pageCount: Int { pages.count }
    /// 某页的 RGBA8 像素（2048×2048×4）
    func pageRGBA(_ i: Int) -> [UInt8] { pages[i].pixels }
    /// 全部已打包帧（key 与 web viewer 拼接格式一致）
    func packedEntries() -> [(key: String, pf: PackedFrame)] {
        packed.map { ($0.key.webKey, $0.value) }
    }

    /// Rasterizes a frame (with palette variant) and packs it.
    func add(key: FrameKey, def: DefFile, block: Int, index: Int, mode: DefRaster.BlitMode) {
        guard packed[key] == nil,
              block < def.blocks.count,
              index < def.blocks[block].count else { return }
        let frame = def.blocks[block][index]

        // Rotate palette for animated variants.
        var palette = def.palette
        let ranges = paletteAnimationRanges[key.def.uppercased()] ?? []
        if key.step > 0, !ranges.isEmpty {
            palette = DefRaster.rotatedPalette(def.palette, ranges: ranges, step: key.step)
        }

        let rgba = DefRaster.rgba(frame: frame, palette: palette, mode: mode)
        guard frame.width > 0, frame.height > 0 else { return }
        // Deflate quirks can leave decoded rows short; pad with transparent pixels.
        let expected = frame.width * frame.height * 4
        var padded = rgba.count == expected ? rgba : (rgba + repeatElement(0, count: max(expected - rgba.count, 0)))
        // 预乘 alpha：线性采样在精灵边缘与透明邻居混色时，非预乘会产生暗色描边
        for i in stride(from: 0, to: padded.count, by: 4) {
            let a = padded[i + 3]
            if a != 255 {
                padded[i] = UInt8((UInt32(padded[i]) * UInt32(a) + 127) / 255)
                padded[i + 1] = UInt8((UInt32(padded[i + 1]) * UInt32(a) + 127) / 255)
                padded[i + 2] = UInt8((UInt32(padded[i + 2]) * UInt32(a) + 127) / 255)
            }
        }
        blit(rgba: padded, width: frame.width, height: frame.height,
             offsetX: frame.x, offsetY: frame.y,
             fullCanvasW: frame.fullWidth, fullCanvasH: frame.fullHeight)
        if let pf = lastPacked {
            packed[key] = pf
        }
    }

    private var lastPacked: PackedFrame?

    private func blit(rgba: [UInt8], width: Int, height: Int, offsetX: Int, offsetY: Int,
                      fullCanvasW: Int, fullCanvasH: Int) {
        // 1px 边缘复制填充：线性采样时相邻图集帧不会渗色，且亚像素平移平滑
        let pad = 1
        let pw = width + pad * 2, ph = height + pad * 2
        if pw > Self.pageSize || ph > Self.pageSize { return }
        var page = pages.count - 1
        var (x, y) = allocate(page: page, width: pw, height: ph)
        if x < 0 {
            pages.append(Page(pixels: [UInt8](repeating: 0, count: Self.pageSize * Self.pageSize * 4)))
            page = pages.count - 1
            (x, y) = allocate(page: page, width: pw, height: ph)
        }
        let ps = Self.pageSize
        func put(_ dx: Int, _ dy: Int) {
            let sc = max(0, min(width - 1, dx)), sr = max(0, min(height - 1, dy))
            let src = (sr * width + sc) * 4
            let dst = ((y + pad + dy) * ps + (x + pad + dx)) * 4
            pages[page].pixels[dst] = rgba[src]
            pages[page].pixels[dst + 1] = rgba[src + 1]
            pages[page].pixels[dst + 2] = rgba[src + 2]
            pages[page].pixels[dst + 3] = rgba[src + 3]
        }
        for row in -pad..<height + pad {
            for col in -pad..<width + pad {
                put(col, row)
            }
        }
        lastPacked = PackedFrame(
            page: page,
            u0: Float(x + pad) / Float(ps),
            v0: Float(y + pad) / Float(ps),
            u1: Float(x + pad + width) / Float(ps),
            v1: Float(y + pad + height) / Float(ps),
            width: width,
            height: height,
            offsetX: offsetX,
            offsetY: offsetY,
            fullCanvasW: fullCanvasW,
            fullCanvasH: fullCanvasH)
    }

    private func allocate(page: Int, width: Int, height: Int) -> (Int, Int) {
        let p = pages[page]
        if p.cursorX + width > Self.pageSize {
            pages[page].cursorY += p.rowHeight
            pages[page].cursorX = 0
            pages[page].rowHeight = 0
        }
        if pages[page].cursorY + height > Self.pageSize {
            return (-1, -1)
        }
        let (x, y) = (pages[page].cursorX, pages[page].cursorY)
        pages[page].cursorX += width
        pages[page].rowHeight = max(pages[page].rowHeight, height)
        return (x, y)
    }
}

/// Builds the packed atlas for one map (deduplicating frame keys).
enum AtlasBuilder {
    static func build(map: GameMap, library: AssetLibrary) -> FrameAtlas {
        let atlas = FrameAtlas()
        var done = Set<FrameKey>()
        for key in map.frameKeys {
            guard done.insert(key).inserted else { continue }
            guard let def = library.def(named: key.def) else { continue }
            let mode: DefRaster.BlitMode
            if terrainDefNames.contains(key.def) || key.def == GameMap.borderDef {
                mode = .opaque
            } else if key.def.hasSuffix("RVR") || key.def.hasSuffix("RD") {
                mode = .colorKey
            } else {
                mode = .shadows
            }
            atlas.add(key: key, def: def, block: key.block, index: key.index, mode: mode)
        }
        return atlas
    }
}
