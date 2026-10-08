import Foundation

// Terrain / river / road def names by h3m byte value.
let terrainDefNames = ["DIRTTL", "SANDTL", "GRASTL", "SNOWTL", "SWMPTL", "ROUGTL", "SUBBTL", "LAVATL", "WATRTL", "ROCKTL"]
let riverDefNames = [nil, "CLRRVR", "ICYRVR", "MUDRVR", "LAVRVR"]
let roadDefNames = [nil, "DIRTRD", "GRAVRD", "COBBRD"]

struct TerrainCell {
    var x: Int
    var y: Int
    var def: String
    var index: Int
    var flipH: Bool
    var flipV: Bool
    var steps: Int // palette animation steps (1 = static)
}

struct RoadCell {
    var x: Int
    var y: Int
    var def: String
    var index: Int
    var flipH: Bool
    var flipV: Bool
}

struct MapObject {
    var anchorX: Int
    var anchorY: Int
    var defName: String
    var frames: [FrameKey] // block-0 frames, in order
    var phase: Int         // per-object animation phase offset
    var isHero: Bool
    var priority: Int
    var // bounding canvas size for culling
        fullW: Int
    var fullH: Int
}

/// Built render data for one map level (surface or underground).
final class GameMap {
    let size: Int
    let level: Int
    let title: String
    let terrain: [TerrainCell]
    let rivers: [TerrainCell]
    let roads: [RoadCell]
    let objects: [MapObject]
    private(set) var frameKeys: [FrameKey] = []
    private(set) var missingObjectDefs: [String] = []

    /// Adventure-map border def.
    static let borderDef = "EDG"

    init(h3m: H3mFile, library: AssetLibrary, level: Int) {
        size = h3m.size
        self.level = level
        title = h3m.title

        var terrain: [TerrainCell] = []
        var rivers: [TerrainCell] = []
        var roads: [RoadCell] = []
        var keys: [FrameKey] = []

        func addTerrainKey(def: String, index: Int, step: Int) {
            keys.append(FrameKey(def: def, block: 0, index: index, step: step))
        }

        for y in 0..<size {
            for x in 0..<size {
                guard let tile = h3m.tile(x: x, y: y, level: level) else { continue }
                // terrain
                if Int(tile.terrain) < terrainDefNames.count {
                    let def = terrainDefNames[Int(tile.terrain)]
                    let steps = DefRaster.rotationStepCount(forDefName: def)
                    let flipBits = Int(tile.mirrorConfig) & 3
                    terrain.append(TerrainCell(x: x, y: y, def: def, index: Int(tile.terrainImageIndex),
                                               flipH: (flipBits & 1) != 0, flipV: (flipBits & 2) != 0,
                                               steps: steps))
                    for step in 0..<steps { addTerrainKey(def: def, index: Int(tile.terrainImageIndex), step: step) }
                }
                // river
                if Int(tile.river) < riverDefNames.count, let def = riverDefNames[Int(tile.river)] {
                    let steps = DefRaster.rotationStepCount(forDefName: def)
                    let flipBits = (Int(tile.mirrorConfig) >> 2) & 3
                    rivers.append(TerrainCell(x: x, y: y, def: def, index: Int(tile.riverImageIndex),
                                              flipH: (flipBits & 1) != 0, flipV: (flipBits & 2) != 0,
                                              steps: steps))
                    for step in 0..<steps { addTerrainKey(def: def, index: Int(tile.riverImageIndex), step: step) }
                }
                // road — flip bit semantics identical to terrain/river (bit0=mirror-x, bit1=mirror-y),
                // confirmed against vcmieditor pixel-perfect (frame 4 + flip 0x01 matched exactly)
                if Int(tile.road) < roadDefNames.count, let def = roadDefNames[Int(tile.road)] {
                    let flipBits = (Int(tile.mirrorConfig) >> 4) & 3
                    roads.append(RoadCell(x: x, y: y, def: def, index: Int(tile.roadImageIndex),
                                          flipH: (flipBits & 1) != 0, flipV: (flipBits & 2) != 0))
                    addTerrainKey(def: def, index: Int(tile.roadImageIndex), step: 0)
                }
            }
        }
        self.terrain = terrain
        self.rivers = rivers
        self.roads = roads

        // ---- objects ----
        // Draw order: priority desc (drawn first = further behind), then y asc, heroes last, x asc, h3m order.
        var objects: [H3mObject] = h3m.objects.filter { $0.z == level }
        objects.sort { a, b in
            if a.def.placementOrder != b.def.placementOrder { return a.def.placementOrder > b.def.placementOrder }
            if a.y != b.y { return a.y < b.y }
            let aHero = a.objectId == 34 || a.objectId == 70 || a.objectId == 62
            let bHero = b.objectId == 34 || b.objectId == 70 || b.objectId == 62
            if aHero != bHero { return bHero } // non-heroes first, heroes drawn last
            if a.x != b.x { return a.x < b.x }
            return a.defIndex < b.defIndex
        }

        var mapObjects: [MapObject] = []
        var phase = 0
        for obj in objects {
            // Invisible object types: events, grail, random heroes/placeholders (grail is buried).
            let objectId = obj.objectId
            if objectId == 26 || objectId == 36 || objectId == 214 { continue }
            let spriteName = Self.resolvedSpriteName(for: obj)
            guard let def = library.def(named: spriteName), !def.blocks.isEmpty else {
                missingObjectDefs.append(spriteName)
                continue
            }
            let frames = def.blocks[0].indices.map { FrameKey(def: spriteName.uppercased(), block: 0, index: $0, step: 0) }
            guard !frames.isEmpty else {
                missingObjectDefs.append(spriteName + " (no frames)")
                continue
            }
            keys.append(contentsOf: frames)
            let mapObject = MapObject(
                anchorX: obj.x,
                anchorY: obj.y,
                defName: spriteName,
                frames: frames,
                phase: phase,
                isHero: objectId == 34 || objectId == 70 || objectId == 62,
                priority: Int(obj.def.placementOrder),
                fullW: def.fullWidth,
                fullH: def.fullHeight)
            mapObjects.append(mapObject)
            phase += 7 // per-object phase offset (prime-ish step decorrelates neighbours)
        }
        self.objects = mapObjects

        // border tiles
        let borderSteps = 1
        for i in 0..<36 { addTerrainKey(def: Self.borderDef, index: i, step: borderSteps - 1) }

        frameKeys = keys
    }

    /// Replaces random monsters/towns/resources/artifacts with a concrete sprite
    /// (port of the reference wallpaper's ObjectsRandomizer).
    static func resolvedSpriteName(for obj: H3mObject) -> String {
        var name = obj.def.spriteName
        let id = obj.objectId
        let subId = obj.def.objectClassSubId

        switch id {
        case 71: // random monster
            name = Self.randomMonster(level: nil)
        case 72, 73, 74, 75, 162, 163, 164: // random monster L1..L7
            name = Self.randomMonster(level: [72: 1, 73: 2, 74: 3, 75: 4, 162: 5, 163: 6, 164: 7][id])
        case 5: // artifact
            name = String(format: "ava%04d", subId)
        case 65, 66, 67, 68: // random artifacts
            name = String(format: "ava%04d", Int.random(in: 10...140))
        case 69: // random relic
            name = String(format: "ava%04d", Int.random(in: 129...139))
        case 76: // random resource
            name = Self.randomResource()
        case 77: // random town
            name = Self.randomTown(faction: subId)
        case 216, 217, 218: // random dwellings
            name = Self.randomDwelling()
        default:
            break
        }
        return name
    }

    static func randomMonster(level: Int?) -> String {
        let monsters: [Int: [String]] = [
            1: ["AVWPike", "AVWpikx0", "AVWcent0", "AVWcenx0", "AVWgrem0", "AVWgrex0", "AVWimp0", "AVWimpx0", "AVWskel0", "AVWskex0", "AVWtrog0", "AvWInfr", "AVWgobl0", "AVWgobx0", "AVWgnll0", "AVWgnlx0", "AVWpixie", "AVWsprit", "AVWhalf", "AVWpeas"],
            2: ["AvWLCrs", "AvWHCrs", "AVWdwrf0", "AVWdwrx0", "AVWgarg0", "AVWgarx0", "AVWgog0", "AVWgogx0", "AVWzomb0", "AVWzomx0", "AVWharp0", "AVWharx0", "AVWwolf0", "AVWwolx0", "AvWLizr", "AVWlizx0", "AVWelmw0", "AVWicee", "AVWboar", "AVWrog"],
            3: ["AvWGrif", "AVWgrix0", "AVWelfw0", "AVWelfx0", "AVWgolm0", "AVWgolx0", "AVWhoun0", "AVWhoux0", "AvWWigh", "AVWwigx0", "AVWbehl0", "AVWbehx0", "AVWorc0", "AVWorcx0", "AvWDFly", "AvWDFir", "AVWelme0", "AVWstone", "AVWmumy", "AVWnomd"],
            4: ["AVWswrd0", "AVWswrx0", "AVWpega0", "AVWpegx0", "AVWmage0", "AVWmagx0", "AVWdemn0", "AVWdemx0", "AVWvamp0", "AVWvamx0", "AvWMeds", "AVWmedx0", "AVWogre0", "AVWogrx0", "AvWBasl", "AvWGBas", "AVWelma0", "AVWstorm", "AVWglmg0", "AVWsharp"],
            5: ["AvWMonk", "AVWmonx0", "AVWtree0", "AVWtrex0", "AVWgeni0", "AVWgenx0", "AVWpitf0", "AVWpitx0", "AVWlich0", "AVWlicx0", "AvWMino", "AVWminx0", "AVWroc0", "AVWrocx0", "AvWGorg", "AVWgorx0", "AVWelmf0", "AVWnrg", "AVWglmd0"],
            6: ["AVWcvlr0", "AVWcvlx0", "AVWunic0", "AVWunix0", "AVWnaga0", "AVWnagx0", "AVWefre0", "AVWefrx0", "AVWbkni0", "AVWbknx0", "AVWmant0", "AVWmanx0", "AVWcycl0", "AVWcycx0", "AvWWyvr", "AVWwyvx0", "AVWpsye", "AVWmagel", "AVWench"],
            7: ["AvWAngl", "AvWArch", "AVWdrag0", "AVWdrax0", "AVWtitn0", "AVWtitx0", "AVWdevl0", "AVWdevx0", "AVWbone0", "AVWbonx0", "AvWRDrg", "AVWddrx0", "AVWbhmt0", "AVWbhmx0", "AvWHydr", "AVWhydx0", "AVWfbird", "AVWphx"],
        ]
        let lvl = level ?? monsters.keys.randomElement()!
        guard let list = monsters[lvl] else { return "AVWpeas" }
        return list.randomElement()!
    }

    static func randomResource() -> String {
        ["avtwood0", "avtore0", "avtsulf0", "avtmerc0", "avtcrys0", "avtgems0", "avtgold0"].randomElement()!
    }

    private static let factions = ["CASTLE", "RAMPART", "TOWER", "INFERNO", "NECROPOLIS", "DUNGEON", "STRONGHOLD", "FORTRESS", "CONFLUX"]

    static func randomTown(faction: Int) -> String {
        let towns = ["avccasx0", "avcramx0", "avctowx0", "avcinfx0", "avcnecx0", "avcdunx0", "avcstrx0", "avcftrx0", "avchforx"]
        let villages = ["avccast0", "avcramp0", "avctowr0", "avcinfc0", "avcnecr0", "avcdung0", "avcstro0", "avcftrt0", "avchfor0"]
        let list = Bool.random() ? towns : villages
        if faction >= 0, faction < list.count { return list[faction] }
        return list.randomElement()!
    }

    static func randomDwelling() -> String {
        let dwellings: [[String]] = [
            ["AVGpike0", "AVGcros0", "AVGgrff0", "AVGswor0", "AVGmonk0", "AVGcavl0", "AVGangl0"],
            ["AVGcent0", "AVGdwrf0", "AVGelf0", "AVGpega0", "AVGtree0", "AVGunic0", "AVGgdrg0"],
            ["AVGgrem0", "AVGgarg0", "AVGgolm0", "AVGmage0", "AVGgeni0", "AVGnaga0", "AVGtitn0"],
            ["AVGimp0", "AVGgogs0", "AVGhell0", "AVGdemn0", "AVGpit0", "AVGefre0", "AVGdevl0"],
            ["AVGskel0", "AVGzomb0", "AVGwght0", "AVGvamp0", "AVGlich0", "AVGbkni0", "AVGbone0"],
            ["AVGtrog0", "AVGharp0", "AVGbhld0", "AVGmdsa0", "AVGmino0", "AVGmant0", "AVGrdrg0"],
            ["AVGgobl0", "AVGwolf0", "AVGorcg0", "AVGogre0", "AVGrocs0", "AVGcycl0", "AVGbhmt0"],
            ["AVGgnll0", "AVGlzrd0", "AVGdfly0", "AVGbasl0", "AVGgorg0", "AVGwyvn0", "AVGhydr0"],
            ["AVGpixie", "AVGair0", "AVGwatr0", "AVGfire0", "AVGerth0", "AVGelp", "AVGfbrd"],
        ]
        let faction = dwellings.randomElement()!
        return faction.randomElement()!
    }

    // MARK: - Border (EDG) frame index, per VCMI MapRendererBorder::getIndexForTile

    static func borderFrameIndex(x: Int, y: Int, mapSize: Int) -> Int {
        // Far-outside check first (mirrors VCMI getIndexForTile ordering); Swift % keeps
        // the sign of negative operands, so use abs() for the far pattern.
        if x < -1 || x > mapSize || y < -1 || y > mapSize {
            return abs(x) % 4 + 4 * (abs(y) % 4)
        }
        if x == -1 && y == -1 { return 16 }
        if x == mapSize && y == -1 { return 17 }
        if x == mapSize && y == mapSize { return 18 }
        if x == -1 && y == mapSize { return 19 }
        if y == -1 { return 20 + (x % 4) }
        if x == mapSize { return 24 + (y % 4) }
        if y == mapSize { return 28 + (x % 4) }
        if x == -1 { return 32 + (y % 4) }
        return abs(x) % 4 + 4 * (abs(y) % 4)
    }
}
