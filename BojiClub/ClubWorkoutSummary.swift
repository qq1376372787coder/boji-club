import Foundation
import CryptoKit

struct ClubWorkoutComparison: Codable, Equatable, Identifiable {
    let exerciseID: UUID
    let name: String
    let priorDate: String
    let priorSessionID: UUID?
    let priorExerciseID: UUID
    let unit: String
    let weight: Double?
    let currentSets: Int
    let priorSets: Int
    let currentValue: Int
    let priorValue: Int
    var id: String { exerciseID.uuidString + "/" + unit + "/" + (weight.map { String($0) } ?? "time") }
    var comparable: Bool { currentSets == priorSets }
}

struct ClubWorkoutSummary: Codable, Equatable {
    let date: String
    let sessionID: UUID
    let completedSets: Int
    let timedSeconds: Int
    let targetSets: Int?
    let originalCompletedSets: Int?
    let changedTargetSets: Int?
    let restSeconds: Int?
    let comparisons: [ClubWorkoutComparison]
    let limitations: [String]
    // Stable source values: no generation clock, photo URLs or device data.
    let exercises: [ClubWorkoutLoggedExercise]
    let baseline: WorkoutExecutionBaseline?
}

struct ClubWorkoutLoggedExercise: Codable, Equatable, Identifiable {
    let id: UUID
    let name: String
    let libraryID: String?
    let customID: UUID?
    let sets: [TrainingSet]
}

enum ClubWorkoutSummaryRules {
    private struct Entry {
        let date: String
        let session: WorkoutSession
        let exercises: [Exercise]
        var order: Date? { session.startedAt ?? session.endedAt }
    }
    private static func entries(_ state: SavedState) -> [Entry] {
        state.days.keys.sorted().flatMap { key -> [Entry] in
            guard let day = state.days[key] else { return [] }
            if let sessions = day.workoutSessions, !sessions.isEmpty {
                return sessions.filter { $0.savedAt != nil }.map { session in
                    Entry(date: key, session: session, exercises: day.exercises.filter { $0.workoutSessionID == session.id })
                }
            }
            guard day.workoutSavedAt != nil, let identity = day.exercises.first?.id else { return [] }
            return [Entry(date: key, session: WorkoutSession(id: identity, startedAt: day.workoutStartedAt,
                endedAt: day.workoutEndedAt, savedAt: day.workoutSavedAt), exercises: day.exercises)]
        }
    }
    static func available(state: SavedState, date: Date, now: Date = Date()) -> [UUID] {
        guard !ClubDates.isFuture(date, now: now) else { return [] }
        return entries(state).filter { $0.date == ClubDates.key(date) && $0.exercises.contains { $0.sets.contains(where: \.validCompletion) } }
            .sorted { ($0.order ?? .distantPast) == ($1.order ?? .distantPast) ? $0.session.id.uuidString < $1.session.id.uuidString : ($0.order ?? .distantPast) < ($1.order ?? .distantPast) }
            .map { $0.session.id }
    }
    private static func identity(_ exercise: Exercise) -> String? { ClubExerciseIdentity.of(exercise) }
    private static func unit(_ exercise: Exercise) -> String? {
        let done = exercise.sets.filter(\.validCompletion)
        guard !done.isEmpty else { return nil }
        let values = Set(done.map { $0.durationSeconds == nil ? "reps" : "time" })
        return values.count == 1 ? values.first : nil
    }
    static func make(state: SavedState, date: Date, sessionID: UUID, now: Date = Date()) -> ClubWorkoutSummary? {
        guard !ClubDates.isFuture(date, now: now) else { return nil }
        let key = ClubDates.key(date)
        let all = entries(state)
        guard let current = all.first(where: { $0.date == key && $0.session.id == sessionID }),
              current.exercises.contains(where: { $0.sets.contains(where: \.validCompletion) }) else { return nil }
        let prior = all.filter { item in
            guard item.session.id != sessionID, item.date <= key else { return false }
            if item.date < key { return true }
            guard let a = item.order, let b = current.order else { return false }
            return a < b
        }.sorted {
            if $0.date != $1.date { return $0.date > $1.date }
            if $0.order != $1.order { return ($0.order ?? .distantPast) > ($1.order ?? .distantPast) }
            return $0.session.id.uuidString < $1.session.id.uuidString
        }
        var comparisons: [ClubWorkoutComparison] = []
        var limitations: [String] = []
        for exercise in current.exercises where exercise.sets.contains(where: \.validCompletion) {
            guard let identity = identity(exercise), let metric = unit(exercise) else {
                limitations.append(exercise.displayName + "缺少稳定动作标识，或混用了次数与时间，暂不作历史对比。")
                continue
            }
            // Duplicate same-variant exercises in one session are ambiguous.
            guard current.exercises.filter({ self.identity($0) == identity }).count == 1 else {
                limitations.append(exercise.displayName + "在同次训练中重复出现，暂不自动配对。")
                continue
            }
            let done = exercise.sets.filter(\.validCompletion)
            let weights: [Double?] = metric == "time" ? [nil] : Array(Set(done.map(\.weight))).sorted().map(Optional.some)
            var matched = false
            for weight in weights {
                let nowSets = done.filter { weight == nil || $0.weight == weight }
                let match = prior.compactMap { entry -> (Entry, Exercise)? in
                    let matches = entry.exercises.filter { self.identity($0) == identity }
                    guard matches.count == 1, let candidate = matches.first, unit(candidate) == metric,
                          candidate.sets.contains(where: { $0.validCompletion && (weight == nil || $0.weight == weight) }) else { return nil }
                    return (entry, candidate)
                }.first
                guard let (entry, old) = match else { continue }
                let oldSets = old.sets.filter { $0.validCompletion && (weight == nil || $0.weight == weight) }
                matched = true
                comparisons.append(ClubWorkoutComparison(exerciseID: exercise.id, name: exercise.displayName,
                    priorDate: entry.date, priorSessionID: entry.session.id, priorExerciseID: old.id, unit: metric, weight: weight,
                    currentSets: nowSets.count, priorSets: oldSets.count,
                    currentValue: nowSets.reduce(0) { $0 + (metric == "time" ? ($1.durationSeconds ?? 0) : $1.reps) },
                    priorValue: oldSets.reduce(0) { $0 + (metric == "time" ? ($1.durationSeconds ?? 0) : $1.reps) }))
            }
            if !matched { limitations.append(exercise.displayName + "尚无同动作、同计量方式的已确认对照；计次动作还需相同登记重量。") }
        }
        let baseline = current.session.executionBaseline.flatMap { $0.version == 1 ? $0 : nil }
        let sets = current.exercises.flatMap(\.sets)
        let byID = Dictionary(sets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let owners = Dictionary(current.exercises.flatMap { ex in ex.sets.map { ($0.id, ex.id) } }, uniquingKeysWith: { first, _ in first })
        let original = baseline?.sets ?? []
        let changed = original.filter { target in
            guard let set = byID[target.id], owners[target.id] == target.exerciseID else { return true }
            return (set.durationSeconds == nil ? "reps" : "time") != target.unit
        }
        let completed = original.filter { target in
            owners[target.id] == target.exerciseID && byID[target.id]?.validCompletion == true &&
                (byID[target.id]?.durationSeconds == nil ? "reps" : "time") == target.unit
        }.count
        if baseline == nil { limitations.insert("没有开始时的目标快照，保留实际完成量，不补造原目标。", at: 0) }
        else if original.contains(where: { $0.unit == "reps" && ($0.targetReps == nil || $0.targetWeight == nil) }) {
            limitations.insert("部分旧目标只保存了单位，未保存原重量或次数，不倒填。", at: 0)
        }
        if !changed.isEmpty { limitations.insert("部分原组已移除、更换动作或变更单位，不能按当前总组数判定原计划全部完成。", at: 0) }
        limitations.append("对比仅反映登记数据；动作幅度、技术质量、余力与器械条件可能不同，不能据此认定力量或肌肉变化。")
        return ClubWorkoutSummary(date: key, sessionID: sessionID, completedSets: sets.filter(\.validCompletion).count,
            timedSeconds: sets.filter(\.validCompletion).reduce(0) { $0 + ($1.durationSeconds ?? 0) },
            targetSets: baseline.map { $0.sets.count }, originalCompletedSets: baseline == nil ? nil : completed,
            changedTargetSets: baseline == nil ? nil : changed.count, restSeconds: baseline?.restSeconds,
            comparisons: comparisons, limitations: limitations,
            exercises: current.exercises.map { ClubWorkoutLoggedExercise(id: $0.id, name: $0.displayName,
                libraryID: $0.libraryID, customID: $0.customExerciseID, sets: $0.sets) }, baseline: baseline)
    }
}

/// A confirmed session, independent of whichever session happens to be active today.
struct ConfirmedWorkoutSnapshot: Equatable, Codable {
    let ownerID: Int
    let dateKey: String
    let sessionID: UUID
    let startedAt: Date?
    let endedAt: Date?
    let completedSets: Int
    let exerciseCount: Int
    let linkedDeviceWorkoutID: String?
    let signature: String
    var pauseIntervals: [WorkoutPauseInterval]? = nil
    var activeDuration: TimeInterval? { guard let start = startedAt, let end = endedAt else { return nil }; return max(0, end.timeIntervalSince(start) - (pauseIntervals ?? []).reduce(0) { $0 + max(0, ($1.end ?? end).timeIntervalSince($1.start)) }) }
    var canExport: Bool { completedSets > 0 && startedAt != nil && endedAt != nil && startedAt! < endedAt! && endedAt! <= Date() }
    static func make(owner: Int, date: Date, sessionID: UUID, day: DayLog) -> Self? {
        guard owner != 0, !ClubDates.isFuture(date) else { return nil }
        let session: WorkoutSession
        let exercises: [Exercise]
        if let sessions = day.workoutSessions, !sessions.isEmpty {
            guard let found = sessions.first(where: { $0.id == sessionID }), found.savedAt != nil, found.cancelledAt == nil else { return nil }
            session = found; exercises = day.exercises.filter { $0.workoutSessionID == sessionID }
        } else {
            guard day.workoutSavedAt != nil, day.exercises.first?.id == sessionID else { return nil }
            session = WorkoutSession(id: sessionID, startedAt: day.workoutStartedAt, endedAt: day.workoutEndedAt,
                savedAt: day.workoutSavedAt, linkedDeviceWorkoutID: day.linkedDeviceWorkoutID)
            exercises = day.exercises
        }
        let count = exercises.flatMap(\.sets).filter(\.validCompletion).count
        guard count > 0 else { return nil }
        guard exercises.flatMap(\.sets).allSatisfy({ $0.weight.isFinite && (0...RecordLimits.maximumWeight).contains($0.weight) }) else { return nil }
        struct FactSet: Encodable { let id: String; let weight: Int; let reps: Int; let seconds: Int?; let completed: Bool; let entered: Bool }
        struct FactExercise: Encodable { let id: String; let library: String?; let custom: String?; let sets: [FactSet] }
        struct Pause: Encodable { let start: Int64; let end: Int64? }
        struct Source: Encodable { let id: String; let start: Int64?; let end: Int64?; let pauses: [Pause]; let exercises: [FactExercise] }
        func stamp(_ date: Date?) -> Int64? { date.map { Int64(($0.timeIntervalSinceReferenceDate * 1000).rounded()) } }
        let facts = exercises.map { e in FactExercise(id: e.id.uuidString.lowercased(), library: e.libraryID,
            custom: e.customExerciseID?.uuidString.lowercased(), sets: e.sets.map { s in
                FactSet(id: s.id.uuidString.lowercased(), weight: Int((s.weight * 1000).rounded()), reps: s.reps,
                    seconds: s.durationSeconds, completed: s.validCompletion, entered: s.hasActualEntry)
            }.sorted { $0.id < $1.id }) }.sorted { $0.id < $1.id }
        let source = Source(id: session.id.uuidString.lowercased(), start: stamp(session.startedAt), end: stamp(session.endedAt),
            pauses: (session.pauseIntervals ?? []).compactMap { interval in
                guard let start = stamp(interval.start) else { return nil }
                return Pause(start: start, end: stamp(interval.end))
            }, exercises: facts)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(source) else { return nil }
        return Self(ownerID: owner, dateKey: ClubDates.key(date), sessionID: sessionID, startedAt: session.startedAt,
            endedAt: session.endedAt, completedSets: count, exerciseCount: exercises.count,
            linkedDeviceWorkoutID: session.linkedDeviceWorkoutID,
            signature: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), pauseIntervals: session.pauseIntervals)
    }
}
