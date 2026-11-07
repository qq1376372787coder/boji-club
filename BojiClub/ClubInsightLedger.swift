import Foundation
import CryptoKit

struct ClubInsightState: RawRepresentable, Codable, Hashable {
    let rawValue: String
    static let active = Self(rawValue: "active")
    static let withdrawn = Self(rawValue: "withdrawn")
    static let expired = Self(rawValue: "expired")
    var supported: Bool { [Self.active, .withdrawn, .expired].contains(self) }
    init(rawValue: String) { self.rawValue = rawValue }
    init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    func encode(to encoder: Encoder) throws { var value = encoder.singleValueContainer(); try value.encode(rawValue) }
}
enum ClubInsightDisplayState: Equatable { case current, updated, withdrawn, expired, unsupported }
struct ClubInsightFeedbackAction: RawRepresentable, Codable, Hashable {
    let rawValue: String
    static let helpful = Self(rawValue: "helpful")
    static let reduce = Self(rawValue: "reduce")
    static let normal = Self(rawValue: "normal")
    static let dismissToday = Self(rawValue: "dismiss_today")
    static let restoreToday = Self(rawValue: "restore_today")
    static let read = Self(rawValue: "read")
    static let unread = Self(rawValue: "unread")
    static let archive = Self(rawValue: "archive")
    static let unarchive = Self(rawValue: "unarchive")
    init(rawValue: String) { self.rawValue = rawValue }
    init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    func encode(to encoder: Encoder) throws { var value = encoder.singleValueContainer(); try value.encode(rawValue) }
}

struct ClubInsightEvent: Identifiable, Codable, Equatable {
    var version = 1
    let id: String
    let date: String
    let groupID: String
    let kind: ClubInsightKind
    let recordedAt: Date
    let previousIDs: [String]
    let state: ClubInsightState
    let evidenceDigest: String
    let title: String
    let detail: String
    let evidence: String
    let priority: Int
    let isTodayReminder: Bool
    var sourceSessionID: UUID? = nil
    var action: ClubInsightAction? = nil
}

struct ClubInsightAction: Codable, Equatable {
    let type: String
    let date: String
    var sessionID: UUID? = nil
}

/// C2：行动状态机。阅读状态（已读/归档）与行动状态分开：
/// 待处理→已完成／执行失败（可重试，不重复应用）；供参考类无行动；
/// 依据变化后旧的行动标记为已过期。状态按 ID 多端并集合并。
struct ClubActionRecord: Codable, Equatable, Identifiable {
    static let statePending = "pending"
    static let stateCompleted = "completed"
    static let stateFailed = "failed"
    static let stateExpired = "expired"
    static let stateReference = "reference"
    static let stateRejected = "rejected"

    let id: String
    var state: String
    var updatedAt: Date
    var note: String? = nil

    var isPending: Bool { state == Self.statePending }
    var isCompleted: Bool { state == Self.stateCompleted }
    var isFailed: Bool { state == Self.stateFailed }
    var isExpired: Bool { state == Self.stateExpired }
    var isRejected: Bool { state == Self.stateRejected }
    var stateLabel: String {
        switch state {
        case Self.statePending: return "待处理"
        case Self.stateCompleted: return "已完成"
        case Self.stateFailed: return "执行失败，可重试"
        case Self.stateExpired: return "已过期"
        case Self.stateRejected: return "已拒绝，不再提示"
        case Self.stateReference: return "供参考"
        default: return "未知状态"
        }
    }
}

struct ClubInsightFeedback: Identifiable, Codable, Equatable {
    var version = 1
    let id: String
    let date: String
    let recordedAt: Date
    let kind: ClubInsightKind
    let action: ClubInsightFeedbackAction
    let eventID: String?
    let scope: String
    let previousIDs: [String]
}

enum ClubInsightLedger {
    static func validGroup(_ event: ClubInsightEvent) -> Bool {
        if event.kind == .workout, let session = event.sourceSessionID {
            return event.groupID == event.date + "/workout/" + session.uuidString.lowercased()
        }
        return event.kind != .workout && event.sourceSessionID == nil && event.groupID == event.date + "/" + event.kind.rawValue
    }
    private struct TrainingSource: Encodable {
        let exercises: [Exercise]
        let confirmed: Bool
        let started: Bool
        let plannedRest: Bool
    }
    private struct NutritionSource: Encodable {
        let meals: [Meal]
        let complete: Bool
        let target: NutritionTarget
        let canEvaluate: Bool
    }
    private struct BodySource: Encodable { let date: String; let kilograms: Double }
    private struct Identity: Encodable {
        let group: String
        let value: String
        let previous: [String]
    }

    static func digest<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return "invalid" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func events(in state: SavedState) -> [ClubInsightEvent] {
        var seen = Set<String>()
        return state.days.keys.sorted().flatMap { state.days[$0]?.insightEvents ?? [] }
            .filter { seen.insert($0.id).inserted }
    }

    static func feedback(in state: SavedState) -> [ClubInsightFeedback] {
        var seen = Set<String>()
        return state.days.keys.sorted().flatMap { state.days[$0]?.insightFeedback ?? [] }
            .filter { seen.insert($0.id).inserted }
    }

    static func leaves(_ events: [ClubInsightEvent]) -> [ClubInsightEvent] {
        let superseded = Set(events.flatMap(\.previousIDs))
        return events.filter { !superseded.contains($0.id) }.sorted {
            $0.recordedAt == $1.recordedAt ? $0.id > $1.id : $0.recordedAt > $1.recordedAt
        }
    }

    private static func preference(scope: String, records: [ClubInsightFeedback]) -> ClubInsightFeedback? {
        let items = records.filter { $0.scope == scope }
        let superseded = Set(items.flatMap(\.previousIDs))
        let terminals = items.filter { !superseded.contains($0.id) }
        // A concurrent reduction wins until the user explicitly restores it.
        return terminals.sorted {
            let left = $0.action == .reduce || $0.action == .dismissToday || $0.action == .archive
            let right = $1.action == .reduce || $1.action == .dismissToday || $1.action == .archive
            if left != right { return left }
            return $0.recordedAt == $1.recordedAt ? $0.id > $1.id : $0.recordedAt > $1.recordedAt
        }.first
    }

    static func reduced(_ kind: ClubInsightKind, in state: SavedState) -> Bool {
        preference(scope: (kind == .workout ? ClubInsightKind.training : kind).rawValue + "/preference", records: feedback(in: state))?.action == .reduce
    }

    static func dismissedToday(_ kind: ClubInsightKind, in state: SavedState, now: Date = Date()) -> Bool {
        preference(scope: (kind == .workout ? ClubInsightKind.training : kind).rawValue + "/today/" + ClubDates.key(now), records: feedback(in: state))?.action == .dismissToday
    }
    static func isRead(_ event: ClubInsightEvent, in state: SavedState) -> Bool {
        preference(scope: event.kind.rawValue + "/reading/" + event.id, records: feedback(in: state))?.action == .read
    }
    static func isArchived(_ event: ClubInsightEvent, in state: SavedState) -> Bool {
        preference(scope: event.kind.rawValue + "/archive/" + event.id, records: feedback(in: state))?.action == .archive
    }
    static func groupArchived(_ group: String, in state: SavedState) -> Bool {
        guard let latest = leaves(events(in: state).filter { $0.groupID == group }).first else { return false }
        return isArchived(latest, in: state)
    }

    static func sourceDigest(kind: ClubInsightKind, date: Date, state: SavedState, now: Date = Date(), sessionID: UUID? = nil) -> String? {
        guard !ClubDates.isFuture(date, now: now) else { return nil }
        let key = ClubDates.key(date)
        let day = state.days[key] ?? DayLog()
        switch kind {
        case .workout:
            guard let sessionID, let report = ClubWorkoutSummaryRules.make(state: state, date: date, sessionID: sessionID, now: now) else { return nil }
            return digest(report)
        case .training:
            let exercises = day.exercises.map { exercise -> Exercise in
                var copy = exercise; copy.imageURL = nil; copy.gifURL = nil
                return copy
            }
            let rest = day.planCycle.map { $0.dates.contains(key) && !$0.plannedDates.contains(key) } ?? false
            return digest(TrainingSource(exercises: exercises, confirmed: day.hasConfirmedTraining,
                started: day.workoutStartedAt != nil, plannedRest: rest))
        case .nutrition:
            let meals = day.meals.sorted { $0.id.uuidString < $1.id.uuidString }.map { meal -> Meal in
                var copy = meal; copy.photoFilename = nil; copy.photoRemoteID = nil
                copy.estimateNotes = nil; copy.estimated = nil; copy.sourceAIJobID = nil
                return copy
            }
            let context = ClubGoalContext(state: state, date: date, now: now)
            return digest(NutritionSource(meals: meals, complete: day.mealsComplete,
                target: context.nutrition, canEvaluate: context.canEvaluateNutrition))
        case .body:
            // An old measurement can remain on the body panel without becoming
            // a new "body updated" event on every subsequent day.
            guard let point = day.bodyWeight, point.isValid, let kilograms = point.kilograms else { return nil }
            return digest(BodySource(date: key, kilograms: kilograms))
        default: return nil
        }
    }

    static func reconcile(state: inout SavedState, dates: [String], now: Date = Date(), includeDependentWorkouts: Bool = true) -> [String] {
        var changed: [String] = []
        var trainingChanged: [String] = []
        for key in Set(dates).sorted() {
            guard let date = ClubDates.date(fromKey: key), !ClubDates.isFuture(date, now: now) else { continue }
            let facts = ClubInsightRules.facts(state: state, date: date, now: now).filter {
                $0.kind != .body || state.days[key]?.bodyWeight?.hasMeasurement == true
            }
            var day = state.days[key] ?? DayLog()
            let all = day.insightEvents ?? []
            let groups = Set(all.map(\.groupID)).union(facts.map(\.id))
            var additions: [ClubInsightEvent] = []
            for group in groups.sorted() {
                let terminals = leaves(all.filter { $0.groupID == group })
                let parents = terminals.map(\.id).sorted()
                let previous = terminals.first
                if let previous, previous.version != 1 || !previous.kind.supported || !previous.state.supported || !validGroup(previous) { continue }
                if let fact = facts.first(where: { $0.id == group }),
                   let evidence = fact.sourceDigest ?? sourceDigest(kind: fact.kind, date: date, state: state, now: now, sessionID: fact.sourceSessionID), evidence != "invalid" {
                    if terminals.count == 1, previous?.state == .active, previous?.evidenceDigest == evidence,
                       previous?.title == fact.title, previous?.detail == fact.detail { continue }
                    let content = evidence + "/" + digest([fact.title, fact.detail, fact.evidence])
                    let id = "insight/" + digest(Identity(group: group, value: content, previous: parents))
                    guard !all.contains(where: { $0.id == id }) else { continue }
                    additions.append(ClubInsightEvent(id: id, date: key, groupID: group, kind: fact.kind,
                        recordedAt: now, previousIDs: parents, state: .active, evidenceDigest: evidence,
                        title: fact.title, detail: fact.detail, evidence: fact.evidence, priority: fact.priority,
                        isTodayReminder: fact.kind == .training && day.completedSets == 0 && day.workoutStartedAt == nil && key == ClubDates.key(now),
                        sourceSessionID: fact.sourceSessionID, action: fact.action))
                } else if let previous, previous.state == .active {
                    let expired = previous.isTodayReminder && key < ClubDates.key(now)
                    let status: ClubInsightState = expired ? .expired : .withdrawn
                    let id = "insight/" + digest(Identity(group: group, value: status.rawValue, previous: parents))
                    guard !all.contains(where: { $0.id == id }) else { continue }
                    additions.append(ClubInsightEvent(id: id, date: key, groupID: group, kind: previous.kind,
                        recordedAt: now, previousIDs: parents, state: status, evidenceDigest: previous.evidenceDigest,
                        title: expired ? "当天提醒已结束" : "此前跟进已撤回",
                        detail: expired ? "当日安排提醒已经结束。没有完成记录不等于没有训练。" : "原记录已删除或改变，目前不再沿用此前结论。",
                        evidence: "原跟进保留在历史中；以目前保存的记录为准。", priority: previous.priority,
                        isTodayReminder: previous.isTodayReminder, sourceSessionID: previous.sourceSessionID))
                }
            }
            if !additions.isEmpty {
                let combined = all + additions
                var compacted: [ClubInsightEvent] = []
                for group in Set(combined.map(\.groupID)).sorted() {
                    let groupEvents = combined.filter { $0.groupID == group }
                    if groupEvents.count > 6 {
                        let leafIDs = Set(leaves(groupEvents).map(\.id))
                        let nonLeaf = groupEvents.filter { !leafIDs.contains($0.id) }.suffix(4)
                        let leafItems = groupEvents.filter { leafIDs.contains($0.id) }
                        compacted.append(contentsOf: nonLeaf + leafItems)
                    } else {
                        compacted.append(contentsOf: groupEvents)
                    }
                }
                day.insightEvents = compacted; state.days[key] = day; changed.append(key)
                if additions.contains(where: { $0.kind == .training || $0.kind == .workout }) { trainingChanged.append(key) }
            }
        }
        if includeDependentWorkouts, let first = trainingChanged.min() {
            let dependent = state.days.keys.filter { key in
                key > first && key <= ClubDates.key(now) && !dates.contains(key) &&
                    (state.days[key]?.insightEvents?.contains { $0.kind == .workout } ?? false)
            }
            changed += reconcile(state: &state, dates: dependent, now: now, includeDependentWorkouts: false)
        }
        return Array(Set(changed)).sorted()
    }

    static func current(in state: SavedState, date: Date, now: Date = Date()) -> [ClubInsightEvent] {
        guard !ClubDates.isFuture(date, now: now) else { return [] }
        let key = ClubDates.key(date)
        let all = state.days[key]?.insightEvents ?? []
        let facts = ClubInsightRules.facts(state: state, date: date, now: now)
        return Set(all.map(\.groupID)).compactMap { group -> ClubInsightEvent? in
            guard let fact = facts.first(where: { $0.id == group }),
                  let hash = fact.sourceDigest ?? sourceDigest(kind: fact.kind, date: date, state: state, now: now, sessionID: fact.sourceSessionID),
                  let item = leaves(all.filter { $0.groupID == group }).first(where: {
                      $0.version == 1 && $0.state == .active && $0.evidenceDigest == hash && $0.title == fact.title && $0.detail == fact.detail
                  }), !isArchived(item, in: state), !reduced(item.kind, in: state), !dismissedToday(item.kind, in: state, now: now) else { return nil }
            return item
        }.sorted { $0.priority == $1.priority ? $0.id < $1.id : $0.priority > $1.priority }
    }

    static func displayState(_ event: ClubInsightEvent, in state: SavedState, now: Date = Date()) -> ClubInsightDisplayState {
        guard event.version == 1, event.kind.supported, event.state.supported,
              validGroup(event) else { return .unsupported }
        if event.state == .withdrawn { return .withdrawn }
        if event.state == .expired || (event.isTodayReminder && event.date < ClubDates.key(now)) { return .expired }
        let group = (state.days[event.date]?.insightEvents ?? []).filter { $0.groupID == event.groupID }
        if group.contains(where: { $0.previousIDs.contains(event.id) }) { return .updated }
        guard let date = ClubDates.date(fromKey: event.date), !ClubDates.isFuture(date, now: now),
              let fact = ClubInsightRules.facts(state: state, date: date, now: now).first(where: { $0.id == event.groupID }),
              (fact.sourceDigest ?? sourceDigest(kind: event.kind, date: date, state: state, now: now, sessionID: event.sourceSessionID)) == event.evidenceDigest,
              fact.title == event.title, fact.detail == event.detail else { return .updated }
        return .current
    }

    @discardableResult
    static func recordFeedback(state: inout SavedState, kind: ClubInsightKind, action: ClubInsightFeedbackAction,
                               eventID: String? = nil, now: Date = Date()) -> String? {
        guard kind.supported else { return nil }
        let familyPreference = [ClubInsightFeedbackAction.reduce, .normal, .dismissToday, .restoreToday].contains(action)
        let kind = kind == .workout && familyPreference ? ClubInsightKind.training : kind
        let records = feedback(in: state)
        let key = ClubDates.key(now)
        let scope: String
        switch action {
        case .helpful:
            guard let eventID, events(in: state).contains(where: { $0.id == eventID && $0.kind == kind }) else { return nil }
            scope = kind.rawValue + "/helpful/" + eventID
        case .read, .unread, .archive, .unarchive:
            guard let eventID, events(in: state).contains(where: { $0.id == eventID && $0.kind == kind }) else { return nil }
            let category = action == .read || action == .unread ? "reading" : "archive"
            scope = kind.rawValue + "/" + category + "/" + eventID
        case .reduce, .normal: scope = kind.rawValue + "/preference"
        case .dismissToday, .restoreToday: scope = kind.rawValue + "/today/" + key
        default: return nil
        }
        let related = records.filter { $0.scope == scope }
        let referenced = Set(related.flatMap(\.previousIDs))
        let terminals = related.filter { !referenced.contains($0.id) }
        if terminals.count == 1, terminals.first?.action == action { return nil }
        let parents = terminals.map(\.id).sorted()
        let id = "feedback/" + digest(Identity(group: scope + "/" + key, value: action.rawValue, previous: parents))
        if records.contains(where: { $0.id == id }) { return nil }
        let entry = ClubInsightFeedback(id: id, date: key, recordedAt: now, kind: kind, action: action,
                                       eventID: eventID, scope: scope, previousIDs: parents)
        var day = state.days[key] ?? DayLog()
        day.insightFeedback = (day.insightFeedback ?? []) + [entry]; state.days[key] = day
        return key
    }
}

enum ClubInsightPriorityRules {
    private static let passiveRepeaterTitles: Set<String> = [
        "今天的训练已安排",
        "今天按计划休息",
        "已记录一次实测体重"
    ]
    static func isActionable(_ event: ClubInsightEvent) -> Bool {
        !passiveRepeaterTitles.contains(event.title)
    }
    /// 首页只展示一条：今天最高优先级（过滤被动状态复读）；今天没有时再回看最近 7 天仍有效的跟进。
    static func top(in state: SavedState, date: Date, now: Date = Date()) -> ClubInsightEvent? {
        if let first = ClubInsightLedger.current(in: state, date: date, now: now).first(where: isActionable) { return first }
        for offset in 1...7 {
            guard let day = ClubDates.calendar.date(byAdding: .day, value: -offset, to: date) else { continue }
            if let first = ClubInsightLedger.current(in: state, date: day, now: now).first(where: isActionable) { return first }
        }
        return nil
    }
    static func followUps(in state: SavedState, date: Date, excluding: String?,
                          now: Date = Date(), limit: Int = 2) -> [ClubInsightEvent] {
        var result = ClubInsightLedger.current(in: state, date: date, now: now).filter { $0.id != excluding && isActionable($0) }
        for offset in 1...7 where result.count < limit {
            guard let day = ClubDates.calendar.date(byAdding: .day, value: -offset, to: date) else { continue }
            result += ClubInsightLedger.current(in: state, date: day, now: now).filter { event in
                event.id != excluding && isActionable(event) && !result.contains(where: { $0.id == event.id })
            }
        }
        return Array(result.prefix(max(0, limit)))
    }
}

enum ClubInsightTimelineRules {
    struct Section: Identifiable {
        let id: String
        let title: String
        let events: [ClubInsightEvent]
    }
    static func sections(_ events: [ClubInsightEvent], now: Date = Date()) -> [Section] {
        let today = ClubDates.key(now)
        let sorted = events.sorted { $0.recordedAt == $1.recordedAt ? $0.id > $1.id : $0.recordedAt > $1.recordedAt }
        let todayEvents = sorted.filter { $0.date == today }
        let earlier = sorted.filter { $0.date != today }
        return [
            Section(id: "today", title: "今天", events: todayEvents),
            Section(id: "earlier", title: "更早", events: earlier)
        ].filter { !$0.events.isEmpty }
    }
    static func filter(_ events: [ClubInsightEvent], kind: ClubInsightKind?) -> [ClubInsightEvent] {
        guard let kind else { return events }
        return events.filter { event in
            kind == .training ? [ClubInsightKind.training, .workout].contains(event.kind) : event.kind == kind
        }
    }
}

enum ClubAIStatusRules {
    static func summary(state: SavedState, date: Date, now: Date = Date(), days: Int = 7) -> String {
        let calendar = ClubDates.calendar
        var recorded = 0
        for offset in 0..<days {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: date),
                  let log = state.days[ClubDates.key(day)] else { continue }
            if log.hasConfirmedTraining || !log.meals.isEmpty || log.bodyWeight?.hasMeasurement == true { recorded += 1 }
        }
        return "基于截至 \(ClubDates.label(date, format: "M月d日")) 的记录 · 近 \(days) 天 \(recorded)/\(days) 天有记录"
    }
}
