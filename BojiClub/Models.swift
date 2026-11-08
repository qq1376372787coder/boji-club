import Foundation

enum EntryValidation {
    static func meal(name: String, nutrition: [Double], componentsValid: Bool) -> String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "请先填写这餐吃了什么。" }
        if name.count > 100 { return "食物名称最多 100 个字，请缩短后保存。" }
        if !componentsValid { return "食物明细中有未填或不合理的数值，请核对份量与营养。" }
        if !nutrition.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 100000 }) {
            return "营养数值请填写 0—100000 范围内的数字。"
        }
        return nil
    }
    static func reward(recipient: String, phone: String, region: String, address: String) -> [String] {
        var issues: [String] = []
        if recipient.trimmingCharacters(in: .whitespacesAndNewlines).count < 2 { issues.append("收件人姓名至少 2 个字") }
        let normalizedPhone = phone.filter { !$0.isWhitespace }
        if normalizedPhone.range(of: "^1[3-9][0-9]{9}$", options: .regularExpression) == nil { issues.append("中国大陆 11 位手机号") }
        if region.trimmingCharacters(in: .whitespacesAndNewlines).count < 2 { issues.append("省、市、区") }
        if address.trimmingCharacters(in: .whitespacesAndNewlines).count < 5 { issues.append("详细地址至少 5 个字") }
        return issues
    }
}


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
    /// 俱乐部申领、成长季等截止日期由服务端按北京时间判定；客户端比较时
    /// 必须使用同一时区，否则跨时区用户会比服务端提前或延后一天。
    static let serverTimeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
    static func serverKey(_ date: Date = Date()) -> String {
        formatterCache.string(date, format: "yyyy-MM-dd", locale: "en_US_POSIX", timezone: serverTimeZone)
    }
    static func date(fromKey value: String) -> Date? { formatterCache.date(value) }
    static func label(_ date: Date, format: String = "M月d日") -> String { formatterCache.string(date, format: format, locale: "zh_CN") }

}

struct TrainingSet: Identifiable, Codable, Equatable {
    var id = UUID()
    var weight: Double = 0
    var reps: Int = 10
    var completed = false
    var durationSeconds: Int? = nil
    // nil keeps already-completed historical records intact. Unfinished targets are not actual input.
    var actualEntered: Bool? = nil
    var hasActualEntry: Bool { actualEntered == true || (completed && actualEntered == nil) }
    var validCompletion: Bool { completed && actualEntered != false && (durationSeconds.map { $0 > 0 } ?? (reps > 0)) }
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
    var planID: String? = nil
    var libraryQuery: String?
    var deletedSetIDs: [String]?
    var workoutSessionID: UUID? = nil
    var customExerciseID: UUID? = nil
    var customUnit: String? = nil
    var restSeconds: Int? = nil
    enum CodingKeys: String, CodingKey { case id, name, muscle, sets, libraryID, equipment, imageURL, gifURL, planID, libraryQuery, deletedSetIDs, workoutSessionID, customExerciseID, customUnit, restSeconds }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(name, forKey: .name); try c.encode(muscle, forKey: .muscle); try c.encode(sets, forKey: .sets)
        try c.encodeIfPresent(libraryID, forKey: .libraryID); try c.encodeIfPresent(equipment, forKey: .equipment)
        try c.encodeIfPresent(planID, forKey: .planID)
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
    var portion: String? = nil
    var recognitionConfidence: Double? = nil
    var estimateNotes: [String]?
    var components: [FoodComponent]? = nil
    var consumedFraction: Double? = nil
    var nutritionKnown: Bool? = nil
    // Phase 3: provenance/uncertainty survives the draft -> formal record path.
    var requiresReview: Bool? = nil
    var nutritionSources: [String]? = nil
    var placementConflictDates: [String]? = nil
    var placementConfirmedAt: Date? = nil
    var hasNutrition: Bool { nutritionKnown != false }
}

/// Field-level merge for concurrent meal edits. The editor passes the snapshot
/// it opened with; only fields the user actually changed overwrite the current
/// record. A cloud merge can therefore combine one device's calories with
/// another device's protein instead of letting the whole meal snapshot win.
enum MealNutritionMerge {
    static func merged(edited: Meal, base: Meal?, current: Meal) -> Meal {
        guard let base else { return applyingAll(edited, to: current) }
        var result = current
        if edited.name != base.name { result.name = edited.name }
        if edited.category != base.category { result.category = edited.category }
        // A known/unknown change must retain that observation's nutrient values.
        let structureChanged = edited.components != base.components || edited.consumedFraction != base.consumedFraction || edited.nutritionKnown != base.nutritionKnown
        let currentStructureChanged = current.components != base.components || current.consumedFraction != base.consumedFraction || current.nutritionKnown != base.nutritionKnown
        let editedNutritionChanged = structureChanged || edited.calories != base.calories || edited.protein != base.protein ||
            edited.carbs != base.carbs || edited.fat != base.fat || edited.nutritionKnown != base.nutritionKnown
        switch nutritionSource(editedStructureChanged: structureChanged,
                               currentStructureChanged: currentStructureChanged,
                               editedNutritionChanged: editedNutritionChanged) {
        case .edited:
            copyNutrition(from: edited, to: &result)
        case .current:
            break
        case .independent:
            if edited.calories != base.calories { result.calories = edited.calories }
            if edited.protein != base.protein { result.protein = edited.protein }
            if edited.carbs != base.carbs { result.carbs = edited.carbs }
            if edited.fat != base.fat { result.fat = edited.fat }
            if edited.nutritionKnown != base.nutritionKnown { result.nutritionKnown = edited.nutritionKnown }
        }
        return result
    }
    enum NutritionSource { case edited, current, independent }
    /// A structural edit makes nutrition one observation. Concurrent nutrition
    /// edits prefer the editor/local observation as a whole; metadata-only edits
    /// keep the current/remote observation. Pure scalar edits remain independent.
    static func nutritionSource(editedStructureChanged: Bool, currentStructureChanged: Bool,
                                editedNutritionChanged: Bool) -> NutritionSource {
        guard editedStructureChanged || currentStructureChanged else { return .independent }
        return editedNutritionChanged ? .edited : .current
    }
    private static func copyNutrition(from meal: Meal, to result: inout Meal) {
        result.calories = meal.calories; result.protein = meal.protein
        result.carbs = meal.carbs; result.fat = meal.fat
        result.components = meal.components; result.consumedFraction = meal.consumedFraction
        result.nutritionKnown = meal.nutritionKnown
    }
    private static func applyingAll(_ edited: Meal, to current: Meal) -> Meal {
        var result = current
        result.name = edited.name
        result.category = edited.category
        result.calories = edited.calories
        result.protein = edited.protein
        result.carbs = edited.carbs
        result.fat = edited.fat
        result.components = edited.components
        result.consumedFraction = edited.consumedFraction
        result.nutritionKnown = edited.nutritionKnown
        return result
    }
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

struct TrainingFeedback: Codable, Equatable {
    var version: Int
    var status: String
    var reason: String
    var evidence: [String]
    var next_step: String
    var supported: Bool { version == 1 && ["green", "yellow", "red", "gray"].contains(status) }
    var presentation: TrainingFeedback { supported ? self : .legacy }
    var title: String {
        if reason == "rest_day" { return "按计划休息" }
        switch status { case "green": return "执行到位"; case "yellow": return "还有提升空间"; case "red": return "优先调整"; default: return "暂不评价" }
    }
    var symbol: String {
        switch status { case "green": return "checkmark.circle"; case "yellow": return "arrow.triangle.2.circlepath"; case "red": return "exclamationmark.triangle"; default: return reason == "rest_day" ? "moon" : "minus.circle" }
    }
    static let legacy = TrainingFeedback(version: 1, status: "gray", reason: "legacy_report",
        evidence: ["这份旧分析没有训练反馈标签，不能按后来修改的记录补判颜色。"],
        next_step: "原报告继续可读；需要新反馈时，按核对后的记录重新生成分析。")
    static let preview = TrainingFeedback(version: 1, status: "gray", reason: "debug_preview",
        evidence: ["这是开发预览，只用于查看日报界面，不评价实际训练。"],
        next_step: "联网账号生成复盘后，将按提交的记录展示真实反馈。")
}

struct WorkoutPauseInterval: Codable, Equatable {
    var start: Date
    var end: Date?
}

struct WorkoutSession: Identifiable, Codable {
    var id: UUID
    var startedAt: Date?
    var endedAt: Date?
    var savedAt: Date?
    var linkedDeviceWorkoutID: String?
    var executionBaseline: WorkoutExecutionBaseline? = nil
    var cancelledAt: Date? = nil
    var pauseIntervals: [WorkoutPauseInterval]? = nil
    func pausedSeconds(through now: Date) -> TimeInterval {
        (pauseIntervals ?? []).reduce(0) { total, interval in
            let begin = max(startedAt ?? interval.start, interval.start)
            let end = min(endedAt ?? now, interval.end ?? now)
            return total + max(0, end.timeIntervalSince(begin))
        }
    }
}


struct DayLog: Codable {
    var _schedule_version: Int? = nil
    var _body_version: Int? = nil
    var _meal_version: Int? = nil
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
    var bodyMeasurements: [BodyWeightEntry]? = nil
    var deletedBodyMeasurementIDs: [String]? = nil
    var workoutSessions: [WorkoutSession]? = nil
    var activeWorkoutSessionID: UUID? = nil
    var planCycle: TrainingCycle? = nil
    var planActions: [PlanLifecycleAction]? = nil
    var mealCompletion: MealCompletion? = nil
    var movedFromDate: String? = nil
    var plannedMoveDestination: String? = nil
    // B1：顺延记录（可选字段，旧数据解码为 nil）。
    var planShifts: [PlanShiftRecord]? = nil
    // D3：阶段报告（挂在结束日期上；旧数据解码为 nil）。
    var phaseReports: [PhaseReport]? = nil
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
            session.cancelledAt == nil && session.savedAt == nil && exercises.contains { $0.workoutSessionID == session.id && $0.sets.contains(where: \.validCompletion) }
        }
    }
    var isTrainingConfirmed: Bool { confirmedTraining.hasTraining && !hasUnconfirmedTraining }
    /// 已确认保存的场次。同一天可能有多场：一场已确认、另一场尚未确认时，
    /// 统计与趋势仍应使用已确认场次，不能因为它被整天布尔值隐藏。
    var confirmedWorkoutSessions: [WorkoutSession] {
        (workoutSessions ?? []).filter { $0.savedAt != nil }
    }
    /// 保存后的执行事实。进行中数据仍用 completedSets/timedSeconds 展示，
    /// 历史汇总、趋势和洞察统一使用 confirmedTraining，避免各页面另写筛选。
    struct ConfirmedTraining {
        let exercises: [Exercise]
        let elapsedSeconds: Int
        var sets: [TrainingSet] { exercises.flatMap(\.sets).filter(\.validCompletion) }
        var completedSets: Int { sets.count }
        var repetitions: Int { sets.filter { $0.durationSeconds == nil }.reduce(0) { $0 + $1.reps } }
        var volume: Double { sets.reduce(0) { $0 + $1.volume } }
        var timedSeconds: Int { sets.reduce(0) { $0 + ($1.durationSeconds ?? 0) } }
        var hasTraining: Bool { completedSets > 0 }
    }
    var confirmedTraining: ConfirmedTraining {
        func seconds(_ start: Date?, _ end: Date?) -> Int {
            guard let start, let end, end > start else { return 0 }
            return Int(end.timeIntervalSince(start))
        }
        if let sessions = workoutSessions, !sessions.isEmpty {
            let saved = sessions.filter { $0.savedAt != nil }
            let ids = Set(saved.map(\.id))
            let exercises = exercises.filter { $0.workoutSessionID.map(ids.contains) ?? false }
            let completedIDs = Set(exercises.filter { $0.sets.contains(where: \.validCompletion) }.compactMap(\.workoutSessionID))
            let elapsed = saved.filter { completedIDs.contains($0.id) }.reduce(0) { $0 + max(0, seconds($1.startedAt, $1.endedAt) - Int($1.pausedSeconds(through: $1.endedAt ?? Date()))) }
            return ConfirmedTraining(exercises: exercises, elapsedSeconds: elapsed)
        }
        guard workoutSavedAt != nil, completedSets > 0 else {
            return ConfirmedTraining(exercises: [], elapsedSeconds: 0)
        }
        return ConfirmedTraining(exercises: exercises, elapsedSeconds: seconds(workoutStartedAt, workoutEndedAt))
    }
    var hasConfirmedTraining: Bool { confirmedTraining.hasTraining }
    var confirmedCompletedSets: Int { confirmedTraining.completedSets }
    /// 训练量唯一口径：只算记完的组（validCompletion）。
    /// 「记完」= validCompletion；场次未保存的历史数据不重复计入（保存的场次已在其 exercises 内）。
    /// 可见串一律用 confirmedTraining.volume（只认已保存场次），本属性仅供计划预览等未保存场景。
    var volume: Double { exercises.flatMap(\.sets).filter(\.validCompletion).reduce(0) { $0 + $1.volume } }
    var completedSets: Int { exercises.flatMap(\.sets).filter(\.validCompletion).count }
    var totalSets: Int { exercises.reduce(0) { $0 + $1.sets.count } }
    var timedSeconds: Int { exercises.flatMap(\.sets).filter(\.validCompletion).reduce(0) { $0 + ($1.durationSeconds ?? 0) } }
    var unknownNutritionMeals: Int { meals.filter { !$0.hasNutrition }.count }
    var knownMeals: [Meal] { meals.filter(\.hasNutrition) }
    var calories: Double { knownMeals.reduce(0) { $0 + $1.calories } }
    var protein: Double { knownMeals.reduce(0) { $0 + $1.protein } }
    var carbs: Double { knownMeals.reduce(0) { $0 + $1.carbs } }
    var fat: Double { knownMeals.reduce(0) { $0 + $1.fat } }

    func deterministicMetrics(dateKey: String) -> AIDailyMetrics {
        let confirmed = confirmedTraining
        let completedExNames = Set(confirmed.exercises.filter { $0.sets.contains(where: \.validCompletion) }.map(\.name))
        let durationMinutes: Int? = confirmed.elapsedSeconds > 0 ? (confirmed.elapsedSeconds / 60) : (timedSeconds > 0 ? (timedSeconds / 60) : nil)
        let sessionsCount = (workoutSessions?.filter { $0.savedAt != nil }.count ?? 0) > 0 ? (workoutSessions?.filter { $0.savedAt != nil }.count ?? 0) : (hasConfirmedTraining ? 1 : 0)

        let hasMealRecords = !meals.isEmpty
        let trainingMetrics = AIDailyTrainingMetrics(
            sessions: sessionsCount,
            duration_minutes: durationMinutes,
            completed_exercises: completedExNames.count,
            completed_sets: confirmed.completedSets,
            total_volume_kg: confirmed.volume
        )

        let nutritionMetrics = AIDailyNutritionMetrics(
            // 口径唯一：有餐但营养全未知 ≠ 摄入了 0。空值一律 nil，读出层显示「还没记」。
            calories: knownMeals.isEmpty ? nil : calories,
            protein: knownMeals.isEmpty ? nil : protein,
            carbs: knownMeals.isEmpty ? nil : carbs,
            fat: knownMeals.isEmpty ? nil : fat,
            data_complete: mealsComplete,
            unknown_meals: unknownNutritionMeals
        )

        let bodyMetrics = AIDailyBodyMetrics(
            // 口径：体重走唯一读法 BodyWeightReading（多条测量取最后一次，非法值为 nil），
            // 体脂/腰围同批只在整条记录有效时报出
            weight_kg: BodyWeightReading.latest(self),
            body_fat_pct: bodyWeight?.isValid == true ? bodyWeight?.bodyFatPercentage : nil,
            waist_cm: bodyWeight?.isValid == true ? bodyWeight?.waistCircumferenceCM : nil
        )

        let activityMetrics = AIDailyActivityMetrics(
            steps: health?.steps?.value,
            active_energy_kcal: health?.activeEnergy?.value
        )

        var warnings: [String] = []
        if hasMealRecords && !mealsComplete {
            warnings.append("全天饮食尚未标记确认完成，当前摄入不代表全天总值。")
        }
        if unknownNutritionMeals > 0 {
            warnings.append("有 \(unknownNutritionMeals) 道餐食缺少明确营养参数，未计入能量合计。")
        }

        return AIDailyMetrics(
            date: dateKey,
            training: trainingMetrics,
            nutrition: nutritionMetrics,
            body: bodyMetrics,
            activity: activityMetrics,
            data_warnings: warnings.isEmpty ? nil : warnings
        )
    }
}

struct ProfileFactMeta: Codable, Equatable {
    var sourceKind: String
    var confirmedAt: String?
    var revision: Int?
    var known: Bool { ["confirmed", "legacy_recorded"].contains(sourceKind) }
}

struct MemberProfile: Codable, Equatable {
    var nickname = "薄肌新成员"
    var identityVersion: Int?
    var avatarID: String?
    var avatarImage: Data?
    var gender: String?
    var ageGroup: String? = nil
    var equipmentExclusions: [String]? = nil
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
    // E7：目标体重（目标概念，与资料体重/实测体重不同；nil=未设置）。
    var targetWeightKg: Double? = nil
    /// Per-field provenance. nil means an older profile (all valid fields are
    /// legacy-confirmed); a present map may explicitly mark unknown fields.
    var factState: [String: ProfileFactMeta]? = [:]
    var canPrepareTrainingPlan: Bool {
        return hasConfirmedBasics || legacyBasicsValid || (height > 0 && weight > 0)
    }
    var v2PlanProfile: [String: JSONValue] {
        var result: [String: JSONValue]=[:]
        func put(_ key: String,_ field: String,_ value: JSONValue) { if isFactConfirmed(field) { result[key]=value } }
        put("goal","goal",.string(goal.isEmpty ? "增肌塑形" : goal))
        if result["goal"] == nil { result["goal"] = .string(goal.isEmpty ? "增肌塑形" : goal) }
        put("experience","experience",.string(experience.isEmpty ? "新手" : experience))
        if result["experience"] == nil { result["experience"] = .string(experience.isEmpty ? "新手" : experience) }
        put("venue","venue",.string(venue.isEmpty ? "健身房" : venue))
        if result["venue"] == nil { result["venue"] = .string(venue.isEmpty ? "健身房" : venue) }
        put("focus","focus",.string(focus))
        put("limitations","limitations",.string(limitations ?? ""))
        if result["limitations"] == nil, let lim = limitations, !lim.isEmpty { result["limitations"] = .string(lim) }
        let minutes = (sessionMinutes ?? 0) > 0 ? (sessionMinutes ?? 0) : 45
        put("sessionMinutes","session_minutes",.number(Double(minutes)))
        if result["sessionMinutes"] == nil { result["sessionMinutes"] = .number(Double(minutes)) }
        put("age","age_years",.number(Double(age > 0 ? age : 25)))
        if result["age"] == nil { result["age"] = .number(Double(age > 0 ? age : 25)) }
        put("height","height_cm",.number(height > 0 ? height : 175))
        if result["height"] == nil { result["height"] = .number(Double(height > 0 ? height : 175)) }
        put("weight","profile_weight_kg",.number(weight > 0 ? weight : 70))
        if result["weight"] == nil { result["weight"] = .number(Double(weight > 0 ? weight : 70)) }
        if isFactConfirmed("equipment") { result["equipment"] = .array((equipment ?? "").split(separator:"、").map { .string(String($0)) }) }
        if isFactConfirmed("equipment_exclusions") { result["equipmentExclusions"] = .array((equipmentExclusions ?? []).map(JSONValue.string)) }
        let rawDays = isFactConfirmed("training_days") ? (trainingDays ?? []) : (trainingDays ?? [])
        let days = rawDays.isEmpty ? [1, 3, 5] : rawDays
        result["trainingDays"] = .array(days.map { .number(Double($0)) });result["daysPerWeek"] = .number(Double(days.count))
        if isFactConfirmed("age_group"),let ageGroup { result["ageGroup"] = .string(ageGroup) }
        else if isFactConfirmed("age_years") { result["ageGroup"] = .string(age < 18 ? "minor" : "adult") }
        else { result["ageGroup"] = .string("adult") }
        result["equipmentOther"] = isFactConfirmed("equipment_other") ? .string(equipmentOther ?? "") : .string("")
        if isFactConfirmed("home_training_days") { result["homeTrainingDays"] = .array((homeTrainingDays ?? []).map { .number(Double($0)) }) }
        return result
    }
    var aiProfile: MemberProfile { var copy = self; copy.identityVersion = nil; copy.avatarID = nil; copy.avatarImage = nil; copy.nickname = "薄肌成员"; return copy }

    func isFactConfirmed(_ field: String) -> Bool {
        if let factState { return factState[field]?.known == true }
        return legacyBasicsValid
    }
    private var legacyBasicsValid: Bool {
        (13...100).contains(age) && (50...250).contains(height) && (20...400).contains(weight)
    }
    /// Unknown/legacy-default body numbers must not feed rules or nutrition math.
    var hasConfirmedBasics: Bool {
        if let factState {
            guard factState["age_years"]?.known == true,
                  factState["height_cm"]?.known == true,
                  factState["profile_weight_kg"]?.known == true else { return false }
        }
        return legacyBasicsValid
    }
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
        guard profile.hasConfirmedBasics else {
            return NutritionTarget(caloriesMin: 0, caloriesMax: 0, proteinMin: 0, proteinMax: 0,
                fatMin: 0, fatMax: 0, meals: 3,
                note: "还没有确认年龄、身高和资料体重，暂不生成个性化热量与蛋白目标。你可以先记录饮食；补齐并核对资料后再计算，未填写的数值不会用示例数代替。",
                maintenanceMin: nil, maintenanceMax: nil, strategy: "需要核对资料", calculationVersion: 3,
                generalGuidanceOnly: true)
        }
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
    // C2：行动状态（可选字段，旧数据解码为 nil）。
    var actionStates: [ClubActionRecord]? = nil
    // E5：自由计划草稿/模板跨设备同步（可选字段，旧数据解码为 nil）。
    var planDrafts: [ManualPlanDraft]? = nil
    var planTemplates: [ManualPlanTemplate]? = nil
    var deletedPlanDraftIDs: [String]? = nil
    var deletedPlanTemplateIDs: [String]? = nil
    // 0.15.0 同步契约标记：>=2 表示本客户端认识 V2 字段（行动状态/草稿模板/目标体重）。
    // 服务端对无标记的旧客户端上传做前向保留；新客户端上传视为权威（删除走软删除标记）。
    var syncSchemaVersion: Int? = 2
}

#if DEBUG
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



#endif

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
        newExercise.workoutSessionID = current.workoutSessionID
        newExercise.planID = current.planID
        newExercise.sets = (0..<max(1, remaining)).map { _ in replacement.customExerciseID != nil ? TrainingSet(reps: replacement.customUnit == "秒" ? 0 : 10, durationSeconds: replacement.customUnit == "秒" ? 30 : nil) : ExerciseMeasurement.blankSet(name: replacement.name, query: replacement.libraryQuery) }
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

enum ExerciseNames {
    static func display(_ name: String, id: String? = nil, query: String? = nil) -> String {
        if let id, let label = byID[id] { return label }
        if let id = byQuery[(query ?? name).lowercased().trimmingCharacters(in: .whitespacesAndNewlines)], let label = byID[id] { return label }
        if name.range(of: "[\\u4E00-\\u9FFF]", options: .regularExpression) != nil { return name }
        return "未匹配动作"
    }
    private static let byID: [String: String] = ["0001": "四分之三仰卧起坐", "0002": "斜凳侧屈", "0003": "仰卧自行车卷腹", "1512": "四足跪姿股四头肌拉伸", "0006": "仰卧交替摸脚跟", "0007": "交替高位下拉", "1368": "脚踝环绕", "3293": "引体向上（射手式）", "3294": "射手俯卧撑", "2355": "臂套悬垂提膝", "2333": "臂套悬垂举腿", "3214": "双臂张开环形触趾（男）", "3204": "双臂上举全仰卧起坐（男）", "0009": "助力双杠撑胸", "0011": "助力悬垂提膝", "0010": "助力悬垂举膝下甩", "1708": "助力卧姿小腿拉伸", "1709": "辅助仰卧臀部拉伸", "1710": "辅助仰卧梨状肌拉伸", "0012": "助力卧姿举腿侧向下甩", "0013": "助力卧姿举腿下甩", "0014": "助力俄式转体（药球）", "0015": "助力对握引体向上", "0016": "辅助俯卧大腿后侧拉伸", "1713": "辅助俯卧股四头肌拉伸", "1714": "助力俯卧股直肌拉伸", "0017": "助力引体向上", "1716": "助力坐姿胸大肌拉伸（健身球）", "1712": "辅助侧卧大腿内侧拉伸", "1758": "辅助仰卧起坐", "1431": "助力反手引体向上", "1432": "助力站姿引体向上（固定器械）", "0018": "助力站姿肱三头肌伸展（毛巾）", "0019": "助力双杠臂屈伸", "2364": "助力跪姿宽距胸推（双杠臂屈伸，固定器械）", "3220": "跨步开合跳", "3672": "前后踏步", "1314": "健身球背部挺身", "3297": "后水平支撑", "1405": "背部胸肌拉伸", "1473": "向后跳", "0020": "平衡板", "0968": "弹力带交替弯举", "0969": "弹力带交替两头起", "0970": "弹力带辅助引体向上", "0971": "弹力带辅助健腹轮", "1254": "弹力带卧推", "0980": "弹力带俯身后踢腿", "0972": "弹力带自行车卷腹", "0974": "弹力带窄握下拉", "0975": "弹力带窄距俯卧撑", "0976": "弹力带集中弯举", "3117": "弹力带固定背部窄距下拉", "3116": "弹力带固定背部反手下拉", "0977": "弹力带前侧平举", "0978": "弹力带前平举", "1408": "弹力带臀桥", "0979": "弹力带帕洛夫推", "0981": "弹力带折刀仰卧起坐", "0983": "弹力带跪姿单臂下拉", "0985": "弹力带跪姿转体卷腹", "0984": "弹力带仰卧髋内旋", "1002": "弹力带仰卧直腿举腿", "0986": "弹力带单臂过头二头弯举", "0987": "弹力带单臂单腿分腿蹲", "0988": "弹力带站姿单臂低位划船", "0989": "弹力带单臂转体推胸", "0990": "弹力带坐姿单臂转体划船", "0991": "弹力带穿腿拉", "0992": "弹力带推举仰卧起坐", "0993": "弹力带反向飞鸟", "0994": "弹力带反向腕弯举", "0996": "弹力带坐姿髋内旋", "1011": "弹力带坐姿转体", "0997": "弹力带肩推", "1018": "弹力带耸肩", "0998": "弹力带侧向臂屈伸", "0999": "弹力带单腿提踵", "1000": "弹力带单腿抬脚尖", "1001": "弹力带分腿蹲", "1004": "弹力带深蹲", "1003": "弹力带深蹲划船", "1005": "弹力带站姿卷腹", "1022": "弹力带站姿后束划船", "1007": "弹力带站姿转体卷腹", "1008": "弹力带登台阶", "1009": "弹力带直腿硬拉（臀部）", "1023": "弹力带直背直腿硬拉", "1010": "弹力带直腿硬拉", "1012": "弹力带转体过头推举", "1369": "弹力带双腿提踵 -（弹力带置于双腿下）v.2", "1013": "弹力带反手下拉", "1014": "弹力带V字两头起", "1015": "弹力带过顶抗旋转推举", "1016": "弹力带腕弯举", "1017": "弹力带Y字举", "0023": "杠铃交替弯举", "0024": "杠铃箱式前蹲", "0025": "平板杠铃卧推", "0026": "杠铃箱式深蹲", "1316": "杠铃屈臂上拉", "0027": "杠铃俯身划船", "2407": "杠铃弯举（臂力板）", "0028": "杠铃高翻推举", "0029": "杠铃翻握前蹲", "0030": "窄握杠铃卧推", "0031": "杠铃弯举", "0032": "杠铃硬拉", "0033": "下斜杠铃卧推", "0034": "杠铃下斜屈臂上拉", "0035": "杠铃下斜窄距颅骨粉碎者推举", "1255": "杠铃下斜上拉", "0036": "杠铃下斜宽距推举", "0037": "杠铃下斜宽距上拉", "0038": "杠铃拖拽弯举", "1370": "杠铃站姿地面提踵", "0039": "杠铃胸前前蹲", "0041": "杠铃前平举", "0040": "杠铃前平举上拉", "0042": "杠铃前蹲", "0043": "杠铃深蹲", "1461": "杠铃深蹲（全蹲，背面视角）", "1462": "杠铃深蹲（全蹲，侧面视角）", "1545": "杠铃泽奇深蹲", "1409": "杠铃臀桥", "3562": "杠铃双腿凳上臀桥（男）", "0044": "杠铃早安式", "0045": "杠铃断头台卧推", "0046": "杠铃哈克深蹲", "1436": "高杠深蹲", "0047": "上斜杠铃卧推", "1719": "上斜杠铃窄握卧推", "0048": "杠铃上斜反握推举", "0049": "上斜凳杠铃划船", "0050": "杠铃上斜肩部前平举", "0051": "杠铃杰弗逊深蹲", "0052": "杠铃JM卧推", "0053": "杠铃深蹲跳", "1410": "杠铃侧弓步蹲", "1435": "低杠深蹲", "0054": "杠铃弓步蹲", "1720": "杠铃卧姿颈后肱三头肌伸展", "0055": "杠铃卧姿窄距推举", "0056": "杠铃卧姿窄距肱三头肌伸展", "0057": "杠铃卧姿臂屈伸", "0058": "杠铃卧姿髋部上挺", "0059": "杠铃卧姿牧师凳弯举", "0061": "杠铃卧姿肱三头肌屈伸", "0060": "杠铃仰卧臂屈伸（额前）", "0063": "杠铃窄站距深蹲", "0064": "杠铃单臂俯身划船", "0065": "杠铃单臂地板卧推", "0066": "杠铃单臂侧向硬拉", "0067": "杠铃单臂抓举", "0068": "杠铃单腿深蹲", "0069": "杠铃过顶深蹲", "1411": "杠铃掌心向下凳上腕弯举", "1412": "杠铃掌心向上凳上腕弯举", "3017": "潘德雷划船", "1751": "杠铃架上卧推", "0070": "杠铃牧师凳弯举", "0071": "杠铃负重仰卧起坐", "0072": "俯卧上斜杠铃弯举", "0073": "杠铃直臂上拉", "0022": "杠铃仰卧上拉接推举", "0074": "杠铃架上硬拉", "0075": "杠铃肩后束平举", "0076": "杠铃后束划船", "0078": "杠铃后撤弓步蹲", "0077": "杠铃后弓步 v.2", "0079": "杠铃反向腕弯举 v.2", "2187": "杠铃反握窄距卧推", "0080": "反握杠铃弯举", "0118": "反握杠铃俯身划船", "1256": "杠铃反握下斜卧推", "1257": "杠铃反握上斜卧推", "1317": "上斜凳杠铃反握划船", "1721": "杠铃反握碎颅者", "0081": "杠铃反握牧师凳弯举", "0082": "杠铃反向腕弯举", "0084": "杠铃滚轮健腹", "0083": "杠铃凳上滚轮健腹", "0085": "杠铃罗马尼亚硬拉", "0086": "杠铃坐姿颈后推举", "0087": "杠铃坐姿布拉德福德推举", "0088": "坐姿杠铃提踵", "1371": "杠铃坐姿提踵", "1718": "杠铃坐姿窄握颈后肱三头肌屈伸", "0089": "杠铃坐姿窄距集中弯举", "0090": "杠铃坐姿早安式", "0091": "坐姿杠铃肩推", "0092": "坐姿杠铃颈后臂屈伸", "0094": "杠铃坐姿转体", "0095": "杠铃耸肩", "0096": "杠铃侧屈 v. 2", "0098": "杠铃侧分腿蹲", "0097": "杠铃侧分腿蹲 v. 2", "1756": "杠铃单腿硬拉", "0099": "杠铃分腿蹲", "2799": "杠铃坐姿交替举腿", "2800": "杠铃坐姿交替抬腿（女性）", "0100": "杠铃滑雪式摆举", "0101": "杠铃快速深蹲", "2810": "杠铃分腿蹲 v. 2", "0102": "杠铃深蹲（跪姿）", "2798": "杠铃深蹲跳接后撤箭步蹲", "0103": "杠铃站姿健腹轮滚动", "0104": "杠铃背后腕弯举", "0105": "杠铃站姿布拉德福德推举", "1372": "杠铃站姿提踵", "0106": "杠铃窄握弯举", "1456": "窄握站姿杠铃肩推", "2414": "杠铃站姿集中弯举", "0107": "杠铃站姿前平举过头", "0108": "杠铃站姿腿举提踵", "0109": "杠铃站姿过头臂屈伸", "0110": "杠铃站姿反握弯举", "0111": "杠铃站姿摇摆提踵", "0112": "杠铃站姿转体", "1629": "杠铃站姿宽握二头弯举", "1457": "杠铃站姿宽握军事推举", "0113": "杠铃宽握弯举", "0114": "杠铃登阶", "0115": "杠铃直腿早安式", "0116": "杠铃直腿硬拉", "0117": "杠铃相扑硬拉", "3305": "杠铃深蹲推举", "0120": "杠铃直立划船", "0119": "杠铃直立划船 v. 2", "0121": "杠铃直立划船 v. 3", "0122": "平板杠铃宽握卧推", "1258": "杠铃宽握反握卧推", "0124": "杠铃宽站距深蹲", "0123": "宽握杠铃直立划船", "0126": "杠铃腕弯举", "0125": "杠铃腕弯举 v. 2", "0127": "杠铃泽奇深蹲", "3212": "基础触趾（男性）", "0128": "战绳", "3360": "熊爬", "1259": "辅助过头胸肌拉伸", "0129": "屈膝凳上臂屈伸", "1399": "地面凳上臂屈伸", "0130": "凳上髋伸展", "3019": "凳上引体向上", "3639": "屈膝卧姿扭转（男）", "1770": "腿部集中二头弯举", "0139": "窄距二头引体向上", "0140": "二头引体向上", "0137": "身体上推", "3543": "徒手深蹲跳下", "3544": "上斜侧平板支撑", "1771": "跪姿徒手臂屈伸", "1769": "侧卧徒手二头弯举", "3168": "徒手蹲姿划船", "3167": "徒手蹲姿划船（用毛巾）", "1373": "徒手站姿提踵", "3156": "徒手站姿窄距单臂划船", "3158": "徒手站姿窄距划船", "3162": "徒手站姿单臂划船", "3161": "徒手站姿单臂划船（用毛巾）", "3166": "徒手站姿划船", "3165": "徒手站姿划船（用毛巾）", "0138": "倒立支撑", "1374": "单腿落地箱跳稳定", "2466": "桥式登山者（交叉）", "1160": "波比跳", "0870": "仰卧抬臀", "1494": "蝴蝶式内收肌拉伸", "0148": "拉力器交替肩推", "0149": "拉力器交替肱三头肌伸展", "3235": "拉力器辅助反向腿弯举", "0150": "宽握高位下拉", "0151": "平板绳索卧推", "1630": "绳索窄握弯举", "1631": "绳索集中弯举", "0152": "拉力器集中伸展（膝上）", "0153": "拉力器交叉高位下拉", "0154": "绳索交叉反向飞鸟", "0155": "拉力器交叉变式", "0868": "绳索弯举", "0157": "拉力器硬拉", "0158": "下斜绳索飞鸟", "1260": "拉力器下斜单臂卧推", "1261": "下斜绳索双臂推胸", "0159": "拉力器下斜坐姿宽距划船", "1632": "绳索拖拽弯举", "0160": "绳索地面坐姿宽握划船", "0161": "拉力器前平举", "0162": "绳索前平举", "0164": "拉力器肩前平举", "0165": "绳索锤式弯举", "1722": "高位绳索过顶臂屈伸（杆把）", "0167": "跪姿绳索高位划船", "0168": "绳索髋内收", "0169": "上斜绳索卧推", "1318": "上斜凳绳索划船", "0171": "上斜绳索飞鸟", "0170": "拉力器上斜飞鸟（健身球上）", "0172": "拉力器上斜下压", "0173": "上斜绳索臂屈伸", "0174": "拉力器柔道翻", "0860": "绳索俯身臂屈伸", "0175": "绳索跪姿卷腹", "3697": "拉力器跪姿肩后束划船（绳索）（男）", "0176": "拉力器跪姿臂屈伸", "2330": "拉力器全幅度高位下拉", "0177": "绳索高位下拉（绳把）", "2616": "V把高位下拉", "0178": "绳索侧平举", "0179": "低位绳索夹胸", "0180": "拉力器低位坐姿划船", "1634": "仰卧绳索弯举", "0182": "拉力器卧姿窄距弯举", "0184": "仰卧绳索上拉（绳把）", "0185": "仰卧绳索飞鸟", "0186": "拉力器卧姿臂屈伸 v. 2", "0188": "中位绳索夹胸", "0189": "绳索单臂俯身划船", "0190": "单臂绳索弯举", "1262": "拉力器单臂下斜胸飞鸟", "1263": "拉力器单臂健身球飞鸟", "1264": "拉力器单臂健身球上斜飞鸟", "1265": "上斜绳索单臂推胸", "1266": "拉力器单臂健身球上斜卧推", "0191": "拉力器单臂侧向俯身平举", "0192": "单臂绳索侧平举", "1633": "绳索单臂牧师凳弯举", "1267": "拉力器单臂健身球卧推", "3563": "单臂高位下拉", "1635": "拉力器单臂反握牧师凳弯举", "0193": "跪姿绳索单臂高位划船", "1723": "单臂绳索下压", "1636": "双高位绳索弯举", "1637": "拉力器健身球过顶弯举", "0194": "绳索过顶臂屈伸（绳把）", "1319": "拉力器掌心旋转划船", "0195": "绳索牧师凳弯举", "1268": "拉力器健身球卧推", "0196": "绳索胯下拉", "0198": "拉力器下拉", "0197": "拉力器下拉（专业长杠）", "1638": "拉力器下拉二头弯举", "0201": "直杆绳索下压", "0199": "拉力器直臂下压 v.2", "0200": "绳索下压（绳把）", "0202": "绳索后束划船（双拉环）", "0203": "绳索俯身后束划船（绳把）", "0204": "拉力器后推", "0205": "拉力器后下拉", "0873": "绳索反向卷腹", "0206": "反握绳索弯举", "2406": "拉力器反握三头下压（Z杠）（配臂托）", "1413": "绳索单臂反握弯举", "0209": "绳索反握牧师凳弯举", "0210": "绳索反向腕弯举", "0207": "反握绳索下压", "0208": "反握坐姿绳索高位划船", "1320": "拉力器绳索交叉坐姿划船", "1321": "拉力器绳索高位坐姿划船", "1322": "拉力器绳索上斜卧推式划船", "1639": "绳索锤式牧师凳弯举（绳把）", "1724": "高位绳索过顶臂屈伸（绳把）", "1725": "拉力器绳索上斜三头臂屈伸", "1726": "地板绳索臂屈伸（绳把）", "1640": "拉力器绳索单臂锤式牧师弯举", "1323": "坐姿绳索划船（绳把）", "0211": "拉力器俄罗斯转体（健身球上）", "2144": "坐姿绳索推胸", "0212": "坐姿绳索卷腹", "1641": "坐姿绳索弯举", "0213": "拉力器坐姿高位划船（V把）", "0214": "绳索坐姿交替单臂划船", "1642": "拉力器坐姿单臂集中弯举", "1643": "拉力器坐姿过顶弯举", "0215": "坐姿绳索反向飞鸟", "0861": "绳索坐姿划船", "0216": "坐姿绳索肩内旋", "2399": "坐姿绳索转体", "0218": "宽握绳索坐姿划船", "0219": "绳索肩推", "0220": "绳索耸肩", "0222": "绳索侧屈", "0221": "拉力器侧弯卷腹（波速球）", "0223": "绳索侧卷腹", "1717": "绳索深蹲划船", "1644": "拉力器蹲姿弯举", "0224": "拉力器站姿后腕弯举", "1375": "站姿绳索提踵", "0225": "高位绳索反向飞鸟", "0226": "站姿绳索卷腹（杆把）", "0874": "站姿绳索卷腹（绳把）", "0227": "拉力器站姿飞鸟", "0228": "绳索站姿后踢腿", "0229": "拉力器站姿内侧弯举", "0230": "绳索斜向上提拉", "0231": "拉力器站姿单臂肱三头肌下压", "1376": "站姿绳索单腿提踵", "0232": "拉力器站姿下拉（绳索手柄）", "0233": "站姿绳索后束划船（绳把）", "1727": "拉力器站姿反握单臂过顶肱三头肌伸展", "0234": "站姿绳索划船（窄握把）", "0235": "绳索肩外旋", "0236": "拉力器站姿转体划船（V把）", "1269": "拉力器站姿直立交叉夹胸", "0238": "直臂下拉", "0237": "绳索直臂下拉", "0239": "拉力器直背坐姿划船", "0240": "拉力器仰卧反向飞鸟", "2464": "拉力器皮划艇式划船（Thibaudeau）", "0241": "绳索下压（V把）", "2405": "拉力器肱三头肌下压（V把）（配臂托板）", "0242": "绳索收膝反向卷腹", "0243": "绳索水平转体", "0862": "绳索伐木式转体（高位向低位）", "0244": "拉力器转体拉背", "1645": "拉力器上斜双臂弯举", "1728": "绳索双臂俯身臂屈伸", "0245": "反握高位下拉", "1270": "拉力器上胸交叉夹胸", "1324": "拉力器高位划船", "0246": "绳索直立划船", "1325": "拉力器宽握颈后下拉", "0247": "绳索腕弯举", "1407": "屈膝扶墙小腿拉伸", "1377": "靠墙小腿拉伸", "1378": "拉伸带小腿拉伸", "0248": "曲杆杠铃卧姿划船", "2963": "队长椅直腿举腿", "1548": "坐姿伸腿拉伸", "1271": "胸肌与肩前侧拉伸", "0251": "双杠撑胸", "1430": "双杠臂屈伸（综合训练架）", "2462": "直杆双杠臂屈伸", "1272": "健身球胸肌拉伸", "3216": "触胸俯卧撑（男）", "1326": "反手引体向上", "0253": "窄距对握引体向上", "0257": "绕膝小腿拉伸", "1273": "击掌俯卧撑", "0258": "时钟俯卧撑", "1327": "窄握反手引体向上", "0259": "窄距俯卧撑", "2398": "跪姿窄距俯卧撑", "0260": "收膝两头起", "1468": "蟹式转体触脚尖", "0262": "交叉卷腹", "0267": "双手过顶卷腹", "0271": "健身球卷腹", "0272": "健身球直臂卷腹", "0274": "卷腹", "3016": "仰卧起坐", "3769": "交叉后撤弓步蹲", "2331": "健身车椭圆机", "0276": "死虫式", "0277": "下斜卷腹", "0279": "下斜俯卧撑", "0282": "下斜仰卧起坐", "1274": "哑铃支撑深度俯卧撑", "0283": "钻石俯卧撑", "0284": "徒手驴式提踵", "1275": "释手俯卧撑", "0285": "哑铃交替弯举", "2403": "哑铃交替二头弯举（使用手臂训练板）", "1646": "哑铃交替锤式牧师凳弯举", "1647": "哑铃交替牧师凳弯举", "1648": "哑铃交替坐姿锤式弯举", "0286": "哑铃交替侧推", "1649": "哑铃交替二头弯举（健身球上抬腿）", "1650": "哑铃健身球坐姿交替二头弯举", "2137": "阿诺德推举", "0287": "哑铃阿诺德推举 v.2", "0288": "哑铃绕头上拉", "0289": "平板哑铃卧推", "0290": "哑铃坐姿推举", "0291": "哑铃箱式深蹲", "0293": "双臂哑铃俯身划船", "1651": "哑铃二头弯举弓步（保龄球动作）", "1652": "哑铃健身球二头弯举（抬腿）", "1653": "哑铃鹤立二头弯举", "0294": "哑铃弯举", "2401": "哑铃弯举（带臂托）", "1654": "哑铃反握弯举", "1655": "哑铃深蹲弯举", "1656": "哑铃V坐波速球弯举", "1201": "哑铃波比跳", "0295": "哑铃高翻", "1731": "哑铃窄距推举", "0296": "哑铃窄距推举", "0297": "哑铃集中弯举", "3635": "哑铃对侧负重前弓步蹲", "0298": "哑铃交叉锤式弯举", "1657": "哑铃交叉锤式弯举 v. 2", "0299": "哑铃古巴推举", "2136": "哑铃古巴推举 v. 2", "0300": "哑铃硬拉", "0301": "下斜哑铃卧推", "0302": "下斜哑铃飞鸟", "0303": "下斜哑铃对握卧推", "1276": "哑铃下斜单臂飞鸟", "1617": "哑铃下斜单臂锤式推举", "0305": "哑铃下斜耸肩", "0304": "哑铃下斜耸肩 v. 2", "0306": "哑铃下斜三头肌臂屈伸", "0307": "哑铃下斜转体飞鸟", "1437": "哑铃手指弯举", "0308": "平板哑铃飞鸟", "1277": "哑铃健身球飞鸟", "1732": "哑铃前弓步三头肌臂屈伸", "0310": "哑铃前平举", "0309": "哑铃前平举 v. 2", "0311": "哑铃全罐侧平举", "1760": "哑铃高脚杯深蹲", "0313": "哑铃锤式弯举", "1659": "哑铃健身球锤式弯举", "0312": "哑铃锤式弯举 v. 2", "2402": "哑铃锤式弯举（带臂托）", "1664": "哑铃高位弯举", "3545": "上斜哑铃交替卧推", "0314": "上斜哑铃卧推", "0315": "上斜凳哑铃弯举", "0316": "哑铃上斜推胸", "0318": "哑铃上斜弯举", "0317": "哑铃上斜弯举 v. 2", "0319": "上斜哑铃飞鸟", "1278": "哑铃上斜健身球飞鸟", "0320": "上斜凳哑铃锤式弯举", "0321": "上斜对握哑铃卧推", "1618": "健身球上哑铃上斜锤式卧推", "0322": "哑铃上斜内侧二头弯举", "1279": "哑铃上斜单臂飞鸟", "1280": "健身球上哑铃上斜单臂飞鸟", "1619": "哑铃上斜单臂锤式卧推", "1620": "健身球上哑铃上斜单臂锤式卧推", "0323": "上斜侧卧哑铃单臂侧平举", "1281": "上斜哑铃单臂卧推", "1282": "健身球上哑铃上斜单臂卧推", "0324": "哑铃上斜对握卧推", "1283": "健身球上哑铃上斜卧推", "0325": "哑铃上斜上举", "0326": "上斜凳哑铃反向飞鸟", "0327": "上斜凳哑铃划船", "0328": "哑铃上斜肩上举", "0329": "上斜凳哑铃耸肩", "3542": "哑铃上斜T字平举", "0330": "上斜哑铃臂屈伸", "0331": "哑铃上斜旋转飞鸟", "1733": "哑铃上斜双臂臂屈伸", "3541": "上斜凳哑铃Y字举", "0332": "哑铃十字举", "0333": "哑铃俯身臂屈伸", "1734": "健身球上哑铃俯身臂屈伸", "1660": "健身球上跪姿哑铃二头弯举", "0334": "哑铃侧平举", "0335": "哑铃侧转前平举", "0336": "哑铃弓步蹲", "1658": "哑铃弓步蹲接二头弯举", "0337": "哑铃卧姿臂屈伸（横过面部）", "1729": "仰卧哑铃交替臂屈伸", "0338": "哑铃卧姿肘推", "0863": "侧卧哑铃肩外旋", "0339": "俯卧哑铃腿弯举", "0340": "对握哑铃卧推", "2470": "哑铃卧姿地面肩后束平举", "0341": "哑铃卧姿单臂后束平举", "0343": "哑铃卧姿单臂卧推", "0342": "哑铃卧姿单臂卧推 版本2", "0344": "仰卧哑铃单臂正握臂屈伸", "0345": "哑铃卧姿单臂俯身侧平举", "0346": "哑铃卧姿单臂旋后臂屈伸", "0347": "哑铃卧姿前臂旋前", "2705": "地面哑铃卧姿前臂旋前", "1284": "健身球上哑铃卧姿上拉", "1328": "哑铃俯卧后束划船", "0348": "哑铃卧姿俯身侧平举", "1735": "哑铃卧姿单侧臂屈伸", "0349": "哑铃卧姿旋后弯举", "2706": "地板哑铃卧姿旋后弯举", "1661": "哑铃仰卧二头弯举", "0350": "哑铃仰卧弯举", "0351": "哑铃仰卧臂屈伸", "1662": "哑铃卧姿宽距弯举", "0352": "哑铃对握卧推", "1285": "哑铃单臂卧推飞鸟", "0292": "单臂哑铃划船", "1286": "健身球哑铃单臂胸部飞鸟", "0353": "健身球哑铃单臂集中弯举", "1287": "哑铃单臂下斜胸推", "1288": "健身球哑铃单臂飞鸟", "1736": "健身球哑铃单臂法式推举", "1663": "哑铃单臂锤式牧师凳弯举", "1621": "健身球哑铃单臂锤式推举", "1289": "哑铃单臂上斜胸推", "0354": "哑铃单臂臂屈伸后踢", "0355": "哑铃单臂侧平举", "0356": "扶撑单臂哑铃侧平举", "1290": "健身球哑铃单臂推举", "1665": "哑铃单臂俯卧弯举", "1666": "哑铃单臂俯卧锤式弯举", "1291": "健身球哑铃单臂仰卧上拉", "0358": "哑铃单臂反向腕弯举", "0359": "支撑哑铃单臂反向飞鸟", "1622": "哑铃单臂反握推举", "1414": "哑铃单臂反握牧师凳弯举", "1667": "哑铃单臂反向蜘蛛弯举", "1668": "健身球哑铃单臂坐姿二头弯举", "1669": "坐姿哑铃单臂锤式弯举", "1415": "坐姿哑铃单臂中立握腕弯举", "0361": "单臂哑铃肩推", "0360": "哑铃单臂肩推 V. 2", "3888": "哑铃单臂抓举", "1670": "哑铃单臂站姿弯举", "1671": "哑铃单臂站姿锤式弯举", "0362": "哑铃单臂凳上臂屈伸", "0363": "哑铃单臂直立划船", "0364": "哑铃单臂腕弯举", "1672": "哑铃单臂佐特曼牧师凳弯举", "1292": "健身球单腿哑铃飞鸟", "0365": "凳上哑铃中立腕弯举", "0366": "凳上哑铃单臂中立腕弯举", "1441": "凳上哑铃单臂反向腕弯举", "0367": "凳上哑铃单臂腕弯举", "0368": "凳上哑铃反向腕弯举", "0369": "哑铃腕弯举", "1329": "哑铃旋握俯身划船", "1623": "哑铃对握上斜卧推", "0370": "哑铃牧师凳锤式弯举", "0371": "哑铃增强式深蹲", "0372": "哑铃牧师凳弯举", "1673": "健身球上哑铃牧师凳弯举", "1293": "健身球上哑铃卧推", "0373": "哑铃旋前握法肱三头肌臂屈伸", "0374": "哑铃俯身上斜弯举", "1674": "俯卧上斜哑铃锤式弯举", "0375": "哑铃上拉", "1294": "健身球上哑铃仰卧上拉髋部伸展", "1295": "健身球上哑铃仰卧上拉", "1700": "哑铃借力推举", "0376": "哑铃抬举", "2292": "哑铃肩后束平举", "0377": "哑铃后束划船", "0378": "哑铃俯身反向飞鸟", "0380": "哑铃俯身侧平举", "0379": "哑铃俯身侧平举（头部支撑）", "0381": "哑铃后撤弓步蹲", "0382": "哑铃反握二头弯举", "1624": "哑铃反握卧推", "0383": "哑铃俯身反向飞鸟", "1330": "哑铃反握上斜凳单臂划船", "1331": "上斜凳哑铃双臂反握划船", "2327": "哑铃反握划船（女）", "0384": "哑铃反握牧师凳弯举", "1675": "哑铃反向蜘蛛弯举", "0385": "哑铃反向腕弯举", "1459": "哑铃罗马尼亚硬拉", "0386": "哑铃旋体反向飞鸟", "2397": "哑铃斯科特推举", "0387": "坐姿哑铃交替前平举", "1676": "健身球上哑铃坐姿交替锤式弯举", "0388": "坐姿哑铃交替肩推", "3546": "哑铃坐姿交替肩推", "0389": "坐姿哑铃颈后臂屈伸", "2317": "坐姿哑铃屈臂侧平举", "1730": "哑铃坐姿俯身交替臂屈伸", "1737": "哑铃坐姿俯身肱三头肌伸展", "1677": "哑铃坐姿二头弯举", "0390": "哑铃坐姿二头弯举（健身球上）", "3547": "哑铃坐姿二头弯举接肩推", "1379": "哑铃坐姿提踵", "0391": "坐姿哑铃弯举", "0392": "坐姿哑铃前平举", "1678": "坐姿哑铃锤式弯举", "0393": "坐姿哑铃内侧二头弯举", "0394": "坐姿哑铃臂屈伸", "0396": "坐姿哑铃侧平举", "0395": "坐姿哑铃侧平举 v. 2", "0397": "坐姿哑铃中立握腕弯举", "1679": "健身球上抬腿坐姿哑铃单臂二头弯举", "0398": "坐姿哑铃单臂俯身臂屈伸", "0399": "坐姿哑铃前臂旋转", "0400": "坐姿哑铃单腿提踵", "1380": "坐姿哑铃单腿提踵 - 锤式握法", "1381": "坐姿哑铃单腿提踵 - 掌心朝上", "0401": "坐姿哑铃掌心朝上腕弯举", "0402": "坐姿哑铃牧师凳弯举", "0403": "坐姿哑铃反握集中弯举", "1738": "坐姿哑铃反握单臂过顶臂屈伸", "0405": "坐姿哑铃肩推", "0404": "坐姿对握哑铃肩推", "2188": "坐姿哑铃肱三头肌伸展", "0406": "哑铃耸肩", "0407": "哑铃侧屈", "0408": "哑铃侧卧单手上举", "3664": "哑铃侧平板支撑反向飞鸟", "3548": "哑铃单臂过顶行走", "0409": "哑铃单腿提踵", "1757": "哑铃单腿硬拉", "2805": "哑铃单腿硬拉（台阶支撑）", "0410": "哑铃保加利亚分腿蹲", "0411": "哑铃单腿深蹲", "0413": "哑铃深蹲", "3560": "站姿哑铃交替锤式弯举加推举", "0414": "站姿哑铃交替肩推", "0415": "站姿哑铃交替平举", "1739": "站姿哑铃交替肱三头肌后撑", "2143": "站姿哑铃绕环", "1740": "站姿俯身哑铃单臂肱三头肌伸展", "1741": "站姿俯身哑铃双臂肱三头肌伸展", "0416": "站姿哑铃二头弯举", "0417": "哑铃站姿提踵", "0418": "站姿哑铃集中弯举", "0419": "站姿哑铃前平举过顶", "2321": "站姿哑铃内侧二头弯举 v. 2", "0420": "站姿哑铃臂屈伸", "0421": "站姿哑铃单臂集中弯举", "0422": "站姿哑铃单臂弯举（上斜凳上方）", "1680": "站姿哑铃单臂上斜凳弯举", "0423": "站姿哑铃单臂伸展", "0424": "站姿哑铃单臂掌心向内推举", "0425": "站姿哑铃单臂反握弯举", "0426": "站姿哑铃肩推", "0427": "站姿对握哑铃肩推", "0428": "哑铃站姿牧师弯举", "0429": "哑铃站姿反弯举", "0430": "站姿哑铃颈后臂屈伸", "2293": "哑铃站姿佐特曼牧师弯举", "1684": "哑铃单腿平衡登台阶弯举", "0431": "哑铃登阶", "2796": "哑铃登台阶接弓步蹲", "2812": "哑铃登台阶分腿蹲", "0432": "哑铃直腿硬拉", "0433": "哑铃直臂上拉", "0434": "哑铃直腿硬拉", "2808": "哑铃相扑拉过", "2803": "哑铃扶持深蹲", "0436": "哑铃泰特推举", "1742": "哑铃单腿支撑俯身臂屈伸", "1743": "哑铃转腕卧推", "0437": "哑铃直立划船", "1765": "哑铃直立划船（背面视角）", "0864": "哑铃肩外旋", "5201": "哑铃侍者弯举", "0438": "哑铃W推举", "0439": "佐特曼弯举", "2294": "哑铃佐特曼牧师弯举", "2189": "哑铃坐姿臂屈伸", "1167": "动态扩胸", "3287": "肘部臂屈伸", "1772": "肘部抬起反向俯卧撑", "0443": "仰卧肘触膝", "3292": "升降", "1332": "健身球交替抬臂", "1333": "健身球背伸展（双臂伸直）", "1334": "健身球背伸展（双手抱头）", "1335": "健身球背伸展（膝离地）", "1336": "健身球背伸展（加旋转）", "1744": "健身球臂屈伸", "1559": "健身球髋屈肌拉伸", "1338": "健身球拥抱", "1339": "健身球背阔肌拉伸", "1341": "健身球下背拉伸（金字塔式）", "1342": "健身球侧卧背阔肌拉伸", "1382": "健身球靠墙提踵", "3241": "健身球靠墙提踵（踝间夹网球）", "3240": "健身球靠墙提踵（膝间夹网球）", "1416": "健身球单腿俯卧下肢旋转", "1417": "健身球单腿对角踢腘绳肌弯举", "1296": "健身球屈体俯卧撑", "1343": "健身球俯卧抬腿", "1560": "健身球坐姿大腿后侧拉伸", "1745": "健身球坐姿肱三头肌拉伸", "1746": "仰卧健身球哑铃肱三头肌臂屈伸", "1747": "健身球曲杆仰卧臂屈伸", "3010": "曲杠屈臂上拉", "1748": "曲杠仰卧头后臂屈伸", "1344": "曲杆反握俯身划船", "1682": "曲杆坐姿窄握集中弯举", "1749": "曲杠站姿过顶臂屈伸", "0445": "曲杆反重力推举", "1627": "曲杆窄握牧师凳弯举", "0446": "曲杠窄握弯举", "0447": "曲杠弯举", "0448": "曲杆下斜窄握面部推举", "2186": "下斜曲杠臂屈伸", "0449": "上斜曲杠臂屈伸", "0450": "曲杆JM推举", "0451": "反握曲杠弯举", "0452": "曲杠反握牧师凳弯举", "1458": "坐姿曲杠弯举", "0453": "坐姿曲杠颈后臂屈伸", "0454": "曲杠蜘蛛弯举", "1628": "曲杆俯身弯举", "2404": "曲杆二头弯举（带手臂训练板）", "2432": "曲杆窄握卧推", "2741": "曲杠宽握弯举", "2133": "农夫行走", "0455": "杠铃手指弯举", "3303": "人体旗帜", "0456": "屈膝举腿仰卧起坐", "0457": "直臂举腿仰卧起坐", "0458": "杠铃地面飞鸟", "0459": "仰卧交替打腿", "1472": "立定跳远", "3470": "徒手前弓步蹲", "3194": "科学怪人深蹲", "2429": "蛙式卷腹", "3301": "蛙式水平支撑", "3296": "前水平", "3295": "前水平（重复练习）", "0464": "高位平板支撑转体", "3315": "全十字支撑", "3299": "全水平支撑", "3327": "全水平支撑俯卧撑", "0466": "吉龙达胸骨引体", "3561": "臀桥交替抬腿", "3523": "双脚放凳臀桥", "3193": "臀腿挺身", "0467": "大猩猩引体", "0469": "腹股沟卷腹", "1383": "哈克机提踵", "1384": "哈克机单腿提踵", "3221": "半蹲（男）", "3202": "半仰卧起坐", "1511": "腘绳肌拉伸", "2139": "手摇功率车", "3218": "十指相扣环形触趾（男）", "3215": "反握相扣环形触趾（男）", "3302": "倒立", "0471": "倒立俯卧撑", "1764": "悬垂屈腿抬髋", "0472": "悬垂举腿", "1761": "悬垂侧向提膝", "0473": "悬垂屈体", "0474": "悬垂直腿抬髋", "0475": "悬垂直腿举腿", "0476": "悬垂转体举腿", "3636": "靠墙高抬腿", "0484": "屈膝抬髋", "1418": "仰卧抱膝拉伸", "3234": "海特哑铃飞鸟", "0489": "罗马椅背伸", "0488": "凳上背部挺身", "3289": "不可能臂屈伸", "1471": "毛毛虫爬行", "3698": "毛毛虫爬 第2版", "0490": "上斜窄距俯卧撑", "0491": "上斜凳直腿抬髋", "0492": "上斜俯卧撑深度跳", "0493": "上斜俯卧撑", "3785": "上斜俯卧撑（箱上）", "0494": "上斜反握俯卧撑", "3011": "上斜肩胛俯卧撑", "0495": "上斜凳转体仰卧起坐", "1564": "中级髋屈肌与股四头肌拉伸", "0496": "北欧腿弯举（凳上固定）", "2400": "辅助北欧腿弯举（器械支撑）", "0499": "反向划船", "2300": "屈膝反向划船", "2298": "反向划船（凳上）", "0497": "反向划船 第2版", "0498": "悬挂带反向划船", "1419": "仰卧交叉转体拉伸", "1297": "胸前等长挤压", "0500": "等长雨刷式", "0501": "开合波比跳", "3224": "开合跳", "0507": "V字两头起", "0508": "Janda仰卧起坐", "2612": "跳绳", "0514": "深蹲跳", "0513": "深蹲跳 V.2", "0517": "壶铃进阶风车", "0518": "壶铃交替悬垂翻", "0520": "壶铃交替肩推", "0519": "壶铃交替地板卧推", "0521": "壶铃交替支撑划船", "0522": "壶铃交替俯身划船", "0523": "壶铃阿诺德推举", "0524": "壶铃屈体推举", "0525": "壶铃悬垂位底朝上翻", "0526": "壶铃双交替悬垂翻", "0527": "壶铃双臂挺举", "0528": "双壶铃借力推举", "0529": "壶铃双臂抓举", "0530": "壶铃双臂风车", "0531": "壶铃地面加长行程单臂推举", "0532": "壶铃绕胯", "0533": "壶铃前蹲", "0534": "壶铃高脚杯深蹲", "0535": "壶铃悬垂翻", "0536": "壶铃箭步蹲胯下传递", "0537": "壶铃单臂翻挺", "1298": "壶铃单臂地板卧推", "0538": "壶铃单臂挺举", "0539": "壶铃单臂侧向军式推举", "0540": "壶铃单臂借力推举", "0541": "壶铃单臂划船", "0542": "壶铃单臂抓举", "0543": "壶铃海盗船腿", "0544": "壶铃手枪深蹲", "0545": "壶铃爆发俯卧撑", "0546": "坐姿壶铃肩推", "1438": "壶铃坐姿双臂军式推举", "0547": "壶铃跷跷板推举", "0548": "壶铃相扑高拉", "0549": "壶铃摆荡", "0550": "壶铃深蹲推举", "0551": "壶铃土耳其起立（深蹲式）", "0552": "双壶铃高翻", "0553": "双壶铃肩推", "1345": "壶铃双臂划船", "0554": "壶铃风车", "0555": "踢腿坐姿收腹", "0558": "摆浪引体上拉", "3640": "触膝卷腹", "1420": "跪姿跳箱深蹲", "1346": "跪姿背阔肌拉伸", "3239": "跪姿平板支撑拍肩", "3211": "跪姿俯卧撑", "3288": "韩式臂屈伸", "3418": "L形引体向上", "3419": "地面L支撑", "0562": "杠铃地雷转体", "3237": "杠铃地雷侧平举", "3300": "前倾俄式挺身", "2271": "左勾拳·拳击", "0570": "平凳收膝", "1576": "仰卧抬腿腘绳肌拉伸", "2287": "固定器械交替腿举", "0571": "器械交替窄握划船", "0572": "固定器械辅助引体向上", "0573": "器械背伸", "0574": "杠杆俯身划船", "3200": "T杠划船（V把）", "0575": "器械弯举", "2289": "固定器械小腿推举", "0577": "器械推胸", "0576": "固定器械卧推", "0578": "器械硬拉", "1300": "器械下斜推胸", "1253": "器械驴式提踵", "0579": "器械高位下拉", "0580": "固定器械免握耸肩", "1439": "固定器械免握耸肩 第二版", "2288": "器械握力训练", "1615": "器械锤式牧师凳弯举", "0581": "器械高位划船", "2286": "器械髋后伸", "2611": "水平腿举机单腿腿举", "1299": "器械上斜推胸", "1479": "固定器械上斜卧推 第二版", "0582": "跪姿单腿腿弯举", "0583": "器械跪姿转体", "0584": "器械侧平举", "0585": "坐姿腿屈伸", "0586": "俯卧腿弯举", "3195": "器械双腿抬起单腿下放腿弯举", "0587": "固定器械肩推", "0588": "器械窄握坐姿划船", "0589": "杠杆单臂俯身划船", "1356": "器械单臂高位划船", "1347": "器械单臂宽握下拉", "0590": "器械单臂肩推", "0591": "固定器械正握臂屈伸", "0592": "器械牧师凳弯举", "1614": "固定器械牧师凳弯举 v.2", "2285": "器械上拉", "2736": "器械反握高位下拉", "1616": "固定器械反握牧师凳弯举", "1348": "器械反握划船", "0593": "器械反向背伸", "1349": "固定器械反向T杠划船", "2315": "固定器械旋转提踵", "2335": "固定器械坐姿小腿推举", "0594": "器械坐姿提踵", "1452": "器械坐姿卷腹", "0595": "胸垫式器械卷腹", "3760": "固定器械坐姿卷腹 v.2", "1451": "器械坐姿下压", "0596": "蝴蝶机夹胸", "3759": "器械坐姿早安式", "0597": "坐姿髋外展", "0598": "坐姿髋内收", "0599": "坐姿腿弯举", "0600": "器械举腿卷腹", "0602": "反向蝴蝶机", "0601": "对握反向蝴蝶机", "1350": "器械坐姿划船", "1385": "固定器械腿举机坐姿提踵", "0603": "器械肩推", "0869": "固定器械肩推 v.2", "2318": "固定器械肩推 v.3", "0604": "器械耸肩", "0605": "器械站姿提踵", "3758": "固定器械站姿胸推", "0606": "T杠划船", "1351": "器械反握杠杆划船", "0607": "器械臂屈伸", "1313": "器械单臂划船", "0609": "伦敦桥", "3013": "徒手臀桥", "1352": "下背卷曲", "3582": "交替弓步跳", "1688": "弓步蹲接转体", "0613": "侧卧股四头肌拉伸", "2312": "卧姿肘触膝", "0620": "凳上仰卧举腿", "0865": "仰卧举腿抬髋", "1301": "固定器械内侧胸推", "0624": "靠墙高抬腿坐", "1353": "药球接球过顶抛", "1302": "药球胸前传球", "1303": "三点支撑药球胸前推", "1304": "药球胸前推多次抛出", "1305": "药球胸前推单次抛出", "1312": "药球跑动胸前推抛", "1701": "药球窄距俯卧撑", "1354": "药球砸地", "1750": "仰卧药球胸上抛", "0627": "正反握引体向上", "3217": "改良版印度俯卧撑（男）", "1421": "前臂支撑改良俯卧撑", "0628": "弹力带怪兽走", "0630": "登山跑", "0631": "双力臂", "1401": "双力臂（竖杆）", "2328": "健身球窄距俯卧撑", "1403": "颈侧拉伸", "0634": "离心卷腹", "1495": "侧腹卷腹 第2版", "0635": "侧卧卷腹", "0636": "奥林匹克杠铃锤式弯举", "0637": "奥林匹克杠铃臂屈伸", "1355": "单臂贴墙划船", "0638": "单臂引体向上", "0639": "单臂臂屈伸", "0640": "药球单臂砸地", "1773": "单臂毛巾划船", "1386": "单腿驴式提踵", "1387": "徒手单腿提踵", "1476": "单腿蹲", "0641": "负重仰卧起坐", "0642": "外侧踢腿俯卧撑", "0643": "肱三头肌过顶拉伸", "3147": "骨盆后倾练习", "1422": "骨盆后倾接臀桥", "1388": "腓骨肌拉伸", "3662": "折刀式接眼镜蛇式俯卧撑", "1306": "爆发俯卧撑", "1687": "后撤步接过顶伸展", "1389": "胫骨后肌拉伸", "3119": "蹲便深蹲", "3132": "扶持深蹲活动度练习", "0648": "高翻", "3665": "高位平板支撑", "3203": "囚徒半仰卧起坐（男）", "1707": "俯卧瑜伽球转体", "0651": "对握引体向上", "0650": "健身球收膝", "0652": "引体向上", "1689": "徒手推拉", "3638": "前倾加速跑", "1307": "波速球俯卧撑", "0662": "标准俯卧撑", "0653": "俯卧撑（波速球）", "0655": "俯卧撑（瑜伽球）", "0656": "俯卧撑（瑜伽球）", "0659": "墙壁俯卧撑", "0658": "俯卧撑（墙壁）v.2", "0660": "哑铃支撑窄距俯卧撑", "0661": "俯卧撑内侧踢腿", "0663": "药球支撑俯卧撑", "1467": "前臂俯卧撑", "3145": "俯卧撑加肩胛前伸", "0664": "俯卧撑接侧支撑", "3533": "股四头肌训练", "3201": "四分之一仰卧起坐", "3552": "原地快速碎步", "0666": "单臂抬高俯卧撑", "0668": "后下斜桥", "0669": "肩后侧拉伸", "0670": "后引体向上", "1582": "仰卧拉伸带大腿后侧拉伸", "3236": "弹力带跪姿髋推", "3007": "弹力带腿屈伸", "3123": "坐姿弹力带弯举", "3124": "弹力带坐姿推胸", "3006": "弹力带坐姿髋外展", "3122": "坐姿弹力带肩推", "3144": "弹力带坐姿划船", "0872": "反向卷腹", "0672": "反向臂屈伸", "0673": "反握固定器械高位下拉", "0674": "反握引体向上", "0675": "健身球反向挺身", "1423": "凳上反向背伸", "3663": "反向平板支撑抬腿", "0677": "吊环臂屈伸", "2571": "青蛙式拉伸", "0678": "Rocky引体下拉", "2208": "泡沫轴背部放松", "2204": "滑动支撑前后移", "2205": "泡沫轴髋背阔肌拉伸", "2202": "泡沫轴臀部放松", "2206": "健腹轮反向卷腹", "2203": "健腹轮坐姿肩屈下压回收", "2209": "健腹轮坐姿单腿肩屈下压回收", "2207": "健腹轮侧背阔肌拉伸", "0680": "爬绳", "0685": "跑步", "0684": "跑步机跑步", "1585": "跑者弓步拉伸", "0687": "俄罗斯转体", "3012": "肩胛臂屈伸", "3021": "肩胛俯卧撑", "0688": "肩胛引体向上", "3219": "剪刀跳", "1390": "坐姿小腿拉伸", "1424": "坐姿臀部拉伸", "0689": "坐姿举腿", "0690": "坐姿下背部拉伸", "2567": "坐姿梨状肌拉伸", "0691": "靠墙坐姿侧卷腹", "1587": "坐姿宽距前屈伸展", "0697": "自辅助反向腿弯举", "1766": "自辅助反向腿弯举", "0696": "自助北欧腿弯举（地面）", "3222": "半蹲跳", "3656": "小步跑", "1763": "对握引体向上", "3699": "高位平板支撑交替拍肩", "0699": "拍肩俯卧撑", "1774": "侧桥抬腿", "0705": "侧桥", "0709": "侧髋（双杠上）", "0710": "侧卧抬腿", "1358": "侧卧地板拉伸", "3667": "侧卧髋内收", "1775": "侧支撑髋内收", "0716": "侧推颈部拉伸", "0717": "侧卧单臂推起", "0721": "手腕拉伸", "0720": "左右引体", "3213": "左右交替触脚尖", "0725": "单臂俯卧撑", "3645": "单腿臀桥", "0727": "单腿提踵（踩哑铃）", "0730": "滑行盘单腿腿弯举", "1759": "手枪深蹲", "1489": "徒手西西深蹲", "0735": "仰卧起坐", "3679": "双手抱胸仰卧起坐", "3361": "滑冰跳", "2142": "滑雪机", "3671": "滑雪步", "3304": "翻转身体（skin the cat）", "1425": "单腿45度腿举", "0738": "45度腿举机提踵", "0739": "45度腿举", "1464": "45度雪橇机腿举（背面视角）", "1463": "45度雪橇机腿举（侧面视角）", "0740": "宽站距45度腿举", "1391": "雪橇机腿举位提踵", "0741": "哈克机窄站距深蹲", "0742": "前倾角度雪橇提踵", "0743": "哈克深蹲机深蹲", "2334": "雪橇机卧式小腿推举", "0744": "卧式蹬腿机深蹲", "1392": "腿举机单腿提踵", "1496": "大锤砸轮胎", "0746": "史密斯机背后耸肩", "0747": "史密斯机颈后推举", "0748": "平板史密斯卧推", "0749": "史密斯机屈膝早安式", "1359": "史密斯俯身划船", "0750": "史密斯箱式深蹲", "0751": "窄握史密斯卧推", "0752": "史密斯硬拉", "0753": "下斜史密斯卧推", "0754": "史密斯机下斜反握推举", "1433": "史密斯前蹲", "3281": "史密斯机全蹲", "0755": "史密斯哈克深蹲", "0756": "史密斯仰卧抬髋", "0757": "上斜史密斯卧推", "0758": "史密斯机上斜反握推举", "0759": "史密斯机上斜肩部平举", "0760": "史密斯机腿举", "1434": "史密斯低杠深蹲", "1683": "史密斯机二头弯举", "1625": "史密斯机下斜窄距卧推", "1752": "史密斯机上斜肱三头肌伸展", "1626": "史密斯机反向下斜窄距卧推", "0761": "史密斯窄握划船", "1360": "史密斯单臂划船", "1393": "史密斯单腿提踵", "0762": "史密斯后束划船", "0763": "史密斯反向提踵", "1394": "史密斯机反向提踵", "1361": "反握史密斯俯身划船", "0764": "平板史密斯反握卧推", "1395": "史密斯机坐姿单腿提踵", "0765": "坐姿史密斯肩推", "1426": "史密斯机坐姿腕弯举", "0766": "史密斯机肩推", "0767": "史密斯耸肩", "0768": "史密斯保加利亚分腿蹲", "0769": "史密斯机冲刺弓步", "0770": "史密斯深蹲", "0771": "史密斯机站姿背后腕弯举", "0772": "史密斯机站姿颈后军式推举", "0773": "史密斯站姿提踵", "0774": "站姿史密斯肩推", "3142": "史密斯相扑深蹲", "1396": "史密斯抬脚尖", "0775": "史密斯直立划船", "1308": "史密斯机宽握卧推", "1309": "史密斯机宽握下斜卧推", "0776": "抓举拉", "0777": "哑铃交替转体（施法者）", "1362": "俯卧前臂撑起（斯芬克斯式）", "0778": "蜘蛛爬俯卧撑", "1363": "脊柱拉伸", "2329": "坐姿脊柱转体", "2368": "徒手分腿蹲", "0786": "深蹲挺举", "1705": "波速球深蹲", "1685": "深蹲上举过头", "1686": "深蹲上举过头加转体", "2297": "瑞士球卷腹（全范围双手抱头）", "3291": "施塔尔德推", "3669": "站姿拉弓", "0788": "站姿颈后推举", "1490": "台阶提踵", "1397": "站姿小腿", "1398": "站姿小腿拉伸", "1599": "拉伸带站姿大腿后侧与小腿拉伸", "0794": "站姿侧屈拉伸", "1364": "站姿骨盆倾斜", "0795": "站姿单腿腿弯举", "0796": "站姿健腹轮滚动", "3223": "星形跳", "2138": "固定单车骑行", "0798": "动感单车走", "3314": "分腿马耳他", "3298": "分腿水平支撑", "1427": "站姿直腿髋外展", "0803": "超人俯卧撑", "0805": "悬挂训练带前伸", "0806": "悬挂训练带俯卧撑", "0807": "悬挂训练带收膝", "0808": "悬挂训练带划船", "0809": "悬挂带分腿蹲", "3433": "游泳式踢腿 v.2（男）", "3318": "摆荡360", "1753": "三凳臂屈伸", "2459": "翻轮胎", "0811": "六角杠硬拉", "0814": "双杠臂屈伸", "0812": "凳上臂屈伸（双腿抬高）", "0813": "肱三头肌臂屈伸（双凳之间）", "0815": "地面反向臂屈伸", "0816": "肱三头肌推举", "0817": "肱三头肌拉伸", "0871": "团身卷腹", "0818": "对握高位下拉", "1466": "转体提髋", "2802": "转体举腿", "2801": "转体举腿（女）", "3231": "双脚触趾（男）", "1365": "上背部拉伸", "1366": "上犬式伸展", "3420": "地面V字支撑", "0826": "双杠支撑举腿", "2141": "椭圆机", "3655": "行走高抬腿弓步", "1460": "行走弓步蹲", "3666": "跑步机爬坡走", "2311": "楼梯机", "0830": "负重凳上臂屈伸", "2987": "负重窄握引体向上（臂屈伸架）", "3643": "负重哥萨克深蹲（男）", "0832": "负重卷腹", "3670": "负重下斜仰卧起坐", "0833": "负重驴式提踵", "1310": "负重释手俯卧撑", "2135": "负重平板支撑", "0834": "杠铃片前平举", "0866": "负重悬垂抬髋", "0835": "负重背伸（健身球上）", "3641": "负重跪姿摆荡上步", "3644": "负重摆荡箭步蹲", "3286": "负重双力臂", "3312": "负重双力臂（单杠）", "3290": "负重单臂引体向上", "0840": "负重过顶卷腹（健身球上）", "0841": "负重引体向上", "0844": "负重绕臂", "0846": "负重俄罗斯转体", "0845": "悬腿负重俄罗斯转体", "2371": "负重俄罗斯转体 v.2", "0847": "药球坐姿二头弯举（健身球上）", "0849": "负重坐姿转体（健身球上）", "0850": "负重侧屈（健身球上）", "0851": "负重西斯深蹲", "0852": "负重深蹲", "0853": "负重站姿弯举", "0854": "负重站姿握挤", "3313": "负重直杆臂屈伸", "3642": "负重伸展弓步", "0856": "杠铃片夹胸推", "1754": "负重三凳臂屈伸", "1755": "负重双杠臂屈伸", "1767": "负重高双杠肱三头肌臂屈伸", "0857": "跪姿健腹轮", "3637": "健腹轮跑", "1429": "宽握引体向上", "1367": "宽距后仰引体向上", "1311": "宽距俯卧撑", "2363": "宽距高双杠胸推", "0858": "原地冲刺跑", "1604": "世界上最棒的拉伸", "1428": "手腕环绕", "0859": "卷腕器卷腕", "boji-cardio-walk": "快走", "boji-cardio-cycle": "户外骑行", "boji-cardio-row": "划船机", "boji-cardio-swim-free": "自由泳", "boji-cardio-swim-breast": "蛙泳", "boji-cardio-stairs": "爬楼梯", "boji-cardio-march": "原地踏步", "boji-cardio-dance": "健身操", "boji-cardio-step-jack": "低冲击开合步", "boji-basic-squat": "徒手深蹲", "boji-basic-plank": "前臂平板支撑", "boji-basic-bird-dog": "鸟狗式", "boji-basic-wall-sit": "靠墙静蹲"]
    private static let byQuery: [String: String] = ["pull-up": "0652", "wide grip pull-up": "1429", "chin-up": "1326", "pull up (neutral grip)": "0651", "chin-ups (narrow parallel grip)": "0253", "assisted pull-up": "0017", "assisted parallel close grip pull-up": "0015", "band assisted pull-up": "0970", "weighted pull-up": "0841", "inverted row": "0499", "inverted row bent knees": "2300", "suspended row": "0808", "scapular pull-up": "0688", "barbell bent over row": "0027", "barbell reverse grip bent over row": "0118", "barbell pendlay row": "3017", "barbell rack pull": "0074", "dumbbell bent over row": "0293", "dumbbell one arm bent-over row": "0292", "dumbbell incline row": "0327", "dumbbell incline y-raise": "3541", "cable bar lateral pulldown": "0150", "cable lateral pulldown with v-bar": "2616", "cable underhand pulldown": "0245", "twin handle parallel grip lat pulldown": "0818", "cable one arm pulldown": "3563", "cable straight arm pulldown": "0238", "cable straight arm pulldown (with rope)": "0237", "cable seated row": "0861", "cable seated wide-grip row": "0218", "cable seated one arm alternate row": "0214", "cable one arm bent over row": "0189", "lever front pulldown": "0579", "lever high row": "0581", "lever narrow grip seated row": "0588", "lever seated row": "1350", "lever unilateral row": "1313", "lever t bar row": "0606", "lever bent-over row with v-bar": "3200", "smith bent over row": "1359", "smith reverse grip bent over row": "1361", "kettlebell one arm row": "0541", "kettlebell two arm row": "1345", "resistance band seated straight back row": "3144", "band close-grip pulldown": "0974", "band kneeling one arm pulldown": "0983", "hyperextension": "0489", "lever back extension": "0573", "kneeling lat stretch": "1346", "upper back stretch": "1365", "barbell full squat": "0043", "barbell high bar squat": "1436", "barbell low bar squat": "1435", "barbell front squat": "0042", "barbell bench squat": "0026", "barbell lunge": "0054", "barbell rear lunge": "0078", "barbell single leg split squat": "0099", "barbell step-up": "0114", "dumbbell goblet squat": "1760", "dumbbell squat": "0413", "dumbbell lunge": "0336", "dumbbell rear lunge": "0381", "dumbbell single leg split squat": "0410", "dumbbell step-up": "0431", "kettlebell goblet squat": "0534", "kettlebell front squat": "0533", "split squats": "2368", "forward lunge (male)": "3470", "walking lunge": "1460", "curtsey squat": "3769", "jump squat": "0514", "lunge with jump": "3582", "single leg squat (pistol) male": "1759", "band squat": "1004", "band single leg split squat": "1001", "smith squat": "0770", "smith front squat (clean grip)": "1433", "smith chair squat": "0750", "smith single leg split squat": "0768", "smith sumo squat": "3142", "sled hack squat": "0743", "sled 45в° leg press": "0739", "sled 45в° leg wide press": "0740", "sled 45 degrees one leg press": "1425", "lever leg extension": "0585", "resistance band leg extension": "3007", "lever lying leg curl": "0586", "lever seated leg curl": "0599", "lever kneeling leg curl": "0582", "dumbbell lying femoral": "0339", "glute-ham raise": "3193", "inverse leg curl (bench support)": "0496", "self assisted inverse leg curl (on floor)": "0696", "lever seated hip adduction": "0598", "cable hip adduction": "0168", "side lying hip adduction (male)": "3667", "hamstring stretch": "1511", "lying (side) quads stretch": "0613", "butterfly yoga pose": "1494", "world greatest stretch": "1604", "leg up hamstring stretch": "1576", "crunch floor": "0274", "sit-up v. 2": "0735", "decline sit-up": "0282", "crunch (on stability ball)": "0271", "cross body crunch": "0262", "oblique crunches floor": "0635", "alternate heel touchers": "0006", "air bike": "0003", "reverse crunch": "0872", "tuck crunch": "0871", "jackknife sit-up": "0507", "flutter kicks": "0459", "assisted hanging knee raise": "0011", "hanging straight leg raise": "0475", "hanging oblique knee raise": "1761", "captains chair straight leg raise": "2963", "lying leg raise flat bench": "0620", "lying leg-hip raise": "0865", "seated leg raise": "0689", "dead bug": "0276", "russian twist": "0687", "weighted russian twist": "0846", "weighted russian twist (legs up)": "0845", "weighted crunch": "0832", "weighted front plank": "2135", "front plank with twist": "0464", "shoulder tap": "3699", "kneeling plank tap shoulder (male)": "3239", "side bridge v. 2": "0705", "reverse plank with leg lift": "3663", "wheel rollerout": "0857", "pull-in (on stability ball)": "0650", "suspended reverse crunch": "0807", "suspended abdominal fallout": "0805", "cable kneeling crunch": "0175", "cable twist (up-down)": "0862", "cable standing lift": "0230", "cable twist": "0243", "band horizontal pallof press": "0979", "band standing crunch": "1005", "dumbbell side bend": "0407", "lever seated crunch": "1452", "pelvic tilt": "3147", "inchworm": "1471", "dumbbell standing overhead press": "0426", "dumbbell seated shoulder press": "0405", "dumbbell seated shoulder press (parallel grip)": "0404", "dumbbell standing palms in press": "0427", "dumbbell one arm shoulder press": "0361", "dumbbell arnold press": "2137", "dumbbell push press": "1700", "dumbbell lateral raise": "0334", "dumbbell seated lateral raise": "0396", "dumbbell one arm lateral raise with support": "0356", "dumbbell front raise": "0310", "dumbbell seated front raise": "0392", "dumbbell reverse fly": "0383", "dumbbell incline rear lateral raise": "0326", "dumbbell rear delt row_shoulder": "0377", "dumbbell upright row": "0437", "dumbbell lying external shoulder rotation": "0863", "dumbbell upright shoulder external rotation": "0864", "barbell seated overhead press": "0091", "barbell standing close grip military press": "1456", "barbell wide-grip upright row": "0123", "cable lateral raise": "0178", "cable one arm lateral raise": "0192", "cable front raise": "0162", "cable cross-over revers fly": "0154", "cable rear delt row (with rope)": "0203", "cable standing shoulder external rotation": "0235", "cable upright row": "0246", "lever shoulder press": "0603", "lever lateral raise": "0584", "lever seated reverse fly": "0602", "lever seated reverse fly (parallel grip)": "0601", "smith seated shoulder press": "0765", "smith standing military press": "0774", "band shoulder press": "0997", "band front raise": "0978", "band reverse fly": "0993", "band y-raise": "1017", "kettlebell two arm military press": "0553", "kettlebell seated press": "0546", "rear deltoid stretch": "0669", "neck side stretch": "1403", "barbell curl": "0031", "barbell reverse curl": "0080", "barbell preacher curl": "0070", "ez barbell curl": "0447", "ez barbell reverse grip curl": "0451", "ez barbell spider curl": "0454", "dumbbell biceps curl": "0294", "dumbbell alternate biceps curl": "0285", "dumbbell hammer curl": "0313", "dumbbell cross body hammer curl": "0298", "dumbbell concentration curl": "0297", "dumbbell incline biceps curl": "0315", "dumbbell incline hammer curl": "0320", "dumbbell seated curl": "0391", "dumbbell seated hammer curl": "1678", "dumbbell preacher curl": "0372", "dumbbell zottman curl": "0439", "cable curl": "0868", "cable hammer curl (with rope)": "0165", "cable one arm curl": "0190", "cable preacher curl": "0195", "cable reverse curl": "0206", "lever bicep curl": "0575", "lever preacher curl": "0592", "band alternating biceps curl": "0968", "barbell close-grip bench press": "0030", "barbell lying triceps extension skull crusher": "0060", "barbell seated overhead triceps extension": "0092", "ez barbell seated triceps extension": "0453", "dumbbell lying triceps extension": "0351", "dumbbell standing triceps extension": "0430", "dumbbell seated bench extension": "0389", "dumbbell kickback": "0333", "cable pushdown": "0201", "cable pushdown (with rope attachment)": "0200", "cable triceps pushdown (v-bar)": "0241", "cable reverse-grip pushdown": "0207", "cable one arm tricep pushdown": "1723", "cable overhead triceps extension (rope attachment)": "0194", "lever triceps extension": "0607", "lever seated dip": "1451", "smith close-grip bench press": "0751", "triceps dip": "0814", "assisted triceps dip (kneeling)": "0019", "weighted tricep dips": "1755", "bench dip (knees bent)": "0129", "diamond push-up": "0283", "close-grip push-up (on knees)": "2398", "close-grip push-up": "0259", "barbell wrist curl": "0126", "barbell reverse wrist curl": "0082", "dumbbell over bench wrist curl": "0369", "cable wrist curl": "0247", "wrist rollerer": "0859", "overhead triceps stretch": "0643", "side wrist pull stretch": "0721", "wrist circles": "1428", "barbell deadlift": "0032", "barbell romanian deadlift": "0085", "barbell sumo deadlift": "0117", "barbell straight leg deadlift": "0116", "barbell single leg deadlift": "1756", "barbell good morning": "0044", "barbell glute bridge": "1409", "barbell shrug": "0095", "dumbbell deadlift": "0300", "dumbbell romanian deadlift": "1459", "dumbbell single leg deadlift": "1757", "low glute bridge on floor": "3013", "single leg bridge with outstretched leg": "3645", "glute bridge march": "3561", "glute bridge two legs on bench (male)": "3523", "reverse hyper on flat bench": "1423", "lever reverse hyperextension": "0593", "lever seated hip abduction": "0597", "lever hip extension v. 2": "2286", "cable standing hip extension": "0228", "cable pull through (with rope)": "0196", "resistance band seated hip abduction": "3006", "band bent-over hip extension": "0980", "band hip lift": "1408", "monster walk": "0628", "side hip abduction": "0710", "side bridge hip abduction": "1774", "kettlebell swing": "0549", "trap bar deadlift": "0811", "smith deadlift": "0752", "seated glute stretch": "1424", "seated piriformis stretch": "2567", "rocking frog stretch": "2571", "barbell bench press": "0025", "barbell incline bench press": "0047", "barbell decline bench press": "0033", "dumbbell bench press": "0289", "dumbbell incline bench press": "0314", "dumbbell decline bench press": "0301", "dumbbell lying hammer press": "0340", "dumbbell incline hammer press": "0321", "dumbbell fly": "0308", "dumbbell incline fly": "0319", "dumbbell pullover": "0375", "push-up": "0662", "kneeling push-up (male)": "3211", "push-up (wall)": "0659", "incline push-up": "0493", "decline push-up": "0279", "wide hand push up": "1311", "scapula push-up": "3021", "clap push up": "1273", "suspended push-up": "0806", "chest dip": "0251", "assisted chest dip (kneeling)": "0009", "cable middle fly": "0188", "cable low fly": "0179", "cable decline fly": "0158", "cable incline fly": "0171", "cable seated chest press": "2144", "lever chest press": "0577", "lever incline chest press": "1299", "lever decline chest press": "1300", "lever seated fly": "0596", "smith bench press": "0748", "smith incline bench press": "0757", "smith decline bench press": "0753", "band bench press": "1254", "resistance band seated chest press": "3124", "weighted svend press": "0856", "chest and front of shoulder stretch": "1271", "dynamic chest stretch (male)": "1167", "bodyweight standing calf raise": "1373", "one leg floor calf raise": "1387", "standing calf raise (on a staircase)": "1490", "dumbbell standing calf raise": "0417", "dumbbell single leg calf raise": "0409", "dumbbell seated calf raise": "1379", "barbell standing calf raise": "1372", "lever standing calf raise": "0605", "lever seated calf raise": "0594", "sled 45в° calf press": "0738", "sled one leg calf press on leg press": "1392", "smith standing leg calf raise": "0773", "band single leg calf raise": "0999", "calf stretch with hands against wall": "1377", "seated calf stretch (male)": "1390", "ankle circles": "1368", "run": "0685", "run (equipment)": "0684", "walking on incline treadmill": "3666", "walk elliptical cross trainer": "2141", "stationary bike run v. 3": "2138", "walking on stepmill": "2311", "jump rope": "2612", "burpee": "1160", "mountain climber": "0630", "jack jump (male)": "3224", "skater hops": "3361", "bear crawl": "3360", "battling ropes": "0128", "farmers walk": "2133", "medicine ball overhead slam": "1354", "barbell thruster": "3305", "kettlebell thruster": "0550", "barbell squat": "0043", "barbell row": "0027", "bodyweight lunge": "3470", "lunge": "3470", "knee push up": "3211", "kneeling push up": "3211", "glute bridge": "3013", "bodyweight glute bridge": "3013", "crunch": "0274", "side plank": "0705", "calf raise": "1373", "jumping jack": "3224", "dumbbell curl": "0294", "dumbbell shoulder press": "0426", "dumbbell row": "0293", "one arm dumbbell row": "0292", "incline dumbbell bench press": "0314", "band row": "3144", "band curl": "0968", "band pull apart": "0993", "kettlebell row": "0541", "pull up": "0652", "chin up": "1326", "alternate lateral pulldown": "0007", "assisted standing chin-up": "1431", "back extension on exercise ball": "1314", "band one arm standing low row": "0988", "band one arm twisting seated row": "0990", "barbell bent arm pullover": "1316", "barbell incline row": "0049", "barbell pullover": "0073", "barbell reverse grip incline bench row": "1317", "cable floor seated wide-grip row": "0160", "cable high row (kneeling)": "0167", "cable incline bench row": "1318", "cable lateral pulldown (with rope attachment)": "0177", "cable lying extension pullover (with rope attachment)": "0184", "cable one arm straight back high row (kneeling)": "0193", "cable reverse-grip straight back seated high row": "0208", "cable rope seated row": "1323", "cable shrug": "0220", "cable squat row (with rope attachment)": "1717", "cable standing row (v-bar)": "0234", "close grip chin-up": "1327", "dumbbell incline shrug": "0329", "dumbbell lying rear delt row": "1328", "dumbbell palm rotational bent over row": "1329", "dumbbell reverse grip incline bench two arm row": "1331", "exercise ball lat stretch": "1339", "ez bar lying bent arms pullover": "3010", "hyperextension (on bench)": "0488", "inverted row with straps": "0498", "kettlebell alternating renegade row": "0521", "kettlebell alternating row": "0522", "lever alternating narrow grip seated row": "0571", "lever one arm lateral high row": "1356", "lever one arm lateral wide pulldown": "1347", "lever pullover": "2285", "lever reverse grip lateral pulldown": "2736", "lever reverse grip vertical row": "1348", "lever t-bar reverse grip row": "1351", "lever shrug": "0604", "roller back stretch": "2208", "seated lower back stretch": "0690", "smith narrow row": "0761", "smith one arm row": "1360", "smith shrug": "0767", "sphinx": "1362", "standing lateral stretch": "0794", "upward facing dog": "1366", "archer push up": "3294", "band one arm twisting chest press": "0989", "barbell wide bench press": "0122", "cable bench press": "0151", "cable decline press": "1261", "cable incline bench press": "0169", "cable lying fly": "0185", "cable one arm incline press": "1265", "chest stretch with exercise ball": "1272", "deep push up": "1274", "drop push up": "1275", "dumbbell decline fly": "0302", "dumbbell decline hammer press": "0303", "dumbbell incline alternate press": "3545", "dumbbell incline one arm press": "1281", "incline scapula push up": "3011", "isometric chest squeeze": "1297", "kettlebell alternating press on floor": "0519", "kettlebell one arm floor press": "1298", "medicine ball chest pass": "1302", "plyo push up": "1306", "push-up medicine ball": "0663", "push-up plus": "3145", "shoulder tap push-up": "0699", "smith reverse-grip press": "0764", "band reverse wrist curl": "0994", "band wrist curl": "1016", "barbell standing back wrist curl": "0104", "cable reverse wrist curl": "0210", "dumbbell finger curls": "1437", "dumbbell one arm reverse wrist curl": "0358", "dumbbell one arm seated neutral wrist curl": "1415", "dumbbell one arm wrist curl": "0364", "dumbbell seated one arm rotate": "0399", "finger curls": "0455", "lever gripper hands": "2288", "band close-grip push-up": "0975", "band concentration curl": "0976", "band side triceps extension": "0998", "barbell drag curl": "0038", "barbell incline close grip bench press": "1719", "barbell pin presses": "1751", "barbell prone incline curl": "0072", "barbell reverse preacher curl": "0081", "barbell standing close grip curl": "0106", "barbell standing wide-grip curl": "0113", "bodyweight kneeling triceps extension": "1771", "cable close grip curl": "1630", "cable concentration curl": "1631", "cable drag curl": "1632", "cable high pulley overhead tricep extension": "1722", "cable incline triceps extension": "0173", "cable kickback": "0860", "cable lying bicep curl": "1634", "cable one arm preacher curl": "1633", "cable overhead curl": "1636", "cable reverse one arm curl": "1413", "cable reverse preacher curl": "0209", "cable rope hammer preacher curl": "1639", "cable rope high pulley overhead tricep extension": "1724", "cable rope lying on floor tricep extension": "1726", "cable seated curl": "1641", "cable two arm tricep kickback": "1728", "dumbbell incline triceps extension": "0330", "dumbbell lying alternate extension": "1729", "dumbbell lying one arm pronated triceps extension": "0344", "dumbbell one arm hammer preacher curl": "1663", "dumbbell one arm seated hammer curl": "1669", "dumbbell prone incline hammer curl": "1674", "dumbbell reverse preacher curl": "0384", "dumbbell seated one arm kickback": "0398", "dumbbell standing one arm reverse curl": "0425", "dumbbell waiter biceps curl": "5201", "ez bar lying close grip triceps extension behind head": "1748", "ez bar standing french press": "1749", "ez barbell close-grip curl": "0446", "ez barbell decline triceps extension": "2186", "ez barbell incline triceps extension": "0449", "ez barbell reverse grip preacher curl": "0452", "ez barbell seated curls": "1458", "ez-barbell standing wide grip biceps curl": "2741", "incline close-grip push-up": "0490", "lever hammer grip preacher curl": "1615", "push-up close-grip off dumbbell": "0660", "resistance band seated biceps curl": "3123", "ring dips": "0677", "side push-up": "0717", "triceps dip (bench leg)": "0812", "triceps dips floor": "0815", "weighted bench dip": "0830", "band standing rear delt row": "1022", "barbell front raise": "0041", "barbell rear delt row": "0076", "barbell upright row": "0120", "cable rear delt row (stirrups)": "0202", "cable seated rear lateral raise": "0215", "cable seated shoulder internal rotation": "0216", "cable shoulder press": "0219", "cable standing cross-over high reverse fly": "0225", "cable standing rear delt row (with rope)": "0233", "dumbbell cuban press": "0299", "dumbbell incline one arm lateral raise": "0323", "dumbbell one arm lateral raise": "0355", "dumbbell one arm reverse fly (with support)": "0359", "dumbbell seated alternate front raise": "0387", "dumbbell seated alternate press": "0388", "dumbbell seated bent arm lateral raise": "2317", "dumbbell single arm overhead carry": "3548", "dumbbell standing alternate overhead press": "0414", "kettlebell alternating press": "0520", "kettlebell double push press": "0528", "kettlebell one arm clean and jerk": "0537", "kettlebell one arm push press": "0540", "kettlebell one arm snatch": "0542", "kettlebell two arm clean": "0552", "landmine lateral raise": "3237", "lever one arm shoulder press": "0590", "resistance band seated shoulder press": "3122", "smith rear delt row": "0762", "smith upright row": "0775", "weighted front raise": "0834", "band single leg reverse calf raise": "1000", "barbell seated calf raise": "0088", "cable standing calf raise": "1375", "cable standing one leg calf raise": "1376", "calf push stretch with hands against wall": "1407", "calf stretch with rope": "1378", "donkey calf raise": "0284", "dumbbell seated one leg calf raise": "0400", "hack calf raise": "1383", "hack one leg calf raise": "1384", "lever donkey calf raise": "1253", "smith one leg floor calf raise": "1393", "smith reverse calf raises": "0763", "smith toe raise": "1396", "weighted donkey calf raise": "0833", "all fours squad stretch": "1512", "assisted prone hamstring": "0016", "assisted prone lying quads stretch": "1713", "assisted side lying adductor stretch": "1712", "barbell bench front squat": "0024", "barbell lateral lunge": "1410", "barbell narrow stance squat": "0063", "barbell overhead squat": "0069", "barbell side split squat": "0098", "barbell wide squat": "0124", "chair leg extended stretch": "1548", "dumbbell bench squat": "0291", "dumbbell contralateral forward lunge": "3635", "dumbbell single leg deadlift with stepbox support": "2805", "dumbbell single leg squat": "0411", "dumbbell step-up lunge": "2796", "dumbbell supported squat": "2803", "exercise ball seated hamstring stretch": "1560", "inverse leg curl (on pull-up cable machine)": "2400", "lever lying two-one leg curl": "3195", "potty squat with support": "3132", "reclining big toe pose with rope": "1582", "runners stretch": "1585", "seated wide angle pose sequence": "1587", "single leg platform slide": "0730", "sissy squat": "1489", "sled closer hack squat": "0741", "sled lying squat": "0744", "smith hack squat": "0755", "smith low bar squat": "1434", "squat on bosu ball": "1705", "standing hamstring and calf stretch with strap": "1599", "standing single leg curl": "0795", "suspended split squat": "0809", "assisted lying glutes stretch": "1709", "assisted lying gluteus and piriformis stretch": "1710", "band lying hip internal rotation": "0984", "band pull through": "0991", "band step-up": "1008", "band stiff leg deadlift": "1009", "hug keens to chest": "1418", "iron cross stretch": "1419", "lever deadlift": "0578", "lever horizontal one leg press": "2611", "lever seated good morning": "3759", "pelvic tilt into bridge": "1422", "resistance band hip thrusts on knees (female)": "3236", "reverse hyper extension (on stability ball)": "0675", "roller hip stretch": "2202", "smith hip raise": "0756", "straight leg outer hip abductor": "1427", "3/4 sit-up": "0001", "45° side bend": "0002", "arm slingers hanging bent knee legs": "2355", "arm slingers hanging straight legs": "2333", "assisted sit-up": "1758", "band alternating v-up": "0969", "band assisted wheel rollerout": "0971", "band bicycle crunch": "0972", "band kneeling twisting crunch": "0985", "band lying straight leg raise": "1002", "band seated twist": "1011", "band standing twisting crunch": "1007", "band vertical pallof press": "1015", "barbell rollerout": "0084", "barbell seated twist": "0094", "barbell sitted alternate leg raise": "2799", "bodyweight incline side plank": "3544", "cable reverse crunch": "0873", "cable seated crunch": "0212", "cable seated twist": "2399", "cable side bend": "0222", "cable side crunch": "0223", "cable standing crunch": "0226", "cable standing crunch (with rope attachment)": "0874", "cable tuck reverse crunch": "0242", "cocoons": "0260", "crab twist toe touch": "1468", "crunch (hands overhead)": "0267", "crunch (on stability ball, arms straight)": "0272", "decline crunch": "0277", "elbow-to-knee": "0443", "frog crunch": "2429", "half sit-up (male)": "3202", "hanging leg hip raise": "1764", "hanging straight leg hip raise": "0474", "hanging straight twisting leg hip raise": "0476", "incline leg hip raise (leg straight)": "0491", "incline twisting sit-up": "0495", "kettlebell figure 8": "0532", "kettlebell windmill": "0554", "knee touch crunch": "3640", "landmine 180": "0562", "leg pull in flat bench": "0570", "lever kneeling twist": "0583", "lever seated crunch (chest pad)": "0595", "lever seated leg raise crunch": "0600", "lunge with twist": "1688", "negative crunch": "0634", "otis up": "0641", "posterior step to overhead reach": "1687", "push-up to side plank": "0664", "roller body saw": "2204", "seated side crunch (wall)": "0691", "side-to-side toe touch (male)": "3213", "sit-up with arms on chest": "3679", "spine twist": "2329", "twisted leg raise": "2802", "vertical leg raise (on parallel bars)": "0826", "weighted decline sit-up": "3670", "weighted hanging leg-hip raise": "0866", "astride jumps (male)": "3220", "back and forth step": "3672", "dumbbell burpee": "1201", "high knee against wall": "3636", "jack burpee": "0501", "push to run": "3638", "scissor jumps (male)": "3219", "semi squat jump (male)": "3222", "short stride run": "3656", "ski step": "3671", "star jump (male)": "3223", "walking high knees lunge": "3655", "hands bike": "2139", "ski ergometer": "2142", "quick feet v. 2": "3552", "wind sprints": "0858", "forward jump": "1472", "medicine ball catch and overhead throw": "1353", "one arm slam (with medicine ball)": "0640", "sledge hammer": "1496", "tire flip": "2459", "brisk walking": "boji-cardio-walk", "outdoor cycling": "boji-cardio-cycle", "rowing machine": "boji-cardio-row", "freestyle swimming": "boji-cardio-swim-free", "breaststroke swimming": "boji-cardio-swim-breast", "stair climbing": "boji-cardio-stairs", "marching in place": "boji-cardio-march", "aerobic dance": "boji-cardio-dance", "low impact step jack": "boji-cardio-step-jack", "bodyweight squat": "boji-basic-squat", "forearm plank": "boji-basic-plank", "bird dog": "boji-basic-bird-dog", "wall sit": "boji-basic-wall-sit"]
}
