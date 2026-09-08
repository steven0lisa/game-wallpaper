import Foundation
import Compression

/// Reader for Heroes of Might & Magic III `.lod` archives (H3sprite.lod / H3bitmap.lod).
///
/// Layout (validated against VCMI `CArchiveLoader::initLODArchive`):
///   - bytes 0..4   magic "LOD\0"
///   - bytes 4..8   version (0xC8)
///   - bytes 8..12  entry count
///   - bytes 0x5C.. entries: name[16], offset u32, size u32, unused u32, compressedSize u32
final class LodFile {
    struct Entry {
        let name: String
        let offset: Int
        let size: Int
        let compressedSize: Int
    }

    let url: URL
    private let fileData: Data
    private(set) var entries: [String: Entry] = [:]
    private(set) var entryCount = 0

    init?(url: URL) {
        self.url = url
        guard let data = try? Data(contentsOf: url), data.count > 0x5C else { return nil }
        fileData = data

        let raw: [UInt8] = [UInt8](data)
        func u32(_ at: Int) -> UInt32 {
            UInt32(raw[at]) | (UInt32(raw[at + 1]) << 8) | (UInt32(raw[at + 2]) << 16) | (UInt32(raw[at + 3]) << 24)
        }
        guard raw[0] == 0x4C, raw[1] == 0x4F, raw[2] == 0x44 else { return nil } // "LOD"
        entryCount = Int(u32(8))
        var pos = 0x5C
        for _ in 0..<entryCount {
            guard pos + 32 <= raw.count else { break }
            let nameBytes = raw[pos..<pos + 16]
            let nameEnd = nameBytes.firstIndex(of: 0) ?? nameBytes.endIndex
            let name = String(bytes: nameBytes[..<nameEnd], encoding: .isoLatin1) ?? ""
            let offset = Int(u32(pos + 16))
            let size = Int(u32(pos + 20))
            let compressed = Int(u32(pos + 28))
            if !name.isEmpty {
                entries[name.uppercased()] = Entry(name: name, offset: offset, size: size, compressedSize: compressed)
            }
            pos += 32
        }
        return
    }

    func entry(named name: String) -> Entry? {
        entries[name.uppercased()]
    }

    func contents(of entry: Entry) -> Data? {
        guard entry.offset + max(entry.compressedSize, entry.size) <= fileData.count else { return nil }
        let slice = fileData.subdata(in: entry.offset..<entry.offset + (entry.compressedSize > 0 ? entry.compressedSize : entry.size))
        guard entry.compressedSize > 0 else { return slice }
        return Self.inflate(slice, outputSize: entry.size)
    }

    func contents(named name: String) -> Data? {
        guard let e = entry(named: name) else { return nil }
        return contents(of: e)
    }

    /// Raw DEFLATE inflate (Apple's COMPRESSION_ZLIB). Strips the 2-byte zlib stream header when present.
    static func inflate(_ input: Data, outputSize: Int) -> Data {
        var src = [UInt8](input)
        if src.count > 2, src[0] == 0x78 {
            src = Array(src[2...])
        }
        guard !src.isEmpty, outputSize > 0 else { return Data() }
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: outputSize)
        defer { dst.deallocate() }
        let written = src.withUnsafeBufferPointer { buf -> Int in
            compression_decode_buffer(dst, outputSize, buf.baseAddress!, src.count, nil, COMPRESSION_ZLIB)
        }
        guard written > 0 else { return Data() }
        return Data(bytes: dst, count: written)
    }
}
