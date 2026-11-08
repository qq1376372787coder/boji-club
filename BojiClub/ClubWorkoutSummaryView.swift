import SwiftUI

struct ClubWorkoutSummaryView: View {
    let date: Date
    let sessionID: UUID
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var ai: AIService
    @EnvironmentObject private var health: HealthDataService
    @Environment(\.dismiss) private var dismiss
    @State private var ownerID: Int?
    @State private var aiError: String?
    @State private var contextSource: ClubContextSource?
    @State private var showClubAI = false
    @State private var confirmHealthExport = false
    @State private var exportingWorkout = false
    @State private var healthExportMessage: String?
    @State private var healthWritten = false
    @State private var feedbackChoice = ""
    @State private var feedbackNote = ""
    @State private var feedbackSaved = false
    private var summary: ClubWorkoutSummary? { ClubWorkoutSummaryRules.make(state: store.state, date: date, sessionID: sessionID) }
    private var workoutJobID: String? {
        guard let owner = ownerID ?? store.editingAccountID, owner > 0 else { return nil }
        return ClubAutomaticReports.jobID(owner: owner, mode: "workout", key: sessionID.uuidString.lowercased())
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BojiLayout.blockGap) {
                if let summary {
                    heading(summary)
                    ClubCard {
                        Text("逐组实际记录").bojiType(.bodyStrong)
                        ForEach(summary.exercises) { exercise in
                            VStack(alignment: .leading, spacing: BojiLayout.inline) {
                                Text(exercise.name).bojiType(.secondary)
                                ForEach(Array(exercise.sets.enumerated()), id: \.element.id) { index, set in
                                    HStack {
                                        Text("第\(index+1)组").foregroundStyle(.secondary)
                                        Spacer()
                                        if set.validCompletion {
                                            Text(set.durationSeconds.map { "\($0) 秒" } ?? "\(set.weight.formatted()) kg × \(set.reps) 次")
                                        } else { Text("没完成 / 没记录").foregroundStyle(.secondary) }
                                    }.bojiType(.secondary)
                                }
                            }.padding(.vertical, BojiLayout.tight)
                        }
                    }
                    DisclosureGroup("与上次同动作比较") { comparisonCard(summary).padding(.top, BojiLayout.inline) }
                        .bojiType(.secondary)
                    DisclosureGroup("记录本次感受（可选）") { feedbackSection.padding(.top, BojiLayout.inline) }.bojiType(.secondary)
                    DisclosureGroup("查看开始时的目标") {
                        ClubCard {
                            ForEach(summary.exercises) { exercise in
                                Text(exercise.name).bojiType(.bodyStrong)
                                ForEach(Array(exercise.sets.enumerated()), id: \.element.id) { index, set in
                                    targetRow(index: index, set: set, exerciseID: exercise.id, summary: summary)
                                }
                            }
                        }.padding(.top, BojiLayout.inline)
                    }.bojiType(.secondary)
                } else {
                    EmptyNote(title: "本次总结暂不可用", detail: "这次训练可能已修改、尚未确认，或已没有有效完成组。请先核对实际记录。")
                }
                Text("基于这一天已确认的训练；历史对照只使用此前已确认的记录。")
                    .bojiType(.caption).foregroundStyle(BojiColor.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.padding(ClubUI.pageInset).frame(maxWidth: ClubUI.contentWidth).frame(maxWidth: .infinity)
        }.background { ClubBackground() }.navigationTitle("本次训练记录").navigationBarTitleDisplayMode(.inline)
            .onAppear {
                ownerID = store.editingAccountID
                if let ownerID, let saved = ClubWorkoutFeedbackStore.load(owner: ownerID, session: sessionID) {
                    feedbackChoice = saved.choice; feedbackNote = saved.note; feedbackSaved = true
                }
            }
            .onChange(of: store.editingAccountID) { _, value in if value != ownerID { dismiss() } }
            .sheet(item: $contextSource) { source in ContextAskView(source: source) }

    }

    private var feedbackSection: some View {
        ClubCard {
            Text("本次感受（可选）").bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
            Text("记录你的主观疲劳度与身体感受。")
                .bojiFont(.label).foregroundStyle(BojiColor.textSecondary)
            Picker("本次感受", selection: $feedbackChoice) {
                Text("未选择").tag("")
                Text("轻松").tag("轻松")
                Text("适中").tag("适中")
                Text("偏累").tag("偏累")
                Text("有不适").tag("有不适")
            }.pickerStyle(.segmented)
            TextField("补充说明（可选）", text: $feedbackNote, axis: .vertical)
                .lineLimit(2...4)
                .padding(BojiLayout.inline)
                .background(BojiColor.inputSurface, in: RoundedRectangle(cornerRadius: BojiRadius.input, style: .continuous))
            if feedbackChoice == "有不适" {
                Text("有疼痛、胸闷、眩晕等明显不适时请停止训练并寻求医疗评估；应用不会据此给出继续加量的建议。")
                    .bojiType(.label).foregroundStyle(.red)
            }
            Button(feedbackSaved ? "已保存本次感受" : "保存本次感受") {
                guard let ownerID else { return }
                let entry = ClubWorkoutFeedbackEntry(dateKey: ClubDates.key(date), choice: feedbackChoice, note: feedbackNote, savedAt: Date())
                ClubWorkoutFeedbackStore.save(entry, owner: ownerID, session: sessionID)
                feedbackSaved = true
            }.buttonStyle(SecondaryButton()).disabled(feedbackChoice.isEmpty)
        }
    }
    @ViewBuilder private func aiWorkoutSection(_ summary: ClubWorkoutSummary) -> some View {
        ClubCard {
            Button("在 Club AI 中复盘本次训练", systemImage: "sparkles") {
                guard let ownerID else { return }
                ClubAIEntryContext.open(owner: ownerID, date: date, sessionID: sessionID)
            }.buttonStyle(PrimaryButton())
            Text("带上这场已确认训练，直接对话并继续追问。")
                .bojiType(.label).foregroundStyle(.secondary)
        }
    }

    /// D1：对照 + 多次可比趋势合并为一张卡（截至本次训练日，不把后续训练混入）。
    @ViewBuilder private func comparisonCard(_ summary: ClubWorkoutSummary) -> some View {
        let identities: [String] = summary.exercises.compactMap { exercise in
            ClubExerciseIdentity.of(customID: exercise.customID, libraryID: exercise.libraryID, query: nil)
        }
        let trends = ClubTrendRules.trends(state: store.state,
                                           through: ClubDates.date(fromKey: summary.date) ?? Date())
            .filter { identities.contains($0.identity) }
        ClubCard {
            Text("与此前记录对照").bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
            if summary.comparisons.isEmpty {
                Text("这是该动作的首条基准记录，下次同重量训练时将同场对照。")
                    .bojiFont(.secondary).foregroundStyle(BojiColor.textSecondary)
            } else {
                ForEach(summary.comparisons) { comparison in
                    ClubWorkoutComparisonRow(comparison: comparison)
                    if comparison.id != summary.comparisons.last?.id { Divider().overlay(BojiColor.divider) }
                }
            }
            if !trends.isEmpty {
                Divider().overlay(BojiColor.divider)
                Text("多次可比训练趋势（截至本次）").bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
                Text("基于相同动作与负重的历史趋势对照。")
                    .bojiFont(.label).foregroundStyle(BojiColor.textSecondary)
                ForEach(trends) { trend in
                    VStack(alignment: .leading, spacing: BojiLayout.tight) {
                        HStack {
                            Text(trend.verdict).bojiFont(.exerciseName)
                                .foregroundStyle(trend.verdict == "样本不足" ? BojiColor.textTertiary : BojiColor.textPrimary)
                            Spacer()
                            Text("\(trend.sampleCount) 次记录").bojiFont(.label, monospacedDigits: true)
                                .foregroundStyle(BojiColor.textSecondary)
                        }
                        Text(trend.detail).bojiFont(.secondary).foregroundStyle(BojiColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }.padding(.vertical, BojiSpace.tight)
                    if trend.id != trends.last?.id { Divider().overlay(BojiColor.divider) }
                }
            }
        }
    }

    @ViewBuilder private var healthSection: some View {
        if let ownerID { ClubCard { WorkoutHealthSyncCard(date: date, sessionID: sessionID, ownerID: ownerID) } }
    }
    private func heading(_ summary: ClubWorkoutSummary) -> some View {
        let totalVolume = summary.exercises.flatMap(\.sets).filter(\.validCompletion).reduce(0.0) { $0 + $1.weight * Double($1.reps) }
        return ClubCard {
            BojiBrandSignature(size:24)
            Text("本次训练总结").bojiFont(.pageTitle).foregroundStyle(BojiColor.textPrimary)
            HStack(spacing: BojiLayout.cardInset) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("已确认完成").bojiType(.caption).foregroundStyle(BojiColor.textSecondary)
                    RollingNumericCounter(targetValue: Double(summary.completedSets), unit: "组")
                }
                if totalVolume > 0 {
                    Divider().frame(height: 28)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("累计负重训练量").bojiType(.caption).foregroundStyle(BojiColor.textSecondary)
                        RollingNumericCounter(targetValue: totalVolume, unit: "kg·次", precision: 1)
                    }
                }
            }
            .padding(.vertical, BojiLayout.tight)
            Text("\(summary.date) · 已确认 \(summary.completedSets) 组").bojiFont(.exerciseName, monospacedDigits: true).foregroundStyle(BojiColor.textSecondary)
            if summary.timedSeconds > 0 { Text("按秒动作累计 \(summary.timedSeconds) 秒，不含组间休息").bojiType(.secondary) }
            if let target = summary.targetSets, let completed = summary.originalCompletedSets {
                Text("开始时 \(target) 组目标，原组中已完成 \(completed) 组").bojiType(.secondary)
            }
            if let rest = summary.restSeconds {
                Text("开始时休息设置：\(rest == 0 ? "关闭自动休息" : "\(rest) 秒")；不代表实际休息时长。")
                    .bojiType(.label).foregroundStyle(.secondary)
            }
        }
    }
    private func targetRow(index: Int, set: TrainingSet, exerciseID: UUID, summary: ClubWorkoutSummary) -> some View {
        let original = summary.baseline?.sets.first { $0.id == set.id && $0.exerciseID == exerciseID }
        return VStack(alignment: .leading, spacing: BojiLayout.tight) {
            Text("第 \(index + 1) 组 · \(set.validCompletion ? "记完了" : "没记完")")
            if let original {
                Text("原目标：" + targetLabel(original)).foregroundStyle(.secondary)
            } else { Text("没有这组的开始目标快照").foregroundStyle(.secondary) }
            Text("当前记录：" + ClubPlanChangeRules.setLabel(AIPlanSet(weight: set.weight, reps: set.reps, durationSeconds: set.durationSeconds)))
                .foregroundStyle(.secondary)
        }.bojiType(.secondary)
    }
    private func targetLabel(_ target: WorkoutBaselineSet) -> String {
        if target.unit == "time" { return target.targetSeconds.map { "\($0) 秒" } ?? "时长未保存" }
        let reps = target.targetReps.map { "\($0) 次" } ?? "原次数未保存"
        let weight = target.targetWeight.map { $0 == 0 ? "自重或未设置重量" : "\($0.formatted()) kg" } ?? "原重量未保存"
        return reps + " · " + weight
    }
}

private struct ClubWorkoutComparisonRow: View {
    let comparison: ClubWorkoutComparison
    private var unit: String { comparison.unit == "time" ? "秒" : "次" }
    var body: some View {
        VStack(alignment: .leading, spacing: BojiLayout.inline) {
            Text(comparison.name).bojiFont(.exerciseName).foregroundStyle(BojiColor.textPrimary)
            if let weight = comparison.weight {
                Text(weight == 0 ? "同为 0 kg（自重或未设置重量）" : "同为 \(weight.formatted()) kg")
                    .bojiType(.secondary).foregroundStyle(.secondary)
            }
            Text("本次 \(comparison.currentSets) 组 · 合计 \(comparison.currentValue) \(unit)").bojiType(.secondary)
            Text("\(comparison.priorDate) · \(comparison.priorSets) 组 · 合计 \(comparison.priorValue) \(unit)")
                .bojiType(.secondary).foregroundStyle(.secondary)
            if comparison.comparable {
                let change = comparison.currentValue - comparison.priorValue
                Text("同样组数下，合计\(change == 0 ? "持平" : change > 0 ? "多 \(change) \(unit)" : "少 \(-change) \(unit)")")
                    .bojiType(.secondary)
            } else {
                Text("两次组数不同，仅陈列记录，不按合计值判断进退。")
                    .bojiType(.secondary).foregroundStyle(.secondary)
            }
        }.padding(.vertical, BojiSpace.tightRow)
    }
}
