import SwiftUI

// MARK: - 数字运动档案卡 & AI 记忆中心（替代老旧冗余表单）
//
// 1. 核心档案卡：基础资料（昵称、身高、体重、BMI、目标），支持极简快捷修改。
// 2. 动态能力表现卡：AI 依据过去 28 天真实已完成组动态计算（训练频率、卧推/深蹲/硬拉估算 1RM），免去死板问卷。
// 3. AI 记忆小本本：展示生活习惯、饮食偏好、身体限制与成员纠错，支持纠正、停用、删除以及随时手动添加一条偏好。

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

    var isEmpty: Bool { allItems.isEmpty }
    /// 拍板 #5-B：**行为习惯栏随对话下线**，`habit` 类记忆不再展示。
    /// 这是纯展示层过滤——服务端数据、`GET /me/ai/memory` 契约、纠正/撤回接口、
    /// 数据导出与 prompt 上下文注入**全部保持不变**，回滚只需还原这一行。
    /// `preference`（成员明确填写的偏好）不属于"AI 归纳的习惯"，仍展示。
    var allItems: [ClubMemoryItem] {
        var list = [ClubMemoryItem]()
        list.append(contentsOf: confirmed)
        list.append(contentsOf: inferred)
        return list.filter { $0.kind != "habit" }
    }
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
    @State private var addingNewMemory = false
    @State private var newMemoryText = ""
    @State private var mutating = false
    @State private var error: String?

    @State private var showEditBasics = false
    @StateObject private var factsEditor = ProfileFactsEditor()

    var body: some View {
        ScrollView {
            contentStack
        }
        .background { ClubBackground() }
        .navigationTitle("AI 记住的内容")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("ai-memory-page")
        .task(id: account.user?.id) { await refreshFacts() }
        .task(id: account.user?.id) { await ai.refreshMemoryPage() }
        .onReceive(NotificationCenter.default.publisher(for: .profileFactsChanged133)) { note in
            if note.object as? Int == account.user?.id {
                Task { await refreshFacts() }
            }
        }
        .refreshable {
            await refreshFacts()
            await ai.refreshMemoryPage(force: true)
        }
        .sheet(isPresented: $showEditBasics, onDismiss: {
            Task {
                await refreshFacts()
                await ai.refreshMemoryPage(force: true)
            }
        }) {
            ProfileFactsForm133(
                title: "修改基础档案",
                fields: [.nickname, .heightCm, .profileWeightKg, .goal]
            )
        }
        .alert("纠正这条记忆", isPresented: Binding(get: { correctingItem != nil }, set: { if !$0 { correctingItem = nil } })) {
            TextField("写成你认为正确的陈述", text: $correctionText)
            Button("提交") { Task { await submitCorrection() } }
            Button("取消", role: .cancel) { correctingItem = nil }
        } message: {
            Text("告诉 Club AI，哪里需要改正。")
        }
        .alert("添加偏好记忆", isPresented: $addingNewMemory) {
            TextField("如：习惯晚间训练 / 不吃猪肉 / 左肩酸痛", text: $newMemoryText)
            Button("存入档案") { Task { await submitNewMemory() } }
            Button("取消", role: .cancel) { newMemoryText = "" }
        } message: {
            Text("AI 会在后续排课、建议与对话中自动遵循此偏好。")
        }
        .confirmationDialog("删除这条记忆？", isPresented: Binding(get: { deletingItem != nil }, set: { if !$0 { deletingItem = nil } }), titleVisibility: .visible) {
            Button("删除", role: .destructive) { Task { await submitDelete() } }
            Button("取消", role: .cancel) { deletingItem = nil }
        } message: {
            Text("删除这条记忆后，AI 不会再在对话与排课中使用它。原始运动记录仍会保留。")
        }
    }

    private var contentStack: some View {
        VStack(spacing: BojiSpace.sectionSpacing) {
            // 1. 核心档案卡片
            athleteIdentityCard

            // 2. 动态能力表现卡片
            dynamicPerformanceCard

            // 3. AI 记忆小本本便签群
            aiMemoryNotesCard

            if let error {
                FlowError(message: error)
            }
        }
        .padding(ClubUI.pageInset)
    }

    // MARK: - 1. 核心档案卡片
    private var athleteIdentityCard: some View {
        ClubCard {
            VStack(alignment: .leading, spacing: BojiLayout.rowGap) {
                HStack(alignment: .center) {
                    HStack(spacing: BojiLayout.inline) {
                        Image(systemName: "person.crop.circle.fill")
                            .bojiType(.display)
                            .foregroundStyle(BojiColor.brandAccent)
                        VStack(alignment: .leading, spacing: 0) {
                            let displayName = store.state.profile.nickname.isEmpty ? (account.user?.profile?.nickname ?? "薄肌会员") : store.state.profile.nickname
                            Text(displayName)
                                .bojiType(.bodyStrong)
                                .foregroundStyle(BojiColor.textPrimary)
                            Text("核心身体档案 · 随测随更")
                                .bojiType(.caption)
                                .foregroundStyle(BojiColor.textSecondary)
                        }
                    }
                    Spacer()
                    Button {
                        showEditBasics = true
                    } label: {
                        HStack(spacing: BojiLayout.tight) {
                            Image(systemName: "pencil")
                            Text("编辑")
                        }
                        .bojiType(.caption)
                        .padding(.horizontal, BojiLayout.inline)
                        .padding(.vertical, BojiLayout.tight)
                        .background(BojiColor.subtleSurface, in: Capsule())
                        .foregroundStyle(BojiColor.textPrimary)
                    }
                    .buttonStyle(.plain)
                }

                Divider().opacity(0.4)

                // 4 宫格核心数据
                let profile = store.state.profile
                let confirmedHeight = profile.isFactConfirmed("height_cm") ? profile.height : nil
                let confirmedProfileWeight = profile.isFactConfirmed("profile_weight_kg") ? profile.weight : nil
                let latestWeight = ProfileBodyRules126.latestMeasurement(store.state.days)?.value ?? confirmedProfileWeight
                let bmi = ProfileBodyRules126.bmi(profile: store.state.profile)

                HStack(spacing: BojiLayout.rowGap) {
                    metricItem(label: "身高", value: confirmedHeight.map { "\($0.formatted()) cm" } ?? "--")
                    metricItem(label: "最新体重", value: latestWeight.map { "\($0.formatted()) kg" } ?? "--")
                    metricItem(label: "BMI", value: bmi.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "--")
                    metricItem(label: "目标", value: profile.isFactConfirmed("goal") && !profile.goal.isEmpty ? profile.goal : "--")
                }
            }
        }
    }

    private func metricItem(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: BojiLayout.tight) {
            Text(label)
                .bojiType(.caption)
                .foregroundStyle(BojiColor.textTertiary)
            Text(value)
                .bojiType(.secondary)
                .foregroundStyle(BojiColor.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, BojiLayout.inline)
        .padding(.vertical, BojiLayout.inline)
        .background(BojiColor.inputSurface, in: RoundedRectangle(cornerRadius: BojiRadius.thumb, style: .continuous))
    }

    // MARK: - 2. 动态能力表现卡片
    private struct AthletePerformance {
        var sessionsCount = 0
        var benchBest: Double? = nil
        var squatBest: Double? = nil
        var deadliftBest: Double? = nil
    }

    private var athletePerformance: AthletePerformance {
        let cal = ClubDates.calendar
        let now = Date()
        guard let windowStart = cal.date(byAdding: .day, value: -28, to: now) else { return AthletePerformance() }
        let startKey = ClubDates.key(windowStart)
        let endKey = ClubDates.key(now)

        var sessions = 0
        var bestBench: Double?
        var bestSquat: Double?
        var bestDeadlift: Double?

        for (key, day) in store.state.days where key >= startKey && key <= endKey {
            let hasCompleted = day.exercises.contains { ex in
                ex.sets.contains(where: { $0.validCompletion })
            }
            if hasCompleted || day.workoutSavedAt != nil {
                sessions += 1
            }

            for ex in day.exercises {
                let name = ex.name.lowercased()
                let completedSets = ex.sets.filter { $0.validCompletion && $0.weight > 0 }
                guard !completedSets.isEmpty else { continue }

                // Epley 1RM 公式：weight * (1 + reps / 30)
                let maxOneRep = completedSets.map { set in
                    let reps = Double(max(1, set.reps))
                    return reps == 1 ? set.weight : set.weight * (1.0 + reps / 30.0)
                }.max() ?? 0

                if name.contains("卧推") || name.contains("推胸") || name.contains("bench") {
                    bestBench = max(bestBench ?? 0, maxOneRep)
                } else if name.contains("深蹲") || name.contains("squat") {
                    bestSquat = max(bestSquat ?? 0, maxOneRep)
                } else if name.contains("硬拉") || name.contains("deadlift") {
                    bestDeadlift = max(bestDeadlift ?? 0, maxOneRep)
                }
            }
        }
        return AthletePerformance(sessionsCount: sessions, benchBest: bestBench, squatBest: bestSquat, deadliftBest: bestDeadlift)
    }

    private var dynamicPerformanceCard: some View {
        ClubCard {
            VStack(alignment: .leading, spacing: BojiLayout.rowGap) {
                HStack {
                    Image(systemName: "flame.fill")
                        .foregroundStyle(BojiColor.aiGold)
                    Text("动态运动表现评估")
                        .bojiType(.bodyStrong)
                        .foregroundStyle(BojiColor.textPrimary)
                    Spacer()
                    Text("近 4 周动态估算")
                        .bojiType(.caption)
                        .foregroundStyle(BojiColor.textSecondary)
                }

                let perf = athletePerformance
                HStack(spacing: BojiLayout.rowGap) {
                    perfItem(title: "近 4 周训练", value: "\(perf.sessionsCount) 次", hint: perf.sessionsCount >= 8 ? "规律训练者" : perf.sessionsCount > 0 ? "起步适应中" : "待开启首次训练")
                    perfItem(title: "卧推估算 1RM", value: perf.benchBest.map { "\($0.formatted(.number.precision(.fractionLength(0)))) kg" } ?? "--", hint: "推类表现")
                    perfItem(title: "深蹲估算 1RM", value: perf.squatBest.map { "\($0.formatted(.number.precision(.fractionLength(0)))) kg" } ?? "--", hint: "下肢力量")
                }

                Label("数据来自你真正练完的组，不用填问卷。练得越久，估得越准。", systemImage: "lightbulb.fill")
                    .bojiType(.caption)
                    .foregroundStyle(BojiColor.textTertiary)
            }
        }
    }

    private func perfItem(title: String, value: String, hint: String) -> some View {
        VStack(alignment: .leading, spacing: BojiLayout.tight) {
            Text(title)
                .bojiType(.caption)
                .foregroundStyle(BojiColor.textTertiary)
            Text(value)
                .bojiType(.section)
                .foregroundStyle(BojiColor.textPrimary)
            Text(hint)
                .bojiType(.caption)
                .foregroundStyle(BojiColor.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(BojiLayout.inline)
        .background(BojiColor.inputSurface, in: RoundedRectangle(cornerRadius: BojiRadius.control, style: .continuous))
    }

    // MARK: - 3. AI 记忆小本本卡片
    private var aiMemoryNotesCard: some View {
        ClubCard {
            VStack(alignment: .leading, spacing: BojiLayout.rowGap) {
                HStack {
                    HStack(spacing: BojiLayout.inline) {
                        Image(systemName: "brain.head.profile")
                            .foregroundStyle(BojiColor.aiViolet)
                        Text("AI 记忆便签本")
                            .bojiType(.bodyStrong)
                            .foregroundStyle(BojiColor.textPrimary)
                    }
                    Spacer()
                    Button {
                        newMemoryText = ""
                        addingNewMemory = true
                    } label: {
                        HStack(spacing: BojiLayout.tight) {
                            Image(systemName: "plus.circle.fill")
                            Text("添加偏好")
                        }
                        .bojiType(.caption)
                        .foregroundStyle(BojiColor.brandAccent)
                    }
                    .buttonStyle(.plain)
                }

                Text("Club AI 会在对话、排课和调整时遵循以下记录。你可以纠正、暂停或删除任意一条。")
                    .bojiType(.caption)
                    .foregroundStyle(BojiColor.textSecondary)

                if account.isPreviewAccount || account.user?.id == nil {
                    previewNotice
                } else if let page = ai.memoryPage {
                    let items = page.allItems
                    if items.isEmpty {
                        VStack(spacing: BojiLayout.inline) {
                            Image(systemName: "sparkles")
                                .bojiType(.section)
                                .foregroundStyle(BojiColor.textTertiary)
                            Text("暂无专属记忆便签")
                                .bojiType(.secondary)
                                .foregroundStyle(BojiColor.textSecondary)
                            Text("点击右上角可手动添加；从你的记录中确认的事实与推断会沉淀在此，随时可以纠正或撤回。")
                                .bojiType(.caption)
                                .foregroundStyle(BojiColor.textTertiary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, BojiLayout.blockGap)
                    } else {
                        VStack(spacing: BojiLayout.inline) {
                            ForEach(items) { item in
                                memoryNoteRow(item)
                            }
                        }
                    }
                } else {
                    HStack {
                        ProgressView()
                        Text("正在同步 AI 记忆…").bojiType(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, BojiLayout.inline)
                }
            }
        }
    }

    private func memoryNoteRow(_ item: ClubMemoryItem) -> some View {
        HStack(alignment: .top, spacing: BojiLayout.inline) {
            VStack(alignment: .leading, spacing: BojiLayout.tight) {
                HStack(spacing: BojiLayout.tight) {
                    Text(item.kindLabel)
                        .bojiType(.caption)
                        .padding(.horizontal, BojiLayout.tight)
                        
                        .background(itemKindColor(item.kind).opacity(0.15), in: RoundedRectangle(cornerRadius: BojiRadius.badge, style: .continuous))
                        .foregroundStyle(itemKindColor(item.kind))

                    if item.isUserCorrected {
                        Text("自主录入").bojiType(.caption).foregroundStyle(BojiColor.textTertiary)
                    }
                    if item.isSuspended {
                        Text("已暂停使用").bojiType(.caption).foregroundStyle(.red.opacity(0.8)) // lint-ignore: status-red（状态红有意降透明，非灰度替代）
                    }
                    Spacer()
                }

                Text(item.content)
                    .bojiType(.secondary)
                    .foregroundStyle(item.isSuspended ? BojiColor.textTertiary : BojiColor.textPrimary)
                    .strikethrough(item.isSuspended)

                HStack(spacing: BojiLayout.tight) {
                    Text(item.isUserCorrected ? "来源：你的确认与录入" : "来源：训练与饮食记录归纳")
                        .bojiType(.caption)
                        .foregroundStyle(BojiColor.textTertiary)
                    if let updated = item.updatedAt {
                        Text("· \(updated)").bojiType(.caption).foregroundStyle(BojiColor.textTertiary)
                    }
                }
            }

            Spacer(minLength: 4)

            Menu {
                Button("纠正这条内容…") {
                    correctingItem = item
                    correctionText = item.content
                }
                if item.isSuspended {
                    Button("恢复使用") { Task { await mutate(item, "resume") } }
                } else {
                    Button("暂停使用（保留记录）") { Task { await mutate(item, "suspend") } }
                }
                Button("删除此条记忆", role: .destructive) {
                    deletingItem = item
                }
            } label: {
                Image(systemName: "ellipsis")
                    .bojiType(.secondary)
                    .foregroundStyle(BojiColor.textSecondary)
                    .frame(width: 32, height: 32)
                    // BUG-027 同族：命中区外扩到 44×44（视觉 32 不变）
                    .contentShape(Rectangle().inset(by: -6))
            }
            .buttonStyle(.plain)
        }
        .padding(BojiLayout.rowGap)
        .background(BojiColor.inputSurface, in: RoundedRectangle(cornerRadius: BojiRadius.control, style: .continuous))
    }

    private func itemKindColor(_ kind: String) -> Color {
        switch kind {
        case "constraint": return .orange
        case "habit": return BojiColor.aiGold
        case "preference": return BojiColor.brandAccent
        case "goal": return BojiColor.aiViolet
        default: return BojiColor.textSecondary
        }
    }

    private var previewNotice: some View {
        VStack(spacing: BojiLayout.tight) {
            Text("预览环境暂无云端记忆").bojiType(.secondary).foregroundStyle(BojiColor.textSecondary)
            Text("登录正式账号后，AI 会在日常使用中自动建立长期档案。").bojiType(.caption).foregroundStyle(BojiColor.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, BojiLayout.rowGap)
    }

    // MARK: - 网络与数据操作
    private func refreshFacts() async {
        let owner = account.user?.id
        await factsEditor.load(account: account)
        guard owner == account.user?.id, owner == store.editingAccountID, let document = factsEditor.facts else { return }
        store.applyV2ProfileFacts(document.facts.mapValues(\.value), meta: document.facts.mapValues { ProfileFactMeta(sourceKind: $0.sourceKind ?? "legacy_recorded", confirmedAt: nil, revision: document.revision) })
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
            BojiHaptics.success()
        } else {
            error = "纠正未能提交，请稍后重试。"
        }
        correctingItem = nil
        correctionText = ""
    }

    private func submitNewMemory() async {
        let trimmed = newMemoryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return }
        mutating = true
        defer { mutating = false }
        let ok = await ai.createMemory(content: trimmed, kind: "preference")
        if ok {
            error = nil
            BojiHaptics.success()
            newMemoryText = ""
        } else {
            error = "偏好保存失败，请稍后重试。"
        }
    }

    private func submitDelete() async {
        guard let item = deletingItem else { return }
        await mutate(item, "withdraw")
        deletingItem = nil
    }
}
