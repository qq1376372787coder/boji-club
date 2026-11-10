import SwiftUI
import PhotosUI
import Vision
import UIKit
import Combine
import CryptoKit

// MARK: - Wire models

extension JSONValue {
    var intValue: Int? { numberValue.map(Int.init) }
    var arrayValue: [JSONValue]? { if case .array(let value) = self { return value }; return nil }

    static func any(_ value: Any) -> JSONValue {
        switch value {
        case let value as String: return .string(value)
        case let value as Bool: return .bool(value)
        case let value as Int: return .number(Double(value))
        case let value as Double: return .number(value)
        case let value as [Any]: return .array(value.map(JSONValue.any))
        case let value as [String: Any]:
            var out: [String: JSONValue] = [:]
            for (key, item) in value { out[key] = .any(item) }
            return .object(out)
        default: return .null
        }
    }

    var anyValue: Any {
        switch self {
        case .string(let value): return value
        case .number(let value): return value
        case .bool(let value): return value
        case .array(let values): return values.map(\.anyValue)
        case .object(let values): return values.mapValues(\.anyValue)
        case .null: return NSNull()
        }
    }

    var displayText: String {
        switch self {
        case .string(let value): return value
        case .number(let value): return value.formatted(.number.precision(.fractionLength(0...2)))
        case .bool(let value): return value ? "是" : "否"
        case .array(let values): return values.map(\.displayText).joined(separator: "、")
        case .object(let values): return values.keys.sorted().compactMap { values[$0]?.displayText }.joined(separator: "、")
        case .null: return "未填写"
        }
    }
}

enum OnboardingTaskKind: String, CaseIterable, Codable {
    case planCreate = "plan_create"
    case planImport = "plan_import"
    case mealLog = "meal_log"
    case workoutLog = "workout_log"
    case explore
    case nutritionGoal = "nutrition_goal"

    var defaultTitle: String {
        switch self {
        case .planCreate: return "帮我安排训练"
        case .planImport: return "整理已有计划"
        case .mealLog: return "先记录一餐"
        case .workoutLog: return "先记录训练"
        case .explore: return "先了解一下"
        case .nutritionGoal: return "了解饮食目标"
        }
    }
    var symbol: String {
        switch self {
        case .planCreate: return "calendar.badge.plus"
        case .planImport: return "doc.text.magnifyingglass"
        case .mealLog: return "fork.knife"
        case .workoutLog: return "dumbbell"
        case .explore: return "sparkles"
        case .nutritionGoal: return "leaf"
        }
    }
}

extension OnboardingTaskKind {
    static func suggested(for text: String) -> OnboardingTaskKind {
        let value=text.lowercased()
        if value.range(of:"导入|整理.*计划|已有.*计划|import",options:.regularExpression) != nil { return .planImport }
        if value.range(of:"记录.*(餐|饭)|早餐|午餐|晚餐|吃了|meal",options:.regularExpression) != nil { return .mealLog }
        if value.range(of:"记录.*训练|练了|完成了.*组",options:.regularExpression) != nil { return .workoutLog }
        if value.range(of:"营养目标|热量目标|饮食目标",options:.regularExpression) != nil { return .nutritionGoal }
        if value.range(of:"增肌|减脂|安排.*训练|制定.*计划|每周.*练|一周.*次|在家.*哑铃",options:.regularExpression) != nil { return .planCreate }
        return .explore
    }
}

enum OnboardingFieldKind {
    case choice([String])
    case multiChoice([String])
    case integer(ClosedRange<Int>)
    case decimal(ClosedRange<Double>)
    case text(Int)
    case date
}

enum OnboardingFieldSpec: String, CaseIterable {
    case nickname, personalPreferences, equipmentOther, homeTrainingDays, goal, experience, venue, equipment, equipmentExclusions, daysPerWeek, trainingDays,
         sessionMinutes, ageGroup, ageYears, sexForNutrition, heightCm, profileWeightKg,
         targetWeightKg, weightMeasurementKind, weightObservedAt, limitations, nutritionContext, dailyActivity, focus

    var apiKey: String {
        switch self {
        case .personalPreferences: return "personal_preferences"
        case .equipmentOther: return "equipment_other"
        case .homeTrainingDays: return "home_training_days"
        case .daysPerWeek: return "days_per_week"
        case .trainingDays: return "training_days"
        case .sessionMinutes: return "session_minutes"
        case .ageGroup: return "age_group"
        case .ageYears: return "age_years"
        case .sexForNutrition: return "sex_for_nutrition"
        case .heightCm: return "height_cm"
        case .profileWeightKg: return "profile_weight_kg"
        case .targetWeightKg: return "target_weight_kg"
        case .weightMeasurementKind: return "weight_measurement_kind"
        case .weightObservedAt: return "weight_observed_at"
        case .nutritionContext: return "nutrition_context"
        case .dailyActivity: return "daily_activity"
        case .equipmentExclusions: return "equipment_exclusions"
        default: return rawValue
        }
    }
    static func from(apiKey: String) -> OnboardingFieldSpec? {
        allCases.first { $0.apiKey == apiKey }
    }
    var title: String {
        switch self {
        case .nickname: return "姓名 / 昵称"
        case .personalPreferences: return "我的习惯与偏好"
        case .equipmentOther: return "其他器械"
        case .homeTrainingDays: return "在家训练日"
        case .goal: return "主要目标"
        case .experience: return "训练经验"
        case .venue: return "训练地点"
        case .equipment: return "可用器械"
        case .equipmentExclusions: return "没有或不想用的器械"
        case .daysPerWeek: return "每周训练次数"
        case .trainingDays: return "可训练日期"
        case .sessionMinutes: return "每次时长"
        case .ageGroup: return "年龄范围"
        case .ageYears: return "年龄"
        case .sexForNutrition: return "营养计算资料"
        case .heightCm: return "身高"
        case .profileWeightKg: return "目前体重"
        case .targetWeightKg: return "目标体重"
        case .weightMeasurementKind: return "体重性质"
        case .weightObservedAt: return "体重日期"
        case .limitations: return "需要留意的情况"
        case .nutritionContext: return "饮食评估方式"
        case .dailyActivity: return "日常活动"
        case .focus: return "优先部位"
        }
    }
    var unit: String? {
        switch self {
        case .heightCm: return "cm"
        case .profileWeightKg, .targetWeightKg: return "kg"
        case .daysPerWeek: return "days_per_week"
        case .sessionMinutes: return "minutes"
        case .ageYears: return "years"
        default: return nil
        }
    }
    var kind: OnboardingFieldKind {
        switch self {
        case .nickname: return .text(40)
        case .personalPreferences: return .text(500)
        case .equipmentOther: return .text(100)
        case .homeTrainingDays: return .multiChoice(["周一", "周二", "周三", "周四", "周五", "周六", "周日"])
        case .goal: return .choice(["增肌塑形", "减脂瘦身", "紧致线条", "提升力量", "养成运动习惯"])
        case .experience: return .choice(["新手", "有基础", "进阶"])
        case .venue: return .choice(["健身房", "在家", "两者都有"])
        case .equipment: return .multiChoice(["徒手", "哑铃", "弹力带", "壶铃", "引体向上杆", "瑜伽垫", "小杠铃", "卧推凳", "有氧器械"])
        case .equipmentExclusions: return .multiChoice(["深蹲架", "杠铃", "器械推胸", "腿举机"])
        case .daysPerWeek: return .integer(1...7)
        case .trainingDays: return .multiChoice(["周一", "周二", "周三", "周四", "周五", "周六", "周日"])
        case .sessionMinutes: return .integer(15...180)
        case .ageGroup: return .choice(["adult", "minor"])
        case .ageYears: return .integer(13...100)
        case .sexForNutrition: return .choice(["男", "女", "不愿提供"])
        case .heightCm: return .decimal(50...250)
        case .profileWeightKg, .targetWeightKg: return .decimal(20...400)
        case .weightMeasurementKind: return .choice(["measured", "estimated"])
        case .weightObservedAt: return .date
        case .limitations: return .text(500)
        case .nutritionContext: return .choice(["普通成人", "孕期或哺乳期", "需按医生建议饮食"])
        case .dailyActivity: return .choice(["主要久坐", "经常站立走动", "日常体力活动较多"])
        case .focus: return .multiChoice(["全身", "胸部", "背部", "肩部", "手臂", "臀腿", "核心"])
        }
    }
    func choiceLabel(_ raw: String) -> String {
        switch (self, raw) {
        case (.ageGroup, "adult"): return "18 岁及以上"
        case (.ageGroup, "minor"): return "未满 18 岁"
        case (.weightMeasurementKind, "measured"): return "实测"
        case (.weightMeasurementKind, "estimated"): return "估计"
        default: return raw
        }
    }
    func rawChoice(_ label: String) -> String {
        switch (self, label) {
        case (.ageGroup, "18 岁及以上"): return "adult"
        case (.ageGroup, "未满 18 岁"): return "minor"
        case (.weightMeasurementKind, "实测"): return "measured"
        case (.weightMeasurementKind, "估计"): return "estimated"
        default: return label
        }
    }
    var allowsSkip: Bool {
        switch self {
        case .goal, .experience, .venue, .daysPerWeek, .trainingDays, .sessionMinutes, .ageGroup: return false
        default: return true
        }
    }
    func displayValue(_ value: JSONValue?) -> String {
        guard let value, value != .null else { return "未填写" }
        if case .multiChoice(_) = kind, let rows = value.arrayValue {
            if self == .trainingDays || self == .homeTrainingDays {
                return rows.compactMap(\.intValue).sorted().map { "周" + ["一","二","三","四","五","六","日"][max(0, min(6, $0 - 1))] }.joined(separator: "、")
            }
            if self == .ageGroup {
                return rows.first?.displayText == "minor" ? "未满 18 岁" : "18 岁及以上"
            }
            return rows.map(\.displayText).joined(separator: "、")
        }
        if self == .ageGroup {
            return value.string == "minor" ? "未满 18 岁" : "18 岁及以上"
        }
        if self == .weightMeasurementKind {
            return value.string == "measured" ? "实测" : value.string == "estimated" ? "估计" : "未说明"
        }
        return value.displayText + (displayUnit133.map { " \($0)" } ?? "")
    }
}

struct OnboardingFactSummary: Codable, Equatable {
    var value: JSONValue
    var unit: String?
    var sourceKind: String?
    var observedAt: String?
    var updatedAt: String?
    enum CodingKeys: String, CodingKey { case value, unit; case sourceKind = "source_kind"; case observedAt = "observed_at"; case updatedAt = "updated_at" }
    var sourceLabel: String {
        switch sourceKind {
        case "confirmed": return "已确认"
        case "legacy_recorded": return "历史录入"
        default: return "来源未说明"
        }
    }
}

struct OnboardingDraftField: Codable, Equatable {
    var value: JSONValue
    var unit: String?
    var origin: String?
    var evidenceQuote: String?
    var updatedAt: String?
    enum CodingKeys: String, CodingKey { case value, unit, origin; case evidenceQuote = "evidence_quote"; case updatedAt = "updated_at" }
    var originLabel: String { origin == "model_candidate" ? "AI 建议，待核对" : "你填写的草稿" }
}

struct OnboardingV2Draft: Codable, Equatable {
    var fields: [String: OnboardingDraftField] = [:]
    var skipped: [String] = []
    var artifacts: [String: OnboardingDraftField] = [:]
    var firstPlan: [String: JSONValue] = [:]
    enum CodingKeys: String, CodingKey { case fields, skipped, artifacts; case firstPlan = "first_plan" }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fields = (try? c.decode([String: OnboardingDraftField].self, forKey: .fields)) ?? [:]
        skipped = (try? c.decode([String].self, forKey: .skipped)) ?? []
        artifacts = (try? c.decode([String: OnboardingDraftField].self, forKey: .artifacts)) ?? [:]
        firstPlan = (try? c.decode([String: JSONValue].self, forKey: .firstPlan)) ?? [:]
    }
}

struct OnboardingSessionInfo: Codable, Equatable {
    var id: String
    var schemaVersion: Int
    var revision: Int
    var status: String
    var taskKind: String
    var conversationID: String?
    var firstJobID: String?
    var firstProposalID: String?
    var firstCommandID: String?
    var createdAt: String?
    var updatedAt: String?
    var completedAt: String?
    var deferredAt: String?
    enum CodingKeys: String, CodingKey {
        case id, schemaVersion = "schema_version", revision, status, taskKind = "task_kind"
        case conversationID = "conversation_id", firstJobID = "first_job_id", firstProposalID = "first_proposal_id"
        case firstCommandID = "first_command_id", createdAt = "created_at", updatedAt = "updated_at"
        case completedAt = "completed_at", deferredAt = "deferred_at"
    }
}

struct OnboardingCapabilities: Codable, Equatable {
    var assistAvailable = false
    var assistBudgetRemaining = 0
    var initialPlanAvailable = false
    var initialPlanJobsUsed = 0
    var initialPlanLimit = 5
    var membershipActive = false
    enum CodingKeys: String, CodingKey {
        case assistAvailable = "assist_available", assistBudgetRemaining = "assist_budget_remaining"
        case initialPlanAvailable = "initial_plan_available", initialPlanJobsUsed = "initial_plan_jobs_used"
        case initialPlanLimit = "initial_plan_limit", membershipActive = "membership_active"
    }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        assistAvailable = (try? c.decode(Bool.self, forKey: .assistAvailable)) ?? false
        assistBudgetRemaining = (try? c.decode(Int.self, forKey: .assistBudgetRemaining)) ?? 0
        initialPlanAvailable = (try? c.decode(Bool.self, forKey: .initialPlanAvailable)) ?? false
        initialPlanJobsUsed = (try? c.decode(Int.self, forKey: .initialPlanJobsUsed)) ?? 0
        initialPlanLimit = (try? c.decode(Int.self, forKey: .initialPlanLimit)) ?? 5
        membershipActive = (try? c.decode(Bool.self, forKey: .membershipActive)) ?? false
    }
}

struct OnboardingContent: Codable, Equatable {
    struct Tip: Codable, Equatable, Identifiable { var id: String; var title: String; var body: String; var screen: String }
    var welcomeTitle = "今天，想先做什么？"
    var welcomeBody = "选一件小事开始；资料可以慢慢补充，没说的内容会保持未知。"
    var taskLabels: [String: String] = [:]
    var tips: [Tip] = []
    enum CodingKeys: String, CodingKey { case welcomeTitle = "welcome_title", welcomeBody = "welcome_body", taskLabels = "task_labels", tips }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        welcomeTitle = (try? c.decode(String.self, forKey: .welcomeTitle)) ?? welcomeTitle
        welcomeBody = (try? c.decode(String.self, forKey: .welcomeBody)) ?? welcomeBody
        taskLabels = (try? c.decode([String: String].self, forKey: .taskLabels)) ?? [:]
        tips = (try? c.decode([Tip].self, forKey: .tips)) ?? []
    }
    func label(_ kind: OnboardingTaskKind) -> String { taskLabels[kind.rawValue].flatMap { $0.isEmpty ? nil : $0 } ?? kind.defaultTitle }
    func tip(_ screen: String) -> Tip? { tips.first { $0.screen == screen } }
}

struct OnboardingAssistUsage: Codable, Equatable {
    var day: String?
    var used = 0
    var limit = 10
    var remaining = 0
}

struct OnboardingTranscriptMessage: Codable, Equatable, Identifiable {
    var role: String
    var text: String
    var createdAt: String?
    var id: String { (createdAt ?? "") + role + text.prefix(16) }
    enum CodingKeys: String, CodingKey { case role, text; case createdAt = "created_at" }
}

struct OnboardingV2State: Codable, Equatable {
    var schemaVersion = 1
    var basicProfileStatus: String?
    var taskCompleteAvailable = false
    var session: OnboardingSessionInfo?
    var profileRevision = 0
    var pendingProposal: OnboardingProposal?
    var confirmedFacts: [String: OnboardingFactSummary] = [:]
    var draft = OnboardingV2Draft()
    var skippedFields: [String] = []
    var requiredFields: [String] = []
    var requiredMissing: [String] = []
    var planReady = false
    var safetyBlocked = false
    var safetyMessage: String?
    var capabilities = OnboardingCapabilities()
    var content = OnboardingContent()
    var recentMessages: [OnboardingTranscriptMessage] = []
    var assistUsage = OnboardingAssistUsage()
    var enabled = true
    var isEmpty = false
    var promptVersion: String?
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", session, profileRevision = "profile_revision", pendingProposal = "pending_profile_proposal"
        case confirmedFacts = "confirmed_facts", draft, skippedFields = "skipped_fields"
        case requiredFields = "required_fields", requiredMissing = "required_missing_fields"
        case planReady = "plan_ready", safetyBlocked = "safety_blocked", safetyMessage = "safety_message",
             capabilities, content, recentMessages = "recent_messages"
        case basicProfileStatus = "basic_profile_status", taskCompleteAvailable = "task_complete_available"
        case assistUsage = "assist_usage", enabled, isEmpty = "empty", promptVersion = "prompt_version"
    }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        basicProfileStatus = try? c.decode(String.self,forKey:.basicProfileStatus)
        taskCompleteAvailable = (try? c.decode(Bool.self,forKey:.taskCompleteAvailable)) ?? false
        schemaVersion = (try? c.decode(Int.self, forKey: .schemaVersion)) ?? 1
        session = try? c.decodeIfPresent(OnboardingSessionInfo.self, forKey: .session)
        profileRevision = (try? c.decode(Int.self, forKey: .profileRevision)) ?? 0
        pendingProposal = try? c.decodeIfPresent(OnboardingProposal.self,forKey:.pendingProposal)
        confirmedFacts = (try? c.decode([String: OnboardingFactSummary].self, forKey: .confirmedFacts)) ?? [:]
        draft = (try? c.decode(OnboardingV2Draft.self, forKey: .draft)) ?? OnboardingV2Draft()
        skippedFields = (try? c.decode([String].self, forKey: .skippedFields)) ?? []
        requiredFields = (try? c.decode([String].self, forKey: .requiredFields)) ?? []
        requiredMissing = (try? c.decode([String].self, forKey: .requiredMissing)) ?? []
        planReady = (try? c.decode(Bool.self, forKey: .planReady)) ?? false
        safetyBlocked = (try? c.decode(Bool.self, forKey: .safetyBlocked)) ?? false
        safetyMessage = try? c.decodeIfPresent(String.self, forKey: .safetyMessage)
        capabilities = (try? c.decode(OnboardingCapabilities.self, forKey: .capabilities)) ?? OnboardingCapabilities()
        content = (try? c.decode(OnboardingContent.self, forKey: .content)) ?? OnboardingContent()
        recentMessages = (try? c.decode([OnboardingTranscriptMessage].self, forKey: .recentMessages)) ?? []
        assistUsage = (try? c.decode(OnboardingAssistUsage.self, forKey: .assistUsage)) ?? OnboardingAssistUsage()
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? true
        isEmpty = (try? c.decode(Bool.self, forKey: .isEmpty)) ?? false
        promptVersion = try? c.decodeIfPresent(String.self, forKey: .promptVersion)
    }
}

struct ProfileFactsDocument: Codable, Equatable {
    var schemaVersion = 1
    var revision = 0
    var facts: [String: OnboardingFactSummary] = [:]
    enum CodingKeys: String, CodingKey { case schemaVersion = "schema_version", revision, facts }
}

struct OnboardingProposal: Codable, Equatable {
    var proposalID: String
    var expiresAt: String?
    var profileRevision: Int
    var sessionRevision: Int
    var before: [String: OnboardingFactSummary] = [:]
    var after: [String: OnboardingFactSummary] = [:]
    var unknownFields: [String] = []
    enum CodingKeys: String, CodingKey {
        case proposalID = "proposal_id", expiresAt = "expires_at", profileRevision = "profile_revision"
        case sessionRevision = "session_revision", before, after, unknownFields = "unknown_fields"
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        proposalID = try c.decode(String.self, forKey: .proposalID)
        expiresAt = try? c.decodeIfPresent(String.self, forKey: .expiresAt)
        profileRevision = (try? c.decode(Int.self, forKey: .profileRevision)) ?? 0
        sessionRevision = (try? c.decode(Int.self, forKey: .sessionRevision)) ?? 0
        before = (try? c.decode([String: OnboardingFactSummary].self, forKey: .before)) ?? [:]
        after = (try? c.decode([String: OnboardingFactSummary].self, forKey: .after)) ?? [:]
        unknownFields = (try? c.decode([String].self, forKey: .unknownFields)) ?? []
    }
}

struct OnboardingConfirmResponse: Codable {
    struct Receipt: Codable { var commandID: String?; var committedAt: String?; enum CodingKeys: String, CodingKey { case commandID = "command_id", committedAt = "committed_at" } }
    struct Effects: Codable { var profileUpdated = false; var measurementCreated = false; var planChanged = false; enum CodingKeys: String, CodingKey { case profileUpdated = "profile_updated", measurementCreated = "measurement_created", planChanged = "plan_changed" } }
    var status: String
    var profileRevision: Int?
    var receipt: Receipt?
    var effects: Effects?
    var state: OnboardingV2State?
    var profile: ProfileFactsDocument?
    enum CodingKeys: String, CodingKey { case status; case profileRevision = "profile_revision"; case receipt, effects, state, profile }
}

struct OnboardingAPIError: LocalizedError {
    var message: String
    var status: Int
    var errorDescription: String? { message }
    var isConflict: Bool { status == 409 }
    var isExpired: Bool { status == 410 }
}

// MARK: - Model

@MainActor
final class OnboardingV2Model: ObservableObject {
    @Published private(set) var state: OnboardingV2State?
    @Published private(set) var facts: ProfileFactsDocument?
    @Published private(set) var loading = false
    @Published private(set) var saving = false
    @Published private(set) var proposal: OnboardingProposal?
    @Published private(set) var planJobID: String?
    @Published private(set) var planBusy = false
    @Published private(set) var error: String?
    @Published private(set) var notice: String?
    @Published private(set) var lastAssistantAnswer: String?
    @Published private(set) var streamingText = ""
    @Published private(set) var isAssisting = false
    @Published private(set) var adoptedReceipt: String?

    private let liveRun = AIRunStreamStore()
    private var cancellables = Set<AnyCancellable>()
    private var planWaitTask: Task<Void, Never>?

    init() {
        liveRun.$streamText.receive(on: RunLoop.main).sink { [weak self] text in
            self?.streamingText = text
        }.store(in: &cancellables)
        liveRun.$phase.receive(on: RunLoop.main).sink { [weak self] phase in
            self?.isAssisting = phase != .idle && phase != .finished
        }.store(in: &cancellables)
    }

    var hasSession: Bool { state?.session != nil }
    var isDeferred: Bool { state?.session?.status == "deferred" }
    var isCompleted: Bool { state?.session?.status == "completed" }
    var planReady: Bool { state?.planReady == true }
    var taskKind: OnboardingTaskKind? { state?.session.flatMap { OnboardingTaskKind(rawValue: $0.taskKind) } }

    func reset() {
        planWaitTask?.cancel(); planWaitTask = nil
        state = nil; facts = nil; proposal = nil; planJobID = nil
        error = nil; notice = nil; lastAssistantAnswer = nil; streamingText = ""; adoptedReceipt = nil
    }

    private var loadedOwner133: Int?
    private var mutationTail133: Task<Void,Never>?
    private var mutationCount133=0

    func load(account: AccountService) async {
        #if DEBUG
        if account.isPreviewAccount { loadPreview(); return }
        #endif
        guard let uid = account.user?.id else { return }
        if loadedOwner133 != uid {
            loadedOwner133=uid;state=nil;facts=nil;proposal=nil;planJobID=nil;error=nil;notice=nil;lastAssistantAnswer=nil
        }
        loading = true; defer { loading = false }
        if state == nil,let cached=OnboardingMutationRecovery.cachedState(owner:uid) { state=try? JSONDecoder().decode(OnboardingV2State.self,from:cached) }
        await OnboardingMutationRecovery.replay(account:account,owner:uid)
        do {
            let stateData = try await request(account: account, path: "/me/onboarding/v2", method: "GET", expectedUserID: uid)
            let decoded = try JSONDecoder().decode(OnboardingV2State.self, from: stateData)
            state = decoded
            proposal = decoded.pendingProposal
            OnboardingMutationRecovery.saveState(stateData,owner:uid)
            if !OnboardingMutationRecovery.entries(owner:uid,review:true).isEmpty { notice="有未提交的修改保存在本机，可从我的任务中重新核对。" }
            if let job = decoded.session?.firstJobID, planJobID == nil { planJobID = job }
            await loadFacts(account: account)
            if decoded.session == nil, account.user?.onboardingCompleted == false,
               UserDefaults.standard.bool(forKey: "onboarding.v2.legacy-imported.\(uid)") == false,
               let snapshot = LegacyOnboardingDraftMigration.snapshot(owner: uid) {
                await createSession(OnboardingTaskKind(rawValue: snapshot.taskKind) ?? .planCreate, account: account)
                if let session = state?.session, error == nil {
                    let changes = snapshot.fields.map { ["field": $0.key, "value": $0.value.anyValue, "unit": NSNull()] }
                    await patch(changes: changes, origin: "legacy_draft", account: account)
                    if error == nil {
                        UserDefaults.standard.set(true, forKey: "onboarding.v2.legacy-imported.\(uid)")
                        notice = "已把旧版未完成草稿读入待核对资料；没有自动确认，也没有重新生成计划。"
                    }
                }
            }
        } catch {
            self.error = AppErrorText.message(error)
        }
    }

    func loadFacts(account: AccountService) async {
        guard let uid = account.user?.id, !account.isPreviewAccount else { return }
        do {
            let data = try await request(account: account, path: "/me/profile-facts", method: "GET", expectedUserID: uid)
            let document = try JSONDecoder().decode(ProfileFactsDocument.self, from: data)
            facts = document
        } catch {
            self.error = AppErrorText.message(error)
        }
    }

    func applyFacts(to store: AppStore) {
        guard let facts else { return }
        let values = facts.facts.mapValues(\.value)
        let meta = facts.facts.mapValues { ProfileFactMeta(sourceKind: $0.sourceKind ?? "legacy_recorded", confirmedAt: nil, revision: nil) }
        store.applyV2ProfileFacts(values, meta: meta)
    }

    func createSession(_ kind: OnboardingTaskKind, account: AccountService) async {
        #if DEBUG
        if account.isPreviewAccount {
            var preview = OnboardingV2State()
            preview.session = OnboardingSessionInfo(id: UUID().uuidString.lowercased(), schemaVersion: 1, revision: 1,
                status: "task_selected", taskKind: kind.rawValue, conversationID: UUID().uuidString.lowercased(),
                firstJobID: nil, firstProposalID: nil, firstCommandID: nil, createdAt: nil, updatedAt: nil, completedAt: nil, deferredAt: nil)
            preview.requiredFields = Self.PROFILE_PREVIEW_REQUIRED[kind] ?? []
            preview.requiredMissing = preview.requiredFields
            preview.capabilities = OnboardingCapabilities()
            preview.capabilities.assistAvailable = false
            preview.enabled = true
            state = preview
            return
        }
        #endif
        await mutate(account: account) {
            let key = UUID().uuidString.lowercased()
            var body: [String: Any] = ["schema_version": 1, "task_kind": kind.rawValue]
            if let revision=self.state?.session?.revision { body["expected_session_revision"]=revision }
            let data = try await self.request(account: account, path: "/me/onboarding/v2/sessions", method: "POST", body: body, idempotency: key, expectedUserID: account.user?.id ?? 0)
            self.state = try JSONDecoder().decode(OnboardingV2State.self, from: data)
            await self.loadFacts(account: account)
        }
    }

    func patch(field: OnboardingFieldSpec, value: JSONValue?, skip: Bool = false, account: AccountService) async {
        var change: [String: Any]? = nil
        if let value { change = ["field": field.apiKey, "value": value.anyValue, "unit": field.unit ?? NSNull()] }
        await patch(changes: change.map { [$0] } ?? [], skipped: skip ? [field.apiKey] : [], account: account)
    }

    func patch(changes: [[String: Any]], skipped: [String] = [], origin: String = "user_form", account: AccountService) async {
        guard state?.session != nil else { return }
        #if DEBUG
        if account.isPreviewAccount {
            var preview = state ?? OnboardingV2State()
            for change in changes {
                guard let field = change["field"] as? String else { continue }
                preview.draft.fields[field] = OnboardingDraftField(value: JSONValue.any(change["value"] ?? NSNull()), unit: change["unit"] as? String,
                    origin: origin, evidenceQuote: nil, updatedAt: nil)
            }
            preview.draft.skipped = Array(Set(preview.draft.skipped + skipped))
            preview.session?.revision += 1
            preview.session?.status = "collecting"
            preview.requiredMissing = preview.requiredFields.filter { preview.draft.fields[$0] == nil }
            state = preview
            return
        }
        #endif
        let sessionID=state?.session?.id
        await mutate(account: account) {
            guard let session=self.state?.session,session.id==sessionID else { throw OnboardingAPIError(message:"当前任务已改变，请重新选择。",status:409) }
            let body: [String: Any] = ["schema_version": 1, "expected_session_revision": session.revision,
                                       "origin": origin, "changes": changes, "skipped": skipped]
            let data = try await self.request(account: account, path: "/me/onboarding/v2/sessions/\(session.id)/draft", method: "PATCH", body: body, idempotency: UUID().uuidString.lowercased(), expectedUserID: account.user?.id ?? 0)
            self.state = try JSONDecoder().decode(OnboardingV2State.self, from: data)
        }
    }

    func previewProfile(account: AccountService) async -> Bool {
        guard let session = state?.session else { return false }
        saving = true; error = nil; proposal = nil
        defer { saving = false }
        do {
            let body: [String: Any] = ["expected_profile_revision": state?.profileRevision ?? 0,
                                       "expected_session_revision": session.revision]
            let data = try await request(account: account, path: "/me/onboarding/v2/sessions/\(session.id)/profile-preview", method: "POST", body: body, idempotency: UUID().uuidString.lowercased(), expectedUserID: account.user?.id ?? 0)
            proposal = try JSONDecoder().decode(OnboardingProposal.self, from: data)
            return true
        } catch {
            self.error = AppErrorText.message(error)
            return false
        }
    }

    func confirmProfile(account: AccountService) async -> Bool {
        guard let session = state?.session, let proposal else { return false }
        saving = true; error = nil
        defer { saving = false }
        do {
            let body: [String: Any] = ["proposal_id": proposal.proposalID,
                                       "expected_profile_revision": proposal.profileRevision,
                                       "expected_session_revision": proposal.sessionRevision]
            let data = try await request(account: account, path: "/me/onboarding/v2/sessions/\(session.id)/profile-confirm", method: "POST", body: body, idempotency: UUID().uuidString.lowercased(), expectedUserID: account.user?.id ?? 0)
            let decoded = try JSONDecoder().decode(OnboardingConfirmResponse.self, from: data)
            if let state = decoded.state { self.state = state }
            else { await load(account: account) }
            await loadFacts(account: account)
            self.notice = "资料已确认并保存。计划没有自动改变；需要调整时再单独预览。"
            self.proposal = nil
            return decoded.status == "committed"
        } catch {
            self.error = AppErrorText.message(error)
            return false
        }
    }

    func resume(account: AccountService) async {
        guard state?.session != nil else { return }
        await patch(changes: [], account: account)
    }

    func deferSession(account: AccountService) async {
        guard let session = state?.session else { return }
        #if DEBUG
        if account.isPreviewAccount {
            state?.session?.status = "deferred"
            notice = "已保存稍后继续（开发预览，不会写入服务端）。"
            return
        }
        #endif
        await mutate(account: account) {
            let body: [String: Any] = ["expected_session_revision": session.revision]
            let data = try await self.request(account: account, path: "/me/onboarding/v2/sessions/\(session.id)/defer", method: "POST", body: body, idempotency: UUID().uuidString.lowercased(), expectedUserID: account.user?.id ?? 0)
            self.state = try JSONDecoder().decode(OnboardingV2State.self, from: data)
            self.notice = "已保存稍后继续；没有填写的资料仍是未知。"
        }
    }

    func completeSession(account: AccountService, covenantVersion: String) async -> Bool {
        guard let session = state?.session else { return false }
        #if DEBUG
        if account.isPreviewAccount {
            try? await account.completeOnboarding()
            state?.session?.status = "completed"
            notice = "这一件事已完成（开发预览）。"
            return true
        }
        #endif
        saving = true; error = nil
        defer { saving = false }
        do {
            let body: [String: Any] = ["expected_session_revision": session.revision, "covenant_version": covenantVersion]
            let data = try await request(account: account, path: "/me/onboarding/v2/sessions/\(session.id)/complete", method: "POST", body: body, idempotency: UUID().uuidString.lowercased(), expectedUserID: account.user?.id ?? 0)
            self.state = try JSONDecoder().decode(OnboardingV2State.self, from: data)
            self.notice = "已完成。其他未完成事项可以稍后继续。"
            await account.refreshAccount()
            if account.user?.onboardingCompleted == true { account.enterClub() }
            return true
        } catch {
            self.error = AppErrorText.message(error)
            return false
        }
    }

    func sendAssist(_ text: String, account: AccountService, ai: AIService) async {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, question.count <= 1200, let session = state?.session,
              let conversation = session.conversationID, let uid = account.user?.id, uid > 0 else { return }
        #if DEBUG
        if account.isPreviewAccount { error = "开发预览不连接引导模型；请用原生卡片继续。"; return }
        #endif
        guard ai.routingConsentGranted else { error = "云端分析尚未开启，可在隐私说明中开启后使用 AI 对话；原生卡片仍可填写。"; return }
        guard state?.capabilities.assistAvailable == true else { error = "今天的引导 AI 次数已用完或引导已暂停；请继续使用原生卡片，明天会自动恢复。"; return }
        error = nil; streamingText = ""; lastAssistantAnswer = nil; isAssisting = true
        defer { isAssisting = false }
        var payload: [String: JSONValue] = [
            "version": .number(1), "conversation_id": .string(conversation), "question": .string(question),
            "history": .array([]), "days": .array([]), "upcoming": .array([]),
            "context_days": .number(0), "timeZone": .string(TimeZone.current.identifier),
            "_onboarding_session_id": .string(session.id)
        ]
        let input = AIInput(kind: "coach", date: ClubDates.key(Date()), payload: payload)
        if FeatureFlagService.shared.streamingV2, !account.isPreviewAccount {
            if let completion = await liveRun.start(input: input, conversation: conversation, owner: uid, account: account) {
                lastAssistantAnswer = completion.coach.answer
                await load(account: account)
                return
            }
            if liveRun.didCreateRun || liveRun.outcomeUnknown || !liveRun.allowsLegacyFallback {
                error = liveRun.error ?? "本次引导回答未完成，输入已保留。"
                return
            }
            payload = input.payload
        }
        do {
            let jobID = try ai.submit(AIInput(kind: "coach", date: input.date, payload: payload), onboardingSessionID: session.id)
            let answer = await waitForJob(jobID, ai: ai)
            if let answer { lastAssistantAnswer = answer; await load(account: account) }
            else if error == nil { error = "这次引导回答未能完成，输入已保留；可稍后重试。" }
        } catch {
            self.error = AppErrorText.message(error)
        }
    }

    private func waitForJob(_ id: String, ai: AIService) async -> String? {
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline, !Task.isCancelled {
            if let job = ai.job(id) {
                if job.status == "succeeded" { return job.result?.coach?.answer }
                if ["failed", "deleted", "expired", "rejected"].contains(job.status) {
                    error = job.error ?? "这次引导回答未完成。"
                    return nil
                }
            }
            try? await Task.sleep(for: .seconds(1))
        }
        return nil
    }

    func generatePlan(kind: OnboardingTaskKind, importedText: String? = nil, account: AccountService, ai: AIService) async {
        guard let session = state?.session, [.planCreate, .planImport].contains(kind) else { return }
        error = nil; notice = nil; planBusy = true; defer { planBusy = false }
        if kind == .planCreate, !planReady { error = "请先核对生成计划所需的资料。"; return }
        let profile = v2ProfilePayload()
        let startKey = state?.draft.fields["first_plan_start_date"]?.value.string ?? ClubDates.key(Date())
        var payload: [String: JSONValue] = [
            "profile": .object(profile), "_v2_profile": .bool(true), "_v2_schema_version": .number(1),
            "timeZone": .string(TimeZone.current.identifier), "plan_days": .number(7),
            "_onboarding_session_id": .string(session.id)
        ]
        let mode = kind == .planImport ? "parse_plan" : "generate_plan"
        if kind == .planImport {
            guard let text = importedText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { error = "请先粘贴或从照片识别计划文本。"; return }
            payload["text"] = .string(text)
        }
        do {
            let id = try ai.submit(AIInput(kind: mode, date: startKey, payload: payload), onboardingSessionID: session.id)
            planJobID = id
            planWaitTask?.cancel()
            planWaitTask = Task { @MainActor [weak self] in
                guard let self else { return }
                let deadline = Date().addingTimeInterval(180)
                while !Task.isCancelled, Date() < deadline {
                    if let job = ai.job(id) {
                        if job.status == "succeeded" { self.notice = "计划已生成，核对后可保存到日历。"; return }
                        if ["failed", "deleted", "expired", "rejected"].contains(job.status) {
                            self.error = job.error ?? "计划生成未完成，输入已保留。"; return
                        }
                    }
                    try? await Task.sleep(for: .seconds(2))
                }
                self.error = "计划生成等待较久，原任务已保留；可稍后在“我的任务”恢复。"
            }
        } catch { self.error = AppErrorText.message(error) }
    }

    func markPlanAdopted(jobID: String, commandID: String? = nil, account: AccountService) async {
        // Plan generation binds first_job_id and increments the session revision
        // on the server. Refresh before the CAS receipt instead of submitting a
        // stale revision or silently overwriting.
        await load(account: account)
        guard let session = state?.session else { return }
        do {
            let body: [String: Any] = ["expected_session_revision": session.revision, "job_id": jobID, "command_id": commandID ?? NSNull()]
            let data = try await request(account: account, path: "/me/onboarding/v2/sessions/\(session.id)/plan-adopted", method: "POST", body: body, idempotency: UUID().uuidString.lowercased(), expectedUserID: account.user?.id ?? 0)
            state = try JSONDecoder().decode(OnboardingV2State.self, from: data)
            if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let receipt = object["receipt"] as? [String: Any], let id = receipt["command_id"] as? String {
                    adoptedReceipt = id
                    notice = "计划已保存到账号。"
                } else if object["status"] as? String == "pending_sync" {
                    notice = "计划已保存到手机，正在上传到账号。"
                }
            }
        } catch { self.error = AppErrorText.message(error) }
    }

    #if DEBUG
    private static let PROFILE_PREVIEW_REQUIRED: [OnboardingTaskKind: [String]] = [
        .planCreate: ["goal", "experience", "venue", "days_per_week", "training_days", "session_minutes", "age_group"],
        .planImport: ["plan_text"],
        .mealLog: ["meal_date", "meal_category", "meal_description"],
        .workoutLog: ["workout_date", "exercise"],
        .nutritionGoal: ["sex_for_nutrition", "age_years", "height_cm", "profile_weight_kg", "daily_activity"],
        .explore: []
    ]
    private func loadPreview() {
        var preview = OnboardingV2State()
        preview.schemaVersion = 1
        preview.content = OnboardingContent()
        preview.enabled = true
        preview.isEmpty = true
        preview.capabilities = OnboardingCapabilities()
        preview.capabilities.assistBudgetRemaining = 10
        preview.content.tips = []
        if let raw = ProcessInfo.processInfo.environment["BOJI_ONBOARDING_PREVIEW_TASK"],
           let kind = OnboardingTaskKind(rawValue: raw) {
            preview.session = OnboardingSessionInfo(id: UUID().uuidString.lowercased(), schemaVersion: 1, revision: 1,
                status: "task_selected", taskKind: kind.rawValue, conversationID: UUID().uuidString.lowercased(),
                firstJobID: nil, firstProposalID: nil, firstCommandID: nil, createdAt: nil, updatedAt: nil, completedAt: nil, deferredAt: nil)
            preview.requiredFields = Self.PROFILE_PREVIEW_REQUIRED[kind] ?? []
            preview.requiredMissing = preview.requiredFields
            preview.planReady = false
            preview.isEmpty = false
        }
        state = preview
        facts = ProfileFactsDocument()
        loading = false
    }
    #endif

    private func v2ProfilePayload() -> [String: JSONValue] {
        var profile: [String: JSONValue] = [:]
        let facts = state?.confirmedFacts ?? [:]
        func put(_ key: String, _ field: String) { if let value = facts[field]?.value { profile[key] = value } }
        put("goal", "goal"); put("experience", "experience"); put("venue", "venue")
        put("focus", "focus"); put("limitations", "limitations")
        put("sessionMinutes", "session_minutes"); put("age", "age_years")
        put("height", "height_cm"); put("weight", "profile_weight_kg")
        if let equipment = facts["equipment"]?.value { profile["equipment"] = equipment }
        if let days = facts["training_days"]?.value { profile["trainingDays"] = days }
        profile["daysPerWeek"] = .number(Double(profile["trainingDays"]?.arrayValue?.count ?? 0))
        if let ageGroup = facts["age_group"]?.value { profile["ageGroup"] = ageGroup }
        else if let age = facts["age_years"]?.value.intValue { profile["ageGroup"] = .string(age < 18 ? "minor" : "adult") }
        profile["equipmentOther"] = .string("")
        return profile
    }

    private func mutate(account: AccountService, _ work: @escaping () async throws -> Void) async {
        let owner=account.user?.id
        let previous=mutationTail133
        mutationCount133 += 1;saving=true
        let task=Task { @MainActor in
            await previous?.value
            guard owner == account.user?.id else { return }
            self.error=nil
            do { try await work() }
            catch {
                guard owner == account.user?.id else { return }
                if let conflict=error as? OnboardingAPIError,conflict.status==409 { await self.load(account:account) }
                self.error=AppErrorText.message(error)
            }
        }
        mutationTail133=task
        await task.value
        mutationCount133 -= 1;saving=mutationCount133>0
    }

    private func request(account: AccountService, path: String, method: String, body: [String: Any]? = nil,
                         idempotency: String? = nil, expectedUserID: Int) async throws -> Data {
        if idempotency != nil, let body {
            return try await OnboardingMutationRecovery.perform(account:account,path:path,method:method,body:body,owner:expectedUserID)
        }
        var data: Data? = nil
        if let body { data = try JSONSerialization.data(withJSONObject: body, options: [.fragmentsAllowed]) }
        var headers: [String: String] = [:]
        if idempotency != nil {
            let canonical = try body.map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) } ?? Data()
            var identity = Data("\(expectedUserID)|\(method)|\(path)|".utf8); identity.append(canonical)
            headers["Idempotency-Key"] = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
        }
        let response = try await account.cloudRequest(path: path, method: method, body: data, expectedUserID: expectedUserID, headers: headers)
        guard (200..<300).contains(response.statusCode) else {
            let object = (try? JSONSerialization.jsonObject(with: response.data)) as? [String: Any]
            let message = (object?["error"] as? String) ?? ((object?["error"] as? [String: Any])?["message"] as? String) ?? "请求未完成（\(response.statusCode)）。"
            throw OnboardingAPIError(message: message, status: response.statusCode)
        }
        return response.data
    }
}

// Account-scoped, protected recovery journal. No credentials are persisted.
enum OnboardingMutationRecovery {
    struct Entry: Codable, Identifiable {
        var id: String; var path: String; var method: String; var body: Data; var createdAt: Date
    }
    private static func folder(_ owner: Int) -> URL {
        OnboardingDraftStore.defaultDirectory().appendingPathComponent("v2-recovery/\(owner)",isDirectory:true)
    }
    private static func write(_ data: Data,to url: URL) throws {
        let directory=url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        var dir=directory;var values=URLResourceValues();values.isExcludedFromBackup=true;try dir.setResourceValues(values)
        try data.write(to:url,options:[.atomic,.completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
    }
    static func clear(owner: Int) { try? FileManager.default.removeItem(at:folder(owner)) }
    static func entries(owner: Int,review: Bool = false) -> [Entry] {
        let suffix=review ? ".review.json" : ".pending.json"
        let urls=(try? FileManager.default.contentsOfDirectory(at:folder(owner),includingPropertiesForKeys:nil)) ?? []
        return urls.filter { $0.lastPathComponent.hasSuffix(suffix) }.compactMap { url in
            guard let data=try? Data(contentsOf:url) else { return nil }
            return try? JSONDecoder().decode(Entry.self,from:data)
        }.sorted { $0.createdAt < $1.createdAt }
    }
    static func saveState(_ data: Data,owner: Int) { try? write(data,to:folder(owner).appendingPathComponent("state.json")) }
    static func cachedState(owner: Int) -> Data? { try? Data(contentsOf:folder(owner).appendingPathComponent("state.json")) }
    static func discard(_ entry: Entry,owner: Int,review: Bool = true) {
        try? FileManager.default.removeItem(at:folder(owner).appendingPathComponent(entry.id+(review ? ".review.json" : ".pending.json")))
    }
    static func key(owner:Int,path:String,method:String,body:[String:Any]) throws -> String {
        let data=try JSONSerialization.data(withJSONObject:body,options:[.sortedKeys])
        var input=Data("\(owner)|\(method)|\(path)|".utf8);input.append(data)
        return SHA256.hash(data:input).map { String(format:"%02x",$0) }.joined()
    }
    static func persist(_ entry:Entry,owner:Int) throws {
        guard owner>0,entry.body.count<=65536 else { throw OnboardingAPIError(message:"恢复草稿无效。",status:422) }
        try write(JSONEncoder().encode(entry),to:folder(owner).appendingPathComponent(entry.id+".pending.json"))
    }
    @MainActor static func perform(account: AccountService,path: String,method: String,body: [String:Any],owner: Int) async throws -> Data {
        guard owner>0,account.user?.id==owner else { throw AccountError.unauthorized }
        guard ["POST","PATCH"].contains(method),
              path.range(of:"^/me/(onboarding/v2/sessions(?:/[a-f0-9-]{36}/(?:draft|profile-preview|profile-confirm|defer|complete|plan-adopted))?|profile-facts/(?:preview|confirm|clear|dismiss))$",options:.regularExpression) != nil else { throw OnboardingAPIError(message:"恢复操作不受支持。",status:422) }
        let data=try JSONSerialization.data(withJSONObject:body,options:[.sortedKeys])
        let key=try key(owner:owner,path:path,method:method,body:body)
        let url=folder(owner).appendingPathComponent(key+".pending.json")
        let previous=(try? Data(contentsOf:url)).flatMap { try? JSONDecoder().decode(Entry.self,from:$0) }
        let entry=Entry(id:key,path:path,method:method,body:data,createdAt:previous?.createdAt ?? Date())
        try persist(entry,owner:owner)
        let response=try await account.cloudRequest(path:path,method:method,body:data,expectedUserID:owner,headers:["Idempotency-Key":key])
        guard (200..<300).contains(response.statusCode) else {
            if (400..<500).contains(response.statusCode) {
                try write(JSONEncoder().encode(entry),to:folder(owner).appendingPathComponent(key+".review.json"))
                discard(entry,owner:owner,review:false)
            }
            let error=(try? JSONSerialization.jsonObject(with:response.data)) as? [String:Any]
            throw OnboardingAPIError(message:error?["error"] as? String ?? "请求未确认，输入已保存在本机。",status:response.statusCode)
        }
        discard(entry,owner:owner,review:false)
        return response.data
    }
    @MainActor static func replay(account: AccountService,owner: Int) async {
        for entry in entries(owner:owner).prefix(20) {
            guard account.user?.id==owner,let body=(try? JSONSerialization.jsonObject(with:entry.body)) as? [String:Any] else { return }
            do { _=try await perform(account:account,path:entry.path,method:entry.method,body:body,owner:owner) }
            catch let error as OnboardingAPIError { if error.status>=500 { return } }
            catch { return }
        }
    }
}

// MARK: - UI

struct OnboardingWorkspaceView: View {
    @ObservedObject var model: OnboardingV2Model
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var account: AccountService
    @EnvironmentObject private var ai: AIService
    @EnvironmentObject private var membership: MembershipService
    @EnvironmentObject private var weekly: WeeklyReviewService
    var onRecordMeal: (Date, String) -> Void
    var onRecordTraining: (Date) -> Void
    var onOpenMembership: () -> Void
    var onOpenKnowledge: () -> Void = {}

    @State private var editing = false
    @State private var reviewing = false
    @State private var completing = false
    @State private var showPlan = false
    @State private var importText = ""
    @State private var showOCR = false
    @State private var planMode: OnboardingTaskKind = .planCreate

    private var content: OnboardingContent { model.state?.content ?? OnboardingContent() }
    private var taskKind: OnboardingTaskKind? { model.taskKind }
    private var sessionStatus: String { model.state?.session?.status ?? "" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if model.state == nil {
                    if model.error != nil {
                        ContentUnavailableView("暂时无法读取引导", systemImage: "wifi.exclamationmark", description: Text("已填内容仍保留，可以重新连接。"))
                        Button("重新连接") { Task { await model.load(account: account) } }
                            .buttonStyle(PrimaryButton()).disabled(model.loading)
                    } else { ProgressView("正在恢复新手引导…").frame(maxWidth: .infinity).padding(.top, 24) }
                } else if model.state?.session == nil {
                    welcome
                } else if (model.state?.schemaVersion ?? 1) > 1 {
                    unsupportedState
                } else {
                    workspace
                }
                if let error = model.error { Text(error).font(.footnote).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                if let notice = model.notice { Text(notice).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            .padding(20).frame(maxWidth: ClubUI.contentWidth).frame(maxWidth: .infinity)
        }
        .background(BojiColor.pageBackground)
        .task(id: account.user?.id) {
            if model.state == nil { await model.load(account: account) }
            model.applyFacts(to: store)
            if let id = model.planJobID, ai.job(id) == nil {
                await ai.recoverTasks(account: account, weekly: weekly, store: store, targetID: id)
            }
        }
        .onChange(of: model.facts?.revision) { _, _ in model.applyFacts(to: store) }
        .sheet(isPresented: $editing,onDismiss:{ Task { await model.load(account:account) } }) {
            OnboardingFieldEditor(model: model, account: account)
        }
        .sheet(isPresented: $reviewing) {
            OnboardingProfileReviewView(model: model, account: account)
        }
        .sheet(isPresented: $completing) {
            OnboardingCompletionView(model: model, account: account)
        }
        .sheet(isPresented: $showPlan) {
            if let id = model.planJobID,
               let date = ClubDates.date(fromKey: ai.job(id)?.request.date ?? model.state?.draft.fields["first_plan_start_date"]?.value.string ?? ClubDates.key(Date())) {
                Group {
                    PlanView(date: date, initialMode: planMode == .planImport ? "parse_plan" : "generate_plan",
                             initialJobID: id, onPlanApplied: {
                                 showPlan = false
                                 Task {
                                     _ = await store.syncNow()
                                     await model.markPlanAdopted(jobID: id, account: account)
                                 }
                             })
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { showPlan = false } } }
                }
            }
        }
        .sheet(isPresented: $showOCR) {
            OnboardingPlanOCRView { text in
                importText = text
                showOCR = false
            }
        }
    }

    private var unsupportedState: some View {
        ClubCard {
            Text("这份引导来自更新版本").font(.headline)
            Text("当前 App 只安全展示可读摘要，不执行未知操作。你仍可使用原生资料表单或训练/饮食记录；原草稿不会丢失。")
                .font(.footnote).foregroundStyle(.secondary)
            Button("AI 对我的了解") { onOpenKnowledge() }.buttonStyle(PrimaryButton())
            Button("稍后继续") { Task { await model.deferSession(account: account) } }.buttonStyle(SecondaryButton())
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                BojiBrandMark(size:56).padding(.bottom,8)
                Text("薄肌俱乐部").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Text(content.welcomeTitle).font(.title2.weight(.semibold))
                Text(content.welcomeBody).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 10) {
                ForEach(OnboardingTaskKind.allCases, id: \.self) { kind in
                    Button {
                        Task { await model.createSession(kind, account: account) }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: kind.symbol).frame(width: 28)
                            Text(content.label(kind)).frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(minHeight: 48).padding(.horizontal, 14)
                        .background(BojiColor.cardSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay { RoundedRectangle(cornerRadius: 14).stroke(BojiColor.outline, lineWidth: 0.5) }
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("也可以直接在下方输入框说你想做什么。没有说出的资料会保持未知，不会用示例数补齐。")
                .font(.footnote).foregroundStyle(.secondary)
            if model.isDeferred {
                Button("继续上次的引导") { Task { await model.resume(account: account) } }.buttonStyle(SecondaryButton())
            }
            Button("了解俱乐部会员") { onOpenMembership() }.buttonStyle(.plain).font(.footnote)
            if model.state?.enabled == false {
                Text("引导暂时无法继续。你仍可手动记录，资料和草稿已保留。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Button("AI 对我的了解") { onOpenKnowledge() }.buttonStyle(.plain).font(.footnote)
        }
    }

    private var workspace: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            Menu("换一件事，保留已有草稿") {
                ForEach(OnboardingTaskKind.allCases,id: \.rawValue) { kind in
                    Button(content.label(kind)) { Task { await model.createSession(kind,account:account) } }
                }
            }.disabled(model.saving || model.isAssisting)
            if model.isDeferred {
                Button("继续这次引导") { Task { await model.resume(account: account) } }.buttonStyle(PrimaryButton())
            }
            if let task = taskKind {
                switch task {
                case .mealLog: mealTask
                case .workoutLog: workoutTask
                case .planImport: importTask
                case .planCreate: planTask
                case .nutritionGoal, .explore: fieldTask
                }
            }
            assistantTranscript
            summaryCard
            actionRow
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: taskKind?.symbol ?? "sparkles")
                Text(taskKind.map { content.label($0) } ?? "新手引导").font(.headline)
                Spacer()
                Text(statusLabel).font(.caption).foregroundStyle(.secondary)
            }
            ProgressView(value: Double(progressValue), total: 1)
            Text("可以慢慢补充。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var statusLabel: String {
        if model.state?.taskCompleteAvailable == true { return "已完成" }
        switch sessionStatus {
        case "task_selected": return "已选任务"
        case "collecting": return "收集中"
        case "review": return "待核对"
        case "first_task_ready": return "可核对计划"
        case "deferred": return "稍后继续"
        case "completed": return "已完成"
        default: return "进行中"
        }
    }
    private var progressValue: Double {
        if model.state?.taskCompleteAvailable == true { return 1 }
        guard let state = model.state else { return 0 }
        let required = max(1, state.requiredFields.count)
        return min(1, Double(required - state.requiredMissing.count) / Double(required))
    }

    private var fieldTask: some View {
        VStack(alignment:.leading,spacing:12) {
            Text("与“AI 对我的了解”使用同一份资料，已填内容会直接带入。")
                .font(.footnote).foregroundStyle(.secondary)
            let fields=ProfileFields133.task(taskKind).filter { field in
                if field == .ageGroup,(model.facts?.facts["age_years"] ?? model.state?.confirmedFacts["age_years"]) != nil { return false }
                if [.equipment,.equipmentOther,.homeTrainingDays,.equipmentExclusions,.focus,.limitations].contains(field) { return false }
                return true
            }
            ForEach(fields,id:\.self) { field in
                HStack { Text(field.title);Spacer();Text((model.facts?.facts[field.apiKey] ?? model.state?.confirmedFacts[field.apiKey]).map { field.displayValue($0.value) } ?? "未填写").foregroundStyle(.secondary).multilineTextAlignment(.trailing) }
                    .font(.subheadline)
            }
            if taskKind == .explore {
                Text("可以先浏览与记录，资料随时可以补充。补充资料不会自动生成计划。") .font(.subheadline).foregroundStyle(.secondary)
                Button("AI 对我的了解",action:onOpenKnowledge).buttonStyle(SecondaryButton())
            } else {
                Button(model.planReady ? "修改训练条件":"填写或修改资料") { editing=true }.buttonStyle(SecondaryButton())
            }
        }
    }

    private var planTask: some View {
        VStack(alignment: .leading, spacing: 12) {
            fieldTask
            if model.planReady {
                ClubCard {
                    Text("第一份计划").font(.headline)
                    Text("将按你确认的目标、经验、地点、器械、日期和时长生成。没有填写的年龄细节不会用示例数代替；未成年或明显不适只做保守安排。")
                        .font(.footnote).foregroundStyle(.secondary)
                    if model.planBusy { ProgressView("正在准备计划…") }
                    Button(model.planJobID == nil ? "生成第一份计划" : "查看计划进度") {
                        if model.planJobID == nil {
                            Task { await model.generatePlan(kind: .planCreate, account: account, ai: ai) }
                        } else { planMode = .planCreate; showPlan = true }
                    }.buttonStyle(PrimaryButton()).disabled(model.planBusy)
                    if let id = model.planJobID, ai.job(id)?.status == "succeeded" {
                        Button("查看并保存计划") { planMode = .planCreate; showPlan = true }.buttonStyle(SecondaryButton())
                    }
                }
            } else if model.state?.safetyBlocked == true {
                Text(model.state?.safetyMessage ?? "你填写的情况需要先由专业人员核对，暂不生成训练强度安排；仍可记录饮食与休息。")
                    .font(.footnote).foregroundStyle(.red)
            } else {
                Text("补充上面的训练条件，保存后即可生成计划。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var importTask: some View {
        VStack(alignment: .leading, spacing: 12) {
            ClubCard {
                Text("把已有计划变成可核对安排").font(.headline)
                Text("先粘贴计划文字，或从照片识别文字。日期、单位和器械会在预览中让你核对。")
                    .font(.footnote).foregroundStyle(.secondary)
                TextEditor(text: $importText).frame(minHeight: 140).padding(8)
                    .background(BojiColor.subtleSurface, in: RoundedRectangle(cornerRadius: 12))
                    .overlay { RoundedRectangle(cornerRadius: 12).stroke(BojiColor.outline, lineWidth: 0.5) }
                HStack {
                    Button("从照片识别文字") { showOCR = true }.buttonStyle(SecondaryButton())
                    Button(model.planBusy ? "正在整理…" : "整理并预览") {
                        Task {
                            planMode = .planImport
                            await model.generatePlan(kind: .planImport, importedText: importText, account: account, ai: ai)
                            if model.error == nil { showPlan = true }
                        }
                    }.buttonStyle(PrimaryButton()).disabled(importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.planBusy)
                }
                if let id = model.planJobID, ai.job(id)?.status == "succeeded" {
                    Button("查看并保存导入计划") { planMode = .planImport; showPlan = true }.buttonStyle(SecondaryButton())
                }
            }
        }
    }

    private var mealTask: some View {
        ClubCard {
            Text("先记一餐，不需要完整训练资料").font(.headline)
            Text("打开原生饮食编辑并保留草稿；保存与同步结果分开显示。AI 不可用时仍可手动填写。")
                .font(.footnote).foregroundStyle(.secondary)
            Button("去记录这一餐") { onRecordMeal(Date(), "手动") }.buttonStyle(PrimaryButton())
            if model.state?.capabilities.membershipActive != true {
                Text("若当前权益暂不允许保存，草稿会保留；购买成功或取消后会回到这里。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var workoutTask: some View {
        ClubCard {
            Text("先记录实际训练").font(.headline)
            Text("动作、组数、次数、重量和计时继续使用原生训练页。这里不会要求先生成计划。")
                .font(.footnote).foregroundStyle(.secondary)
            Button("去训练页记录") { onRecordTraining(Date()) }.buttonStyle(PrimaryButton())
        }
    }

    private var assistantTranscript: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let messages = model.state?.recentMessages, !messages.isEmpty {
                Text("这次引导的对话").font(.subheadline.weight(.medium))
                let shown = Array(messages.suffix(6))
                ForEach(Array(shown.enumerated()),id:\.element.id) { index,message in
                    VStack(alignment:.leading,spacing:6) {
                        if message.role == "user" { Text("你").font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                        else if index == 0 || shown[index-1].role == "user" { BojiBrandMark(size:20,style:.monochrome) }
                        Text(message.text).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                    }.padding(.vertical,4)
                }
            }
            if !model.streamingText.isEmpty {
                BojiBrandMark(size:20,style:.monochrome)
                Text(model.streamingText).font(.subheadline).fixedSize(horizontal:false,vertical:true)
            } else if let answer = model.lastAssistantAnswer, !(model.state?.recentMessages.contains(where: { $0.role == "assistant" && $0.text == answer }) ?? false) {
                BojiBrandMark(size:20,style:.monochrome)
                Text(answer).font(.subheadline).fixedSize(horizontal:false,vertical:true)
            }
            if model.isAssisting { HStack(spacing:10) { if model.streamingText.isEmpty { AIProcessingMark(size:24) };Text("正在理解这句话…").font(.footnote).foregroundStyle(.secondary) }.accessibilityElement(children:.combine) }
            if let usage = model.state?.assistUsage, usage.remaining <= 2, usage.limit > 0 {
                Text("今天还可使用 \(usage.remaining) 次引导 AI；用完后原生卡片仍可继续。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("当前资料摘要").font(.subheadline.weight(.medium))
                Spacer()
                Button("展开编辑") { editing = true }.font(.footnote)
            }
            let facts = model.state?.confirmedFacts ?? [:]
            let drafts = model.state?.draft.fields ?? [:]
            if facts.isEmpty && drafts.isEmpty {
                Text("还没有已确认资料；未知不会被默认数替代。").font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(Array(OnboardingFieldSpec.allCases.enumerated()), id: \.offset) { _, field in
                if let fact = facts[field.apiKey] {
                    row(field.title, field.displayValue(fact.value), fact.sourceLabel)
                } else if let draft = drafts[field.apiKey] {
                    row(field.title, field.displayValue(draft.value), "草稿 · 待核对")
                }
            }
        }
        .padding(16)
        .background(BojiColor.cardSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 18).stroke(BojiColor.outline, lineWidth: 0.5) }
    }

    private func row(_ title: String, _ value: String, _ status: String) -> some View {
        HStack(alignment: .top) {
            Text(title).font(.footnote).foregroundStyle(.secondary).frame(width: 96, alignment: .leading)
            Text(value).font(.footnote).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            Text(status).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var actionRow: some View {
        VStack(spacing: 10) {
            if model.state?.draft.fields.contains(where: { key,value in OnboardingFieldSpec.from(apiKey:key) != nil && value.value != model.facts?.facts[key]?.value }) == true {
                Button(reviewing ? "正在核对…" : "核对 AI 建议的资料") {
                    Task { if await model.previewProfile(account: account) { reviewing = true } }
                }.buttonStyle(PrimaryButton()).disabled(model.saving || model.isDeferred)
            }
            HStack {
                Button("稍后继续") { Task { await model.deferSession(account: account) } }.buttonStyle(SecondaryButton())
                if model.state?.taskCompleteAvailable == true { Button("完成设置") { completing = true }.buttonStyle(SecondaryButton()) }
            }
            Text("以后可以随时修改。")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }
}

struct OnboardingFieldEditor: View {
    @ObservedObject var model: OnboardingV2Model
    let account: AccountService
    var body: some View {
        ProfileFactsForm133(title:model.taskKind == .nutritionGoal ? "营养计算资料":"目标与训练条件",fields:ProfileFields133.task(model.taskKind),suggestions:model.state?.draft.fields.mapValues(\.value) ?? [:]) {
            Task { await model.load(account:account) }
        }
    }
}

private extension OnboardingFieldKind {
    var isDecimal: Bool { if case .decimal(_) = self { return true }; return false }
}

struct OnboardingProfileReviewView: View {
    @ObservedObject var model: OnboardingV2Model
    let account: AccountService
    @Environment(\.dismiss) private var dismiss
    @State private var confirming = false
    @State private var localError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("资料核对").font(.title2.weight(.semibold))
                    Text("看看下面的资料，确认后保存。")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let proposal = model.proposal {
                        ForEach(Array(OnboardingFieldSpec.allCases.enumerated()), id: \.offset) { _, field in
                            let before = proposal.before[field.apiKey]?.value
                            let after = proposal.after[field.apiKey]?.value
                            if before != after {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(field.title).font(.caption).foregroundStyle(.secondary)
                                    Text((before.map(field.displayValue) ?? "未填写") + "  →  " + (after.map(field.displayValue) ?? "未填写"))
                                        .font(.subheadline)
                                }.padding(.vertical, 3)
                            }
                        }
                        if !proposal.unknownFields.isEmpty {
                            Text("仍未填写：\(proposal.unknownFields.prefix(8).map { OnboardingFieldSpec.from(apiKey: $0)?.title ?? $0 }.joined(separator: "、"))。这些会保持未知。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        Text("提案有效期至 \(proposal.expiresAt ?? "未知")；其他人后来修改过资料时，服务端会要求重新核对。")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        ProgressView("正在生成资料预览…")
                    }
                    if let error = localError ?? model.error { Text(error).font(.footnote).foregroundStyle(.red) }
                }.padding(20)
            }
            .background(BojiColor.pageBackground)
            .navigationTitle("核对资料")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("返回") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirming ? "确认中…" : "确认保存") {
                        confirming = true
                        Task {
                            let ok = await model.confirmProfile(account: account)
                            confirming = false
                            if ok { dismiss() } else { localError = model.error }
                        }
                    }.disabled(confirming || model.proposal == nil)
                }
            }
            .task { if model.proposal == nil { _ = await model.previewProfile(account: account) } }
        }
    }
}

struct OnboardingCompletionView: View {
    @ObservedObject var model: OnboardingV2Model
    let account: AccountService
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var error: String?
    @State private var legal: LegalDocument?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("完成后可继续其他待办，也可稍后从侧栏返回。")
                        .font(.footnote)
                }
                Section { Text("首项设置已完成。资料已保存在“AI 对我的了解”，之后仍可修改。") }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("完成这次引导")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(busy ? "正在确认…" : "完成") {
                        busy = true; error = nil
                        Task {
                            let ok = await model.completeSession(account: account, covenantVersion: "2026-10-25")
                            busy = false
                            if ok { dismiss() } else { error = model.error }
                        }
                    }.disabled(busy || model.state?.taskCompleteAvailable != true)
                }
            }
            .sheet(item: $legal) { LegalDocumentView(document: $0) }
        }
    }
}

// MARK: - Plan text OCR

struct OnboardingPlanOCRView: View {
    let onText: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var item: PhotosPickerItem?
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Text("选择一张包含训练计划的照片。识别出的文字会先放进可编辑文本，再由你核对。")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                PhotosPicker(selection: $item, matching: .images) {
                    Label("选择计划照片", systemImage: "photo")
                }.buttonStyle(PrimaryButton())
                if busy { ProgressView("正在识别文字…") }
                if let error { Text(error).foregroundStyle(.red).font(.footnote) }
                Spacer()
            }.padding(24)
                .navigationTitle("从照片导入")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
                .onChange(of: item) { _, value in
                    guard let value else { return }
                    Task { await recognize(value) }
                }
        }
    }

    private func recognize(_ item: PhotosPickerItem) async {
        busy = true; error = nil; defer { busy = false }
        do {
            guard let data = try await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else { throw OnboardingAPIError(message: "照片读取失败。", status: 0) }
            let text = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                let request = VNRecognizeTextRequest { request, error in
                    if let error { continuation.resume(throwing: error); return }
                    let lines = (request.results as? [VNRecognizedTextObservation] ?? []).compactMap { $0.topCandidates(1).first?.string }
                    continuation.resume(returning: lines.joined(separator: "\n"))
                }
                request.recognitionLanguages = ["zh-Hans", "en-US"]
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                do { try VNImageRequestHandler(cgImage: image.cgImage!).perform([request]) }
                catch { continuation.resume(throwing: error) }
            }
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw OnboardingAPIError(message: "没有识别到可读文字，请换一张更清晰的照片或手动粘贴。", status: 0) }
            onText(text); dismiss()
        } catch { self.error = AppErrorText.message(error) }
    }
}


/// Recovery is explicit when an earlier request was rejected or conflicted.
struct LocalMutationReviewView: View {
    let entry: OnboardingMutationRecovery.Entry
    @EnvironmentObject private var account: AccountService
    @Environment(\.dismiss) private var dismiss
    @State private var changes: [JSONValue] = []
    @State private var error: String?
    @State private var notice: String?
    @State private var busy = false
    @State private var proposalID: String?
    @StateObject private var editor=ProfileFactsEditor()
    private var original: [String:Any] { (try? JSONSerialization.jsonObject(with:entry.body)) as? [String:Any] ?? [:] }
    var body: some View {
        ScrollView { VStack(alignment:.leading,spacing:16) {
            Text("原输入已保存在这台设备，尚未当作新的业务事实。").font(.subheadline)
            ForEach(Array(changes.enumerated()),id:\.offset) { _,change in
                if case .object(let c)=change,let field=c["field"]?.string {
                    Text("\(OnboardingFieldSpec.from(apiKey:field)?.title ?? field)：\(c["value"]?.displayText ?? "未填写")")
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
            if let notice { Text(notice).foregroundStyle(.secondary) }
            Button(busy ? "正在核对…" : "恢复并重新核对") { Task { await restore() } }.buttonStyle(PrimaryButton()).disabled(busy)
            Button("返回原任务") { NotificationCenter.default.post(name:.clubResumeOnboarding,object:nil);dismiss() }.buttonStyle(SecondaryButton())
            Button("放弃这份本机恢复稿",role:.destructive) {
                if let uid=account.user?.id { OnboardingMutationRecovery.discard(entry,owner:uid);OnboardingMutationRecovery.discard(entry,owner:uid,review:false) };dismiss()
            }.font(.footnote)
        }.padding() }.navigationTitle("恢复未提交修改")
            .toolbar { ToolbarItem(placement:.cancellationAction) { Button("关闭") { dismiss() } } }
            .task { await inspect() }
            .sheet(item:Binding(get:{ proposalID.map { LocalProposalRoute(id:$0) } },set:{ proposalID=$0?.id })) { route in
                NavigationStack { AIProfileProposalView(proposalID:route.id) }
            }
    }
    private struct LocalProposalRoute: Identifiable { var id: String }
    private func inspect() async {
        if let raw=original["changes"],let data=try? JSONSerialization.data(withJSONObject:raw) { changes=(try? JSONDecoder().decode([JSONValue].self,from:data)) ?? [] }
        if changes.isEmpty,let id=original["proposal_id"] as? String,let uid=account.user?.id,
           let response=try? await account.cloudRequest(path:"/me/profile-facts/proposals/\(id)",expectedUserID:uid),
           let raw=(try? JSONSerialization.jsonObject(with:response.data)) as? [String:Any],let value=raw["changes"],let data=try? JSONSerialization.data(withJSONObject:value) {
            changes=(try? JSONDecoder().decode([JSONValue].self,from:data)) ?? []
        }
    }
    @MainActor private func restore() async {
        guard let uid=account.user?.id else { return }
        busy=true;error=nil;defer { busy=false }
        do {
            if OnboardingMutationRecovery.entries(owner:uid).contains(where:{$0.id==entry.id}) {
                let data=try await OnboardingMutationRecovery.perform(account:account,path:entry.path,method:entry.method,body:original,owner:uid)
                if let value=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],let id=value["proposal_id"] as? String { proposalID=id }
                notice="已恢复这次回答，请查看下方操作结果。";return
            }
            let rawChanges=changes.map(\.anyValue)
            if entry.path.hasSuffix("/draft"),!rawChanges.isEmpty {
                let response=try await account.cloudRequest(path:"/me/onboarding/v2",expectedUserID:uid)
                let state=try JSONDecoder().decode(OnboardingV2State.self,from:response.data)
                guard let session=state.session,entry.path.contains(session.id) else { throw OnboardingAPIError(message:"请先回到原引导任务核对。",status:409) }
                _=try await OnboardingMutationRecovery.perform(account:account,path:entry.path,method:"PATCH",body:["expected_session_revision":session.revision,"changes":rawChanges],owner:uid)
                OnboardingMutationRecovery.discard(entry,owner:uid);notice="已恢复为待确认草稿，尚未改动实际资料。";return
            }
            if !rawChanges.isEmpty {
                await editor.load(account:account)
                guard let revision=editor.facts?.revision else { throw OnboardingAPIError(message:editor.error ?? "资料暂不可用。",status:503) }
                let data=try await OnboardingMutationRecovery.perform(account:account,path:"/me/profile-facts/preview",method:"POST",body:["expected_profile_revision":revision,"changes":rawChanges,"plan_start_date":original["plan_start_date"] ?? NSNull()],owner:uid)
                let value=try JSONDecoder().decode(OnboardingProposal.self,from:data)
                OnboardingMutationRecovery.discard(entry,owner:uid);proposalID=value.proposalID;return
            }
            notice="这项操作需要回到原任务，重新核对协议或当前资料后继续。"
        } catch { self.error=AppErrorText.message(error) }
    }
}
