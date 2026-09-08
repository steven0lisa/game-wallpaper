import Foundation
import Metal
import simd
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// One sprite drawn as an instanced quad. Field layout matches the Metal shader struct
/// (struct size rounds up to 64 bytes due to float4 alignment).
struct InstanceData {
    var a: SIMD4<Float>   // pos.x, pos.y (top-left, map px), size.x, size.y
    var b: SIMD4<Float>   // uv x0, y0, x1, y1 (atlas px)
    var c: SIMD4<Float>   // tint r,g,b,a
    var d: SIMD2<UInt32>  // page, flags (bit0 = flipH, bit1 = flipV)
}

struct FrameUniforms {
    var projection: simd_float4x4
    var brightness: Float
    var pad0: SIMD4<Float> = .init(repeating: 0)
    var pad1: SIMD4<Float> = .init(repeating: 0)
}

final class MapRenderer {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private var pipeline: MTLRenderPipelineState
    // Per-frame-in-flight buffers: the CPU rewrites slot data every frame while the GPU
    // may still be executing a previous commit (wait:false), so slots are never reused
    // until their command buffer completes (frameSlots semaphore = back-pressure).
    private static let bufferCount = 3
    private var instanceBuffers: [MTLBuffer]
    private var uniformBuffers: [MTLBuffer]
    private let frameSlots: DispatchSemaphore
    private var slotIndex = 0
    private var indexBuffer: MTLBuffer
    private var cornerBuffer: MTLBuffer

    private var textureArray: MTLTexture?

    // ---- 静止循环缓存：相机停留时预构建整个动画循环的 instance buffer， ----
    // ---- 播放帧直接绑定（零场景遍历、零 memcpy）；相机/地图/atlas 变化即失效。 ----
    private var loopCache: LoopCache?
    private var loopCacheBuilding = false
    private var cachedDrawBuffer: MTLBuffer?
    /// 同一场景只记一次拒绝日志
    private var lastRejectedScene: LoopSceneKey?
    /// 后台构建完成时校验场景未变（最近一次 buildFrame 的场景标识）
    private var latestScene: LoopSceneKey?
    // ---- 直接路径（平移中/超限地图）的整包 memcpy 跳过：数据版本 + slot 已拷贝版本 ----
    private var dataVersion = 0
    private var slotDataVersion: [Int]

    static let maxInstances = 65_536
    static let instanceStride = 64
    private var instances: [InstanceData] = []
    private var instanceCount = 0
    private var pendingUniforms: FrameUniforms?

    var currentBrightness: Float = 0

    init(device: MTLDevice) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw RenderError.device }
        self.queue = queue

        guard let library = try? device.makeLibrary(source: Self.shaderSource, options: nil),
              let vertexFn = library.makeFunction(name: "spriteVertex"),
              let fragmentFn = library.makeFunction(name: "spriteFragment") else {
            throw RenderError.shader
        }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vertexFn
        desc.fragmentFunction = fragmentFn
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        desc.colorAttachments[0].isBlendingEnabled = true
        desc.colorAttachments[0].rgbBlendOperation = .add
        // 图集为预乘 alpha（线性采样防暗边）；RGB: src + dst*(1-a)
        desc.colorAttachments[0].sourceRGBBlendFactor = .one
        desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        desc.colorAttachments[0].sourceAlphaBlendFactor = .one
        desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipeline = try device.makeRenderPipelineState(descriptor: desc)

        var ibs: [MTLBuffer] = []
        var ubs: [MTLBuffer] = []
        for _ in 0..<Self.bufferCount {
            guard let ib = device.makeBuffer(length: Self.instanceStride * Self.maxInstances, options: .storageModeShared),
                  let ub = device.makeBuffer(length: MemoryLayout<FrameUniforms>.stride, options: .storageModeShared) else {
                throw RenderError.buffer
            }
            ibs.append(ib)
            ubs.append(ub)
        }
        instanceBuffers = ibs
        uniformBuffers = ubs
        frameSlots = DispatchSemaphore(value: Self.bufferCount)

        let indices: [UInt16] = [0, 1, 2, 2, 1, 3]
        guard let idxB = device.makeBuffer(bytes: indices, length: 12, options: []),
              let cornerB = device.makeBuffer(bytes: [SIMD2<Float>(0, 0), SIMD2<Float>(1, 0), SIMD2<Float>(0, 1), SIMD2<Float>(1, 1)],
                                              length: 32, options: []) else {
            throw RenderError.buffer
        }
        indexBuffer = idxB
        cornerBuffer = cornerB
        instances = []
        instances.reserveCapacity(80_000)
        slotDataVersion = .init(repeating: -1, count: Self.bufferCount)
    }

    // MARK: - Atlas upload

    func uploadAtlas(_ atlas: FrameAtlas) {
        generation &+= 1
        lastSig = nil
        let ps = FrameAtlas.pageSize
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: ps, height: ps, mipmapped: false)
        desc.textureType = .type2DArray
        desc.arrayLength = max(atlas.pages.count, 1)
        desc.usage = [.shaderRead]
        guard let tex = device.makeTexture(descriptor: desc) else { return }
        for (i, page) in atlas.pages.enumerated() {
            page.pixels.withUnsafeBytes { raw in
                tex.replace(region: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0), size: MTLSize(width: ps, height: ps, depth: 1)),
                            mipmapLevel: 0, slice: i, withBytes: raw.baseAddress!, bytesPerRow: ps * 4, bytesPerImage: ps * ps * 4)
            }
        }
        textureArray = tex
    }

    // MARK: - Frame building

    struct Viewport {
        var viewLeft: Float
        var viewTop: Float
        var viewWidth: Float
        var viewHeight: Float
    }

    /// Computes the atlas UV rect for a sub-crop of a frame, pre-composed with the frame's flip
    /// (the shader then mirrors within the submitted rect when the flip flag is set).
    private static func uvRect(_ pf: PackedFrame, atlasPS: Int,
                               cropX: Float, cropY: Float, cropW: Float, cropH: Float,
                               flipH: Bool, flipV: Bool) -> (SIMD4<Float>, UInt32) {
        let ps = Float(atlasPS)
        let u0 = pf.u0 * ps, v0 = pf.v0 * ps, u1 = pf.u1 * ps, v1 = pf.v1 * ps
        let x0 = u0 + (flipH ? (pf.width.f - cropX - cropW) : cropX)
        let x1 = x0 + cropW
        let y0 = v0 + (flipV ? (pf.height.f - cropY - cropH) : cropY)
        let y1 = y0 + cropH
        var flags: UInt32 = 0
        if flipH { flags |= 1 }
        if flipV { flags |= 2 }
        return (SIMD4<Float>(x0, y0, x1, y1), flags)
    }

    /// Canvas-coordinate crop, VCMI order (MapTileStorage::load + MapRendererRoad::renderTile):
    /// the WHOLE frame is mirrored first (pre-flipped storage slots), then a plain canvas
    /// Rect is cropped from the flipped image. We mirror the data rect into flipped-canvas
    /// space, intersect with the requested rect, and let the shader mirror the sampled
    /// atlas (unflipped) pixels inside the quad via flags. Returns the intersection UVs,
    /// its offset inside the canvas-crop rect, and the flip flags to apply.
    private static func canvasCrop(_ pf: PackedFrame, atlasPS: Int,
                                   canvasX: Float, canvasY: Float, canvasW: Float, canvasH: Float,
                                   flipH: Bool, flipV: Bool)
        -> (uv: SIMD4<Float>, offset: SIMD2<Float>, size: SIMD2<Float>, flags: UInt32)? {
        let dX = Float(pf.offsetX), dY = Float(pf.offsetY)
        let dW = Float(pf.width), dH = Float(pf.height)
        let fx = flipH ? (Float(pf.fullCanvasW) - dX - dW) : dX
        let fy = flipV ? (Float(pf.fullCanvasH) - dY - dH) : dY
        let ix0 = max(canvasX, fx), iy0 = max(canvasY, fy)
        let ix1 = min(canvasX + canvasW, fx + dW), iy1 = min(canvasY + canvasH, fy + dH)
        guard ix1 > ix0, iy1 > iy0 else { return nil }
        let w = ix1 - ix0, h = iy1 - iy0
        let ps = Float(atlasPS)
        let lx0 = ix0 - fx, ly0 = iy0 - fy
        let uL = pf.u0 * ps + (flipH ? (dW - lx0 - w) : lx0)
        let uR = pf.u0 * ps + (flipH ? (dW - lx0) : (lx0 + w))
        let vT = pf.v0 * ps + (flipV ? (dH - ly0 - h) : ly0)
        let vB = pf.v0 * ps + (flipV ? (dH - ly0) : (ly0 + h))
        var flags: UInt32 = 0
        if flipH { flags |= 1 }
        if flipV { flags |= 2 }
        return (SIMD4<Float>(uL, vT, uR, vB),
                SIMD2<Float>(ix0 - canvasX, iy0 - canvasY),
                SIMD2<Float>(w, h),
                flags)
    }

    /// 实例重建的条件签名：相机亚像素漂移不改变可见图块集合，动画步不变时
    /// 实例数据完全相同 —— 跳过重建与拷贝（约 30 次/秒 → 约 5.5 次/秒）。
    private struct BuildSig: Equatable {
        var mapID: ObjectIdentifier
        var animStep: Int
        var tx0: Int, ty0: Int, tx1: Int, ty1: Int
        var gen: Int
    }
    private var lastSig: BuildSig?
    private(set) var generation = 0 // atlas 重建时递增，强制重算

    func buildFrame(map: GameMap, atlas: FrameAtlas, view: Viewport, timeMs: Double,
                    cameraAtRest: Bool = false) {
        let px = view.viewLeft, py = view.viewTop
        let pw = view.viewWidth, ph = view.viewHeight
        let animStep = Int(timeMs / 180)
        let x0 = Int(floor(px / 32)) - 1
        let x1 = Int(floor((px + pw) / 32)) + 1
        let y0 = Int(floor(py / 32)) - 1
        let y1 = Int(floor((py + ph) / 32)) + 1

        // ---- 循环缓存命中：直接绑定预构建 buffer（零场景遍历、零拷贝）----
        let sceneKey = LoopSceneKey(mapID: ObjectIdentifier(map), gen: generation,
                                    tx0: x0, ty0: y0, tx1: x1, ty1: y1)
        if let cache = loopCache, cache.key == sceneKey {
            let step = animStep % cache.cycle
            cachedDrawBuffer = cache.buffers[step]
            instanceCount = cache.counts[step]
            lastSig = nil
            pendingUniforms = FrameUniforms(projection: Self.orthographic(left: px, top: py, width: pw, height: ph),
                                            brightness: currentBrightness)
            return
        }
        cachedDrawBuffer = nil

        // 记录最近到达的场景：相机停留时同一 sceneKey 反复到达无影响；平移/跳跃时
        // 每帧 sceneKey 都在变，正在后台构建的旧场景在提交回调里会被 latestScene !=
        // sceneKey 拒绝，避免把相机已离开的场景写进 cache（也保证过期 buffer 被尽快释放）。
        latestScene = sceneKey

        let sig = BuildSig(mapID: ObjectIdentifier(map), animStep: animStep,
                           tx0: x0, ty0: y0, tx1: x1, ty1: y1, gen: generation)
        if sig == lastSig {
            // 实例不变，仅更新本帧 uniform（亚像素视口偏移由 GPU 投影呈现）
            pendingUniforms = FrameUniforms(projection: Self.orthographic(left: px, top: py, width: pw, height: ph),
                                            brightness: currentBrightness)
            return
        }
        lastSig = sig
        dataVersion &+= 1

        instanceCount = buildInstances(map: map, atlas: atlas, view: view,
                                       x0: x0, y0: y0, x1: x1, y1: y1, animStep: animStep,
                                       into: &instances)
        pendingUniforms = FrameUniforms(projection: Self.orthographic(left: px, top: py, width: pw, height: ph),
                                        brightness: currentBrightness)

        maybePrebuildLoopCache(map: map, atlas: atlas, view: view, sceneKey: sceneKey,
                               cameraAtRest: cameraAtRest)
    }

    /// 全场景 instance 构建：坐标全部在地图空间（整数），相机仅通过投影矩阵生效，
    /// 因此同一 (可见图块范围, animStep) 的数据与亚像素视口位置无关，可缓存复用。
    /// 主线程直接路径与后台循环缓存构建共用；返回写入数量。
    @discardableResult
    private func buildInstances(map: GameMap, atlas: FrameAtlas, view: Viewport,
                                x0: Int, y0: Int, x1: Int, y1: Int, animStep: Int,
                                into instances: inout [InstanceData]) -> Int {
        let px = view.viewLeft, py = view.viewTop
        let pw = view.viewWidth, ph = view.viewHeight
        let ps = FrameAtlas.pageSize
        let size = map.size
        instances.removeAll(keepingCapacity: true)

        func push(_ pos: SIMD4<Float>, _ uv: SIMD4<Float>, flags: UInt32, page: Int) {
            if instances.count < Self.maxInstances {
                instances.append(InstanceData(a: pos, b: uv, c: SIMD4<Float>(1, 1, 1, 1),
                                              d: SIMD2<UInt32>(UInt32(page), flags)))
            }
        }

        func packed(_ key: FrameKey) -> PackedFrame? { atlas.frame(key) }

        // ---- border tiles (all tiles outside the map within view) ----
        for y in y0...y1 {
            for x in x0...x1 {
                guard x < 0 || y < 0 || x >= size || y >= size else { continue }
                let idx = GameMap.borderFrameIndex(x: x, y: y, mapSize: size)
                guard let pf = packed(FrameKey(def: GameMap.borderDef, block: 0, index: idx, step: 0)) else { continue }
                let (uv, flags) = Self.uvRect(pf, atlasPS: ps, cropX: 0, cropY: 0, cropW: 32, cropH: 32, flipH: false, flipV: false)
                push(SIMD4<Float>(Float(x * 32), Float(y * 32), 32, 32), uv, flags: flags, page: pf.page)
            }
        }

        // ---- terrain ----
        for cell in map.terrain {
            if Float(cell.x * 32) + 32 < px || Float(cell.x * 32) > px + pw { continue }
            if Float(cell.y * 32) + 32 < py || Float(cell.y * 32) > py + ph { continue }
            let step = cell.steps > 1 ? animStep % cell.steps : 0
            guard let pf = packed(FrameKey(def: cell.def, block: 0, index: cell.index, step: step)) else { continue }
            let (uv, flags) = Self.uvRect(pf, atlasPS: ps, cropX: 0, cropY: 0, cropW: 32, cropH: 32,
                                          flipH: cell.flipH, flipV: cell.flipV)
            push(SIMD4<Float>(Float(cell.x * 32), Float(cell.y * 32), 32, 32), uv, flags: flags, page: pf.page)
        }

        // ---- rivers ----
        for cell in map.rivers {
            if Float(cell.x * 32) + 32 < px || Float(cell.x * 32) > px + pw { continue }
            if Float(cell.y * 32) + 32 < py || Float(cell.y * 32) > py + ph { continue }
            let step = cell.steps > 1 ? animStep % cell.steps : 0
            guard let pf = packed(FrameKey(def: cell.def, block: 0, index: cell.index, step: step)) else { continue }
            let (uv, flags) = Self.uvRect(pf, atlasPS: ps, cropX: 0, cropY: 0, cropW: 32, cropH: 32,
                                          flipH: cell.flipH, flipV: cell.flipV)
            push(SIMD4<Float>(Float(cell.x * 32), Float(cell.y * 32), 32, 32), uv, flags: flags, page: pf.page)
        }

        // ---- roads: VCMI renders every visible tile — a tile with no road still
        //      draws the bottom half of the road image above it, otherwise roads
        //      break apart at connections (road image spans two tiles) ----
        if !map.roads.isEmpty {
            var roadByTile: [Int: RoadCell] = [:]
            for cell in map.roads { roadByTile[cell.y * size + cell.x] = cell }

            let cx0 = max(x0, 0), cx1 = min(x1, size - 1)
            let cy0 = max(y0, 0), cy1 = min(y1, size - 1)
            for y in cy0...cy1 {
                for x in cx0...cx1 {
                    // Road frames have margins (data sits inside a 32×32 canvas); the
                    // half-tile split works in CANVAS coordinates (VCMI Rect semantics).
                    // bottom half of the tile above's road canvas → this tile's top half
                    if y > 0, let above = roadByTile[(y - 1) * size + x] {
                        if let pf = packed(FrameKey(def: above.def, block: 0, index: above.index, step: 0)),
                           let c = Self.canvasCrop(pf, atlasPS: ps, canvasX: 0, canvasY: 16, canvasW: 32, canvasH: 16,
                                                   flipH: above.flipH, flipV: above.flipV) {
                            push(SIMD4<Float>(Float(x * 32) + c.offset.x, Float(y * 32) + c.offset.y, c.size.x, c.size.y),
                                 c.uv, flags: c.flags, page: pf.page)
                        }
                    }
                    // top half of this tile's road canvas → this tile's bottom half
                    if let cell = roadByTile[y * size + x] {
                        if let pf = packed(FrameKey(def: cell.def, block: 0, index: cell.index, step: 0)),
                           let c = Self.canvasCrop(pf, atlasPS: ps, canvasX: 0, canvasY: 0, canvasW: 32, canvasH: 16,
                                                   flipH: cell.flipH, flipV: cell.flipV) {
                            push(SIMD4<Float>(Float(x * 32) + c.offset.x, Float(y * 32) + 16 + c.offset.y, c.size.x, c.size.y),
                                 c.uv, flags: c.flags, page: pf.page)
                        }
                    }
                }
            }
        }

        // ---- objects (canvas bottom-right anchored at the anchor tile) ----
        for obj in map.objects {
            let canvasLeft = Float((obj.anchorX + 1) * 32 - obj.fullW)
            let canvasTop = Float((obj.anchorY + 1) * 32 - obj.fullH)
            if canvasLeft + Float(obj.fullW) < px || canvasLeft > px + pw { continue }
            if canvasTop + Float(obj.fullH) < py || canvasTop > py + ph { continue }

            guard !obj.frames.isEmpty else { continue }
            let frameIndex = (animStep + obj.phase) % obj.frames.count
            guard let pf = packed(obj.frames[frameIndex]) else { continue }
            let offX = Float(pf.offsetX), offY = Float(pf.offsetY)
            push(SIMD4<Float>(canvasLeft + offX, canvasTop + offY, Float(pf.width), Float(pf.height)),
                 SIMD4<Float>(pf.u0 * Float(ps), pf.v0 * Float(ps), pf.u1 * Float(ps), pf.v1 * Float(ps)),
                 flags: 0, page: pf.page)
        }

        return instances.count
    }

    // MARK: - 静止循环缓存（相机停留时预构建整段动画循环，播放帧只读缓存）

    /// 循环缓存的场景标识：同一张图 + 同一 atlas 代 + 同一可见图块范围。
    private struct LoopSceneKey: Equatable {
        var mapID: ObjectIdentifier
        var gen: Int
        var tx0: Int, ty0: Int, tx1: Int, ty1: Int
    }

    /// 一个动画循环内每步的只读实例 buffer。实例坐标在地图空间，相机移动只改
    /// 投影矩阵；场景实例数据是 (可见图块集合, animStep % 各元素周期) 的函数，
    /// 相机停留时按周期 LCM 预构建后即可整段循环播放。
    private final class LoopCache {
        let key: LoopSceneKey
        let cycle: Int
        let buffers: [MTLBuffer]
        let counts: [Int]

        init(key: LoopSceneKey, cycle: Int, buffers: [MTLBuffer], counts: [Int]) {
            self.key = key
            self.cycle = cycle
            self.buffers = buffers
            self.counts = counts
        }
    }

    /// 整循环周期/内存超限时回退直接路径（仍有 sig-skip 与 memcpy-skip 兜底）
    static let maxLoopCycle = 96
    static let maxLoopCacheBytes = 96_000_000

    /// 相机停留时在后台线程预构建整个动画循环（构建期间直接路径照常渲染，
    /// 无卡顿）。完成后场景已变化则丢弃，由后续帧重新触发。
    private func maybePrebuildLoopCache(map: GameMap, atlas: FrameAtlas, view: Viewport,
                                        sceneKey: LoopSceneKey, cameraAtRest: Bool) {
        guard cameraAtRest, !loopCacheBuilding else { return }
        if let cache = loopCache, cache.key == sceneKey { return }
        let cycle = Self.visibleAnimCycle(map: map, view: view)
        let estBytes = cycle * Self.instanceStride * max(instanceCount, 1)
        guard cycle <= Self.maxLoopCycle, estBytes <= Self.maxLoopCacheBytes else {
            if lastRejectedScene != sceneKey {
                lastRejectedScene = sceneKey
                NSLog("Heroes3Wallpaper: loop cache skipped cycle=%d instances=%d estBytes=%d", cycle, instanceCount, estBytes)
                debugLog("loop-cache skipped cycle=\(cycle) instances=\(instanceCount) estBytes=\(estBytes) [\(map.size)x\(map.size)]")
            }
            return
        }

        loopCacheBuilding = true
        latestScene = sceneKey
        let device = self.device
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var buffers: [MTLBuffer] = []
            var counts: [Int] = []
            var scratch: [InstanceData] = []
            scratch.reserveCapacity(80_000)
            var ok = true
            for step in 0..<cycle {
                let count = self?.buildInstances(map: map, atlas: atlas, view: view,
                                                 x0: sceneKey.tx0, y0: sceneKey.ty0,
                                                 x1: sceneKey.tx1, y1: sceneKey.ty1,
                                                 animStep: step, into: &scratch) ?? 0
                if let buf = device.makeBuffer(bytes: scratch, length: count * Self.instanceStride,
                                               options: .storageModeShared) {
                    buffers.append(buf)
                    counts.append(count)
                } else {
                    ok = false
                    break
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.loopCacheBuilding = false
                // 构建期间相机/地图/atlas 变过则作废，下一帧重新触发。
                // 作废时本闭包持有的 buffers/counts 随闭包退出释放，不会滞留。
                guard ok, self.latestScene == sceneKey, self.generation == sceneKey.gen else {
                    if ok {
                        NSLog("Heroes3Wallpaper: loop cache discarded (scene changed during build) cycle=%d", cycle)
                        debugLog("loop-cache discarded cycle=\(cycle)")
                    }
                    return
                }
                self.loopCache = LoopCache(key: sceneKey, cycle: cycle, buffers: buffers, counts: counts)
                NSLog("Heroes3Wallpaper: loop cache ready cycle=%d instances=%d", cycle, counts.first ?? 0)
                debugLog("loop-cache ready cycle=\(cycle) first=\(counts.first ?? 0) n=\(counts.count)")
            }
        }
    }

    /// 可见元素的动画周期 LCM（饱和至 10^6 防溢出）。地形/河流为调色板旋转步数
    /// （水 12、熔岩河 9 等），它们才是全局同步的动画（整幅画面同相）。
    ///
    /// 对象动画虽然也用 animStep 驱动（frameIndex = (animStep+phase)%frames.count），
    /// 但各对象周期彼此独立（phase 为质数步进），若把对象帧数也 LCM 进全局周期，
    /// 任何一张含多帧对象的地图周期都会爆炸（如某对象 16 帧 × 水 12 帧 → 48+），
    /// 使循环缓存（上限 maxLoopCycle）永不命中。因此对象帧数不参与全局周期；
    /// 缓存播放时每步按 (step+phase)%count 取帧，采样正确，仅个别对象在周期
    /// 小于其帧数时会跳过少数帧（可接受，远优于缓存永不失效）。
    static func visibleAnimCycle(map: GameMap, view: Viewport) -> Int {
        let px = view.viewLeft, py = view.viewTop
        let pw = view.viewWidth, ph = view.viewHeight
        func lcmSat(_ a: Int, _ b: Int) -> Int {
            let limit = 1_000_000
            var g = a, r = b
            while r != 0 { (g, r) = (r, g % r) }
            let l = a / g * b
            return l >= limit ? limit : l
        }
        var cycle = 1
        for cell in map.terrain where cell.steps > 1 {
            if Float(cell.x * 32) + 32 < px || Float(cell.x * 32) > px + pw { continue }
            if Float(cell.y * 32) + 32 < py || Float(cell.y * 32) > py + ph { continue }
            cycle = lcmSat(cycle, cell.steps)
        }
        for cell in map.rivers where cell.steps > 1 {
            if Float(cell.x * 32) + 32 < px || Float(cell.x * 32) > px + pw { continue }
            if Float(cell.y * 32) + 32 < py || Float(cell.y * 32) > py + ph { continue }
            cycle = lcmSat(cycle, cell.steps)
        }
        return cycle
    }

    private static func orthographic(left: Float, top: Float, width: Float, height: Float) -> simd_float4x4 {
        let sx = 2 / width
        let sy = -2 / height // map y grows downward
        let tx = -(2 * left + width) / width
        let ty = (2 * top + height) / height
        return simd_float4x4(
            SIMD4<Float>(sx, 0, 0, 0),
            SIMD4<Float>(0, sy, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(tx, ty, 0, 1))
    }

    // MARK: - Drawing

    func draw(to renderPassDescriptor: MTLRenderPassDescriptor, wait: Bool) {
        guard textureArray != nil else { return }
        guard let cmd = queue.makeCommandBuffer(),
              let encoder = cmd.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else { return }

        // 背压：最多 bufferCount 个提交在飞；slot 在其命令缓冲完成后才会被复用
        frameSlots.wait()
        let slot = slotIndex % Self.bufferCount
        slotIndex &+= 1

        // 实例数据：循环缓存命中时直接绑定预构建只读 buffer（可跨在飞帧共享，无撕裂）；
        // ring 路径仅在数据版本变化时整包 memcpy（GPU 可能还在执行上一帧的提交，
        // 单缓冲直写会撕裂，表现为偶发一帧的错误贴图/闪烁）。
        let instanceBuffer: MTLBuffer
        if let cached = cachedDrawBuffer {
            instanceBuffer = cached
        } else {
            instanceBuffer = instanceBuffers[slot]
            if instanceCount > 0, slotDataVersion[slot] != dataVersion {
                instances.withUnsafeBufferPointer { buf in
                    memcpy(instanceBuffers[slot].contents(), buf.baseAddress!, instanceCount * Self.instanceStride)
                }
                slotDataVersion[slot] = dataVersion
            }
        }
        if let uniforms = pendingUniforms {
            var u = uniforms
            withUnsafeMutableBytes(of: &u) { raw in
                uniformBuffers[slot].contents().copyMemory(from: raw.baseAddress!, byteCount: MemoryLayout<FrameUniforms>.stride)
            }
        }

        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(instanceBuffer, offset: 0, index: 0)
        encoder.setVertexBuffer(uniformBuffers[slot], offset: 0, index: 1)
        encoder.setVertexBuffer(cornerBuffer, offset: 0, index: 2)
        encoder.setFragmentTexture(textureArray, index: 0)
        encoder.setFragmentBuffer(uniformBuffers[slot], offset: 0, index: 0)

        encoder.drawIndexedPrimitives(type: .triangle, indexCount: 6, indexType: .uint16,
                                      indexBuffer: indexBuffer, indexBufferOffset: 0,
                                      instanceCount: max(instanceCount, 1))
        encoder.endEncoding()
        cmd.addCompletedHandler { [weak self] _ in
            if let self, let err = cmd.error {
                NSLog("Heroes3Wallpaper: command buffer error: \(err)")
            }
            self?.frameSlots.signal()
        }
        cmd.commit()
        if wait { cmd.waitUntilCompleted() }
    }

    enum RenderError: Error {
        case device, shader, buffer
    }

    // MARK: - Snapshot (headless verification)

    /// Renders one frame offscreen and returns a CGImage.
    func snapshot(width: Int, height: Int) -> CGImage? {
        guard let textureArray else { return nil }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        guard let target = device.makeTexture(descriptor: desc) else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        draw(to: pass, wait: true)

        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            target.getBytes(raw.baseAddress!, bytesPerRow: bytesPerRow,
                            from: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0), size: MTLSize(width: width, height: height, depth: 1)),
                            mipmapLevel: 0)
        }
        for i in stride(from: 0, to: pixels.count, by: 4) { // BGRA → RGBA
            pixels.swapAt(i, i + 2)
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: bytesPerRow, space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        return ctx.makeImage()
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw RenderError.buffer }
    }

    // MARK: - Shaders

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Instance {
        float4 a; // pos.xy, size.xy
        float4 b; // uv x0,y0,x1,y1 (atlas px)
        float4 c; // tint
        uint2 d;  // page, flags
    };

    struct Uniforms {
        float4x4 projection;
        float brightness;
        float4 pad0;
        float4 pad1;
    };

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
        float4 tint;
        uint page;
    };

    vertex VertexOut spriteVertex(uint vid [[vertex_id]],
                                  uint iid [[instance_id]],
                                  const device Instance* instances [[buffer(0)]],
                                  const device Uniforms& uniforms [[buffer(1)]],
                                  const device float2* corners [[buffer(2)]]) {
        const device Instance& inst = instances[iid];
        float2 corner = corners[vid];
        float2 pos = inst.a.xy + corner * inst.a.zw;
        VertexOut out;
        out.position = uniforms.projection * float4(pos, 0.0, 1.0);
        float u = mix(inst.b.x, inst.b.z, corner.x);
        float v = mix(inst.b.y, inst.b.w, corner.y);
        uint flags = inst.d.y;
        if (flags & 1u) { u = inst.b.x + inst.b.z - u; }
        if (flags & 2u) { v = inst.b.y + inst.b.w - v; }
        out.uv = float2(u, v) / 2048.0;
        out.tint = inst.c;
        out.page = inst.d.x;
        return out;
    }

    fragment float4 spriteFragment(VertexOut in [[stage_in]],
                                   texture2d_array<float> atlas [[texture(0)]],
                                   const device Uniforms& uniforms [[buffer(0)]]) {
        constexpr sampler s(address::clamp_to_edge, filter::linear);
        float4 color = atlas.sample(s, in.uv, in.page);
        color.rgb *= (1.0 - uniforms.brightness);
        return color * in.tint;
    }
    """
}

private extension Int {
    var f: Float { Float(self) }
}

/// 诊断文件日志：LSUIElement 应用的 NSLog 不落到标准输出，排查渲染/缓存问题时
/// 追加到 /tmp/heroes3wallpaper.log，便于按"日志先行"原则复现（临时保留）。
func debugLog(_ msg: String) {
    let line = "\(Date()) \(msg)\n"
    if let d = line.data(using: .utf8),
       let fh = FileHandle(forWritingAtPath: "/tmp/heroes3wallpaper.log") {
        _ = try? fh.seekToEnd()
        _ = try? fh.write(contentsOf: d)
        _ = try? fh.close()
    } else {
        _ = try? line.write(toFile: "/tmp/heroes3wallpaper.log", atomically: true, encoding: .utf8)
    }
}
