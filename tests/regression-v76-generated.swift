import Foundation
enum ClubDates {
    static func isFuture(_ date: Date, now: Date = Date()) -> Bool {
        calendar.startOfDay(for: date) > calendar.startOfDay(for: now)
    }
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        return calendar
    }

    private static let formatterCache = ClubDateFormatterCache()
    static func key(_ date: Date) -> String { formatterCache.string(date, format: "yyyy-MM-dd", locale: "en_US_POSIX") }
    static func date(fromKey value: String) -> Date? { formatterCache.date(value) }
    static func label(_ date: Date, format: String = "M月d日") -> String { formatterCache.string(date, format: format, locale: "zh_CN") }

}
final class ClubDateFormatterCache: @unchecked Sendable {
    private let lock = NSLock()
    private var formatters: [String: DateFormatter] = [:]
    func string(_ date: Date, format: String, locale: String, timezone: TimeZone = .current) -> String {
        lock.lock(); defer { lock.unlock() }
        return formatter(format: format, locale: locale, timezone: timezone).string(from: date)
    }
    func date(_ value: String, timezone: TimeZone = .current) -> Date? {
        lock.lock(); defer { lock.unlock() }
        let f = formatter(format: "yyyy-MM-dd", locale: "en_US_POSIX", timezone: timezone)
        guard let date = f.date(from: value), f.string(from: date) == value else { return nil }
        return date
    }
    private func formatter(format: String, locale: String, timezone: TimeZone) -> DateFormatter {
        let key = locale + "/" + format + "/" + timezone.identifier
        if let found = formatters[key] { return found }
        if formatters.count >= 32 { formatters.removeAll() }
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: locale); f.timeZone = timezone
        f.dateFormat = format; f.isLenient = false; formatters[key] = f
        return f
    }
}
struct TrainingSet: Identifiable, Codable, Equatable {
    var id = UUID()
    var weight: Double = 0
    var reps: Int = 10
    var completed = false
    var durationSeconds: Int? = nil
    var validCompletion: Bool { completed && (durationSeconds.map { $0 > 0 } ?? (reps > 0)) }
    var volume: Double { validCompletion && durationSeconds == nil ? weight * Double(reps) : 0 }
}
struct Exercise: Identifiable, Codable {
    var id = UUID()
    var name: String
    var muscle: String
    var displayName: String { customExerciseID != nil ? name : ExerciseNames.display(name, id: libraryID, query: libraryQuery) }
    var sets: [TrainingSet] = (0..<3).map { _ in TrainingSet() }
    var libraryID: String?
    var equipment: String?
    var imageURL: String?
    var gifURL: String?
    var libraryQuery: String?
    var deletedSetIDs: [String]?
    var workoutSessionID: UUID? = nil
    var customExerciseID: UUID? = nil
    var customUnit: String? = nil
    var restSeconds: Int? = nil
    enum CodingKeys: String, CodingKey { case id, name, muscle, sets, libraryID, equipment, imageURL, gifURL, libraryQuery, deletedSetIDs, workoutSessionID, customExerciseID, customUnit, restSeconds }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(name, forKey: .name); try c.encode(muscle, forKey: .muscle); try c.encode(sets, forKey: .sets)
        try c.encodeIfPresent(libraryID, forKey: .libraryID); try c.encodeIfPresent(equipment, forKey: .equipment)
        try c.encodeIfPresent(imageURL, forKey: .imageURL); try c.encodeIfPresent(gifURL, forKey: .gifURL); try c.encodeIfPresent(libraryQuery, forKey: .libraryQuery)
        try c.encodeIfPresent(deletedSetIDs, forKey: .deletedSetIDs); try c.encodeIfPresent(workoutSessionID, forKey: .workoutSessionID)
        try c.encodeIfPresent(customExerciseID, forKey: .customExerciseID); try c.encodeIfPresent(customUnit, forKey: .customUnit)
        // Explicit null resets an override; old clients omit this key entirely.
        try c.encode(restSeconds, forKey: .restSeconds)
    }
}
enum RecordLimits { static let maximumWeight = 2000.0
    static let maximumReps = 1000
    static let maximumSeconds = 6 * 3600
    static let maximumNutrition = 100000.0
    static func valid(_ set: TrainingSet) -> Bool {
        set.weight.isFinite && (0...maximumWeight).contains(set.weight) && (0...maximumReps).contains(set.reps)
            && (set.durationSeconds.map { (0...maximumSeconds).contains($0) } ?? true)
    } }
struct AIPlanSet: Codable, Equatable { var weight: Double?; var reps: Int; var durationSeconds: Int? = nil
    var repetitionLabel: String { durationSeconds.map { "\($0) 秒" } ?? "\(reps) 次" }
}
struct AIPlanExercise: Codable, Equatable { var name: String; var muscle: String; var sets: [AIPlanSet]; var library_query: String?; var library_id: String? = nil; var custom_id: UUID? = nil; var custom_unit: String? = nil; var rest_seconds: Int? = nil }
struct AIPlanSession: Codable, Equatable { var date: String; var label: String; var exercises: [AIPlanExercise] }

enum ExerciseNames { static func display(_ value:String,id:String?,query:String?)->String { value } }
struct Explanation:Codable { var version=1 }
struct AIResult { var kind:String;var sessions:[AIPlanSession]?;var explanation:Explanation?;var plan_days:Int? }
struct WorkoutSession:Codable { var id=UUID();var startedAt:Date?;var savedAt:Date? }
struct HealthDay:Codable { var hasData=false }
struct BodyWeightEntry:Codable { var kilograms:Double? }
struct WeeklyStub:Codable { var result:String? }
struct MemberProfile:Codable { var trainingDays:[Int]?=[1,3,5] }
struct DayLog:Codable {
    var exercises:[Exercise]=[];var meals:[String]=[];var health:HealthDay?;var bodyWeight:BodyWeightEntry?
    var workoutStartedAt:Date?;var workoutSavedAt:Date?;var workoutSessions:[WorkoutSession]?;var activeWorkoutSessionID:UUID?
    var planCycle:TrainingCycle?;var plannedMoveDestination:String?;var movedFromDate:String?;var weeklyReview:WeeklyStub?
    var completedSets:Int { exercises.flatMap(\.sets).filter(\.validCompletion).count }
}
struct SavedState:Codable { var days:[String:DayLog]=[:];var profile=MemberProfile();var deletedExerciseIDs:[String]?;var appliedAIJobs:[String]? }
enum CloudMerge {
    static func same<T:Encodable>(_ a:T,_ b:T)throws->Bool { let e=JSONEncoder();e.outputFormatting=[.sortedKeys];return try e.encode(a)==e.encode(b) }
}
final class StoreFixture {
    var state=SavedState();var message:String?;var writesAllowed=true;var changedDates:[String]=[]
    func stableID(_ value:String)->UUID { UUID() }
    func hasAppliedAIJob(_ value:String)->Bool { state.appliedAIJobs?.contains(value)==true }
    func persist(changedDates:[String])->Bool { self.changedDates=changedDates;return writesAllowed }
    func recordPlanHistory(operationID:String,result:AIResult,start:Date,previous:SavedState,scope:[String],source:String?=nil,requestedJobID:String?=nil) {}
    func log(for date:Date)->DayLog { state.days[ClubDates.key(date)] ?? DayLog() }

func applyAIPlan(_ result: AIResult, jobID: String, replaceUnstarted: Bool = false, cycleStart: Date? = nil, minimumCycleStart: Date? = nil, expectedDays: [String: DayLog]? = nil) -> Bool {
        if hasAppliedAIJob(jobID) { return true }
        guard result.kind == "plan", let sessions = result.sessions, !sessions.isEmpty,
              sessions.allSatisfy({ ClubDates.date(fromKey: $0.date) != nil }) else {
            message = "计划日期不完整，请重新生成。"
            return false
        }
        if let minimumCycleStart {
            guard let cycleStart, ClubDates.key(cycleStart) >= ClubDates.key(minimumCycleStart) else {
                message = "下一周必须从原安排结束后的日期开始，请重新选择。"
                return false
            }
        }
        var window: Set<String> = []
        if let start = cycleStart {
            guard ClubDates.key(start) >= ClubDates.key(Date()) else { message = "计划开始日期已过去，请重新预览。"; return false }
            let duration = result.plan_days ?? 7
            guard [7,14,28].contains(duration) else { message = "计划长度不正确，请重新预览。"; return false }
            window = Set((0..<duration).compactMap { ClubDates.calendar.date(byAdding: .day, value: $0, to: start) }.map(ClubDates.key))
            guard Set(sessions.map(\.date)).count == sessions.count,
                  sessions.allSatisfy({ window.contains($0.date) && $0.date >= ClubDates.key(Date()) && !PlanAdoptionRules.isProtected(state.days[$0.date] ?? DayLog()) }) else {
                message = "计划日期已过去、重复或已有开始的训练，请重新预览。"; return false
            }
        }
        let affectedDates = replaceUnstarted && cycleStart != nil ? window : Set(sessions.map(\.date))
        if let expectedDays {
            guard affectedDates.allSatisfy({ key in
                guard let expected = expectedDays[key] else { return false }
                return PlanAdoptionRules.sameTraining(state.days[key] ?? DayLog(), expected)
            }) else { message = "安排在预览后发生了变化，请重新核对再保存。"; return false }
        }
        guard sessions.allSatisfy({ session in
            !session.exercises.isEmpty && session.exercises.count <= 30 && session.exercises.allSatisfy { exercise in
                !exercise.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (exercise.rest_seconds.map { (0...3600).contains($0) } ?? true) && (1...50).contains(exercise.sets.count)
                    && exercise.sets.allSatisfy { set in
                        (set.weight ?? 0).isFinite && (0...RecordLimits.maximumWeight).contains(set.weight ?? 0)
                            && (set.durationSeconds.map { (1...RecordLimits.maximumSeconds).contains($0) } ?? (1...RecordLimits.maximumReps).contains(set.reps))
                    }
            }
        }) else { message = "动作或组次数据不完整，请重新核对计划。"; return false }
        let previous = state
        // Rest days belong to the replacement scope too. Leave started records intact.
        let restDates = affectedDates.subtracting(sessions.map(\.date))
        for key in restDates where !PlanAdoptionRules.isProtected(state.days[key] ?? DayLog()) {
            var day = state.days[key] ?? DayLog()
            state.deletedExerciseIDs = Array(Set((state.deletedExerciseIDs ?? []) + day.exercises.map { $0.id.uuidString })).sorted()
            day.exercises = []; day.plannedMoveDestination = nil; day.movedFromDate = nil
            day.workoutSavedAt = nil
            state.days[key] = day
        }
        for session in sessions {
            var log = state.days[session.date] ?? DayLog()
            log.plannedMoveDestination = nil
            if replaceUnstarted && PlanAdoptionRules.isProtected(log) { state = previous; message = "这一天已经开始训练，请保留记录后另选日期。"; return false }
            if replaceUnstarted {
                log.movedFromDate = nil
                let removable = log.exercises.filter { !$0.sets.contains(where: { $0.completed }) }
                state.deletedExerciseIDs = Array(Set((state.deletedExerciseIDs ?? []) + removable.map { $0.id.uuidString })).sorted()
                log.exercises.removeAll { !$0.sets.contains(where: { $0.completed }) }
            }
            guard log.exercises.count + session.exercises.count <= 30 else { state = previous; message = "该日期的动作将超过 30 个，请先精简已有计划。"; return false }
            log.workoutSavedAt = nil
            log.exercises.append(contentsOf: session.exercises.enumerated().map { index, exercise in
                let key = "\(jobID)/\(session.date)/\(index)"
                return Exercise(id: stableID(key), name: exercise.name, muscle: exercise.muscle, sets: exercise.sets.enumerated().map { setIndex, set in
                    TrainingSet(id: stableID("\(key)/\(setIndex)"), weight: set.weight ?? 0, reps: set.reps, durationSeconds: set.durationSeconds)
                }, libraryID: exercise.library_id, libraryQuery: exercise.library_query, customExerciseID: exercise.custom_id, customUnit: exercise.custom_unit, restSeconds: exercise.rest_seconds)
            })
            state.days[session.date] = log
        }
        state.appliedAIJobs = (state.appliedAIJobs ?? []) + [jobID]
        var cycleDates: [String] = []
        if let start = cycleStart {
            let weeks = (result.plan_days ?? 7) / 7
            for week in 0..<weeks {
                guard let anchor = ClubDates.calendar.date(byAdding: .day, value: week * 7, to: start) else { state = previous; message = "计划日期无法读取。"; return false }
                cycleDates += TrainingCycle.stamp(days: &state.days, start: anchor, plannedDates: sessions.map(\.date) + Array(restDates.filter { !(state.days[$0]?.exercises.isEmpty ?? true) }), sourceJobID: result.explanation?.version == 1 ? jobID : nil)
            }
        }
        if let start = cycleStart {
            recordPlanHistory(operationID: jobID, result: result, start: start, previous: previous, scope: Array(affectedDates))
        }
        if persist(changedDates: Array(affectedDates.union(cycleDates))) { return true }
        state = previous
        return false
    }
func continuationSessions(starting start: Date, ending end: Date, nextStart: Date) -> [AIPlanSession] {
        let today = ClubDates.calendar.startOfDay(for: Date())
        let sourceDates = PlanContinuationRules.sourceDates(start: start, end: end)
        return sourceDates.enumerated().compactMap { offset, from in
            guard let to = ClubDates.calendar.date(byAdding: .day, value: offset, to: nextStart), to >= today else { return nil }
            let exercises = log(for: from).exercises
            guard !exercises.isEmpty else { return nil }
            return AIPlanSession(date: ClubDates.key(to), label: "延续 \(ClubDates.label(from)) 的安排", exercises: exercises.map {
                AIPlanExercise(name: $0.name, muscle: $0.muscle, sets: $0.sets.map { AIPlanSet(weight: $0.weight, reps: $0.reps, durationSeconds: $0.durationSeconds) }, library_query: $0.libraryQuery, library_id: $0.libraryID, custom_id: $0.customExerciseID, custom_unit: $0.customUnit, rest_seconds: $0.restSeconds)
            })
        }
    }
}
enum WorkoutEditing { static func isProtected(_ day: DayLog) -> Bool {
        day.workoutSavedAt != nil || day.workoutStartedAt != nil || day.exercises.contains { $0.sets.contains(where: \.completed) }
    } }
struct TrainingCycle: Codable, Equatable, Identifiable {
    var start: String
    var plannedDates: [String]
    var sourceJobID: String? = nil
    var explanationVersion: Int? = nil
    // A new plan may split a previous cycle. Keep its actual remaining interval.
    var endDate: String? = nil
    var id: String { start }
    var dates: [String] {
        guard let date = ClubDates.date(fromKey: start) else { return [] }
        let full = (0..<7).compactMap { ClubDates.calendar.date(byAdding: .day, value: $0, to: date) }.map(ClubDates.key)
        guard let endDate else { return full }
        return full.filter { $0 <= endDate }
    }
    var end: String { dates.last ?? start }
    var label: String { start + " — " + end }
    func ended(now: Date = Date()) -> Bool { end < ClubDates.key(now) }
    static func available(days: [String: DayLog], now: Date = Date()) -> [TrainingCycle] {
        var byStart: [String: TrainingCycle] = [:]
        for cycle in ownedIntervals(days: days) { byStart[cycle.start] = cycle }
        // Legacy plans have no cycle marker. Anchor to their first actual schedule,
        // keep seven-day boundaries stable, and include the latest completed period.
        if byStart.isEmpty {
            let first = days.keys.filter { !(days[$0]?.exercises.isEmpty ?? true) }.sorted().first
            let today = ClubDates.calendar.startOfDay(for: now)
            let start = first.flatMap(ClubDates.date(fromKey:)) ?? today
            let elapsed = max(0, ClubDates.calendar.dateComponents([.day], from: start, to: today).day ?? 0)
            let last = elapsed / 7
            for index in max(0, last - 12)...last {
                guard let anchor = ClubDates.calendar.date(byAdding: .day, value: index * 7, to: start) else { continue }
                var cycle = TrainingCycle(start: ClubDates.key(anchor), plannedDates: [])
                cycle.plannedDates = cycle.dates.filter { !(days[$0]?.exercises.isEmpty ?? true) }
                byStart[cycle.start] = cycle
            }
        }
        // Old/manual/imported schedules can coexist with newly stamped AI cycles.
        var covered = Set(byStart.values.flatMap(\.dates))
        for key in days.keys.sorted() where !covered.contains(key) && !(days[key]?.exercises.isEmpty ?? true) {
            var cycle = TrainingCycle(start: key, plannedDates: [])
            cycle.plannedDates = cycle.dates.filter { !(days[$0]?.exercises.isEmpty ?? true) }
            guard !cycle.dates.contains(where: { covered.contains($0) }) else { continue }
            byStart[key] = cycle; covered.formUnion(cycle.dates)
        }
        return byStart.values.sorted { $0.start > $1.start }
    }
    static func preferred(days: [String: DayLog], now: Date = Date()) -> TrainingCycle {
        let all = available(days: days, now: now)
        return all.first(where: { $0.ended(now: now) && days[$0.end]?.weeklyReview?.result == nil })
            ?? all.first(where: { $0.dates.contains(ClubDates.key(now)) })
            ?? all.first ?? TrainingCycle(start: ClubDates.key(now), plannedDates: [])
    }
    // Actual per-day ownership is authoritative, including old overlapping markers.
    // Split at ownership changes/gaps; never combine provenance from different jobs.
    static func ownedIntervals(days: [String: DayLog]) -> [TrainingCycle] {
        let keys = days.keys.sorted().filter { key in days[key]?.planCycle?.dates.contains(key) == true }
        var result: [TrainingCycle] = []
        var group: [String] = []
        func appendGroup() {
            guard let first = group.first, let last = group.last, var source = days[first]?.planCycle else { return }
            source.start = first; source.endDate = last
            source.plannedDates = source.plannedDates.filter { group.contains($0) }
            result.append(source)
        }
        for key in keys {
            if let previous = group.last {
                let previousCycle = days[previous]?.planCycle
                let currentCycle = days[key]?.planCycle
                let next = ClubDates.date(fromKey: previous).flatMap { ClubDates.calendar.date(byAdding: .day, value: 1, to: $0) }.map(ClubDates.key)
                if next != key || previousCycle?.start != currentCycle?.start || previousCycle?.sourceJobID != currentCycle?.sourceJobID {
                    appendGroup(); group = []
                }
            }
            group.append(key)
        }
        appendGroup()
        return result
    }
    // Called inside the same persistence transaction as plan changes.
    static func stamp(days: inout [String: DayLog], start: Date, plannedDates: [String], sourceJobID: String? = nil) -> [String] {
        var cycle = TrainingCycle(start: ClubDates.key(start), plannedDates: plannedDates.sorted())
        cycle.endDate = cycle.end
        cycle.sourceJobID = sourceJobID
        cycle.explanationVersion = 1
        cycle.plannedDates = cycle.dates.filter { !(days[$0]?.exercises.isEmpty ?? true) }
        var changed = Set(cycle.dates)
        // Remove only cycle markers inside the new interval, never training data.
        // Normalize the surviving prefixes/suffixes and retain their source jobs.
        for key in cycle.dates { days[key]?.planCycle = nil }
        for survivor in ownedIntervals(days: days) {
            for key in survivor.dates where days[key]?.planCycle != survivor {
                days[key]?.planCycle = survivor; changed.insert(key)
            }
        }
        for key in cycle.dates { days[key, default: DayLog()].planCycle = cycle }
        return changed.sorted()
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
enum CloudSyncStatus: Equatable {
    case idle, pending, syncing, synced(Date), waiting, waitingService, failed(String)

    var label: String {
        switch self {
        case .idle: return "云端同步准备中"
        case .pending: return "记录已保存在本机，等待同步"
        case .syncing: return "正在同步云端记录…"
        case .synced(let date):
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "HH:mm"
            return "已同步 · \(formatter.string(from: date))"
        case .waiting: return "离线记录已保留，联网后自动同步"
        case .waitingService: return "云端繁忙，正在等待自动同步"
        case .failed: return "云端同步暂不可用，记录已保存在本机"
        }
    }
}

struct SyncUser { var id=1 }
struct SyncAccount { var user:SyncUser?=SyncUser() }
@MainActor final class SyncFixture {
    var canSave=true;var accountService:SyncAccount?=SyncAccount()
    var generation=UUID();var activeAccountID:Int?=1;var syncInProgress=false
    var syncWaiters:[UUID:CheckedContinuation<Bool,Never>]=[:]
    var syncStatus:CloudSyncStatus = .idle;var message:String?;var calls=0
    var nextStatus:CloudSyncStatus = .synced(Date())
    func syncNow() async { calls += 1;syncStatus=nextStatus }

func finishSyncWaiters(completed: Bool) {
        let waiting = Array(syncWaiters.values)
        syncWaiters.removeAll()
        for continuation in waiting { continuation.resume(returning: completed) }
    }
func waitForCurrentSync() async -> Bool {
        guard syncInProgress else { return true }
        let id = UUID()
        let deadline = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
            self?.syncWaiters.removeValue(forKey: id)?.resume(returning: false)
        }
        defer { deadline.cancel() }
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled, syncInProgress else { continuation.resume(returning: !Task.isCancelled); return }
                syncWaiters[id] = continuation
            }
        }, onCancel: { [weak self] in
            Task { @MainActor in self?.syncWaiters.removeValue(forKey: id)?.resume(returning: false) }
        })
    }
func syncForPlanAdoption(ownerID: Int) async -> Bool {
        guard canSave else { message = "本机记录尚不能保存，请先完成记录修复，原安排已保留。"; return false }
        guard accountService?.user?.id == ownerID else { message = "登录状态已变化，请重新登录后确认调整。"; return false }
        let ticket = generation
        for _ in 0..<3 {
            guard generation == ticket, activeAccountID == ownerID, accountService?.user?.id == ownerID, !Task.isCancelled else { return false }
            if syncInProgress {
                guard await waitForCurrentSync() else {
                    guard generation == ticket, activeAccountID == ownerID, accountService?.user?.id == ownerID, !Task.isCancelled else { return false }
                    message = "当前同步尚未完成，请稍后再确认调整；原安排已保留。"; return false
                }
            } else { await syncNow() }
            guard generation == ticket, activeAccountID == ownerID, accountService?.user?.id == ownerID, !Task.isCancelled else { return false }
            switch syncStatus {
            case .synced: return true
            case .pending: continue // Edits made during the upload need their own acknowledgment.
            case .failed(let reason): message = "同步未完成：\(reason)。原安排已保留。"
            case .waitingService: message = "服务暂忙，正在等待同步。请稍后确认调整，原安排已保留。"
            case .waiting: message = "同步暂时中断，请检查网络后重试，原安排已保留。"
            default: message = "记录尚未同步完成，请稍后确认调整，原安排已保留。"
            }
            return false
        }
        message = "记录仍在更新，请等同步完成后再确认调整；原安排已保留。"
        return false
    }
}

func sortedJSON<T:Encodable>(_ value:T)throws->Data { let e=JSONEncoder();e.outputFormatting=[.sortedKeys];return try e.encode(value) }
var checks=0
func check(_ value:Bool,_ label:String) { guard value else { fatalError(label) };checks+=1 }
func day(_ key:String)->Date { ClubDates.date(fromKey:key)! }
func movement(_ name:String="旧动作")->Exercise { Exercise(name:name,muscle:"全身",sets:[TrainingSet(reps:10)]) }
let start=ClubDates.calendar.startOfDay(for:ClubDates.calendar.date(byAdding:.day,value:14,to:Date())!)
let keys=(0..<35).map { ClubDates.key(ClubDates.calendar.date(byAdding:.day,value:$0,to:start)!) }
func session(_ key:String)->AIPlanSession { AIPlanSession(date:key,label:"训练",exercises:[AIPlanExercise(name:"新动作",muscle:"全身",sets:[AIPlanSet(weight:10,reps:10)])]) }
func initial(_ duration:Int)->StoreFixture {
    let store=StoreFixture()
    for i in 0..<duration { store.state.days[keys[i]]=DayLog(exercises:[movement()],meals:["晚餐"],health:HealthDay(hasData:true),bodyWeight:BodyWeightEntry(kilograms:68)) }
    return store
}
for duration in [7,14,28] {
    let store=initial(duration);let baseline=store.state.days
    let oldIDs=baseline.values.flatMap { $0.exercises.map { $0.id.uuidString } }
    let training=(0..<duration).filter { $0%7==0 || $0%7==2 || $0%7==4 }.map { session(keys[$0]) }
    let result=AIResult(kind:"plan",sessions:training,plan_days:duration)
    check(store.applyAIPlan(result,jobID:"replace-\(duration)",replaceUnstarted:true,cycleStart:start,expectedDays:baseline),"replace entire \(duration)-day window")
    for i in 0..<duration {
        check(store.state.days[keys[i]]?.exercises.isEmpty == !(i%7==0 || i%7==2 || i%7==4),"rest days have no residual training")
        check(store.state.days[keys[i]]?.meals==["晚餐"] && store.state.days[keys[i]]?.bodyWeight?.kilograms==68 && store.state.days[keys[i]]?.health?.hasData==true,"food, weight, health retained")
    }
    check(Set(oldIDs).isSubset(of:Set(store.state.deletedExerciseIDs ?? [])),"deleted movement tombstones prevent sync resurrection")
    check(Set(keys.prefix(duration)).isSubset(of:Set(store.changedDates)),"all replaced dates persisted")
    let saved=try sortedJSON(store.state)
    check(store.applyAIPlan(result,jobID:"replace-\(duration)",replaceUnstarted:true,cycleStart:start),"same AI job is idempotent")
    check(try sortedJSON(store.state)==saved,"duplicate AI apply does not mutate data")
}
let protected=initial(7)
protected.state.days[keys[1]]?.workoutSessions=[WorkoutSession(startedAt:Date())]
let protectedID=protected.state.days[keys[1]]!.exercises[0].id
check(protected.applyAIPlan(AIResult(kind:"plan",sessions:[session(keys[0])],plan_days:7),jobID:"protected",replaceUnstarted:true,cycleStart:start),"started rest day is preserved")
check(protected.state.days[keys[1]]?.exercises.first?.id==protectedID,"inactive started session survives rest-day cleanup")
check(protected.state.days[keys[1]]?.planCycle?.plannedDates.contains(keys[1])==true,"retained real training remains visible in cycle")
let rollback=initial(7);let before=try sortedJSON(rollback.state);rollback.writesAllowed=false
check(!rollback.applyAIPlan(AIResult(kind:"plan",sessions:[session(keys[0])],plan_days:7),jobID:"rollback",replaceUnstarted:true,cycleStart:start),"disk failure rejects save")
check(try sortedJSON(rollback.state)==before,"disk failure rolls back movements, tombstones, cycle and applied IDs")
let concurrent=initial(7);let snapshot=concurrent.state.days;concurrent.state.days[keys[1]]?.exercises.append(movement("临时加练"))
let concurrentBefore=try sortedJSON(concurrent.state)
check(!concurrent.applyAIPlan(AIResult(kind:"plan",sessions:[session(keys[0])],plan_days:7),jobID:"conflict",replaceUnstarted:true,cycleStart:start,expectedDays:snapshot),"changed rest-day plan rejects stale confirmation")
check(try sortedJSON(concurrent.state)==concurrentBefore,"conflict does not erase concurrent changes")
let append=initial(7)
check(append.applyAIPlan(AIResult(kind:"plan",sessions:[session(keys[0])],plan_days:7),jobID:"append",cycleStart:start),"append remains available")
check(append.state.days[keys[1]]?.exercises.count==1,"append does not clear rest-day existing plan")
let imported=initial(7)
check(imported.applyAIPlan(AIResult(kind:"plan",sessions:[session(keys[0])]),jobID:"import",replaceUnstarted:true),"sparse import succeeds")
check(imported.state.days[keys[1]]?.exercises.count==1,"sparse import does not infer missing rest days")
let source=initial(7)
let clipped=source.continuationSessions(starting:day(keys[5]),ending:day(keys[6]),nextStart:day(keys[14]))
check(clipped.count==2 && clipped.map(\.date)==[keys[14],keys[15]],"two-day cycle copies only its two dates")
let full=source.continuationSessions(starting:start,ending:day(keys[6]),nextStart:day(keys[14]))
check(full.count==7,"normal full-week source remains seven days")
check(source.continuationSessions(starting:start,ending:day(keys[7]),nextStart:day(keys[14])).isEmpty,"invalid overlong source rejected")
source.state.days[keys[1]]?.exercises=[]
check(source.continuationSessions(starting:start,ending:day(keys[6]),nextStart:day(keys[14])).map(\.date)==[keys[14],keys[16],keys[17],keys[18],keys[19],keys[20]],"source rest day retains offset instead of compressing schedule")
let copy=StoreFixture();let copied=AIResult(kind:"plan",sessions:clipped)
let firstID=PlanContinuationRules.operationID(UUID()),secondID=PlanContinuationRules.operationID(UUID())
check(firstID != secondID,"separate copy operations have distinct IDs")
check(copy.applyAIPlan(copied,jobID:firstID,cycleStart:day(keys[14])),"first copy adds actual training")
check(copy.applyAIPlan(copied,jobID:firstID,cycleStart:day(keys[14])) && copy.state.days[keys[14]]?.exercises.count==1,"same operation double tap does not duplicate")
for key in [keys[14],keys[15]] {
    let ids=copy.state.days[key]!.exercises.map { $0.id.uuidString }
    copy.state.deletedExerciseIDs=(copy.state.deletedExerciseIDs ?? [])+ids
    copy.state.days[key]?.exercises=[]
}
check(copy.applyAIPlan(copied,jobID:secondID,cycleStart:day(keys[14])),"new explicit operation can copy after deletion")
check(copy.state.days[keys[14]]?.exercises.count==1 && copy.state.days[keys[15]]?.exercises.count==1,"recopy success means real records exist")
let retry=StoreFixture();retry.writesAllowed=false
check(!retry.applyAIPlan(copied,jobID:firstID,cycleStart:day(keys[14])),"failed copy is not adopted")
retry.writesAllowed=true
check(retry.applyAIPlan(copied,jobID:firstID,cycleStart:day(keys[14])),"same operation can retry a disk failure")

let ranges=StoreFixture()
let rangeSessions=[AIPlanSession(date:keys[14],label:"实际次数",exercises:[AIPlanExercise(name:"自重训练",muscle:"全身",sets:[AIPlanSet(weight:0,reps:300)])]),
                   AIPlanSession(date:keys[15],label:"有氧训练",exercises:[AIPlanExercise(name:"骑行",muscle:"有氧",sets:[AIPlanSet(weight:0,reps:0,durationSeconds:7200)])])]
check(ranges.applyAIPlan(AIResult(kind:"plan",sessions:rangeSessions),jobID:"range-copy",cycleStart:day(keys[14])),"continuation accepts actual 300 reps and two-hour timing")
check(ranges.state.days[keys[14]]?.exercises.first?.sets.first?.reps==300 && ranges.state.days[keys[15]]?.exercises.first?.sets.first?.durationSeconds==7200,"copy does not clip real targets")
var tooLong=rangeSessions;tooLong[1].exercises[0].sets[0].durationSeconds=21601
let untouched=try sortedJSON(ranges.state)
let rangeRejected = !ranges.applyAIPlan(AIResult(kind:"plan",sessions:tooLong),jobID:"invalid-range",cycleStart:day(keys[14]))
let afterRejection = try sortedJSON(ranges.state)
check(rangeRejected && afterRejection==untouched,"invalid target cannot partly modify a plan")

let asyncTests=Task { @MainActor in
    let joining=SyncFixture();joining.syncInProgress=true;joining.syncStatus = .syncing
    let waiter=Task { await joining.syncForPlanAdoption(ownerID:1) }
    try? await Task.sleep(nanoseconds:10_000_000)
    check(joining.syncWaiters.count==1,"plan adoption really awaits active sync")
    joining.syncInProgress=false;joining.syncStatus = .synced(Date());joining.finishSyncWaiters(completed:true)
    let joined=await waiter.value
    check(joined && joining.calls==0 && joining.message==nil,"completed current sync succeeds without false offline message or redundant upload")
    let pending=SyncFixture();pending.syncInProgress=true;pending.syncStatus = .syncing
    let next=Task { await pending.syncForPlanAdoption(ownerID:1) }
    try? await Task.sleep(nanoseconds:10_000_000)
    pending.syncInProgress=false;pending.syncStatus = .pending;pending.finishSyncWaiters(completed:true)
    let nextResult=await next.value
    check(nextResult && pending.calls==1,"concurrent edits await an additional acknowledgment")
    let failed=SyncFixture();failed.nextStatus = .failed("写入失败")
    let failure=await failed.syncForPlanAdoption(ownerID:1)
    check(!failure && failed.message?.contains("写入失败")==true,"real failure exposes specific reason")
    let changed=SyncFixture();changed.syncInProgress=true
    let old=Task { await changed.syncForPlanAdoption(ownerID:1) }
    try? await Task.sleep(nanoseconds:10_000_000)
    changed.generation=UUID();changed.activeAccountID=2;changed.syncInProgress=false;changed.finishSyncWaiters(completed:false)
    let oldResult=await old.value
    check(!oldResult && changed.message==nil && changed.syncWaiters.isEmpty,"account switch releases old waiter without modifying new account message")
    let canceled=SyncFixture();canceled.syncInProgress=true
    let cancelTask=Task { await canceled.syncForPlanAdoption(ownerID:1) }
    try? await Task.sleep(nanoseconds:10_000_000);cancelTask.cancel()
    let canceledResult=await cancelTask.value
    check(!canceledResult && canceled.syncWaiters.isEmpty && canceled.message==nil,"cancellation releases continuation and does not overwrite message")
    let timeout=SyncFixture();timeout.syncInProgress=true
    let expired=await timeout.syncForPlanAdoption(ownerID:1)
    check(!expired && timeout.message?.contains("尚未完成")==true && timeout.syncInProgress && timeout.syncWaiters.isEmpty,"timeout explains waiting without canceling background sync")
    timeout.finishSyncWaiters(completed:true) // No double continuation resume after the watchdog fired.
}
await asyncTests.value
print("v76 production rule checks passed: \(checks)")
