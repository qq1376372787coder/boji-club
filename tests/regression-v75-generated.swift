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
struct WeeklySurvey: Codable {
    var weight: Double?
    var waist: Double?
    var bodyFat: Double?
    var bodyFatSource = ""
    var fatigue = ""
    var pain = ""
    var difficulty = ""
    var diet = ""
    var notes = ""
    var days = 3
    var trainingDays: [Int]? = nil
}
struct ReviewPhoto: Codable, Identifiable {
    var id = UUID()
    var pose: String
    var filename: String
}
struct WeeklyResult: Codable {
    var kind: String
    var summary: String
    var training: String
    var nutrition: String
    var recovery: String
    var appearance: String
    var photoFeedback: [String]
    var decision: String
    var reason: String
    var notes: [String]
    var sessions: [AIPlanSession]
}
struct WeeklyReview: Codable, Identifiable {
    var id = UUID()
    var date: String
    var survey = WeeklySurvey()
    var photos: [ReviewPhoto] = []
    var compareWith: UUID?
    var jobID: String?
    var status = "draft"
    var result: WeeklyResult?
    var baseline: [String: [Exercise]] = [:]
    var applied = false
    var updatedAt = Date()
    var recoveredWithoutContext: Bool? = nil
    var priorJobIDs: [String]? = nil
    var cycle: TrainingCycle? = nil
    var scope: String? = nil
    var inputFingerprint: String? = nil
}
enum ExerciseNames { static func display(_ value:String,id:String?,query:String?)->String { value } }
enum WorkoutEditing { static func isProtected(_ day: DayLog) -> Bool {
        day.workoutSavedAt != nil || day.workoutStartedAt != nil || day.exercises.contains { $0.sets.contains(where: \.completed) }
    } }

struct BodyWeightEntry:Codable { var kilograms:Double?;var updatedAt=Date() }
struct HealthDay:Codable { var hasData=false }
struct DayLog:Codable {
    var exercises:[Exercise]=[];var meals:[String]=[];var health:HealthDay?
    var weeklyReview:WeeklyReview?;var planCycle:TrainingCycle?
    var workoutStartedAt:Date?;var workoutSavedAt:Date?;var bodyWeight:BodyWeightEntry?
    var plannedMoveDestination:String?;var movedFromDate:String?
    var completedSets:Int { exercises.flatMap(\.sets).filter(\.validCompletion).count }
}
struct MemberProfile:Codable { var trainingDays:[Int]?=[1,3,5] }
struct SavedState:Codable { var days:[String:DayLog]=[:];var profile=MemberProfile();var deletedExerciseIDs:[String]?;var appliedAIJobs:[String]? }
enum WeeklyVersions { static func insert(_ value:WeeklyReview,into day:inout DayLog) { day.weeklyReview=value } }
enum CloudMerge {
    static func same<T:Encodable>(_ a:T,_ b:T)throws->Bool {
        let e=JSONEncoder();e.outputFormatting=[.sortedKeys];return try e.encode(a)==e.encode(b)
    }
}
final class StoreFixture {
    var state=SavedState();var message:String?;var writesAllowed=true;var changedDates:[String]=[]
    func stableID(_ value:String)->UUID { UUID() }
    func hasAppliedAIJob(_ value:String)->Bool { state.appliedAIJobs?.contains(value)==true }
    func persist(changedDates:[String])->Bool { self.changedDates=changedDates;return writesAllowed }
    func recordWeeklyPlanHistory(review:WeeklyReview,sessions:[AIPlanSession],previous:SavedState,start:Date,scope:[String]) {}

func applyWeeklyPlan(_ review: WeeklyReview, sessions: [AIPlanSession], replaceWholeWeek: Bool = true) -> Bool {
        let appliedID = "weekly/" + review.id.uuidString
        if hasAppliedAIJob(appliedID) { return true }
        guard review.result?.decision == "adjust", !sessions.isEmpty, let end = ClubDates.date(fromKey: review.date) else { message = "本次没有可应用的调整。"; return false }
        if let latest = state.days[review.date]?.weeklyReview, latest.id != review.id, latest.updatedAt > review.updatedAt {
            message = "本周期已有更新的复盘，请查看最新建议后再调整。"; return false
        }
        let today = ClubDates.calendar.startOfDay(for: Date())
        let selectedDates = sessions.map(\.date)
        guard Set(selectedDates).count == selectedDates.count else { message = "训练日期重复。"; return false }
        for session in sessions {
            guard let date = ClubDates.date(fromKey: session.date), date >= today,
                  let offset = ClubDates.calendar.dateComponents([.day], from: end, to: date).day, (1...7).contains(offset),
                  (review.survey.trainingDays ?? state.profile.trainingDays ?? [1,3,5]).contains((ClubDates.calendar.component(.weekday, from: date)+5)%7+1),
                  let original = review.baseline[session.date], !session.exercises.isEmpty, session.exercises.count <= 30, session.exercises.allSatisfy({ $0.sets.count <= 50 }),
                  session.exercises.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.sets.isEmpty && $0.sets.allSatisfy { ($0.durationSeconds.map { (1...RecordLimits.maximumSeconds).contains($0) } ?? (1...RecordLimits.maximumReps).contains($0.reps)) && ($0.weight ?? 0).isFinite && ($0.weight ?? 0) >= 0 && ($0.weight ?? 0) <= RecordLimits.maximumWeight } }) else {
                message = "建议日期已到期或训练数据不完整，请重新复盘。"; return false
            }
            let current = state.days[session.date]?.exercises ?? []
            guard !WorkoutEditing.isProtected(state.days[session.date] ?? DayLog()), current.flatMap(\.sets).allSatisfy({ !$0.completed }), (try? CloudMerge.same(current, original)) == true else {
                message = "\(session.date) 的计划已更改或开始训练。为保留你的记录，请重新复盘后再调整。"; return false
            }
        }
        let nextWeek = (1...7).compactMap { ClubDates.calendar.date(byAdding: .day, value: $0, to: end) }.map(ClubDates.key)
        let restDates = replaceWholeWeek ? nextWeek.filter { !selectedDates.contains($0) } : []
        if replaceWholeWeek {
            guard Set(selectedDates) == Set((review.result?.sessions ?? []).map(\.date)) else {
                message = "整周调整需要采用全部建议训练日；只调整部分日期请切换调整方式。"; return false
            }
            for key in restDates {
                guard key >= ClubDates.key(today), let original = review.baseline[key],
                      !WorkoutEditing.isProtected(state.days[key] ?? DayLog()),
                      (try? CloudMerge.same(state.days[key]?.exercises ?? [], original)) == true else {
                    message = "\(key) 已开始训练、已过去或安排有变化，无法整周替换。请保留记录并重新复盘，或只调整选中日期。"; return false
                }
            }
        }
        let previous = state
        for key in restDates {
            var day = state.days[key] ?? DayLog()
            state.deletedExerciseIDs = Array(Set((state.deletedExerciseIDs ?? []) + day.exercises.map { $0.id.uuidString })).sorted()
            day.exercises = []; day.workoutSavedAt = nil; day.plannedMoveDestination = nil; day.movedFromDate = nil
            state.days[key] = day
        }
        for session in sessions {
            let oldIDs = (state.days[session.date]?.exercises ?? []).map { $0.id.uuidString }
            state.deletedExerciseIDs = Array(Set((state.deletedExerciseIDs ?? []) + oldIDs)).sorted()
            var day = state.days[session.date] ?? DayLog()
            day.workoutSavedAt = nil
            day.exercises = session.exercises.enumerated().map { index, exercise in
                let key = appliedID + "/" + session.date + "/" + String(index)
                return Exercise(id: stableID(key), name: exercise.name, muscle: exercise.muscle, sets: exercise.sets.enumerated().map { j, set in TrainingSet(id: stableID(key+"/"+String(j)), weight: set.weight ?? 0, reps: set.reps, durationSeconds: set.durationSeconds) }, libraryID: exercise.library_id, libraryQuery: exercise.library_query, customExerciseID: exercise.custom_id, customUnit: exercise.custom_unit, restSeconds: exercise.rest_seconds)
            }
            state.days[session.date] = day
        }
        state.appliedAIJobs = (state.appliedAIJobs ?? []) + [appliedID]
        var saved = review; saved.applied = true; saved.photos = []; saved.updatedAt = Date()
        var reviewDay = state.days[review.date] ?? DayLog()
        WeeklyVersions.insert(saved, into: &reviewDay)
        state.days[review.date] = reviewDay
        let next = ClubDates.calendar.date(byAdding: .day, value: 1, to: end)!
        let cycleDates = TrainingCycle.stamp(days: &state.days, start: next, plannedDates: sessions.map(\.date))
        recordWeeklyPlanHistory(review: review, sessions: sessions, previous: previous, start: next,
            scope: replaceWholeWeek ? nextWeek : selectedDates)
        if persist(changedDates: cycleDates + [review.date]) { return true }
        state = previous; return false
    }
}
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
enum WorkoutSessionTransition {
    // nil -> UUID is automatic first start, not a switch to another workout.
    static func shouldResetRest(previous: UUID?, current: UUID?) -> Bool {
        previous != nil || current == nil
    }
}
enum ClubNotificationRouting {
    static func dateKey(kind: String, provided: String?, now: Date = Date()) -> String? {
        guard ["training", "report", "weekly_review", "weekly_center", "club_weekly", "club_workout"].contains(kind) else { return nil }
        let key = kind == "weekly_center" ? ClubDates.key(now) : provided
        guard let key, ClubDates.date(fromKey: key) != nil else { return nil }
        return key
    }
}
enum MembershipUpgradePolicy {
    static func permitsPurchase(activeMember: Bool, lifetimeOwned: Bool, lifetimePackage: Bool) -> Bool {
        !lifetimeOwned && (!activeMember || lifetimePackage)
    }
}
enum PlanExplanationRules {
static func sameStructure(_ before: [AIPlanSession], _ after: [AIPlanSession]) -> Bool {
        guard before.count == after.count else { return false }
        let left = before.sorted { $0.date < $1.date }, right = after.sorted { $0.date < $1.date }
        for (a, b) in zip(left, right) {
            guard a.date == b.date, a.exercises.count == b.exercises.count else { return false }
            for (x, y) in zip(a.exercises, b.exercises) {
                guard x.library_id == y.library_id, x.custom_id == y.custom_id,
                      x.custom_unit == y.custom_unit, x.rest_seconds == y.rest_seconds, x.name == y.name, x.sets.count == y.sets.count else { return false }
                for (s, t) in zip(x.sets, y.sets) {
                    guard s.reps == t.reps, s.durationSeconds == t.durationSeconds else { return false }
                    // The AI leaves loads unset; entering an actual load is not a new prescription.
                    if let weight = s.weight, Optional(weight) != t.weight { return false }
                }
            }
        }
        return true
    }
static func originalSessions(_ sessions: [AIPlanSession], in cycle: TrainingCycle) -> [AIPlanSession] {
        sessions.filter { cycle.dates.contains($0.date) }
    }
static func sessions(in cycle: TrainingCycle, days: [String: DayLog]) -> [AIPlanSession] {
        cycle.dates.compactMap { key in
            guard let day = days[key], !day.exercises.isEmpty else { return nil }
            return session(date: key, exercises: day.exercises)
        }
    }
static func session(date: String, exercises: [Exercise]) -> AIPlanSession {
        AIPlanSession(date: date, label: "", exercises: exercises.map { exercise in
            AIPlanExercise(name: exercise.name, muscle: exercise.muscle,
                sets: exercise.sets.map { AIPlanSet(weight: $0.weight, reps: $0.reps, durationSeconds: $0.durationSeconds) },
                library_query: exercise.libraryQuery, library_id: exercise.libraryID,
                custom_id: exercise.customExerciseID, custom_unit: exercise.customUnit, rest_seconds: exercise.restSeconds)
        })
    }
}

var checks=0
func check(_ value:Bool,_ label:String) { guard value else { fatalError(label) };checks+=1 }
func date(_ key:String)->Date { ClubDates.date(fromKey:key)! }
func movement(_ name:String="旧动作")->Exercise { Exercise(name:name,muscle:"全身",sets:[TrainingSet(reps:10)]) }
let future=ClubDates.calendar.date(byAdding:.day,value:14,to:Date())!
let monday=ClubDates.calendar.nextDate(after:future,matching:DateComponents(weekday:2),matchingPolicy:.nextTime)!
let start=ClubDates.calendar.startOfDay(for:monday)
let dates=(0..<28).map { ClubDates.key(ClubDates.calendar.date(byAdding:.day,value:$0,to:start)!) }
var old:[String:DayLog]=[:]
for i in 0..<14 { old[dates[i]]=DayLog(exercises:[movement()]) }
let originalIDs=old.mapValues { $0.exercises.map(\.id) }
_ = TrainingCycle.stamp(days:&old,start:start,plannedDates:dates,sourceJobID:"old-job")
_ = TrainingCycle.stamp(days:&old,start:date(dates[7]),plannedDates:dates,sourceJobID:"old-job")
let changed=TrainingCycle.stamp(days:&old,start:date(dates[2]),plannedDates:Array(dates[2..<9]),sourceJobID:"new-job")
let intervals=TrainingCycle.available(days:old)
check(Set(intervals.flatMap(\.dates)).count==intervals.flatMap(\.dates).count,"no overlapping cycles after mid-cycle adoption")
check(old[dates[0]]?.planCycle?.end==dates[1] && old[dates[0]]?.planCycle?.sourceJobID=="old-job","old prefix and provenance retained")
check(old[dates[9]]?.planCycle?.end==dates[13] && old[dates[9]]?.planCycle?.sourceJobID=="old-job","old suffix and provenance retained")
check(changed.contains(dates[0]) && changed.contains(dates[13]),"surviving interval changes included in persistence transaction")
check(old.mapValues { $0.exercises.map(\.id) }==originalIDs,"cycle repair does not delete movements")
let encoded=try JSONEncoder().encode(old)
let restored=try JSONDecoder().decode([String:DayLog].self,from:encoded)
check(TrainingCycle.available(days:restored)==intervals,"new intervals survive serialization")
var legacy:[String:DayLog]=[:]
let first=TrainingCycle(start:dates[0],plannedDates:Array(dates[0..<7]),sourceJobID:"old")
let second=TrainingCycle(start:dates[2],plannedDates:Array(dates[2..<9]),sourceJobID:"new")
for key in first.dates { legacy[key]=DayLog(exercises:[movement()],planCycle:first) }
for key in second.dates { legacy[key]=DayLog(exercises:[movement()],planCycle:second) }
let recovered=TrainingCycle.available(days:legacy)
check(Set(recovered.flatMap(\.dates)).count==recovered.flatMap(\.dates).count,"existing overlapping markers resolved by actual ownership")
for duration in [14,28] {
    var logs:[String:DayLog]=[:];var full:[AIPlanSession]=[]
    for i in 0..<duration where i%7==0 || i%7==2 || i%7==4 {
        let ex=movement();logs[dates[i]]=DayLog(exercises:[ex]);full.append(PlanExplanationRules.session(date:dates[i],exercises:[ex]))
    }
    for i in stride(from:0,to:duration,by:7) {
        _=TrainingCycle.stamp(days:&logs,start:date(dates[i]),plannedDates:full.map(\.date),sourceJobID:"long-job")
    }
    for cycle in TrainingCycle.available(days:logs) {
        let expected=PlanExplanationRules.originalSessions(full,in:cycle)
        check(PlanExplanationRules.sameStructure(expected,PlanExplanationRules.sessions(in:cycle,days:logs)),"unchanged long plan is not labelled modified")
        var actual=PlanExplanationRules.sessions(in:cycle,days:logs)
        actual[0].exercises[0].sets[0].reps+=1
        check(!PlanExplanationRules.sameStructure(expected,actual),"actual target edits remain detected")
    }
}
check(!HistoryVisibility.hasRecordedActivity(DayLog(bodyWeight:BodyWeightEntry(kilograms:nil))),"weight deletion tombstone does not create record day")
check(HistoryVisibility.hasRecordedActivity(DayLog(bodyWeight:BodyWeightEntry(kilograms:68))),"actual weight retains record day")
check(HistoryVisibility.hasRecordedActivity(DayLog(meals:["早餐"],bodyWeight:BodyWeightEntry(kilograms:nil))),"other actual records survive weight deletion")
check(!HistoryVisibility.hasRecordedActivity(DayLog(exercises:[movement()],bodyWeight:BodyWeightEntry(kilograms:nil))),"uncompleted schedule alone is not a recorded day")
check(!WorkoutSessionTransition.shouldResetRest(previous:nil,current:UUID()),"automatic first start keeps rest countdown")
check(WorkoutSessionTransition.shouldResetRest(previous:UUID(),current:UUID()),"actual session switch resets rest countdown")
check(WorkoutSessionTransition.shouldResetRest(previous:UUID(),current:nil),"closing session resets rest countdown")
check(ClubNotificationRouting.dateKey(kind:"weekly_center",provided:nil,now:start)==ClubDates.key(start),"periodic reminder opens current review without stale scheduled date")
check(ClubNotificationRouting.dateKey(kind:"weekly_center",provided:"2000-01-01",now:start)==ClubDates.key(start),"periodic reminder date resolved at tap time")
check(ClubNotificationRouting.dateKey(kind:"weekly_review",provided:"2026-10-01",now:start)=="2026-10-01","completed report notification retains exact report date")
check(ClubNotificationRouting.dateKey(kind:"report",provided:"2026-02-30",now:start)==nil,"malformed notification date cannot navigate")
check(ClubNotificationRouting.dateKey(kind:"unsupported",provided:dates[0],now:start)==nil,"unknown notification kind ignored")
check(MembershipUpgradePolicy.permitsPurchase(activeMember:true,lifetimeOwned:false,lifetimePackage:true),"subscriber can buy lifetime")
check(!MembershipUpgradePolicy.permitsPurchase(activeMember:true,lifetimeOwned:false,lifetimePackage:false),"subscriber cannot buy duplicate subscription through upgrade path")
check(!MembershipUpgradePolicy.permitsPurchase(activeMember:true,lifetimeOwned:true,lifetimePackage:true),"permanent member cannot buy again")
check(MembershipUpgradePolicy.permitsPurchase(activeMember:false,lifetimeOwned:false,lifetimePackage:false),"non-member may buy subscription")

func prepared()->(StoreFixture,WeeklyReview,[AIPlanSession]) {
    let store=StoreFixture()
    for i in 0..<7 { store.state.days[dates[i]]=DayLog(exercises:i<5 ? [movement()] : [],meals:["早餐"],bodyWeight:BodyWeightEntry(kilograms:68)) }
    let sessions=[0,2,4].map { i in PlanExplanationRules.session(date:dates[i],exercises:[movement("新动作")]) }
    let result=WeeklyResult(kind:"weekly_review",summary:"",training:"",nutrition:"",recovery:"",appearance:"",photoFeedback:[],decision:"adjust",reason:"",notes:[],sessions:sessions)
    var review=WeeklyReview(date:ClubDates.key(ClubDates.calendar.date(byAdding:.day,value:-1,to:start)!),result:result)
    review.survey.trainingDays=[1,3,5];review.baseline=store.state.days.mapValues(\.exercises)
    return (store,review,sessions)
}
let (store,review,sessions)=prepared()
let oldRemoved=store.state.days[dates[1]]!.exercises[0].id.uuidString
check(store.applyWeeklyPlan(review,sessions:sessions),"whole-week adjustment succeeds")
check(dates.prefix(7).filter { !(store.state.days[$0]?.exercises.isEmpty ?? true) }.count==3,"five training days actually reduced to three")
check(store.state.days[dates[1]]?.meals==["早餐"] && store.state.days[dates[1]]?.bodyWeight?.kilograms==68,"rest day keeps food and weight")
check(store.state.deletedExerciseIDs?.contains(oldRemoved)==true,"removed old exercise receives cloud tombstone")
check(store.applyWeeklyPlan(review,sessions:sessions) && store.state.days[dates[0]]?.exercises.count==1,"second apply is idempotent")
let (partial,pReview,pSessions)=prepared()
check(partial.applyWeeklyPlan(pReview,sessions:[pSessions[0]],replaceWholeWeek:false),"explicit partial adjustment remains available")
check(partial.state.days[dates[1]]?.exercises.count==1,"partial adjustment preserves other dates")
let (protected,qReview,qSessions)=prepared();protected.state.days[dates[1]]!.workoutStartedAt=Date()
let beforeProtected=try JSONEncoder().encode(protected.state)
check(!protected.applyWeeklyPlan(qReview,sessions:qSessions),"started rest-day workout blocks entire transaction")
check(try CloudMerge.same(protected.state,JSONDecoder().decode(SavedState.self,from:beforeProtected)),"blocked whole-week change preserves all data")
let (edited,eReview,eSessions)=prepared();edited.state.days[dates[1]]!.exercises[0].sets[0].reps=12
check(!edited.applyWeeklyPlan(eReview,sessions:eSessions),"concurrent edit on removed rest day blocks replacement")
let (failed,fReview,fSessions)=prepared();failed.writesAllowed=false
let previous=failed.state
check(!failed.applyWeeklyPlan(fReview,sessions:fSessions),"storage failure is reported")
check(try CloudMerge.same(previous,failed.state),"storage failure rolls back rest-day removal and replacements")
let (missing,mReview,mSessions)=prepared();var withoutBaseline=mReview;withoutBaseline.baseline.removeValue(forKey:dates[1])
check(!missing.applyWeeklyPlan(withoutBaseline,sessions:mSessions),"missing baseline cannot remove an old arrangement")
print("PASS \(checks) production v75 cycle/adoption/history rules")
