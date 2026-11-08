import Foundation

// D5：趋势与阶段判断的阈值集中配置。禁止散落在提示词里；改参数只改这里。
enum ClubTrendThresholds {
    /// 可比训练趋势最少样本数（同动作身份＋同计量＋同负重）。
    static let trendMinSamples = 3
    /// 趋势至少跨越的最少天数（避免同一天多场次冒充趋势）。
    static let trendMinSpanDays = 2
    /// 「平台期」体重判定：最少测量次数。
    static let bodyPlateauMinSamples = 4
    /// 「平台期」判定的最小跨度（天）。
    static let bodyPlateauMinSpanDays = 14
    /// 「平台期」判定的均值变化阈值（kg）；小于该值视为无明显变化。
    static let bodyPlateauDeltaKg = 0.5
    /// 计划执行跟进：连续错过安排的提示阈值（天）。
    static let missedRunDays = 2
    /// 首页身体趋势摘要窗口（天）。
    static let homeTrendWindowDays = 14
}

// D1：多次可比训练的趋势分析。
// 比较条件：同动作身份（library/custom/query）、同计量方式（次/秒）、同登记重量（计次动作）。
// 样本不足明确降级；动作质量与主观感受未知，只能给有条件的选择，不自动加重（D2）。

/// 训练动作的稳定身份。UUID 统一小写；训练总结、趋势、阶段报告与历史查询共用，
/// 避免同一自定义动作因大小写不同被拆成两份历史。
enum ClubExerciseIdentity {
    static func of(_ exercise: Exercise) -> String? {
        of(customID: exercise.customExerciseID, libraryID: exercise.libraryID, query: exercise.libraryQuery)
    }
    static func of(customID: UUID?, libraryID: String?, query: String?) -> String? {
        if let customID { return "custom/" + customID.uuidString.lowercased() }
        if let libraryID {
            let value = libraryID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !value.isEmpty { return "library/" + value }
        }
        guard let query else { return nil }
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value.isEmpty ? nil : "query/" + value
    }
}

/// 已确认训练场次。同一天可以有多场：只采用已保存场次的实际动作，
/// 未确认的第二场不能把第一场已确认的记录藏起来。
enum TrainingEvidence {
    struct Slice {
        let sessionID: UUID?
        let exercises: [Exercise]
    }
    static func confirmedSlices(day: DayLog) -> [Slice] {
        let confirmed = day.confirmedTraining.exercises
        if day.workoutSessions?.isEmpty == false {
            return day.confirmedWorkoutSessions.compactMap { session in
                let exercises = confirmed.filter { $0.workoutSessionID == session.id }
                return exercises.contains { $0.sets.contains(where: \.validCompletion) }
                    ? Slice(sessionID: session.id, exercises: exercises) : nil
            }
        }
        return day.hasConfirmedTraining ? [Slice(sessionID: nil, exercises: confirmed)] : []
    }
    static func confirmedSetCount(day: DayLog) -> Int { day.confirmedTraining.completedSets }

}

struct ClubTrendPoint: Codable, Equatable, Identifiable {
    var id: String { date + "/" + String(value) }
    let date: String
    let value: Int       // 该次训练该动作同负重下的总次数或总秒数
    let sets: Int
}

struct ClubTrendResult: Codable, Equatable, Identifiable {
    let identity: String
    let name: String
    let unit: String       // "reps" | "time"
    let weight: Double?
    let points: [ClubTrendPoint]
    let sampleCount: Int
    let spanDays: Int
    /// 结论恒为条件性表述；样本不足时 verdict 为「样本不足」。
    let verdict: String
    let detail: String
    /// 身份＋计量＋负重唯一（同动作不同负重是不同趋势项）。
    var id: String { identity + "|" + unit + "|" + (weight.map { String($0) } ?? "-") }
}

enum ClubTrendRules {
    /// 与 ClubWorkoutSummaryRules 保持同一套身份与计量规则。
    static func identity(_ exercise: Exercise) -> String? { ClubExerciseIdentity.of(exercise) }
    static func unit(_ exercise: Exercise) -> String? {
        let done = exercise.sets.filter(\.validCompletion)
        guard !done.isEmpty else { return nil }
        let values = Set(done.map { $0.durationSeconds == nil ? "reps" : "time" })
        return values.count == 1 ? values.first : nil
    }

    private struct Bucket {
        let identity: String
        var name: String
        var unit: String
        var weight: Double?
        /// 日期 →（当天合计值，当天合计组数）。
        var byDate: [String: (value: Int, sets: Int)] = [:]
    }

    /// 汇总已确认训练中的可比样本，按 (身份, 单位, 负重) 分组给趋势。
    /// 只看登记数据；只统计 [from, through] 区间内（F7）；质量与余力未知，结论一律带条件。
    /// 比较的是「单组平均表现」——多做组数是训练量变化，不等于能力提升（F8）。
    static func trends(state: SavedState, through: Date = Date(), from: Date? = nil) -> [ClubTrendResult] {
        let startKey = from.map { ClubDates.key($0) }
        var buckets: [String: Bucket] = [:]
        for key in state.days.keys.sorted() where !key.isEmpty && key <= ClubDates.key(through) {
            if let startKey, key < startKey { continue }
            guard let day = state.days[key] else { continue }
            for slice in TrainingEvidence.confirmedSlices(day: day) {
                for exercise in slice.exercises {
                    guard let identity = identity(exercise), let metric = unit(exercise) else { continue }
                    let done = exercise.sets.filter(\.validCompletion)
                    let weights: [Double?] = metric == "time" ? [nil] : Array(Set(done.map(\.weight))).sorted().map(Optional.some)
                    for weight in weights {
                        let sets = done.filter { weight == nil || $0.weight == weight }
                        guard !sets.isEmpty else { continue }
                        let bucketKey = identity + "|" + metric + "|" + String(weight ?? -1)
                        let value = sets.reduce(0) { $0 + (metric == "time" ? ($1.durationSeconds ?? 0) : $1.reps) }
                        var bucket = buckets[bucketKey] ?? Bucket(identity: identity, name: exercise.displayName, unit: metric, weight: weight)
                        let prior = bucket.byDate[key] ?? (value: 0, sets: 0)
                        bucket.byDate[key] = (value: prior.value + value, sets: prior.sets + sets.count)
                        buckets[bucketKey] = bucket
                    }
                }
            }
        }
        return buckets.values.compactMap { bucket -> ClubTrendResult? in
            let dates = bucket.byDate.keys.sorted()
            let points = dates.map {
                ClubTrendPoint(date: $0, value: bucket.byDate[$0]?.value ?? 0, sets: bucket.byDate[$0]?.sets ?? 0)
            }
            let weightText = bucket.weight.map { " \($0.formatted())kg" } ?? ""
            let base = ClubTrendResult(identity: bucket.identity, name: bucket.name, unit: bucket.unit,
                                       weight: bucket.weight, points: points,
                                       sampleCount: dates.count, spanDays: 0, verdict: "", detail: "")
            guard dates.count >= ClubTrendThresholds.trendMinSamples else {
                return ClubTrendResult(identity: base.identity, name: base.name, unit: base.unit, weight: base.weight,
                    points: points, sampleCount: dates.count, spanDays: 0, verdict: "样本不足",
                    detail: "\(base.name)\(weightText)：同条件的已确认记录只有 \(dates.count) 天，不足 \(ClubTrendThresholds.trendMinSamples) 次，暂不作趋势判断。")
            }
            let first = ClubDates.date(fromKey: dates.first ?? "") ?? Date()
            let last = ClubDates.date(fromKey: dates.last ?? "") ?? Date()
            let span = max(0, ClubDates.calendar.dateComponents([.day], from: first, to: last).day ?? 0)
            guard span >= ClubTrendThresholds.trendMinSpanDays else {
                return ClubTrendResult(identity: base.identity, name: base.name, unit: base.unit, weight: base.weight,
                    points: points, sampleCount: dates.count, spanDays: span, verdict: "样本不足",
                    detail: "\(base.name)\(weightText)：记录集中在相邻日期（跨度 \(span) 天），不足 \(ClubTrendThresholds.trendMinSpanDays) 天，暂不作趋势判断。")
            }
            // 单组平均值：把「多做几组」与「同等条件下更强」分开（F8）。
            let perSet = points.map { $0.sets > 0 ? Double($0.value) / Double($0.sets) : 0 }
            let firstAvg = perSet.first ?? 0
            let lastAvg = perSet.last ?? 0
            let highAvg = perSet.max() ?? 0
            let firstSets = points.first?.sets ?? 0
            let lastSets = points.last?.sets ?? 0
            let setsNote = firstSets == lastSets ? "" : "（组数有变化 \(firstSets)→\(lastSets) 组，总量变化不直接代表能力变化）"
            let condition = "动作幅度、技术与主观感受稳定的话"
            let metricWord = bucket.unit == "time" ? "单组秒数" : "单组次数"
            let verdict: String
            let detail: String
            if lastAvg > firstAvg * 1.05 && lastAvg >= highAvg * 0.99 {
                verdict = "记录表现上升"
                detail = "\(base.name)\(weightText)：\(metricWord)从 \(firstAvg.formatted(.number.precision(.fractionLength(1)))) 到 \(lastAvg.formatted(.number.precision(.fractionLength(1))))（\(dates.count) 天可比记录，跨度 \(span) 天）\(setsNote)。\(condition)，可以小幅尝试增加难度并留意质量；是否加重由你判断。"
            } else if abs(lastAvg - firstAvg) <= max(0.5, firstAvg * 0.05) {
                verdict = "记录表现平稳"
                detail = "\(base.name)\(weightText)：\(metricWord)在 \(firstAvg.formatted(.number.precision(.fractionLength(1))))–\(highAvg.formatted(.number.precision(.fractionLength(1)))) 之间（\(dates.count) 天可比记录，跨度 \(span) 天）\(setsNote)。平稳不等于停滞；可维持或小幅调整。"
            } else {
                verdict = "记录表现有波动"
                detail = "\(base.name)\(weightText)：最近 \(metricWord) \(lastAvg.formatted(.number.precision(.fractionLength(1))))，此前最高 \(highAvg.formatted(.number.precision(.fractionLength(1))))（\(dates.count) 天可比记录，跨度 \(span) 天）\(setsNote)。\(condition)，可结合当天状态判断；单次下滑不等于退步。"
            }
            return ClubTrendResult(identity: base.identity, name: base.name, unit: base.unit, weight: base.weight,
                points: points, sampleCount: dates.count, spanDays: span, verdict: verdict, detail: detail)
        }.sorted { $0.name == $1.name ? $0.id < $1.id : $0.name < $1.name }
    }

    /// D5：身体「平台期」判断。阈值集中配置（≥4 次测量、跨度 ≥14 天、近 7 天与前 7 天均值差 <0.5kg）。
    /// 条件不满足返回 nil——短时波动绝不叫平台期。
    static func bodyPlateau(state: SavedState, through endDate: Date) -> String? {
        let calendar = ClubDates.calendar
        let end = calendar.startOfDay(for: endDate)
        guard let windowStart = calendar.date(byAdding: .day, value: -(ClubTrendThresholds.bodyPlateauMinSpanDays * 2 - 1), to: end) else { return nil }
        let points = state.days.keys.sorted().flatMap { key -> [(Date, Double)] in
            guard let date = ClubDates.date(fromKey: key), date >= windowStart, date <= end,
                  let day = state.days[key] else { return [] }
            // 一天记了两次就算两次测量，平台期判断不再只看单条
            return BodyWeightReading.rows(of: day).compactMap { row in
                guard let kg = row.measuredKilograms else { return nil }
                return (row.recordedAt ?? date, kg)
            }
        }
        guard points.count >= ClubTrendThresholds.bodyPlateauMinSamples else { return nil }
        let firstPoint = points[0].0
        guard (ClubDates.calendar.dateComponents([.day], from: firstPoint, to: end).day ?? 0) >= ClubTrendThresholds.bodyPlateauMinSpanDays else { return nil }
        guard let recentStart = calendar.date(byAdding: .day, value: -6, to: end),
              let priorStart = calendar.date(byAdding: .day, value: -13, to: end) else { return nil }
        let recent = points.filter { $0.0 >= recentStart }
        let prior = points.filter { $0.0 >= priorStart && $0.0 < recentStart }
        guard recent.count >= 2, prior.count >= 2 else { return nil }
        let recentAvg = recent.map(\.1).reduce(0, +) / Double(recent.count)
        let priorAvg = prior.map(\.1).reduce(0, +) / Double(prior.count)
        guard abs(recentAvg - priorAvg) < ClubTrendThresholds.bodyPlateauDeltaKg else { return nil }
        return "体重在近 \(ClubTrendThresholds.bodyPlateauMinSpanDays) 天保持稳定（\(points.count) 次测量，均值变化小于 \(ClubTrendThresholds.bodyPlateauDeltaKg.formatted()) kg）。稳定不代表停滞，训练与饮食目标是否调整可结合其他记录判断。"
    }
}

// MARK: - D3/D4：阶段报告（4 周及以上）
// 客户端规则计算，不依赖服务端 AI：明确起止日期、真实数据覆盖、无上一阶段不虚构环比。
// 结果持久化在 DayLog（同步、历史可读）；服务端 AI 增强为待部署交付项，不在此轮假装打通。

struct PhaseReport: Codable, Equatable, Identifiable {
    let id: String            // "phase/<start>/<end>/<uuid>"：重生成为新版本，历史保留
    let start: String
    let end: String
    let generatedAt: Date
    let daysCovered: Int      // 区间内有记录的天数
    let daysTotal: Int
    let trainingDaysPlanned: Int
    let trainingDaysCompleted: Int
    let confirmedSets: Int
    let measuredDays: Int     // 实测体重天数
    let weightFirstKg: Double?
    let weightLastKg: Double?
    let trends: [ClubTrendResult]
    let plateauNote: String?
    let hasPreviousPhase: Bool
    let summary: String
    let notes: [String]
    /// 生成时的依据指纹。源记录变化后可在详情页明确提示「报告可能已过时」。
    /// 旧报告没有该字段（nil），不补造结论。
    var evidenceDigest: String? = nil
}

enum PhaseReportRules {
    static let minimumDays = 28

    /// 生成阶段报告。数据不足（总天数 < 28 或有记录天数 < 7）时拒绝生成并说明原因。
    static func make(state: SavedState, start: Date, end: Date, now: Date = Date()) throws -> PhaseReport {
        guard end <= now, start < end else { throw AIClientError.message("阶段报告需要过去的一段完整时间。") }
        let calendar = ClubDates.calendar
        // 日历语义算天数（夏令时 23/25 小时日不差一天）。
        let daysTotal = max(1, (calendar.dateComponents([.day], from: calendar.startOfDay(for: start), to: calendar.startOfDay(for: end)).day ?? 0) + 1)
        guard daysTotal >= minimumDays else {
            throw AIClientError.message("阶段报告至少需要 \(minimumDays) 天区间，当前为 \(daysTotal) 天。")
        }
        let startKey = ClubDates.key(start), endKey = ClubDates.key(end)
        var covered = 0; var planned = 0; var completed = 0; var confirmedSets = 0
        var weightPoints: [(String, Double)] = []
        for key in state.days.keys.sorted() where key >= startKey && key <= endKey {
            guard let day = state.days[key] else { continue }
            // F7：覆盖只认真实记录（完成组/餐食/实测）；只有计划不算「有记录」。
            // 删除体重留下的墓碑（kilograms == nil）不是一次测量。
            let hasRecord = day.completedSets > 0 || !day.meals.isEmpty || day.bodyWeight?.hasMeasurement == true
            if hasRecord { covered += 1 }
            if let cycle = day.planCycle, cycle.dates.contains(key) {
                if cycle.plannedDates.contains(key) { planned += 1 }
            } else if !day.exercises.isEmpty { planned += 1 }
            // 同一天多场训练：只汇总已确认场次，未确认的第二场不影响第一场。
            let confirmedSlices = TrainingEvidence.confirmedSlices(day: day)
            if !confirmedSlices.isEmpty {
                completed += 1
                confirmedSets += TrainingEvidence.confirmedSetCount(day: day)
            }
            // 当日多次称重全部计入（口径表 §八第 11 条）
            for row in BodyWeightReading.rows(of: day) {
                if let kg = row.measuredKilograms { weightPoints.append((key, kg)) }
            }
        }
        guard covered >= 7 else {
            throw AIClientError.message("这段时间只有 \(covered) 天有实际记录，数据不足以生成阶段报告；继续记录一段时间后再来。")
        }
        // F7：趋势严格限定在本区间内；上一阶段也需有效覆盖才算「有环比依据」。
        let trendWindow = ClubTrendRules.trends(state: state, through: end, from: start)
        let plateau = ClubTrendRules.bodyPlateau(state: state, through: end)
        let previousStart = calendar.date(byAdding: .day, value: -daysTotal, to: start) ?? start
        let previousEnd = calendar.date(byAdding: .day, value: -1, to: start) ?? start
        let hasPrevious: Bool = {
            var count = 0
            let fromKey = ClubDates.key(previousStart), toKey = ClubDates.key(previousEnd)
            for key in state.days.keys where key >= fromKey && key <= toKey {
                guard let day = state.days[key] else { continue }
                if day.completedSets > 0 || !day.meals.isEmpty || day.bodyWeight?.hasMeasurement == true { count += 1 }
            }
            return count >= 7
        }()
        var notes: [String] = []
        notes.append("区间 \(startKey) 至 \(endKey)，共 \(daysTotal) 天，其中 \(covered) 天有实际记录；未记录的日期不计入结论。")
        if !hasPrevious { notes.append("没有完整的上一阶段数据，本次不提供环比结论。") }
        if weightPoints.count < ClubTrendThresholds.bodyPlateauMinSamples {
            notes.append("体重测量 \(weightPoints.count) 次，不足以判断体重趋势。")
        }
        notes.append("结论基于你记录的数据；动作质量、主观感受与生活状态未在记录中，不能单独据此断定增肌或减脂效果。")
        let summary = "阶段小结：完成 \(completed)/\(planned) 个训练日、累计 \(confirmedSets) 个完成组、\(covered)/\(daysTotal) 天有记录。" +
            (trendWindow.contains(where: { $0.verdict != "样本不足" }) ? "有可比训练趋势可查看。" : "可比训练数据还少，暂不作趋势判断。") +
            (plateau != nil ? " 体重进入稳定区间。" : "")
        return PhaseReport(
            // 不可变 ID：重生成出新版本、历史保留（与日报一致）；按 ID 并集合并即可正确同步。
            id: "phase/\(startKey)/\(endKey)/" + UUID().uuidString.lowercased(), start: startKey, end: endKey, generatedAt: Date(),
            daysCovered: covered, daysTotal: daysTotal,
            trainingDaysPlanned: planned, trainingDaysCompleted: completed, confirmedSets: confirmedSets,
            measuredDays: weightPoints.count,
            weightFirstKg: weightPoints.first?.1, weightLastKg: weightPoints.last?.1,
            trends: trendWindow, plateauNote: plateau, hasPreviousPhase: hasPrevious,
            summary: summary, notes: notes,
            evidenceDigest: evidenceDigest(state: state, start: startKey, end: endKey))
    }

    // MARK: - 依据指纹与历史版本

    private struct EvidenceDay: Encodable {
        let exercises: [Exercise]
        let meals: [Meal]
        let bodyWeight: BodyWeightEntry?
        let workoutSessions: [WorkoutSession]?
        let planCycle: TrainingCycle?
    }
    private struct Evidence: Encodable {
        let start: String
        let end: String
        let days: [String: EvidenceDay]
    }

    /// 只覆盖报告实际使用的记录（训练、饮食、实测体重、场次确认与计划归属），
    /// 不含报告自身、洞察或分析任务，避免生成报告本身立刻把报告标成过时。
    static func evidenceDigest(state: SavedState, start: String, end: String) -> String {
        var days: [String: EvidenceDay] = [:]
        for key in state.days.keys.sorted() where key >= start && key <= end {
            guard let day = state.days[key] else { continue }
            days[key] = EvidenceDay(exercises: day.exercises, meals: day.meals,
                                    bodyWeight: day.bodyWeight, workoutSessions: day.workoutSessions,
                                    planCycle: day.planCycle)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(Evidence(start: start, end: end, days: days)) else { return "invalid" }
        var hash: UInt64 = 14695981039346656037
        for byte in data { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return String(hash, radix: 16)
    }
    /// 报告生成后源记录是否已有变化。旧报告没有指纹时返回 false（不补造结论）。
    static func isStale(_ report: PhaseReport, state: SavedState) -> Bool {
        guard let digest = report.evidenceDigest else { return false }
        return digest != evidenceDigest(state: state, start: report.start, end: report.end)
    }
}

// MARK: - 记录页多尺度趋势
// 唯一聚合入口。缺失日期不补零；训练只取已确认场次；营养只统计已知餐食；
// 体重只取实际称重点。视图只负责呈现，不再各自计算另一种口径。

enum ReviewTrendScale: Hashable {
    case months3, months6, months12, all
    case custom(start: Date, end: Date)

    var title: String {
        switch self {
        case .months3: return "近 3 个月"
        case .months6: return "近 6 个月"
        case .months12: return "近 12 个月"
        case .all: return "累计"
        case .custom: return "自定义"
        }
    }
}

enum ReviewTrendMetric: String, CaseIterable, Identifiable {
    case confirmedSets, volume, timedMinutes, trainingDays, mealDays, calories, protein, weight, measurements
    var id: String { rawValue }
    var title: String {
        switch self {
        case .confirmedSets: return "确认完成组"
        case .volume: return "训练量"
        case .timedMinutes: return "计时训练"
        case .trainingDays: return "训练天数"
        case .mealDays: return "饮食记录天数"
        case .calories: return "已记录热量"
        case .protein: return "已记录蛋白质"
        case .weight: return "实测体重"
        case .measurements: return "体重测量次数"
        }
    }
    var unit: String {
        switch self {
        case .confirmedSets: return "组"
        case .volume: return "kg·次"
        case .timedMinutes: return "分钟"
        case .trainingDays, .mealDays: return "天"
        case .calories: return "千卡"
        case .protein: return "g"
        case .weight: return "kg"
        case .measurements: return "次"
        }
    }
}

struct ReviewTrendPoint: Identifiable, Equatable {
    let date: Date
    let value: Double
    let sampleCount: Int
    let planned: Double?
    var id: String { ClubDates.key(date) }
}

struct ReviewTrendSeries: Equatable {
    let metric: ReviewTrendMetric
    let points: [ReviewTrendPoint]
    let start: Date
    let end: Date
    let monthly: Bool
    let target: Double?
    let targetChanged: Bool
    var unit: String { metric.unit }
    var isEmpty: Bool { points.isEmpty }
}

enum ReviewTrendRules {
    private struct Bucket {
        var dayCount = 0
        var confirmedSets = 0.0
        var volume = 0.0
        var timedSeconds = 0.0
        var trainingDays = 0
        var mealDays = 0
        var calories = 0.0
        var protein = 0.0
        var nutritionDays = 0
        var weight = 0.0
        var weightDays = 0
        var plannedSets = 0.0
        var targetNotes = Set<String>()
    }

    static func range(_ scale: ReviewTrendScale, state: SavedState,
                      now: Date = Date()) -> (start: Date, end: Date, monthly: Bool) {
        let calendar = ClubDates.calendar
        let end = calendar.startOfDay(for: now)
        switch scale {
        case .months3, .months6, .months12:
            let count = scale == .months3 ? 3 : scale == .months6 ? 6 : 12
            let start = calendar.date(byAdding: .month, value: -(count - 1), to: monthStart(end)) ?? end
            return (start, end, true)
        case .all:
            let earliest = state.days.keys.compactMap(ClubDates.date(fromKey:)).min() ?? end
            return (monthStart(earliest), end, true)
        case .custom(let start, let rawEnd):
            let safeStart = calendar.startOfDay(for: min(start, rawEnd))
            let safeEnd = calendar.startOfDay(for: min(max(start, rawEnd), now))
            let span = calendar.dateComponents([.day], from: safeStart, to: safeEnd).day ?? 0
            return (safeStart, safeEnd, span >= 60)
        }
    }

    static func series(state: SavedState, scale: ReviewTrendScale, metric: ReviewTrendMetric,
                       now: Date = Date()) -> ReviewTrendSeries {
        let bounds = range(scale, state: state, now: now)
        let calendar = ClubDates.calendar
        let startKey = ClubDates.key(bounds.start), endKey = ClubDates.key(bounds.end)
        var buckets: [String: Bucket] = [:]
        for key in state.days.keys.sorted() where key >= startKey && key <= endKey {
            guard let date = ClubDates.date(fromKey: key), let day = state.days[key] else { continue }
            let bucketKey = bounds.monthly
                ? String(format: "%04d-%02d", calendar.component(.year, from: date), calendar.component(.month, from: date))
                : key
            var bucket = buckets[bucketKey] ?? Bucket()
            bucket.dayCount += 1
            let training = day.confirmedTraining
            if training.hasTraining { bucket.trainingDays += 1 }
            bucket.confirmedSets += Double(training.completedSets)
            bucket.volume += training.volume
            bucket.timedSeconds += Double(training.timedSeconds)
            if !day.meals.isEmpty { bucket.mealDays += 1 }
            if !day.knownMeals.isEmpty {
                bucket.calories += day.calories
                bucket.protein += day.protein
                bucket.nutritionDays += 1
            }
            for row in BodyWeightReading.rows(of: day) {
                if let kg = row.measuredKilograms { bucket.weight += kg; bucket.weightDays += 1 }
            }
            let planned = day.planCycle.map { $0.plannedDates.contains(key) } ?? !day.exercises.isEmpty
            if planned { bucket.plannedSets += Double(day.totalSets) }
            if let target = day.nutritionTarget {
                bucket.targetNotes.insert("\(target.caloriesMin)-\(target.caloriesMax)-\(target.proteinMin)-\(target.proteinMax)")
            }
            buckets[bucketKey] = bucket
        }
        var points: [ReviewTrendPoint] = []
        var targetChanged = false
        var allTargets = Set<String>()
        for (key, bucket) in buckets.sorted(by: { $0.key < $1.key }) {
            allTargets.formUnion(bucket.targetNotes)
            let date: Date
            if bounds.monthly {
                let parts = key.split(separator: "-").compactMap { Int($0) }
                date = calendar.date(from: DateComponents(year: parts.first, month: parts.count > 1 ? parts[1] : 1, day: 1)) ?? bounds.start
            } else {
                date = ClubDates.date(fromKey: key) ?? bounds.start
            }
            let value: Double?
            let samples: Int
            switch metric {
            case .confirmedSets: value = bucket.confirmedSets; samples = bucket.dayCount
            case .volume: value = bucket.volume; samples = bucket.dayCount
            case .timedMinutes: value = bucket.timedSeconds / 60; samples = bucket.dayCount
            case .trainingDays: value = Double(bucket.trainingDays); samples = bucket.dayCount
            case .mealDays: value = Double(bucket.mealDays); samples = bucket.dayCount
            case .calories: value = bucket.nutritionDays > 0 ? bucket.calories / Double(bucket.nutritionDays) : nil; samples = bucket.nutritionDays
            case .protein: value = bucket.nutritionDays > 0 ? bucket.protein / Double(bucket.nutritionDays) : nil; samples = bucket.nutritionDays
            case .weight: value = bucket.weightDays > 0 ? bucket.weight / Double(bucket.weightDays) : nil; samples = bucket.weightDays
            case .measurements: value = bucket.weightDays > 0 ? Double(bucket.weightDays) : nil; samples = bucket.weightDays
            }
            guard let value, value.isFinite else { continue }
            let planned = metric == .confirmedSets && bucket.plannedSets > 0 ? bucket.plannedSets : nil
            points.append(ReviewTrendPoint(date: date, value: value, sampleCount: samples, planned: planned))
        }
        targetChanged = allTargets.count > 1
        let target: Double? = {
            switch metric {
            case .weight: return state.profile.targetWeightKg
            case .calories:
                guard let value = state.nutritionTarget, !targetChanged else { return nil }
                return (value.caloriesMin + value.caloriesMax) / 2
            case .protein:
                guard let value = state.nutritionTarget, !targetChanged else { return nil }
                return (value.proteinMin + value.proteinMax) / 2
            default: return nil
            }
        }()
        return ReviewTrendSeries(metric: metric, points: points, start: bounds.start, end: bounds.end,
                                 monthly: bounds.monthly, target: target, targetChanged: targetChanged)
    }

    private static func monthStart(_ date: Date) -> Date {
        let calendar = ClubDates.calendar
        return calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
    }
}
