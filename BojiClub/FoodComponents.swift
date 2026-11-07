import SwiftUI

struct FoodComponent: Identifiable, Codable, Equatable {
    var id: String = UUID().uuidString
    var name: String
    var amount: Double
    var unit: String
    var calories: Double
    var protein: Double
    var carbs: Double
    var fat: Double
    var basis: String
    var details: [String]
    // Phase 3 evidence chain (optional for backward compatibility).
    var sourceKind: String? = nil
    var sourceRef: String? = nil
    var sourceDatabase: String? = nil
    var sourceVersion: String? = nil
    var confidenceLow: Double? = nil
    var confidenceHigh: Double? = nil
    var edibleGrams: Double? = nil
    var uncertaintyFlags: [String]? = nil
    var requiresReview: Bool? = nil
    var nutritionEngine: String? = nil

    /// Both meal entry and later editing use this derived total.
    static func total(_ key: KeyPath<FoodComponent, Double>, components: [FoodComponent],
                      fraction: Double, fallback: Double) -> Double {
        components.isEmpty ? fallback : components.reduce(0) { $0 + $1[keyPath: key] } * fraction
    }

    var valid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && amount > 0 &&
        [amount, calories, protein, carbs, fat].allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 10000 }
    }
    mutating func resize(to value: Double) {
        guard value.isFinite, value > 0, value <= 10000, amount > 0 else { return }
        let ratio = value / amount
        calories *= ratio; protein *= ratio; carbs *= ratio; fat *= ratio
        confidenceLow = confidenceLow.map { $0 * ratio }
        confidenceHigh = confidenceHigh.map { $0 * ratio }
        edibleGrams = edibleGrams.map { $0 * ratio }
        amount = value
    }

    mutating func rename(to value: String) {
        guard value.trimmingCharacters(in: .whitespacesAndNewlines) != name.trimmingCharacters(in: .whitespacesAndNewlines) else { name = value; return }
        name = value
        calories = 0; protein = 0; carbs = 0; fat = 0
        sourceKind = "estimate"; sourceRef = nil; sourceDatabase = nil; sourceVersion = nil
        confidenceLow = nil; confidenceHigh = nil; edibleGrams = nil; nutritionEngine = nil
        uncertaintyFlags = ["identity_changed_needs_rematch", "nutrition_unknown"]
        requiresReview = true
        details = ["名称已修改，请重新识别或填写这项食物的营养值。"]
    }

    mutating func editNutrient(_ key: WritableKeyPath<FoodComponent, Double>, value: Double) {
        self[keyPath: key] = value
        sourceKind = "user_input"; sourceRef = nil; sourceDatabase = nil; sourceVersion = nil
        confidenceLow = nil; confidenceHigh = nil; nutritionEngine = nil
        uncertaintyFlags = ["manual_nutrient_entry"]
        requiresReview = true
    }
}

struct FoodCompositionEditor: View {
    @Binding var items: [FoodComponent]
    @Binding var fraction: Double
    @Binding var editingValid: Bool
    @State private var invalidAmounts: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: BojiLayout.blockGap) {
            Text("实际吃了多少").bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
            Picker("你吃了这份食物的多少？", selection: $fraction) {
                Text("全部").tag(1.0); Text("3/4").tag(0.75)
                Text("1/2").tag(0.5); Text("1/4").tag(0.25)
                if fraction.isFinite, fraction > 0, fraction <= 1, ![1.0, 0.75, 0.5, 0.25].contains(fraction) {
                    Text("\(Int(fraction * 100))%").tag(fraction)
                }
            }.clubAdaptivePicker()
            Text("按整份估算份量，并选择实际食用比例。")
                .bojiFont(.label).foregroundStyle(BojiColor.textSecondary)
            ForEach($items) { $item in
                DisclosureGroup {
                    VStack(spacing: BojiLayout.rowGap) {
                        TextField("食物名称", text: Binding(get: { item.name }, set: { item.rename(to: $0) }))
                        HStack {
                            Text("整份份量")
                            Spacer()
                            FoodPortionField(item: $item) { valid in
                                if valid { invalidAmounts.remove(item.id) } else { invalidAmounts.insert(item.id) }
                                editingValid = invalidAmounts.isEmpty
                            }
                            Text(item.unit).foregroundStyle(.secondary)
                        }
                        nutrient("热量 kcal", value: Binding(get: { item.calories }, set: { item.editNutrient(\.calories, value: $0) }))
                        nutrient("蛋白质 g", value: Binding(get: { item.protein }, set: { item.editNutrient(\.protein, value: $0) }))
                        nutrient("碳水 g", value: Binding(get: { item.carbs }, set: { item.editNutrient(\.carbs, value: $0) }))
                        nutrient("脂肪 g", value: Binding(get: { item.fat }, set: { item.editNutrient(\.fat, value: $0) }))
                        ForEach(Array(item.details.enumerated()), id: \.offset) { _, detail in
                            Text(detail).bojiType(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if let flags = item.uncertaintyFlags, !flags.isEmpty {
                            Text("需确认：" + flags.map(uncertaintyLabel).joined(separator: "、"))
                                .bojiType(.caption).foregroundStyle(.orange)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if let database = item.sourceDatabase, !database.isEmpty {
                            Text("营养来源：" + (database == "USDA_FDC_SR_LEGACY" ? "USDA 食物成分参考库" : "参考营养库") + (item.sourceVersion.map { " · " + $0 } ?? ""))
                                .bojiType(.caption).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if let low = item.confidenceLow, let high = item.confidenceHigh, low != high {
                            Text("估算区间：\((low * fraction).formatted(.number.precision(.fractionLength(0))))–\((high * fraction).formatted(.number.precision(.fractionLength(0)))) kcal")
                                .bojiType(.caption).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Button("移除这项食物", role: .destructive) { items.removeAll { $0.id == item.id } }
                            .buttonStyle(DestructiveButton()).disabled(items.count <= 1)
                    }.padding(.top, BojiSpace.workoutCardInset)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: BojiLayout.tight) {
                            Text(item.name.isEmpty ? "新增食物" : item.name).bojiType(.secondary)
                            Text("\(item.amount.formatted(.number.precision(.fractionLength(0...1)))) \(item.unit) · \(item.basis == "assumed" ? "按常见做法估算" : item.basis == "user" ? "手动填写" : item.basis == "described" ? "文字描述 · 营养估算" : "照片识别 · 份量估算")")
                                .bojiType(.caption).foregroundStyle(.secondary)
                            if item.requiresReview == true {
                                Text("来源/份量待确认").bojiType(.caption).foregroundStyle(.orange)
                            }
                        }
                        Spacer()
                        Text("\((item.calories * fraction).formatted(.number.precision(.fractionLength(0)))) kcal")
                            .bojiType(.caption)
                    }
                }.tint(.primary)
                Divider()
            }
            Menu {
                Button("补充食物或酱汁") { add(oil: false) }
                Button("补充食用油（默认 5 g，可修改）") { add(oil: true) }
            } label: { Label("补充食物 / 油 / 酱汁", systemImage: "plus.circle") }
                .buttonStyle(SecondaryButton())
                .disabled(items.count >= 20)
            Text("补充前确认原有条目是否已包含油或酱汁，避免重复计算。手动添加项需填写营养数据。")
                .bojiType(.caption).foregroundStyle(.secondary)
        }.onAppear {
            if !fraction.isFinite || fraction <= 0 || fraction > 1 { fraction = 1 }
        }.onChange(of: items.map(\.id)) { _, ids in
            invalidAmounts.formIntersection(Set(ids)); editingValid = invalidAmounts.isEmpty
        }
    }
    private func uncertaintyLabel(_ flag: String) -> String {
        switch flag {
        case "volume_requires_density": return "体积需密度才能换算质量"
        case "source_unverified": return "来源未验证"
        case "portion_requires_mass": return "按个/碗/份记录，质量未确认，营养为估算"
        case "portion_estimated": return "份量为估算"
        case "portion_total_not_per_100g": return "尚无每百克参考值"
        case "manual_nutrient_entry": return "营养已手动修改，请核对"
        case "identity_changed_needs_rematch": return "食物已更换，需重新匹配"
        case "nutrition_unknown": return "营养未知"
        case "added_fat_or_sauce_unknown": return "油/酱料未知"
        case "mixed_confirmed_and_estimated_mass": return "含估算份量"
        default: return flag
        }
    }

    private func nutrient(_ label: String, value: Binding<Double>) -> some View {
        HStack {
            Text(label); Spacer()
            TextField("0", value: value, format: .number.precision(.fractionLength(0...1)))
                .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
        }
    }
    private func add(oil: Bool) {
        items.append(FoodComponent(name: oil ? "食用油" : "", amount: oil ? 5 : 100, unit: "g",
            calories: oil ? 45 : 0, protein: 0, carbs: 0, fat: oil ? 5 : 0, basis: "user", details: []))
    }
}

private struct FoodPortionField: View {
    @Binding var item: FoodComponent
    let validation: (Bool) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool
    private var value: Double? { Double(text.replacingOccurrences(of: ",", with: ".")) }
    private var valid: Bool { value.map { $0.isFinite && $0 > 0 && $0 <= 10000 } == true }
    var body: some View {
        VStack(alignment: .trailing, spacing: BojiLayout.tight) {
            TextField("份量", text: $text).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                .focused($focused).accessibilityLabel("\(item.name)整份份量")
            if !valid { Text("请输入大于 0、最多 10000 的份量").bojiType(.label).foregroundStyle(.red) }
        }
        .onAppear { text = String(item.amount); validation(item.amount.isFinite && item.amount > 0 && item.amount <= 10000) }
        .onChange(of: text) { _, _ in
            validation(valid)
            if valid, let value { item.resize(to: value) }
        }
        .onChange(of: item.amount) { _, amount in if !focused { text = String(amount) } }
    }
}


/// Explicit whole-meal ratios update the draft only, without another model request.
enum MealCorrectionRules {
    static func explicitFraction(_ text:String) -> Double? {
        let value=text.trimmingCharacters(in:.whitespacesAndNewlines).replacingOccurrences(of:"。",with:"")
        if value.range(of:"^(?:这餐|这份|整餐|整份|我)?(?:实际)?(?:只)?吃了?(?:一半|半份|半餐|50[%％])$",options:.regularExpression) != nil { return 0.5 }
        if value.range(of:"^(?:这餐|这份|我)?(?:只)?吃了?(?:四分之一|25[%％])$",options:.regularExpression) != nil { return 0.25 }
        if value.range(of:"^(?:这餐|这份|我)?(?:只)?吃了?(?:四分之三|75[%％])$",options:.regularExpression) != nil { return 0.75 }
        return nil
    }
}
