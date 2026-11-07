import Foundation
import Combine
import CryptoKit

enum JSONValue: Codable, Equatable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([JSONValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    var object: [String: JSONValue]? { if case .object(let value) = self { return value }; return nil }
    var array: [JSONValue]? { if case .array(let value) = self { return value }; return nil }
    var string: String? { if case .string(let v) = self { return v }; return nil }
    static func encode<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }
}

struct AIInput: Codable, Equatable {
    var kind: String
    var date: String
    var payload: [String: JSONValue]
}

struct AIRequest: Codable, Equatable {
    var id: String
    var kind: String
    var date: String
    var payload: [String: JSONValue]
    /// Server-owned onboarding binding. The purpose itself is derived server-side.
    var onboardingSessionID: String? = nil
    var contextSource: JSONValue? = nil
    enum CodingKeys: String, CodingKey {
        case id, kind, date, payload
        case onboardingSessionID = "onboarding_session_id"
        case contextSource = "context_source"
    }
}

struct AIPlanSet: Codable, Equatable { var weight: Double?; var reps: Int; var durationSeconds: Int? = nil
    var repetitionLabel: String { durationSeconds.map { "\($0) 秒" } ?? "\(reps) 次" }
}
struct AIPlanExercise: Codable, Equatable { var name: String; var muscle: String; var sets: [AIPlanSet]; var library_query: String?; var library_id: String? = nil; var custom_id: UUID? = nil; var custom_unit: String? = nil; var rest_seconds: Int? = nil }
extension AIPlanExercise { var displayName: String { custom_id != nil ? name : ExerciseNames.display(name, id: library_id, query: library_query) } }
struct AIPlanSession: Codable, Equatable { var date: String; var label: String; var exercises: [AIPlanExercise] }

struct AIPlanReason: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var basis: String
    var detail: String
}
struct AIPlanPurpose: Codable, Equatable, Identifiable {
    var date: String
    var purpose: String
    var id: String { date }
}
struct AIPlanExplanation: Codable, Equatable {
    var version: Int
    var summary: [String]
    var sections: [AIPlanReason]
    var sessions: [AIPlanPurpose]
}

struct AIDailyTrainingMetrics: Codable, Equatable {
    var sessions: Int?
    var duration_minutes: Int?
    var completed_exercises: Int?
    var completed_sets: Int?
    var total_volume_kg: Double?
}

struct AIDailyNutritionMetrics: Codable, Equatable {
    var calories: Double?
    var protein: Double?
    var carbs: Double?
    var fat: Double?
    var data_complete: Bool?
    var unknown_meals: Int?
}

struct AIDailyBodyMetrics: Codable, Equatable {
    var weight_kg: Double?
    var body_fat_pct: Double?
    var waist_cm: Double?
}

struct AIDailyActivityMetrics: Codable, Equatable {
    var steps: Double?
    var active_energy_kcal: Double?
}

struct AIDailyMetrics: Codable, Equatable {
    var date: String?
    var training: AIDailyTrainingMetrics?
    var nutrition: AIDailyNutritionMetrics?
    var body: AIDailyBodyMetrics?
    var activity: AIDailyActivityMetrics?
    var data_warnings: [String]?
}

struct AIResult: Codable, Equatable {
    var coach: ClubCoachAnswer? = nil
    var kind: String
    var notes: [String]
    var title: String?
    var sessions: [AIPlanSession]?
    var name: String?
    var is_food: Bool?
    var components: [FoodComponent]?
    var consumed_fraction: Double? = nil
    var estimated: Bool?
    var calories: Double?
    var protein: Double?
    var carbs: Double?
    var fat: Double?
    var summary: String?
    var training: String?
    var nutrition: String?
    var recovery: String?
    var meals: [AIBatchMeal]? = nil
    var explanation: AIPlanExplanation? = nil
    var training_feedback: TrainingFeedback? = nil
    var plan_days: Int? = nil
    // 自由计划采用时随版本保存的上下文（可选：AI/旧版本结果没有这些键）。
    var plan_description: String? = nil
    var plan_intent: String? = nil
    var plan_pattern: String? = nil
    var metrics: AIDailyMetrics? = nil
    var highlights: [String]? = nil
    var observations: [String]? = nil
    var recommendations: [String]? = nil
    var data_warnings: [String]? = nil
}

struct AIJobResponse: Codable {
    var id: String
    var status: String
    var result: AIResult?
    var provider: String?
    var model: String?
    var error_code: String?
    var error_message: String?
    var source_status: String? = nil
    var source_revision: String? = nil
}

struct AILocalJob: Identifiable, Codable, Equatable {
    var id: String
    var digest: String
    var request: AIRequest
    var status = "pending"
    var result: AIResult?
    var error: String?
    var provider: String?
    var model: String?
    var created = Date()
    var consumed = false
    var errorCode: String?
    /// Phase 2: server trace when the turn arrived over a durable run.
    var traceID: String? = nil
    var replacementID: String?
    var retryAfter: Date? = nil
    var connectionFailures: Int? = nil
    var isWaiting: Bool { ["waiting_connection", "waiting_service"].contains(status) }
    var isTerminal: Bool { ["succeeded", "failed", "deleted", "expired", "rejected", "discarded"].contains(status) }
}

enum AIClientError: LocalizedError {
    case message(String)
    case http(Int, String?, String)
    case deferred(Int, String?, String, Date)
    var errorDescription: String? {
        switch self { case .message(let text): return text; case .http(_, _, let text): return text; case .deferred(_, _, let text, _): return text }
    }
}

struct AIRetryDecision {
    var status: String
    var code: String? = nil
    var after: Date
    var failures: Int
}

enum AIRetryPolicy {
    static func isDue(_ after: Date?, now: Date = Date()) -> Bool { after.map { $0 <= now } ?? true }
    static func decision(_ error: Error, previousFailures: Int?, now: Date = Date()) -> AIRetryDecision {
        let failures = min(9, max(0, previousFailures ?? 0)) + 1
        var result = AIRetryDecision(status: "waiting_connection", after: now.addingTimeInterval(min(300, 30 * pow(2, Double(failures - 1)))), failures: failures)
        switch error {
        case AIClientError.deferred(_, let code, _, let after):
            result.after = max(result.after, after); result.code = code
            result.status = ["quota_exceeded", "daily_capacity"].contains(code ?? "") ? "failed" : "waiting_service"
        case AIClientError.http(let status, let code, _):
            result.code = code
            if [400, 403, 409, 413, 422].contains(status) || code == "input_expired" {
                result.status = code == "input_expired" ? "expired" : "rejected"
            }
        default: break
        }
        return result
    }
}

/// Background polling failures are de-duplicated per account and reason. The
/// gate is intentionally independent from user-initiated errors.
struct BackgroundRecoveryNoticeGate {
    private(set) var key: String?
    mutating func shouldPresent(accountID: Int) -> Bool {
        let next = "\(accountID)-background-recovery"
        guard key != next else { return false }
        key = next
        return true
    }
    mutating func reset() { key = nil }
}

@MainActor
final class AIService: ObservableObject {
    @Published private(set) var jobs: [AILocalJob] = []
    @Published private(set) var cloudChangeID = 0
    @Published var notice: String?
    /// 服务端首页洞察（§2.5/D-09）；nil = 服务端无事实或本次未取到 → 客户端本地兜底。
    @Published private(set) var homeInsight: ClubServerInsight?
    /// 后台恢复失败的非阻塞状态；不进入全局模态，同账号同原因只提示一次。
    @Published private(set) var recoveryNotice: String?
    private var recoveryGate = BackgroundRecoveryNoticeGate()
    func dismissRecoveryNotice() { recoveryNotice = nil }
    @Published var requiresRoutingConsent = false
    var routingConsentGranted: Bool { activeAccountID != nil && cloudRoutingAllowed }
    /// 开发预览账号只产生本地确定性结果，数据不出设备，因此无需云端分析授权；
    /// 真实账号仍然必须逐账号显式同意（CloudAnalysisConsent）。
    private var cloudRoutingAllowed: Bool {
        if accountService?.isPreviewAccount == true { return true }
        return hasRoutingConsent
    }
    private var hasRoutingConsent: Bool { CloudAnalysisConsent.allowed(accountID: activeAccountID) }
    private let jobDisk = AIJobDiskStore()
    private var storageURL: URL
    private let storageDirectory: URL
    private var activeAccountID: Int?
    private weak var accountService: AccountService?
    private var workers: [String: Task<Void, Never>] = [:]
    private var storageAvailable = true
    var canSyncJobs: Bool { storageAvailable }
    private var workerGeneration = UUID()
    private var retryTimer130: Task<Void, Never>?
    private var foreground130 = true
    private var refreshingMealBatchKeys: Set<String> = []
    private var pendingWorkers: [(id: String, retry: Bool)] = []
    private let maximumWorkers = 3

    private let intelligenceTransport: ((Int, String) async throws -> Data)?

    init(intelligenceTransport: ((Int, String) async throws -> Data)? = nil) {
        self.intelligenceTransport = intelligenceTransport
        storageDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BojiClub")
        storageURL = storageDirectory.appendingPathComponent("ai-tasks-v1.json")
        do {
            try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
            try loadCurrentJobs()
        } catch {
            storageAvailable = false
            notice = "AI 任务记录读取失败，原文件已保留。"
        }
    }

    func activateAccount(_ id: Int, account: AccountService) {
        guard activeAccountID != id else { return }
        hasMoreTaskHistory = false
        recoveryCursor = nil; recoveryBusy = false; recoveryGeneration = UUID()
        workerGeneration = UUID(); pendingWorkers.removeAll()
        workers.values.forEach { $0.cancel() }
        workers.removeAll()
        requiresRoutingConsent = false
        resetPersonalIntelligenceCache()
        activeAccountID = id
        accountService = account
        storageURL = storageDirectory.appendingPathComponent("ai-tasks-user-\(id)-v1.json")
        jobs = []
        storageAvailable = true
        do { try loadCurrentJobs() }
        catch { storageAvailable = false; notice = "这个账号的 AI 任务记录读取失败，原文件已保留。" }
        #if DEBUG
        if account.isPreviewAccount, ProcessInfo.processInfo.environment["BOJI_AUDIT_SCREEN"] != nil {
            jobs = [BojiAuditFixtures.report(date: Date())]
        }
        #endif
    }

    func deactivateAccount() {
        hasMoreTaskHistory = false
        recoveryCursor = nil; recoveryBusy = false; recoveryGeneration = UUID()
        workerGeneration = UUID(); pendingWorkers.removeAll()
        workers.values.forEach { $0.cancel() }
        workers.removeAll()
        requiresRoutingConsent = false
        resetPersonalIntelligenceCache()
        activeAccountID = nil
        accountService = nil
        storageURL = storageDirectory.appendingPathComponent("ai-tasks-v1.json")
        jobs = []
        jobDisk.reset()
        storageAvailable = true
    }

    @discardableResult
    func eraseAccountData(_ id: Int) -> Bool {
        if activeAccountID == id { workerGeneration = UUID(); pendingWorkers.removeAll(); workers.values.forEach { $0.cancel() }; workers.removeAll() }
        let file = storageDirectory.appendingPathComponent("ai-tasks-user-\(id)-v1.json")
        do {
            let savedJobs = FileManager.default.fileExists(atPath: file.path) ? try AIJobDiskStore().load(file) : []
            for job in savedJobs { UserDefaults.standard.removeObject(forKey: "plan.preview.\(job.id)") }
            for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix("plan.preview.user-\(id).") {
                UserDefaults.standard.removeObject(forKey: key)
            }
        } catch {
            for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix("plan.preview.") { UserDefaults.standard.removeObject(forKey: key) }
        }
        AIRunResumeStore.erase(owner: id)
        AIRunPendingStore.erase(owner: id)
        do {
            for target in [file, file.appendingPathExtension("parts"), file.appendingPathExtension("legacy")] where FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        } catch { return false }
        if activeAccountID == id {
            resetPersonalIntelligenceCache()
            jobs = []
            jobDisk.reset()
            cloudChangeID &+= 1
        }
        return true
    }

    private func loadCurrentJobs() throws {
        jobs = try jobDisk.load(storageURL)
        if !jobDisk.unreadableJobIDs.isEmpty {
            storageAvailable = false
            notice = "有 \(jobDisk.unreadableJobIDs.count) 份任务暂时无法读取，其余报告可查看。原文件已保留，云同步已暂停，避免覆盖报告。"
            return
        }
        try expirePhotoInputs()
    }

    /// Completed/failed recognition inputs need not keep full photos indefinitely.
    private func expirePhotoInputs() throws {
        let cutoff = Date().addingTimeInterval(-7 * 86400)
        let succeededCutoff = Date().addingTimeInterval(-86400)
        let previous = jobs
        var changed = false
        for index in jobs.indices where jobs[index].request.payload["image_base64"] != nil || jobs[index].request.payload["images"]?.array?.contains(where: { $0.object?["data_base64"] != nil }) == true {
            let shouldExpire = jobs[index].consumed
                || (jobs[index].status == "succeeded" && ((jobs[index].request.kind != "food" && jobs[index].request.kind != "coach") || jobs[index].created < succeededCutoff))
                || (jobs[index].isTerminal && jobs[index].created < cutoff)
            if shouldExpire {
                jobs[index].request.payload.removeValue(forKey: "image_base64")
                if let images = jobs[index].request.payload["images"]?.array {
                    jobs[index].request.payload["images"] = .array(images.map { item in
                        var fields = item.object ?? [:]; fields.removeValue(forKey: "data_base64"); return .object(fields)
                    })
                }
                changed = true
            }
        }
        if changed {
            do { try persist() } catch { jobs = previous; throw error }
        }
    }

    func job(_ id: String?) -> AILocalJob? {
        var current = id
        for _ in 0..<32 {
            guard let item = jobs.first(where: { $0.id == current }) else { return nil }
            guard let replacement = item.replacementID else { return item }
            current = replacement
        }
        return nil
    }
    func latest(kind: String, date: Date) -> AILocalJob? {
        jobs.first {
            $0.request.payload["operation"]?.string != "notes_only" && $0.result?.kind != "plan_notes"
                && !(kind == "parse_plan" && $0.digest.hasPrefix("recovered/") && $0.result == nil)
                && $0.request.kind == kind && $0.request.date == ClubDates.key(date)
                && !$0.consumed && $0.replacementID == nil && (kind != "food" || $0.status == "succeeded")
        }
    }

    func reportInput(date: Date, log: DayLog, nutritionTarget: NutritionTarget? = nil, weightHistory: [BodyWeightPoint] = [], goalContext: ClubAIContext? = nil, allowEmpty: Bool = false) throws -> AIInput {
        guard !ClubDates.isFuture(date) else { throw AIClientError.message("未来日期还没有实际记录，到了当天才能生成复盘。") }
        guard allowEmpty || DailyReportEligibility.hasRecords(log) else { throw AIClientError.message(DailyReportEligibility.missingMessage) }
        guard log.exercises.count <= 30, log.meals.count <= 50, log.exercises.allSatisfy({ $0.sets.count <= 50 }) else {
            throw AIClientError.message("这一天的记录超过分析范围（30 个动作、每动作 50 组、50 餐），请精简重复记录后再生成。")
        }
        let exercises: [JSONValue] = log.exercises.map { exercise in
            var fields: [String: JSONValue] = ["name": .string(String(exercise.displayName.prefix(100))), "exercise_id": .string(exercise.id.uuidString.lowercased()), "session_id": exercise.workoutSessionID.map { .string($0.uuidString.lowercased()) } ?? .null, "sets": .array(exercise.sets.map {
                .object(["id": .string($0.id.uuidString.lowercased()), "weight": .number($0.weight), "reps": .number(Double($0.reps)), "completed": .bool($0.validCompletion), "durationSeconds": $0.durationSeconds.map { .number(Double($0)) } ?? .null])
            })]
            if let id = exercise.libraryID { fields["library_id"] = .string(id) }
            if let id = exercise.customExerciseID { fields["custom_id"] = .string(id.uuidString.lowercased()); fields["is_custom"] = .bool(true) }
            return .object(fields)
        }
        let meals: [JSONValue] = log.meals.map {
            .object(["name": .string(String($0.name.prefix(100))), "nutrition_known": .bool($0.hasNutrition), "calories": .number($0.calories), "protein": .number($0.protein),
                     "carbs": .number($0.carbs), "fat": .number($0.fat)])
        }
        var payload: [String: JSONValue] = ["exercises": .array(exercises), "meals": .array(meals)]
        if let sessions = log.workoutSessions, !sessions.isEmpty { payload["workout_sessions"] = try .encode(sessions) }
        if let entry = log.bodyWeight, entry.isValid {
            if let kg = entry.kilograms { payload["body_weight_kg"] = .number(kg) }
            if let fat = entry.bodyFatPercentage { payload["body_fat_percentage"] = .number(fat) }
            if let waist = entry.waistCircumferenceCM { payload["waist_circumference_cm"] = .number(waist) }
            if let recorded = entry.recordedAt { payload["body_measurement_recorded_at"] = .number(recorded.timeIntervalSinceReferenceDate) }
            if let source = entry.source { payload["body_measurement_source"] = .string(source) }
        }
        if !weightHistory.isEmpty {
            payload["body_weight_history"] = .array(weightHistory.suffix(30).map {
                .object(["date": .string(ClubDates.key($0.date)), "kilograms": .number($0.kilograms)])
            })
        }
        let historicalTarget = log.nutritionTarget
        let target: NutritionTarget?
        if historicalTarget?.generalGuidanceOnly == true { target = historicalTarget }
        else if nutritionTarget?.generalGuidanceOnly == true { target = nutritionTarget }
        else { target = historicalTarget ?? nutritionTarget }
        if let target {
            if target.generalGuidanceOnly == true {
                payload["nutritionTarget"] = .object(["generalGuidanceOnly": .bool(true)])
            } else {
                payload["nutritionTarget"] = try .encode(target)
            }
        }
        if let summary = log.health, summary.hasData {
            payload["health"] = try JSONValue.encode(summary)
            if log.workoutSessions?.isEmpty != false, log.completedSets > 0, let linked = log.linkedDeviceWorkoutID, summary.workouts.contains(where: { $0.id == linked }) {
                payload["workout_link"] = .object(["device_workout_id": .string(linked), "confirmed_by_user": .bool(true)])
            }
            payload["health_interpretation"] = .string("健康数据为用户确认分享的日汇总；时间为当地自然日，sleep单位小时，心率bpm，热量kcal；bodyMass/leanBodyMass单位kg，bodyFatPercentage单位%，height单位cm，bodyMassIndex单位kg/m²，waistCircumference单位cm，身体测量的recordedAt是实际采样时间。空值代表未知，不是0。每项取一个数据来源，不跨来源累加。身体指标只作健身背景，不作医疗诊断；单次测量不能证明身体趋势。运动列表按开始日归属，运动热量可能包含在全天活动能量中，不能相加，也不能把力量总训练量当成热量。睡眠为当日0点至24点区间并集，不一定是完整一夜。注意更新时间和数据覆盖范围。")
        }
        if let goalContext { payload["goal_context"] = try .encode(goalContext) }
        payload["coaching_version"] = .number(1)
        payload["meals_complete"] = .bool(log.mealsComplete)
        payload["training_confirmed"] = .bool(log.isTrainingConfirmed)
        payload["analysis_version"] = .number(2)
        payload["training_feedback_version"] = .number(1)
        if let cycle = log.planCycle, cycle.dates.contains(ClubDates.key(date)) {
            payload["planned_training_day"] = .bool(cycle.plannedDates.contains(ClubDates.key(date)))
        }
        return AIInput(kind: "report", date: ClubDates.key(date), payload: payload)
    }

    func matching(_ input: AIInput) -> AILocalJob? {
        guard let digest = try? digestFor(input) else { return nil }
        return jobs.first { $0.digest == digest }
    }

    func planExercisesInput(_ log: DayLog) throws -> [JSONValue] {
        guard log.exercises.count <= 30, log.exercises.allSatisfy({$0.sets.count <= 50}) else {
            throw AIClientError.message("计划超过 30 个动作或每动作 50 组，请精简后复盘。")
        }
        return log.exercises.map { exercise in
            var fields: [String: JSONValue] = ["name":.string(String(exercise.displayName.prefix(100))),"sets":.array(exercise.sets.map {
                .object(["weight":.number($0.weight),"reps":.number(Double($0.reps)),"completed":.bool(false),"durationSeconds":$0.durationSeconds.map{.number(Double($0))} ?? .null])
            })]
            if exercise.customExerciseID != nil { fields["is_custom"] = .bool(true) }
            return .object(fields)
        }
    }

    func submit(_ input: AIInput, forceNew: Bool = false, submissionID: String? = nil, onboardingSessionID: String? = nil) throws -> String {
        if let submissionID {
            guard UUID(uuidString: submissionID) != nil else { throw AIClientError.message("任务编号不正确。") }
            // A deterministic automatic slot is immutable even if later records change.
            if let existing = jobs.first(where: { $0.id == submissionID }) { return existing.id }
        }
        if input.kind == "generate_plan", !NewPlanDateRules.isValidStart(input.date) {
            throw AIClientError.message("新训练计划请从今天或之后开始；过去的训练请在训练页补记。")
        }
        if ["report", "food", "coach"].contains(input.kind), let date = ClubDates.date(fromKey: input.date), ClubDates.isFuture(date) {
            throw AIClientError.message("未来日期不能记录餐食或生成复盘。")
        }
        let digest = try digestFor(input)
        if !forceNew, let previous = jobs.first(where: { $0.digest == digest && $0.replacementID == nil && !["deleted", "expired", "rejected", "discarded"].contains($0.status) }) {
            if !previous.isTerminal { launch(previous.id) }
            return previous.id
        }
        let id = submissionID ?? UUID().uuidString.lowercased()
        var payload = planExplanationInput(input).payload
        if ["food", "generate_plan", "report"].contains(input.kind) {
            payload["timeZone"] = .string(TimeZone.current.identifier)
        }
        if input.kind == "food" {
            if payload["mode"]?.string == "multiple", payload["reference_date"] == nil {
                payload["reference_date"] = .string(ClubDates.key(Date()))
            }
        }
        payload["_routing_version"] = .number(Double(CloudAnalysisConsent.routerVersion(accountID: activeAccountID)))
        var body = AIRequest(id: id, kind: input.kind, date: input.date, payload: payload)
        body.onboardingSessionID = onboardingSessionID ?? input.payload["_onboarding_session_id"]?.string
        body.contextSource = input.payload["context_source"]
        if let photo = input.payload["image_base64"]?.string {
            try expirePhotoInputs()
            let retained = jobs.reduce(0) { $0 + ($1.request.payload["image_base64"]?.string?.utf8.count ?? 0) }
            guard photo.utf8.count + retained <= 24 * 1024 * 1024 else {
                throw AIClientError.message("本机待处理照片较多，请先保存需要的识别结果，或删除不需要的任务后再拍照。")
            }
        }
        jobs.insert(AILocalJob(id: id, digest: digest, request: body), at: 0)
        do { try persist() } catch { jobs.removeAll { $0.id == id }; throw error }
        launch(id)
        return id
    }

    /// Phase 2: a completed SSE run becomes a normal local turn so every
    /// existing renderer, history rule and card router keeps working unchanged.
    /// No cloud submit happens here — the server already persisted this turn.
    func importStreamedCoach(_ completion: AIRunCompletion, input: AIInput) throws {
        if let index = jobs.firstIndex(where: { $0.id == completion.messageID }), jobs[index].status == "succeeded", jobs[index].result?.coach != nil { return }
        var payload = input.payload
        payload["_routing_version"] = .number(Double(CloudAnalysisConsent.routerVersion(accountID: activeAccountID)))
        let request = AIRequest(id: completion.messageID, kind: input.kind, date: input.date, payload: payload)
        var result = AIResult(kind: "coach", notes: [])
        result.coach = completion.coach
        let digest = (try? digestFor(input)) ?? completion.messageID
        var job = AILocalJob(id: completion.messageID, digest: digest, request: request)
        job.status = "succeeded"
        job.result = result
        job.traceID = completion.traceID
        let previous = jobs
        if let index = jobs.firstIndex(where: { $0.id == job.id }) { jobs[index] = job } else { jobs.insert(job, at: 0) }
        do { try persist() } catch { jobs = previous; throw error }
    }

    private var recoveryCursor: String?
    @Published private(set) var hasMoreTaskHistory = false
    private var recoveryBusy = false
    private var recoveryGeneration = UUID()
    struct RecoveredTask: Decodable { var id: String; var kind: String; var date: String; var status: String; var created: Double; var purpose: String? = nil }
    func recoverTasks(account: AccountService, weekly: WeeklyReviewService, store: AppStore, targetID: String? = nil) async {
        guard let user = activeAccountID, account.user?.id == user, storageAvailable, !account.isPreviewAccount, !recoveryBusy else { return }
        if let targetID, UUID(uuidString: targetID) == nil { return }
        let recoveryTicket = recoveryGeneration
        recoveryBusy = true
        defer { if recoveryTicket == recoveryGeneration { recoveryBusy = false } }
        do {
            struct List: Decodable { var items: [RecoveredTask]; var next_cursor: String? = nil }
            // Resume from the next cursor on later foreground passes. This is
            // a per-pass budget, never a limit on recoverable account history.
            for _ in 0..<(targetID == nil ? 4 : 1) {
                let suffix = targetID.map { "?id=" + $0.lowercased() } ?? recoveryCursor.map { "?cursor=" + $0 } ?? ""
                let response = try await account.cloudRequest(path: "/me/ai/tasks" + suffix, expectedUserID: user)
                guard recoveryTicket == recoveryGeneration, activeAccountID == user, account.user?.id == user, !Task.isCancelled else { return }
                guard response.statusCode == 200 else { throw AIClientError.message("任务列表暂不可用，稍后继续恢复。") }
                let page = try JSONDecoder().decode(List.self, from: response.data)
                let previous = jobs
                for item in page.items where ClubDates.date(fromKey: item.date) != nil {
                    if item.kind == "weekly_review" { weekly.recoverTask(item, store: store); continue }
                    if item.kind == "food", store.hasAppliedAIJob(item.id) { continue }
                    guard !(store.state.deletedAIJobIDs ?? []).contains(item.id), !jobs.contains(where: { $0.id == item.id }) else { continue }
                    jobs.append(AILocalJob(id: item.id, digest: "recovered/"+item.id, request: AIRequest(id: item.id, kind: item.kind, date: item.date, payload: item.purpose.map { ["purpose": .string($0)] } ?? [:]), status: "waiting_connection", created: Date(timeIntervalSince1970: item.created)))
                }
                if jobs.count != previous.count { do { try persist() } catch { jobs = previous; throw error } }
                if targetID == nil { recoveryCursor = page.next_cursor; hasMoreTaskHistory = page.next_cursor != nil }
                resume()
                if targetID != nil || page.next_cursor == nil { break }
            }
            // A completed pass proves the connection recovered; clear stale status.
            if recoveryTicket == recoveryGeneration, activeAccountID == user {
                recoveryNotice = nil
                recoveryGate.reset()
            }
        } catch {
            if recoveryTicket == recoveryGeneration, activeAccountID == user {
                // AUD-022/FIX-022：后台恢复是轮询行为，不能每 30 秒抢全局模态。
                // 状态放到任务/同步提示，按账号与原因去重；用户主动请求的错误仍走 notice。
                if recoveryGate.shouldPresent(accountID: user) {
                    recoveryNotice = "后台任务暂未恢复，联网后会从已保存的进度继续。手动记录不受影响。"
                }
            }
        }
    }

    func pause() {
        foreground130 = false; retryTimer130?.cancel(); retryTimer130 = nil
        workerGeneration = UUID(); pendingWorkers.removeAll()
        workers.values.forEach { $0.cancel() }; workers.removeAll()
    }

    func resume() {
        foreground130 = true
        defer { scheduleRetry130() }
        if !storageAvailable {
            // Protected files may become readable after the phone is unlocked.
            // Recheck the original files; never replace an unreadable index.
            storageAvailable = true
            do { try loadCurrentJobs() } catch { storageAvailable = false }
        }
        guard storageAvailable else { return }
        for job in jobs.sorted(by: { $0.created > $1.created }) where !job.isTerminal && job.replacementID == nil && !(job.request.kind == "food" && job.consumed) && AIRetryPolicy.isDue(job.retryAfter) { launch(job.id) }
    }

    func retry(_ id: String) {
        guard let local = job(id), local.status != "succeeded", workers[local.id] == nil else { return }
        if local.request.kind == "generate_plan", !NewPlanDateRules.isValidStart(local.request.date) {
            notice = "原计划的起始日已过去，请选择今天或之后的日期重新制定。"; return
        }
        guard storageAvailable else { notice = "任务文件尚未恢复，已暂停提交，原记录保留。"; return }
        if let after = local.retryAfter, after > Date() { notice = local.error ?? "服务尚未恢复，请稍后重试。"; return }
        guard local.status != "discarded", !(local.request.kind == "food" && local.consumed) else { return }
        if local.request.kind == "food", local.request.payload["image_base64"] == nil, local.request.payload["description"] == nil,
           local.created < Date().addingTimeInterval(-7 * 86400) || ["deleted", "expired", "rejected"].contains(local.status) {
            notice = "原照片已过保留期或不在这台手机上，请回到饮食页面重新拍照或选图。"; return
        }
        if local.digest.hasPrefix("recovered/"), ["deleted", "expired", "rejected"].contains(local.status) {
            notice = "原输入只保存在提交时的手机，请回到对应页面重新填写或选图。"; return
        }
        if ["deleted", "expired", "rejected"].contains(local.status) {
            do {
                let input = AIInput(kind: local.request.kind, date: local.request.date, payload: local.request.payload)
                let replacement = try submit(input, forceNew: true)
                if let index = jobs.firstIndex(where: { $0.id == local.id }) { jobs[index].replacementID = replacement; try persist() }
            } catch { notice = AppErrorText.message(error) }
            return
        }
        enqueue(local.id, retry: true)
    }

    func markConsumed(_ id: String) {
        guard let resolved = job(id)?.id, let index = jobs.firstIndex(where: { $0.id == resolved }) else { return }
        jobs[index].consumed = true
        if jobs[index].request.kind == "food", !jobs[index].isTerminal {
            jobs[index].status = "discarded"
            workers.removeValue(forKey: resolved)?.cancel()
            pendingWorkers.removeAll { $0.id == resolved }
        }
        jobs[index].request.payload.removeValue(forKey: "image_base64")
        do { try persist() } catch { notice = AppErrorText.message(error) }
    }

    func settlePlanCandidates(adopted id: String) {
        guard let chosen = job(id), chosen.request.kind == "generate_plan" else { return }
        func range(_ item: AILocalJob) -> DateInterval? {
            guard let start = ClubDates.date(fromKey: item.request.date) else { return nil }
            var length = 7
            if case .number(let value)? = item.request.payload["plan_days"], [7.0,14.0,28.0].contains(value) { length = Int(value) }
            guard let end = ClubDates.calendar.date(byAdding: .day, value: length, to: start) else { return nil }
            return DateInterval(start: start, end: end)
        }
        guard let selected = range(chosen) else { return }
        let before = jobs
        var changed = false
        for index in jobs.indices {
            let item = jobs[index]
            guard item.id != chosen.id, item.request.kind == "generate_plan", !item.consumed,
                  item.replacementID == nil, item.created <= chosen.created, let interval = range(item),
                  interval.start < selected.end, selected.start < interval.end else { continue }
            // Retain the old candidate data; only stop presenting it as a
            // second outstanding plan after the user adopted its replacement.
            jobs[index].replacementID = chosen.id; changed = true
        }
        guard changed else { return }
        do { try persist() } catch { jobs = before; notice = AppErrorText.message(error) }
    }

    func cloudJobs() -> [AILocalJob] {
        jobs.compactMap { job in
            guard job.result != nil else { return nil }
            var clean = job
            clean.request.payload.removeValue(forKey: "image_base64")
            if let images = clean.request.payload["images"]?.array {
                clean.request.payload["images"] = .array(images.map { item in
                    var fields = item.object ?? [:]; fields.removeValue(forKey: "data_base64"); return .object(fields)
                })
            }
            if clean.status == "succeeded", clean.consumed {
                let retained = Set(["description", "profile", "operation", "reference_date", "_routing_version", "weight_reference"])
                clean.request.payload = clean.request.payload.filter { retained.contains($0.key) }
            }
            return clean
        }
    }

    @discardableResult
    func replaceCloudJobs(_ cloudJobs: [AILocalJob]) -> Bool {
        guard storageAvailable else { return false }
        var byID: [String: AILocalJob] = [:]
        for job in jobs { byID[job.id] = job }
        for var job in cloudJobs {
            if let local = byID[job.id] {
                // A sync snapshot taken before completion must not erase a durable result.
                if local.status == "succeeded", !job.isTerminal, job.status != "cancelled" { continue }
                job.consumed = job.consumed || local.consumed
                if !job.consumed, job.request.payload["image_base64"] == nil {
                    job.request.payload["image_base64"] = local.request.payload["image_base64"]
                }
            }
            if job.consumed { job.request.payload.removeValue(forKey: "image_base64") }
            byID[job.id] = job
        }
        let merged = byID.values.sorted { $0.created > $1.created }
        guard jobs != merged else { return true }
        let previous = jobs; jobs = merged
        do { try persist(notifyCloud: false); return true } catch { jobs = previous; notice = AppErrorText.message(error); return false }
    }

    func pruneArchivedJobs(_ ids: Set<String>) {
        guard storageAvailable, jobs.contains(where: { ids.contains($0.id) }) else { return }
        let previous = jobs
        jobs.removeAll { ids.contains($0.id) }
        do {
            try persist(notifyCloud: false)
            pendingWorkers.removeAll { ids.contains($0.id) }
            for id in ids { workers[id]?.cancel() }
        } catch { jobs = previous; notice = "归档记录已保存，本机报告缓存尚未清理，将在下次同步继续处理。" }
    }

    private func digestFor(_ input: AIInput) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(planExplanationInput(input))).map { String(format: "%02x", $0) }.joined()
    }

    private func planExplanationInput(_ input: AIInput) -> AIInput {
        var value = input
        if value.kind == "generate_plan", value.payload["_v2_profile"]?.boolValue != true {
            value.payload["plan_explanation_version"] = .number(1)
        }
        return value
    }

    private func launch(_ id: String) { enqueue(id, retry: false) }

    private func enqueue(_ id: String, retry: Bool) {
        guard storageAvailable, activeAccountID != nil, workers[id] == nil else { return }
        if let index = pendingWorkers.firstIndex(where: { $0.id == id }) {
            pendingWorkers[index].retry = pendingWorkers[index].retry || retry
        } else { pendingWorkers.append((id, retry)) }
        drainWorkers()
    }

    private func drainWorkers() {
        while workers.count < maximumWorkers && !pendingWorkers.isEmpty {
            let item = pendingWorkers.removeFirst()
            guard let local = job(item.id), item.retry || !local.isTerminal else { continue }
            guard !(local.request.kind == "food" && local.consumed) else { continue }
            if [.number(2), .number(3)].contains(local.request.payload["_routing_version"] ?? .null), !cloudRoutingAllowed {
                requiresRoutingConsent = true
                continue
            }
            let ticket = workerGeneration
            workers[item.id] = Task { [weak self] in
                guard let self else { return }
                defer {
                    if ticket == self.workerGeneration {
                        self.workers[item.id] = nil
                        self.drainWorkers()
                    }
                }
                guard ticket == self.workerGeneration, !Task.isCancelled else { return }
                if item.retry {
                    do {
                        let current = try await self.request(path: "/jobs/\(item.id)")
                        let status = try JSONDecoder().decode(AIJobResponse.self, from: current).status
                        let raw: Data
                        if status == "failed" { raw = try await self.request(path: "/jobs/\(item.id)/retry", method: "POST", body: Data("{}".utf8)) }
                        else { raw = current }
                        guard ticket == self.workerGeneration, !Task.isCancelled else { return }
                        self.update(try JSONDecoder().decode(AIJobResponse.self, from: raw))
                    } catch AIClientError.http(let status, let code, let message) {
                        guard ticket == self.workerGeneration, !Task.isCancelled else { return }
                        if code == "input_expired", let index = self.jobs.firstIndex(where: { $0.id == item.id }) {
                            self.jobs[index].status = "expired"; self.jobs[index].errorCode = code
                            self.jobs[index].error = "服务器输入已过期，可使用本机保留的输入重新生成。"
                            do { try self.persist() } catch { self.notice = AppErrorText.message(error) }
                            return
                        }
                        if status != 404 { self.recordFailure(AIClientError.http(status, code, message), id: item.id); return }
                    } catch {
                        if ticket == self.workerGeneration, !Task.isCancelled { self.recordFailure(error, id: item.id) }
                        return
                    }
                }
                await self.process(item.id, ticket: ticket)
            }
        }
    }

    private func process(_ id: String, ticket: UUID) async {
        guard ticket == workerGeneration, !Task.isCancelled, let local = job(id) else { return }
        #if DEBUG
        if accountService?.isPreviewAccount == true {
            guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
            do {
                jobs[index].result = try previewResult(for: local.request)
                jobs[index].status = "succeeded"
                jobs[index].provider = "开发预览"
                jobs[index].model = "offline"
                jobs[index].error = nil
            } catch {
                jobs[index].status = "failed"
                jobs[index].error = AppErrorText.message(error)
            }
            do { try persist() } catch { notice = AppErrorText.message(error) }
            return
        }
        #endif
        do {
            var data: Data
            do {
                data = try await request(path: "/jobs/\(id)")
                guard ticket == workerGeneration, !Task.isCancelled else { return }
                // Another device may have filled this automatic date slot first.
                // Never label its unknown submitted evidence as this device's snapshot.
                if id.hasPrefix("a170da11-"), ["pending", "waiting_connection", "waiting_service"].contains(local.status),
                   let index = jobs.firstIndex(where: { $0.id == id }) {
                    jobs[index].digest = "recovered/" + id; jobs[index].request.payload = jobs[index].request.payload["purpose"].map { ["purpose": $0] } ?? [:]
                }
            }
            catch AIClientError.http(let status, _, _) where status == 404 {
                guard ticket == workerGeneration, !Task.isCancelled else { return }
                guard !local.digest.hasPrefix("recovered/") else { throw AIClientError.http(404, "input_expired", "原任务已清除，请重新填写或选图后提交。") }
                do { data = try await request(path: "/jobs", method: "POST", body: JSONEncoder().encode(local.request)) }
                catch AIClientError.http(let status, let code, _) where id.hasPrefix("a170da11-") && (status == 409 || code == "id_conflict") {
                    data = try await request(path: "/jobs/\(id)")
                    guard ticket == workerGeneration, !Task.isCancelled else { return }
                    if let index = jobs.firstIndex(where: { $0.id == id }) { jobs[index].digest = "recovered/" + id; jobs[index].request.payload = jobs[index].request.payload["purpose"].map { ["purpose": $0] } ?? [:] }
                }
            }
            guard ticket == workerGeneration, !Task.isCancelled else { return }
            // Phase 3: durable Run + SSE for report / weekly_review. Server-authoritative
            // flag; any refusal falls through to the polling loop with the same
            // client_job_id, so the server maps both paths to one Python job.
            if await runKindPath(id: id, ticket: ticket, request: local.request) { return }
            let deadline = Date().addingTimeInterval(600)
            var pollDelay: UInt64 = 300_000_000
            while !Task.isCancelled && ticket == workerGeneration {
                let response = try JSONDecoder().decode(AIJobResponse.self, from: data)
                guard response.id == id else { throw AIClientError.message("任务编号不匹配，请重试。") }
                update(response)
                if ["succeeded", "failed", "deleted", "expired"].contains(response.status) { return }
                if Date() > deadline { throw AIClientError.deferred(503, "processing_later", "后台仍在处理，输入已保存，可稍后继续查看。", Date().addingTimeInterval(60)) }
                try await Task.sleep(nanoseconds: pollDelay)
                pollDelay = min(1_500_000_000, pollDelay + 150_000_000)
                guard ticket == workerGeneration, !Task.isCancelled else { return }
                data = try await request(path: "/jobs/\(id)")
            }
        } catch {
            if Task.isCancelled || ticket != workerGeneration { return }
            recordFailure(error, id: id)
        }
    }

    /// Phase 3: durable Run + SSE for report / weekly_review.
    /// Returns true when the run reached a terminal state (the caller must stop);
    /// false means the caller keeps the legacy polling loop.
    private func runKindPath(id: String, ticket: UUID, request: AIRequest) async -> Bool {
        guard ticket == workerGeneration, !Task.isCancelled,
              let account = accountService, let owner = activeAccountID,
              FeatureFlagService.shared.runV2Enabled,
              Self.runV2KindAllowed(request.kind),
              ["report", "weekly_review"].contains(request.kind) else { return false }
        let input = AIInput(kind: request.kind, date: request.date, payload: request.payload)
        do {
            let outcome = try await AIRunKindRunner.run(input: input, clientJobID: id, owner: owner, account: account)
            guard ticket == workerGeneration, !Task.isCancelled else { return true }
            let result = try outcome.aiResult()
            guard let index = jobs.firstIndex(where: { $0.id == id }) else { return true }
            jobs[index].result = result
            jobs[index].status = "succeeded"
            jobs[index].traceID = outcome.traceID
            jobs[index].error = nil
            jobs[index].errorCode = nil
            jobs[index].retryAfter = nil
            do { try persist() } catch { notice = AppErrorText.message(error) }
            return true
        } catch let error as AIRunKindError {
            switch error {
            case .uncertain:
                // The create POST may have been accepted. Never resubmit: keep
                // polling the same client_job_id, which resolves to the same job.
                return false
            case .disabled, .rejected:
                return false
            case .failed, .resyncUnavailable:
                guard ticket == workerGeneration, !Task.isCancelled else { return true }
                guard let index = jobs.firstIndex(where: { $0.id == id }) else { return true }
                jobs[index].status = "failed"
                jobs[index].error = error.localizedDescription
                jobs[index].errorCode = "run_failed"
                do { try persist() } catch { notice = AppErrorText.message(error) }
                return true
            }
        } catch {
            return false
        }
    }

    static func runV2KindAllowed(_ kind: String) -> Bool {
        let list = FeatureFlagService.shared.runV2Kinds
        if list.isEmpty { return true }
        return list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.contains(kind)
    }

    private func recordFailure(_ error: Error, id: String) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), !jobs[index].consumed, jobs[index].status != "succeeded" else { return }
        let decision = AIRetryPolicy.decision(error, previousFailures: jobs[index].connectionFailures)
        jobs[index].connectionFailures = decision.failures
        jobs[index].status = decision.status
        jobs[index].retryAfter = decision.after
        jobs[index].errorCode = decision.code
        jobs[index].error = AppErrorText.message(error)
        do { try persist() } catch { notice = "任务状态保存失败，输入仍在本次运行中保留。" }
    }

    func refreshMealBatch(_ id: String) async {
        let owner = activeAccountID
        let generation = workerGeneration
        let key = generation.uuidString + "/" + id
        guard let local = job(id), !local.consumed, local.request.payload["mode"]?.string == "multiple",
              !refreshingMealBatchKeys.contains(key) else { return }
        refreshingMealBatchKeys.insert(key)
        defer { refreshingMealBatchKeys.remove(key) }
        do {
            let data = try await request(path: "/jobs/\(id)")
            guard activeAccountID == owner, workerGeneration == generation, !Task.isCancelled else { return }
            let response = try JSONDecoder().decode(AIJobResponse.self, from: data)
            guard response.id == id else { return }
            update(response)
        } catch { if activeAccountID == owner, workerGeneration == generation, !Task.isCancelled { notice = "分餐结果暂未刷新，本机内容保留；联网后可以重试。" } }
    }

    private func update(_ response: AIJobResponse) {
        guard let index = jobs.firstIndex(where: { $0.id == response.id }) else { return }
        guard jobs[index].status != "discarded", !(jobs[index].request.kind == "food" && jobs[index].consumed) else { return }
        guard jobs[index].status != response.status || jobs[index].error != response.error_message ||
                (response.result?.kind == "meal_batch" && jobs[index].result?.meals == nil) else { return }
        jobs[index].status = response.status
        jobs[index].result = response.result
        jobs[index].provider = response.provider
        jobs[index].model = response.model
        jobs[index].error = response.status == "deleted" ? "此任务已过期或被删除，点击重新生成可创建新任务。" : AIVisibleError.message(code: response.error_code, fallback: response.error_message)
        jobs[index].errorCode = response.error_code
        jobs[index].retryAfter = nil
        jobs[index].connectionFailures = nil
        if response.status == "succeeded", (jobs[index].request.kind != "food" || jobs[index].consumed) {
            jobs[index].request.payload.removeValue(forKey: "image_base64")
        }
        if response.status == "succeeded", response.result?.kind == "report", !ClubPushService.shared.ready {
            AppNotificationService.notifyDailyReportReady(date: ClubDates.date(fromKey: jobs[index].request.date) ?? jobs[index].created, accountID: activeAccountID)
        }
        if response.status == "succeeded", !ClubPushService.shared.ready, let purpose = response.result?.coach?.purpose, ["weekly","workout"].contains(purpose) {
            AppNotificationService.notifyClubFollowupReady(date: ClubDates.date(fromKey: jobs[index].request.date) ?? jobs[index].created, weekly: purpose == "weekly", jobID: jobs[index].id, accountID: activeAccountID)
        }
        do { try persist() } catch { notice = AppErrorText.message(error) }
    }

    #if DEBUG
    /// Deterministic offline content for DEBUG preview accounts only.
    private func previewResult(for request: AIRequest) throws -> AIResult {
        if request.payload["operation"]?.string == "notes_only" {
            throw AIClientError.message("开发预览不提供真实翻译。请用联网账号整理旧计划提醒。")
        }
        switch request.kind {
        case "generate_plan", "parse_plan":
            let profileData = try JSONEncoder().encode(request.payload["profile"] ?? .object([:]))
            let profile = try JSONDecoder().decode(MemberProfile.self, from: profileData)
            let start = ClubDates.date(fromKey: request.date) ?? Date()
            let weekdays = (profile.trainingDays ?? []).isEmpty ? [1, 3, 5] : Array((profile.trainingDays ?? []).prefix(7))
            func sessionDate(weekday: Int) -> Date {
                for offset in 0..<8 {
                    let candidate = ClubDates.calendar.date(byAdding: .day, value: offset, to: start) ?? start
                    if (ClubDates.calendar.component(.weekday, from: candidate) + 5) % 7 + 1 == weekday { return candidate }
                }
                return start
            }
            func trainingExercises(home: Bool) -> [AIPlanExercise] {
                func exercise(_ name: String, _ muscle: String) -> AIPlanExercise {
                    AIPlanExercise(name: name, muscle: muscle, sets: [
                        AIPlanSet(weight: nil, reps: 10), AIPlanSet(weight: nil, reps: 10), AIPlanSet(weight: nil, reps: 10)
                    ], library_query: name)
                }
                let equipment = profile.equipment ?? ""
                if home && !equipment.contains("哑铃") {
                    return [exercise("徒手深蹲", "腿部"), exercise("跪姿俯卧撑", "胸部"), exercise("臀桥", "臀部")]
                }
                if home {
                    return [exercise("高脚杯深蹲", "腿部"), exercise("哑铃卧推", "胸部"), exercise("单臂哑铃划船", "背部")]
                }
                return [exercise("杠铃深蹲", "腿部"), exercise("杠铃卧推", "胸部"), exercise("坐姿划船", "背部")]
            }
            var sessions: [AIPlanSession] = weekdays.enumerated().map { index, weekday in
                let home: Bool
                if profile.venue == "在家" {
                    home = true
                } else if profile.venue == "健身房" {
                    home = false
                } else if let homeDays = profile.homeTrainingDays, !homeDays.isEmpty {
                    home = homeDays.contains(weekday)
                } else {
                    home = index % 2 == 0
                }
                return AIPlanSession(
                    date: ClubDates.key(sessionDate(weekday: weekday)),
                    label: home ? "居家训练 · 全身基础" : "健身房 · 全身力量",
                    exercises: trainingExercises(home: home)
                )
            }
            sessions.sort { $0.date < $1.date }
            return AIResult(
                kind: "plan", notes: ["开发预览方案，仅用于测试操作流程。"], title: "专属训练计划",
                sessions: sessions,
                name: nil, is_food: nil, components: nil, estimated: nil, calories: nil,
                protein: nil, carbs: nil, fat: nil, summary: nil, training: nil, nutrition: nil, recovery: nil
            )
        case "food":
            let item = FoodComponent(
                name: "鸡胸肉藜麦碗", amount: 1, unit: "份", calories: 520, protein: 38,
                carbs: 58, fat: 14, basis: "visible", details: ["开发预览估算", "请按实际份量调整"]
            )
            return AIResult(
                kind: "meal", notes: ["这是开发预览餐食，不代表真实图像识别。"], title: nil, sessions: nil,
                name: "鸡胸肉藜麦碗", is_food: true, components: [item], estimated: true,
                calories: 520, protein: 38, carbs: 58, fat: 14,
                summary: nil, training: nil, nutrition: nil, recovery: nil
            )
        case "report":
            return AIResult(
                kind: "report", notes: ["开发预览日报，仅用于测试展示。"], title: nil, sessions: nil,
                name: nil, is_food: nil, components: nil, estimated: nil, calories: nil,
                protein: nil, carbs: nil, fat: nil,
                summary: "今天完成了训练与记录，正在形成稳定节奏。",
                training: "动作完成情况整体良好；下一次训练优先保持动作稳定，再逐步增加负荷。",
                nutrition: "记录已保存。开发预览不会读取真实餐食，请以实际摄入为准。",
                recovery: "注意睡眠和训练后的放松；如有持续疼痛请停止训练并寻求专业帮助。",
                training_feedback: .preview
            )
        case "coach":
            return try previewCoachResult(for: request)
        default:
            throw AIClientError.message("开发预览暂不支持此 AI 功能。")
        }
    }

    /// 开发预览对话：镜像服务端 card_composer 的确定性组装——今天的安排来自请求上下文
    /// 的 days[today]（upcoming 只含未来 1-7 天），无数据返回空态卡，绝不编造。
    private func previewCoachResult(for request: AIRequest) throws -> AIResult {
        var todayExercises: [JSONValue] = []
        if case .array(let days)? = request.payload["days"] {
            for day in days {
                guard case .object(let dayObject) = day, dayObject["date"]?.string == request.date,
                      case .object(let payload)? = dayObject["payload"],
                      case .array(let exercises)? = payload["exercises"] else { continue }
                todayExercises = exercises
            }
        }
        var totalSets = 0
        for exercise in todayExercises {
            if case .object(let fields) = exercise, case .array(let sets)? = fields["sets"] {
                totalSets += sets.count
            }
        }
        let card: AICardEnvelope
        if todayExercises.isEmpty {
            card = AICardEnvelope(
                card_id: "card-preview-today-training", card_type: "today_training", schema_version: 1,
                title: "今日训练",
                payload: .object(["date": .string(request.date), "empty": .bool(true),
                                  "reason": .string("no_planned_session"),
                                  "hint": .string("今天没有已安排的训练。可以安排一次，或把今天留给恢复。")]),
                actions: [AICardAction(action_id: "create_plan", label: "创建安排", kind: "navigate")],
                evidence_refs: [], created_at: nil, expires_at: nil)
        } else {
            let minutes = max(15, min(150, totalSets * 3))
            card = AICardEnvelope(
                card_id: "card-preview-today-training", card_type: "today_training", schema_version: 1,
                title: "今日训练",
                payload: .object(["date": .string(request.date),
                                  "display_name": .string("今日训练安排"),
                                  "exercise_count": .number(Double(todayExercises.count)),
                                  "total_sets": .number(Double(totalSets)),
                                  "estimated_minutes": .number(Double(minutes)),
                                  "estimation_basis": .string("按 \(totalSets) 组、每组约 3 分钟估算")]),
                actions: [AICardAction(action_id: "start_training", label: "开始训练", kind: "navigate"),
                          AICardAction(action_id: "view_plan", label: "查看计划", kind: "navigate")],
                evidence_refs: ["day/" + request.date], created_at: nil, expires_at: nil)
        }
        var answer = todayExercises.isEmpty
            ? "开发预览：今天还没有安排好的训练。可以点下方卡片创建一次安排，或把今天留给恢复。真实环境的回答会结合你的近期记录给出建议。"
            : "开发预览：今天的安排在下方卡片里，共 \(todayExercises.count) 个动作、\(totalSets) 组。点「开始训练」即可进入训练页。真实环境的回答会结合你的近期记录给出建议。"
        // Synthetic display fixture, compiled only in DEBUG; no real records or model response.
        if ProcessInfo.processInfo.environment["BOJI_UI_TEST_LONG_CHAT"] == "1" {
            answer = (1...28).map { "第\($0)段：这是一条用于检查长对话滚动和输入框避让的开发预览文字。" }.joined(separator: "\n\n") + "\n\n长回复末尾可见检查127"
        }
        return AIResult(
            coach: ClubCoachAnswer(answer: answer, sources: [], actions: [], cards: ProcessInfo.processInfo.environment["BOJI_UI_TEST_LONG_CHAT"] == "1" ? [] : [card]),
            kind: "coach", notes: ["开发预览对话，仅用于测试卡片流程。"], title: nil, sessions: nil,
            name: nil, is_food: nil, components: nil, estimated: nil,
            calories: nil, protein: nil, carbs: nil, fat: nil,
            summary: nil, training: nil, nutrition: nil, recovery: nil)
    }

    #endif

    @Published private(set) var memoryPage: ClubMemoryPage?
    @Published private(set) var memoryError: String?
    private var memoryFetchedAt: Date?
    private var intelligenceGeneration = UUID()
    private var homeInsightAttemptedDay: Set<String> = []

    private var domainRefreshTask: Task<Void, Never>?
    func invalidateDomainQueries(refresh: Bool = false) {
        resetPersonalIntelligenceCache()
        guard refresh else { return }
        let ticket = intelligenceGeneration
        domainRefreshTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            guard let self, self.intelligenceGeneration == ticket, !Task.isCancelled else { return }
            await self.refreshMemoryPage(force: true)
            guard self.intelligenceGeneration == ticket, !Task.isCancelled else { return }
            await self.refreshHomeInsightIfNeeded()
        }
    }

    private func resetPersonalIntelligenceCache() {
        domainRefreshTask?.cancel(); domainRefreshTask = nil
        intelligenceGeneration = UUID()
        memoryPage = nil; memoryError = nil; memoryFetchedAt = nil
        homeInsight = nil; homeInsightAttemptedDay = []
    }

    func refreshMemoryPage(force: Bool = false) async {
        guard let owner = activeAccountID, accountService?.isPreviewAccount == false else { return }
        if !force, let memoryFetchedAt, Date().timeIntervalSince(memoryFetchedAt) < 120 { return }
        let ticket = intelligenceGeneration
        do {
            let data = try await intelligenceData(owner: owner, path: "/memory")
            let page = try JSONDecoder().decode(ClubMemoryResponse.self, from: data).columns
            guard activeAccountID == owner, intelligenceGeneration == ticket, !Task.isCancelled else { return }
            memoryPage = page; memoryError = nil; memoryFetchedAt = Date()
        } catch {
            guard activeAccountID == owner, intelligenceGeneration == ticket, !Task.isCancelled else { return }
            memoryError = "读取失败，请检查网络后重试。"
        }
    }

    func mutateMemory(id: String, action: String, content: String? = nil) async -> Bool {
        guard let owner = activeAccountID, accountService?.isPreviewAccount == false else { return false }
        let ticket = intelligenceGeneration
        do {
            let body: Data? = action == "correct"
                ? try JSONSerialization.data(withJSONObject: ["content": content ?? ""])
                : nil
            _ = try await request(path: "/memory/" + id + "/" + action, method: "POST", body: body)
            guard activeAccountID == owner, intelligenceGeneration == ticket, !Task.isCancelled else { return false }
            await refreshMemoryPage(force: true)
            return memoryError == nil
        } catch { return false }
    }

    func createMemory(content: String, kind: String = "preference") async -> Bool {
        guard let owner = activeAccountID, accountService?.isPreviewAccount == false else { return false }
        let ticket = intelligenceGeneration
        do {
            let body = try JSONSerialization.data(withJSONObject: ["content": content, "kind": kind])
            _ = try await request(path: "/memory/create", method: "POST", body: body)
            guard activeAccountID == owner, intelligenceGeneration == ticket, !Task.isCancelled else { return false }
            await refreshMemoryPage(force: true)
            return memoryError == nil
        } catch { return false }
    }

    func refreshHomeInsightIfNeeded(today: Date = Date()) async {
        guard let owner = activeAccountID, accountService?.isPreviewAccount == false else { return }
        let dayKey = ClubDates.key(today)
        guard !homeInsightAttemptedDay.contains(dayKey) else { return }
        let ticket = intelligenceGeneration
        do {
            let data = try await intelligenceData(owner: owner, path: "/insights/home")
            let response = try JSONDecoder().decode(ClubServerInsightResponse.self, from: data)
            guard activeAccountID == owner, intelligenceGeneration == ticket, !Task.isCancelled else { return }
            homeInsight = response.insight
            homeInsightAttemptedDay.insert(dayKey)
        } catch { /* A failed attempt must remain retryable. */ }
    }

    private func intelligenceData(owner: Int, path: String) async throws -> Data {
        if let intelligenceTransport { return try await intelligenceTransport(owner, path) }
        return try await request(path: path)
    }

    private func request(path: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        guard let account = accountService, let userID = activeAccountID else { throw AIClientError.message("请先登录薄肌俱乐部。") }
        if method == "POST" { try await account.syncAIConsentDecision(owner: userID) }
        let response = try await account.cloudRequest(path: "/me/ai" + path, method: method, body: body, expectedUserID: userID)
        if response.statusCode == 401 { throw AccountError.unauthorized }
        guard (200..<300).contains(response.statusCode) else {
            struct ErrorBody: Decodable { let error: String; let code: String?; let retry_after: Int? }
            let details = try? JSONDecoder().decode(ErrorBody.self, from: response.data)
            let message = details?.error ?? "暂时无法完成分析，请稍后重试。"
            let code = details?.code
            if response.statusCode == 429 || (500..<600).contains(response.statusCode) {
                let wait = max(30, min(86400, details?.retry_after ?? 60))
                throw AIClientError.deferred(response.statusCode, code, AIVisibleError.message(code: code, fallback: message) ?? message, Date().addingTimeInterval(Double(wait)))
            }
            throw AIClientError.http(response.statusCode, code, AIVisibleError.message(code: code, fallback: message) ?? "分析暂未完成，请稍后重试。")
        }
        return response.data
    }

    private func scheduleRetry130() {
        retryTimer130?.cancel(); retryTimer130 = nil
        guard foreground130, hasRoutingConsent, let owner = activeAccountID else { return }
        let future = jobs.filter { !$0.isTerminal && $0.replacementID == nil }.compactMap(\.retryAfter).filter { $0 > Date() }
        guard let date = future.min() else { return }
        let ticket = workerGeneration
        retryTimer130 = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(1, date.timeIntervalSinceNow))) } catch { return }
            guard let self, !Task.isCancelled, self.foreground130, self.activeAccountID == owner, self.workerGeneration == ticket else { return }
            self.resume()
        }
    }

    private func persist(notifyCloud: Bool = true) throws {
        guard storageAvailable else { throw AIClientError.message("AI 本地任务存储不可用，请先备份检查原文件。") }
        var folder = storageURL.deletingLastPathComponent(); var values = URLResourceValues(); values.isExcludedFromBackup = true; try folder.setResourceValues(values)
        try jobDisk.save(jobs, to: storageURL)
        if notifyCloud { cloudChangeID &+= 1 }
        scheduleRetry130()
    }
}


extension AIService {
    static func recordRoutingConsent(accountID: Int, allowed: Bool) {
        CloudAnalysisConsent.set(allowed, accountID: accountID)
    }
    func acceptRoutingConsent() {
        guard activeAccountID != nil else { requiresRoutingConsent = false; return }
        if let accountID = activeAccountID { Self.recordRoutingConsent(accountID: accountID, allowed: true) }
        requiresRoutingConsent = false
        resume()
    }
    func revokeRoutingConsent() {
        guard let accountID = activeAccountID else { return }
        Self.recordRoutingConsent(accountID: accountID, allowed: false)
        if let account = accountService { Task { try? await account.syncAIConsentDecision(owner: accountID) } }
        pause()
        declineRoutingConsent()
    }
    func declineRoutingConsent() {
        let previous = jobs
        for index in jobs.indices where !jobs[index].isTerminal && [.number(2), .number(3)].contains(jobs[index].request.payload["_routing_version"] ?? .null) {
            jobs[index].status = "discarded"
            jobs[index].error = "未开启云端分析，原记录与照片仍可手动编辑。"
        }
        do { try persist() } catch { jobs = previous; notice = AppErrorText.message(error); return }
        requiresRoutingConsent = false
    }
}


extension AIService {
    func updateActionDraftHash(id: String, hash: String) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[i].request.payload["action_draft_hash"] = .string(hash)
        do { try persist() } catch { notice = AppErrorText.message(error) }
    }
    func importActionDraft(_ remote: ClubRemoteActionDraft, owner: Int) throws {
        guard activeAccountID == owner, storageAvailable else { throw AIClientError.message("账号已变化或本机存储不可用。") }
        var request = remote.request; request.id = remote.draft_id
        request.payload["action_draft_id"] = .string(remote.draft_id)
        request.payload["action_draft_hash"] = .string(remote.hash)
        var record = AILocalJob(id: remote.draft_id, digest: "action/" + remote.draft_id, request: request)
        record.status = "succeeded"; record.result = remote.result
        let before = jobs; jobs.removeAll { $0.id == record.id }; jobs.insert(record, at: 0)
        do { try persist() } catch { jobs = before; throw error }
    }
}
