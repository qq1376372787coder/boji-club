import SwiftUI
import Charts

/// Pure presentation math; no inferred training, recovery or calorie facts.
enum NativeData134 {
    static func energy(_ grams: Double, factor: Double) -> Double {
        grams.isFinite && grams > 0 ? grams * factor : 0
    }
    static func share(_ value: Double, total: Double) -> Double {
        guard value.isFinite, total.isFinite, value >= 0, total > 0 else { return 0 }
        return min(1, value / total)
    }
    static func frequency(trainingDays: Int, start: String, end: String) -> Double? {
        guard trainingDays >= 0, let first = ClubDates.date(fromKey: start), let last = ClubDates.date(fromKey: end), first <= last,
            let interval = ClubDates.calendar.dateComponents([.day], from: first, to: last).day else { return nil }
        let days = interval + 1
        guard days > 0, trainingDays <= days else { return nil }
        return Double(trainingDays) / Double(days)
    }
    static func colorIndex(_ name: String) -> Int {
        let familiar = ["背": 0, "肩": 1, "腿": 2, "手臂": 3, "胸": 4, "核心": 5]
        return familiar[name] ?? name.unicodeScalars.reduce(0) { ($0 + Int($1.value)) % 6 }
    }
    static func domain(_ values: [Double], target: Double?) -> ClosedRange<Double> {
        let valid = (values + [target].compactMap { $0 }).filter(\.isFinite)
        let low = valid.min() ?? 0, high = valid.max() ?? 1
        let padding = max(1, (high - low) * 0.18)
        return (low - padding)...(high + padding)
    }
}

/// Muted chart colours, separate from status/error colours and readable on both themes.
// lint-ignore: chart-palette（数据可视化色板，非 UI 表面色，不进 BojiColor）
enum DataPalette134 {
    static let blue = Color(red: 0.34, green: 0.52, blue: 0.71)  // lint-ignore: chart-palette（数据可视化色板）
    static let colors: [Color] = [blue, Color(red:0.57,green:0.49,blue:0.78),  // lint-ignore: chart-palette（数据可视化色板）
        Color(red:0.38,green:0.64,blue:0.57), Color(red:0.78,green:0.56,blue:0.36),  // lint-ignore: chart-palette（数据可视化色板）
        Color(red:0.74,green:0.46,blue:0.57), Color(red:0.46,green:0.60,blue:0.72)]  // lint-ignore: chart-palette（数据可视化色板）
    static func color(_ name: String) -> Color { colors[NativeData134.colorIndex(name)] }
    static let protein = BojiColor.macroProtein
    static let carbs = BojiColor.macroCarbs
    static let fat = BojiColor.macroFat
}

struct DataMetric134: View {
    let title: String
    let value: String
    let unit: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(alignment: .leading, spacing: BojiLayout.tight) {
            Text(title).bojiType(.caption).foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: BojiLayout.tight) { number; suffix }
                VStack(alignment: .leading, spacing: 0) { number; suffix }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
    }
    private var number: some View {
        Text(value).bojiType(.section).contentTransition(.numericText())
            .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: value)
    }
    private var suffix: some View { Text(unit).bojiType(.caption).foregroundStyle(.secondary) }
}

struct MusclePetal134: Identifiable, Equatable {
    var name: String
    var sets: Int
    var id: String { name }
}

/// Equal-angle petals: radial length represents completed sets, not area or recovery.
struct MuscleFlower134: View {
    let items: [MusclePetal134]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var selected: String?
    @State private var appeared = false
    private var positive: [MusclePetal134] { items.filter { $0.sets > 0 }.sorted { $0.name < $1.name } }
    private var total: Int { positive.reduce(0) { $0 + $1.sets } }
    private var active: MusclePetal134? { positive.first { $0.id == selected } }
    var body: some View {
        VStack(alignment: .leading, spacing: BojiLayout.cardInset) {
            if !typeSize.isAccessibilitySize && !positive.isEmpty {
                ZStack {
                    Chart(positive) { item in
                        SectorMark(
                            angle: .value("组数", item.sets),
                            innerRadius: .ratio(0.68),
                            angularInset: 2.5
                        )
                        .cornerRadius(6)
                        .foregroundStyle(DataPalette134.color(item.name).gradient)
                        .opacity(selected == nil || selected == item.id ? 1.0 : 0.35)
                    }
                    .chartLegend(.hidden)
                    .frame(height: 240)

                    VStack(spacing: BojiLayout.tight) {
                        Text(active?.name ?? "完成组数").bojiType(.caption).foregroundStyle(.secondary)
                        Text("\(active?.sets ?? total)").bojiType(.display)
                            .contentTransition(.numericText()).monospacedDigit()
                        Text("组").bojiType(.caption).foregroundStyle(.secondary)
                    }.allowsHitTesting(false)
                }
                .frame(maxWidth: .infinity).frame(height: 260)
                .scaleEffect(appeared ? 1 : 0.94).opacity(appeared ? 1 : 0)
                .accessibilityHidden(true)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 260 : 130))], alignment: .leading, spacing: BojiLayout.inline) {
                ForEach(positive) { item in
                    Button { select(item.id) } label: {
                        HStack(spacing: BojiLayout.inline) {
                            Circle().fill(DataPalette134.color(item.name)).frame(width: 8, height: 8) // lint-ignore: legend-dot（行命中区 44 由外层保证）
                            Text(item.name).bojiType(.secondary)
                            Spacer(minLength: 2)
                            Text("\(item.sets)组").bojiType(.secondary)
                        }.padding(.horizontal, BojiLayout.inline).frame(minHeight: 44)
                            .background(selected == item.id ? DataPalette134.color(item.name).opacity(0.13) : Color.clear, in: RoundedRectangle(cornerRadius: BojiRadius.control))
                    }.buttonStyle(.plain)
                        .accessibilityLabel("\(item.name)，完成\(item.sets)组，占\(Int((NativeData134.share(Double(item.sets), total: Double(total)) * 100).rounded()))%，点按查看")
                        .accessibilityAddTraits(selected == item.id ? .isSelected : [])
                }
            }
            if let active {
                Text("\(active.name) · \(active.sets) 组，占本期完成组数的 \(Int((NativeData134.share(Double(active.sets), total: Double(total)) * 100).rounded()))%")
                    .bojiType(.secondary).contentTransition(.opacity)
            }
            Text(typeSize.isAccessibilitySize ? "按动作的主要肌群统计完成组数。" : "花瓣长度表示完成组数；按动作的主要肌群分类。")
                .bojiType(.caption).foregroundStyle(.secondary)
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.4), value: items)
        .onAppear { withAnimation(reduceMotion ? nil : BojiMotion2.celebrate) { appeared = true } }
        .onChange(of: items) { _, _ in if !positive.contains(where: { $0.id == selected }) { selected = nil } }
    }
    private func select(_ id: String) {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { selected = selected == id ? nil : id }
        BojiHaptics.selection()
    }
}

struct RecordMilestone134: Identifiable {
    let id: String
    let date: Date
    let title: String
    let detail: String
}
struct RecordTimeline134: View {
    let events: [RecordMilestone134]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                HStack(alignment: .top, spacing: BojiLayout.rowGap) {
                    VStack(spacing: 0) {
                        Circle().fill(DataPalette134.blue).frame(width: 7, height: 7).padding(.top, BojiLayout.tight)
                        if index < events.count - 1 { Rectangle().fill(BojiColor.outline).frame(width: 1).frame(minHeight: 52) }
                    }.frame(width: 10)
                    Text(ClubDates.label(event.date, format: "M月d日")).bojiType(.caption).foregroundStyle(.secondary).frame(width: 50, alignment: .leading).padding(.top, BojiLayout.tight)
                    VStack(alignment: .leading, spacing: BojiLayout.tight) {
                        Text(event.title).bojiType(.secondary)
                        Text(event.detail).bojiType(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, BojiLayout.blockGap)
                }.accessibilityElement(children: .combine)
            }
        }
    }
}

/// Uses the card's confirmed snapshot only, never the latest local records or invented daily bars.
struct AITrainingDataCard134: View {
    let payload: AITrainingProgressPayload
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        VStack(alignment: .leading, spacing: BojiLayout.rowGap) {
            HStack(alignment: .top, spacing: BojiLayout.blockGap) {
                DataMetric134(title: "训练日", value: "\(payload.trainingDays)", unit: "天")
                DataMetric134(title: "实际完成", value: "\(payload.completedSets)", unit: "组")
            }
            if let frequency = NativeData134.frequency(trainingDays: payload.trainingDays, start: payload.windowStart, end: payload.windowEnd) {
                HStack(spacing: BojiLayout.rowGap) {
                    BojiRingGauge(progress: frequency, tint: DataPalette134.blue, lineWidth: 5) {
                        Text("\(Int((frequency * 100).rounded()))%").bojiType(.caption)
                    }.frame(width: 52, height: 52).accessibilityHidden(true)
                    Text("期间有训练的天数占 \(Int((frequency * 100).rounded()))%")
                        .bojiType(.secondary).foregroundStyle(.secondary)
                }
            }
            Text("\(payload.windowStart) 至 \(payload.windowEnd) · 仅计已确认训练")
                .bojiType(.caption).foregroundStyle(.secondary)
        }
    }
}
