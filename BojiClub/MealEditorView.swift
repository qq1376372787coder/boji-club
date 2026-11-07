private struct DraftSignature: Equatable {
    var name: String
    var category: String
    var calories: Double
    var protein: Double
    var carbs: Double
    var fat: Double
    var fraction: Double
    var jobID: String?
    var sourceJobID: String?
    var estimateNotes: [String]
    var photoAttached: Bool
    var mealDescription: String
    var textEntry: Bool
    var multipleMeals: Bool
    var previousRecognitionJobID: String?
}

import SwiftUI
import PhotosUI
import UIKit

struct MealEditorView: View {
    @State private var date: Date
    let onSaved: (() -> Void)?
    private let requestedCategory: String?
    private let requestedEntryMode: String?
    private let prefilled: MealBatchSeed?
    private let initialJobID: String?
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var ai: AIService
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var category = "午餐"
    @State private var calories: Double = 0
    @State private var energyUnitIsKJ = false
    @State private var protein: Double = 0
    @State private var carbs: Double = 0
    @State private var fat: Double = 0
    @State private var components: [FoodComponent] = []
    @State private var fraction = 1.0
    @State private var portionInputsValid = true
    @State private var repairedDateConfirmed = false
    @State private var photoItem: PhotosPickerItem?
    @State private var photo: Data?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var descriptionFocused: Bool
    @State private var captureMode = true
    @State private var cameraStatus: MealCameraStatus = .preparing
    @State private var captureID = 0
    @State private var cameraAttempt = 0
    @State private var takingPhoto = false
    @State private var photoLoadID = UUID()
    @State private var cameraMessage: String?
    @State private var loadingPhoto = false
    @State private var jobID: String?
    @State private var sourceJobID: String?
    @State private var previousRecognitionJobID: String?
    @State private var confirmExistingEstimate = false
    @State private var estimateNotes: [String] = []
    @State private var confirmRetake = false
    @State private var draftID = UUID()
    @State private var draftCreatedAt = Date()
    @State private var draftOwner: Int?
    @State private var draftLoaded = false
    @State private var draftReadable = true
    @State private var saved = false
    @State private var recognitionFeedback = 0
    @State private var restoredDraft = false
    @State private var draftChoices: [MealDraftChoice] = []
    @State private var showDraftChoices = false
    @State private var deletingDraft: MealDraftChoice?
    @State private var legacyDraftFile: URL?
    @State private var confirmUnknownNutrition = false
    @StateObject private var speech = MealSpeechInput()
    @State private var entryMode = "照片"
    @State private var mealDescription = ""
    @State private var speechPrefix = ""
    @State private var confirmTextRecognition = false
    @State private var pendingTextHint: MealDescriptionHint?
    @State private var textNeedsAI = true
    @State private var multipleMeals = false
    @State private var showMealDetails131 = false
    @State private var showMealCorrection131 = false
    @State private var showBatchReview = false
    @State private var correctionText = ""
    @State private var correctionBusy = false
    @State private var correctionError: String?
    @State private var correctionSequence = 0
    @State private var correctionJobID: String?
    private var batchHasHandledMeals: Bool {
        guard let jobID, !store.hasAppliedAIJob(jobID), let items = ai.job(jobID)?.result?.meals else { return false }
        return items.contains { store.hasAppliedAIJob(MealBatchIdentity.sourceID(root: jobID, item: $0.id)) }
    }

    init(date: Date, category: String? = nil, prefilled: MealBatchSeed? = nil, initialEntryMode: String? = nil, initialJobID: String? = nil, onSaved: (() -> Void)? = nil) {
        _date = State(initialValue: date)
        self.onSaved = onSaved
        requestedCategory = category
        self.prefilled = prefilled
        self.initialJobID = initialJobID
        requestedEntryMode = initialEntryMode
        let mode = ["照片", "语音", "手动"].contains(initialEntryMode ?? "") ? initialEntryMode! : "照片"
        _entryMode = State(initialValue: mode)
        _captureMode = State(initialValue: mode == "照片")
        _category = State(initialValue: category ?? "早餐")
    }
    private func total(_ key: KeyPath<FoodComponent, Double>, fallback: Double) -> Double {
        FoodComponent.total(key, components: components, fraction: fraction, fallback: fallback)
    }
    var body: some View {
        NavigationStack { observedEditor }
    }

    // Opaque section boundaries keep SwiftUI's type-checker from expanding
    // the entire editor, every presentation, and every observer at once.
    private var editorScroll: some View {
        ScrollViewReader { proxy in
            Form {
                    mealHeader
                    entrySection
                    recognitionSection
                    if sourceJobID != nil || !components.isEmpty {
                        DisclosureGroup("识别有误？修改食物或份量", isExpanded: $showMealCorrection131) { correctionSection }
                    }
                    nutritionSection.id("meal-nutrition")

        }.clubManagementList132().scrollDismissesKeyboard(.interactively)
                .background { ClubBackground() }
                .task(id: recognitionFeedback) {
                    guard recognitionFeedback > 0 else { return }
                    BojiHaptics.latch()
                    // Allow newly inserted result cards to participate in layout.
                    do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
                    guard !Task.isCancelled, scenePhase == .active, !saved,
                          draftOwner != nil, draftOwner == store.editingAccountID,
                          sourceJobID != nil, sourceJobID == jobID, !showBatchReview, !showDraftChoices else { return }
                    withAnimation(reduceMotion ? nil : BojiMotion2.state) {
                        proxy.scrollTo("meal-nutrition", anchor: .top)
                    }
                }
        }
    }

    @ViewBuilder
    private var mealHeader: some View {
        HStack(alignment: .center, spacing: BojiLayout.inline) {
            Menu {
                ForEach(MealCategorySuggestion.categories, id: \.self) { value in
                    Button {
                        category = value
                        persistDraft()
                    } label: {
                        HStack {
                            Text(value)
                            if category == value { Image(systemName: "checkmark") }
                        }
                    }
                }
            } label: {
                HStack(spacing: BojiLayout.tight) {
                    Text(category)
                        .bojiType(.section)
                        .foregroundStyle(BojiColor.textPrimary)
                    Image(systemName: "chevron.down.circle.fill")
                        .bojiType(.secondary)
                        .foregroundStyle(BojiColor.brandAccent)
                }
                .padding(.horizontal, BojiLayout.inline)
                .padding(.vertical, BojiLayout.tight)
                .background(BojiColor.subtleSurface, in: Capsule())
            }

            Text("·  \(ClubDates.label(date))")
                .bojiType(.secondary)
                .foregroundStyle(BojiColor.textSecondary)

            Spacer()

            if prefilled == nil, !draftChoices.isEmpty, draftLoaded {
                Button {
                    guard persistDraft() else { return }
                    loadDraftChoices()
                    showDraftChoices = true
                } label: {
                    Image(systemName: "doc.on.doc")
                        .bojiType(.secondary)
                        .foregroundStyle(BojiColor.textSecondary)
                }
                .buttonStyle(.plain)
                .disabled(isBusy || loadingPhoto || takingPhoto)
                .accessibilityLabel("查看其他草稿")
            }
        }
        .padding(.vertical, BojiLayout.tight)
        if restoredDraft {
            Text("已恢复未保存草稿").bojiType(.caption).foregroundStyle(BojiColor.textTertiary)
        }
    }

    @ViewBuilder
    private var entrySection: some View {
        if prefilled != nil {
            if let original = prefilled?.invalidOriginalDate {
                Text("原结果日期“\(original)”无法使用。请在下面明确选择这餐的实际日期，再保存。").bojiType(.secondary).foregroundStyle(.red)
                Button(repairedDateConfirmed ? "已确认记录日期" : "确认这餐记在 \(ClubDates.label(date))") { repairedDateConfirmed = true }.buttonStyle(SecondaryButton())
            }
            DatePicker("记录日期", selection: Binding(get: { date }, set: { _ = changeDraftDate(to: $0) }), in: ...Date(), displayedComponents: .date)
                .onChange(of: ClubDates.key(date)) { _, _ in if prefilled?.invalidOriginalDate != nil { repairedDateConfirmed = false } }
            Text("看看日期和份量，确认后保存。").bojiType(.caption).foregroundStyle(.secondary)
        } else {
        Picker("记录方式", selection: Binding(get: { entryMode }, set: { mode in
            if entryMode == "语音", multipleMeals { guard invalidateTextRecognition() else { return } }
            if isBusy, let jobID { ai.markConsumed(jobID); self.jobID = nil }
            entryMode = mode
            if mode == "手动" { showMealDetails131 = true }
        })) {
            Text("拍照").tag("照片")
            Text("语音 / 文字").tag("语音")
            Text("手动").tag("手动")
        }.pickerStyle(.segmented).accessibilityIdentifier("meal-entry-mode").disabled(loadingPhoto || takingPhoto || speech.isPreparing || batchHasHandledMeals)
        if entryMode == "语音" {
            textInputArea
        }
        else { photoCaptureArea }
        if entryMode == "照片" {
            Text("拍照后 AI 自动估算营养素，保存前可微调。")
                .bojiType(.caption).foregroundStyle(.secondary)
        }
        if !recentFrequentMeals.isEmpty && !isBusy {
            VStack(alignment: .leading, spacing: BojiLayout.inline) {
                HStack(spacing: BojiLayout.tight) {
                    Image(systemName: "bolt.fill")
                        .bojiType(.caption)
                        .foregroundStyle(BojiColor.aiGold)
                    Text("常吃与最近餐食 · 一键带入")
                        .bojiType(.caption)
                        .foregroundStyle(BojiColor.textSecondary)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: BojiLayout.inline) {
                        ForEach(recentFrequentMeals, id: \.id) { item in
                            Button {
                                applyQuickMeal(item)
                            } label: {
                                HStack(spacing: BojiLayout.tight) {
                                    Text(item.name)
                                        .bojiType(.caption)
                                        .foregroundStyle(BojiColor.textPrimary)
                                        .lineLimit(1)
                                    Text("\(Int(item.calories.rounded())) kcal")
                                        .bojiType(.caption)
                                        .foregroundStyle(BojiColor.textSecondary)
                                }
                                .padding(.horizontal, BojiSpace.general)
                                .padding(.vertical, BojiLayout.inline)
                                .background(BojiColor.subtleSurface, in: Capsule())
                                .overlay { Capsule().stroke(BojiColor.outline, lineWidth: 0.5) }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.top, BojiLayout.tight)
        }
        }
    }


    @ViewBuilder
    private var correctionSection: some View {
        if !components.isEmpty || !name.isEmpty || calories > 0 {
            ClubCard {
                Text("用一句话修正这餐").bojiType(.secondary)
                Text("描述修改内容，例如“只吃了一半”或“香蕉改为苹果”。")
                    .bojiType(.label).foregroundStyle(.secondary)
                HStack(spacing: BojiLayout.inline) {
                    TextField("描述需要改什么", text: $correctionText).textFieldStyle(.roundedBorder)
                    Button(correctionBusy ? "修改中…" : "修改草稿") { Task { await applyNaturalLanguageCorrection() } }
                        .buttonStyle(SecondaryButton()).disabled(correctionBusy || correctionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let correctionError { Text(correctionError).bojiType(.label).foregroundStyle(.red) }
                if correctionJobID != nil, ai.job(correctionJobID!)?.status == "succeeded" {
                    Text("已更新，看看份量是否合适。").bojiType(.label).foregroundStyle(.secondary)
                }
            }
        }
    }

    private struct CorrectionSnapshot: Codable {
        var id:UUID;var date:String;var name:String;var category:String;var components:[FoodComponent]
        var calories:Double;var protein:Double;var carbs:Double;var fat:Double;var fraction:Double
    }
    private var correctionSnapshot: Data? {
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        return try? encoder.encode(CorrectionSnapshot(id:draftID,date:ClubDates.key(date),name:name,category:category,components:components,calories:calories,protein:protein,carbs:carbs,fat:fat,fraction:fraction))
    }
    private func applyNaturalLanguageCorrection() async {
        let text = correctionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, draftLoaded, draftOwner == store.editingAccountID, !isBusy, !correctionBusy else { return }
        correctionBusy = true; correctionError = nil; correctionJobID = nil
        defer { correctionBusy = false }
        if let value=MealCorrectionRules.explicitFraction(text) {
            fraction=value;estimateNotes.append("整餐食用比例已按你的描述调整，请核对后保存。");persistDraft();correctionText="";return
        }
        guard let captured=correctionSnapshot else { correctionError="草稿数值暂不可用，请先核对。";return }
        let owner=draftOwner
        correctionSequence += 1
        let context: [String: JSONValue] = [
            "draft_id": .string(draftID.uuidString.lowercased()),
            "revision": .number(Double(correctionSequence)),
            "name": .string(name), "category": .string(category),
            "components": .array(components.map { component in
                .object(["name": .string(component.name), "amount": .number(component.amount), "unit": .string(component.unit),
                         "calories": .number(component.calories), "protein": .number(component.protein),
                         "carbs": .number(component.carbs), "fat": .number(component.fat)])
            }),
            "fraction": .number(fraction),
            "nutrition_sources": .array(components.compactMap { $0.sourceDatabase.map(JSONValue.string) }),
            "uncertainty_note": .string(estimateNotes.joined(separator: "；"))
        ]
        let payload: [String: JSONValue] = [
            "source": .string("text"), "description": .string(text), "meal_category": .string(category),
            "draft_id": .string(draftID.uuidString.lowercased()), "draft_context": .object(context),
            "timeZone": .string(TimeZone.current.identifier)
        ]
        do {
            let id = try ai.submit(AIInput(kind: "food", date: ClubDates.key(date), payload: payload))
            correctionJobID = id
            let deadline = Date().addingTimeInterval(60)
            while Date() < deadline, !Task.isCancelled {
                if let job = ai.job(id) {
                    if job.status == "succeeded", let result = job.result, result.kind == "meal" {
                        guard owner==store.editingAccountID,draftOwner==owner,correctionSnapshot==captured else { correctionError="草稿在等待期间已修改，这次结果没有覆盖新修改。请重新核对后再试。";return }
                        if let value=result.consumed_fraction,value.isFinite,(0...1).contains(value) { fraction=value }
                        if let newName = result.name, !newName.isEmpty { name = newName }
                        if let newComponents = result.components { components = newComponents }
                        calories = result.calories ?? 0; protein = result.protein ?? 0
                        carbs = result.carbs ?? 0; fat = result.fat ?? 0
                        estimateNotes = result.notes
                        // A correction re-estimates the draft; old database
                        // trust is cleared until the new result earns its own.
                        sourceJobID = nil
                        persistDraft()
                        correctionText = ""
                        return
                    }
                    if ["failed", "deleted", "expired", "rejected"].contains(job.status) {
                        correctionError = job.error ?? "这次修正没有完成，原草稿已保留。"
                        return
                    }
                }
                try? await Task.sleep(for: .seconds(1))
            }
            correctionError = "修正等待较久，原草稿已保留；可稍后重试。"
        } catch { correctionError = AppErrorText.message(error) }
    }
    private var recentFrequentMeals: [Meal] {
        var seen = Set<String>()
        var results: [Meal] = []
        for key in store.state.days.keys.sorted(by: >).prefix(30) {
            guard let meals = store.state.days[key]?.meals else { continue }
            for meal in meals.reversed() {
                let trimmed = meal.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, meal.hasNutrition, seen.insert(trimmed).inserted else { continue }
                results.append(meal)
                if results.count >= 6 { return results }
            }
        }
        return results
    }

    private func applyQuickMeal(_ item: Meal) {
        BojiHaptics.latch()
        name = item.name
        calories = item.calories
        protein = item.protein
        carbs = item.carbs
        fat = item.fat
        components = item.components ?? []
        fraction = 1.0
        persistDraft()
    }

    @ViewBuilder
    private var recognitionSection: some View {
        if loadingPhoto { ClubLoadingCard(title: "正在读取照片…") }
        AIJobStatusView(id: jobID, animated: true)
        if !components.isEmpty && !isBusy {
            let totalProt = protein
            let totalCal = calories
            let isHighProtein = totalProt >= 25.0 || (totalCal > 0 && (totalProt * 4.0 / totalCal) >= 0.3)
            HStack(spacing: BojiLayout.tight) {
                Image(systemName: isHighProtein ? "sparkles" : "info.circle")
                    .bojiType(.caption)
                    .foregroundStyle(isHighProtein ? BojiColor.aiGold : BojiColor.textSecondary)
                Text(isHighProtein ? "蛋白质充裕（\(Int(totalProt.rounded()))g），适合作为训后营养补充。" : "供能概览：\(Int(totalCal.rounded())) kcal · 蛋白质 \(Int(totalProt.rounded()))g")
                    .bojiType(.caption)
                    .foregroundStyle(BojiColor.textSecondary)
            }
            .padding(.horizontal, BojiLayout.inline).padding(.vertical, BojiSpace.tight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(BojiColor.subtleSurface, in: RoundedRectangle(cornerRadius: BojiRadius.thumb, style: .continuous))
        }
        if ai.job(jobID)?.result?.kind == "meal_batch" {
            ForEach(Array((ai.job(jobID)?.result?.notes ?? []).enumerated()), id: \.offset) { _, note in Text(note).bojiType(.caption).foregroundStyle(.secondary) }
        }
        if estimateIsStale {
            Label("描述已更新。点此重新识别，或直接保存现有估算数值。", systemImage: "info.circle")
                .bojiType(.secondary).foregroundStyle(.secondary)
        }
        if let previous = previousRecognitionJobID, !isBusy {
            Button("返回上一次识别结果") {
                if let jobID, jobID != previous { ai.markConsumed(jobID) }
                jobID = previous; previousRecognitionJobID = nil; applyResult(); persistDraft()
            }.buttonStyle(SecondaryButton())
        }
        if isBusy {
            Button("改为手动记录") {
                if let jobID { ai.markConsumed(jobID) }
                captureMode = false
                if entryMode == "语音" {
                    jobID = nil; entryMode = "手动"; multipleMeals = false
                    cameraMessage = "文字草稿已保留，可以手动填写继续记录。"
                } else { cameraMessage = "照片已保留，可以手动填写继续记录。" }
                persistDraft()
            }.buttonStyle(SecondaryButton()).bojiType(.secondary)
        }
        if photo != nil && !isBusy && entryMode != "语音" {
            Button(jobID == nil ? "识别这张照片" : "重新识别") { identify(forceNew: jobID != nil) }.buttonStyle(SecondaryButton()).bojiType(.secondary)
        }
        if prefilled == nil, photo == nil, let previous = ai.latest(kind: "food", date: date), !previous.consumed, !store.hasAppliedAIJob(previous.id) {
            Button("恢复上次未保存的识别") {
                photo = previous.request.payload["image_base64"]?.string.flatMap { Data(base64Encoded: $0) }
                if let text = previous.request.payload["description"]?.string {
                    mealDescription = text; entryMode = "语音"; captureMode = false
                    category = previous.request.payload["meal_category"]?.string ?? category
                    multipleMeals = previous.request.payload["mode"]?.string == "multiple"
                }
                jobID = previous.id
                applyResult()
            }.buttonStyle(SecondaryButton())
        }
        if ai.job(jobID)?.result?.is_food == false {
            Text(ai.job(jobID)?.request.payload["source"]?.string == "text" ? "这段描述暂时无法整理为一餐，请核对食物、日期和餐别后重试。" : "没有识别到可辨认的食物，请重拍或手动填写。")
                .bojiType(.secondary).foregroundStyle(.secondary)
            if let notes = ai.job(jobID)?.result?.notes {
                ForEach(Array(notes.enumerated()), id: \.offset) { _, note in Text(note).bojiType(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    @ViewBuilder
    private var nutritionSection: some View {
        if !(entryMode == "语音" && multipleMeals) {
            mealSummary
            DisclosureGroup("食物、份量与营养明细", isExpanded: $showMealDetails131) {
                compositionSection
                estimateNotesSection
                ContextualTipView(screen: "food_fraction")
            }.padding(ClubUI.cardInset).background(ClubUI.surface, in: RoundedRectangle(cornerRadius: ClubUI.cardRadius))
        }
    }

    private var mealSummary: some View {
        VStack(alignment: .leading, spacing: BojiLayout.blockGap) {
            TextField("这一餐叫什么？（最多100字）", text: $name).bojiFont(.cardTitle).disabled(isBusy)
            HStack(alignment: .firstTextBaseline, spacing: BojiLayout.tight) {
                Text(total(\.calories, fallback: calories).formatted(.number.precision(.fractionLength(0))))
                    .bojiType(.display)
                Text("kcal").bojiFont(.label).foregroundStyle(BojiColor.textSecondary)
                Spacer()
                Text(sourceJobID == nil ? "饮食记录" : "AI 估算").bojiType(.caption).foregroundStyle(.secondary)
            }
            HStack {
                macro("蛋白质", total(\.protein, fallback: protein))
                macro("碳水", total(\.carbs, fallback: carbs))
                macro("脂肪", total(\.fat, fallback: fat))
            }
        }.padding(ClubUI.cardInset).background(ClubUI.surface, in: RoundedRectangle(cornerRadius: ClubUI.cardRadius, style: .continuous))
    }

    @ViewBuilder
    private var compositionSection: some View {
        if !components.isEmpty {
            VStack(alignment: .leading, spacing: BojiLayout.blockGap) {
                Text("食物明细").bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
                if components.contains(where: { $0.requiresReview == true || !($0.uncertaintyFlags ?? []).isEmpty }) {
                    Text("营养是估算值，可以调整食物和份量。")
                        .bojiType(.caption).foregroundStyle(.orange)
                }
                FoodCompositionEditor(items: $components, fraction: $fraction, editingValid: $portionInputsValid).disabled(isBusy)
            }.padding(ClubUI.cardInset).background(ClubUI.surface, in: RoundedRectangle(cornerRadius: ClubUI.cardRadius, style: .continuous))
        } else {
            VStack(spacing: BojiLayout.cardInset) {
                HStack {
                    Text("手动填写或修改").bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
                    Spacer()
                    Picker("热量单位", selection: $energyUnitIsKJ) {
                        Text("千卡 kcal").tag(false)
                        Text("千焦 kJ").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 160)
                }
                if !energyUnitIsKJ {
                    valueRow("热量", value: $calories, unit: "kcal")
                } else {
                    HStack {
                        Text("热量"); Spacer()
                        TextField("0", value: Binding<Double>(
                            get: { (calories * 4.184 * 10).rounded() / 10 },
                            set: { calories = ($0 / 4.184 * 10).rounded() / 10 }
                        ), format: .number.precision(.fractionLength(0...1)))
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(minWidth: 80, maxWidth: 150)
                            .accessibilityLabel("热量，千焦")
                        Text("kJ").foregroundStyle(.secondary)
                    }
                    HStack {
                        Spacer()
                        Text("≈ \(Int(calories.rounded())) kcal（按 1 kcal = 4.184 kJ 换算）")
                            .bojiType(.caption)
                            .foregroundStyle(BojiColor.textTertiary)
                    }
                }
                valueRow("蛋白质", value: $protein, unit: "g")
                valueRow("碳水", value: $carbs, unit: "g")
                valueRow("脂肪", value: $fat, unit: "g")
                Button("添加食物明细") {
                    components = [FoodComponent(name: name.isEmpty ? "餐食" : name, amount: 1, unit: "份", calories: calories, protein: protein, carbs: carbs, fat: fat, basis: "user", details: [])]
                }.buttonStyle(SecondaryButton())
            }.padding(ClubUI.cardInset).background(ClubUI.surface, in: RoundedRectangle(cornerRadius: ClubUI.cardRadius, style: .continuous)).disabled(isBusy)
        }
    }

    @ViewBuilder
    private var estimateNotesSection: some View {
        if !estimateNotes.isEmpty {
            VStack(alignment: .leading, spacing: BojiLayout.inline) {
                Label("需要你确认", systemImage: "slider.horizontal.3").bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
                ForEach(Array(estimateNotes.enumerated()), id: \.offset) { _, note in
                    Text(note).bojiType(.secondary).foregroundStyle(.secondary)
                }
            }.padding(ClubUI.cardInset).background(ClubUI.surface, in: RoundedRectangle(cornerRadius: ClubUI.cardRadius, style: .continuous))
        }
    }

    private var bottomAction: some View {
        FlowDock {
            if let reason = bottomActionReason {
                Text(reason).bojiType(.label).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            }
            Button {
                if entryMode == "语音" && multipleMeals { showBatchReview = true }
                else if hasNutritionValues { save() } else { confirmUnknownNutrition = true }
            } label: {
                Text(entryMode == "语音" && multipleMeals ? "逐餐核对并保存" : "保存这餐")
            }.buttonStyle(PrimaryButton()).disabled(!canUseBottomAction)
                .accessibilityHint(bottomActionReason ?? "保存前请核对日期、餐别和份量")
        }
    }

    private var navigationEditor: some View {
        editorScroll
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭", systemImage: "xmark") { dismiss() }.tint(.primary) } }
            .safeAreaInset(edge: .bottom) { bottomAction }
    }

    private var photoRecognitionEditor: some View {
        navigationEditor
        .task(id: photoItem) {
            guard let photoItem else { return }
            let loadID = UUID(); photoLoadID = loadID
            loadingPhoto = true
            defer { if photoLoadID == loadID { loadingPhoto = false; self.photoItem = nil } }
            do {
                if let data = try await photoItem.loadTransferable(type: Data.self), let image = await ClubImage.preview(data, pixels: 1400) {
                    guard !Task.isCancelled, photoLoadID == loadID else { return }; setPhoto(image)
                } else if !Task.isCancelled, photoLoadID == loadID { cameraMessage = "无法读取这张照片，请换一张。" }
            } catch { if !Task.isCancelled { cameraMessage = "照片读取失败，请重试。" } }
        }

    }

    private var textRecognitionEditor: some View {
        photoRecognitionEditor
        .confirmationDialog(textNeedsAI ? "核对后识别这一餐？" : "只保存食物名称？", isPresented: $confirmTextRecognition, titleVisibility: .visible) {
            Button(textNeedsAI ? "确认日期餐别，识别餐食" : "确认日期餐别，保存名称") {
                guard let hint = pendingTextHint, applyTextContext(hint) else { return }
                if textNeedsAI { identifyText() }
                else { prepareNameOnlyRecord() }
            }
            Button("取消", role: .cancel) { }
        } message: {
            let hint = pendingTextHint ?? MealDescriptionHint(date: date, category: category)
            Text("\(ClubDates.label(hint.date, format: "yyyy年M月d日")) · \(hint.category)\n" +
                 (store.log(for: hint.date).meals.contains { $0.category == hint.category } ? "这天已有同类餐食，本次另记一餐，不会覆盖。\n" : "") +
                 (textNeedsAI ? "仅核对后的文字用于云端 AI 分析，不发送录音或照片。识别会替换当前名称和营养数据，请核对份量后再保存。" : "营养值将标为未知，不会当作零热量。"))
        }
        .onAppear {
            restoreDraft()
            if requestedEntryMode == "手动" { entryMode = "手动"; captureMode = false }
        }
    }

    private var reviewEditor: some View {
        textRecognitionEditor
        .confirmationDialog("保留当前营养估算？", isPresented: $confirmExistingEstimate, titleVisibility: .visible) {
            Button("已核对，保留现有数值并保存") { save(unknownNutrition: !hasNutritionValues, acceptingExistingEstimate: true) }
            Button("继续修改或重新识别", role: .cancel) { }
        } message: { Text("原话已修改，当前数值来自上一次识别。若食物或份量发生变化，请先重新识别或手动调整。") }
        .sheet(isPresented: $showBatchReview) {
            if let jobID { MealBatchReviewView(jobID: jobID) { saved = true; clearDraft(); onSaved?(); dismiss() } }
        }
        .sheet(isPresented: $showDraftChoices) { draftSelection }
        .confirmationDialog("这餐还没有营养数据", isPresented: $confirmUnknownNutrition, titleVisibility: .visible) {
            Button("先保存，营养值标记为未知") { save(unknownNutrition: true) }
            Button("继续填写", role: .cancel) { }
        } message: { Text("食物名称和照片会保存。它不会当作零热量，AI 分析也会说明这餐的数据缺失。") }
    }

    private var draftSelection: some View {
        NavigationStack {
            List {
                Section("这一天尚未保存的餐食") {
                    ForEach(draftChoices) { choice in
                        Button { if restore(choice) { showDraftChoices = false } } label: {
                            VStack(alignment: .leading, spacing: BojiLayout.tight) {
                                Text("\(choice.draft.category) · \(choice.draft.name.isEmpty ? "未命名餐食" : choice.draft.name)")
                                if let created = choice.draft.createdAt {
                                    Text("创建于 \(created.formatted(date: .omitted, time: .shortened))").bojiType(.caption).foregroundStyle(.secondary)
                                }
                                if choice.draft.category == category { Text("优先继续这餐").bojiType(.caption).foregroundStyle(.secondary) }
                            }
                        }.buttonStyle(ClubActionButtonStyle(kind: .row)).tint(.primary).swipeActions { Button("删除", role: .destructive) { deletingDraft = choice } }
                    }
                }
                Button("新建另一餐") { startNewDraft(); showDraftChoices = false }.buttonStyle(ClubActionButtonStyle(kind: .row))
            }.clubListSurface()
            .navigationTitle("继续草稿或新建")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement:.cancellationAction) { Button("取消记餐") { showDraftChoices=false;dismiss() } } }
        }
        .confirmationDialog("删除这份餐食草稿？", isPresented: Binding(get: { deletingDraft != nil }, set: { if !$0 { deletingDraft = nil } }), titleVisibility: .visible) {
            Button("删除草稿和未采用的识别", role: .destructive) { if let choice = deletingDraft { deleteDraft(choice) }; deletingDraft = nil }
            Button("保留", role: .cancel) { deletingDraft = nil }
        } message: { Text("已保存的餐食不会受影响；其他餐食草稿会继续保留。") }
        .alert("餐食草稿提示", isPresented: Binding(get: { cameraMessage != nil }, set: { if !$0 { cameraMessage = nil } })) { Button("知道了") { cameraMessage = nil } } message: { Text(cameraMessage ?? "") }
        .interactiveDismissDisabled()
    }

    private var lifecycleEditor: some View {
        reviewEditor
        .task(id: draftSignature) {
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            guard !Task.isCancelled else { return }; persistDraft()
        }
        .onChange(of: photo) { _, _ in persistDraftPhoto() }
        .onDisappear { speech.stop(); persistDraft() }
        .onChange(of: entryMode) { _, mode in speech.stop(); captureMode = mode == "照片"; takingPhoto = false }
        .onChange(of: scenePhase) { _, phase in if phase == .background || (phase != .active && speech.isRecording) { speech.stop(); persistDraft() } }
    }

    private var observedEditor: some View {
        lifecycleEditor
        .sensoryFeedback(.success, trigger: recognitionFeedback)
        .onChange(of: speech.transcript) { _, text in
            guard !text.isEmpty else { return }
            updateDescription(speechPrefix.isEmpty ? text : speechPrefix + "\n" + text)
            if mealDescription.count >= 2000 { speech.stop() }
        }
        .onChange(of: ai.job(jobID)?.status) { _, _ in applyResult() }
        .onChange(of: jobID) { _, _ in applyResult() }
        .onChange(of: store.editingAccountID) { _, owner in
            if draftOwner != nil, owner != draftOwner { showDraftChoices=false;dismiss() }
        }
        .alert("餐食记录提示", isPresented: Binding(get: { cameraMessage != nil && !showDraftChoices }, set: { if !$0 { cameraMessage = nil } })) {
            Button("知道了") { cameraMessage = nil }
        } message: { Text(cameraMessage ?? "") }
    }

    private var cameraActive: Bool {
        draftLoaded && !showDraftChoices && draftOwner != nil && draftOwner == store.editingAccountID && captureMode &&
        photo == nil && scenePhase == .active && !loadingPhoto && !isBusy
    }
    private var textInputArea: some View {
        ClubCard {
            HStack {
                Label("说说吃了什么", systemImage: "mic").bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
                Spacer()
                Menu {
                    ForEach(MealSpeechInput.languages, id: \.0) { language in
                        Button {
                            speech.language = language.0
                        } label: {
                            HStack {
                                Text(language.1)
                                if speech.language == language.0 { Image(systemName: "checkmark") }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: BojiLayout.tight) {
                        Text(MealSpeechInput.languages.first(where: { $0.0 == speech.language })?.1 ?? "普通话")
                            .bojiType(.caption)
                        Image(systemName: "chevron.down")
                            .bojiType(.caption)
                    }
                    .foregroundStyle(BojiColor.textSecondary)
                    .padding(.horizontal, BojiLayout.inline)
                    .padding(.vertical, BojiLayout.tight)
                    .background(BojiColor.inputSurface, in: Capsule())
                }
                .disabled(speech.isRecording || speech.isPreparing)
            }
            Text("一餐或多餐都可以，例如：早上两个鸡蛋，中午一碗牛肉面。识别后核对再保存。")
                .bojiType(.caption).foregroundStyle(.secondary)
            DatePicker("记录日期", selection: Binding(get: { date }, set: { _ = changeDraftDate(to: $0) }), in: ...Date(), displayedComponents: .date)
                .disabled(isBusy || jobID != nil || speech.isRecording || speech.isPreparing)
            TextEditor(text: Binding(get: { mealDescription }, set: updateDescription))
                .focused($descriptionFocused)
                .frame(minHeight: 100, maxHeight: 160).scrollContentBackground(.hidden)
                .padding(BojiSpace.tightRow).background(BojiColor.inputSurface, in: RoundedRectangle(cornerRadius: BojiRadius.inner))
                .accessibilityLabel("描述吃了什么、餐别和份量").disabled(isBusy || speech.isRecording || speech.isPreparing || batchHasHandledMeals)
            HStack {
                Button {
                    if speech.isRecording { speech.finishRecording(); persistDraft() }
                    else {
                        speechPrefix = mealDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                        Task { await speech.start() }
                    }
                } label: {
                    Label(speech.isFinishing ? "正在整理文字…" : speech.isPreparing ? "准备识别…" : speech.isRecording ? "结束录音" : "开始说话", systemImage: speech.isRecording ? "stop.circle.fill" : "mic.fill")
                }.buttonStyle(SecondaryButton()).tint(.primary)
                    .disabled(isBusy || speech.isPreparing || batchHasHandledMeals || !draftLoaded || !draftReadable || (mealDescription.count >= 2000 && !speech.isRecording))
                Spacer()
                Text("\(mealDescription.count)/2000").bojiType(.caption).foregroundStyle(.secondary)
            }
            if speech.isFinishing { ClubLoadingCard(title: "正在整理识别文字…") }
            else if speech.isPreparing { ClubLoadingCard(title: "正在准备语音输入…") }
            else if speech.isRecording { Label("正在本地识别，结束后核对文字", systemImage: "waveform").bojiType(.caption) }
            if let message = speech.message { Text(message).bojiType(.caption).foregroundStyle(.secondary) }
            Text("语音已在本地实时识别。")
                .bojiType(.label).foregroundStyle(.secondary)
            if batchHasHandledMeals { Text("这次分餐已开始保存，请先处理剩余餐食；已保存的不会重复识别。").bojiType(.caption).foregroundStyle(.secondary) }
            Button(jobID == nil ? "识别餐食" : "重新识别") { requestTextAction(estimate: true) }
                .buttonStyle(PrimaryButton()).tint(.primary)
                .disabled(isBusy || speech.isRecording || speech.isPreparing || batchHasHandledMeals || mealDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draftLoaded || !draftReadable)
            if !multipleMeals {
            Button("仅保存食物名称") { requestTextAction(estimate: false) }.buttonStyle(SecondaryButton())
                .bojiType(.caption).disabled(isBusy || speech.isRecording || speech.isPreparing || mealDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draftLoaded || !draftReadable)
            }
        }
    }
    private var canUseBottomAction: Bool {
        let activeBatch = jobID.map { !store.hasAppliedAIJob($0) && ai.job($0)?.consumed != true } ?? false
        let available = entryMode == "语音" && multipleMeals ? activeBatch && !(ai.job(jobID)?.result?.meals?.isEmpty ?? true) : canSave
        return available && !loadingPhoto && !isBusy && !speech.isRecording && !speech.isPreparing
    }
    @discardableResult
    private func invalidateTextRecognition() -> Bool {
        guard !batchHasHandledMeals else { cameraMessage = "请先处理剩余分餐，再切换记录方式。"; return false }
        return true
    }

    private var estimateIsStale: Bool {
        let id = sourceJobID ?? (ai.job(jobID)?.result?.kind == "meal_batch" ? jobID : nil)
        guard let id else { return false }
        if ai.job(id)?.result?.kind == "meal_batch", !multipleMeals { return true }
        let original = ai.job(id)?.request.payload["description"]?.string ?? ""
        return original.trimmingCharacters(in: .whitespacesAndNewlines) != mealDescription.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private func updateDescription(_ value: String) {
        let clean = String(value.prefix(2000))
        guard clean != mealDescription else { return }
        guard !batchHasHandledMeals else { speech.stop(); cameraMessage = "请先处理剩余分餐，再修改原话。"; return }
        mealDescription = clean
    }
    private func finishReplacingRecognition(_ replacement: String) -> Bool {
        guard let previous = previousRecognitionJobID, previous != replacement else { return true }
        if let items = ai.job(previous)?.result?.meals {
            let ids = items.map { MealBatchIdentity.sourceID(root: previous, item: $0.id) } + [previous]
            guard store.handleMealRecognitionIDs(ids) else { cameraMessage = store.takeMessage(); return false }
        }
        ai.markConsumed(previous); previousRecognitionJobID = nil
        return true
    }
    private func requestTextAction(estimate: Bool) {
        descriptionFocused = false
        speech.stop()
        guard draftLoaded, draftReadable, draftOwner == store.editingAccountID, !saved, !isBusy else { return }
        let text = mealDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if estimate {
            guard !batchHasHandledMeals else { return }
            multipleMeals = true
            guard persistDraft() else { return }
            identifyText(); return
        }
        multipleMeals = false
        let hint = MealDescriptionUnderstanding.inspect(text, date: date, category: category)
        if let problem = hint.problem { cameraMessage = problem; return }
        guard persistDraft() else { return }
        pendingTextHint = hint; textNeedsAI = estimate
        let requiresReview = hint.requiresDateConfirmation || MealRecognitionReviewPolicy.requiresConfirmation(
            dateChanged: ClubDates.key(hint.date) != ClubDates.key(date),
            categoryChanged: hint.category != category,
            replacesExisting: !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !components.isEmpty || hasNutritionValues)
        if requiresReview { confirmTextRecognition = true; return }
        guard applyTextContext(hint) else { return }
        if estimate { identifyText() } else { prepareNameOnlyRecord() }
    }
    private func prepareNameOnlyRecord() {
        showMealDetails131 = true
        if let jobID { ai.markConsumed(jobID) }
        jobID = nil; sourceJobID = nil; components = []; fraction = 1
        calories = 0; protein = 0; carbs = 0; fat = 0; estimateNotes = []
        name = String(mealDescription.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        confirmUnknownNutrition = true
    }
    private func applyTextContext(_ hint: MealDescriptionHint) -> Bool {
        guard !ClubDates.isFuture(hint.date), !isBusy, draftOwner == store.editingAccountID else { return false }
        guard changeDraftDate(to: hint.date) else { return false }
        category = hint.category
        return persistDraft()
    }
    private func changeDraftDate(to candidate: Date) -> Bool {
        guard !ClubDates.isFuture(candidate), draftLoaded, draftReadable, !saved, !isBusy, draftOwner == store.editingAccountID else { return false }
        guard ClubDates.key(candidate) != ClubDates.key(date) else { return true }
        let previous = date, oldStem = draftStem
        do {
            let folder = try prepareDraftFolder()
            date = candidate
            // Write the new photo and JSON before removing the original draft.
            if let photo { try photo.write(to: folder.appendingPathComponent(draftStem + ".jpg"), options: [.atomic, .completeFileProtection]) }
            guard persistDraft() else { date = previous; return false }
            let oldJSON = folder.appendingPathComponent(oldStem + ".json")
            do {
                if FileManager.default.fileExists(atPath: oldJSON.path) {
                    // A tombstone cannot be restored as a second meal on the old day.
                    try FileManager.default.moveItem(at: oldJSON, to: folder.appendingPathComponent(oldStem + "-" + UUID().uuidString + ".discarded"))
                }
            } catch {
                for ext in ["json", "jpg"] { try? FileManager.default.removeItem(at: folder.appendingPathComponent(draftStem + "." + ext)) }
                date = previous; throw error
            }
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(oldStem + ".jpg"))
            draftChoices = []; return true
        } catch { date = previous; cameraMessage = "日期修改未保存，原草稿已保留，请稍后重试。"; return false }
    }
    private func identifyText() {
        guard !batchHasHandledMeals, draftOwner != nil, draftOwner == store.editingAccountID else { return }
        do {
            var payload: [String: JSONValue] = ["source": .string("text"), "description": .string(mealDescription.trimmingCharacters(in: .whitespacesAndNewlines)), "meal_category": .string(category), "draft_id": .string(draftID.uuidString.lowercased())]
            if multipleMeals { payload["mode"] = .string("multiple"); payload["reference_date"] = .string(ClubDates.key(Date())) }
            let input = AIInput(kind: "food", date: ClubDates.key(date), payload: payload)
            let submitted = try ai.submit(input, forceNew: jobID != nil)
            if let previous = jobID, previous != submitted {
                if previousRecognitionJobID == nil { previousRecognitionJobID = previous }
                else if previous != previousRecognitionJobID { ai.markConsumed(previous) }
            }
            jobID = submitted
            if ai.job(submitted)?.consumed == true { cameraMessage = "这段描述已经记录，可在饮食历史中修改原记录。" }
            applyResult()
        } catch { cameraMessage = AppErrorText.message(error) }
    }
    private var photoCaptureArea: some View {
        VStack(spacing: BojiLayout.rowGap) {
            if let photo {
                ZStack {
                    FoodCutoutView(data: photo)
                    LaserScanBeamOverlay(isScanning: isBusy)
                }
                .clipShape(RoundedRectangle(cornerRadius: BojiRadius.image, style: .continuous))
                HStack {
                    Button { captureMode = true; confirmRetake = true } label: { Label("重拍", systemImage: "camera") }
                    Spacer()
                    PhotosPicker(selection: $photoItem, matching: .images) { Label("更换照片", systemImage: "photo") }
                }.buttonStyle(SecondaryButton()).tint(.primary).disabled(loadingPhoto || isBusy)
            } else if captureMode {
                ZStack {
                    Color.black
                    MealCameraPreview(active: cameraActive, captureID: captureID, receive: { image in
                        guard cameraActive else { takingPhoto = false; return }; setPhoto(image)
                    }, status: { status in
                        if cameraStatus != status { cameraStatus = status }
                    }, captureFinished: { message in
                        takingPhoto = false
                        if let message { cameraMessage = message }
                    }).id(cameraAttempt)
                    VStack(spacing: BojiLayout.rowGap) {
                        HStack {
                            Text(cameraStatus.message).bojiType(.caption).multilineTextAlignment(.leading)
                            Spacer()
                        }.padding(BojiSpace.workoutCardInset).background(.black.opacity(0.55))
                        if cameraStatus != .ready {
                            Spacer()
                            if cameraStatus == .preparing {
                                ClubActivityMark(size: 30, tint: .white)
                                ClubWaitBar(tint: .white).frame(width: 140).padding(.top, BojiSpace.tightRow)
                            }
                            else {
                                Image(systemName: "camera").bojiType(.display)
                                if cameraStatus == .denied {
                                    Button("打开系统设置") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }.buttonStyle(ClubIconButtonStyle())
                                } else {
                                    Button("重新打开相机") { cameraStatus = .preparing; cameraAttempt += 1; takingPhoto = false }.buttonStyle(ClubIconButtonStyle())
                                }
                            }
                        }
                        Spacer()
                        HStack {
                            Button {
                                BojiHaptics.tick()
                                entryMode = "手动"
                                captureMode = false
                                takingPhoto = false
                            } label: {
                                VStack(spacing: BojiLayout.tight) {
                                    Image(systemName: "square.and.pencil")
                                        .bojiType(.body)
                                    Text("手动")
                                        .bojiType(.caption)
                                }
                                .foregroundStyle(.white)
                                .frame(width: 50, height: 50)
                                .clubGlassEffect(in: Circle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("不拍照，手动记录")

                            Spacer()

                            Button {
                                BojiHaptics.tick()
                                takingPhoto = true
                                captureID += 1
                            } label: {
                                ZStack {
                                    Circle()
                                        .stroke(Color.white, lineWidth: 3.5)
                                        .frame(width: 66, height: 66)
                                    if takingPhoto {
                                        ClubActivityMark(size: 28, tint: .white)
                                    } else {
                                        Circle()
                                            .fill(Color.white)
                                            .frame(width: 54, height: 54)
                                            .shadow(color: Color.black.opacity(0.25), radius: 6)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(cameraStatus != .ready || !cameraActive || takingPhoto)
                            .accessibilityLabel("拍摄这一餐")

                            Spacer()

                            PhotosPicker(selection: $photoItem, matching: .images) {
                                VStack(spacing: BojiLayout.tight) {
                                    Image(systemName: "photo")
                                        .bojiType(.body)
                                    Text("相册")
                                        .bojiType(.caption)
                                }
                                .foregroundStyle(.white)
                                .frame(width: 50, height: 50)
                                .clubGlassEffect(in: Circle())
                            }
                            .buttonStyle(.plain)
                            .disabled(loadingPhoto || takingPhoto)
                            .accessibilityLabel("从相册选择餐食照片")
                        }
                        .padding(.horizontal, BojiLayout.sectionGap)
                        .padding(.vertical, BojiLayout.inline)
                        .clubGlassEffect(in: Capsule())
                        .padding(.horizontal, BojiLayout.cardInset)
                        .padding(.bottom, BojiLayout.inline)
                        if takingPhoto { ClubWaitBar(tint: .white).padding(.horizontal, BojiLayout.cardInset).padding(.bottom, BojiLayout.inline) }
                    }.foregroundStyle(.white)
                }.frame(height: 330).clipShape(RoundedRectangle(cornerRadius: BojiRadius.image))
            } else {
                ClubCard {
                    Label("手动记录", systemImage: "square.and.pencil").bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
                    Text("无需照片也能保存，填写下方名称和营养信息即可。").bojiType(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("打开相机") { entryMode = "照片"; captureMode = true }
                        Spacer()
                        PhotosPicker(selection: $photoItem, matching: .images) { Label("选择照片", systemImage: "photo") }
                    }.buttonStyle(SecondaryButton()).tint(.primary).disabled(loadingPhoto || isBusy)
                }
            }
        }
        .confirmationDialog("重新拍摄这一餐？", isPresented: $confirmRetake, titleVisibility: .visible) {
            Button("清除当前照片并重拍") {
                guard prepareRetakeDraft() else { return }
                photo = nil; photoItem = nil; jobID = nil
                if sourceJobID != nil || components.contains(where: { ["visible", "assumed"].contains($0.basis) }) {
                    name = ""; calories = 0; protein = 0; carbs = 0; fat = 0; components = []; fraction = 1; estimateNotes = []
                }
                sourceJobID = nil; persistDraft()
                cameraStatus = .preparing; takingPhoto = false; cameraAttempt += 1
            }
            Button("取消", role: .cancel) { }
        } message: { Text("当前照片及它的 AI 估算会清空，已经保存的餐食记录保留。") }
    }
    private func prepareRetakeDraft() -> Bool {
        guard draftLoaded, draftReadable, !saved, draftOwner == store.editingAccountID else { return false }
        let reset = sourceJobID != nil || components.contains { ["visible", "assumed"].contains($0.basis) }
        let cleared = MealEditorDraft(id: draftID, name: reset ? "" : name, category: category,
            calories: reset ? 0 : calories, protein: reset ? 0 : protein, carbs: reset ? 0 : carbs,
            fat: reset ? 0 : fat, components: reset ? [] : components, fraction: reset ? 1 : fraction,
            jobID: nil, sourceJobID: nil, estimateNotes: reset ? [] : estimateNotes, photoAttached: false,
            mealDescription: mealDescription.isEmpty ? nil : mealDescription, textEntry: entryMode == "语音", multipleMeals: multipleMeals)
        do {
            let folder = try prepareDraftFolder()
            // Commit the absence of a photo before removing its old bytes.
            try JSONEncoder().encode(cleared).write(to: folder.appendingPathComponent(draftStem + ".json"), options: [.atomic, .completeFileProtection])
            let file = folder.appendingPathComponent(draftStem + ".jpg")
            if FileManager.default.fileExists(atPath: file.path) { try? FileManager.default.removeItem(at: file) }
            for id in [jobID, previousRecognitionJobID].compactMap({ $0 }) { ai.markConsumed(id) }
            previousRecognitionJobID = nil
            return true
        } catch { cameraMessage = "重拍准备未保存，当前照片和内容已保留，请稍后重试。"; return false }
    }

    private var draftFolder: URL? {
        guard let draftOwner else { return nil }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BojiClub/meal-drafts-user-\(draftOwner)", isDirectory: true)
    }
    /// Cheap per-render change key for the debounced draft writer. Keying the
    /// task on `draftData` re-encoded the whole draft to JSON on every keystroke;
    /// this struct has identical change semantics at a fraction of the cost.
    private var draftSignature: DraftSignature {
        DraftSignature(name: name, category: category, calories: calories, protein: protein, carbs: carbs, fat: fat,
                       fraction: fraction, jobID: jobID, sourceJobID: sourceJobID, estimateNotes: estimateNotes,
                       photoAttached: photo != nil, mealDescription: mealDescription, textEntry: entryMode == "语音",
                       multipleMeals: multipleMeals, previousRecognitionJobID: previousRecognitionJobID)
    }
    private var draftData: Data? {
        try? JSONEncoder().encode(MealEditorDraft(id:draftID,name:name,category:category,calories:calories,protein:protein,carbs:carbs,fat:fat,components:components,fraction:fraction,jobID:jobID,sourceJobID:sourceJobID,estimateNotes:estimateNotes,photoAttached:photo != nil,createdAt:draftCreatedAt,mealDescription:mealDescription.isEmpty ? nil : mealDescription,textEntry:entryMode == "语音",multipleMeals:multipleMeals,previousRecognitionJobID:previousRecognitionJobID))
    }
    private var draftStem: String { ClubDates.key(date) + "-" + draftID.uuidString.lowercased() }
    private func prepareDraftFolder() throws -> URL {
        guard var folder = draftFolder else { throw AccountError.message("请先登录再填写餐食。") }
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.protectionKey:FileProtectionType.complete])
        var values=URLResourceValues();values.isExcludedFromBackup=true;try folder.setResourceValues(values)
        return folder
    }
    @discardableResult
    private func persistDraft() -> Bool {
        guard draftLoaded,draftReadable,!saved,draftOwner == store.editingAccountID,let data=draftData else { return false }
        guard !mealDescription.isEmpty || !name.isEmpty || photo != nil || !components.isEmpty || jobID != nil || [calories,protein,carbs,fat].contains(where:{$0>0}) || restoredDraft else { return true }
        do {
            let folder=try prepareDraftFolder()
            if legacyDraftFile != nil, let photo { try photo.write(to:folder.appendingPathComponent(draftStem+".jpg"),options:[.atomic,.completeFileProtection]) }
            var updated = try JSONDecoder().decode(MealEditorDraft.self,from:data); updated.updatedAt=Date()
            try JSONEncoder().encode(updated).write(to:folder.appendingPathComponent(draftStem+".json"),options:[.atomic,.completeFileProtection])
            if let legacyDraftFile {
                try? FileManager.default.removeItem(at:legacyDraftFile)
                try? FileManager.default.removeItem(at:legacyDraftFile.deletingPathExtension().appendingPathExtension("jpg"))
                self.legacyDraftFile = nil
            }
            return true
        }
        catch { cameraMessage="草稿暂未保存，请保留当前页面后重试。"; return false }
    }
    private func persistDraftPhoto() {
        guard draftLoaded,draftReadable,!saved,draftOwner == store.editingAccountID,let photo else { return }
        do { let folder=try prepareDraftFolder();try photo.write(to:folder.appendingPathComponent(draftStem+".jpg"),options:[.atomic,.completeFileProtection]) }
        catch { cameraMessage="草稿照片暂未保存，请保留当前页面后重试。" }
    }
    private func clearDraft() {
        guard draftReadable,let folder=draftFolder else { return }
        for ext in ["json","jpg"] { try? FileManager.default.removeItem(at:folder.appendingPathComponent(draftStem+"."+ext)) }
        if let legacyDraftFile {
            try? FileManager.default.removeItem(at:legacyDraftFile)
            try? FileManager.default.removeItem(at:legacyDraftFile.deletingPathExtension().appendingPathExtension("jpg"))
        }
    }
    private func restoreDraft() {
        guard !draftLoaded else { return };draftOwner=store.editingAccountID
        category = requestedCategory ?? MealCategorySuggestion.recommended(for: date, meals: store.log(for: date).meals)
        if let id = initialJobID {
            guard let job = ai.job(id), job.request.kind == "food", !job.consumed, !store.hasAppliedAIJob(id),
                  job.request.date == ClubDates.key(date) else { draftLoaded = true; draftReadable = false; cameraMessage = "这份识别结果已处理或暂未恢复，请返回处理进度重试。"; return }
            do {
                if let folder = draftFolder, FileManager.default.fileExists(atPath: folder.path),
                   let existing = try availableDrafts(in: folder).first(where: { $0.draft.jobID == id || $0.draft.sourceJobID == id }) {
                    _ = restore(existing); captureMode = false; return
                }
            } catch { draftLoaded = true; draftReadable = false; cameraMessage = "原草稿暂不可读，文件已保留。"; return }
            jobID = id; sourceJobID = id; draftID = UUID(uuidString: id) ?? UUID()
            mealDescription = job.request.payload["description"]?.string ?? ""
            photo = job.request.payload["image_base64"]?.string.flatMap { Data(base64Encoded: $0) }
            entryMode = job.request.payload["source"]?.string == "text" ? "语音" : "照片"
            captureMode = false; draftLoaded = true
            applyResult(); _ = persistDraft()
            return
        }
        if let prefilled {
            guard !store.hasAppliedAIJob(prefilled.sourceID),
                  MealBatchIdentity.parentID(prefilled.sourceID).map({ !store.hasAppliedAIJob($0) && ai.job($0)?.consumed != true }) == true else {
                draftLoaded = true; draftReadable = false; cameraMessage = "这餐已处理，请返回分餐列表。"; return
            }
            do {
                if let folder = draftFolder, FileManager.default.fileExists(atPath: folder.path) {
                    // Search all days: a reviewed child may have been moved to another date.
                    var matches: [MealDraftChoice] = []
                    for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) where file.pathExtension == "json" {
                        let data = try Data(contentsOf: file)
                        do {
                            let draft = try JSONDecoder().decode(MealEditorDraft.self, from: data)
                            if draft.sourceJobID == prefilled.sourceID { matches.append(MealDraftChoice(draft: draft, file: file)) }
                        } catch is DecodingError {
                            cameraMessage = "有一份旧草稿格式损坏，原文件已保留；其他餐食仍可继续核对。"
                        }
                    }
                    if let choice = matches.max(by: { ($0.draft.updatedAt ?? $0.draft.createdAt ?? .distantPast) < ($1.draft.updatedAt ?? $1.draft.createdAt ?? .distantPast) }) {
                        if let restoredDate = ClubDates.date(fromKey: String(choice.file.lastPathComponent.prefix(10))) { date = restoredDate }
                        if !restore(choice) { draftLoaded = true; draftReadable = false }; return
                    }
                }
                let item = prefilled.item
                name = item.name; category = item.category; calories = item.calories; protein = item.protein
                carbs = item.carbs; fat = item.fat; components = item.components; estimateNotes = item.notes
                sourceJobID = prefilled.sourceID; entryMode = "手动"; captureMode = false
                draftLoaded = true; persistDraft(); return
            } catch { draftLoaded = true; draftReadable = false; cameraMessage = "分餐草稿暂时无法读取，文件已保留，请解锁手机后重试。"; return }
        }
        guard let folder=draftFolder, FileManager.default.fileExists(atPath:folder.path) else { draftLoaded=true; return }
        do {
            for id in MealDraftLibrary.abandonedJobIDs(in: folder) { ai.markConsumed(id) }
            draftChoices = try availableDrafts(in: folder)
            if draftChoices.isEmpty { draftLoaded=true }
            else if draftChoices.filter({ $0.draft.category == category }).count == 1,
                    let matching = draftChoices.first(where: { $0.draft.category == category }) { if !restore(matching) { showDraftChoices = true } }
            else { showDraftChoices=true }
        } catch { draftReadable=false;draftLoaded=true;cameraMessage="原草稿暂时无法读取，文件已保留。请解锁手机后重试。" }
    }
    private func availableDrafts(in folder: URL) throws -> [MealDraftChoice] {
        try MealDraftLibrary.choices(in: folder, dateKey: ClubDates.key(date), category: category).filter { choice in
            !store.log(for:date).meals.contains(where:{$0.id == choice.draft.id}) &&
            ![choice.draft.jobID,choice.draft.sourceJobID].compactMap({$0}).contains(where:store.hasAppliedAIJob) &&
            choice.draft.sourceJobID.flatMap(MealBatchIdentity.parentID) == nil
        }
    }
    private func loadDraftChoices() {
        guard let folder = draftFolder, draftOwner == store.editingAccountID else { return }
        do { draftChoices = try availableDrafts(in: folder) } catch { cameraMessage = "草稿读取失败，原文件已保留。" }
    }
    private func startNewDraft() {
        speech.stop(); mealDescription = ""; multipleMeals = false
        draftLoaded = false
        draftID = UUID(); draftCreatedAt = Date(); name = ""; photo = nil; photoItem = nil
        calories = 0; protein = 0; carbs = 0; fat = 0; components = []; fraction = 1
        jobID = nil; sourceJobID = nil; previousRecognitionJobID = nil; estimateNotes = []; restoredDraft = false; legacyDraftFile = nil
        category = requestedCategory ?? MealCategorySuggestion.recommended(for: date, meals: store.log(for:date).meals)
        draftReadable = true; draftLoaded = true
    }
    private func deleteDraft(_ choice: MealDraftChoice) {
        guard let folder = draftFolder, draftOwner == store.editingAccountID else { return }
        do {
            try MealDraftLibrary.remove(choice, in: folder)
            for id in MealDraftLibrary.abandonedJobIDs(in: folder) { ai.markConsumed(id) }
            if choice.draft.id == draftID { startNewDraft() }
            loadDraftChoices()
        } catch { cameraMessage = "草稿未能删除，请解锁手机后重试。" }
    }
    private func restore(_ choice: MealDraftChoice) -> Bool {
        guard draftOwner == store.editingAccountID else { return false }
        do {
            let draft=choice.draft
            let photoFile=choice.file.deletingPathExtension().appendingPathExtension("jpg")
            let restoredPhoto: Data? = draft.photoAttached != false && FileManager.default.fileExists(atPath:photoFile.path) ? try Data(contentsOf:photoFile) : nil
            draftLoaded = false; legacyDraftFile = nil; photo = restoredPhoto
            draftCreatedAt = draft.createdAt ?? draft.updatedAt ?? Date()
            draftID=draft.id;name=draft.name;category=draft.category;calories=draft.calories;protein=draft.protein;carbs=draft.carbs;fat=draft.fat
            restoredDraft = true
            components=draft.components;fraction=draft.fraction;jobID=draft.jobID;sourceJobID=draft.sourceJobID;estimateNotes=draft.estimateNotes
            mealDescription = draft.mealDescription ?? ""
            previousRecognitionJobID = draft.previousRecognitionJobID
            multipleMeals = draft.multipleMeals ?? (ai.job(draft.jobID)?.request.payload["mode"]?.string == "multiple")
            entryMode = draft.textEntry == true ? "语音" : restoredPhoto != nil ? "照片" : "手动"
            captureMode = entryMode == "照片"
            if choice.file.deletingPathExtension().lastPathComponent != draftStem { legacyDraftFile=choice.file }
            draftReadable=true;draftLoaded=true;persistDraft();applyResult();return true
        } catch { cameraMessage="原草稿暂时无法读取，文件已保留。请解锁手机后重试。"; return false }
    }

    private func macro(_ name: String, _ value: Double) -> some View {
        VStack(alignment: .leading, spacing: BojiLayout.tight) {
            Text(name).bojiType(.caption).foregroundStyle(.secondary)
            Text("\(value.formatted(.number.precision(.fractionLength(0...1)))) g").bojiType(.bodyStrong)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var mealInputProblem: String? {
        EntryValidation.meal(name: name,
            nutrition: [total(\.calories, fallback: calories), total(\.protein, fallback: protein), total(\.carbs, fallback: carbs), total(\.fat, fallback: fat)],
            componentsValid: portionInputsValid && components.allSatisfy(\.valid))
    }
    private var bottomActionReason: String? {
        if prefilled?.invalidOriginalDate != nil, !repairedDateConfirmed { return "请先确认这餐的实际日期。" }
        if saved { return "这餐已经保存，请在饮食记录中查看或修改。" }
        if !draftLoaded { return "正在准备餐食草稿…" }
        if draftOwner == nil || draftOwner != store.editingAccountID { return "请在当前登录账号重新打开这餐。" }
        if !draftReadable { return "草稿暂时无法读取，原内容已保留；请解锁手机后重新打开。" }
        if ClubDates.isFuture(date) { return "未来日期不能记录饮食，请选择今天或过去的日期。" }
        if loadingPhoto { return "正在读取照片，完成后可以继续。" }
        if speech.isFinishing { return "正在整理识别文字，请稍候…" }
        if speech.isPreparing { return "正在准备语音输入…" }
        if speech.isRecording { return "请先结束录音，再核对并保存。" }
        if isBusy { return "正在识别，可以等待结果，或停止识别后改为手动记录。" }
        if entryMode == "语音" && multipleMeals {
            return canUseBottomAction ? nil : "请先识别这段多餐描述，再逐餐核对保存；已保存的餐食不会重复登记。"
        }
        if ai.job(jobID)?.result?.kind == "meal_batch" { return "这次包含多餐，请进入逐餐核对后保存。" }
        if let issue = mealInputProblem { return issue }
        if !canSave { return "这份识别可能已保存，或原描述尚未核对；请查看原记录，或重新识别后再保存。" }
        return nil
    }
    private var canSave: Bool {
        (prefilled?.invalidOriginalDate == nil || repairedDateConfirmed) && ai.job(jobID)?.result?.kind != "meal_batch" && !(entryMode == "语音" && multipleMeals) && prefilled.map({ !store.hasAppliedAIJob($0.sourceID) }) != false &&
        sourceJobID.flatMap(MealBatchIdentity.parentID).map({ !store.hasAppliedAIJob($0) && ai.job($0)?.consumed != true }) != false &&
        !ClubDates.isFuture(date) && draftLoaded && draftReadable && draftOwner != nil && draftOwner == store.editingAccountID && mealInputProblem == nil &&
        (entryMode != "语音" || mealDescription.isEmpty || sourceJobID != nil || name == String(mealDescription.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))) &&
        !saved
    }
    private var isBusy: Bool {
        ai.job(jobID).map { !$0.isTerminal && !$0.isWaiting } ?? false
    }
    private var hasNutritionValues: Bool { if components.contains(where: { ($0.uncertaintyFlags ?? []).contains("nutrition_unknown") }) { return false }; return [total(\.calories,fallback:calories),total(\.protein,fallback:protein),total(\.carbs,fallback:carbs),total(\.fat,fallback:fat)].contains { $0 > 0 } }
    private func setPhoto(_ image: UIImage) {
        let shouldRecognize = entryMode != "手动"
        speech.stop()
        guard draftLoaded, draftOwner != nil, draftOwner == store.editingAccountID, !isBusy else { return }
        let scale = min(1, 1024 / max(image.size.width, image.size.height))
        let size = CGSize(width: max(1, image.size.width * scale), height: max(1, image.size.height * scale))
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        photo = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }.jpegData(compressionQuality: 0.65)
        let hadEstimate = sourceJobID != nil || components.contains { ["visible", "assumed"].contains($0.basis) }
        if let jobID { ai.markConsumed(jobID) }
        jobID = nil; sourceJobID = nil
        if hadEstimate {
            name = ""; calories = 0; protein = 0; carbs = 0; fat = 0; components = []; fraction = 1; estimateNotes = []
            cameraMessage = "照片已更换，上一张照片的估算已清空。"
        }
        if persistDraft(), shouldRecognize { identify() }
    }
    private func identify(forceNew: Bool = false) {
        guard let photo else { return }
        let context = name
        do {
            let submitted = try ai.submit(AIInput(kind: "food", date: ClubDates.key(date), payload: ["image_base64": .string(photo.base64EncodedString()), "context": .string(context), "draft_id": .string(draftID.uuidString.lowercased())]), forceNew: forceNew)
            if forceNew, let previous=jobID, previous != submitted { ai.markConsumed(previous) }
            jobID=submitted
            if ai.job(jobID)?.consumed == true { cameraMessage = "这张照片已记录，可在饮食历史中修改原记录。" }
            applyResult()
        } catch { cameraMessage = AppErrorText.message(error) }
    }
    private func applyResult() {
        if let jobID, !store.hasAppliedAIJob(jobID), ai.job(jobID)?.consumed != true,
           ai.job(jobID)?.result?.kind == "meal_batch" {
            if !(ai.job(jobID)?.result?.meals?.isEmpty ?? true), finishReplacingRecognition(jobID) { showBatchReview = true }
            return
        }
        guard !saved, let jobID, let job = ai.job(jobID), sourceJobID != job.id, !job.consumed, !store.hasAppliedAIJob(job.id),
              job.status == "succeeded", let result = job.result, result.is_food == true else { return }
        guard finishReplacingRecognition(job.id) else { return }
        name = result.name ?? "餐食"; calories = result.calories ?? 0; protein = result.protein ?? 0
        carbs = result.carbs ?? 0; fat = result.fat ?? 0; components = result.components ?? []; fraction = 1
        sourceJobID = job.id; estimateNotes = result.notes
        descriptionFocused = false
        recognitionFeedback &+= 1
        ClubAccessibility.announce("识别完成，请核对食物名称、份量和营养数据。")
    }
    private func save(unknownNutrition: Bool = false, acceptingExistingEstimate: Bool = false) {
        guard canSave, !saved, !isBusy, !loadingPhoto, !speech.isRecording, !speech.isPreparing else { return }
        if estimateIsStale && !acceptingExistingEstimate { confirmExistingEstimate = true; return }
        var notes = estimateNotes
        if estimateIsStale { notes.append("描述修改后保留了此前估算，已由用户核对；营养仍为估算。") }
        let meal = Meal(id: draftID, name: name.trimmingCharacters(in: .whitespacesAndNewlines), category: category,
            calories: total(\.calories, fallback: calories), protein: total(\.protein, fallback: protein),
            carbs: total(\.carbs, fallback: carbs), fat: total(\.fat, fallback: fat), sourceAIJobID: sourceJobID,
            estimated: sourceJobID == nil ? nil : true, estimateNotes: notes.isEmpty ? nil : notes,
            components: components.isEmpty ? nil : components, consumedFraction: components.isEmpty ? nil : fraction,
            nutritionKnown: unknownNutrition ? false : true)
        let handled = Array(Set([jobID,ai.job(jobID)?.id,sourceJobID,previousRecognitionJobID].compactMap { $0 }))
        if store.addMeal(meal, photo: photo, on: date, handledAIJobIDs: handled) {
            saved = true
            for id in handled { ai.markConsumed(id) }
            clearDraft(); onSaved?(); dismiss()
        } else { cameraMessage = store.takeMessage(fallback: "保存失败，请重试。") }
    }
    private func valueRow(_ title: String, value: Binding<Double>, unit: String) -> some View {
        HStack {
            Text(title); Spacer()
            TextField("0", value: value, format: .number.precision(.fractionLength(0...1)))
                .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(minWidth: 80, maxWidth: 150)
                .accessibilityLabel("\(title)，\(unit == "kcal" ? "千卡" : "克")")
            Text(unit).foregroundStyle(.secondary)
        }
    }
}
