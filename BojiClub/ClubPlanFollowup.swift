import Foundation

enum ClubPlanFollowupStatus: String {
    case waiting, rest, notObserved, inProgress, confirmed, changed, superseded, unknown, retained
    var title: String {
        switch self {
        case .waiting: return "还没到这一天"
        case .rest: return "安排休息与恢复"
        case .notObserved: return "尚未看到确认记录"
        case .inProgress: return "训练尚未确认结束"
        case .confirmed: return "已有可核对的执行记录"
        case .changed: return "开始时目标已不同"
        case .superseded: return "已有后续方案覆盖"
        case .unknown: return "依据不足，暂不归入本方案"
        case .retained: return "保留原训练，本次未调整"
        }
    }
}

struct ClubPlanFollowupDay: Identifiable {
    let date: String
    let status: ClubPlanFollowupStatus
    let detail: String
    let targetSets: Int
    var sessionID: UUID? = nil
    var completedOriginalSets: Int? = nil
    var achievedTargets: Int? = nil
    var changedLoadOrUnitSets: Int? = nil
    var comparisons: [ClubWorkoutComparison] = []
    var id: String { date }
}

struct ClubPlanFollowup {
    let versionID: String
    let days: [ClubPlanFollowupDay]
    let hasCompleteAdoptionSnapshot: Bool
    var confirmedDays: Int { days.filter { $0.status == .confirmed }.count }
    var plannedDays: Int { days.filter { $0.targetSets > 0 && $0.status != .retained }.count }
    var comparableItems: Int { days.flatMap(\.comparisons).count }
}

/// Read-only association of adopted targets and observed start snapshots.
/// Similar numbers never prove the plan caused a physical change.
enum ClubPlanFollowupRules {
    private enum Match { case same, different, unknown }
    private struct Candidate {
        let session: WorkoutSession
        let exercises: [Exercise]
    }
    private static func versions(_ state: SavedState) -> [ClubPlanVersion] {
        var seen = Set<String>()
        return state.days.keys.sorted().flatMap { state.days[$0]?.planVersions ?? [] }
            .filter { $0.version == 1 && seen.insert($0.id).inserted }
    }
    static func frontier(_ plans: [ClubPlanVersion], date: String, through time: Date) -> [ClubPlanVersion] {
        let candidates = plans.filter { $0.recordedAt <= time && $0.scopeDates.contains(date) && !$0.retainedDates.contains(date) }
        let byID = Dictionary(plans.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var parents = Set<String>(); var pending = candidates.flatMap(\.previousIDs)
        while let id = pending.popLast() {
            if parents.insert(id).inserted { pending.append(contentsOf: byID[id]?.previousIDs ?? []) }
        }
        // Concurrent branches stay ambiguous; device clocks do not break the tie.
        return candidates.filter { !parents.contains($0.id) }
    }
    private static func sameIdentity(_ planned: AIPlanExercise, _ actual: Exercise) -> Bool? {
        if planned.custom_id != nil || actual.customExerciseID != nil {
            return planned.custom_id != nil && planned.custom_id == actual.customExerciseID
        }
        if let left = planned.library_id, let right = actual.libraryID { return left == right }
        if let left = planned.library_query, let right = actual.libraryQuery,
           !left.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return left.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) == right.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }
    private static func match(_ baseline: WorkoutExecutionBaseline, exercises: [Exercise], planned: [AIPlanExercise]) -> Match {
        guard baseline.version == 1, !baseline.sets.isEmpty,
              Set(baseline.sets.map(\.id)).count == baseline.sets.count else { return .unknown }
        let groups = Dictionary(grouping: baseline.sets, by: \.exerciseID)
        guard groups.count == planned.count else { return .different }
        var used = Set<UUID>()
        for movement in planned {
            let candidates = exercises.filter { groups[$0.id] != nil && sameIdentity(movement, $0) == true }
            if candidates.isEmpty {
                let available = exercises.filter { groups[$0.id] != nil }
                if available.count == groups.count && available.allSatisfy({ sameIdentity(movement, $0) != nil }) { return .different }
            }
            // Names are not stable identities; repeated variants cannot be paired arbitrarily.
            guard candidates.count == 1, let exercise = candidates.first, used.insert(exercise.id).inserted,
                  let targets = groups[exercise.id] else { return .unknown }
            guard targets.count == movement.sets.count else { return .different }
            if let expectedRest = movement.rest_seconds {
                guard targets.allSatisfy({ $0.targetRestSeconds != nil }) else { return .unknown }
                if targets.contains(where: { $0.targetRestSeconds != expectedRest }) { return .different }
            }
            for (target, original) in zip(targets, movement.sets) {
                guard ["reps", "time"].contains(target.unit) else { return .unknown }
                if target.unit != (original.durationSeconds == nil ? "reps" : "time") { return .different }
                if let seconds = original.durationSeconds {
                    guard target.unit == "time", let duration = target.targetSeconds, duration > 0, seconds > 0 else { return .unknown }
                    if duration != seconds { return .different }
                } else {
                    guard target.unit == "reps", let reps = target.targetReps, reps > 0,
                          let weight = target.targetWeight, weight.isFinite, weight >= 0 else { return .unknown }
                    if reps != original.reps || weight != (original.weight ?? 0) { return .different }
                }
            }
        }
        return .same
    }
    private static func candidates(_ day: DayLog) -> [Candidate] {
        (day.workoutSessions ?? []).map { session in
            Candidate(session: session, exercises: day.exercises.filter { $0.workoutSessionID == session.id })
        }
    }
    private static func counts(_ candidate: Candidate, baseline: WorkoutExecutionBaseline) -> (Int, Int, Int) {
        let sets = candidate.exercises.flatMap { exercise in exercise.sets.map { ($0.id, (exercise.id, $0)) } }
        let byID = Dictionary(sets, uniquingKeysWith: { first, _ in first })
        var completed = 0; var achieved = 0; var changed = 0
        for target in baseline.sets {
            guard let (exerciseID, actual) = byID[target.id], exerciseID == target.exerciseID else { changed += 1; continue }
            let unit = actual.durationSeconds == nil ? "reps" : "time"
            guard unit == target.unit else { changed += 1; continue }
            if actual.validCompletion { completed += 1 }
            if unit == "reps", actual.weight != target.targetWeight { changed += 1; continue }
            guard actual.validCompletion else { continue }
            if unit == "time", let seconds = target.targetSeconds, let actualSeconds = actual.durationSeconds, actualSeconds >= seconds { achieved += 1 }
            if unit == "reps", let reps = target.targetReps, actual.reps >= reps { achieved += 1 }
        }
        return (completed, achieved, changed)
    }
    static func make(version: ClubPlanVersion, state: SavedState, now: Date = Date()) -> ClubPlanFollowup {
        let all = versions(state)
        let today = ClubDates.key(now)
        let rows = version.scopeDates.sorted().map { key -> ClubPlanFollowupDay in
            let change = version.changes?.first { $0.date == key }
            let planned = change?.after ?? []
            let count = planned.reduce(0) { $0 + $1.sets.count }
            func row(_ status: ClubPlanFollowupStatus, _ detail: String) -> ClubPlanFollowupDay {
                ClubPlanFollowupDay(date: key, status: status, detail: detail, targetSets: count)
            }
            guard version.version == 1, version.recordedAt <= now,
                  all.contains(where: { $0.id == version.id && $0 == version }) else {
                return row(.unknown, "当前账号的方案版本或观察时间暂不可确认，不将训练归入这份方案。")
            }
            if version.retainedDates.contains(key) || change?.retained == true { return row(.retained, "采用时已开始的训练继续保留，不计为这次调整的执行结果。") }
            guard change != nil else { return row(.unknown, "这份旧方案没有可核对的实际采用快照，不用建议内容补造执行依据。") }
            if key > today {
                let active = frontier(all, date: key, through: now)
                if active.isEmpty { return row(.unknown, "方案的采用关系无法可靠对应，暂不推断应执行哪份安排。") }
                if active.count > 1 { return row(.unknown, "这一天存在并行确认的方案，不能仅按设备时间认定哪一份生效。请先核对日程。") }
                if active.count == 1, active.first?.id != version.id { return row(.superseded, "未来这一天已有后续方案覆盖，不再等待执行旧安排。") }
                return row(.waiting, "到了当天并确认训练后，再核对实际执行。")
            }
            let day = state.days[key] ?? DayLog()
            let observations = candidates(day).filter { candidate in
                guard let baseline = candidate.session.executionBaseline, let started = candidate.session.startedAt,
                      started >= version.recordedAt, started <= baseline.capturedAt,
                      candidate.session.savedAt.map({ $0 >= baseline.capturedAt && $0 <= now }) ?? true else { return false }
                return baseline.capturedAt >= version.recordedAt && baseline.capturedAt <= now && ClubDates.key(baseline.capturedAt) == key
            }
            var verified: [Candidate] = []; var different = false; var ambiguous = false
            for observation in observations {
                guard let baseline = observation.session.executionBaseline else { continue }
                let active = frontier(all, date: key, through: baseline.capturedAt)
                guard active.count == 1, active.first?.id == version.id else { if active.count > 1 { ambiguous = true }; continue }
                switch match(baseline, exercises: observation.exercises, planned: planned) {
                case .same: verified.append(observation)
                case .different: different = true
                case .unknown: ambiguous = true
                }
            }
            if verified.count > 1 { return row(.unknown, "同一天有多次训练与采用目标相符，不能自动指定哪次属于原安排。请分别查看场次。") }
            if let observation = verified.first, let baseline = observation.session.executionBaseline {
                guard observation.session.savedAt != nil else { return row(.inProgress, "开始时目标与采用安排相符，训练还没有确认结束；不提前评价结果。") }
                guard observation.exercises.contains(where: { $0.sets.contains(where: \.validCompletion) }) else {
                    return row(.unknown, "确认标记与有效完成组无法对应，请先核对当天实际记录。")
                }
                let values = counts(observation, baseline: baseline)
                var result = row(.confirmed, "按开始时目标与实际组编号核对；新增组不补成原目标已完成，改重量或单位另行说明。")
                result.sessionID = observation.session.id; result.completedOriginalSets = values.0
                result.achievedTargets = values.1; result.changedLoadOrUnitSets = values.2
                if let date = ClubDates.date(fromKey: key) {
                    // Compare only with training before this plan's start. Another
                    // session after adoption must not become a fabricated old-plan baseline.
                    var comparisonState = state
                    comparisonState.days = state.days.filter { $0.key < version.start || $0.key == key }
                    var current = day; current.exercises = observation.exercises
                    current.workoutSessions = [observation.session]; current.activeWorkoutSessionID = observation.session.id
                    comparisonState.days[key] = current
                    result.comparisons = (ClubWorkoutSummaryRules.make(state: comparisonState, date: date, sessionID: observation.session.id, now: now)?.comparisons ?? [])
                        .filter { $0.comparable && $0.priorDate < version.start }
                }
                return result
            }
            let activeNow = frontier(all, date: key, through: now)
            if activeNow.isEmpty { return row(.unknown, "方案的采用关系无法可靠对应，保留实际记录，不推断执行归属。") }
            if activeNow.count == 1, activeNow.first?.id != version.id { return row(.superseded, "这一天已有后续确认的方案。未找到可归入旧方案的开始快照，后来的训练不算作旧方案执行。") }
            if activeNow.count > 1 || ambiguous { return row(.unknown, "存在并行方案，或缺少动作标识/原重量次数。无法可靠关联，不按设备时间强行选一份。") }
            if planned.isEmpty {
                return row(.rest, day.completedSets > 0 ? "休息安排日另有训练登记，可在当天记录查看；不会把加练算成原计划完成。" : "没有训练登记不能证明充分休息，也不能据此认定漏练。")
            }
            if different { return row(.changed, "开始时的动作、计量方式、组数或目标参数已与采用快照不同；实际记录保留，不据此认定原参数调整有效。") }
            if day.completedSets > 0 || day.workoutSavedAt != nil || day.workoutSessions?.contains(where: { $0.startedAt != nil || $0.savedAt != nil }) == true {
                return row(.unknown, "已有训练记录，但缺少与本方案对应的开始时目标快照；旧记录和补记不倒填原目标。")
            }
            return row(.notObserved, "目前未看到这一天可确认的执行记录；可能尚未训练或漏记，不能直接判定没练。")
        }
        let complete = version.changes != nil && Set(version.changes?.map(\.date) ?? []) == Set(version.scopeDates) &&
            version.version == 1 && version.recordedAt <= now && all.contains(where: { $0 == version })
        return ClubPlanFollowup(versionID: version.id, days: rows, hasCompleteAdoptionSnapshot: complete)
    }
}
