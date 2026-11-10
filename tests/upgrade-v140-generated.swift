import Foundation
import CryptoKit

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

struct Meal: Identifiable, Codable {
    var id = UUID()
    var name: String
    var category: String
    var calories: Double
    var protein: Double
    var carbs: Double
    var fat: Double
    var photoFilename: String?
    var photoRemoteID: String? = nil
    var sourceAIJobID: String?
    var estimated: Bool?
    var estimateNotes: [String]?
    var components: [FoodComponent]? = nil
    var consumedFraction: Double? = nil
    var nutritionKnown: Bool? = nil
    var placementConflictDates: [String]? = nil
    var placementConfirmedAt: Date? = nil
    var hasNutrition: Bool { nutritionKnown != false }
}

struct WorkoutBaselineSet: Codable, Equatable {
    var id: UUID
    var exerciseID: UUID
    var unit: String
    var targetSeconds: Int?
    var targetReps: Int? = nil
    var targetWeight: Double? = nil
    var targetRestSeconds: Int? = nil
}

struct WorkoutExecutionBaseline: Codable, Equatable {
    var version = 1
    var capturedAt: Date
    var sets: [WorkoutBaselineSet]
    var restSeconds: Int? = nil
}

struct WorkoutSession: Identifiable, Codable {
    var id: UUID
    var startedAt: Date?
    var endedAt: Date?
    var savedAt: Date?
    var linkedDeviceWorkoutID: String?
    var executionBaseline: WorkoutExecutionBaseline? = nil
}

struct DayLog: Codable {
    var insightEvents: [ClubInsightEvent]? = nil
    var insightFeedback: [ClubInsightFeedback]? = nil
    var goalVersions: [ClubGoalVersion]? = nil
    var planVersions: [ClubPlanVersion]? = nil
    var exercises: [Exercise] = []
    var meals: [Meal] = []
    var health: HealthDay?
    var weeklyReview: WeeklyReview?
    var weeklyReviewHistory: [WeeklyReview]? = nil
    var deletedWeeklyReviewIDs: [String]? = nil
    var workoutSavedAt: Date?
    // Optional additions keep all pre-0.13.18 records decodable.
    var workoutStartedAt: Date?
    var workoutEndedAt: Date?
    var linkedDeviceWorkoutID: String?
    var nutritionTarget: NutritionTarget?
    var bodyWeight: BodyWeightEntry?
    var workoutSessions: [WorkoutSession]? = nil
    var activeWorkoutSessionID: UUID? = nil
    var planCycle: TrainingCycle? = nil
    var mealCompletion: MealCompletion? = nil
    var movedFromDate: String? = nil
    var plannedMoveDestination: String? = nil
    var mealsComplete: Bool { !meals.isEmpty && mealCompletion?.signature == MealCompletion.signature(meals) }
    var trainingLog: DayLog {
        guard let active = activeWorkoutSessionID, workoutSessions?.contains(where: { $0.id == active }) == true else { return self }
        var result = self
        result.exercises = exercises.filter { $0.workoutSessionID == active }
        result.workoutSessions = nil; result.activeWorkoutSessionID = nil
        return result
    }
    var hasUnconfirmedTraining: Bool {
        guard let sessions = workoutSessions, !sessions.isEmpty else { return completedSets > 0 && workoutSavedAt == nil }
        return sessions.contains { session in
            session.savedAt == nil && exercises.contains { $0.workoutSessionID == session.id && $0.sets.contains(where: \.validCompletion) }
        }
    }
    var isTrainingConfirmed: Bool { completedSets > 0 && !hasUnconfirmedTraining }
    var volume: Double { exercises.flatMap(\.sets).reduce(0) { $0 + $1.volume } }
    var completedSets: Int { exercises.flatMap(\.sets).filter(\.validCompletion).count }
    var totalSets: Int { exercises.reduce(0) { $0 + $1.sets.count } }
    var timedSeconds: Int { exercises.flatMap(\.sets).filter(\.validCompletion).reduce(0) { $0 + ($1.durationSeconds ?? 0) } }
    var unknownNutritionMeals: Int { meals.filter { !$0.hasNutrition }.count }
    var knownMeals: [Meal] { meals.filter(\.hasNutrition) }
    var calories: Double { knownMeals.reduce(0) { $0 + $1.calories } }
    var protein: Double { knownMeals.reduce(0) { $0 + $1.protein } }
}

struct MemberProfile: Codable, Equatable {
    var nickname = "薄肌新成员"
    var identityVersion: Int?
    var avatarID: String?
    var avatarImage: Data?
    var gender: String?
    var age = 28
    var height: Double = 175
    var weight: Double = 68
    var goal = "增肌"
    var experience = "新手"
    var venue = "健身房"
    var daysPerWeek = 3
    var focus = "全身"
    var equipment: String?
    var equipmentOther: String?
    var sessionMinutes: Int?
    var limitations: String?
    var trainingDays: [Int]?
    var dailyActivity: String?
    var nutritionContext: String?
    var homeTrainingDays: [Int]?
    var planDurationDays: Int? = nil
    var aiProfile: MemberProfile { var copy = self; copy.identityVersion = nil; copy.avatarID = nil; copy.avatarImage = nil; copy.nickname = "薄肌成员"; return copy }
}

struct NutritionTarget: Codable, Equatable {
    var caloriesMin: Double
    var caloriesMax: Double
    var proteinMin: Double
    var proteinMax: Double
    var fatMin: Double
    var fatMax: Double
    var meals: Int
    var note: String

    var maintenanceMin: Double? = nil
    var maintenanceMax: Double? = nil
    var strategy: String? = nil
    var calculationVersion: Int? = nil
    var generalGuidanceOnly: Bool? = nil

    static func estimate(_ profile: MemberProfile) -> NutritionTarget {
        let weight = profile.weight.isFinite ? max(20, min(400, profile.weight)) : 68
        let height = profile.height.isFinite ? max(100, min(250, profile.height)) : 175
        let age = max(18, min(100, profile.age))
        let genderOffset = profile.gender == "女" ? -161.0 : profile.gender == "男" ? 5.0 : -78.0
        let bmr = 10 * weight + 6.25 * height - 5 * Double(age) + genderOffset
        let base = profile.dailyActivity == "日常体力活动较多" ? 1.55 : profile.dailyActivity == "经常站立走动" ? 1.4 : 1.2
        let activity = min(1.85, base + Double(max(0, min(7, profile.daysPerWeek))) * 0.035)
        let maintenance = min(9000, max(1400, bmr * activity))
        let bmi = BodyProfileAssessment.bmi(profile)
        let special = profile.age < 18 || (profile.nutritionContext != nil && profile.nutritionContext != "普通成人")
        let underweight = bmi.map { $0 < 18.5 } ?? false
        let lose = profile.goal.contains("减脂") && !underweight && !special
        let gain = (profile.goal.contains("增肌") || profile.goal.contains("力量")) && (bmi ?? 24) < 24 && !special
        let strategy = special ? "需要个别评估" : lose ? "温和热量缺口" : gain ? "小幅热量盈余" : "维持热量与规律训练"
        let calories = maintenance * (lose ? 0.9 : gain ? 1.05 : 1)
        let band = max(100, calories * 0.04)
        var note = "估算结合身体资料、日常活动和每周训练频率。先观察至少两周的真实记录与体重均值，再决定调整；手表运动热量不直接加回饮食目标。"
        if profile.dailyActivity == nil { note += "目前按主要久坐估算，可在资料页补充日常活动。" }
        if underweight && profile.goal.contains("减脂") { note += "当前 BMI 偏轻，未设置减脂缺口，建议重新确认目标。" }
        if special { note = "当前情况不适用通用成人减脂或增重算法。保留饮食记录与规律饮食建议，具体目标请结合专业评估。" }
        return NutritionTarget(caloriesMin: max(1200, (calories-band).rounded()), caloriesMax: max(1300, (calories+band).rounded()),
            proteinMin: (weight * (gain ? 1.6 : 1.2)).rounded(), proteinMax: (weight * (gain ? 2.0 : 1.6)).rounded(), fatMin: (weight*0.8).rounded(), fatMax: (weight*1.0).rounded(),
            meals: 3, note: note, maintenanceMin: (maintenance*0.95).rounded(), maintenanceMax: (maintenance*1.05).rounded(),
            strategy: strategy, calculationVersion: 2, generalGuidanceOnly: special)
    }
}

struct PostDraft: Identifiable, Codable {
    // Legacy records remain decodable; the forum feature has been removed.
    var id = UUID()
    var text: String
    var createdAt = Date()
}

struct CustomExercise: Identifiable, Codable, Equatable {
    var id = UUID()
    var name = ""
    var muscle = ""
    var equipment = ""
    var unit = "次"
    var updatedAt = Date()
    static let muscles = ["胸", "背", "肩", "手臂", "大腿", "臀", "小腿", "核心", "有氧"]
    var normalizedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "zh_CN")) }
    var valid: Bool { !normalizedName.isEmpty && name.unicodeScalars.count <= 60 && !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) && ["次","秒"].contains(unit) && (muscle.isEmpty || Self.muscles.contains(muscle)) && equipment.unicodeScalars.count <= 60 }
    var bodyPart: String { ["胸":"chest", "背":"back", "肩":"shoulders", "手臂":"upper arms", "大腿":"upper legs", "臀":"glutes", "小腿":"lower legs", "核心":"waist", "有氧":"cardio"][muscle] ?? "" }
    var blankSet: TrainingSet { TrainingSet(reps: unit == "秒" ? 0 : 10, durationSeconds: unit == "秒" ? 30 : nil) }
    func exercise() -> Exercise {
        Exercise(name: name, muscle: muscle.isEmpty ? "未指定" : muscle, sets: (0..<3).map { _ in blankSet }, equipment: equipment.isEmpty ? nil : equipment, customExerciseID: id, customUnit: unit)
    }
}

struct SavedState: Codable {
    var version = 1
    var days: [String: DayLog] = [:]
    var profile = MemberProfile()
    var drafts: [PostDraft] = []
    var importedPlan = ""
    // Optional for compatibility with records saved by version 0.1.
    var appliedAIJobs: [String]?
    var deletedExerciseIDs: [String]?
    var deletedMealIDs: [String]?
    var deletedMediaIDs: [String]?
    var deletedAIJobIDs: [String]?
    var nutritionTarget: NutritionTarget?
    var customExercises: [CustomExercise]? = nil
    var deletedCustomExerciseIDs: [String]? = nil
}

struct BodyWeightEntry: Codable, Equatable {
    var kilograms: Double?
    var updatedAt: Date
    var isValid: Bool { kilograms.map { $0.isFinite && (20...400).contains($0) } ?? true }
}

struct BodyWeightPoint: Identifiable {
    let date: Date
    let kilograms: Double
    var id: String { ClubDates.key(date) }
}

enum BodyWeightHistory {
    static func points(days: [String: DayLog], through date: Date, limit: Int = 30) -> [BodyWeightPoint] {
        let end = ClubDates.key(date)
        return days.keys.sorted().filter { $0 <= end }.compactMap { key in
            guard let entry = days[key]?.bodyWeight, entry.isValid,
                  let kg = entry.kilograms, let measured = ClubDates.date(fromKey: key) else { return nil }
            return BodyWeightPoint(date: measured, kilograms: kg)
        }.suffix(max(0, limit)).map { $0 }
    }
}

struct MealCompletion: Codable {
    var signature: String
    var updatedAt: Date = Date()
    static func signature(_ meals: [Meal]) -> String {
        // Media upload/download and provenance do not alter what the person ate.
        let content = meals.sorted { $0.id.uuidString < $1.id.uuidString }.map { meal -> Meal in
            var copy = meal; copy.photoFilename = nil; copy.photoRemoteID = nil
            copy.estimateNotes = nil; copy.estimated = nil; copy.sourceAIJobID = nil
            return copy
        }
        return ExperienceDigest.of(content)
    }
}

enum BodyProfileAssessment {
    static let activityOptions = ["主要久坐", "经常站立走动", "日常体力活动较多"]
    static let contextOptions = ["普通成人", "孕期或哺乳期", "需按医生建议饮食"]
    static func bmi(_ p: MemberProfile) -> Double? {
        guard p.age >= 18, p.nutritionContext != "孕期或哺乳期", p.height.isFinite, (100...250).contains(p.height), p.weight.isFinite, (20...400).contains(p.weight) else { return nil }
        return ((p.weight / pow(p.height / 100, 2)) * 10).rounded() / 10
    }
    static func category(_ p: MemberProfile) -> String {
        guard let value = bmi(p) else { return "不适用成人 BMI 分类" }
        if value < 18.5 { return "偏轻" }; if value < 24 { return "适中" }
        return value < 28 ? "超重范围" : "肥胖范围"
    }
    static func suggestedGoal(_ p: MemberProfile) -> String {
        guard let value = bmi(p), p.nutritionContext == nil || p.nutritionContext == "普通成人" else { return "养成运动习惯" }
        return value < 18.5 ? "增肌塑形" : value >= 24 ? "减脂瘦身" : "增肌塑形"
    }
    static func explanation(_ p: MemberProfile) -> String {
        if p.nutritionContext == "孕期或哺乳期" { return "孕期或哺乳期不使用当前体重的成人 BMI 分类来推荐减脂目标，请结合个人情况评估。" }
        if p.age < 18 { return "未成年人不使用成人 BMI 分类和减脂热量目标，身体发育情况需要结合年龄评估。" }
        guard bmi(p) != nil else { return "请核对身高与体重后查看 BMI 参考；超出适用范围时不提供分类。" }
        return "BMI 只反映身高与体重关系，不能区分肌肉和脂肪。建议还要结合腰围、训练经验与个人目标；不会替你更改选择。"
    }
}

enum ExperienceDigest {
    // Stable, non-security fingerprint. sortedKeys also makes it device-independent.
    static func of<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return "invalid" }
        var hash: UInt64 = 14695981039346656037
        for byte in data { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return String(hash, radix: 16)
    }
}


struct FoodComponent: Codable {}
struct HealthDay: Codable {}
struct WeeklyReview: Codable { var result: String? = nil }
enum ExerciseNames { static func display(_ name:String,id:String?,query:String?)->String { name } }


struct AIPlanSet: Codable, Equatable { var weight: Double?; var reps: Int; var durationSeconds: Int? = nil
    var repetitionLabel: String { durationSeconds.map { "\($0) 秒" } ?? "\(reps) 次" }
}

struct AIPlanExercise: Codable, Equatable { var name: String; var muscle: String; var sets: [AIPlanSet]; var library_query: String?; var library_id: String? = nil; var custom_id: UUID? = nil; var custom_unit: String? = nil; var rest_seconds: Int? = nil }

struct AIPlanSession: Codable, Equatable { var date: String; var label: String; var exercises: [AIPlanExercise] }

extension AIPlanExercise { var displayName: String { custom_id != nil ? name : ExerciseNames.display(name, id: library_id, query: library_query) } }

struct FixtureExplanation { var version = 1 }
struct AIResult { var kind:String;var notes:[String] = [];var title:String? = nil;var sessions:[AIPlanSession]?;var plan_days:Int? = nil;var explanation:FixtureExplanation? = nil }

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

enum WorkoutEditing { static func isProtected(_ day: DayLog) -> Bool {
        day.workoutSavedAt != nil || day.workoutStartedAt != nil || day.exercises.contains { $0.sets.contains(where: \.completed) }
    } }

enum PlanAdoptionRules { static func isProtected(_ day: DayLog) -> Bool {
        WorkoutEditing.isProtected(day) || day.workoutSessions?.contains { $0.startedAt != nil || $0.savedAt != nil } == true
    } }

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
                let plan = plans.filter { $0.scopeDates.contains(key) && !$0.retainedDates.contains(key) }.max {
                    $0.recordedAt == $1.recordedAt ? $0.id < $1.id : $0.recordedAt < $1.recordedAt
                }
                rows.append(ClubAIDayContext(date: key, goalVersionID: goal?.id.uuidString.lowercased(),
                    profile: goal?.profile.aiProfile, goalChangedDuringDay: changes.count > 1 || (changes.count == 1 && goals.contains { $0.recordedAt < day }),
                    planVersionID: plan?.id, planSource: plan?.source))
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
            previousIDs: Array(Set(parents)).sorted(), scopeDates: Array(dates).sorted(), retainedDates: retained)
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


import Foundation

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
    private static func identity(_ exercise: Exercise) -> String? {
        if let id = exercise.customExerciseID { return "custom/" + id.uuidString }
        if let id = exercise.libraryID { return "library/" + id }
        // Legacy free-text names alone cannot prove the same exercise variant.
        guard let query = exercise.libraryQuery, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return "query/" + query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }
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


import Foundation

// Facts are rebuilt from the current saved records. No generated claim is cached
// under a date after its source has changed or been deleted.
struct ClubInsightKind: RawRepresentable, Codable, Hashable {
    let rawValue: String
    static let training = Self(rawValue: "training")
    static let nutrition = Self(rawValue: "nutrition")
    static let body = Self(rawValue: "body")
    static let workout = Self(rawValue: "workout")
    var supported: Bool { [Self.training, .nutrition, .body, .workout].contains(self) }
    init(rawValue: String) { self.rawValue = rawValue }
    init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    func encode(to encoder: Encoder) throws { var value = encoder.singleValueContainer(); try value.encode(rawValue) }
}

struct ClubInsightFact: Identifiable, Equatable {
    let id: String
    let kind: ClubInsightKind
    let title: String
    let detail: String
    let evidence: String
    let priority: Int
    var sourceSessionID: UUID? = nil
    var action: ClubInsightAction? = nil
    var sourceDigest: String? = nil
}

struct ClubGoalContext {
    let profile: MemberProfile
    let nutrition: NutritionTarget
    let dateKey: String
    let usesHistoricalNutrition: Bool
    let canEvaluateNutrition: Bool

    init(state: SavedState, date: Date, now: Date = Date()) {
        let key = ClubDates.key(date)
        dateKey = key
        let historical = ClubDates.key(date) < ClubDates.key(now)
        profile = historical ? (ClubHistoryRules.profile(on: date, days: state.days) ?? state.profile).aiProfile : state.profile.aiProfile
        let snapshot = state.days[key]?.nutritionTarget
        nutrition = (historical ? snapshot : nil) ?? state.nutritionTarget ?? NutritionTarget.estimate(state.profile)
        usesHistoricalNutrition = historical && snapshot != nil
        canEvaluateNutrition = !historical || snapshot != nil
    }
}

enum ClubInsightRules {
    static func facts(state: SavedState, date: Date, now: Date = Date()) -> [ClubInsightFact] {
        guard !ClubDates.isFuture(date, now: now) else { return [] }
        let key = ClubDates.key(date)
        let day = state.days[key] ?? DayLog()
        let context = ClubGoalContext(state: state, date: date, now: now)
        var result: [ClubInsightFact] = []
        for sessionID in ClubWorkoutSummaryRules.available(state: state, date: date, now: now) {
            guard let report = ClubWorkoutSummaryRules.make(state: state, date: date, sessionID: sessionID, now: now) else { continue }
            result.append(.init(id: key + "/workout/" + sessionID.uuidString.lowercased(), kind: .workout,
                title: "本次训练总结已更新", detail: "这次已确认 \(report.completedSets) 组。" + (report.comparisons.isEmpty ? "先保留这次实际表现，不凭单次记录判断进步。" : "有符合条件的历史记录，可以展开逐项对照。"),
                evidence: "依据：\(key) 这一次已确认训练；按场次区分，历史只采用此前已确认的记录。",
                priority: 110, sourceSessionID: sessionID,
                action: ClubInsightAction(type: "workout_summary", date: key, sessionID: sessionID),
                sourceDigest: ClubInsightLedger.digest(report)))
        }
        let isToday = key == ClubDates.key(now)
        if day.isTrainingConfirmed {
            result.append(.init(id: key + "/training", kind: .training, title: "训练已保存",
                detail: "已确认完成 \(day.completedSets) 组" + (day.timedSeconds > 0 ? "，其中按秒训练累计 \(day.timedSeconds) 秒。" : "。") + "可以结合饮食记录查看本日分析。",
                evidence: "依据：\(key) 已确认的有效训练组。普通保存和计划目标不算完成。", priority: 100))
        } else if day.completedSets > 0 {
            result.append(.init(id: key + "/training", kind: .training, title: "训练记录待确认",
                detail: "已记录 \(day.completedSets) 个有效完成组。结束训练后，请确认保存实际完成的部分。",
                evidence: "依据：\(key) 已登记组次，仍有未确认的训练。", priority: 90))
        } else if day.workoutStartedAt != nil && day.workoutSavedAt == nil && day.workoutEndedAt == nil {
            result.append(.init(id: key + "/training", kind: .training, title: "训练已开始，记录待完成",
                detail: "已保存开始状态，尚无有效完成组。确实完成训练后，可以登记组次并确认保存。",
                evidence: "依据：这一天的训练开始标记，不据此推断实际完成量。", priority: 85))
        } else if isToday && !day.exercises.isEmpty {
            result.append(.init(id: key + "/training", kind: .training, title: "今天的训练已安排",
                detail: "日程中有 \(day.exercises.count) 个动作、\(day.totalSets) 组。准备好后可以开始。",
                evidence: "依据：今天保存的训练安排。尚无完成记录，不代表你没有训练。", priority: 70))
        } else if isToday, let cycle = day.planCycle, cycle.dates.contains(key), !cycle.plannedDates.contains(key) {
            result.append(.init(id: key + "/training", kind: .training, title: "今天按计划休息",
                detail: "当前计划把今天留给恢复。如果想提前练，可以在当天安排里选择后续训练。",
                evidence: "依据：当前计划中的休息日。", priority: 50))
        }
        if !day.meals.isEmpty {
            let known = day.knownMeals
            let protein = known.reduce(0) { $0 + $1.protein }
            let number = String(format: "%.0f", protein)
            let hasUnknown = day.unknownNutritionMeals > 0
            var detail = "已登记 \(day.meals.count) 条饮食"
            detail += known.isEmpty ? "，目前没有可汇总的营养估算。" : "，其中已知蛋白质约 \(number) g。"
            if hasUnknown || !day.mealsComplete {
                detail += "可能存在漏记或未知营养，暂不判断全天是否达标。"
            } else if !context.canEvaluateNutrition {
                detail += "缺少当时的饮食目标，不使用今天的目标评价历史记录。"
            } else if context.nutrition.generalGuidanceOnly == true {
                detail += "当前身体背景需要个别评估，不按通用目标判断缺口。"
            } else if protein < context.nutrition.proteinMin {
                detail += "你已确认饮食记录完整；已登记蛋白质低于参考下限，可以核对份量与明细。"
            } else {
                detail += "你已确认饮食记录完整，可以查看全天分析。"
            }
            result.append(.init(id: key + "/nutrition", kind: .nutrition, title: "饮食记录跟进", detail: detail,
                evidence: "依据：\(key) 已登记饮食及完整性确认。营养值为估算，未记录不等于没吃。", priority: 60))
        }
        // BodyWeightHistory filters dates, invalid values, and takes the most recent
        // entries. Never infer a plateau from a pair of measurements.
        let points = BodyWeightHistory.points(days: state.days, through: date, limit: 30)
        if let last = points.last {
            result.append(.init(id: key + "/body", kind: .body, title: ClubDates.key(last.date) == key ? "身体记录已更新" : "最近一次身体记录",
                detail: "最近一次测量为 \(ClubDates.label(last.date))，\(String(format: "%.1f", last.kilograms)) kg。单次波动不能说明增肌或减脂效果。",
                evidence: "依据：截至 \(key) 的实际称重记录。资料中的体重不作为实测点。", priority: 30))
        }
        return result.sorted { $0.priority == $1.priority ? $0.id < $1.id : $0.priority > $1.priority }
    }
}


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
            return digest(TrainingSource(exercises: exercises, confirmed: day.isTrainingConfirmed,
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
                $0.kind != .body || state.days[key]?.bodyWeight?.kilograms != nil
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
                day.insightEvents = all + additions; state.days[key] = day; changed.append(key)
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



var tests = 0
func check(_ value: @autoclosure () -> Bool, _ name: String) {
    precondition(value(), name); tests += 1
}
let now = ClubDates.date(fromKey: "2026-10-15")!
let today = ClubDates.key(now)
let yesterday = ClubDates.calendar.date(byAdding: .day, value: -1, to: now)!
let tomorrow = ClubDates.calendar.date(byAdding: .day, value: 1, to: now)!
func facts(_ state: SavedState, date: Date = now) -> [ClubInsightFact] {
    ClubInsightRules.facts(state: state, date: date, now: now)
}
var state = SavedState()
check(facts(state).isEmpty, "profile weight is not a measured weight")
var meal = Meal(name: "鸡蛋", category: "早餐", calories: 150, protein: 12, carbs: 1, fat: 10)
var day = DayLog(); day.meals = [meal]; state.days[today] = day
check(facts(state).first!.detail.contains("暂不判断全天"), "single meal must not infer a daily shortfall")
day.mealCompletion = MealCompletion(signature: MealCompletion.signature(day.meals)); state.days[today] = day
check(facts(state).first!.detail.contains("低于参考下限"), "explicit complete records can compare a reference")
day.meals[0].nutritionKnown = false
day.mealCompletion = MealCompletion(signature: MealCompletion.signature(day.meals)); state.days[today] = day
check(facts(state).first!.detail.contains("暂不判断全天"), "unknown nutrition blocks daily judgement even after confirmation")
state.days[ClubDates.key(tomorrow)] = day
check(facts(state,date:tomorrow).isEmpty, "future records never produce insights")
day.meals[0].nutritionKnown = true
day.mealCompletion = MealCompletion(signature: MealCompletion.signature(day.meals))
state.days[ClubDates.key(yesterday)] = day
check(facts(state,date:yesterday).first!.detail.contains("缺少当时"), "historical target cannot be invented")
day.nutritionTarget = NutritionTarget.estimate(state.profile)
day.nutritionTarget!.proteinMin = 5
state.days[ClubDates.key(yesterday)] = day
check(!facts(state,date:yesterday).first!.detail.contains("低于参考下限"), "historical target wins over today's target")
var timed = DayLog()
timed.exercises = [Exercise(name:"平板支撑",muscle:"核心",sets:[TrainingSet(reps:0,completed:true,durationSeconds:60)])]
state.days[today] = timed
check(facts(state).first!.title == "训练记录待确认", "completed set is not a confirmed workout")
timed.workoutSavedAt = now; state.days[today] = timed
check(facts(state).first(where: { $0.kind == .training })!.detail.contains("60 秒"), "timed training is not zero training")
check(facts(state).first(where: { $0.kind == .training })!.title == "训练已保存", "confirmed workout becomes completion feedback")
let first = facts(state)
check(first == facts(state), "re-reading does not manufacture messages or timestamps")
state.days[today] = DayLog()
check(facts(state).isEmpty, "deleted training retracts the current fact")
var rest = DayLog(); rest.planCycle = TrainingCycle(start:today,plannedDates:[])
state.days[today] = rest
check(facts(state).first!.title == "今天按计划休息", "rest days are not missed workouts")
rest.bodyWeight = BodyWeightEntry(kilograms:70,updatedAt:now); state.days[today] = rest
check(facts(state).filter { $0.kind == .body }.count == 1, "actual measured point is visible")
check(!facts(state).contains { $0.detail.contains("平台期") }, "one measurement cannot establish a plateau")
state.days[today]!.bodyWeight = nil
check(!facts(state).contains { $0.kind == .body }, "deleted measurement removes fact")
check(facts(SavedState()).isEmpty, "a different empty account inherits no facts")
var special = SavedState(); special.profile.nutritionContext = "孕期或哺乳期"
special.days[today] = day; special.days[today]!.nutritionTarget = nil
check(facts(special).first!.detail.contains("个别评估"), "special context does not receive generic deficits")
print("Club AI foundation: \(tests) behavioral checks passed")
