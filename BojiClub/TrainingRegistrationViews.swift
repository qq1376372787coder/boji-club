import SwiftUI

// 训练登记页组件（任务书 4.1）。业务写入口仍走 AppStore；此处只做展示与交互组织。

// MARK: - 训练用时

/// 顶栏中间的训练用时。按实际开始时间累计；未开始或补记历史不编造用时。
struct TrainingElapsedLabel: View {
    let date: Date
    @EnvironmentObject private var store: AppStore
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(label(at: context.date))
                .bojiType(.section)
                .foregroundStyle(BojiColor.timerAccent)
                .lineLimit(1)
                .minimumScaleFactor(0.62)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minWidth: 82)
        }
        .accessibilityLabel("训练用时")
    }

    private func label(at now: Date) -> String {
        let raw = store.log(for: date)
        let log = raw.trainingLog
        guard !ClubDates.isFuture(date) else { return "未开始" }
        if let duration = WorkoutTiming.completedDuration(raw, on: date, now: now) {
            return clock(duration)
        }
        if WorkoutTiming.isOngoing(log, on: date, now: now), let start = log.workoutStartedAt {
            let session = raw.activeWorkoutSessionID ?? raw.workoutSessions?.first?.id
            let pause = ClubWorkoutPauseStorage.load(owner: store.editingAccountID ?? 0, date: date,
                                                     sessionID: session, now: now)
            let sessionRecord = raw.workoutSessions?.first(where: { $0.id == session })
            let duration = sessionRecord?.pauseIntervals != nil
                ? max(0, now.timeIntervalSince(start) - (sessionRecord?.pausedSeconds(through: now) ?? 0))
                : (pause?.elapsed(startedAt: start, now: now) ?? max(0, now.timeIntervalSince(start)))
            return clock(duration)
        }
        return "—:—"
    }

    private func clock(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded(.down)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

// MARK: - 提示带：训练建议（仅展示已有可靠依据，不制造建议）

/// 由调用方传入已有依据的建议文案；无依据时传 nil，不显示。
struct TrainingSuggestionBand: View {
    let headline: String
    let detail: String?
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: BojiLayout.inline) {
            Image(systemName: "arrow.up").bojiType(.label)
                .foregroundStyle(BojiColor.textPrimary)
            Text(headline).bojiFont(.label, monospacedDigits: true)
                .foregroundStyle(BojiColor.textPrimary)
            if let detail {
                Text(detail).bojiFont(.secondary)
                    .foregroundStyle(BojiColor.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, BojiSpace.general)
        .padding(.vertical, BojiLayout.inline)
        .bojiInset(cornerRadius: BojiRadius.input, background: BojiColor.subtleSurface)
    }
}

// MARK: - 展开动作卡头部

struct TrainingExerciseHeader: View {
    let exercise: Exercise
    let completed: Int
    let expanded: Bool
    let moreMenu: AnyView
    let toggle: () -> Void
    var body: some View {
        HStack(spacing: BojiSpace.general) {
            BojiExerciseThumb(exercise: exercise, side: 88)
            VStack(alignment: .leading, spacing: BojiLayout.tight) {
                Text(exercise.displayName).bojiFont(.exerciseName)
                    .foregroundStyle(BojiColor.textPrimary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                if let seconds = exercise.restSeconds {
                    HStack(spacing: BojiLayout.tight) {
                        Image(systemName: "timer").bojiType(.caption)
                        Text(seconds == 0 ? "本动作不自动休息" : "组间休息 \(seconds / 60):\(String(format: "%02d", seconds % 60))")
                            .bojiFont(.label)
                    }.foregroundStyle(BojiColor.textSecondary)
                }
                Text("\(exercise.sets.count) 组 · 已完成 \(completed)")
                    .bojiFont(.label).foregroundStyle(BojiColor.textSecondary)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: BojiLayout.tight) {
                moreMenu
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .bojiType(.caption).foregroundStyle(BojiColor.textTertiary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(exercise.displayName)，已完成 \(completed) 组，共 \(exercise.sets.count) 组")
        .accessibilityHint(expanded ? "点击收起" : "点击展开")
    }
}

// MARK: - 收起动作卡

struct TrainingCollapsedExerciseCard: View {
    let exercise: Exercise
    let completed: Int
    let moreMenu: AnyView
    let toggle: () -> Void
    var body: some View {
        HStack(spacing: BojiSpace.general) {
            BojiExerciseThumb(exercise: exercise, side: 52)
            VStack(alignment: .leading, spacing: BojiLayout.inline) {
                Text(exercise.displayName).bojiFont(.exerciseName)
                    .foregroundStyle(BojiColor.textPrimary).lineLimit(1)
                HStack(spacing: BojiLayout.inline) {
                    Text("\(completed)/\(exercise.sets.count) 组")
                        .bojiFont(.label, monospacedDigits: true)
                        .foregroundStyle(BojiColor.textSecondary)
                    BojiSegmentedProgress(total: exercise.sets.count, completed: completed)
                }
            }
            Spacer(minLength: 0)
            moreMenu
        }
        .padding(BojiSpace.workoutCardInset)
        .frame(minHeight: 70)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BojiColor.cardSurface, in: RoundedRectangle(cornerRadius: BojiRadius.card, style: .continuous))
        .shadow(color: .black.opacity(0.035), radius: 18, x: 0, y: 5)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 组次表

/// 一行一列布局：组号 | 重量 kg | 次数/秒 | 完成。
struct TrainingSetRowView: View {
    let number: Int
    let trainingSet: TrainingSet
    let isActive: Bool
    let allowCompletion: Bool
    var isQuickAdjusting: Bool = false
    var weightStep: Double = 2.5
    var previousSet: TrainingSet? = nil
    var isLastUncompletedSet: Bool = false
    var onQuickUpdate: ((TrainingSet) -> Void)? = nil
    var onOpenFullEditor: (() -> Void)? = nil
    var editWeight: (() -> Void)? = nil
    var editAmount: (() -> Void)? = nil
    let editNumbers: () -> Void
    let toggleComplete: () -> Void
    let undoComplete: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var amount: Int { trainingSet.durationSeconds ?? trainingSet.reps }
    private var unit: String { trainingSet.durationSeconds == nil ? "次" : "秒" }
    private var amountText: String { trainingSet.hasActualEntry || !allowCompletion ? "\(amount) \(unit)" : "— \(unit)" }

    var body: some View {
        VStack(spacing: BojiLayout.tight) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    // 大字号回流：组号行＋数值行两段竖排，保证触控与可读（§7.1）。
                    VStack(alignment: .leading, spacing: BojiSpace.tightRow) {
                        HStack {
                            Text("第 \(number) 组").bojiFont(.label).foregroundStyle(BojiColor.textSecondary)
                            Spacer(minLength: 8)
                            completeControl
                        }
                        HStack(spacing: BojiSpace.tightRow) {
                            if trainingSet.durationSeconds == nil {
                                HStack(spacing: BojiLayout.tight) {
                                    BojiSetNumberCell(text: weightText, isEditing: isQuickAdjusting) { (editWeight ?? editNumbers)() }
                                    Text("kg").bojiFont(.label).foregroundStyle(BojiColor.textSecondary)
                                }
                            }
                            HStack(spacing: BojiLayout.tight) {
                                BojiSetNumberCell(text: amountText, isEditing: isQuickAdjusting) { (editAmount ?? editNumbers)() }
                                Text(unit).bojiFont(.label).foregroundStyle(BojiColor.textSecondary)
                            }
                        }
                    }
                    .frame(minHeight: BojiSetTable.rowMinHeight)
                } else {
                    HStack(spacing: BojiSpace.tightRow) {
                        Text("\(number)")
                            .bojiFont(.setNumber)
                            .foregroundStyle(trainingSet.validCompletion ? BojiColor.emeraldAccent : (isActive ? BojiColor.textPrimary : BojiColor.textSecondary))
                            .frame(width: BojiSetTable.numberColumn)
                            .accessibilityLabel("第 \(number) 组")
                        if trainingSet.durationSeconds == nil {
                            BojiSetNumberCell(text: weightText, isEditing: isQuickAdjusting) { (editWeight ?? editNumbers)() }
                                .accessibilityLabel("第 \(number) 组重量，点击快调或输入")
                        }
                        BojiSetNumberCell(text: amountText, isEditing: isQuickAdjusting) { (editAmount ?? editNumbers)() }
                            .accessibilityLabel("第 \(number) 组\(trainingSet.durationSeconds == nil ? "次数" : "秒数")，\(amount)\(unit)，点击快调或输入")
                        completeControl
                            .frame(width: BojiSetTable.completeColumn)
                    }
                    .frame(minHeight: BojiSetTable.rowMinHeight)
                }
            }
            .padding(.horizontal, BojiLayout.tight)
            .background(
                trainingSet.validCompletion
                    ? BojiColor.emeraldAccent.opacity(0.08)
                    : (isActive ? BojiColor.subtleSurface.opacity(0.65) : Color.clear),
                in: RoundedRectangle(cornerRadius: BojiRadius.input, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: BojiRadius.input, style: .continuous)
                    .stroke(
                        isQuickAdjusting ? BojiColor.timerAccent : (isActive ? BojiColor.outline : .clear),
                        lineWidth: isQuickAdjusting ? 1.5 : 1.2
                    )
            }
            .animation(reduceMotion ? nil : .bojiSnappy, value: trainingSet.validCompletion)

            if isQuickAdjusting, trainingSet.hasActualEntry, let onQuickUpdate {
                inlineQuickAdjustTray(onQuickUpdate: onQuickUpdate)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .opacity.combined(with: .scale(scale: 0.96, anchor: .top))
                    )
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if trainingSet.validCompletion {
                Button {
                    BojiHaptics.latch()
                    undoComplete()
                } label: {
                    Label("撤销完成", systemImage: "arrow.uturn.backward")
                }
                .tint(.orange)
            } else if allowCompletion && amount > 0 {
                Button {
                    BojiHaptics.latch()
                    toggleComplete()
                } label: {
                    Label("完成本组", systemImage: "checkmark.circle.fill")
                }
                .tint(BojiColor.accentBrand)
            }
        }
        .contextMenu {
            Button {
                editNumbers()
            } label: {
                Label("编辑重量与次数", systemImage: "slider.horizontal.3")
            }
            if trainingSet.validCompletion {
                Button {
                    BojiHaptics.latch()
                    undoComplete()
                } label: {
                    Label("撤销本组完成状态", systemImage: "arrow.uturn.backward")
                }
            } else if allowCompletion && amount > 0 {
                Button {
                    BojiHaptics.latch()
                    toggleComplete()
                } label: {
                    Label("标记本组完成", systemImage: "checkmark.circle")
                }
            }
        }
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }

    private var weightText: String {
        trainingSet.hasActualEntry || !allowCompletion ? trainingSet.weight.formatted(.number.precision(.fractionLength(0...1))) : "—"
    }

    @ViewBuilder private var completeControl: some View {
        if trainingSet.validCompletion {
            LiquidCheckbox(isCompleted: true, isLastSet: isLastUncompletedSet) {
                undoComplete()
            }
            .accessibilityLabel("第 \(number) 组已完成，点击撤销完成")
        } else if allowCompletion {
            LiquidCheckbox(isCompleted: false, isLastSet: isLastUncompletedSet) {
                toggleComplete()
            }
            .disabled(amount <= 0)
            .accessibilityLabel("完成第 \(number) 组")
            .accessibilityHint(amount <= 0 ? "请先填写实际数值" : "保存本组并进入下一组")
        } else {
            Text("计划")
                .bojiFont(.label).foregroundStyle(BojiColor.textTertiary)
                .frame(minHeight: BojiSize.minimumTap)
        }
    }

    @ViewBuilder private func inlineQuickAdjustTray(onQuickUpdate: @escaping (TrainingSet) -> Void) -> some View {
        VStack(alignment: .leading, spacing: BojiLayout.inline) {
            if trainingSet.durationSeconds == nil {
                HStack(spacing: BojiLayout.tight) {
                    Text("重量")
                        .bojiType(.caption)
                        .foregroundStyle(BojiColor.textSecondary)
                        .frame(width: 28, alignment: .leading)
                    ForEach([-weightStep, weightStep, 5.0], id: \.self) { delta in
                        Button {
                            BojiHaptics.tick()
                            var copy = trainingSet
                            let next = min(RecordLimits.maximumWeight, max(0, ((copy.weight + delta) * 10).rounded() / 10))
                            copy.weight = next
                            withAnimation(.bojiSnappy) { onQuickUpdate(copy) }
                        } label: {
                            Text((delta > 0 ? "+" : "") + delta.formatted(.number.precision(.fractionLength(0...1))) + "kg")
                                .bojiType(.caption)
                                .padding(.horizontal, BojiLayout.inline)
                                .padding(.vertical, BojiSpace.tight)
                                .background(BojiColor.cardSurface, in: Capsule())
                                .overlay { Capsule().stroke(BojiColor.outline, lineWidth: 0.5) }
                        }
                        .buttonStyle(BojiPressableButtonStyle(scale: 0.92))
                    }
                    Spacer(minLength: 4)
                    Text("次数")
                        .bojiType(.caption)
                        .foregroundStyle(BojiColor.textSecondary)
                    ForEach([-1, 1, 2], id: \.self) { delta in
                        Button {
                            BojiHaptics.tick()
                            var copy = trainingSet
                            copy.reps = min(RecordLimits.maximumReps, max(1, copy.reps + delta))
                            withAnimation(.bojiSnappy) { onQuickUpdate(copy) }
                        } label: {
                            Text(delta > 0 ? "+\(delta)" : "\(delta)")
                                .bojiType(.caption)
                                .padding(.horizontal, BojiLayout.inline)
                                .padding(.vertical, BojiSpace.tight)
                                .background(BojiColor.cardSurface, in: Capsule())
                                .overlay { Capsule().stroke(BojiColor.outline, lineWidth: 0.5) }
                        }
                        .buttonStyle(BojiPressableButtonStyle(scale: 0.92))
                    }
                }
            } else {
                HStack(spacing: BojiLayout.tight) {
                    Text("时长")
                        .bojiType(.caption)
                        .foregroundStyle(BojiColor.textSecondary)
                    ForEach([-10, -5, 5, 15], id: \.self) { delta in
                        Button {
                            BojiHaptics.tick()
                            var copy = trainingSet
                            let cur = copy.durationSeconds ?? 30
                            copy.durationSeconds = min(RecordLimits.maximumSeconds, max(5, cur + delta))
                            withAnimation(.bojiSnappy) { onQuickUpdate(copy) }
                        } label: {
                            Text((delta > 0 ? "+" : "") + "\(delta)s")
                                .bojiType(.caption)
                                .padding(.horizontal, BojiLayout.inline)
                                .padding(.vertical, BojiSpace.tight)
                                .background(BojiColor.cardSurface, in: Capsule())
                                .overlay { Capsule().stroke(BojiColor.outline, lineWidth: 0.5) }
                        }
                        .buttonStyle(BojiPressableButtonStyle(scale: 0.92))
                    }
                    Spacer()
                }
            }

            HStack(spacing: BojiLayout.inline) {
                if let prev = previousSet, (prev.durationSeconds == nil) == (trainingSet.durationSeconds == nil) {
                    Button {
                        BojiHaptics.latch()
                        var copy = trainingSet
                        copy.weight = prev.weight
                        if prev.durationSeconds != nil { copy.durationSeconds = prev.durationSeconds }
                        else { copy.reps = prev.reps }
                        withAnimation(.bojiSnappy) { onQuickUpdate(copy) }
                    } label: {
                        Label(
                            prev.durationSeconds == nil
                                ? "沿用上组 (\(prev.weight.formatted(.number.precision(.fractionLength(0...1))))kg×\(prev.reps))"
                                : "沿用上组 (\(prev.durationSeconds ?? 30)s)",
                            systemImage: "arrow.uturn.down"
                        )
                        .bojiType(.caption)
                        .padding(.horizontal, BojiLayout.inline)
                        .padding(.vertical, BojiLayout.tight)
                        .background(BojiColor.cardSurface, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    BojiHaptics.tick()
                    (onOpenFullEditor ?? editNumbers)()
                } label: {
                    Label("键盘精调 / 更多", systemImage: "keyboard")
                        .bojiType(.caption)
                        .padding(.horizontal, BojiLayout.inline)
                        .padding(.vertical, BojiLayout.tight)
                        .background(BojiColor.cardSurface, in: Capsule())
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    BojiHaptics.tick()
                    editNumbers()
                } label: {
                    Text("收起")
                        .bojiType(.caption)
                        .foregroundStyle(BojiColor.textSecondary)
                        .padding(.horizontal, BojiSpace.tightRow)
                        .padding(.vertical, BojiLayout.tight)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(BojiLayout.inline)
        .background(BojiColor.subtleSurface, in: RoundedRectangle(cornerRadius: BojiRadius.inner, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: BojiRadius.inner, style: .continuous)
                .stroke(BojiColor.timerAccent.opacity(0.35), lineWidth: 1)
        }
    }
}

/// 轻按反馈（公开版，供训练页复用）。
struct BojiRowPressStylePublic: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: BojiMotion.pressDuration), value: configuration.isPressed)
    }
}

// MARK: - 数字编辑底部面板

/// 点击数值打开。临时值只在保存成功后写入；取消不落任何输入。
/// 切换动作、关闭面板、交互式下拉关闭时均拦截未保存输入。
struct TrainingSetEditPanel: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let original: TrainingSet
    let number: Int
    let previous: TrainingSet?
    let canUsePrevious: Bool
    let history: TrainingSet?
    let canUseHistory: Bool
    let weightStep: Binding<Double>
    let allowTimer: Bool
    let save: (TrainingSet) -> Bool
    /// 打开计时页时传入要计时的组（保存后传更新值，避免丢输入）。
    let startTimer: (TrainingSet) -> Void
    /// 删除在面板内确认并执行（避免面板与确认弹层跨层竞争）。
    /// 返回 false 表示未删除（如已确认场次保护），面板保持打开以展示原因。
    let performDelete: () -> Bool

    @State private var keypadWeight: Bool
    @State private var weight: String
    @State private var amount: String
    @State private var error: String?
    @State private var owner: Int?
    @State private var snapshot: TrainingSet?
    var isPlanTarget = false
    var completeOnSave = false
    @State private var confirmDiscard = false
    @State private var confirmDelete = false
    @State private var confirmTimer = false

    init(original: TrainingSet, number: Int, previous: TrainingSet?, canUsePrevious: Bool,
         history: TrainingSet? = nil, canUseHistory: Bool = false,
         weightStep: Binding<Double>, allowTimer: Bool, isPlanTarget: Bool = false, completeOnSave: Bool = false, initialWeight: Bool = true,
         save: @escaping (TrainingSet) -> Bool, startTimer: @escaping (TrainingSet) -> Void,
         performDelete: @escaping () -> Bool) {
        _keypadWeight = State(initialValue: initialWeight && original.durationSeconds == nil)
        self.original = original; self.number = number
        self.previous = previous; self.canUsePrevious = canUsePrevious
        self.history = history; self.canUseHistory = canUseHistory
        self.weightStep = weightStep; self.allowTimer = allowTimer; self.isPlanTarget = isPlanTarget; self.completeOnSave = completeOnSave
        self.save = save; self.startTimer = startTimer; self.performDelete = performDelete
        _weight = State(initialValue: original.hasActualEntry || isPlanTarget ? original.weight.formatted(.number.grouping(.never).precision(.fractionLength(0...1))) : "")
        _amount = State(initialValue: original.hasActualEntry || isPlanTarget ? String(original.durationSeconds ?? original.reps) : "")
    }

    private var isTimed: Bool { original.durationSeconds != nil }
    private var dirty: Bool {
        weight != (original.hasActualEntry || isPlanTarget ? original.weight.formatted(.number.grouping(.never).precision(.fractionLength(0...1))) : "")
            || amount != (original.hasActualEntry || isPlanTarget ? String(original.durationSeconds ?? original.reps) : "")
    }

    private func applyTargetValues() {
        weight = original.weight.formatted(.number.grouping(.never).precision(.fractionLength(0...1)))
        let count = original.durationSeconds ?? original.reps
        amount = String(count)
    }

    private func applyHistoryValues(_ history: TrainingSet) {
        weight = history.weight.formatted(.number.grouping(.never).precision(.fractionLength(0...1)))
        let count = history.durationSeconds ?? history.reps
        amount = String(count)
    }

    private func applyPreviousValues(_ previous: TrainingSet) {
        weight = previous.weight.formatted(.number.grouping(.never).precision(.fractionLength(0...1)))
        let count = previous.durationSeconds ?? previous.reps
        amount = String(count)
    }

    var body: some View {
        NavigationStack {
            Form {
                if !original.hasActualEntry && !isPlanTarget {
                    Section("本组目标参考") {
                        Text(isTimed ? "目标 \(original.durationSeconds ?? 0) 秒" : "目标 \(original.weight.formatted()) kg · \(original.reps) 次")
                            .bojiType(.label).foregroundStyle(.secondary)
                        Button("填入本组目标值", action: applyTargetValues)
                    }
                }

                Section(isTimed ? "时长（秒）" : "重量（kg）") {
                    HStack(spacing: BojiSpace.general) {
                        if !isTimed {
                            stepButton(symbol: "minus") { adjust(isWeight: true, positive: false) }
                            ClubNumericField(value: $weight, placeholder: "无额外负重填 0", decimal: true, selected: keypadWeight) { keypadWeight = true }
                            stepButton(symbol: "plus") { adjust(isWeight: true, positive: true) }
                        } else {
                            stepButton(symbol: "minus") { adjust(isWeight: false, positive: false, timed: true) }
                            ClubNumericField(value: $amount, placeholder: "实际秒数", decimal: false, selected: !keypadWeight) { keypadWeight = false }
                            stepButton(symbol: "plus") { adjust(isWeight: false, positive: true, timed: true) }
                        }
                    }
                    if !isTimed {
                        SmartWeightStepper(currentWeight: Double(weight.replacingOccurrences(of: ",", with: ".")) ?? 0) { delta in
                            let current = Double(weight.replacingOccurrences(of: ",", with: ".")) ?? 0
                            let next = min(RecordLimits.maximumWeight, max(0, ((current + delta) * 10).rounded() / 10))
                            weight = next.formatted(.number.grouping(.never).precision(.fractionLength(0...1)))
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, BojiLayout.tight)
                    }
                }
                if !isTimed {
                    Section("次数") {
                        HStack(spacing: BojiSpace.general) {
                            stepButton(symbol: "minus") { adjust(isWeight: false, positive: false) }
                            ClubNumericField(value: $amount, placeholder: "实际完成次数", decimal: false, selected: !keypadWeight) { keypadWeight = false }
                            stepButton(symbol: "plus") { adjust(isWeight: false, positive: true) }
                        }
                    }
                    Section("重量步长") {
                        Picker("重量步长", selection: weightStep) {
                            ForEach([0.5, 1.0, 2.5, 5.0], id: \.self) {
                                Text("\($0.formatted()) kg").tag($0)
                            }
                        }.clubAdaptivePicker()
                    }
                }
                Section {
                    if isTimed && allowTimer && !original.validCompletion {
                        Button("开始计时") {
                            // F12：有未保存输入时先问，不能静默丢弃。
                            if dirty { confirmTimer = true }
                            else { startTimer(original); dismiss() }
                        }.buttonStyle(BojiButtonStyle(kind: .secondary))
                    }
                    if canUseHistory, let history {
                        let historyText = history.durationSeconds == nil
                            ? "\(history.weight.formatted(.number.precision(.fractionLength(0...1)))) kg × \(history.reps) 次"
                            : "\(history.durationSeconds ?? 0) 秒"
                        Button("沿用上次训练（\(historyText)）") {
                            applyHistoryValues(history)
                        }.buttonStyle(BojiButtonStyle(kind: .secondary))
                    }
                    if canUsePrevious, let previous {
                        let previousText = previous.durationSeconds == nil
                            ? "\(previous.weight.formatted(.number.precision(.fractionLength(0...1)))) kg × \(previous.reps) 次"
                            : "\(previous.durationSeconds ?? 0) 秒"
                        Button("沿用上一组（\(previousText)）") {
                            applyPreviousValues(previous)
                        }.buttonStyle(BojiButtonStyle(kind: .secondary))
                    }
                    Button("保存数值", action: submit).buttonStyle(BojiButtonStyle(kind: .primary))
                    if let error {
                        Text(error).bojiFont(.secondary).foregroundStyle(.red)
                    }
                    Text("只修改这一组；取消不会写入输入内容。").bojiFont(.secondary)
                        .foregroundStyle(BojiColor.textSecondary)
                }
            }.clubGroupedSurface()
            .navigationTitle("第 \(number) 组").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { if dirty { confirmDiscard = true } else { dismiss() } }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("删除本组", role: .destructive) { confirmDelete = true }
                    } label: {
                        Image(systemName: "ellipsis").frame(width: BojiSize.minimumTap, height: BojiSize.minimumTap)
                    }
                    .accessibilityLabel("本组更多操作")
                }
                ToolbarItem(placement: .confirmationAction) { Button("保存", action: submit) }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 0) {
                    HStack {
                        Text(keypadWeight ? "重量 kg" : isTimed ? "时长 秒" : "次数").bojiType(.caption)
                        Spacer()
                        Button("清空") { if keypadWeight { weight = "" } else { amount = "" } }.bojiType(.caption)
                    }
                    ClubNumericKeypad(value: keypadWeight ? $weight : $amount, decimal: keypadWeight, next: keypadWeight && !isTimed ? { keypadWeight = false } : nil)
                }.padding(.horizontal, BojiLayout.pageInset).clubGlassEffect(in: RoundedRectangle(cornerRadius: BojiRadius.input, style: .continuous))
            }
            .interactiveDismissDisabled(dirty)
            .confirmationDialog("放弃这组未保存的输入？", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("放弃输入", role: .destructive) { dismiss() }
                Button("继续编辑", role: .cancel) { }
            }
            .confirmationDialog("删除这组训练记录？", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("删除训练组", role: .destructive) {
                    if performDelete() { dismiss() }
                }
                Button("取消", role: .cancel) { }
            } message: {
                Text("删除后这组不再计入完成统计；动作和其他训练组保留。")
            }
            .confirmationDialog("开始计时前如何处理已输入的数值？", isPresented: $confirmTimer, titleVisibility: .visible) {
                Button("保存输入并开始计时") { commitTyped(startTimerAfter: true) }
                Button("放弃输入，直接计时", role: .destructive) { startTimer(original); dismiss() }
                Button("继续编辑", role: .cancel) { }
            }
            .onAppear { if snapshot == nil { snapshot = original; owner = store.editingAccountID } }
            .onChange(of: store.editingAccountID) { _, value in if value != owner { dismiss() } }
        }
        .presentationDetents([.large])
    }

    private func stepButton(symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: BojiSize.minimumTap, height: BojiSize.minimumTap)
        }.buttonStyle(BojiCircleButtonStyle(visualDiameter: 36))
    }

    private func adjust(isWeight: Bool, positive: Bool, timed: Bool = false) {
        if isWeight {
            let delta = positive ? weightStep.wrappedValue : -weightStep.wrappedValue
            let current = Double(weight.replacingOccurrences(of: ",", with: ".")) ?? 0
            let next = min(RecordLimits.maximumWeight, max(0, ((current + delta) * 10).rounded() / 10))
            weight = next.formatted(.number.grouping(.never).precision(.fractionLength(0...1)))
        } else {
            let current = Int(amount) ?? 0
            let delta = (timed ? 5 : 1) * (positive ? 1 : -1)
            let next = min(timed ? RecordLimits.maximumSeconds : RecordLimits.maximumReps, max(0, current + delta))
            amount = String(next)
        }
    }

    private func submit() { commitTyped(startTimerAfter: false) }

    private func commitTyped(startTimerAfter: Bool) {
        guard owner == store.editingAccountID, let snapshot,
              snapshot.weight == original.weight, snapshot.reps == original.reps,
              snapshot.durationSeconds == original.durationSeconds, snapshot.completed == original.completed else {
            error = "记录或账号已变化，请关闭后重新核对。"; return
        }
        let cleaned = (isTimed ? "0" : weight).trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        guard let kg = Double(cleaned), kg.isFinite, kg >= 0, kg <= RecordLimits.maximumWeight,
              let count = Int(amount.trimmingCharacters(in: .whitespacesAndNewlines)), count > 0,
              count <= (isTimed ? RecordLimits.maximumSeconds : RecordLimits.maximumReps) else {
            error = "请填写有效负重和大于 0 的次数或秒数。"; return
        }
        var value = original; value.weight = (kg * 10).rounded() / 10; value.actualEntered = !isPlanTarget
        if completeOnSave && !startTimerAfter { value.completed = true }
        if isTimed { value.durationSeconds = count; value.reps = 0 } else { value.reps = count }
        if save(value) {
            if startTimerAfter { startTimer(value) }
            dismiss()
        } else { error = "未能保存，请检查训练记录后重试。" }
    }
}

// MARK: - 应用内迷你训练栏

/// 可跨页面复用的轻量训练状态；完整训练仍由全屏 WorkoutView 承载。
struct MiniWorkoutBar: View {
    let snapshot: ActiveWorkoutSnapshot
    let open: () -> Void
    let togglePause: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showAICoach = false

    var body: some View {
        HStack(spacing: BojiLayout.inline) {
            Button(action: open) {
                HStack(spacing: BojiLayout.inline) {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(clock(snapshot.isPaused ? snapshot.elapsed : snapshot.elapsed(at: context.date)))
                            // 系统字号（subheadline=15pt）随动态字体缩放；固定 15pt 会被
                            // 审计判"完全不支持动态字体"（硬失败）。fixedSize 防止
                            // 辅助字号下时间在冒号处折行（00:\n14）。
                            .bojiType(.secondary)
                            .foregroundStyle(BojiColor.timerAccent)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(minWidth: 48, alignment: .leading)
                    }
                    VStack(alignment: .leading, spacing: BojiLayout.tight) {
                        // 不设行数上限：设限后更大动态字体下会被审计判"可能裁切"。
                        Text(snapshot.isPaused ? "训练已暂停" : snapshot.currentExerciseName ?? snapshot.workoutName)
                            .bojiType(.secondary)
                        HStack(spacing: BojiLayout.inline) {
                            Text("\(snapshot.completedSets)/\(snapshot.totalSets) 组")
                                .bojiType(.caption)
                                // 系统 .secondary 在半透明材质上不足 4.5:1，用品牌次级文本色。
                                .foregroundStyle(BojiColor.textSecondary)
                            BojiSegmentedProgress(total: snapshot.totalSets, completed: snapshot.completedSets)
                            if let rest = snapshot.restEndsAt, rest > Date() {
                                TimelineView(.periodic(from: .now, by: 1)) { context in
                                    Text("休息 \(max(0, Int(ceil(rest.timeIntervalSince(context.date)))))s")
                                        .bojiType(.caption).foregroundStyle(BojiColor.timerAccent)
                                }
                            }
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up").bojiType(.caption).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button {
                BojiHaptics.latch()
                showAICoach = true
            } label: {
                Image(systemName: "sparkles")
                    .bojiType(.label)
                    .frame(width: 36, height: 36).contentShape(Rectangle().inset(by: -4)) // 命中区 44
                    .background(BojiColor.subtleSurface, in: Circle())
                    // aiGold（浅色 222,193,138）对 subtleSurface 仅 1.56:1，过不了
                    // 图形 3:1 对比度审计；timerAccent 为同族深金（3.25:1 浅色 / 8.9:1 暗色）。
                    .foregroundStyle(BojiColor.timerAccent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("召唤 Club AI 教练")
            Button(action: togglePause) {
                Image(systemName: snapshot.isPaused ? "play.fill" : "pause.fill")
                    .bojiType(.label)
                    .frame(width: 44, height: 44)
                    .background(BojiColor.subtleSurface, in: Circle())
                    .foregroundStyle(BojiColor.textPrimary)
            }
            .frame(width: 44, height: 44).contentShape(Rectangle()).layoutPriority(1)
            .buttonStyle(.plain)
            .accessibilityLabel(snapshot.isPaused ? "继续训练" : "暂停训练")
        }
        .padding(.horizontal, BojiSpace.workoutCardInset)
        .frame(minHeight: dynamicTypeSize.isAccessibilitySize ? 96 : 78)
        .clubGlassEffect(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .bojiSpecularBorder(cornerRadius: 20)
        .shadow(color: .black.opacity(0.14), radius: 18, y: 6)
        .sheet(isPresented: $showAICoach) {
            ClubCurrentTrainingHelp(date: ClubDates.date(fromKey: snapshot.dateKey) ?? Date())
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .accessibilityIdentifier("mini-workout-bar")
        .accessibilityElement(children: .contain)
    }
    private func clock(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d", value / 60, value % 60)
    }
}

private struct MiniWorkoutInsetModifier: ViewModifier {
    let snapshot: ActiveWorkoutSnapshot?
    let open: () -> Void
    let togglePause: () -> Void
    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            if let snapshot {
                MiniWorkoutBar(snapshot: snapshot, open: open, togglePause: togglePause)
                    .padding(.horizontal, BojiSpace.general)
                    .padding(.bottom, BojiLayout.tight)
            }
        }
    }
}

extension View {
    func miniWorkoutInset(snapshot: ActiveWorkoutSnapshot?, open: @escaping () -> Void,
                          togglePause: @escaping () -> Void) -> some View {
        modifier(MiniWorkoutInsetModifier(snapshot: snapshot, open: open, togglePause: togglePause))
    }
}

// MARK: - 杠铃片计算器 (PM 40)

struct BarbellPlateCalculatorSheet: View {
    @Binding var targetWeightString: String
    @Environment(\.dismiss) private var dismiss
    @State private var barWeight: Double = 20.0
    @State private var targetWeight: Double = 60.0

    private let standardPlates: [Double] = [25.0, 20.0, 15.0, 10.0, 5.0, 2.5, 1.25]

    init(targetWeightString: Binding<String>) {
        _targetWeightString = targetWeightString
        let parsed = Double(targetWeightString.wrappedValue.replacingOccurrences(of: ",", with: ".")) ?? 60.0
        _targetWeight = State(initialValue: max(20.0, parsed))
    }

    private var sideWeight: Double {
        max(0, (targetWeight - barWeight) / 2.0)
    }

    private var plateBreakdown: [(plate: Double, count: Int)] {
        var remaining = sideWeight
        var result: [(Double, Int)] = []
        for plate in standardPlates {
            if remaining >= plate {
                let count = Int(remaining / plate)
                result.append((plate, count))
                remaining -= Double(count) * plate
                remaining = (remaining * 100).rounded() / 100
            }
        }
        return result
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("杠铃杆重量") {
                    Picker("杆重", selection: $barWeight) {
                        Text("20 kg（标准奥林匹克杆）").tag(20.0)
                        Text("15 kg（女子/轻量杆）").tag(15.0)
                        Text("10 kg（技术练习杆）").tag(10.0)
                    }
                    .pickerStyle(.menu)
                }

                Section("目标总重量（含杠铃杆）") {
                    HStack {
                        Button {
                            targetWeight = max(barWeight, targetWeight - 2.5)
                        } label: {
                            Image(systemName: "minus.circle.fill").bojiType(.section)
                        }
                        .buttonStyle(.plain)

                        Spacer()
                        Text("\(targetWeight.formatted(.number.precision(.fractionLength(0...1)))) kg")
                            .bojiType(.title)
                        Spacer()

                        Button {
                            targetWeight = min(400, targetWeight + 2.5)
                        } label: {
                            Image(systemName: "plus.circle.fill").bojiType(.section)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, BojiLayout.tight)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: BojiLayout.inline) {
                            ForEach([40.0, 60.0, 80.0, 100.0, 120.0, 140.0], id: \.self) { preset in
                                Button("\(Int(preset)) kg") {
                                    targetWeight = preset
                                    BojiHaptics.tick()
                                }
                                .buttonStyle(.bordered)
                                .buttonBorderShape(.capsule)
                                .controlSize(.small)
                            }
                        }
                    }
                }

                Section("配片方案（单侧装配）") {
                    if targetWeight < barWeight {
                        Text("目标重量小于杠铃杆重量（\(barWeight.formatted()) kg）")
                            .bojiType(.label)
                            .foregroundStyle(.secondary)
                    } else if plateBreakdown.isEmpty {
                        Text("空杆即可，无需上片（单侧 0 kg）")
                            .bojiType(.label)
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: BojiLayout.inline) {
                            HStack {
                                Text("单侧需配重：")
                                    .bojiType(.secondary)
                                    .foregroundStyle(.secondary)
                                Text("\(sideWeight.formatted(.number.precision(.fractionLength(0...2)))) kg")
                                    .bojiType(.secondary)
                            }

                            HStack(spacing: BojiLayout.tight) {
                                ForEach(plateBreakdown, id: \.plate) { item in
                                    ForEach(0..<item.count, id: \.self) { _ in
                                        VStack(spacing: 0) {
                                            RoundedRectangle(cornerRadius: BojiRadius.badge)
                                                .fill(plateColor(item.plate))
                                                .frame(width: plateWidth(item.plate), height: plateHeight(item.plate))
                                            Text("\(item.plate.formatted())")
                                                .bojiType(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                            .padding(.vertical, BojiLayout.inline)

                            Text("单侧各上：" + plateBreakdown.map { "\($0.plate.formatted())kg × \($0.count)" }.joined(separator: " + "))
                                .bojiType(.label)
                                .foregroundStyle(BojiColor.textPrimary)

                            Text("杆重 \(barWeight.formatted())kg + 双侧各 \(sideWeight.formatted())kg = 总计 \(targetWeight.formatted())kg")
                                .bojiType(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    Button("填入此重量并关闭") {
                        targetWeightString = targetWeight.formatted(.number.grouping(.never).precision(.fractionLength(0...1)))
                        BojiHaptics.latch()
                        dismiss()
                    }
                    .buttonStyle(BojiButtonStyle(kind: .primary))
                }
            }
            .navigationTitle("杠铃片计算器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    private func plateColor(_ weight: Double) -> Color {
        switch weight {
        case 25: return Color.red
        case 20: return Color.blue
        case 15: return Color.yellow
        case 10: return Color.green
        case 5: return Color.white.opacity(0.8)
        default: return Color.gray
        }
    }

    private func plateWidth(_ weight: Double) -> CGFloat {
        switch weight {
        case 25, 20: return 16
        case 15, 10: return 13
        default: return 10
        }
    }

    private func plateHeight(_ weight: Double) -> CGFloat {
        switch weight {
        case 25: return 52
        case 20: return 48
        case 15: return 42
        case 10: return 36
        case 5: return 30
        default: return 24
        }
    }
}
