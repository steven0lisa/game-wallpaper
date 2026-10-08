import Foundation

/// Decoder for H3 `.def` sprite files (validated against VCMI `CDefFile::loadFrame`
/// and the reference wallpaper's DefReader).
struct DefFrame {
    let fullWidth: Int
    let fullHeight: Int
    let width: Int
    let height: Int
    /// Left margin of the pixel data inside the full canvas.
    let x: Int
    /// Top margin of the pixel data inside the full canvas.
    let y: Int
    /// Palette indices, width*height entries.
    let indices: [UInt8]
}

struct DefFile {
    let type: UInt32
    let fullWidth: Int
    let fullHeight: Int
    /// 256 RGB triples (768 bytes).
    var palette: [UInt8]
    /// Frame groups ("blocks"); the adventure map uses block 0 for idle animations.
    var blocks: [[DefFrame]]

    init(_ data: Data) throws {
        var r = ByteReader(data)
        type = r.u32()
        fullWidth = Int(r.u32())
        fullHeight = Int(r.u32())
        let groupsCount = Int(r.u32())
        // 256 RGB triples (768 bytes) — header is [type][w][h][blockCount][palette][blocks...].
        palette = r.bytes(256 * 3)

        struct RawGroup {
            var type: Int
            var offsets: [Int]
            var legacy: Bool
        }
        var rawGroups: [RawGroup] = []
        // Corrupt defs (bad inflate or wrong layout) can carry absurd counts; refuse to iterate them.
        guard groupsCount >= 0, groupsCount <= 64 else {
            blocks = []
            return
        }
        for _ in 0..<groupsCount {
            let groupType = Int(r.u32())
            let framesCount = Int(r.u32())
            guard framesCount >= 0, framesCount <= 100_000 else {
                rawGroups.append(RawGroup(type: groupType, offsets: [], legacy: false))
                continue
            }
            r.skip(8)
            r.skip(framesCount * 13)
            var offsets: [Int] = []
            for _ in 0..<max(framesCount, 0) {
                offsets.append(Int(r.u32()))
            }
            // Legacy defs store the line-offset table where normal defs store margins;
            // detect by checking whether frames would run past the end of the stream.
            var legacy = false
            for off in offsets {
                if off + 36 <= r.bytes.count {
                    let declared = Int(r.u32(at: off))
                    if off + 32 + declared > r.bytes.count {
                        legacy = true
                        break
                    }
                } else {
                    legacy = true
                    break
                }
            }
            rawGroups.append(RawGroup(type: groupType, offsets: offsets, legacy: legacy))
        }

        blocks = []
        for group in rawGroups {
            var frames: [DefFrame] = []
            for offset in group.offsets {
                r.seek(offset)
                let size = Int(r.u32())
                let compression = Int(r.u32())
                let fw = Int(r.u32())
                let fh = Int(r.u32())
                var w: Int, h: Int, x: Int, y: Int
                if group.legacy {
                    w = fw; h = fh; x = 0; y = 0
                } else {
                    w = Int(r.u32()); h = Int(r.u32()); x = Int(r.u32()); y = Int(r.u32())
                }
                // Sanity: bogus dimensions mean the legacy heuristic misfired for this frame.
                if w <= 0 || h <= 0 || w > 4096 || h > 4096 || x > 4096 || y > 4096 {
                    w = fw; h = fh; x = 0; y = 0
                }
                if w <= 0 || h <= 0 || w > 4096 || h > 4096 { continue }
                let dataOffset = r.pos
                let indices = DefFile.decodeFrame(r: &r, dataOffset: dataOffset, compression: compression,
                                                  width: w, height: h, size: size)
                frames.append(DefFrame(fullWidth: fw, fullHeight: fh, width: w, height: h, x: x, y: y, indices: indices))
            }
            blocks.append(frames)
        }
    }

    private static func decodeFrame(r: inout ByteReader, dataOffset: Int, compression: Int,
                                    width: Int, height: Int, size: Int) -> [UInt8] {
        guard width > 0, height > 0, width <= 4096, height <= 4096 else { return [] }
        var out: [UInt8] = []
        out.reserveCapacity(width * height)
        func emit(_ count: Int, _ value: UInt8) {
            out.append(contentsOf: repeatElement(value, count: count))
        }

        switch compression {
        case 0:
            return r.bytes(width * height)

        case 1:
            var lineOffsets: [Int] = []
            for _ in 0..<height { lineOffsets.append(Int(r.u32())) }
            for line in 0..<height {
                r.seek(dataOffset + lineOffsets[line])
                var left = width
                while left > 0, r.pos < r.bytes.count {
                    let code = r.u8()
                    let len = Int(r.u8()) + 1
                    if code == 0xFF {
                        out.append(contentsOf: r.bytes(min(len, left)))
                    } else {
                        emit(min(len, left), code)
                    }
                    left -= len
                }
            }
            return out

        case 2:
            var lineOffsets: [Int] = []
            for _ in 0..<height { lineOffsets.append(Int(r.u16())) }
            for line in 0..<height {
                r.seek(dataOffset + lineOffsets[line])
                var left = width
                while left > 0, r.pos < r.bytes.count {
                    let b = r.u8()
                    let code = b >> 5
                    let len = Int(b & 31) + 1
                    if code == 7 {
                        out.append(contentsOf: r.bytes(min(len, left)))
                    } else {
                        emit(min(len, left), code)
                    }
                    left -= len
                }
            }
            return out

        case 3:
            let groups = (height * width) / 32
            var lineOffsets: [Int] = []
            for _ in 0..<max(groups, 0) { lineOffsets.append(Int(r.u16())) }
            for g in 0..<max(groups, 0) {
                r.seek(dataOffset + lineOffsets[g])
                var left = 32
                while left > 0, r.pos < r.bytes.count {
                    let b = r.u8()
                    let code = b >> 5
                    let len = Int(b & 31) + 1
                    if code == 7 {
                        out.append(contentsOf: r.bytes(min(len, left)))
                    } else {
                        emit(min(len, left), code)
                    }
                    left -= len
                }
            }
            return out

        default:
            return []
        }
    }
}

// MARK: - Palette animation & RGBA conversion

/// Palette-rotation ranges per def (from VCMI config terrains.json / rivers.json).
/// Each range [start, start+length) rotates one step per animation frame.
let paletteAnimationRanges: [String: [(start: Int, length: Int)]] = [
    "LAVATL": [(246, 9)],
    "WATRTL": [(229, 12), (242, 12)],
    "CLRRVR": [(183, 12), (195, 6)],
    "MUDRVR": [(228, 12), (183, 6), (240, 6)],
    "LAVRVR": [(240, 9)],
]

enum DefRaster {
    /// Number of palette rotation steps (LCM of range lengths); 1 means static.
    static func rotationStepCount(forDefName name: String) -> Int {
        guard let ranges = paletteAnimationRanges[name.uppercased()] else { return 1 }
        var steps = 1
        for range in ranges { steps = lcm(steps, range.length) }
        return steps
    }

    /// Palette rotated by `step` positions (right rotation, matching VCMI shiftPalette).
    static func rotatedPalette(_ base: [UInt8], ranges: [(start: Int, length: Int)], step: Int) -> [UInt8] {
        guard step > 0, !ranges.isEmpty else { return base }
        var out = base
        for range in ranges {
            let s = range.start * 3
            let len = range.length
            for i in 0..<len {
                let target = (i + step) % len
                out[s + target * 3] = base[s + i * 3]
                out[s + target * 3 + 1] = base[s + i * 3 + 1]
                out[s + target * 3 + 2] = base[s + i * 3 + 2]
            }
        }
        return out
    }

    struct PlayerColor {
        var r: UInt8, g: UInt8, b: UInt8
    }

    /// How palette indices map to alpha (mirrors VCMI's EImageBlitMode).
    enum BlitMode {
        case opaque    // terrain, border
        case colorKey  // rivers, roads: only index 0 is transparent
        case shadows   // objects: index 0 transparent, 1 = 25% shadow, 4 = 50% shadow, 5 = flag color
    }

    static func mode(forDefName name: String) -> BlitMode {
        let upper = name.uppercased()
        if terrainDefNames.contains(upper) || upper == "EDG" { return .opaque }
        if upper.hasSuffix("RVR") || upper.hasSuffix("RD") { return .colorKey }
        return .shadows
    }

    /// Convert palette-indexed frame data to RGBA8.
    ///
    /// Special indices (VCMI ScalableImage semantics):
    ///   0 = transparent, 1 = 25% shadow, 4 = 50% shadow, 5 = flag/player color,
    ///   6 = 50% (selection), 7 = 25% (selection).
    static func rgba(frame: DefFrame, palette: [UInt8], mode: BlitMode, player: PlayerColor? = nil) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: frame.width * frame.height * 4)
        out.withUnsafeMutableBufferPointer { dst in
            var p = 0
            for idx in frame.indices {
                let pi = Int(idx) * 3
                var r = palette[pi], g = palette[pi + 1], b = palette[pi + 2]
                var a: UInt8 = 255
                switch mode {
                case .opaque:
                    a = 255
                case .colorKey:
                    a = idx == 0 ? 0 : 255
                case .shadows:
                    // Shadow/selection indices carry placeholder colors (often magenta) in the
                    // def palette; the game renders them as translucent black / flag color.
                    switch idx {
                    case 0:
                        a = 0
                    case 1, 7:
                        r = 0; g = 0; b = 0; a = 64
                    case 2, 3:
                        a = 0
                    case 4, 6:
                        r = 0; g = 0; b = 0; a = 128
                    case 5:
                        r = player?.r ?? 128; g = player?.g ?? 128; b = player?.b ?? 128
                        a = 255
                    default:
                        a = 255
                    }
                }
                dst[p] = r; dst[p + 1] = g; dst[p + 2] = b; dst[p + 3] = a
                p += 4
            }
        }
        return out
    }

    private static func lcm(_ a: Int, _ b: Int) -> Int {
        var x = a, y = b
        while y != 0 { (x, y) = (y, x % y) }
        return a / max(x, 1) * b
    }
}
