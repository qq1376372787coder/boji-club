//
//  BojiDesignSystemV2.swift
//  BojiClub
//
//  薄肌俱乐部 · 设计系统 v2（2026-11-07）
//
//  定位：替换 / 收敛当前并存的四套设计入口
//    - DesignTokens.swift（BojiColor / BojiSpace / BojiRadius / BojiSize / BojiFontRole）
//    - Design.swift（ClubUI / ClubBrand / ClubMotion / Metric）
//    - FlowDesign.swift（FlowPalette / FlowHeading / FlowSurface）
//    - JourneyComponents.swift（ClubActionButtonStyle）
//
//  迁移方式：把本文件加入 target，页面只允许使用。
//    BojiType.*     文字（唯一入口）
//    BojiLayout.*   间距 / 圆角 / 控件尺寸（唯一入口）
//    BojiEmphasis   粗体 / 下划线 / 斜体 / 小型大写（唯一入口）
//    BojiMotion2    动效分层（唯一入口，旧 BojiMotion / ClubMotion 转 deprecated）
//    BojiFeedback   事件 → 触感映射（唯一入口）
//  旧的 BojiFontRole / ClubUI / FlowPalette / ClubMotion 全部标 @available(*, deprecated)。
//
//  设计依据：
//    - iOS HIG 的语义字号与 44pt 最小点击区
//    - 参考截图：Apple Music 专辑页（编辑式层级 / 列表行 / 可点击文字的下划线）
//      与健身 App（指标卡大数字 + 小单位 / 时间轴 / 组行栅格 / 空态 "--"）
//    - 中文排版：PingFang SC 只有 Regular / Medium / Semibold，禁用合成粗体与合成斜体
//

import SwiftUI
import UIKit

// MARK: - 0. 基础：中文安全字重

extension Font.Weight {
    /// 中文安全粗体。PingFang SC 无 Bold 字重，.bold 会被系统合成（笔画变粗且糊），
    /// 因此中文语境最高使用 .semibold；仅在拉丁文/数字上允许 .bold。
    static let bojiCJKStrong: Font.Weight = .semibold
}

/// 判断字符串是否需要按 CJK 规则降级字重 / 禁用斜体。
enum BojiScript {
    static func containsCJK(_ s: String) -> Bool {
        s.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value)      // CJK 统一表意
            || (0x3400...0x4DBF).contains(scalar.value)   // 扩展 A
            || (0x3000...0x303F).contains(scalar.value)   // CJK 标点
            || (0xFF00...0xFFEF).contains(scalar.value)   // 全角
        }
    }
}

// MARK: - 1. 文字：BojiType（唯一入口）

/// 11 级语义字阶。任何页面不得再出现 `.font(.system(size: N))`。
///
///  role         size  weight     line   extra   tracking  design      用途
///  ────────────────────────────────────────────────────────────────────────────────
///  hero          44   bold*      48     0      -1.2     default     训练中计时、单一体重数字
///  display       34   semibold   40     0      -0.8     default     首屏判断句、指标主角
///  title         28   semibold   34     0      -0.5     default     页面标题（One Boji Header）
///  section       20   semibold   26     0      -0.2     default     卡片标题 / 分组标题
///  body          16   regular    24     2       0       default     正文、列表主文本
///  bodyStrong    16   semibold   24     2       0       default     正文内强调
///  secondary     14   regular    20     1       0       default     副标题、说明、元信息
///  label         13   medium     18     0       0.1     default     指标名、控件标签、小节标签
///  caption       11   medium     16     0       0.3     default     徽章、时间戳、脚注
///  eyebrow       11   bold       14     0       1.8     monospaced  英文小标（UPPERCASE）
///  data          17   medium     22     0       0       default     表格 / 组行数值（自动等宽数字）
///
///  * hero 的 bold 仅用于数字，中文永远不会走到 hero（见 `.bojiType` 内的 CJK 降级）。
enum BojiTypeRole: String, CaseIterable {
    case hero, display, title, section, body, bodyStrong, secondary, label, caption, eyebrow, data
    /// T4 正文/说明单行 15pt（规格表 5 档之一；T1 88 在 BojiEditorialNumber，T2=.title 28，T3=.data 17，T5=.caption 11）。
    case body15

    var size: CGFloat {
        switch self {
        case .hero: 44
        case .display: 34
        case .title: 28
        case .section: 20
        case .body, .bodyStrong: 16
        case .secondary: 14
        case .label: 13
        case .caption, .eyebrow: 11
        case .data: 17
        case .body15: 15
        }
    }

    /// 目标行高（pt）。SwiftUI 里换算成 lineSpacing = 目标行高 - 系统行高。
    var lineHeight: CGFloat {
        switch self {
        case .hero: 48
        case .display: 40
        case .title: 34
        case .section: 26
        case .body, .bodyStrong: 24
        case .secondary: 20
        case .label: 18
        case .caption: 16
        case .eyebrow: 14
        case .data: 22
        case .body15: 22
        }
    }

    var weight: Font.Weight {
        switch self {
        case .hero: .bold
        case .display, .title, .section, .bodyStrong: .semibold
        case .body, .secondary, .body15: .regular
        case .label, .caption, .data: .medium
        case .eyebrow: .bold
        }
    }

    var tracking: CGFloat {
        switch self {
        case .hero: -1.2
        case .display: -0.8
        case .title: -0.5
        case .section: -0.2
        case .body, .bodyStrong, .secondary, .body15: 0
        case .label: 0.1
        case .caption: 0.3
        case .eyebrow: 1.8
        case .data: 0
        }
    }

    /// Dynamic Type 的缩放基准。
    var textStyle: Font.TextStyle {
        switch self {
        case .hero, .display: .largeTitle
        case .title: .title
        case .section: .title3
        case .body, .bodyStrong, .data, .body15: .body
        case .secondary: .subheadline
        case .label: .footnote
        case .caption, .eyebrow: .caption2
        }
    }

    /// 数字是否默认走等宽（避免计数跳动）。
    var defaultMonospacedDigits: Bool {
        switch self {
        case .hero, .display, .data, .label: true
        default: false
        }
    }

    /// 是否允许按 CJK 规则把 bold 降为 semibold（hero 的数字不受影响，滚动数字时另说）。
    var demotesBoldForCJK: Bool { self == .hero || self == .eyebrow }

    /// 字阶允许的最小/最大 Dynamic Type 缩放，防止 AX5 下版式崩坏。
    var dynamicTypeRange: ClosedRange<DynamicTypeSize> {
        switch self {
        case .hero, .display: .xSmall...(.accessibility3)
        case .title: .xSmall...(.accessibility2)
        default: .xSmall...(.accessibility5)
        }
    }
}

// MARK: - 巨号排印数字（2+3 规格表 §0.2：.display 88 / .editorial 76 / .hero 52）
// 88pt/76pt 只在状态卡、进度大数字、记录当前值三处使用，封闭在此组件内，不改全局 BojiTypeRole
// （既有 .display 34pt 档位全库使用中，直接改值会波及所有页面版式）。

struct BojiEditorialNumber: View {
    /// 数字本身（如 "88"、"3/12"、"76.5"）。
    let value: String
    /// 数字下方的细字标签（如 "今天的身体状态"、"组进度"）。
    var label: String? = nil
    /// 档位：88pt 状态/进度巨号，76pt 记录当前值。
    var scale: EditorialScale = .display
    /// 数字颜色；默认主文字色。
    var tint: Color = BojiColor.textPrimary
    /// Dynamic Type 基准：88pt 档跟随 largeTitle 缩放，其余档位按此比例换算。
    @ScaledMetric(relativeTo: .largeTitle) private var displayUnit: CGFloat = 88
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// M8 数字叙事：整数位进场从 0 滚到终值（0.35s），减动效直落终值。
    @State private var shownValue: String?

    enum EditorialScale {
        /// 88pt / 800 / -3pt —— 状态数字、进度大数字。
        case display
        /// 76pt / 800 / -3.5pt —— 记录页当前值。
        case editorial
        /// 52pt —— 视频上的 Hero 数字。
        case hero

        var size: CGFloat {
            switch self {
            case .display: 88
            case .editorial: 76
            case .hero: 52
            }
        }
        var tracking: CGFloat {
            switch self {
            case .display: -3
            case .editorial: -3.5
            case .hero: -2
            }
        }
    }

    private var effectiveSize: CGFloat {
        let scaled = displayUnit * (scale.size / 88)
        return typeSize > .accessibility3 ? scaled * 0.75 : scaled
    }

    /// 只有纯整数才做 0→终值滚动（"3/12"、"76.5" 这类不滚，避免读出怪值）。
    private var rollsFromZero: Bool { Int(value) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(shownValue ?? (rollsFromZero ? "0" : value))
                .font(.system(size: effectiveSize, weight: .heavy, design: .default))
                .monospacedDigit()
                .kerning(scale.tracking * (effectiveSize / scale.size))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .contentTransition(.numericText())
                .onAppear {
                    shownValue = reduceMotion ? value : (rollsFromZero ? "0" : value)
                    if !reduceMotion && rollsFromZero {
                        withAnimation(.snappy(duration: 0.35)) { shownValue = value }
                    }
                }
                .onChange(of: value) { _, next in
                    if reduceMotion { shownValue = next }
                    else { withAnimation(.snappy(duration: 0.35)) { shownValue = next } }
                }
            if let label, !label.isEmpty {
                Rectangle()
                    .fill(BojiColor.divider)
                    .frame(width: 44, height: 1)
                Text(label)
                    .bojiType(.label)
                    .foregroundStyle(BojiColor.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 唯一指标组件 MetricValue（全局组件规格体系 §2.6：跨页同名指标只许走这里）
//
// 数字 T2 28 / semibold / 等宽 / 字距 -1；单位与标签 T5 11；发丝线 0.5pt。
// 空值（nil 或空串）整块不渲染——「0」「—」「未记录」不再上屏。
// 页面层禁止再用 .bojiType(.body) 之类自拼指标数字（跨页字号散掉的根因）。

struct MetricValue: View {
    /// 数值文本；nil 或空串时整块不渲染。
    let value: String?
    var unit: String? = nil
    let label: String
    var tint: Color = BojiColor.textPrimary

    var body: some View {
        if let value, !value.isEmpty {
            VStack(alignment: .leading, spacing: BojiLayout.tight) {
                Text(label)
                    .bojiType(.caption)
                    .foregroundStyle(BojiColor.textTertiary)
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(value)
                        .bojiType(.title, monospacedDigits: true)
                        .fontWeight(.semibold)
                        .kerning(-1)
                        .foregroundStyle(tint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    if let unit, !unit.isEmpty {
                        Text(unit)
                            .bojiType(.caption)
                            .foregroundStyle(BojiColor.textTertiary)
                    }
                }
                .padding(.top, BojiLayout.tight)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(label) \(value) \(unit ?? "")")
        }
    }

    /// 供分组容器判空：空值不进组，避免留白格。
    var hasValue: Bool { !(value ?? "").isEmpty }
}

/// 横排一组指标（§2.6 横排式）：外层上下各一条发丝线，块间一条竖发丝线——不叠双线。
struct MetricRowGroup: View {
    let metrics: [MetricValue]
    var body: some View {
        let shown = metrics.filter(\.hasValue)
        if !shown.isEmpty {
            HStack(spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.offset) { index, metric in
                    metric
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 13)
                        .padding(.leading, index == 0 ? 0 : 14)
                        .overlay(alignment: .leading) {
                            if index > 0 {
                                Rectangle().fill(BojiColor.divider).frame(width: BojiLayout.hairline)
                            }
                        }
                }
            }
            .overlay(alignment: .top) { Rectangle().fill(BojiColor.divider).frame(height: BojiLayout.hairline) }
            .overlay(alignment: .bottom) { Rectangle().fill(BojiColor.divider).frame(height: BojiLayout.hairline) }
            .accessibilityElement(children: .contain)
        }
    }
}

extension View {
    /// 单列指标行（§2.6 单列式）：本块下一条发丝线；整列顶部再补一条 `.metricColumnTopRule()`。
    func metricColumnItem() -> some View {
        padding(.vertical, 13)
            .overlay(alignment: .bottom) { Rectangle().fill(BojiColor.divider).frame(height: BojiLayout.hairline) }
    }

    /// 单列指标整列顶部发丝线。
    func metricColumnTopRule() -> some View {
        overlay(alignment: .top) { Rectangle().fill(BojiColor.divider).frame(height: BojiLayout.hairline) }
    }
}

// MARK: - 1.1 旧角色 → 新角色 迁移表（供 CI / codemod 使用）
extension BojiTypeRole {
    /// 旧 BojiFontRole 的机械映射。
    static func migrated(from old: String) -> BojiTypeRole {
        switch old {
        case "pageTitle": return .title
        case "cardTitle": return .section
        case "exerciseName": return .bodyStrong
        case "body": return .body
        case "secondary": return .secondary
        case "label": return .label
        case "bodyMetric": return .display
        case "timer": return .hero
        case "setNumber": return .data
        default: return .body
        }
    }
}

/// 字阶修饰器：字号走 @ScaledMetric 以支持 Dynamic Type，行高、字距、等宽一次配齐。
private struct BojiTypeModifier: ViewModifier {
    let role: BojiTypeRole
    var monospacedDigits: Bool?
    var cjkText: Bool
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    func body(content: Content) -> some View {
        let useMono = monospacedDigits ?? role.defaultMonospacedDigits
        var weight = role.weight
        // 中文合成粗体会糊：hero / eyebrow 在中文场景降一档。
        if cjkText, role.demotesBoldForCJK, weight == .bold {
            weight = .bojiCJKStrong
        }
        let font = Font.system(size: role.size * scale, weight: weight, design: role.eyebrowDesign)
        return content
            .font(useMono ? font.monospacedDigit() : font)
            .tracking(role.tracking)
            .lineSpacing(max(0, role.lineHeight - role.size * 1.17 - (cjkText ? 2 : 0)))
            .dynamicTypeSize(role.dynamicTypeRange)
    }
}

private extension BojiTypeRole {
    var eyebrowDesign: Font.Design { self == .eyebrow ? .monospaced : .default }
}

extension View {
    /// 唯一文字入口。用法：`Text("今天的训练").bojiType(.title)`
    func bojiType(_ role: BojiTypeRole, monospacedDigits: Bool? = nil) -> some View {
        // Text 内容无法在此处读取，CJK 判定交给 `.bojiType(_:text:)` 重载。
        modifier(BojiTypeModifier(role: role, monospacedDigits: monospacedDigits, cjkText: false))
    }

    /// 带内容判定的重载：中文自动降字重、英文 eyebrow 自动大写。
    func bojiType(_ role: BojiTypeRole, text: String, monospacedDigits: Bool? = nil) -> some View {
        modifier(BojiTypeModifier(role: role,
                                  monospacedDigits: monospacedDigits,
                                  cjkText: BojiScript.containsCJK(text)))
    }
}

extension Text {
    /// 中文安全字重：中文降为 semibold，拉丁文保留 bold。
    func bojiWeight(_ weight: Font.Weight) -> Text {
        // Text 无法读取自身字符串，保守起见：若上层使用 .bojiType(text:) 已处理；
        // 这里仅作为显式覆盖入口，默认不改写。
        fontWeight(weight)
    }
}

// MARK: - 2. 间距 / 圆角 / 控件：BojiLayout（唯一入口）

/// 4pt 栅格的语义别名。禁止页面直接写 6 / 10 / 14 / 18 / 22 / 26 / 30。
enum BojiLayout {
    // —— 页面级 ——
    /// 页面左右安全边距：常规 20（compact 由系统 safe area 再收，不再逐页判断）。
    static let pageInset: CGFloat = 20
    /// 卡片内边距。
    static let cardInset: CGFloat = 16
    /// 两个「大块」之间的距离（section 之间）。
    static let sectionGap: CGFloat = 28
    /// 同一块内卡片之间的距离。
    static let cardGap: CGFloat = 12
    /// 卡片内「标题区 → 内容区」的距离。
    static let blockGap: CGFloat = 20
    /// 列表行之间 / 行内主副信息之间。
    static let rowGap: CGFloat = 12
    /// 图标与文字、chip 之间。
    static let inline: CGFloat = 8
    /// 紧邻元素（数字与单位、徽章与文字）。
    static let tight: CGFloat = 4
    /// 发丝线。
    static let hairline: CGFloat = 0.5

    // —— 全局组件规格体系 v1（唯一尺寸来源，表外尺寸一票否决）——
    /// B1 主操作高度（玻璃胶囊，每屏 1 个）。
    static let actionHeight: CGFloat = 54
    /// B2 次操作 / B3 图标按钮 / R1 单行行高。
    static let controlHeight: CGFloat = 44
    /// R2 双行行高。
    static let rowHeight: CGFloat = 56
    /// 输入框高度（唯一一种）。
    static let inputHeight: CGFloat = 48
    /// 列表底部避让：主操作 54 + 24（浮钮不许压最后一行）。
    static let actionClearance: CGFloat = 78

    // —— 纵向节奏（页面骨架专用，减少每个页面各自拍脑袋）——
    enum Rhythm {
        static let eyebrowToTitle: CGFloat = 6
        static let titleToMeta: CGFloat = 8
        static let headerToContent: CGFloat = 24
        static let pageTop: CGFloat = 48          // 首屏大留白（引导页 / 报告封面）
        static let footerClearance: CGFloat = 32  // 末块与底部控件之间
        static let sectionHeaderToBody: CGFloat = 12
        static let lastContentToDock: CGFloat = 120   // 底部悬浮 dock 的避让高度
    }

    // —— 圆角阶梯（8 级，按元素体积递增）——
    enum Radius {
        static let badge: CGFloat = 6          // 徽章、状态点、序号底
        static let thumb: CGFloat = 10         // 32–40pt 缩略图
        static let control: CGFloat = 12       // 输入框、chip、小按钮、缩略图 48–56
        static let inner: CGFloat = 16         // 卡内嵌容器（建议条、组行容器）
        static let cardSmall: CGFloat = 20     // 紧凑卡（指标卡、列表组）
        static let card: CGFloat = 24          // 主卡片
        static let hero: CGFloat = 28          // 大图 / 封面 / sheet 顶部
        static let pill: CGFloat = 999
    }

    // —— 控件尺寸表 ——
    enum Control {
        static let primaryHeight: CGFloat = 52      // 主 CTA（黑底胶囊）
        static let secondaryHeight: CGFloat = 44    // 次按钮
        static let compactHeight: CGFloat = 36      // chip / 小胶囊
        static let inputHeight: CGFloat = 48        // 输入框
        static let searchHeight: CGFloat = 44
        static let iconVisual: CGFloat = 32         // 图标视觉尺寸
        static let iconHit: CGFloat = 44            // 图标点击区（必须）
        static let fab: CGFloat = 56                // 悬浮主按钮
        static let rowSingle: CGFloat = 48          // 单行列表
        static let rowDouble: CGFloat = 64          // 双行列表
        static let rowThumb: CGFloat = 72           // 带 48pt 缩略图的列表
        static let thumb: CGFloat = 48
        static let thumbSmall: CGFloat = 40
        static let avatar: CGFloat = 36
        static let metricTileMinHeight: CGFloat = 96
        static let setRowHeight: CGFloat = 44       // 组行（kg / reps 输入）
        static let numberColumn: CGFloat = 28       // 组行序号列
        static let checkColumn: CGFloat = 40        // 组行打勾列
        static let minimumTap: CGFloat = 44         // 铁律
        static let contentWidth: CGFloat = 680      // iPad / 横屏正文最大宽度
    }
}

/// 给所有可点击元素兜底 44×44 的修饰器：视觉可以小，命中区必须够。
struct BojiTapTarget: ViewModifier {
    var minSize: CGFloat = BojiLayout.Control.minimumTap
    func body(content: Content) -> some View {
        content
            .frame(minWidth: minSize, minHeight: minSize)
            .contentShape(Rectangle())
    }
}

extension View {
    func bojiTapTarget(_ minSize: CGFloat = BojiLayout.Control.minimumTap) -> some View {
        modifier(BojiTapTarget(minSize: minSize))
    }
}

// MARK: - 3. 强调：BojiEmphasis（粗体 / 下划线 / 斜体 / 小型大写）

/// 强调只用四种手段，且互斥：
///   1. 粗体 strong   —— 判断句的关键名词（一句最多 1 处）、可点击主操作
///   2. 下划线 link   —— 仅次级可点击文字 / 外部链接 / 法务文本
///   3. 斜体 italic   —— 仅拉丁文（品牌、动作英文名、注释），中文禁用
///   4. 小型大写 eyebrow —— 仅英文小标
/// 其余强调交给「字号 + 灰度」，不要用字重堆叠。
enum BojiEmphasis {
    /// 行内富文本构造函数：把一段文案里的关键片段加粗，其余保持正文。
    /// 用法：BojiEmphasis.rich("今天练推，", strong: "腿还欠一次恢复") + Text("。")
    static func rich(_ plain: String, strong: String, role: BojiTypeRole = .display) -> Text {
        Text(plain) + Text(strong).fontWeight(role.weight) + Text("")
    }

    /// 英文/数字用 bold，中文自动降为 semibold。
    static func strong(_ s: String) -> Text {
        Text(s).fontWeight(BojiScript.containsCJK(s) ? .bojiCJKStrong : .bold)
    }

    /// 期刊式署名/注释：仅拉丁文斜体；中文串原样返回（禁止合成斜体）。
    static func cite(_ s: String) -> Text {
        BojiScript.containsCJK(s) ? Text(s).italicIf(false) : Text(s).italic()
    }
}

private extension Text {
    func italicIf(_ on: Bool) -> Text { on ? italic() : self }
}

/// 下划线（链接语义）。SwiftUI 原生 `.underline()` 无法控制与基线的距离，
/// 这里用 1pt overlay 画在文字下方 3pt 处，并按 0.55 透明度降低重量。
struct BojiUnderline: ViewModifier {
    var color: Color = BojiColor.textSecondary
    var isActive: Bool = false
    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(color.opacity(isActive ? 0.9 : 0.55))
                    .frame(height: 1)
                    .offset(y: 3)
                    .allowsHitTesting(false)
            }
            .padding(.bottom, BojiLayout.tight)
    }
}

extension View {
    /// 可点击的次级文字：下划线 + 44pt 命中区。
    /// 用法：`Text("查看全部").bojiType(.label).bojiLink { showAll = true }`
    func bojiLink(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            self.modifier(BojiUnderline(color: BojiColor.textSecondary, isActive: true))
                .bojiTapTarget()
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isLink)
    }

    /// 仅用于「非按钮」的下划线强调（数据来源、法务文本）。
    func bojiUnderlined(_ color: Color = BojiColor.textSecondary) -> some View {
        modifier(BojiUnderline(color: color))
    }

    /// 英文品牌字 / 动作英文名：自动判定，中文不斜。
    func bojiLatinItalic(_ content: String) -> some View {
        self.italicIfLatin(content)
    }
}

private extension View {
    @ViewBuilder
    func italicIfLatin(_ content: String) -> some View {
        if BojiScript.containsCJK(content) { self } else { self.italic() }
    }
}

// MARK: - 4. 动效：BojiMotion2（分层，唯一入口）

/// 四层运动语言。原则：
///   - 只有「状态真的变了」才动；装饰性循环动画默认关闭。
///   - 只动 transform / opacity / 颜色；不动 frame / padding（避免布局抖动）。
///   - 每层只允许一个曲线，禁止页面自定义时长。
enum BojiMotion2 {
    /// L1 微反馈 160ms：按下、勾选、步进、切页签（微交互档 120-200ms，2026-11-07 参数对齐）。
    static let micro = Animation.spring(response: 0.16, dampingFraction: 0.78)
    /// L2 状态变化 220ms：展开/收起、开关、进度（默认档 response 0.40-0.50 / damping 0.75-0.85）。
    static let state = Animation.spring(response: 0.40, dampingFraction: 0.85)
    /// L3 转场 320ms：sheet、页面推入、卡片重组。
    static let transition = Animation.spring(response: 0.42, dampingFraction: 0.85)
    /// L4 庆典 560ms：PR、训练完成、徽章解锁（发力感档 damping 0.70-0.78，现行 0.74 合规不改）。
    static let celebrate = Animation.spring(response: 0.52, dampingFraction: 0.74)
    /// 进度条 / 环形：线性更诚实，避免弹簧制造的假进度。
    static let progress = Animation.easeOut(duration: 0.32)
    /// 数字滚动 counter：linear 300-450ms（§5.1 数字滚动档，供 RollingNumericCounter 等使用）。
    static let counter = Animation.linear(duration: 0.35)
    /// 长内容入场 entrance：spring(response 0.35, dampingFraction 0.85)（规范 §4.1 浮件/事实格进场档）。
    static let entrance = Animation.spring(response: 0.35, dampingFraction: 0.85)

    /// 序列入场拍间隔：50ms（规范 §4.1；整串总和 ≤600ms）。
    static let stagger: Double = 0.05

    /// Reduce Motion 下把任意层级降为「短交叉淡入」（120ms 纯淡入淡出，§5.1 降级规则）。
    static func resolved(_ level: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? .easeOut(duration: 0.12) : level
    }

    /// 统一入口：自动读 reduceMotion，避免每处手写三元表达式。
    struct Animated<Value: Equatable>: ViewModifier {
        let animation: Animation
        let value: Value
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        func body(content: Content) -> some View {
            content.animation(BojiMotion2.resolved(animation, reduceMotion: reduceMotion), value: value)
        }
    }
}

extension View {
    func bojiAnimate<V: Equatable>(_ animation: Animation, value: V) -> some View {
        modifier(BojiMotion2.Animated(animation: animation, value: value))
    }

    /// 统一的按下回弹：0.96 → 1，L1 曲线，可选触感。
    func bojiPressable(scale: CGFloat = 0.96, haptic: BojiFeedback.Event? = .selection) -> some View {
        modifier(BojiPressModifier(scale: scale, haptic: haptic))
    }
}

private struct BojiPressModifier: ViewModifier {
    let scale: CGFloat
    let haptic: BojiFeedback.Event?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.buttonStyle(BojiPressStyle(scale: scale, haptic: haptic, reduceMotion: reduceMotion))
    }
}

struct BojiPressStyle: ButtonStyle {
    var scale: CGFloat = 0.96
    var haptic: BojiFeedback.Event? = .selection
    var reduceMotion: Bool = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? scale : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(reduceMotion ? nil : BojiMotion2.micro, value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed, let haptic { BojiFeedback.fire(haptic) }
            }
    }
}

// MARK: - 5. 触感：BojiFeedback（事件驱动，而不是随手 .light()）

/// 触感按「事件语义」取用，禁止页面直接调 UIImpactFeedbackGenerator。
enum BojiFeedback {
    enum Event {
        case selection        // 切换页签、选中 chip、步进、日期切换
        case toggle           // 开关、勾选一组
        case commit           // 保存、确认、提交表单
        case success          // 训练保存成功、AI 报告生成完成
        case milestone        // PR、连续打卡、结营
        case warning
        case error
        case destructive      // 删除确认
    }

    static func fire(_ event: Event) {
        switch event {
        case .selection:
            BojiHaptics.tick()
        case .toggle:
            BojiHaptics.latch()
        case .commit:
            BojiHaptics.pressRelease()
        case .success:
            BojiHaptics.heavyDrop()
        case .milestone:
            BojiHaptics.milestone()
        case .warning:
            BojiHaptics.warning()
        case .error:
            BojiHaptics.error()
        case .destructive:
            BojiHaptics.latch()
        }
    }
}

// MARK: - 6. 组件规格速查（给实现者的注释，不参与编译）
//
//  Button
//    主 CTA      高 52 / 圆角 999 / 黑底白字 / label 用 .bodyStrong / 一屏最多 1 个
//    次按钮      高 44 / 浅底（cardSurface）+ 0.5pt 描边 / label 用 .bodyStrong
//    文字按钮    无底色 / label 用 .label + .bojiLink / 命中区 44
//    危险按钮    浅红底 red.opacity(0.10) / 红字 / 需二次确认
//    禁用态      统一 opacity 0.38，禁止只改颜色不改透明度
//
//  List Row（借用 Apple Music 规格）
//    单行 48 / 双行 64 / 带缩略图 72；左右内边距 = cardInset(16)
//    分隔线 0.5pt，从「文字起点」缩进（不是全宽），颜色 divider
//    行尾 chevron 14pt，颜色 textTertiary；整行 contentShape 命中
//    序号列 28pt 等宽数字，颜色 textTertiary（参考图的专辑曲目号）
//
//  Metric Tile（借用健身 App 规格）
//    最小高 96 / 内边距 16 / 圆角 20 / 表面 cardSurface
//    标题 .label + textSecondary → 数值 .display(34) 等宽 → 单位 .label 且不粗
//    空态显示 "--" 而不是隐藏整块（读数位仍在）
//
//  Set Row（训练组行）
//    高 44 / 列：序号 28 · 重量 flex · 次数 flex · 打勾 40
//    输入底 inputSurface + 圆角 10；行距 8；组间 12
//
//  Empty State
//    图标 32 / 标题 .bodyStrong / 说明 .secondary + textSecondary / 一个主操作
//    禁止整块留白，禁止用插画代替可执行动作
//
//  Sheet
//    大圆角 28（系统默认）/ 顶部 grabber / 标题 .section / 动作区固定在底部
