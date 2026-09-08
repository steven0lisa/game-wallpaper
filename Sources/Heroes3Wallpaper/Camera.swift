import Foundation
import simd

/// 跳点相机：每隔 `switchInterval` 秒在地图内随机挑一个可见点（cover 视口范围内），
/// 用 ease-in-out 插值滑过去，落在新点停留到下一次切换。
/// 比连续漫游更像正式游戏的关卡浏览：画面内容明显变化、节拍有间隔、不耗 CPU。
struct Camera {
    var center: SIMD2<Float> = .init(repeating: 0)
    /// 目标点（下一处停留的位置）
    private var target: SIMD2<Float> = .init(repeating: 0)
    /// 起点（=上一次停留位置；切换时记录为当时的 center）
    private var origin: SIMD2<Float> = .init(repeating: 0)
    /// 插值进度：0 = 已在 target，1 = 还在 origin
    private var t: Float = 0
    private let transitionDuration: Float = 1.6
    /// 距下次跳点的剩余秒数；到 0 时挑新 target
    private var switchInterval: Double = 180
    private var switchRemaining: Double = 0
    /// 冻结：电池模式 / 用户暂停时 = true
    private(set) var frozen = false
    private var initialized = false
    /// 跳点最小距离（避免重复同区域）
    private let minJumpFraction: Float = 0.18

    private static func centerBounds(mapSizePx: Float, viewW: Float, viewH: Float)
        -> (loX: Float, hiX: Float, loY: Float, hiY: Float) {
        let halfW = min(viewW / 2, mapSizePx / 2)
        let halfH = min(viewH / 2, mapSizePx / 2)
        var loX = halfW, hiX = mapSizePx - halfW
        var loY = halfH, hiY = mapSizePx - halfH
        if loX > hiX { loX = mapSizePx / 2; hiX = mapSizePx / 2 }
        if loY > hiY { loY = mapSizePx / 2; hiY = mapSizePx / 2 }
        return (loX, hiX, loY, hiY)
    }

    /// 配置（地图变化时调用）
    mutating func reset(mapSizePx: Float, viewW: Float, viewH: Float, switchInterval: Double) {
        self.switchInterval = max(20, switchInterval)
        let b = Self.centerBounds(mapSizePx: mapSizePx, viewW: viewW, viewH: viewH)
        center = SIMD2<Float>(mapSizePx / 2, mapSizePx / 2)
        target = center
        origin = center
        t = 0
        switchRemaining = self.switchInterval
        initialized = true
    }

    /// 立即跳到新点（用户点击"下一张地图"或刷新）
    mutating func jumpToRandomPoint(mapSizePx: Float, viewW: Float, viewH: Float) {
        origin = center
        pickTarget(mapSizePx: mapSizePx, viewW: viewW, viewH: viewH)
        t = 1
        switchRemaining = switchInterval
    }

    /// 相机是否处于停留状态（无平移插值进行中）—— 静止时可见图块集合固定，
    /// 渲染层可预构建整个动画循环的实例缓存。
    var isAtRest: Bool { t == 0 }

    /// 冻结 / 解冻（电池模式）
    mutating func setFrozen(_ f: Bool) { frozen = f }

    private mutating func pickTarget(mapSizePx: Float, viewW: Float, viewH: Float) {
        let b = Self.centerBounds(mapSizePx: mapSizePx, viewW: viewW, viewH: viewH)
        let minDist = min(viewW, viewH) * minJumpFraction
        for _ in 0..<8 {
            let cand = SIMD2<Float>(Float.random(in: b.loX...b.hiX),
                                     Float.random(in: b.loY...b.hiY))
            if simd_length(cand - center) >= minDist {
                target = cand
                t = 1
                return
            }
        }
        target = SIMD2<Float>(Float.random(in: b.loX...b.hiX),
                              Float.random(in: b.loY...b.hiY))
        t = 1
    }

    mutating func update(dt: Double, mapSizePx: Float, viewW: Float, viewH: Float) {
        if !initialized {
            reset(mapSizePx: mapSizePx, viewW: viewW, viewH: viewH, switchInterval: switchInterval)
        }
        if frozen {
            // 电池模式：停留当前位置，相机不更新（视口保持固定）
            return
        }
        // 推进插值
        if t > 0 {
            let step = Float(dt) / transitionDuration
            t = max(0, t - step)
            let s = 1 - t
            // ease-in-out (smoothstep)
            let e = s * s * (3 - 2 * s)
            center = simd_mix(origin, target, SIMD2<Float>(repeating: e))
            return // 过渡中不触发新跳点
        }
        switchRemaining -= dt
        if switchRemaining <= 0 {
            pickTarget(mapSizePx: mapSizePx, viewW: viewW, viewH: viewH)
            switchRemaining = switchInterval
        }
    }
}
