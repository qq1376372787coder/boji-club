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
enum DataPalette134 {
    static let blue = Color(red: 0.34, green: 0.52, blue: 0.71)
    static let colors: [Color] = [blue, Color(red:0.57,green:0.49,blue:0.78),
        Color(red:0.38,green:0.64,blue:0.57), Color(red:0.78,green:0.56,blue:0.36),
        Color(red:0.74,green:0.46,blue:0.57), Color(red:0.46,green:0.60,blue:0.72)]
    static func color(_ name: String) -> Color { colors[NativeData134.colorIndex(name)] }
    static let protein = colors[0], carbs = colors[3], fat = colors[1]
}

struct DataMetric134: View {
    let title: String
    let value: String
    let unit: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 3) { number; suffix }
                VStack(alignment: .leading, spacing: 2) { number; suffix }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
    }
    private var number: some View {
        Text(value).font(.system(.title2, design: .rounded, weight: .semibold))
            .monospacedDigit().contentTransition(.numericText())
            .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: value)
    }
    private var suffix: some View { Text(unit).font(.caption).foregroundStyle(.secondary) }
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
        VStack(alignment: .leading, spacing: 18) {
            if !typeSize.isAccessibilitySize && !positive.isEmpty {
                ZStack {
                    ForEach(Array(positive.enumerated()), id: \.element.id) { index, item in
                        petal(item, index: index)
                    }
                    VStack(spacing: 3) {
                        Text(active?.name ?? "完成组数").font(.caption).foregroundStyle(.secondary)
                        Text("\(active?.sets ?? total)").font(.system(size: 34, weight: .semibold, design: .rounded))
                            .contentTransition(.numericText()).monospacedDigit()
                        Text("组").font(.caption).foregroundStyle(.secondary)
                    }.allowsHitTesting(false)
                }
                .frame(maxWidth: .infinity).frame(height: 260)
                .scaleEffect(appeared ? 1 : 0.94).opacity(appeared ? 1 : 0)
                .accessibilityHidden(true)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 260 : 130))], alignment: .leading, spacing: 8) {
                ForEach(positive) { item in
                    Button { select(item.id) } label: {
                        HStack(spacing: 8) {
                            Circle().fill(DataPalette134.color(item.name)).frame(width: 8, height: 8)
                            Text(item.name).font(.subheadline)
                            Spacer(minLength: 2)
                            Text("\(item.sets)组").font(.subheadline.monospacedDigit().weight(.medium))
                        }.padding(.horizontal, 10).frame(minHeight: 44)
                            .background(selected == item.id ? DataPalette134.color(item.name).opacity(0.13) : Color.clear, in: RoundedRectangle(cornerRadius: 12))
                    }.buttonStyle(.plain)
                        .accessibilityLabel("\(item.name)，完成\(item.sets)组，占\(Int((NativeData134.share(Double(item.sets), total: Double(total)) * 100).rounded()))%，点按查看")
                        .accessibilityAddTraits(selected == item.id ? .isSelected : [])
                }
            }
            if let active {
                Text("\(active.name) · \(active.sets) 组，占本期完成组数的 \(Int((NativeData134.share(Double(active.sets), total: Double(total)) * 100).rounded()))%")
                    .font(.subheadline.weight(.medium)).contentTransition(.opacity)
            }
            Text(typeSize.isAccessibilitySize ? "按动作的主要肌群统计完成组数。" : "花瓣长度表示完成组数；按动作的主要肌群分类。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.4), value: items)
        .onAppear { withAnimation(reduceMotion ? nil : .spring(duration: 0.55, bounce: 0.12)) { appeared = true } }
        .onChange(of: items) { _, _ in if !positive.contains(where: { $0.id == selected }) { selected = nil } }
    }
    private func petal(_ item: MusclePetal134, index: Int) -> some View {
        let maximum = max(1, positive.map(\.sets).max() ?? 1)
        let radius = 58 + 65 * Double(item.sets) / Double(maximum)
        let angle = 360 / Double(max(1, positive.count))
        let color = DataPalette134.color(item.name)
        return DataPetalShape134(start: Double(index) * angle - 90, sweep: angle, radius: radius)
            .fill(RadialGradient(colors: [color.opacity(0.16), color.opacity(selected == item.id ? 0.95 : 0.6)], center: .center, startRadius: 40, endRadius: 124))
            .overlay { DataPetalShape134(start: Double(index) * angle - 90, sweep: angle, radius: radius).stroke(color.opacity(selected == item.id ? 0.9 : 0.1), lineWidth: selected == item.id ? 2 : 1) }
            .contentShape(DataPetalShape134(start: Double(index) * angle - 90, sweep: angle, radius: radius))
            .onTapGesture { select(item.id) }
    }
    private func select(_ id: String) {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { selected = selected == id ? nil : id }
        BojiHaptics.selection()
    }
}

private struct DataPetalShape134: Shape {
    var start: Double
    var sweep: Double
    var radius: Double
    var animatableData: Double { get { radius } set { radius = newValue } }
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let gap = min(3.0, sweep * 0.08)
        let a = Angle.degrees(start + gap), b = Angle.degrees(start + sweep - gap)
        let rounding = min(5.0, sweep * 0.09)
        func point(_ r: Double, _ degrees: Double) -> CGPoint {
            CGPoint(x: center.x + r * cos(degrees * .pi / 180), y: center.y + r * sin(degrees * .pi / 180))
        }
        var path = Path()
        path.addArc(center: center, radius: 46, startAngle: .degrees(a.degrees + rounding), endAngle: .degrees(b.degrees - rounding), clockwise: false)
        path.addQuadCurve(to: point(51, b.degrees), control: point(46, b.degrees))
        path.addLine(to: point(radius - 5, b.degrees))
        path.addQuadCurve(to: point(radius, b.degrees - rounding), control: point(radius, b.degrees))
        path.addArc(center: center, radius: radius, startAngle: .degrees(b.degrees - rounding), endAngle: .degrees(a.degrees + rounding), clockwise: true)
        path.addQuadCurve(to: point(radius - 5, a.degrees), control: point(radius, a.degrees))
        path.addLine(to: point(51, a.degrees))
        path.addQuadCurve(to: point(46, a.degrees + rounding), control: point(46, a.degrees))
        path.closeSubpath()
        return path
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
                HStack(alignment: .top, spacing: 14) {
                    VStack(spacing: 0) {
                        Circle().fill(DataPalette134.blue).frame(width: 7, height: 7).padding(.top, 6)
                        if index < events.count - 1 { Rectangle().fill(BojiColor.outline).frame(width: 1).frame(minHeight: 52) }
                    }.frame(width: 10)
                    Text(ClubDates.label(event.date, format: "M月d日")).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 50, alignment: .leading).padding(.top, 3)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(event.title).font(.subheadline.weight(.medium))
                        Text(event.detail).font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 22)
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
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 20) {
                DataMetric134(title: "训练日", value: "\(payload.trainingDays)", unit: "天")
                DataMetric134(title: "实际完成", value: "\(payload.completedSets)", unit: "组")
            }
            if let frequency = NativeData134.frequency(trainingDays: payload.trainingDays, start: payload.windowStart, end: payload.windowEnd) {
                HStack(spacing: 12) {
                    BojiRingGauge(progress: frequency, tint: DataPalette134.blue, lineWidth: 5) {
                        Text("\(Int((frequency * 100).rounded()))%").font(.caption.monospacedDigit().weight(.semibold))
                    }.frame(width: 52, height: 52).accessibilityHidden(true)
                    Text("期间有训练的天数占 \(Int((frequency * 100).rounded()))%")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Text("\(payload.windowStart) 至 \(payload.windowEnd) · 仅计已确认训练")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
