import SwiftUI

/// 设计稿 §9 的组件规格：PrimaryButton / GhostButton / GlassCard / ItemRow /
/// StatStrip / Chip / InputBar，以及 §12 要求的 BojiSkeleton 四态骨架。
///
/// 环形进度 `BojiProgressRing` 在 BojiMotion.swift（M7 的实现与动效绑定在一起）。
///
/// 全部组件都在同一块玻璃上：不要用普通圆角视图冒充玻璃（§5）。

// MARK: - PrimaryButton

/// PrimaryButton：h 56，r 28，#2E6BF6，17pt Semibold 白字，accent 投影，
/// 内顶 1pt 白高光，M8 流光，按下 scale .97。一屏最多一个。
struct BojiPrimaryButtonStyle: ButtonStyle {

    /// 这里只做按下缩放和 M8 流光，**不再给标签加宽**。
    ///
    /// 宽度只能由标签里的 .frame(maxWidth: .infinity) 决定一次。
    /// 样式里再写一次 .frame(maxWidth: .infinity) 就是二次填宽：Button 的尺寸
    /// 取自样式视图，标签被二次撑开后宽度算不准，布局时焦点卡从 322pt 被撑到
    /// 694.82pt（AX 实测「开始训练」frame=(-353.82, 815.67, 694.82, 56)，
    /// 屏宽只有 402pt），按钮整个溢出到屏幕左侧外。
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
            .shadow(color: BojiV2.accentShadow, radius: 24, x: 0, y: 8)
            .bojiSheen()
    }
}

/// 主按钮的便捷入口。
struct BojiPrimaryButton: View {
    let title: String
    var systemImage: String? = nil
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
            .font(BojiV2.bodyEm)
            .foregroundStyle(.white)
            // 整宽只在这里做一次，样式不再重复填宽。
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(BojiV2.accent, in: Capsule())
            .overlay {
                Capsule().strokeBorder(
                    LinearGradient(colors: [Color.white.opacity(0.65), Color.white.opacity(0.12)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 1
                )
            }
            .contentShape(Capsule())
        }
        .buttonStyle(BojiPrimaryButtonStyle())
        .accessibilityLabel(title)
    }
}

// MARK: - GhostButton

/// GhostButton：h 48–50，r 24–28，白 75% 玻璃底，accent 字，1pt 白描边，无流光。
struct BojiGhostButtonStyle: ButtonStyle {
    var fullWidth: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(BojiV2.bodyEm)
            .foregroundStyle(BojiV2.accent)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .frame(height: 50)
            .background(Color.white.opacity(0.75), in: Capsule())
            .overlay { Capsule().strokeBorder(Color.white.opacity(0.95), lineWidth: 1) }
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: - GlassCard

/// GlassCard：内容卡 r 22，底部大卡 r 40，都贴同一块玻璃。
struct BojiGlassCard<Content: View>: View {
    var radius: CGFloat = BojiV2.glassCardRadius
    var padding: CGFloat = BojiV2.glassPadding
    var elevated: Bool = true
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .bojiGlass(radius: radius, elevated: elevated)
    }
}

// MARK: - ItemRow

/// ItemRow：r 22 玻璃，左 38pt 圆图标底（#F2F2F7，内 17pt 符号）＋主文 15 Semibold
/// ＋副文 12 #6E6E73＋右侧数值 15 Semibold 等宽或「›」。
struct BojiItemRow: View {
    let title: String
    var subtitle: String? = nil
    var systemImage: String? = nil
    var value: String? = nil
    var showsChevron: Bool = false
    var action: (() -> Void)? = nil
    /// 无障碍与 UI 测试定位标识；默认取 title（同一屏内唯一）。
    var identifier: String? = nil

    var body: some View {
        let content = HStack(spacing: 12) {
            if let systemImage {
                ZStack {
                    Circle().fill(Color(red: 0.949, green: 0.949, blue: 0.969))
                    Image(systemName: systemImage)
                        .font(.system(.body, design: .default, weight: .medium))
                        .foregroundStyle(BojiV2.textSecondary)
                }
                .frame(width: 38, height: 38)
                .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(.subheadline, design: .default, weight: .semibold))
                    .foregroundStyle(BojiV2.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(.caption, design: .default))
                        .foregroundStyle(BojiV2.textSecondary)
                }
            }
            Spacer(minLength: 8)
            if let value {
                Text(value)
                    .bojiNumeral(.subheadline, weight: .semibold)
                    .foregroundStyle(BojiV2.textPrimary)
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(.footnote, design: .default, weight: .semibold))
                    .foregroundStyle(BojiV2.textSecondary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, BojiV2.rowPadding)
        .padding(.vertical, 12)
        .bojiGlass(radius: BojiV2.glassCardRadius, elevated: false)
        // 必须是真 Button：`.onTapGesture` + `.accessibilityAddTraits(.isButton)`
        // 只改播报不改动作，VoiceOver 双击无法激活，XCUI 也不会把它当 button 查。
        if let action {
            Button(action: action) { content }
                .buttonStyle(.plain)
                .accessibilityIdentifier(identifier ?? title)
        } else {
            content
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(identifier ?? title)
        }
    }
}

// MARK: - StatStrip

/// StatStrip：三格等宽，中间竖分隔线 rgba(0,0,0,0.08)，值 20–40pt Semibold 等宽
/// ＋12pt 标签。
struct BojiStatStrip: View {
    struct Item: Identifiable {
        let id = UUID()
        let value: String
        let label: String
        var isNumeric: Bool = true
    }

    let items: [Item]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 {
                    Rectangle()
                        .fill(Color.black.opacity(0.08))
                        .frame(width: 1, height: 28)
                }
                VStack(spacing: 4) {
                    if item.isNumeric {
                        Text(item.value)
                            .bojiNumeral(.title3)
                            .foregroundStyle(BojiV2.textPrimary)
                    } else {
                        Text(item.value)
                            .font(.system(.headline, design: .default, weight: .semibold))
                            .foregroundStyle(BojiV2.textPrimary)
                    }
                    Text(item.label)
                        .font(BojiV2.micro)
                        .foregroundStyle(BojiV2.textSecondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Chip

/// Chip：h 38，r 19，白 75% 玻璃底，14pt 文字。
struct BojiChip: View {
    let title: String
    var systemImage: String? = nil
    var isSelected: Bool = false
    var action: (() -> Void)? = nil

    var body: some View {
        let content = HStack(spacing: 6) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 13, weight: .semibold)) }
            Text(title).font(.system(size: 14, weight: .medium))
        }
        .foregroundStyle(isSelected ? Color.white : BojiV2.textPrimary)
        .padding(.horizontal, 14)
        .frame(height: 38)
        .background(isSelected ? BojiV2.accent : Color.white.opacity(0.75), in: Capsule())
        .overlay { Capsule().strokeBorder(Color.white.opacity(0.95), lineWidth: 1) }
        .contentShape(Capsule())
        .onTapGesture { action?() }
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
    }
}

// MARK: - InputBar

/// InputBar：h 52，r 26，白 80% 玻璃底，placeholder #6E6E73 15pt，
/// 右侧 40pt 圆形 accent 发送钮。
struct BojiInputBar: View {
    @Binding var text: String
    var placeholder: String = "说说你的想法…"
    var isEnabled: Bool = true
    var onSend: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            TextField(placeholder, text: $text)
                .font(.system(size: 15))
                .foregroundStyle(BojiV2.textPrimary)
                .tint(BojiV2.accent)
                .submitLabel(.send)
                .onSubmit { if isEnabled && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { onSend() } }
            Button(action: onSend) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(BojiV2.accent, in: Circle())
            }
            .disabled(!isEnabled || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(isEnabled ? 1 : 0.4)
            .accessibilityLabel("发送")
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .background(Color.white.opacity(0.80), in: Capsule())
        .overlay { Capsule().strokeBorder(Color.white.opacity(0.95), lineWidth: 1) }
    }
}

// MARK: - Skeleton

/// BojiSkeleton：每屏四态共用的骨架（灰圆角闪烁条）。
struct BojiSkeleton: View {
    var height: CGFloat = 16
    var width: CGFloat? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    var body: some View {
        RoundedRectangle(cornerRadius: height / 2, style: .continuous)
            .fill(Color.black.opacity(0.06))
            .frame(width: width, height: height)
            .overlay {
                if !reduceMotion {
                    LinearGradient(colors: [.clear, Color.white.opacity(0.55), .clear],
                                   startPoint: .leading, endPoint: .trailing)
                        .offset(x: phase * 260)
                        .mask(RoundedRectangle(cornerRadius: height / 2, style: .continuous))
                }
            }
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { phase = 1 }
            }
            .accessibilityHidden(true)
    }
}

/// 骨架占位块（数字位用「—」而不是骨架，见 §10.1 加载态）。
struct BojiSkeletonBlock: View {
    var title: String?
    var subtitle: String?

    var body: some View {
        HStack(spacing: 10) {
            BojiSkeleton(height: 38, width: 38)
            VStack(alignment: .leading, spacing: 6) {
                if let title { BojiSkeleton(height: 15, width: 180) }
                if let subtitle { BojiSkeleton(height: 12, width: 120) }
            }
            Spacer()
            BojiSkeleton(height: 15, width: 44)
        }
        .padding(.horizontal, BojiV2.rowPadding)
        .padding(.vertical, 12)
        .bojiGlass(radius: BojiV2.glassCardRadius, elevated: false)
    }
}
