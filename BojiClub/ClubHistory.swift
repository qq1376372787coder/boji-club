import Foundation

// Each row belongs to its actual record date. A profile first observed today
// cannot be used as evidence of what the member wanted last month.
struct ClubAIDayContext: Codable, Equatable {
    let date: String
    let goalVersionID: String?
    let profile: MemberProfile?
    let goalChangedDuringDay: Bool
    let planVersionID: String?
    let planSource: String?
}

struct ClubAIContext: Codable, Equatable {
    var version = 1
    let start: String
    let end: String
    let days: [ClubAIDayContext]

    static func make(state: SavedState, start: Date, end: Date, now: Date = Date()) -> ClubAIContext {
        let first = ClubDates.calendar.startOfDay(for: start)
        let last = min(ClubDates.calendar.startOfDay(for: end), ClubDates.calendar.startOfDay(for: now))
        var goals: [ClubGoalVersion] = []
        var plans: [ClubPlanVersion] = []
        for log in state.days.values {
            for goal in log.goalVersions ?? [] where goal.version == 1 && goal.recordedAt <= now {
                goals.append(goal)
            }
            for plan in log.planVersions ?? [] where plan.version == 1 && plan.recordedAt <= now {
                plans.append(plan)
            }
        }
        goals.sort { (left: ClubGoalVersion, right: ClubGoalVersion) -> Bool in
            if left.recordedAt == right.recordedAt { return left.id.uuidString < right.id.uuidString }
            return left.recordedAt < right.recordedAt
        }
        var rows: [ClubAIDayContext] = []
        if first <= last {
            let span = min(28, (ClubDates.calendar.dateComponents([.day], from: first, to: last).day ?? 0) + 1)
            for offset in 0..<span {
                guard let day = ClubDates.calendar.date(byAdding: .day, value: offset, to: first),
                      let next = ClubDates.calendar.date(byAdding: .day, value: 1, to: day) else { continue }
                let key = ClubDates.key(day)
                let goal = goals.last { $0.recordedAt < next }
                let changes = goals.filter { $0.recordedAt >= day && $0.recordedAt < next }
                let matchingPlans: [ClubPlanVersion] = plans.filter {
                    $0.scopeDates.contains(key) && !$0.retainedDates.contains(key)
                }
                let plan: ClubPlanVersion? = matchingPlans.max { (left: ClubPlanVersion, right: ClubPlanVersion) -> Bool in
                    if left.recordedAt == right.recordedAt { return left.id < right.id }
                    return left.recordedAt < right.recordedAt
                }
                let hasEarlierGoal = goals.contains { $0.recordedAt < day }
                let changedDuringDay = changes.count > 1 || (changes.count == 1 && hasEarlierGoal)
                let knownProfile = goal?.profile.hasConfirmedBasics == true ? goal?.profile.aiProfile : nil
                let row = ClubAIDayContext(date: key, goalVersionID: knownProfile == nil ? nil : goal?.id.uuidString.lowercased(),
                    profile: knownProfile, goalChangedDuringDay: knownProfile == nil ? false : changedDuringDay,
                    planVersionID: plan?.id, planSource: plan?.source)
                rows.append(row)
            }
        }
        return ClubAIContext(start: rows.first?.date ?? ClubDates.key(first), end: rows.last?.date ?? ClubDates.key(last), days: rows)
    }
}

struct ClubGoalVersion: Identifiable, Codable, Equatable {
    var version = 1
    let id: UUID
    let recordedAt: Date
    let profile: MemberProfile
    let nutrition: NutritionTarget
}

struct ClubPlanVersion: Identifiable, Codable, Equatable {
    var version = 1
    let id: String
    let recordedAt: Date
    let source: String
    let title: String
    let start: String
    let duration: Int
    let sessions: [AIPlanSession]
    let requestedProfile: MemberProfile
    let adoptedProfile: MemberProfile
    let nutrition: NutritionTarget
    let previousIDs: [String]
    let scopeDates: [String]
    let retainedDates: [String]
    var changes: [ClubPlanDayChange]? = nil
    // E1：自由计划描述/意图/编排方式随正式版本保留（旧版本没有这些键 → nil）。
    var planDescription: String? = nil
    var planIntent: String? = nil
    var planPattern: String? = nil
    var notes: [String]? = nil
}

struct ClubPlanDayChange: Codable, Equatable, Identifiable {
    let date: String
    let before: [AIPlanExercise]
    let after: [AIPlanExercise]
    let retained: Bool
    var id: String { date }
    var changed: Bool { !ClubPlanChangeRules.sameContents(before, after) }
    var label: String {
        if retained { return "保留已开始的训练" }
        if !changed { return "安排不变" }
        if after.isEmpty { return "改为休息日" }
        if before.isEmpty { return "新增训练安排" }
        return "更新训练安排"
    }
}

struct ClubPlanMovementChange: Identifiable {
    let before: AIPlanExercise?
    let after: AIPlanExercise?
    let oldIndex: Int?
    let newIndex: Int?
    var id: String { "\(oldIndex ?? -1)/\(newIndex ?? -1)" }
    var changed: Bool {
        guard let before, let after else { return true }
        return !ClubPlanChangeRules.sameContents([before], [after]) || oldIndex != newIndex
    }
    var label: String {
        if before == nil { return "新增" }
        if after == nil { return "移除" }
        if before?.sets != after?.sets || before?.rest_seconds != after?.rest_seconds { return "参数更新" }
        if before?.displayName != after?.displayName { return "动作名称更新" }
        return oldIndex == newIndex ? "保持" : "调整顺序"
    }
}

enum ClubPlanChangeRules {
    static func snapshot(_ exercises: [Exercise]) -> [AIPlanExercise] {
        exercises.map { exercise in
            AIPlanExercise(name: exercise.displayName, muscle: exercise.muscle,
                sets: exercise.sets.map { AIPlanSet(weight: $0.weight, reps: $0.reps, durationSeconds: $0.durationSeconds) },
                library_query: exercise.libraryQuery, library_id: exercise.libraryID,
                custom_id: exercise.customExerciseID, custom_unit: exercise.customUnit, rest_seconds: exercise.restSeconds)
        }
    }
    static func stored(_ exercises: [AIPlanExercise]) -> [AIPlanExercise] {
        exercises.map { exercise in
            var copy = exercise
            copy.name = exercise.displayName
            copy.sets = exercise.sets.map { set in var value = set; value.weight = set.weight ?? 0; return value }
            return copy
        }
    }
    static func preview(before: [String: DayLog], sessions: [AIPlanSession], scope: [String], replace: Bool) -> [ClubPlanDayChange] {
        Set(scope).sorted().map { key in
            let day = before[key] ?? DayLog()
            let old = snapshot(day.exercises)
            let retained = PlanAdoptionRules.isProtected(day)
            let proposed = stored(sessions.first { $0.date == key }?.exercises ?? [])
            let next = retained ? old : replace ? proposed : old + proposed
            return ClubPlanDayChange(date: key, before: old, after: next, retained: retained)
        }
    }
    private static func sameMovement(_ left: AIPlanExercise, _ right: AIPlanExercise) -> Bool {
        if left.custom_id != nil || right.custom_id != nil { return left.custom_id != nil && left.custom_id == right.custom_id }
        if let a = left.library_id, let b = right.library_id { return a == b }
        return left.displayName == right.displayName
    }
    static func sameContents(_ left: [AIPlanExercise], _ right: [AIPlanExercise]) -> Bool {
        guard left.count == right.count else { return false }
        return zip(left, right).allSatisfy { a, b in
            sameMovement(a, b) && a.displayName == b.displayName && a.sets == b.sets && a.custom_unit == b.custom_unit && a.rest_seconds == b.rest_seconds
        }
    }
    static func movements(_ change: ClubPlanDayChange) -> [ClubPlanMovementChange] {
        var used = Set<Int>()
        var rows: [ClubPlanMovementChange] = []
        for (index, movement) in change.after.enumerated() {
            let previous = change.before.indices.first { !used.contains($0) && sameMovement(change.before[$0], movement) }
            if let previous { used.insert(previous) }
            rows.append(ClubPlanMovementChange(before: previous.map { change.before[$0] }, after: movement, oldIndex: previous, newIndex: index))
        }
        for index in change.before.indices where !used.contains(index) {
            rows.append(ClubPlanMovementChange(before: change.before[index], after: nil, oldIndex: index, newIndex: nil))
        }
        return rows
    }
    static func setLabel(_ set: AIPlanSet) -> String {
        if let seconds = set.durationSeconds { return "\(seconds) 秒" }
        let weight = set.weight ?? 0
        return "\(set.reps) 次 · " + (weight == 0 ? "自重或未设置重量" : "\(weight.formatted()) kg")
    }
}

enum ClubHistoryRules {
    // Establish a baseline only when it is observed. Never invent a profile for
    // dates before this client first recorded it.
    static func recordGoal(days: inout [String: DayLog], profile: MemberProfile,
                           nutrition: NutritionTarget, now: Date = Date()) -> String? {
        let clean = profile.aiProfile
        var latest: ClubGoalVersion?
        for log in days.values {
            for candidate in log.goalVersions ?? [] where candidate.recordedAt <= now {
                if let current = latest {
                    if candidate.recordedAt < current.recordedAt { continue }
                    if candidate.recordedAt == current.recordedAt && candidate.id.uuidString <= current.id.uuidString { continue }
                }
                latest = candidate
            }
        }
        if let latest, latest.profile == clean, latest.nutrition == nutrition { return nil }
        let key = ClubDates.key(now)
        var day = days[key] ?? DayLog()
        day.goalVersions = (day.goalVersions ?? []) + [ClubGoalVersion(id: UUID(), recordedAt: now, profile: clean, nutrition: nutrition)]
        days[key] = day
        return key
    }

    static func recordPlan(days: inout [String: DayLog], previous: [String: DayLog],
                           operationID: String, result: AIResult, start: Date, source: String,
                           requestedProfile: MemberProfile, adoptedProfile: MemberProfile,
                           nutrition: NutritionTarget, scope: [String], now: Date = Date()) {
        let key = ClubDates.key(start)
        var old: [ClubPlanVersion] = []
        for log in previous.values { old.append(contentsOf: log.planVersions ?? []) }
        guard !old.contains(where: { $0.id == operationID }) else { return }
        let dates = Set(scope)
        let parents = old.filter { !dates.isDisjoint(with: $0.scopeDates) }.map(\.id)
        let retained = scope.filter { PlanAdoptionRules.isProtected(previous[$0] ?? DayLog()) }.sorted()
        let record = ClubPlanVersion(id: operationID, recordedAt: now, source: source,
            title: result.title ?? "训练计划", start: key, duration: result.plan_days ?? 7,
            sessions: result.sessions ?? [], requestedProfile: requestedProfile.aiProfile,
            adoptedProfile: adoptedProfile.aiProfile, nutrition: nutrition,
            previousIDs: Array(Set(parents)).sorted(), scopeDates: Array(dates).sorted(), retainedDates: retained,
            planDescription: result.plan_description, planIntent: result.plan_intent,
            planPattern: result.plan_pattern, notes: result.notes.isEmpty ? nil : result.notes)
        var confirmed = record
        confirmed.changes = dates.sorted().map { date in
            ClubPlanDayChange(date: date, before: ClubPlanChangeRules.snapshot(previous[date]?.exercises ?? []),
                after: ClubPlanChangeRules.snapshot(days[date]?.exercises ?? []), retained: retained.contains(date))
        }
        var day = days[key] ?? DayLog()
        day.planVersions = (day.planVersions ?? []) + [confirmed]
        days[key] = day
    }

    static func profile(on date: Date, days: [String: DayLog]) -> MemberProfile? {
        guard let end = ClubDates.calendar.date(byAdding: .day, value: 1, to: ClubDates.calendar.startOfDay(for: date)) else { return nil }
        var latest: ClubGoalVersion?
        for log in days.values {
            for candidate in log.goalVersions ?? [] where candidate.recordedAt < end {
                if let current = latest {
                    if candidate.recordedAt < current.recordedAt { continue }
                    if candidate.recordedAt == current.recordedAt && candidate.id.uuidString <= current.id.uuidString { continue }
                }
                latest = candidate
            }
        }
        return latest?.profile
    }
}

/// Immutable observations, replicated with each affected day so legacy uploads
/// cannot erase a cancellation. IDs of started workouts are never tombstoned.
struct PlanLifecycleAction: Codable, Equatable, Identifiable {
    var id: String
    var planID: String
    var kind: String // ended / archived
    var createdAt: Date
    var exerciseIDs: [String]
    var clearsCycle: Bool? = nil
}

enum PlanManagementRules {
    static func ownerForAddition(_ day: DayLog) -> String? {
        day.trainingLog.exercises.first?.planID ?? ((day.workoutSessions?.count ?? 0) <= 1 ? day.planCycle?.sourceJobID : nil)
    }
    static func isCancelled(_ id: String, days: [String: DayLog]) -> Bool {
        days.values.contains { ($0.planActions ?? []).contains { $0.planID == id && $0.kind == "ended" } }
    }
    static func restoreConcurrentExecution(_ day: inout DayLog, sources: [DayLog]) {
        let cancelled = Set((day.planActions ?? []).filter { $0.kind == "ended" }.flatMap(\.exerciseIDs).map { $0.lowercased() })
        guard !cancelled.isEmpty else { return }
        for source in sources {
            let started = source.workoutStartedAt != nil || source.workoutSavedAt != nil || source.completedSets > 0 || source.workoutSessions?.contains { $0.startedAt != nil || $0.savedAt != nil } == true
            guard started else { continue }
            let present = Set(day.exercises.map(\.id))
            day.exercises += source.exercises.filter { cancelled.contains($0.id.uuidString.lowercased()) && !present.contains($0.id) }
            if day.workoutStartedAt == nil { day.workoutStartedAt = source.workoutStartedAt }
            if day.workoutSavedAt == nil { day.workoutSavedAt = source.workoutSavedAt }
            if day.workoutEndedAt == nil { day.workoutEndedAt = source.workoutEndedAt }
        }
    }
    static func reconcile(_ day: inout DayLog) {
        let ended = (day.planActions ?? []).filter { $0.kind == "ended" }
        guard !ended.isEmpty else { return }
        // Cancellation loses to concurrent execution facts, protecting a workout
        // another device started before it learned about this cancellation.
        let protected = day.workoutStartedAt != nil || day.workoutSavedAt != nil || day.completedSets > 0 ||
            day.workoutSessions?.contains { $0.startedAt != nil || $0.savedAt != nil } == true
        guard !protected else { return }
        let ids = Set(ended.flatMap(\.exerciseIDs).map { $0.lowercased() })
        day.exercises.removeAll { ids.contains($0.id.uuidString.lowercased()) }
        if day.exercises.isEmpty, let cycle = day.planCycle,
           ended.contains(where: { $0.clearsCycle == true && ($0.planID == cycle.sourceJobID || $0.planID == "legacy-plan-" + cycle.start) }) { day.planCycle = nil }
    }
}
