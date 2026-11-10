import SwiftUI
import CoreMotion

// MARK: - 分层主视觉（Hero Layers）
//
// 不用「一张合成图 + 整体漂浮」，而是 N 个透明 PNG，每层独立动画参数。
// 这样才有纵深（视差）、才有生命感。单张 PNG 物理上做不到视差。
//
// 设计稿 §6：每屏 0–1 个漂浮 3D 素材图；§8 M1 浮入 / M2 漂浮 / M3 倾斜视差。
// M3 的幅度是 ±14pt、rotateY ±4°，由 CoreMotion 的 gravity 提供。

/// 一层漂浮物的描述
struct HeroLayer: Identifiable {
    let id: String
    let image: String          // Asset Catalog 里的图片名
    /// 归一化位置（0...1，相对 hero 区域）
    let x: CGFloat
    let y: CGFloat
    /// 相对宽度（相对 hero 区域宽度）
    let width: CGFloat
    /// 景深：0 = 最远，1 = 最近。决定视差位移量和缩放。
    let depth: CGFloat
    /// 漂浮幅度（pt）与周期（秒）。不同层用不同周期 → 整体不同步。
    let amplitude: CGFloat
    let period: Double
    /// 自转幅度（度）
    let rotation: CGFloat
    /// 基础旋转角
    let baseRotation: Double
}

/// 动效引擎：把「时间 + 设备倾斜」换算成每层的变换
struct HeroMotionEngine {
    /// 设备倾斜（来自 CoreMotion），范围约 -1...1
    var tiltX: CGFloat = 0
    var tiltY: CGFloat = 0
    /// 全局时间（秒）
    var time: Double = 0
    /// 视差总幅度（pt）—— 设计稿 M3 规定 ±14pt
    var parallaxAmount: CGFloat = 14

    func transform(for layer: HeroLayer) -> LayerTransform {
        let phase = Double(abs(layer.id.hashValue) % 7) * 0.9
        let angle = (time / layer.period) * 2 * .pi + phase

        let floatY = layer.amplitude * CGFloat(sin(angle))
        let floatR = layer.rotation * CGFloat(sin(angle * 0.83))

        // 视差：前景跟着倾斜多走，背景反着走 → 产生纵深
        let parallaxX = tiltX * parallaxAmount * (layer.depth - 0.5) * 2
        let parallaxY = tiltY * parallaxAmount * (layer.depth - 0.5) * 2

        return LayerTransform(
            offsetX: parallaxX,
            offsetY: floatY + parallaxY,
            rotation: layer.baseRotation + Double(floatR),
            scale: 1.0 + layer.depth * 0.06
        )
    }
}

struct LayerTransform {
    var offsetX: CGFloat = 0
    var offsetY: CGFloat = 0
    var rotation: Double = 0
    var scale: CGFloat = 1
}

// MARK: - 主视图

struct HeroLayersView: View {
    let layers: [HeroLayer]
    var size: CGSize = CGSize(width: 340, height: 300)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var motionManager = HeroMotionManager()

    var body: some View {
        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let engine = motionManager.current

            ZStack {
                ForEach(layers) { layer in
                    let transform = resolvedTransform(for: layer, at: time, engine: engine)
                    Image(layer.image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: size.width * layer.width)
                        .rotationEffect(.degrees(transform.rotation))
                        .scaleEffect(transform.scale)
                        .offset(x: transform.offsetX, y: transform.offsetY)
                        .position(
                            x: size.width * layer.x,
                            y: size.height * layer.y
                        )
                        .accessibilityHidden(true)   // 装饰性元素，对 VoiceOver 隐藏
                }
            }
            .frame(width: size.width, height: size.height)
            .onAppear { motionManager.start() }
            .onDisappear { motionManager.stop() }
        }
    }

    private func resolvedTransform(for layer: HeroLayer, at time: Double, engine: HeroMotionEngine) -> LayerTransform {
        // 减少动效：全部降级为静止（设计稿 §8 末段：M2/M3 停止循环）
        if reduceMotion {
            return LayerTransform(
                offsetX: 0, offsetY: 0,
                rotation: layer.baseRotation,
                scale: 1
            )
        }
        var live = engine
        live.time = time
        return live.transform(for: layer)
    }
}

// MARK: - CoreMotion 倾斜输入（设计稿 M3）

/// CoreMotion 的回调线程与渲染线程不同，这里用锁保护状态，不引入 actor 隔离
/// （`@MainActor` 类放进 `@StateObject` 的属性初始化器在严格并发检查下会报警告）。
final class HeroMotionManager: ObservableObject {
    private let manager = CMMotionManager()
    private let lock = NSLock()
    private var engine = HeroMotionEngine()
    private var queue: OperationQueue = {
        let q = OperationQueue()
        q.qualityOfService = .userInteractive
        q.maxConcurrentOperationCount = 1
        return q
    }()

    /// 当前倾斜量；由 CoreMotion 回调写入，由渲染线程读取。
    var current: HeroMotionEngine {
        lock.lock()
        defer { lock.unlock() }
        return engine
    }

    func start() {
        guard manager.isDeviceMotionAvailable else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 60.0
        manager.startDeviceMotionUpdates(to: queue) { [weak self] motion, _ in
            guard let m = motion else { return }
            // gravity 已在设备坐标系里做了重力补偿，直接用 x/y 作为倾斜量
            let x = CGFloat(max(-1, min(1, m.gravity.x)))
            let y = CGFloat(max(-1, min(1, m.gravity.y)))
            self?.apply(tiltX: x, tiltY: y)
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
    }

    private func apply(tiltX: CGFloat, tiltY: CGFloat) {
        lock.lock()
        defer { lock.unlock() }
        engine.tiltX = tiltX
        engine.tiltY = tiltY
    }
}

// MARK: - 素材配置

extension HeroLayer {
    /// 首页主视觉：6 个漂浮物，各层独立的周期与景深。
    /// 素材是 Apple clay/glass 风格的透明 PNG（Asset Catalog 里的 boji-hero-*）。
    static let home: [HeroLayer] = [
        HeroLayer(id: "band",       image: "boji-hero-band",
                  x: 0.50, y: 0.14, width: 0.52, depth: 0.10,
                  amplitude: 9,  period: 8.2, rotation: 1.1, baseRotation: -12),
        HeroLayer(id: "shaker",     image: "boji-hero-shaker",
                  x: 0.31, y: 0.28, width: 0.46, depth: 0.30,
                  amplitude: 12, period: 6.8, rotation: 0.8, baseRotation: 6),
        HeroLayer(id: "kettlebell", image: "boji-hero-kettlebell",
                  x: 0.70, y: 0.32, width: 0.40, depth: 0.26,
                  amplitude: 10, period: 7.6, rotation: 1.4, baseRotation: 8),
        HeroLayer(id: "bottle",     image: "boji-hero-bottle",
                  x: 0.64, y: 0.50, width: 0.44, depth: 0.48,
                  amplitude: 13, period: 6.1, rotation: 0.7, baseRotation: 10),
        HeroLayer(id: "dumbbell",   image: "boji-hero-dumbbell",
                  x: 0.42, y: 0.63, width: 0.60, depth: 0.72,
                  amplitude: 15, period: 5.6, rotation: 0.9, baseRotation: -14),
        HeroLayer(id: "apple",      image: "boji-hero-apple",
                  x: 0.72, y: 0.77, width: 0.34, depth: 0.86,
                  amplitude: 17, period: 5.2, rotation: 1.6, baseRotation: 4),
    ]
}
