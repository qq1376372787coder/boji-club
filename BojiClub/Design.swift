import ImageIO
import UIKit
import SwiftUI
import Foundation

enum ClubBrand {
    static let accent = BojiColor.mistAccent
    static let onAccent = Color("BrandOnAccent")
    static let soft = accent.opacity(0.06)
}

// 旧入口保留给存量调用；取值一律来自 DesignTokens.swift，禁止在此定义新参数。
enum ClubUI {
    static let page = BojiColor.pageBackground
    static let surface = BojiColor.cardSurface
    static let insetSurface = BojiColor.inputSurface
    static let border = BojiColor.outline
    static let cardRadius: CGFloat = BojiRadius.card
    static let controlRadius: CGFloat = BojiRadius.input
    static let mediaRadius: CGFloat = BojiRadius.image
    static let minimumTap: CGFloat = BojiSize.minimumTap
    static let pageInset: CGFloat = BojiSpace.pageInset
    static let cardInset: CGFloat = BojiSpace.cardInset
    static let sectionSpacing: CGFloat = BojiSpace.sectionSpacing
    static let contentWidth: CGFloat = BojiSize.contentWidth
    static let primaryHeight: CGFloat = BojiSize.primaryButtonHeight
}

enum ClubAccessibility {
    static func announce(_ message: String) {
        DispatchQueue.main.async {
            guard UIAccessibility.isVoiceOverRunning else { return }
            UIAccessibility.post(notification: .announcement, argument: message)
        }
    }
}

struct ClubBackground: View {
    var body: some View {
        ClubUI.page
            .ignoresSafeArea()
    }
}

struct ClubCard<Content: View>: View {
    private let content: Content
    private let compact: Bool
    @Environment(\.clubNativeSections132) private var nativeSections
    init(compact: Bool = false, @ViewBuilder content: () -> Content) { self.compact = compact; self.content = content() }
    var body: some View {
        if nativeSections {
            Section { content.environment(\.clubNativeSections132, false) }
        } else {
            // 设计稿 §12：内容卡统一走 v2 玻璃，不再保留「灰底 + 描边 + 抬高」双轨。
            // 列表截面（nativeSections）继续用系统分组背景，避免材质叠材质。
            VStack(alignment: .leading, spacing: compact ? 8 : 14) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(compact ? BojiV2.rowPadding : BojiV2.glassPadding)
                .bojiGlass(radius: BojiV2.glassCardRadius)
        }
    }
}

struct SectionTitle: View {
    let title: String
    let symbol: String
    var body: some View {
        Label(title, systemImage: symbol).bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
    }
}

struct Metric: View {
    let title: String
    let value: String
    let unit: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).bojiFont(.label).foregroundStyle(BojiColor.textSecondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(.title3, design: .rounded, weight: .bold).monospacedDigit())
                    .foregroundStyle(BojiColor.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(unit)
                    .bojiFont(.label)
                    .foregroundStyle(BojiColor.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(BojiSpace.general)
        .background(ClubUI.insetSurface, in: RoundedRectangle(cornerRadius: ClubUI.controlRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: ClubUI.controlRadius, style: .continuous)
                .stroke(BojiColor.outline, lineWidth: 0.5)
                .allowsHitTesting(false)
        }
    }
}

struct PrimaryButton: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ClubActionButtonStyle(kind: .primary, size: .large).makeBody(configuration: configuration)
    }
}

struct EmptyNote: View {
    let title: String
    let detail: String
    var symbol: String = "sparkles.rectangle.stack"
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(BojiColor.brandAccent)
                .frame(width: 34, height: 34)
                .background(BojiColor.brandAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .bojiFont(.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(BojiColor.textPrimary)
                Text(detail)
                    .bojiFont(.secondary)
                    .foregroundStyle(BojiColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(BojiSpace.workoutCardInset)
        .background(BojiColor.subtleSurface.opacity(0.75), in: RoundedRectangle(cornerRadius: BojiRadius.input, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: BojiRadius.input, style: .continuous)
                .stroke(BojiColor.outline, lineWidth: 0.5)
                .allowsHitTesting(false)
        }
    }
}

extension View {
    /// Retain native editing, navigation and swipe actions, on the same page surface.
    func clubGroupedSurface() -> some View {
        scrollContentBackground(.hidden)
            .contentMargins(.horizontal, ClubUI.pageInset, for: .scrollContent)
            .listRowBackground(BojiColor.cardSurface)
            .background { ClubBackground() }
            .tint(BojiV2.accent)
            .environment(\.defaultMinListRowHeight, ClubUI.minimumTap)
            .presentationDragIndicator(.visible)
    }

    func clubListSurface() -> some View {
        listStyle(.insetGrouped).clubGroupedSurface()
    }

    func clubGlassEffect<S: Shape>(in shape: S) -> some View {
        modifier(ClubGlassSurface(shape: shape))
    }

    @ViewBuilder
    func clubGlassGroup(spacing: CGFloat = 12) -> some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { self }
        } else { self }
    }

    /// Keep native labels readable when accessibility sizes outgrow a segmented control.
    func clubAdaptivePicker() -> some View { modifier(ClubAdaptivePickerStyle()) }

    /// Use this for stand-alone floating actions; content actions use bordered system styles.
    func clubNativeGlassButton(prominent: Bool = false) -> some View {
        modifier(ClubNativeGlassButtonModifier(prominent: prominent))
    }

    /// A single bottom accessory slot. The content owns its floating material and margins.
    func clubBottomBar<Bar: View>(@ViewBuilder content: () -> Bar) -> some View {
        modifier(ClubBottomBarModifier(bar: content()))
    }
}

private struct ClubAdaptivePickerStyle: ViewModifier {
    @Environment(\.dynamicTypeSize) private var typeSize
    @ViewBuilder func body(content: Content) -> some View {
        if typeSize.isAccessibilitySize { content.pickerStyle(.menu) }
        else { content.pickerStyle(.segmented) }
    }
}

private struct ClubGlassSurface<S: Shape>: ViewModifier {
    let shape: S
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency || contrast == .increased {
            content.background(BojiColor.cardSurface, in: shape)
                .overlay { shape.stroke(BojiColor.outline, lineWidth: 1).allowsHitTesting(false) }
        } else if #available(iOS 26.0, *) {
            content.glassEffect(.regular.tint(BojiColor.brandMist.opacity(0.45)), in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
        }
    }
}

private struct ClubNativeGlassButtonModifier: ViewModifier {
    let prominent: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *), !reduceTransparency, contrast != .increased {
            if prominent { content.buttonStyle(.glassProminent) }
            else { content.buttonStyle(.glass) }
        } else if prominent {
            content.buttonStyle(.borderedProminent)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

private struct ClubBottomBarModifier<Bar: View>: ViewModifier {
    let bar: Bar
    @ViewBuilder func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) { bar }
    }
}


enum AppErrorText {
    static func message(_ error: Error, fallback: String = "暂时未能完成操作，请稍后重试。") -> String {
        let authored = (error as? AccountError)?.errorDescription
            ?? (error as? AIClientError)?.errorDescription
            ?? (error as? CloudSyncError)?.errorDescription
            ?? (error as? HealthImportError)?.errorDescription
        if let authored, !authored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return authored
        }
        let system = error as NSError
        if system.domain == NSURLErrorDomain {
            switch system.code {
            case URLError.notConnectedToInternet.rawValue, URLError.networkConnectionLost.rawValue:
                return "网络连接已断开，请连接网络后重试。"
            case URLError.timedOut.rawValue:
                return "等待时间较长，请稍后重试。"
            case URLError.cancelled.rawValue:
                return "操作已取消。"
            default: return "暂时无法连接服务，请检查网络后重试。"
            }
        }
        return fallback
    }
}


enum ClubImage {
    nonisolated static func downsample(_ data: Data, pixels: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: max(1,pixels), kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
    nonisolated static func preview(_ data: Data, pixels: Int) async -> UIImage? {
        await Task.detached(priority: .utility) { downsample(data, pixels: pixels) }.value
    }
}

struct ClubPhotoPreview: View {
    let data: Data
    var pixels: Int = 600
    @State private var image: UIImage?
    @State private var loaded = false
    var body: some View {
        Group {
            if let image { Image(uiImage:image).resizable().scaledToFit() }
            else if loaded { Image(systemName: "photo.badge.exclamationmark").accessibilityLabel("照片暂时无法读取") }
            else { ClubCompactWait(title: "正在读取照片…") }
        }.task(id: data) {
            loaded = false; image = nil
            let value = await ClubImage.preview(data, pixels: pixels)
            guard !Task.isCancelled else { return }; image = value; loaded = true
        }
    }
}


// Motion is opt-in so existing Home / R30 behavior stays unchanged.
enum ClubMotion {
    static let quick = Animation.easeOut(duration: 0.18)
    static let standard = Animation.easeInOut(duration: 0.26)
    static func transition(reduced: Bool) -> AnyTransition {
        reduced ? .opacity : .opacity.combined(with: .offset(y: 6))
    }
}

private struct ClubMotionModifier<Value: Equatable>: ViewModifier {
    let value: Value
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : ClubMotion.standard, value: value)
    }
}

private struct ClubRevealModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false
    func body(content: Content) -> some View {
        content.opacity(revealed ? 1 : 0)
            .offset(y: revealed || reduceMotion ? 0 : 6)
            .task {
                withAnimation(reduceMotion ? nil : ClubMotion.standard) { revealed = true }
            }
    }
}

struct ClubMotionButton: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(configuration.role == .destructive ? Color.red : .primary)
            .frame(minHeight: ClubUI.minimumTap).contentShape(Rectangle())
            .opacity(configuration.isPressed && enabled ? 0.78 : 1)
            .scaleEffect(configuration.isPressed && enabled && !reduceMotion ? 0.985 : 1)
            .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: configuration.isPressed)
            .sensoryFeedback(.selection, trigger: configuration.isPressed) { _, pressed in pressed && enabled }
    }
}

// Time-driven motion has no repeatForever task to outlive its visible view.
// The decorative ring is indeterminate, never a fabricated completion percentage.
struct ClubActivityMark: View {
    var size: CGFloat = 28
    var tint: Color = ClubBrand.accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var visible = false
    @State private var inViewport = false
    private var moving: Bool { visible && inViewport && scenePhase == .active && !reduceMotion }
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !moving)) { context in
            let phase = moving ? context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8) / 1.8 : 0
            ZStack {
                Circle().stroke(tint.opacity(0.12), lineWidth: 2)
                Circle().fill(tint.opacity(0.45))
                    .frame(width: size * 0.18, height: size * 0.18)
                    .scaleEffect(CGFloat(moving ? 0.9 + 0.12 * sin(phase * 2 * Double.pi) : 1))
                Circle().trim(from: 0, to: 0.26)
                    .stroke(tint.opacity(0.8), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(phase * 360 - 90))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .clubViewportVisibility($inViewport)
        .onAppear { visible = true }
        .onDisappear { visible = false }
    }
}

struct ClubLoadingCard: View {
    let title: String
    var detail: String? = nil
    var tint: Color = ClubBrand.accent
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Image(systemName: "hourglass").font(.title3).foregroundStyle(tint)
                    .frame(width: 28).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.subheadline.weight(.medium))
                    if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 0)
            }
            ClubWaitBar(tint: tint)
        }
        .padding(.vertical, BojiSpace.general)
        .accessibilityElement(children: .combine)
        .clubReveal()
    }
}

struct ClubLoadingSkeleton: View {
    let title: String
    var rows: Int = 3
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var visible = false
    @State private var inViewport = false
    @State private var showPlaceholders = false
    private var moving: Bool { visible && inViewport && scenePhase == .active && !reduceMotion }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ClubLoadingCard(title: title)
            if showPlaceholders {
                TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !moving)) { context in
                    let pulse = moving ? 0.65 + 0.15 * sin(context.date.timeIntervalSinceReferenceDate * 3) : 0.65
                    VStack(spacing: 12) {
                        ForEach(0..<max(0, min(rows, 4)), id: \.self) { _ in
                            HStack(spacing: 14) {
                                RoundedRectangle(cornerRadius: BojiRadius.inner).fill(Color.primary.opacity(0.07)).frame(width: 54, height: 54)
                                VStack(alignment: .leading, spacing: 10) {
                                    RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)).frame(height: 11)
                                    RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.06)).frame(maxWidth: 140).frame(height: 9)
                                }
                                Spacer(minLength: 18)
                            }.padding(ClubUI.cardInset).background(ClubUI.surface, in: RoundedRectangle(cornerRadius: ClubUI.cardRadius, style: .continuous))
                        }
                    }.opacity(pulse)
                }
                .accessibilityHidden(true)
                .transition(.opacity)
            }
        }
        .clubViewportVisibility($inViewport)
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .task {
            // Quick responses never flash a full placeholder layout.
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : ClubMotion.quick) { showPlaceholders = true }
        }
    }
}

private struct ClubSuccessFeedbackModifier: ViewModifier {
    let title: String
    let trigger: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showing = false
    @State private var lastHandledTrigger = 0
    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if showing {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(ClubBrand.accent)
                    Text(title)
                }.font(.subheadline.weight(.medium))
                    .padding(.horizontal, BojiSpace.pageInset).padding(.vertical, BojiSpace.general)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, BojiSpace.tightRow)
                    .transition(ClubMotion.transition(reduced: reduceMotion))
                    .allowsHitTesting(false)
            }
        }
        .task(id: trigger) {
            guard trigger > lastHandledTrigger else { return }
            lastHandledTrigger = trigger
            withAnimation(reduceMotion ? nil : ClubMotion.quick) { showing = true }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : ClubMotion.quick) { showing = false }
        }
        .onDisappear { showing = false }
    }
}

extension View {
    func clubMotion<Value: Equatable>(value: Value) -> some View { modifier(ClubMotionModifier(value: value)) }
    func clubReveal() -> some View { modifier(ClubRevealModifier()) }
    func clubSuccessFeedback(_ title: String, trigger: Int) -> some View {
        modifier(ClubSuccessFeedbackModifier(title: title, trigger: trigger))
    }
}


// All AI waits use the same lightweight mark; task text comes from actual status.
struct AIProcessingMark: View {
    var size: CGFloat = 40
    @Environment(\.accessibilityReduceMotion) private var reduced
    @Environment(\.scenePhase) private var phase
    @State private var visible = false
    @State private var inViewport = false
    private var moving: Bool { visible && inViewport && !reduced && phase == .active }
    var body: some View {
        TimelineView(.animation(minimumInterval:1.0 / 15,paused:!moving)) { context in
            let angle = moving ? context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy:2.8) / 2.8 * .pi * 2 : .pi / 2
            BojiBrandMark(size:size)
                .opacity(moving ? 0.86 + 0.14 * sin(angle) : 1)
        }
        .frame(width:size,height:size).accessibilityHidden(true)
        .clubViewportVisibility($inViewport)
        .onAppear { visible = true }.onDisappear { visible = false }
    }
}

struct AILoadingCard: View {
    let title: String
    var detail: String? = nil
    var status: String? = nil
    var compact = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 16) {
                AIProcessingMark(size:compact ? 24 : 40)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.body.weight(.semibold)).foregroundStyle(.primary)
                    if let detail { Text(detail).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer(minLength: 0)
            }
            AIWaitProgress(status: status)
        }.padding(.vertical, BojiSpace.general).accessibilityElement(children: .combine)
    }
}

/// A moving segment communicates activity; it does not claim a measured percentage.
struct ClubWaitBar: View {
    var tint: Color = ClubBrand.accent
    var active = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var visible = false
    @State private var inViewport = false
    private var moving: Bool { active && visible && inViewport && scenePhase == .active && !reduceMotion }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: !moving)) { context in
            let phase = moving ? context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2) / 2 : 0.5
            GeometryReader { geometry in
                let width = max(0, geometry.size.width)
                ZStack(alignment: .leading) {
                    Capsule().fill(tint.opacity(0.12))
                    Capsule().fill(tint.opacity(active ? 1 : 0.45))
                        .frame(width: width * 0.34)
                        .offset(x: CGFloat(phase * 1.4 - 0.37) * width)
                }.clipShape(Capsule())
            }
        }
        .frame(height: 5)
        .accessibilityLabel("等待进度")
        .accessibilityValue(active ? "处理中，暂时没有准确百分比" : "等待继续")
        .clubViewportVisibility($inViewport)
        .onAppear { visible = true }
        .onDisappear { visible = false }
    }
}

struct AIWaitProgress: View {
    let status: String?
    private var phase: AIWaitPhase { AIWaitPhase(status: status) }
    private let titles = ["提交", "排队", "AI 处理", "完成"]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if phase.showsStages {
                HStack(alignment: .top, spacing: 7) {
                    ForEach(titles.indices, id: \.self) { index in
                        stage(index)
                    }
                }.accessibilityHidden(true)
            } else {
                ClubWaitBar(active: phase.isActive).accessibilityHidden(true)
            }
            Text(phase.message).font(.footnote).foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            if phase.isActive {
                Text("可以先去记录，稍后回来查看结果。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.accessibilityElement(children: .combine)
    }
    private func stage(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Group {
                if index == phase.activeStage {
                    ClubWaitBar()
                } else {
                    Capsule().fill(index < phase.completedStages ? ClubBrand.accent : Color.primary.opacity(0.08))
                        .frame(height: 5)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                if index < phase.completedStages { Image(systemName: "checkmark").font(.caption2) }
                Text(titles[index]).font(.caption)
            }.foregroundStyle(index <= (phase.activeStage ?? phase.completedStages - 1) ? ClubBrand.accent : Color.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Compact feedback for thumbnail and inline waits without changing their layout.
struct ClubCompactWait: View {
    var title: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title { Text(title).font(.caption).foregroundStyle(.secondary) }
            ClubWaitBar()
        }.frame(maxWidth: 160).padding(.horizontal, BojiSpace.tightRow)
            .accessibilityElement(children: .combine)
    }
}

/// Version comes from the installed build; this page never implies membership or AI availability.
struct BojiAboutView: View {
    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "—")（\(info["CFBundleVersion"] as? String ?? "—")）"
    }
    var body: some View { AboutSettings132() }
}
