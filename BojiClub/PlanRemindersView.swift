import SwiftUI

/// Translation is a separate text task. It never mutates the plan or its original notes.
struct PlanRemindersView: View {
    let notes: [String]
    let date: Date
    @EnvironmentObject private var ai: AIService
    @EnvironmentObject private var store: AppStore
    @State private var taskID: String?
    @State private var ownerID: Int?
    @State private var error: String?
    private var pending: [String] { notes.filter(PlanDisplayCopy.needsTranslation) }
    private var input: AIInput {
        AIInput(kind: "parse_plan", date: ClubDates.key(date),
            payload: ["operation": .string("notes_only"), "notes": .array(pending.map { .string($0) })])
    }
    private var job: AILocalJob? { ai.job(taskID) }
    private var translated: [String]? {
        guard let result = job?.result, job?.status == "succeeded", result.kind == "plan_notes",
              result.notes.count == pending.count, !result.notes.contains(where: PlanDisplayCopy.needsTranslation) else { return nil }
        return result.notes
    }
    private var busy: Bool { job.map { !$0.isTerminal && !$0.isWaiting } ?? false }
    var body: some View {
        VStack(alignment: .leading, spacing: BojiLayout.rowGap) {
            Label("给你的训练提醒", systemImage: "leaf").bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
            ForEach(Array(notes.enumerated()), id: \.offset) { index, note in
                if !PlanDisplayCopy.needsTranslation(note) {
                    Text(PlanDisplayCopy.text(note)).bojiType(.secondary).lineSpacing(4)
                } else if let translated {
                    let position = notes.prefix(index).filter(PlanDisplayCopy.needsTranslation).count
                    Text(translated[position]).bojiType(.secondary).lineSpacing(4)
                }
            }
            if !pending.isEmpty && translated == nil {
                Text("这份旧计划有 \(pending.count) 条提醒需要整理成中文。原提醒和训练安排都已保留。")
                    .bojiType(.secondary).foregroundStyle(.secondary)
                if busy && !ai.requiresRoutingConsent {
                    AILoadingCard(title: "正在整理训练提醒…", detail: "只整理文字，可以离开后回来查看。", status: job?.status)
                } else if !busy {
                    Button(job == nil ? "整理为中文" : "重试中文整理") { translate() }.buttonStyle(SecondaryButton())
                    Text("需要联网，使用一次文字处理；只发送这些提醒，不重新生成训练安排。")
                        .bojiType(.label).foregroundStyle(.secondary)
                }
            }
            if translated != nil { Text("请核对整理后的提醒；原文可以展开查看。").bojiType(.label).foregroundStyle(.secondary) }
            if !pending.isEmpty {
                DisclosureGroup("查看保留的原提醒") {
                    ForEach(Array(pending.enumerated()), id: \.offset) { _, original in
                        Text(original).bojiType(.label).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }.bojiType(.label)
            }
            if let text = error ?? job?.error { Text(text).bojiType(.label).foregroundStyle(.red) }
            if ai.requiresRoutingConsent && busy { AIRoutingConsentView() }
        }.onAppear {
            if ownerID == nil { ownerID = store.editingAccountID }
            if taskID == nil && !pending.isEmpty { taskID = ai.matching(input)?.id }
        }
        .onChange(of: notes) { _, _ in taskID = pending.isEmpty ? nil : ai.matching(input)?.id; error = nil }
        .onChange(of: store.editingAccountID) { _, id in if id != ownerID { taskID = nil; error = nil } }
    }
    private func translate() {
        guard ownerID != nil, ownerID == store.editingAccountID, !pending.isEmpty, !busy else { return }
        error = nil
        do {
            if let job, ["failed", "waiting_connection", "waiting_service"].contains(job.status) { ai.retry(job.id) }
            else { taskID = try ai.submit(input, forceNew: job?.status == "succeeded" && translated == nil) }
        } catch { self.error = AppErrorText.message(error) }
    }
}
