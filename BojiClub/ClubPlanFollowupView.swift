import SwiftUI

struct ClubPlanFollowupView: View {
    let version: ClubPlanVersion
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var ownerID: Int?
    @State private var report: ClubPlanFollowup?
    @State private var showReview = false
    private var cycle: TrainingCycle? {
        let today = ClubDates.key(Date())
        let cycles = TrainingCycle.available(days: store.state.days).filter {
            $0.start >= version.start && $0.end <= (version.scopeDates.max() ?? version.start)
        }
        return cycles.filter { $0.end <= today }.max { $0.end < $1.end } ?? cycles.min { $0.start < $1.start }
    }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: BojiLayout.cardInset) {
                if let report {
                    heading(report)
                    ClubCard {
                        Text("下一步怎么做").bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
                        Text(report.confirmedDays == 0 ? "完成训练后，这里会显示你的进度。" : "回顾训练感受，看看下周怎么安排。")
                            .bojiType(.secondary).foregroundStyle(.secondary)
                        Button("开始每周回顾") { showReview = true }.buttonStyle(SecondaryButton())
                    }
                    ForEach(report.days.filter { $0.date <= ClubDates.key(Date()) }) { day in ClubPlanFollowupDayCard(day: day) }
                    let upcoming = report.days.filter { $0.date > ClubDates.key(Date()) }
                    if !upcoming.isEmpty {
                        DisclosureGroup("后续安排 · \(upcoming.count) 天") {
                            ForEach(upcoming) { day in ClubPlanFollowupDayCard(day: day) }
                        }.bojiType(.secondary)
                    }
                    ClubCard {
                        Text("这些记录能说明什么").bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
                        Text("这里对比计划和实际完成情况；训练状态也会影响表现。")
                            .bojiType(.secondary).foregroundStyle(.secondary)
                        Text("无法对应的记录会留空。")
                            .bojiType(.label).foregroundStyle(.secondary)
                    }
                } else { Text("正在核对方案与已确认记录…").bojiType(.secondary).foregroundStyle(.secondary) }
            }.padding(ClubUI.pageInset).frame(maxWidth: ClubUI.contentWidth).frame(maxWidth: .infinity)
        }.background { ClubBackground() }.navigationTitle("方案执行跟进").navigationBarTitleDisplayMode(.inline)
            .onAppear { ownerID = store.editingAccountID; refresh() }
            .onReceive(store.$state) { _ in Task { @MainActor in await Task.yield(); refresh() } }
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in refresh() }
            .onChange(of: scenePhase) { _, phase in if phase == .active { refresh() } }
            .onChange(of: store.editingAccountID) { _, id in if id != ownerID { report = nil; dismiss() } }
            .sheet(isPresented: $showReview) { ClubAIEntryBridge(scope: .make(.rolling7, through: cycle.flatMap { ClubDates.date(fromKey: $0.end) } ?? Date())) }
    }
    private func refresh() {
        guard ownerID != nil, ownerID == store.editingAccountID else { return }
        report = ClubPlanFollowupRules.make(version: version, state: store.state)
    }
    private func heading(_ value: ClubPlanFollowup) -> some View {
        ClubCard {
            Text(version.title).bojiFont(.pageTitle).foregroundStyle(BojiColor.textPrimary)
            Text("\(version.start) 起 · 计划开始后的记录").bojiType(.secondary).foregroundStyle(.secondary)
            Text("\(value.confirmedDays) 个安排日已有可核对的确认记录").bojiFont(.exerciseName, monospacedDigits: true).foregroundStyle(BojiColor.textPrimary)
            if value.hasCompleteAdoptionSnapshot {
                Text("共安排 \(value.plannedDays) 个训练日。")
                    .bojiType(.secondary).foregroundStyle(.secondary)
            } else {
                Text("这份计划缺少部分安排，仍可查看已登记的训练。")
                    .bojiType(.secondary).foregroundStyle(.secondary)
            }
            Text(value.comparableItems == 0 ? "还没有可比较的同动作、同条件记录。" : "找到 \(value.comparableItems) 项与本方案开始前的同条件登记对照，可逐日查看。")
                .bojiType(.secondary)
            if store.state.profile.aiProfile != version.adoptedProfile {
                Text("你的资料有更新，可以看看计划是否还适合你。")
                    .bojiType(.label).foregroundStyle(.secondary)
            }
        }
    }
}

private struct ClubPlanFollowupDayCard: View {
    let day: ClubPlanFollowupDay
    var body: some View {
        ClubCard {
            Text(day.date).bojiFont(.exerciseName, monospacedDigits: true).foregroundStyle(BojiColor.textPrimary)
            Label(day.status.title, systemImage: day.status == .confirmed ? "checkmark.circle" : "info.circle")
                .bojiType(.secondary)
            Text(day.detail).bojiType(.secondary).foregroundStyle(.secondary)
            if let completed = day.completedOriginalSets, let achieved = day.achievedTargets {
                Text("原目标 \(day.targetSets) 组 · 原组已登记完成 \(completed) 组").bojiType(.secondary)
                Text("\(achieved) 组在相同登记重量下达到目标次数，或达到目标秒数。")
                    .bojiType(.secondary).foregroundStyle(.secondary)
                if let changed = day.changedLoadOrUnitSets, changed > 0 {
                    Text("\(changed) 组的安排有变化。")
                        .bojiType(.label).foregroundStyle(.secondary)
                }
            }
            if !day.comparisons.isEmpty {
                DisclosureGroup("与本方案开始前的登记对照") {
                    ForEach(day.comparisons) { comparison in
                        VStack(alignment: .leading, spacing: BojiLayout.tight) {
                            Text(comparison.name).bojiType(.secondary)
                            if let weight = comparison.weight { Text(weight == 0 ? "登记为自重或未设置重量" : "登记重量 \(weight.formatted()) kg").bojiType(.label) }
                            Text("本次 \(comparison.currentSets) 组，合计 \(comparison.currentValue) \(comparison.unit == "time" ? "秒" : "次")")
                            Text("\(comparison.priorDate) · \(comparison.priorSets) 组，合计 \(comparison.priorValue) \(comparison.unit == "time" ? "秒" : "次")")
                                .foregroundStyle(.secondary)
                        }.bojiType(.secondary).padding(.vertical, BojiSpace.tightRow)
                    }
                }.bojiType(.secondary)
            }
            if let session = day.sessionID, let date = ClubDates.date(fromKey: day.date) {
                NavigationLink("查看本次训练总结") { ClubWorkoutSummaryView(date: date, sessionID: session) }.buttonStyle(SecondaryButton())
            }
        }
    }
}
