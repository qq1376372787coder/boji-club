import SwiftUI

struct ClubAIHubView: View {
    var initialSection = "动态"
    var body: some View {
        if initialSection == "报告" { NavigationStack { ReportLibraryView() } }
        else { ClubAIEntryBridge() }
    }
}

struct ClubAIHomeView: View {
    var body: some View {
        ClubInsightTimelineView(embedded: true)
    }
}

private struct ClubCoachOpen: Identifiable { let id = UUID(); let action: ClubCoachAction }

/// Kept by the shell so mode switches do not destroy drafts, navigation context or scroll position.
@MainActor
final class ClubCoachSession: ObservableObject {
    @Published var conversation: String
    @Published var question: String { didSet { composerRevision130 &+= 1 } }
    @Published var contextDays = 14
    @Published var planIntake131 = false
    @Published var onboardingPlanSession135: String?
    @Published var workoutContext: ClubAIEntryContext?
    @Published var attachments: [ClubChatAttachment] = [] { didSet { composerRevision130 &+= 1 } }
    @Published var references: [AIContextReference] = [] { didSet { composerRevision130 &+= 1 } }
    @Published var continuationSource: ClubContextSource?
    @Published var reviewScope: ClubReviewScope?
    @Published var deepAnalysis = false { didSet { composerRevision130 &+= 1 } }
    @Published var preparingReferences = false
    @Published var processingConversation: String?
    @Published var scrollAnchor: String?
    @Published var sendRequest = 0
    @Published var error: String?
    @Published var followLatest = true
    @Published var focusRequest = 0
    @Published fileprivate var draftCardOutcomes: [String: ClubDraftCardOutcome] = [:]
    @Published fileprivate var cardActionError: String?
    fileprivate var composerRevision130 = 0
    fileprivate var submittedDraftRevisions130: [String: Int] = [:]
    var referenceSendTask130: Task<Void, Never>?
    func cancelReferenceSend130() {
        referenceSendTask130?.cancel(); referenceSendTask130 = nil; preparingReferences = false
        error = "发送已取消，草稿已保留。"
    }
    fileprivate var consumedSendRequest = 0
    fileprivate var ownerID: Int?
    fileprivate var initialized = false
    private var scrollAnchors: [String: String] = [:]

    init(conversation: String = UUID().uuidString.lowercased(), question: String = "") {
        self.conversation = conversation
        self.question = question
    }

    func reset(conversation: String = UUID().uuidString.lowercased(), question: String = "") {
        referenceSendTask130?.cancel(); referenceSendTask130 = nil
        self.conversation = conversation; self.question = question
        planIntake131 = false; onboardingPlanSession135 = nil; contextDays = 14; scrollAnchor = nil; sendRequest = 0; consumedSendRequest = 0
        error = nil; cardActionError = nil; draftCardOutcomes = [:]; followLatest = true; focusRequest = 0
        ownerID = nil; initialized = false; scrollAnchors = [:]; workoutContext = nil; continuationSource = nil; reviewScope = nil; attachments = []; references = []; deepAnalysis = false; preparingReferences = false; processingConversation = nil
    }

    func persistExtras() {
        guard let ownerID else { return }
        if !ClubChatDraftStorage.save(owner: ownerID, conversation: conversation, attachments: attachments, context: workoutContext, references: references, source: continuationSource, scope: reviewScope) {
            error = "照片草稿未能保存到本机，请保留当前页面并重试。"
        }
    }

    /// A render or mode switch cannot submit the same queued question twice.
    func takePendingSend() -> Bool {
        guard sendRequest != consumedSendRequest else { return false }
        consumedSendRequest = sendRequest
        return true
    }

    func selectConversation(_ id: String, owner: Int?) {
        if owner == ownerID || ownerID == nil, let owner {
            ClubCoachDraftStorage.save(question, owner: owner, conversation: conversation)
            persistExtras()
            if let scrollAnchor { scrollAnchors[conversation] = scrollAnchor }
        }
        if owner != ownerID { scrollAnchors = [:] }
        ownerID = owner
        planIntake131 = false
        conversation = id
        let draft = owner.flatMap { ClubChatDraftStorage.load(owner: $0, conversation: id) }
        continuationSource = draft?.source; reviewScope = draft?.scope
        workoutContext = draft?.context
        attachments = draft?.attachments ?? []; references = draft?.references ?? []
        question = owner.map { ClubCoachDraftStorage.load(owner: $0, conversation: id) } ?? ""
        if !references.isEmpty {
            // Migrate old rich-text reference prefixes once when opening a draft.
            var migrated = question
            for ref in references {
                let prefix = "@" + ref.title
                if migrated.hasPrefix(prefix) { migrated = String(migrated.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines) }
            }
            if migrated != question { question = migrated; if let owner { ClubCoachDraftStorage.save(migrated, owner: owner, conversation: id) } }
        }

        scrollAnchor = scrollAnchors[id]
        error = nil; cardActionError = nil; followLatest = scrollAnchor == nil
        initialized = true
        consumedSendRequest = sendRequest
    }

    func newConversation(owner: Int?, keepDraft: Bool) {
        planIntake131 = false
        if let owner {
            if keepDraft { ClubCoachDraftStorage.save(question, owner: owner, conversation: conversation); persistExtras() }
            else { ClubCoachDraftStorage.clear(owner: owner, conversation: conversation); ClubChatDraftStorage.clear(owner: owner, conversation: conversation) }
        }
        conversation = UUID().uuidString.lowercased()
        question = ""; scrollAnchor = nil; followLatest = true; workoutContext = nil; continuationSource = nil; reviewScope = nil; attachments = []; references = []; deepAnalysis = false; preparingReferences = false; processingConversation = nil
        error = nil; cardActionError = nil; draftCardOutcomes = [:]
        ownerID = owner; initialized = true; consumedSendRequest = sendRequest
    }
}

private struct CoachBottomPosition: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Native phases distinguish deliberate history browsing from layout or keyboard changes.
private struct CoachUserScrollTracking: ViewModifier {
    let changed: (Bool, Bool?) -> Void
    @State private var fallbackDragging = false
    @State private var fallbackSettling: Task<Void, Never>?

    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollPhaseChange { old, phase, context in
                let nearBottom = context.geometry.contentSize.height - context.geometry.visibleRect.maxY <= 100
                switch phase {
                case .tracking: changed(true, nil)
                case .interacting, .decelerating: changed(true, nearBottom)
                case .idle:
                    let wasUserScroll = old == .tracking || old == .interacting || old == .decelerating
                    changed(false, wasUserScroll ? nearBottom : nil)
                case .animating: changed(false, nil)
                }
            }
        } else {
            // iOS 17 has no public scroll-phase API. Drag marks user intent; retain a short
            // settling window so ordinary deceleration can still update bottom proximity.
            content.simultaneousGesture(DragGesture(minimumDistance: 4)
                .onChanged { _ in
                    fallbackSettling?.cancel()
                    if !fallbackDragging { fallbackDragging = true; changed(true, nil) }
                }
                .onEnded { _ in
                    fallbackDragging = false
                    fallbackSettling?.cancel()
                    fallbackSettling = Task { @MainActor in
                        do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                        changed(false, nil)
                    }
                })
                .onDisappear { fallbackSettling?.cancel() }
        }
    }
}

private struct ClubMealDraftRoute: Identifiable { let id: String; let jobID: String; let card: AICardEnvelope }

private struct ClubActionPlanRoute: Identifiable { let id: String; let date: Date }

enum ClubCoachTimelineRow: Identifiable {
    case job(AILocalJob)
    case live

    var id: String {
        switch self {
        case .job(let job): return "job/" + job.id
        case .live: return "coach-live"
        }
    }
}

enum ClubCoachTimelineBuilder {
    /// The live turn always follows the sorted history. It never appears above
    /// old messages, and the same row identity is reused after import.
    static func rows(turns: [AILocalJob], liveActive: Bool) -> [ClubCoachTimelineRow] {
        turns.map { .job($0) } + (liveActive ? [.live] : [])
    }
}

struct ClubCoachView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion131
    @State private var knownSucceeded131: Set<String> = []
    @EnvironmentObject private var account: AccountService
    private var cardActionError: String? {
        get { session.cardActionError }
        nonmutating set { session.cardActionError = newValue }
    }

    private func draftOutcome(_ card: AICardEnvelope) -> ClubDraftCardOutcome? {
        if let transient = draftCardOutcomes[card.card_id] { return transient }
        let saved = store.state.actionStates?.first { $0.id == "ai-draft/" + card.card_id }
        if saved?.state == ClubActionRecord.stateCompleted { return .confirmed }
        if saved?.state == ClubActionRecord.stateRejected { return .dismissed }
        return nil
    }

    private func handleCardAction(_ action: AICardAction, card: AICardEnvelope) {
        guard AICardRegistry.isRenderable(card), !card.isExpired else { return }
        switch action.action_id {
        case "confirm_proposal":
            if let state = draftOutcome(card), state == .confirming || state == .confirmed || state == .dismissed { return }
            let owner = store.editingAccountID
            draftCardOutcomes[card.card_id] = .confirming
            let cardSnapshot = card
            Task { @MainActor in
                let outcome = await ClubProposalSync.confirmDraftCard(cardSnapshot, account: account)
                guard owner == store.editingAccountID else { return }
                guard account.user?.id == owner else { return }
                switch outcome {
                case .confirmed:
                    ai.invalidateDomainQueries()
                    let refreshed = await store.refreshAfterMutation130()
                    guard owner == store.editingAccountID else { return }
                    if !refreshed { draftCardOutcomes[cardSnapshot.card_id] = .conflict("已保存到账号，手机尚未更新。请刷新记录。"); return }
                    _ = store.recordActionState(id: "ai-draft/" + cardSnapshot.card_id, state: ClubActionRecord.stateCompleted, note: "用户确认草稿，服务端已保存")
                    draftCardOutcomes[cardSnapshot.card_id] = .confirmed
                case .conflict(let message):
                    draftCardOutcomes[cardSnapshot.card_id] = .conflict(message)
                case .fallback:
                    draftCardOutcomes[cardSnapshot.card_id] = nil
                    cardActionError = "记录通道暂不可用，请稍后重试或手动记录。"
                }
            }
        case "dismiss_proposal":
            if store.recordActionState(id: "ai-draft/" + card.card_id, state: ClubActionRecord.stateRejected, note: "用户不采用草稿") {
                draftCardOutcomes[card.card_id] = .dismissed
            }
        default:
            _ = AICardActionRouter.handle(action, card: card, requestDate: card.payloadDate ?? "") { coachAction in
                typing = false
                openCoachAction131(coachAction)
            }
        }
    }

    private func openCoachAction131(_ action: ClubCoachAction) {
        guard let owner = ownerID, owner == store.editingAccountID else { return }
        if action.type == "weekly" || action.type == "daily" {
            guard !busy, let date = ClubDates.date(fromKey: action.date) else { return }
            let scope = ClubReviewScope.make(action.type == "weekly" ? .completedCalendarWeek : .daily, through: date)
            ClubAIRoute.open(owner: owner, question: scope.prompt, scope: scope, sendImmediately131: true)
        } else { destination = ClubCoachOpen(action: action) }
    }
    private var renderedRows131: [CoachRenderRow131] {
        let liveID = liveRun.clientMessageID.isEmpty ? "coach-live" : liveRun.clientMessageID
        let live = liveRun.phase != .idle && liveRun.conversationKey == conversation && !turns.contains { $0.id == liveID }
        return ClubCoachTimelineBuilder.rows(turns: turns, liveActive: live).map { row in
            switch row {
            case .job(let job): return CoachRenderRow131(id: job.id, row: row)
            case .live: return CoachRenderRow131(id: liveID, row: row)
            }
        }
    }

    // MARK: - Phase 2：能力路由（模型只请求，服务端决定执行方式）

    /// 把模型请求的能力交给服务端路由；客户端不自行判断能否写入。
    private func routeCapabilities(for job: AILocalJob) async {
        guard job.status == "succeeded", let answer = job.result?.coach, let calls = answer.capability_calls, !calls.isEmpty else { return }
        guard routedResults[job.id] == nil, !routingJobs.contains(job.id) else { return }
        guard let owner = account.user?.id else { return }
        routingJobs.insert(job.id)
        let results = await CapabilityRouter.resolve(calls: calls, messageID: job.id, owner: owner, account: account)
        guard account.user?.id == owner, !Task.isCancelled else { routingJobs.remove(job.id); return }
        routedResults[job.id] = results
        routingJobs.remove(job.id)
        if results.contains(where: { $0.isCompleted }) {
            let refreshed = await store.refreshAfterMutation130()
            guard account.user?.id == owner, owner == store.editingAccountID else { return }
            if !refreshed { cardActionError = "服务端已完成，但手机尚未读取到最新记录。请稍后刷新记录。" }
        }
        // 派生投影落后时给出可见提示（权威数据仍以领域状态为准）。
        if let status = await CapabilityRouter.projectionStatus(owner: owner, account: account), !status.in_sync {
            cardActionError = "部分提醒与洞察还在同步（\(status.pending_events) 条待处理），稍后会自动补齐。"
        }
    }

    @ViewBuilder private func routedResultView(_ result: CapabilityRouteResult, job: AILocalJob) -> some View {
        VStack(alignment: .leading, spacing: BojiLayout.rowGap) {
            if let card = result.card {
                let outcome = routeOutcomes[card.id] ?? (result.isCompleted ? .confirmed : (result.status == "cancelled" ? .dismissed : nil))
                AICardView(card: card, outcome: outcome) { action in handleRouteAction(action, card: card, result: result, job: job) }
            } else {
                Label(routeStatusLine(result), systemImage: result.isCompleted ? "checkmark.circle" : "hourglass").bojiType(.label).foregroundStyle(.secondary)
            }
            if result.isAwaitingConfirmation, let card = result.card,
               let preview = AIProposalPreviewPayload(json: card.payload), preview.kind == "meal_draft" {
                Button("编辑份量与营养估算") { mealDraftRoute = ClubMealDraftRoute(id: preview.proposalID, jobID: job.id, card: card) }.buttonStyle(.bordered)
            }
            if let card = result.card, (routeOutcomes[card.id] == .confirmed || result.isCompleted),
               ["nutrition.create_draft", "nutrition.save_entry"].contains(result.capability ?? "") {
                Button("查看饮食记录") {
                    savedMealDate130 = card.payload.object?["preview"]?.object?["date"]?.string.flatMap(ClubDates.date(fromKey:)) ?? ClubDates.date(fromKey: job.request.date)
                    showSavedMeals130 = true
                }.buttonStyle(.bordered)
            }
            if result.capability == "training.get_history", let data = result.data {
                ClubTrainingHistoryDetails(data: data)
            }
            if result.isAccepted || result.needsAttention {
                Button("查询原行动状态") {
                    if let execution = result.execution_id { Task { await checkExecution(execution, job: job) } }
                    else { routedResults[job.id] = nil; Task { await routeCapabilities(for: job) } }
                }.buttonStyle(.bordered)
            }
            if result.isCompleted, ["plan.generate_draft", "plan.preview_exercise_swap"].contains(result.capability ?? ""), case .object(let data)? = result.data, data["job_id"]?.string != nil, let execution = result.execution_id {
                Button("查看并编辑候选计划") { Task { await openActionPlan(execution) } }.buttonStyle(.borderedProminent)
            }
            if result.isCompleted, ["body.record_weight", "nutrition.save_entry", "nutrition.create_draft"].contains(result.capability ?? ""),
               case .object(let fields)? = result.data, let commandID = fields["commandId"]?.string {
                Button("撤销这笔记录", role: .destructive) {
                    guard let owner = account.user?.id else { return }
                    Task { if await CapabilityRouter.undo(commandID: commandID, owner: owner, account: account) { await store.refreshAfterMutation130(); if let id = result.execution_id { await checkExecution(id, job: job) } } else { cardActionError = "撤销未确认，请查询状态或在记录页核对。" } }
                }.buttonStyle(.bordered)
            }
        }
    }
    private func openActionPlan(_ id: String) async {
        guard let owner = account.user?.id else { return }
        do {
            let response = try await account.proposalRequest(path: "/me/ai/drafts/" + id, method: "GET", body: nil, expectedUserID: owner)
            guard response.statusCode == 200 else { throw AIClientError.message("候选计划尚未准备好，请先查询进度。") }
            let remote = try JSONDecoder().decode(ClubRemoteActionDraft.self, from: response.data)
            guard account.user?.id == owner else { return }
            try ai.importActionDraft(remote, owner: owner)
            actionPlanRoute = ClubActionPlanRoute(id: id, date: ClubDates.date(fromKey: remote.request.date) ?? Date())
        } catch { cardActionError = AppErrorText.message(error) }
    }

    private func routeStatusLine(_ result: CapabilityRouteResult) -> String {
        switch result.status {
        case "completed", "succeeded", "draft_ready": return "服务端已完成这次只读/直执行操作。"
        case "undone": return "这笔记录已撤销。"
        case "awaiting_confirmation": return "等待你确认后才会生效。"
        case "needs_clarification": return "需要补充信息，尚未修改记录。"
        case "running", "verifying_result", "failed_retryable", "accepted": return "已受理，正在处理中（完成前不代表已经生效）。"
        default: return result.error ?? "这次操作没有完成，可以重新发起。"
        }
    }

    private func handleRouteAction(_ action: AICardAction, card: AICardEnvelope,
                                   result: CapabilityRouteResult, job: AILocalJob) {
        guard AICardRegistry.isRenderable(card), !card.isExpired else { return }
        guard let owner = account.user?.id else { return }
        switch action.action_id {
        case "confirm_proposal":
            guard let proposal = AIProposalPreviewPayload(json: card.payload) else { return }
            guard FeatureFlagService.shared.actionSystemEnabled else {
                routeOutcomes[card.id] = .conflict("AI 行动已暂停，提案与记录仍保留。")
                return
            }
            routeOutcomes[card.id] = .confirming
            Task { @MainActor in
                let outcome = await CapabilityRouter.confirmProposal(kind: proposal.kind, proposalID: proposal.proposalID,
                                                                     owner: owner, account: account)
                switch outcome {
                case .confirmed:
                    let refreshed = await store.refreshAfterMutation130()
                    routeOutcomes[card.id] = refreshed ? .confirmed : .conflict("已保存到账号，正在等待更新到手机。可刷新记录查看。")
                case .conflict(let message):
                    routeOutcomes[card.id] = .conflict(message)
                case .fallback:
                    routeOutcomes[card.id] = .conflict("记录通道暂不可用，请稍后重试。")
                }
            }
        case "discard_training_draft":
            guard let proposal = AIProposalPreviewPayload(json: card.payload), proposal.kind == "training_finish" else { return }
            Task { @MainActor in
                let response = try? await account.proposalRequest(path: "/me/ai/proposals/" + proposal.proposalID + "/discard-training", method: "POST", body: Data("{}".utf8), expectedUserID: owner)
                guard account.user?.id == owner else { return }
                if response?.statusCode == 200 { await store.refreshAfterMutation130(); routeOutcomes[card.id] = .dismissed } else { routeOutcomes[card.id] = .conflict("训练状态有变化，请重新查询。") }
            }
        case "dismiss_proposal":
            guard let proposal = AIProposalPreviewPayload(json: card.payload) else { return }
            Task { @MainActor in
                let cancelled = await CapabilityRouter.cancelProposal(proposalID: proposal.proposalID, owner: owner, account: account)
                guard account.user?.id == owner else { return }
                routeOutcomes[card.id] = cancelled ? .dismissed : .conflict("取消没有成功，请稍后再试。")
            }
        case "check_execution":
            guard let execution = result.execution_id else { return }
            Task { @MainActor in await checkExecution(execution, job: job) }
        default:
            _ = AICardActionRouter.handle(action, card: card, requestDate: card.payloadDate ?? "") { coachAction in
                typing = false
                openCoachAction131(coachAction)
            }
        }
    }

    /// 断网或结果未明时查执行状态，而不是让用户盲目重试（spec §9）。
    private func checkExecution(_ executionID: String, job: AILocalJob) async {
        guard let owner = account.user?.id else { return }
        guard let status = await CapabilityRouter.status(executionID: executionID, owner: owner, account: account) else { return }
        guard account.user?.id == owner else { return }
        var updated = routedResults[job.id] ?? []
        if let index = updated.firstIndex(where: { $0.execution_id == executionID }) {
            var merged = status
            merged.capability = merged.capability ?? updated[index].capability
            merged.execution_id = executionID
            updated[index] = merged
            routedResults[job.id] = updated
        }
        if status.isCompleted { await store.refreshAfterMutation130() }
    }
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var ai: AIService
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session: ClubCoachSession
    private let embeddedInShell: Bool
    private let presetConversation: String?
    private var ownerID: Int? {
        get { session.ownerID }
        nonmutating set { session.ownerID = newValue }
    }
    private var conversation: String {
        get { session.conversation }
        nonmutating set { session.conversation = newValue }
    }
    private var question: String {
        get { session.question }
        nonmutating set { session.question = newValue }
    }
    private var contextDays: Int {
        get { session.contextDays }
        nonmutating set { session.contextDays = newValue }
    }
    private var error: String? {
        get { session.error }
        nonmutating set { session.error = newValue }
    }

    init(session: ClubCoachSession, embeddedInShell: Bool = true) {
        _session = StateObject(wrappedValue: session)
        self.embeddedInShell = embeddedInShell
        presetConversation = session.conversation
    }

    init(initialQuestion: String? = nil, initialConversation: String? = nil, autoSubmit: Bool = false) {
        let state = ClubCoachSession(conversation: initialConversation ?? UUID().uuidString.lowercased(), question: initialQuestion ?? "")
        if autoSubmit { state.sendRequest = 1 }
        _session = StateObject(wrappedValue: state)
        embeddedInShell = false
        presetConversation = initialConversation
    }
    @State private var destination: ClubCoachOpen?
    /// AI 起草卡（meal_draft/weight_entry）确认状态：card_id → 结果横幅。
    private var draftCardOutcomes: [String: ClubDraftCardOutcome] {
        get { session.draftCardOutcomes }
        nonmutating set { session.draftCardOutcomes = newValue }
    }
    @State private var showHistory = false
    @State private var contextStates: [String: String] = [:]
    @State private var currentProposals = Set<String>()
    @FocusState private var typing: Bool
    @State private var historySearch = ""
    @State private var mealRoute: ClubComposerMealRoute?
    @State private var bodyPresented = false
    @State private var copiedReply: String?
    @State private var feedback: [String: String] = [:]
    @State private var reportingJobID: String?
    @State private var showReportAlert = false
    @State private var pendingReeditQuestion: String?
    @State private var showReeditConfirm = false
    /// Phase 2：能力路由结果（按提问任务索引）。服务端决定执行方式，客户端只呈现。
    @State private var mealDraftRoute: ClubMealDraftRoute?
    @State private var savedMealDate130: Date?
    @State private var showSavedMeals130 = false
    @State private var actionPlanRoute: ClubActionPlanRoute?
    @State private var showPlanWizard = false
    @State private var routedResults: [String: [CapabilityRouteResult]] = [:]
    @State private var routingJobs: Set<String> = []
    @State private var routeOutcomes: [String: ClubDraftCardOutcome] = [:]
    @State private var userScrollActive = false
    @State private var nearLatestMessage = true
    @State private var followScrollTask: Task<Void, Never>?
    @State private var followScrollTicket = UUID()
    /// Phase 2 §3.3: live SSE turn. Final turns are imported into `ai.jobs`, so
    /// this bubble disappears and the existing renderer takes over.
    @StateObject private var liveRun = AIRunStreamStore()
    @State private var resumedRunKeys = Set<String>()
    private var preparingReferences: Bool {
        get { session.preparingReferences }
        nonmutating set { session.preparingReferences = newValue }
    }
    @State private var providerConsentSheet = false
    private var turns: [AILocalJob] {
        ClubCoachRules.turns(ai.jobs, conversation: conversation, deleted: Set(store.state.deletedAIJobIDs ?? []))
    }
    private var successfulIDs131: [String] { turns.filter { $0.status == "succeeded" }.map(\.id) }
    private func receiveFeedback131() {
        let successful = turns.filter { $0.status == "succeeded" }
        if let owner = ownerID, let job = successful.first(where: { !knownSucceeded131.contains($0.id) && Date().timeIntervalSince($0.created) < 120 }) {
            BojiInteraction131.received(owner: owner, message: job.id)
        }
        knownSucceeded131.formUnion(successful.map(\.id))
    }
    private var busy: Bool { preparingReferences || (liveRun.isActive && liveRun.conversationKey == conversation) || turns.contains { !$0.isTerminal } }
    private var conversations: [String] {
        var seen = Set<String>(); let deleted = Set(store.state.deletedAIJobIDs ?? [])
        return ai.jobs.filter { !deleted.contains($0.id) }.sorted { $0.created > $1.created }
            .compactMap { ClubCoachRules.conversation($0) }.filter { seen.insert($0).inserted }
    }
    private var conversationPresentation131: some View {
        timeline
            .navigationTitle(embeddedInShell ? "" : "Club AI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { if !embeddedInShell { ToolbarItem(placement: .topBarTrailing) { conversationOptions } } }
            .onChange(of: liveRun.isActive) { _, active in
                if active { session.processingConversation = liveRun.conversationKey }
                else { session.processingConversation = nil }
            }
            .onChange(of: session.references) { _, _ in session.persistExtras() }
            .sheet(isPresented: $providerConsentSheet) { AIProviderConsentSheet() }
            .onAppear {
                if !session.initialized {
                    if presetConversation == nil { conversation = conversations.first ?? conversation }
                    ownerID = store.editingAccountID
                    if question.isEmpty, let ownerID {
                        question = ClubCoachDraftStorage.load(owner: ownerID, conversation: conversation)
                    }
                    session.initialized = true
                }
                if let ownerID, session.attachments.isEmpty,
                   let draft = ClubChatDraftStorage.load(owner: ownerID, conversation: conversation) {
                    session.attachments = draft.attachments
                    if session.references.isEmpty { session.references = draft.references ?? [] }
                    if session.workoutContext == nil { session.workoutContext = draft.context }
                }
                knownSucceeded131 = Set(turns.filter { $0.status == "succeeded" }.map(\.id))
                restoreWorkoutContext()
                refreshContexts()
                consumeSendRequest()
                resumeActiveRunIfNeeded()
            }
            .alert("隐私与数据使用", isPresented: $showDataUse) {
                Button("知道了", role: .cancel) { }
            } message: {
                Text(session.workoutContext == nil
                    ? "主动发送的问题、附件及所选近 \(contextDays) 天已确认记录用于云端 AI 分析。可在设置的隐私说明中关闭；图片不会自动登记为饮食。"
                    : "主动发送的问题、附件和这场已确认训练用于 AI 复盘。其他日期仅用于明确标注的历史对比。可在设置中关闭云端分析。")
            }
            .alert("举报不良回答", isPresented: $showReportAlert) {
                Button("确认举报", role: .destructive) {
                    if let id = reportingJobID {
                        Task { await account.trackEvent(name: "coach_reply_reported", detail: ["job_id": id]) }
                        ClubAccessibility.announce("已收到举报，我们将尽快审查处理")
                    }
                }
                Button("取消", role: .cancel) { }
            } message: {
                Text("感谢你的监督。我们会人工复核该回复内容，持续过滤违规或有害生成。")
            }
            .alert("替换当前正在编辑的文字？", isPresented: $showReeditConfirm) {
                Button("替换", role: .destructive) {
                    if let pending = pendingReeditQuestion {
                        question = pending
                        session.focusRequest += 1
                    }
                    pendingReeditQuestion = nil
                }
                Button("追加到末尾") {
                    if let pending = pendingReeditQuestion {
                        question = question.isEmpty ? pending : (question + "\n" + pending)
                        session.focusRequest += 1
                    }
                    pendingReeditQuestion = nil
                }
                Button("取消", role: .cancel) {
                    pendingReeditQuestion = nil
                }
            } message: {
                Text("输入框中已有未发送的内容，是否替换为这条历史提问？")
            }
            .onChange(of: session.sendRequest) { _, _ in consumeSendRequest() }
            .onChange(of: session.attachments) { _, _ in session.persistExtras() }
            .onChange(of: session.workoutContext) { _, _ in session.persistExtras() }
            .onChange(of: question) { _, value in
                if let ownerID { ClubCoachDraftStorage.save(value, owner: ownerID, conversation: conversation) }
            }
    }
    var body: some View {
        conversationPresentation131
            .onReceive(store.$state) { _ in Task { @MainActor in await Task.yield(); refreshContexts() } }
            .onChange(of: ai.cloudChangeID) { _, _ in refreshContexts() }
            .onChange(of: successfulIDs131) { _, _ in receiveFeedback131() }
            .onChange(of: conversation) { _, _ in refreshContexts() }
            .onChange(of: store.editingAccountID) { _, value in
                if value != ownerID { destination = nil; question = ""; dismiss() }
            }
            .sheet(item: $destination) { ClubCoachDestinationView(action: $0.action, ownerID: ownerID) }
            .sheet(isPresented: $showHistory) { historyView }
            .sheet(item: $mealRoute) { route in MealEditorView(date: route.date, initialEntryMode: route.mode) }
            .sheet(isPresented: $showSavedMeals130) { NavigationStack { NutritionView(selectedDate: Binding(get: { savedMealDate130 ?? Date() }, set: { savedMealDate130 = $0 })).navigationTitle("饮食记录").toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showSavedMeals130 = false } } } } }
            .sheet(isPresented: $bodyPresented) { BodyWeightView(initialDate: Date()) }
            .sheet(item: $mealDraftRoute) { route in
                ClubMealActionEditor(card: route.card) { updated in
                    if let index = routedResults[route.jobID]?.firstIndex(where: { $0.proposal_id == route.id }) {
                        routedResults[route.jobID]?[index] = updated
                    }
                }
            }
            .sheet(item: $actionPlanRoute) { route in NavigationStack { PlanView(date: route.date, initialJobID: route.id) } }
            .sheet(isPresented: $showPlanWizard) {
                NavigationStack {
                    PlanView(date: Date(), onPlanApplied: {
                        showPlanWizard = false
                    })
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("关闭") { showPlanWizard = false }
                        }
                    }
                }
            }
    }

    private var timeline: some View {
        ScrollViewReader { proxy in
            GeometryReader { viewport in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: BojiLayout.Rhythm.headerToContent) {
                        if let context = session.workoutContext { workoutSourceCard(context) }
                        if turns.isEmpty && liveRun.phase == .idle { emptyConversation }
                        ForEach(renderedRows131) { item in
                            Group { switch item.row {
                            case .job(let job):
                                turn(job).id(job.id).task(id: job.id + "/" + job.status) { await routeCapabilities(for: job) }
                            case .live:
                                liveTurn.id("coach-live")
                            } }.transition(reduceMotion131 ? .identity : .opacity.combined(with: .move(edge: .bottom)))
                        }
                        if let error { FlowError(message: error) }
                        if let cardActionError { FlowError(message: cardActionError) }
                        Color.clear.frame(height: 1)
                            .id("coach-bottom")
                            .background { GeometryReader { geometry in
                                Color.clear.preference(key: CoachBottomPosition.self,
                                    value: geometry.frame(in: .named("coach-scroll")).maxY)
                            } }
                    }
                    .animation(reduceMotion131 ? nil : BojiMotion2.state, value: renderedRows131.map(\.id))
                    .scrollTargetLayout()
                    .padding(.vertical, ClubUI.pageInset)
                    .frame(maxWidth: ClubUI.contentWidth).frame(maxWidth: .infinity)
                }
                // Native scroll margins remain outside the target coordinate space when restoring anchors.
                .contentMargins(.horizontal, ClubUI.pageInset, for: .scrollContent)
                .contentMargins(.bottom, 16, for: .scrollContent)
                .coordinateSpace(name: "coach-scroll")
                .scrollPosition(id: Binding(get: { session.followLatest ? nil : session.scrollAnchor }, set: { if !session.followLatest { session.scrollAnchor = $0 } }), anchor: .top)
                .scrollDismissesKeyboard(.interactively)
                .modifier(CoachUserScrollTracking { active, proximity in
                    if userScrollActive != active { userScrollActive = active }
                    if active { followScrollTask?.cancel(); followScrollTask = nil; followScrollTicket = UUID() }
                    else { scheduleLatestMessage(proxy) }
                    if let proximity {
                        if nearLatestMessage != proximity { nearLatestMessage = proximity }
                        if session.followLatest != proximity { session.followLatest = proximity }
                    }
                })
                .onPreferenceChange(CoachBottomPosition.self) { bottom in
                    guard bottom != 0 else { return }
                    let nearBottom = bottom <= viewport.size.height + 100
                    if nearLatestMessage != nearBottom { nearLatestMessage = nearBottom }
                    // Content growth and keyboard resizing must never turn following off.
                    if userScrollActive, session.followLatest != nearBottom { session.followLatest = nearBottom }
                }
                .onAppear { scheduleLatestMessage(proxy) }
                .onDisappear { followScrollTask?.cancel(); followScrollTask = nil; followScrollTicket = UUID() }
                .onChange(of: turns.map { "\($0.id)/\($0.status)" }) { _, _ in scheduleLatestMessage(proxy) }
                .onChange(of: viewport.size.height) { _, _ in scheduleLatestMessage(proxy) }
                .onChange(of: conversation) { _, _ in scheduleLatestMessage(proxy) }
                .onChange(of: session.sendRequest) { _, _ in
                    session.followLatest = true
                    scheduleLatestMessage(proxy)
                }
                .onChange(of: liveRun.streamText) { _, _ in scheduleLatestMessage(proxy) }
                .onChange(of: liveRun.phase) { _, phase in
                    if phase == .streaming { clearAcceptedDraft130() }
                    if phase == .saving || phase == .finished { scheduleLatestMessage(proxy) }
                }
                .onChange(of: error) { _, value in
                    if value != nil { session.followLatest = true; scheduleLatestMessage(proxy) }
                }
                .onChange(of: cardActionError) { _, value in
                    if value != nil { session.followLatest = true; scheduleLatestMessage(proxy) }
                }
                .overlay(alignment: .bottomTrailing) {
                    if !session.followLatest, !turns.isEmpty {
                        Button {
                            session.followLatest = true
                            scheduleLatestMessage(proxy)
                        } label: { Image(systemName: "arrow.down").frame(minWidth: 44, minHeight: 44) }
                        .buttonStyle(.bordered).buttonBorderShape(.circle)
                        .clubGlassEffect(in: Circle())
                        .accessibilityLabel("回到最新消息")
                        .padding(BojiLayout.cardInset)
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if !embeddedInShell { composer }
                }
            }
        }
        .background(BojiColor.pageBackground)
    }

    private func scheduleLatestMessage(_ proxy: ScrollViewProxy) {
        guard session.followLatest, !userScrollActive, followScrollTask == nil else { return }
        let ticket = UUID(); followScrollTicket = ticket
        let currentConversation = conversation
        followScrollTask = Task { @MainActor in
            defer { if followScrollTicket == ticket { followScrollTask = nil } }
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            guard !Task.isCancelled, followScrollTicket == ticket, session.followLatest, !userScrollActive, conversation == currentConversation else { return }
            if reduceMotion131 { proxy.scrollTo("coach-bottom", anchor: .bottom) }
            else { withAnimation(.easeOut(duration: liveRun.isActive ? 0.1 : 0.22)) { proxy.scrollTo("coach-bottom", anchor: .bottom) } }
        }
    }

    private var emptyConversation: some View {
        VStack(alignment: .leading, spacing: BojiLayout.rowGap) {
            Text("想聊什么？").bojiType(.section)
            ForEach(Array(ClubCoachRules.quickQuestions(state: store.state).prefix(2)), id: \.self) { sample in
                Button(sample) { question = sample; session.focusRequest += 1 }
                    .buttonStyle(.borderless).frame(minHeight: 44, alignment: .leading)
            }
        }.padding(.vertical, BojiLayout.blockGap)
    }

    private func consumeSendRequest() {
        guard session.takePendingSend() else { return }
        send()
    }

    private var conversationOptions: some View {
        Menu {
            Button("开启新对话") { session.newConversation(owner: ownerID, keepDraft: true) }
            Button("查看此前对话") { showHistory = true }
            if session.workoutContext == nil {
                Picker("下一条回答方式", selection: $session.deepAnalysis) { Text("自动").tag(false); Text("深入").tag(true) }
                Picker("参考记录", selection: $session.contextDays) {
                    Text("近 7 天").tag(7); Text("近 14 天").tag(14)
                }
            }
            Button("隐私与数据使用") { showDataUse = true }
        } label: { Image(systemName: "ellipsis.bubble").frame(minWidth: 44, minHeight: 44) }
        .accessibilityLabel("对话选项")
    }
    @State private var showDataUse = false
    private func workoutSourceCard(_ context: ClubAIEntryContext) -> some View {
        VStack(alignment: .leading, spacing: BojiLayout.tight) {
            Label("本次训练 · \(context.dateKey)", systemImage: "dumbbell").bojiType(.secondary)
            if !context.isCurrent(owner: store.editingAccountID, state: store.state) {
                Text("这场记录已变化，请核对后更新来源。旧回复不会改写。")
                    .bojiType(.label).foregroundStyle(.secondary)
                Button("核对并使用最新记录") {
                    guard let date = context.date,
                          let fresh = ClubAIEntryContext.make(owner: context.ownerID, date: date, sessionID: context.sessionID, state: store.state) else { return }
                    session.workoutContext = fresh
                }.buttonStyle(.borderless)
            }
            Button("另开普通对话") { session.newConversation(owner: ownerID, keepDraft: true) }
                .bojiType(.caption).buttonStyle(.borderless)
        }.padding(BojiLayout.rowGap).frame(maxWidth: .infinity, alignment: .leading)
            .background(BojiColor.mistSurface, in: RoundedRectangle(cornerRadius: BojiRadius.inner))
    }
    private func restoreWorkoutContext() {
        guard session.references.isEmpty, session.workoutContext == nil, let owner = ownerID,
              let turn = turns.first(where: { $0.request.payload["purpose"]?.string == "workout" }),
              let id = turn.request.payload["source_session"]?.string.flatMap(UUID.init(uuidString:)),
              let date = ClubDates.date(fromKey: turn.request.date) else { return }
        // Keep the original version; a changed source requires explicit reconfirmation.
        let current = ClubAIEntryContext.make(owner: owner, date: date, sessionID: id, state: store.state)
        let version = turn.request.payload["source_version"]?.string ?? current?.sourceVersion ?? "unavailable"
        session.workoutContext = ClubAIEntryContext(ownerID: owner, dateKey: turn.request.date, sessionID: id, sourceVersion: version, chatID: conversation)
    }
    /// Same bubble styling as the frozen transcript; extracted so the live SSE
    /// turn cannot drift visually from a persisted turn.
    private func userBubble(_ text: String) -> some View {
        HStack {
            Spacer(minLength: 36)
            Text(text)
                .bojiType(.body).textSelection(.enabled)
                .padding(.horizontal, BojiLayout.cardInset).padding(.vertical, BojiLayout.rowGap)
                .background(BojiColor.subtleSurface,
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    @ViewBuilder private var liveTurn: some View {
        if liveRun.phase != .idle, liveRun.conversationKey == conversation {
            VStack(alignment: .leading, spacing: BojiLayout.cardInset) {
                userBubble(liveRun.question ?? "")
                if liveRun.streamText.isEmpty && liveRun.isActive {
                    HStack(spacing: BojiLayout.inline) {
                        AIProcessingMark(size:24)
                        Text(liveRun.statusLine ?? "正在分析…")
                            .bojiType(.label).foregroundStyle(BojiColor.textSecondary)
                    }
                } else if !liveRun.streamText.isEmpty {
                    BojiBrandMark(size:22,style:.monochrome)
                    ClubReply130(text: liveRun.streamText, streaming: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("coach-live-reply")
                    if let line = liveRun.statusLine, liveRun.isActive {
                        Text(line).bojiType(.label).foregroundStyle(BojiColor.textSecondary)
                    }
                }
                if liveRun.phase == .failed {
                    Text(liveRun.error ?? "连接已中断，原任务仍保留。").bojiType(.label).foregroundStyle(.secondary)
                    Button("恢复这次回答") {
                        resumedRunKeys.remove(conversation); self.error = nil; resumeActiveRunIfNeeded()
                    }.buttonStyle(.bordered).disabled(liveRun.isActive)
                }
            }
            .padding(.vertical, BojiLayout.tight)
        }
    }

    private func turn(_ job: AILocalJob) -> some View {
        let freshness = contextStates[job.id] ?? "正在读取记录"
        return VStack(alignment: .leading, spacing: BojiLayout.cardInset) {
            userBubble(job.request.payload["question"]?.string ?? "此前提问内容未恢复")
            if let raw = job.request.payload["reference_selection"], let data = try? JSONEncoder().encode(raw), let refs = try? JSONDecoder().decode([AIContextReference].self, from: data) {
                ForEach(refs) { AIReferenceSourceCard(reference: $0) }
            }
            if let images = job.request.payload["images"]?.array, !images.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(Array(images.enumerated()), id: \.offset) { _, item in
                            if let encoded = item.object?["data_base64"]?.string, let data = Data(base64Encoded: encoded), let image = UIImage(data: data) {
                                Image(uiImage: image).resizable().scaledToFit().frame(width: 112, height: 112)
                                    .clipShape(RoundedRectangle(cornerRadius: 12)).accessibilityLabel("已发送照片")
                            } else { Label("照片附件", systemImage: "photo").bojiType(.caption) }
                        }
                    }
                }
            }
            if let answer = job.result?.coach, job.status == "succeeded" {
                BojiBrandMark(size:22,style:.monochrome)
                ClubReply130(text: answer.answer, streaming: false)
                    .accessibilityIdentifier("coach-reply-text")
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !answer.sources.isEmpty {
                    DisclosureGroup("查看用到的记录") {
                        ForEach(answer.sources) { source in
                            VStack(alignment: .leading, spacing: BojiLayout.tight) {
                                Text(source.label).bojiType(.secondary)
                                Text(source.detail).bojiType(.secondary).foregroundStyle(.secondary)
                            }.padding(.vertical, BojiSpace.tight)
                        }
                    }.bojiType(.label).foregroundStyle(.secondary)
                }
                if let proposal = answer.proposal {
                    ClubProposalCard(job: job, proposal: proposal, current: currentProposals.contains(job.id))
                }
                if let schedule = answer.schedule_proposal {
                    ClubScheduleProposalCard(proposal: schedule, jobID: job.id, current: currentProposals.contains(job.id))
                }
                if let cards = answer.cards, !cards.isEmpty {
                    ForEach(cards) { card in
                        AICardView(card: card, outcome: draftOutcome(card)) { action in
                            handleCardAction(action, card: card)
                        }
                        if card.card_type == "meal_draft", draftOutcome(card) == .confirmed {
                            Button("查看这餐") { savedMealDate130 = card.payloadDate.flatMap(ClubDates.date(fromKey:)) ?? Date(); showSavedMeals130 = true }.buttonStyle(.bordered)
                        }
                    }
                }
                if let results = routedResults[job.id], !results.isEmpty {
                    ForEach(results) { result in
                        routedResultView(result, job: job)
                    }
                }
                if freshness == "基于当次提交记录；与当前记录一致" {
                    ForEach(answer.actions) { action in
                        Button(action.label) { typing = false; openCoachAction131(action) }
                            .buttonStyle(.bordered).frame(minHeight: 44)
                    }
                }
                HStack(spacing: BojiLayout.tight) {
                    Button {
                        UIPasteboard.general.string = answer.answer
                        copiedReply = job.id
                        ClubAccessibility.announce("回复已复制")
                    } label: {
                        Image(systemName: copiedReply == job.id ? "checkmark" : "doc.on.doc")
                            .frame(minWidth: 44, minHeight: 44)
                    }.accessibilityLabel(copiedReply == job.id ? "回复已复制" : "复制回复")
                    Button {
                        feedback[job.id] = "helpful"
                        Task { await account.trackEvent(name: "coach_reply_feedback", detail: ["job_id": job.id, "rating": "helpful"]) }
                        ClubAccessibility.announce("谢谢你的反馈")
                    } label: {
                        Image(systemName: feedback[job.id] == "helpful" ? "hand.thumbsup.fill" : "hand.thumbsup")
                            .frame(minWidth: 44, minHeight: 44)
                    }.accessibilityLabel("回复有帮助")
                    .disabled(feedback[job.id] == "helpful")
                    Button {
                        feedback[job.id] = "unhelpful"
                        Task { await account.trackEvent(name: "coach_reply_feedback", detail: ["job_id": job.id, "rating": "unhelpful"]) }
                        ClubAccessibility.announce("已记录你的反馈")
                    } label: {
                        Image(systemName: feedback[job.id] == "unhelpful" ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                            .frame(minWidth: 44, minHeight: 44)
                    }.accessibilityLabel("回复未解决问题")
                    .disabled(feedback[job.id] == "unhelpful")
                    Menu {
                        ShareLink(item: answer.answer) { Label("分享回复", systemImage: "square.and.arrow.up") }
                        Button {
                            let oldQuestion = job.request.payload["question"]?.string ?? ""
                            if question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || question == oldQuestion {
                                question = oldQuestion
                                session.focusRequest += 1
                            } else {
                                pendingReeditQuestion = oldQuestion
                                showReeditConfirm = true
                            }
                        } label: { Label("再次编辑提问", systemImage: "square.and.pencil") }
                        Divider()
                        Button(role: .destructive) {
                            reportingJobID = job.id
                            showReportAlert = true
                        } label: { Label("举报有害或违规内容", systemImage: "flag") }
                    } label: { Image(systemName: "ellipsis").frame(minWidth: 44, minHeight: 44) }
                    .accessibilityLabel("更多回复操作")
                }.buttonStyle(.borderless).foregroundStyle(.secondary)
            } else {
                AIJobStatusView(id: job.id, animated: true)

            }
        }
        .padding(.vertical, BojiLayout.tight)
    }
    private func renderedAnswer(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }

    private func refreshContexts() {
        // Build one context per date/range on actual record changes, not on every keystroke.
        var contexts: [String: JSONValue] = [:]; var states: [String: String] = [:]
        for job in turns {
            let sourceSession = (job.request.payload["source_session"]?.string ?? job.result?.coach?.source_session).flatMap(UUID.init(uuidString:))
            let purpose = ChatContextPurpose127.restored(payload: job.request.payload, sourceSession: sourceSession)
            if purpose == .contextContinue {
                states[job.id] = "沿用选定报告的已确认来源；不代表当前最新记录"; continue
            }
            guard case .number(let span)? = job.request.payload["context_days"], [1.0,7.0,14.0].contains(span), purpose.accepts(days: Int(span)),
                  span == Double(Int(span)), job.request.payload["days"] != nil,
                  let date = ClubDates.date(fromKey: job.request.date) else {
                states[job.id] = "提交依据未完整恢复，不能核对是否最新"; continue
            }
            let key = job.request.date + "/\(Int(span))/" + (sourceSession?.uuidString ?? "all")
            if contexts[key] == nil {
                contexts[key] = (try? ai.coachInput(question: "核对记录依据", conversation: conversation, history: [],
                    through: date, contextDays: Int(span), store: store, sessionID: sourceSession, contextPurpose: purpose))?.payload["days"] ?? .null
            }
            if contexts[key] == .null { states[job.id] = "当前记录暂时无法核对，保留当时回复" }
            else { states[job.id] = contexts[key] == job.request.payload["days"] ? "基于当次提交记录；与当前记录一致" : "记录已有变化，这是当时的回复；可重新提问核对" }
        }
        currentProposals = Set(turns.filter { job in
            guard states[job.id] == "基于当次提交记录；与当前记录一致" else { return false }
            if let proposal = job.result?.coach?.proposal,
               let date = ClubDates.date(fromKey: job.request.date), !ClubDates.isFuture(date), ClubDates.key(date) == ClubDates.key(Date()) {
                return proposal.baseline == ClubAdjustmentRules.upcoming(state: store.state, after: date)
            }
            if let schedule = job.result?.coach?.schedule_proposal, (try? ClubCoachRules.validatedMoves(schedule, state: store.state)) != nil {
                return true
            }
            return false
        }.map(\.id))
        contextStates = states
    }
    private var composer: some View {
        ClubSharedComposer(text: $session.question, attachments: $session.attachments, references: $session.references, deepAnalysis: $session.deepAnalysis, conversationID: conversation, busy: busy,
            enabled: FeatureFlagService.shared.aiEnabled, focusRequest: session.focusRequest,
            onSend: send, onRecordMeal: { mode in mealRoute = ClubComposerMealRoute(date: Date(), mode: mode) },
            onRecordBody: { bodyPresented = true })
            .padding(.horizontal, BojiLayout.rowGap).padding(.bottom, BojiLayout.inline)
    }
    private func send() {
        guard !busy else { return }
        if let context = session.workoutContext {
            guard let owner = ownerID, context.isCurrent(owner: store.editingAccountID, state: store.state) else {
                error = "这场训练有更新，请先使用上方的最新记录。"; return
            }
            let reference = AIContextReference(kind: "workout_session", resourceID: context.sessionID.uuidString.lowercased(), from: context.dateKey, to: context.dateKey, title: context.dateKey + " · 本次训练")
            if FeatureFlagService.shared.referencesEnabled && !session.references.contains(where: { $0.id == reference.id }) { session.references.append(reference) }
            guard owner == store.editingAccountID else { return }
        }
        sendWithReferences()
    }
    private func sendWithReferences() {
        guard !busy else { return }
        if !session.references.isEmpty {
            let refs = session.references; let id = conversation
            let fingerprints131 = Dictionary(refs.map { ($0.id, $0.localFingerprint(store.state)) }, uniquingKeysWith: { first, _ in first })
            let originalText = session.question; let photos = session.attachments; let deep = session.deepAnalysis
            guard let owner = ownerID, ai.routingConsentGranted else { error = "请先开启云端分析。"; return }
            preparingReferences = true; error = nil
            session.referenceSendTask130?.cancel()
            session.referenceSendTask130 = Task { @MainActor in
                defer { if ownerID == owner, conversation == id { preparingReferences = false }; session.referenceSendTask130 = nil }
                do {
                    let bundle = try await AIContextBundle.resolve(refs, conversation: id, owner: owner, store: store, account: account, jobs: ai.jobs)
                    guard !Task.isCancelled, ownerID == owner, conversation == id, session.references == refs,
                          session.question == originalText, session.attachments == photos, session.deepAnalysis == deep else { return }
                    guard refs.allSatisfy({ $0.localFingerprint(store.state) == fingerprints131[$0.id] }) else {
                        error = "引用记录刚有更新，请重新发送；文字已保留。"; return
                    }
                    session.references = bundle.references.map { var ref = $0.reference; ref.localVersion = ref.localFingerprint(store.state); return ref }
                    preparingReferences = false; sendPrepared(bundleID: bundle.bundleID)
                } catch is CancellationError { }
                catch { if ownerID == owner, conversation == id { self.error = AppErrorText.message(error) } }
            }
        } else { sendPrepared() }
    }
    private func sendPrepared(bundleID: String? = nil) {
        guard !busy else { return }
        if liveRun.phase == .failed, AIRunResumeStore.load(owner: ownerID ?? 0, conversation: conversation) != nil {
            error = "上一条回答等待恢复，请先点击‘恢复这次回答’。"; return
        }
        guard FeatureFlagService.shared.aiEnabled else { error = "服务暂时无法连接，请稍后重试。仍可手动记录。"; return }
        guard ownerID != nil, ownerID == store.editingAccountID else { return }
        guard ai.routingConsentGranted else { error = "云端分析已关闭，可在隐私说明中开启后使用对话。"; return }
        do {
            if let context = session.workoutContext, !context.isCurrent(owner: store.editingAccountID, state: store.state) {
                throw AIClientError.message("本次训练来源已变化，请先核对并更新来源。")
            }
            let submittedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? (!session.references.isEmpty ? "请分析我引用的记录。" : "请帮我看看这些照片。") : question
            var input = try ai.coachInput(question: submittedQuestion, conversation: conversation,
                history: ClubCoachRules.history(turns), through: session.reviewScope?.endDate ?? session.workoutContext?.date ?? Date(),
                contextDays: session.continuationSource != nil ? 0 : session.reviewScope?.contextDays ?? (session.workoutContext == nil ? contextDays : 7), store: store,
                sessionID: session.workoutContext?.sessionID, contextPurpose: session.continuationSource != nil ? .contextContinue : session.workoutContext != nil ? .workout : session.reviewScope?.kind == .daily ? .daily : session.reviewScope != nil ? .weekly : .dialogue)
            if let context = session.workoutContext {
                input.payload["purpose"] = .string("workout")
                input.payload["source_session"] = .string(context.sessionID.uuidString.lowercased())
                input.payload["source_version"] = .string(context.sourceVersion)
                if let version = store.log(for: context.date ?? Date())._schedule_version {
                    input.payload["source_schedule_version"] = .number(Double(version))
                }
            }
            if !session.attachments.isEmpty {
                input.payload["images"] = try ClubChatAttachment.payload(session.attachments, owner: ownerID ?? 0, conversation: conversation)
            }
            if let bundleID {
                input.payload["context_bundle_id"] = .string(bundleID)
                if session.reviewScope?.kind != .completedCalendarWeek && session.reviewScope?.kind != .rolling7 { input.payload["purpose"] = .string("dialogue") }
                for field in ["source_session", "source_version", "source_schedule_version"] { input.payload.removeValue(forKey: field) }
                input.payload["reference_selection"] = try JSONValue.encode(session.references)
                input.payload["days"] = .array([]); input.payload["upcoming"] = .array([])
            }
            if let source = session.continuationSource {
                var ref: [String: JSONValue] = ["type": .string(source.type), "id": .string(source.jobID.lowercased())]
                if let version = source.version { ref["version"] = .string(version) }
                if let id = source.sessionID { ref["session_id"] = .string(id) }
                input.payload["context_source"] = .object(ref); input.payload["_context_source"] = .object(ref)
                input.payload["days"] = .array([]); input.payload["upcoming"] = .array([])
            }
            if let scope = session.reviewScope {
                input.payload["review_scope"] = try JSONValue.encode(scope)
                if scope.kind != .daily { input.payload["purpose"] = .string("weekly") }
            }
            input.payload["deep_analysis"] = .bool(session.deepAnalysis)
            let encoded = try JSONEncoder().encode(input.payload)
            guard encoded.count <= 5_600_000 else { throw AIClientError.message("照片和参考记录合计过大，请减少照片或选择近 7 天。") }
            let conversationID = conversation
            session.submittedDraftRevisions130[conversationID] = session.composerRevision130
            session.followLatest = true; session.scrollAnchor = "coach-bottom"
            error = nil; typing = false
            if FeatureFlagService.shared.streamingV2, !account.isPreviewAccount {
                Task { await runStream(input, conversation: conversationID) }
            } else {
                _ = try ai.submit(input, submissionID: session.workoutContext != nil && turns.isEmpty ? conversationID : nil)
                clearSubmittedDraft(input, conversation: conversationID)
            }
        } catch { self.error = AppErrorText.message(error) }
    }

    private func runStream(_ input: AIInput, conversation conversationID: String) async {
        guard let owner = ownerID, owner == store.editingAccountID else { return }
        if let completion = await liveRun.start(input: input, conversation: conversationID, owner: owner, account: account,
            preferredMessageID: session.workoutContext != nil && turns.isEmpty ? conversationID : nil) {
            guard owner == ownerID, owner == store.editingAccountID else { return }
            do { try ai.importStreamedCoach(completion, input: input); BojiInteraction131.received(owner: owner, message: completion.messageID); clearSubmittedDraft(input, conversation: conversationID, submissionID: completion.messageID); liveRun.clearAfterImport() }
            catch { self.error = AppErrorText.message(error); liveRun.preserveImportFailure130() }
            return
        }
        guard owner == ownerID, owner == store.editingAccountID, conversation == conversationID else { return }
        if let message = liveRun.error {
            if liveRun.didCreateRun || liveRun.outcomeUnknown || !liveRun.allowsLegacyFallback {
                // The run may exist server-side: never resubmit under a new id.
                self.error = message
            } else {
                liveRun.clearAfterImport()
                do { _ = try ai.submit(input); clearSubmittedDraft(input, conversation: conversationID) } catch { self.error = AppErrorText.message(error) }
            }
        }
    }

    private func clearAcceptedDraft130() {
        guard liveRun.conversationKey == conversation, let pending = AIRunResumeStore.load(owner: ownerID ?? 0, conversation: conversation) else { return }
        clearSubmittedDraft(pending.input, conversation: conversation, submissionID: pending.messageID)
    }

    private func clearSubmittedDraft(_ input: AIInput, conversation id: String, submissionID: String? = nil) {
        guard conversation == id, ownerID == store.editingAccountID else { return }
        // Streaming acceptance and final import can both arrive; clear a draft only once.
        if let submissionID, !SubmittedDraftClears130.claim(owner: ownerID ?? 0, messageID: submissionID) { return }
        let draftUnchanged = session.submittedDraftRevisions130[id].map { $0 == session.composerRevision130 } ?? true
        if draftUnchanged { session.deepAnalysis = false }
        let original = input.payload["question"]?.string ?? ""
        if draftUnchanged && (question.trimmingCharacters(in: .whitespacesAndNewlines) == original || question.isEmpty || (original == "请帮我看看这些照片。" && question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)) {
            question = ""; ClubCoachDraftStorage.clear(owner: ownerID ?? 0, conversation: id)
        }
        let sent = Set(input.payload["images"]?.array?.compactMap { $0.object?["id"]?.string } ?? [])
        session.attachments.removeAll { sent.contains($0.id.uuidString.lowercased()) }
        if let raw = input.payload["reference_selection"], let data = try? JSONEncoder().encode(raw), let refs = try? JSONDecoder().decode([AIContextReference].self, from: data) {
            session.references.removeAll { ref in refs.contains(where: { $0.id == ref.id }) }
        }
        session.persistExtras()
    }

    private func resumeActiveRunIfNeeded() {
        guard FeatureFlagService.shared.streamingV2, !account.isPreviewAccount,
              let owner = ownerID, owner == store.editingAccountID,
              !resumedRunKeys.contains(conversation) else { return }
        if let pending = AIRunPendingStore.load(owner: owner, conversation: conversation) {
            // A POST whose response was lost: replay the same identity instead
            // of creating a new job/channel.
            resumedRunKeys.insert(conversation)
            Task {
                if let completion = await liveRun.start(input: pending.input, conversation: pending.conversation,
                                                        owner: owner, account: account) {
                    guard owner == ownerID, owner == store.editingAccountID else { return }
                    do { try ai.importStreamedCoach(completion, input: pending.input); liveRun.clearAfterImport() }
                    catch { self.error = AppErrorText.message(error); liveRun.preserveImportFailure130() }
                }
            }
            return
        }
        guard let saved = AIRunResumeStore.load(owner: owner, conversation: conversation) else { return }
        resumedRunKeys.insert(conversation)
        Task {
            if let completion = await liveRun.resume(saved, owner: owner, account: account) {
                guard owner == ownerID, owner == store.editingAccountID else { return }
                do { try ai.importStreamedCoach(completion, input: saved.input); liveRun.clearAfterImport() }
                catch { self.error = AppErrorText.message(error); liveRun.preserveImportFailure130() }
            }
        }
    }
    private var historyView: some View {
        NavigationStack {
            List {
                if conversations.isEmpty { Text("还没有保存的对话。") }
                ForEach(conversations.filter { id in
                    historySearch.isEmpty || ClubCoachRules.turns(ai.jobs, conversation: id, deleted: Set(store.state.deletedAIJobIDs ?? []))
                        .contains { ($0.request.payload["question"]?.string ?? "").localizedCaseInsensitiveContains(historySearch)
                            || ($0.result?.coach?.answer ?? "").localizedCaseInsensitiveContains(historySearch) }
                }, id: \.self) { id in
                    let jobs = ClubCoachRules.turns(ai.jobs, conversation: id, deleted: Set(store.state.deletedAIJobIDs ?? []))
                    Button {
                        session.selectConversation(id, owner: ownerID); showHistory = false
                    } label: {
                        VStack(alignment: .leading, spacing: BojiLayout.tight) {
                            Text(jobs.first?.request.payload["question"]?.string ?? "此前对话").lineLimit(2)
                            Text(jobs.last.map { ClubDates.label($0.created, format: "M月d日 HH:mm") } ?? "")
                                .bojiType(.label).foregroundStyle(.secondary)
                        }.padding(.vertical, BojiSpace.tight)
                    }
                }
            }.searchable(text: $historySearch, prompt: "搜索对话")
                .navigationTitle("此前对话").toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { showHistory = false } } }
        }
    }
}

/// B5：对话日程提案卡。模型只给意图（from→to），程序核查后进入同一顺延预览确认流程。
struct ClubScheduleProposalCard: View {
    let proposal: ClubScheduleProposal
    let jobID: String
    let current: Bool
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var account: AccountService
    @State private var shift: ShiftScheduleView?
    @State private var error: String?
    @State private var syncing = false

    /// C2：行动状态与阅读状态分开。已执行＝存在一份顺延记录覆盖本次全部 from→to；
    /// 未执行时按依据是否最新显示待处理/已过期/已拒绝。
    private var actionID: String { "coach-schedule-" + jobID }
    private var rejected: Bool { store.actionState(actionID)?.isRejected == true }
    private var applied: Bool {
        guard !proposal.moves.isEmpty else { return false }
        return store.state.days.values.contains { day in
            (day.planShifts ?? []).contains { record in
                proposal.moves.allSatisfy { record.moves[$0.from] == $0.to }
            }
        }
    }
    private var actionStateLabel: String {
        if applied { return "已完成" }
        if rejected { return "已拒绝" }
        return current ? "待处理" : "已过期"
    }
    private var actionStateColor: Color {
        if applied { return BojiColor.textPrimary }
        return current && !rejected ? BojiColor.textSecondary : BojiColor.textTertiary
    }
    var body: some View {
        VStack(alignment: .leading, spacing: BojiLayout.rowGap) {
            HStack {
                Text("待你确认的日程调整").bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
                Spacer()
                Text(actionStateLabel).bojiFont(.label)
                    .foregroundStyle(actionStateColor)
                    .padding(.horizontal, BojiLayout.inline).padding(.vertical, BojiLayout.tight)
                    .background(BojiColor.inputSurface, in: Capsule())
            }
            Text("这是提案，不会直接改动安排。核对通过后进入预览，确认时才会更新未来日程。")
                .bojiFont(.secondary).foregroundStyle(BojiColor.textSecondary)
            ForEach(proposal.moves, id: \.from) { move in
                HStack(spacing: BojiLayout.inline) {
                    Text(ClubDates.date(fromKey: move.from).map { ClubDates.label($0, format: "M月d日") } ?? move.from)
                        .bojiFont(.label).foregroundStyle(BojiColor.textSecondary)
                    Image(systemName: "arrow.right").bojiType(.label).foregroundStyle(BojiColor.textTertiary)
                    Text(ClubDates.date(fromKey: move.to).map { ClubDates.label($0, format: "M月d日") } ?? move.to)
                        .bojiFont(.label).foregroundStyle(BojiColor.textPrimary)
                    Spacer(minLength: 0)
                }
            }
            Button(applied ? "已应用这项调整" : (syncing ? "正在核对…" : "预览这个调整")) {
                Task { @MainActor in
                    syncing = true
                    defer { syncing = false }
                    do {
                        let moves = try ClubCoachRules.validatedMoves(proposal, state: store.state)
                        // Preview is read-only. Only ShiftScheduleView's final confirmation can execute.
                        shift = ShiftScheduleView(presetMoves: moves, reason: "coach_schedule_shift"); error = nil
                    } catch { self.error = AppErrorText.message(error) }
                }
            }
            .buttonStyle(BojiButtonStyle(kind: .secondary))
            .disabled(!current || applied || rejected || syncing)
            if !applied && !rejected {
                Button("忽略这项调整") {
                    if !store.recordActionState(id: actionID, state: ClubActionRecord.stateRejected, note: "用户不采用日程调整建议") {
                        error = store.takeMessage(fallback: "建议状态未能保存，请重试。")
                    }
                }.buttonStyle(BojiButtonStyle(kind: .secondary))
            }
            if let error { Text(error).bojiFont(.secondary).foregroundStyle(.red) }
        }
        .bojiCard()
        .sheet(item: $shift) { $0 }
    }
}

private struct ClubCoachDestinationView: View {
    let action: ClubCoachAction
    let ownerID: Int?
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Group {
            if ownerID != nil, ownerID == store.editingAccountID, let date = ClubDates.date(fromKey: action.date) {
                switch action.type {
                case "plans":
                    PlanView(date: max(date, Date()))
                case "schedule_shift":
                    NavigationStack {
                        ShiftScheduleView()
                            .toolbar { ToolbarItem(placement: .cancellationAction) { DismissButton() } }
                    }
                case "nutrition":
                    if !ClubDates.isFuture(date) {
                        MealEditorView(date: date)
                    } else {
                        EmptyNote(title: "尚未到记录日期", detail: "未来的饮食请在当天开始后再记录。")
                    }
                case "body":
                    if !ClubDates.isFuture(date) {
                        BodyWeightView(initialDate: date)
                    } else {
                        EmptyNote(title: "尚未到记录日期", detail: "未来的体重请在当天测量后再记录。")
                    }
                case "training":
                    if !ClubDates.isFuture(date) {
                        NavigationStack {
                            WorkoutView(selectedDate: .constant(date), focused: true)
                                .toolbar { ToolbarItem(placement: .cancellationAction) { DismissButton() } }
                        }
                        .onAppear { store.trainingInterfacePresented = true }
                        .onDisappear { store.trainingInterfacePresented = false }
                    } else {
                        EmptyNote(title: "尚未到训练日期", detail: "未来的训练请在当天开始。")
                    }
                default:
                    EmptyNote(title: "暂不支持这项操作", detail: "请从计划或记录页面继续。")
                }
            } else {
                EmptyNote(title: "账号或记录状态已变化", detail: "请关闭页面重新核对。")
            }
        }.onChange(of: store.editingAccountID) { _, value in if value != ownerID { dismiss() } }
    }
}


private struct ClubTrainingHistoryDetails: View {
    let data: JSONValue
    private struct History: Decodable {
        struct Day: Decodable, Identifiable {
            struct Movement: Decodable {
                struct Set: Decodable { let set_number: Int; let weight: Double; let reps: Int; let duration_seconds: Int? }
                let name: String; let sets: [Set]
            }
            let date: String; let movements: [Movement]; var id: String { date }
        }
        let days: [Day]
    }
    private var days: [History.Day] { (try? JSONDecoder().decode(History.self, from: JSONEncoder().encode(data)))?.days.sorted { $0.date > $1.date } ?? [] }
    var body: some View {
        ForEach(days.prefix(10)) { day in
            VStack(alignment: .leading, spacing: BojiLayout.tight) {
                Text(day.date).bojiType(.caption).foregroundStyle(.secondary)
                ForEach(Array(day.movements.enumerated()), id: \.offset) { _, movement in
                    Text(movement.name).bojiType(.secondary)
                    ForEach(Array(movement.sets.enumerated()), id: \.offset) { _, set in
                        Text("第\(set.set_number)组 · " + (set.duration_seconds.map { "\($0) 秒" } ?? "\(set.weight.formatted()) kg × \(set.reps) 次")).bojiType(.caption)
                    }
                }
            }
        }
    }
}

/// An edit creates a fresh server preview and invalidates the old one; saving here never commits a meal.
private struct ClubMealActionEditor: View {
    let card: AICardEnvelope
    let onSaved: (CapabilityRouteResult) -> Void
    @EnvironmentObject private var account: AccountService
    @Environment(\.dismiss) private var dismiss
    private struct Row: Identifiable {
        let id = UUID()
        var name: String; var category: String; var portion: String
        var calories: String; var protein: String; var carbs: String; var fat: String
        var estimated: Bool; var confidence: Double?
        init(_ value: JSONValue) {
            let f: [String: JSONValue]; if case .object(let fields) = value { f = fields } else { f = [:] }
            name = f["name"]?.string ?? ""; category = f["category"]?.string ?? "午餐"; portion = f["portion"]?.string ?? ""
            func number(_ key: String) -> String { f[key]?.numberValue.map { String($0) } ?? "" }
            calories = number("calories"); protein = number("protein"); carbs = number("carbs"); fat = number("fat")
            estimated = f["estimated"]?.boolValue ?? true; confidence = f["confidence"]?.numberValue
        }
        func payload() throws -> JSONValue {
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIClientError.message("请填写食物名称。") }
            var f: [String: JSONValue] = ["name": .string(name), "category": .string(category), "portion": .string(portion), "estimated": .bool(estimated)]
            for (key, text) in [("calories", calories), ("protein", protein), ("carbs", carbs), ("fat", fat)] {
                guard !text.isEmpty else { continue }
                guard let n = Double(text.replacingOccurrences(of: ",", with: ".")), n.isFinite, n >= 0 else { throw AIClientError.message("营养值请填写非负数字；不确定可留空。") }
                f[key] = .number(n)
            }
            if let confidence { f["confidence"] = .number(confidence) }
            return .object(f)
        }
    }
    @State private var rows: [Row] = []
    @State private var date = ""
    @State private var owner: Int?
    @State private var busy = false
    @State private var error: String?
    @State private var editID = UUID().uuidString.lowercased()
    var body: some View {
        NavigationStack {
            Form {
                Section { Text("确认食物、份量和估算值。保存编辑后会生成新的确认卡片，确认卡片后才记入饮食记录。").bojiType(.label).foregroundStyle(.secondary) }
                Section("登记日期") { TextField("yyyy-MM-dd", text: $date) }
                ForEach($rows) { $row in
                    Section {
                        TextField("食物名称", text: $row.name)
                        Picker("餐次", selection: $row.category) { ForEach(["早餐", "午餐", "晚餐", "加餐"], id: \.self) { Text($0) } }
                        TextField("份量与单位，例如 150 g", text: $row.portion)
                        HStack { Text("热量 kcal"); TextField("未知可留空", text: $row.calories).keyboardType(.decimalPad) }
                        HStack { Text("蛋白质 g"); TextField("未知可留空", text: $row.protein).keyboardType(.decimalPad) }
                        HStack { Text("碳水 g"); TextField("未知可留空", text: $row.carbs).keyboardType(.decimalPad) }
                        HStack { Text("脂肪 g"); TextField("未知可留空", text: $row.fat).keyboardType(.decimalPad) }
                        Toggle("营养值为估算", isOn: $row.estimated)
                        if let confidence = row.confidence { Text("识别置信信息：\(Int(confidence * 100))%；请自行核对份量。").bojiType(.caption).foregroundStyle(.secondary) }
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }.disabled(busy)
            .navigationTitle("编辑饮食草稿").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) { Button(busy ? "保存中" : "保存编辑") { Task { await save() } }.disabled(busy || rows.isEmpty) }
            }
            .onAppear {
                guard owner == nil else { return }; owner = account.user?.id
                if case .object(let f) = card.payload { date = f["date"]?.string ?? ""; if case .array(let meals) = f["meals"] { rows = meals.map(Row.init) } }
            }
        }
    }
    private func save() async {
        guard let owner, owner == account.user?.id, let proposal = AIProposalPreviewPayload(json: card.payload) else { error = "账号已变化，请重新打开。"; return }
        busy = true; defer { busy = false }
        do {
            let body: [String: JSONValue] = ["edit_id": .string(editID), "payload": .object(["date": .string(date), "meals": .array(try rows.map { try $0.payload() })])]
            let response = try await account.proposalRequest(path: "/me/ai/proposals/" + proposal.proposalID + "/meal-draft", method: "PUT", body: try JSONEncoder().encode(body), expectedUserID: owner)
            guard response.statusCode == 200 else { throw AIClientError.message((try? JSONDecoder().decode(ClubCommandErrorResponse.self, from: response.data))?.error ?? "草稿已变化，请重新读取。") }
            let updated = try JSONDecoder().decode(CapabilityRouteResult.self, from: response.data)
            guard owner == account.user?.id else { return }; onSaved(updated); dismiss()
        } catch { self.error = AppErrorText.message(error) }
    }
}
