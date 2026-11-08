import SwiftUI

// MARK: - Wire models

struct UserTaskStep: Codable, Equatable, Identifiable {
    var taskType: String
    var taskID: String
    var kind: String
    var status: String
    var businessStatus: String
    var id: String { taskType + "/" + taskID }
    enum CodingKeys: String, CodingKey {
        case taskType = "task_type", taskID = "task_id", kind, status, businessStatus = "business_status"
    }
}

struct UserTask: Codable, Equatable, Identifiable {
    var taskType: String
    var taskID: String
    var taskKey: String
    var kind: String
    var titleKey: String
    var status: String
    var businessStatus: String
    var group: String
    var updatedAt: String

    var sourceType: String?
    var sourceID: String?
    var sourceJobID: String?
    var sourceConversationID: String?
    var runID: String?
    var availableActions: [String] = []
    var steps: [UserTaskStep] = []
    var sync: TaskSyncSummary?
    var id: String { taskKey }
    enum CodingKeys: String, CodingKey {
        case taskType = "task_type", taskID = "task_id", taskKey = "task_key", kind, titleKey = "title_key",
             status, businessStatus = "business_status", group, updatedAt = "updated_at", availableActions = "available_actions",
             steps, sync, runID = "run_id", sourceRef = "source_ref"
    }
    enum SourceKeys: String, CodingKey { case type, id, jobID = "job_id", conversationID = "conversation_id" }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        taskType = try c.decode(String.self, forKey: .taskType)
        taskID = try c.decode(String.self, forKey: .taskID)
        taskKey = (try? c.decode(String.self, forKey: .taskKey)) ?? taskType + "/" + taskID
        kind = (try? c.decode(String.self, forKey: .kind)) ?? ""
        titleKey = (try? c.decode(String.self, forKey: .titleKey)) ?? "task.general"
        status = (try? c.decode(String.self, forKey: .status)) ?? "queued"
        businessStatus = (try? c.decode(String.self, forKey: .businessStatus)) ?? "pending"
        group = (try? c.decode(String.self, forKey: .group)) ?? "history"
        updatedAt = (try? c.decode(String.self, forKey: .updatedAt)) ?? ""
        availableActions = (try? c.decode([String].self, forKey: .availableActions)) ?? []
        steps = (try? c.decode([UserTaskStep].self, forKey: .steps)) ?? []
        sync = try? c.decodeIfPresent(TaskSyncSummary.self, forKey: .sync)
        runID = try? c.decodeIfPresent(String.self, forKey: .runID)
        if let nested = try? c.nestedContainer(keyedBy: SourceKeys.self, forKey: .sourceRef) {
            sourceType = try? nested.decodeIfPresent(String.self, forKey: .type)
            sourceID = try? nested.decodeIfPresent(String.self, forKey: .id)
            sourceJobID = try? nested.decodeIfPresent(String.self, forKey: .jobID)
            sourceConversationID = try? nested.decodeIfPresent(String.self, forKey: .conversationID)
        }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(taskType, forKey: .taskType); try c.encode(taskID, forKey: .taskID)
        try c.encode(taskKey, forKey: .taskKey); try c.encode(kind, forKey: .kind)
        try c.encode(titleKey, forKey: .titleKey); try c.encode(status, forKey: .status)
        try c.encode(businessStatus, forKey: .businessStatus); try c.encode(group, forKey: .group)
        try c.encode(updatedAt, forKey: .updatedAt); try c.encode(availableActions, forKey: .availableActions)
        try c.encode(steps, forKey: .steps); try c.encodeIfPresent(sync, forKey: .sync); try c.encodeIfPresent(runID, forKey: .runID)
    }

    var title: String {
        if taskType == "onboarding" { return "新手引导" }
        switch kind {
        case "generate_plan": return "第一份训练计划"
        case "parse_plan": return "导入训练计划"
        case "coach": return "Club AI 对话"
        case "report": return "日报"
        case "weekly_review": return "每周回顾"
        case "food": return "饮食识别"
        case "meal_draft": return "饮食草稿"
        case "weight_entry": return "身体记录草稿"
        case "plan_activation": return "计划变更预览"
        case "plan_change_proposal": return "日程调整预览"
        case "plan_draft": return "计划草稿"
        case "exercise_swap": return "动作替换预览"
        case "training_finish": return "训练结束确认"
        case "onboarding": return "新手引导"
        case "profile_change": return "资料变更预览"
        default: return "我的任务"
        }
    }
    var statusLabel: String {
        if status == "succeeded", businessStatus == "not_committed" { return kind == "food" ? "识别完成，待你核对" : "已生成预览，待你确认" }
        switch status {
        case "unknown": return "状态待核对"
        case "queued": return "排队中"
        case "running", "processing", "executing", "dispatching", "verifying_result": return "处理中"
        case "retrying": return "正在重试"
        case "succeeded", "completed": return "已完成"
        case "awaiting_confirmation", "draft_ready": return "待你确认"
        case "failed": return "失败，可安全重试"
        case "conflict": return "内容已变化，需重新核对"
        case "expired": return "预览已过期"
        case "cancelled": return "已取消"
        default: return status
        }
    }
    var businessLabel: String {
        if let sync, sync.failed > 0 { return "同步失败 · 本机记录仍保留" }
        if let sync, sync.pending > 0 { return "已提交 · 正在同步" }
        switch businessStatus {
        case "committed", "completed": return "服务端已保存"
        case "syncing": return "正在同步"
        case "sync_failed": return "同步失败"
        case "discarded": return "已放弃草稿，未写入记录"
        case "not_committed": return "尚未保存，需要你确认"
        case "pending": return "等待处理"
        case "needs_attention": return "有步骤需要处理"
        default: return businessStatus
        }
    }
    var symbol: String {
        switch kind {
        case "generate_plan", "parse_plan", "plan_draft", "plan_activation": return "calendar"
        case "report", "weekly_review": return "doc.text"
        case "food", "meal_draft": return "fork.knife"
        case "weight_entry": return "scalemass"
        case "onboarding": return "sparkles"
        default: return "bubble.left.and.bubble.right"
        }
    }
}

struct TaskSyncSummary: Codable, Equatable {
    var pending = 0
    var failed = 0
    var published = 0
}

struct TaskPage: Codable {
    var items: [UserTask]
    var nextCursor: String?
    enum CodingKeys: String, CodingKey { case items; case nextCursor = "next_cursor" }
}

enum TaskCenterAPI {
    @MainActor
    static func page(account: AccountService, cursor: String? = nil, group: String? = nil) async throws -> TaskPage {
        guard let uid = account.user?.id else { throw AccountError.unauthorized }
        var path = "/me/tasks?limit=30"
        if let cursor, let encodedCursor = cursor.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            path += "&cursor=" + encodedCursor
        }
        if let group, !group.isEmpty { path += "&group=\(group)" }
        let response = try await account.cloudRequest(path: path, expectedUserID: uid)
        guard response.statusCode == 200 else { throw OnboardingAPIError(message: "任务列表暂不可用。", status: response.statusCode) }
        return try JSONDecoder().decode(TaskPage.self, from: response.data)
    }

    @MainActor
    static func cancelRun(_ runID: String, account: AccountService) async throws {
        guard let uid = account.user?.id else { throw AccountError.unauthorized }
        let response = try await account.cloudRequest(path: "/me/ai/runs/\(runID)/cancel", method: "POST", body: Data("{}".utf8), expectedUserID: uid)
        guard (200..<300).contains(response.statusCode) else { throw OnboardingAPIError(message: "取消未完成。", status: response.statusCode) }
    }

    @MainActor
    static func cancelProposal(_ id: String, account: AccountService) async throws {
        guard let uid = account.user?.id else { throw AccountError.unauthorized }
        let response = try await account.cloudRequest(path: "/me/ai/proposals/\(id)/cancel", method: "POST", body: Data("{}".utf8), expectedUserID: uid)
        guard (200..<300).contains(response.statusCode) else { throw OnboardingAPIError(message: "取消预览未完成。", status: response.statusCode) }
    }

    @MainActor
    static func retryJob(_ id: String, account: AccountService) async throws {
        guard let uid = account.user?.id else { throw AccountError.unauthorized }
        let response = try await account.cloudRequest(path: "/me/ai/jobs/\(id)/retry", method: "POST", body: Data("{}".utf8), expectedUserID: uid)
        guard (200..<300).contains(response.statusCode) else { throw OnboardingAPIError(message: "重试未被接受。", status: response.statusCode) }
    }
}

// MARK: - UI

@MainActor
final class TaskCenterModel: ObservableObject {
    @Published private(set) var tasks: [UserTask] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var notice: String?
    @Published var group = "attention"
    private var ownerID: Int?
    private var generation = UUID()
    private var cursor: String?
    private var hasMore = false

    func load(account: AccountService, reset: Bool = true) async {
        guard let owner = account.user?.id else { tasks = []; return }
        if ownerID != owner {
            generation = UUID(); ownerID = owner; tasks = []; loading = false; notice = nil; error = nil; cursor = nil
        }
        guard !loading else { return }
        let ticket = generation
        loading = true; error = nil
        defer { if generation == ticket { loading = false } }
        if reset { cursor = nil; hasMore = false }
        do {
            let page = try await TaskCenterAPI.page(account: account, cursor: cursor, group: group == "all" ? nil : group)
            guard ticket == generation, account.user?.id == owner, ownerID == owner else { return }
            if reset {
                tasks = page.items
            } else {
                let existing = Set(tasks.map(\.id))
                tasks += page.items.filter { !existing.contains($0.id) }
            }
            cursor = page.nextCursor
            hasMore = page.nextCursor != nil
        } catch { if generation == ticket, account.user?.id == owner { self.error = AppErrorText.message(error) } }
    }

    func loadMore(account: AccountService) async {
        guard hasMore, !loading else { return }
        await load(account: account, reset: false)
    }

    func cancel(_ task: UserTask, account: AccountService) async {
        do {
            if task.taskType == "proposal" {
                try await TaskCenterAPI.cancelProposal(task.taskID, account: account)
                notice = "已取消这份预览；没有执行任何业务写入。"
            } else if task.taskType == "ai_job", let runID = task.runID {
                try await TaskCenterAPI.cancelRun(runID, account: account)
                notice = "已请求取消；已提交的业务记录不会回滚。"
            } else { return }
            await load(account: account)
        } catch { self.error = AppErrorText.message(error) }
    }

    func retry(_ task: UserTask, account: AccountService) async {
        do {
            try await TaskCenterAPI.retryJob(task.taskID, account: account)
            notice = "已沿用原任务编号请求重试，不会创建第二个业务任务。"
            await load(account: account)
        } catch { self.error = AppErrorText.message(error) }
    }
}

struct TaskCenterView: View {
    @EnvironmentObject private var account: AccountService
    @EnvironmentObject private var ai: AIService
    @EnvironmentObject private var weekly: WeeklyReviewService
    @EnvironmentObject private var store: AppStore
    @State private var recoveryEntries: [OnboardingMutationRecovery.Entry] = []
    @State private var recoverySelection: OnboardingMutationRecovery.Entry?
    @State private var profileProposalID: String?
    @StateObject private var model = TaskCenterModel()
    @State private var selected: UserTask?
    @State private var planRoute: TaskPlanRoute?
    @State private var reportID: String?
    @State private var conversation: String?
    @State private var mealRoute: TaskMealRoute?

    private let groups: [(String, String)] = [("attention", "需要处理"), ("processing", "处理中"), ("history", "已结束"), ("all", "全部")]

    var body: some View {
        List {
                Picker("任务筛选", selection: $model.group) {
                    ForEach(groups, id: \.0) { Text($0.1).tag($0.0) }
                }.pickerStyle(.segmented)
                .onChange(of: model.group) { _, _ in Task { await model.load(account: account) } }

                if !recoveryEntries.isEmpty {
                    Text("本机待恢复的修改").bojiType(.bodyStrong)
                    ForEach(recoveryEntries) { entry in
                        Button("核对未提交的资料或引导修改") { recoverySelection=entry }.buttonStyle(.bordered)
                    }
                }
                ContextualTipView(screen: "task_center")
                Text("在这里核对待保存的草稿、查看处理进度，或重试失败的请求。生成的内容经你确认后才会保存。")
                    .bojiType(.label).foregroundStyle(.secondary)

                if model.tasks.isEmpty, !model.loading {
                    ContentUnavailableView("还没有任务", systemImage: "checklist", description: Text("你发起的计划、报告、记录与同步会在这里按真实状态汇总。"))
                }
                ForEach(model.tasks) { task in
                    taskRow(task)
                }
                if model.tasks.count >= 30 {
                    Button(model.loading ? "正在加载…" : "加载更多") { Task { await model.loadMore(account: account) } }
                        .buttonStyle(SecondaryButton()).disabled(model.loading)
                }
                if let error = model.error { Text(error).bojiType(.label).foregroundStyle(.red) }
                if let notice = model.notice { Text(notice).bojiType(.label).foregroundStyle(.secondary) }

        }.clubManagementList132()
        .background(BojiColor.pageBackground)
        .navigationTitle("处理进度")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.load(account: account) }
        .task { await model.load(account: account) }
        .sheet(item: $mealRoute) { route in
            if route.batch { MealBatchReviewView(jobID: route.id) }
            else { MealEditorView(date: route.date, initialJobID: route.id) }
        }
        .onChange(of: account.user?.id) { _, _ in
            selected = nil; planRoute = nil; reportID = nil; conversation = nil; mealRoute = nil; profileProposalID = nil
            Task { await model.load(account: account) }
        }
        .sheet(item:$recoverySelection,onDismiss:{ refreshRecoveryEntries() }) { entry in
            NavigationStack { LocalMutationReviewView(entry:entry) }
        }
        .onAppear { refreshRecoveryEntries() }
        .onChange(of:model.loading) { _,loading in if !loading { refreshRecoveryEntries() } }
        .sheet(item: $selected) { task in TaskDetailView(task: task) }
        .sheet(item: Binding(get: { profileProposalID.map { TaskStringRoute(value: $0) } }, set: { profileProposalID = $0?.value })) { route in
            NavigationStack { AIProfileProposalView(proposalID: route.value)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { profileProposalID = nil } } } }
        }
        .sheet(item: $planRoute) { route in
            NavigationStack {
                PlanView(date: route.date, initialMode: route.mode, initialJobID: route.jobID)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { planRoute = nil } } }
            }
        }
        .sheet(item: Binding(get: { reportID.map { TaskStringRoute(value: $0) } }, set: { reportID = $0?.value })) { route in
            NavigationStack { AIReportReaderView(jobID: route.value).toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { reportID = nil } } } }
        }
        .sheet(item: Binding(get: { conversation.map { TaskStringRoute(value: $0) } }, set: { conversation = $0?.value })) { route in
            NavigationStack { ClubAIEntryBridge(conversation: route.value)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { conversation = nil } } } }
        }
    }

    private func taskRow(_ task: UserTask) -> some View {
        VStack(alignment: .leading, spacing: BojiLayout.inline) {
            HStack(alignment: .top, spacing: BojiLayout.inline) {
                Image(systemName: task.symbol).foregroundStyle(ClubBrand.accent).frame(width: 24)
                VStack(alignment: .leading, spacing: BojiLayout.tight) {
                    Text(task.title).bojiType(.secondary)
                    Text(task.statusLabel).bojiType(.caption).foregroundStyle(.secondary)
                    Text(task.businessLabel).bojiType(.caption).foregroundStyle(task.businessStatus == "sync_failed" ? .red : .secondary)
                }
                Spacer()

            }
            HStack(spacing: BojiLayout.inline) {
                if task.availableActions.contains("open_source") { Button(task.kind == "food" && task.businessStatus == "not_committed" ? "核对饮食草稿" : "查看内容") { open(task) }.buttonStyle(.bordered) }
                if task.availableActions.contains("open_preview") { Button("打开预览") { open(task) }.buttonStyle(.borderedProminent) }
                if task.availableActions.contains("resume_onboarding") {
                    Button("继续新手引导") { NotificationCenter.default.post(name: .clubResumeOnboarding, object: nil) }.buttonStyle(.borderedProminent)
                }
                if task.availableActions.contains("cancel") { Button("取消", role: .destructive) { Task { await model.cancel(task, account: account) } }.buttonStyle(.bordered) }
                if task.availableActions.contains("retry") { Button("安全重试") { Task { await model.retry(task, account: account) } }.buttonStyle(.bordered) }
                Button("诊断详情") { selected = task }.buttonStyle(.borderless).bojiType(.label)
            }.buttonBorderShape(.capsule)
        }
        .padding(.vertical, BojiLayout.tight)
    }

    private func refreshRecoveryEntries() {
        guard let uid=account.user?.id else { recoveryEntries=[];return }
        recoveryEntries=OnboardingMutationRecovery.entries(owner:uid)+OnboardingMutationRecovery.entries(owner:uid,review:true)
    }
    private func open(_ task: UserTask) {
        if task.kind == "food" {
            let owner = account.user?.id
            Task {
                if ai.job(task.taskID) == nil { await ai.recoverTasks(account: account, weekly: weekly, store: store, targetID: task.taskID) }
                guard owner == account.user?.id, let job = ai.job(task.taskID),
                      !job.consumed, !store.hasAppliedAIJob(job.id), let date = ClubDates.date(fromKey: job.request.date) else { selected = task; return }
                mealRoute = TaskMealRoute(id: job.id, date: date, batch: job.result?.kind == "meal_batch")
            }
            return
        }
        if task.taskType == "profile_proposal" { profileProposalID = task.taskID; return }
        if task.taskType == "onboarding" { NotificationCenter.default.post(name: .clubResumeOnboarding, object: nil); return }
        if task.taskType == "proposal" || task.taskType == "plan_draft" || task.taskType == "command" { selected = task; return }
        if task.kind == "report", let job = ai.job(task.taskID), !(store.state.deletedAIJobIDs ?? []).contains(job.id) { reportID = job.id; return }
        if (task.kind == "generate_plan" || task.kind == "parse_plan"), let job = ai.job(task.taskID),
           !job.consumed, !store.hasAppliedAIJob(job.id), let date = ClubDates.date(fromKey: job.request.date) {
            planRoute = TaskPlanRoute(id: task.taskID, date: date, mode: job.request.kind, jobID: task.taskID); return
        }
        if task.kind == "coach", let conversation = task.sourceConversationID { self.conversation = conversation; return }
        selected = task
    }
}

private struct TaskMealRoute: Identifiable { let id: String; let date: Date; let batch: Bool }
private struct TaskStringRoute: Identifiable { let value: String; var id: String { value } }
private struct TaskPlanRoute: Identifiable { let id: String; let date: Date; let mode: String; let jobID: String }

struct TaskDetailView: View {
    let task: UserTask
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("任务") {
                    LabeledContent("编号", value: task.taskID)
                    LabeledContent("类型", value: task.kind)
                    LabeledContent("状态", value: task.statusLabel)
                    LabeledContent("业务", value: task.businessLabel)
                    LabeledContent("更新时间", value: task.updatedAt)
                }
                if let sync = task.sync {
                    Section("同步") {
                        LabeledContent("待同步事件", value: "\(sync.pending)")
                        LabeledContent("同步失败", value: "\(sync.failed)")
                        LabeledContent("已发布", value: "\(sync.published)")
                        Text("同步失败不会删除已保存的本机记录；不会用重试重复保存同一业务。")
                            .bojiType(.label).foregroundStyle(.secondary)
                    }
                }
                if !task.steps.isEmpty {
                    Section("关联步骤") {
                        ForEach(task.steps) { step in
                            VStack(alignment: .leading, spacing: 0) {
                                Text(step.kind).bojiType(.secondary)
                                Text("\(step.status) · \(step.businessStatus)").bojiType(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section {
                    Text("这里不会自动重放已成功命令；取消只停止尚未提交的工作。")
                        .bojiType(.label).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(task.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("关闭") { dismiss() } } }
        }
    }
}

extension Notification.Name {
    static let clubResumeOnboarding = Notification.Name("clubResumeOnboarding")
}
