import Foundation

/// Little-endian byte reader over an in-memory buffer,
/// mirroring the reading primitives used by the reference parsers.
struct ByteReader {
    let bytes: [UInt8]
    private(set) var pos: Int = 0

    init(_ data: Data) { bytes = [UInt8](data) }
    init(_ slice: ArraySlice<UInt8>) { bytes = Array(slice) }
    init(_ array: [UInt8]) { bytes = array }

    var remaining: Int { bytes.count - pos }

    /// Non-mutating direct read, for probe-style access without copying slices.
    func u32(at index: Int) -> UInt32 {
        guard index + 3 < bytes.count else { return 0 }
        return UInt32(bytes[index]) | (UInt32(bytes[index + 1]) << 8)
            | (UInt32(bytes[index + 2]) << 16) | (UInt32(bytes[index + 3]) << 24)
    }

    mutating func seek(_ p: Int) { pos = max(0, min(p, bytes.count)) }
    mutating func skip(_ n: Int) { pos += n }

    mutating func u8() -> UInt8 {
        defer { pos += 1 }
        return pos < bytes.count ? bytes[pos] : 0
    }

    mutating func u16() -> UInt16 {
        defer { pos += 2 }
        guard pos + 1 < bytes.count else { return 0 }
        return UInt16(bytes[pos]) | (UInt16(bytes[pos + 1]) << 8)
    }

    mutating func u32() -> UInt32 {
        defer { pos += 4 }
        guard pos + 3 < bytes.count else { return 0 }
        return UInt32(bytes[pos])
            | (UInt32(bytes[pos + 1]) << 8)
            | (UInt32(bytes[pos + 2]) << 16)
            | (UInt32(bytes[pos + 3]) << 24)
    }

    mutating func i32() -> Int32 { Int32(bitPattern: u32()) }

    mutating func bytes(_ n: Int) -> [UInt8] {
        defer { pos += n }
        let end = min(pos + n, bytes.count)
        guard pos < end else { return [] }
        return Array(bytes[pos..<end])
    }

    /// u32-length-prefixed string, truncated at the first NUL.
    mutating func string32() -> String {
        let len = Int(u32())
        return fixedString(len)
    }

    mutating func fixedString(_ n: Int) -> String {
        let raw = bytes(n)
        guard let end = raw.firstIndex(of: 0) else {
            return String(bytes: raw, encoding: .utf8) ?? String(decoding: raw, as: UTF8.self)
        }
        return String(bytes: raw[..<end], encoding: .utf8) ?? String(decoding: raw[..<end], as: UTF8.self)
    }
}
