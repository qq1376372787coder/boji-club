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
            VStack(alignment: .leading, spacing: 18) {
                dateNavigation
                if !log.meals.isEmpty { AIReferenceEntryButton(reference: .day("meal_day", date: selectedDate, title: ClubDates.key(selectedDate) + " · 当天饮食")) }
                if !pendingBatches.isEmpty {
                    ClubCard {
                        Text("继续未完成的分餐").bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
                        ForEach(pendingBatches) { job in
                            Button { pendingBatch = job } label: {
                                HStack {
                                    let count = job.result?.meals?.filter { !store.hasAppliedAIJob(MealBatchIdentity.sourceID(root: job.id, item: $0.id)) }.count
                                    Text("\(job.request.date) · \(count.map { "\($0) 餐待处理" } ?? "查看分餐结果")").font(.subheadline)
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
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: dynamicTypeSize.isAccessibilitySize ? 2 : 4), spacing: 8) {
                    ForEach(MealCategorySuggestion.categories, id: \.self) { category in
                        Button { recorder = MealEntryRequest(date: selectedDate, category: category) } label: {
                            VStack(spacing: 5) {
                                Text(category).font(.caption.weight(.medium))
                                Text(log.meals.filter { $0.category == category }.isEmpty ? "+ 记录" : "已记 · \(log.meals.filter { $0.category == category }.map(\.calories).reduce(0, +).formatted(.number.precision(.fractionLength(0)))) kcal")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity).padding(.vertical, BojiSpace.general)
                                .background(ClubUI.insetSurface, in: RoundedRectangle(cornerRadius: ClubUI.controlRadius, style: .continuous))
                        }.buttonStyle(ClubMotionButton()).accessibilityLabel("记录\(category)")
                    }
                }
                if log.meals.isEmpty {
                    ClubCard { EmptyNote(title: "这一天还没有餐食记录", detail: "支持拍照识别、语音描述或手动记录。") }
                } else {
                    ForEach(categories.filter { category in log.meals.contains { $0.category == category } }, id: \.self) { category in
                        mealSection(category)
                    }
                }
                if !log.meals.isEmpty {
                    ClubCard {
                        Toggle("\(ClubDates.label(selectedDate))饮食已记完", isOn: Binding(get: { log.mealsComplete }, set: { _ = store.confirmMeals(on: selectedDate, complete: $0) }))
                        Text("确认今日餐食已记全；后续若增改餐食将自动重置此状态。").font(.footnote).foregroundStyle(.secondary)
                        if log.unknownNutritionMeals > 0 { Text("还有营养值未知的餐食，可补填后计入综合周复盘。").font(.footnote).foregroundStyle(.secondary) }
                    }
                }
                DisclosureGroup("目标与营养策略") {
                    NutritionStrategyCard(date: selectedDate).padding(.top, BojiSpace.general)
                }.font(.subheadline).tint(ClubBrand.accent)
                weeklyTrend
            }.padding(ClubUI.pageInset)
        }
        .safeAreaInset(edge: .bottom) {
            Button { recorder = MealEntryRequest(date: selectedDate) } label: {
                Label("记录饮食", systemImage: "plus").frame(maxWidth: .infinity, minHeight: 44)
            }.buttonStyle(PrimaryButton())
                .padding(.horizontal, ClubUI.pageInset).padding(.vertical, BojiSpace.tightRow)
                .background(BojiColor.pageBackground)
        }
        .clubSuccessFeedback("这一餐已保存到本机", trigger: saveFeedback)
        .sensoryFeedback(.success, trigger: saveFeedback)
        .background { ClubBackground() }
        .navigationTitle("饮食").navigationBarTitleDisplayMode(.inline)
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
        } message: { Text("当天营养汇总会随之更新，联网后同步到云端。") }
    }
    @ViewBuilder private var dateNavigation: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 12) {
                DatePicker("饮食日期", selection: $selectedDate, in: ...Date(), displayedComponents: .date)
                    .labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    Button { moveDate(-1) } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(ClubIconButtonStyle()).accessibilityLabel("前一天")
                    Spacer()
                    Button("今天") { selectedDate = Date() }.font(.subheadline.weight(.medium)).buttonStyle(ClubMotionButton())
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
                    Button("今天") { selectedDate = Date() }.font(.subheadline.weight(.medium)).buttonStyle(ClubMotionButton())
                }
        }
    }

    private var dailySummary: some View {
        let carbsTotal = log.knownMeals.reduce(0) { $0 + $1.carbs }
        let fatTotal = log.knownMeals.reduce(0) { $0 + $1.fat }
        return ClubCard {
            HStack(alignment: .firstTextBaseline) {
                Text("这一天，吃得怎么样").font(.title3.weight(.semibold))
                Spacer(minLength: 8)
                Text("已记 \(log.meals.count) 餐").font(.caption).foregroundStyle(.secondary)
            }
            if let target, target.generalGuidanceOnly != true {
                Text("热量参考 \(target.caloriesMin.formatted(.number.precision(.fractionLength(0))))–\(target.caloriesMax.formatted(.number.precision(.fractionLength(0)))) kcal")
                    .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }
            BojiMacroDonut(protein: log.protein, carbs: carbsTotal, fat: fatTotal,
                calorieProgress: (log.mealsComplete && log.knownMeals.count == log.meals.count && target?.generalGuidanceOnly != true && (target?.caloriesMax ?? 0) > 0) ? log.calories / (target?.caloriesMax ?? 1) : nil,
                centerTitle: "已记录热量", centerValue: log.knownMeals.isEmpty ? "—" : "\(log.calories.formatted(.number.precision(.fractionLength(0)))) kcal", size: 216)
                .frame(maxWidth: .infinity).padding(.vertical, 14)
            let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16)) : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
            layout {
                macroMetric("蛋白质", value: log.protein, color: DataPalette134.protein)
                macroMetric("碳水", value: carbsTotal, color: DataPalette134.carbs)
                macroMetric("脂肪", value: fatTotal, color: DataPalette134.fat)
            }
            Text("环图为供能占比 · 蛋白质/碳水每克 4 kcal，脂肪每克 9 kcal。点按色块查看。")
                .font(.caption).foregroundStyle(.secondary)
            if log.mealsComplete && log.knownMeals.count == log.meals.count && target?.generalGuidanceOnly != true && (target?.caloriesMax ?? 0) > 0 {
                Text("内圈为已记录热量相对参考上限的进度，不代表越满越好。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if log.unknownNutritionMeals > 0 {
                Label("另有 \(log.unknownNutritionMeals) 餐待补营养信息，未计入图表。", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func macroMetric(_ name: String, value: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Capsule().fill(color.opacity(0.7)).frame(width: 24, height: 4)
            DataMetric134(title: name, value: log.knownMeals.isEmpty ? "—" : value.formatted(.number.precision(.fractionLength(0...1))), unit: "g")
        }.frame(maxWidth: .infinity, alignment: .leading)
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
            Text("截至所选日期 · 未完整记录不判断达标，参考区间按各日版本核对").font(.caption).foregroundStyle(.secondary)
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
                VStack(alignment: .leading, spacing: 6) {
                    BojiAdaptiveGroup {
                        Text(category).font(.headline)
                        Spacer(minLength: 0)
                        Text(knownMeals.isEmpty ? "营养数据未知" : "\(knownMeals.reduce(0) { $0 + $1.calories }.formatted(.number.precision(.fractionLength(0)))) kcal")
                            .font(.subheadline.monospacedDigit()).foregroundStyle(BojiColor.textSecondary)
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.semibold)).foregroundStyle(BojiColor.textTertiary)
                    }
                    Text(meals.map(\.name).joined(separator: "、"))
                        .font(.footnote).foregroundStyle(BojiColor.textSecondary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                }
                .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("meal-group-" + category)
            .accessibilityLabel("\(category)分组，\(expanded ? "收起" : "展开")")
            .accessibilityHint(meals.map(\.name).joined(separator: "、"))

            if expanded {
                ForEach(meals) { meal in
                    HStack(alignment: .top, spacing: 12) {
                        Button { editing = MealNutritionEditRequest(date: selectedDate, meal: meal) } label: {
                            HStack(alignment: .top, spacing: 12) {
                                MealThumbnail(meal: meal).frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: BojiRadius.inner))
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(meal.name).font(.subheadline.weight(.medium)).multilineTextAlignment(.leading)
                                    Text(meal.hasNutrition ? "\(meal.calories.formatted(.number.precision(.fractionLength(0)))) kcal · 蛋白质 \(meal.protein.formatted(.number.precision(.fractionLength(0...1)))) g" : "营养数据未知 · 点按补填").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                                    Text(meal.estimated == true ? "AI 估算 · 点按修改" : "手动记录 · 点按修改").font(.caption).foregroundStyle(.secondary)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }
                        .buttonStyle(ClubMotionButton())
                        .accessibilityIdentifier("meal-edit-\(meal.id.uuidString)")
                        Button { deleting = MealNutritionEditRequest(date: selectedDate, meal: meal) } label: {
                            Image(systemName: "trash").font(.body).foregroundStyle(.secondary)
                        }
                        .buttonStyle(ClubIconButtonStyle())
                        .accessibilityIdentifier("meal-delete-\(meal.id.uuidString)")
                        .accessibilityLabel("删除\(meal.name)")
                    }.transition(ClubMotion.transition(reduced: reduceMotion))
                }
            }
            Divider().overlay(BojiColor.divider)
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
            Text("同一次识别在不同设备记到了不同日期，当前只计入一餐。选对日期后，其他设备也会同步这个选择。")
                .font(.footnote).foregroundStyle(.secondary)
            ForEach(store.mealPlacementIssues) { issue in
                VStack(alignment: .leading, spacing: 8) {
                    Text(issue.meal.name).font(.subheadline.weight(.semibold))
                    Text("当前记在 \(issue.date)").font(.caption).foregroundStyle(.secondary)
                    ForEach(issue.meal.placementConflictDates ?? [issue.date], id: \.self) { date in
                        Button("确认记在 \(date)") {
                            guard owner != nil, owner == store.editingAccountID else { return }
                            if !store.confirmMealPlacement(issue.id, currentDate: issue.date, destination: date) { error = store.takeMessage() }
                            else { error = nil }
                        }.buttonStyle(SecondaryButton())
                    }
                }
            }
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
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
            else { Image(systemName: "fork.knife").font(.title3).foregroundStyle(.secondary) }
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
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(ClubDates.label(date, format: "yyyy年M月d日")).font(.subheadline.weight(.medium))
                                    Text("\(log.meals.count) 条餐食 · \(log.knownMeals.isEmpty ? "营养数据未知" : "已知蛋白质 \(log.protein.formatted(.number.precision(.fractionLength(0...1)))) g")").font(.caption).foregroundStyle(.secondary)
                                    if log.unknownNutritionMeals > 0 { Text("\(log.unknownNutritionMeals) 餐待补填营养数据").font(.footnote).foregroundStyle(.secondary) }
                                }
                                Spacer()
                                Text(log.knownMeals.isEmpty ? "—" : "\(log.calories.formatted(.number.precision(.fractionLength(0)))) kcal").font(.caption.monospacedDigit())
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
                        Text("营养数值来自估算，可根据实际份量修改。").font(.caption)
                        ForEach(Array((meal.estimateNotes ?? []).enumerated()), id: \.offset) { _, note in Text(note).font(.caption) }
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
    var body: some View {
        if let target = store.log(for: date).nutritionTarget ?? store.state.nutritionTarget {
            ClubCard {
                Text(JourneyCopy.nutritionTitle(target.strategy)).bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
                Text(JourneyCopy.nutritionPurpose(target.strategy)).font(.subheadline).lineSpacing(4)
                if target.generalGuidanceOnly != true {
                    LabeledContent("每日热量参考", value: "\(Int(target.caloriesMin))–\(Int(target.caloriesMax)) 千卡")
                    LabeledContent("每日蛋白质参考", value: "\(Int(target.proteinMin))–\(Int(target.proteinMax)) 克")
                    Text("参考区间仅供日常对照，无需每天严格卡点。").font(.footnote).foregroundStyle(.secondary)
                }
                DisclosureGroup("这个参考怎么来的？") {
                    if target.generalGuidanceOnly != true, let low = target.maintenanceMin, let high = target.maintenanceMax {
                        Text("按身体资料、活动量和训练频率估计，你每天大致消耗 \(Int(low))–\(Int(high)) 千卡。上方参考是在这个基础上结合目标确定的。").font(.subheadline)
                    }
                    Text(target.note).font(.footnote).foregroundStyle(.secondary)
                    NutritionTrendSummary(through: date)
                }
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
            Text("最近两周实测均值：\(before.formatted(.number.precision(.fractionLength(1)))) → \(after.formatted(.number.precision(.fractionLength(1)))) kg；分别有 \(previous.count)、\(recent.count) 次记录。").font(.footnote)
            Text("这不是脂肪或肌肉变化的结论。结合已记完整的饮食、训练表现和饥饿感，在周复盘中检查是否需要调整。").font(.footnote).foregroundStyle(.secondary)
        } else {
            Text("近两周各有至少 3 次体重记录后，将展示双周均值对比。").font(.footnote).foregroundStyle(.secondary)
        }
    }
}

#if DEBUG
enum NutritionAuditFactory {
 static func history(date: Binding<Date>) -> some View { NutritionHistoryView(selectedDate: date) }
 static func editor(date: Date, meal: Meal) -> some View { MealNutritionEditor(date: date, meal: meal) }
}
#endif
