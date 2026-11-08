import SwiftUI
import Charts

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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BojiLayout.rowGap) {
                if embeddedInShell {
                    VStack(alignment: .leading, spacing: BojiLayout.tight) {
                        Text("今天的训练").bojiType(.section)
                        if let cycleDetail { Text(cycleDetail).bojiType(.secondary).foregroundStyle(.secondary) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    BojiPageHeader(
                        eyebrow: "TRAINING PLAN · 训练计划",
                        title: cycleTitle ?? "训练计划",
                        subtitle: cycleDetail ?? "按目标安排与调整每周训练"
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
                        .bojiType(.label).buttonStyle(.borderless)
                }
                DisclosureGroup("创建或更换计划", isExpanded: $showCreation) {
                    creationCard.padding(.top, BojiSpace.general)
                }.bojiType(.secondary).tint(ClubBrand.accent).id("training-creation")
                entryRows.id("training-links")
            }
            .scrollTargetLayout()
            .padding(.horizontal, ClubUI.pageInset).padding(.top, BojiLayout.inline).padding(.bottom, ClubUI.pageInset)
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
                    Button {
                        showLibrary = true
                    } label: {
                        Image(systemName: "rectangle.stack")
                    }
                    .accessibilityLabel("动作库")
                }
            }
        }
        .sheet(isPresented: $showCreationSheet) { PlanCreationSheet(date: selectedDate) }
        .sheet(isPresented: $showGenerator) { PlanView(date: max(Date(), selectedDate)) }
        .sheet(isPresented: $showManualPlan) { WeeklyPlanCreator130(startDate: max(Date(), selectedDate)) }
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
            Text("制定计划，或自己安排每周训练。保存前可查看。")
                .bojiType(.secondary).foregroundStyle(.secondary)
            BojiAdaptiveGroup {
                Button { showGenerator = true } label: {
                    Label("制定", systemImage: "sparkles")
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
        trainingLink("动作库", detail: "按部位与器械查找动作", library: true) { showLibrary = true }
            .background(BojiColor.cardSurface, in: RoundedRectangle(cornerRadius: 20))
            .accessibilityIdentifier("plan-open-library")
    }
    private func trainingLink(_ title: String, detail: String, library: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: BojiLayout.rowGap) {
                TrainingEntryGlyph125(library: library).frame(width: 34, height: 34).contentShape(Rectangle().inset(by: -5)) // 命中区 44
                VStack(alignment: .leading, spacing: BojiLayout.tight) {
                    Text(title).bojiType(.body).foregroundStyle(BojiColor.textPrimary)
                    Text(detail).bojiType(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").bojiType(.caption).foregroundStyle(.tertiary)
            }.padding(.horizontal, BojiLayout.cardInset).frame(minHeight: 78).contentShape(Rectangle())
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
                VStack(alignment: .leading, spacing: BojiLayout.cardInset) {
                    Text("每次确认，都留下依据").bojiFont(.pageTitle).foregroundStyle(BojiColor.textPrimary)
                    Text("查看以前的计划和对应训练记录。")
                        .bojiType(.secondary).foregroundStyle(.secondary)
                    if versions.isEmpty { EmptyNote(title: "还没有方案版本", detail: "采用新的自动生成或自由计划后，将保存当时的安排、目标与生效范围。") }
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
                    .bojiType(.secondary).foregroundStyle(.secondary)
                Text("确认于 \(ClubDates.label(version.recordedAt, format: "M月d日 HH:mm"))")
                    .bojiType(.label).foregroundStyle(.secondary)
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
        if version.id.hasPrefix("coach-plan-") { return "建议 · 待确认" }
        switch version.source { case "manual": return "自由创建"; case "weekly_review": return "周复盘调整"; case "continuation": return "沿用已有计划"; default: return "制定" }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BojiLayout.cardInset) {
                ClubCard {
                    AIReferenceEntryButton(reference: .init(kind: "plan_version", resourceID: version.id, from: version.start, to: version.start, title: version.title))
                    Text(version.title).bojiFont(.pageTitle).foregroundStyle(BojiColor.textPrimary)
                    Text("\(source) · \(version.start) 起 \(version.duration) 天")
                    Text("制定时目标：\(version.requestedProfile.goal) · 每周 \(version.requestedProfile.daysPerWeek) 练")
                        .bojiType(.secondary).foregroundStyle(.secondary)
                    if version.requestedProfile != version.adoptedProfile {
                        Text("采用时资料已有变化；原方案的制定资料与采用时资料分别保留。")
                            .bojiType(.label).foregroundStyle(.secondary)
                    }
                    if let description = version.planDescription, !description.isEmpty {
                        Text("计划描述：\(description)").bojiType(.secondary)
                    }
                    if let intent = version.planIntent, !intent.isEmpty {
                        Text("计划意图：\(intent)").bojiType(.secondary)
                    }
                    if let pattern = version.planPattern, !pattern.isEmpty {
                        Text("安排方式：\(pattern)").bojiType(.label).foregroundStyle(.secondary)
                    }
                    if let notes = version.notes, !notes.isEmpty,
                       version.planDescription == nil, version.planIntent == nil, version.planPattern == nil {
                        // 旧版本只把描述/意图放在 notes 里；继续可读，但不补造字段。
                        ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                            Text(note).bojiType(.label).foregroundStyle(.secondary)
                        }
                    }
                    if !version.previousIDs.isEmpty { Text("本次涉及此前 \(version.previousIDs.count) 份方案的日期范围，旧快照继续保留。")
                        .bojiType(.label).foregroundStyle(.secondary) }
                    if !version.retainedDates.isEmpty { Text("保留已开始的训练：\(version.retainedDates.joined(separator: "、"))")
                        .bojiType(.label).foregroundStyle(.secondary) }
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
                    .bojiType(.label).foregroundStyle(.secondary)
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
                            Text("保留当天原训练，没有采用这一天的新建议").bojiType(.secondary).foregroundStyle(.secondary)
                        } else if let session = originalSession {
                            Text(session.label).bojiType(.secondary)
                        }
                        // New snapshots show the actual saved schedule, including
                        // existing movements when the member chose to append.
                        if !version.retainedDates.contains(key) || saved != nil {
                            ForEach(Array(exercises.enumerated()), id: \.offset) { _, exercise in
                                DisclosureGroup(exercise.displayName + " · \(exercise.sets.count) 组") {
                                    ForEach(Array(exercise.sets.enumerated()), id: \.offset) { index, set in
                                        Text("第 \(index + 1) 组 · " + ClubPlanChangeRules.setLabel(set))
                                            .bojiType(.secondary).padding(.vertical, BojiLayout.tight)
                                    }
                                }.bojiType(.secondary)
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
        VStack(alignment: .leading, spacing: BojiLayout.rowGap) {
            Text(title).bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
            Text("\(updated) 天有变化" + (retained > 0 ? " · \(retained) 天保留已开始的训练" : ""))
                .bojiType(.secondary).foregroundStyle(.secondary)
            ForEach(changes) { day in
                DisclosureGroup {
                    if day.retained {
                        Text("当天已经开始的训练会保留。本次不会把建议写入这一天。")
                            .bojiType(.secondary).foregroundStyle(.secondary).padding(.vertical, BojiSpace.tight)
                    }
                    if day.before.isEmpty && day.after.isEmpty {
                        Text("没有新增训练动作").bojiType(.secondary).foregroundStyle(.secondary)
                    }
                    ForEach(ClubPlanChangeRules.movements(day)) { row in
                        ClubPlanMovementChangeRow(row: row).padding(.vertical, BojiSpace.tight)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: BojiLayout.tight) {
                        Text(day.date).bojiType(.secondary)
                        Text(day.label).bojiType(.secondary).foregroundStyle(.secondary)
                    }.padding(.vertical, BojiLayout.tight)
                }
                if day.id != changes.last?.id { Divider() }
            }
        }
    }
}

private struct ClubPlanMovementChangeRow: View {
    let row: ClubPlanMovementChange
    var body: some View {
        VStack(alignment: .leading, spacing: BojiLayout.inline) {
            Text((row.after ?? row.before)?.displayName ?? "训练动作").bojiType(.secondary)
            if row.changed {
                DisclosureGroup(row.label + " · 查看每组对比") {
                    parameters("原安排", movement: row.before, index: row.oldIndex)
                    parameters("采用后", movement: row.after, index: row.newIndex)
                }.bojiType(.secondary)
            } else {
                Text("保持原安排 · \(row.after?.sets.count ?? 0) 组").bojiType(.secondary).foregroundStyle(.secondary)
            }
        }
    }
    private func parameters(_ label: String, movement: AIPlanExercise?, index: Int?) -> some View {
        VStack(alignment: .leading, spacing: BojiLayout.tight) {
            Text(label + (index.map { " · 第 \($0 + 1) 个动作" } ?? "")).fontWeight(.medium)
            if let movement {
                Text(movement.rest_seconds.map { "组间休息 \($0) 秒" } ?? "组间休息沿用训练设置").foregroundStyle(.secondary)
                if movement.sets.isEmpty { Text("尚未设置训练组").foregroundStyle(.secondary) }
                ForEach(Array(movement.sets.enumerated()), id: \.offset) { index, set in
                    Text("第 \(index + 1) 组 · " + ClubPlanChangeRules.setLabel(set))
                        .foregroundStyle(.secondary)
                }
            } else { Text("无此动作").foregroundStyle(.secondary) }
        }.bojiType(.secondary).padding(.vertical, BojiSpace.tight)
    }
}

/// Missing observations stay missing; profile estimates never become chart samples.
enum ClubDashboardFacts {
    struct WeightPoint: Identifiable {
        let date: Date
        let weight: Double
        let source: String
        var id: String { ClubDates.key(date) }
    }

    static func calorieTarget(_ target: NutritionTarget?) -> Double? {
        guard let target, target.generalGuidanceOnly != true,
              target.caloriesMax.isFinite, target.caloriesMax > 0 else { return nil }
        return target.caloriesMax
    }

    static func weightHistory(days: [String: DayLog], healthDays: [String: HealthDay], through date: Date) -> [WeightPoint] {
        let calendar = ClubDates.calendar
        let today = calendar.startOfDay(for: date)
        return (0..<14).reversed().compactMap { offset in
            guard let dayDate = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let key = ClubDates.key(dayDate)
            if let day = days[key], let sample = BodyWeightHistory.points(days: [key: day], through: date, limit: Int.max).last,
               sample.date <= date {
                return WeightPoint(date: sample.date, weight: sample.kilograms, source: "已保存测量")
            }
            guard let sample = (healthDays[key] ?? days[key]?.health)?.bodyMass,
                  sample.value.isFinite, (20...400).contains(sample.value) else { return nil }
            let measuredAt = sample.recordedAt ?? dayDate
            guard measuredAt <= date, ClubDates.key(measuredAt) == key else { return nil }
            return WeightPoint(date: measuredAt, weight: sample.value, source: sample.source.name)
        }
    }

    static func trainingStreak(days: [String: DayLog], through date: Date) -> Int {
        let calendar = ClubDates.calendar
        func weekKey(_ date: Date) -> Int {
            let components = calendar.dateComponents([.weekOfYear, .yearForWeekOfYear], from: date)
            return (components.yearForWeekOfYear ?? 0) * 100 + (components.weekOfYear ?? 0)
        }
        let cutoff = ClubDates.key(date)
        let weeks = Set(days.compactMap { key, log -> Int? in
            guard key <= cutoff, log.confirmedTraining.hasTraining, let day = ClubDates.date(fromKey: key) else { return nil }
            return weekKey(day)
        })
        var cursor = date
        if !weeks.contains(weekKey(cursor)), let previous = calendar.date(byAdding: .weekOfYear, value: -1, to: cursor) { cursor = previous }
        var count = 0
        while weeks.contains(weekKey(cursor)) {
            count += 1
            guard let previous = calendar.date(byAdding: .weekOfYear, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return count
    }
}

struct ClubRecordsExecutiveDashboard: View {
    @Binding var category: String
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var health: HealthDataService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var showWeightSheet = false
    @State private var isTelemetryPulsing = false

    private var today: Date { Date() }
    private var todayLog: DayLog { store.log(for: today) }
    private var todayConfirmed: DayLog.ConfirmedTraining { todayLog.confirmedTraining }

    private var targetCalories: Double? {
        ClubDashboardFacts.calorieTarget(todayLog.nutritionTarget ?? store.state.nutritionTarget)
    }
    private var todayCalories: Double { todayLog.calories }
    private var calorieRatio: Double? {
        guard todayLog.mealsComplete, todayLog.unknownNutritionMeals == 0, let targetCalories else { return nil }
        return max(0, todayCalories / targetCalories)
    }
    private var todayProtein: Double { todayLog.protein }
    private var todayCarbs: Double { todayLog.knownMeals.reduce(0) { $0 + $1.carbs } }
    private var todayFat: Double { todayLog.knownMeals.reduce(0) { $0 + $1.fat } }
    private var mealCount: Int { todayLog.meals.count }
    private var weightHistory: [ClubDashboardFacts.WeightPoint] {
        ClubDashboardFacts.weightHistory(days: store.state.days, healthDays: health.days, through: today)
    }
    private var weightDelta: Double? {
        guard weightHistory.count >= 2, let first = weightHistory.first?.weight, let last = weightHistory.last?.weight else { return nil }
        return last - first
    }
    private var trainingStreakWeeks: Int { ClubDashboardFacts.trainingStreak(days: store.state.days, through: today) }

    var body: some View {
        ScrollView {
            VStack(spacing: BojiLayout.cardInset) {
                telemetryHeader
                workoutTelemetryCard
                nutritionTelemetryCard
                bodyTelemetryCard
                clubMomentumCard
                quickActionsDock
                    .padding(.top, BojiLayout.tight)
                    .padding(.bottom, BojiLayout.Rhythm.footerClearance)
            }
            .padding(.horizontal, ClubUI.pageInset)
            .padding(.top, BojiSpace.tightRow)
        }
        .sheet(isPresented: $showWeightSheet) {
            BodyWeightView(initialDate: Date())
        }
    }

    private var telemetryHeader: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: BojiLayout.tight) {
                Text(ClubDates.label(today, format: "yyyy年M月d日 · EEEE"))
                    .bojiType(.caption)
                    .foregroundStyle(BojiColor.textTertiary)
                    .textCase(.uppercase)
                Text("概览")
                    .bojiType(.title)
                    .foregroundStyle(BojiColor.textPrimary)
            }
            Spacer()
            HStack(spacing: BojiLayout.tight) {
                // 红线：不许无限闪动——状态点只做一次性亮入
                Circle()
                    .fill(Color.green)
                    .frame(width: 7, height: 7)
                    .scaleEffect(isTelemetryPulsing ? 1.0 : 0.6)
                    .opacity(isTelemetryPulsing ? 1.0 : 0.4)
                    .animation(reduceMotion ? nil : BojiMotion2.entrance, value: isTelemetryPulsing)
                Text("本机记录概览")
                    .bojiType(.caption)
                    .foregroundStyle(BojiColor.textSecondary)
            }
            .padding(.horizontal, BojiLayout.inline)
            .padding(.vertical, BojiLayout.tight)
            .clubGlassEffect(in: Capsule())
        }
        .onAppear { isTelemetryPulsing = true }
    }

    private var workoutTelemetryCard: some View {
        Button {
            BojiHaptics.selection()
            withAnimation(reduceMotion ? nil : BojiMotion2.transition) {
                category = "训练"
            }
        } label: {
            ClubCard {
                HStack {
                    HStack(spacing: BojiLayout.inline) {
                        Image(systemName: "figure.strengthtraining.traditional")
                            .bojiType(.secondary)
                            .foregroundStyle(BojiColor.brandMist)
                            .frame(width: 28, height: 28)
                            .background(BojiColor.brandMist.opacity(0.15), in: Circle())
                        Text("训练动力")
                            .bojiType(.body)
                            .foregroundStyle(BojiColor.textPrimary)
                    }
                    Spacer()
                    HStack(spacing: BojiLayout.tight) {
                        Text(todayConfirmed.hasTraining ? "今天练完了" : (todayLog.workoutStartedAt != nil ? "训练进行中" : (!todayLog.exercises.isEmpty ? "待开始" : "暂无训练记录")))
                            .bojiType(.caption)
                            .foregroundStyle(todayConfirmed.hasTraining ? Color.green : BojiColor.brandAccent)
                        Image(systemName: "chevron.right")
                            .bojiType(.caption)
                            .foregroundStyle(BojiColor.textTertiary)
                    }
                }

                // 空值不摆 0：没练就没这排数字，改一句话说明（口径表 §八）
                if todayConfirmed.hasTraining {
                    HStack(spacing: BojiLayout.inline) {
                        telemetryMetric(
                            title: "完成组数",
                            value: "\(todayConfirmed.completedSets)",
                            unit: "组",
                            icon: "checkmark.circle.fill",
                            color: Color.green
                        )
                        if todayConfirmed.volume > 0 {
                            telemetryMetric(
                                title: "训练量",
                                value: "\(Int(todayConfirmed.volume))",
                                unit: "kg·次",
                                icon: "scalemass.fill",
                                color: BojiColor.brandMist
                            )
                        }
                        telemetryMetric(
                            title: "练完动作",
                            value: "\(todayConfirmed.exercises.count)",
                            unit: "项",
                            icon: "dumbbell.fill",
                            color: BojiColor.brandAccent
                        )
                    }
                } else {
                    Text(todayLog.exercises.isEmpty ? "今天还没记训练" : "今天还没练完，记完组就有数")
                        .bojiType(.caption)
                        .foregroundStyle(BojiColor.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, BojiLayout.tight)
                }

                if let firstEx = todayConfirmed.exercises.first ?? todayLog.exercises.first {
                    HStack(spacing: BojiLayout.tight) {
                        Text((todayConfirmed.exercises.isEmpty ? "计划动作 · " : "练完的 · ") + firstEx.displayName)
                            .bojiType(.caption)
                            .foregroundStyle(BojiColor.textSecondary)
                        Spacer()
                        Text("查看深度分析 →")
                            .bojiType(.caption)
                            .foregroundStyle(BojiColor.brandMist)
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var nutritionTelemetryCard: some View {
        Button {
            BojiHaptics.selection()
            withAnimation(reduceMotion ? nil : BojiMotion2.transition) {
                category = "饮食"
            }
        } label: {
            ClubCard {
                HStack {
                    HStack(spacing: BojiLayout.inline) {
                        Image(systemName: "fork.knife")
                            .bojiType(.secondary)
                            .foregroundStyle(Color.orange)
                            .frame(width: 28, height: 28)
                            .background(Color.orange.opacity(0.15), in: Circle())
                        Text("饮食与能量")
                            .bojiType(.body)
                            .foregroundStyle(BojiColor.textPrimary)
                    }
                    Spacer()
                    HStack(spacing: BojiLayout.tight) {
                        Text(mealCount > 0 ? "已记录 \(mealCount) 餐" : "今日待打卡")
                            .bojiType(.caption)
                            .foregroundStyle(mealCount > 0 ? BojiColor.textSecondary : Color.orange)
                        Image(systemName: "chevron.right")
                            .bojiType(.caption)
                            .foregroundStyle(BojiColor.textTertiary)
                    }
                }

                VStack(spacing: BojiLayout.inline) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(todayLog.knownMeals.isEmpty ? "—" : "\(Int(todayCalories))")
                            .bojiType(.title)
                            .foregroundStyle(BojiColor.textPrimary)
                        Text(targetCalories.map { "/ \(Int($0)) kcal" } ?? "kcal · 尚无个性化目标")
                            .bojiType(.secondary)
                            .foregroundStyle(BojiColor.textTertiary)
                        Spacer()
                        Text(calorieRatio.map { "\(Int($0 * 100))%" } ?? "记录未齐")
                            .bojiType(.caption)
                            .foregroundStyle(BojiColor.textSecondary)
                    }

                    ProgressView(value: min(1.0, max(0.0, calorieRatio ?? 0.0)), total: 1.0)
                        .tint(Color.orange)
                }

                if todayLog.unknownNutritionMeals > 0 {
                    Text("另有 \(todayLog.unknownNutritionMeals) 餐营养未知，未计入数值")
                        .bojiType(.caption).foregroundStyle(BojiColor.textSecondary)
                }
                HStack(spacing: BojiLayout.inline) {
                    macroPill(label: "蛋白质", value: todayProtein, unit: "g", color: BojiColor.macroProtein)
                    macroPill(label: "碳水", value: todayCarbs, unit: "g", color: BojiColor.macroCarbs)
                    macroPill(label: "脂肪", value: todayFat, unit: "g", color: BojiColor.macroFat)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var bodyTelemetryCard: some View {
        Button {
            BojiHaptics.selection()
            withAnimation(reduceMotion ? nil : BojiMotion2.transition) {
                category = "身体"
            }
        } label: {
            ClubCard {
                HStack {
                    HStack(spacing: BojiLayout.inline) {
                        Image(systemName: "scalemass.fill")
                            .bojiType(.secondary)
                            .foregroundStyle(BojiColor.brandMist)
                            .frame(width: 28, height: 28)
                            .background(BojiColor.brandMist.opacity(0.15), in: Circle())
                        Text("身体蜕变")
                            .bojiType(.body)
                            .foregroundStyle(BojiColor.textPrimary)
                    }
                    Spacer()
                    HStack(spacing: BojiLayout.tight) {
                        if let delta = weightDelta {
                            HStack(spacing: 0) {
                                Image(systemName: delta <= 0 ? "arrow.down.right" : "arrow.up.right")
                                Text(String(format: "%.1f kg", abs(delta)))
                            }
                            .bojiType(.caption)
                            .foregroundStyle(BojiColor.textSecondary)
                            .padding(.horizontal, BojiLayout.tight)
                            .padding(.vertical, 0)
                            .background(BojiColor.inputSurface, in: Capsule())
                        }
                        Image(systemName: "chevron.right")
                            .bojiType(.caption)
                            .foregroundStyle(BojiColor.textTertiary)
                    }
                }

                HStack(alignment: .center, spacing: BojiLayout.cardInset) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(weightHistory.last.map { String(format: "%.1f", $0.weight) } ?? "—")
                            .bojiType(.display)
                            .foregroundStyle(BojiColor.textPrimary)
                        Text("最近实测体重 (kg)")
                            .bojiType(.caption)
                            .foregroundStyle(BojiColor.textTertiary)
                    }
                    .frame(minWidth: 100, alignment: .leading)

                    if weightHistory.isEmpty {
                        Text("近14天暂无实际测量，记录后显示趋势")
                            .bojiType(.caption).foregroundStyle(BojiColor.textSecondary)
                    } else {
                    Chart(weightHistory) { point in
                        PointMark(x: .value("日期", point.date), y: .value("体重", point.weight))
                            .foregroundStyle(BojiColor.brandMist)
                        LineMark(
                            x: .value("日期", point.date),
                            y: .value("体重", point.weight)
                        )
                        .interpolationMethod(.linear)
                        .foregroundStyle(BojiColor.brandMist)
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))

                        AreaMark(
                            x: .value("日期", point.date),
                            y: .value("体重", point.weight)
                        )
                        .interpolationMethod(.linear)
                        .foregroundStyle(
                            LinearGradient(
                                colors: [BojiColor.brandMist.opacity(0.35), BojiColor.brandMist.opacity(0.0)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    }
                    .chartXAxis(.hidden)
                    .chartYAxis(.hidden)
                    .chartYScale(domain: (weightHistory.map(\.weight).min().map { $0 - 1 } ?? 60)...(weightHistory.map(\.weight).max().map { $0 + 1 } ?? 80))
                    .frame(height: 52)
                    }
                }
                if let last = weightHistory.last {
                    Text(ClubDates.label(last.date, format: "M月d日") + " · " + last.source + " · 近14天实际记录")
                        .bojiType(.caption).foregroundStyle(BojiColor.textSecondary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var clubMomentumCard: some View {
        HStack(spacing: BojiLayout.inline) {
            Image(systemName: "flame.fill")
                .bojiType(.section)
                .foregroundStyle(LinearGradient(colors: [Color.orange, Color.red], startPoint: .top, endPoint: .bottom))
            VStack(alignment: .leading, spacing: 0) {
                Text("连续训练记录")
                    .bojiType(.caption)
                    .foregroundStyle(BojiColor.textTertiary)
                Text(trainingStreakWeeks > 0 ? "\(trainingStreakWeeks) 周持续" : "从实际训练开始")
                    .bojiType(.secondary)
                    .foregroundStyle(BojiColor.textPrimary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(BojiLayout.rowGap)
        .background(BojiColor.cardSurface, in: RoundedRectangle(cornerRadius: BojiRadius.inner, style: .continuous))
    }

    private var quickActionsDock: some View {
        HStack(spacing: BojiLayout.rowGap) {
            Button {
                BojiHaptics.selection()
                withAnimation(reduceMotion ? nil : BojiMotion2.transition) {
                    category = "饮食"
                }
            } label: {
                HStack(spacing: BojiLayout.tight) {
                    Image(systemName: "plus.circle.fill")
                        .bojiType(.caption)
                    Text("记饮食")
                        .bojiType(.secondary)
                }
                .foregroundStyle(BojiColor.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, BojiLayout.rowGap)
                .clubGlassEffect(in: Capsule())
            }
            .buttonStyle(.plain)

            Button {
                BojiHaptics.selection()
                showWeightSheet = true
            } label: {
                HStack(spacing: BojiLayout.tight) {
                    Image(systemName: "scalemass")
                        .bojiType(.caption)
                    Text("录体征")
                        .bojiType(.secondary)
                }
                .foregroundStyle(BojiColor.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, BojiLayout.rowGap)
                .clubGlassEffect(in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private func telemetryMetric(title: String, value: String, unit: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: BojiLayout.tight) {
            HStack(spacing: BojiLayout.tight) {
                Image(systemName: icon)
                    .bojiType(.caption)
                    .foregroundStyle(color)
                Text(title)
                    .bojiType(.caption)
                    .foregroundStyle(BojiColor.textTertiary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(value)
                    .bojiType(.body)
                    .foregroundStyle(BojiColor.textPrimary)
                Text(unit)
                    .bojiType(.caption)
                    .foregroundStyle(BojiColor.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(BojiLayout.inline)
        .background(BojiColor.inputSurface.opacity(0.6), in: RoundedRectangle(cornerRadius: BojiRadius.control, style: .continuous))
    }

    private func macroPill(label: String, value: Double, unit: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .bojiType(.caption)
                .foregroundStyle(BojiColor.textTertiary)
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(todayLog.knownMeals.isEmpty ? "—" : "\(Int(value))")
                    .bojiType(.secondary)
                    .foregroundStyle(color)
                Text(unit)
                    .bojiType(.caption)
                    .foregroundStyle(BojiColor.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, BojiLayout.inline)
        .padding(.vertical, BojiLayout.inline)
        .background(BojiColor.inputSurface.opacity(0.6), in: RoundedRectangle(cornerRadius: BojiRadius.thumb, style: .continuous))
    }
}

struct ClubRecordsHub: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let externalCategory: Binding<String>?
    @State private var localCategory = "综合看板"
    var embeddedInShell = false
    private let pagedCategory: String?
    init(category: Binding<String>? = nil, embeddedInShell: Bool = false, pagedCategory: String? = nil) {
        externalCategory = category; self.embeddedInShell = embeddedInShell; self.pagedCategory = pagedCategory
    }
    @State private var mealDate = Date()
    @State private var showReports = false
    static let pageCategories = ["综合看板", "训练", "饮食", "身体"]
    /// 显示名与内部路由 key 分离：改显示名不断路由（定稿第二节 ⚠️ 项）。
    static func displayName(_ category: String) -> String { category == "综合看板" ? "概览" : category }
    private var categories: [String] { Self.pageCategories }
    private var category: Binding<String> { externalCategory ?? $localCategory }
    private var page: Binding<String> {
        Binding(get: { categories.contains(category.wrappedValue) ? category.wrappedValue : "综合看板" },
                set: { category.wrappedValue = $0 })
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("记录分类", selection: page) {
                ForEach(categories, id: \.self) { title in
                    Text(Self.displayName(title)).tag(title).accessibilityIdentifier("records-tab-" + title)
                }
            }
            .clubAdaptivePicker()
            .accessibilityIdentifier("records-category-picker")
            .padding(.horizontal, ClubUI.pageInset)
            .padding(.vertical, BojiLayout.inline)

            if let pagedCategory {
                // The shell provides paging; do not nest a competing horizontal pager.
                categoryContent(pagedCategory)
            } else {
                TabView(selection: page) {
                    ForEach(categories, id: \.self) { title in
                        categoryContent(title).tag(title)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: page.wrappedValue)
            }
        }
        .background { ClubBackground() }
        .navigationTitle("记录").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !embeddedInShell {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("AI 报告", systemImage: "ellipsis") { showReports = true }
                }
            }
        }
        .onChange(of: category.wrappedValue) { _, value in
            if pagedCategory == nil || pagedCategory == value { BojiHaptics.selection() }
            if value == "报告", pagedCategory == nil || pagedCategory == "综合看板" {
                showReports = true; category.wrappedValue = "综合看板"
            }
        }
        .onAppear {
            if category.wrappedValue == "报告", pagedCategory == nil || pagedCategory == "综合看板" {
                showReports = true; category.wrappedValue = "综合看板"
            }
        }
        .sheet(isPresented: $showReports) {
            NavigationStack {
                ReportLibraryView().toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("关闭") { showReports = false } }
                }
            }
        }
    }
    @ViewBuilder private func categoryContent(_ title: String) -> some View {
        switch title {
        case "训练": ScrollView { ReviewDashboardView().padding(ClubUI.pageInset) }
        case "饮食": NutritionView(selectedDate: $mealDate)
        case "身体": BodyOverviewView(embedded: true)
        default: ClubRecordsExecutiveDashboard(category: category)
        }
    }
}

#if DEBUG
enum ProductAuditFactory {
 static func version(_ version: ClubPlanVersion) -> some View { ClubPlanVersionDetail(version: version) }
}
#endif
