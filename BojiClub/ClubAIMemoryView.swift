import SwiftUI

// MARK: - Phase 4 §5.2：「AI 对我的了解」页（D-10 三栏 + 成员控制）
//
// 三栏映射：确认事实 = fact+goal+constraint；观察习惯 = habit+preference；
// 待确认推断 = correction（用户自己的纠正陈述）。
// 成员控制：纠错（supersedes 链）/ 暂停个性化 / 恢复 / 删除。预览账号与
// 未登录显示占位说明——本地预览路径没有服务端记忆。

struct ClubMemoryItem: Decodable, Equatable, Identifiable {
    let memoryId: String
    let kind: String
    let status: String
    let origin: String?
    let content: String
    let confidence: Int
    let evidenceRefs: [String]?
    let supersedes: String?
    let updatedAt: String?

    var id: String { memoryId }

    enum CodingKeys: String, CodingKey {
        case memoryId = "memory_id"
        case kind, status, origin, content, confidence
        case evidenceRefs = "evidence_refs"
        case supersedes
        case updatedAt = "updated_at"
    }

    var isSuspended: Bool { status == "suspended" }
    var isUserCorrected: Bool { origin == "user" }

    var kindLabel: String {
        switch kind {
        case "fact": return "事实"
        case "habit": return "习惯"
        case "preference": return "偏好"
        case "goal": return "目标"
        case "constraint": return "限制"
        case "correction": return "我的纠正"
        default: return kind
        }
    }
}

struct ClubMemoryPage: Decodable, Equatable {
    let confirmed: [ClubMemoryItem]
    let habits: [ClubMemoryItem]
    let inferred: [ClubMemoryItem]

    enum CodingKeys: String, CodingKey {
        case confirmed, habits, inferred
    }

    var isEmpty: Bool { confirmed.isEmpty && habits.isEmpty && inferred.isEmpty }
}

struct ClubMemoryResponse: Decodable {
    let columns: ClubMemoryPage
}

struct ClubAIMemoryView: View {
    @EnvironmentObject private var ai: AIService
    @EnvironmentObject private var account: AccountService
    @EnvironmentObject private var store: AppStore
    @State private var correctingItem: ClubMemoryItem?
    @State private var correctionText = ""
    @State private var deletingItem: ClubMemoryItem?
    @State private var mutating = false
    @State private var error: String?
    @StateObject private var factsEditor = ProfileFactsEditor()
    @State private var editingGroup132: ProfileEditSection126?
    @State private var editingFact: ProfileFactEditTarget?
    @State private var clearingFact: OnboardingFieldSpec?
    @State private var clearing = false

    var body: some View {
        List {

                ProfileKnowledgeCards126(editor: factsEditor, onEdit: { editingFact = $0 }, onClear: { clearingFact = $0 }, onEditGroup: { editingGroup132 = $0 })
                if account.isPreviewAccount || account.user?.id == nil {
                    previewNotice
                } else if let page = ai.memoryPage {
                    memorySection("观察到的习惯与偏好", page.habits, footer: "由已确认记录形成；你可以纠正或停止使用。")
                    memorySection("AI 的理解", page.confirmed, footer: "这里的理解以你上方确认的资料为准。")
                    if !page.inferred.isEmpty { memorySection("我的纠正", page.inferred, footer: "你明确纠正过的内容。") }
                    privacyFooter
                } else {
                    ClubCard {
                        Text("AI 的理解").font(.headline)
                        Text(ai.memoryError ?? "正在加载…").font(.subheadline).foregroundStyle(.secondary)
                        if ai.memoryError != nil { Button("重新加载") { Task { await ai.refreshMemoryPage(force: true) } } }
                    }
                }
                if let error { FlowError(message: error) }

        }.clubManagementList132()
        .background { ClubBackground() }
        .navigationTitle("AI 对我的了解")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("ai-memory-page")
        .task(id: account.user?.id) { await refreshFacts() }
        .onReceive(NotificationCenter.default.publisher(for:.profileFactsChanged133)) { note in if note.object as? Int == account.user?.id { Task { await refreshFacts() } } }
        .task(id: account.user?.id) { await ai.refreshMemoryPage() }
        .sheet(item: $editingGroup132, onDismiss: { Task { await refreshFacts(); await ai.refreshMemoryPage(force: true) } }) { section in ProfileFactsForm133(title:section.title,fields:section == .body ? ProfileFields133.body:ProfileFields133.training) }
        .sheet(item: $editingFact) { target in
            ProfileFactEditView(target: target, editor: factsEditor, account: account) {
                Task { await refreshFacts(); await ai.refreshMemoryPage(force: true) }
            }
        }
        .confirmationDialog("清空这项已确认资料？", isPresented: Binding(get: { clearingFact != nil }, set: { if !$0 { clearingFact = nil } }), titleVisibility: .visible) {
            Button("清空资料", role: .destructive) {
                guard let field = clearingFact else { return }
                clearing = true
                Task {
                    if await factsEditor.clear(field: field.apiKey, account: account) { await refreshFacts(); await ai.refreshMemoryPage(force: true) }
                    clearing = false; clearingFact = nil
                }
            }
            Button("取消", role: .cancel) { clearingFact = nil }
        } message: {
            Text("这项资料会被清空，训练、饮食和体重记录会保留。")
        }
        .refreshable { await refreshFacts(); await ai.refreshMemoryPage(force: true) }
        .alert("纠正这条记忆", isPresented: .init(get: { correctingItem != nil }, set: { if !$0 { correctingItem = nil } })) {
            TextField("写成你认为正确的陈述", text: $correctionText)
            Button("提交") { Task { await submitCorrection() } }
            Button("取消", role: .cancel) { correctingItem = nil }
        } message: {
            Text("告诉 Club AI，哪里需要改正。")
        }
        .confirmationDialog("删除这条记忆？", isPresented: .init(get: { deletingItem != nil }, set: { if !$0 { deletingItem = nil } }), titleVisibility: .visible) {
            Button("删除", role: .destructive) { Task { await submitDelete() } }
            Button("取消", role: .cancel) { deletingItem = nil }
        } message: {
            Text("删除这条 AI 记忆，原始记录会保留。")
        }
    }


    private func refreshFacts() async {
        let owner = account.user?.id
        await factsEditor.load(account: account)
        guard owner == account.user?.id, owner == store.editingAccountID, let document = factsEditor.facts else { return }
        store.applyV2ProfileFacts(document.facts.mapValues(\.value), meta: document.facts.mapValues { ProfileFactMeta(sourceKind: $0.sourceKind ?? "legacy_recorded", confirmedAt: nil, revision: document.revision) })
    }
    private var previewNotice: some View {
        ClubCard {
            Text("预览账号没有云端记忆").bojiFont(.exerciseName).foregroundStyle(BojiColor.textPrimary)
            Text("长期记忆来自真实账号的已确认记录。当前预览环境的每次分析都只基于你已保存的记录，不会把推测当作事实。")
                .bojiFont(.secondary).foregroundStyle(BojiColor.textSecondary)
        }
    }

    private var privacyFooter: some View {
        ClubCard {
            Text("管理这些信息").bojiFont(.exerciseName).foregroundStyle(BojiColor.textPrimary)
            Text("你可以随时管理这些信息。")
                .bojiFont(.secondary).foregroundStyle(BojiColor.textSecondary)
        }
    }

    @ViewBuilder private func memorySection(_ title: String, _ items: [ClubMemoryItem], footer: String) -> some View {
        NavigationLink {
            List {
            if items.isEmpty {
                Text("暂无").bojiFont(.secondary).foregroundStyle(BojiColor.textTertiary)
            }
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(item.kindLabel)
                                    .font(.system(.caption2, design: .monospaced).weight(.semibold))
                                    .foregroundStyle(BojiColor.textSecondary)
                                if item.isUserCorrected {
                                    Text("成员修订").font(.caption2).foregroundStyle(BojiColor.textTertiary)
                                }
                                if item.isSuspended {
                                    Text("已暂停个性化").font(.caption2).foregroundStyle(BojiColor.textTertiary)
                                }
                            }
                            Text(item.content).bojiFont(.body).foregroundStyle(BojiColor.textPrimary)
                            Text(item.isUserCorrected ? "来源：你的确认或纠正" : "来源：已确认资料与记录")
                                .font(.caption).foregroundStyle(.secondary)
                            if let refs = item.evidenceRefs, !refs.isEmpty {
                                DisclosureGroup("查看依据（\(refs.count)项）") {
                                    ForEach(refs, id: \.self) { ref in Text(MemoryEvidenceLabels126.label(ref)).font(.caption) }
                                }.font(.caption)
                            }
                            if let updated = item.updatedAt {
                                Text("更新于 \(updated)").font(.caption2).foregroundStyle(BojiColor.textTertiary)
                            }
                        }
                        Spacer(minLength: 0)
                        Menu {
                            Button("这条记忆有帮助") { Task { await account.trackEvent(name: "memory_feedback", kind: "feedback", target: item.memoryId, action: "helpful"); await ai.refreshMemoryPage(force: true) } }
                            Button("这条记忆不准确") { Task { await account.trackEvent(name: "memory_feedback", kind: "feedback", target: item.memoryId, action: "wrong"); await ai.refreshMemoryPage(force: true) } }
                            Button("纠正这条 AI 理解…") { correctingItem = item; correctionText = "" }
                            if item.isSuspended {
                                Button("恢复 AI 使用这条记忆") { Task { await mutate(item, "resume") } }
                            } else {
                                Button("撤回 AI 使用（保留原记录）") { Task { await mutate(item, "suspend") } }
                            }
                            Button("删除这条 AI 记忆（不删原始记录）", role: .destructive) { deletingItem = item }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.body)
                                .foregroundStyle(BojiColor.textSecondary)
                                .frame(width: BojiSize.minimumTap, height: BojiSize.minimumTap)
                                .contentShape(Rectangle())
                        }
                        .accessibilityIdentifier("memory-item-menu-\(item.memoryId)")
                    }
                }
            }
            Text(footer).bojiFont(.secondary).foregroundStyle(BojiColor.textTertiary)
        }
            .clubManagementList132().navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        } label: { LabeledContent(title, value: "\(items.count) 条") }
        .accessibilityIdentifier("memory-column-\(title)")
    }

    private func mutate(_ item: ClubMemoryItem, _ action: String) async {
        mutating = true
        defer { mutating = false }
        let ok = await ai.mutateMemory(id: item.memoryId, action: action)
        if !ok { error = "操作未能完成，请检查网络后重试。" }
    }

    private func submitCorrection() async {
        guard let item = correctingItem else { return }
        guard correctionText.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 else {
            error = "纠正内容太短。"
            return
        }
        mutating = true
        defer { mutating = false }
        let ok = await ai.mutateMemory(id: item.memoryId, action: "correct", content: correctionText)
        if ok {
            error = nil
            await account.trackEvent(name: "memory_corrected", kind: "feedback", target: item.memoryId, action: "correct")
        } else {
            error = "纠正未能提交，请稍后重试。"
        }
        correctingItem = nil
        correctionText = ""
    }

    private func submitDelete() async {
        guard let item = deletingItem else { return }
        await mutate(item, "withdraw")
        deletingItem = nil
    }
}
