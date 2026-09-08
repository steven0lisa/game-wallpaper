import Foundation
import Compression

/// Parser for Heroes III `.h3m` map files.
/// Faithful port of the reference wallpaper's H3mReader/H3mObjects
/// (which matches VCMI's MapFormatH3M for ROE/AB/SoD maps).
struct H3mTile {
    var terrain: UInt8
    var terrainImageIndex: UInt8
    var river: UInt8
    var riverImageIndex: UInt8
    var road: UInt8
    var roadImageIndex: UInt8
    /// bits 0-1 terrain flip, 2-3 river flip, 4-5 road flip (mirroring VCMI extTileFlags)
    var mirrorConfig: UInt8
}

struct H3mDefInfo {
    var spriteName: String
    var terrainType: UInt16
    var terrainGroup: UInt16
    var objectId: Int
    var objectClassSubId: Int
    var objectsGroup: UInt8
    var placementOrder: UInt8
}

struct H3mObject {
    var x: Int
    var y: Int
    var z: Int
    var defIndex: Int
    var def: H3mDefInfo

    var objectId: Int { def.objectId }
}

enum H3mVersion: Int32 {
    case roe = 14
    case ab = 21
    case sod = 28

    init?(raw: Int32) {
        switch raw {
        case 14: self = .roe
        case 21: self = .ab
        case 28, 29: self = .sod
        default: return nil
        }
    }
}

final class H3mFile {
    let version: H3mVersion
    let size: Int
    let hasUnderground: Bool
    let title: String
    let tiles: [H3mTile]          // indexed z*size*size + y*size + x
    let defs: [H3mDefInfo]
    let objects: [H3mObject]
    /// Byte offsets after each parse stage (diagnostics for map-format desyncs).
    private(set) var checkpoints: [String: Int] = [:]

    init(url: URL) throws {
        let gzipped = try Data(contentsOf: url)
        let raw = Self.gunzip(gzipped)
        var r = ByteReader(raw)

        let versionRaw = r.i32()
        guard let v = H3mVersion(raw: versionRaw) else {
            throw H3mError.unsupportedVersion(versionRaw)
        }
        version = v

        // ---- header ----
        _ = r.u8()                       // hasPlayers
        size = Int(r.u32())
        hasUnderground = r.u8() == 1
        title = r.string32()             // title
        _ = r.string32()                 // description
        _ = r.u8()                       // difficulty
        if version != .roe { _ = r.u8() }
        try Self.readPlayerInfo(&r, version: version)
        Self.readVictoryLossConditions(&r, version: version)
        checkpoints["header"] = r.pos
        // team info
        if r.u8() > 0 { r.skip(8) }
        // allowed heroes
        r.skip(version == .roe ? 16 : 20)
        if version != .roe { r.skip(Int(r.u32())) }
        // disposed heroes
        if version == .sod {
            var n = Int(r.u8())
            while n > 0 { r.skip(1 + 1); _ = r.string32(); r.skip(1); n -= 1 }
        }
        r.skip(31)
        // allowed artifacts
        if version != .roe { r.skip(version == .ab ? 17 : 18) }
        // allowed spells & secondary skills
        if version == .sod { r.skip(9); r.skip(4) }
        // rumors
        var rumors = Int(r.u32())
        while rumors > 0 { _ = r.string32(); _ = r.string32(); rumors -= 1 }
        // predefined heroes
        if version == .sod {
            for _ in 0...155 {
                if r.u8() == 1 {
                    if r.u8() == 1 { _ = r.u32() }
                    if r.u8() == 1 {
                        var n = Int(r.u32())
                        while n > 0 { r.skip(2); n -= 1 }
                    }
                    Self.readArtifactsOfHero(&r, version: version)
                    if r.u8() == 1 { _ = r.string32() }
                    _ = r.u8()
                    if r.u8() == 1 { r.skip(9) }
                    if r.u8() == 1 { r.skip(4) }
                }
            }
        }

        // ---- terrain ----
        let levels = hasUnderground ? 2 : 1
        var tiles: [H3mTile] = []
        tiles.reserveCapacity(size * size * levels)
        for _ in 0..<(size * size * levels) {
            tiles.append(H3mTile(
                terrain: r.u8(),
                terrainImageIndex: r.u8(),
                river: r.u8(),
                riverImageIndex: r.u8(),
                road: r.u8(),
                roadImageIndex: r.u8(),
                mirrorConfig: r.u8()))
        }
        self.tiles = tiles

        checkpoints["terrain"] = r.pos
        // ---- def table ----
        var defs: [H3mDefInfo] = []
        var defCount = Int(r.u32())
        while defCount > 0 {
            defCount -= 1
            let spriteName = r.string32()
            _ = r.u32(); _ = r.u16()      // passable cells
            _ = r.u32(); _ = r.u16()      // active cells
            let terrainType = r.u16()
            let terrainGroup = r.u16()
            let objectId = Int(r.u32())
            let subId = Int(r.u32())
            let group = r.u8()
            let order = r.u8()
            r.skip(16)
            defs.append(H3mDefInfo(spriteName: spriteName, terrainType: terrainType, terrainGroup: terrainGroup,
                                   objectId: objectId, objectClassSubId: subId, objectsGroup: group,
                                   placementOrder: order))
        }
        self.defs = defs

        checkpoints["defs"] = r.pos
        // ---- objects ----
        var objects: [H3mObject] = []
        var objectCount = Int(r.u32())
        while objectCount > 0 {
            objectCount -= 1
            let x = Int(r.u8())
            let y = Int(r.u8())
            let z = Int(r.u8())
            let defIndex = Int(r.u32())
            r.skip(5)
            guard defIndex >= 0 && defIndex < defs.count else { continue }
            let def = defs[defIndex]
            Self.skipObjectPayload(&r, objectId: def.objectId, version: version)
            objects.append(H3mObject(x: x, y: y, z: z, defIndex: defIndex, def: def))
        }
        self.objects = objects
        checkpoints["objects"] = r.pos
        checkpoints["fileSize"] = raw.count
    }

    func tile(x: Int, y: Int, level: Int) -> H3mTile? {
        guard x >= 0, y >= 0, x < size, y < size, level >= 0, level < (hasUnderground ? 2 : 1) else { return nil }
        return tiles[level * size * size + y * size + x]
    }

    // MARK: - Header sections

    private static func readPlayerInfo(_ r: inout ByteReader, version: H3mVersion) throws {
        for _ in 0..<8 {
            let human = r.u8() == 1
            let computer = r.u8() == 1
            if !human && !computer {
                switch version {
                case .sod: r.skip(13)
                case .ab: r.skip(12)
                case .roe: r.skip(6)
                }
            } else {
                _ = r.u8()
                if version == .sod { _ = r.u8() == 1 }
                _ = r.u8()
                if version != .roe { _ = r.u8() }
                _ = r.u8() == 1
                let hasMainTown = r.u8() == 1
                if hasMainTown {
                    if version != .roe { _ = r.u8() == 1; _ = r.u8() == 1 }
                    r.skip(3)
                }
                _ = r.u8() == 1
                if r.u8() != 255 {
                    _ = r.u8()
                    _ = r.string32()
                }
                if version != .roe {
                    _ = r.u8()
                    var n = Int(r.u32())
                    while n > 0 { r.skip(1); _ = r.string32(); n -= 1 }
                }
            }
        }
    }

    private static func readVictoryLossConditions(_ r: inout ByteReader, version: H3mVersion) {
        let victory = Int(r.u8())
        if victory != 255 { r.skip(2) }
        if victory != 10 {
            switch victory {
            case 0: r.skip(1); if version != .roe { r.skip(1) }
            case 1: r.skip(1); if version != .roe { r.skip(1) }; _ = r.u32()
            case 2: r.skip(1); _ = r.u32()
            case 3: r.skip(5)
            case 4: r.skip(3)
            case 5: r.skip(3)
            case 6: r.skip(3)
            case 7: r.skip(3)
            default: break
            }
        } else {
            r.skip(1)
            r.skip(3)
        }
        let loss = Int(r.u8())
        if loss == 0 { r.skip(3) }
        else if loss == 1 { r.skip(3) }
        else if loss == 2 { r.skip(2) }
    }

    private static func readArtifactSlot(_ r: inout ByteReader, version: H3mVersion) {
        if version == .roe { _ = r.u8() } else { _ = r.u16() }
    }

    private static func readArtifactsOfHero(_ r: inout ByteReader, version: H3mVersion) {
        if r.u8() == 1 {
            for _ in 0...15 { readArtifactSlot(&r, version: version) }
            if version == .sod { readArtifactSlot(&r, version: version) }
            readArtifactSlot(&r, version: version)
            if version != .roe {
                readArtifactSlot(&r, version: version)
            } else {
                _ = r.u8()
            }
            var n = Int(r.u16())
            while n > 0 { readArtifactSlot(&r, version: version); n -= 1 }
        }
    }

    // MARK: - Object payloads (skip-only, to advance the stream)

    private static func readCreatureSet(_ r: inout ByteReader, count: Int, version: H3mVersion) {
        var n = count
        while n > 0 {
            r.skip(version != .roe ? 2 : 1)
            r.skip(2)
            n -= 1
        }
    }

    private static func readMessageAndGuards(_ r: inout ByteReader, version: H3mVersion) {
        if r.u8() == 1 {
            _ = r.string32()
            if r.u8() == 1 {
                readCreatureSet(&r, count: 7, version: version)
            }
            r.skip(4)
        }
    }

    private static func readResources(_ r: inout ByteReader) {
        for _ in 0...6 { _ = r.u32() }
    }

    private static func readQuest(_ r: inout ByteReader, missionType: Int, version: H3mVersion) {
        switch missionType {
        case 0: return
        case 1, 2, 3, 4: r.skip(4)
        case 5: r.skip(Int(r.u8()) * 2)
        case 6: r.skip(Int(r.u8()) * 2 * 2)
        case 7: r.skip(28)
        case 8, 9: r.skip(1)
        default: break
        }
        r.skip(4)
        _ = r.string32()
        _ = r.string32()
        _ = r.string32()
    }

    /// Object payload skipping — exact port of the reference wallpaper's H3mReader switch.
    /// Objects not listed carry zero payload bytes in ROE/AB/SoD maps.
    private static func skipObjectPayload(_ r: inout ByteReader, objectId: Int, version: H3mVersion) {
        switch objectId {
        case 26: // event
            readMessageAndGuards(&r, version: version)
            r.skip(4); r.skip(4); r.skip(1); r.skip(1)
            readResources(&r)
            r.skip(4)
            r.skip(Int(r.u8()) * 2)
            r.skip(Int(r.u8()) * (version == .roe ? 1 : 2))
            r.skip(Int(r.u8()))
            readCreatureSet(&r, count: Int(r.u8()), version: version)
            r.skip(8)
            r.skip(1); r.skip(1); r.skip(1)
            r.skip(4)
        case 34, 70, 62: // hero / random hero / prison
            readHeroPayload(&r, version: version)
        case 54, 71, 72, 73, 74, 75, 162, 163, 164: // monster + random monster tiers 1-7
            readMonsterPayload(&r, version: version)
        case 59, 91: // ocean bottle / sign
            _ = r.string32()
            r.skip(4)
        case 83: // seer hut
            var hasQuest = true
            if version != .roe {
                let t = Int(r.u8())
                readQuest(&r, missionType: t, version: version)
            } else {
                hasQuest = r.u8() != 255
            }
            if hasQuest {
                let reward = Int(r.u8())
                switch reward {
                case 1, 2: _ = r.u32()
                case 3, 4: _ = r.u8()
                case 5: _ = r.u8(); _ = r.u32()
                case 6, 7: _ = r.u8(); _ = r.u8()
                case 8: if version == .roe { _ = r.u8() } else { _ = r.u16() }
                case 9: _ = r.u8()
                case 10: r.skip(version != .roe ? 4 : 3)
                default: break
                }
                r.skip(2)
            } else {
                r.skip(3)
            }
        case 113: // witch hut
            if version != .roe { r.skip(4) }
        case 81: // scholar
            r.skip(2)
            r.skip(6)
        case 33, 219: // garrison / garrison2
            r.skip(1); r.skip(3)
            readCreatureSet(&r, count: 7, version: version)
            if version != .roe { _ = r.u8() == 1 }
            r.skip(8)
        case 5, 65, 66, 67, 68, 69, 93: // artifact / random artifacts / spell scroll
            readMessageAndGuards(&r, version: version)
            if objectId == 93 { _ = r.u32() }
        case 76, 79: // random resource / resource
            readMessageAndGuards(&r, version: version)
            _ = r.u32()
            r.skip(4)
        case 77, 98: // random town / town
            readTownPayload(&r, version: version)
        case 53, 220, 88, 89, 90, 87, 42, 36: // mine, abandoned mine, shrines, shipyard, lighthouse, grail
            r.skip(4)
        case 17, 18, 19, 20: // creature generators 1-4
            r.skip(4)
        case 6: // pandora's box
            readMessageAndGuards(&r, version: version)
            r.skip(4); r.skip(4); r.skip(1); r.skip(1)
            readResources(&r)
            r.skip(4)
            r.skip(Int(r.u8()) * 2)
            r.skip(Int(r.u8()) * (version != .roe ? 2 : 1))
            r.skip(Int(r.u8()))
            readCreatureSet(&r, count: Int(r.u8()), version: version)
            r.skip(8)
        case 216, 217, 218: // random dwellings
            r.skip(4)
            if objectId == 216 || objectId == 217 {
                if r.u32() == 0 { _ = r.u16() }
            }
            if objectId == 216 || objectId == 218 {
                _ = r.u8()
                _ = r.u8()
            }
        case 215: // quest guard
            readQuest(&r, missionType: Int(r.u8()), version: version)
        case 214: // hero placeholder
            _ = r.u8()
            if r.u8() == 255 { r.skip(1) }
        default:
            break // all other objects carry no payload
        }
    }

    private static func readHeroPayload(_ r: inout ByteReader, version: H3mVersion) {
        if version != .roe { r.skip(4) }          // hero type
        r.skip(1)                                  // owner
        r.skip(1)                                  // portrait
        if r.u8() == 1 { _ = r.string32() }        // custom name
        if version != .roe && version != .ab {
            if r.u8() == 1 { _ = r.u32() }         // experience
        } else {
            _ = r.u32()
        }
        if r.u8() == 1 { _ = r.u8() }              // sex
        if r.u8() == 1 { r.skip(Int(r.u32()) * 2) }// secondary skills
        if r.u8() == 1 { readCreatureSet(&r, count: 7, version: version) }
        _ = r.u8()                                 // formation
        readArtifactsOfHero(&r, version: version)
        _ = r.u8()                                 // patrol radius / AI
        if version != .roe {
            if r.u8() == 1 { _ = r.string32() }    // biography
            _ = r.u8()                             // gender
        }
        if version != .roe && version != .ab {
            if r.u8() == 1 { r.skip(9) }           // spells
        } else if version == .ab {
            r.skip(1)
        }
        if version != .roe && version != .ab {
            if r.u8() == 1 { r.skip(4) }           // custom PrimSkills?
        }
        r.skip(16)
    }

    private static func readMonsterPayload(_ r: inout ByteReader, version: H3mVersion) {
        if version != .roe { r.skip(4) }           // monster type
        _ = r.u16()                                // count
        _ = r.u8()                                 // character
        if r.u8() == 1 {                           // message & resources
            _ = r.string32()
            readResources(&r)
            if version == .roe { _ = r.u8() } else { _ = r.u16() }
        }
        _ = r.u8()                                 // never flees
        _ = r.u8()                                 // join offer
        r.skip(2)                                  // army bonus / amount
    }

    private static func readTownPayload(_ r: inout ByteReader, version: H3mVersion) {
        if version != .roe { _ = r.u32() }         // town type
        _ = r.u8()                                 // owner
        if r.u8() == 1 { _ = r.string32() }        // custom name
        if r.u8() == 1 { readCreatureSet(&r, count: 7, version: version) }
        _ = r.u8()                                 // garrison formation
        if r.u8() == 1 {
            r.skip(6); r.skip(6)                   // built / restricted buildings
        } else {
            _ = r.u8() == 1                        // standard buildings
        }
        if version != .roe { r.skip(9) }           // custom buildings (SoD extra)
        r.skip(9)                                  //_obligatorySpells etc
        var n = Int(r.u32())                       // possible events
        while n > 0 {
            _ = r.string32()
            _ = r.string32()
            readResources(&r)
            _ = r.u8()
            if version == .sod { _ = r.u8() }
            r.skip(1); r.skip(2); r.skip(1)
            r.skip(17); r.skip(6); r.skip(14); r.skip(4)
            n -= 1
        }
        if version != .roe && version != .ab { r.skip(1) }
        r.skip(3)
    }

    // MARK: - gzip

    private static func gunzip(_ data: Data) -> Data {
        var src = [UInt8](data)
        guard src.count > 2 else { return data }
        // gzip magic 1F 8B; strip 10-byte header, then raw deflate, ignore trailer.
        if src[0] == 0x1F && src[1] == 0x8B {
            src = Array(src[10...])
            let out = Self.rawInflate(src, hint: data.count * 30)
            return out ?? data
        }
        return data
    }

    private static func rawInflate(_ src: [UInt8], hint: Int) -> Data? {
        // gzip streams may exceed our initial hint; grow on failure.
        for size in [hint, hint * 4, hint * 16] {
            guard size > 0, size < (1 << 30) else { continue }
            let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
            defer { dst.deallocate() }
            let written = src.withUnsafeBufferPointer { buf -> Int in
                compression_decode_buffer(dst, size, buf.baseAddress!, src.count, nil, COMPRESSION_ZLIB)
            }
            if written > 0 { return Data(bytes: dst, count: written) }
        }
        return nil
    }
}

enum H3mError: Error {
    case unsupportedVersion(Int32)
}
