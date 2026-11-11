import SwiftUI

struct ClubTrainingRoute: Identifiable {
    let id = UUID()
    let date: Date
}

/// 计划卡路由：携带被点选的周期 ID；「查看我的计划」才使用默认焦点。
struct PlanListRoute: Identifiable {
    let id = UUID()
    let cycleStart: String?
}

struct PlanMoveRoute: Identifiable {
    let id = UUID()
    let date: Date
}

struct PlanAdvanceRoute: Identifiable {
    let id = UUID()
    let date: Date
}

struct ClubPlanHub: View {
    @Binding var selectedDate: Date
    let openWorkout: () -> Void
    var embeddedInShell = false
    var scrollAnchor: Binding<String?> = .constant(nil)
    var calendarExpanded: Binding<Bool>? = nil
    @EnvironmentObject private var store: AppStore
    @State private var showGenerator = false
    @State private var showCreationSheet = false
    var createOnOpen = false
    @State private var showCreation = false
    @State private var planRoute: PlanListRoute?
    @State private var showLibrary = false
    @State private var showManualPlan = false
    @State private var showVersions = false
    @State private var moveRoute: PlanMoveRoute?
    @State private var advanceRoute: PlanAdvanceRoute?
    @State private var restDate: Date?
    @State private var showRestConfirm = false

    private var activeCycles: [TrainingCycle] {
        TrainingCycle.available(days: store.state.days).filter { !$0.plannedDates.isEmpty }
    }
    private var currentCycle: TrainingCycle? {
        let today = ClubDates.key(Date())
        return activeCycles.first { $0.dates.contains(today) && $0.end >= today }
            ?? activeCycles.filter { $0.start > today }.min { $0.start < $1.start }
    }
    private var cycleTitle: String? {
        guard let currentCycle else { return nil }
        return currentCycle.dates.contains(ClubDates.key(Date())) ? "当前计划" : "即将开始"
    }
    private var cycleDetail: String? {
        guard let cycle = currentCycle else { return nil }
        return "\(compactCycleLabel(cycle)) · \(cycle.plannedDates.count) 个训练日"
    }

    /// §10.5：34pt 标题 + 顶部进度卡（Score「第 N 周」+ 环）。
    /// 没有计划时给空态，而不是一张空卡。
    private var planProgressHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("计划").font(BojiV2.display).foregroundStyle(BojiV2.textPrimary)
            BojiGlassCard(radius: BojiV2.glassCardRadius, padding: BojiV2.glassPadding) {
                if let cycle = currentCycle {
                    HStack(spacing: 16) {
                        ZStack {
                            BojiProgressRing(progress: cycleProgress, lineWidth: 8)
                            Text("第 \(cycleWeek) 周").font(BojiV2.caption)
                                .foregroundStyle(BojiV2.textPrimary)
                        }
                        .frame(width: 92, height: 92)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(cycleTitle ?? "训练计划").font(BojiV2.bodyEm)
                                .foregroundStyle(BojiV2.textPrimary)
                            Text("\(cycle.plannedDates.count) 个训练日 · 还剩 \(max(0, cycleTotalWeeks - cycleWeek)) 周")
                                .font(BojiV2.caption).foregroundStyle(BojiV2.textSecondary)
                        }
                        Spacer(minLength: 0)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("还没有计划").font(BojiV2.bodyEm).foregroundStyle(BojiV2.textPrimary)
                        Text("选一个计划").font(BojiV2.caption).foregroundStyle(BojiV2.textSecondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 当前处在计划的第几周（从 1 开始）。
    private var cycleWeek: Int {
        guard let cycle = currentCycle, let start = ClubDates.date(fromKey: cycle.start) else { return 1 }
        let elapsed = ClubDates.calendar.dateComponents([.day], from: start, to: Date()).day ?? 0
        return max(1, elapsed / 7 + 1)
    }

    /// 计划总周数：按首尾日期向上取整，至少 1 周。
    private var cycleTotalWeeks: Int {
        guard let cycle = currentCycle,
              let start = ClubDates.date(fromKey: cycle.start),
              let end = ClubDates.date(fromKey: cycle.end) else { return 1 }
        let days = ClubDates.calendar.dateComponents([.day], from: start, to: end).day ?? 0
        return max(1, Int((Double(days) / 7).rounded(.up)))
    }

    private var cycleProgress: Double {
        guard cycleTotalWeeks > 0 else { return 0 }
        return min(1, Double(cycleWeek) / Double(cycleTotalWeeks))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if embeddedInShell {
                    planProgressHeader
                } else {
                    BojiPageHeader(
                        eyebrow: "TRAINING PLAN · 训练计划",
                        title: cycleTitle ?? "训练计划",
                        subtitle: cycleDetail ?? "按目标编排与调整每周训练安排"
                    )
                }
                PlanWeekCard(selectedDate: $selectedDate, monthExpanded: calendarExpanded,
                             cycleTitle: nil,
                             cycleDetail: nil,
                             openPlan: currentCycle.map { cycle in
                                 { planRoute = PlanListRoute(cycleStart: cycle.start) }
                             }).id("training-calendar")
                PlanDaySummaryCard(date: selectedDate, openWorkout: openWorkout,
                                   onMove: { moveRoute = PlanMoveRoute(date: selectedDate) },
                                   onRest: { restDate = selectedDate; showRestConfirm = true },
                                   onAdvance: { advanceRoute = PlanAdvanceRoute(date: selectedDate) },
                                   openPlan: { showCreationSheet = true },
                                   selectDate: { selectedDate = $0 }).id("training-summary")
                if let cycle = TrainingHandoff.pending(on: selectedDate, days: store.state.days) {
                    Button("安排后续训练", systemImage: "calendar.badge.plus") { planRoute = PlanListRoute(cycleStart: cycle.start) }
                        .font(.footnote).buttonStyle(.borderless)
                }
                DisclosureGroup("创建或更换计划", isExpanded: $showCreation) {
                    creationCard.padding(.top, BojiSpace.general)
                }.font(.subheadline).tint(ClubBrand.accent).id("training-creation")
                entryRows.id("training-links")
            }
            .scrollTargetLayout()
            .padding(.horizontal, ClubUI.pageInset).padding(.top, 8).padding(.bottom, ClubUI.pageInset)
            .frame(maxWidth: ClubUI.contentWidth)
            .frame(maxWidth: .infinity)
        }
        .scrollPosition(id: scrollAnchor, anchor: .top)
        .background { ClubBackground() }
        .onAppear { if !hasCurrentPlan { showCreation = true }; if createOnOpen { showCreationSheet = true } }
        .modifier(ClubPlanHubNavigationChrome(embedded: embeddedInShell))
        .toolbar {
            if !embeddedInShell {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("动作库", systemImage: "rectangle.stack") { showLibrary = true }
                        Button("方案版本", systemImage: "clock.arrow.circlepath") { showVersions = true }
                    } label: { Image(systemName: "ellipsis") }
                        .accessibilityLabel("计划工具")
                }
            }
        }
        .sheet(isPresented: $showCreationSheet) { PlanCreationSheet(date: selectedDate) }
        .sheet(isPresented: $showGenerator) { PlanView(date: max(Date(), selectedDate)) }
        .sheet(isPresented: $showManualPlan) { WeeklyPlanCreator130(startDate: max(Date(), selectedDate)) }
        .sheet(isPresented: $showVersions) { ClubPlanVersionsView() }
        .sheet(item: $planRoute) { route in TrainingPlansView(focusDate: selectedDate, initialCycleStart: route.cycleStart) }
        .sheet(item: $moveRoute) { route in PlanMoveSheet(sourceDate: route.date) }
        .sheet(item: $advanceRoute) { route in AdvanceWorkoutView(date: route.date) }
        .sheet(isPresented: $showLibrary) {
            NavigationStack {
                ExerciseLibraryView(date: selectedDate) { showLibrary = false }
                    .navigationTitle("添加到 \(ClubDates.label(selectedDate))")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { DismissButton() } }
            }
        }
        .alert("设为休息日？", isPresented: $showRestConfirm) {
            Button("设为休息日", role: .destructive) {
                if let date = restDate, !store.setPlannedRestDay(on: date) {
                    store.message = store.takeMessage(fallback: "这一天暂时不能改为休息日，请先确认没有已开始的训练。")
                }
                restDate = nil
            }
            Button("取消", role: .cancel) { restDate = nil }
        } message: {
            Text("会清空这一天的未开始安排并重算本周计划的训练日；已完成的训练、历史版本和记录不会被删除。")
        }
    }

    private func compactCycleLabel(_ cycle: TrainingCycle) -> String {
        guard let start = ClubDates.date(fromKey: cycle.start),
              let end = ClubDates.date(fromKey: cycle.end) else { return cycle.label }
        let calendar = ClubDates.calendar
        let startYear = calendar.component(.year, from: start)
        let endYear = calendar.component(.year, from: end)
        let startMonth = calendar.component(.month, from: start)
        let endMonth = calendar.component(.month, from: end)
        if startYear != endYear {
            return "\(ClubDates.label(start, format: "yyyy年M月d日"))—\(ClubDates.label(end, format: "yyyy年M月d日"))"
        }
        if startMonth == endMonth {
            return "\(ClubDates.label(start, format: "M月d日"))—\(ClubDates.label(end, format: "d日"))"
        }
        return "\(ClubDates.label(start, format: "M月d日"))—\(ClubDates.label(end, format: "M月d日"))"
    }

    private var creationCard: some View {
        ClubCard {
            Text(hasCurrentPlan ? "创建新计划" : "开始第一份计划")
                .bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
            Text("让 AI 制定计划，或自己安排每周训练。保存前可查看。")
                .font(.subheadline).foregroundStyle(.secondary)
            BojiAdaptiveGroup {
                Button { showGenerator = true } label: {
                    Label("AI 制定", systemImage: "sparkles")
                        .frame(maxWidth: .infinity, minHeight: BojiSize.primaryButtonHeight)
                }
                .buttonStyle(BojiButtonStyle(kind: .primary))
                Button { showManualPlan = true } label: {
                    Label("自由创建", systemImage: "slider.horizontal.3")
                        .frame(maxWidth: .infinity, minHeight: BojiSize.primaryButtonHeight)
                }
                .buttonStyle(BojiButtonStyle(kind: .secondary))
                .accessibilityIdentifier("plan-free-create")
            }
        }
    }

    private var entryRows: some View {
        VStack(spacing: 0) {
            trainingLink("动作库", detail: "按部位与器械查找动作", library: true) { showLibrary = true }
                .accessibilityIdentifier("plan-open-library")
            Divider().padding(.leading, 64)
            trainingLink("我的计划", detail: "当前安排与历史方案", library: false) { planRoute = PlanListRoute(cycleStart: nil) }
        }.background(BojiColor.cardSurface, in: RoundedRectangle(cornerRadius: 22))
    }
    private func trainingLink(_ title: String, detail: String, library: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                TrainingEntryGlyph125(library: library).frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.body.weight(.medium)).foregroundStyle(BojiColor.textPrimary)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.caption.weight(.medium)).foregroundStyle(.tertiary)
            }.padding(.horizontal, 16).frame(minHeight: 78).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private var hasCurrentPlan: Bool {
        let today = ClubDates.key(Date())
        return activeCycles.contains { $0.end >= today } ||
            store.state.days.contains { $0.key >= today && !$0.value.exercises.isEmpty }
    }
}

private struct ClubPlanHubNavigationChrome: ViewModifier {
    let embedded: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if embedded { content }
        else { content.navigationTitle("训练").navigationBarTitleDisplayMode(.inline) }
    }
}

struct ClubPlanVersionsView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var owner: Int?
    private var versions: [ClubPlanVersion] {
        var values: [ClubPlanVersion] = []
        for log in store.state.days.values { values.append(contentsOf: log.planVersions ?? []) }
        values.sort { (left: ClubPlanVersion, right: ClubPlanVersion) -> Bool in
            if left.recordedAt == right.recordedAt { return left.id > right.id }
            return left.recordedAt > right.recordedAt
        }
        var seen = Set<String>()
        return values.filter { seen.insert($0.id).inserted }
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("每次确认，都留下依据").bojiFont(.pageTitle).foregroundStyle(BojiColor.textPrimary)
                    Text("查看以前的计划和对应训练记录。")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if versions.isEmpty { EmptyNote(title: "还没有方案版本", detail: "采用新的 AI 或自由计划后，将保存当时的安排、目标与生效范围。") }
                    ForEach(versions) { version in versionRow(version) }
                }.padding(ClubUI.pageInset)
            }.background { ClubBackground() }
                .navigationTitle("方案版本").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { DismissButton() } }
                .onAppear { owner = store.editingAccountID }
                .onChange(of: store.editingAccountID) { _, id in if id != owner { dismiss() } }
        }
    }
    private func versionRow(_ version: ClubPlanVersion) -> some View {
        NavigationLink {
            ClubPlanVersionDetail(version: version)
        } label: {
            ClubCard {
                HStack {
                    Text(version.title).bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right")
                }
                Text("\(version.start) 起 · \(version.duration) 天 · \(adoptedDaysLabel(version))")
                    .font(.subheadline).foregroundStyle(.secondary)
                Text("确认于 \(ClubDates.label(version.recordedAt, format: "M月d日 HH:mm"))")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.buttonStyle(ClubMotionButton())
    }
    private func adoptedDaysLabel(_ version: ClubPlanVersion) -> String {
        guard let changes = version.changes, Set(changes.map(\.date)) == Set(version.scopeDates) else {
            return "实际采用总数未留存"
        }
        let count = changes.filter { !$0.retained && !version.retainedDates.contains($0.date) && !$0.after.isEmpty }.count
        return "\(count) 个训练安排日"
    }
}

private struct ClubPlanVersionDetail: View {
    let version: ClubPlanVersion
    @State private var restoredDraft: ManualPlanDraft?
    @State private var restoreError: String?
    private var source: String {
        if version.id.hasPrefix("coach-plan-") { return "Club AI 建议 · 由你确认" }
        switch version.source { case "manual": return "自由创建"; case "weekly_review": return "周复盘调整"; case "continuation": return "沿用已有计划"; default: return "AI 制定" }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ClubCard {
                    Text(version.title).bojiFont(.pageTitle).foregroundStyle(BojiColor.textPrimary)
                    Text("\(source) · \(version.start) 起 \(version.duration) 天")
                    Text("制定时目标：\(version.requestedProfile.goal) · 每周 \(version.requestedProfile.daysPerWeek) 练")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if version.requestedProfile != version.adoptedProfile {
                        Text("采用时资料已有变化；原方案的制定资料与采用时资料分别保留。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if let description = version.planDescription, !description.isEmpty {
                        Text("计划描述：\(description)").font(.subheadline)
                    }
                    if let intent = version.planIntent, !intent.isEmpty {
                        Text("计划意图：\(intent)").font(.subheadline)
                    }
                    if let pattern = version.planPattern, !pattern.isEmpty {
                        Text("安排方式：\(pattern)").font(.footnote).foregroundStyle(.secondary)
                    }
                    if let notes = version.notes, !notes.isEmpty,
                       version.planDescription == nil, version.planIntent == nil, version.planPattern == nil {
                        // 旧版本只把描述/意图放在 notes 里；继续可读，但不补造字段。
                        ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                            Text(note).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    if !version.previousIDs.isEmpty { Text("本次涉及此前 \(version.previousIDs.count) 份方案的日期范围，旧快照继续保留。")
                        .font(.footnote).foregroundStyle(.secondary) }
                    if !version.retainedDates.isEmpty { Text("保留已开始的训练：\(version.retainedDates.joined(separator: "、"))")
                        .font(.footnote).foregroundStyle(.secondary) }
                }
                Button("以此为基础创建新计划") {
                    do {
                        guard let changes = version.changes, Set(changes.map(\.date)) == Set(version.scopeDates) else {
                            throw ManualPlanError.message("这份旧方案缺少完整的实际采用快照，无法可靠复用。请从动作库创建。")
                        }
                        guard let origin = ClubDates.date(fromKey: version.start) else { throw ManualPlanError.message("原方案日期无法读取。") }
                        let scope = Set((0..<version.duration).compactMap { ClubDates.calendar.date(byAdding: .day, value: $0, to: origin) }.map(ClubDates.key))
                        guard scope == Set(version.scopeDates) else { throw ManualPlanError.message("这份方案只调整了部分日期，不能据此补造整个周期。请从完整方案复用或自由创建。") }
                        let sessions = changes.filter { !$0.after.isEmpty }.map { AIPlanSession(date: $0.date, label: "复用训练", exercises: $0.after) }
                        let result = AIResult(kind: "plan", notes: [], title: String(("复用：" + version.title).prefix(80)), sessions: sessions, plan_days: version.duration)
                        restoredDraft = try ManualPlanDraft.importing(result, originalStart: version.start)
                        restoreError = nil
                    } catch { restoreError = AppErrorText.message(error) }
                }.buttonStyle(SecondaryButton())
                Text("以该版本为基础创建新草稿，原方案与历史记录保留。")
                    .font(.footnote).foregroundStyle(.secondary)
                if let restoreError { FlowError(message: restoreError) }
                NavigationLink("查看方案执行跟进") { ClubPlanFollowupView(version: version) }.buttonStyle(PrimaryButton())
                if let changes = version.changes {
                    ClubCard { ClubPlanChangesView(changes: changes, title: "这次确认的变更") }
                }
                ForEach(version.scopeDates, id: \.self) { key in
                    ClubPlanVersionDay(version: version, key: key)
                }
            }.padding(ClubUI.pageInset)
        }.background { ClubBackground() }.navigationTitle("当时保存的安排").navigationBarTitleDisplayMode(.inline)
            .sheet(item: $restoredDraft) { ManualPlanView(initialDraft: $0) }
    }
}

private struct ClubPlanVersionDay: View {
    let version: ClubPlanVersion
    let key: String
    var body: some View {
                    ClubCard(compact: true) {
                        Text(key).bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
                        let saved = version.changes?.first { $0.date == key }
                        let originalSession = version.sessions.first { $0.date == key }
                        let exercises = saved?.after ?? originalSession?.exercises ?? []
                        if version.retainedDates.contains(key) {
                            Text("保留当天原训练，没有采用这一天的新建议").font(.subheadline).foregroundStyle(.secondary)
                        } else if let session = originalSession {
                            Text(session.label).font(.subheadline.weight(.medium))
                        }
                        // New snapshots show the actual saved schedule, including
                        // existing movements when the member chose to append.
                        if !version.retainedDates.contains(key) || saved != nil {
                            ForEach(Array(exercises.enumerated()), id: \.offset) { _, exercise in
                                DisclosureGroup(exercise.displayName + " · \(exercise.sets.count) 组") {
                                    ForEach(Array(exercise.sets.enumerated()), id: \.offset) { index, set in
                                        Text("第 \(index + 1) 组 · " + ClubPlanChangeRules.setLabel(set))
                                            .font(.subheadline).padding(.vertical, 3)
                                    }
                                }.font(.subheadline)
                            }
                            if exercises.isEmpty { Text("休息与恢复").foregroundStyle(.secondary) }
                        }
                    }
    }
}

struct ClubPlanChangesView: View {
    let changes: [ClubPlanDayChange]
    var title = "采用前后对比"
    private var updated: Int { changes.filter { $0.changed && !$0.retained }.count }
    private var retained: Int { changes.filter(\.retained).count }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
            Text("\(updated) 天有变化" + (retained > 0 ? " · \(retained) 天保留已开始的训练" : ""))
                .font(.subheadline).foregroundStyle(.secondary)
            ForEach(changes) { day in
                DisclosureGroup {
                    if day.retained {
                        Text("当天已经开始的训练会保留。本次不会把建议写入这一天。")
                            .font(.subheadline).foregroundStyle(.secondary).padding(.vertical, BojiSpace.tight)
                    }
                    if day.before.isEmpty && day.after.isEmpty {
                        Text("没有新增训练动作").font(.subheadline).foregroundStyle(.secondary)
                    }
                    ForEach(ClubPlanChangeRules.movements(day)) { row in
                        ClubPlanMovementChangeRow(row: row).padding(.vertical, BojiSpace.tight)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(day.date).font(.subheadline.weight(.semibold))
                        Text(day.label).font(.subheadline).foregroundStyle(.secondary)
                    }.padding(.vertical, 4)
                }
                if day.id != changes.last?.id { Divider() }
            }
        }
    }
}

private struct ClubPlanMovementChangeRow: View {
    let row: ClubPlanMovementChange
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text((row.after ?? row.before)?.displayName ?? "训练动作").font(.subheadline.weight(.medium))
            if row.changed {
                DisclosureGroup(row.label + " · 查看每组对比") {
                    parameters("原安排", movement: row.before, index: row.oldIndex)
                    parameters("采用后", movement: row.after, index: row.newIndex)
                }.font(.subheadline)
            } else {
                Text("保持原安排 · \(row.after?.sets.count ?? 0) 组").font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
    private func parameters(_ label: String, movement: AIPlanExercise?, index: Int?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label + (index.map { " · 第 \($0 + 1) 个动作" } ?? "")).fontWeight(.medium)
            if let movement {
                Text(movement.rest_seconds.map { "组间休息 \($0) 秒" } ?? "组间休息沿用训练设置").foregroundStyle(.secondary)
                if movement.sets.isEmpty { Text("尚未设置训练组").foregroundStyle(.secondary) }
                ForEach(Array(movement.sets.enumerated()), id: \.offset) { index, set in
                    Text("第 \(index + 1) 组 · " + ClubPlanChangeRules.setLabel(set))
                        .foregroundStyle(.secondary)
                }
            } else { Text("无此动作").foregroundStyle(.secondary) }
        }.font(.subheadline).padding(.vertical, BojiSpace.tight)
    }
}

struct ClubRecordsHub: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var category: String
    var embeddedInShell = false
    init(category: Binding<String> = .constant("训练"), embeddedInShell: Bool = false) { _category = category; self.embeddedInShell = embeddedInShell }
    @State private var mealDate = Date()
    @State private var showReports = false
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Picker("记录分类", selection: $category) {
                    ForEach(["训练", "饮食", "身体"], id: \.self) { Text($0).tag($0) }
                }
                .clubAdaptivePicker().accessibilityIdentifier("records-category-picker")
            }
            .padding(.horizontal, ClubUI.pageInset)
            .padding(.top, BojiSpace.general)
            .padding(.bottom, 10)
            switch category {
            case "饮食": NutritionView(selectedDate: $mealDate)
            case "身体": BodyOverviewView(embedded: true)
            case "报告":
                ReportLibraryView(embedded: true)
            default: ScrollView { ReviewDashboardView().padding(ClubUI.pageInset) }
            }
        }.animation(reduceMotion ? nil : .smooth(duration: 0.25), value: category)
            .background { ClubBackground() }
            .navigationTitle("记录").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !embeddedInShell {
                    ToolbarItem(placement: .topBarTrailing) { Button("AI 解读档案", systemImage: "ellipsis") { showReports = true } }
                }
            }
            .sheet(isPresented: $showReports) { ReportLibraryView() }
    }
}

#if DEBUG
enum ProductAuditFactory {
 static func version(_ version: ClubPlanVersion) -> some View { ClubPlanVersionDetail(version: version) }
}
#endif
