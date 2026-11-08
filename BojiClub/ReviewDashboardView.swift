import SwiftUI
import Charts

private struct ReviewDay: Identifiable {
    let date: Date
    let log: DayLog
    var id: String { ClubDates.key(date) }
}

private struct ReviewExerciseHistoryEntry: Identifiable {
    let id: String
    let date: Date
    let sets: Int
    let repetitions: Int
    let volume: Double
    let bestWeight: Double
    let estimatedOneRepMax: Double?
}

private struct ReviewExerciseAggregate: Identifiable {
    let id: String
    let name: String
    let muscle: String
    var sets = 0
    var repetitions = 0
    var volume = 0.0
    var bestWeight = 0.0
    var estimatedOneRepMax: Double? = nil
    var personalRecords = ReviewExercisePersonalRecords()
    var history: [ReviewExerciseHistoryEntry] = []
    var includesBestWeightRecord: Bool {
        guard personalRecords.bestWeight > 0, let recordDate = personalRecords.bestWeightDate else { return false }
        let recordKey = ClubDates.key(recordDate)
        return history.contains {
            ClubDates.key($0.date) == recordKey && abs($0.bestWeight - personalRecords.bestWeight) < 0.0001
        }
    }

    mutating func include(_ exercise: Exercise, on date: Date) {
        let valid = exercise.sets.filter(\.validCompletion)
        guard !valid.isEmpty else { return }
        let repSets = valid.filter { $0.durationSeconds == nil }
        let repCount = repSets.reduce(0) { $0 + $1.reps }
        let addedVolume = valid.reduce(0) { $0 + $1.volume }
        let best = repSets.map(\.weight).filter { $0 > 0 }.max() ?? 0
        let estimate = repSets.filter { $0.weight > 0 && (1...10).contains($0.reps) }
            .map { set in set.reps == 1 ? set.weight : (set.weight * (1 + Double(set.reps) / 30)) }.max()
        sets += valid.count
        repetitions += repCount
        volume += addedVolume
        bestWeight = max(bestWeight, best)
        if let estimate { estimatedOneRepMax = max(estimatedOneRepMax ?? 0, estimate) }
        history.append(ReviewExerciseHistoryEntry(
            id: "\(ClubDates.key(date))-\(history.count)-\(valid.count)", date: date,
            sets: valid.count, repetitions: repCount, volume: addedVolume,
            bestWeight: best, estimatedOneRepMax: estimate
        ))
    }
}

private struct ReviewExercisePersonalRecords {
    var bestWeight: Double = 0
    var bestWeightDate: Date?
    var estimatedOneRepMax: Double = 0
    var estimatedOneRepMaxDate: Date?
}

private struct ReviewMuscleAggregate: Identifiable {
    let name: String
    let sets: Int
    let repetitions: Int
    let volume: Double
    var id: String { name }
}

struct ReviewDashboardView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var account: AccountService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedDay: ReviewDay?
    @State private var selectedExercise: ReviewExerciseAggregate?
    @State private var window = "本月"
    @State private var reviewMonth = Date()
    @State private var trendScaleKey = "近 3 个月"
    @State private var trendMetric: ReviewTrendMetric = .confirmedSets
    @State private var customStart = ClubDates.calendar.date(byAdding: .month, value: -2, to: Date()) ?? Date()
    @State private var customEnd = Date()
    @State private var showRecords = false
    @State private var analysisSection = "趋势"
    @State private var recordLimit = 20
    @State private var showMethodologySheet = false
    @State private var selectedTrendPoint: ReviewTrendPoint? = nil
    @State private var showDiagnosticCoach = false

    private var monthStart: Date { ClubDates.calendar.dateInterval(of: .month, for: reviewMonth)?.start ?? reviewMonth }
    private var earliestMonth: Date {
        let actual = store.state.days.compactMap { key, log in HistoryVisibility.hasRecordedActivity(log) ? ClubDates.date(fromKey: key) : nil }.min()
        let first = [actual, HistoryVisibility.joinedDate(account.user?.createdAt), Date()].compactMap { $0 }.min() ?? Date()
        return ClubDates.calendar.dateInterval(of: .month, for: first)?.start ?? first
    }
    private var days: [ReviewDay] {
        let today = ClubDates.calendar.startOfDay(for: Date())
        if window == "累计" {
            return store.state.days.compactMap { key, log -> ReviewDay? in
                guard let date = ClubDates.date(fromKey: key), date <= today, HistoryVisibility.hasRecordedActivity(log) else { return nil }
                return ReviewDay(date: date, log: log)
            }.sorted { $0.date < $1.date }
        }
        guard let range = ClubDates.calendar.dateInterval(of: .month, for: reviewMonth),
              let count = ClubDates.calendar.range(of: .day, in: .month, for: reviewMonth) else { return [] }
        let joined = HistoryVisibility.joinedDate(account.user?.createdAt).map { ClubDates.calendar.startOfDay(for: $0) }
        return count.compactMap { number in
            guard let date = ClubDates.calendar.date(byAdding: .day, value: number - 1, to: range.start), date <= today else { return nil }
            let log = store.log(for: date)
            if let joined, date < joined, !HistoryVisibility.hasRecordedActivity(log) { return nil }
            return ReviewDay(date: date, log: log)
        }
    }
    private var recordedDays: [ReviewDay] { days.filter { HistoryVisibility.hasRecordedActivity($0.log) }.sorted { $0.date > $1.date } }
    private var periodTitle: String { window == "累计" ? "累计训练回顾" : ClubDates.label(reviewMonth, format: "yyyy年M月") + "回顾" }
    private var periodDescription: String {
        if window == "累计" { return "全部已确认的训练记录" }
        return ClubDates.calendar.isDate(reviewMonth, equalTo: Date(), toGranularity: .month)
            ? "当月已确认记录汇总"
            : "所选月份已确认记录汇总"
    }

    var body: some View {
        VStack(spacing: BojiLayout.cardInset) {
            periodControls
            summaryCard
            HStack {
                HStack(spacing: BojiLayout.tight) {
                    ForEach(["趋势", "动作", "历史"], id: \.self) { section in
                        Button {
                            BojiHaptics.selection()
                            withAnimation(.smooth(duration: 0.22)) {
                                analysisSection = section
                            }
                        } label: {
                            HStack(spacing: BojiLayout.tight) {
                                Image(systemName: section == "趋势" ? "chart.line.uptrend.xyaxis" : section == "动作" ? "figure.strengthtraining.traditional" : "clock.arrow.circlepath")
                                    .bojiType(.caption)
                                Text(section)
                                    .bojiType(.secondary)
                            }
                            .foregroundStyle(analysisSection == section ? BojiColor.textPrimary : BojiColor.textSecondary)
                            .padding(.horizontal, BojiLayout.rowGap)
                            .padding(.vertical, BojiLayout.inline)
                            .background {
                                if analysisSection == section {
                                    Capsule()
                                        .fill(BojiColor.cardSurface)
                                        .shadow(color: Color.black.opacity(0.06), radius: 4, y: 1)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("records-analysis-\(section)")
                    }
                }
                .padding(BojiLayout.tight)
                .background(BojiColor.inputSurface.opacity(0.65), in: Capsule())
                Spacer()
            }
            .accessibilityIdentifier("records-analysis-section")
            if analysisSection == "趋势" {
                trendCard
                DisclosureGroup("本期观察与建议") { diagnosticInsightCard.padding(.top, BojiSpace.general) }
                    .bojiType(.secondary).tint(ClubBrand.accent)
            } else if analysisSection == "动作" {
                muscleBreakdownCard
                exerciseBreakdownCard
            } else { recordsCard }
        }
        .sheet(item: $selectedDay) { ReviewDayDetailView(day: $0) }
        .sheet(item: $selectedExercise) { ReviewExerciseHistoryView(exercise: $0, periodTitle: periodTitle) }
        .onChange(of: window) { _, _ in recordLimit = 20 }
        .onChange(of: reviewMonth) { _, _ in recordLimit = 20 }
    }
    private var exerciseAnalytics: [ReviewExerciseAggregate] {
        var values: [String: ReviewExerciseAggregate] = [:]
        for day in days {
            let log = day.log
            let exercises = log.confirmedTraining.exercises
            for exercise in exercises {
                let key = exerciseIdentity(exercise)
                var aggregate = values[key] ?? ReviewExerciseAggregate(id: key, name: exercise.displayName, muscle: exercise.muscle.isEmpty ? "未标注" : exercise.muscle)
                aggregate.include(exercise, on: day.date)
                values[key] = aggregate
            }
        }
        let records = allTimeExerciseRecords
        return values.values.map { value in
            var aggregate = value
            aggregate.personalRecords = records[value.id] ?? ReviewExercisePersonalRecords()
            return aggregate
        }.sorted {
            if $0.volume != $1.volume { return $0.volume > $1.volume }
            if $0.sets != $1.sets { return $0.sets > $1.sets }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
    private func exerciseIdentity(_ exercise: Exercise) -> String {
        if let identity = ClubExerciseIdentity.of(exercise) { return identity }
        let name = exercise.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let equipment = (exercise.equipment ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "name:\(name)|equipment:\(equipment)"
    }
    private var allTimeExerciseRecords: [String: ReviewExercisePersonalRecords] {
        var records: [String: ReviewExercisePersonalRecords] = [:]
        let today = ClubDates.calendar.startOfDay(for: Date())
        for (dateKey, log) in store.state.days.sorted(by: { $0.key < $1.key }) {
            guard let date = ClubDates.date(fromKey: dateKey), date <= today else { continue }
            let exercises = log.confirmedTraining.exercises
            for exercise in exercises {
                let repSets = exercise.sets.filter(\.validCompletion).filter { $0.durationSeconds == nil && $0.weight > 0 }
                let key = exerciseIdentity(exercise)
                var value = records[key] ?? ReviewExercisePersonalRecords()
                for set in repSets {
                    if set.weight > value.bestWeight ||
                        (set.weight == value.bestWeight && (value.bestWeightDate.map { date < $0 } ?? true)) {
                        value.bestWeight = set.weight
                        value.bestWeightDate = date
                    }
                    if (1...10).contains(set.reps) {
                        let estimate = set.weight * (1 + Double(set.reps) / 30)
                        if estimate > value.estimatedOneRepMax ||
                            (estimate == value.estimatedOneRepMax && (value.estimatedOneRepMaxDate.map { date < $0 } ?? true)) {
                            value.estimatedOneRepMax = estimate
                            value.estimatedOneRepMaxDate = date
                        }
                    }
                }
                records[key] = value
            }
        }
        return records
    }
    private var muscleAnalytics: [ReviewMuscleAggregate] {
        Dictionary(grouping: exerciseAnalytics, by: \.muscle).map { name, exercises in
            ReviewMuscleAggregate(name: name,
                                  sets: exercises.reduce(0) { $0 + $1.sets },
                                  repetitions: exercises.reduce(0) { $0 + $1.repetitions },
                                  volume: exercises.reduce(0) { $0 + $1.volume })
        }.sorted { $0.sets == $1.sets ? $0.name < $1.name : $0.sets > $1.sets }
    }
    private var linkedDeviceCalories: Double? {
        var seen = Set<String>()
        var total = 0.0
        var found = false
        for day in days {
            let log = day.log
            let ids: Set<String>
            if let sessions = log.workoutSessions, !sessions.isEmpty {
                ids = Set(log.confirmedWorkoutSessions.compactMap(\.linkedDeviceWorkoutID))
            } else if log.isTrainingConfirmed, let id = log.linkedDeviceWorkoutID {
                ids = [id]
            } else { ids = [] }
            for workout in log.health?.workouts ?? [] where ids.contains(workout.id) && seen.insert(workout.id).inserted {
                if let calories = workout.calories { total += calories; found = true }
            }
        }
        return found ? total : nil
    }

    private var muscleBreakdownCard: some View {
        ClubCard {
            Text("练到了哪些部位").bojiType(.section)
            if let top = muscleAnalytics.first {
                Text("\(top.name)登记最多 · \(top.sets) 组").bojiType(.secondary).foregroundStyle(.secondary)
            }
            if muscleAnalytics.isEmpty {
                EmptyNote(title: "还没有肌群数据", detail: "确认训练后，这里会展示各部位的实际完成组数。")
            } else {
                MuscleFlower134(items: muscleAnalytics.map { MusclePetal134(name: $0.name, sets: $0.sets) })
            }
        }
    }

    private var exerciseBreakdownCard: some View {
        ClubCard {
            SectionTitle(title: "动作表现与历史", symbol: "dumbbell")
            Text("点击动作查看每次记录；同名但器械不同的动作分开统计。")
                .bojiType(.label).foregroundStyle(.secondary)
            if exerciseAnalytics.isEmpty {
                EmptyNote(title: "暂无动作记录", detail: "完成并确认训练后，动作的最好重量、估算 1RM、总量和历史会显示在这里。")
            } else {
                // Top5 动作训练量横向条形图
                Chart(exerciseAnalytics.prefix(5)) { exercise in
                    BarMark(x: .value("训练量", exercise.volume), y: .value("动作", exercise.name))
                        .foregroundStyle(LinearGradient(colors: [BojiColor.mistAccent, BojiColor.mistAccent.opacity(0.55)], startPoint: .leading, endPoint: .trailing))
                        .cornerRadius(4)
                        .accessibilityLabel(exercise.name)
                        .accessibilityValue("\(exercise.volume.formatted(.number.precision(.fractionLength(0)))) kg·次")
                }
                .chartXAxis { AxisMarks(position: .bottom, values: .automatic(desiredCount: 3)) }
                .chartYAxis { AxisMarks(position: .leading) }
                .chartLegend(.hidden)
                .frame(height: 5 * 26 + 16)
                ForEach(exerciseAnalytics.prefix(10)) { exercise in
                    Button { selectedExercise = exercise } label: {
                        VStack(alignment: .leading, spacing: BojiLayout.tight) {
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: BojiLayout.tight) {
                                    Text(exercise.name).bojiType(.secondary).foregroundStyle(BojiColor.textPrimary)
                                    Text(exercise.muscle).bojiType(.caption).foregroundStyle(BojiColor.textSecondary)
                                }
                                Spacer()
                                Text("\(exercise.sets) 组").bojiType(.caption).foregroundStyle(BojiColor.textSecondary)
                                if exercise.includesBestWeightRecord {
                                    HStack(spacing: BojiLayout.tight) {
                                        Image(systemName: "flame.fill").bojiType(.caption)
                                        Text("新高 PR").bojiType(.caption)
                                    }
                                    .padding(.horizontal, BojiLayout.inline).padding(.vertical, BojiLayout.tight)
                                    .background(BojiColor.timerAccent.opacity(0.12), in: Capsule())
                                    .foregroundStyle(BojiColor.timerAccent)
                                }
                            }
                            HStack(spacing: BojiLayout.inline) {
                                Text("\(exercise.repetitions) 次")
                                if exercise.bestWeight > 0 {
                                    Text("最高外加重量 \(exercise.bestWeight.formatted(.number.precision(.fractionLength(0...1)))) kg")
                                } else {
                                    Text("无已记录外加重量")
                                }
                                if let estimate = exercise.estimatedOneRepMax {
                                    Text("估算 1RM \(estimate.formatted(.number.precision(.fractionLength(0...1))))")
                                }
                            }.bojiType(.caption).foregroundStyle(BojiColor.textTertiary).lineLimit(1).minimumScaleFactor(0.8)
                            Text("负重训练量 \(exercise.volume.formatted(.number.precision(.fractionLength(0...1)))) kg·次 · \(exercise.history.count) 条训练记录")
                                .bojiType(.caption).foregroundStyle(BojiColor.textSecondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }.buttonStyle(ClubMotionButton())
                    if exercise.id != exerciseAnalytics.prefix(10).last?.id { Divider() }
                }
            }
            Text("1RM 按 Epley 公式估算，仅作参考，不代表你实际完成过该重量。")
                .bojiType(.label).foregroundStyle(.secondary)
        }
    }
    private var periodControls: some View {
        VStack(spacing: BojiLayout.inline) {
            HStack {
                    Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left") }.buttonStyle(ClubIconButtonStyle()).disabled(monthStart <= earliestMonth).accessibilityLabel("上个月")
                    Spacer()
                    Text(ClubDates.label(reviewMonth, format: "yyyy年 M月")).bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
                    Spacer()
                    Button { shiftMonth(1) } label: { Image(systemName: "chevron.right") }.buttonStyle(ClubIconButtonStyle()).disabled(ClubDates.calendar.isDate(reviewMonth, equalTo: Date(), toGranularity: .month)).accessibilityLabel("下个月")
            }
        }
    }
    private func shiftMonth(_ amount: Int) {
        if let date = ClubDates.calendar.date(byAdding: .month, value: amount, to: monthStart) { reviewMonth = date }
    }
    /// 上一周期汇总：仅"本月"口径取上月同长度日期范围逐日 store.log(for:) 汇总；"累计"口径返回 nil（不显示环比）。
    private var previousPeriodMetrics: ReviewMetrics? {
        guard window != "累计",
              let previousMonth = ClubDates.calendar.date(byAdding: .month, value: -1, to: reviewMonth),
              let previousStart = ClubDates.calendar.dateInterval(of: .month, for: previousMonth)?.start,
              let currentCount = ClubDates.calendar.range(of: .day, in: .month, for: reviewMonth)?.count,
              let previousCount = ClubDates.calendar.range(of: .day, in: .month, for: previousMonth)?.count
        else { return nil }
        let elapsed = ClubDates.calendar.isDate(reviewMonth, equalTo: Date(), toGranularity: .month) ? ClubDates.calendar.component(.day, from: Date()) : currentCount
        let logs = (0..<min(elapsed, previousCount)).compactMap { offset -> DayLog? in
            guard let date = ClubDates.calendar.date(byAdding: .day, value: offset, to: previousStart) else { return nil }
            return store.log(for: date)
        }
        return ReviewMetrics(logs: logs)
    }
    /// 连续训练周数：按 ISO 周（weekOfYear + yearForWeekOfYear）从今天所在周向前连续计数，中断即停。
    private var consecutiveTrainingWeeks: Int {
        let calendar = ClubDates.calendar
        func weekKey(_ date: Date) -> Int? {
            let components = calendar.dateComponents([.weekOfYear, .yearForWeekOfYear], from: date)
            guard let week = components.weekOfYear, let year = components.yearForWeekOfYear else { return nil }
            return year * 100 + week
        }
        var trainedWeeks = Set<Int>()
        for (key, log) in store.state.days {
            guard log.confirmedTraining.hasTraining,
                  let date = ClubDates.date(fromKey: key),
                  let week = weekKey(date) else { continue }
            trainedWeeks.insert(week)
        }
        var count = 0
        var cursor = Date()
        if let current = weekKey(cursor), !trainedWeeks.contains(current), let previous = calendar.date(byAdding: .weekOfYear, value: -1, to: cursor) { cursor = previous }
        while let week = weekKey(cursor), trainedWeeks.contains(week) {
            count += 1
            guard let previous = calendar.date(byAdding: .weekOfYear, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return count
    }
    /// 与 BojiVolumeHeatStrip 五级色阶一致的图例取色（0 档为无训练浅底，不列入图例）。
    private func heatStripLegendColor(_ level: Int) -> Color {
        switch level {
        case 0: return BojiColor.mistAccent.opacity(0.22)
        case 1: return BojiColor.mistAccent.opacity(0.42)
        case 2: return BojiColor.mistAccent.opacity(0.65)
        case 3: return BojiColor.mistAccent.opacity(0.85)
        default: return BojiColor.mistAccent
        }
    }
    private func summaryTile(title: String, value: String, unit: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: BojiLayout.tight) {
            HStack(spacing: BojiLayout.tight) {
                Image(systemName: icon)
                    .bojiType(.caption)
                    .foregroundStyle(BojiColor.textTertiary)
                Text(title)
                    .bojiType(.caption)
                    .foregroundStyle(BojiColor.textSecondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(value)
                    .bojiType(.section)
                    .foregroundStyle(BojiColor.textPrimary)
                Text(unit)
                    .bojiType(.caption)
                    .foregroundStyle(BojiColor.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, BojiLayout.inline).padding(.vertical, BojiLayout.inline)
        .background(BojiColor.inputSurface, in: RoundedRectangle(cornerRadius: BojiRadius.control, style: .continuous))
    }

    private func muscleColor(_ index: Int) -> Color {
        let colors = [
            BojiColor.timerAccent,
            BojiColor.mistAccent,
            BojiColor.macroFat,
            BojiColor.macroCarbs,
            BojiColor.macroProtein
        ]
        return colors[index % colors.count]
    }

    private func signed(_ value: Double) -> String { value.formatted(.number.sign(strategy: .always()).precision(.fractionLength(0))) }

    private var summaryCard: some View {
        let totals = ReviewMetrics(logs: days.map(\.log))
        let muscles = muscleAnalytics
        let totalMuscleSets = max(1, muscles.reduce(0) { $0 + $1.sets })
        return ClubCard {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(periodTitle)
                        .bojiType(.caption)
                        .foregroundStyle(BojiColor.textSecondary)
                    Text(totals.confirmedTrainingDays > 0 ? "阶段训练表现" : "开启训练打卡")
                        .bojiType(.section)
                        .foregroundStyle(BojiColor.textPrimary)
                }
                Spacer()
                if consecutiveTrainingWeeks > 0 {
                    HStack(spacing: BojiLayout.tight) {
                        Image(systemName: "flame.fill")
                            .bojiType(.label)
                            .foregroundStyle(BojiColor.timerAccent)
                        Text("连练 \(consecutiveTrainingWeeks) 周")
                            .bojiType(.caption)
                            .foregroundStyle(BojiColor.textPrimary)
                    }
                    .padding(.horizontal, BojiLayout.inline).padding(.vertical, BojiLayout.tight)
                    .background(BojiColor.inputSurface, in: Capsule())
                }
            }

            HStack(spacing: BojiLayout.inline) {
                summaryTile(title: "负荷总量", value: totals.confirmedVolume >= 1000 ? (totals.confirmedVolume / 1000).formatted(.number.precision(.fractionLength(1))) : totals.confirmedVolume.formatted(.number.precision(.fractionLength(0))), unit: totals.confirmedVolume >= 1000 ? "千 kg·次" : "kg·次", icon: "scalemass.fill")
                summaryTile(title: "完成组数", value: "\(totals.confirmedSets)", unit: "组", icon: "checkmark.circle.fill")
                summaryTile(title: "训练天数", value: "\(totals.confirmedTrainingDays)", unit: "天", icon: "calendar")
            }
            .padding(.vertical, BojiLayout.tight)
            Text(periodDescription + " · 只统计已确认训练和实际称重。")
                .bojiType(.caption).foregroundStyle(BojiColor.textSecondary)
            if totals.completedSets > totals.confirmedSets {
                Text("另有 \(totals.completedSets - totals.confirmedSets) 组已登记待确认。")
                    .bojiType(.caption).foregroundStyle(BojiColor.textSecondary)
            }

            if let previous = previousPeriodMetrics {
                let dayDiff = totals.confirmedTrainingDays - previous.confirmedTrainingDays
                let setDiff = totals.confirmedSets - previous.confirmedSets
                HStack(spacing: BojiLayout.tight) {
                    Image(systemName: dayDiff >= 0 ? "arrow.up.right" : "arrow.down.right")
                        .bojiType(.caption)
                        .foregroundStyle(dayDiff >= 0 ? BojiColor.timerAccent : BojiColor.textTertiary)
                    Text("较上期：训练天数 \(signed(Double(dayDiff))) 天 · 完成组数 \(signed(Double(setDiff))) 组")
                        .bojiType(.caption)
                        .foregroundStyle(BojiColor.textSecondary)
                }
                .padding(.horizontal, BojiLayout.inline).padding(.vertical, BojiLayout.tight)
                .background(BojiColor.inputSurface.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            if !muscles.isEmpty {
                VStack(alignment: .leading, spacing: BojiLayout.inline) {
                    HStack {
                        Text("肌群训练分布")
                            .bojiType(.caption)
                            .foregroundStyle(BojiColor.textSecondary)
                        Spacer()
                        Text("\(muscles.count) 个部位")
                            .bojiType(.caption)
                            .foregroundStyle(BojiColor.textTertiary)
                    }
                    Chart {
                        ForEach(Array(muscles.prefix(5).enumerated()), id: \.element.id) { index, muscle in
                            BarMark(
                                x: .value("组数", muscle.sets),
                                y: .value("类别", "部位")
                            )
                            .foregroundStyle(muscleColor(index))
                        }
                    }
                    .chartXAxis(.hidden)
                    .chartYAxis(.hidden)
                    .chartLegend(.hidden)
                    .frame(height: 7)
                    .clipShape(Capsule())
                    HStack(spacing: BojiLayout.inline) {
                        ForEach(Array(muscles.prefix(4).enumerated()), id: \.element.id) { index, muscle in
                            HStack(spacing: BojiLayout.tight) {
                                Circle().fill(muscleColor(index)).frame(width: 6, height: 6)
                                Text("\(muscle.name) \(muscle.sets)组")
                                    .bojiType(.caption)
                                    .foregroundStyle(BojiColor.textSecondary)
                            }
                        }
                    }
                }
                .padding(BojiLayout.inline)
                .background(BojiColor.inputSurface.opacity(0.4), in: RoundedRectangle(cornerRadius: BojiRadius.inner, style: .continuous))
            }

            VStack(alignment: .leading, spacing: BojiLayout.tight) {
                HStack {
                    Text("这周练了几次")
                        .bojiType(.caption)
                        .foregroundStyle(BojiColor.textSecondary)
                    Spacer()
                    Text("已打卡 \(totals.confirmedTrainingDays) 天")
                        .bojiType(.caption)
                        .foregroundStyle(BojiColor.textPrimary)
                }
                BojiVolumeHeatStrip(cells: days.map { day in
                    let confirmed = day.log.confirmedTraining
                    let label = confirmed.completedSets > 0
                        ? "\(ClubDates.label(day.date, format: "M月d日")) · 已确认\(confirmed.completedSets)组 · 训练量\(confirmed.volume.formatted(.number.precision(.fractionLength(0)))) kg·次"
                        : "\(ClubDates.label(day.date, format: "M月d日")) · 无训练"
                    return BojiVolumeHeatStrip.Cell(date: day.date, value: confirmed.volume, label: label)
                }, onSelect: nil)
            }
            .padding(BojiLayout.inline)
            .background(BojiColor.inputSurface.opacity(0.4), in: RoundedRectangle(cornerRadius: BojiRadius.inner, style: .continuous))

            DisclosureGroup("训练与身体数据明细") {
                VStack(spacing: BojiLayout.rowGap) {
                    LabeledContent("已记录训练时长", value: "\(totals.confirmedElapsedSeconds / 60) 分钟")
                    LabeledContent("完成重复次数", value: "\(totals.confirmedRepetitions) 次")
                    LabeledContent("计时动作累计", value: "\(totals.confirmedTimedSeconds / 60) 分钟")
                    Divider()
                    LabeledContent("饮食记录", value: "\(totals.mealDays) 天 · \(totals.meals) 餐")
                    LabeledContent("实际称重", value: "\(totals.weightMeasurements) 次")
                    LabeledContent("关联设备运动能量", value: linkedDeviceCalories.map { $0.formatted(.number.precision(.fractionLength(0))) + " kcal" } ?? "暂无")
                }.bojiType(.secondary).padding(.top, BojiSpace.general)
            }.bojiType(.secondary).tint(ClubBrand.accent)
        }
    }
    private var trendCard: some View {
        let series = ReviewTrendRules.series(state: store.state, scale: selectedTrendScale, metric: trendMetric)
        return ClubCard {
            HStack {
                SectionTitle(title: "多尺度趋势", symbol: "chart.bar.xaxis")
                Spacer()
                if let point = selectedTrendPoint {
                    HStack(spacing: BojiLayout.tight) {
                        Text(ClubDates.label(point.date, format: series.monthly ? "yyyy年M月" : "M月d日"))
                            .bojiType(.caption).foregroundStyle(BojiColor.textSecondary)
                        Text("\(point.value.formatted(.number.precision(.fractionLength(1)))) \(series.unit)")
                            .bojiType(.caption)
                            .foregroundStyle(BojiColor.timerAccent)
                    }
                    .padding(.horizontal, BojiSpace.tightRow).padding(.vertical, BojiLayout.tight)
                    .background(BojiColor.inputSurface, in: Capsule())
                }
            }
            BojiChipRow(items: ["近 3 个月", "近 6 个月", "近 12 个月", "自定义", "累计"], selection: $trendScaleKey)
                .onChange(of: trendScaleKey) { _, _ in selectedTrendPoint = nil }
            if trendScaleKey == "自定义" {
                HStack {
                    DatePicker("开始", selection: $customStart, in: ...customEnd, displayedComponents: .date)
                    DatePicker("结束", selection: $customEnd, in: customStart...Date(), displayedComponents: .date)
                }.bojiType(.caption)
            }
            Picker("趋势指标", selection: $trendMetric) {
                ForEach(ReviewTrendMetric.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.menu)
                .onChange(of: trendMetric) { _, _ in selectedTrendPoint = nil }
            if series.points.isEmpty {
                Text("这段时间没有这个指标的实际记录。先记录一次训练、饮食或称重，再回来查看。")
                    .bojiType(.secondary).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 90)
            } else {
                let baselineWeight = (series.points.map(\.value).min() ?? 60) - 2
                Chart {
                    if series.metric == .weight {
                        weightMarks(series: series, baseline: baselineWeight)
                    } else {
                        barMarks(series: series)
                    }
                    if let target = series.target, series.metric == .weight || series.metric == .calories || series.metric == .protein {
                        RuleMark(y: .value("目标", target))
                            .foregroundStyle(BojiColor.timerAccent.opacity(0.6))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    }
                    if let sel = selectedTrendPoint {
                        RuleMark(x: .value("所选", sel.date, unit: series.monthly ? .month : .day))
                            .foregroundStyle(BojiColor.timerAccent.opacity(0.4))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                }
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.month(.abbreviated)) } }
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        Rectangle().fill(Color.clear).contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 10)
                                    .onChanged { value in
                                        guard let plotFrame = proxy.plotFrame else { return }
                                        let currentX = value.location.x - geometry[plotFrame].origin.x
                                        guard let date: Date = proxy.value(atX: currentX) else { return }
                                        if let closest = series.points.min(by: { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }) {
                                            if selectedTrendPoint?.id != closest.id {
                                                selectedTrendPoint = closest
                                                BojiHaptics.selection()
                                            }
                                        }
                                    }
                            )
                    }
                }
                .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
                .chartYScale(domain: series.metric == .weight ? NativeData134.domain(series.points.map(\.value), target: series.target) : 0...max(1, (series.points.map { max($0.value, $0.planned ?? 0) }.max() ?? 1) * 1.15))
                .frame(height: 210)
                .animation(reduceMotion ? nil : .smooth(duration: 0.4), value: series)
                Text(trendDescription(series))
                    .bojiType(.label).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    @ChartContentBuilder
    private func weightMarks(series: ReviewTrendSeries, baseline: Double) -> some ChartContent {
        ForEach(series.points) { point in
            PointMark(x: .value("日期", point.date), y: .value("体重", point.value))
                .foregroundStyle(point.id == selectedTrendPoint?.id ? BojiColor.timerAccent : BojiColor.mistAccent)
                .symbolSize(point.id == selectedTrendPoint?.id ? 56 : 36)
            AreaMark(x: .value("日期", point.date), yStart: .value("基准", baseline), yEnd: .value("体重", point.value))
                .foregroundStyle(LinearGradient(colors: [BojiColor.mistAccent.opacity(0.14), BojiColor.mistAccent.opacity(0.01)], startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.linear)
            LineMark(x: .value("日期", point.date), y: .value("体重", point.value))
                .foregroundStyle(BojiColor.mistAccent.opacity(0.85))
                .interpolationMethod(.linear)
        }
    }

    @ChartContentBuilder
    private func barMarks(series: ReviewTrendSeries) -> some ChartContent {
        ForEach(series.points) { point in
            if let planned = point.planned {
                BarMark(x: .value("日期", point.date, unit: series.monthly ? .month : .day),
                        yStart: .value("起点", 0), yEnd: .value("计划", planned))
                    .foregroundStyle(BojiColor.textTertiary.opacity(0.22))
                    .cornerRadius(3)
            }
            BarMark(x: .value("日期", point.date, unit: series.monthly ? .month : .day),
                    yStart: .value("起点", 0), yEnd: .value(series.metric.title, point.value))
                .foregroundStyle(barStyle(for: point))
                .cornerRadius(3)
                .accessibilityLabel(ClubDates.label(point.date, format: series.monthly ? "yyyy年M月" : "M月d日"))
                .accessibilityValue("\(point.value.formatted(.number.precision(.fractionLength(1)))) \(series.unit)")
        }
    }

    private func barStyle(for point: ReviewTrendPoint) -> AnyShapeStyle {
        if point.id == selectedTrendPoint?.id {
            return AnyShapeStyle(BojiColor.timerAccent)
        }
        return AnyShapeStyle(LinearGradient(
            colors: [BojiColor.mistAccent, BojiColor.mistAccent.opacity(0.55)],
            startPoint: .top, endPoint: .bottom
        ))
    }

    private var selectedTrendScale: ReviewTrendScale {
        switch trendScaleKey {
        case "近 6 个月": return .months6
        case "近 12 个月": return .months12
        case "累计": return .all
        case "自定义": return .custom(start: customStart, end: customEnd)
        default: return .months3
        }
    }
    private func trendDescription(_ series: ReviewTrendSeries) -> String {
        let buckets = series.monthly ? "按月统计" : "按日统计"
        let range = ClubDates.key(series.start) + " 至 " + ClubDates.key(series.end)
        var text = "\(range) · \(buckets)"
        if let target = series.target { text += " · 目标参考 \(target.formatted(.number.precision(.fractionLength(0)))) \(series.unit)" }
        return text
    }

        private var recordsCard: some View {
        let rows = recordedDays
        let trainingDays = rows.filter { $0.log.confirmedTraining.hasTraining }.sorted { $0.date < $1.date }
        let events: [RecordMilestone134] = trainingDays.enumerated().compactMap { index, day in
            guard index == 0 || index == trainingDays.count - 1 else { return nil }
            return RecordMilestone134(id: ClubDates.key(day.date), date: day.date,
                title: index == 0 ? "本期首次训练" : "本期最近训练",
                detail: "完成 \(day.log.confirmedTraining.completedSets) 组 · \(day.log.confirmedTraining.exercises.count) 个动作")
        }
        return ClubCard {
            if !events.isEmpty {
                Text("你的训练足迹").bojiType(.section)
                RecordTimeline134(events: events)
            }
            DisclosureGroup("逐日记录 · \(rows.count) 天", isExpanded: $showRecords) {
                if rows.isEmpty { Text("这段时间还没有实际记录，空白日期和训练计划不会列为已训练。").bojiType(.secondary).foregroundStyle(.secondary) }
                ForEach(Array(rows.prefix(recordLimit))) { day in
                    Button { selectedDay = day } label: {
                        HStack {
                            Text(ClubDates.label(day.date, format: "M月d日 EEE")).bojiType(.secondary)
                            Spacer()
                            Text("已登记 \(day.log.confirmedTraining.completedSets) 组 · \(day.log.meals.count) 餐").bojiType(.caption).foregroundStyle(.secondary)
                            Image(systemName: "chevron.right").bojiType(.caption)
                        }.frame(minHeight: 44)
                    }.buttonStyle(ClubMotionButton())
                }
                if recordLimit < rows.count { Button("显示更多记录") { recordLimit += 20 }.buttonStyle(SecondaryButton()) }
            }
        }
    }

    @ViewBuilder private var diagnosticInsightCard: some View {
        let top = ClubInsightPriorityRules.top(in: store.state, date: reviewMonth)
        if let top {
            ClubCard {
                HStack {
                    Label("周期总结", systemImage: "sparkles")
                        .bojiType(.caption)
                        .foregroundStyle(BojiColor.brandAccent)
                    Spacer()
                }
                Text(top.title)
                    .bojiType(.secondary)
                    .foregroundStyle(BojiColor.textPrimary)
                Text(top.detail)
                    .bojiType(.label)
                    .foregroundStyle(BojiColor.textSecondary)
                    .lineLimit(2)
            }
            .sheet(isPresented: $showDiagnosticCoach) {
                ClubAIEntryBridge(question: "关于回顾周期诊断“\(top.title)”：\(top.detail)，我接下来的训练排期应如何优化？")
            }
        }
    }

}

private struct ReviewExerciseHistoryView: View {
    let exercise: ReviewExerciseAggregate
    let periodTitle: String
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: BojiLayout.cardInset) {
                    ClubCard {
                        Text(exercise.name).bojiFont(.pageTitle).foregroundStyle(BojiColor.textPrimary)
                        Text("\(exercise.muscle) · \(periodTitle)").bojiType(.secondary).foregroundStyle(.secondary)
                        HStack(spacing: BojiLayout.inline) {
                            Metric(title: "完成组数", value: "\(exercise.sets)", unit: "组")
                            Metric(title: "次数", value: "\(exercise.repetitions)", unit: "次")
                        }
                        HStack(spacing: BojiLayout.inline) {
                            Metric(title: "本期最高外加重量", value: exercise.bestWeight > 0 ? exercise.bestWeight.formatted(.number.precision(.fractionLength(0...1))) : "—", unit: exercise.bestWeight > 0 ? "kg" : "无记录")
                            Metric(title: "本期负重训练量", value: exercise.volume.formatted(.number.precision(.fractionLength(0...1))), unit: "kg·次")
                        }
                        if let estimate = exercise.estimatedOneRepMax {
                            Text("本期估算 1RM：\(estimate.formatted(.number.precision(.fractionLength(0...1)))) kg")
                                .bojiType(.secondary)
                        }
                        if exercise.personalRecords.bestWeight > 0 {
                            Text("历史最高重量：\(exercise.personalRecords.bestWeight.formatted(.number.precision(.fractionLength(0...1)))) kg · \(exercise.personalRecords.bestWeightDate.map { ClubDates.label($0, format: "yyyy年M月d日") } ?? "日期未知")")
                                .bojiType(.secondary)
                        }
                        if exercise.personalRecords.estimatedOneRepMax > 0 {
                            Text("历史最高估算 1RM：\(exercise.personalRecords.estimatedOneRepMax.formatted(.number.precision(.fractionLength(0...1)))) kg · \(exercise.personalRecords.estimatedOneRepMaxDate.map { ClubDates.label($0, format: "yyyy年M月d日") } ?? "日期未知")")
                                .bojiType(.secondary)
                        }
                    }
                    ClubCard {
                        SectionTitle(title: "训练历史", symbol: "clock.arrow.circlepath")
                        ForEach(exercise.history.sorted { $0.date > $1.date }) { entry in
                            VStack(alignment: .leading, spacing: BojiLayout.tight) {
                                Text(ClubDates.label(entry.date, format: "yyyy年M月d日"))
                                    .bojiType(.secondary)
                                Text("\(entry.sets) 组 · \(entry.repetitions) 次 · " + (entry.bestWeight > 0 ? "最高外加重量 \(entry.bestWeight.formatted(.number.precision(.fractionLength(0...1)))) kg" : "无已记录外加重量"))
                                    .bojiType(.caption).foregroundStyle(.secondary)
                                Text("负重训练量 \(entry.volume.formatted(.number.precision(.fractionLength(0...1)))) kg·次" + (entry.estimatedOneRepMax.map { " · 估算 1RM \($0.formatted(.number.precision(.fractionLength(0...1)))) kg" } ?? ""))
                                    .bojiType(.caption).foregroundStyle(.secondary)
                            }
                            if entry.id != exercise.history.sorted(by: { $0.date > $1.date }).last?.id { Divider() }
                        }
                        Text("只纳入已确认的真实完成组。重量训练量 = 额外负重 × 次数；未记录重量、自重与计时动作不混入。估算 1RM 是趋势参考，不代表实测最大重量。")
                            .bojiType(.label).foregroundStyle(.secondary)
                    }
                }.padding(ClubUI.pageInset)
            }
            .background { ClubBackground() }
            .navigationTitle("动作记录").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { DismissButton() } }
        }
    }
}

private struct ReviewDayDetailView: View {
    let day: ReviewDay
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var ai: AIService
    @Environment(\.dismiss) private var dismiss

    private var reportJobs: [AILocalJob] {
        ai.jobs.filter { $0.request.date == ClubDates.key(day.date) && $0.request.kind == "report" && !(store.state.deletedAIJobIDs ?? []).contains($0.id) }
    }
    private var completedReport: AILocalJob? { reportJobs.filter { $0.status == "succeeded" && $0.result != nil }.max { $0.created < $1.created } }
    private var pendingReport: AILocalJob? { reportJobs.filter { $0.status != "succeeded" && $0.created > (completedReport?.created ?? .distantPast) }.max { $0.created < $1.created } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: BojiLayout.cardInset) {
                    ClubCard {
                        SectionTitle(title: "训练记录", symbol: "dumbbell.fill")
                        if day.log.exercises.isEmpty {
                            EmptyNote(title: "当天没有训练计划", detail: "这一天可能是休息日，或尚未添加训练计划。")
                        } else {
                            Text(TrainingRecordText.summary(day.log).joined(separator:" · "))
                                .bojiFont(.setNumber, monospacedDigits: true)
                            ForEach(day.log.exercises) { exercise in
                                HStack {
                                    Text(exercise.displayName).bojiType(.secondary)
                                    Spacer()
                                    Text("\(exercise.sets.filter(\.validCompletion).count)/\(exercise.sets.count) 组")
                                        .bojiType(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    let sessions = ClubWorkoutSummaryRules.available(state: store.state, date: day.date)
                    if !sessions.isEmpty {
                        ClubCard {
                            Text("单次训练总结").bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
                            ForEach(Array(sessions.enumerated()), id: \.element) { index, sessionID in
                                NavigationLink("第 \(index + 1) 次训练 · 查看总结") {
                                    ClubWorkoutSummaryView(date: day.date, sessionID: sessionID)
                                }.buttonStyle(SecondaryButton())
                            }
                        }
                    }
                    ClubCard {
                        SectionTitle(title: "饮食记录", symbol: "fork.knife")
                        if day.log.meals.isEmpty {
                            EmptyNote(title: "当天没有饮食记录", detail: "记录缺失不代表当天没有进食。")
                        } else {
                            Text(day.log.knownMeals.isEmpty ? "营养数据未知" : "已知 \(day.log.calories.formatted(.number.precision(.fractionLength(0)))) kcal · 蛋白质 \(day.log.protein.formatted(.number.precision(.fractionLength(0...1)))) g")
                                .bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
                            if day.log.unknownNutritionMeals > 0 { Text("\(day.log.unknownNutritionMeals) 餐待补填营养数据，未计入汇总。").bojiType(.caption).foregroundStyle(.secondary) }
                            ForEach(day.log.meals) { meal in
                                HStack {
                                    Text(meal.name).bojiType(.secondary)
                                    Spacer()
                                    Text(meal.hasNutrition ? "\(meal.calories.formatted(.number.precision(.fractionLength(0)))) kcal" : "营养数据未知").bojiType(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    ClubCard {
                        SectionTitle(title: "健康与分析", symbol: "heart")
                        Text(day.log.health?.hasData == true ? "健康数据已同步到这一天。" : "这一天没有确认分享的健康数据。")
                            .bojiType(.caption).foregroundStyle(.secondary)
                        if let job = completedReport {
                            Divider()
                            Text("报告生成于 \(job.created.formatted(date: .abbreviated, time: .shortened))。它保留当时的分析，不会随补记自动重写。").bojiType(.caption).foregroundStyle(.secondary)
                            if let result = job.result, job.status == "succeeded" {
                                Text(result.summary ?? "").bojiType(.secondary).textSelection(.enabled)
                                ReportSectionText(title: "训练", text: result.training)
                                ReportSectionText(title: "饮食", text: result.nutrition)
                                ReportSectionText(title: "恢复与下一步", text: result.recovery)
                                ForEach(Array(result.notes.enumerated()), id: \.offset) { _, note in Text(note).bojiType(.caption).foregroundStyle(.secondary) }
                            } else { Text(job.error ?? "日报正在处理。").bojiType(.caption).foregroundStyle(.secondary) }
                        }
                        if let latest = pendingReport {
                            Text("另有一次生成：\(latest.error ?? (latest.isTerminal ? "未完成，可在下方日报入口重试" : "正在处理，旧版仍可阅读"))").bojiType(.caption).foregroundStyle(.secondary)
                            if !latest.isTerminal { AIJobStatusView(id: latest.id) }
                        }
                        if let job = completedReport {
                            NavigationLink("查看完整日报", destination: AIReportReaderView(jobID: job.id))
                                .buttonStyle(SecondaryButton())
                            ReportPreviousAnalysesLink(dateKey: ClubDates.key(day.date))
                        } else {
                            NavigationLink(pendingReport != nil ? "打开当日日报并重试" : "打开当日日报", destination: AIReportHistoryView(dateKey: ClubDates.key(day.date)))
                                .buttonStyle(SecondaryButton())
                        }
                    }
                }
                .padding(ClubUI.pageInset)
            }
            .background { ClubBackground() }
            .navigationTitle(ClubDates.label(day.date, format: "yyyy年M月d日"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}




// MARK: - 顶层核心指标卡片

struct BojiHeroMetricCard: View {
    let title: String
    let value: String
    let unit: String
    let subtitle: String
    let icon: String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: BojiLayout.tight) {
            HStack {
                Label(title, systemImage: icon)
                    .bojiType(.caption)
                    .foregroundStyle(BojiColor.textSecondary)
                Spacer()
            }
            HStack(alignment: .firstTextBaseline, spacing: BojiLayout.tight) {
                Text(value)
                    .bojiFont(.bodyMetric, monospacedDigits: true)
                    .foregroundStyle(BojiColor.textPrimary)
                Text(unit)
                    .bojiType(.secondary)
                    .foregroundStyle(BojiColor.textSecondary)
            }
            Text(subtitle)
                .bojiType(.caption)
                .foregroundStyle(BojiColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(BojiSpace.general)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BojiColor.subtleSurface, in: RoundedRectangle(cornerRadius: BojiRadius.inner, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: BojiRadius.inner, style: .continuous)
                .stroke(BojiColor.outline, lineWidth: 0.5)
        }
    }
}

#if DEBUG
enum ReviewAuditFactory {
 static func day(date: Date, log: DayLog) -> some View { ReviewDayDetailView(day: ReviewDay(date: date, log: log)) }
 static func exercise() -> some View { ReviewExerciseHistoryView(exercise: ReviewExerciseAggregate(id: "audit", name: "哑铃卧推", muscle: "胸", sets: 18, repetitions: 180, volume: 3600, bestWeight: 20), periodTitle: "本月") }
}
#endif
