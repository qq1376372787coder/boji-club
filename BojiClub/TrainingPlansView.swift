import SwiftUI

private struct PlanDayStartRoute: Identifiable {
    let id = UUID()
    let date: Date
}

struct TrainingPlansView: View {
    let focusDate: Date
    var initialCycleStart: String? = nil
    var body: some View { ManagedPlanList(focusDate: focusDate, initialCycleStart: initialCycleStart) }
}

struct DismissButton: View {
    @Environment(\.clubPushed132) private var pushed
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        if !pushed { Button("关闭") { BojiHaptics.tick(); dismiss() } }
    }
}

struct TrainingHandoffCard: View {
    let cycle: TrainingCycle
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var weekly: WeeklyReviewService
    @State private var ownerID: Int?
    @State private var continuing = false
    @State private var reviewing = false
    @State private var adjustment: WeeklyReview?
    private var savedReview: WeeklyReview? {
        WeeklyVersions.visible(days: store.state.days, local: weekly.reviews,
            deletedJobIDs: Set(store.state.deletedAIJobIDs ?? []))
            .first { $0.date == cycle.end && $0.result != nil }
    }
    private var adjustmentTitle: String {
        if let review = savedReview, review.result?.decision == "adjust", !review.baseline.isEmpty,
           !store.hasAppliedAIJob("weekly/" + review.id.uuidString) { return "比较并确认调整建议" }
        return savedReview == nil ? "查看进度，开始本周复盘" : "查看本周复盘与建议"
    }
    var body: some View {
        ClubCard {
            HStack(spacing: 8) {
                Image(systemName: "arrow.right.circle.fill").foregroundStyle(ClubBrand.accent)
                Text("继续下一周").bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
            }
            Text(cycle.label).font(.footnote).foregroundStyle(.secondary)
            Text(TrainingHandoff.detail(cycle, days: store.state.days)).font(.subheadline).lineSpacing(4)
            HStack(spacing: 8) {
                Button("继续这套计划") { continuing = true }.buttonStyle(PrimaryButton())
                if let review = savedReview, review.result?.decision == "adjust", !review.baseline.isEmpty, !store.hasAppliedAIJob("weekly/" + review.id.uuidString) {
                    Button("查看调整建议") { openAdjustment() }.buttonStyle(SecondaryButton())
                }
            }
        }
        .clubReveal()
        .onAppear { if ownerID == nil { ownerID = store.editingAccountID } }
        .onChange(of: store.editingAccountID) { _, id in
            if id != ownerID { continuing = false; reviewing = false; adjustment = nil }
        }
        .sheet(isPresented: $continuing) { ContinueWeekView(endDate: ClubDates.date(fromKey: cycle.end) ?? Date(), initialCycle: cycle) }
        .sheet(isPresented: $reviewing) { ClubAIEntryBridge(scope: .make(.rolling7, through: ClubDates.date(fromKey: cycle.end) ?? Date())) }
        .sheet(item: $adjustment) { WeeklyPlanPreview(review: $0) }
    }
    private func openAdjustment() {
        guard ownerID != nil, ownerID == store.editingAccountID else { return }
        if let review = savedReview, review.result?.decision == "adjust", !review.baseline.isEmpty,
           !store.hasAppliedAIJob("weekly/" + review.id.uuidString) { adjustment = review }
        else { reviewing = true }
    }
}
