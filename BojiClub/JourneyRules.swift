import Foundation

enum NewPlanDateRules {
    static func earliestStart(replacingProfileWeek: Bool = false, now: Date = Date()) -> Date {
        let today = ClubDates.calendar.startOfDay(for: now)
        return replacingProfileWeek ? (ClubDates.calendar.date(byAdding: .day, value: 1, to: today) ?? today) : today
    }
    static func isValidStart(_ key: String, replacingProfileWeek: Bool = false, now: Date = Date()) -> Bool {
        guard let date = ClubDates.date(fromKey: key) else { return false }
        return date >= earliestStart(replacingProfileWeek: replacingProfileWeek, now: now)
    }
}

enum WorkoutSessionTransition {
    // nil -> UUID is automatic first start, not a switch to another workout.
    static func shouldResetRest(previous: UUID?, current: UUID?) -> Bool {
        previous != nil || current == nil
    }
}

enum ClubNotificationRouting {
    static func dateKey(kind: String, provided: String?, now: Date = Date()) -> String? {
        guard ["training", "report", "weekly_review", "weekly_center", "club_weekly", "club_workout", "meal", "body", "task", "task_center"].contains(kind) else { return nil }
        // 周中心提醒是周期性的：按下时按当前周打开，绝不沿用排程时的旧日期。
        let key = kind == "weekly_center" ? ClubDates.key(now)
            : (["task", "task_center"].contains(kind) ? (provided ?? ClubDates.key(now)) : provided)
        guard let key, ClubDates.date(fromKey: key) != nil else { return nil }
        return key
    }
}

enum MembershipUpgradePolicy {
    static func permitsPurchase(activeMember: Bool, lifetimeOwned: Bool, lifetimePackage: Bool) -> Bool {
        !lifetimeOwned && (!activeMember || lifetimePackage)
    }
}

enum HistoryVisibility {
    static func hasRecordedActivity(_ log: DayLog) -> Bool {
        log.completedSets > 0 || !log.meals.isEmpty || (log.bodyWeight?.kilograms.map { $0.isFinite && (20...400).contains($0) } ?? false) || log.health?.hasData == true
    }
    static func isEmptyHistoricalDay(_ date: Date, log: DayLog, now: Date = Date()) -> Bool {
        ClubDates.calendar.startOfDay(for: date) < ClubDates.calendar.startOfDay(for: now)
            && log.exercises.isEmpty && log.completedSets == 0
    }
    static func joinedDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        return ISO8601DateFormatter().date(from: value)
    }
}

/// A short first-entry path still asks before changing context or replacing edits.
enum MealRecognitionReviewPolicy {
    static func requiresConfirmation(dateChanged: Bool, categoryChanged: Bool, replacesExisting: Bool) -> Bool {
        dateChanged || categoryChanged || replacesExisting
    }
}

struct RecordedCalorieProgress: Equatable {
    let recorded: Double
    let upperBound: Double
    let knownMeals: Int
    let unknownMeals: Int

    var hasValidTarget: Bool { upperBound.isFinite && upperBound > 0 }
    var hasKnownIntake: Bool { knownMeals > 0 && recorded.isFinite && recorded >= 0 }
    var fraction: Double {
        guard hasValidTarget, hasKnownIntake else { return 0 }
        return min(1, recorded / upperBound)
    }
    var exceedsUpperBound: Bool { hasValidTarget && hasKnownIntake && recorded > upperBound }
    var excess: Double { exceedsUpperBound ? recorded - upperBound : 0 }
    var isIncomplete: Bool { unknownMeals > 0 }
}

enum CloudAnalysisConsent {
    // Health-adjacent AI input requires an explicit per-account decision. A
    // missing decision (new account or upgrade from an older build) means not
    // allowed; the first AI action asks for consent before any job is sent.
    static func key(accountID: Int) -> String { "ai.routing-consent.v3.\(accountID)" }
    static func allowed(accountID: Int?, defaults: UserDefaults = .standard) -> Bool {
        // 已登出 / 无效 owner 永不放行：无账号即无从决策、也无从撤回。
        guard let accountID, accountID > 0 else { return false }
        let value = defaults.object(forKey: key(accountID: accountID)) as? Bool
        // 未决策 = 不放行（与本枚举顶部注释、fail-closed 同意原则一致）。
        // 原 `?? true` 使从未表态的账号默认开启健康数据云端分析——隐私回归，
        // 由 onboarding_v52/repair_v46/plan_insights_v49/ui_v47 四条 harness 暴露。
        return value ?? false
    }
    static func routerVersion(accountID: Int?, defaults: UserDefaults = .standard) -> Int {
        return 3
    }
    static func hasDecision(accountID: Int, defaults: UserDefaults = .standard) -> Bool {
        accountID > 0 && defaults.object(forKey: key(accountID: accountID)) is Bool
    }
    static func set(_ allowed: Bool, accountID: Int, defaults: UserDefaults = .standard) {
        guard accountID > 0 else { return }
        defaults.set(allowed, forKey: key(accountID: accountID))
        defaults.set("2026-10-26.deepseek-minimax-v1", forKey: key(accountID: accountID) + ".notice-version")
        defaults.set(true, forKey: key(accountID: accountID) + ".pending-server")
    }
}

/// Only acknowledged task states advance the display. Time never advances it.
enum AIWaitPhase: Equatable {
    case submitting, queued, processing, retrying, waitingConnection, waitingService, completed, stopped, unknown

    init(status: String?) {
        switch status {
        case "pending", "submitting": self = .submitting
        case "queued": self = .queued
        case "running": self = .processing
        case "retrying": self = .retrying
        case "waiting_connection": self = .waitingConnection
        case "waiting_service": self = .waitingService
        case "succeeded": self = .completed
        case "draft", "failed", "deleted", "expired", "rejected", "discarded": self = .stopped
        default: self = .unknown
        }
    }

    var activeStage: Int? {
        switch self {
        case .submitting: return 0
        case .queued, .retrying: return 1
        case .processing: return 2
        default: return nil
        }
    }
    var completedStages: Int {
        switch self {
        case .queued, .retrying: return 1
        case .processing: return 2
        case .completed: return 4
        default: return 0
        }
    }
    var isActive: Bool {
        switch self {
        case .waitingConnection, .waitingService, .completed, .stopped: return false
        default: return true
        }
    }
    var showsStages: Bool { activeStage != nil || self == .completed }
    var message: String {
        switch self {
        case .submitting: return "正在提交这次输入"
        case .queued: return "任务已接收，正在等待分析"
        case .processing: return "AI 正在处理，完成后会显示结果"
        case .retrying: return "正在等待自动重试，输入已保留"
        case .waitingConnection: return "网络暂时中断，输入已保留，恢复后可重试"
        case .waitingService: return "分析服务暂时繁忙，输入已保留，将稍后继续处理"
        case .completed: return "处理完成"
        case .stopped: return "处理已停止，请查看提示"
        case .unknown: return "正在确认处理进度"
        }
    }
}

enum StartingWeightSource: String, CaseIterable, Codable {
    case today = "今天刚称"
    case earlier = "之前称的"
    case estimate = "大概估计"

    func recordDate(selected: Date, now: Date, calendar: Calendar) -> Date? {
        let today = calendar.startOfDay(for: now)
        switch self {
        case .today, .earlier:
            let date = calendar.startOfDay(for: selected)
            return date <= today ? date : nil
        case .estimate: return nil
        }
    }
}

enum JourneyCopy {
    static func weeklyAction(ended: Bool, trainingReady: Bool, foodReady: Bool, hasReport: Bool) -> String {
        if hasReport { return "查看本周复盘" }
        if trainingReady { return foodReady ? "开始完整复盘" : "开始训练复盘" }
        if !ended { return "查看本周进度" }
        return "查看已有记录"
    }
    static func nutritionTitle(_ strategy: String?) -> String {
        switch strategy {
        case "温和热量缺口": return "你的饮食方向：逐步减脂"
        case "小幅热量盈余": return "你的饮食方向：支持增肌"
        case "需要个别评估": return "你的饮食参考：先记录，再个别评估"
        default: return "你的饮食方向：保持体重，稳定训练"
        }
    }
    static func nutritionPurpose(_ strategy: String?) -> String {
        switch strategy {
        case "温和热量缺口": return "每天比估计的身体消耗少吃一点，同时保持训练和正常饮食。先看持续记录与体重趋势，再考虑调整。"
        case "小幅热量盈余": return "在估计的日常消耗基础上稍多吃一点，为训练与增肌提供支持。增加多少，要结合实际记录和变化观察。"
        case "需要个别评估": return "当前不使用通用成人的减脂或增重目标。先把实际饮食记清楚，具体目标结合专业评估确定。"
        default: return "先让饮食大致满足日常消耗，配合规律训练。这里的数字是起点参考，之后结合体重和训练表现检查是否合适。"
        }
    }
}

enum PlanDisplayCopy {
    private static let unavailable = "这份旧计划的部分提醒尚未整理成中文，请重新生成计划后核对。原训练安排仍保留。"
    static let replacements: [(String, String)] = [
        ("trainingDays", "训练日"), ("daysPerWeek", "每周训练天数"),
        ("sessionMinutes", "每次训练时长"), ("homeTrainingDays", "居家训练日"),
        ("library_query", "动作匹配信息"), ("library_id", "动作编号"),
        ("durationSeconds", "计时秒数"), ("equipmentOther", "其他器械"),
        ("nutritionTarget", "饮食参考"), ("sessions", "训练安排"),
        ("limitations", "需要留意的情况"), ("equipment", "器械"),
        ("profile", "身体资料"), ("sets", "组数"), ("reps", "次数"),
        ("weight", "重量"), ("null", "未提供"), ("nil", "未提供"),
        ("BMI", "身体质量指数"), ("RPE", "主观用力度"),
        ("RIR", "预计还能完成的次数"), ("kcal", "千卡"), ("kg", "公斤"),
        ("cm", "厘米"), ("min", "分钟"), ("AI", "智能")
    ]
    static func text(_ value: String) -> String {
        if value.range(of: "[A-Za-z_][A-Za-z0-9_]*\\s*\\.\\s*[A-Za-z_]|\\(\\s*\\)", options: .regularExpression) != nil { return unavailable }
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        for (source, target) in replacements {
            result = result.replacingOccurrences(of: "(?<![A-Za-z_])" + NSRegularExpression.escapedPattern(for: source) + "(?![A-Za-z_])",
                with: target, options: [.regularExpression, .caseInsensitive])
        }
        if result.range(of: "[A-Za-z_]{2,}|[{}]|```", options: .regularExpression) != nil {
            return unavailable
        }
        return result
    }
    static func notes(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.map(text).filter { !$0.isEmpty && seen.insert($0).inserted }
    }
    static func needsTranslation(_ value: String) -> Bool { text(value) == unavailable }
    static func heading(_ value: String, fallback: String = "当日训练") -> String {
        let result = text(value)
        return result.isEmpty || result.hasPrefix("这份旧计划") ? fallback : result
    }
}

enum JourneyScrollRules {
    static func clamped(_ value: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
        guard minimum.isFinite, maximum.isFinite else { return 0 }
        guard value.isFinite else { return minimum }
        return min(max(minimum, maximum), max(minimum, value))
    }
}

enum JourneyVisibility {
    static func intersects(_ content: CGRect, _ viewport: CGRect) -> Bool {
        let values = [content.minX, content.minY, content.width, content.height,
                      viewport.minX, viewport.minY, viewport.width, viewport.height]
        guard values.allSatisfy({ $0.isFinite }), !content.isEmpty, !viewport.isEmpty,
              !content.isNull, !viewport.isNull else { return false }
        let intersection = content.intersection(viewport)
        return !intersection.isNull && !intersection.isEmpty
    }
}

enum TrainingHandoff {
    static func pending(on selectedDate: Date, days: [String: DayLog], now: Date = Date()) -> TrainingCycle? {
        let today = ClubDates.key(now)
        // Do not put current-cycle prompts on historical or future training pages.
        guard ClubDates.key(selectedDate) == today else { return nil }
        let cycles = TrainingCycle.available(days: days, now: now).filter { !$0.plannedDates.isEmpty && $0.start <= today }
        guard let cycle = cycles.first(where: { $0.dates.contains(today) }) ?? cycles.first(where: { $0.end < today }),
              let end = ClubDates.date(fromKey: cycle.end) else { return nil }
        let untilEnd = ClubDates.calendar.dateComponents([.day], from: ClubDates.calendar.startOfDay(for: now), to: end).day ?? 7
        let allFinished = cycle.plannedDates.allSatisfy { $0 <= today && days[$0]?.hasConfirmedTraining == true }
        guard untilEnd <= 1 || allFinished else { return nil }
        let horizon = ClubDates.key(ClubDates.calendar.date(byAdding: .day, value: 13, to: now) ?? now)
        let hasNext = days.contains { key, day in key > cycle.end && key >= today && key <= horizon && !day.exercises.isEmpty }
        return hasNext ? nil : cycle
    }
    static func detail(_ cycle: TrainingCycle, days: [String: DayLog], now: Date = Date()) -> String {
        if cycle.ended(now: now) { return "这一轮已经结束。可以沿用这套安排，也可以先复盘再调整，预览后由你确认。" }
        if cycle.plannedDates.allSatisfy({ days[$0]?.hasConfirmedTraining == true }) {
            return "这一轮安排的训练都已保存。可以提前准备下一周，休息日仍留给恢复。"
        }
        return "这一轮快结束了。先看下一周怎么安排，当前未完成的训练记录会继续保留。"
    }
}


enum PlanAdoptionRules {
    static func isProtected(_ day: DayLog) -> Bool {
        WorkoutEditing.isProtected(day) || day.workoutSessions?.contains { $0.startedAt != nil || $0.savedAt != nil } == true
    }
    static func sameTraining(_ current: DayLog, _ expected: DayLog) -> Bool {
        (try? CloudMerge.same(current.exercises, expected.exercises)) == true
            && (try? CloudMerge.same(current.workoutSessions, expected.workoutSessions)) == true
            && current.activeWorkoutSessionID == expected.activeWorkoutSessionID
            && current.workoutStartedAt == expected.workoutStartedAt
            && current.workoutSavedAt == expected.workoutSavedAt
            && current.planCycle == expected.planCycle
            && current.plannedMoveDestination == expected.plannedMoveDestination
            && current.movedFromDate == expected.movedFromDate
    }
}

enum PlanContinuationRules {
    static func sourceDates(start: Date, end: Date) -> [Date] {
        let first = ClubDates.calendar.startOfDay(for: start)
        let last = ClubDates.calendar.startOfDay(for: end)
        guard let days = ClubDates.calendar.dateComponents([.day], from: first, to: last).day, (0...6).contains(days) else { return [] }
        return (0...days).compactMap { ClubDates.calendar.date(byAdding: .day, value: $0, to: first) }
    }
    static func operationID(_ id: UUID) -> String { "continue/" + id.uuidString }
}


enum CustomBackupRules {
    static func recover(_ incoming: [CustomExercise], into existing: [CustomExercise], deleted: [String]) -> [CustomExercise] {
        let removed = Set(deleted.map { $0.uppercased() })
        var result = existing
        var ids = Set(existing.map(\.id))
        for value in incoming where value.valid && !removed.contains(value.id.uuidString.uppercased()) {
            if ids.insert(value.id).inserted { result.append(value) }
        }
        return result
    }
}

enum EmptyWorkoutSessionRules {
    static func canRemove(_ id: UUID, from day: DayLog) -> Bool {
        guard let sessions = day.workoutSessions, sessions.count > 1,
              let value = sessions.first(where: { $0.id == id }),
              value.startedAt == nil, value.endedAt == nil, value.savedAt == nil, value.executionBaseline == nil,
              value.linkedDeviceWorkoutID == nil else { return false }
        return !day.exercises.contains { $0.workoutSessionID == id }
    }
}


enum PlanWeightReference {
    static func kilograms(_ value: JSONValue?) -> Double? {
        guard case .object(let fields)? = value, case .string(let date)? = fields["date"],
              ClubDates.date(fromKey: date) != nil, case .number(let kg)? = fields["kilograms"],
              kg.isFinite, (20...400).contains(kg) else { return nil }
        return kg
    }
    static func description(_ value: JSONValue?) -> String? {
        guard let kg = kilograms(value), case .object(let fields)? = value, case .string(let date)? = fields["date"] else { return nil }
        return "制定时采用 \(date) 实测体重 \(kg.formatted(.number.precision(.fractionLength(0...1)))) kg；与资料体重区分保存，不代表之后每天都称过。"
    }
}
