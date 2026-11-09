import SwiftUI
import AudioToolbox
import UserNotifications

private struct FirstLaunchWalkthroughPresentedKey: EnvironmentKey {
    static let defaultValue = false
}
extension EnvironmentValues {
    var firstLaunchWalkthroughPresented: Bool {
        get { self[FirstLaunchWalkthroughPresentedKey.self] }
        set { self[FirstLaunchWalkthroughPresentedKey.self] = newValue }
    }
}

enum WalkthroughPresentationRules {
    static func shouldPresent(completed: Bool, force: Bool = false, auditScreen: String? = nil, skipForPreview: Bool = false) -> Bool {
        if force { return true }
        if skipForPreview { return false }
        if auditScreen != nil { return false }
        return !completed
    }
    static func slide(_ proposed: Int) -> Int { min(3, max(0, proposed)) }
}

/// First-use introduction. Demonstrations never enter saved member records.
struct FirstLaunchWalkthroughView: View {
    @Binding var isPresented: Bool
    var initialSlide: Int = 0
    @EnvironmentObject private var health: HealthDataService
    @EnvironmentObject private var notifications: AppNotificationService
    @AppStorage("boji.hasCompletedFirstLaunchWalkthrough") private var hasCompletedWalkthrough = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var currentSlide: Int
    @State private var isDismissing: Bool = false

    private let totalSlides = 4

    init(isPresented: Binding<Bool>, initialSlide: Int = 0) {
        self._isPresented = isPresented
        self.initialSlide = WalkthroughPresentationRules.slide(initialSlide)
        self._currentSlide = State(initialValue: WalkthroughPresentationRules.slide(initialSlide))
    }

    var body: some View {
        ZStack {
            // Immersive ambient backdrop with subtle flowing refraction spots
            (colorScheme == .dark ? Color(red: 10/255, green: 13/255, blue: 18/255) : Color(red: 245/255, green: 247/255, blue: 250/255))
                .ignoresSafeArea()

            WalkthroughAtmosphereBackdrop(activeSlide: currentSlide)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Top floating utility bar
                topUtilityBar
                    .padding(.horizontal, BojiLayout.pageInset)
                    .padding(.top, BojiLayout.inline)

                if currentSlide < totalSlides - 1 {
                    Text("功能演示 · 示例数据，不是你的实际记录")
                        .bojiType(.caption).foregroundStyle(BojiColor.textSecondary)
                        .padding(.top, BojiLayout.inline)
                }
                // Slide carousel
                TabView(selection: $currentSlide) {
                    scrollableSlide { WalkthroughAICoachSlide() }.tag(0)

                    scrollableSlide { WalkthroughWorkoutSetsSlide() }.tag(1)

                    scrollableSlide { WalkthroughNutritionEvolutionSlide() }.tag(2)

                    scrollableSlide { WalkthroughReadinessSlide() }.tag(3)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(reduceMotion ? nil : BojiMotion2.celebrate, value: currentSlide)

                // Bottom Liquid Glass navigation & indicator dock
                bottomNavigationDock
                    .padding(.horizontal, BojiLayout.Rhythm.headerToContent)
                    .padding(.bottom, BojiLayout.inline)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(isDismissing ? 0 : 1)
        .accessibilityIdentifier("first-launch-walkthrough")
        .animation(BojiMotion2.transition, value: isDismissing)
        .onAppear {
            currentSlide = initialSlide

        }
    }

    private func scrollableSlide<Content: View>(@ViewBuilder content: @escaping () -> Content) -> some View {
        GeometryReader { geometry in
            ScrollView {
                content().frame(maxWidth: .infinity).frame(minHeight: geometry.size.height)
                    .padding(.vertical, BojiLayout.rowGap)
            }
        }
    }

    // MARK: - Top Utility Bar

    private var topUtilityBar: some View {
        HStack {
            Spacer()

            if currentSlide < totalSlides - 1 {
                Button {
                    BojiHaptics.selection()
                    finishWalkthrough()
                } label: {
                    Text("跳过")
                        .bojiType(.secondary)
                        .foregroundStyle(BojiColor.textSecondary)
                        .padding(.horizontal, BojiLayout.rowGap)
                        .padding(.vertical, BojiLayout.inline)
                        .background(BojiColor.subtleSurface, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("跳过引导")
            }
        }
    }

    // MARK: - Bottom Navigation Dock

    private var bottomNavigationDock: some View {
        HStack(spacing: BojiLayout.cardInset) {
            // Fluid page indicator dots
            HStack(spacing: BojiLayout.tight) {
                ForEach(0..<totalSlides, id: \.self) { index in
                    Capsule()
                        .fill(index == currentSlide ? BojiColor.textPrimary : BojiColor.outline.opacity(0.6))
                        .frame(width: index == currentSlide ? 22 : 6, height: 6)
                        .animation(reduceMotion ? nil : BojiMotion2.transition, value: currentSlide)
                        .onTapGesture {
                            BojiHaptics.tick()
                            withAnimation { currentSlide = index }
                        }
                }
            }
            .padding(.horizontal, BojiLayout.rowGap)
            .padding(.vertical, BojiLayout.inline)
            .background(BojiColor.subtleSurface, in: Capsule())

            Spacer()

            // Dynamic action button
            if currentSlide < totalSlides - 1 {
                Button {
                    BojiHaptics.tick()
                    withAnimation {
                        currentSlide = min(totalSlides - 1, currentSlide + 1)
                    }
                } label: {
                    HStack(spacing: BojiLayout.tight) {
                        Text("继续")
                            .bojiType(.body)
                        Image(systemName: "chevron.right")
                            .bojiType(.label)
                    }
                    .foregroundStyle(BojiColor.pageBackground)
                    .padding(.horizontal, BojiLayout.pageInset)
                    .padding(.vertical, BojiLayout.rowGap)
                    .background(BojiColor.textPrimary, in: Capsule())
                    .shadow(color: Color.black.opacity(0.18), radius: 8, y: 4)
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    finishWalkthrough()
                } label: {
                    HStack(spacing: BojiLayout.inline) {
                        Text("开始")
                            .bojiType(.body)
                        Image(systemName: "sparkles")
                            .bojiType(.secondary)
                    }
                    .foregroundStyle(BojiColor.pageBackground)
                    .padding(.horizontal, BojiLayout.Rhythm.headerToContent)
                    .padding(.vertical, BojiLayout.rowGap)
                    .background(BojiColor.textPrimary, in: Capsule())
                    .shadow(color: Color.black.opacity(0.24), radius: 10, y: 4)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func finishWalkthrough() {
        guard !isDismissing else { return }
        BojiHaptics.success()
        hasCompletedWalkthrough = true
        withAnimation(BojiMotion2.state) {
            isDismissing = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
            isPresented = false
        }
    }
}

// MARK: - Slide 1: Club AI · 为你定制

private struct WalkthroughAICoachSlide: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragOffset: CGSize = .zero
    @State private var isBreathing: Bool = false

    var body: some View {
        VStack(spacing: BojiLayout.sectionGap) {
            Spacer()

            // 3D Floating Crystal Sphere with Ambient Halos
            ZStack {
                // Layer 1: Ambient breathing glow（品牌色软光 + 系统模糊）
                Circle()
                    .fill(BojiColor.brandMist.opacity(isBreathing ? 0.30 : 0.18))
                    .blur(radius: 60)
                    .frame(width: 260, height: 260)
                    .scaleEffect(isBreathing ? 1.08 : 0.95)
                    .animation(reduceMotion ? nil : BojiMotion2.celebrate.repeatForever(autoreverses: true), value: isBreathing)

                // Layer 2: Orbit ring（静态细环，去手绘旋转渐变）
                Circle()
                    .stroke(BojiColor.brandMist.opacity(0.45), lineWidth: 1.5)
                    .frame(width: 190, height: 190)

                // Layer 3: Central crystal sphere（原生玻璃 + SF Symbols）
                ZStack {
                    Circle()
                        .fill(BojiColor.brandMist.opacity(0.18))
                        .frame(width: 130, height: 130)
                        .clubGlassEffect(in: Circle())
                        .overlay {
                            Circle().stroke(Color.white.opacity(0.35), lineWidth: 1)
                        }
                        .shadow(color: BojiColor.brandMist.opacity(0.35), radius: 24, y: 10)

                    // Core AI glyph
                    Image(systemName: "sparkles")
                        .font(.system(size: 44))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color.white, BojiColor.brandMist],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .shadow(color: Color.white.opacity(0.6), radius: 10)
                }
                .rotation3DEffect(
                    .degrees(Double(dragOffset.width) / 8),
                    axis: (x: 0, y: 1, z: 0)
                )
                .rotation3DEffect(
                    .degrees(-Double(dragOffset.height) / 8),
                    axis: (x: 1, y: 0, z: 0)
                )
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            dragOffset = value.translation
                        }
                        .onEnded { _ in
                            withAnimation(BojiMotion2.celebrate) {
                                dragOffset = .zero
                            }
                            BojiHaptics.tick()
                        }
                )

                // Floating glass feature satellites
                satellitePill(icon: "bolt.fill", title: "训练计划建议", offset: CGSize(width: -95, height: -80))
                satellitePill(icon: "waveform.path.ecg", title: "训练感受记录", offset: CGSize(width: 105, height: -30))
                satellitePill(icon: "bubble.left.and.bubble.right.fill", title: "对话训练助手", offset: CGSize(width: -80, height: 85))
            }
            .frame(height: 280)

            // Text presentation
            VStack(spacing: BojiLayout.inline) {
                Text("按你的身体来")
                    .bojiType(.display)
                    .foregroundStyle(BojiColor.textPrimary)

                Text("建议只看你真记下来的")
                    .bojiType(.body)
                    .foregroundStyle(BojiColor.textSecondary)
                    .multilineTextAlignment(.center)
            }

            Spacer()
        }
        .onAppear {
            isBreathing = true
        }
    }

    private func satellitePill(icon: String, title: String, offset: CGSize) -> some View {
        HStack(spacing: BojiLayout.tight) {
            Image(systemName: icon)
                .bojiType(.caption)
                .foregroundStyle(BojiColor.brandAccent)
            Text(title)
                .bojiType(.caption)
                .foregroundStyle(BojiColor.textPrimary)
        }
        .padding(.horizontal, BojiLayout.inline)
        .padding(.vertical, BojiLayout.tight)
        .background(BojiColor.cardSurface, in: Capsule())
        .overlay { Capsule().stroke(BojiColor.outline, lineWidth: 0.5) }
        .offset(offset)
        .shadow(color: Color.black.opacity(0.12), radius: 6, y: 3)
    }
}

// MARK: - Slide 2: 逐组打卡 · 毫秒级掌控

private struct WalkthroughWorkoutSetsSlide: View {
    @State private var restSecondsRemaining: Int = 45
    @State private var isResting: Bool = true
    @State private var totalRest: Int = 90
    @State private var isPressingPlus: Bool = false

    var body: some View {
        VStack(spacing: BojiLayout.sectionGap) {
            Spacer()

            // Interactive Floating Liquid Glass Rest Timer Dock
            VStack(spacing: BojiLayout.cardInset) {
                // Exercise label
                HStack(spacing: BojiLayout.inline) {
                    Circle()
                        .fill(BojiColor.brandAccent)
                        .frame(width: 8, height: 8)
                    Text("当前训练 · 杠铃卧推")
                        .bojiType(.label)
                        .foregroundStyle(BojiColor.textSecondary)
                    Spacer()
                    Text("第 3 / 4 组")
                        .bojiType(.caption)
                        .foregroundStyle(BojiColor.textTertiary)
                }
                .padding(.horizontal, BojiLayout.tight)

                // Big Timer Dial Container
                ZStack {
                    // Background circle track
                    Circle()
                        .stroke(BojiColor.outline.opacity(0.4), lineWidth: 8)

                    // Progress ring
                    Circle()
                        .trim(from: 0, to: CGFloat(restSecondsRemaining) / CGFloat(totalRest))
                        .stroke(
                            LinearGradient(
                                colors: [BojiColor.brandMist, BojiColor.textPrimary],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            style: StrokeStyle(lineWidth: 8, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                        .animation(BojiMotion2.progress, value: restSecondsRemaining)

                    // Countdown numbers
                    VStack(spacing: BojiLayout.tight) {
                        Text(String(format: "%02d:%02d", restSecondsRemaining / 60, restSecondsRemaining % 60))
                            .bojiType(.hero)
                            .foregroundStyle(BojiColor.textPrimary)

                        Text("组间休息中")
                            .bojiType(.caption)
                            .foregroundStyle(BojiColor.textTertiary)
                    }
                }
                .frame(width: 170, height: 170)
                .padding(.vertical, BojiLayout.inline)

                // Interactive Quick Adjustment Bar
                HStack(spacing: BojiLayout.rowGap) {
                    Button {
                            BojiHaptics.tick()
                        restSecondsRemaining += 15
                        totalRest += 15
                    } label: {
                        HStack(spacing: BojiLayout.tight) {
                            Image(systemName: "plus")
                                .bojiType(.caption)
                            Text("15 秒")
                                .bojiType(.label)
                        }
                        .foregroundStyle(BojiColor.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, BojiLayout.inline)
                        .background(BojiColor.subtleSurface, in: Capsule())
                        .overlay { Capsule().stroke(BojiColor.outline, lineWidth: 0.5) }
                    }
                    .buttonStyle(.plain)

                    Button {
                        AudioServicesPlaySystemSound(1104)
                        BojiHaptics.success()
                        restSecondsRemaining = 0
                    } label: {
                        Text("完成休息")
                            .bojiType(.label)
                            .foregroundStyle(Color.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, BojiLayout.inline)
                            .background(BojiColor.textPrimary, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(BojiLayout.blockGap)
            .clubGlassEffect(in: RoundedRectangle(cornerRadius: BojiRadius.hero, style: .continuous))
            .shadow(color: Color.black.opacity(0.12), radius: 16, y: 8)
            .padding(.horizontal, BojiLayout.sectionGap)

            // Text presentation
            VStack(spacing: BojiLayout.inline) {
                Text("休息你说了算")
                    .bojiType(.display)
                    .foregroundStyle(BojiColor.textPrimary)

                Text("组间休息随时调，每组练完自己确认")
                    .bojiType(.body)
                    .foregroundStyle(BojiColor.textSecondary)
                    .multilineTextAlignment(.center)
            }

            Spacer()
        }
        .task {
            // Subtle countdown demo loop
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if restSecondsRemaining > 0 {
                    restSecondsRemaining -= 1
                } else {
                    restSecondsRemaining = 45
                }
            }
        }
    }
}

// MARK: - Slide 3: 营养与体征 · 看见进化的轨迹

private struct WalkthroughNutritionEvolutionSlide: View {
    @State private var showingDetails: Bool = false

    var body: some View {
        VStack(spacing: BojiLayout.sectionGap) {
            Spacer()

            // Concentric Macro Rings & Body Evolution Dial
            ZStack {
                VStack(spacing: BojiLayout.cardInset) {
                    // Concentric rings hero
                    ZStack {
                        // Outer Ring: Calorie (Amber)
                        Circle()
                            .stroke(Color.orange.opacity(0.15), lineWidth: 10)
                            .frame(width: 170, height: 170)
                        Circle()
                            .trim(from: 0, to: 0.82)
                            .stroke(
                                LinearGradient(colors: [Color.orange, Color.yellow], startPoint: .topLeading, endPoint: .bottomTrailing),
                                style: StrokeStyle(lineWidth: 10, lineCap: .round)
                            )
                            .frame(width: 170, height: 170)
                            .rotationEffect(.degrees(-90))

                        // Middle Ring: Protein (Cyan/Mist)
                        Circle()
                            .stroke(BojiColor.brandMist.opacity(0.4), lineWidth: 10)
                            .frame(width: 136, height: 136)
                        Circle()
                            .trim(from: 0, to: 0.94)
                            .stroke(
                                LinearGradient(colors: [BojiColor.brandAccent, BojiColor.brandMist], startPoint: .topLeading, endPoint: .bottomTrailing),
                                style: StrokeStyle(lineWidth: 10, lineCap: .round)
                            )
                            .frame(width: 136, height: 136)
                            .rotationEffect(.degrees(-90))

                        // Inner Ring: Clean Carbs (Emerald)
                        Circle()
                            .stroke(Color.green.opacity(0.15), lineWidth: 10)
                            .frame(width: 102, height: 102)
                        Circle()
                            .trim(from: 0, to: 0.70)
                            .stroke(
                                LinearGradient(colors: [Color.green, Color.mint], startPoint: .topLeading, endPoint: .bottomTrailing),
                                style: StrokeStyle(lineWidth: 10, lineCap: .round)
                            )
                            .frame(width: 102, height: 102)
                            .rotationEffect(.degrees(-90))

                        // Center Icon
                        Image(systemName: "flame.fill")
                            .bojiType(.title)
                            .foregroundStyle(Color.orange)
                    }
                    .frame(height: 180)

                    // Stats summary pills
                    HStack(spacing: BojiLayout.rowGap) {
                        nutrientStatPill(title: "热量", value: "2,450", unit: "kcal", color: .orange)
                        nutrientStatPill(title: "蛋白质", value: "165", unit: "g", color: BojiColor.brandAccent)
                        nutrientStatPill(title: "碳水", value: "210", unit: "g", color: .green)
                    }

                    // Floating transformation badge
                    HStack(spacing: BojiLayout.rowGap) {
                        HStack(spacing: BojiLayout.tight) {
                            Image(systemName: "arrow.up.right")
                                .bojiType(.caption)
                                .foregroundStyle(Color.green)
                            Text("骨骼肌 +1.8 kg")
                                .bojiType(.caption)
                                .foregroundStyle(BojiColor.textPrimary)
                        }

                        Divider().frame(height: 12)

                        HStack(spacing: BojiLayout.tight) {
                            Image(systemName: "arrow.down.right")
                                .bojiType(.caption)
                                .foregroundStyle(BojiColor.brandAccent)
                            Text("体脂率 -2.4%")
                                .bojiType(.caption)
                                .foregroundStyle(BojiColor.textPrimary)
                        }
                    }
                    .padding(.horizontal, BojiLayout.rowGap)
                    .padding(.vertical, BojiLayout.inline)
                    .background(BojiColor.subtleSurface, in: Capsule())
                }
                .padding(BojiLayout.blockGap)
                .background(BojiColor.cardSurface, in: RoundedRectangle(cornerRadius: BojiRadius.hero, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: BojiRadius.hero, style: .continuous)
                        .stroke(BojiColor.outline, lineWidth: 0.5)
                }
                .shadow(color: Color.black.opacity(0.12), radius: 16, y: 8)
                .padding(.horizontal, BojiLayout.sectionGap)
            }

            // Text presentation
            VStack(spacing: BojiLayout.inline) {
                Text("变化看得见")
                    .bojiType(.display)
                    .foregroundStyle(BojiColor.textPrimary)

                Text("只看蛋白质、碳水和脂肪")
                    .bojiType(.body)
                    .foregroundStyle(BojiColor.textSecondary)
                    .multilineTextAlignment(.center)
            }

            Spacer()
        }
    }

    private func nutrientStatPill(title: String, value: String, unit: String, color: Color) -> some View {
        VStack(spacing: 0) {
            Text(title)
                .bojiType(.caption)
                .foregroundStyle(BojiColor.textTertiary)
            HStack(spacing: 0) {
                Text(value)
                    .bojiType(.label)
                    .foregroundStyle(color)
                Text(unit)
                    .bojiType(.caption)
                    .foregroundStyle(BojiColor.textTertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, BojiLayout.tight)
        .background(BojiColor.cardSurface.opacity(0.6), in: RoundedRectangle(cornerRadius: BojiRadius.thumb, style: .continuous))
    }
}

// MARK: - Slide 4: 开启最佳体验 (One-Stop Readiness & Permissions)

private struct WalkthroughReadinessSlide: View {
    @EnvironmentObject private var account: AccountService
    @Environment(\.dynamicTypeSize) private var typeSize
    @EnvironmentObject private var health: HealthDataService
    @EnvironmentObject private var notifications: AppNotificationService

    @State private var healthConnecting: Bool = false
    private var notificationsAuthorized: Bool {
        [.authorized, .provisional, .ephemeral].contains(notifications.authorizationStatus)
    }

    var body: some View {
        VStack(spacing: BojiLayout.blockGap) {
            Spacer()

            // Header
            VStack(spacing: BojiLayout.inline) {
                Text("都好了")
                    .bojiType(.display)
                    .foregroundStyle(BojiColor.textPrimary)

                Text("点一下就进去")
                    .bojiType(.body)
                    .foregroundStyle(BojiColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, BojiLayout.Rhythm.headerToContent)
            }

            // 3 Experience Cards
            VStack(spacing: BojiLayout.rowGap) {
                // Card 1: Apple HealthKit
                readinessCard(
                    icon: "heart.fill",
                    iconColor: Color.red,
                    title: "Apple 健康",
                    subtitle: account.user == nil ? "登录后可连接；读取权限由你在系统中选择。" : "读取所选健康数据；写入训练需另行确认。",
                    isDone: health.enabled,
                    isLoading: healthConnecting,
                    actionTitle: account.user == nil ? "登录后设置" : health.enabled ? "已设置" : "连接健康",
                    action: {
                        guard account.user != nil, !health.enabled else { return }
                        Task {
                            healthConnecting = true
                            await health.connect(on: Date())
                            healthConnecting = false
                            if health.enabled { BojiHaptics.success() }
                        }
                    }
                )
                if let message = health.message {
                    Text(message).bojiType(.caption).foregroundStyle(BojiColor.textSecondary)
                }
                Text("设好了不等于给了权限。这里只显示系统真的允许我们读的数据，之后在设置里还能调。")
                    .bojiType(.caption).foregroundStyle(BojiColor.textSecondary)

                // Card 2: Push Notifications
                readinessCard(
                    icon: "bell.badge.fill",
                    iconColor: Color.orange,
                    title: "智能节奏提醒",
                    subtitle: "用于休息结束及训练日提醒，可稍后设置。",
                    isDone: notificationsAuthorized,
                    isLoading: false,
                    actionTitle: notificationsAuthorized ? "已允许" : "允许通知",
                    action: {
                        guard !notificationsAuthorized else { return }
                        Task {
                            await notifications.requestAuthorization()
                            if notificationsAuthorized { BojiHaptics.success() }
                        }
                    }
                )
            }
            .padding(.horizontal, BojiLayout.Rhythm.headerToContent)

            Spacer()
        }
        .task { await notifications.refreshAuthorizationStatus() }
    }

    private func readinessCard(
        icon: String,
        iconColor: Color,
        title: String,
        subtitle: String,
        isDone: Bool,
        isLoading: Bool,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: BojiLayout.rowGap)) : AnyLayout(HStackLayout(spacing: BojiLayout.rowGap))
        return layout {
            // Icon container
            ZStack {
                Circle()
                    .fill(iconColor.opacity(0.12))
                    .frame(width: 44, height: 44)

                Image(systemName: icon)
                    .bojiType(.body)
                    .foregroundStyle(iconColor)
            }

            // Info
            VStack(alignment: .leading, spacing: BojiLayout.tight) {
                Text(title)
                    .bojiType(.body)
                    .foregroundStyle(BojiColor.textPrimary)

                Text(subtitle)
                    .bojiType(.caption)
                    .foregroundStyle(BojiColor.textTertiary)
                    .lineLimit(2)
            }

            Spacer(minLength: 4)

            // Button / Status Pill
            Button {
                action()
            } label: {
                HStack(spacing: BojiLayout.tight) {
                    if isLoading {
                        ProgressView()
                            .scaleEffect(0.7)
                    } else if isDone {
                        Image(systemName: "checkmark")
                            .bojiType(.caption)
                            .foregroundStyle(Color.green)
                    }
                    Text(actionTitle)
                        .bojiType(.caption)
                        .foregroundStyle(isDone ? Color.green : BojiColor.textPrimary)
                }
                .padding(.horizontal, BojiLayout.rowGap)
                .padding(.vertical, BojiLayout.inline)
                .background(
                    isDone ? Color.green.opacity(0.12) : BojiColor.cardSurface,
                    in: Capsule()
                )
                .overlay {
                    if isDone {
                        Capsule().stroke(Color.green.opacity(0.3), lineWidth: 0.5)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(isLoading || isDone)
        }
        .padding(BojiLayout.rowGap)
        .background(BojiColor.cardSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(BojiColor.outline, lineWidth: 0.5)
        }
    }
}

// MARK: - Atmospheric Background

private struct WalkthroughAtmosphereBackdrop: View {
    let activeSlide: Int
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            // Base background
            (colorScheme == .dark ? Color(red: 10/255, green: 13/255, blue: 18/255) : Color(red: 245/255, green: 247/255, blue: 250/255))
                .ignoresSafeArea()

            // Soft glowing organic orbs
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height

                Circle()
                    .fill(BojiColor.brandMist.opacity(colorScheme == .dark ? 0.18 : 0.45))
                    .blur(radius: 80)
                    .frame(width: 440, height: 440)
                    .offset(x: activeSlide % 2 == 0 ? -60 : w - 380, y: activeSlide < 2 ? 60 : h - 480)
                    .animation(reduceMotion ? nil : BojiMotion2.celebrate, value: activeSlide)

                Circle()
                    .fill(BojiColor.brandAccent.opacity(colorScheme == .dark ? 0.10 : 0.25))
                    .blur(radius: 70)
                    .frame(width: 360, height: 360)
                    .offset(x: activeSlide % 2 == 0 ? w - 300 : -40, y: activeSlide < 2 ? h - 380 : 100)
                    .animation(reduceMotion ? nil : BojiMotion2.celebrate, value: activeSlide)
            }
        }
    }
}
