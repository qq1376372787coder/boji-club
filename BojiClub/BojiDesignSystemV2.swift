import SwiftUI
import UIKit

/// 界面视觉设计稿 v2「原生感 · 玻璃与立体」的 Token 层。
///
/// 设计稿 §2 色彩 / §3 字体 / §4 间距与形状 / §5 材质与玻璃的唯一取值来源。
/// 页面禁止再写近似值：需要新值先回到这里加 token。
///
/// 与旧版 `BojiColor` / `BojiRadius` / `BojiMotion` 并存而不是替换它们：
/// 新旧两套外壳在 AI 收拢与界面改造期间共存，老调用面不受影响。
enum BojiV2 {

    // MARK: - 色彩（§2）

    /// 主强调色 #2E6BF6。全 App 唯一品牌色：按钮、环形进度、当前 Tab、链接、tint。
    static let accent = Color(red: 0.18, green: 0.42, blue: 0.965)
    /// accent 填充底 rgba(46,107,246,0.12)：chip / 标签底，如「今天」。
    static let accentFill = Color(red: 0.18, green: 0.42, blue: 0.965).opacity(0.12)
    /// 主文字 #1d1d1f，对页面底色 15.7:1。深色 #f5f5f7（§2.2）。
    static let textPrimary = adaptive(light: Color(red: 0.114, green: 0.114, blue: 0.122),
                                     dark: Color(red: 0.961, green: 0.961, blue: 0.968))
    /// 次文字 #6E6E73，全部正文级副文案，4.7:1（过 WCAG AA）。深色 #98989f。
    static let textSecondary = adaptive(light: Color(red: 0.431, green: 0.431, blue: 0.451),
                                       dark: Color(red: 0.596, green: 0.596, blue: 0.624))
    /// 弱化图标与装饰线 rgba(0,0,0,0.07)；深色 rgba(255,255,255,0.10)。
    static let hairline = adaptive(light: Color.black.opacity(0.07), dark: Color.white.opacity(0.10))
    /// 页面底色 #F5F5F7。整页只有这一层背景，不允许灰底 + 不透明白卡。深色 #000（§2.2）。
    static let background = adaptive(light: Color(red: 0.961, green: 0.961, blue: 0.968), dark: .black)

    /// 语义色（§2.3）。只用于状态反馈，不进 chrome。
    static let success = Color(red: 0.188, green: 0.820, blue: 0.345)
    static let warning = Color(red: 1.0, green: 0.624, blue: 0.039)
    static let danger = Color(red: 1.0, green: 0.216, blue: 0.373)
    static let badgeGold = Color(red: 1.0, green: 0.839, blue: 0.039)

    /// 深色模式是同一套值换表（§2.2）。MVP 先做浅色，这里预留同一张表。
    static func adaptive(light: Color, dark: Color) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
    }

    // MARK: - 材质与玻璃（§5）

    /// 玻璃填充：浅色 rgba(255,255,255,0.62) 叠加在系统材质之上；深色 rgba(255,255,255,0.08)（§2.2）。
    static let glassFill = adaptive(light: Color.white.opacity(0.62), dark: Color.white.opacity(0.08))
    /// 玻璃描边：浅色 rgba(255,255,255,0.95)；深色 rgba(255,255,255,0.18)。
    static let glassStroke = adaptive(light: Color.white.opacity(0.95), dark: Color.white.opacity(0.18))
    /// 唯一一档阴影：卡片 0 4–6pt 20–40pt rgba(0,0,0,0.05–0.06)。其余一律不加。深色加深到 40%。
    static let cardShadow = adaptive(light: Color.black.opacity(0.06), dark: Color.black.opacity(0.40))
    /// 主按钮专用投影 0 8pt 24pt rgba(46,107,246,0.35)。
    static let accentShadow = Color(red: 0.18, green: 0.42, blue: 0.965).opacity(0.35)

    // MARK: - 间距与形状（§4）

    /// 页面左右安全边：标题 24pt。
    static let titleInset: CGFloat = 24
    /// 卡片列表 16pt；底部玻璃大卡 10pt。
    static let cardInset: CGFloat = 16
    static let dockInset: CGFloat = 10
    /// 玻璃卡内边距 20–22pt。
    static let glassPadding: CGFloat = 21
    /// 列表行内边距 15–18pt，行间距 10pt。
    static let rowPadding: CGFloat = 16
    static let rowSpacing: CGFloat = 10
    /// 标题区 110pt 起。
    static let headerHeight: CGFloat = 110

    // MARK: - 字体（§3）

    // 全部走 Font.TextStyle，随 Dynamic Type 缩放（§11）。尺寸逐字对齐 §3 字阶；
    // title 是唯一近似项：系统没有 30pt 的 text style，取最近的 .title（28pt），
    // 换来的是可随无障碍字号缩放 —— 固定磅值会被无障碍审计判为「无法改变字号」。
    /// Display 34pt Semibold：页面大标题。
    static let display = Font.system(.largeTitle, design: .default, weight: .semibold)
    /// Title 28pt Semibold：首页 / 庆祝主标题（§3 写 30，系统 text style 无 30pt）。
    static let title = Font.system(.title, design: .default, weight: .semibold)
    /// Score 56pt Semibold：大数字。没有对应的 text style，保持固定磅值，
    /// 调用点按 §11 用 .scaledToFit() 收敛，避免截断数字。
    static let score = Font.system(size: 56, weight: .semibold)
    static let scoreCompact = Font.system(size: 40, weight: .semibold)
    /// Body-em 17pt Semibold：卡内主文案、按钮文字。
    static let bodyEm = Font.system(.headline, design: .default, weight: .semibold)
    static let body = Font.system(.subheadline, design: .default)
    /// Caption 13pt：单位、时间、副标签。
    static let caption = Font.system(.footnote, design: .default)
    /// Micro 11–12pt：Tab 标签、宏量营养标签。
    static let micro = Font.system(.caption2, design: .default)
    static let microEm = Font.system(.caption, design: .default, weight: .medium)

    /// 数字一律等宽（§3），并随 Dynamic Type 缩放。用于所有会跳变的数值，避免数字滚动时抖动。
    static func numeral(_ style: Font.TextStyle, weight: Font.Weight = .semibold) -> Font {
        .system(style, design: .rounded, weight: weight).monospacedDigit()
    }
}

/// 数字等宽且随 Dynamic Type 缩放（§11：可缩到 85%，不允许截断数字）。
extension View {
    func bojiNumeral(_ style: Font.TextStyle, weight: Font.Weight = .semibold) -> some View {
        self.font(.system(style, design: .rounded, weight: weight).monospacedDigit())
            .minimumScaleFactor(0.85)
            .lineLimit(1)
    }
}

/// 统一的玻璃层：系统材质 + 白 62% + 1pt 白色描边 + 顶部内侧高光 + 唯一一档阴影。
///
/// 设计稿 §5 的「所有容器都是同一块玻璃」：内容卡、底部大卡、列表行都走这里，
/// 不允许用普通圆角视图冒充。
struct BojiGlassModifier: ViewModifier {
    let radius: CGFloat
    var elevated: Bool = true
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if reduceTransparency || contrast == .increased {
            // 降低透明度 / 高对比度：退回实心表面，保证文字对比度。
            content
                .background(BojiV2.background, in: shape)
                .overlay { shape.stroke(BojiV2.hairline, lineWidth: 1).allowsHitTesting(false) }
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .background(BojiV2.glassFill, in: shape)
                .overlay { shape.stroke(BojiV2.glassStroke, lineWidth: 1).allowsHitTesting(false) }
                .overlay {
                    // 内侧顶边 1px 高光：白色自上而下渐隐。
                    shape.strokeBorder(
                        LinearGradient(colors: [Color.white.opacity(0.95), Color.white.opacity(0.18)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 1
                    ).allowsHitTesting(false)
                }
                .shadow(color: elevated ? BojiV2.cardShadow : .clear, radius: 26, x: 0, y: 5)
        }
    }
}

extension View {
    /// 玻璃卡。`radius` 默认内容卡 22pt；底部大卡传 40pt。
    func bojiGlass(radius: CGFloat = BojiV2.glassCardRadius, elevated: Bool = true) -> some View {
        modifier(BojiGlassModifier(radius: radius, elevated: elevated))
    }
}

extension BojiV2 {
    /// 内容卡圆角 22pt（§4：内容卡 22–32）。
    static let glassCardRadius: CGFloat = 22
    /// 底部大卡圆角 40pt。
    static let glassDockRadius: CGFloat = 40
    /// 按钮 28pt（高度 56 的一半，胶囊）。
    static let buttonRadius: CGFloat = 28
    /// chip 19pt。
    static let chipRadius: CGFloat = 19
}
