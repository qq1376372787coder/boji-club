import SwiftUI
import CryptoKit

enum ClubAutomaticReports {
    static func jobID(owner: Int, mode: String, key: String) -> String {
        let hex = SHA256.hash(data: Data("club-auto-v1/\(owner)/\(mode)/\(key)".utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        let a = Array(hex)
        return [String(a[0..<8]),String(a[8..<12]),String(a[12..<16]),String(a[16..<20]),String(a[20..<32])].joined(separator: "-")
    }
    static func items(_ jobs: [AILocalJob], deleted: Set<String>) -> [AILocalJob] {
        jobs.filter { !deleted.contains($0.id) && $0.replacementID == nil && ["workout","weekly"].contains($0.result?.coach?.purpose ?? $0.request.payload["purpose"]?.string ?? "") }
            .sorted { $0.created > $1.created }
    }
}

#if DEBUG
struct ClubAutomaticReportList: View {
    @EnvironmentObject private var ai: AIService
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var ownerID: Int?
    private var jobs: [AILocalJob] { ClubAutomaticReports.items(ai.jobs, deleted: Set(store.state.deletedAIJobIDs ?? [])) }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                Text("记录之后，持续跟进").bojiFont(.pageTitle).foregroundStyle(BojiColor.textPrimary)
                Text("训练解读与周度记录报告保留各自日期依据；主观感受和参数修改仍由你确认。记录变化后，旧报告是当时的观察。")
                    .font(.subheadline).foregroundStyle(.secondary)
                if jobs.isEmpty { EmptyNote(title: "还没有自动跟进报告", detail: "在 Club AI 设置中开启。训练确认后可生成解读；完整记录周满足条件后生成周度报告。") }
                ForEach(jobs) { job in
                    NavigationLink { ClubAutomaticReportReader(jobID: job.id) } label: {
                        ClubCard {
                            Text(job.request.date).bojiFont(.exerciseName, monospacedDigits: true).foregroundStyle(BojiColor.textPrimary)
                            Text((job.result?.coach?.purpose ?? job.request.payload["purpose"]?.string) == "weekly" ? "每周记录成长报告" : "本次训练解读").font(.subheadline.weight(.medium))
                            Text(job.result?.coach?.answer ?? "正在核对已登记的记录，可进入查看处理状态").font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }.buttonStyle(ClubMotionButton())
                }
            }.padding(ClubUI.pageInset)
        }.background { ClubBackground() }.navigationTitle("自动跟进报告").navigationBarTitleDisplayMode(.inline)
            .onAppear { ownerID = store.editingAccountID }
            .onChange(of: store.editingAccountID) { _, id in if id != ownerID { dismiss() } }
    }
}
#endif

struct ClubAutomaticReportReader: View {
    let jobID: String
    @EnvironmentObject private var ai: AIService
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var account: AccountService
    @EnvironmentObject private var weekly: WeeklyReviewService
    @Environment(\.dismiss) private var dismiss
    @State private var ownerID: Int?
    @State private var proposalCurrent = false
    @State private var recovering = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let job = ai.job(jobID), let answer = job.result?.coach {
                    Text(job.request.date).bojiFont(.exerciseName, monospacedDigits: true).foregroundStyle(BojiColor.textPrimary)
                    BojiBrandMark(size:22,style:.monochrome)
                    Text(answer.answer).font(.body).lineSpacing(7).textSelection(.enabled)
                    Text("基于生成时已同步的记录；后续补记与修改请在最新分析中重新核对。").font(.footnote).foregroundStyle(.secondary)
                    DisclosureGroup("查看记录依据") {
                        ForEach(answer.sources) { source in
                            Text(source.detail).font(.subheadline).padding(.vertical, BojiSpace.tight)
                        }
                    }
                    if let proposal = answer.proposal {
                        ClubProposalCard(job: job, proposal: proposal, current: proposalCurrent)
                        if !proposalCurrent { Text("建议依据无法与当前记录完整对应，请重新提问核对后再调整。").font(.footnote).foregroundStyle(.secondary) }
                    }
                } else if ai.job(jobID) != nil {
                    AIJobStatusView(id: jobID, animated: true)
                } else if recovering {
                    AILoadingCard(title: "正在同步这份报告…", detail: "正在向账号核对任务，可以稍后回来查看。", status: "waiting_connection", compact: false)
                } else {
                    EmptyNote(title: "暂未找到这份报告", detail: "可能尚未同步，或这份报告已被移除。原训练与饮食记录仍保留。")
                    Button("重新同步报告") { Task { await recoverReport() } }.buttonStyle(SecondaryButton())
                }
            }.padding(ClubUI.pageInset)
        }.background { ClubBackground() }.navigationTitle("Club AI 跟进").navigationBarTitleDisplayMode(.inline)
            .onAppear { ownerID = store.editingAccountID; refreshProposal() }
            .task(id: jobID) { if ai.job(jobID) == nil { await recoverReport() } }
            .onReceive(store.$state) { _ in Task { @MainActor in await Task.yield(); refreshProposal() } }
            .onChange(of: ai.cloudChangeID) { _, _ in refreshProposal() }
            .onChange(of: store.editingAccountID) { _, id in if id != ownerID { dismiss() } }
    }
    private func recoverReport() async {
        guard !recovering, let owner = store.editingAccountID, owner == account.user?.id else { return }
        recovering = true
        defer { if store.editingAccountID == owner { recovering = false } }
        await ai.recoverTasks(account: account, weekly: weekly, store: store, targetID: jobID)
    }
    private func refreshProposal() {
        proposalCurrent = false
        guard ownerID != nil, ownerID == store.editingAccountID, let job = ai.job(jobID),
              let proposal = job.result?.coach?.proposal, let date = ClubDates.date(fromKey: job.request.date),
              ClubDates.key(date) == ClubDates.key(Date()), job.request.payload["days"] != nil,
              case .number(let span)? = job.request.payload["context_days"], [7.0,14.0].contains(span),
              proposal.baseline == ClubAdjustmentRules.upcoming(state: store.state, after: date) else { return }
        let session = job.result?.coach?.source_session.flatMap(UUID.init(uuidString:))
        let input = try? ai.coachInput(question: "核对建议依据", conversation: job.id, history: [], through: date, contextDays: Int(span), store: store, sessionID: session)
        proposalCurrent = input?.payload["days"] == job.request.payload["days"]
    }
}

struct ClubParameterChange: Codable, Equatable {
    let date: String
    let exercise: Int
    let setIndex: Int?
    let field: String
    let value: Double
    let reason: String
    enum CodingKeys: String, CodingKey { case date, exercise, field, value, reason; case setIndex = "set" }
}
struct ClubParameterProposal: Codable, Equatable {
    let version: Int
    let changes: [ClubParameterChange]
    let baseline: [AIPlanSession]
}

enum ClubAdjustmentRules {
    static func upcoming(state: SavedState, after date: Date) -> [AIPlanSession] {
        (1...7).compactMap { offset in
            guard let next = ClubDates.calendar.date(byAdding: .day, value: offset, to: date) else { return nil }
            let key = ClubDates.key(next); let day = state.days[key] ?? DayLog()
            guard !day.exercises.isEmpty, !PlanAdoptionRules.isProtected(day) else { return nil }
            return AIPlanSession(date: key, label: "训练安排", exercises: ClubPlanChangeRules.snapshot(day.exercises))
        }
    }
    static func draft(_ proposal: ClubParameterProposal, job: AILocalJob, selected: Set<Int>, state: SavedState, now: Date = Date()) throws -> ManualPlanDraft {
        guard proposal.version == 1, (1...6).contains(proposal.changes.count), !selected.isEmpty,
              selected.allSatisfy({ proposal.changes.indices.contains($0) }),
              let sourceDate = ClubDates.date(fromKey: job.request.date), ClubDates.key(sourceDate) == ClubDates.key(now),
              proposal.baseline == upcoming(state: state, after: sourceDate),
              let start = ClubDates.calendar.date(byAdding: .day, value: 1, to: sourceDate) else {
            throw ManualPlanError.message("建议依据或未来安排已有变化，请重新提问后再核对。")
        }
        var sessions = proposal.baseline; var seen = Set<String>()
        for index in selected.sorted() {
            let change = proposal.changes[index]
            guard change.value.isFinite, let day = sessions.firstIndex(where: { $0.date == change.date }),
                  sessions[day].exercises.indices.contains(change.exercise) else { throw ManualPlanError.message("建议中的动作已无法对应。") }
            let key = "\(change.date)/\(change.exercise)/\(change.setIndex ?? -1)/\(change.field)"
            guard seen.insert(key).inserted else { throw ManualPlanError.message("建议参数重复，请重新核对。") }
            if change.field == "rest_seconds" {
                guard change.setIndex == nil, change.value.rounded() == change.value, (0...3600).contains(change.value) else { throw ManualPlanError.message("休息参数不正确。") }
                sessions[day].exercises[change.exercise].rest_seconds = Int(change.value)
            } else {
                guard let group = change.setIndex, sessions[day].exercises[change.exercise].sets.indices.contains(group) else { throw ManualPlanError.message("建议中的训练组已无法对应。") }
                var target = sessions[day].exercises[change.exercise].sets[group]
                switch change.field {
                case "weight":
                    guard target.durationSeconds == nil, (0...RecordLimits.maximumWeight).contains(change.value), change.value <= (target.weight ?? 0) + max(2.5, (target.weight ?? 0) * 0.05) else { throw ManualPlanError.message("重量建议超出核对范围。") }
                    target.weight = change.value
                case "reps", "durationSeconds":
                    let timed = change.field == "durationSeconds"
                    let previous = timed ? target.durationSeconds ?? 0 : target.reps
                    let maximum = timed ? RecordLimits.maximumSeconds : RecordLimits.maximumReps
                    guard (target.durationSeconds != nil) == timed, change.value.rounded() == change.value, (1...Double(maximum)).contains(change.value), change.value <= Double(previous) * 1.2 + 1 else { throw ManualPlanError.message("目标建议超出核对范围。") }
                    if timed { target.durationSeconds = Int(change.value) } else { target.reps = Int(change.value) }
                default: throw ManualPlanError.message("当前版本不支持这类参数调整。")
                }
                sessions[day].exercises[change.exercise].sets[group] = target
            }
        }
        let result = AIResult(kind: "plan", notes: [], title: "Club AI 参数调整", sessions: sessions, plan_days: 7)
        var draft = try ManualPlanDraft.importing(result, originalStart: ClubDates.key(start), start: start)
        draft.proposalJobID = job.id
        draft.suggestedForProfile = state.profile.aiProfile
        return draft
    }
    static func description(_ change: ClubParameterChange, baseline: [AIPlanSession]) -> String {
        guard let day = baseline.first(where: { $0.date == change.date }), day.exercises.indices.contains(change.exercise) else { return "暂时无法对应的建议" }
        let movement = day.exercises[change.exercise]
        let group = change.setIndex.flatMap { movement.sets.indices.contains($0) ? movement.sets[$0] : nil }
        let old: String; let unit: String
        switch change.field {
        case "weight": old = (group?.weight ?? 0).formatted(); unit = "kg"
        case "reps": old = String(group?.reps ?? 0); unit = "次"
        case "durationSeconds": old = String(group?.durationSeconds ?? 0); unit = "秒"
        default: old = movement.rest_seconds.map { String($0) } ?? "训练默认值"; unit = "秒休息"
        }
        return "\(change.date) · \(movement.displayName)" + (change.setIndex.map { " · 第 \($0 + 1) 组" } ?? "") + "\n\(old) → \(change.value.formatted()) \(unit)"
    }
}

struct ClubProposalCard: View {
    let job: AILocalJob
    let proposal: ClubParameterProposal
    let current: Bool
    @EnvironmentObject private var store: AppStore
    @State private var selected = Set<Int>()
    @State private var showVersions = false
    @State private var draft: ManualPlanDraft?
    @State private var error: String?
    private var actionID: String { "coach-proposal-" + job.id }
    private var applied: Bool { store.hasAppliedAIJob("coach-plan-" + job.id) }
    private var rejected: Bool { store.actionState(actionID)?.isRejected == true }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("训练调整建议").bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
                Spacer()
                if rejected { Text("已拒绝").bojiFont(.label).foregroundStyle(BojiColor.textTertiary) }
            }
            Text("选择要调整的项目，再核对未来安排。确认保存后生效，历史计划和训练记录保留。")
                .font(.subheadline).foregroundStyle(.secondary)
            ForEach(Array(proposal.changes.enumerated()), id: \.offset) { index, change in
                Toggle(isOn: Binding(get: { selected.contains(index) }, set: { if $0 { selected.insert(index) } else { selected.remove(index) } })) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(ClubAdjustmentRules.description(change, baseline: proposal.baseline)).font(.subheadline.weight(.medium))
                        Text(change.reason).font(.footnote).foregroundStyle(.secondary)
                    }
                }.disabled(!current || applied || rejected)
            }
            Button(applied ? "查看调整后的训练" : "预览选中的调整") {
                if applied { showVersions = true; return }
                do { draft = try ClubAdjustmentRules.draft(proposal, job: job, selected: selected, state: store.state); error = nil }
                catch { self.error = AppErrorText.message(error) }
            }.buttonStyle(SecondaryButton()).disabled(!applied && (!current || selected.isEmpty || rejected))
            if !applied && !rejected {
                Button("忽略这项建议") {
                    if !store.recordActionState(id: actionID, state: ClubActionRecord.stateRejected, note: "用户不采用参数建议") {
                        error = store.takeMessage(fallback: "建议状态未能保存，请重试。")
                    }
                }.buttonStyle(SecondaryButton())
            }
            if let error { FlowError(message: error) }
        }.sheet(item: $draft) { ManualPlanView(initialDraft: $0) }
            .sheet(isPresented: $showVersions) { ClubPlanVersionsView() }
    }
}
