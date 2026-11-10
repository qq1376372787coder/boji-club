import Foundation

/// Device preferences never imply a new health-data sharing permission.
/// Phase 4 §5.3（D-11）：主动程度三档。安静=全部主动分析关闭（手动不受影响）；
/// 平衡=每日+周报（默认预算）；积极=四项全开。push budget（proactive_daily_limit）
/// 是服务端全局设置（club_push_settings），不随个人档位变化——档位只映射四个开关。
/// 用户在档位之下仍可细调任一开关；与所有预设分叉时显示"自定义"。
enum ClubProactiveMode: String, CaseIterable {
    case quiet, balanced, active

    var label: String {
        switch self {
        case .quiet: return "安静"
        case .balanced: return "标准"
        case .active: return "积极"
        }
    }
}

struct ClubAutomationSettings: Codable, Equatable {
    var version = 1
    var automaticDaily = false
    var enabledFrom: String? = nil
    var dailyHour = 21
    var includePartial = false
    var automaticWeekly: Bool? = nil
    var automaticWorkout: Bool? = nil
    var serverAutomation: Bool? = nil
    var serverZone: String? = nil
    var enabledAt: Date? = nil
    var weeklyEnabled: Bool { get { automaticWeekly ?? false } set { automaticWeekly = newValue } }
    var workoutEnabled: Bool { get { automaticWorkout ?? false } set { automaticWorkout = newValue } }
    var serverEnabled: Bool { get { serverAutomation ?? false } set { serverAutomation = newValue } }
    var anyAutomatic: Bool { automaticDaily || weeklyEnabled || workoutEnabled }
    var quietEnabled = true
    var quietStart = 22
    var quietEnd = 8
    /// 主动程度档位（D-11）。nil = 旧数据或分叉后的自定义。
    var proactiveMode: String? = nil

    /// 应用档位到四个开关（免打扰/时间等其余设置保持不动）。
    static func applying(_ mode: ClubProactiveMode, to settings: ClubAutomationSettings) -> ClubAutomationSettings {
        var copy = settings
        copy.proactiveMode = mode.rawValue
        copy.automaticDaily = mode != .quiet
        copy.weeklyEnabled = mode != .quiet
        copy.workoutEnabled = mode == .active
        copy.includePartial = mode == .active
        return copy
    }

    /// 当前档位：开关组合与某预设完全一致 → 该档；否则 nil（自定义）。
    var modeLabel: ClubProactiveMode? {
        for mode in ClubProactiveMode.allCases where ClubAutomationSettings.applying(mode, to: self).switchSignature == switchSignature {
            return mode
        }
        return nil
    }
    /// 只取参与档位映射的四个开关的签名（其余字段不影响档位判断）。
    var switchSignature: [Bool] {
        [automaticDaily, weeklyEnabled, workoutEnabled, includePartial]
    }

    var valid: Bool {
        version == 1 && (serverZone == nil || TimeZone(identifier: serverZone!) != nil) && (0...23).contains(dailyHour) && (0...23).contains(quietStart) &&
        (0...23).contains(quietEnd) && quietStart != quietEnd &&
        (enabledFrom == nil || ClubDates.date(fromKey: enabledFrom!) != nil)
    }
    static func key(_ owner: Int) -> String { "club-ai.automation.v1.\(owner)" }
    static func load(owner: Int, defaults: UserDefaults = .standard) throws -> Self {
        guard let data = defaults.data(forKey: key(owner)) else { return Self() }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.valid else { throw ClubAutomationError.invalidPreferences }
        return value
    }
    func save(owner: Int, defaults: UserDefaults = .standard) throws {
        guard owner > 0, valid else { throw ClubAutomationError.invalidPreferences }
        defaults.set(try JSONEncoder().encode(self), forKey: Self.key(owner))
    }
    func nextAllowedNotification(after now: Date, calendar: Calendar = ClubDates.calendar) -> Date {
        guard quietEnabled else { return now }
        let hour = calendar.component(.hour, from: now)
        let quiet = quietStart < quietEnd ? (quietStart..<quietEnd).contains(hour) : hour >= quietStart || hour < quietEnd
        guard quiet else { return now }
        var components = DateComponents(); components.hour = quietEnd; components.minute = 0; components.second = 0
        return calendar.nextDate(after: now, matching: components, matchingPolicy: .nextTime) ?? now.addingTimeInterval(86400)
    }
}

enum ClubAutomationError: LocalizedError {
    case invalidPreferences
    var errorDescription: String? { "自动分析设置无法读取，已暂停自动提交；原设置仍保留。请核对后重新保存。" }
}

enum ClubAnalysisNotifications {
    static func key(kind: String, owner: Int) -> String {
        "notifications." + (["report","club_workout"].contains(kind) ? "daily_report" : "weekly_review") + ".user.\(owner)"
    }
    static func enabled(kind: String, owner: Int, defaults: UserDefaults = .standard) -> Bool {
        (defaults.object(forKey: key(kind: kind, owner: owner)) as? Bool) ?? true
    }
    static func migrateLegacy(owner: Int, defaults: UserDefaults = .standard) {
        guard owner > 0, !defaults.bool(forKey: "notifications.scoped-preferences-migrated") else { return }
        for kind in ["report", "weekly_review"] {
            let key = Self.key(kind: kind, owner: owner)
            let legacy = "notifications." + (kind == "report" ? "daily_report" : "weekly_review")
            if defaults.object(forKey: key) == nil { defaults.set((defaults.object(forKey: legacy) as? Bool) ?? true, forKey: key) }
        }
        defaults.set(true, forKey: "notifications.scoped-preferences-migrated")
    }
}

enum ClubAutomationRules {
    static func recentWorkoutDates(now: Date, calendar: Calendar = ClubDates.calendar) -> [Date] {
        (0...1).compactMap { calendar.date(byAdding: .day, value: -$0, to: now) }
    }
    /// At most yesterday and today, and never before the explicit opt-in date.
    /// This is a foreground catch-up rule, not an iOS background execution promise.
    static func candidates(settings: ClubAutomationSettings, now: Date = Date()) -> [String] {
        guard settings.valid, settings.automaticDaily, let first = settings.enabledFrom else { return [] }
        let calendar = ClubDates.calendar
        let today = calendar.startOfDay(for: now)
        let dates = [calendar.date(byAdding: .day, value: -1, to: today), today].compactMap { $0 }
        return dates.filter {
            guard ClubDates.key($0) >= first else { return false }
            let due = calendar.date(bySettingHour: settings.dailyHour, minute: 0, second: 0, of: $0) ?? .distantFuture
            return due <= now
        }.map(ClubDates.key)
    }
    static func eligible(_ day: DayLog, partialAllowed: Bool) -> Bool {
        guard DailyReportEligibility.hasRecords(day), !day.hasUnconfirmedTraining else { return false }
        if partialAllowed { return true }
        return DailyAnalysisReadiness.warnings(day).isEmpty
    }
    /// Same account and natural date always reserve the same automatic job.
    /// No evidence in the identifier; retries cannot create a second daily job.
    static func jobID(owner: Int, date: String) -> String? {
        guard owner > 0, ClubDates.date(fromKey: date) != nil else { return nil }
        let bytes = UInt64(owner)
        let ownerHex = String(format: "%016llx", bytes)
        let compactDate = date.replacingOccurrences(of: "-", with: "")
        return "a170da11-\(compactDate.prefix(4))-\(compactDate.suffix(4))-\(ownerHex.prefix(4))-\(ownerHex.suffix(12))"
    }
}

struct ClubRestResume: Codable, Equatable {
    let deadline: Date
    let sessionID: UUID?
    /// 休息暂停时保存剩余秒数；nil 表示正在计时或没有休息。
    var pausedRemaining: TimeInterval? = nil
}

struct WorkoutPauseState: Codable, Equatable {
    var pausedAt: Date?
    var accumulated: TimeInterval
    var sessionID: UUID?
    var isPaused: Bool { pausedAt != nil }
    static func from(_ session: WorkoutSession) -> Self? {
        guard let intervals = session.pauseIntervals else { return nil }
        let open = intervals.last.flatMap { $0.end == nil ? $0.start : nil }
        let accumulated = intervals.reduce(0.0) { total, interval in total + max(0, interval.end?.timeIntervalSince(interval.start) ?? 0) }
        return Self(pausedAt: open, accumulated: accumulated, sessionID: session.id)
    }
    func elapsed(startedAt: Date, now: Date = Date()) -> TimeInterval {
        guard startedAt <= now else { return 0 }
        let end = pausedAt ?? now
        return max(0, end.timeIntervalSince(startedAt) - max(0, accumulated))
    }
}

enum ClubWorkoutPauseStorage {
    static func key(owner: Int, date: Date) -> String { "club-workout-pause.v1.\(owner).\(ClubDates.key(date))" }
    static func load(owner: Int, date: Date, sessionID: UUID?, now: Date = Date(),
                     defaults: UserDefaults = .standard) -> WorkoutPauseState? {
        guard owner != 0, let data = defaults.data(forKey: key(owner: owner, date: date)),
              let value = try? JSONDecoder().decode(WorkoutPauseState.self, from: data),
              value.sessionID == sessionID,
              value.accumulated.isFinite, value.accumulated >= 0 else { return nil }
        if let pausedAt = value.pausedAt {
            guard pausedAt <= now, now.timeIntervalSince(pausedAt) <= 12 * 60 * 60 else { return nil }
        }
        return value
    }
    static func save(_ state: WorkoutPauseState?, owner: Int, date: Date, defaults: UserDefaults = .standard) {
        let key = self.key(owner: owner, date: date)
        guard owner != 0, let state, state.accumulated.isFinite, state.accumulated >= 0,
              let data = try? JSONEncoder().encode(state) else {
            defaults.removeObject(forKey: key); return
        }
        defaults.set(data, forKey: key)
    }
    static func erase(owner: Int, defaults: UserDefaults = .standard) {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("club-workout-pause.v1.\(owner).") {
            defaults.removeObject(forKey: key)
        }
    }
}

@MainActor
final class WorkoutPauseService: ObservableObject {
    static let shared = WorkoutPauseService()
    @Published private(set) var state: WorkoutPauseState?
    private var owner: Int?
    private var dateKey: String?
    private init() {}

    func load(owner: Int, date: Date, sessionID: UUID?, now: Date = Date()) {
        self.owner = owner; dateKey = ClubDates.key(date)
        state = ClubWorkoutPauseStorage.load(owner: owner, date: date, sessionID: sessionID, now: now)
    }
    func adopt(_ value: WorkoutPauseState, owner: Int, date: Date) {
        guard value != state || self.owner != owner || dateKey != ClubDates.key(date) else { return }
        self.owner = owner; dateKey = ClubDates.key(date); state = value
        ClubWorkoutPauseStorage.save(value, owner: owner, date: date)
    }
    @discardableResult
    func setPaused(_ paused: Bool, owner: Int, date: Date, sessionID: UUID?,
                   startedAt: Date?, now: Date = Date()) -> Bool {
        guard owner != 0, startedAt != nil else { return false }
        var value = ClubWorkoutPauseStorage.load(owner: owner, date: date, sessionID: sessionID, now: now)
            ?? WorkoutPauseState(pausedAt: nil, accumulated: 0, sessionID: sessionID)
        if paused {
            guard value.pausedAt == nil else { return true }
            value.pausedAt = now
        } else {
            guard let pausedAt = value.pausedAt else { return true }
            value.accumulated += max(0, now.timeIntervalSince(pausedAt))
            value.pausedAt = nil
        }
        ClubWorkoutPauseStorage.save(value, owner: owner, date: date)
        self.owner = owner; dateKey = ClubDates.key(date); state = value.pausedAt == nil && value.accumulated == 0 ? nil : value
        return true
    }
    func clear(owner: Int, date: Date) {
        ClubWorkoutPauseStorage.save(nil, owner: owner, date: date)
        if self.owner == owner && dateKey == ClubDates.key(date) { state = nil }
    }
}

enum ClubRestStorage {
    static func key(owner: Int, date: Date) -> String { "club-rest.v1.\(owner).\(ClubDates.key(date))" }
    static func save(_ end: Date?, owner: Int, date: Date, sessionID: UUID?, defaults: UserDefaults = .standard) {
        let key = Self.key(owner: owner, date: date)
        guard owner > 0, let end, end > Date(), end.timeIntervalSinceNow <= 3600,
              let data = try? JSONEncoder().encode(ClubRestResume(deadline: end, sessionID: sessionID)) else {
            defaults.removeObject(forKey: key); return
        }
        defaults.set(data, forKey: key)
    }
    static func deadline(owner: Int, date: Date, sessionID: UUID?, unfinished: Bool,
                         now: Date = Date(), defaults: UserDefaults = .standard) -> Date? {
        guard owner > 0, unfinished, let data = defaults.data(forKey: key(owner: owner, date: date)),
              let value = try? JSONDecoder().decode(ClubRestResume.self, from: data),
              value.sessionID == sessionID, value.pausedRemaining == nil,
              value.deadline > now, value.deadline.timeIntervalSince(now) <= 3600 else { return nil }
        return value.deadline
    }
    static func savePaused(_ remaining: TimeInterval?, owner: Int, date: Date, sessionID: UUID?,
                           defaults: UserDefaults = .standard) {
        let key = Self.key(owner: owner, date: date)
        guard owner > 0, let remaining, remaining.isFinite, remaining > 0, remaining <= 3600,
              let data = try? JSONEncoder().encode(ClubRestResume(deadline: Date(), sessionID: sessionID,
                                                                 pausedRemaining: remaining)) else {
            defaults.removeObject(forKey: key); return
        }
        defaults.set(data, forKey: key)
    }
    static func pausedRemaining(owner: Int, date: Date, sessionID: UUID?, unfinished: Bool,
                                now: Date = Date(), defaults: UserDefaults = .standard) -> TimeInterval? {
        guard owner > 0, unfinished, let data = defaults.data(forKey: key(owner: owner, date: date)),
              let value = try? JSONDecoder().decode(ClubRestResume.self, from: data),
              value.sessionID == sessionID, let remaining = value.pausedRemaining,
              remaining.isFinite, remaining > 0, remaining <= 3600 else { return nil }
        return remaining
    }
    static func erase(owner: Int, defaults: UserDefaults = .standard) {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("club-rest.v1.\(owner).") {
            defaults.removeObject(forKey: key)
        }
        defaults.removeObject(forKey: ClubAutomationSettings.key(owner))
        defaults.removeObject(forKey: ClubAnalysisNotifications.key(kind: "report", owner: owner))
        defaults.removeObject(forKey: ClubAnalysisNotifications.key(kind: "weekly_review", owner: owner))
    }
}
