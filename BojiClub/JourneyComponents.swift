import SwiftUI

struct ClubIconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(minWidth: ClubUI.minimumTap, minHeight: ClubUI.minimumTap)
            .contentShape(Rectangle())
            .opacity(enabled ? (configuration.isPressed ? 0.72 : 1) : 0.42)
            .scaleEffect(configuration.isPressed && enabled && !reduceMotion ? 0.96 : 1)
            .animation(reduceMotion ? nil : BojiMotion2.state, value: configuration.isPressed)
            .sensoryFeedback(.selection, trigger: configuration.isPressed) { _, pressed in pressed && enabled }
    }
}

struct ClubLogoutButton: View {
    @EnvironmentObject private var account: AccountService
    @EnvironmentObject private var store: AppStore
    @State private var confirming = false
    @State private var loggingOut = false
    @State private var confirmingAccountID: Int?
    var body: some View {
        Button(loggingOut ? "正在退出…" : "退出登录", role: .destructive) {
            guard let id = account.user?.id else { return }
            confirmingAccountID = id; confirming = true
        }
            .buttonStyle(DestructiveButton()).disabled(loggingOut)
            .confirmationDialog("退出当前账号？", isPresented: $confirming, titleVisibility: .visible) {
                Button("退出登录", role: .destructive) {
                    guard !loggingOut, confirmingAccountID != nil, confirmingAccountID == account.user?.id else { return }
                    loggingOut = true
                    Task { await account.logout(); loggingOut = false }
                }
                Button("继续使用", role: .cancel) { }
            } message: {
                Text("当前同步状态：\(store.syncStatus.label)。记录会保留在本机，重新登录同一账号后可以继续同步；退出登录不会注销账号。")
            }
            .onChange(of: account.user?.id) { _, _ in confirming = false; confirmingAccountID = nil }
    }
}

enum ClubButtonKind: Equatable { case primary, secondary, row, destructive }

struct ClubActionButtonStyle: PrimitiveButtonStyle {
    @Environment(\.clubManagementSurface132) private var management
    var kind: ClubButtonKind = .secondary
    var size: ControlSize = .regular
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @ViewBuilder func makeBody(configuration: Configuration) -> some View {
        if management {
            Button(role: configuration.role, action: configuration.trigger) { configuration.label }
                .buttonStyle(.borderless)
                .foregroundStyle(kind == .destructive || configuration.role == .destructive ? Color.red : Color.primary)
        } else if kind == .row {
            Button(role: configuration.role, action: configuration.trigger) {
                configuration.label.frame(maxWidth: .infinity, minHeight: ClubUI.minimumTap, alignment: .leading)
                    .contentShape(Rectangle())
            }
                .buttonStyle(.plain)
        } else if kind == .primary {
            if #available(iOS 26.0, *), !reduceTransparency, contrast != .increased {
                Button(role: configuration.role, action: configuration.trigger) {
                    configuration.label.frame(maxWidth: .infinity)
                }
                    .buttonStyle(.glassProminent)
                    .tint(BojiColor.textPrimary)
                    .foregroundStyle(BojiColor.pageBackground)
                    .buttonBorderShape(.capsule)
                    .controlSize(size)
            } else {
                Button(role: configuration.role, action: configuration.trigger) {
                    configuration.label.frame(maxWidth: .infinity)
                }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(size)
                    .tint(BojiColor.textPrimary)
                    .foregroundStyle(BojiColor.pageBackground)
            }
        } else {
            if #available(iOS 26.0, *), !reduceTransparency, contrast != .increased {
                Button(configuration)
                    .frame(minHeight: ClubUI.minimumTap)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    .controlSize(size)
                    .tint(kind == .destructive || configuration.role == .destructive ? .red : ClubBrand.accent)
            } else {
                Button(configuration)
                    .frame(minHeight: ClubUI.minimumTap)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(size)
                    .tint(kind == .destructive || configuration.role == .destructive ? .red : ClubBrand.accent)
            }
        }
    }
}

struct DestructiveButton: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ClubActionButtonStyle(kind: .destructive).makeBody(configuration: configuration)
    }
}

struct SecondaryButton: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ClubActionButtonStyle(kind: .secondary).makeBody(configuration: configuration)
    }
}

struct ClubSelectionButtonStyle: PrimitiveButtonStyle {
    let selected: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @ViewBuilder func makeBody(configuration: Configuration) -> some View {
        if #available(iOS 26.0, *), !reduceTransparency, contrast != .increased {
            if selected { native(configuration).buttonStyle(.glassProminent) }
            else { native(configuration).buttonStyle(.glass) }
        } else {
            if selected { native(configuration).buttonStyle(.borderedProminent) }
            else { native(configuration).buttonStyle(.bordered) }
        }
    }
    private func native(_ configuration: Configuration) -> some View {
        Button(configuration).buttonBorderShape(.capsule).controlSize(.regular)
            .tint(ClubBrand.accent).frame(minHeight: 44)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct ClubOptionRow: View {
    let title: String
    var detail: String? = nil
    let selected: Bool
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Button(action: action) {
            HStack(spacing: BojiLayout.rowGap) {
                VStack(alignment: .leading, spacing: BojiLayout.tight) {
                    Text(title).bojiType(.secondary)
                    if let detail { Text(detail).bojiType(.label).opacity(selected ? 1 : 0.72) }
                }
                Spacer(minLength: 8)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .bojiType(.section).opacity(selected ? 1 : 0.35)
            }.frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                .padding(BojiSpace.general)
                .foregroundStyle(selected ? ClubBrand.onAccent : .primary)
                .background(selected ? ClubBrand.accent : BojiColor.cardSurface, in: RoundedRectangle(cornerRadius: ClubUI.controlRadius))
                .contentShape(Rectangle())
                .animation(reduceMotion ? nil : BojiMotion2.state, value: selected)
        }.buttonStyle(ClubMotionButton())
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct ClubRouteRow: View {
    let title: String
    let symbol: String
    var detail: String? = nil
    let action: () -> Void
    var body: some View {
        BojiEntryRow(title: title, symbol: symbol, detail: detail, action: action)
    }
}


@MainActor
struct ClubCalorieProgressView: View {
    let log: DayLog
    let target: NutritionTarget
    var isFuture = false
    var showsProteinReference = true
    private var progress: RecordedCalorieProgress {
        RecordedCalorieProgress(recorded: log.calories, upperBound: target.caloriesMax,
                                knownMeals: log.knownMeals.count, unknownMeals: log.unknownNutritionMeals)
    }
    private var tint: Color { progress.exceedsUpperBound ? .orange : .primary }
    private var status: String {
        if !progress.hasKnownIntake { return "还没有可统计的餐食" }
        if progress.exceedsUpperBound {
            return "已记录热量超出参考上限 \(progress.excess.formatted(.number.precision(.fractionLength(0)))) kcal"
        }
        if log.calories >= target.caloriesMin { return "已记录热量在参考范围内" }
        return "已记录占参考上限 \(progress.fraction.formatted(.percent.precision(.fractionLength(0))))"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: BojiLayout.inline) {
            Text("每日热量参考 \(target.caloriesMin.formatted(.number.precision(.fractionLength(0))))–\(target.caloriesMax.formatted(.number.precision(.fractionLength(0)))) kcal")
                .bojiType(.secondary).foregroundStyle(.secondary)
            if !isFuture, progress.hasValidTarget {
                ProgressView(value: progress.fraction, total: 1).tint(tint)
                    .accessibilityLabel("已记录热量与每日参考上限")
                    .accessibilityValue(status)
                Text(status).bojiType(.label).foregroundStyle(tint)
                Text(progress.isIncomplete ? "进度未包含 \(log.unknownNutritionMeals) 餐营养未知的记录。" : "仅按已记录餐食计算，不代表全天实际摄入。")
                    .bojiType(.label).foregroundStyle(.secondary)
            }
            if showsProteinReference {
                Text("蛋白质参考 \(target.proteinMin.formatted(.number.precision(.fractionLength(0))))–\(target.proteinMax.formatted(.number.precision(.fractionLength(0)))) g")
                    .bojiType(.label).foregroundStyle(.secondary)
            }
        }
    }
}

