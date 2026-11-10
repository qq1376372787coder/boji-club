import SwiftUI

/// 动效规格（设计稿 §8）。
///
/// 七类动效各有编号 M1–M12，验收时按编号核对：
/// · 同一时刻最多两个动效在跑（原则 4）：主视觉漂浮 + 一个数据类动效，其余延后。
/// · `accessibilityReduceMotion` 或设置里的「减少动效」打开时，M1–M12 全部降级为
///   0.01 秒淡入，M2 / M3 / M8 / M11 / M12 停止循环。
enum BojiV2Motion {
    /// M1 主视觉浮入 1.4s cubic-bezier(.2,.8,.2,1)。
    static let heroEntranceDuration: Double = 1.4
    /// M2 主视觉漂浮 7s 循环。
    static let floatingDuration: Double = 7
    /// M2 漂浮幅度：y ±14pt、rotate ±0.6°。
    static let floatingTravel: CGFloat = 14
    static let floatingTilt: Double = 0.6
    /// M3 倾斜视差跟手幅度：x/y ±14pt、rotateY ±4°。
    static let parallaxTravel: CGFloat = 14
    static let parallaxTilt: Double = 4
    /// M4 玻璃卡弹出 0.9s cubic-bezier(.2,.9,.25,1)。
    static let sheetDuration: Double = 0.9
    /// M5 标题上浮 1.0s。
    static let titleDuration: Double = 1.0
    /// M6 数字滚动 1.3s ease-out。
    static let countDuration: Double = 1.3
    /// M7 环形描画 1.2s cubic-bezier(.2,.8,.2,1)。
    static let ringDuration: Double = 1.2
    /// M8 按钮流光 3.6s 循环，首次延迟 2.2s。
    static let sheenDuration: Double = 3.6
    static let sheenFirstDelay: Double = 2.2
    /// M9 列表错峰：delay 0.06 + 0.07·i。
    static let staggerBase: Double = 0.06
    static let staggerStep: Double = 0.07
    /// M10 庆祝彩带 26 片，下落 3–6s。
    static let confettiCount = 26
    /// M12 AI 球呼吸 3s。
    static let breathDuration: Double = 3

    static func timing(_ c0: Double, _ c1: Double, _ c2: Double, _ c3: Double, _ duration: Double) -> Animation {
        .timingCurve(c0, c1, c2, c3, duration: duration)
    }
    /// 设计稿里的「cubic-bezier(.2,.8,.2,1)」。
    static let entrance = timing(0.2, 0.8, 0.2, 1, heroEntranceDuration)
    /// 设计稿里的「cubic-bezier(.2,.9,.25,1)」。
    static let sheet = timing(0.2, 0.9, 0.25, 1, sheetDuration)
    /// 环形描画与入场共用同一条曲线。
    static let ring = timing(0.2, 0.8, 0.2, 1, ringDuration)
    /// 降级路径：全部动效退化为 0.01 秒淡入。
    static let degraded = Animation.easeOut(duration: 0.01)
}

// MARK: - M1 主视觉浮入

private struct BojiHeroEntranceModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(shown ? 1 : 0.92)
            .offset(y: shown ? 0 : 60)
            .blur(radius: shown ? 0 : 12)
            .opacity(shown ? 1 : 0)
            .onAppear {
                withAnimation(reduceMotion ? BojiV2Motion.degraded : BojiV2Motion.entrance) { shown = true }
            }
    }
}

// MARK: - M2 主视觉漂浮

private struct BojiFloatingModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let phase: Double
    @State private var risen = false

    func body(content: Content) -> some View {
        content
            .offset(y: risen ? -BojiV2Motion.floatingTravel : BojiV2Motion.floatingTravel)
            .rotationEffect(.degrees(risen ? BojiV2Motion.floatingTilt : -BojiV2Motion.floatingTilt))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: BojiV2Motion.floatingDuration)
                    .repeatForever(autoreverses: true)
                    .delay(phase)) {
                    risen = true
                }
            }
    }
}

// MARK: - M4 玻璃卡弹出 / M5 标题上浮

private struct BojiGlassSheetUpModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .offset(y: shown ? 0 : 110)
            .opacity(shown ? 1 : 0)
            .onAppear {
                withAnimation(reduceMotion ? BojiV2Motion.degraded : BojiV2Motion.sheet) { shown = true }
            }
    }
}

private struct BojiTitleFloatModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .offset(y: shown ? 0 : 16)
            .opacity(shown ? 1 : 0)
            .onAppear {
                withAnimation(reduceMotion ? BojiV2Motion.degraded : .easeOut(duration: BojiV2Motion.titleDuration)) { shown = true }
            }
    }
}

// MARK: - M9 列表错峰入场

private struct BojiStaggerModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let index: Int
    @State private var shown = false

    var body(content: Content) -> some View {
        content
            .offset(y: shown ? 0 : 16)
            .opacity(shown ? 1 : 0)
            .onAppear {
                let delay = BojiV2Motion.staggerBase + BojiV2Motion.staggerStep * Double(index)
                withAnimation((reduceMotion ? BojiV2Motion.degraded : .easeOut(duration: BojiV2Motion.titleDuration)).delay(delay)) {
                    shown = true
                }
            }
    }
}

// MARK: - M12 AI 球呼吸

private struct BojiBreathModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var inflated = false

    var body(content: Content) -> some View {
        content
            .scaleEffect(inflated ? 1.04 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: BojiV2Motion.breathDuration).repeatForever(autoreverses: true)) {
                    inflated = true
                }
            }
    }
}

extension View {
    /// M1 主视觉浮入：blur 12→0、y +60→0、scale .92→1。
    func bojiHeroEntrance() -> some View { modifier(BojiHeroEntranceModifier()) }
    /// M2 主视觉漂浮。`phase` 让多层素材错峰。
    func bojiFloating(phase: Double = 0) -> some View { modifier(BojiFloatingModifier(phase: phase)) }
    /// M4 玻璃卡弹出：y +110→0。
    func bojiGlassSheetUp() -> some View { modifier(BojiGlassSheetUpModifier()) }
    /// M5 标题上浮：y +16→0、opacity 0→1。
    func bojiTitleFloat() -> some View { modifier(BojiTitleFloatModifier()) }
    /// M9 列表错峰入场。第 i 行的延迟 = 0.06 + 0.07·i。
    func bojiStagger(index: Int) -> some View { modifier(BojiStaggerModifier(index: index)) }
    /// M12 AI 球呼吸：scale 1↔1.04。
    func bojiBreath() -> some View { modifier(BojiBreathModifier()) }
}

// MARK: - M6 数字滚动

/// M6 数字滚动：0 → 目标值 1.3s ease-out，等宽数字防跳动。
struct BojiCountUpText: View {
    let value: Double
    var formatter: (Double) -> String = { String(Int($0.rounded())) }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown: Double = 0

    var body: some View {
        Text(formatter(shown))
            .bojiNumeral(40)
            .contentTransition(.numericText())
            .onAppear {
                guard !reduceMotion else { shown = value; return }
                withAnimation(.easeOut(duration: BojiV2Motion.countDuration)) { shown = value }
            }
            .onChange(of: value) { _, next in
                guard !reduceMotion else { shown = next; return }
                withAnimation(.easeOut(duration: BojiV2Motion.countDuration)) { shown = next }
            }
    }
}

// MARK: - M7 环形描画

/// M7 环形描画：stroke-dashoffset 全长 → 余量 1.2s。
struct BojiProgressRing: View {
    /// 0…1。
    let progress: Double
    var lineWidth: CGFloat = 7
    var trackColor: Color = BojiV2.hairline
    var progressColor: Color = BojiV2.accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawn: Double = 0

    var body: some View {
        ZStack {
            Circle().stroke(trackColor, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, drawn)))
                .stroke(progressColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .onAppear {
            guard !reduceMotion else { drawn = progress; return }
            withAnimation(BojiV2Motion.ring) { drawn = progress }
        }
        .onChange(of: progress) { _, next in
            guard !reduceMotion else { drawn = next; return }
            withAnimation(BojiV2Motion.ring) { drawn = next }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - M8 按钮流光

private struct BojiSheenModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content.overlay { BojiSheenBand().allowsHitTesting(false) }
        }
    }
}

/// 40% 宽白色 45% 渐变带扫过按钮（M8）。带子被裁进按钮形状，不会溢出。
private struct BojiSheenBand: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var offset: CGFloat = -1.2

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            LinearGradient(colors: [.clear, .white.opacity(0.45), .clear],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: max(1, width * 0.4))
                .offset(x: offset * width * 1.4)
        }
        .clipShape(Capsule())
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: BojiV2Motion.sheenDuration)
                .repeatForever(autoreverses: false)
                .delay(BojiV2Motion.sheenFirstDelay)) {
                offset = 1.2
            }
        }
    }
}

extension View {
    /// M8 按钮流光。
    func bojiSheen() -> some View { modifier(BojiSheenModifier()) }
}
