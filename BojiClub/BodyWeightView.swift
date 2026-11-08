import SwiftUI
import Charts

struct BodyWeightView: View {
    var initialDate: Date = Date()
    @Environment(\.dynamicTypeSize) private var typeSize
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var health: HealthDataService
    @EnvironmentObject private var account: AccountService
    @Environment(\.dismiss) private var dismiss
    @State private var selectedDate = Date()
    @State private var loaded = false
    @State private var dateNotice: String?
    @State private var editor: WeightEditRequest?
    @State private var rangeKey = "近 3 个月"
    @State private var customStart = ClubDates.calendar.date(byAdding: .month, value: -2, to: Date()) ?? Date()
    @State private var customEnd = Date()
    @State private var rowLimit = 30
    @State private var showFactIntake = false
    @State private var show7DayAverage = false
    private var points: [BodyWeightPoint] {
        let calendar = ClubDates.calendar
        let end = calendar.startOfDay(for: min(customEnd, Date()))
        let start: Date
        switch rangeKey {
        case "近 6 个月": start = calendar.date(byAdding: .month, value: -5, to: end) ?? end
        case "近 12 个月": start = calendar.date(byAdding: .month, value: -11, to: end) ?? end
        case "自定义": start = calendar.startOfDay(for: min(customStart, end))
        default: start = calendar.date(byAdding: .month, value: -2, to: end) ?? end
        }
        return store.bodyWeightPoints(through: end, limit: 10000).filter { ($0.dayKey ?? ClubDates.key($0.date)) >= ClubDates.key(start) && ($0.dayKey ?? ClubDates.key($0.date)) <= ClubDates.key(end) }
    }
    var body: some View {
        ClubNavigationStack132 {
            scrollContent
                .navigationTitle("身体记录").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { AIReferenceEntryButton(reference: .day("body_range", date: selectedDate, title: "身体测量")) }
                    ToolbarItem(placement: .topBarLeading) { Button("分类登记") { showFactIntake = true } }
                    ToolbarItem(placement: .cancellationAction) { DismissButton() }
                }
        }
        .onAppear {
            guard !loaded else { return }; loaded = true
            if ClubDates.isFuture(initialDate) {
                selectedDate = Date(); dateNotice = "未来日期不可登记，已自动切回今天。"
            } else { selectedDate = initialDate }
        }
        .onChange(of: rangeKey) { _, _ in rowLimit = 30 }
        .sheet(item: $editor) { request in WeightEntryEditor(date: request.date, measurementID: request.measurementID) }
        .sheet(isPresented: $showFactIntake) { BodyFactIntakeView(initialDate: selectedDate) }
        .task(id: ClubDates.key(selectedDate)) { if health.enabled { await health.refresh(selectedDate) } }
    }

    private var scrollContent: some View {
        List {
                    ClubCard {
                        if typeSize.isAccessibilitySize {
                            VStack(alignment: .leading, spacing: BojiLayout.inline) {
                                Text("登记日期").bojiType(.bodyStrong)
                                DatePicker("登记日期", selection: $selectedDate, in: ...Date(), displayedComponents: .date).labelsHidden()
                            }
                        } else {
                            DatePicker("登记日期", selection: $selectedDate, in: ...Date(), displayedComponents: .date)
                        }
                        if let dateNotice { Text(dateNotice).bojiType(.caption).foregroundStyle(.secondary) }
                        BojiAdaptiveGroup {
                            VStack(alignment: .leading, spacing: BojiLayout.tight) {
                                Text(ClubDates.label(selectedDate, format: "M月d日") + " 实际称重")
                                    .bojiFont(.label).foregroundStyle(BojiColor.textSecondary)
                                if let kilograms = store.log(for: selectedDate).bodyWeight?.kilograms {
                                    Text(kilograms.formatted(.number.precision(.fractionLength(1))) + " kg")
                                        .bojiFont(.bodyMetric, monospacedDigits: true)
                                        .foregroundStyle(BojiColor.textPrimary)
                                } else {
                                    Text("尚未登记").bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
                                }
                            }
                            Spacer()
                            Button(store.log(for: selectedDate).bodyWeight?.kilograms == nil ? "登记" : "再次测量") {
                                editor = WeightEditRequest(date: selectedDate)
                            }.buttonStyle(BojiButtonStyle(kind: .primary))
                        }
                        if let entry = store.log(for: selectedDate).bodyWeight,
                           entry.bodyFatPercentage != nil || entry.waistCircumferenceCM != nil {
                            HStack(spacing: BojiSpace.general) {
                                if let fat = entry.bodyFatPercentage {
                                    Text("体脂 \(fat.formatted(.number.precision(.fractionLength(1))))%")
                                }
                                if let waist = entry.waistCircumferenceCM {
                                    Text("腰围 \(waist.formatted(.number.precision(.fractionLength(1)))) cm")
                                }
                                Spacer()
                                if let recorded = entry.recordedAt {
                                    Text(recorded.formatted(date: .abbreviated, time: .shortened))
                                }
                            }.bojiType(.caption).foregroundStyle(.secondary)
                        }
                        Text("按实际称重记录即可，无需每天打卡。").bojiType(.caption).foregroundStyle(.secondary)
                    }
                    if let last = points.last {
                        let target = store.state.profile.targetWeightKg
                        let weekAgo = points.dropLast().last
                        let weekDelta = weekAgo.map { last.kilograms - $0.kilograms }
                        let interval = weekAgo.map { ClubDates.calendar.dateComponents([.day], from: $0.date, to: last.date).day ?? 0 }
                        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading)) : AnyLayout(HStackLayout(spacing: BojiLayout.inline))
                        layout {
                            BojiKpiCapsule(
                                title: "当前体重",
                                value: last.kilograms.formatted(.number.precision(.fractionLength(1))),
                                unit: "kg",
                                spark: points.suffix(7).map(\.kilograms)
                            )
                            BojiKpiCapsule(
                                title: interval.map { "较上次（\($0)天）" } ?? "较上次",
                                value: weekDelta?.formatted(.number.sign(strategy: .always()).precision(.fractionLength(1))) ?? "—",
                                unit: "kg",
                                delta: weekDelta,
                                downIsGood: target.map { last.kilograms > $0 } ?? false
                            )
                            BojiKpiCapsule(
                                title: "距目标",
                                value: target.map { abs($0 - last.kilograms).formatted(.number.precision(.fractionLength(1))) } ?? "未设置目标",
                                unit: target == nil ? "" : "kg"
                            )
                        }
                    }
                    ClubCard {
                        HStack(alignment: .center) {
                            Text("体重变化").bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
                            Spacer()

                        }
                        BojiChipRow(items: ["近 3 个月", "近 6 个月", "近 12 个月", "自定义"], selection: $rangeKey)
                        if rangeKey == "自定义" {
                            HStack {
                                DatePicker("开始", selection: $customStart, in: ...customEnd, displayedComponents: .date)
                                DatePicker("结束", selection: $customEnd, in: customStart...Date(), displayedComponents: .date)
                            }.bojiType(.caption)
                        }
                        if points.isEmpty {
                            EmptyNote(title: "还没有体重记录", detail: "登记一次，就会在这里留下一个真实的数据点。")
                        } else {
                            HStack {
                                Spacer()
                                Toggle("7 天均线", isOn: $show7DayAverage)
                                    .bojiType(.caption)
                                    .foregroundStyle(show7DayAverage ? BojiColor.brandAccent : BojiColor.textSecondary)
                                    .toggleStyle(.button)
                                    .buttonStyle(.bordered)
                                    .buttonBorderShape(.capsule)
                                    .controlSize(.mini)
                            }
                            BodyTrendChart(points: points, target: store.state.profile.targetWeightKg,
                                           height: 190, showsAxis: true, show7DayAverage: show7DayAverage)
                            HStack {
                                Text("\(points.count) 次实际测量\(show7DayAverage ? "（已叠加 7 天移动均线）" : "")").bojiType(.caption).foregroundStyle(.secondary)
                                Spacer()
                                if let first = points.first, let last = points.last, points.count >= 2 {
                                    Text("首末记录相差 " + (last.kilograms - first.kilograms).formatted(.number.sign(strategy: .always()).precision(.fractionLength(1))) + " kg")
                                        .bojiType(.caption)
                                }
                            }
                        }
                        Text("仅展示实际测量点，结合训练与饮食综合分析趋势。")
                            .bojiFont(.label).foregroundStyle(BojiColor.textSecondary)
                        if let target = store.state.profile.targetWeightKg {
                            Text("目标体重 \(target.formatted(.number.precision(.fractionLength(1)))) kg")
                                .bojiFont(.label).foregroundStyle(BojiColor.textTertiary)
                        }
                    }
                    ClubContextualInsightStrip(date: selectedDate, kinds: [.body])
                    HealthSummaryCard(date: selectedDate)
                    if !points.isEmpty {
                        ClubCard {
                            Text("测量记录").bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
                            ForEach(Array(points.reversed().prefix(rowLimit))) { point in
                                Button {
                                    editor = WeightEditRequest(date: ClubDates.date(fromKey: point.dayKey ?? ClubDates.key(point.date)) ?? point.date, measurementID: point.measurementID.flatMap(UUID.init(uuidString:)))
                                } label: {
                                    HStack {
                                        Text(ClubDates.label(point.date, format: "M月d日 HH:mm"))
                                        Spacer()
                                        Text(point.kilograms.formatted(.number.precision(.fractionLength(1))) + " kg").monospacedDigit()
                                        Image(systemName: "chevron.right").bojiType(.caption).foregroundStyle(.secondary)
                                    }.bojiType(.secondary).padding(.vertical, BojiSpace.tight).contentShape(Rectangle())
                                }.buttonStyle(ClubMotionButton())
                            }
                            if points.count > rowLimit {
                                Button("再显示 30 条记录") { rowLimit += 30 }.buttonStyle(SecondaryButton()).bojiType(.caption)
                            }
                        }
                    }

        }.clubManagementList132()
        .background { ClubBackground() }
    }
}

private struct WeightEditRequest: Identifiable {
    let id = UUID()
    let date: Date
    var measurementID: UUID? = nil
}

/// 真实测量点趋势。只有一个点时不连线；目标线只在用户设置目标后显示。
struct BodyTrendChart: View {
    let points: [BodyWeightPoint]
    var target: Double? = nil
    var height: CGFloat = 90
    var showsAxis = false
    var show7DayAverage = false

    var body: some View {
        if !points.isEmpty {
            BojiLineTrendChart(points: points.map { BojiTrendPoint(date: $0.date, value: $0.kilograms, sourceID: $0.id) }, target: target,
                unit: "kg", height: height, showsAxis: showsAxis, show7DayAverage: show7DayAverage)
                .accessibilityLabel("真实体重记录，\(points.count)次测量；折线仅连接测量点，未测日期不记为零\(show7DayAverage ? "；已叠加 7 天移动均线" : "")")
        }
    }
}

struct WeightEntryEditor: View {
    let date: Date
    var measurementID: UUID? = nil
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var health: HealthDataService
    @Environment(\.dismiss) private var dismiss
    @State private var measuredAt = Date()
    @State private var kilograms = ""
    @State private var bodyFat = ""
    @State private var waist = ""
    @State private var owner: Int?
    @State private var original: BodyWeightEntry?
    @State private var loaded = false
    @State private var error: String?
    @State private var confirmDelete = false
    @FocusState private var focused: Bool
    private var value: Double? {
        let text = kilograms.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        guard let kg = Double(text), kg.isFinite, (20...400).contains(kg) else { return nil }
        return kg
    }
    private func optional(_ text: String, range: ClosedRange<Double>) -> Double?? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        if trimmed.isEmpty { return .some(nil) }
        guard let number = Double(trimmed), number.isFinite, range.contains(number) else { return nil }
        return .some(number)
    }
    private var parsedBodyFat: Double?? { optional(bodyFat, range: 0...70) }
    private var parsedWaist: Double?? { optional(waist, range: 30...300) }
    private var canSave: Bool {
        (value != nil || (!bodyFat.isEmpty && parsedBodyFat != nil) || (!waist.isEmpty && parsedWaist != nil))
            && parsedBodyFat != nil && parsedWaist != nil
    }
    var body: some View {
        ClubNavigationStack132 {
            Form {
                Section(ClubDates.label(date, format: "yyyy年M月d日")) {
                    HStack {
                        TextField("填写这次实际称得的体重", text: $kilograms).keyboardType(.decimalPad).focused($focused)
                            .accessibilityLabel("测量体重，公斤")
                        Text("kg").foregroundStyle(.secondary)
                    }
                    DatePicker("测量时间", selection: $measuredAt, in: measurementTimeRange, displayedComponents: [.date, .hourAndMinute])
                    Text("建议在早晨空腹等相近条件下测量。")
                        .bojiType(.caption).foregroundStyle(.secondary)
                    Text("使用公斤，允许范围 20–400 kg。").bojiType(.label).foregroundStyle(.secondary)
                    if !kilograms.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value == nil {
                        Text("请输入 20–400 之间的体重数字，例如 68.5。").bojiType(.caption).foregroundStyle(.red)
                    }
                }
                Section("可选测量") {
                    HStack {
                        TextField("体脂率（可留空）", text: $bodyFat).keyboardType(.decimalPad)
                            .accessibilityLabel("手动体脂率，百分比")
                        Text("%").foregroundStyle(.secondary)
                    }
                    HStack {
                        TextField("腰围（可留空）", text: $waist).keyboardType(.decimalPad)
                            .accessibilityLabel("手动腰围，厘米")
                        Text("cm").foregroundStyle(.secondary)
                    }
                    if !bodyFat.isEmpty && parsedBodyFat == nil || !waist.isEmpty && parsedWaist == nil {
                        Text("体脂率范围 0–70%，腰围范围 30–300 cm；不确定就留空。").bojiType(.caption).foregroundStyle(.red)
                    }
                    Text("每次采样独立保留。纠正已有测量会保留原来源；Apple 健康源样本仍由健康 App 管理。")
                        .bojiType(.caption).foregroundStyle(.secondary)
                }
                if original?.hasMeasurement == true {
                    Section { Button("删除当前显示的这次测量", role: .destructive) { confirmDelete = true }.buttonStyle(ClubActionButtonStyle(kind: .row)) }
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }.clubManagementList132().clubGroupedSurface()
            .navigationTitle(measurementID == nil ? "登记身体测量" : "纠正这次测量").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { saveMeasurements() }.disabled(!canSave) }
            }
            .onAppear {
                guard !loaded else { return }; loaded = true; owner = store.editingAccountID
                original = measurementID.flatMap { id in (store.log(for: date).bodyMeasurements ?? [store.log(for: date).bodyWeight].compactMap { $0 }).first { ($0.id ?? BodyMeasurementIdentity.legacy($0, date: ClubDates.key(date))) == id } }
                let now = Date(); let c = ClubDates.calendar.dateComponents([.hour, .minute], from: now)
                measuredAt = original?.recordedAt ?? ClubDates.calendar.date(bySettingHour: c.hour ?? 12, minute: c.minute ?? 0, second: 0, of: date) ?? date
                measuredAt = min(max(measuredAt, measurementTimeRange.lowerBound), measurementTimeRange.upperBound)
                if let kg = original?.kilograms { kilograms = kg.formatted(.number.precision(.fractionLength(1)).grouping(.never)) }
                if let fat = original?.bodyFatPercentage { bodyFat = fat.formatted(.number.precision(.fractionLength(1)).grouping(.never)) }
                if let waist = original?.waistCircumferenceCM { self.waist = waist.formatted(.number.precision(.fractionLength(1)).grouping(.never)) }
                focused = true
            }
            .confirmationDialog("删除当前显示的这次测量？", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("删除测量记录", role: .destructive) { BojiHaptics.warning(); save(nil) }
                Button("取消", role: .cancel) { }
            } message: { Text("训练和饮食记录保留。已生成的旧分析不会自动重写。") }
        }
    }
    private var measurementTimeRange: ClosedRange<Date> {
        let start = ClubDates.calendar.startOfDay(for: date)
        let end = min(ClubDates.calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_399), Date())
        return start...max(start, end)
    }
    private var measurementUnchanged: Bool {
        guard let measurementID else { return true }
        return original == (store.log(for: date).bodyMeasurements ?? [store.log(for: date).bodyWeight].compactMap { $0 }).first { ($0.id ?? BodyMeasurementIdentity.legacy($0, date: ClubDates.key(date))) == measurementID }
    }
    private func saveMeasurements() {
        guard owner != nil, owner == store.editingAccountID else { error = "账号已变化，请重新打开。"; return }
        guard measurementUnchanged else { error = "这条测量已在其他地方修改，请重新打开后核对。"; return }
        guard parsedBodyFat != nil, parsedWaist != nil else {
            error = "体脂率范围 0–70%，腰围范围 30–300 cm；不确定就留空。"; return
        }
        let targetID = measurementID ?? UUID()
        if store.saveBodyMeasurements(kilograms: value, bodyFatPercentage: parsedBodyFat ?? nil,
                                      waistCircumferenceCM: parsedWaist ?? nil, on: date, measurementID: targetID, measuredAt: measuredAt) {
            let written = store.log(for: date).bodyMeasurements?.first(where: { $0.id == targetID }) ?? store.log(for: date).bodyWeight
            if let entry = written, entry.kilograms != nil, measurementID == nil {
                Task { await health.writeWeight(entry) }
            }
            dismiss()
        }
        else { error = store.takeMessage(fallback: "测量未保存，请重试。"); store.message = nil }
    }
    private func save(_ value: Double?) {
        guard owner != nil, owner == store.editingAccountID else { error = "账号已变化，请重新打开。"; return }
        guard measurementUnchanged else { error = "这条测量已在其他地方修改，请重新打开后核对。"; return }
        let targetID = measurementID ?? UUID()
        if store.saveBodyMeasurements(kilograms: value, bodyFatPercentage: nil, waistCircumferenceCM: nil, on: date, measurementID: targetID, measuredAt: measuredAt) {
            let written = store.log(for: date).bodyMeasurements?.first(where: { $0.id == targetID }) ?? store.log(for: date).bodyWeight
            if let entry = written, entry.kilograms != nil, measurementID == nil {
                Task { await health.writeWeight(entry) }
            }
            dismiss()
        }
        else { error = store.takeMessage(fallback: "测量未保存，请重试。"); store.message = nil }
    }
}
