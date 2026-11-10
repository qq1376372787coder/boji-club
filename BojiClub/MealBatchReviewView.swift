import SwiftUI

struct AIBatchMeal: Identifiable, Codable, Equatable {
    var id: String
    var date: String
    var category: String
    var name: String
    var notes: [String]
    var components: [FoodComponent]
    var estimated: Bool
    var calories: Double
    var protein: Double
    var carbs: Double
    var fat: Double
}

struct MealBatchSeed {
    let item: AIBatchMeal
    let sourceID: String
    var invalidOriginalDate: String? = nil
}

enum MealBatchIdentity {
    static func sourceID(root: String, item: String) -> String { "meal-batch/\(root)/\(item)" }
    static func parentID(_ source: String) -> String? {
        let parts = source.split(separator: "/")
        guard parts.count == 3, parts[0] == "meal-batch", UUID(uuidString: String(parts[1])) != nil else { return nil }
        return String(parts[1])
    }
}

private struct SavedBatchMeal {
    let dateKey: String
    let meal: Meal
}

struct MealBatchReviewView: View {
    let jobID: String
    var onFinished: (() -> Void)? = nil
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var ai: AIService
    @Environment(\.dismiss) private var dismiss
    @State private var editing: AIBatchMeal?
    @State private var skipping: AIBatchMeal?
    @State private var owner: Int?
    @State private var message: String?
    @State private var refreshing = false
    private var meals: [AIBatchMeal] { ai.job(jobID)?.result?.meals ?? [] }
    private var canAct: Bool { owner != nil && owner == store.editingAccountID && !store.hasAppliedAIJob(jobID) && ai.job(jobID)?.consumed != true }
    private func token(_ item: AIBatchMeal) -> String { MealBatchIdentity.sourceID(root: jobID, item: item.id) }
    private func handled(_ item: AIBatchMeal) -> Bool { store.hasAppliedAIJob(token(item)) }
    private var remaining: Int { meals.filter { !handled($0) }.count }
    private var savedRecords: [String: SavedBatchMeal] {
        var result: [String: SavedBatchMeal] = [:]
        for (key, log) in store.state.days {
            for meal in log.meals { if let id = meal.sourceAIJobID { result[id] = SavedBatchMeal(dateKey: key, meal: meal) } }
        }
        return result
    }
    var body: some View {
        let saved = savedRecords
        return NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("\(meals.count) 餐已分开 · \(remaining) 餐待处理").bojiFont(.cardTitle, monospacedDigits: true).foregroundStyle(BojiColor.textPrimary)
                    Text("逐餐核对日期、餐别和份量后保存；不需要的可以跳过。关闭后可从饮食页继续，已保存的不会重复登记。")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if let description = ai.job(jobID)?.request.payload["description"]?.string, !description.isEmpty {
                        DisclosureGroup("对照原话，检查是否有遗漏") { Text(description).font(.subheadline).textSelection(.enabled) }
                    }
                    ForEach(Array((ai.job(jobID)?.result?.notes ?? []).enumerated()), id: \.offset) { _, note in
                        Text(note).font(.caption).foregroundStyle(.secondary)
                    }
                    if meals.isEmpty {
                        ContentUnavailableView("暂无可保存的分餐", systemImage: "fork.knife", description: Text("请明确说出吃了哪些食物及餐别；一次最多 6 餐，更多请分批。"))
                        Button(action: refreshResult) {
                            HStack(spacing: 8) {
                                if refreshing { ClubActivityMark(size: 16) }
                                Text(refreshing ? "正在查询结果…" : "查询识别结果")
                            }
                        }.buttonStyle(SecondaryButton()).disabled(refreshing)
                            .accessibilityHint("查询已有识别，不重新发起分析")
                    }
                    ForEach(meals) { item in mealCard(item, saved: saved[token(item)]) }
                    if !meals.isEmpty, remaining == 0 {
                        Button("完成这次分餐记录", action: finishIfComplete).buttonStyle(PrimaryButton()).tint(.primary).disabled(!canAct)
                    }
                }.padding(ClubUI.pageInset)
            }.background { ClubBackground() }
                .navigationTitle("逐餐核对")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("稍后继续") { dismiss() } } }
                .sheet(item: $editing, onDismiss: finishIfComplete) { item in
                    let parsed = ClubDates.date(fromKey: item.date)
                    let usable = parsed.map { !ClubDates.isFuture($0) } == true
                    let date = usable ? (parsed ?? Date()) : Date()
                    MealEditorView(date: date, category: item.category, prefilled: MealBatchSeed(item: item, sourceID: token(item), invalidOriginalDate: usable ? nil : item.date)) { editing = nil }
                }
                .confirmationDialog("跳过这餐？", isPresented: Binding(get: { skipping != nil }, set: { if !$0 { skipping = nil } }), titleVisibility: .visible) {
                    Button("跳过，不登记", role: .destructive) {
                        guard canAct, let item = skipping else { return }
                        if store.handleMealRecognitionIDs([token(item)]) { skipping = nil; finishIfComplete() }
                        else { message = store.takeMessage(fallback: "处理状态未保存，请重试。") }
                    }
                    Button("继续核对", role: .cancel) { skipping = nil }
                } message: { Text("这餐不会进入饮食记录或营养统计，其他餐不受影响。") }
                .alert("分餐记录提示", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                    Button("知道了") { message = nil }
                } message: { Text(message ?? "") }
                .onAppear { owner = store.editingAccountID }
                .onChange(of: store.editingAccountID) { _, value in if value != owner { dismiss() } }
                .task(id: jobID) {
                    guard !refreshing else { return }
                    refreshing = true
                    defer { refreshing = false }
                    await ai.refreshMealBatch(jobID)
                }
        }
    }
    private func refreshResult() {
        guard !refreshing, owner != nil, owner == store.editingAccountID else { return }
        refreshing = true
        Task {
            defer { refreshing = false }
            await ai.refreshMealBatch(jobID)
        }
    }
    private func mealCard(_ item: AIBatchMeal, saved: SavedBatchMeal?) -> some View {
        let done = handled(item)
        let portion = saved?.meal.consumedFraction ?? 1
        let components = saved?.meal.components ?? item.components
        return ClubCard {
            HStack {
                Text("\(saved?.dateKey ?? item.date) · \(saved?.meal.category ?? item.category)").bojiFont(.exerciseName, monospacedDigits: true).foregroundStyle(BojiColor.textPrimary)
                Spacer()
                if done { Label(saved == nil ? "已跳过或已删除" : "已保存", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.secondary) }
            }
            Text(saved?.meal.name ?? item.name).bojiFont(.exerciseName).foregroundStyle(BojiColor.textPrimary)
            Text("估算 \((saved?.meal.calories ?? item.calories).formatted(.number.precision(.fractionLength(0)))) kcal").font(.subheadline)
            if !components.isEmpty || !item.notes.isEmpty {
                DisclosureGroup("食物明细与估算说明 · \(components.count) 项") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(components.enumerated()), id: \.offset) { _, component in
                            Text("\(component.name) \((component.amount * portion).formatted(.number.precision(.fractionLength(0...1))))\(component.unit)")
                                .font(.subheadline)
                        }
                        ForEach(Array(item.notes.enumerated()), id: \.offset) { _, note in
                            Text(note).font(.footnote).foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, BojiSpace.tightRow)
                }
            }
            if !done {
                Text("日期和餐别也可以在核对页修改。已有同类餐食时，本次新增，不覆盖。").font(.footnote).foregroundStyle(.secondary)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { mealActions(item) }
                    VStack(alignment: .leading, spacing: 12) { mealActions(item) }
                }
            }
        }
    }
    @ViewBuilder private func mealActions(_ item: AIBatchMeal) -> some View {
        Button("核对并保存这餐") { editing = item }.buttonStyle(PrimaryButton()).tint(.primary)
            .disabled(!canAct)
        Button("跳过") { skipping = item }.buttonStyle(SecondaryButton()).disabled(!canAct)
    }

    private func finishIfComplete() {
        guard canAct, !meals.isEmpty, remaining == 0 else { return }
        guard store.handleMealRecognitionIDs([jobID]) else { message = store.takeMessage(fallback: "完成状态未保存，请重试。"); return }
        ai.markConsumed(jobID)
        onFinished?(); dismiss()
    }
}
