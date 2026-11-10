import Foundation

// Facts are rebuilt from the current saved records. No generated claim is cached
// under a date after its source has changed or been deleted.
struct ClubInsightKind: RawRepresentable, Codable, Hashable {
    let rawValue: String
    static let training = Self(rawValue: "training")
    static let nutrition = Self(rawValue: "nutrition")
    static let body = Self(rawValue: "body")
    static let workout = Self(rawValue: "workout")
    static let plan = Self(rawValue: "plan")
    var supported: Bool { [Self.training, .nutrition, .body, .workout, .plan].contains(self) }
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
                title: "本次训练总结已更新", detail: "这次已确认 \(report.completedSets) 组。" + (report.comparisons.isEmpty ? "继续记录相同动作与负重，再核对是否可以比较。" : "有符合条件的历史记录，可以展开逐项对照。"),
                evidence: "依据：\(key) 这一次已确认训练；按场次区分，历史只采用此前已确认的记录。",
                priority: 110, sourceSessionID: sessionID,
                action: ClubInsightAction(type: "workout_summary", date: key, sessionID: sessionID),
                sourceDigest: ClubInsightLedger.digest(report)))
        }
        let isToday = key == ClubDates.key(now)
        if day.hasConfirmedTraining {
            result.append(.init(id: key + "/training", kind: .training, title: "训练已保存",
                detail: "已确认完成 \(day.confirmedCompletedSets) 组" + (day.confirmedTraining.timedSeconds > 0 ? "，其中按秒训练累计 \(day.confirmedTraining.timedSeconds) 秒。" : "。") + "可以结合饮食记录查看本日分析。",
                evidence: "依据：\(key) 已确认的有效训练组。普通保存和计划目标不算完成；同一天其他未确认场次单独处理。", priority: 100))
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
                detail += "补齐漏记的餐次，摄入数据会更完整。"
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
        // B4：计划执行跟进——连续错过安排时提示「尚未看到完成记录」，给查看与调整入口。
        // 只在今天评估一次；不断言用户没有运动；错过天数阈值见 DECISIONS（≥2 天）。
        if isToday {
            var missedRun: [String] = []
            for offset in 1...7 {
                guard let day = ClubDates.calendar.date(byAdding: .day, value: -offset, to: date) else { break }
                let pastKey = ClubDates.key(day)
                let past = state.days[pastKey] ?? DayLog()
                if past.exercises.isEmpty { continue }
                if past.plannedMoveDestination != nil { continue } // 已提前，不算错过
                if past.isTrainingConfirmed || past.completedSets > 0 { break } // 有记录，中断连续
                if WorkoutEditing.isProtected(past) { break } // 有未确认训练，先处理
                missedRun.append(pastKey)
            }
            if missedRun.count >= ClubTrendThresholds.missedRunDays {
                let rangeText = (missedRun.last ?? "") + "—" + (missedRun.first ?? "")
                // 依据摘要：错过日＋各自安排的动作 ID。记录变化→摘要变化→事件版本链正确更新/撤回。
                let digestInput = missedRun.sorted().map { key in
                    let ids = state.days[key]?.exercises.map { $0.id.uuidString.lowercased() }.sorted().joined(separator: ",") ?? ""
                    return key + "|" + ids
                }
                result.append(.init(id: key + "/plan", kind: .plan,
                    title: "有安排尚未看到完成记录",
                    detail: "\(rangeText) 的 \(missedRun.count) 次安排还没有看到完成记录。可以查看日程，或把尚未开始的安排顺延。漏记也可以直接补上实际训练。",
                    evidence: "依据：这些日期的日程存在且无已确认训练组；没有记录不等于没有运动，仅提示可查看。",
                    priority: 95,
                    action: ClubInsightAction(type: "schedule_shift", date: key),
                    sourceDigest: ClubInsightLedger.digest(digestInput)))
            }
        }
        return result.sorted { $0.priority == $1.priority ? $0.id < $1.id : $0.priority > $1.priority }
    }
}
