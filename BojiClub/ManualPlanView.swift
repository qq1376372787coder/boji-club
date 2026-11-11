import SwiftUI

private struct ManualPlanPreview: Identifiable {
    let id = UUID()
    let draft: ManualPlanDraft
    let baseline: [String: DayLog]
}

/// AUD-014/FIX-014：保留原草稿为模板是载入的前置步骤；失败必须停止。
enum ManualPlanImportRules {
    static func mayLoad(keepPrevious: Bool, templateSaved: Bool) -> Bool {
        !keepPrevious || templateSaved
    }
    static let templateFailure = "原草稿未能保存为模板，已停止载入；当前草稿保持不变。请重试或先复制草稿。"
}

struct ManualPlanView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var ai: AIService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    let initialDraft: ManualPlanDraft?
    let startDate: Date
    let singleDay: Bool
    let openTemplates: Bool
    let onSaved: (() -> Void)?
    init(initialDraft: ManualPlanDraft? = nil, startDate: Date = Date(), singleDay: Bool = false, openTemplates: Bool = false, onSaved: (() -> Void)? = nil) {
        self.initialDraft = initialDraft; self.startDate = startDate; self.singleDay = singleDay; self.openTemplates = openTemplates; self.onSaved = onSaved
    }
    @State private var confirmImport = false
    @State private var draft = ManualPlanDraft()
    @State private var owner: Int?
    @State private var loaded = false
    @State private var error: String?
    @State private var selectedDay = 0
    @State private var selectingMovement = false
    @State private var repeatConfirmation = false
    @State private var copyConfirmation = false
    @State private var restConfirmation = false
    @State private var copySource: Int?
    @State private var preview: ManualPlanPreview?
    @State private var showTemplates = false
    @State private var batchSelection: [LibraryExercise] = []
    @State private var advanced = false
    @State private var templates: [ManualPlanTemplate] = []
    @State private var templateIssues = 0
    @State private var pendingTemplate: ManualPlanTemplate?
    @State private var deletingTemplate: ManualPlanTemplate?
    @State private var templateNotice: String?
    @State private var templateDecisionPresented = false

    var body: some View {
        ClubNavigationStack132 {
            ScrollView {
                VStack(alignment: .leading, spacing: ClubUI.sectionSpacing) {
                    Text(singleDay ? "安排这一天" : "搭好一周，再重复").bojiFont(.pageTitle).foregroundStyle(BojiColor.textPrimary)
                    Text("先添加动作，组次可以继续调整。")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text(error == nil ? "草稿自动保存" : "请检查保存提示").font(.caption).foregroundStyle(.secondary)
                    if loaded { configuration; if !singleDay { daySelector }; dayEditor }
                    if let error { FlowError(message: error) }
                    if !loaded { Button("重新读取草稿", action: load).buttonStyle(SecondaryButton()) }
                }.padding(ClubUI.pageInset).frame(maxWidth: ClubUI.contentWidth).frame(maxWidth: .infinity)
            }.scrollDismissesKeyboard(.interactively).background { ClubBackground() }
                .navigationTitle("自由创建计划").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) {
                    Button("保存并关闭") { if !loaded || saveDraft() { dismiss() } }
                } }
                .safeAreaInset(edge: .bottom) {
                    if loaded { Button(singleDay ? "保存当天安排" : "保存计划", action: saveOrPreview).buttonStyle(PrimaryButton()).padding(BojiSpace.pageInset).background(.regularMaterial) }
                }
                .onAppear { if owner == nil { load(); if openTemplates { refreshTemplates(); showTemplates = true } } }
                .task(id: draft) { guard loaded else { return }; do { try await Task.sleep(for: .milliseconds(450)); _ = saveDraft() } catch { } }
                .onChange(of: draft.editingDuration) { _, value in selectedDay = min(selectedDay, value - 1) }
                .onChange(of: store.editingAccountID) { _, value in if owner != value { preview = nil; dismiss() } }
                .alert("用这份方案创建可编辑草稿？", isPresented: $confirmImport) {
                    Button("先保留原草稿为模板，再载入") { importDraft(keepPrevious: true) }
                    Button("替换当前草稿", role: .destructive) { importDraft(keepPrevious: false) }
                    Button("取消", role: .cancel) { dismiss() }
                } message: { Text("已采用的日程与历史记录保持原样；编辑后仍需预览并确认。") }
                .sheet(isPresented: $selectingMovement) { movementPicker }
                .sheet(item: $preview) { previewContent($0) }
                .sheet(isPresented: $showTemplates) { templateLibrary }
                .confirmationDialog("用第一周覆盖草稿的后续周？", isPresented: $repeatConfirmation, titleVisibility: .visible) {
                    Button("重复第一周") { draft.repeatFirstWeek() }
                    Button("取消", role: .cancel) { }
                } message: { Text("只修改这份草稿，不影响已保存的训练日程。") }
                .confirmationDialog("覆盖正在编辑这一天的草稿？", isPresented: $copyConfirmation, titleVisibility: .visible) {
                    Button("复制到这一天") { if let source = copySource { draft.copyDay(from: source, to: selectedDay) }; copySource = nil }
                    Button("取消", role: .cancel) { copySource = nil }
                } message: { Text("其他日期和已经采用的计划不受影响。") }
                .confirmationDialog("把第 \(selectedDay + 1) 天设为休息日？", isPresented: $restConfirmation, titleVisibility: .visible) {
                    Button("设为休息日", role: .destructive) { draft.setRestDay(at: selectedDay) }
                    Button("取消", role: .cancel) { }
                } message: {
                    Text("会清空这一天草稿中的标题、待配置标记和 \(draft.days[selectedDay].movements.count) 个动作。只影响这份草稿，已采用的计划和训练记录不变。")
                }
        }
        .interactiveDismissDisabled(loaded && error != nil)
    }

    private var startDatePicker: some View {
        DatePicker(singleDay ? "训练日期" : "开始日期", selection: Binding(get: { ClubDates.date(fromKey: draft.start) ?? startDate }, set: { draft.start = ClubDates.key($0) }), in: ClubDates.calendar.startOfDay(for: Date())..., displayedComponents: .date)
            .datePickerStyle(.compact)
    }

    private var configuration: some View {
        ClubCard {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) {
                    Text(singleDay ? "训练日期" : "开始日期").font(.headline)
                    startDatePicker.labelsHidden().dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                }
            } else { startDatePicker }
            if let start = ClubDates.date(fromKey: draft.start), ClubDates.key(start) < ClubDates.key(Date()) {
                Text("草稿开始日期已过去，动作已保留。请选择新的开始日期。")
                    .font(.subheadline).foregroundStyle(.orange)
                Button("从今天继续") { draft.start = ClubDates.key(Date()) }.buttonStyle(SecondaryButton())
            }
            if !singleDay {
                Picker("重复范围", selection: $draft.duration) {
                    Text("一周").tag(7); Text("两周").tag(14); Text("四周").tag(28)
                }.clubAdaptivePicker()
                if draft.duration > 7 { Button("后续周沿用第一周") { repeatConfirmation = true }.buttonStyle(SecondaryButton()) }
            }
            DisclosureGroup("名称、备注与更多设置", isExpanded: $advanced) {
                VStack(alignment: .leading, spacing: 14) {
                    TextField("计划名称", text: $draft.title)
                    TextField("备注（可选）", text: Binding(get: { draft.planDescription ?? "" }, set: { draft.planDescription = String($0.prefix(200)) }), axis: .vertical)
                    if !singleDay { cyclePatternSection }
                    Button("保存为模板", action: saveTemplate).buttonStyle(SecondaryButton())
                    Button("我的模板") { refreshTemplates(); showTemplates = true }.buttonStyle(SecondaryButton())
                    if let templateNotice { Text(templateNotice).font(.caption).foregroundStyle(.secondary) }
                    if draft.proposalJobID != nil {
                        Button("转为自己安排，重新核对") { draft = draft.reusable(start: ClubDates.date(fromKey: draft.start) ?? Date()) }.buttonStyle(SecondaryButton())
                    }
                }.padding(.top, BojiSpace.general)
            }
        }
    }

    private var templateLibrary: some View {
        ClubNavigationStack132 {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    Text("复用动作安排，重新确认日期").bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
                    Text("保存在当前账号的模板，联网后同步。选择后会替换正在编辑的草稿；已采用的日程仍需预览确认才会更改。")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text("同步状态：\(store.syncStatus.label)")
                        .font(.caption).foregroundStyle(BojiColor.textTertiary)
                    if templates.isEmpty { EmptyNote(title: "还没有模板", detail: "在自由计划中搭好动作，点击“保存为模板”。") }
                    ForEach(templates) { value in
                        ClubCard {
                            Text(value.draft.title).bojiFont(.exerciseName).foregroundStyle(BojiColor.textPrimary)
                            Text("\(value.draft.duration) 天 · \(value.draft.activeDays.filter { !$0.movements.isEmpty }.count) 个训练日")
                                .font(.subheadline).foregroundStyle(.secondary)
                            Button("用这套安排创建") { deletingTemplate = nil; pendingTemplate = value; templateDecisionPresented = true }.buttonStyle(SecondaryButton())
                            Button("删除模板", role: .destructive) { pendingTemplate = nil; deletingTemplate = value; templateDecisionPresented = true }.buttonStyle(SecondaryButton())
                        }
                    }
                    if let notice = store.planMigrationNotice { Text(notice).font(.footnote).foregroundStyle(.orange) }
            else if templateIssues > 0 { Text("有 \(templateIssues) 份模板暂时无法读取，原文件已保留。").font(.footnote).foregroundStyle(.secondary) }
                    if let error { FlowError(message: error) }
                }.padding(ClubUI.pageInset)
            }.background { ClubBackground() }.navigationTitle("我的计划模板")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { showTemplates = false } } }
                .alert(pendingTemplate == nil ? "删除这份模板？" : "使用模板替换当前草稿？", isPresented: $templateDecisionPresented) {
                    if pendingTemplate != nil {
                        Button("替换草稿", action: usePendingTemplate)
                    } else { Button("删除", role: .destructive, action: deletePendingTemplate) }
                    Button("取消", role: .cancel) { pendingTemplate = nil; deletingTemplate = nil }
                } message: {
                    Text(pendingTemplate == nil ? "只删除模板，已经采用的计划与训练记录保留。" : "将载入“\(pendingTemplate?.draft.title ?? "")”，开始日期先设为今天，可继续修改。当前草稿如需保留，请先返回保存为模板。")
                }
        }
    }
    private func usePendingTemplate() {
        guard let value = pendingTemplate, let owner, owner == store.editingAccountID else { return }
        var next = value.draft.reusable(start: startDate)
        next.singleDay = singleDay
        if singleDay, let first = value.draft.activeDays.first(where: { !$0.movements.isEmpty }) { next.days[0] = first }
        if store.saveSyncedPlanDraft(next) {
            draft = next; selectedDay = 0; pendingTemplate = nil; showTemplates = false; error = nil
        } else { self.error = store.takeMessage(fallback: "草稿未能保存，请重试。"); pendingTemplate = nil }
    }
    private func deletePendingTemplate() {
        guard let id = deletingTemplate?.id, let owner, owner == store.editingAccountID else { return }
        if store.deleteSyncedPlanTemplate(id) { refreshTemplates(); deletingTemplate = nil }
        else { self.error = store.takeMessage(fallback: "模板未能删除，请重试。") }
    }
    private func refreshTemplates() {
        guard let owner, owner == store.editingAccountID else { return }
        store.migrateLocalPlanStorageIfNeeded(owner: owner)
        templates = store.syncedPlanTemplates()
        // 迁移读取问题不静默：显示在模板库，原文件保留。
        templateIssues = store.planMigrationNotice == nil ? 0 : 1
    }
    private func saveTemplate() {
        guard let owner, owner == store.editingAccountID, saveDraft() else { return }
        // 防重复：同一草稿内容不重复存模板（双击只存一份）。
        if store.syncedPlanTemplates().contains(where: { $0.draft == draft }) {
            templateNotice = "这份安排已经在“我的模板”里了。"
            return
        }
        let value = ManualPlanTemplate(createdAt: Date(), draft: draft)
        if store.saveSyncedPlanTemplate(value) { templateNotice = "模板已保存，可在“我的模板”复用" }
        else { self.error = store.takeMessage(fallback: "模板未能保存，请重试。") }
    }

    // E2/E3：循环编排。预览→确认→只填空白日；续排范围写入草稿。
    @State private var cyclePattern: PlanCyclePattern = .on2off1
    @State private var cycleWeekdays: Set<Int> = [1, 3, 5]
    @State private var customCycle: [Bool] = [true, true, false]
    @State private var patternPreviewShown = false

    private var cyclePatternSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("安排方式（可选）").font(.subheadline.weight(.semibold))
            Picker("编排方式", selection: $cyclePattern) {
                ForEach(PlanCyclePattern.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.menu)
            if cyclePattern.needsWeekdays {
                // 小屏可横向滚动，七枚星期胶囊不挤压（核查 §6）。
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(1...7, id: \.self) { weekday in
                            Button(["一","二","三","四","五","六","日"][weekday - 1]) {
                                if cycleWeekdays.contains(weekday) { cycleWeekdays.remove(weekday) } else { cycleWeekdays.insert(weekday) }
                            }
                            .buttonStyle(BojiButtonStyle(kind: cycleWeekdays.contains(weekday) ? .primary : .secondary))
                            .font(.caption)
                        }
                    }
                }
            }
            if cyclePattern.needsCustomCycle {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(customCycle.enumerated()), id: \.offset) { index, isTraining in
                            Button(isTraining ? "练" : "休") {
                                customCycle[index].toggle()
                            }
                            .buttonStyle(BojiButtonStyle(kind: isTraining ? .primary : .secondary))
                            .font(.caption)
                        }
                        Button("+1") { customCycle.append(true) }.font(.caption)
                            .buttonStyle(BojiButtonStyle(kind: .secondary)).disabled(customCycle.count >= 8)
                        Button("-1") { if customCycle.count > 2 { customCycle.removeLast() } }.font(.caption)
                            .buttonStyle(BojiButtonStyle(kind: .secondary)).disabled(customCycle.count <= 2)
                    }
                }
            }
            Button(patternPreviewShown ? "收起预览" : "查看安排日期") { patternPreviewShown.toggle() }
                .buttonStyle(BojiButtonStyle(kind: .secondary))
            if patternPreviewShown {
                let dates = draft.patternPreview(cyclePattern, weekdays: cycleWeekdays, customCycle: customCycle)
                Text(dates.isEmpty ? "当前设置下没有训练日。" : dates.joined(separator: "、"))
                    .font(.caption).foregroundStyle(.secondary)
                Button("按已有训练日复制到空白日期") {
                    _ = draft.fillPattern(cyclePattern, weekdays: cycleWeekdays, customCycle: customCycle)
                    patternPreviewShown = false
                }.buttonStyle(BojiButtonStyle(kind: .secondary)).disabled(!draft.activeDays.contains { !$0.movements.isEmpty })
                if !draft.activeDays.contains(where: { !$0.movements.isEmpty }) { Text("先为一天添加动作，再将这套动作复制到循环日期。").font(.caption).foregroundStyle(.secondary) }
            }
            if let label = draft.planPatternLabel {
                Text("安排范围：\(label)").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    /// 日期标签：待配置训练日与休息日明确区分（F3）。
    private func dayTag(_ index: Int) -> String {
        let day = draft.days[index]
        if !day.movements.isEmpty { return "\(day.movements.count) 动作" }
        if day.isUnconfiguredPlaceholder { return "待配置" }
        return "未安排"
    }

    private var daySelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(0..<draft.editingDuration, id: \.self) { index in
                    Button { selectedDay = index } label: {
                        VStack(spacing: 5) {
                            Text(draft.dateKey(offset: index).flatMap(ClubDates.date(fromKey:)).map { ClubDates.label($0, format: "M/d EEE") } ?? "第 \(index + 1) 天").font(.subheadline.weight(.semibold))
                            Text(dayTag(index)).font(.caption)
                        }.padding(BojiSpace.general).frame(minWidth: 70, minHeight: 54)
                            .foregroundStyle(selectedDay == index ? BojiColor.pageBackground : BojiColor.textPrimary)
                            .background(selectedDay == index ? BojiColor.textPrimary : BojiColor.cardSurface, in: RoundedRectangle(cornerRadius: BojiRadius.inner))
                    }.buttonStyle(ClubMotionButton()).accessibilityAddTraits(selectedDay == index ? .isSelected : [])
                }
            }
        }
    }

    private var dayEditor: some View {
        ClubCard {
            Text(draft.dateKey(offset: selectedDay).flatMap(ClubDates.date(fromKey:)).map { ClubDates.label($0, format: "M月d日 EEEE") } ?? "请选择日期").bojiFont(.exerciseName)
            if !singleDay {
                Menu("复制、交换与休息日") {
                    Menu("复制其他日期到这一天") {
                        ForEach((0..<draft.editingDuration).filter { $0 != selectedDay }, id: \.self) { source in
                            Button("第 \(source + 1) 天 · \(draft.days[source].movements.count) 个动作") {
                                if draft.days[selectedDay].movements.isEmpty { draft.copyDay(from: source, to: selectedDay) }
                                else { copySource = source; copyConfirmation = true }
                            }
                        }
                    }
                    Menu("与另一天交换") {
                        ForEach((0..<draft.editingDuration).filter { $0 != selectedDay }, id: \.self) { other in
                            Button("与第 \(other + 1) 天交换") { draft.swapDays(selectedDay, other) }
                        }
                    }
                    Button("设为休息日", role: .destructive) { restConfirmation = true }
                }.font(.subheadline).frame(minHeight: 44)
            }
            if draft.days[selectedDay].movements.isEmpty {
                Text(singleDay ? "添加动作，再按需要调整组次。" : "还没有动作。添加后可调整组次；重复计划中的空白日期会留给恢复。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach($draft.days[selectedDay].movements) { $movement in
                DisclosureGroup {
                    ManualMovementEditor(movement: $movement, moveUp: { move(movement.id, offset: -1) }, moveDown: { move(movement.id, offset: 1) }) {
                        draft.days[selectedDay].movements.removeAll { $0.id == movement.id }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(movement.name).font(.headline)
                        Text("\(movement.effectiveSets.count) 组 · " + (movement.unit == "秒" ? "每组 \(movement.seconds) 秒" : "每组 \(movement.reps) 次") + " · 点此调整").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Divider()
            }
            Button("添加动作") { batchSelection = []; selectingMovement = true }.buttonStyle(SecondaryButton())
                .accessibilityIdentifier("manual-add-from-library")
                .disabled(draft.days[selectedDay].movements.count >= 30)
        }
    }

    private var movementPicker: some View {
        ClubNavigationStack132 {
            ExerciseLibraryView(date: ClubDates.date(fromKey: draft.start) ?? Date(), selectionAction: { item in
                if let index = batchSelection.firstIndex(where: { $0.id == item.id }) { batchSelection.remove(at: index) }
                else if batchSelection.count + draft.days[selectedDay].movements.count < 30 { batchSelection.append(item) }
            }, selectedIDs: Set(batchSelection.map(\.id)), added: { })
                .navigationTitle("选择动作")
                .toolbar { ToolbarItem(placement: .cancellationAction) { DismissButton() } }
                .safeAreaInset(edge: .bottom) {
                    Button("添加 \(batchSelection.count) 个动作") { addSelectedMovements() }
                        .buttonStyle(PrimaryButton()).disabled(batchSelection.isEmpty).padding(BojiSpace.pageInset).background(.regularMaterial)
                }
        }
    }
    private func addSelectedMovements() {
        guard owner == store.editingAccountID else { return }
        for item in batchSelection {
            let sets: [TrainingSet]
            if let id = item.customID {
                guard let definition = store.customExercises.first(where: { $0.id == id }) else { error = "个人动作已变化，请重新选择。"; return }
                sets = definition.exercise().sets
            } else { sets = ExerciseMeasurement.initialSets(name: item.displayName, query: item.name, recordingUnit: item.suggestedRecordingUnit, trainingType: item.trainingTypeZH) }
            let first = sets.first ?? TrainingSet()
            draft.days[selectedDay].movements.append(ManualPlanMovement(name: item.displayName, muscle: item.muscleLabel, query: item.customID == nil ? item.name : nil, libraryID: item.customID == nil ? item.id : nil, customID: item.customID, unit: first.durationSeconds == nil ? "次" : "秒", count: sets.count, weight: first.weight, reps: first.reps, seconds: first.durationSeconds ?? 30))
        }
        draft.days[selectedDay].placeholder = nil
        selectingMovement = false; batchSelection = []
    }

    private func previewContent(_ value: ManualPlanPreview) -> some View {
        ClubNavigationStack132 {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(value.draft.title).bojiFont(.pageTitle).foregroundStyle(BojiColor.textPrimary)
                    Text(value.draft.singleDay == true ? "只更新所选日期；其他日期保持原安排。" : "更新本周期的未开始安排，包括空白休息日。已开始的训练会保留。")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if let result = try? value.draft.result() {
                        let scope = (0..<value.draft.editingDuration).compactMap { value.draft.dateKey(offset: $0) }
                        ClubCard { ClubPlanChangesView(changes: ClubPlanChangeRules.preview(before: value.baseline,
                            sessions: result.sessions ?? [], scope: scope, replace: true)) }
                    }
                    DisclosureGroup("查看新计划的每日安排") {
                    ForEach(0..<value.draft.editingDuration, id: \.self) { index in
                        let key = value.draft.dateKey(offset: index) ?? ""
                        let day = value.draft.days[index]
                        ClubCard(compact: true) {
                            Text(key).bojiFont(.exerciseName).foregroundStyle(BojiColor.textPrimary)
                            Text(day.isRestDay ? "休息日" : day.title.isEmpty ? "自由训练" : day.title)
                            ForEach(day.movements) { movement in
                                Text("\(movement.name) · \(movement.effectiveSets.count) 组 · \(movement.individualSets == nil ? "相同目标" : "逐组目标")")
                                    .font(.subheadline)
                            }
                            if PlanAdoptionRules.isProtected(value.baseline[key] ?? DayLog()) {
                                Text("已有开始的训练，保留当天记录").font(.footnote).foregroundStyle(.secondary)
                            } else if !(value.baseline[key]?.exercises.isEmpty ?? true) {
                                Text("将替换当天旧安排").font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                    }
                    if let error { FlowError(message: error) }
                }.padding(ClubUI.pageInset)
            }.background { ClubBackground() }.navigationTitle("确认计划")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("返回编辑") { preview = nil } } }
                .safeAreaInset(edge: .bottom) {
                    Button("保存到训练日历", action: { apply(value) }).buttonStyle(PrimaryButton()).padding(BojiSpace.pageInset).background(.regularMaterial)
                }
        }
    }

    private func load() {
        guard let id = store.editingAccountID else { error = "请先登录后创建计划。"; return }
        owner = id
        store.migrateLocalPlanStorageIfNeeded(owner: id)
        // 旧草稿读取失败时，不允许用空白草稿覆盖原文件；保留恢复入口，稍后重试。
        if store.planDraftNeedsRecovery(owner: id) {
            loaded = false
            error = store.planMigrationNotice ?? "本机旧草稿暂时无法读取，原文件已保留；请稍后重试。"
            return
        }
        if let saved = store.syncedPlanDraft() {
            if store.hasAppliedAIJob(saved.operationID) {
                // 已采用的草稿归档后不再作为活动草稿；归档失败不阻塞清理入口。
                try? ManualPlanDraftStorage.archive(saved, owner: id)
                _ = store.clearSyncedPlanDraft(id: saved.id)
                draft = ManualPlanDraft()
            } else { draft = saved }
        } else { draft = ManualPlanDraft() }
        if initialDraft == nil && (draft.start != ClubDates.key(startDate) || (draft.singleDay == true) != singleDay) {
            if draft.activeDays.contains(where: { !$0.movements.isEmpty }) {
                guard store.saveSyncedPlanTemplate(ManualPlanTemplate(createdAt: Date(), draft: draft)) else { error = store.takeMessage(); return }
            }
            draft = ManualPlanDraft(); draft.start = ClubDates.key(startDate)
            templateNotice = "上次草稿已保留在我的模板中。"
        }
        draft.singleDay = singleDay
        if draft.title == "我的训练计划" { draft.title = singleDay ? ClubDates.label(startDate) + "训练" : "我的每周训练" }
        loaded = true; error = nil
        if store.invalidSyncedPlanDraftCount() > 0 {
            // 云端异常草稿已被跳过，原记录仍保留；不让界面按错误长度取下标。
            error = "云端有一份草稿结构不完整，已安全跳过并保留原记录。可以新建草稿，或稍后重试同步。"
        }
        if initialDraft != nil { confirmImport = true }
    }
    private func importDraft(keepPrevious: Bool) {
        guard let initialDraft, let owner, owner == store.editingAccountID else { return }
        var preservedTemplate = false
        if keepPrevious && draft.activeDays.contains(where: { !$0.movements.isEmpty }) {
            let value = ManualPlanTemplate(createdAt: Date(), draft: draft)
            // AUD-014/FIX-014：模板写入失败时停止载入，原草稿与当前编辑内容都保持不变。
            guard ManualPlanImportRules.mayLoad(keepPrevious: true, templateSaved: store.saveSyncedPlanTemplate(value)) else {
                self.error = store.takeMessage(fallback: ManualPlanImportRules.templateFailure)
                return
            }
            preservedTemplate = true
        }
        var copy = initialDraft.reusable(start: ClubDates.date(fromKey: initialDraft.start) ?? Date())
        copy.proposalJobID = initialDraft.proposalJobID
        copy.suggestedForProfile = initialDraft.suggestedForProfile
        if store.saveSyncedPlanDraft(copy) {
            draft = copy; selectedDay = 0; error = nil
        } else {
            let fallback = preservedTemplate
                ? "原草稿已保存为模板；新草稿保存失败，当前编辑内容未切换。请重试载入。"
                : "草稿未能保存，请重试；当前编辑内容保持不变。"
            self.error = store.takeMessage(fallback: fallback)
        }
    }
    private func move(_ id: UUID, offset: Int) {
        guard let index = draft.days[selectedDay].movements.firstIndex(where: { $0.id == id }),
              draft.days[selectedDay].movements.indices.contains(index + offset) else { return }
        draft.days[selectedDay].movements.swapAt(index, index + offset)
    }
    @discardableResult private func saveDraft() -> Bool {
        guard loaded, let owner, owner == store.editingAccountID else { return false }
        if store.saveSyncedPlanDraft(draft) { error = nil; return true }
        self.error = store.takeMessage(fallback: "草稿未保存，请保留页面并重试。")
        return false
    }
    private func checkProposalEvidence(_ value: ManualPlanDraft) throws {
        guard let id = value.proposalJobID else { return }
        guard let job = ai.job(id), job.status == "succeeded", let proposal = job.result?.coach?.proposal,
              let date = ClubDates.date(fromKey: job.request.date), ClubDates.key(date) == ClubDates.key(Date()),
              case .number(let span)? = job.request.payload["context_days"], [7.0,14.0].contains(span),
              job.request.payload["days"] != nil,
              proposal.baseline == ClubAdjustmentRules.upcoming(state: store.state, after: date) else {
            throw ManualPlanError.message("建议或未来安排已变化，请返回 AI 计划重新核对，或明确另建自由草稿。")
        }
        let session = job.result?.coach?.source_session.flatMap(UUID.init(uuidString:))
        let fresh = try ai.coachInput(question: "采用前核对记录依据", conversation: job.id, history: [],
            through: date, contextDays: Int(span), store: store, sessionID: session)
        guard fresh.payload["days"] == job.request.payload["days"] else {
            throw ManualPlanError.message("编辑期间原始记录已有变化，请重新核对建议后再采用；草稿仍保留。")
        }
    }
    private func saveOrPreview() {
        // 统一语义：保存总是进入预览确认，不再在无冲突时静默直接采用。
        preparePreview()
    }
    private func preparePreview() {
        do { try checkProposalEvidence(draft) } catch { self.error = error.localizedDescription; return }
        if let profile = draft.suggestedForProfile, profile != store.state.profile.aiProfile { error = "目标或训练条件已变化，请重新核对建议，或明确转为自由草稿后预览。"; return }
        if let message = draft.validation() { error = message; return }
        guard saveDraft() else { return }
        let baseline = Dictionary(uniqueKeysWithValues: (0..<draft.editingDuration).compactMap { index -> (String, DayLog)? in
            guard let key = draft.dateKey(offset: index) else { return nil }
            return (key, store.state.days[key] ?? DayLog())
        })
        if singleDay, PlanAdoptionRules.isProtected(baseline[draft.start] ?? DayLog()) {
            error = "这一天已有开始的训练。请在训练页调整，或选择其他日期。"; return
        }
        error = nil; preview = ManualPlanPreview(draft: draft, baseline: baseline)
    }
    private func apply(_ value: ManualPlanPreview) {
        guard let owner, owner == store.editingAccountID else { preview = nil; onSaved?(); dismiss(); return }
        do {
            // A completed adoption must only retry local archiving/cleanup.
            // Its old evidence is expected to differ after the accepted change.
            if store.hasAppliedAIJob(value.draft.operationID) {
                try ManualPlanDraftStorage.archive(value.draft, owner: owner)
                try ManualPlanDraftStorage.clear(owner: owner)
                _ = store.clearSyncedPlanDraft(id: value.draft.id)
                preview = nil; onSaved?(); dismiss(); return
            }
            try checkProposalEvidence(value.draft)
            if let profile = value.draft.suggestedForProfile, profile != store.state.profile.aiProfile { error = "预览后目标或训练条件已变化，请返回核对后重新预览。"; return }
            var result = try value.draft.result()
            let protectedDates = Set(value.baseline.filter { PlanAdoptionRules.isProtected($0.value) }.keys)
            result.sessions = result.sessions?.filter { !protectedDates.contains($0.date) }
            guard result.sessions?.isEmpty == false else { error = "所有训练日期都已有开始的记录，请选择新的开始日期。"; return }
            let scope = value.baseline.keys.filter { !protectedDates.contains($0) }.sorted()
            let customIDs = value.draft.activeDays.flatMap(\.movements).compactMap(\.customID)
            guard customIDs.allSatisfy({ id in store.customExercises.contains(where: { $0.id == id }) }) else {
                error = "计划中有已删除的个人动作，请返回编辑后重新选择。"; return
            }
            guard store.applyAIPlan(result, jobID: value.draft.operationID, replaceUnstarted: true,
                cycleStart: ClubDates.date(fromKey: value.draft.start), expectedDays: value.baseline, explicitScope: value.draft.singleDay == true || !protectedDates.isEmpty ? scope : nil, singleDay: value.draft.singleDay == true) else {
                error = store.takeMessage(); return
            }
            // The applied operation ID also prevents replay if clearing the draft fails.
            try ManualPlanDraftStorage.archive(value.draft, owner: owner)
            try ManualPlanDraftStorage.clear(owner: owner)
            _ = store.clearSyncedPlanDraft(id: value.draft.id)
            preview = nil; onSaved?(); dismiss()
        } catch {
            self.error = store.hasAppliedAIJob(value.draft.operationID)
                ? "训练日程已保存，本机模板归档暂未完成。请重试，重复确认不会再次添加动作。\(error.localizedDescription)"
                : error.localizedDescription
        }
    }
}

struct ManualMovementEditor: View {
    @State private var confirmUniform = false
    @Binding var movement: ManualPlanMovement
    let moveUp: () -> Void
    let moveDown: () -> Void
    let remove: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(movement.name).bojiFont(.exerciseName).foregroundStyle(BojiColor.textPrimary)
                Spacer()
                Button(role: .destructive, action: remove) { Image(systemName: "trash") }
                    .buttonStyle(ClubIconButtonStyle()).accessibilityLabel("移除\(movement.name)")
            }
            if movement.individualSets == nil {
                Stepper("\(movement.count) 组", value: $movement.count, in: 1...50)
            }
            Toggle("逐组设置目标", isOn: Binding(get: { movement.individualSets != nil }, set: { enabled in
                if enabled { movement.individualSets = movement.effectiveSets }
                else if let first = movement.individualSets?.first, movement.effectiveSets.contains(where: { $0 != first }) { confirmUniform = true }
                else { useUniformTargets() }
            }))
            Text("关闭逐组设置后，全部组沿用第一组目标；不同目标会先请你确认。").font(.caption).foregroundStyle(.secondary)
            Picker("组间休息", selection: Binding(get: { movement.restSeconds ?? -1 }, set: { movement.restSeconds = $0 < 0 ? nil : $0 })) {
                Text("使用训练默认值").tag(-1)
                ForEach([0,30,45,60,90,120,180,240,300], id: \.self) { Text($0 == 0 ? "不自动计时" : "\($0) 秒").tag($0) }
                if let seconds = movement.restSeconds, ![0,30,45,60,90,120,180,240,300].contains(seconds) { Text("\(seconds) 秒").tag(seconds) }
            }
            HStack {
                Button(action: moveUp) { Label("上移", systemImage: "arrow.up") }.buttonStyle(SecondaryButton())
                Button(action: moveDown) { Label("下移", systemImage: "arrow.down") }.buttonStyle(SecondaryButton())
            }
            if movement.individualSets != nil {
                ManualIndividualSetsEditor(movement: $movement)
            } else if movement.unit == "秒" {
                LabeledContent("每组秒数") { TextField("秒", value: $movement.seconds, format: .number).keyboardType(.numberPad).multilineTextAlignment(.trailing) }
            } else {
                LabeledContent("每组次数") { TextField("次", value: $movement.reps, format: .number).keyboardType(.numberPad).multilineTextAlignment(.trailing) }
                LabeledContent("重量 kg") { TextField("kg", value: $movement.weight, format: .number).keyboardType(.decimalPad).multilineTextAlignment(.trailing) }
            }
        }.confirmationDialog("将所有组改为相同目标？", isPresented: $confirmUniform, titleVisibility: .visible) {
            Button("全部沿用第一组目标", action: useUniformTargets)
            Button("保留逐组目标", role: .cancel) { }
        } message: { Text("当前每组有不同目标。确认后会用第一组的重量、次数或时间替换这些差异，只影响草稿。") }
    }
    private func useUniformTargets() {
        let sets = movement.effectiveSets; movement.count = sets.count
        if let first = sets.first { movement.weight = first.weight ?? 0; movement.reps = first.reps; movement.seconds = first.durationSeconds ?? 30 }
        movement.individualSets = nil
    }
}

private struct ManualIndividualSetsEditor: View {
    @Binding var movement: ManualPlanMovement
    private func field<T>(_ index: Int, get: @escaping (AIPlanSet) -> T, set: @escaping (inout AIPlanSet, T) -> Void) -> Binding<T> {
        Binding(get: { get(movement.individualSets?.indices.contains(index) == true ? movement.individualSets![index] : AIPlanSet(weight: 0, reps: 0)) }, set: { value in
            guard movement.individualSets?.indices.contains(index) == true else { return }
            set(&movement.individualSets![index], value)
        })
    }
    var body: some View {
        VStack(spacing: 12) {
            ForEach(Array((movement.individualSets ?? []).indices), id: \.self) { index in
                HStack {
                    Text("第 \(index + 1) 组").font(.subheadline)
                    if movement.unit == "秒" {
                        TextField("秒", value: field(index, get: { $0.durationSeconds ?? 30 }, set: { $0.durationSeconds = $1; $0.reps = 0; $0.weight = 0 }), format: .number).keyboardType(.numberPad)
                        Text("秒")
                    } else {
                        TextField("kg", value: field(index, get: { $0.weight ?? 0 }, set: { $0.weight = $1 }), format: .number).keyboardType(.decimalPad)
                        Text("kg")
                        TextField("次", value: field(index, get: { $0.reps }, set: { $0.reps = $1 }), format: .number).keyboardType(.numberPad)
                        Text("次")
                    }
                    Button { if movement.individualSets?.indices.contains(index) == true { movement.individualSets?.remove(at: index) } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(ClubIconButtonStyle()).disabled((movement.individualSets?.count ?? 0) <= 1).accessibilityLabel("移除第 \(index + 1) 组")
                }.textFieldStyle(.roundedBorder)
            }
            Button("增加一组") { if let last = movement.individualSets?.last { movement.individualSets?.append(last) } }
                .buttonStyle(SecondaryButton()).disabled((movement.individualSets?.count ?? 0) >= 50)
        }
    }
}
