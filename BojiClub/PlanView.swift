import SwiftUI

private struct PlanEditTarget: Identifiable {
    let session: Int
    let exercise: Int
    var id: String { "\(session)-\(exercise)" }
}

private struct PlanAdoptionPreview: Identifiable {
    let id = UUID()
    let result: AIResult
    let jobID: String
    let baseline: [String: DayLog]
    let scope: [String]
    let replace: Bool
}

struct PlanView: View {
    let date: Date
    @State private var planStartDate: Date
    let onPlanApplied: (() -> Void)?
    let onDeferred: ((String) -> Void)?
    let replacesProfileWeek: Bool
    let initialJobID: String?
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var ai: AIService
    @EnvironmentObject private var account: AccountService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var editableDraft: ManualPlanDraft?
    @State private var text = ""
    @State private var editingAccountID: Int?
    @State private var mode: String
    @State private var planDays = 7
    @State private var useMeasuredWeight = false
    private var recentWeight: BodyWeightPoint? {
        let now = Date()
        guard let point = store.bodyWeightPoints(through: now).last,
              let age = ClubDates.calendar.dateComponents([.day], from: point.date, to: now).day, (0...30).contains(age) else { return nil }
        return point
    }
    @State private var restoredPlanScope = false
    @State private var jobID: String?
    @State private var preview: AIResult?
    @State private var fallbackPlanJobID: String?
    @State private var fallbackPlanPreview: AIResult?
    @State private var expanded: Set<Int> = [0]
    @State private var error: String?
    @State private var applying = false
    @State private var actionProposal: CapabilityRouteResult?
    @State private var preparingAction = false
    @State private var editing: PlanEditTarget?
    @State private var showConditions = false
    @State private var showRevision = false
    @State private var chooseApplyMode = false
    @State private var adoptionPreview: PlanAdoptionPreview?
    @State private var applyBaseline: [String: DayLog]?
    @State private var revisionProfile = MemberProfile()
    private var job: AILocalJob? { ai.job(jobID) }
    private var planProfile: MemberProfile {
        guard let value = job?.request.payload["profile"],
              let data = try? JSONEncoder().encode(value),
              let profile = try? JSONDecoder().decode(MemberProfile.self, from: data) else { return store.state.profile }
        return profile
    }
    private var profileHasChanged: Bool {
        replacesProfileWeek && preview != nil && PlanExplanationRules.profileDiffers(job?.request.payload["profile"], from: store.state.profile, weightReference: job?.request.payload["weight_reference"]) != false
    }
    private var sessions: [AIPlanSession] { preview?.sessions ?? [] }
    private var alreadyApplied: Bool { job.map { store.hasAppliedAIJob($0.id) } ?? false }
    private var isBusy: Bool { job.map { !$0.isTerminal && !$0.isWaiting } ?? false }
    private var hasFailure: Bool { job.map { ["failed", "waiting_connection", "waiting_service", "deleted", "expired", "rejected", "discarded"].contains($0.status) } ?? false }
    private var earliestPlanStart: Date { NewPlanDateRules.earliestStart(replacingProfileWeek: replacesProfileWeek) }

    init(date: Date, initialMode: String = "generate_plan", initialJobID: String? = nil, replacesProfileWeek: Bool = false, onDeferred: ((String) -> Void)? = nil, onPlanApplied: (() -> Void)? = nil) {
        self.date = date
        let minimum = NewPlanDateRules.earliestStart(replacingProfileWeek: replacesProfileWeek)
        let start = initialMode == "generate_plan" && initialJobID == nil ? max(date, minimum) : date
        self._planStartDate = State(initialValue: start)
        self.onPlanApplied = onPlanApplied
        self.onDeferred = onDeferred
        self.replacesProfileWeek = replacesProfileWeek
        self.initialJobID = initialJobID
        _mode = State(initialValue: initialMode)
    }

    var body: some View {
        ClubNavigationStack132 {
            ZStack {
                FlowBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: ClubUI.sectionSpacing) {
                        FlowHeading(eyebrow: preview == nil ? "MADE FOR YOUR LIFE" : "YOUR TRAINING BLUEPRINT",
                                    title: preview == nil ? "训练计划" : "训练安排已准备好。",
                                    subtitle: preview == nil ? "从 \(ClubDates.label(planStartDate)) 开始。" : "确认后写入月历。")
                        if let preview {
                            planSummary(preview).clubReveal()
                            if let explanation = preview.explanation, explanation.version == 1 {
                                PlanExplanationCard(explanation: explanation, notice: explanationNotice).id(jobID ?? "preview")
                            }
                            Button("在自由编辑器中逐组调整") {
                                do { editableDraft = try ManualPlanDraft.importing(preview, originalStart: ClubDates.key(planStartDate)) }
                                catch { self.error = AppErrorText.message(error) }
                            }.buttonStyle(SecondaryButton())
                            Text("支持逐组调整目标与组间休息，确认后才会写入日程。")
                                .bojiType(.label).foregroundStyle(.secondary)
                            sessionList.clubReveal()
                        }
                        else if isBusy || job?.isWaiting == true { waiting }
                        else { configuration }
                        if profileHasChanged {
                            FlowSurface {
                                Text("训练资料已更新，这份方案仍按之前的资料制定。").bojiType(.secondary)
                                Button("按当前资料重新制定") { submit() }.buttonStyle(SecondaryButton()).disabled(isBusy)
                            }
                        }
                        if let error { FlowError(message: error) }
                        if hasFailure { failure }
                        if let preview, !preview.notes.isEmpty {
                            PlanRemindersView(notes: preview.notes, date: planStartDate).padding(.vertical, BojiSpace.tightRow)
                        }
                    }.clubMotion(value: isBusy).clubMotion(value: preview != nil).padding(ClubUI.pageInset).frame(maxWidth: ClubUI.contentWidth).frame(maxWidth: .infinity)
                }.scrollDismissesKeyboard(.interactively)
            }
            .safeAreaInset(edge: .bottom) { dock }
            .confirmationDialog("这些日期已有安排，如何加入新计划？", isPresented: $chooseApplyMode, titleVisibility: .visible) {
                if replacesProfileWeek {
                    Button("更新这 7 天，保留已开始的训练日") { prepareAdoption(replace: true) }
                } else {
                    Button("追加到已有安排") { prepareAdoption(replace: false) }
                    Button(mode == "generate_plan" ? "更新整段安排，包括休息日" : "替换这些日期的未开始动作") { prepareAdoption(replace: true) }
                }
                Button("取消", role: .cancel) { }
            } message: {
                Text(adoptionMessage)
            }
            .sheet(item: $editableDraft) { ManualPlanView(initialDraft: $0) }
            .sheet(item: $adoptionPreview) { value in adoptionSheet(value) }
            .navigationTitle(preview == nil ? "生成" : "确认").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { guard editingAccountID != nil, editingAccountID == store.editingAccountID else { dismiss(); return }; if store.savePlanText(text) { dismiss() } else { error = store.takeMessage() } } label: { Image(systemName: "xmark").bojiType(.secondary) }.accessibilityLabel("关闭，保留进度")
                }
                ToolbarItem(placement: .topBarTrailing) {
                }
            }
            .tint(FlowPalette.ink)
            .onAppear { editingAccountID = store.editingAccountID; text = store.state.importedPlan; restore() }
            .onChange(of: store.editingAccountID) { _, id in
                if editingAccountID != id { adoptionPreview = nil; editing = nil; showRevision = false; dismiss() }
            }
            .onChange(of: mode) { _, _ in restore() }
            .onChange(of: planStartDate) { _, _ in restore() }
            .onChange(of: planDays) { _, value in
                guard [7,14,28].contains(value) else { return }
                if let job {
                    let scope: Double
                    if case .number(let length)? = job.request.payload["plan_days"] { scope = length } else { scope = 7 }
                    if scope == Double(value) { return }
                }
                restore(useInitialJob: false)
            }
            .onChange(of: job?.status) { _, _ in receiveResult() }
            .onChange(of: text) { _, value in
                if value.count > 16000 { text = String(value.prefix(16000)); error = "计划文字最多 16000 字，请分段导入。" }
            }
            .task(id: text) {
                do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
                guard !Task.isCancelled, editingAccountID != nil, editingAccountID == store.editingAccountID else { return }
                if !store.savePlanText(text) { error = store.takeMessage() }
            }
            .onDisappear { if editingAccountID != nil, editingAccountID == store.editingAccountID { store.savePlanText(text) } }
            .sheet(item: $editing) { target in
                if sessions.indices.contains(target.session), sessions[target.session].exercises.indices.contains(target.exercise) {
                    let exercises = sessions[target.session].exercises
                    PlanExerciseEditor(exercise: exercises[target.exercise]) { value in
                        preview?.sessions?[target.session].exercises[target.exercise] = value
                        persistPreview()
                    }
                }
            }
            .sheet(isPresented: $showRevision) { revisionSheet }
            .sheet(isPresented: $showConditions) { PlanMissingConditions131 { error = nil; submit() } }
        }
    }

    @ViewBuilder private var planWeightChoice: some View {
        if !store.state.profile.hasConfirmedBasics {
            Text("身体资料尚未确认；本次仅按已确认的训练条件编排，不使用示例体重。").bojiType(.label).foregroundStyle(.secondary)
        } else {
        Text("资料体重：\(store.state.profile.weight.formatted(.number.precision(.fractionLength(0...1)))) kg").bojiType(.secondary)
        if let point = recentWeight {
            Toggle("本次采用 \(ClubDates.label(point.date)) 实测 \(point.kilograms.formatted(.number.precision(.fractionLength(0...1)))) kg", isOn: $useMeasuredWeight)
                .bojiType(.secondary)
            Text("仅用于这次计划，不改动个人资料。")
                .bojiType(.label).foregroundStyle(.secondary)
        } else {
            Text("本次按资料体重制定。近 30 天没有实测记录，可先登记体重，或在个人资料中修改资料值。")
                .bojiType(.label).foregroundStyle(.secondary)
        }
        }
    }
    private var configuration: some View {
        VStack(alignment: .leading, spacing: BojiLayout.Rhythm.headerToContent) {
            // Legacy parse jobs remain readable; new plans start from generation or the schedule editor.
            if mode == "generate_plan" {
                FlowSurface {
                    Label("按你的训练档案", systemImage: "person.crop.circle").bojiType(.secondary).foregroundStyle(FlowPalette.secondaryInk)
                    Text(store.state.profile.goal).bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
                    planWeightChoice
                    if !store.state.profile.canPrepareTrainingPlan { Button("核对训练日与条件") { showConditions=true }.buttonStyle(SecondaryButton()) }
                    HStack(spacing: BojiLayout.blockGap) {
                        summaryMetric("每周", "\(store.state.profile.daysPerWeek)", "次")
                        summaryMetric("训练场地", store.state.profile.venue, "")
                    }
                    Divider()
                    Text("\(store.state.profile.experience) · 优先关注\(store.state.profile.focus)").bojiType(.label).foregroundStyle(.secondary)
                    if let limitations = store.state.profile.limitations, !limitations.isEmpty {
                        Text("禁忌与偏好：\(limitations)").bojiType(.label).foregroundStyle(FlowPalette.secondaryInk)
                    }
                }
                Label("生成后可查看动作示范，修改动作、组数与次数。", systemImage: "slider.horizontal.3")
                    .bojiType(.label).foregroundStyle(.secondary)
            } else {
                FlowSurface {
                    Label("粘贴你的文字计划", systemImage: "doc.text").bojiType(.secondary).foregroundStyle(FlowPalette.secondaryInk)
                    ZStack(alignment: .topLeading) {
                        if text.isEmpty { Text("例如：\n周一练胸：俯卧撑 3 组，每组 12 次\n周三练腿：深蹲 4 组，每组 10 次")
                            .bojiType(.body).foregroundStyle(.tertiary).padding(.top, BojiSpace.tightRow).padding(.leading, BojiLayout.tight).allowsHitTesting(false) }
                        TextEditor(text: $text).scrollContentBackground(.hidden).frame(minHeight: 220)
                            .accessibilityLabel("文字训练计划")
                    }
                    HStack { Text("原文自动保存在当前账号"); Spacer(); Text("\(text.count) / 16000") }.bojiType(.caption).foregroundStyle(.secondary)
                }
                Text("日期、动作与组次已整理，确认后保存。")
                    .bojiType(.label).foregroundStyle(.secondary)
            }
        }
    }

    private var waiting: some View {
        VStack(spacing: BojiLayout.cardInset) {
            if ai.requiresRoutingConsent { AIRoutingConsentView() }
            FlowSurface {
            HStack(spacing: BojiLayout.cardInset) {
                AIProcessingMark()
                VStack(alignment: .leading, spacing: BojiLayout.inline) {
                    Text(mode == "parse_plan" ? "正在生成计划" : "正在生成计划").bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
                    Text(waitingMessage)
                        .bojiType(.label).foregroundStyle(.secondary)
                }
            }.padding(.vertical, BojiSpace.workoutCardInset)
            Divider()
            Text("\(planProfile.goal) · 每周 \(planProfile.daysPerWeek) 次 · \(planProfile.venue)")
                .bojiType(.secondary).foregroundStyle(FlowPalette.secondaryInk)
            Text("你可以暂时离开，任务和输入会保留。回来后可继续查看。")
                .bojiType(.label).foregroundStyle(.secondary).lineSpacing(4)
        }
        }
    }

    private var waitingMessage: String {
        if job?.errorCode == "invalid_output" {
            return "方案日期或内容不符合要求，正在重新生成。资料已保留。"
        }
        if job?.status == "retrying" { return "服务暂时未完成，正在自动重试；你的资料已保留。" }
        if job?.status == "pending" { return "任务等待处理，输入已经保留。" }
        return "正在生成计划…"
    }

    private var failure: some View {
        FlowSurface {
            Label("暂时没有完成", systemImage: "wifi.exclamationmark").bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
            Text(job?.error ?? "连接中断，输入已保留。请稍后重试。")
                .bojiType(.label).foregroundStyle(.secondary)
            Button("保留输入，重新尝试") { if let job { if job.status == "discarded" { submit() } else { ai.retry(job.id) } } }.buttonStyle(SecondaryButton())
                .bojiType(.secondary)
            if let fallbackPlanJobID, let fallbackPlanPreview {
                Button("返回上一次方案") { jobID = fallbackPlanJobID; preview = fallbackPlanPreview; error = nil }.buttonStyle(SecondaryButton())
            }
        }
    }

    private func planSummary(_ result: AIResult) -> some View {
        FlowSurface {
            HStack { Label("已准备好", systemImage: "checkmark.circle.fill").foregroundStyle(FlowPalette.secondaryInk); Spacer(); Text("\(sessions.count) 个训练日").foregroundStyle(.secondary) }.bojiType(.caption)
            Text(PlanDisplayCopy.heading(result.title ?? "", fallback: "训练方案")).bojiFont(.pageTitle).foregroundStyle(BojiColor.textPrimary)
            if mode == "generate_plan", sessions.contains(where: { $0.date < ClubDates.key(Date()) }) {
                Text("部分日期已过去。保留预览，可从今天重新生成。")
                    .bojiType(.secondary).foregroundStyle(.secondary)
                Button("从今天重新安排") { planStartDate = Date() }.buttonStyle(SecondaryButton())
            }
            if let length = result.plan_days {
                Text("\(length) 天安排 · 每周可确认调整下一周")
                    .bojiType(.secondary).foregroundStyle(.secondary)
                if length > 7 {
                    Text("第 2 周起沿用基础周的动作与组次，不自动加重；后续强度由每周回顾后确认调整。")
                        .bojiType(.secondary).foregroundStyle(.secondary)
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 125), alignment: .leading)], alignment: .leading, spacing: BojiLayout.blockGap) {
                summaryMetric("训练日", "\(sessions.count)", "天")
                summaryMetric("计划动作", "\(sessions.reduce(0) { $0 + $1.exercises.count })", "项")
                summaryMetric("计划起始", ClubDates.label(planStartDate, format: "M.dd"), "")
                summaryMetric("首个训练", firstTrainingDateLabel, "")
            }
            if let target = store.state.nutritionTarget, target.generalGuidanceOnly != true {
                Divider()
                Label("每日营养目标", systemImage: "fork.knife").bojiType(.caption)
                HStack(spacing: BojiLayout.Rhythm.headerToContent) {
                    summaryMetric("热量", "\(target.caloriesMin.formatted(.number.precision(.fractionLength(0))))–\(target.caloriesMax.formatted(.number.precision(.fractionLength(0))))", "kcal")
                    summaryMetric("蛋白质", "\(target.proteinMin.formatted(.number.precision(.fractionLength(0))))–\(target.proteinMax.formatted(.number.precision(.fractionLength(0))))", "g")
                }
            }
            if !alreadyApplied && mode == "generate_plan" && !replacesProfileWeek {
                Divider()
                Button { revisionProfile = planProfile; showRevision = true } label: {
                    Label("调整目标与安排，重新生成", systemImage: "arrow.triangle.2.circlepath").bojiType(.label)
                }.buttonStyle(SecondaryButton())
            }
        }
    }
    private var firstTrainingDateLabel: String {
        let first = sessions.compactMap { ClubDates.date(fromKey: $0.date) }.min()
        return first.map { ClubDates.label($0, format: "M.dd") } ?? "—"
    }

    private var explanationNotice: String? {
        let changed = !PlanExplanationRules.sameStructure(job?.result?.sessions ?? [], sessions)
        let notice = PlanExplanationRules.notice(profileChanged: PlanExplanationRules.profileDiffers(job?.request.payload["profile"], from: store.state.profile, weightReference: job?.request.payload["weight_reference"]), planChanged: changed)
        let source = PlanWeightReference.description(job?.request.payload["weight_reference"])
        let values = [source, notice].compactMap { $0 }
        return values.isEmpty ? nil : values.joined(separator: "\n")
    }

    private func sessionPurpose(_ session: AIPlanSession) -> String? {
        guard let original = job?.result?.sessions?.first(where: { $0.date == session.date }),
              PlanExplanationRules.sameStructure([original], [session]) else { return nil }
        return preview?.explanation?.sessions.first { $0.date == session.date }?.purpose
    }

    private func summaryMetric(_ label: String, _ value: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: BojiLayout.inline) {
            Text(label).bojiType(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: BojiLayout.tight) { Text(value).bojiFont(.setNumber, monospacedDigits: true); Text(unit).bojiFont(.label).foregroundStyle(BojiColor.textSecondary) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sessionList: some View {
        VStack(spacing: BojiLayout.rowGap) {
            ForEach(Array(sessions.enumerated()), id: \.offset) { index, session in
                FlowSurface {
                    Button {
                        withAnimation(reduceMotion ? nil : BojiMotion2.state) {
                            if expanded.contains(index) { expanded.remove(index) } else { expanded.insert(index) }
                        }
                    } label: {
                        HStack(spacing: BojiLayout.cardInset) {
                            VStack(spacing: BojiLayout.tight) {
                                Text(dayLabel(session.date, format: "EEE")).bojiType(.caption)
                                Text(dayLabel(session.date, format: "dd")).bojiType(.section)
                            }.frame(width: 52, height: 64).background(FlowPalette.paper, in: RoundedRectangle(cornerRadius: BojiRadius.inner))
                            VStack(alignment: .leading, spacing: BojiLayout.tight) { Text(PlanDisplayCopy.heading(session.label)).bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary); Text("\(session.exercises.count) 个动作 · \(session.exercises.reduce(0) { $0 + $1.sets.count }) 组").bojiType(.caption).foregroundStyle(.secondary) }
                            Spacer(minLength: 0)
                            Image(systemName: expanded.contains(index) ? "chevron.up" : "chevron.down").bojiType(.caption)
                        }.contentShape(Rectangle())
                    }.buttonStyle(ClubMotionButton()).accessibilityLabel("\(session.date)，\(PlanDisplayCopy.heading(session.label))，\(expanded.contains(index) ? "收起" : "展开")")
                    if expanded.contains(index) {
                        if let purpose = sessionPurpose(session) {
                            Text(purpose).bojiType(.secondary).foregroundStyle(.secondary).lineSpacing(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(Array(session.exercises.enumerated()), id: \.offset) { exerciseIndex, exercise in
                            Divider()
                            VStack(alignment: .leading, spacing: BojiLayout.rowGap) {
                                HStack(alignment: .top) {
                                    Text(String(format: "%02d", exerciseIndex + 1)).bojiType(.caption).foregroundStyle(FlowPalette.secondaryInk)
                                    VStack(alignment: .leading, spacing: BojiLayout.tight) {
                                        Text(exercise.displayName).bojiType(.secondary)
                                        Text(exercise.muscle).bojiType(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if !alreadyApplied {
                                        Button { editing = PlanEditTarget(session: index, exercise: exerciseIndex) } label: {
                                            Image(systemName: "slider.horizontal.3").frame(width: 44, height: 44).background(FlowPalette.paper, in: Circle())
                                        }.buttonStyle(ClubMotionButton()).accessibilityLabel("调整\(exercise.displayName)")
                                    }
                                }
                                Text(exercise.sets.map { $0.repetitionLabel + ($0.weight.map { " · \($0.formatted()) kg" } ?? "") }.joined(separator: " / "))
                                    .bojiType(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                ExerciseDemoButton(exercise: Exercise(name: exercise.name, muscle: exercise.muscle, libraryID: exercise.library_id, libraryQuery: exercise.library_query, customExerciseID: exercise.custom_id, customUnit: exercise.custom_unit))
                            }
                        }
                    }
                }
            }
        }
    }
    private func dayLabel(_ key: String, format: String) -> String {
        ClubDates.date(fromKey: key).map { ClubDates.label($0, format: format) } ?? key
    }

    private var dock: some View {
        FlowDock {
            if preview != nil {
                Text(alreadyApplied ? "这份计划已保存，可直接继续。" : "保留已有记录 · 动作与重量可继续调整")
                    .bojiType(.caption).foregroundStyle(.secondary)
                Button(alreadyApplied ? "完成，继续" : "查看并保存计划") {
                    if alreadyApplied { finish() } else { requestApply() }
                }.buttonStyle(FlowButtonStyle()).disabled(applying || sessions.isEmpty)
            } else if isBusy || job?.isWaiting == true {
                Button(onDeferred == nil ? "稍后回来查看" : "稍后查看计划") {
                    guard editingAccountID != nil, editingAccountID == store.editingAccountID else { return }
                    if let jobID { onDeferred?(jobID) }
                    dismiss()
                }.buttonStyle(FlowButtonStyle())
            } else {
                if mode == "generate_plan", !replacesProfileWeek {
                    Picker("计划长度", selection: $planDays) {
                        Text("7 天").tag(7); Text("14 天").tag(14); Text("28 天").tag(28)
                    }.clubAdaptivePicker()
                    Text("后续周沿用本周安排，可随时调整。")
                        .bojiType(.caption).foregroundStyle(.secondary)
                }
                if mode == "generate_plan" {
                    DatePicker("计划起始日", selection: $planStartDate, in: earliestPlanStart..., displayedComponents: .date)
                        .bojiType(.secondary)
                    Text(replacesProfileWeek ? "资料更新后的新计划从明天或之后开始，保留今天的训练。" : "新计划从今天或之后开始；已经练过的训练可在训练页补记。")
                        .bojiType(.caption).foregroundStyle(.secondary)
                } else {
                    DatePicker("计划起始日", selection: $planStartDate, displayedComponents: .date).bojiType(.secondary)
                }
                if mode == "parse_plan", ClubDates.key(planStartDate) < ClubDates.key(Date()) {
                    Text("起始日早于今天：这份计划会加入过去的月历，请确认是补录历史安排。")
                        .bojiType(.caption).foregroundStyle(.orange)
                }
                Text("按你选择的训练日安排。")
                    .bojiType(.caption).foregroundStyle(.secondary)
                Button(hasFailure ? "重新尝试这份计划" : mode == "generate_plan" ? "生成专属训练计划" : "识别并预览计划") {
                    if hasFailure, let job, job.status != "discarded" { ai.retry(job.id) }
                    else { submit() }
                }
                    .buttonStyle(FlowButtonStyle())
                    .disabled(mode == "parse_plan" && (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.count > 16000))
                if hasFailure, let onDeferred, let jobID {
                    Button("稍后查看计划") { onDeferred(jobID); dismiss() }.buttonStyle(SecondaryButton())
                }
            }
        }
    }

    private var revisionSheet: some View {
        ClubNavigationStack132 {
            ZStack {
                FlowBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: BojiLayout.Rhythm.headerToContent) {
                        FlowHeading(eyebrow: "REFINE YOUR PLAN", title: "换一种安排。", subtitle: "调整本次计划的偏好，不会修改个人资料；确认前不会修改月历。")
                        FlowSurface {
                            Picker("目标", selection: $revisionProfile.goal) {
                                ForEach(["增肌塑形", "减脂瘦身", "紧致线条", "提升力量", "养成运动习惯"], id: \.self) { Text($0).tag($0) }
                            }
                            Divider()
                            Stepper("每周 \(revisionProfile.daysPerWeek) 天", value: $revisionProfile.daysPerWeek, in: 1...7)
                            Divider()
                            TextField("优先训练部位", text: $revisionProfile.focus)
                            Divider()
                            FlowChips(values: ["健身房", "在家", "两者都有"], selection: $revisionProfile.venue)
                        }
                        Text("重新生成会替换当前预览。")
                            .bojiType(.label).foregroundStyle(.secondary)
                    }.padding(ClubUI.pageInset)
                }
            }.navigationTitle("调整方案").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { showRevision = false } } }
                .safeAreaInset(edge: .bottom) {
                    FlowDock {
                        Button("按新安排生成") {
                            if revisionProfile.trainingDays?.count != revisionProfile.daysPerWeek { revisionProfile.trainingDays = nil; revisionProfile.homeTrainingDays = nil }
                            showRevision = false; submit(profile: revisionProfile)
                        }.buttonStyle(FlowButtonStyle())
                    }
                }
        }.presentationDragIndicator(.visible)
    }

    private func restore(useInitialJob: Bool = true) {
        guard editingAccountID != nil, editingAccountID == store.editingAccountID else { return }
        if !restoredPlanScope {
            let configured = replacesProfileWeek ? 7 : store.state.profile.planDurationDays ?? 7
            planDays = [7,14,28].contains(configured) ? configured : 7; restoredPlanScope = true
        }
        if useInitialJob, let initialJobID, let existing = ai.job(initialJobID), existing.request.kind == mode,
           existing.request.date == ClubDates.key(planStartDate), !existing.consumed, !store.hasAppliedAIJob(existing.id) {
            if case .number(let value)? = existing.request.payload["plan_days"], [7.0,14.0,28.0].contains(value) { planDays = Int(value) }
            else { planDays = 7 }
            jobID = existing.id; preview = nil; error = nil; receiveResult(); ai.resume(); return
        }
        if mode == "generate_plan", let value = try? JSONValue.encode(store.state.profile.aiProfile) {
            let input = AIInput(kind: mode, date: ClubDates.key(planStartDate), payload: ["profile": value, "goal_context": (try? JSONValue.encode(recentGoalContext)) ?? .null, "plan_days": .number(Double(planDays))])
            let candidate = ai.matching(input) ?? (planDays == 7 ? ai.matching(AIInput(kind: mode, date: ClubDates.key(planStartDate), payload: ["profile": value])) : nil)
            jobID = candidate.flatMap { item in
                item.consumed || store.hasAppliedAIJob(item.id) ? nil : item.id
            }
        } else {
            jobID = ai.latest(kind: mode, date: planStartDate)?.id
        }
        preview = nil; error = nil; receiveResult()
        ai.resume()
    }
    private func previewKey(_ id: String) -> String { "plan.preview.user-\(editingAccountID ?? 0).\(id)" }
    private func receiveResult() {
        guard editingAccountID != nil, editingAccountID == store.editingAccountID else { return }
        guard let job, job.status == "succeeded", job.result?.kind == "plan" else { return }
        let legacy = "plan.preview.\(job.id)"
        if let data = UserDefaults.standard.data(forKey: legacy) {
            UserDefaults.standard.set(data, forKey: previewKey(job.id)); UserDefaults.standard.removeObject(forKey: legacy)
        }
        if let data = UserDefaults.standard.data(forKey: previewKey(job.id)), let saved = try? JSONDecoder().decode(AIResult.self, from: data) { preview = saved }
        else { preview = job.result }
        expanded = [0]
    }
    private func persistPreview() {
        guard editingAccountID != nil, editingAccountID == store.editingAccountID else { return }
        if let id = jobID, let preview, let data = try? JSONEncoder().encode(preview) { UserDefaults.standard.set(data, forKey: previewKey(id)) }
    }
    private var recentGoalContext: ClubAIContext {
        let end = Date()
        let start = ClubDates.calendar.date(byAdding: .day, value: -27, to: end) ?? end
        return ClubAIContext.make(state: store.state, start: start, end: end)
    }
    private func submit(profile: MemberProfile? = nil) {
        guard editingAccountID != nil, editingAccountID == store.editingAccountID else { return }
        if mode == "generate_plan", !NewPlanDateRules.isValidStart(ClubDates.key(planStartDate), replacingProfileWeek: replacesProfileWeek) {
            error = replacesProfileWeek ? "更新计划请从明天或之后开始，今天的训练会保留。" : "计划起始日已过去，请改为今天或之后的日期，再重新制定。"; return
        }
        if mode == "generate_plan", !store.state.profile.canPrepareTrainingPlan {
            error = nil; showConditions = true
            return
        }
        do {
            var planningProfile = (profile ?? store.state.profile).aiProfile
            var reference: JSONValue?
            if mode == "generate_plan", useMeasuredWeight, let point = recentWeight {
                planningProfile.weight = point.kilograms
                reference = .object(["date": .string(ClubDates.key(point.date)), "kilograms": .number(point.kilograms)])
            }
            var payload: [String: JSONValue] = ["profile": try .encode(planningProfile)]
            if planningProfile.factState != nil {
                payload["profile"] = .object(planningProfile.v2PlanProfile)
                payload["_v2_profile"] = .bool(true);payload["_v2_schema_version"] = .number(1)
                payload["timeZone"] = .string(TimeZone.current.identifier)
            }
            if let reference,planningProfile.hasConfirmedBasics { payload["weight_reference"] = reference }
            if mode == "generate_plan" { if planningProfile.factState == nil { payload["goal_context"] = try .encode(recentGoalContext) }; payload["plan_days"] = .number(Double(replacesProfileWeek ? 7 : planDays)) }
            if mode == "parse_plan" { guard store.savePlanText(text) else { throw AIClientError.message(store.takeMessage(fallback: "输入保存失败。")) }; payload["text"] = .string(text) }
            let input = AIInput(kind: mode, date: ClubDates.key(planStartDate), payload: payload)
            let previous = ai.matching(input)
            let wasApplied = previous.map { $0.consumed || store.hasAppliedAIJob($0.id) } ?? false
            if let preview, let jobID { fallbackPlanPreview = preview; fallbackPlanJobID = jobID }
            jobID = try ai.submit(input, forceNew: wasApplied)
            preview = nil; error = nil; receiveResult()
        } catch { self.error = AppErrorText.message(error) }
    }
    private var adoptionMessage: String {
        if replacesProfileWeek { return "所选 7 天内未开始的安排将按新方案更新，包括改为休息的日期。已开始或已确认的训练日不会改动。" }
        if mode == "generate_plan" { return "替换会清理新计划中改为休息的日期上的旧安排。已开始或已完成的训练会保留；新训练日已有开始记录时需另选日期。追加则保留原安排。" }
        return "仅处理导入的训练日期，不更改其他日期。已记录完成的训练会保留。"
    }
    private var adoptionDates: [String] {
        guard mode == "generate_plan" else { return sessions.map(\.date) }
        return (0..<(preview?.plan_days ?? 7)).compactMap {
            ClubDates.calendar.date(byAdding: .day, value: $0, to: planStartDate).map(ClubDates.key)
        }
    }
    private func requestApply() {
        applyBaseline = Dictionary(uniqueKeysWithValues: Set(adoptionDates).map { ($0, store.state.days[$0] ?? DayLog()) })
        if replacesProfileWeek || adoptionDates.contains(where: { !(store.state.days[$0]?.exercises.isEmpty ?? true) }) { chooseApplyMode = true }
        else { prepareAdoption(replace: false) }
    }
    private func prepareAdoption(replace: Bool) {
        guard let result = preview, let jobID, !sessions.isEmpty else { return }
        let baseline = applyBaseline ?? Dictionary(uniqueKeysWithValues: Set(adoptionDates).map { ($0, store.state.days[$0] ?? DayLog()) })
        let scope = replace && mode == "generate_plan" ? adoptionDates : sessions.map(\.date)
        error = nil
        actionProposal = nil
        adoptionPreview = PlanAdoptionPreview(result: result, jobID: jobID, baseline: baseline, scope: scope, replace: replace)
    }
    private func adoptionSheet(_ value: PlanAdoptionPreview) -> some View {
        let blocked = (replacesProfileWeek || job?.request.payload["action_draft_id"]?.string != nil) ? [] : (value.result.sessions ?? []).map(\.date).filter { PlanAdoptionRules.isProtected(value.baseline[$0] ?? DayLog()) }
        return ClubNavigationStack132 {
            ScrollView {
                VStack(alignment: .leading, spacing: BojiLayout.cardInset) {
                    Text(value.replace ? "更新所选日期的安排" : "加入新的训练安排").bojiFont(.pageTitle).foregroundStyle(BojiColor.textPrimary)
                    Text("以下对比按打开预览时的安排计算。确认前不会修改月历；已开始的训练不会被替换。")
                        .bojiType(.secondary).foregroundStyle(.secondary)
                    ClubCard { ClubPlanChangesView(changes: ClubPlanChangeRules.preview(before: value.baseline,
                        sessions: value.result.sessions ?? [], scope: value.scope, replace: value.replace)) }
                    if let card = actionProposal?.card {
                        var readOnly = card
                        AICardView(card: { readOnly.actions = []; return readOnly }()) { _ in }
                    }
                    if preparingAction { ProgressView("正在取得服务端预览…") }
                    if !blocked.isEmpty {
                        Text("这些训练日已有开始记录：" + blocked.joined(separator: "、") + "。请返回调整日期后重新预览。")
                            .bojiType(.secondary).foregroundStyle(.secondary)
                    }
                    if let error { FlowError(message: error) }
                }.padding(ClubUI.pageInset)
            }.background { ClubBackground() }.navigationTitle("核对计划变更").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("返回核对") { adoptionPreview = nil }.disabled(applying) } }
                .safeAreaInset(edge: .bottom) {
                    Button(applying ? "正在保存…" : "保存这些安排") { apply(value) }
                        .buttonStyle(PrimaryButton()).disabled(applying || preparingAction || !blocked.isEmpty || (job?.request.payload["action_draft_id"]?.string != nil && actionProposal == nil)).padding(BojiSpace.pageInset).clubGlassEffect(in: RoundedRectangle(cornerRadius: BojiRadius.input, style: .continuous))
                }
        }.interactiveDismissDisabled(applying)
            .task(id: value.id) { await prepareActionPlan(value) }
    }
    private func prepareActionPlan(_ value: PlanAdoptionPreview) async {
        guard let job, let draft = job.request.payload["action_draft_id"]?.string, let hash = job.request.payload["action_draft_hash"]?.string, let owner = account.user?.id else { return }
        preparingAction = true; defer { preparingAction = false }
        do {
            let prepared = try await CapabilityRouter.preparePlan(draftID: draft, result: value.result, expectedHash: hash, baseline: value.baseline, replace: value.replace, previewID: value.id.uuidString.lowercased(), owner: owner, account: account) { savedHash in
                ai.updateActionDraftHash(id: job.id, hash: savedHash)
            }
            guard account.user?.id == owner else { return }
            ai.updateActionDraftHash(id: job.id, hash: prepared.1)
            actionProposal = prepared.0
        } catch { self.error = AppErrorText.message(error) }
    }
    private func apply(_ value: PlanAdoptionPreview) {
        guard editingAccountID != nil, editingAccountID == store.editingAccountID else { return }
        guard let job, job.id == value.jobID, !applying else { return }
        if job.request.payload["action_draft_id"]?.string != nil {
            guard let proposal = actionProposal?.proposal_id, let owner = account.user?.id else { error = "服务端预览尚未就绪。"; return }
            applying = true
            Task { @MainActor in
                defer { applying = false }
                let result = await CapabilityRouter.confirmProposal(kind: "plan_activation", proposalID: proposal, owner: owner, account: account)
                guard account.user?.id == owner else { return }
                if case .confirmed = result {
                    await store.syncNow()
                    guard store.hasAppliedAIJob(job.id) else { error = "服务端已确认，正在同步到本机；请先处理待同步操作后继续。"; return }
                    adoptionPreview = nil; ai.markConsumed(job.id); finish()
                } else if case .conflict(let message) = result { error = message }
            }
            return
        }
        let preview = value.result
        applying = true
        defer { applying = false }
        let applied: Bool
        if replacesProfileWeek {
            guard PlanExplanationRules.profileDiffers(job.request.payload["profile"], from: store.state.profile, weightReference: job.request.payload["weight_reference"]) == false else {
                error = "资料在生成后又发生了变化，请重新按当前资料生成计划。"; return
            }
            applied = store.applyProfilePlan(preview, jobID: job.id, start: planStartDate, expectedDays: value.baseline)
        } else {
            applied = store.applyAIPlan(preview, jobID: job.id, replaceUnstarted: value.replace, cycleStart: mode == "generate_plan" ? planStartDate : nil, expectedDays: value.baseline)
        }
        guard applied else { error = store.takeMessage(fallback: "保存失败，请重试。"); return }
        adoptionPreview = nil; ai.markConsumed(job.id); ai.settlePlanCandidates(adopted: job.id); finish()
    }
    private func finish() { onPlanApplied?(); dismiss() }
}

private struct PlanExerciseEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var exercise: AIPlanExercise
    let save: (AIPlanExercise) -> Void
    @State private var query = ""
    @State private var results: [LibraryExercise] = []
    @State private var loading = false
    @State private var searchError: String?
    @State private var searchingLibrary = false
    @State private var pendingReplacement: LibraryExercise?
    @State private var confirmReplacement = false
    @State private var replacementNotice: String?

    var body: some View {
        ClubNavigationStack132 {
            ZStack {
                FlowBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: BojiLayout.blockGap) {
                        FlowHeading(eyebrow: "MAKE IT YOURS", title: "调整这个动作。", subtitle: "选择适合自己的动作与组次，重量也可以开练时再填。")
                        FlowSurface {
                            Text(exercise.displayName).bojiFont(.exerciseName).foregroundStyle(BojiColor.textPrimary)
                            ForEach(exercise.sets.indices, id: \.self) { index in
                                VStack(alignment: .leading, spacing: BojiLayout.rowGap) {
                                    Divider()
                                    if exercise.sets[index].durationSeconds != nil {
                                        Stepper("第 \(index + 1) 组 · \(exercise.sets[index].durationSeconds ?? 30) 秒", value: Binding(get: { exercise.sets[index].durationSeconds ?? 30 }, set: { exercise.sets[index].durationSeconds = $0 }), in: 1...RecordLimits.maximumSeconds)
                                    } else {
                                        Stepper("第 \(index + 1) 组 · \(exercise.sets[index].reps) 次", value: $exercise.sets[index].reps, in: 1...100)
                                    }
                                    Menu("记录单位") {
                                        Button("按次数") { exercise.sets[index].durationSeconds = nil; exercise.sets[index].reps = 10 }
                                        Button("按秒数") { exercise.sets[index].durationSeconds = 30; exercise.sets[index].reps = 0; exercise.sets[index].weight = nil }
                                    }.bojiType(.caption)
                                    if exercise.sets[index].durationSeconds == nil {
                                        HStack {
                                            Text("重量 kg").bojiType(.caption).foregroundStyle(.secondary)
                                            Spacer()
                                            TextField("开练时填写", value: $exercise.sets[index].weight, format: .number)
                                                .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                                                .accessibilityLabel("第\(index + 1)组重量，千克，选填")
                                        }
                                    }
                                }
                            }
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: BojiLayout.rowGap) { setCountActions }
                                VStack(alignment: .leading, spacing: BojiLayout.rowGap) { setCountActions }
                            }
                        }
                        if let replacementNotice { Text(replacementNotice).bojiType(.label).foregroundStyle(.secondary) }
                        Button(searchingLibrary ? "收起动作搜索" : "从动作库更换") { searchingLibrary.toggle() }.buttonStyle(SecondaryButton())
                        if searchingLibrary {
                        TextField("搜索动作或器械", text: $query).padding(ClubUI.pageInset)
                            .background(ClubUI.surface, in: RoundedRectangle(cornerRadius: ClubUI.cardRadius, style: .continuous))
                        if loading { ClubLoadingCard(title: "正在查找动作…") }
                        if let searchError { FlowError(message: searchError) }
                        if !loading && !query.isEmpty && results.isEmpty && searchError == nil {
                            Text("没有找到匹配动作，试试其他关键词。")
                                .bojiType(.label).foregroundStyle(.secondary)
                        }
                        ForEach(results) { item in
                            Button {
                                if exercise.library_id == item.id {
                                    query = ""; results = []; searchingLibrary = false
                                } else { pendingReplacement = item; confirmReplacement = true }
                            } label: {
                                HStack(spacing: BojiLayout.rowGap) {
                                    AsyncImage(url: ExerciseLibraryAPI.mediaURL(item.imageURL)) { image in image.resizable().scaledToFit() } placeholder: { Image(systemName: "figure.strengthtraining.traditional") }
                                        .frame(width: 56, height: 56)
                                    VStack(alignment: .leading, spacing: BojiLayout.tight) { Text(item.displayName).bojiType(.secondary); Text(item.equipmentLabel).bojiType(.caption).foregroundStyle(.secondary) }
                                    Spacer(); Image(systemName: "arrow.up.left")
                                }.padding(ClubUI.cardInset).background(ClubUI.surface, in: RoundedRectangle(cornerRadius: ClubUI.cardRadius, style: .continuous))
                            }.buttonStyle(ClubMotionButton())
                        }
                        }
                    }.padding(ClubUI.pageInset)
                }.scrollDismissesKeyboard(.interactively)
            }.navigationTitle("编辑动作").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
                .safeAreaInset(edge: .bottom) {
                    FlowDock {
                        if !validWeights { Text("重量请填写 0—2000 kg，或留空。") .bojiType(.caption).foregroundStyle(.red) }
                        Button("保存调整") { save(exercise); dismiss() }.buttonStyle(FlowButtonStyle()).disabled(!validWeights)
                    }
                }
                .task(id: "\(searchingLibrary)/\(query)") {
                    guard searchingLibrary else { results = []; loading = false; searchError = nil; return }
                    guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { results = []; loading = false; searchError = nil; return }
                    loading = true; searchError = nil
                    do {
                        try await Task.sleep(for: .milliseconds(350))
                        let found = try await ExerciseLibraryAPI.resolve(query, limit: 15)
                        try Task.checkCancellation()
                        results = found; loading = false
                    } catch is CancellationError { }
                    catch { if !Task.isCancelled { searchError = "动作库暂时无法连接，请稍后重新搜索。"; loading = false } }
                }
                .confirmationDialog("更换动作并重设目标？", isPresented: $confirmReplacement, titleVisibility: .visible) {
                    if let item = pendingReplacement {
                        Button("更换为\(item.displayName)") { replaceExercise(with: item); pendingReplacement = nil }
                    }
                    Button("取消", role: .cancel) { pendingReplacement = nil }
                } message: {
                    Text("保留当前组数，按新动作重新设置次数或秒数，并清空旧动作重量。保存前仍可调整；取消不会改变原动作。")
                }
        }.tint(FlowPalette.ink).presentationDragIndicator(.visible)
    }
    @ViewBuilder private var setCountActions: some View {
        Button("减少一组") { exercise.sets.removeLast() }.buttonStyle(SecondaryButton())
            .disabled(exercise.sets.count <= 1)
        Button("增加一组") { exercise.sets.append(exercise.sets.last ?? AIPlanSet(weight: nil, reps: 10)) }.buttonStyle(SecondaryButton())
            .disabled(exercise.sets.count >= 10)
    }
    private var validWeights: Bool { exercise.sets.allSatisfy { $0.weight.map { $0.isFinite && (0...2000).contains($0) } ?? true } }

    private func replaceExercise(with item: LibraryExercise) {
        let targets = ExerciseMeasurement.planReplacementSets(count: exercise.sets.count, name: item.displayName,
            query: item.name, recordingUnit: item.suggestedRecordingUnit, trainingType: item.trainingTypeZH)
        exercise.name = item.displayName; exercise.muscle = item.muscleLabel
        exercise.library_query = item.name; exercise.library_id = item.id
        exercise.custom_id = nil; exercise.custom_unit = nil; exercise.sets = targets
        replacementNotice = "已按新动作重设目标，旧重量已清空，请核对后保存。"
        query = ""; results = []; searchingLibrary = false
    }
}


struct ContinueWeekView: View {
    let endDate: Date
    var initialCycle: TrainingCycle? = nil
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var selected = Set<String>()
    @State private var confirming = false
    @State private var error: String?
    @State private var sourceEnd = Date()
    @State private var ownerID: Int?
    @State private var destinationStart: Date?
    @State private var loaded = false
    @State private var sourceDayCount = 7
    @State private var operationID = UUID()
    @State private var confirmedSessions: [AIPlanSession] = []
    @State private var sourceBaseline: [String: DayLog] = [:]
    @State private var targetBaseline: [String: DayLog] = [:]
    private var sourceStart: Date { ClubDates.calendar.date(byAdding: .day, value: -(sourceDayCount - 1), to: sourceEnd) ?? sourceEnd }
    private var sessions: [AIPlanSession] { store.continuationSessions(starting: sourceStart, ending: sourceEnd, nextStart: destinationStart ?? earliestDestinationStart) }
    private var earliestDestinationStart: Date {
        let today = ClubDates.calendar.startOfDay(for: Date())
        let followingSourceDate = ClubDates.calendar.date(byAdding: .day, value: 1, to: sourceEnd) ?? sourceEnd
        let followingSource = ClubDates.calendar.startOfDay(for: followingSourceDate)
        return max(today, followingSource)
    }
    var body: some View {
        ClubNavigationStack132 {
            List {
                sourceSection
                ForEach(sessions, id: \.date) { session in
                    let occupied = !(store.state.days[session.date]?.exercises.isEmpty ?? true)
                    Toggle(isOn: Binding(get: { selected.contains(session.date) }, set: { if $0 { selected.insert(session.date) } else { selected.remove(session.date) } })) {
                        VStack(alignment: .leading) { Text(ClubDates.date(fromKey: session.date).map { ClubDates.label($0, format: "M月d日 EEEE") } ?? session.date); Text(session.exercises.map(\.displayName).joined(separator: "、")).bojiType(.caption); if occupied { Text("已有安排，保留原计划").bojiType(.caption).foregroundStyle(.secondary) } }
                    }.disabled(occupied)
                }
                if sessions.isEmpty { Text("这一周还没有保存的训练安排。先回到“我的计划”制定一份计划，或从动作库自由添加。") }
                if let error { Text(error).foregroundStyle(.red) }
                Button("确认安排下一周") { if selected.isEmpty { error = "请至少选择一个没有已有安排的训练日。" } else { prepareConfirmation() } }.buttonStyle(PrimaryButton())
            }.clubListSurface().navigationTitle("下一周安排预览").navigationBarTitleDisplayMode(.inline)
            .onAppear {
                guard !loaded else { return }; loaded = true; sourceDayCount = initialCycle?.dates.count ?? 7; sourceEnd = endDate; ownerID = store.editingAccountID
                destinationStart = earliestDestinationStart
                selected = Set(sessions.filter { store.state.days[$0.date]?.exercises.isEmpty ?? true }.map(\.date))
            }
            .onChange(of: destinationStart) { _, _ in
                operationID = UUID()
                selected = Set(sessions.filter { store.state.days[$0.date]?.exercises.isEmpty ?? true }.map(\.date)); error = nil
            }
            .onChange(of: sourceEnd) { _, _ in
                operationID = UUID()
                if destinationStart.map({ ClubDates.calendar.startOfDay(for: $0) < earliestDestinationStart }) ?? true {
                    destinationStart = earliestDestinationStart
                }
                selected = Set(sessions.filter { store.state.days[$0.date]?.exercises.isEmpty ?? true }.map(\.date)); error = nil
            }
            .onChange(of: selected) { _, _ in operationID = UUID() }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .onChange(of: store.editingAccountID) { _, id in if id != ownerID { dismiss() } }
            .confirmationDialog("确认添加这些日期的安排？", isPresented: $confirming, titleVisibility: .visible) {
                Button("确认添加") {
                    applyContinuation()
                }
            }
        }
    }
    private var sourceSection: some View {
        Section {
            DisclosureGroup("查看或修改来源日期") {
            DatePicker("来源安排的开始日期", selection: Binding(get: {
                sourceStart
            }, set: { sourceEnd = ClubDates.calendar.date(byAdding: .day, value: sourceDayCount - 1, to: $0) ?? $0 }), displayedComponents: .date)
            }
            let start = sourceStart
            let nextStart = max(destinationStart ?? ClubDates.calendar.date(byAdding: .day, value: 1, to: sourceEnd) ?? sourceEnd, earliestDestinationStart)
            let nextEnd = ClubDates.calendar.date(byAdding: .day, value: 6, to: nextStart) ?? nextStart
            DatePicker("下一周从哪天开始", selection: Binding(get: { nextStart }, set: { destinationStart = max(ClubDates.calendar.startOfDay(for: $0), earliestDestinationStart) }), in: earliestDestinationStart..., displayedComponents: .date)
            Text("\(ClubDates.label(start))—\(ClubDates.label(sourceEnd)) → \(ClubDates.label(nextStart))—\(ClubDates.label(nextEnd))").bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
            Text("已选择 \(selected.count) 次训练；已有安排的日期会保留。").bojiType(.secondary)
            if sourceDayCount < 7 { Text("这份原计划只剩 \(sourceDayCount) 天，仅沿用上方日期范围内的安排，不会带入前一份计划。其余日期留空，可另行添加训练。").bojiType(.secondary) }
            Text("仅沿用上方日期范围内的动作、组数与目标次数，从目标起始日顺序安排。新训练从未完成状态开始，已有安排的日期会保留原计划。").bojiType(.secondary).foregroundStyle(.secondary)
        }
    }
    private func applyContinuation() {
            guard ownerID != nil, ownerID == store.editingAccountID else { dismiss(); return }
            guard sourceBaseline.allSatisfy({ PlanAdoptionRules.sameTraining(store.state.days[$0.key] ?? DayLog(), $0.value) }) else { error = "来源安排在预览后发生变化，请重新核对。"; return }
            let chosen = confirmedSessions
            guard !chosen.isEmpty, chosen.allSatisfy({ store.state.days[$0.date]?.exercises.isEmpty ?? true }) else { error = "日期已有新安排，请关闭后重新预览。"; return }
            let result = AIResult(kind: "plan", notes: [], title: "下一周训练安排", sessions: chosen)
            if store.applyAIPlan(result, jobID: PlanContinuationRules.operationID(operationID), cycleStart: destinationStart ?? earliestDestinationStart, minimumCycleStart: earliestDestinationStart, expectedDays: targetBaseline) { dismiss() } else { error = store.takeMessage() }
    }
    private func prepareConfirmation() {
        if let cycle = initialCycle, ClubDates.key(sourceStart) == cycle.start, ClubDates.key(sourceEnd) == cycle.end {
            guard TrainingCycle.available(days: store.state.days).contains(where: { $0.start == cycle.start && $0.end == cycle.end && $0.sourceJobID == cycle.sourceJobID }) else {
                error = "来源计划的日期范围已更新，请回到“我的计划”重新选择。"; return
            }
        }
        let keys = PlanContinuationRules.sourceDates(start: sourceStart, end: sourceEnd).map(ClubDates.key)
        sourceBaseline = Dictionary(uniqueKeysWithValues: keys.map { ($0, store.state.days[$0] ?? DayLog()) })
        confirmedSessions = sessions.filter { selected.contains($0.date) }
        targetBaseline = Dictionary(uniqueKeysWithValues: confirmedSessions.map { ($0.date, store.state.days[$0.date] ?? DayLog()) })
        confirming = true
    }
}

#if DEBUG
enum PlanAuditFactory {
 static func editor() -> some View { PlanExerciseEditor(exercise: AIPlanExercise(name: "哑铃卧推", muscle: "胸", sets: [AIPlanSet(weight: 20, reps: 10)], library_query: nil), save: { _ in }) }
}
#endif
