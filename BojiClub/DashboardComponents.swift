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
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption2.weight(.medium)).foregroundStyle(BojiColor.textSecondary)
                .lineLimit(1).minimumScaleFactor(0.8)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(.title3, design: .rounded, weight: .bold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                if !unit.isEmpty {
                    Text(unit).font(.caption2.weight(.semibold)).foregroundStyle(BojiColor.textSecondary)
                }
            }
            HStack(spacing: 4) {
                if let delta, let color = deltaColor {
                    HStack(spacing: 2) {
                        Image(systemName: delta > 0 ? "arrow.up.right" : delta < 0 ? "arrow.down.right" : "arrow.right")
                            .font(.system(size: 8, weight: .bold))
                        Text((delta > 0 ? "+" : "") + delta.formatted(.number.precision(.fractionLength(0...1))) + deltaSuffix)
                            .font(.caption2.weight(.semibold)).monospacedDigit()
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
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BojiColor.cardSurface, in: RoundedRectangle(cornerRadius: BojiRadius.inner, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: BojiRadius.inner, style: .continuous).stroke(BojiColor.outline, lineWidth: 0.5) }
    }
}

// MARK: - 迷你走势

/// 无坐标轴微缩折线（KPI 胶囊、指标格用）。Path + trim 画入动画。
struct BojiSparkline: View {
    var points: [Double]
    var tint: Color = BojiColor.mistAccent
    var filled: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawn: CGFloat = 0

    private var path: Path {
        var path = Path()
        guard points.count >= 2, let low = points.min(), let high = points.max(), low.isFinite, high.isFinite else { return path }
        let spread = high - low
        for (index, value) in points.enumerated() {
            let point = CGPoint(x: Double(index) / Double(points.count - 1), y: spread > 0 ? 1 - (value - low) / spread : 0.5)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
    var body: some View {
        GeometryReader { geo in
            let stroke = path.applying(CGAffineTransform(scaleX: geo.size.width, y: geo.size.height))
            ZStack {
                if filled, points.count >= 2 {
                    Path { area in
                        area.addPath(stroke)
                        area.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height))
                        area.addLine(to: CGPoint(x: 0, y: geo.size.height))
                        area.closeSubpath()
                    }.fill(LinearGradient(colors: [tint.opacity(0.2), tint.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                }
                stroke.trim(from: 0, to: drawn).stroke(tint, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
            }
        }
        .onAppear { withAnimation(reduceMotion ? nil : .bojiFluid) { drawn = 1 } }
        .accessibilityHidden(true)
    }
}

// MARK: - 目标圆环

/// 目标完成环：进度 0...1.5（允许超额），入场扫过动画，中心内容由调用方提供。
struct BojiRingGauge<Center: View>: View {
    var progress: Double
    var tint: Color = BojiColor.mistAccent
    var lineWidth: CGFloat = 12
    @ViewBuilder var center: () -> Center

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweep: Double = 0

    var body: some View {
        ZStack {
            Circle()
                .stroke(BojiColor.inputSurface, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(1, max(0, sweep)))
                .stroke(
                    AngularGradient(colors: [tint.opacity(0.65), tint], center: .center),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .overlay {
                    if progress > 1 {
                        Circle()
                            .trim(from: 0, to: min(1, sweep))
                            .stroke(BojiColor.emeraldAccent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .mask { Circle().trim(from: 0.66, to: 1).rotationEffect(.degrees(-90)) }
                    }
                }
            center()
        }
        .onAppear {
            sweep = reduceMotion ? progress : 0
            if !reduceMotion { withAnimation(.bojiFluid) { sweep = progress } }
        }
        .onChange(of: progress) { _, value in
            if reduceMotion { sweep = value } else { withAnimation(.bojiFluid) { sweep = value } }
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
            VStack(spacing: 4) {
                Text(selected?.name ?? centerTitle).font(.caption).foregroundStyle(.secondary)
                Text(selected.map { "\(Int((NativeData134.share($0.energy, total: total) * 100).rounded()))%" } ?? centerValue)
                    .font(.system(.title2, design: .rounded, weight: .semibold)).monospacedDigit().contentTransition(.numericText())
                    .lineLimit(1).minimumScaleFactor(0.7)
                if selected != nil { Text("供能占比").font(.caption2).foregroundStyle(.secondary) }
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
        VStack(alignment: .leading, spacing: 10) {
            if let selected {
                Text("\(ClubDates.label(selected.date, format: "M月d日")) · \(barValueText(selected))")
                    .font(.subheadline.monospacedDigit().weight(.medium)).contentTransition(.numericText())
            }
            if typeSize.isAccessibilitySize {
                ForEach(bars) { bar in
                    HStack { Text(ClubDates.label(bar.date, format: "M月d日")); Spacer(); Text(barValueText(bar)).monospacedDigit() }
                        .font(.subheadline).accessibilityElement(children: .combine)
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
    var onSelect: ((BojiTrendPoint) -> Void)? = nil
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var selection: Date?
    @State private var selectedID: String?
    private var sorted: [BojiTrendPoint] { points.filter { $0.value.isFinite }.sorted { $0.date < $1.date } }
    private var selected: BojiTrendPoint? { sorted.first { $0.id == selectedID } }
    private var domain: ClosedRange<Double> { NativeData134.domain(sorted.map(\.value), target: target) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let selected {
                Text("\(ClubDates.label(selected.date, format: "M月d日")) · \(selected.value.formatted(.number.precision(.fractionLength(0...1)))) \(unit)")
                    .font(.subheadline.monospacedDigit().weight(.medium)).contentTransition(.numericText())
            }
            if typeSize.isAccessibilitySize {
                ForEach(sorted) { point in
                    HStack { Text(ClubDates.label(point.date, format: "M月d日")); Spacer(); Text("\(point.value.formatted(.number.precision(.fractionLength(0...1)))) \(unit)") }
                        .font(.subheadline).accessibilityElement(children: .combine)
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
                    .foregroundStyle(LinearGradient(colors: [tint.opacity(0.22), tint.opacity(0.01)], startPoint: .top, endPoint: .bottom)).interpolationMethod(.linear)
                LineMark(x: .value("日期", point.date), y: .value("数值", point.value))
                    .foregroundStyle(tint).lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round)).interpolationMethod(.linear)
                PointMark(x: .value("日期", point.date), y: .value("数值", point.value))
                    .foregroundStyle(tint).symbolSize(point.id == selectedID ? 70 : sorted.count > 45 ? 8 : 20)
                    .accessibilityLabel(ClubDates.label(point.date, format: "M月d日"))
                    .accessibilityValue("\(point.value.formatted(.number.precision(.fractionLength(0...1)))) \(unit)")
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

// MARK: - 训练量热力条

/// 按当日训练量五级色阶（GitHub 打卡风），升级原二进制打点。
struct BojiVolumeHeatStrip: View {
    struct Cell: Identifiable, Equatable {
        var id: Date { date }
        var date: Date
        var value: Double // 当日训练量（容量或组数）
        var label: String = ""
    }

    var cells: [Cell]
    var onSelect: ((Cell) -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    private var peak: Double { max(1, cells.map(\.value).max() ?? 1) }

    var body: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
        LazyVGrid(columns: columns, spacing: 4) {
            ForEach(cells) { cell in
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(intensity(cell.value))
                    .frame(height: 22)
                    .overlay {
                        if ClubDates.calendar.isDateInToday(cell.date) {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .stroke(BojiColor.mistAccent, lineWidth: 1.5)
                        }
                    }
                    .onTapGesture { onSelect?(cell) }
                    .accessibilityLabel(cell.label.isEmpty ? ClubDates.label(cell.date, format: "M月d日") : cell.label)
                    .accessibilityAddTraits(onSelect == nil ? [] : .isButton)
            }
        }
        .opacity(appeared ? 1 : 0)
        .onAppear {
            if reduceMotion { appeared = true } else { withAnimation(.bojiSnappy) { appeared = true } }
        }
    }

    /// 五级雾霾蓝色阶：0 → 浅底，max → 实色。
    private func intensity(_ value: Double) -> Color {
        guard value > 0 else { return BojiColor.inputSurface }
        let level = min(4, Int(value / peak * 4) + 1)
        switch level {
        case 1: return BojiColor.mistAccent.opacity(0.22)
        case 2: return BojiColor.mistAccent.opacity(0.42)
        case 3: return BojiColor.mistAccent.opacity(0.65)
        case 4: return BojiColor.mistAccent.opacity(0.85)
        default: return BojiColor.mistAccent
        }
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
