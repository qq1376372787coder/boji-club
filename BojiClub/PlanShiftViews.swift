import SwiftUI

// B1–B3：计划「调整日期／顺延」闭环。
// 选范围 → 预览前后 → 冲突检查（不静默覆盖）→ 用户确认 → 记录版本 → 只改未来安排。
// 已开始／已完成日程永远不进范围；替换仅限明确勾选的、尚未开始的可编辑安排，并留快照可追溯。

// MARK: - 顺延记录（随 DayLog 同步；旧数据无此字段可正常解码）

struct PlanShiftRecord: Codable, Equatable, Identifiable {
    let id: String
    let createdAt: Date
    let shiftDays: Int
    /// 原日期 → 新日期（key 为 yyyy-MM-dd）。
    let moves: [String: String]
    /// 被明确替换的原目标日完整动作快照（date → 动作含逐组参数），可据此恢复。
    var replaced: [String: [AIPlanExercise]] = [:]
    /// 目标日期 → 来源计划周期的 start（保留来源版本依据，跨周时不丢上下文）。
    var sourceCycles: [String: String]? = nil
    /// 本次调整实际涉及的日期范围（生效范围）。
    var effectScope: [String]? = nil
    /// 调整原因：user_shift / coach_schedule_shift 等。
    var reason: String? = nil
    var note: String { "顺延 \(shiftDays) 天 · \(moves.count) 个安排" }
}

// MARK: - 校验与执行规则

enum ClubShiftRules {
    /// 可参与顺延的未来安排日：有动作、未开始、无未确认训练。
    static func movableDates(state: SavedState, now: Date = Date()) -> [Date] {
        state.days.keys.compactMap(ClubDates.date).filter { date in
            guard ClubDates.isFuture(date, now: now) else { return false }
            let day = state.days[ClubDates.key(date)] ?? DayLog()
            return !day.exercises.isEmpty && !WorkoutEditing.isProtected(day) && !day.hasUnconfirmedTraining
        }.sorted()
    }

    /// 冲突分类：hard=目标日已开始/已完成/有未确认训练（整批拒绝）；soft=目标日有未开始安排（需显式勾选替换）。
    struct Conflicts {
        var hard: [String] = []
        var soft: [String] = []
    }
    static func conflicts(moves: [(String, String)], state: SavedState) -> Conflicts {
        var result = Conflicts()
        let sources = Set(moves.map(\.0))
        for (_, target) in moves {
            let day = state.days[target] ?? DayLog()
            if WorkoutEditing.isProtected(day) || day.hasUnconfirmedTraining {
                result.hard.append("\(target)（已开始或已有未确认训练）")
            } else if !day.exercises.isEmpty && !sources.contains(target) {
                result.soft.append(target)
            }
        }
        return result
    }

    /// 目标日不属于任何现成周期时，以源周期的周界为基准找目标所在的那一周，
    /// 保证新周期仍是合法的七天区间（start..start+6）。
    static func shiftWeekAnchor(sourceCycle: TrainingCycle?, target: String) -> String {
        guard let sourceCycle, let origin = ClubDates.date(fromKey: sourceCycle.start),
              let targetDate = ClubDates.date(fromKey: target) else { return target }
        let delta = ClubDates.calendar.dateComponents([.day], from: origin, to: targetDate).day ?? 0
        let weeks = Int(floor(Double(delta) / 7.0))
        guard let anchor = ClubDates.calendar.date(byAdding: .day, value: weeks * 7, to: origin) else { return target }
        return ClubDates.key(anchor)
    }

    struct DestinationPlan {
        /// 目标日期 → 应归属的周期。
        var cycles: [String: TrainingCycle] = [:]
        /// 目标日期 → 来源周期 start（用于版本追溯）。
        var sourceStarts: [String: String] = [:]
    }
    /// 顺延前为每个目标日确定合法周期：
    /// 1) 目标日已有覆盖它的周期（跨计划顺延）→ 目标所在周期；
    /// 2) 目标仍在源周期七天窗口内 → 源周期；
    /// 3) 否则按源周期周界创建目标所在周的合法七天周期。
    static func destinations(moves: [(String, String)], days: [String: DayLog],
                             cycles: [TrainingCycle]) -> DestinationPlan {
        var plan = DestinationPlan()
        for (source, target) in moves {
            let sourceDay = days[source] ?? DayLog()
            let sourceCycle = sourceDay.planCycle.flatMap { $0.dates.contains(source) ? $0 : nil }
                ?? cycles.first(where: { $0.dates.contains(source) && $0.plannedDates.contains(source) })
                ?? cycles.first(where: { $0.dates.contains(source) })
            if let sourceCycle { plan.sourceStarts[target] = sourceCycle.start }
            if let existing = days[target]?.planCycle, existing.dates.contains(target) {
                plan.cycles[target] = existing
            } else if let existing = cycles.first(where: { $0.dates.contains(target) }) {
                plan.cycles[target] = existing
            } else if let sourceCycle, sourceCycle.dates.contains(target) {
                plan.cycles[target] = sourceCycle
            } else {
                let anchor = shiftWeekAnchor(sourceCycle: sourceCycle, target: target)
                if let cycle = TrainingCycle.week(anchoredAt: anchor,
                                                  sourceJobID: sourceCycle?.sourceJobID,
                                                  explanationVersion: sourceCycle?.explanationVersion) {
                    plan.cycles[target] = cycle
                }
            }
        }
        return plan
    }

    /// 快照指纹：预览后任何相关日期的安排或参数变化（组数/重量/次数/休息）都会使确认失效。
    static func fingerprint(_ days: [String: DayLog]) -> String {
        days.keys.sorted().map { key in
            let exercises = ClubPlanChangeRules.snapshot(days[key]?.exercises ?? [])
            let detail = exercises.map { exercise in
                let sets = exercise.sets.map {
                    "\($0.weight ?? -1)/\($0.reps)/\($0.durationSeconds ?? -1)"
                }.joined(separator: ",")
                return "\(exercise.displayName)#\(exercise.rest_seconds ?? -1)[\(sets)]"
            }.joined(separator: ";")
            return key + "/" + detail
        }.joined(separator: "|")
    }
}

// MARK: - AppStore 执行

// 顺延执行在 AppStore.swift（需要访问持久化事务与私有状态）。

// MARK: - 日历内单日调整

struct PlanMovePreview: Equatable {
    let sourceKey: String
    let targetKey: String
    let sourceExercises: [AIPlanExercise]
    let replacedExercises: [AIPlanExercise]
    let hardConflicts: [String]
    let softConflicts: [String]
    let sourceCycleStart: String?
    let targetCycleStart: String?
    let fingerprint: String
    let dayDelta: Int
    var hasHardConflict: Bool { !hardConflicts.isEmpty }
}

enum PlanMoveRules {
    static func preview(source: String, target: String, state: SavedState, now: Date = Date()) -> PlanMovePreview? {
        guard source != target,
              let sourceDate = ClubDates.date(fromKey: source),
              let targetDate = ClubDates.date(fromKey: target),
              ClubDates.key(sourceDate) >= ClubDates.key(now),
              ClubDates.isFuture(targetDate, now: now) else { return nil }
        let sourceDay = state.days[source] ?? DayLog()
        guard !sourceDay.exercises.isEmpty,
              !WorkoutEditing.isProtected(sourceDay),
              !sourceDay.hasUnconfirmedTraining else { return nil }
        let targetDay = state.days[target] ?? DayLog()
        let conflicts = ClubShiftRules.conflicts(moves: [(source, target)], state: state)
        let cycles = TrainingCycle.available(days: state.days, now: now)
        let destinations = ClubShiftRules.destinations(moves: [(source, target)], days: state.days, cycles: cycles)
        var involved = [String: DayLog]()
        involved[source] = sourceDay
        involved[target] = targetDay
        let delta = ClubDates.calendar.dateComponents([.day], from: sourceDate, to: targetDate).day ?? 0
        return PlanMovePreview(
            sourceKey: source, targetKey: target,
            sourceExercises: ClubPlanChangeRules.snapshot(sourceDay.exercises),
            replacedExercises: ClubPlanChangeRules.snapshot(targetDay.exercises),
            hardConflicts: conflicts.hard, softConflicts: conflicts.soft,
            sourceCycleStart: sourceDay.planCycle?.start ?? destinations.sourceStarts[target],
            targetCycleStart: destinations.cycles[target]?.start,
            fingerprint: ClubShiftRules.fingerprint(involved),
            dayDelta: delta)
    }
}

struct PlanMoveSheet: View {
    let sourceDate: Date
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var displayedMonth = Date()
    @State private var targetDate: Date?
    @State private var replaceTarget = false
    @State private var busy = false
    @State private var error: String?
    @State private var loaded = false

    private var sourceKey: String { ClubDates.key(sourceDate) }
    private var targetKey: String? { targetDate.map(ClubDates.key) }
    private var preview: PlanMovePreview? {
        guard let targetKey else { return nil }
        return PlanMoveRules.preview(source: sourceKey, target: targetKey, state: store.state)
    }
    private var canConfirm: Bool {
        guard let preview else { return false }
        if preview.hasHardConflict { return false }
        if !preview.softConflicts.isEmpty && !replaceTarget { return false }
        return true
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: BojiSpace.sectionSpacing) {
                    VStack(alignment: .leading, spacing: BojiLayout.tight) {
                        Text("移动这一天的安排").bojiFont(.pageTitle).foregroundStyle(BojiColor.textPrimary)
                        Text("\(ClubDates.label(sourceDate, format: "M月d日 EEEE")) · \((store.state.days[sourceKey]?.exercises ?? []).count) 个动作")
                            .bojiFont(.secondary).foregroundStyle(BojiColor.textSecondary)
                        Text("只能移动到今天之后的日期。提前到今天请使用“提前训练”；已完成训练不会被移动。")
                            .bojiType(.label).foregroundStyle(BojiColor.textTertiary)
                    }
                    calendarCard
                    if let preview {
                        previewCard(preview)
                    } else {
                        Text("选择一个目标日期查看影响。").bojiFont(.secondary).foregroundStyle(BojiColor.textSecondary)
                    }
                    if let error { FlowError(message: error) }
                    Button(busy ? "正在核对最新记录…" : "确认移动") { execute() }
                        .buttonStyle(BojiButtonStyle(kind: .primary))
                        .disabled(busy || !canConfirm)
                    if busy { ClubLoadingCard(title: "正在同步其他设备的改动…", detail: "确认后才会更新未来安排；原计划保持可追溯。") }
                }
                .padding(ClubUI.pageInset)
                .frame(maxWidth: BojiSize.contentWidth)
                .frame(maxWidth: .infinity)
            }
            .background { ClubBackground() }
            .navigationTitle("调整安排").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() }.disabled(busy) } }
            .interactiveDismissDisabled(busy)
            .onAppear {
                guard !loaded else { return }
                loaded = true
                displayedMonth = sourceDate
            }
        }
    }

    private var calendarCard: some View {
        let cells = PlanCalendarRules.monthCells(anchor: displayedMonth)
        return VStack(spacing: BojiLayout.inline) {
            HStack {
                Button { displayedMonth = PlanCalendarRules.shiftMonth(displayedMonth, by: -1) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(BojiCircleButtonStyle(visualDiameter: 34))
                Spacer()
                Text(PlanCalendarRules.monthLabel(displayedMonth)).bojiFont(.cardTitle)
                Spacer()
                Button { displayedMonth = PlanCalendarRules.shiftMonth(displayedMonth, by: 1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(BojiCircleButtonStyle(visualDiameter: 34))
            }
            HStack(spacing: BojiLayout.tight) {
                ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) { label in
                    Text(label).bojiType(.caption).foregroundStyle(BojiColor.textTertiary).frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: BojiLayout.tight), count: 7), spacing: BojiLayout.tight) {
                ForEach(Array(cells.enumerated()), id: \.offset) { _, date in
                    if let date {
                        let enabled = ClubDates.isFuture(date) && ClubDates.key(date) != sourceKey
                        Button {
                            targetDate = date
                            replaceTarget = false
                        } label: {
                            VStack(spacing: 0) {
                                Text("\(ClubDates.calendar.component(.day, from: date))")
                                    .bojiFont(.label, monospacedDigits: true)
                                    .foregroundStyle(targetDate.map { ClubDates.calendar.isDate($0, inSameDayAs: date) } == true ? BojiColor.pageBackground : (enabled ? BojiColor.textPrimary : BojiColor.textTertiary))
                                if ClubDates.key(date) == sourceKey { Text("原日期").bojiType(.caption) }
                                else if !(store.state.days[ClubDates.key(date)]?.exercises.isEmpty ?? true) { Text("有安排").bojiType(.caption) }
                            }
                            .frame(maxWidth: .infinity, minHeight: BojiLayout.controlHeight)
                            .background(targetDate.map { ClubDates.calendar.isDate($0, inSameDayAs: date) } == true ? BojiColor.textPrimary : BojiColor.cardSurface.opacity(0.7), in: RoundedRectangle(cornerRadius: BojiRadius.inner))
                        }
                        .buttonStyle(.plain)
                        .disabled(!enabled)
                        .opacity(ClubDates.key(date) == sourceKey ? 0.65 : 1)
                    } else {
                        Color.clear.frame(height: BojiLayout.controlHeight)
                    }
                }
            }
        }
        .padding(BojiSpace.cardInset)
        .background(BojiColor.calendarSurface, in: RoundedRectangle(cornerRadius: BojiRadius.card, style: .continuous))
    }

    private func previewCard(_ preview: PlanMovePreview) -> some View {
        VStack(alignment: .leading, spacing: BojiLayout.inline) {
            Text("移动预览").bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
            HStack(spacing: BojiLayout.inline) {
                Text(ClubDates.label(sourceDate, format: "M月d日"))
                Image(systemName: "arrow.right")
                Text(ClubDates.date(fromKey: preview.targetKey).map { ClubDates.label($0, format: "M月d日") } ?? preview.targetKey)
            }.bojiFont(.body)
            Text("日期变化：\(preview.dayDelta > 0 ? "+" : "")\(preview.dayDelta) 天")
                .bojiFont(.secondary).foregroundStyle(BojiColor.textSecondary)
            if preview.sourceCycleStart != preview.targetCycleStart {
                Text("计划周期：\(preview.sourceCycleStart ?? "未归属") → \(preview.targetCycleStart ?? "未归属")")
                    .bojiFont(.secondary).foregroundStyle(BojiColor.textSecondary)
            }
            if !preview.replacedExercises.isEmpty {
                Text("目标日现有 \(preview.replacedExercises.count) 个动作；确认替换后会留档在顺延记录里。")
                    .bojiFont(.secondary).foregroundStyle(BojiColor.textSecondary)
            }
            if !preview.softConflicts.isEmpty {
                Toggle("替换目标日现有安排", isOn: $replaceTarget)
                    .bojiType(.secondary)
            }
            if preview.hasHardConflict {
                Label("目标日已有开始/完成或未确认训练，不能移动。", systemImage: "exclamationmark.triangle")
                    .bojiType(.label).foregroundStyle(.orange)
            }
            Text("移动后原日期不再显示同一份待练；历史训练、计划版本和顺延记录保留。")
                .bojiType(.label).foregroundStyle(BojiColor.textTertiary)
        }
        .bojiCard()
    }

    private func execute() {
        guard !busy, let preview, let targetKey = targetKey else { return }
        busy = true; error = nil
        Task {
            defer { busy = false }
            guard let owner = store.editingAccountID else { error = "登录状态已变化，请重新打开。"; return }
            let synchronized = await store.syncForPlanAdoption(ownerID: owner)
            guard owner == store.editingAccountID, !Task.isCancelled else { return }
            guard synchronized else { error = store.takeMessage(fallback: "记录尚未同步完成，请稍后重试；原安排已保留。"); return }
            let replace: Set<String> = replaceTarget ? [targetKey] : []
            if store.shiftPlannedSchedule(moves: [(preview.sourceKey, targetKey)],
                                          shiftDays: max(1, abs(preview.dayDelta)),
                                          replaceTargets: replace,
                                          expectedFingerprint: preview.fingerprint,
                                          reason: "calendar_move",
                                          allowTodaySource: true) {
                dismiss()
            } else {
                error = store.takeMessage(fallback: "移动未执行，原安排已保留。")
            }
        }
    }
}

// MARK: - 顺延预览与确认页

struct ShiftScheduleView: View, Identifiable {
    let id = UUID()
    /// 对话提案预填：固定 (from,to) 对；手动模式为 nil。
    var presetMoves: [(String, String)]? = nil
    /// 调整来源：user_shift / coach_schedule_shift。
    var reason: String = "user_shift"
    @EnvironmentObject private var account: AccountService
    @State private var preparedProposal: ClubProposalSync.PreparedSchedule?
    @State private var preparedFingerprint: String?
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var owner: Int?
    @State private var startDate = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
    @State private var spanDays = 3
    @State private var shiftDays = 1
    @State private var replaceTargets = Set<String>()
    @State private var confirming = false
    @State private var busy = false
    @State private var error: String?

    private var needsServerProposal: Bool { reason == "coach_schedule_shift" && !account.isPreviewAccount }
    private var movable: [Date] { ClubShiftRules.movableDates(state: store.state) }

    private var moves: [(String, String)] {
        if let presetMoves { return presetMoves }
        let calendar = ClubDates.calendar
        let keys = movable
            .filter { date in
                guard let end = calendar.date(byAdding: .day, value: spanDays - 1, to: calendar.startOfDay(for: startDate)) else { return false }
                return date >= calendar.startOfDay(for: startDate) && date <= end
            }
        return keys.compactMap { source in
            guard let target = calendar.date(byAdding: .day, value: shiftDays, to: source) else { return nil }
            return (ClubDates.key(source), ClubDates.key(target))
        }
    }

    private var fingerprint: String {
        var involved: [String: DayLog] = [:]
        for (source, target) in moves {
            involved[source] = store.state.days[source] ?? DayLog()
            involved[target] = store.state.days[target] ?? DayLog()
        }
        return ClubShiftRules.fingerprint(involved)
    }

    /// 有效顺延天数：手动模式用步进值；对话提案按实际日期差（提案可为任意 from→to）。
    private var effectiveShiftDays: Int {
        if let presetMoves {
            let diffs = presetMoves.compactMap { pair -> Int? in
                guard let from = ClubDates.date(fromKey: pair.0), let to = ClubDates.date(fromKey: pair.1) else { return nil }
                return abs(ClubDates.calendar.dateComponents([.day], from: from, to: to).day ?? 0)
            }
            return max(1, diffs.max() ?? 1)
        }
        return shiftDays
    }

    private var conflicts: ClubShiftRules.Conflicts { ClubShiftRules.conflicts(moves: moves, state: store.state) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: BojiSpace.sectionSpacing) {
                    Text("调整日期 · 顺延").bojiFont(.pageTitle).foregroundStyle(BojiColor.textPrimary)
                    Text("只移动尚未开始的安排。已开始、已完成和未确认的训练永远保留原位。")
                        .bojiFont(.secondary).foregroundStyle(BojiColor.textSecondary)

                    if presetMoves == nil {
                        VStack(alignment: .leading, spacing: BojiLayout.rowGap) {
                            DatePicker("起始日期", selection: $startDate, in: Date()..., displayedComponents: .date)
                            Stepper("范围：\(spanDays) 天", value: $spanDays, in: 1...14)
                            Stepper("顺延：\(shiftDays) 天", value: $shiftDays, in: 1...28)
                        }
                        .bojiCard()
                    }

                    previewCard

                    if !conflicts.hard.isEmpty {
                        VStack(alignment: .leading, spacing: BojiLayout.inline) {
                            Text("目标日期冲突，无法顺延").bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
                            ForEach(conflicts.hard, id: \.self) { Text($0).bojiFont(.secondary).foregroundStyle(BojiColor.textSecondary) }
                            Text("请更换顺延天数。已开始或未确认的训练不会被移动。")
                                .bojiFont(.label).foregroundStyle(BojiColor.textTertiary)
                        }
                        .bojiCard()
                    }

                    if !conflicts.soft.isEmpty {
                        VStack(alignment: .leading, spacing: BojiLayout.inline) {
                            Text("目标日期已有可编辑安排").bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
                            Text("不会静默覆盖。更换顺延天数，或明确勾选要替换的日期；替换前的安排会留档在顺延记录里。")
                                .bojiFont(.secondary).foregroundStyle(BojiColor.textSecondary)
                            ForEach(conflicts.soft, id: \.self) { key in
                                Toggle(isOn: Binding(get: { replaceTargets.contains(key) },
                                                     set: { if $0 { replaceTargets.insert(key) } else { replaceTargets.remove(key) } })) {
                                    Text("替换 \(friendly(key)) 的安排").bojiFont(.body)
                                }
                            }
                        }
                        .bojiCard()
                    }

                    Button("确认顺延这些安排") {
                        confirming = true
                    }
                    .buttonStyle(BojiButtonStyle(kind: .primary))
                    .disabled(moves.isEmpty || !conflicts.hard.isEmpty || busy || (needsServerProposal && preparedProposal == nil))
                    if needsServerProposal, error != nil {
                        Button("重新核对提案") { Task { await prepareServerProposal() } }.disabled(busy)
                    }

                    if busy { ClubLoadingCard(title: "正在核对最新记录…", detail: "先同步其他设备的改动，再执行顺延。") }
                    if let error { Text(error).bojiFont(.secondary).foregroundStyle(.red) }
                }
                .padding(ClubUI.pageInset)
                .frame(maxWidth: BojiSize.contentWidth)
                .frame(maxWidth: .infinity)
            }
            .background { ClubBackground() }
            .navigationTitle("调整日期").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() }.disabled(busy) } }
            .interactiveDismissDisabled(busy)
            .onAppear { owner = store.editingAccountID }
            .task { if needsServerProposal { await prepareServerProposal() } }
            .onChange(of: store.editingAccountID) { _, current in if current != owner { dismiss() } }
            .alert("确认顺延？", isPresented: $confirming) {
                Button("确认移动") { execute() }
                Button("再看看", role: .cancel) { }
            } message: {
                Text(replaceTargets.isEmpty
                     ? "将把 \(moves.count) 个未开始的安排各顺延约 \(effectiveShiftDays) 天；原日期转为恢复，不留下重复待练。"
                     : "将顺延 \(moves.count) 个安排，并替换 \(replaceTargets.count) 个目标日的可编辑安排（原安排留档可查）。")
            }
        }
    }

    private func friendly(_ key: String) -> String {
        ClubDates.date(fromKey: key).map { ClubDates.label($0, format: "M月d日") } ?? key
    }

    private var previewCard: some View {
        VStack(alignment: .leading, spacing: BojiLayout.inline) {
            Text("前后对照").bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
            if moves.isEmpty {
                Text("所选范围没有可顺延的安排。").bojiFont(.secondary).foregroundStyle(BojiColor.textSecondary)
            } else {
                ForEach(moves, id: \.0) { move in
                    HStack(spacing: BojiLayout.inline) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(friendly(move.0)).bojiFont(.label).foregroundStyle(BojiColor.textSecondary)
                            Text((store.state.days[move.0]?.exercises ?? []).map(\.displayName).joined(separator: "、"))
                                .bojiFont(.secondary).lineLimit(2)
                        }
                        Image(systemName: "arrow.right").bojiType(.label).foregroundStyle(BojiColor.textTertiary)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(friendly(move.1)).bojiFont(.label).foregroundStyle(BojiColor.textPrimary)
                            Text(conflicts.soft.contains(move.1) && !replaceTargets.contains(move.1) ? "与现有安排冲突" : "将放置这份安排")
                                .bojiFont(.secondary).foregroundStyle(conflicts.soft.contains(move.1) ? BojiColor.timerAccent : BojiColor.textSecondary)
                        }
                        Spacer(minLength: 0)
                    }
                    if move.0 != moves.last?.0 { Divider().overlay(BojiColor.divider) }
                }
            }
        }
        .bojiCard()
    }

    private func prepareServerProposal() async {
        guard !busy, let owner = store.editingAccountID else { return }
        busy = true; error = nil; preparedProposal = nil
        defer { busy = false }
        let fp = fingerprint
        guard await store.syncForPlanAdoption(ownerID: owner), owner == store.editingAccountID, !Task.isCancelled else {
            error = "记录尚未同步，请联网后重新核对提案。"; return
        }
        guard fingerprint == fp else { error = "安排已有变化，请重新核对。"; return }
        var baseline: [String: DayLog] = [:]
        for (from, to) in moves {
            baseline[from] = store.state.days[from] ?? DayLog()
            baseline[to] = store.state.days[to] ?? DayLog()
        }
        do {
            let proposal = try await ClubProposalSync.prepareScheduleMoves(
                moves.map { ClubScheduleMove(from: $0.0, to: $0.1) }, baseline: baseline,
                operationID: UUID().uuidString.lowercased(), account: account)
            guard owner == store.editingAccountID, !Task.isCancelled else { return }
            preparedProposal = proposal; preparedFingerprint = fp
        } catch { self.error = AppErrorText.message(error) }
    }

    private func execute() {
        guard !busy, let owner, owner == store.editingAccountID else { return }
        busy = true; error = nil
        let snapshot = moves
        let span = effectiveShiftDays
        let replace = replaceTargets
        let fp = fingerprint
        Task {
            defer { busy = false }
            if needsServerProposal {
                guard let preparedProposal, preparedFingerprint == fp else {
                    error = "提案尚未核对或安排已有变化，请重新核对。"; return
                }
                let outcome = await ClubProposalSync.confirmScheduleMoves(preparedProposal, account: account)
                guard owner == store.editingAccountID else { return }
                switch outcome {
                case .confirmed:
                    await store.syncNow()
                    guard owner == store.editingAccountID else { return }
                    dismiss()
                case .conflict(let message): error = message
                case .fallback: error = "云端尚未确认，原安排保留。"
                }
                return
            }
            let synchronized = await store.syncForPlanAdoption(ownerID: owner)
            guard owner == store.editingAccountID, !Task.isCancelled else { return }
            guard synchronized else { error = store.takeMessage(fallback: "记录尚未同步完成，请稍后确认顺延；原安排已保留。"); return }
            guard fingerprint == fp else { error = "安排在预览后已变化，请重新核对。"; return }
            if store.shiftPlannedSchedule(moves: snapshot, shiftDays: span, replaceTargets: replace, expectedFingerprint: fp, reason: reason) {
                dismiss()
            } else {
                error = store.takeMessage(fallback: "顺延未执行，安排已保留。")
            }
        }
    }
}
