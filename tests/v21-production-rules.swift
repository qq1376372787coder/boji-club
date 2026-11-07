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

    static func key(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func date(fromKey value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: value), key(date) == value else { return nil }
        return date
    }

    static func label(_ date: Date, format: String = "M月d日") -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}

struct TrainingSet: Identifiable, Codable {
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
    var sets: [TrainingSet] = (0..<3).map { _ in TrainingSet() }
    var libraryID: String?
    var equipment: String?
    var imageURL: String?
    var gifURL: String?
    var libraryQuery: String?
    var deletedSetIDs: [String]?
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
    var hasNutrition: Bool { nutritionKnown != false }
}

struct DayLog: Codable {
    var exercises: [Exercise] = []
    var meals: [Meal] = []
    var health: HealthDay?
    var weeklyReview: WeeklyReview?
    var workoutSavedAt: Date?
    // Optional additions keep all pre-0.13.18 records decodable.
    var workoutStartedAt: Date?
    var workoutEndedAt: Date?
    var linkedDeviceWorkoutID: String?
    var nutritionTarget: NutritionTarget?
    var bodyWeight: BodyWeightEntry?
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
    var homeTrainingDays: [Int]?
}

struct WidgetSnapshot: Codable, Equatable {
    var date: String = ""
    var workoutName: String = "今天还没有训练计划"
    var completedSets: Int = 0
    var totalSets: Int = 0
    var calories: Double = 0
    var protein: Double = 0
    var updatedAt: Date = .distantPast
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

    static func estimate(_ profile: MemberProfile) -> NutritionTarget {
        let weight = profile.weight.isFinite ? max(20, min(400, profile.weight)) : 68
        let height = profile.height.isFinite ? max(50, min(250, profile.height)) : 175
        let age = max(13, min(100, profile.age))
        let genderOffset = profile.gender == "女" ? -161.0 : 5.0
        let bmr = 10 * weight + 6.25 * height - 5 * Double(age) + genderOffset
        let activity = 1.2 + Double(max(1, min(7, profile.daysPerWeek))) * 0.045
        var calories = bmr * activity
        if profile.goal.contains("减脂") {
            calories *= 0.90
        } else if profile.goal.contains("增肌") || profile.goal.contains("力量") {
            calories *= 1.08
        }
        let calorieBand = max(120.0, calories * 0.045)
        let proteinFactorMin = profile.goal.contains("增肌") || profile.goal.contains("力量") ? 1.6 : 1.2
        let proteinFactorMax = profile.goal.contains("增肌") || profile.goal.contains("力量") ? 2.0 : 1.6
        let fatMin = weight * 0.8
        let fatMax = weight * 1.2
        return NutritionTarget(
            caloriesMin: max(1200, (calories - calorieBand).rounded()),
            caloriesMax: max(1300, (calories + calorieBand).rounded()),
            proteinMin: (weight * proteinFactorMin).rounded(),
            proteinMax: (weight * proteinFactorMax).rounded(),
            fatMin: fatMin.rounded(),
            fatMax: fatMax.rounded(),
            meals: (3...4).contains(profile.daysPerWeek) ? 3 : 4,
            note: "训练与饮食记录的估算范围，可按实际感受调整；不是医学或临床营养处方。"
        )
    }
}

struct PostDraft: Identifiable, Codable {
    // Legacy records remain decodable; the forum feature has been removed.
    var id = UUID()
    var text: String
    var createdAt = Date()
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
}

struct ExerciseGuide: Identifiable {
    let id: String
    let name: String
    let muscle: String
    let equipment: String
    let steps: [String]

    // Curated local examples; not represented as an imported GitHub dataset.
    static let samples: [ExerciseGuide] = [
        .init(id: "bench", name: "杠铃卧推", muscle: "胸部", equipment: "杠铃、卧推凳", steps: ["双脚稳定支撑，肩胛收紧。", "选择可控重量，缓慢下放杠铃。", "平稳推起；首次练习请寻求现场指导。"]),
        .init(id: "row", name: "坐姿划船", muscle: "背部", equipment: "划船器械", steps: ["调整坐姿，保持躯干稳定。", "控制手柄拉向身体，避免借力后仰。", "缓慢还原，保持动作范围舒适。"]),
        .init(id: "squat", name: "徒手深蹲", muscle: "腿部", equipment: "自重", steps: ["双脚稳定站立，脚尖自然朝向。", "屈髋屈膝下蹲至可控范围。", "平稳站起，保持呼吸。"]),
        .init(id: "press", name: "哑铃推举", muscle: "肩部", equipment: "哑铃", steps: ["使用可控重量，收紧躯干。", "向上推起，避免过度后仰。", "缓慢下放至舒适位置。"]),
        .init(id: "curl", name: "哑铃弯举", muscle: "手臂", equipment: "哑铃", steps: ["上臂贴近身体。", "屈肘举起哑铃，避免摆动。", "控制速度还原。"]),
        .init(id: "plank", name: "俯卧撑", muscle: "胸部", equipment: "自重", steps: ["双手支撑，保持躯干稳定。", "缓慢屈肘下放。", "推起身体；可按能力采用跪姿。"])
    ]
}



enum WorkoutEditError: LocalizedError {
    case changed, completed, limit
    var errorDescription: String? {
        switch self {
        case .changed: return "动作已被修改或删除，请重新打开后再更换。"
        case .completed: return "这个动作已全部完成。如需继续训练，请添加新动作，保留已有记录。"
        case .limit: return "保留已完成记录后会超过一天 30 个动作的上限，请先精简未开始的动作。"
        }
    }
}

enum WorkoutEditing {
    // Never rename recorded sets to a different movement or carry over its load.
    static func replacing(_ original: Exercise, with replacement: Exercise, in day: DayLog) throws -> DayLog {

        guard let index = day.exercises.firstIndex(where: { $0.id == original.id }) else { throw WorkoutEditError.changed }
        let current = day.exercises[index]
        let kept = current.sets.filter(\.validCompletion)
        let remaining = current.sets.filter { !$0.validCompletion }.count
        guard remaining > 0 || current.sets.isEmpty else { throw WorkoutEditError.completed }
        guard kept.isEmpty || day.exercises.count < 30 else { throw WorkoutEditError.limit }
        var result = day
        var newExercise = replacement
        newExercise.id = UUID()
        newExercise.sets = (0..<max(1, remaining)).map { _ in ExerciseMeasurement.blankSet(name: replacement.name, query: replacement.libraryQuery) }
        if kept.isEmpty {
            result.exercises[index] = newExercise
        } else {
            result.exercises[index].sets = kept
            result.exercises[index].deletedSetIDs = Array(Set((current.deletedSetIDs ?? []) + current.sets.filter { !$0.validCompletion }.map { $0.id.uuidString })).sorted()
            result.exercises.insert(newExercise, at: index + 1)
        }
        result.workoutSavedAt = nil
        return result
    }

    static func isProtected(_ day: DayLog) -> Bool {
        day.workoutSavedAt != nil || day.workoutStartedAt != nil || day.exercises.contains { $0.sets.contains(where: \.completed) }
    }
}

import Foundation

enum MealCategorySuggestion {
    static let categories = ["早餐", "午餐", "晚餐", "加餐"]
    static func recommended(for date: Date, now: Date = Date(), meals: [Meal], calendar: Calendar = ClubDates.calendar) -> String {
        guard calendar.isDate(date, inSameDayAs: now) else {
            return categories.first { category in !meals.contains { $0.category == category } } ?? "加餐"
        }
        let hour = calendar.component(.hour, from: now)
        let category: String
        switch hour {
        case 5..<10: category = "早餐"
        case 10..<15: category = "午餐"
        case 17..<22: category = "晚餐"
        default: category = "加餐"
        }
        return category != "加餐" && meals.contains { $0.category == category } ? "加餐" : category
    }
}

enum CalendarWindow {
    static func dates(centeredOn date: Date, calendar: Calendar = ClubDates.calendar) -> [Date] {
        let center = calendar.startOfDay(for: date)
        return (-3...3).compactMap { calendar.date(byAdding: .day, value: $0, to: center) }
    }
}

enum ClubGuideProgress {
    private static func key(_ id: Int, _ field: String) -> String { "boji.usage-guide.v2.\(id).\(field)" }
    static func shouldShow(_ id: Int, now: Date = Date(), defaults: UserDefaults = .standard) -> Bool {
        guard !defaults.bool(forKey:key(id,"completed")), !defaults.bool(forKey:key(id,"muted")) else { return false }
        if let snoozed = defaults.object(forKey:key(id,"snoozed")) as? Date, ClubDates.calendar.isDate(snoozed,inSameDayAs:now) { return false }
        return true
    }
    static func complete(_ id: Int) { UserDefaults.standard.set(true,forKey:key(id,"completed")) }
    static func postpone(_ id: Int) { UserDefaults.standard.set(Date(),forKey:key(id,"snoozed")) }
    static func mute(_ id: Int) { UserDefaults.standard.set(true,forKey:key(id,"muted")) }
}

enum ShareTextPages {
    static func split(_ text: String, fits: (String) -> Bool) -> [String] {
        guard !text.isEmpty else { return [""] }
        let characters=Array(text)
        var pages: [String]=[];var start=0
        while start < characters.count {
            var low=start+1;var high=min(characters.count,start+2000);var end=low
            while low <= high {
                let mid=(low+high)/2
                if fits(String(characters[start..<mid])) { end=mid;low=mid+1 } else { high=mid-1 }
            }
            if end < characters.count {
                let floor=start+max(1,(end-start)*3/4)
                if let boundary=(floor..<end).last(where:{["\n","。","！","？"," "].contains(characters[$0])}) { end=boundary+1 }
            }
            pages.append(String(characters[start..<end]));start=end
        }
        return pages
    }
}

enum ExerciseMeasurement {
    // Conservative defaults; dynamic variants override static-hold keywords.
    static func usesSeconds(name: String, query: String? = nil) -> Bool {
        let raw = [name, query ?? ""].joined(separator: " ").lowercased()
        let candidates = [name, query ?? ""].map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
        let countedVariants: Set<String> = ["isometric wipers", "power point plank", "dynamic chest stretch (male)", "circles knee stretch", "rocking frog stretch", "world greatest stretch", "weighted stretch lunge"]
        if candidates.contains(where: { countedVariants.contains($0) }) { return false }
        let timedCardio: Set<String> = ["run", "run (equipment)", "short stride run", "hands bike", "farmers walk", "walking on stepmill", "跑步", "慢跑", "农夫行走", "农夫走", "登楼机"]
        if candidates.contains(where: { timedCardio.contains($0) }) { return true }
        let dynamic = ["plank jack", "plank to", "plank up", "plank with", "plank leg", "plank knee", "plank twist", "plank reach", "plank shoulder", "plank hip", "side plank dip", "side plank rotation", "side plank raise", "to plank", "平板开合", "平板支撑转", "平板支撑交替", "平板支撑抬", "平板支撑提", "平板支撑摸", "平板支撑点", "平板支撑登", "侧平板抬", "侧平板提", "侧平板转", "侧平板下沉"]
        if dynamic.contains(where: { raw.contains($0) }) || raw.contains("plank tap") || raw.contains("to side plank") { return false }
        let timed = ["plank", "wall sit", "dead hang", "isometric", "static hold", "stretch", "treadmill", "stationary bike", "elliptical", "rowing machine", "jump rope", "battle rope", "平板支撑", "侧支撑", "靠墙静蹲", "静态", "悬垂保持", "拉伸", "跑步机", "动感单车", "椭圆机", "划船机", "跳绳", "战绳"]
        return timed.contains { token in
            if token.unicodeScalars.allSatisfy({ $0.isASCII }) {
                let pattern = "(?<![a-z])" + NSRegularExpression.escapedPattern(for: token) + "(?![a-z])"
                return raw.range(of: pattern, options: .regularExpression) != nil
            }
            return raw.contains(token)
        }
    }
    static func blankSet(name: String, query: String? = nil) -> TrainingSet {
        usesSeconds(name: name, query: query) ? TrainingSet(reps: 0, durationSeconds: 30) : TrainingSet()
    }
    // Imported/AI records retain their explicit units and all old recorded sets.
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

struct MealEntryRequest: Identifiable {
    let id = UUID()
    let date: Date
    var category: String? = nil
}


struct ReviewMetrics {
    let plannedSets, completedSets, trainingDays, finishedDays, mealDays, meals, healthDays: Int
    let averageCalories, averageProtein: Double?
    let nutritionDays: Int
    var remainingSets: Int { max(0, plannedSets - completedSets) }
    var completionLabel: String {
        guard plannedSets > 0 else { return "—" }
        return "\(Int((Double(completedSets) / Double(plannedSets) * 100).rounded()))%"
    }
    init(logs: [DayLog]) {
        plannedSets = logs.reduce(0) { $0 + $1.totalSets }
        completedSets = logs.reduce(0) { $0 + $1.completedSets }
        trainingDays = logs.filter { $0.completedSets > 0 }.count
        finishedDays = logs.filter { $0.totalSets > 0 && $0.completedSets == $0.totalSets }.count
        let foodDays = logs.filter { !$0.knownMeals.isEmpty }
        nutritionDays=foodDays.count
        mealDays = logs.filter { !$0.meals.isEmpty }.count
        meals = logs.reduce(0) { $0 + $1.meals.count }
        healthDays = logs.filter { $0.health?.hasData == true }.count
        averageCalories = foodDays.isEmpty ? nil : foodDays.reduce(0) { $0 + $1.calories } / Double(foodDays.count)
        averageProtein = foodDays.isEmpty ? nil : foodDays.reduce(0) { $0 + $1.protein } / Double(foodDays.count)
    }
}

struct HealthSource: Codable, Hashable, Identifiable {
    var id: String
    var name: String
}

struct HealthMetric: Codable {
    var value: Double
    var source: HealthSource
    var availableSources: [HealthSource]?
}

struct DeviceWorkout: Codable, Identifiable {
    var id: String
    var name: String
    var start: Date
    var end: Date
    var minutes: Double
    var calories: Double?
    var source: HealthSource
    var activityKind: String? = nil
    var averageHeartRate: Double? = nil

    var comparableKind: String? {
        if let activityKind, activityKind != "other" { return activityKind }
        return ["跑步": "running", "步行": "walking", "骑行": "cycling", "游泳": "swimming",
                "力量训练": "strength", "间歇训练": "interval", "瑜伽": "yoga", "徒步": "hiking"][name]
    }
}

struct HealthDay: Codable {
    var date: String
    var timeZone: String
    var updatedAt: Date
    var steps: HealthMetric?
    var activeEnergy: HealthMetric?
    var heartRate: HealthMetric?
    var restingHeartRate: HealthMetric?
    var sleep: HealthMetric?
    var workouts: [DeviceWorkout] = []
    var hasData: Bool { steps != nil || activeEnergy != nil || heartRate != nil || restingHeartRate != nil || sleep != nil || !workouts.isEmpty }
    var sources: [HealthSource] {
        Array(Set([steps, activeEnergy, heartRate, restingHeartRate, sleep].compactMap { $0?.source } + workouts.map(\.source))).sorted { $0.name < $1.name }
    }
    static func deduplicated(_ values: [DeviceWorkout], preferred: String) -> [DeviceWorkout] {
        let ordered = values.sorted {
            let l = $0.source.id == preferred ? 0 : $0.source.id == "tcx" ? 2 : 1
            let r = $1.source.id == preferred ? 0 : $1.source.id == "tcx" ? 2 : 1
            return l == r ? $0.id < $1.id : l < r
        }
        var result: [DeviceWorkout] = []
        for workout in ordered {
            let duplicate = result.contains { existing in
                if existing.id == workout.id { return true }
                // Different activities or two entries from one device are not proven duplicates.
                guard existing.source.id != workout.source.id,
                      let kind = existing.comparableKind, kind == workout.comparableKind else { return false }
                let overlap = min(existing.end, workout.end).timeIntervalSince(max(existing.start, workout.start))
                let longest = max(existing.end.timeIntervalSince(existing.start), workout.end.timeIntervalSince(workout.start))
                return longest > 0 && overlap / longest > 0.8
            }
            if !duplicate { result.append(workout) }
        }
        return result.sorted { $0.start < $1.start }
    }
}


enum WorkoutAssociation {
    static func suggestedIDs(for day: DayLog, workouts: [DeviceWorkout]) -> Set<String> {
        guard let start = day.workoutStartedAt, let end = day.workoutEndedAt,
              end > start, end.timeIntervalSince(start) <= 6 * 3600 else { return [] }
        return Set(workouts.filter { workout in
            guard workout.comparableKind == "strength" else { return false }
            let longest = max(end.timeIntervalSince(start), workout.end.timeIntervalSince(workout.start))
            let overlap = min(end, workout.end).timeIntervalSince(max(start, workout.start))
            return longest > 0 && overlap / longest >= 0.5
        }.map(\.id))
    }
}

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
    var string: String? { if case .string(let v) = self { return v }; return nil }
    static func encode<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }
}

struct AIInput: Codable {
    var kind: String
    var date: String
    var payload: [String: JSONValue]
}

struct AIRequest: Codable {
    var id: String
    var kind: String
    var date: String
    var payload: [String: JSONValue]
}

struct AIPlanSet: Codable { var weight: Double?; var reps: Int; var durationSeconds: Int? = nil
    var repetitionLabel: String { durationSeconds.map { "\($0) 秒" } ?? "\(reps) 次" }
}
struct AIPlanExercise: Codable { var name: String; var muscle: String; var sets: [AIPlanSet]; var library_query: String?; var library_id: String? = nil }
struct AIPlanSession: Codable { var date: String; var label: String; var exercises: [AIPlanExercise] }

struct AIResult: Codable {
    var kind: String
    var notes: [String]
    var title: String?
    var sessions: [AIPlanSession]?
    var name: String?
    var is_food: Bool?
    var components: [FoodComponent]?
    var estimated: Bool?
    var calories: Double?
    var protein: Double?
    var carbs: Double?
    var fat: Double?
    var summary: String?
    var training: String?
    var nutrition: String?
    var recovery: String?
}

struct AIJobResponse: Codable {
    var id: String
    var status: String
    var result: AIResult?
    var provider: String?
    var model: String?
    var error_code: String?
    var error_message: String?
}

struct AILocalJob: Identifiable, Codable {
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
    var replacementID: String?
    var isTerminal: Bool { ["succeeded", "failed", "deleted", "expired", "rejected", "discarded"].contains(status) }
}

enum AIClientError: LocalizedError {
    case message(String)
    case http(Int, String?, String)
    var errorDescription: String? {
        switch self { case .message(let text): return text; case .http(_, _, let text): return text }
    }
}


struct FoodComponent: Identifiable, Codable {
    var id: String = UUID().uuidString
    var name: String
    var amount: Double
    var unit: String
    var calories: Double
    var protein: Double
    var carbs: Double
    var fat: Double
    var basis: String
    var details: [String]

    var valid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && amount > 0 &&
        [amount, calories, protein, carbs, fat].allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 10000 }
    }
    mutating func resize(to value: Double) {
        guard value.isFinite, value > 0, value <= 10000, amount > 0 else { return }
        let ratio = value / amount
        calories *= ratio; protein *= ratio; carbs *= ratio; fat *= ratio
        amount = value
    }
}


struct LibraryExercise: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let bodyPart: String
    let equipment: String
    let target: String
    let muscleGroup: String
    let secondaryMuscles: [String]
    let imageURL: String?
    let gifURL: String?
    var nameZH: String? = nil
    var displayName: String { nameZH?.isEmpty == false ? nameZH! : name }
    var equipmentLabel: String { equipmentName(equipment) }
    var muscleLabel: String { muscleName(target.isEmpty ? bodyPart : target) }

    enum CodingKeys: String, CodingKey {
        case id, name, equipment, target
        case nameZH = "name_zh"
        case bodyPart = "body_part"
        case muscleGroup = "muscle_group"
        case secondaryMuscles = "secondary_muscles"
        case imageURL = "image_url"
        case gifURL = "gif_url"
    }
}


import Foundation

enum CloudSyncStatus: Equatable {
    case idle, syncing, synced(Date), waiting, failed(String)

    var label: String {
        switch self {
        case .idle: return "云端同步准备中"
        case .syncing: return "正在同步云端记录…"
        case .synced(let date):
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "HH:mm"
            return "已同步 · \(formatter.string(from: date))"
        case .waiting: return "离线记录已保留，联网后自动同步"
        case .failed: return "云端同步暂不可用，记录已保存在本机"
        }
    }
}

struct CloudState: Codable {
    var version = 1
    var days: [String: DayLog]
    var profile: MemberProfile
    var drafts: [PostDraft]
    var importedPlan: String
    var appliedAIJobs: [String]?
    var deletedExerciseIDs: [String]?
    var deletedMealIDs: [String]?
    var deletedMediaIDs: [String]?
    var deletedAIJobIDs: [String]?
    var nutritionTarget: NutritionTarget?
    var aiJobs: [AILocalJob]?

    init(_ state: SavedState, aiJobs: [AILocalJob] = []) {
        days = state.days
        profile = state.profile
        nutritionTarget = state.nutritionTarget
        drafts = state.drafts
        importedPlan = state.importedPlan
        appliedAIJobs = state.appliedAIJobs
        deletedExerciseIDs = state.deletedExerciseIDs
        deletedMealIDs = state.deletedMealIDs
        deletedMediaIDs = state.deletedMediaIDs
        deletedAIJobIDs = state.deletedAIJobIDs
        self.aiJobs = aiJobs
    }

    func savedState() -> SavedState {
        SavedState(version: 1, days: days, profile: profile, drafts: drafts, importedPlan: importedPlan, appliedAIJobs: appliedAIJobs, deletedExerciseIDs: deletedExerciseIDs, deletedMealIDs: deletedMealIDs, deletedMediaIDs: deletedMediaIDs, deletedAIJobIDs: deletedAIJobIDs, nutritionTarget: nutritionTarget)
    }
}

struct CloudStateEnvelope: Decodable {
    let revision: Int
    let state: CloudState?
    var unchanged: Bool?
    var media_cleanup_pending: Int?
}

struct CloudConflictEnvelope: Decodable {
    let revision: Int
    let state: CloudState?
}

struct CloudErrorEnvelope: Decodable {
    let error: String
}

struct LocalSyncEnvelope: Codable {
    var state: SavedState
    var base: CloudState?
    var cloudRevision: Int? = nil
    var journalSequence: Int? = nil
}

struct CloudStateUpload: Encodable {
    let base_revision: Int
    let state: CloudState
}

// Compare against the last cloud snapshot, so unchanged stale local values cannot
// overwrite edits made on another device. Concurrent edits of one field keep local.
enum CloudMerge {
    static func merge(local: CloudState, remote: CloudState, base: CloudState?) throws -> CloudState {
        let localValue = try JSONValue.encode(local)
        let remoteValue = try JSONValue.encode(remote)
        let baseValue = try base.map { try JSONValue.encode($0) }
        let combined = mergeValue(localValue, remoteValue, baseValue) ?? remoteValue
        var result = try JSONDecoder().decode(CloudState.self, from: JSONEncoder().encode(combined))
        let deletedExercises = Set((result.deletedExerciseIDs ?? []).map { $0.uppercased() })
        let deletedMeals = Set((result.deletedMealIDs ?? []).map { $0.uppercased() })
        for date in Array(result.days.keys) {
            result.days[date]?.exercises.removeAll { deletedExercises.contains($0.id.uuidString) }
            result.days[date]?.meals.removeAll { deletedMeals.contains($0.id.uuidString) }
            if var day = result.days[date] {
                for index in day.exercises.indices {
                    let deleted = Set((day.exercises[index].deletedSetIDs ?? []).map { $0.uppercased() })
                    day.exercises[index].sets.removeAll { deleted.contains($0.id.uuidString) }
                }
                if day.completedSets == 0 { day.linkedDeviceWorkoutID = nil }
                if let linked = day.linkedDeviceWorkoutID, day.health?.workouts.contains(where: { $0.id == linked }) != true {
                    day.linkedDeviceWorkoutID = nil
                }
                result.days[date] = day
            }
        }
        let archivedJobs = Set(result.deletedAIJobIDs ?? [])
        result.aiJobs?.removeAll { archivedJobs.contains($0.id) }
        return result
    }

    static func conflictCount(local: CloudState, remote: CloudState, base: CloudState?) throws -> Int {
        guard let base else { return 0 }
        func count(_ l: JSONValue?, _ r: JSONValue?, _ b: JSONValue?, key: String = "") -> Int {
            if l == r || l == b || r == b || key.hasPrefix("deleted") || key == "appliedAIJobs" || key == "aiJobs" { return 0 }
            if case .object(let left)? = l, case .object(let right)? = r {
                let baseline: [String: JSONValue]; if case .object(let value)? = b { baseline = value } else { baseline = [:] }
                return Set(left.keys).union(right.keys).reduce(0) { $0 + count(left[$1], right[$1], baseline[$1], key: $1) }
            }
            if ["exercises","sets","meals","drafts"].contains(key), case .array(let left)? = l, case .array(let right)? = r {
                let baseline: [JSONValue]; if case .array(let value)? = b { baseline = value } else { baseline = [] }
                let lm = indexed(left), rm = indexed(right), bm = indexed(baseline)
                return Set(lm.keys).union(rm.keys).reduce(0) { $0 + count(lm[$1],rm[$1],bm[$1]) }
            }
            return 1
        }
        return count(try JSONValue.encode(local), try JSONValue.encode(remote), try JSONValue.encode(base))
    }

    static func same<T: Encodable>(_ left: T, _ right: T) throws -> Bool {
        try JSONValue.encode(left) == JSONValue.encode(right)
    }

    private static func mergeValue(_ local: JSONValue?, _ remote: JSONValue?, _ base: JSONValue?, key: String = "") -> JSONValue? {
        let unions = ["appliedAIJobs", "deletedExerciseIDs", "deletedMealIDs", "deletedMediaIDs", "deletedAIJobIDs", "deletedSetIDs"]
        if unions.contains(key) {
            let l = strings(local); let r = strings(remote)
            return .array(Array(Set(l + r)).sorted().map { .string($0) })
        }
        if local == remote { return local }
        if local == base { return remote }
        if remote == base { return local }
        // Health summaries are indivisible observations, never merge metric fragments.
        if ["health", "weeklyReview", "bodyWeight"].contains(key), case .object(let l)? = local, case .object(let r)? = remote {
            if case .number(let lt)? = l["updatedAt"], case .number(let rt)? = r["updatedAt"] {
                return lt >= rt ? local : remote
            }
            return local
        }
        if case .object(let l)? = local, case .object(let r)? = remote {
            let b: [String: JSONValue]
            if case .object(let values)? = base { b = values } else { b = [:] }
            var output: [String: JSONValue] = [:]
            for field in Set(l.keys).union(r.keys).union(b.keys) {
                output[field] = mergeValue(l[field], r[field], b[field], key: field)
            }
            // A meal's values and known/unknown status form one observation, including manual meals.
            if l["category"] != nil, l["calories"] != nil {
                let nutritionKeys = ["components", "consumedFraction", "calories", "protein", "carbs", "fat", "nutritionKnown"]
                let source = nutritionKeys.allSatisfy { l[$0] == b[$0] } ? r : l
                for field in nutritionKeys { output[field] = source[field] }
            }
            return .object(output)
        }
        if ["exercises", "sets", "meals", "drafts", "aiJobs"].contains(key),
           case .array(let l)? = local, case .array(let r)? = remote {
            let b: [JSONValue]
            if case .array(let values)? = base { b = values } else { b = [] }
            let lm = indexed(l), rm = indexed(r), bm = indexed(b)
            var seen = Set<String>()
            let order = (r + l + b).compactMap(id).filter { seen.insert($0).inserted }
            return .array(order.compactMap { mergeValue(lm[$0], rm[$0], bm[$0]) })
        }
        // Deletion wins when the record was present at the common baseline.
        if base != nil && (local == nil || remote == nil) { return nil }
        return local ?? remote
    }

    private static func id(_ value: JSONValue) -> String? {
        guard case .object(let fields) = value else { return nil }
        return fields["id"]?.string
    }
    private static func indexed(_ values: [JSONValue]) -> [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        for value in values { if let key = id(value) { result[key] = value } }
        return result
    }
    private static func strings(_ value: JSONValue?) -> [String] {
        guard case .array(let values)? = value else { return [] }
        return values.compactMap(\.string)
    }
}

enum CloudSyncError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}


struct WeeklyReview: Codable { var id = UUID() }
func equipmentName(_ value: String) -> String { value }
func muscleName(_ value: String) -> String { value }
final class AppStore {
    var state = SavedState()
    var mediaDirectory = FileManager.default.temporaryDirectory
    func prepareMediaDirectory() throws { }

    var message: String?
    var editingAccountID: Int? = 1
    var allowPersistence = true
    var writtenDates: [String] = []
    var stableIDs: [String:UUID] = [:]
    func stableID(_ key: String) -> UUID {
        if let value = stableIDs[key] { return value }
        let value = UUID(); stableIDs[key] = value; return value
    }
    func persist(changedDates: [String]) -> Bool { writtenDates = changedDates; return allowPersistence }
    func log(for date: Date) -> DayLog { state.days[ClubDates.key(date)] ?? DayLog() }
    func saveProfile(_ profile: MemberProfile) -> Bool {
        let previous = state
        let today = ClubDates.key(Date())
        let oldTarget = state.nutritionTarget ?? NutritionTarget.estimate(state.profile)
        var frozen: [String] = []
        for key in state.days.keys.sorted() where key < today && state.days[key]?.nutritionTarget == nil {
            state.days[key]?.nutritionTarget = oldTarget
            frozen.append(key)
        }
        state.profile = profile
        state.nutritionTarget = NutritionTarget.estimate(profile)
        if persist(changedDates: frozen) { return true }; state = previous; return false
    }
    func saveWorkout(on date: Date) -> Bool {
        guard !ClubDates.isFuture(date) else { message = "未来训练只能保存计划，不能确认完成。"; return false }
        guard log(for: date).completedSets > 0 else { message = "至少完成一组后才能确认本次训练。"; return false }
        guard mutate(date, edit: {
            $0.workoutSavedAt = Date()
            if $0.workoutStartedAt != nil && $0.workoutEndedAt == nil && Calendar.current.isDateInToday(date) {
                $0.workoutEndedAt = Date()
            }
        }) else { return false }
        return true
    }
    func saveHealth(_ summary: HealthDay, on date: Date) -> Bool {
        guard summary.date == ClubDates.key(date) else { return false }
        var shared = summary
        shared.steps?.availableSources = nil; shared.activeEnergy?.availableSources = nil
        shared.heartRate?.availableSources = nil; shared.restingHeartRate?.availableSources = nil; shared.sleep?.availableSources = nil
        return mutate(date) {
            $0.health = shared
            if let linked = $0.linkedDeviceWorkoutID, !shared.workouts.contains(where: { $0.id == linked }) {
                $0.linkedDeviceWorkoutID = nil
            }
        }
    }
    func removeHealth(on date: Date) -> Bool { mutate(date) { $0.health = nil; $0.linkedDeviceWorkoutID = nil } }
    func updateSet(_ set: TrainingSet, exerciseID: UUID, on date: Date) -> Bool {
        guard !set.completed || !ClubDates.isFuture(date) else { message = "未来日期只能安排训练，到了当天才能勾选完成。"; return false }
        let autoStart = set.validCompletion && Calendar.current.isDateInToday(date) && log(for: date).workoutStartedAt == nil
        return mutate(date) { log in
            guard let exerciseIndex = log.exercises.firstIndex(where: { $0.id == exerciseID }),
                  let setIndex = log.exercises[exerciseIndex].sets.firstIndex(where: { $0.id == set.id }) else { return }
            var clean = set
            clean.weight = clean.weight.isFinite ? min(max(0, clean.weight), 2000) : 0
            clean.reps = min(max(0, clean.reps), 1000)
            clean.durationSeconds = clean.durationSeconds.map { min(max(0, $0), 3600) }
            if clean.durationSeconds != nil { clean.reps = 0 }
            if !(clean.durationSeconds.map { $0 > 0 } ?? (clean.reps > 0)) { clean.completed = false }
            if autoStart && clean.validCompletion { log.workoutStartedAt = Date(); log.workoutEndedAt = nil }
            if clean.validCompletion && !log.exercises[exerciseIndex].sets[setIndex].validCompletion { log.workoutEndedAt = nil }
            if log.exercises[exerciseIndex].sets[setIndex].completed != clean.completed || log.exercises[exerciseIndex].sets[setIndex].weight != clean.weight || log.exercises[exerciseIndex].sets[setIndex].reps != clean.reps || log.exercises[exerciseIndex].sets[setIndex].durationSeconds != clean.durationSeconds { log.workoutSavedAt = nil }
            log.exercises[exerciseIndex].sets[setIndex] = clean
        }
    }
    func removeSet(_ setID: UUID, exerciseID: UUID, on date: Date) {
        mutate(date) { log in
            guard let index = log.exercises.firstIndex(where: { $0.id == exerciseID }) else { return }
            log.workoutSavedAt = nil
            log.exercises[index].sets.removeAll { $0.id == setID }
            log.exercises[index].deletedSetIDs = Array(Set((log.exercises[index].deletedSetIDs ?? []) + [setID.uuidString])).sorted()
        }
    }
    func removeExercise(_ id: UUID, on date: Date) -> Bool {
        let previous = state
        state.days[ClubDates.key(date)]?.workoutSavedAt = nil
        state.days[ClubDates.key(date)]?.exercises.removeAll { $0.id == id }
        state.deletedExerciseIDs = Array(Set((state.deletedExerciseIDs ?? []) + [id.uuidString])).sorted()
        if state.days[ClubDates.key(date)]?.completedSets == 0 { state.days[ClubDates.key(date)]?.linkedDeviceWorkoutID = nil }
        if state.days[ClubDates.key(date)]?.exercises.isEmpty == true {
            state.days[ClubDates.key(date)]?.workoutStartedAt = nil
            state.days[ClubDates.key(date)]?.workoutEndedAt = nil
            state.days[ClubDates.key(date)]?.linkedDeviceWorkoutID = nil
        }
        if persist(changedDates: [ClubDates.key(date)]) { return true }
        state = previous; return false
    }
    func hasAppliedAIJob(_ id: String) -> Bool { state.appliedAIJobs?.contains(id) == true }
    func mutate(_ date: Date, edit: (inout DayLog) -> Void) -> Bool {
        let previous = state
        let key = ClubDates.key(date)
        var log = state.days[key] ?? DayLog()
        edit(&log)
        if log.completedSets == 0 { log.linkedDeviceWorkoutID = nil }
        state.days[key] = log
        guard persist(changedDates: [key]) else { state = previous; return false }
        return true
    }
}

extension AppStore {
    func nutritionTarget(on date: Date) -> NutritionTarget? {
        log(for: date).nutritionTarget ?? state.nutritionTarget
    }

    @discardableResult
    func beginWorkout(on date: Date) -> Bool {
        let day = log(for: date)
        guard Calendar.current.isDateInToday(date), !day.exercises.isEmpty,
              day.workoutStartedAt == nil, day.completedSets == 0, day.workoutSavedAt == nil else { return false }
        return mutate(date) { $0.workoutStartedAt = Date(); $0.workoutEndedAt = nil }
    }

    @discardableResult
    func replaceExercise(_ original: Exercise, with item: LibraryExercise, on date: Date) -> Bool {
        let current = log(for: date)
        guard let existing = current.exercises.first(where: { $0.id == original.id }),
              (try? CloudMerge.same(existing, original)) == true else { message = WorkoutEditError.changed.localizedDescription; return false }
        guard existing.libraryID != item.id else { message = "请选择另一个动作。"; return false }
        let replacement = Exercise(name: String(item.displayName.prefix(100)), muscle: item.muscleLabel,
                                   libraryID: item.id, equipment: item.equipmentLabel, imageURL: item.imageURL,
                                   gifURL: item.gifURL, libraryQuery: item.name)
        do {
            let updated = try WorkoutEditing.replacing(original, with: replacement, in: current)
            let previous = state
            if !original.sets.contains(where: \.validCompletion) {
                state.deletedExerciseIDs = Array(Set((state.deletedExerciseIDs ?? []) + [original.id.uuidString])).sorted()
            }
            state.days[ClubDates.key(date)] = updated
            if persist(changedDates: [ClubDates.key(date)]) { return true }
            state = previous; return false
        } catch { message = error.localizedDescription; return false }
    }

    @discardableResult
    func linkDeviceWorkout(_ id: String?, on date: Date) -> Bool {
        let day = log(for: date)
        if let id {
            guard day.completedSets > 0, day.health?.workouts.contains(where: { $0.id == id }) == true else {
                message = "请先确认分享该日健康汇总，并至少记录一组已完成训练。"; return false
            }
        }
        return mutate(date) { $0.linkedDeviceWorkoutID = id }
    }
}


extension AppStore {
    @discardableResult
    func applyProfilePlan(_ result: AIResult, jobID: String, start: Date) -> Bool {
        if hasAppliedAIJob(jobID) { return true }
        let startDay = ClubDates.calendar.startOfDay(for: start)
        guard startDay > ClubDates.calendar.startOfDay(for: Date()),
              result.kind == "plan", let sessions = result.sessions, !sessions.isEmpty else {
            message = "更新计划必须从未来日期开始，请重新选择起始日。"; return false
        }
        let dates = (0..<7).compactMap { ClubDates.calendar.date(byAdding: .day, value: $0, to: startDay) }.map(ClubDates.key)
        let window = Set(dates)
        let expectedDates = Set(dates.filter { key in
            guard let date = ClubDates.date(fromKey: key) else { return false }
            let weekday = (ClubDates.calendar.component(.weekday, from: date) + 5) % 7 + 1
            return (state.profile.trainingDays ?? []).contains(weekday)
        })
        guard !expectedDates.isEmpty, Set(sessions.map(\.date)) == expectedDates,
              Set(sessions.map(\.date)).count == sessions.count,
              sessions.allSatisfy({ session in
                  guard let dayDate = ClubDates.date(fromKey: session.date) else { return false }
                  let weekday = (ClubDates.calendar.component(.weekday, from: dayDate) + 5) % 7 + 1
                  return window.contains(session.date) && (state.profile.trainingDays ?? []).contains(weekday) &&
                    !session.exercises.isEmpty && session.exercises.count <= 30 && session.exercises.allSatisfy { exercise in
                        !exercise.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !exercise.sets.isEmpty && exercise.sets.count <= 50 &&
                        exercise.sets.allSatisfy { set in
                            let weight = set.weight ?? 0
                            return weight.isFinite && (0...2000).contains(weight) &&
                                (set.durationSeconds.map { (1...3600).contains($0) } ?? (1...1000).contains(set.reps))
                        }
                    }
              }) else { message = "新方案的日期或训练组不完整，请重新生成。"; return false }
        let previous = state
        for key in dates {
            var day = state.days[key] ?? DayLog()
            guard !WorkoutEditing.isProtected(day) else { continue }
            state.deletedExerciseIDs = Array(Set((state.deletedExerciseIDs ?? []) + day.exercises.map { $0.id.uuidString })).sorted()
            day.exercises = []
            day.workoutSavedAt = nil; day.linkedDeviceWorkoutID = nil; day.workoutEndedAt = nil
            if let session = sessions.first(where: { $0.date == key }) {
                day.exercises = session.exercises.enumerated().map { i, exercise in
                    let prefix = "\(jobID)/\(key)/\(i)"
                    return Exercise(id: stableID(prefix), name: exercise.name, muscle: exercise.muscle,
                                    sets: exercise.sets.enumerated().map { j, set in
                                        TrainingSet(id: stableID("\(prefix)/\(j)"), weight: set.durationSeconds == nil ? (set.weight ?? 0) : 0,
                                                    reps: set.durationSeconds == nil ? set.reps : 0, durationSeconds: set.durationSeconds)
                                    }, libraryID: exercise.library_id, libraryQuery: exercise.library_query)
                }
            }
            // Rest days still retain all meals, health observations and reviews.
            state.days[key] = day
        }
        state.appliedAIJobs = (state.appliedAIJobs ?? []) + [jobID]
        if persist(changedDates: dates) { return true }
        state = previous; return false
    }
}

extension AppStore {
    @discardableResult
    func saveBodyWeight(_ kilograms: Double?, on date: Date, now: Date = Date()) -> Bool {
        guard ClubDates.calendar.startOfDay(for: date) <= ClubDates.calendar.startOfDay(for: now),
              kilograms.map({ $0.isFinite && (20...400).contains($0) }) ?? true else {
            message = "请选择今天或过去的日期，体重范围为 20–400 kg。"; return false
        }
        let value = kilograms.map { ($0 * 10).rounded() / 10 }
        return mutate(date) { $0.bodyWeight = BodyWeightEntry(kilograms: value, updatedAt: now) }
    }
    func bodyWeightPoints(through date: Date, limit: Int = 30) -> [BodyWeightPoint] {
        BodyWeightHistory.points(days: state.days, through: date, limit: limit)
    }
}


var checks = 0
func check(_ value: Bool, _ label: String) {
    guard value else { fatalError("FAILED: \(label)") }
    checks += 1; print("PASS \(label)")
}
func rejected(_ label: String, _ operation: () throws -> Void) {
    do { try operation(); fatalError("FAILED: \(label)") } catch { check(true,label) }
}
let now = Date()
let today = ClubDates.key(now)
let yesterday = ClubDates.calendar.date(byAdding:.day,value:-1,to:now)!
let tomorrow = ClubDates.calendar.date(byAdding:.day,value:1,to:now)!
let finished = TrainingSet(weight:30,reps:8,completed:true)
let pending = TrainingSet(weight:60,reps:12)
let old = Exercise(name:"卧推",muscle:"胸",sets:[finished,pending],libraryID:"old")
let replacement = Exercise(name:"俯卧撑",muscle:"胸")
let partial = DayLog(exercises:[old],workoutSavedAt:now)
let replaced = try WorkoutEditing.replacing(old,with:replacement,in:partial)
check(replaced.exercises.count == 2,"partial replacement keeps completed exercise")
check(replaced.exercises[0].sets[0].id == finished.id,"completed set identity retained")
check(replaced.exercises[0].sets[0].weight == 30 && replaced.exercises[0].name == "卧推","recorded movement and load retained")
check(replaced.exercises[1].sets.count == 1 && replaced.exercises[1].sets[0].weight == 0,"new movement load reset")
check(!replaced.exercises[1].sets[0].completed,"new movement is uncompleted")
check(replaced.workoutSavedAt == nil,"new workout confirmation required")
check(replaced.exercises[0].deletedSetIDs == [pending.id.uuidString],"removed pending set has tombstone")
var unstarted=old;unstarted.sets=[pending]
let one=try WorkoutEditing.replacing(unstarted,with:replacement,in:DayLog(exercises:[unstarted]))
check(one.exercises.count == 1 && one.exercises[0].id != old.id,"unstarted replacement creates one new movement")
var allDone=old;allDone.sets=[finished]
rejected("completed movement cannot be overwritten") { _=try WorkoutEditing.replacing(allDone,with:replacement,in:DayLog(exercises:[allDone])) }
rejected("missing original rejected") { _=try WorkoutEditing.replacing(old,with:replacement,in:DayLog()) }
let full=DayLog(exercises:[old]+(0..<29).map { _ in replacement })
rejected("daily movement limit respected") { _=try WorkoutEditing.replacing(old,with:replacement,in:full) }
check(WorkoutEditing.isProtected(partial),"confirmed day protected")
check(WorkoutEditing.isProtected(DayLog(exercises:[unstarted],workoutStartedAt:now)),"started day protected")
check(!WorkoutEditing.isProtected(DayLog(exercises:[unstarted])),"unstarted day editable")

let a=HealthSource(id:"watch",name:"Watch"), b=HealthSource(id:"sync",name:"Sync")
let start=now.addingTimeInterval(-3600)
let watch=DeviceWorkout(id:"watch-1",name:"力量训练",start:start,end:now,minutes:60,calories:200,source:a,activityKind:"strength")
var mirror=watch;mirror.id="mirror";mirror.source=b
check(HealthDay.deduplicated([mirror,watch],preferred:"watch").map(\.id) == ["watch-1"],"same activity across sources deduplicated")
var other=mirror;other.activityKind="running";other.name="跑步"
check(HealthDay.deduplicated([watch,other],preferred:"").count == 2,"overlapping different activities preserved")
var same=watch;same.id="watch-2"
check(HealthDay.deduplicated([watch,same],preferred:"").count == 2,"two records from one source preserved")
var unknown=mirror;unknown.activityKind=nil;unknown.name="运动"
check(HealthDay.deduplicated([watch,unknown],preferred:"").count == 2,"unknown activity not silently deleted")
check(HealthDay.deduplicated([watch,watch],preferred:"").count == 1,"same record ID deduplicates")
let session=DayLog(exercises:[old],workoutStartedAt:start,workoutEndedAt:now)
check(WorkoutAssociation.suggestedIDs(for:session,workouts:[watch,other]) == [watch.id],"only matching strength session suggested")
check(WorkoutAssociation.suggestedIDs(for:DayLog(),workouts:[watch]).isEmpty,"missing start time never guessed")
let abandoned=DayLog(workoutStartedAt:now.addingTimeInterval(-8*3600),workoutEndedAt:now)
check(WorkoutAssociation.suggestedIDs(for:abandoned,workouts:[watch]).isEmpty,"abandoned start cannot produce confident match")
let legacy=try JSONDecoder().decode(DayLog.self,from:Data("{\"exercises\":[],\"meals\":[]}".utf8))
check(legacy.workoutStartedAt == nil && legacy.nutritionTarget == nil,"old day decodes")
var legacyWatch=try JSONSerialization.jsonObject(with:JSONEncoder().encode(watch)) as! [String:Any]
legacyWatch.removeValue(forKey:"activityKind");legacyWatch.removeValue(forKey:"averageHeartRate")
let decoded=try JSONDecoder().decode(DeviceWorkout.self,from:JSONSerialization.data(withJSONObject:legacyWatch))
check(decoded.averageHeartRate == nil && decoded.comparableKind == "strength","old device data has no invented heart rate")

var local=SavedState();local.days[today]=replaced
var remote=SavedState();remote.days[today]=partial
let merged=try CloudMerge.merge(local:CloudState(local),remote:CloudState(remote),base:nil)
check(merged.days[today]!.exercises.flatMap(\.sets).allSatisfy { $0.id != pending.id },"stale first sync cannot resurrect removed pending set")
check(merged.days[today]!.completedSets == 1,"cloud merge preserves completed set")

let store=AppStore();store.state.days[ClubDates.key(yesterday)]=partial
store.state.nutritionTarget=NutritionTarget.estimate(store.state.profile)
let oldTarget=store.state.nutritionTarget!
var profile=store.state.profile;profile.weight=90;profile.trainingDays=[1,3,5]
check(store.saveProfile(profile),"profile save succeeds")
check(store.state.profile.weight == 90 && store.state.nutritionTarget != oldTarget,"profile updates current target")
check(store.nutritionTarget(on:yesterday) == oldTarget,"historical target retained")
check(store.writtenDates.contains(ClubDates.key(yesterday)),"historical target included in journal")
let before=store.state;store.allowPersistence=false;profile.weight=100
check(!store.saveProfile(profile),"failed profile save reported")
check(try CloudMerge.same(before,store.state),"failed profile save rolls back")
store.allowPersistence=true
check(!store.beginWorkout(on:yesterday),"historical record never gets current start")
store.state.days[today]=DayLog(exercises:[unstarted])
check(store.beginWorkout(on:now),"explicit start recorded")
let recordedStart=store.log(for:now).workoutStartedAt
check(!store.beginWorkout(on:now) && store.log(for:now).workoutStartedAt == recordedStart,"repeated start does not reset time")
check(!store.saveWorkout(on:now),"zero completed sets cannot be confirmed")
store.state.days[today]=session
check(store.saveWorkout(on:now),"completed session saves")
let recordedEnd=store.log(for:now).workoutEndedAt
check(store.saveWorkout(on:now) && store.log(for:now).workoutEndedAt == recordedEnd,"resave does not move workout end")
let health=HealthDay(date:today,timeZone:"Asia/Shanghai",updatedAt:now,workouts:[watch])
check(!store.linkDeviceWorkout(watch.id,on:now),"local-only health cannot be implicitly uploaded by link")
check(store.saveHealth(health,on:now),"confirmed health saves")
check(store.linkDeviceWorkout(watch.id,on:now),"explicit existing link saves")
check(!store.linkDeviceWorkout("unknown",on:now),"missing device ID rejected")
var emptyHealth=health;emptyHealth.workouts=[]
check(store.saveHealth(emptyHealth,on:now) && store.log(for:now).linkedDeviceWorkoutID == nil,"disappeared shared workout clears link")
_=store.saveHealth(health,on:now);_=store.linkDeviceWorkout(watch.id,on:now)
var undone=finished;undone.completed=false
check(store.updateSet(undone,exerciseID:old.id,on:now) && store.log(for:now).linkedDeviceWorkoutID == nil,"undo last completion clears link")

let planning=AppStore();planning.state.profile.trainingDays=[(ClubDates.calendar.component(.weekday,from:tomorrow)+5)%7+1]
let keys=(0..<7).map { ClubDates.key(ClubDates.calendar.date(byAdding:.day,value:$0,to:tomorrow)!) }
for key in keys { planning.state.days[key]=DayLog(exercises:[unstarted]) }
planning.state.days[keys[1]]=DayLog(exercises:[old],workoutSavedAt:now)
planning.state.days[keys[2]]=DayLog(exercises:[unstarted],workoutStartedAt:now)
planning.state.days[keys[3]]!.meals=[Meal(name:"test",category:"午餐",calories:100,protein:10,carbs:10,fat:2)]
let newSession=AIPlanSession(date:keys[0],label:"new",exercises:[AIPlanExercise(name:"深蹲",muscle:"腿",sets:[AIPlanSet(weight:20,reps:8)],library_query:nil)])
let plan=AIResult(kind:"plan",notes:[],sessions:[newSession])
check(planning.applyProfilePlan(plan,jobID:"profile",start:tomorrow),"whole selected profile week updates")
check(planning.state.days[keys[0]]!.exercises.first!.name == "深蹲","planned day replaced")
check(planning.state.days[keys[3]]!.exercises.isEmpty,"removed training day becomes rest")
check(planning.state.days[keys[3]]!.meals.count == 1,"rest-day update preserves meals")
check(planning.state.days[keys[1]]!.completedSets == 1,"completed day retained during replan")
check(planning.state.days[keys[2]]!.exercises.first!.name == unstarted.name,"started day retained during replan")
let appliedState=planning.state
check(planning.applyProfilePlan(plan,jobID:"profile",start:tomorrow),"same plan reapply succeeds")
check(try CloudMerge.same(appliedState,planning.state),"same plan reapply is idempotent")
let failed=AppStore();failed.state.profile.trainingDays=planning.state.profile.trainingDays;failed.allowPersistence=false
let failedBefore=failed.state
check(!failed.applyProfilePlan(plan,jobID:"fail",start:tomorrow),"plan persistence failure reported")
check(try CloudMerge.same(failedBefore,failed.state),"plan persistence failure rolls back all days and tombstones")
check(!planning.applyProfilePlan(plan,jobID:"past",start:yesterday),"profile plan cannot replace past")
var duplicate=plan;duplicate.sessions=[newSession,newSession]
check(!planning.applyProfilePlan(duplicate,jobID:"dup",start:tomorrow),"duplicate plan dates rejected")
print("PASS \(checks) production Swift rule checks; UIKit/HealthKit need Xcode/iPhone")

final class ReportInputBuilder {
    func reportInput(date: Date, log: DayLog, nutritionTarget: NutritionTarget? = nil, weightHistory: [BodyWeightPoint] = []) throws -> AIInput {
        guard !ClubDates.isFuture(date) else { throw AIClientError.message("未来日期还没有实际记录，到了当天才能生成日报。") }
        guard log.exercises.count <= 30, log.meals.count <= 50, log.exercises.allSatisfy({ $0.sets.count <= 50 }) else {
            throw AIClientError.message("这一天的记录超过分析范围（30 个动作、每动作 50 组、50 餐），请精简重复记录后再生成。")
        }
        let exercises: [JSONValue] = log.exercises.map { exercise in
            .object(["name": .string(String(exercise.name.prefix(100))), "sets": .array(exercise.sets.map {
                .object(["weight": .number($0.weight), "reps": .number(Double($0.reps)), "completed": .bool($0.validCompletion), "durationSeconds": $0.durationSeconds.map { .number(Double($0)) } ?? .null])
            })])
        }
        let meals: [JSONValue] = log.meals.map {
            .object(["name": .string(String($0.name.prefix(100))), "nutrition_known": .bool($0.hasNutrition), "calories": .number($0.calories), "protein": .number($0.protein),
                     "carbs": .number($0.carbs), "fat": .number($0.fat)])
        }
        var payload: [String: JSONValue] = ["exercises": .array(exercises), "meals": .array(meals)]
        if let entry = log.bodyWeight, entry.isValid, let kg = entry.kilograms {
            payload["body_weight_kg"] = .number(kg)
        }
        if !weightHistory.isEmpty {
            payload["body_weight_history"] = .array(weightHistory.suffix(30).map {
                .object(["date": .string(ClubDates.key($0.date)), "kilograms": .number($0.kilograms)])
            })
        }
        if let target = log.nutritionTarget ?? nutritionTarget { payload["nutritionTarget"] = try .encode(target) }
        if let summary = log.health, summary.hasData {
            payload["health"] = try JSONValue.encode(summary)
            if log.completedSets > 0, let linked = log.linkedDeviceWorkoutID, summary.workouts.contains(where: { $0.id == linked }) {
                payload["workout_link"] = .object(["device_workout_id": .string(linked), "confirmed_by_user": .bool(true)])
            }
            payload["health_interpretation"] = .string("健康数据为用户确认分享的日汇总；时间为当地自然日，sleep单位小时，心率bpm，热量kcal。空值代表未知，不是0。每项取一个数据来源，不跨来源累加。运动列表按开始日归属，运动热量可能包含在全天活动能量中，不能相加，也不能把力量总训练量当成热量。睡眠为当日0点至24点区间并集，不一定是完整一夜。只作健身建议，不作医疗诊断。注意更新时间和数据覆盖范围。")
        }
        payload["analysis_version"] = .number(2)
        return AIInput(kind: "report", date: ClubDates.key(date), payload: payload)
    }
}

func validateBackupValue(_ value: JSONValue, key: String = "") throws {
    switch value {
    case .number(let number):
        let dates = ["created", "createdAt", "updatedAt", "start", "end", "workoutSavedAt", "workoutStartedAt", "workoutEndedAt"]
        let valid = dates.contains(key) ? (-978307200.0...10000000000.0).contains(number) : (0.0...10000000.0).contains(number)
        guard number.isFinite, valid else { throw CloudSyncError.message("备份包含不支持的数值。") }
    case .string(let text):
        guard text.count <= 20000 else { throw CloudSyncError.message("备份中的文字过长。") }
    case .array(let values):
        guard values.count <= 20000 else { throw CloudSyncError.message("备份中的列表过长。") }
        for child in values { try validateBackupValue(child, key: key) }
    case .object(let fields):
        for (name, child) in fields {
            guard name.count <= 200 else { throw CloudSyncError.message("备份标识不正确。") }
            try validateBackupValue(child, key: name)
        }
    case .bool, .null: break
    }
}


struct MealEditorDraft: Codable {
    var id: UUID
    var name: String
    var category: String
    var calories: Double
    var protein: Double
    var carbs: Double
    var fat: Double
    var components: [FoodComponent]
    var fraction: Double
    var jobID: String?
    var sourceJobID: String?
    var estimateNotes: [String]
    var photoAttached: Bool? = nil
    var updatedAt: Date? = nil
}

private struct MealDraftChoice: Identifiable {
    let draft: MealEditorDraft
    let file: URL
    var id: UUID { draft.id }
}


let phaseTwoStart = checks
let legacyDraft = Data(#"{"id":"550E8400-E29B-41D4-A716-446655440000","name":"meal","category":"早餐","calories":100,"protein":10,"carbs":10,"fat":2,"components":[],"fraction":1,"estimateNotes":[]}"#.utf8)
var decodedDraft = try JSONDecoder().decode(MealEditorDraft.self,from:legacyDraft)
check(decodedDraft.photoAttached == nil,"old meal drafts retain legacy photo lookup")
decodedDraft.photoAttached = false
let retakeDraft = try JSONDecoder().decode(MealEditorDraft.self,from:JSONEncoder().encode(decodedDraft))
check(retakeDraft.photoAttached == false,"cleared draft explicitly prevents stale photo recovery")
let backupDay = DayLog(workoutStartedAt:now,workoutEndedAt:now,bodyWeight:BodyWeightEntry(kilograms:68,updatedAt:now))
try validateBackupValue(JSONValue.encode(backupDay))
check(true,"month backup accepts new workout and weight timestamps")
rejected("backup still rejects oversized non-timestamp values") { try validateBackupValue(.number(812000000),key:"calories") }
let fixedDate = ClubDates.date(fromKey:"2026-10-04")!
func time(_ hour: Int, _ minute: Int = 0) -> Date {
    ClubDates.calendar.date(bySettingHour:hour,minute:minute,second:0,of:fixedDate)!
}
func meal(_ category: String) -> Meal { Meal(name:"fixture",category:category,calories:100,protein:10,carbs:10,fat:2) }
for (hour,expected) in [(4,"加餐"),(5,"早餐"),(9,"早餐"),(10,"午餐"),(14,"午餐"),(15,"加餐"),(16,"加餐"),(17,"晚餐"),(21,"晚餐"),(22,"加餐")] {
    check(MealCategorySuggestion.recommended(for:fixedDate,now:time(hour),meals:[]) == expected,"meal boundary \(hour)")
}
check(MealCategorySuggestion.recommended(for:fixedDate,now:time(8),meals:[meal("早餐")]) == "加餐","already recorded breakfast suggests snack")
check(MealCategorySuggestion.recommended(for:fixedDate,now:time(8),meals:[meal("加餐")]) == "早餐","snack does not block breakfast")
let priorDate = ClubDates.date(fromKey:"2026-10-03")!
check(MealCategorySuggestion.recommended(for:priorDate,now:time(20),meals:[]) == "早餐","historical record does not infer current dinner")
check(MealCategorySuggestion.recommended(for:priorDate,now:time(20),meals:[meal("早餐")]) == "午餐","historical suggestion chooses unrecorded main meal")
let boundaryCenter = ClubDates.date(fromKey:"2026-10-01")!
let centered = CalendarWindow.dates(centeredOn:boundaryCenter)
check(centered.count == 7 && ClubDates.key(centered[3]) == "2026-10-01","selected date is calendar center")
check(ClubDates.key(centered[0]) == "2026-09-28" && ClubDates.key(centered[6]) == "2026-10-04","calendar crosses month safely")
var dst = Calendar(identifier:.gregorian);dst.timeZone = TimeZone(identifier:"America/New_York")!
let dstCenter = dst.date(from:DateComponents(year:2026,month:3,day:8,hour:12))!
let dstWindow = CalendarWindow.dates(centeredOn:dstCenter,calendar:dst)
check(dstWindow.count == 7 && Set(dstWindow.map { dst.component(.day,from:$0) }).count == 7,"calendar DST dates remain distinct")
for name in ["plank","weighted side plank","wall sit","dead hang","hamstring stretch","stationary bike","rowing machine","平板支撑","靠墙静蹲","股四头肌拉伸","run","farmers walk","walking on stepmill","hands bike","short stride run"] {
    check(ExerciseMeasurement.usesSeconds(name:name),"timed default: \(name)")
}
for name in ["dumbbell row","push-up","plank jack","side plank hip raise","plank shoulder tap","平板支撑抬腿","侧平板转体","卧推","深蹲","kneeling plank tap shoulder (male)","push-up to side plank","isometric wipers","wheel run","power point plank"] {
    check(!ExerciseMeasurement.usesSeconds(name:name),"reps default: \(name)")
}
let timedBlank = ExerciseMeasurement.blankSet(name:"plank")
check(timedBlank.durationSeconds == 30 && timedBlank.reps == 0 && timedBlank.weight == 0 && !timedBlank.completed,"timed new sets start empty and uncompleted")
let timedStore = AppStore()
let loadedTimed = Exercise(name:"farmers walk",muscle:"全身",sets:[TrainingSet(weight:20,reps:0,completed:true,durationSeconds:60)])
timedStore.state.days[today] = DayLog(exercises:[loadedTimed])
check(timedStore.updateSet(loadedTimed.sets[0],exerciseID:loadedTimed.id,on:now),"timed load editing saves")
check(timedStore.log(for:now).exercises[0].sets[0].weight == 20 && timedStore.log(for:now).volume == 0,"timed load preserved without inventing reps volume")
let timedReplacement = Exercise(name:"平板支撑",muscle:"核心",libraryQuery:"plank")
let replacedTimed = try WorkoutEditing.replacing(old,with:timedReplacement,in:partial)
check(replacedTimed.exercises[1].sets.allSatisfy { $0.durationSeconds == 30 && !$0.completed },"replacement adopts timed defaults")
check(try CloudMerge.same(replacedTimed.exercises[0].sets,old.sets.filter(\.validCompletion)),"timed replacement preserves old completed values")
let weights = AppStore(); let originalProfile = weights.state.profile
check(weights.saveBodyWeight(68.26,on:now),"daily weight saves")
check(weights.log(for:now).bodyWeight?.kilograms == 68.3,"weight rounds to one decimal")
check(weights.state.profile == originalProfile,"daily weight does not rewrite profile or plan")
check(!weights.saveBodyWeight(68,on:tomorrow),"future measurement rejected")
check(!weights.saveBodyWeight(Double.nan,on:now),"invalid numeric weight rejected")
let savedWeightState = weights.state; weights.allowPersistence = false
check(!weights.saveBodyWeight(69,on:now),"failed weight persistence reported")
check(try CloudMerge.same(weights.state,savedWeightState),"failed weight save rolls back")
weights.allowPersistence = true
check(weights.saveBodyWeight(68,on:yesterday),"missed date can be recorded")
check(weights.bodyWeightPoints(through:now).count == 2,"history contains actual measurements only")
check(weights.bodyWeightPoints(through:yesterday).count == 1,"historical AI excludes later measurements")
check(weights.saveBodyWeight(nil,on:now),"weight delete saves tombstone")
check(weights.bodyWeightPoints(through:now).count == 1 && weights.log(for:now).bodyWeight?.updatedAt != nil,"deleted date is absent from chart but keeps deletion timestamp")
var remoteWeight = SavedState();remoteWeight.days[today] = DayLog(bodyWeight:BodyWeightEntry(kilograms:70,updatedAt:now.addingTimeInterval(-60)))
let mergedDelete = try CloudMerge.merge(local:CloudState(weights.state),remote:CloudState(remoteWeight),base:nil)
check(mergedDelete.days[today]?.bodyWeight?.kilograms == nil,"stale first sync cannot resurrect deleted weight")
var left = remoteWeight;var right = remoteWeight
left.days[today]?.bodyWeight = BodyWeightEntry(kilograms:71,updatedAt:now)
right.days[today]?.bodyWeight = BodyWeightEntry(kilograms:72,updatedAt:now.addingTimeInterval(1))
let atomicWeight = try CloudMerge.merge(local:CloudState(left),remote:CloudState(right),base:CloudState(remoteWeight))
check(atomicWeight.days[today]?.bodyWeight == right.days[today]?.bodyWeight,"concurrent weight value and timestamp stay together")
let oldDay = try JSONDecoder().decode(DayLog.self,from:Data(#"{"exercises":[],"meals":[]}"#.utf8))
check(oldDay.bodyWeight == nil,"legacy day has no invented weight")
let builder = ReportInputBuilder()
let measuredInput = try builder.reportInput(date:yesterday,log:weights.log(for:yesterday),weightHistory:weights.bodyWeightPoints(through:yesterday))
check(measuredInput.payload["body_weight_kg"] == .number(68),"AI receives actual measured weight")
check(measuredInput.payload["body_weight_history"] != nil,"AI receives sparse date-stamped history")
let deletedInput = try builder.reportInput(date:now,log:weights.log(for:now),weightHistory:weights.bodyWeightPoints(through:now))
check(deletedInput.payload["body_weight_kg"] == nil && deletedInput.payload["body_weight_history"] != nil,"missing today weight is not filled from prior date")
print("PASS \(checks-phaseTwoStart) phase2 production Swift rule checks")
if CommandLine.arguments.count > 1 {
    let rows = try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [[String:String]]
    let classifications = rows.map { row in ["id":row["id"]!,"name":row["name"]!,"unit":ExerciseMeasurement.usesSeconds(name:row["name"]!) ? "seconds" : "reps"] }
    try JSONSerialization.data(withJSONObject:classifications,options:[.sortedKeys,.prettyPrinted]).write(to:URL(fileURLWithPath:"movement-measurements-v19.json"))
    print("CLASSIFIED \(rows.count) exercise catalog entries")
}

struct ClubSeason: Decodable, Identifiable {
    let id: Int
    let slug: String
    let title: String
    let subtitle: String
    let officialNote: String
    let rules: String
    let startsOn: String
    let endsOn: String
    let joinDeadline: String
    let accessMode: String

    enum CodingKeys: String, CodingKey {
        case id, slug, title, subtitle, rules
        case officialNote = "official_note"
        case startsOn = "starts_on"
        case endsOn = "ends_on"
        case joinDeadline = "join_deadline"
        case accessMode = "access_mode"
    }
}

struct ClubSeasonTask: Decodable, Identifiable {
    let id: Int
    let title: String
    let detail: String
    let metric: String
    let target: Int
    let current: Int
    let completed: Bool
}

struct ClubSeasonReward: Decodable, Identifiable {
    let id: Int
    let title: String
    let detail: String
    let type: String
    let icon: String
    let unlocked: Bool
    let claimStatus: String?
    let trackingCompany: String?
    let trackingNumber: String?
    var taskID: Int? = nil
    var unlockScope: String? = nil
    var shippedAt: String? = nil
    var imagePath: String? = nil
    var claimDeadline: String? = nil
    var maxPerUser: Int? = nil
    var blockedByOtherClaim: Bool? = nil
    var typeLabel: String {
        switch type { case "physical": return "实物纪念品"; case "title": return "成员称号"; default: return "电子徽章" }
    }
    var canClaim: Bool {
        type == "physical" && unlocked && blockedByOtherClaim != true && (claimStatus == nil || claimStatus == "cancelled") && (claimDeadline == nil || ClubDates.key(Date()) <= claimDeadline!)
    }

    enum CodingKeys: String, CodingKey {
        case id, title, detail, type, icon, unlocked
        case taskID = "task_id", unlockScope = "unlock_scope"
        case claimStatus = "claim_status"
        case trackingCompany = "tracking_company"
        case trackingNumber = "tracking_number"
        case shippedAt = "shipped_at"
        case blockedByOtherClaim = "blocked_by_other_claim"
        case imagePath = "image_path", claimDeadline = "claim_deadline", maxPerUser = "max_per_user"
    }
}

struct ClubSeasonEnvelope: Decodable {
    let season: ClubSeason?
    let joined: Bool?
    let joinedAt: String?
    let tasks: [ClubSeasonTask]?
    let rewards: [ClubSeasonReward]?
    let announcements: [ClubAnnouncement]?
    let memberCount: Int?

    enum CodingKeys: String, CodingKey {
        case season, joined, tasks, rewards, announcements
        case joinedAt = "joined_at"
        case memberCount = "member_count"
    }
}

enum ClubRewardGrouping {
    static func taskRewards(_ rewards: [ClubSeasonReward], taskID: Int) -> [ClubSeasonReward] {
        rewards.filter { $0.type != "physical" && $0.taskID == taskID && $0.unlockScope != "season" }
    }
    static func finale(_ rewards: [ClubSeasonReward]) -> [ClubSeasonReward] {
        rewards.filter { $0.type == "physical" || $0.unlockScope == "season" }
    }
    static func unlinked(_ rewards: [ClubSeasonReward], taskIDs: Set<Int>) -> [ClubSeasonReward] {
        rewards.filter { $0.type != "physical" && $0.unlockScope != "season" && ($0.taskID == nil || !taskIDs.contains($0.taskID ?? 0)) }
    }
}

struct ClubAnnouncement: Decodable, Identifiable {
    let id: Int
    let title: String
    let body: String
    let publishedAt: String

    enum CodingKeys: String, CodingKey {
        case id, title, body
        case publishedAt = "published_at"
    }
}

struct ClubCollectedReward: Decodable, Identifiable {
    let id: Int
    let title: String
    let icon: String
    let rewardType: String
    let seasonTitle: String
    let slug: String
    var detail: String? = nil
    var imagePath: String? = nil

    enum CodingKeys: String, CodingKey {
        case id, title, icon, slug, detail
        case rewardType = "reward_type"
        case seasonTitle = "season_title"
        case imagePath = "image_path"
    }
}

private struct ClubHistoryEnvelope: Decodable { let items: [ClubSeasonEnvelope] }
private struct ClubCollectionEnvelope: Decodable { let items: [ClubCollectedReward] }

struct RewardClaimDraft {
    var recipient = ""
    var phone = ""
    var region = ""
    var address = ""
    var size = ""
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

do {
let phaseThreeStart = checks
let noData = ReviewMetrics(logs:[])
check(noData.plannedSets == 0 && noData.completedSets == 0,"empty review has no training")
check(noData.averageCalories == nil && noData.averageProtein == nil,"empty nutrition is unknown, not zero")
check(noData.completionLabel == "—","empty review does not show a fabricated percentage")
let partial = DayLog(exercises:[Exercise(name:"测试",muscle:"全身",sets:[TrainingSet(weight:20,reps:5,completed:true),TrainingSet(weight:20,reps:5)])],meals:[meal("早餐")])
let totals = ReviewMetrics(logs:[DayLog(),partial])
check(totals.plannedSets == 2 && totals.completedSets == 1 && totals.remainingSets == 1,"partial plan donut preserves denominator")
check(totals.trainingDays == 1 && totals.finishedDays == 0,"partial and fully finished training days differ")
check(totals.completionLabel == "50%","half the valid groups equals fifty percent")
check(totals.averageCalories == 100 && totals.averageProtein == 10,"unlogged days excluded from food average")
check(totals.mealDays == 1 && totals.meals == 1,"meals and recorded days kept separately")
let fullDay=DayLog(exercises:[Exercise(name:"保持",muscle:"核心",sets:[TrainingSet(weight:10,reps:0,completed:true,durationSeconds:30)])])
let fullMetrics=ReviewMetrics(logs:[fullDay])
check(fullMetrics.finishedDays == 1 && fullMetrics.completionLabel == "100%","timed valid set counts as completed")
check(fullDay.volume == 0,"timed set does not fabricate kilograms")
let invalidDay=DayLog(exercises:[Exercise(name:"无效保持",muscle:"核心",sets:[TrainingSet(weight:0,reps:0,completed:true,durationSeconds:0)])])
check(ReviewMetrics(logs:[invalidDay]).completedSets == 0,"invalid checked set does not inflate completion")
let legacyRewardData=Data(#"{"id":1,"title":"Old","detail":"old","type":"badge","icon":"seal","unlocked":true}"#.utf8)
let oldReward=try JSONDecoder().decode(ClubSeasonReward.self,from:legacyRewardData)
check(oldReward.taskID == nil && oldReward.unlockScope == nil,"old reward JSON remains compatible")
var taskReward=oldReward;taskReward.taskID=7;taskReward.unlockScope="task"
let physical=ClubSeasonReward(id:2,title:"Gift",detail:"all tasks",type:"physical",icon:"gift",unlocked:false,claimStatus:nil,trackingCompany:nil,trackingNumber:nil,taskID:7,unlockScope:"season")
var other=oldReward;other.taskID=8;other.unlockScope="task"
let rewards=[taskReward,physical,other,oldReward]
check(ClubRewardGrouping.taskRewards(rewards,taskID:7).count == 1,"physical all-tasks reward never appears as a single-task reward")
check(ClubRewardGrouping.taskRewards(rewards,taskID:99).isEmpty,"unmatched task does not steal a reward")
check(ClubRewardGrouping.finale(rewards).count == 1,"physical reward is a season finale")
check(ClubRewardGrouping.unlinked(rewards,taskIDs:[7]).count == 2,"old and orphan reward stays visible")
let oldCollection=try JSONDecoder().decode(ClubCollectedReward.self,from:Data(#"{"id":1,"title":"Old","icon":"seal","reward_type":"badge","season_title":"Season","slug":"old"}"#.utf8))
check(oldCollection.detail == nil,"legacy collection accepts absent description")
let newCollection=try JSONDecoder().decode(ClubCollectedReward.self,from:Data(#"{"id":1,"title":"New","detail":"Official description","icon":"seal","reward_type":"badge","season_title":"Season","slug":"new"}"#.utf8))
check(newCollection.detail == "Official description","collection preserves official detail")
let dailyRaw:JSONValue = .object(["kind":.string("report"),"notes":.array([]),"summary":.string(String(repeating:"据记录分析。\n",count:200)),"training":.string("实际训练"),"nutrition":.string("实际饮食"),"recovery":.string("恢复")])
let longResult=try JSONDecoder().decode(AIResult.self,from:JSONEncoder().encode(dailyRaw))
check(longResult.summary?.count == 1400,"long report decodes in the actual app model")
let longRoundtrip=try JSONDecoder().decode(AIResult.self,from:JSONEncoder().encode(longResult))
check(longRoundtrip.summary == longResult.summary,"long report persistence has no truncation")
let versionedInput=try builder.reportInput(date:now,log:partial)
check(versionedInput.payload["analysis_version"] == .number(2),"new analysis does not match an old short report")
let weeklyLong=WeeklyResult(kind:"weekly_review",summary:longResult.summary!,training:longResult.summary!,nutrition:"实际饮食",recovery:"恢复",appearance:"无照片",photoFeedback:[],decision:"keep",reason:longResult.summary!,notes:[],sessions:[])
let weeklyRoundtrip=try JSONDecoder().decode(WeeklyResult.self,from:JSONEncoder().encode(weeklyLong))
check(weeklyRoundtrip.summary == weeklyLong.summary && weeklyRoundtrip.reason == weeklyLong.reason,"actual weekly model retains detailed analysis")
check(weeklyRoundtrip.sessions.isEmpty && weeklyRoundtrip.decision == "keep","long analysis does not imply an unconfirmed plan change")
print("PASS \(checks-phaseThreeStart) phase3 production Swift rule checks")
}

extension AppStore {
    func saveWorkoutPlan(on date: Date) -> Bool {
        guard ClubDates.isFuture(date), !log(for:date).exercises.isEmpty else { return false }
        return mutate(date) { day in
            for i in day.exercises.indices {
                for j in day.exercises[i].sets.indices { day.exercises[i].sets[j].completed = false }
            }
            day.workoutSavedAt=nil;day.workoutStartedAt=nil;day.workoutEndedAt=nil;day.linkedDeviceWorkoutID=nil
        }
    }
    func addMeal(_ meal: Meal, photo: Data?, on date: Date, handledAIJobIDs: [String] = []) -> Bool {
        guard !ClubDates.isFuture(date) else { message = "饮食只能记录今天或过去日期。"; return false }
        guard !log(for: date).meals.contains(where: { $0.id == meal.id }), !handledAIJobIDs.contains(where: hasAppliedAIJob) else { message = "这餐或它的识别任务已处理，请查看已有记录。"; return false }
        guard [meal.calories, meal.protein, meal.carbs, meal.fat].allSatisfy({ $0.isFinite && (0...100000).contains($0) }) else { message = "营养数值不正确，请检查后保存。"; return false }
        guard log(for: date).meals.count < 50, !meal.name.isEmpty, meal.name.count <= 100 else { message = "一天最多记录 50 餐，餐食名称需为 1—100 字。"; return false }
        if let id = meal.sourceAIJobID, hasAppliedAIJob(id) {
            message = "这次识别结果已保存，可在饮食记录中查看。"
            return false
        }
        let previous = state
        var meal = meal
        var newPhotoURL: URL?
        if let jobID = meal.sourceAIJobID { meal.id = stableID("meal/\(jobID)") }
        if let photo {
            let filename = UUID().uuidString.lowercased() + ".jpg"
            do {
                try prepareMediaDirectory()
                try photo.write(to: mediaDirectory.appendingPathComponent(filename), options: [.atomic, .completeFileProtection])
                meal.photoFilename = filename
                newPhotoURL = mediaDirectory.appendingPathComponent(filename)
            } catch {
                message = "照片保存失败，饮食数值仍会保存。"
            }
        }
        let key = ClubDates.key(date)
        var log = state.days[key] ?? DayLog()
        log.meals.append(meal)
        state.days[key] = log
        state.appliedAIJobs = Array(Set((state.appliedAIJobs ?? []) + handledAIJobIDs + [meal.sourceAIJobID].compactMap { $0 })).sorted()
        if persist(changedDates: [key]) { return true }
        state = previous
        if let newPhotoURL { try? FileManager.default.removeItem(at: newPhotoURL) }
        return false
    }
}

extension ReportInputBuilder {
    func planExercisesInput(_ log: DayLog) throws -> [JSONValue] {
        guard log.exercises.count <= 30, log.exercises.allSatisfy({$0.sets.count <= 50}) else {
            throw AIClientError.message("计划超过 30 个动作或每动作 50 组，请精简后复盘。")
        }
        return log.exercises.map { exercise in
            .object(["name":.string(String(exercise.name.prefix(100))),"sets":.array(exercise.sets.map {
                .object(["weight":.number($0.weight),"reps":.number(Double($0.reps)),"completed":.bool(false),"durationSeconds":$0.durationSeconds.map{.number(Double($0))} ?? .null])
            })])
        }
    }
}

do {
let before=checks
let futureStore=AppStore()
let pendingMovement=Exercise(name:"计划",muscle:"核心",sets:[TrainingSet(reps:0,durationSeconds:30)])
futureStore.state.days[ClubDates.key(tomorrow)]=DayLog(exercises:[pendingMovement])
var checked=pendingMovement.sets[0];checked.completed=true
check(!futureStore.updateSet(checked,exerciseID:pendingMovement.id,on:tomorrow),"future set completion is refused at store boundary")
check(futureStore.log(for:tomorrow).completedSets == 0,"future rejected write leaves plan intact")
check(!futureStore.saveWorkout(on:tomorrow),"future workout cannot be confirmed")
var planned=pendingMovement.sets[0];planned.durationSeconds=50
check(futureStore.updateSet(planned,exerciseID:pendingMovement.id,on:tomorrow),"future target duration remains editable")
check(futureStore.saveWorkoutPlan(on:tomorrow),"future plan saves without completed history")
check(futureStore.log(for:tomorrow).workoutSavedAt == nil && futureStore.log(for:tomorrow).workoutStartedAt == nil,"plan has no fabricated start or finish")
check(!futureStore.addMeal(meal("午餐"),photo:nil,on:tomorrow),"future meal rejected by store")
rejected("future daily report rejected") { _=try builder.reportInput(date:tomorrow,log:DayLog()) }
let plannedJSON=try builder.planExercisesInput(DayLog(exercises:[Exercise(name:"未来基线",muscle:"核心",sets:[checked])]))
if case .object(let exercise)=plannedJSON[0],case .array(let sets)?=exercise["sets"],case .object(let values)=sets[0] { check(values["completed"] == .bool(false),"weekly future plan input is allowed without fabricating completion") } else { fatalError("missing plan input") }
check(!ClubDates.isFuture(now) && ClubDates.isFuture(tomorrow),"future rule compares natural days")
let startedStore=AppStore()
startedStore.state.days[today]=DayLog(exercises:[pendingMovement])
check(startedStore.updateSet(checked,exerciseID:pendingMovement.id,on:now),"first completed set starts today's workout")
let firstStart=startedStore.log(for:now).workoutStartedAt
check(firstStart != nil,"automatic start timestamp persisted")
check(startedStore.updateSet(checked,exerciseID:pendingMovement.id,on:now) && startedStore.log(for:now).workoutStartedAt == firstStart,"editing completed group never resets start")
check(startedStore.log(for:now).timedSeconds == 30 && startedStore.log(for:now).completedSets == 1 && startedStore.log(for:now).volume == 0,"timed completion is visible without invented kilograms")
let historyStore=AppStore();historyStore.state.days[ClubDates.key(yesterday)]=DayLog(exercises:[pendingMovement])
check(historyStore.updateSet(checked,exerciseID:pendingMovement.id,on:yesterday) && historyStore.log(for:yesterday).workoutStartedAt == nil,"historical completion never invents present start time")
let rollback=AppStore();rollback.state.days[today]=DayLog(exercises:[pendingMovement]);rollback.allowPersistence=false
check(!rollback.updateSet(checked,exerciseID:pendingMovement.id,on:now) && rollback.log(for:now).workoutStartedAt == nil,"failed persistence rolls back automatic start and completion")
var unknown=meal("早餐");unknown.nutritionKnown=false;unknown.calories=0;unknown.protein=0
let foodStore=AppStore()
check(foodStore.addMeal(unknown,photo:nil,on:now,handledAIJobIDs:["waiting-food"]),"manual meal and pending food task handled in one persistent write")
check(foodStore.hasAppliedAIJob("waiting-food"),"late AI result remains durably handled")
check(!foodStore.addMeal(unknown,photo:nil,on:now),"same draft cannot be saved twice")
check(!foodStore.addMeal(meal("早餐"),photo:nil,on:now,handledAIJobIDs:["waiting-food"]),"same food task cannot create a second meal")
check(foodStore.log(for:now).unknownNutritionMeals == 1 && foodStore.log(for:now).knownMeals.isEmpty,"unknown meal stays explicitly unknown")
check(ReviewMetrics(logs:[foodStore.log(for:now)]).averageCalories == nil,"unknown-only day does not become zero-calorie average")
let input=try builder.reportInput(date:now,log:foodStore.log(for:now))
if case .array(let meals)?=input.payload["meals"],case .object(let values)=meals[0] { check(values["nutrition_known"] == .bool(false),"AI input declares missing nutrition") } else { fatalError("missing meal") }
let oldMeal=try JSONDecoder().decode(Meal.self,from:Data(#"{"id":"550E8400-E29B-41D4-A716-446655440000","name":"old","category":"早餐","calories":100,"protein":10,"carbs":10,"fat":2}"#.utf8))
check(oldMeal.hasNutrition,"legacy nutrition remains decodable and known")
let mixed=DayLog(meals:[unknown,oldMeal])
check(mixed.calories == 100 && mixed.unknownNutritionMeals == 1,"known meal totals exclude missing meal")
var nutritionBase=SavedState();nutritionBase.days[today]=DayLog(meals:[unknown])
var nutritionLocal=nutritionBase;var nutritionRemote=nutritionBase
nutritionLocal.days[today]!.meals[0].name="补充菜名"
nutritionRemote.days[today]!.meals[0].calories=300;nutritionRemote.days[today]!.meals[0].protein=20;nutritionRemote.days[today]!.meals[0].nutritionKnown=true
let nutritionMerged=try CloudMerge.merge(local:CloudState(nutritionLocal),remote:CloudState(nutritionRemote),base:CloudState(nutritionBase)).savedState().days[today]!.meals[0]
check(nutritionMerged.name == "补充菜名" && nutritionMerged.hasNutrition && nutritionMerged.calories == 300 && nutritionMerged.protein == 20,"remote nutrition fill combines safely with local meal name edit")
nutritionLocal.days[today]!.meals[0].nutritionKnown=true;nutritionLocal.days[today]!.meals[0].calories=200;nutritionLocal.days[today]!.meals[0].protein=10
let nutritionConflict=try CloudMerge.merge(local:CloudState(nutritionLocal),remote:CloudState(nutritionRemote),base:CloudState(nutritionBase)).savedState().days[today]!.meals[0]
check(nutritionConflict.hasNutrition && nutritionConflict.calories == 200 && nutritionConflict.protein == 10,"concurrent manual nutrition edits keep one coherent set of values")
nutritionBase=nutritionRemote;nutritionLocal=nutritionBase;nutritionLocal.days[today]!.meals[0].nutritionKnown=false
nutritionRemote.days[today]!.meals[0].calories=400
let unknownConflict=try CloudMerge.merge(local:CloudState(nutritionLocal),remote:CloudState(nutritionRemote),base:CloudState(nutritionBase)).savedState().days[today]!.meals[0]
check(!unknownConflict.hasNutrition && unknownConflict.calories == 300,"unknown flag never inherits unrelated remote nutrition values")
let mixedText=String(repeating:"训练记录。中文 English 123\n👨‍👩‍👦 继续！",count:300)
let pages=ShareTextPages.split(mixedText){$0.count <= 120}
check(pages.count > 1 && pages.joined() == mixedText,"pagination preserves every character and emoji")
check(pages.allSatisfy{!$0.isEmpty && $0.count <= 120},"page boundary never exceeds measured capacity")
check(ShareTextPages.split(""){_ in true} == [""],"empty share text remains one valid page")
let longWord=String(repeating:"A",count:5000)
check(ShareTextPages.split(longWord){$0.count<=80}.joined() == longWord,"unbroken English text paginates without data loss")
let suite="boji-v21-test-"+UUID().uuidString;let defaults=UserDefaults(suiteName:suite)!
defer { defaults.removePersistentDomain(forName:suite) }
let owner=9876
check(ClubGuideProgress.shouldShow(owner,now:now,defaults:defaults),"new member guide is pending")
defaults.set(now,forKey:"boji.usage-guide.v2.9876.snoozed")
check(!ClubGuideProgress.shouldShow(owner,now:now,defaults:defaults),"postponed guide stays quiet today")
check(ClubGuideProgress.shouldShow(owner,now:tomorrow,defaults:defaults),"postponing does not mark guide complete")
defaults.set(true,forKey:"boji.usage-guide.v2.9876.completed")
check(!ClubGuideProgress.shouldShow(owner,now:tomorrow,defaults:defaults),"completed guide is not automatically repeated")
defaults.removeObject(forKey:"boji.usage-guide.v2.9876.completed");defaults.set(true,forKey:"boji.usage-guide.v2.9876.muted")
check(!ClubGuideProgress.shouldShow(owner,now:tomorrow,defaults:defaults),"explicit guide mute respected")
let pendingJob=AILocalJob(id:"x",digest:"x",request:AIRequest(id:"x",kind:"food",date:today,payload:[:]),status:"discarded",consumed:true)
check(pendingJob.isTerminal,"discarded recognition never resumes")
print("PASS \(checks-before) v21 production Swift rule checks; total \(checks)")
}
