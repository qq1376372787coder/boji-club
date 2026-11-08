import SwiftUI
import Charts

private struct OverviewWeightRequest: Identifiable { let id = UUID(); let date: Date }

private enum BodyOverviewMetric: String, CaseIterable, Identifiable {
    case sleep, resting, steps, energy, weight, fat, waist
    var id: String { rawValue }
    var title: String {
        switch self { case .sleep: return "睡眠"; case .resting: return "静息心率"; case .steps: return "步数"; case .energy: return "活动能量"; case .weight: return "体重"; case .fat: return "体脂率"; case .waist: return "腰围" }
    }
    var unit: String {
        switch self { case .sleep: return "小时"; case .resting: return "次/分"; case .steps: return "步"; case .energy: return "kcal"; case .weight: return "kg"; case .fat: return "%"; case .waist: return "cm" }
    }
    var decimals: Int { [.steps, .energy, .resting].contains(self) ? 0 : 1 }
}
private struct OverviewValue {
    let value: Double
    let date: Date
    let source: String
}
@MainActor private enum BodyOverviewData {
    static func day(_ date: Date, store: AppStore, health: HealthDataService) -> HealthDay? { health.summary(for: date) ?? store.log(for: date).health }
    static func value(_ kind: BodyOverviewMetric, on date: Date, store: AppStore, health: HealthDataService) -> OverviewValue? {
        let key = ClubDates.key(date)
        if [.weight, .fat, .waist].contains(kind) {
            var values: [OverviewValue] = []
            for (dayKey, day) in store.state.days where dayKey <= key {
                guard let entry = day.bodyWeight, let fallbackDate = ClubDates.date(fromKey: dayKey) else { continue }
                let number = kind == .weight ? entry.kilograms : kind == .fat ? entry.bodyFatPercentage : entry.waistCircumferenceCM
                if let number { values.append(OverviewValue(value: number, date: entry.recordedAt ?? fallbackDate, source: "手动测量")) }
            }
            let known = store.state.days.values.compactMap(\.health) + Array(health.days.values)
            for summary in known {
                let dayKey = summary.date
                let metric = kind == .weight ? (summary.bodyMass ?? summary.recentBodyMass) : kind == .fat ? (summary.bodyFatPercentage ?? summary.recentBodyFatPercentage) : (summary.waistCircumference ?? summary.recentWaistCircumference)
                if let metric, let fallbackDate = ClubDates.date(fromKey: dayKey) {
                    values.append(OverviewValue(value: metric.value, date: metric.recordedAt ?? fallbackDate, source: metric.source.name))
                }
            }
            return values.filter { ClubDates.key($0.date) <= key }.sorted {
                if $0.date != $1.date { return $0.date > $1.date }
                if $0.source != $1.source { return $0.source == "手动测量" || ($1.source != "手动测量" && $0.source < $1.source) }
                return $0.value > $1.value
            }.first
        }
        guard let summary = day(date, store: store, health: health) else { return nil }
        let metric: HealthMetric?
        switch kind { case .sleep: metric = summary.nightSleep ?? summary.sleep; case .resting: metric = summary.restingHeartRate; case .steps: metric = summary.steps; case .energy: metric = summary.activeEnergy; default: metric = nil }
        return metric.map { OverviewValue(value: $0.value, date: $0.recordedAt ?? date, source: $0.source.name) }
    }
    static func history(_ kind: BodyOverviewMetric, through date: Date, store: AppStore, health: HealthDataService, limit: Int = 7) -> [Double] {
        let cutoff = ClubDates.key(date)
        let keys = Set(store.state.days.keys).union(health.days.keys).filter { $0 <= cutoff }.sorted()
        var seen = Set<Date>()
        let samples = keys.compactMap { key -> OverviewValue? in
            guard let day = ClubDates.date(fromKey: key), let sample = value(kind, on: day, store: store, health: health),
                  ClubDates.key(sample.date) <= cutoff, seen.insert(sample.date).inserted else { return nil }
            return sample
        }.sorted { $0.date < $1.date }
        return samples.suffix(limit).map(\.value)
    }

}

struct BodyOverviewCard: View {
    let date: Date
    let openDetails: () -> Void
    let record: () -> Void
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var health: HealthDataService
    @Environment(\.scenePhase) private var phase
    @State private var metrics: [BodyOverviewMetric] = [.sleep, .resting, .steps, .weight]
    @State private var configuring = false
    private var values: [(BodyOverviewMetric, OverviewValue)] { metrics.compactMap { kind in BodyOverviewData.value(kind, on: date, store: store, health: health).map { (kind, $0) } } }
    private var preferenceKey: String { "body-overview.metrics.\(store.editingAccountID ?? 0)" }
    private func metricIcon(_ kind: BodyOverviewMetric) -> String {
        switch kind {
        case .sleep: return "bed.double.fill"
        case .resting: return "heart.fill"
        case .steps: return "figure.walk"
        case .weight: return "scalemass.fill"
        case .fat: return "percent"
        case .waist: return "ruler.fill"
        case .energy: return "flame.fill"
        }
    }

    var body: some View {
        ClubCard(compact: values.count <= 1) {
            HStack {
                Text("身体概览")
                    .bojiType(.section)
                    .foregroundStyle(BojiColor.textPrimary)
                Spacer()
                Button { configuring = true } label: {
                    Image(systemName: "slider.horizontal.3")
                        .bojiType(.secondary)
                        .foregroundStyle(BojiColor.textSecondary)
                        .padding(BojiLayout.tight)
                        .background(BojiColor.inputSurface, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("选择身体指标")

                Button(action: record) {
                    HStack(spacing: BojiLayout.tight) {
                        Image(systemName: "plus")
                        Text("测量")
                    }
                    .bojiType(.caption)
                    .foregroundStyle(BojiColor.textPrimary)
                    .padding(.horizontal, BojiLayout.inline).padding(.vertical, BojiLayout.tight)
                    .background(BojiColor.inputSurface, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            if metrics.isEmpty {
                Button("选择要显示的身体指标") { configuring = true }.buttonStyle(SecondaryButton())
            } else if values.isEmpty {
                Text(health.enabled ? "还没有数据。可手动记录。" : "连接 Apple 健康，查看活动、睡眠与身体测量。")
                    .bojiType(.secondary).foregroundStyle(.secondary)
                HStack { Button("查看与连接", action: openDetails).buttonStyle(SecondaryButton()); Button("手动记录", action: record).buttonStyle(SecondaryButton()) }
            } else if values.count == 1, let first = values.first {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: BojiLayout.tight) {
                        Text(first.0.title + " " + first.1.value.formatted(.number.precision(.fractionLength(first.0.decimals))) + " " + first.0.unit).bojiType(.bodyStrong)
                        Text(ClubDates.label(first.1.date, format: "M月d日") + " · " + first.1.source).bojiType(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("＋记录", action: record).bojiType(.secondary).frame(minHeight: 44)
                }
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: BojiLayout.inline), GridItem(.flexible(), spacing: BojiLayout.inline)], spacing: BojiLayout.inline) {
                    ForEach(values, id: \.0.id) { kind, value in
                        let history = BodyOverviewData.history(kind, through: date, store: store, health: health)
                        Button(action: openDetails) {
                            VStack(alignment: .leading, spacing: BojiLayout.tight) {
                                HStack(spacing: BojiLayout.tight) {
                                    Image(systemName: metricIcon(kind))
                                        .bojiType(.caption)
                                        .foregroundStyle(kind == .resting ? BojiColor.macroProtein : (kind == .sleep ? BojiColor.macroFat : BojiColor.mistAccent))
                                    Text(kind == .sleep && BodyOverviewData.day(date, store: store, health: health)?.nightSleep != nil ? "主要睡眠" : kind.title)
                                        .bojiType(.caption)
                                        .foregroundStyle(BojiColor.textSecondary)
                                    Spacer(minLength: 0)
                                }
                                HStack(alignment: .firstTextBaseline, spacing: 0) {
                                    Text(value.value.formatted(.number.precision(.fractionLength(kind.decimals))))
                                        .bojiType(.section)
                                        .foregroundStyle(BojiColor.textPrimary)
                                    Text(kind.unit)
                                        .bojiType(.caption)
                                        .foregroundStyle(BojiColor.textTertiary)
                                }
                                if history.count >= 2 {
                                    let diff = history[history.count - 1] - history[history.count - 2]
                                    HStack(spacing: BojiLayout.tight) {
                                        Image(systemName: diff >= 0 ? "arrow.up.right" : "arrow.down.right")
                                            .bojiType(.caption)
                                        Text(diff.formatted(.number.sign(strategy: .always()).precision(.fractionLength(kind.decimals))))
                                            .bojiType(.caption)
                                    }
                                    .foregroundStyle(diff == 0 ? BojiColor.textTertiary : BojiColor.textSecondary)
                                }
                                Text(ClubDates.label(value.date, format: "M月d日") + " · " + value.source)
                                    .bojiType(.caption).foregroundStyle(BojiColor.textTertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
                            .padding(BojiLayout.inline)
                            .background(BojiColor.inputSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                if let summary = BodyOverviewData.day(date, store: store, health: health) {
                    Text("数据更新于 " + summary.updatedAt.formatted(date: .omitted, time: .shortened))
                        .bojiType(.caption)
                        .foregroundStyle(BojiColor.textTertiary)
                }
            }
            if let message = health.message { Text(message).bojiType(.caption).foregroundStyle(.secondary).lineLimit(2) }
        }
        .task(id: "\(store.editingAccountID ?? 0)-\(ClubDates.key(date))-\(phase == .active)") {
            metrics = UserDefaults.standard.stringArray(forKey: preferenceKey)?.compactMap(BodyOverviewMetric.init(rawValue:)) ?? [.sleep, .resting, .steps, .weight]
            if phase == .active { await health.refresh(date) }
        }
        .sheet(isPresented: $configuring) {
            NavigationStack {
                Form {
                    Section("身体概览显示的指标") {
                        ForEach(BodyOverviewMetric.allCases) { kind in
                            Toggle(kind.title, isOn: Binding(get: { metrics.contains(kind) }, set: { enabled in
                                if enabled { metrics.append(kind) } else { metrics.removeAll { $0 == kind } }
                                UserDefaults.standard.set(metrics.map(\.rawValue), forKey: preferenceKey)
                            }))
                        }
                    }
                    Text("只显示有记录的指标，保留来源与日期。")
                }.navigationTitle("身体概览指标").toolbar { ToolbarItem(placement: .confirmationAction) { DismissButton() } }
            }
        }
    }
}

struct BodyOverviewView: View {
    var embedded = false
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var health: HealthDataService
    @State private var date = Date()
    @State private var weightRange = 30
    @State private var activityRange = 7
    @State private var connections = false
    @State private var weightRecords = false
    @State private var editor: OverviewWeightRequest?
    @State private var readingRange = false
    @State private var readingTask: Task<Void, Never>?

    private func metricSeries(_ kind: BodyOverviewMetric, daysCount: Int = 30) -> [BojiTrendPoint] {
        let end = ClubDates.calendar.startOfDay(for: date)
        let datesList = (0..<daysCount).reversed().compactMap { ClubDates.calendar.date(byAdding: .day, value: -$0, to: end) }
        return datesList.compactMap { day in
            guard let value = BodyOverviewData.value(kind, on: day, store: store, health: health) else { return nil }
            guard ![.weight, .fat, .waist].contains(kind) || ClubDates.key(value.date) == ClubDates.key(day) else { return nil }
            return BojiTrendPoint(date: day, value: value.value)
        }
    }

    var body: some View {
        Group {
            if embedded { content }
            else { NavigationStack { content.toolbar { ToolbarItem(placement: .cancellationAction) { DismissButton() } } } }
        }
        .onDisappear { readingTask?.cancel() }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BojiLayout.cardInset) {
                // Top Date Bar
                HStack {
                    Button {
                        if let prev = ClubDates.calendar.date(byAdding: .day, value: -1, to: date) { date = prev }
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(ClubIconButtonStyle())
                    .accessibilityLabel("前一天")

                    DatePicker("查看日期", selection: $date, in: ...Date(), displayedComponents: .date)
                        .labelsHidden()
                        .frame(maxWidth: .infinity)

                    Button {
                        if let next = ClubDates.calendar.date(byAdding: .day, value: 1, to: date), next <= Date() { date = next }
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .buttonStyle(ClubIconButtonStyle())
                    .disabled(ClubDates.calendar.isDateInToday(date))
                    .accessibilityLabel("后一天")

                    Button("今天") { date = Date() }
                        .bojiType(.secondary)
                        .buttonStyle(ClubMotionButton())
                }

                BodyOverviewCard(date: date, openDetails: { connections = true }, record: { editor = OverviewWeightRequest(date: date) })

                // Card 1: 身材与体重趋势
                bodyWeightCard

                // Card 2: 日常活动与步数
                activityCard

                // Card 3: 睡眠与体能恢复
                recoveryCard

                if health.enabled {
                    HStack {
                        Button(readingRange ? "正在同步…" : "同步近期健康数据") {
                            if readingRange { readingTask?.cancel(); readingRange = false }
                            else {
                                readingRange = true
                                let end = ClubDates.calendar.startOfDay(for: date)
                                let selected = (0..<30).reversed().compactMap { ClubDates.calendar.date(byAdding: .day, value: -$0, to: end) }
                                readingTask = Task {
                                    for day in selected { if Task.isCancelled { break }; await health.refresh(day) }
                                    readingRange = false
                                }
                            }
                        }
                        .bojiType(.caption)
                        .foregroundStyle(BojiColor.brandAccent)
                        Spacer()
                    }
                    .padding(.horizontal, BojiLayout.tight)
                }

                HStack(spacing: BojiLayout.inline) {
                    Button { weightRecords = true } label: {
                        HStack(spacing: BojiLayout.tight) {
                            Image(systemName: "chart.xyaxis.line")
                                .bojiType(.secondary)
                            Text("历史测量与曲线")
                                .bojiType(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundStyle(BojiColor.textPrimary)
                        .background(BojiColor.inputSurface, in: RoundedRectangle(cornerRadius: BojiRadius.control, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    Button { connections = true } label: {
                        HStack(spacing: BojiLayout.tight) {
                            Image(systemName: "heart.text.clipboard")
                                .bojiType(.secondary)
                            Text("健康数据权限")
                                .bojiType(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundStyle(BojiColor.textPrimary)
                        .background(BojiColor.inputSurface, in: RoundedRectangle(cornerRadius: BojiRadius.control, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(ClubUI.pageInset)
        }
        .background { ClubBackground() }
        .sheet(item: $editor) { req in
            WeightEntryEditor(date: req.date)
        }
        .sheet(isPresented: $connections) {
            HealthConnectionsView(date: Date())
        }
        .sheet(isPresented: $weightRecords) {
            BodyWeightView()
        }
    }

    private var bodyWeightCard: some View {
        ClubCard {
            VStack(alignment: .leading, spacing: BojiLayout.rowGap) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("身材与体重趋势")
                            .bojiType(.bodyStrong)
                            .foregroundStyle(BojiColor.textPrimary)
                        if let current = BodyOverviewData.value(.weight, on: date, store: store, health: health) {
                            HStack(alignment: .firstTextBaseline, spacing: BojiLayout.tight) {
                                Text(current.value.formatted(.number.precision(.fractionLength(1))))
                                    .bojiType(.title)
                                    .foregroundStyle(BojiColor.textPrimary)
                                Text("kg")
                                    .bojiType(.secondary)
                                    .foregroundStyle(BojiColor.textSecondary)
                                if let target = store.state.profile.targetWeightKg {
                                    let diff = current.value - target
                                    Text("距目标 \(diff >= 0 ? "+" : "")\(diff.formatted(.number.precision(.fractionLength(1)))) kg")
                                        .bojiType(.caption)
                                        .foregroundStyle(diff > 0 ? BojiColor.brandAccent : BojiColor.macroProtein)
                                        .padding(.leading, BojiLayout.tight)
                                }
                            }
                        } else {
                            Text("当天没有测量")
                                .bojiType(.secondary)
                                .foregroundStyle(BojiColor.textSecondary)
                        }
                    }
                    Spacer()
                    Picker("时间范围", selection: $weightRange) {
                        Text("7天").tag(7)
                        Text("30天").tag(30)
                        Text("90天").tag(90)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 150)
                }

                let points = metricSeries(.weight, daysCount: weightRange)
                if points.isEmpty {
                    EmptyNote(title: "近 \(weightRange) 天没有体重记录", detail: "可从 Apple 健康读取历史数据，或点击记录。")
                } else {
                    BojiLineTrendChart(
                        points: points,
                        target: store.state.profile.targetWeightKg,
                        unit: "kg",
                        tint: BojiColor.brandAccent,
                        height: 160,
                        show7DayAverage: true
                    )
                }

                // Sub-metrics: Body Fat % & Waist CM
                HStack(spacing: BojiLayout.rowGap) {
                    subMetricBadge(title: "体脂率", kind: .fat)
                    subMetricBadge(title: "腰围", kind: .waist)
                    Spacer()
                    Button {
                        editor = OverviewWeightRequest(date: date)
                    } label: {
                        Label("记录测量", systemImage: "plus")
                            .bojiType(.caption)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                }
            }
        }
    }

    private var activityCard: some View {
        ClubCard {
            VStack(alignment: .leading, spacing: BojiLayout.rowGap) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("日常活动与步数")
                            .bojiType(.bodyStrong)
                            .foregroundStyle(BojiColor.textPrimary)
                        if let steps = BodyOverviewData.value(.steps, on: date, store: store, health: health) {
                            HStack(alignment: .firstTextBaseline, spacing: BojiLayout.tight) {
                                Text("\(Int(steps.value))")
                                    .bojiType(.title)
                                    .foregroundStyle(BojiColor.textPrimary)
                                Text("步")
                                    .bojiType(.secondary)
                                    .foregroundStyle(BojiColor.textSecondary)
                                if let energy = BodyOverviewData.value(.energy, on: date, store: store, health: health) {
                                    Text("· \(Int(energy.value)) kcal")
                                        .bojiType(.caption)
                                        .foregroundStyle(BojiColor.macroCarbs)
                                        .padding(.leading, BojiLayout.tight)
                                }
                            }
                        } else {
                            Text("步数还没同步到")
                                .bojiType(.secondary)
                                .foregroundStyle(BojiColor.textSecondary)
                        }
                    }
                    Spacer()
                    Picker("时间", selection: $activityRange) {
                        Text("7天").tag(7)
                        Text("14天").tag(14)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 110)
                }

                let points = metricSeries(.steps, daysCount: activityRange)
                if points.isEmpty {
                    EmptyNote(title: "暂无步数记录", detail: "授权 Apple 健康后可自动读取每日步数与活动能量。")
                } else {
                    BojiLineTrendChart(
                        points: points,
                        unit: "步",
                        tint: BojiColor.macroCarbs,
                        height: 130
                    )
                }
            }
        }
    }

    private var recoveryCard: some View {
        ClubCard {
            VStack(alignment: .leading, spacing: BojiLayout.rowGap) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("睡眠与体能恢复")
                            .bojiType(.bodyStrong)
                            .foregroundStyle(BojiColor.textPrimary)
                        if let sleep = BodyOverviewData.value(.sleep, on: date, store: store, health: health) {
                            HStack(alignment: .firstTextBaseline, spacing: BojiLayout.tight) {
                                Text(sleep.value.formatted(.number.precision(.fractionLength(1))))
                                    .bojiType(.title)
                                    .foregroundStyle(BojiColor.textPrimary)
                                Text("小时")
                                    .bojiType(.secondary)
                                    .foregroundStyle(BojiColor.textSecondary)
                                if let resting = BodyOverviewData.value(.resting, on: date, store: store, health: health) {
                                    Text("· 静息 \(Int(resting.value)) 次/分")
                                        .bojiType(.caption)
                                        .foregroundStyle(BojiColor.macroFat)
                                        .padding(.leading, BojiLayout.tight)
                                }
                            }
                        } else {
                            Text("睡眠还没同步到")
                                .bojiType(.secondary)
                                .foregroundStyle(BojiColor.textSecondary)
                        }
                    }
                    Spacer()
                }

                let points = metricSeries(.sleep, daysCount: 7)
                if points.isEmpty {
                    EmptyNote(title: "暂无睡眠数据", detail: "可佩戴 Apple Watch 或同步健康睡眠分析。")
                } else {
                    BojiLineTrendChart(
                        points: points,
                        unit: "小时",
                        tint: BojiColor.macroFat,
                        height: 120
                    )
                }
            }
        }
    }

    private func subMetricBadge(title: String, kind: BodyOverviewMetric) -> some View {
        HStack(spacing: BojiLayout.tight) {
            Text(title + ":")
                .bojiType(.caption)
                .foregroundStyle(BojiColor.textTertiary)
            if let val = BodyOverviewData.value(kind, on: date, store: store, health: health) {
                Text("\(val.value.formatted(.number.precision(.fractionLength(kind.decimals)))) \(kind.unit)")
                    .bojiType(.caption)
                    .foregroundStyle(BojiColor.textPrimary)
            } else {
                Text("--")
                    .bojiType(.caption)
                    .foregroundStyle(BojiColor.textTertiary)
            }
        }
        .padding(.horizontal, BojiLayout.inline)
        .padding(.vertical, BojiLayout.tight)
        .background(BojiColor.inputSurface, in: RoundedRectangle(cornerRadius: BojiRadius.badge, style: .continuous))
    }
}
