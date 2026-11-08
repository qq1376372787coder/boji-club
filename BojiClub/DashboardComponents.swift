import SwiftUI
import Charts

// MARK: - 记录看板组件库
// 三个记录页（训练/饮食/身体）共用的看板组件。数据主色一律用 BojiColor.mistAccent，
// 语义色只表状态（达标 emerald / 超标 red）；尊重 reduceMotion 与动态字体。

// MARK: - KPI 胶囊

/// 顶部指标行用：标签 + 大数字 + 环比箭头（可选）+ 迷你走势（可选）。
struct BojiKpiCapsule: View {
    let title: String
    let value: String
    var unit: String = ""
    /// 环比值（如 -0.4）。nil 不显示箭头。
    var delta: Double? = nil
    /// 下降为好的指标（如体重）传 true，箭头颜色语义反转。
    var downIsGood: Bool = false
    var deltaSuffix: String = ""
    var spark: [Double] = []
    var tint: Color = BojiColor.mistAccent

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var deltaColor: Color? {
        guard let delta else { return nil }
        if delta == 0 { return BojiColor.textTertiary }
        return BojiColor.textSecondary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BojiLayout.tight) {
            Text(title).bojiType(.caption).foregroundStyle(BojiColor.textSecondary)
                .lineLimit(1).minimumScaleFactor(0.8)
            HStack(alignment: .firstTextBaseline, spacing: BojiLayout.tight) {
                Text(value)
                    .bojiType(.section)
                    .contentTransition(.numericText())
                if !unit.isEmpty {
                    Text(unit).bojiType(.caption).foregroundStyle(BojiColor.textSecondary)
                }
            }
            HStack(spacing: BojiLayout.tight) {
                if let delta, let color = deltaColor {
                    HStack(spacing: 0) {
                        Image(systemName: delta > 0 ? "arrow.up.right" : delta < 0 ? "arrow.down.right" : "arrow.right")
                            .bojiType(.caption)
                        Text((delta > 0 ? "+" : "") + delta.formatted(.number.precision(.fractionLength(0...1))) + deltaSuffix)
                            .bojiType(.caption)
                    }
                    .foregroundStyle(color)
                }
                Spacer(minLength: 0)
                if !spark.isEmpty {
                    BojiSparkline(points: spark, tint: tint)
                        .frame(width: 44, height: 16)
                }
            }
            .frame(minHeight: 12)
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: value)
        .padding(.horizontal, BojiLayout.rowGap).padding(.vertical, BojiLayout.inline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BojiColor.cardSurface, in: RoundedRectangle(cornerRadius: BojiRadius.inner, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: BojiRadius.inner, style: .continuous).stroke(BojiColor.outline, lineWidth: 0.5) }
    }
}

// MARK: - 迷你走势（Apple Swift Charts 原生实现）

/// 无坐标轴微缩折线（KPI 胶囊、指标格用），采用原生 LineMark + AreaMark。
struct BojiSparkline: View {
    var points: [Double]
    var tint: Color = BojiColor.mistAccent
    var filled: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct SparkPoint: Identifiable {
        let id: Int
        let value: Double
    }

    private var sparkPoints: [SparkPoint] {
        points.enumerated().map { SparkPoint(id: $0.offset, value: $0.element) }
    }

    var body: some View {
        Group {
            if points.count >= 2 {
                Chart(sparkPoints) { pt in
                    if filled {
                        AreaMark(
                            x: .value("Index", pt.id),
                            y: .value("Value", pt.value)
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [tint.opacity(0.24), tint.opacity(0.02)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .interpolationMethod(.monotone)
                    }
                    LineMark(
                        x: .value("Index", pt.id),
                        y: .value("Value", pt.value)
                    )
                    .foregroundStyle(tint)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartLegend(.hidden)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - 目标圆环（Apple iOS 原生 Gauge 实现）

/// 目标完成环：采用 Apple iOS 原生 Gauge 渲染，支持无障碍感知与系统级动效。
struct BojiRingGauge<Center: View>: View {
    var progress: Double
    var tint: Color = BojiColor.mistAccent
    var lineWidth: CGFloat = 12
    @ViewBuilder var center: () -> Center

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Gauge(value: min(1, max(0, progress)), in: 0...1) {
                Text("完成度")
            } currentValueLabel: {
                EmptyView()
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(tint)

            center()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("完成度 \(Int(min(progress, 9.99) * 100))%")
    }
}

// MARK: - 宏量甜甜圈

/// 蛋白/碳水/脂肪 SectorMark 甜甜圈；中心可叠加热量完成环（calorieProgress 0...1）。
struct BojiMacroDonut: View {
    var protein: Double
    var carbs: Double
    var fat: Double
    var calorieProgress: Double? = nil
    var centerTitle: String = ""
    var centerValue: String = ""
    var size: CGFloat = 172
    struct Slice: Identifiable {
        var id: String { name }
        let name: String
        let grams: Double
        let factor: Double
        let color: Color
        var energy: Double { NativeData134.energy(grams, factor: factor) }
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var selection: Double?
    private var slices: [Slice] { [
        Slice(name: "蛋白质", grams: protein, factor: 4, color: DataPalette134.protein),
        Slice(name: "碳水", grams: carbs, factor: 4, color: DataPalette134.carbs),
        Slice(name: "脂肪", grams: fat, factor: 9, color: DataPalette134.fat)] }
    private var selected: Slice? {
        guard let selection else { return nil }
        var cumulative = 0.0
        for slice in slices { cumulative += slice.energy; if selection < cumulative { return slice } }
        return nil
    }
    var body: some View {
        let total = slices.reduce(0) { $0 + $1.energy }
        ZStack {
            Circle().stroke(BojiColor.brandMist, lineWidth: size * 0.14).padding(size * 0.07)
            Chart(slices) { slice in
                SectorMark(angle: .value(slice.name, slice.energy), innerRadius: .ratio(0.72), angularInset: 3)
                    .foregroundStyle(slice.color.gradient).cornerRadius(5)
                    .opacity(selected == nil || selected?.id == slice.id ? 1 : 0.3)
                    .accessibilityLabel(slice.name)
                    .accessibilityValue("\(slice.grams.formatted(.number.precision(.fractionLength(0...1))))克，供能占比\(Int((NativeData134.share(slice.energy, total: total) * 100).rounded()))%")
            }.chartLegend(.hidden).chartAngleSelection(value: $selection)
            if let calorieProgress {
                Circle().trim(from: 0, to: min(1, max(0, calorieProgress)))
                    .stroke(BojiColor.mistAccent.opacity(0.4), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90)).padding(size * 0.20)
            }
            VStack(spacing: BojiLayout.tight) {
                Text(selected?.name ?? centerTitle).bojiType(.caption).foregroundStyle(.secondary)
                Text(selected.map { "\(Int((NativeData134.share($0.energy, total: total) * 100).rounded()))%" } ?? centerValue)
                    .bojiType(.section).contentTransition(.numericText())
                    .lineLimit(1).minimumScaleFactor(0.7)
                if selected != nil { Text("供能占比").bojiType(.caption).foregroundStyle(.secondary) }
            }.padding(.horizontal, size * 0.19).allowsHitTesting(false)
        }
        .frame(width: size, height: size).scaleEffect(appeared ? 1 : 0.97)
        .animation(reduceMotion ? nil : .smooth(duration: 0.4), value: [protein, carbs, fat, calorieProgress ?? 0])
        .onAppear { withAnimation(reduceMotion ? nil : .smooth(duration: 0.4)) { appeared = true } }
        .onChange(of: selected?.id) { _, _ in if selected != nil { BojiHaptics.selection() } }
        .onChange(of: [protein, carbs, fat]) { _, _ in selection = nil }
    }
}

// MARK: - 区间柱状图（真 Charts，替换手绘矩形）

/// 渐变柱 + 目标虚线 + 点选回调。metGoal 用于达标/超标双色；nil 统一主色。
struct BojiBarTrendChart: View {
    struct Bar: Identifiable, Equatable {
        var id: Date { date }
        var date: Date
        var value: Double?
        var metGoal: Bool? = nil
    }
    var bars: [Bar]
    var target: Double? = nil
    var unit: String = ""
    var tint: Color = DataPalette134.blue
    var height: CGFloat = 148
    var onSelect: ((Bar) -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var appeared = false
    @State private var selection: Date?
    @State private var selectedID: Date?
    private var selected: Bar? { bars.first { $0.id == selectedID } }
    var body: some View {
        VStack(alignment: .leading, spacing: BojiLayout.inline) {
            if let selected {
                Text("\(ClubDates.label(selected.date, format: "M月d日")) · \(barValueText(selected))")
                    .bojiType(.secondary).contentTransition(.numericText())
            }
            if typeSize.isAccessibilitySize {
                ForEach(bars) { bar in
                    HStack { Text(ClubDates.label(bar.date, format: "M月d日")); Spacer(); Text(barValueText(bar)).monospacedDigit() }
                        .bojiType(.secondary).accessibilityElement(children: .combine)
                }
            } else {
                Chart {
                    ForEach(bars) { bar in
                        if let value = bar.value {
                            BarMark(x: .value("日期", bar.date, unit: .day), y: .value("数值", value))
                                .foregroundStyle(tint.gradient).cornerRadius(5)
                                .opacity(selectedID == nil || selectedID == bar.id ? 1 : 0.35)
                                .accessibilityLabel(ClubDates.label(bar.date, format: "M月d日"))
                                .accessibilityValue(barValueText(bar))
                        }
                    }
                    if let target {
                        RuleMark(y: .value("目标", target)).foregroundStyle(BojiColor.textSecondary)
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    }
                    if let selected {
                        RuleMark(x: .value("所选日期", selected.date, unit: .day))
                            .foregroundStyle(tint.opacity(0.35)).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                }
                .chartXScale(domain: xDomain)
                .chartXAxis { AxisMarks(values: .stride(by: .day, count: max(1, bars.count / 4))) { _ in AxisValueLabel(format: .dateTime.month(.defaultDigits).day()) } }
                .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
                .chartLegend(.hidden).chartXSelection(value: $selection).frame(height: height)
                .animation(reduceMotion ? nil : .smooth(duration: 0.4), value: bars)
            }
        }
        .onAppear { withAnimation(reduceMotion ? nil : .smooth(duration: 0.35)) { appeared = true } }
        .onChange(of: selection) { _, date in
            guard let date, let closest = bars.min(by: { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }), closest.id != selectedID else { return }
            selectedID = closest.id; BojiHaptics.selection(); onSelect?(closest)
        }
        .onChange(of: bars) { _, _ in if !bars.contains(where: { $0.id == selectedID }) { selectedID = nil } }
    }
    private var xDomain: ClosedRange<Date> {
        let first = bars.map(\.date).min() ?? Date()
        let last = bars.map(\.date).max() ?? first
        return first.addingTimeInterval(-43200)...last.addingTimeInterval(43200)
    }
    private func barValueText(_ bar: Bar) -> String {
        guard let value = bar.value else { return "未记录" }
        return value.formatted(.number.precision(.fractionLength(0))) + (unit.isEmpty ? "" : " " + unit)
    }
}

struct BojiTrendPoint: Identifiable, Equatable {
    var date: Date
    var value: Double
    var sourceID: String? = nil
    var id: String { sourceID ?? String(date.timeIntervalSinceReferenceDate) }
}

struct BojiLineTrendChart: View {
    var points: [BojiTrendPoint]
    var target: Double? = nil
    var unit: String = ""
    var tint: Color = DataPalette134.blue
    var height: CGFloat = 170
    var showsAxis: Bool = true
    var show7DayAverage: Bool = false
    var onSelect: ((BojiTrendPoint) -> Void)? = nil
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var selection: Date?
    @State private var selectedID: String?
    private var sorted: [BojiTrendPoint] { points.filter { $0.value.isFinite }.sorted { $0.date < $1.date } }
    private var selected: BojiTrendPoint? { sorted.first { $0.id == selectedID } }
    private var domain: ClosedRange<Double> { NativeData134.domain(sorted.map(\.value), target: target) }
    private var rolling7DayPoints: [BojiTrendPoint] {
        guard show7DayAverage, sorted.count >= 2 else { return [] }
        return sorted.compactMap { current in
            let windowStart = current.date.addingTimeInterval(-6 * 86400)
            let inWindow = sorted.filter { $0.date >= windowStart && $0.date <= current.date }
            guard !inWindow.isEmpty else { return nil }
            let avg = inWindow.map(\.value).reduce(0, +) / Double(inWindow.count)
            return BojiTrendPoint(date: current.date, value: avg, sourceID: "avg-\(current.id)")
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: BojiLayout.inline) {
            if let selected {
                Text("\(ClubDates.label(selected.date, format: "M月d日")) · \(selected.value.formatted(.number.precision(.fractionLength(0...1)))) \(unit)")
                    .bojiType(.secondary).contentTransition(.numericText())
            }
            if typeSize.isAccessibilitySize {
                ForEach(sorted) { point in
                    HStack { Text(ClubDates.label(point.date, format: "M月d日")); Spacer(); Text("\(point.value.formatted(.number.precision(.fractionLength(0...1)))) \(unit)") }
                        .bojiType(.secondary).accessibilityElement(children: .combine)
                }
            } else {
                chartContent.frame(height: height)
                    .animation(reduceMotion ? nil : .smooth(duration: 0.4), value: points)
            }
        }
        .onAppear { withAnimation(reduceMotion ? nil : .smooth(duration: 0.35)) { appeared = true } }
        .onChange(of: selection) { _, date in
            guard let date, let closest = sorted.min(by: { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }), closest.id != selectedID else { return }
            selectedID = closest.id; BojiHaptics.selection(); onSelect?(closest)
        }
        .onChange(of: points) { _, _ in if !sorted.contains(where: { $0.id == selectedID }) { selectedID = nil } }
    }
    private var chartContent: some View {
        Chart {
            ForEach(sorted) { point in
                AreaMark(x: .value("日期", point.date), yStart: .value("基准", domain.lowerBound), yEnd: .value("数值", point.value))
                    .foregroundStyle(LinearGradient(colors: [tint.opacity(show7DayAverage ? 0.08 : 0.22), tint.opacity(0.01)], startPoint: .top, endPoint: .bottom)).interpolationMethod(.linear)
                LineMark(x: .value("日期", point.date), y: .value("数值", point.value), series: .value("类别", "实测"))
                    .foregroundStyle(show7DayAverage ? tint.opacity(0.5) : tint).lineStyle(StrokeStyle(lineWidth: show7DayAverage ? 1.5 : 2.5, lineCap: .round, dash: show7DayAverage ? [4, 3] : [])).interpolationMethod(.linear)
                PointMark(x: .value("日期", point.date), y: .value("数值", point.value))
                    .foregroundStyle(tint).symbolSize(point.id == selectedID ? 70 : sorted.count > 45 ? 8 : 20)
                    .accessibilityLabel(ClubDates.label(point.date, format: "M月d日"))
                    .accessibilityValue("\(point.value.formatted(.number.precision(.fractionLength(0...1)))) \(unit)")
            }
            if show7DayAverage {
                ForEach(rolling7DayPoints) { avgPoint in
                    LineMark(x: .value("日期", avgPoint.date), y: .value("数值", avgPoint.value), series: .value("类别", "7天均值"))
                        .foregroundStyle(BojiColor.timerAccent)
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .interpolationMethod(.monotone)
                }
            }
            if let target {
                RuleMark(y: .value("目标", target)).foregroundStyle(BojiColor.textSecondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
            if let selected {
                RuleMark(x: .value("所选日期", selected.date)).foregroundStyle(tint.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .chartYScale(domain: domain).chartLegend(.hidden).chartXSelection(value: $selection)
        .chartXAxis { if showsAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisValueLabel(format: .dateTime.month(.defaultDigits).day()) } } }
        .chartYAxis { if showsAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) } }
    }
}

// MARK: - 训练量热力条（Apple Swift Charts 原生实现）

/// 7天训练量节奏条：采用 Apple Swift Charts 原生 BarMark 渲染。
struct BojiVolumeHeatStrip: View {
    struct Cell: Identifiable, Equatable {
        var id: Date { date }
        var date: Date
        var value: Double
        var label: String = ""
    }

    var cells: [Cell]
    var onSelect: ((Cell) -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Chart(cells) { cell in
            BarMark(
                x: .value("日期", cell.date, unit: .day),
                y: .value("训练量", max(0.01, cell.value))
            )
            .foregroundStyle(cell.value > 0 ? BojiColor.mistAccent.gradient : Color.secondary.opacity(0.12).gradient)
            .cornerRadius(4)
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day)) { val in
                if let d = val.as(Date.self) {
                    AxisValueLabel {
                        Text(ClubDates.label(d, format: "E"))
                            .bojiType(.caption)
                            .foregroundStyle(BojiColor.textTertiary)
                    }
                }
            }
        }
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .frame(height: 48)
        .accessibilityLabel("这周练了几天的节奏分布")
    }
}

/// Display and analysis share completeness semantics. Missing data never means zero.
enum DashboardMetricProvider {
    static func nutritionStatus(_ day: DayLog, target: NutritionTarget?) -> Bool? {
        guard day.mealsComplete, !day.meals.isEmpty, day.knownMeals.count == day.meals.count,
              let target, target.generalGuidanceOnly != true else { return nil }
        return day.calories >= target.caloriesMin && day.calories <= target.caloriesMax
    }
}
