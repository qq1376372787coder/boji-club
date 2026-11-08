import Foundation

struct ClubCoachSource: Identifiable, Codable, Equatable {
    let id: String
    let date: String
    let label: String
    let detail: String
}
struct ClubCoachAction: Codable, Equatable, Identifiable {
    let type: String
    let date: String
    var id: String { type + "/" + date }
    var label: String {
        switch type {
        case "training": return "查看当天训练"
        case "nutrition": return "登记饮食"
        case "body": return "查看身体记录"
        case "plans": return "预览新的训练方案"
        case "daily": return "查看当天分析"
        case "weekly": return "进入每周回顾"
        case "schedule_shift": return "预览日程调整"
        default: return "暂不支持的操作"
        }
    }
}
/// B5：对话日程意图的受控结构化提案。只声明 from→to，绝不直接执行；
/// 经程序核查后进入与手动顺延相同的预览确认流程。
struct ClubScheduleMove: Codable, Equatable {
    let from: String
    let to: String
}
struct ClubScheduleProposal: Codable, Equatable {
    let version: Int
    let moves: [ClubScheduleMove]
    let baseline: [AIPlanSession]
}
struct ClubCoachAnswer: Codable, Equatable {
    /// Phase 2：模型请求的能力调用。仅为请求，执行方式由服务端决定（spec §3）。
    /// 嵌套在回答结构内，便于按结构整体解码与复用。
    struct CapabilityCall: Codable, Equatable {
        var capability: String
        var input: [String: JSONValue] = [:]
    }
    let answer: String
    let sources: [ClubCoachSource]
    let actions: [ClubCoachAction]
    var purpose: String? = nil
    var source_session: String? = nil
    var proposal: ClubParameterProposal? = nil
    var schedule_proposal: ClubScheduleProposal? = nil
    /// V2 只读卡片（schema v1）。旧服务端不下发 → nil；未知卡类型由 CardRegistry 降级。
    var cards: [AICardEnvelope]? = nil
    /// Phase 2：模型请求的能力调用（仅为请求）。
    var capability_calls: [CapabilityCall]? = nil
    /// Restricted onboarding candidates (server validated; never confirmed facts).
    var onboarding: ClubOnboardingOutput? = nil
    var prompt_version: String? = nil
    var safety_blocked: Bool? = nil
}

struct ClubOnboardingCandidate: Codable, Equatable {
    var field: String
    var value: JSONValue
    var unit: String?
    var evidence_quote: String
}

struct ClubOnboardingOutput: Codable, Equatable {
    var schema_version: Int
    var candidates: [ClubOnboardingCandidate]
}

enum ClubCoachRules {
    static func conversation(_ job: AILocalJob) -> String? {
        guard job.request.kind == "coach", ["dialogue", "workout"].contains(job.result?.coach?.purpose ?? job.request.payload["purpose"]?.string ?? "dialogue") else { return nil }
        return job.request.payload["conversation_id"]?.string ?? job.id
    }
    static func turns(_ jobs: [AILocalJob], conversation: String, deleted: Set<String>) -> [AILocalJob] {
        jobs.filter { self.conversation($0) == conversation && !deleted.contains($0.id) && $0.replacementID == nil }
            .sorted { $0.created == $1.created ? $0.id < $1.id : $0.created < $1.created }
    }
    static func history(_ jobs: [AILocalJob]) -> [JSONValue] {
        var pairs: [[JSONValue]] = []; var characters = 0
        for job in jobs.reversed() {
            guard job.status == "succeeded", let question = job.request.payload["question"]?.string,
                  let answer = job.result?.coach?.answer else { continue }
            let shortAnswer = String(answer.prefix(4000))
            guard pairs.count < 6, characters + question.count + shortAnswer.count <= 16000 else { break }
            characters += question.count + shortAnswer.count
            pairs.insert([.object(["role": .string("user"), "text": .string(question)]),
                          .object(["role": .string("assistant"), "text": .string(shortAnswer)])], at: 0)
        }
        return pairs.flatMap { $0 }
    }

    /// B5：日程提案程序核查。模型只声明意图；这里逐条验证日期、可移动性与基线，
    /// 通过后才交给顺延预览确认流程。绝不把模型输出直接当执行指令。
    static func validatedMoves(_ proposal: ClubScheduleProposal, state: SavedState, now: Date = Date()) throws -> [(String, String)] {
        guard proposal.version == 1, (1...7).contains(proposal.moves.count) else {
            throw AIClientError.message("日程提案格式无法识别，请重新描述。")
        }
        // 基线校验：提案生成后未来安排或参数已变化 → 不再采用，要求重新提问。
        guard proposal.baseline == ClubAdjustmentRules.upcoming(state: state, after: now) else {
            throw AIClientError.message("日程提案依据的未来安排已有变化，请重新提问后再核对。")
        }
        let movableKeys = Set(ClubShiftRules.movableDates(state: state, now: now).map(ClubDates.key))
        // from 与 to 分别去重；同一日期可以既是某步目标又是另一步源（A→B、B→C 链式移动合法）。
        var seenFrom = Set<String>(), seenTo = Set<String>()
        var result: [(String, String)] = []
        for move in proposal.moves {
            guard let from = ClubDates.date(fromKey: move.from), let to = ClubDates.date(fromKey: move.to),
                  ClubDates.isFuture(from, now: now), ClubDates.isFuture(to, now: now), move.from != move.to else {
                throw AIClientError.message("提案包含无效日期，未执行任何修改。")
            }
            guard movableKeys.contains(move.from) else {
                throw AIClientError.message("\(move.from) 的安排已开始或已变化，不能按提案移动。")
            }
            guard seenFrom.insert(move.from).inserted, seenTo.insert(move.to).inserted else {
                throw AIClientError.message("提案日期重复，请重新描述。")
            }
            result.append((move.from, move.to))
        }
        return result
    }
}

enum ClubCoachDraftStorage {
    private static func key(owner: Int, conversation: String) -> String {
        "club-coach-draft.v1.\(owner).\(conversation)"
    }
    private static func indexKey(owner: Int) -> String { "club-coach-draft-index.v1.\(owner)" }
    static func load(owner: Int, conversation: String, defaults: UserDefaults = .standard) -> String {
        guard owner != 0 else { return "" }
        return defaults.string(forKey: key(owner: owner, conversation: conversation)) ?? ""
    }
    static func save(_ text: String, owner: Int, conversation: String, defaults: UserDefaults = .standard) {
        guard owner != 0, UUID(uuidString: conversation) != nil else { return }
        if text.isEmpty { clear(owner: owner, conversation: conversation, defaults: defaults) }
        else {
            defaults.set(text, forKey: key(owner: owner, conversation: conversation))
            var ids = defaults.stringArray(forKey: indexKey(owner: owner)) ?? []
            ids.removeAll { $0 == conversation }; ids.insert(conversation, at: 0)
            defaults.set(ids, forKey: indexKey(owner: owner))
        }
    }
    static func clear(owner: Int, conversation: String, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(owner: owner, conversation: conversation))
        var ids = defaults.stringArray(forKey: indexKey(owner: owner)) ?? []
        ids.removeAll { $0 == conversation }; defaults.set(ids, forKey: indexKey(owner: owner))
    }
    /// Erase all indexed and legacy drafts for exactly one account, including preview accounts.
    static func erase(owner: Int, defaults: UserDefaults = .standard) {
        guard owner != 0 else { return }
        let prefix = "club-coach-draft.v1.\(owner)."
        for item in defaults.dictionaryRepresentation().keys where item.hasPrefix(prefix) {
            defaults.removeObject(forKey: item)
        }
        defaults.removeObject(forKey: indexKey(owner: owner))
        ClubChatDraftStorage.erase(owner: owner)
    }

    /// Include drafts created by older builds, which had no discovery index.
    static func conversations(owner: Int, defaults: UserDefaults = .standard) -> [String] {
        guard owner != 0 else { return [] }
        let prefix = "club-coach-draft.v1.\(owner)."
        let legacy = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }.sorted()
        var seen = Set<String>()
        return ((defaults.stringArray(forKey: indexKey(owner: owner)) ?? []) + legacy + ClubChatDraftStorage.conversations(owner: owner)).filter {
            UUID(uuidString: $0) != nil && (!load(owner: owner, conversation: $0, defaults: defaults).isEmpty || ClubChatDraftStorage.load(owner: owner, conversation: $0)?.attachments.isEmpty == false) && seen.insert($0).inserted
        }
    }
}

extension ClubCoachRules {
    /// 只提供当前记录真正能回答的快捷问题，不把空数据包装成可分析。
    static func quickQuestions(state: SavedState, now: Date = Date()) -> [String] {
        var questions: [String] = []
        let recent = (0..<14).compactMap { offset -> DayLog? in
            guard let date = ClubDates.calendar.date(byAdding: .day, value: -offset, to: now) else { return nil }
            return state.days[ClubDates.key(date)]
        }
        let todayKey = ClubDates.key(now)
        let todayTrained = state.days[todayKey]?.hasConfirmedTraining == true
        if todayTrained {
            questions.append("复盘今天的训练")
        } else if let lastTrainingOffset = (1..<14).first(where: { offset in
            guard let date = ClubDates.calendar.date(byAdding: .day, value: -offset, to: now) else { return false }
            return state.days[ClubDates.key(date)]?.hasConfirmedTraining == true
        }), let lastDate = ClubDates.calendar.date(byAdding: .day, value: -lastTrainingOffset, to: now) {
            let dateStr = ClubDates.label(lastDate, format: "M月d日")
            questions.append("复盘\(dateStr)的训练")
        }
        if recent.contains(where: { $0.bodyWeight?.hasMeasurement == true }) { questions.append("看看近两周体重变化") }
        if state.days.values.contains(where: { day in day.planCycle?.plannedDates.isEmpty == false }) { questions.append("帮我评估本周安排") }
        if recent.contains(where: { !$0.meals.isEmpty }) { questions.append("我记录的饮食和当前目标相符吗？") }
        if questions.isEmpty { questions = ["今天最值得改的一件事是什么？", "我该怎么开始记录？"] }
        return Array(questions.prefix(3))
    }
}

extension AIService {
    func coachInput(question: String, conversation: String, history: [JSONValue], through date: Date,
                    contextDays: Int, store: AppStore, sessionID: UUID? = nil, contextPurpose: ChatContextPurpose127 = .dialogue) throws -> AIInput {
        guard contextPurpose.accepts(days: contextDays), UUID(uuidString: conversation) != nil,
              !ClubDates.isFuture(date) else { throw AIClientError.message("对话日期或上下文不正确。") }
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, question.count <= 1200 else { throw AIClientError.message("请把这次问题控制在 1200 字以内。") }
        var days: [JSONValue] = []; var groups = 0; var meals = 0
        for offset in (0..<contextDays).reversed() {
            guard let day = ClubDates.calendar.date(byAdding: .day, value: -offset, to: date) else { continue }
            var log = store.log(for: day)
            if offset == 0, let sessionID {
                guard let session = log.workoutSessions?.first(where: { $0.id == sessionID }), session.savedAt != nil else { throw AIClientError.message("本次训练尚未确认保存。") }
                log.exercises = log.exercises.filter { $0.workoutSessionID == sessionID }
                log.workoutSessions = [session]; log.activeWorkoutSessionID = sessionID
                log.workoutStartedAt = session.startedAt; log.workoutEndedAt = session.endedAt; log.workoutSavedAt = session.savedAt
                log.linkedDeviceWorkoutID = nil
            }
            // Include today even without records, to explain current observed goals;
            // never create empty historical dates that imply an observation existed.
            if offset > 0 && !DailyReportEligibility.hasRecords(log) && log.exercises.isEmpty { continue }
            groups += log.totalSets; meals += log.meals.count
            guard groups <= 2100, meals <= 200 else { throw AIClientError.message("这段时间记录较多，请先选择近 7 天，或在每日分析中查看更细的记录。") }
            let input = try reportInput(date: day, log: log, nutritionTarget: store.reportNutritionTarget(on: day),
                weightHistory: [], goalContext: ClubAIContext.make(state: store.state, start: day, end: day), allowEmpty: true)
            days.append(.object(["date": .string(ClubDates.key(day)), "payload": .object(input.payload)]))
        }
        let upcoming = ClubAdjustmentRules.upcoming(state: store.state, after: date)
        return AIInput(kind: "coach", date: ClubDates.key(date), payload: ["version": .number(1),
            "conversation_id": .string(conversation), "question": .string(question), "history": .array(history),
            "days": .array(days), "upcoming": try .encode(upcoming), "context_days": .number(Double(contextDays)), "timeZone": .string(TimeZone.current.identifier)])
    }
}

struct ClubAIEntryContext: Codable, Equatable {
    let ownerID: Int
    let dateKey: String
    let sessionID: UUID
    let sourceVersion: String
    var chatID: String? = nil
    var conversationID: String { chatID ?? ClubAutomaticReports.jobID(owner: ownerID, mode: "workout", key: sessionID.uuidString.lowercased()) }
    var date: Date? { ClubDates.date(fromKey: dateKey) }
    static let defaultQuestion = "帮我复盘这次训练，说说做得怎么样，以及下次可以注意什么。"
    static func make(owner: Int, date: Date, sessionID: UUID, state: SavedState) -> Self? {
        guard let snapshot = ConfirmedWorkoutSnapshot.make(owner: owner, date: date, sessionID: sessionID,
            day: state.days[ClubDates.key(date)] ?? DayLog()) else { return nil }
        let archived = Set(state.deletedAIJobIDs ?? [])
        var conversation = ClubAutomaticReports.jobID(owner: owner, mode: "workout", key: sessionID.uuidString.lowercased())
        // Repeated entry reuses this identity. An explicitly deleted thread starts a new stable generation.
        for _ in 0...archived.count {
            if !archived.contains(conversation) { break }
            conversation = ClubAutomaticReports.jobID(owner: owner, mode: "workout-chat", key: sessionID.uuidString.lowercased() + "/after/" + conversation)
        }
        return Self(ownerID: owner, dateKey: snapshot.dateKey, sessionID: sessionID, sourceVersion: snapshot.signature, chatID: conversation)
    }
    func isCurrent(owner: Int?, state: SavedState) -> Bool {
        guard owner == ownerID, let date else { return false }
        return Self.make(owner: ownerID, date: date, sessionID: sessionID, state: state)?.sourceVersion == sourceVersion
    }
    @MainActor static func open(owner: Int, date: Date, sessionID: UUID) {
        NotificationCenter.default.post(name: .clubOpenWorkoutAI, object: nil,
            userInfo: ["owner": owner, "date": ClubDates.key(date), "session": sessionID.uuidString])
    }
}
extension Notification.Name { static let clubOpenWorkoutAI = Notification.Name("clubOpenWorkoutAI") }
