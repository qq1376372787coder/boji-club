import SwiftUI
import ImageIO
import UIKit

struct NutritionView: View {
    @Binding var selectedDate: Date
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var ai: AIService
    @State private var pendingBatch: AILocalJob?
    private var pendingBatches: [AILocalJob] {
        ai.jobs.filter { $0.request.kind == "food" && $0.request.payload["mode"]?.string == "multiple" &&
            $0.status == "succeeded" && !$0.consumed && !store.hasAppliedAIJob($0.id) && $0.result?.meals?.isEmpty != true }
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var saveFeedback = 0
    @State private var recorder: MealEntryRequest?
    @State private var showHistory = false
    @State private var expandedMeals: Set<String> = []
    @State private var editing: MealNutritionEditRequest?
    @State private var deleting: MealNutritionEditRequest?
    private var log: DayLog { store.log(for: selectedDate) }
    private var target: NutritionTarget? { store.nutritionTarget(on: selectedDate) }
    private var categories: [String] {
        MealCategorySuggestion.categories + Set(log.meals.map(\.category)).subtracting(MealCategorySuggestion.categories).sorted()
    }
    private var recentDays: [Date] {
        (-6...0).compactMap { ClubDates.calendar.date(byAdding: .day, value: $0, to: selectedDate) }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BojiLayout.cardInset) {
                dateNavigation
                if !log.meals.isEmpty { AIReferenceEntryButton(reference: .day("meal_day", date: selectedDate, title: ClubDates.key(selectedDate) + " · 当天饮食")) }
                if !pendingBatches.isEmpty {
                    ClubCard {
                        Text("继续分餐").bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
                        ForEach(pendingBatches) { job in
                            Button { pendingBatch = job } label: {
                                HStack {
                                    let count = job.result?.meals?.filter { !store.hasAppliedAIJob(MealBatchIdentity.sourceID(root: job.id, item: $0.id)) }.count
                                    Text("\(job.request.date) · \(count.map { "\($0) 餐待处理" } ?? "查看分餐结果")").bojiType(.secondary)
                                    Spacer(); Image(systemName: "chevron.right")
                                }
                            }.buttonStyle(ClubActionButtonStyle(kind: .row)).tint(.primary)
                        }
                    }
                }
                dailySummary
                ClubContextualInsightStrip(date: selectedDate, kinds: [.nutrition])
                if !store.mealPlacementIssues.isEmpty { MealPlacementReviewCard() }
                HStack {
                    Text("这一天的餐食").bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
                    Spacer()
                    Button { showHistory = true } label: { Label("历史", systemImage: "clock.arrow.circlepath") }.buttonStyle(SecondaryButton())
                }
                ClubCard {
                    VStack(spacing: 0) {
                        ForEach(categories, id: \.self) { category in
                            mealRowOrSection(category)
                            if category != categories.last {
                                Divider().overlay(BojiColor.divider)
                            }
                        }
                    }
                }
                if !log.meals.isEmpty {
                    ClubCard {
                        Toggle("标记今日餐食已记全", isOn: Binding(get: { log.mealsComplete }, set: { _ = store.confirmMeals(on: selectedDate, complete: $0) }))
                        if log.unknownNutritionMeals > 0 { Text("有餐食未估算热量，补填后计入本周总结。").bojiType(.label).foregroundStyle(BojiColor.textSecondary) }
                    }
                }
                DisclosureGroup("目标与营养策略") {
                    NutritionStrategyCard(date: selectedDate).padding(.top, BojiSpace.general)
                }.bojiType(.secondary).tint(ClubBrand.accent)
                // 蓝图 §六：7 日柱图移出本页（批 3 随「看结果」落位），本页只回答今天。
            }.padding(ClubUI.pageInset)
        }
        // BUG-021：底部主操作单一玻璃胶囊（B1 规格 54pt，safeAreaInset 自动为列表留位），
        // 去掉「黑钮 + 玻璃条」双层叠放与重复内边距
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button { recorder = MealEntryRequest(date: selectedDate) } label: {
                Text("记一餐")
                    .frame(maxWidth: .infinity, minHeight: BojiLayout.actionHeight)
            }
            .clubNativeGlassButton(prominent: true)
            .padding(.horizontal, BojiSpace.pageInset)
            .padding(.bottom, BojiLayout.tight)
        }
        .clubSuccessFeedback("已保存到本机", trigger: saveFeedback)
        .sensoryFeedback(.success, trigger: saveFeedback)
        .background { ClubBackground() }
        .navigationTitle("今天吃了").navigationBarTitleDisplayMode(.inline)
        .onAppear { if ClubDates.isFuture(selectedDate) { selectedDate=Date() } }
        .sheet(item: $recorder) { request in MealEditorView(date: request.date, category: request.category) { saveFeedback &+= 1 } }
        .sheet(item: $pendingBatch) { job in MealBatchReviewView(jobID: job.id) { saveFeedback &+= 1 } }
        .sheet(isPresented: $showHistory) { NutritionHistoryView(selectedDate: $selectedDate) }
        .sheet(item: $editing) { request in MealNutritionEditor(date: request.date, meal: request.meal) }
        .confirmationDialog("删除这条饮食记录？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("删除记录", role: .destructive) {
                BojiHaptics.warning()
                if let request = deleting { store.removeMeal(request.meal.id, on: request.date) }; deleting = nil
            }
        } message: { Text("营养汇总已更新，联网后同步。") }
    }
    @ViewBuilder private var dateNavigation: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: BojiLayout.rowGap) {
                DatePicker("饮食日期", selection: $selectedDate, in: ...Date(), displayedComponents: .date)
                    .labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    Button { moveDate(-1) } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(ClubIconButtonStyle()).accessibilityLabel("前一天")
                    Spacer()
                    Button("今天") { selectedDate = Date() }.bojiType(.secondary).buttonStyle(ClubMotionButton())
                    Spacer()
                    Button { moveDate(1) } label: { Image(systemName: "chevron.right") }
                        .buttonStyle(ClubIconButtonStyle()).disabled(ClubDates.calendar.isDateInToday(selectedDate)).accessibilityLabel("后一天")
                }
            }
        } else {
HStack {
                    Button { moveDate(-1) } label: { Image(systemName: "chevron.left") }.buttonStyle(ClubIconButtonStyle()).accessibilityLabel("前一天")
                    DatePicker("饮食日期", selection: $selectedDate, in: ...Date(), displayedComponents: .date).labelsHidden().frame(maxWidth: .infinity)
                    Button { moveDate(1) } label: { Image(systemName: "chevron.right") }.buttonStyle(ClubIconButtonStyle()).disabled(ClubDates.calendar.isDateInToday(selectedDate)).accessibilityLabel("后一天")
                    Button("今天") { selectedDate = Date() }.bojiType(.secondary).buttonStyle(ClubMotionButton())
                }
        }
    }

    /// §六 饮食（2026-11-09 推倒重来）：巨号「今天吃了多少」+ 6pt 细线进度 + 三行宏量小进度。
    /// 空值不摆 0（P0-3）：没记录只给引导不给假数字。环形甜甜圈已删（横条更易读）。
    private var dailySummary: some View {
        let calMax = (target?.generalGuidanceOnly != true) ? (target?.caloriesMax ?? 0) : 0
        return Group {
            if log.knownMeals.isEmpty {
                VStack(alignment: .leading, spacing: BojiLayout.tight) {
                    Text("今天还没记餐")
                        .bojiType(.section)
                        .foregroundStyle(BojiColor.textPrimary)
                    Text("记一餐，就能看到吃了多少、还差多少。")
                        .bojiType(.body15)
                        .foregroundStyle(BojiColor.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, BojiLayout.blockGap)
            } else {
                VStack(alignment: .leading, spacing: BojiLayout.rowGap) {
                    HStack(alignment: .firstTextBaseline, spacing: BojiLayout.tight) {
                        BojiEditorialNumber(value: "\(Int(log.calories))")
                        if calMax > 0 {
                            Text("/ \(Int(calMax)) 千卡")
                                .bojiType(.data)
                                .foregroundStyle(BojiColor.textTertiary)
                        } else {
                            Text("千卡")
                                .bojiType(.data)
                                .foregroundStyle(BojiColor.textTertiary)
                        }
                    }
                    if calMax > 0 {
                        let ratio = min(1, log.calories / calMax)
                        HStack(spacing: BojiLayout.inline) {
                            ProgressView(value: ratio)
                                .tint(ClubBrand.accent)
                                .frame(height: 6)
                                .accessibilityLabel("摄入热量进度")
                            Text("\(Int((ratio * 100).rounded()))%")
                                .bojiType(.caption, monospacedDigits: true)
                                .foregroundStyle(BojiColor.textSecondary)
                        }
                    }
                    macroBarRow(name: "蛋白", value: log.protein, max: target?.proteinMax ?? 0, color: BojiColor.macroProtein)
                    macroBarRow(name: "碳水", value: log.carbs, max: carbsMax, color: BojiColor.macroCarbs)
                    macroBarRow(name: "脂肪", value: log.fat, max: target?.fatMax ?? 0, color: BojiColor.macroFat)
                    if let target, target.generalGuidanceOnly != true, target.caloriesMax > 0 {
                        let remaining = target.caloriesMax - log.calories
                        Text(remaining >= 0 ? "距上限参考还剩约 \(Int(remaining.rounded())) 千卡" : "超出上限参考约 \(Int((-remaining).rounded())) 千卡")
                            .bojiType(.caption)
                            .foregroundStyle(remaining >= 0 ? BojiColor.textSecondary : BojiColor.timerAccent)
                    }
                }
            }
        }
    }

    /// 碳水参考上限：热量上限扣除蛋白与脂肪后的余量折算（克）。
    private var carbsMax: Double {
        guard let target, target.generalGuidanceOnly != true, target.caloriesMax > 0 else { return 0 }
        return max(0, (target.caloriesMax - target.proteinMin * 4 - target.fatMin * 9) / 4)
    }

    /// 宏量三行小进度（§六）：名称与读数 T5，细条压在行下。
    private func macroBarRow(name: String, value: Double, max maxValue: Double, color: Color) -> some View {
        VStack(spacing: BojiLayout.tight) {
            HStack {
                Text(name)
                    .bojiType(.caption)
                    .foregroundStyle(BojiColor.textSecondary)
                Spacer()
                Text(maxValue > 0
                     ? "\(Int(value.rounded())) / \(Int(maxValue.rounded())) 克"
                     : "\(Int(value.rounded())) 克")
                    .bojiType(.caption, monospacedDigits: true)
                    .foregroundStyle(BojiColor.textSecondary)
            }
            ProgressView(value: maxValue > 0 ? min(1, value / maxValue) : 0)
                .tint(color)
                .frame(height: 3)
        }
    }

    private func macroMetric(_ name: String, value: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: BojiLayout.tight) {
            HStack(spacing: BojiLayout.tight) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(name)
                    .bojiType(.caption)
                    .foregroundStyle(BojiColor.textSecondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(log.knownMeals.isEmpty ? "—" : value.formatted(.number.precision(.fractionLength(0...1))))
                    .bojiType(.body)
                    .foregroundStyle(BojiColor.textPrimary)
                Text("g")
                    .bojiType(.caption)
                    .foregroundStyle(BojiColor.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(BojiLayout.inline)
        .background(BojiColor.inputSurface, in: RoundedRectangle(cornerRadius: BojiRadius.control, style: .continuous))
    }

    private var weeklyTrend: some View {
        let bars = recentDays.map { date in
            let day = store.log(for: date)
            return BojiBarTrendChart.Bar(
                date: date,
                value: day.knownMeals.isEmpty ? nil : day.calories,
                metGoal: DashboardMetricProvider.nutritionStatus(day, target: store.nutritionTarget(on: date))
            )
        }
        return ClubCard {
            HStack {
                Text("近 7 天热量").bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
                Spacer()
            }
            BojiBarTrendChart(bars: bars, target: nil, unit: "kcal")
            Text("按日摄入对比 · 缺卡日期保持留白").bojiType(.caption).foregroundStyle(.secondary)
        }
    }

    private func categoryIcon(_ category: String) -> String {
        switch category {
        case "早餐": return "sun.horizon.fill"
        case "午餐": return "sun.max.fill"
        case "晚餐": return "moon.stars.fill"
        default: return "cup.and.saucer.fill"
        }
    }

    @ViewBuilder
    private func mealRowOrSection(_ category: String) -> some View {
        let meals = log.meals.filter { $0.category == category }
        if !meals.isEmpty {
            mealSection(category)
        } else {
            HStack(spacing: BojiLayout.rowGap) {
                Image(systemName: categoryIcon(category))
                    .bojiType(.secondary)
                    .foregroundStyle(BojiColor.textTertiary)
                    .frame(width: 32, height: 32)
                    .background(BojiColor.inputSurface, in: Circle())
                VStack(alignment: .leading, spacing: 0) {
                    Text(category).bojiType(.secondary)
                    Text("未记录").bojiType(.caption).foregroundStyle(BojiColor.textTertiary)
                }
                Spacer()
                Button {
                    BojiHaptics.light()
                    recorder = MealEntryRequest(date: selectedDate, category: category)
                } label: {
                    HStack(spacing: BojiLayout.tight) {
                        Image(systemName: "plus")
                        Text("记录")
                    }
                    .bojiType(.caption)
                    .foregroundStyle(BojiColor.textPrimary)
                    .padding(.horizontal, BojiLayout.inline).padding(.vertical, BojiLayout.tight)
                    .background(BojiColor.inputSurface, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, BojiLayout.inline)
        }
    }

    private func mealSection(_ category: String) -> some View {
        let meals = log.meals.filter { $0.category == category }
        let knownMeals = meals.filter(\.hasNutrition)
        let expanded = expandedMeals.contains(category)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: reduceMotion ? 0 : 0.2)) {
                    if expanded { expandedMeals.remove(category) } else { expandedMeals.insert(category) }
                }
            } label: {
                HStack(alignment: .center, spacing: BojiLayout.rowGap) {
                    Image(systemName: categoryIcon(category))
                        .bojiType(.secondary)
                        .foregroundStyle(BojiColor.timerAccent)
                        .frame(width: 32, height: 32)
                        .background(BojiColor.inputSurface, in: Circle())
                    VStack(alignment: .leading, spacing: BojiLayout.tight) {
                        HStack {
                            Text(category).bojiType(.secondary)
                            Spacer()
                            Text(knownMeals.isEmpty ? "已记录" : "\(knownMeals.reduce(0) { $0 + $1.calories }.formatted(.number.precision(.fractionLength(0)))) kcal")
                                .bojiType(.secondary)
                                .foregroundStyle(BojiColor.textPrimary)
                            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                                .bojiType(.caption)
                                .foregroundStyle(BojiColor.textTertiary)
                        }
                        Text(meals.map(\.name).joined(separator: "、"))
                            .bojiType(.caption)
                            .foregroundStyle(BojiColor.textSecondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                .padding(.vertical, BojiLayout.inline)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("meal-group-" + category)
            .accessibilityLabel("\(category)分组，\(expanded ? "收起" : "展开")")
            .accessibilityHint(meals.map(\.name).joined(separator: "、"))

            if expanded {
                ForEach(Array(meals.enumerated()), id: \.element.id) { index, meal in
                    HStack(alignment: .top, spacing: BojiLayout.rowGap) {
                        Button { editing = MealNutritionEditRequest(date: selectedDate, meal: meal) } label: {
                            HStack(alignment: .top, spacing: BojiLayout.rowGap) {
                                MealThumbnail(meal: meal).frame(width: 52, height: 52).clipShape(RoundedRectangle(cornerRadius: BojiRadius.inner))
                                VStack(alignment: .leading, spacing: BojiLayout.tight) {
                                    Text(meal.name).bojiType(.secondary).multilineTextAlignment(.leading)
                                    Text(meal.hasNutrition ? "\(meal.calories.formatted(.number.precision(.fractionLength(0)))) kcal · 蛋白质 \(meal.protein.formatted(.number.precision(.fractionLength(0...1)))) g" : "点按补填营养数据").bojiType(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }
                        .buttonStyle(ClubMotionButton())
                        .accessibilityIdentifier("meal-edit-\(meal.id.uuidString)")
                        Button { deleting = MealNutritionEditRequest(date: selectedDate, meal: meal) } label: {
                            Image(systemName: "trash").bojiType(.secondary).foregroundStyle(.secondary)
                        }
                        .buttonStyle(ClubIconButtonStyle())
                        .accessibilityIdentifier("meal-delete-\(meal.id.uuidString)")
                        .accessibilityLabel("删除\(meal.name)")
                    }
                    .padding(.vertical, BojiLayout.tight)
                    // 细线列表（甲-3）：行间 0.5pt 发丝线，末行不加、交容器底线——块间不叠双线
                    .overlay(alignment: .bottom) {
                        if index < meals.count - 1 {
                            Rectangle().fill(BojiColor.divider).frame(height: BojiLayout.hairline)
                        }
                    }
                    .transition(ClubMotion.transition(reduced: reduceMotion))
                }
            }
        }.clubMotion(value: meals.map(\.id))
    }
    private func moveDate(_ offset: Int) {
        if let next = ClubDates.calendar.date(byAdding:.day,value:offset,to:selectedDate), !ClubDates.isFuture(next) { selectedDate=next }
    }
}

private struct MealPlacementReviewCard: View {
    @EnvironmentObject private var store: AppStore
    @State private var owner: Int?
    @State private var error: String?
    var body: some View {
        ClubCard {
            Text("核对跨设备餐食日期").bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
            Text("识别结果在不同设备记到了不同日期，目前只计入一餐。选择日期后，其他设备会同步。")
                .bojiType(.label).foregroundStyle(.secondary)
            ForEach(store.mealPlacementIssues) { issue in
                VStack(alignment: .leading, spacing: BojiLayout.inline) {
                    Text(issue.meal.name).bojiType(.secondary)
                    Text("当前记在 \(issue.date)").bojiType(.caption).foregroundStyle(.secondary)
                    ForEach(issue.meal.placementConflictDates ?? [issue.date], id: \.self) { date in
                        Button("确认记在 \(date)") {
                            guard owner != nil, owner == store.editingAccountID else { return }
                            if !store.confirmMealPlacement(issue.id, currentDate: issue.date, destination: date) { error = store.takeMessage() }
                            else { error = nil }
                        }.buttonStyle(SecondaryButton())
                    }
                }
            }
            if let error { Text(error).bojiType(.label).foregroundStyle(.red) }
        }.onAppear { owner = store.editingAccountID }
            .disabled(owner == nil || owner != store.editingAccountID)
    }
}

private struct MealNutritionEditRequest: Identifiable {
    let id = UUID()
    let date: Date
    let meal: Meal
}

private struct MealThumbnail: View {
    let meal: Meal
    @EnvironmentObject private var store: AppStore
    @State private var image: UIImage?
    var body: some View {
        ZStack {
            BojiColor.textPrimary.opacity(0.04)
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { Image(systemName: "fork.knife").bojiType(.section).foregroundStyle(.secondary) }
        }.clipped()
            .task(id: "\(meal.photoFilename ?? "")-\(store.photoChangeID)") {
                guard let file = store.photoFile(for: meal) else { image = nil; return }
                let thumbnail = await Task.detached(priority: .utility) { () -> CGImage? in
                    guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
                    let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 192, kCGImageSourceCreateThumbnailWithTransform: true]
                    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
                }.value
                guard !Task.isCancelled else { return }; image = thumbnail.map { UIImage(cgImage: $0) }
            }
    }
}

private struct NutritionHistoryView: View {
    @Binding var selectedDate: Date
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    private var dates: [String] { store.state.days.keys.filter { !(store.state.days[$0]?.meals.isEmpty ?? true) }.sorted(by: >) }
    var body: some View {
        NavigationStack {
            List {
                if dates.isEmpty { ContentUnavailableView("还没有饮食记录", systemImage: "fork.knife", description: Text("保存第一餐后，可以在这里回看。")) }
                ForEach(dates, id: \.self) { key in
                    if let date = ClubDates.date(fromKey: key), let log = store.state.days[key] {
                        Button { selectedDate = date; dismiss() } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: BojiLayout.tight) {
                                    Text(ClubDates.label(date, format: "yyyy年M月d日")).bojiType(.secondary)
                                    Text("\(log.meals.count) 条餐食 · \(log.knownMeals.isEmpty ? "营养数据未知" : "已知蛋白质 \(log.protein.formatted(.number.precision(.fractionLength(0...1)))) g")").bojiType(.caption).foregroundStyle(.secondary)
                                    if log.unknownNutritionMeals > 0 { Text("\(log.unknownNutritionMeals) 餐待补填营养数据").bojiType(.label).foregroundStyle(.secondary) }
                                }
                                Spacer()
                                Text(log.knownMeals.isEmpty ? "—" : "\(log.calories.formatted(.number.precision(.fractionLength(0)))) kcal").bojiType(.caption)
                            }
                        }.buttonStyle(ClubActionButtonStyle(kind: .row)).tint(ClubBrand.accent)
                    }
                }
            }.clubListSurface().navigationTitle("饮食历史").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}

private struct MealNutritionEditor: View {
    let date: Date
    @State var meal: Meal
    @State private var items: [FoodComponent]
    @State private var fraction: Double
    @State private var photo: Data?
    /// Snapshot at open time; only fields changed from this base are written.
    private let original: Meal
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    @State private var confirmUnknown = false
    @State private var portionInputsValid = true
    init(date: Date, meal: Meal) {
        self.date = date
        self.original = meal
        _meal = State(initialValue: meal)
        _items = State(initialValue: meal.components ?? [])
        _fraction = State(initialValue: meal.consumedFraction ?? 1)
    }
    private var categories: [String] { Array(Set(["早餐", "午餐", "晚餐", "加餐", meal.category])).sorted() }
    private func total(_ key: KeyPath<FoodComponent, Double>, fallback: Double) -> Double {
        FoodComponent.total(key, components: items, fraction: fraction, fallback: fallback)
    }
    private var valid: Bool {
        portionInputsValid && !meal.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && meal.name.count <= 100 && items.allSatisfy(\.valid) &&
        [total(\.calories, fallback: meal.calories), total(\.protein, fallback: meal.protein), total(\.carbs, fallback: meal.carbs), total(\.fat, fallback: meal.fat)].allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 100000 }
    }
    var body: some View {
        NavigationStack {
            Form {
                if let photo { Section { FoodCutoutView(data: photo) }.listRowInsets(EdgeInsets()) }
                Section("\(ClubDates.label(date)) · 餐食信息") {
                    TextField("名称", text: $meal.name, axis: .vertical).lineLimit(1...4).accessibilityIdentifier("meal-name-field")
                    Picker("餐次", selection: $meal.category) { ForEach(categories, id: \.self) { Text($0).tag($0) } }
                    if items.isEmpty {
                        amount("热量 kcal", $meal.calories); amount("蛋白质 g", $meal.protein)
                        amount("碳水 g", $meal.carbs); amount("脂肪 g", $meal.fat)
                    } else {
                        LabeledContent("热量", value: "\(total(\.calories, fallback: meal.calories).formatted(.number.precision(.fractionLength(0)))) kcal")
                        LabeledContent("蛋白质", value: "\(total(\.protein, fallback: meal.protein).formatted(.number.precision(.fractionLength(0...1)))) g")
                        LabeledContent("碳水", value: "\(total(\.carbs, fallback: meal.carbs).formatted(.number.precision(.fractionLength(0...1)))) g")
                        LabeledContent("脂肪", value: "\(total(\.fat, fallback: meal.fat).formatted(.number.precision(.fractionLength(0...1)))) g")
                    }
                }
                if !items.isEmpty { Section("食物明细") { FoodCompositionEditor(items: $items, fraction: $fraction, editingValid: $portionInputsValid) } }
                if meal.estimated == true {
                    Section("需要你确认") {
                        Text("营养数值来自估算，可根据实际份量修改。").bojiType(.caption)
                        ForEach(Array((meal.estimateNotes ?? []).enumerated()), id: \.offset) { _, note in Text(note).bojiType(.caption) }
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }.clubGroupedSurface().navigationTitle("餐食详情").navigationBarTitleDisplayMode(.inline)
                .task { photo = store.photoData(for: meal) }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            if [total(\.calories,fallback:meal.calories),total(\.protein,fallback:meal.protein),total(\.carbs,fallback:meal.carbs),total(\.fat,fallback:meal.fat)].contains(where:{$0>0}) { save(unknown:false) }
                            else { confirmUnknown=true }
                        }.disabled(!valid)
                    }
                }
                .confirmationDialog("这餐还没有营养数据",isPresented:$confirmUnknown,titleVisibility:.visible) {
                    Button("保存并标记营养数据未知") { save(unknown:true) }
                    Button("继续填写",role:.cancel) { }
                }
        }
    }
    private func save(unknown: Bool) {
        meal.name=meal.name.trimmingCharacters(in:.whitespacesAndNewlines)
        meal.calories=total(\.calories,fallback:meal.calories);meal.protein=total(\.protein,fallback:meal.protein)
        meal.carbs=total(\.carbs,fallback:meal.carbs);meal.fat=total(\.fat,fallback:meal.fat)
        meal.components=items.isEmpty ? nil : items;meal.consumedFraction=items.isEmpty ? nil : fraction
        meal.nutritionKnown = !unknown
        if store.updateMealNutrition(meal, base: original, on: date) { dismiss() } else { error=store.takeMessage(fallback: "保存失败，请稍后重试。") }
    }
    private func amount(_ title: String, _ value: Binding<Double>) -> some View {
        HStack { Text(title); Spacer(); TextField("0", value: value, format: .number.precision(.fractionLength(0...1))).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 110).accessibilityLabel(title) }
    }
}


struct NutritionStrategyCard: View {
    @State private var reviewingTarget = false
    let date: Date
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var account: AccountService
    var body: some View {
        if let target = store.log(for: date).nutritionTarget ?? store.state.nutritionTarget {
            ClubCard {
                Text(JourneyCopy.nutritionTitle(target.strategy)).bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
                Text(JourneyCopy.nutritionPurpose(target.strategy)).bojiType(.secondary).lineSpacing(4)
                if target.generalGuidanceOnly != true {
                    LabeledContent("每日热量参考", value: "\(Int(target.caloriesMin))–\(Int(target.caloriesMax)) kcal")
                    LabeledContent("每日蛋白质参考", value: "\(Int(target.proteinMin))–\(Int(target.proteinMax)) g")
                    Text("参考区间仅供日常对照，无需每天严格卡点。").bojiType(.label).foregroundStyle(.secondary)
                }
                DisclosureGroup("这个参考怎么来的？") {
                    if target.generalGuidanceOnly != true, let low = target.maintenanceMin, let high = target.maintenanceMax {
                        Text("按身体资料、活动量和训练频率估计，你每天大致消耗 \(Int(low))–\(Int(high)) kcal。上方参考是在这个基础上结合目标确定的。").bojiType(.secondary)
                    }
                    Text(target.note).bojiType(.label).foregroundStyle(.secondary)
                    NutritionTrendSummary(through: date)
                }
                Button("更新资料与饮食参考") { reviewingTarget = true }.buttonStyle(SecondaryButton())
            // 拍板 #5：原入口指向记忆页（ClubAIMemoryView），与按钮文案「更新资料」不符，
            // 且记忆页浏览入口已下线。改为直开资料表单——饮食参考由
            // 身体资料 + 活动量 + 营养背景三项决定，正是 nutrition_goal 任务字段。
            }.sheet(isPresented: $reviewingTarget) {
                ProfileFactsForm133(title: "更新资料与饮食参考", fields: ProfileFields133.task(.nutritionGoal))
            }
        }
    }
}
private struct NutritionTrendSummary: View {
    let through: Date
    @EnvironmentObject private var store: AppStore
    var body: some View {
        let points = store.bodyWeightPoints(through: through).filter { (ClubDates.calendar.dateComponents([.day], from: $0.date, to: through).day ?? 99) < 14 }
        let recent = points.filter { (ClubDates.calendar.dateComponents([.day], from: $0.date, to: through).day ?? 99) < 7 }
        let previous = points.filter { (ClubDates.calendar.dateComponents([.day], from: $0.date, to: through).day ?? 99) >= 7 }
        if recent.count >= 3 && previous.count >= 3 {
            let before = previous.reduce(0) { $0 + $1.kilograms } / Double(previous.count)
            let after = recent.reduce(0) { $0 + $1.kilograms } / Double(recent.count)
            Text("最近两周实测均值：\(before.formatted(.number.precision(.fractionLength(1)))) → \(after.formatted(.number.precision(.fractionLength(1)))) kg；分别有 \(previous.count)、\(recent.count) 次记录。").bojiType(.label)
            Text("这还不是脂肪或肌肉变化的结论。把饮食、训练和饥饿感记完整，周回顾时再看要不要调。").bojiType(.label).foregroundStyle(.secondary)
        } else {
            Text("近两周各有至少 3 次体重记录后，将展示双周均值对比。").bojiType(.label).foregroundStyle(.secondary)
        }
    }
}

#if DEBUG
enum NutritionAuditFactory {
 static func history(date: Binding<Date>) -> some View { NutritionHistoryView(selectedDate: date) }
 static func editor(date: Date, meal: Meal) -> some View { MealNutritionEditor(date: date, meal: meal) }
}
#endif
