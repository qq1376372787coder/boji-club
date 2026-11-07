import SwiftUI
import UIKit

// 全局设计 Token。页面禁止零散定义近似值；首轮参数来自 2026-10-16 实施任务书，
// 后续以原生截图校正时只改这里。

// MARK: - 颜色

enum BojiColor {
    /// 语义色随系统深浅外观动态解析；禁止在页面里再硬编码近似色。
    private static func adaptive(_ light: UIColor, _ dark: UIColor) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        })
    }
    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> UIColor {
        UIColor(red: r / 255, green: g / 255, blue: b / 255, alpha: 1)
    }

    static let pageBackground = adaptive(.white, rgb(14, 15, 18))
    static let cardSurface = adaptive(.white, rgb(26, 28, 32))
    /// 封面卡背景：浅色为纯黑封面，暗色页面本身近黑，改用略抬升的冷灰避免封面消失。
    static let coverSurface = adaptive(UIColor.black, rgb(30, 33, 38))
    static let inputSurface = adaptive(rgb(240, 240, 245), rgb(38, 40, 45))
    static let subtleSurface = adaptive(rgb(242, 243, 245), rgb(32, 34, 38))
    /// 品牌雾蓝 #E3E7F0：信息性表面（日历、周历、选中浅底）。暗色取冷调蓝灰。
    static let brandMist = adaptive(rgb(227, 231, 240), rgb(28, 36, 48))
    static let calendarSurface = brandMist
    /// 品牌可读前景：浅色 #414D63，暗色 #E3E7F0；品牌浅底使用 brandMist。
    static let mistAccent = adaptive(rgb(65, 77, 99), rgb(227, 231, 240))
    static let brandContent = adaptive(rgb(25, 26, 30), rgb(227, 231, 240))
    /// 雾霾蓝·浅底：信息表面 tint。
    static let mistSurface = adaptive(rgb(227, 231, 240), rgb(28, 36, 48))
    static let textPrimary = adaptive(rgb(25, 26, 30), rgb(245, 246, 248))
    static let textSecondary = adaptive(rgb(98, 100, 108), rgb(169, 173, 181))
    static let textTertiary = adaptive(rgb(118, 121, 130), rgb(133, 138, 147))
    static let divider = adaptive(UIColor.black.withAlphaComponent(0.08), UIColor.white.withAlphaComponent(0.12))
    static let outline = adaptive(UIColor.black.withAlphaComponent(0.10), UIColor.white.withAlphaComponent(0.16))
    static let coverSand = adaptive(rgb(201, 184, 164), rgb(107, 95, 82))
    static let timerAccent = adaptive(rgb(184, 122, 16), rgb(242, 184, 75))
    static let brandAccent = ClubBrand.accent
    static let accentBrand = ClubBrand.accent
    static let aiViolet = adaptive(rgb(138, 121, 200), rgb(185, 167, 240))
    static let aiGold = adaptive(rgb(222, 193, 138), rgb(232, 211, 166))
    static let brandGold = aiGold
    static let emeraldAccent = adaptive(rgb(16, 163, 108), rgb(52, 211, 153))
    static let macroProtein = adaptive(rgb(230, 92, 64), rgb(248, 113, 113))
    static let macroCarbs = adaptive(rgb(218, 146, 20), rgb(251, 191, 36))
    static let macroFat = adaptive(rgb(88, 114, 216), rgb(129, 140, 248))

    // 训练质量评价色：必须配文字，不单独表意。
    static let qualityGood = adaptive(rgb(198, 232, 206), rgb(45, 74, 52))
    static let qualityFair = adaptive(rgb(250, 232, 186), rgb(82, 66, 32))
    static let qualityPoor = adaptive(rgb(246, 206, 206), rgb(82, 45, 45))
}

// MARK: - 尺寸（全部 pt）

enum BojiSpace {
    static let pageInset: CGFloat = 18
    static let sectionSpacing: CGFloat = 18
    static let cardInset: CGFloat = 18
    static let workoutCardInset: CGFloat = 14
    static let tight: CGFloat = 6
    static let tightRow: CGFloat = 8
    static let general: CGFloat = 12
    static let showcase: CGFloat = 24
}

enum BojiRadius {
    /// v2 圆角阶梯补齐（与 BojiLayout.Radius 同值；旧调用点迁移后统一走这里）。
    static let badge: CGFloat = 6
    static let thumb: CGFloat = 10
    static let control: CGFloat = 12
    static let cardSmall: CGFloat = 20
    static let hero: CGFloat = 28
    static let pill: CGFloat = 999
    static let card: CGFloat = 24
    static let cover: CGFloat = 32
    static let image: CGFloat = 22
    /// 内嵌容器统一圆角：吞并此前散落的 12/14/15/18/20。
    static let inner: CGFloat = 16
    static let input = inner
    static let capsule: CGFloat = 999
}

enum BojiSize {
    static let primaryButtonHeight: CGFloat = 52
    static let imageButtonHeight: CGFloat = 54
    static let circleControlVisual: CGFloat = 42
    static let minimumTap: CGFloat = 44
    static let contentWidth: CGFloat = 680
}

// MARK: - 字体

/// 字号角色。默认值即 .large（标准）动态字号下的点数，经 @ScaledMetric 随动态字号缩放。
enum BojiFontRole {
    case pageTitle      // 30 / SemiBold
    case cardTitle      // 20 / SemiBold
    case exerciseName   // 18 / SemiBold
    case body           // 16 / Regular
    case secondary      // 14 / Regular
    case label          // 13 / Medium
    case bodyMetric     // 40 / SemiBold
    case timer          // 28 / SemiBold
    case setNumber      // 17 / Medium

    var size: CGFloat {
        switch self {
        case .pageTitle: 30
        case .cardTitle: 20
        case .exerciseName: 18
        case .body: 16
        case .secondary: 14
        case .label: 13
        case .bodyMetric: 40
        case .timer: 28
        case .setNumber: 17
        }
    }

    var weight: Font.Weight {
        switch self {
        case .pageTitle, .cardTitle, .exerciseName, .bodyMetric, .timer: .semibold
        case .label, .setNumber: .medium
        case .body, .secondary: .regular
        }
    }

    /// 计数与时间场景置真，重量、次数、日期等宽数字。
    var prefersMonospacedDigits: Bool {
        switch self {
        case .bodyMetric, .timer, .setNumber: true
        default: false
        }
    }

    var textStyle: Font.TextStyle {
        switch self {
        case .pageTitle, .bodyMetric: .largeTitle
        case .cardTitle: .title3
        case .exerciseName: .headline
        case .body, .setNumber: .body
        case .secondary: .subheadline
        case .label: .footnote
        case .timer: .title
        }
    }
}

private struct BojiFontModifier: ViewModifier {
    let role: BojiFontRole
    var monospacedDigits: Bool?
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1
    func body(content: Content) -> some View {
        let font = role == .bodyMetric
            ? Font.system(size: role.size * scale, weight: role.weight)
            : Font.system(role.textStyle, weight: role.weight)
        content.font((monospacedDigits ?? role.prefersMonospacedDigits) ? font.monospacedDigit() : font)
    }
}

extension View {
    func bojiFont(_ role: BojiFontRole, monospacedDigits: Bool? = nil) -> some View {
        modifier(BojiFontModifier(role: role, monospacedDigits: monospacedDigits))
    }
}

// MARK: - 三种可复用表面

/// Content surfaces remain opaque and readable beneath native floating controls.
struct BojiCardSurface: ViewModifier {
    var padding: CGFloat = BojiSpace.cardInset
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(BojiColor.cardSurface, in: RoundedRectangle(cornerRadius: BojiRadius.card, style: .continuous))
            // C3 修复：浅色下 pageBackground 与 cardSurface 同为 #FFFFFF，卡片必须带 0.5pt 边界，
            // 否则浅色模式卡片视觉消失（像素实测非白为 0）。深色下 outline 同步提亮。
            .overlay {
                RoundedRectangle(cornerRadius: BojiRadius.card, style: .continuous)
                    .stroke(BojiColor.outline, lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
    }
}

/// 浮起控件：近白底、0.5–1pt 细边缘、黑色 6% / 模糊 10 / y=3、顶部白色高光。
struct BojiRaisedSurface: ViewModifier {
    var cornerRadius: CGFloat = BojiRadius.input
    func body(content: Content) -> some View {
        content
            .background(
                LinearGradient(colors: [BojiColor.cardSurface, BojiColor.cardSurface.opacity(0.92)], startPoint: .top, endPoint: .bottom),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(BojiColor.outline, lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .top) {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(BojiColor.cardSurface.opacity(0.65))
                    .frame(height: 1)
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(0.06), radius: 10, x: 0, y: 3)
    }
}

/// 内嵌输入区：#F0F0F5 底色、14–16pt 圆角，靠底色表达内嵌，不加重模糊。
struct BojiInsetSurface: ViewModifier {
    var cornerRadius: CGFloat = BojiRadius.input
    var background: Color = BojiColor.inputSurface
    func body(content: Content) -> some View {
        content
            .background(background, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

extension View {
    func bojiCard(padding: CGFloat = BojiSpace.cardInset) -> some View {
        modifier(BojiCardSurface(padding: padding))
    }
    func bojiRaised(cornerRadius: CGFloat = BojiRadius.input) -> some View {
        modifier(BojiRaisedSurface(cornerRadius: cornerRadius))
    }
    func bojiInset(cornerRadius: CGFloat = BojiRadius.input, background: Color = BojiColor.inputSurface) -> some View {
        modifier(BojiInsetSurface(cornerRadius: cornerRadius, background: background))
    }
}

// MARK: - 按钮体系

enum BojiButtonKind {
    /// 主要提交：黑底白字胶囊（保存、采用计划、购买）。一个操作区域最多一个。
    case primary
    /// 展示卡主要按钮：白底黑字胶囊，最小 54pt（图片卡上的训练、饮食入口）。
    case displayPrimary
    /// 次按钮：浅底黑字，轻边缘。
    case secondary
    /// 危险操作：浅红底红字（确认框、菜单内用红字）。
    case destructive
}

/// Native content controls. Floating controls use clubNativeGlassButton instead.
struct BojiButtonStyle: PrimitiveButtonStyle {
    let kind: BojiButtonKind

    @ViewBuilder func makeBody(configuration: Configuration) -> some View {
        switch kind {
        case .primary:
            ClubActionButtonStyle(kind: .primary).makeBody(configuration: configuration)
        case .displayPrimary:
            Button(role: configuration.role, action: configuration.trigger) {
                configuration.label.frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .tint(BojiColor.cardSurface)
            .foregroundStyle(BojiColor.textPrimary)
        case .secondary:
            ClubActionButtonStyle(kind: .secondary).makeBody(configuration: configuration)
        case .destructive:
            ClubActionButtonStyle(kind: .destructive).makeBody(configuration: configuration)
        }
    }
}

/// Native compact content action. Keep a 44pt hit target without adding glass to every row.
struct BojiCircleButtonStyle: PrimitiveButtonStyle {
    var visualDiameter: CGFloat = BojiSize.circleControlVisual
    func makeBody(configuration: Configuration) -> some View {
        Button(role: configuration.role, action: configuration.trigger) {
            configuration.label
                .bojiType(.body)
                .frame(minWidth: BojiSize.minimumTap, minHeight: BojiSize.minimumTap)
                .contentShape(Circle())
        }
        .buttonStyle(.borderless)
        .buttonBorderShape(.circle)
        .tint(ClubBrand.accent)
    }
}

// MARK: - 动效

enum BojiMotion {
    static let pressDuration: Double = 0.15
    static let stateChange: Double = 0.20
    /// 卡片展开弹簧：response≈0.30、dampingFraction≈0.88。
    static func cardExpand(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : BojiMotion2.state
    }
    static func stateChangeAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: stateChange)
    }
    /// 交互式拖拽、手势跟随弹簧（图表游标、滑块）
    static func interactiveSpring(reduceMotion: Bool = false) -> Animation? {
        reduceMotion ? nil : .interactiveSpring(response: 0.28, dampingFraction: 0.86, blendDuration: 0.1)
    }
    /// 活泼反弹（数字跳动、点赞、完成勋章）
    static func bouncySpring(reduceMotion: Bool = false) -> Animation? {
        reduceMotion ? nil : BojiMotion2.transition
    }
    /// 平滑过渡弹簧（分段选择、卡片切换）
    static func smoothSpring(reduceMotion: Bool = false) -> Animation? {
        reduceMotion ? nil : BojiMotion2.transition
    }
}

// MARK: - 分级触感引擎 (L1~L4 物理触觉)

enum BojiHaptics {
    private static let softGen: UIImpactFeedbackGenerator = {
        let g = UIImpactFeedbackGenerator(style: .soft); g.prepare(); return g
    }()
    private static let lightGen: UIImpactFeedbackGenerator = {
        let g = UIImpactFeedbackGenerator(style: .light); g.prepare(); return g
    }()
    private static let mediumGen: UIImpactFeedbackGenerator = {
        let g = UIImpactFeedbackGenerator(style: .medium); g.prepare(); return g
    }()
    private static let rigidGen: UIImpactFeedbackGenerator = {
        let g = UIImpactFeedbackGenerator(style: .rigid); g.prepare(); return g
    }()
    private static let heavyGen: UIImpactFeedbackGenerator = {
        let g = UIImpactFeedbackGenerator(style: .heavy); g.prepare(); return g
    }()
    private static let selectionGen: UISelectionFeedbackGenerator = {
        let g = UISelectionFeedbackGenerator(); g.prepare(); return g
    }()
    private static let notificationGen: UINotificationFeedbackGenerator = {
        let g = UINotificationFeedbackGenerator(); g.prepare(); return g
    }()

    /// 两段式物理按键：第一段下压微阻尼 (Touch Down)
    static func pressDown() {
        softGen.impactOccurred(intensity: 0.38)
        softGen.prepare()
    }
    /// 两段式物理按键：第二段释放机械锁止 (Touch Up)
    static func pressRelease() {
        rigidGen.impactOccurred(intensity: 0.72)
        rigidGen.prepare()
    }
    /// L1: 零延迟微刻度 (Tick) - 步进器点按、胶囊滑动切换、日历切日期
    static func tick() {
        lightGen.impactOccurred(intensity: 0.62)
        lightGen.prepare()
    }
    /// L2: 机械双脉冲卡扣 (Latch) - 完成一组打勾、展开快调舱、开启计时器
    static func latch() {
        rigidGen.impactOccurred(intensity: 0.88)
        rigidGen.prepare()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.055) {
            softGen.impactOccurred(intensity: 0.45)
            softGen.prepare()
        }
    }
    /// L3: 渐强双脉冲跃迁 (HeavyDrop) - 动作全组完成、整堂训练保存、AI 分析完成
    static func heavyDrop() {
        mediumGen.impactOccurred(intensity: 0.68)
        mediumGen.prepare()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.075) {
            heavyGen.impactOccurred(intensity: 1.0)
            heavyGen.prepare()
        }
    }
    /// L4: 阶梯式庆典爆发 (Milestone) - 突破历史 PR、完成整场训练收官、徽章解锁
    static func milestone() {
        lightGen.impactOccurred(intensity: 0.55)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            mediumGen.impactOccurred(intensity: 0.80)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.13) {
            notificationGen.notificationOccurred(.success)
            notificationGen.prepare()
        }
    }

    // 常用别名映射
    static func selection() {
        selectionGen.selectionChanged()
        selectionGen.prepare()
    }
    static func light() { tick() }
    static func medium() { latch() }
    static func heavy() { heavyDrop() }
    static func success() { milestone() }
    static func warning() {
        notificationGen.notificationOccurred(.warning)
        notificationGen.prepare()
    }
    static func error() {
        notificationGen.notificationOccurred(.error)
        notificationGen.prepare()
    }
}

// MARK: - 流体弹簧物理规范

extension Animation {
    /// 微交互弹簧：按钮按下回弹、打勾框选中、卡片轻点反馈（转发 BojiMotion2.micro，160ms/0.78）
    static var bojiSnappy: Animation {
        BojiMotion2.micro
    }
    /// 标准弹簧动效规范
    static var bojiSpring: Animation {
        BojiMotion2.transition
    }
    /// 页面展开流体弹簧：动作卡片展开、日历周/月切换、Sheet 弹性吸附（转发 BojiMotion2.transition）
    static var bojiFluid: Animation {
        BojiMotion2.transition
    }
    /// 重物下坠阻尼：大重量确认、训练完成总结卡片掉落（转发 BojiMotion2.celebrate，发力感档）
    static var bojiHeavy: Animation {
        BojiMotion2.celebrate
    }
}

extension Optional where Wrapped == Animation {
    static var bojiSpring: Animation? {
        BojiMotion2.transition
    }
    static var bojiSnappy: Animation? {
        BojiMotion2.micro
    }
    static var bojiFluid: Animation? {
        BojiMotion2.transition
    }
}

// MARK: - 触感与微缩回弹按键样式

struct BojiPressableButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.96
    var haptic: () -> Void = { BojiHaptics.tick() }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? scale : 1.0)
            .animation(reduceMotion ? nil : .bojiSnappy, value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, isPressed in
                if isPressed { haptic() }
            }
    }
}

// MARK: - iOS 17/18 视觉空间深度与双层磨砂阴影

struct BojiDeepShadowModifier: ViewModifier {
    var cornerRadius: CGFloat = BojiRadius.card
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        content
            .background(BojiColor.cardSurface, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(BojiColor.outline, lineWidth: contrast == .increased ? 1 : 0.5)
                    .allowsHitTesting(false)
            }
    }
}

struct BojiSpecularBorderModifier: ViewModifier {
    var cornerRadius: CGFloat = BojiRadius.card
    func body(content: Content) -> some View {
        content.overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(
                    LinearGradient(
                        stops: [
                            .init(color: Color.white.opacity(0.16), location: 0),
                            .init(color: Color.white.opacity(0.03), location: 0.4),
                            .init(color: Color.black.opacity(0.12), location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.5
                )
                .allowsHitTesting(false)
        }
    }
}

extension View {
    func bojiElevated(cornerRadius: CGFloat = BojiRadius.card) -> some View {
        modifier(BojiDeepShadowModifier(cornerRadius: cornerRadius))
    }
    func bojiSpecularBorder(cornerRadius: CGFloat = BojiRadius.card) -> some View {
        modifier(BojiSpecularBorderModifier(cornerRadius: cornerRadius))
    }
}

// MARK: - 「One Boji」全应用统一页面顶栏、胶囊工具与状态横幅

struct BojiPageHeader<Trailing: View>: View {
    let eyebrow: String
    let title: String
    let subtitle: String?
    private let trailing: Trailing

    init(eyebrow: String, title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.eyebrow = eyebrow
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .top, spacing: BojiLayout.rowGap) {
            VStack(alignment: .leading, spacing: BojiLayout.tight) {
                // D3 修复：eyebrow 不再被 isStep 误判隐藏；拉丁文走 mono eyebrow，中文走 label + 雾蓝。
                if BojiScript.containsCJK(eyebrow) {
                    Text(eyebrow)
                        .bojiType(.label)
                        .foregroundStyle(BojiColor.brandAccent)
                } else {
                    Text(eyebrow)
                        .bojiType(.eyebrow)
                        .foregroundStyle(BojiColor.brandAccent)
                }
                Text(title)
                    .bojiFont(.pageTitle)
                    .foregroundStyle(BojiColor.textPrimary)
                    .lineLimit(2)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .bojiFont(.secondary)
                        .foregroundStyle(BojiColor.textSecondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        
    }
}

extension BojiPageHeader where Trailing == EmptyView {
    init(eyebrow: String, title: String, subtitle: String? = nil) {
        self.init(eyebrow: eyebrow, title: title, subtitle: subtitle) { EmptyView() }
    }
}

struct BojiToolbarCapsuleButton: View {
    var title: String? = nil
    let systemImage: String
    var badgeColor: Color? = nil
    let action: () -> Void

    var body: some View {
        Button {
            BojiHaptics.tick()
            action()
        } label: {
            HStack(spacing: BojiLayout.tight) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(BojiColor.textPrimary)
                    if let badgeColor {
                        Circle()
                            .fill(badgeColor)
                            .frame(width: 6, height: 6)
                            .offset(x: 4, y: -3)
                    }
                }
                if let title, !title.isEmpty {
                    Text(title)
                        .bojiType(.caption)
                        .foregroundStyle(BojiColor.textPrimary)
                }
            }
            .padding(.horizontal, title == nil ? 10 : 12)
            .padding(.vertical, BojiSpace.tight)
            .background(BojiColor.subtleSurface, in: Capsule())
            .overlay { Capsule().stroke(BojiColor.outline, lineWidth: 0.5) }
            .contentShape(Rectangle().inset(by: -9))
        }
        .buttonStyle(BojiPressableButtonStyle(scale: 0.95))
    }
}

struct BojiStatusBanner: View {
    let icon: String
    let title: String
    var detail: String? = nil
    var tint: Color = BojiColor.timerAccent
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .center, spacing: BojiLayout.inline) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .bojiType(.caption)
                    .foregroundStyle(BojiColor.textPrimary)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .bojiType(.caption)
                        .foregroundStyle(BojiColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 6)
            if let actionTitle, let action {
                Button {
                    BojiHaptics.tick()
                    action()
                } label: {
                    Text(actionTitle)
                        .bojiType(.caption)
                        .foregroundStyle(BojiColor.textPrimary)
                        .padding(.horizontal, BojiLayout.inline)
                        .padding(.vertical, BojiLayout.tight)
                        .background(BojiColor.inputSurface, in: Capsule())
                        .overlay { Capsule().stroke(BojiColor.outline, lineWidth: 0.5) }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, BojiSpace.workoutCardInset)
        .padding(.vertical, BojiLayout.inline)
        .background(BojiColor.cardSurface, in: RoundedRectangle(cornerRadius: BojiRadius.inner, style: .continuous))
        .padding(.horizontal, BojiSpace.pageInset)
        .padding(.vertical, BojiLayout.tight)
    }
}

struct BojiSectionHeader: View {
    let title: String
    var symbol: String? = nil
    var trailingText: String? = nil

    var body: some View {
        HStack(spacing: BojiLayout.tight) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(BojiColor.brandAccent)
            }
            Text(title)
                .bojiType(.caption)
                .foregroundStyle(BojiColor.textSecondary)
            Spacer()
            if let trailingText {
                Text(trailingText)
                    .bojiType(.caption)
                    .foregroundStyle(BojiColor.textTertiary)
            }
        }
        .padding(.horizontal, BojiLayout.tight)
    }
}

// MARK: - 液体蔓延完成打勾控件 (Liquid Checkbox)

struct LiquidCheckbox: View {
    let isCompleted: Bool
    var isLastSet: Bool = false
    let onToggle: () -> Void
    @State private var waveScale: CGFloat = 1.0
    @State private var rippleScale: CGFloat = 0.85
    @State private var rippleOpacity: Double = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            if !isCompleted {
                if isLastSet {
                    BojiHaptics.heavyDrop()
                } else {
                    BojiHaptics.latch()
                }
                if !reduceMotion {
                    waveScale = 0.82
                    rippleScale = 0.85
                    rippleOpacity = 0.65
                    withAnimation(.bojiSnappy) {
                        waveScale = 1.0
                    }
                    withAnimation(BojiMotion2.celebrate) {
                        rippleScale = 1.75
                        rippleOpacity = 0.0
                    }
                }
            } else {
                BojiHaptics.tick()
            }
            onToggle()
        } label: {
            ZStack {
                Circle()
                    .stroke(BojiColor.emeraldAccent, lineWidth: 2)
                    .frame(width: 28, height: 28)
                    .scaleEffect(rippleScale)
                    .opacity(rippleOpacity)

                Circle()
                    .stroke(isCompleted ? BojiColor.emeraldAccent : BojiColor.textTertiary.opacity(0.55), lineWidth: 2)
                    .frame(width: 28, height: 28)

                if isCompleted {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [BojiColor.emeraldAccent, BojiColor.emeraldAccent.opacity(0.82)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 28, height: 28)
                        .scaleEffect(waveScale)
                        .shadow(color: BojiColor.emeraldAccent.opacity(0.32), radius: 6, x: 0, y: 2)

                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.white)
                        .symbolEffect(.bounce.up.byLayer, value: isCompleted)
                }
            }
            .frame(width: BojiSize.minimumTap, height: BojiSize.minimumTap)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 组间休息流体光晕进度环 (Breathing Pulse Halo 2.0)

struct BreathingPulseHalo: View {
    let remaining: Int
    var total: Int = 60
    @State private var breath = false

    private var fraction: CGFloat {
        guard total > 0 else { return remaining > 0 ? 1 : 0 }
        return CGFloat(min(1, max(0, Double(remaining) / Double(total))))
    }
    private var isUrgent: Bool { remaining > 0 && remaining <= 3 }
    private var ringColor: Color { isUrgent ? Color.red : BojiColor.timerAccent }

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            ringColor.opacity(breath ? 0.30 : 0.08),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: 6,
                        endRadius: 28
                    )
                )
                .frame(width: 52, height: 52)
                .scaleEffect(breath ? 1.14 : 0.94)
                .animation(
                    isUrgent
                        ? BojiMotion2.celebrate.repeatForever(autoreverses: true)
                        : BojiMotion2.celebrate.repeatForever(autoreverses: true),
                    value: breath
                )

            Circle()
                .stroke(ringColor.opacity(0.18), lineWidth: 3.5)
                .frame(width: 36, height: 36)

            Circle()
                .trim(from: 0, to: fraction)
                .stroke(
                    ringColor,
                    style: StrokeStyle(lineWidth: 3.5, lineCap: .round)
                )
                .frame(width: 36, height: 36)
                .rotationEffect(.degrees(-90))
                .animation(BojiMotion2.progress, value: remaining)

            Image(systemName: isUrgent ? "flame.fill" : (remaining == 0 ? "checkmark" : "timer"))
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(ringColor)
                .symbolEffect(.bounce, value: isUrgent)
        }
        .frame(width: 40, height: 40)
        .onAppear { breath = true }
        .onChange(of: remaining) { _, sec in
            if sec > 0 && sec <= 3 {
                BojiHaptics.tick()
            } else if sec == 0 {
                BojiHaptics.heavyDrop()
            }
        }
    }
}

// MARK: - 单手盲操智能磁吸步进胶囊 (Smart Weight Stepper)

struct SmartWeightStepper: View {
    let currentWeight: Double
    let onAdjust: (Double) -> Void

    private let steps: [Double] = [-5, -2.5, 2.5, 5]

    var body: some View {
        HStack(spacing: BojiLayout.inline) {
            ForEach(steps, id: \.self) { step in
                Button {
                    BojiHaptics.tick()
                    onAdjust(step)
                } label: {
                    Text(step > 0 ? "+\(step.formatted())" : "\(step.formatted())")
                        .bojiType(.label)
                        .foregroundStyle(step > 0 ? BojiColor.textPrimary : BojiColor.textSecondary)
                        .padding(.horizontal, BojiLayout.rowGap)
                        .padding(.vertical, BojiLayout.inline)
                        .background(BojiColor.inputSurface, in: Capsule())
                        .overlay {
                            Capsule().stroke(BojiColor.outline, lineWidth: 0.5)
                        }
                        .contentShape(Rectangle().inset(by: -7))
                }
                .buttonStyle(BojiPressableButtonStyle(scale: 0.92))
            }
        }
    }
}

// MARK: - 原生流体翻牌计数器 (Rolling Numeric Counter 2.0)

struct RollingNumericCounter: View {
    let targetValue: Double
    var unit: String = ""
    var precision: Int = 0
    @State private var displayValue: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: BojiLayout.tight) {
            Text(displayValue.formatted(.number.precision(.fractionLength(precision))))
                .bojiFont(.bodyMetric, monospacedDigits: true)
                .foregroundStyle(BojiColor.textPrimary)
                .contentTransition(.numericText(value: displayValue))
            if !unit.isEmpty {
                Text(unit)
                    .bojiType(.secondary)
                    .foregroundStyle(BojiColor.textSecondary)
            }
        }
        .onAppear {
            if reduceMotion {
                displayValue = targetValue
            } else {
                withAnimation(BojiMotion2.counter) {
                    displayValue = targetValue
                }
            }
        }
        .onChange(of: targetValue) { _, newValue in
            if reduceMotion {
                displayValue = newValue
            } else {
                withAnimation(BojiMotion2.counter) {
                    displayValue = newValue
                }
            }
        }
    }
}

// MARK: - AI 照片激光流光扫描线 (Laser Scan Beam Animation)

struct LaserScanBeamOverlay: View {
    let isScanning: Bool
    @State private var scanOffset: CGFloat = -120

    var body: some View {
        GeometryReader { geo in
            if isScanning {
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.clear,
                                BojiColor.aiGold.opacity(0.6),
                                BojiColor.aiGold,
                                BojiColor.aiGold.opacity(0.6),
                                Color.clear
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(height: 6)
                    .shadow(color: BojiColor.aiGold.opacity(0.8), radius: 8, x: 0, y: 0)
                    .offset(y: scanOffset)
                    .onAppear {
                        scanOffset = -10
                        withAnimation(BojiMotion2.celebrate.repeatForever(autoreverses: true)) {
                            scanOffset = geo.size.height + 10
                        }
                    }
            }
        }
        .allowsHitTesting(false)
    }
}


// MARK: - 业务现场原位伴随洞察条 (In-Situ Contextual Insight Strip)

struct ClubContextualInsightStrip: View {
    let date: Date
    let kinds: [ClubInsightKind]
    @EnvironmentObject private var store: AppStore
    @State private var showCoach = false
    @State private var showShift = false
    @State private var dismissedEventID: String?
    @State private var showEvidence = false

    private var matchingEvent: ClubInsightEvent? {
        let todayMatches = ClubInsightLedger.current(in: store.state, date: date)
            .filter { kinds.contains($0.kind) && ClubInsightPriorityRules.isActionable($0) }
        if let first = todayMatches.first { return first }
        for offset in 1...3 {
            guard let prior = ClubDates.calendar.date(byAdding: .day, value: -offset, to: date) else { continue }
            let priorMatches = ClubInsightLedger.current(in: store.state, date: prior)
                .filter { kinds.contains($0.kind) && ClubInsightPriorityRules.isActionable($0) }
            if let first = priorMatches.first { return first }
        }
        return nil
    }

    var body: some View {
        if let event = matchingEvent, dismissedEventID != event.id {
            VStack(alignment: .leading, spacing: BojiLayout.inline) {
                HStack(alignment: .top, spacing: BojiLayout.inline) {
                    ZStack {
                        Circle()
                            .fill(event.kind.accentColor.opacity(0.15))
                            .frame(width: 30, height: 30)
                        Image(systemName: event.kind.symbol)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(event.kind.accentColor)
                    }

                    VStack(alignment: .leading, spacing: BojiLayout.tight) {
                        HStack(spacing: BojiLayout.tight) {
                            Text("Club AI · \(event.kind.label)")
                                .bojiType(.caption)
                                .foregroundStyle(event.kind.accentColor)
                            Spacer()
                            Button {
                                BojiHaptics.tick()
                                withAnimation(.bojiSnappy) { dismissedEventID = event.id }
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(BojiColor.textTertiary)
                                    .frame(width: 22, height: 22)
                                    .contentShape(Rectangle().inset(by: -11))
                            }
                            .buttonStyle(.plain)
                        }
                        Text(event.title)
                            .bojiType(.bodyStrong)
                            .foregroundStyle(BojiColor.textPrimary)
                        // P3 强调规范示范：下划线 = 可点击的次级文字（这里展开/收起证据行）。
                        Button {
                            BojiHaptics.tick()
                            withAnimation(BojiMotion2.state) { showEvidence.toggle() }
                        } label: {
                            Text(showEvidence ? "收起依据" : "为什么")
                                .bojiType(.label)
                                .modifier(BojiUnderline(color: BojiColor.textSecondary, isActive: true))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(.isLink)
                        Text(event.detail)
                            .bojiType(.caption)
                            .foregroundStyle(BojiColor.textSecondary)
                            .lineLimit(showEvidence ? nil : 2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack(spacing: BojiLayout.inline) {
                    if event.action?.type == "schedule_shift" {
                        Button {
                            BojiHaptics.latch()
                            showShift = true
                        } label: {
                            Label("一键预览顺延", systemImage: "calendar.badge.clock")
                                .bojiType(.caption)
                                .padding(.horizontal, BojiSpace.general)
                                .padding(.vertical, BojiSpace.tight)
                                .background(BojiColor.textPrimary, in: Capsule())
                                .foregroundStyle(BojiColor.pageBackground)
                        }
                        .buttonStyle(.plain)
                    }

                    Spacer()
                }
            }
            .padding(BojiSpace.workoutCardInset)
            .background(
                LinearGradient(
                    colors: [event.kind.accentColor.opacity(0.09), BojiColor.cardSurface],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: BojiRadius.inner, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: BojiRadius.inner, style: .continuous)
                    .stroke(event.kind.accentColor.opacity(0.32), lineWidth: 0.8)
            }
            .sheet(isPresented: $showShift) {
                NavigationStack {
                    ShiftScheduleView()
                        .toolbar { ToolbarItem(placement: .cancellationAction) { DismissButton() } }
                }
            }
        }
    }
}

// MARK: - 训练现场原位伴随气泡 (Workout In-situ Insight Cue)

struct WorkoutContextualInsightBar: View {
    let date: Date
    @EnvironmentObject private var store: AppStore

    var body: some View {
        let events = ClubInsightLedger.current(in: store.state, date: date)
            .filter { [ClubInsightKind.training, .workout].contains($0.kind) && ClubInsightPriorityRules.isActionable($0) }
        if let event = events.first {
            HStack(spacing: BojiLayout.inline) {
                Image(systemName: "sparkles")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(BojiColor.timerAccent)
                VStack(alignment: .leading, spacing: 0) {
                    Text(event.title)
                        .bojiType(.caption)
                        .foregroundStyle(BojiColor.textPrimary)
                        .lineLimit(1)
                    Text(event.detail)
                        .bojiType(.caption)
                        .foregroundStyle(BojiColor.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
            }
            .padding(BojiLayout.inline)
            .background(BojiColor.cardSurface, in: RoundedRectangle(cornerRadius: BojiRadius.inner, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: BojiRadius.inner, style: .continuous)
                    .stroke(BojiColor.outline, lineWidth: 0.5)
            }
        }
    }
}
