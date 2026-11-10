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
    var body: some View {
        ClubCard(compact: values.count <= 1) {
            HStack {
                Button(action: openDetails) { Label("身体概览", systemImage: "heart.text.clipboard") }.buttonStyle(.plain).font(.headline)
                Spacer()
                Button { configuring = true } label: { Image(systemName: "slider.horizontal.3").frame(width: 44, height: 44) }.buttonStyle(.plain).accessibilityLabel("选择身体指标")
                Button(action: openDetails) { Image(systemName: "chevron.right").frame(width: 30, height: 44) }.buttonStyle(.plain).accessibilityLabel("查看身体详情")
            }
            if metrics.isEmpty {
                Button("选择要显示的身体指标") { configuring = true }.buttonStyle(SecondaryButton())
            } else if values.isEmpty {
                Text(health.enabled ? "暂无可读取数据，手动测量也可以记录。" : "连接 Apple 健康，查看活动、睡眠与身体测量。")
                    .font(.subheadline).foregroundStyle(.secondary)
                HStack { Button("查看与连接", action: openDetails).buttonStyle(SecondaryButton()); Button("手动记录", action: record).buttonStyle(SecondaryButton()) }
            } else if values.count == 1, let first = values.first {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(first.0.title + " " + first.1.value.formatted(.number.precision(.fractionLength(first.0.decimals))) + " " + first.0.unit).font(.headline)
                        Text(ClubDates.label(first.1.date, format: "M月d日") + " · " + first.1.source).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("＋记录", action: record).font(.subheadline).frame(minHeight: 44)
                }
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 14) {
                    ForEach(values, id: \.0.id) { kind, value in
                        let history = BodyOverviewData.history(kind, through: date, store: store, health: health)
                        Button(action: openDetails) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(kind == .sleep && BodyOverviewData.day(date, store: store, health: health)?.nightSleep != nil ? "主要睡眠 · 醒来日" : kind.title).font(.caption).foregroundStyle(.secondary)
                                Text(value.value.formatted(.number.precision(.fractionLength(kind.decimals))) + " " + kind.unit).font(.headline).monospacedDigit()
                                if history.count >= 2 {
                                    BojiSparkline(points: history, tint: BojiColor.mistAccent)
                                        .frame(height: 22)
                                    Text("较上次 " + (history[history.count - 1] - history[history.count - 2]).formatted(.number.sign(strategy: .always()).precision(.fractionLength(kind.decimals))))
                                        .font(.caption2).foregroundStyle(BojiColor.textSecondary)
                                }
                                if [.weight, .fat, .waist].contains(kind) { Text(ClubDates.label(value.date, format: "M月d日") + " · " + value.source).font(.caption2).foregroundStyle(.secondary) }
                            }.frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                        }.buttonStyle(.plain)
                    }
                }
                HStack {
                    if let summary = BodyOverviewData.day(date, store: store, health: health) { Text("更新于 " + summary.updatedAt.formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundStyle(.secondary) }
                    Spacer()
                    Button("＋记录测量", action: record).font(.caption.weight(.semibold)).frame(minHeight: 44)
                }
            }
            if let message = health.message { Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
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
                    Text("仅展示有记录的指标，保留原始测量来源与日期。")
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
    @State private var metric: BodyOverviewMetric = .weight
    @State private var range = 30
    @State private var customStart = ClubDates.calendar.date(byAdding: .day, value: -29, to: Date()) ?? Date()
    @State private var connections = false
    @State private var weightRecords = false
    @State private var editor: OverviewWeightRequest?
    @State private var readingRange = false
    @State private var readingTask: Task<Void, Never>?
    private var dates: [Date] {
        let end = ClubDates.calendar.startOfDay(for: date)
        let count = range == 0 ? min(365, max(1, (ClubDates.calendar.dateComponents([.day], from: customStart, to: end).day ?? 0) + 1)) : range
        return (0..<count).reversed().compactMap { ClubDates.calendar.date(byAdding: .day, value: -$0, to: end) }
    }
    private var series: [(Date, Double)] {
        dates.compactMap { day in
            guard let value = BodyOverviewData.value(metric, on: day, store: store, health: health) else { return nil }
            // Never fill unmeasured dates with the previous body measurement.
            guard ![.weight, .fat, .waist].contains(metric) || ClubDates.key(value.date) == ClubDates.key(day) else { return nil }
            return (day, value.value)
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
            VStack(alignment: .leading, spacing: 18) {
                DatePicker("查看日期", selection: $date, in: ...Date(), displayedComponents: .date).datePickerStyle(.compact).dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                BodyOverviewCard(date: date, openDetails: { connections = true }, record: { editor = OverviewWeightRequest(date: date) })
                ClubCard {
                    Text("变化趋势").bojiFont(.cardTitle)
                    Picker("指标", selection: $metric) { ForEach(BodyOverviewMetric.allCases) { Text($0.title).tag($0) } }.pickerStyle(.menu)
                    Picker("时间范围", selection: $range) { Text("7天").tag(7); Text("30天").tag(30); Text("90天").tag(90); Text("自定").tag(0) }.clubAdaptivePicker()
                    if range == 0 { DatePicker("开始日期", selection: $customStart, in: ...date, displayedComponents: .date).datePickerStyle(.compact).dynamicTypeSize(...DynamicTypeSize.xxxLarge) }
                    if series.isEmpty { EmptyNote(title: "这段时间暂无记录", detail: "可从 Apple 健康读取历史数据，或手动补记测量。") }
                    else {
                        BojiLineTrendChart(points: series.map { BojiTrendPoint(date: $0.0, value: $0.1) },
                            target: metric == .weight ? store.state.profile.targetWeightKg : nil,
                            unit: metric.unit, height: 190)
                            .id(metric)
                            .chartYAxisLabel(metric.unit)
                        Text("\(series.count) 天有记录 · \(metric.unit)").font(.caption).foregroundStyle(.secondary)
                    }
                    if health.enabled {
                        Button(readingRange ? "停止读取历史数据" : "读取这段时间的健康数据") {
                            if readingRange { readingTask?.cancel(); readingRange = false }
                            else {
                                readingRange = true
                                let selected = dates
                                readingTask = Task {
                                    for day in selected { if Task.isCancelled { break }; await health.refresh(day) }
                                    readingRange = false
                                }
                            }
                        }.buttonStyle(SecondaryButton())
                    }
                    Text(metric == .sleep ? "主要睡眠按醒来日期归属；未刷新旧记录可能仍是当天睡眠汇总。" : "只展示实际记录；短期变化不能单独说明体脂或训练效果。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let day = BodyOverviewData.day(date, store: store, health: health), day.nightSleep != nil {
                    ClubCard {
                        Text("睡眠时段").bojiFont(.cardTitle)
                        if let start = day.nightSleepStart, let end = day.nightSleepEnd { Text(start.formatted(date: .abbreviated, time: .shortened) + " — " + end.formatted(date: .abbreviated, time: .shortened)) }
                        if let nap = day.napSleep { Text("其他睡眠：" + nap.value.formatted(.number.precision(.fractionLength(1))) + " 小时") }
                        Text("以醒来日查看最长一段睡眠；按实际睡眠区间计时，夜间清醒间隔不会计入。来源：" + (day.nightSleep?.source.name ?? ""))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button("测量记录与体重曲线") { weightRecords = true }.buttonStyle(SecondaryButton())
                Button("设备、数据来源与分享设置") { connections = true }.buttonStyle(SecondaryButton())
                Text("本机读取的数据经你确认后才会用于 AI 分析。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(BojiSpace.pageInset)
        }.background { ClubBackground() }.navigationTitle("身体概览").navigationBarTitleDisplayMode(.inline)
            .onChange(of: date) { _, value in
                if customStart > value { customStart = value }
                readingTask?.cancel(); readingRange = false
            }
            .onChange(of: range) { _, _ in readingTask?.cancel(); readingRange = false }
            .sheet(isPresented: $connections) { HealthConnectionsView(date: date) }
            .sheet(isPresented: $weightRecords) { BodyWeightView(initialDate: date) }
            .sheet(item: $editor) { WeightEntryEditor(date: $0.date) }
    }
}
