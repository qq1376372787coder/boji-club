import SwiftUI
import UIKit

struct WorkoutView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var notifications: AppNotificationService
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("training.rest.seconds") private var restSeconds = 60
    @AppStorage("training.rest.alerts") private var restAlerts = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var pauseService = WorkoutPauseService.shared
    @Binding var selectedDate: Date
    var focused = true
    var initialRestEnd: Date? = nil
    var restChanged: ((Date?) -> Void)? = nil
    @State private var expandedExerciseID: UUID?
    @State private var showPlan = false
    @State private var showMyPlans = false
    @State private var showAdvance = false
    @State private var showLibrary = false
    @State private var restEnd: Date?
    @State private var restPausedRemaining: TimeInterval?
    @State private var restOwnerID: Int?
    @State private var restDateKey = ""
    @State private var shareDraft: ShareDraft?
    @State private var saveFeedback = 0
    @State private var planFeedback = 0
    @State private var completion: WorkoutCompletionSnapshot?
    @State private var confirmFinish = false
    @State private var finishReviewOwner: Int?
    @State private var finishReviewSession: UUID?
    @State private var restFeedback = 0
    @State private var actionError: String?
    private func finishWorkout() {
        let showCompletion = !hasFinished
        guard let owner = store.editingAccountID else {
            actionError = "登录状态已变化，请在当前账号重新打开训练。"
            return
        }
        guard store.saveWorkout(on: selectedDate) else {
            actionError = store.takeMessage(fallback: "训练未能保存。原记录保留，请检查存储空间后重试。")
            return
        }
        TrainingActivityService.shared.end(); restEnd = nil; restPausedRemaining = nil; saveFeedback &+= 1
        if showCompletion {
            let saved = store.log(for: selectedDate)
            completion = WorkoutCompletionSnapshot(ownerID: owner, date: selectedDate, sessionID: saved.activeWorkoutSessionID)
        }
    }
    private var hasFinished: Bool { log.workoutEndedAt != nil || log.workoutSavedAt != nil }
    private var log: DayLog { store.log(for: selectedDate).trainingLog }
    private var day: DayLog { store.log(for: selectedDate) }
    private var isFuture: Bool { ClubDates.isFuture(selectedDate) }
    private var isPlannedRestDay: Bool {
        let key = ClubDates.key(selectedDate)
        guard log.exercises.isEmpty, let cycle = day.planCycle,
              cycle.dates.contains(key) else { return false }
        return !cycle.plannedDates.contains(key)
    }

    var body: some View {
        restTaskWorkout
            .alert("操作未完成", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
                Button("知道了") { actionError = nil }
            } message: {
                Text(actionError ?? "请稍后再试。")
            }
    }

    private var workoutContent: some View {
        ScrollView {
            VStack(spacing: 18) {
                Text(ClubDates.label(selectedDate, format: "M月d日 EEEE"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                trainingContent
            }
            .padding(ClubUI.pageInset)
        }.scrollDismissesKeyboard(.interactively)
    }

    private var presentedWorkout: some View {
        workoutContent
        .background { ClubBackground() }
        .navigationTitle(isFuture ? "当天安排" : "训练登记")
        .onAppear {
            restOwnerID = store.editingAccountID; restDateKey = ClubDates.key(selectedDate)
            if expandedExerciseID == nil {
                expandedExerciseID = log.exercises.first(where: { $0.sets.contains { !$0.validCompletion } })?.id ?? log.exercises.first?.id
            }
            if let owner = store.editingAccountID {
                pauseService.load(owner: owner, date: selectedDate, sessionID: day.activeWorkoutSessionID)
                restEnd = ClubRestStorage.deadline(owner: owner, date: selectedDate, sessionID: day.activeWorkoutSessionID, unfinished: !hasFinished)
                restPausedRemaining = ClubRestStorage.pausedRemaining(owner: owner, date: selectedDate, sessionID: day.activeWorkoutSessionID, unfinished: !hasFinished)
            }
            if restEnd == nil, restPausedRemaining == nil, let end = initialRestEnd, end > Date(), !hasFinished { restEnd = end }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !isFuture {
                ToolbarItem(placement: .principal) { TrainingElapsedLabel(date: selectedDate) }
            }
            ToolbarItem(placement: .topBarTrailing) { workoutMoreMenu }
            ToolbarItem(placement: .topBarTrailing) {
                if !isFuture && !log.exercises.isEmpty {
                    Button {
                        if hasFinished { finishWorkout() }
                        else { finishReviewOwner = store.editingAccountID; finishReviewSession = day.activeWorkoutSessionID; confirmFinish = true }
                    } label: {
                        Text(hasFinished ? "保存修改" : "结束训练")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, BojiSpace.workoutCardInset).padding(.vertical, BojiSpace.tightRow)
                            .background(BojiColor.textPrimary, in: Capsule())
                            .foregroundStyle(BojiColor.pageBackground)
                    }
                    .disabled(log.completedSets == 0)
                    .accessibilityLabel(hasFinished ? "保存训练修改" : "结束并保存本次训练")
                    .accessibilityHint(log.completedSets == 0 ? "至少完成一组后才能结束训练" : "")
                }
            }
        }
        .sheet(isPresented: $showPlan) { PlanCreationSheet(date: selectedDate) }
        .sheet(isPresented: $showMyPlans) { TrainingPlansView(focusDate: selectedDate) }
        .sheet(isPresented: $showAdvance) { AdvanceWorkoutView(date: selectedDate) }
        .sheet(isPresented: $showLibrary) {
            NavigationStack {
                ExerciseLibraryView(date: selectedDate) { showLibrary = false }
                    .navigationTitle("动作库")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { showLibrary = false } } }
            }
        }
        .sheet(item: $completion) { snapshot in WorkoutCompletionView(snapshot: snapshot) }
        .sheet(isPresented: $confirmFinish) {
            WorkoutFinishReview125(completed: log.completedSets, total: log.totalSets, confirm: {
                guard store.editingAccountID == finishReviewOwner, day.activeWorkoutSessionID == finishReviewSession else {
                    confirmFinish = false; actionError = "训练或账号已变化，请重新核对。"; return
                }
                let reviewDate = ClubDates.key(selectedDate)
                confirmFinish = false
                // Present the saved summary only after the review sheet has closed.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(350))
                    guard store.editingAccountID == finishReviewOwner, day.activeWorkoutSessionID == finishReviewSession, ClubDates.key(selectedDate) == reviewDate, !hasFinished else { return }
                    finishWorkout()
                }
            }, cancel: { confirmFinish = false })
        }
        .sheet(item: $shareDraft) { draft in
            ShareCardPreview(draft: draft)
        }
    }

    private var observedWorkout: some View {
        presentedWorkout
        .clubSuccessFeedback("本次训练记录已确认", trigger: saveFeedback)
        .clubSuccessFeedback("训练计划已保存", trigger: planFeedback)
        .sensoryFeedback(.success, trigger: saveFeedback)
        .sensoryFeedback(.success, trigger: restFeedback)
        .onChange(of: selectedDate) { _, _ in restEnd = nil; completion = nil; confirmFinish = false }
        .onChange(of:store.editingAccountID) { _, _ in restEnd = nil; completion = nil; confirmFinish = false }
        .onChange(of: day.activeWorkoutSessionID) { previous, value in
            pauseService.load(owner: store.editingAccountID ?? 0, date: selectedDate, sessionID: value)
            store.restoreWorkoutPause(on: selectedDate)
            // nil -> first ID freezes the same workout, rather than switching workouts.
            if WorkoutSessionTransition.shouldResetRest(previous: previous, current: value) { TrainingActivityService.shared.end(); restEnd = nil }
            if let completion, completion.sessionID != value { self.completion = nil }
        }
        .onChange(of: log.completedSets) { _, count in if count > 0 { ClubInlineGuide.complete("first_set", owner: store.editingAccountID) }; updateActivity() }
        .onChange(of: log.totalSets) { _, _ in updateActivity() }
        .onChange(of: log.workoutSavedAt) { _, _ in updateActivity() }
    }

    private var restObservedWorkout: some View {
        observedWorkout
        .onChange(of: restEnd) { _, end in
            if end != nil, restPausedRemaining != nil { restPausedRemaining = nil }
            updateActivity()
            if let owner = restOwnerID, owner == store.editingAccountID, restDateKey == ClubDates.key(selectedDate) {
                if let remaining = restPausedRemaining {
                    ClubRestStorage.savePaused(remaining, owner: owner, date: selectedDate, sessionID: day.activeWorkoutSessionID)
                } else {
                    ClubRestStorage.save(end, owner: owner, date: selectedDate, sessionID: day.activeWorkoutSessionID)
                }
            }
            restChanged?(end)
            updateActivity()
            if restAlerts, let end { notifications.scheduleRestReminder(until: end, on: selectedDate) }
            else { notifications.cancelRestReminder() }
        }
        .onChange(of: pauseService.state?.isPaused) { previous, paused in
            if paused == true, let end = restEnd {
                restPausedRemaining = max(0, end.timeIntervalSinceNow); restEnd = nil
                notifications.cancelRestReminder()
            } else if previous == true, let remaining = restPausedRemaining {
                restPausedRemaining = nil; restEnd = Date().addingTimeInterval(remaining)
            }
        }
        .onChange(of: restAlerts) { _, enabled in
            if enabled, let restEnd { notifications.scheduleRestReminder(until: restEnd, on: selectedDate) }
            else { notifications.cancelRestReminder() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active, let owner = restOwnerID, owner == store.editingAccountID, restDateKey == ClubDates.key(selectedDate) {
                if let remaining = restPausedRemaining { ClubRestStorage.savePaused(remaining, owner: owner, date: selectedDate, sessionID: day.activeWorkoutSessionID) }
                else { ClubRestStorage.save(restEnd, owner: owner, date: selectedDate, sessionID: day.activeWorkoutSessionID) }
            }
        }
    }

    private var restTaskWorkout: some View {
        restObservedWorkout
        .task(id: restEnd) {
            guard let end = restEnd, end > Date() else { return }
            do { try await Task.sleep(for: .seconds(max(0, end.timeIntervalSinceNow))) } catch { return }
            guard !Task.isCancelled, restEnd == end, restAlerts, scenePhase == .active else { return }
            restFeedback &+= 1
        }
        .safeAreaInset(edge: .bottom) {
            // 底部安全区只放休息条；结束训练在顶栏，避免双主按钮。
            // 未来日期没有休息，保留保存计划入口。
            if !log.exercises.isEmpty {
                VStack(spacing: 0) {
                    restDock
                    if isFuture { futurePlanSaveDock }
                }
            }
        }
    }

    private var workoutMoreMenu: some View {
        Menu {
            Button { showMyPlans = true } label: { Label("我的计划", systemImage: "list.bullet.rectangle") }
            if hasFinished { additionalWorkoutMenu }
            if true {
                if !isFuture, !hasFinished, log.workoutStartedAt != nil, let owner = store.editingAccountID,
                   let session = day.activeWorkoutSessionID {
                    Button {
                        let paused = pauseService.state?.isPaused == true
                        if !store.setWorkoutPaused(!paused, on: selectedDate) { actionError = "暂停状态未保存，请重试。" }
                        updateActivity()
                    } label: {
                        Label(pauseService.state?.isPaused == true ? "继续训练" : "暂停训练",
                              systemImage: pauseService.state?.isPaused == true ? "play.circle" : "pause.circle")
                    }
                }
                Menu(restSeconds == 0 ? "默认休息：关闭" : "默认休息：\(restSeconds) 秒") {
                    ForEach([0, 30, 60, 90, 120, 180], id: \.self) { seconds in
                        Button(seconds == 0 ? "关闭自动休息" : "\(seconds) 秒") { restSeconds = seconds }
                    }
                }
                Menu("结束提醒") {
                    Toggle("结束震动与通知", isOn: $restAlerts)
                    Button("开启系统通知权限") { Task { await notifications.requestAuthorization() } }
                }
                if !isFuture && log.workoutSavedAt != nil {
                    Button {
                        let card = ShareCardView(
                            title: "\(ClubDates.label(selectedDate)) \(log.totalSets > 0 && log.completedSets >= log.totalSets ? "训练完成" : "训练记录")",
                            headline: "已完成 \(log.completedSets) / \(log.totalSets) 组，每一组都有记录。",
                            stats: TrainingRecordText.summary(log),
                            tagline: "把进步交给时间。"
                        )
                        shareDraft = ShareDraft(card: card)
                    } label: { Label("分享训练记录卡", systemImage: "square.and.arrow.up") }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .foregroundStyle(BojiColor.textPrimary)
                .frame(width: BojiSize.minimumTap, height: BojiSize.minimumTap)
                .contentShape(Circle())
        }
        .accessibilityLabel("更多操作")
    }

    private func updateActivity() {
        store.restoreWorkoutPause(on: selectedDate)
        guard Calendar.current.isDateInToday(selectedDate) || WorkoutTiming.isOngoing(log,on:selectedDate) else { return }
        let snapshot = ActiveWorkoutRules.snapshot(state: store.state, now: Date(), pause: pauseService.state,
                                                   restEndsAt: restPausedRemaining == nil ? restEnd : nil)
        TrainingActivityService.shared.sync(snapshot: snapshot, restPausedRemaining: restPausedRemaining)
    }

    private var trainingContent: some View {
        VStack(spacing: 14) {
            movedTrainingNotice
            workoutSessionPicker
            if !isFuture && !log.exercises.isEmpty { trainingProgressSummary }
            trainingStartControls
            ClubInlineGuide(step: "first_set", message: "点重量或次数填写实际数值，做完一组再点完成。")

            emptyTrainingContent
            trainingExerciseList
            trainingFooter
        }.clubMotion(value: log.exercises.map(\.id))
    }

    /// 顶部进度摘要：真实完成数据；总训练量按已完成组计算。
    @ViewBuilder private var trainingProgressSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("已完成 \(log.completedSets) / \(log.totalSets) 组")
                        .bojiFont(.cardTitle)
                    Text(log.workoutSavedAt != nil ? "本次训练记录已确认，汗水已入账"
                         : log.workoutEndedAt != nil ? "训练已结束 · 点击右上角确认保存"
                         : log.workoutStartedAt == nil && log.completedSets == 0 ? "训练准备 · 核对动作与目标" : "训练进行中 · 记录每一次突破")
                        .bojiFont(.label).foregroundStyle(BojiColor.textSecondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    ForEach(TrainingRecordText.measurements(log), id: \.self) { text in
                        Text(text).bojiFont(.label, monospacedDigits: true)
                            .foregroundStyle(BojiColor.textSecondary)
                    }
                }
            }
            ProgressView(value: Double(log.completedSets), total: Double(max(1, log.totalSets)))
                .tint(ClubBrand.accent)
                .clubMotion(value: log.completedSets)
                .accessibilityLabel("训练完成进度")
            if hasFinished {
                Text("按已完成组统计额外负重 × 次数")
                    .bojiFont(.label).foregroundStyle(BojiColor.textSecondary)
            }
            if log.completedSets == 0 && !hasFinished {
                Text("完成首组后即可保存本堂训练。")
                    .bojiFont(.label).foregroundStyle(BojiColor.textSecondary)
            }
        }
        .bojiCard()
    }

    @ViewBuilder private var movedTrainingNotice: some View {
        if let original = day.movedFromDate {
                Text("今天提前执行了 \(original) 的训练安排，原日期不会重复待练。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
    }

    @ViewBuilder private var trainingPurpose: some View {
        PlanDayPurposeView(dateKey: ClubDates.key(selectedDate), day: day)
    }

    @ViewBuilder private var workoutSessionPicker: some View {
        if let sessions = day.workoutSessions, sessions.count > 1 {
                Picker("当天训练", selection: Binding<UUID?>(get: { day.activeWorkoutSessionID }, set: { id in if let id { _ = store.selectWorkoutSession(id, on: selectedDate) } })) {
                    ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                        Text("第 \(index + 1) 次训练 · \(session.savedAt == nil ? "待确认" : "已确认")").tag(Optional(session.id))
                    }
                }.pickerStyle(.menu)
                Text("可切换或新增当日训练场次（最多 8 场）").font(.caption2).foregroundStyle(.secondary)
                if let id = day.activeWorkoutSessionID, EmptyWorkoutSessionRules.canRemove(id, from: day) {
                    Button("删除这次空白训练", role: .destructive) { _ = store.removeEmptyWorkoutSession(id, on: selectedDate) }.buttonStyle(DestructiveButton())
                }
            }
    }

    @ViewBuilder private var additionalWorkoutMenu: some View {
        if !isFuture && !log.exercises.isEmpty {
                Menu("同日再练一场") {
                    Button("新建空白训练") { if store.addWorkoutSession(on: selectedDate, copyPlan: false) { restEnd = nil } }
                    Button("复制当前动作，清空完成标记") { if store.addWorkoutSession(on: selectedDate, copyPlan: true) { restEnd = nil } }
                    if ClubDates.calendar.isDateInToday(selectedDate) {
                        Button("提前未来训练，保留当前记录") { showAdvance = true }
                    }
                }.font(.caption)
            }
    }

    @ViewBuilder private var trainingStartControls: some View {
        if isFuture {
            Text("这是未来的训练计划。可以安排动作和目标组数，到了当天再勾选完成。")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        if !log.exercises.isEmpty && Calendar.current.isDateInToday(selectedDate) && log.workoutStartedAt == nil && log.completedSets == 0 {
            Button { store.beginWorkout(on: selectedDate) } label: {
                Label("开始训练", systemImage: "play.fill")
            }.buttonStyle(SecondaryButton())
        }
    }

    @ViewBuilder private var trainingTimingHelp: some View {
        if !log.exercises.isEmpty && !isFuture {
            Text("记录开始时间，便于核对手表训练记录")
                .font(.footnote).foregroundStyle(.secondary)
            if restSeconds > 0 || log.exercises.contains(where: { ($0.restSeconds ?? 0) > 0 }) {
                Text("勾选完成本组后自动开始休息计时")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var emptyTrainingContent: some View {
        if log.exercises.isEmpty {
                ClubCard {
                    if let target = day.plannedMoveDestination {
                        EmptyNote(title: "这次训练已提前", detail: "已移到 \(target)，这一天留给恢复；可在我的计划查看。")
                    } else if isPlannedRestDay {
                        EmptyNote(title: "这一天是计划休息日", detail: "恢复已经包含在本周期计划中，不需要再次让 AI 制定计划。身体状态允许时，也可以临时加练。")
                        if ClubDates.calendar.isDateInToday(selectedDate) {
                            Button("提前练下一次训练") { showAdvance = true }.buttonStyle(PrimaryButton())
                        }
                        Button("临时加练 · 从动作库选择") { showLibrary = true }.buttonStyle(SecondaryButton())
                    } else if HistoryVisibility.isEmptyHistoricalDay(selectedDate, log: day) {
                        EmptyNote(title: "这一天没有训练记录", detail: "如果当天练过，可以补记实际完成的动作。")
                        Button("补记") { showLibrary = true }.buttonStyle(SecondaryButton())
                    } else {
                        EmptyNote(title: "这一天还没有训练计划", detail: "先选择动作。记录自重动作时，外加重量可以保留为 0。")
                        Button("从动作库添加") { showLibrary = true }.buttonStyle(PrimaryButton())
                        Button("安排重复计划或使用 AI") { showPlan = true }.buttonStyle(SecondaryButton())
                    }
                }
            }
    }

    @ViewBuilder private var trainingExerciseList: some View {
        ForEach(Array(log.exercises.enumerated()), id: \.element.id) { index, exercise in
                TrainingExerciseCard(
                    exercise: exercise,
                    date: selectedDate,
                    expandedID: $expandedExerciseID,
                    restEnd: $restEnd,
                    onAddNew: { showLibrary = true }
                ).transition(ClubMotion.transition(reduced: reduceMotion))
            }
    }

    @ViewBuilder private var healthLink: some View {
        if log.completedSets > 0 && !isFuture { WorkoutHealthLinkCard(date: selectedDate) }
    }

    @ViewBuilder private var trainingFooter: some View {
        if !log.exercises.isEmpty {
                Button { showLibrary = true } label: { Label("添加动作", systemImage: "plus") }
                    .buttonStyle(SecondaryButton())
                    .buttonBorderShape(.capsule)
            }
    }

    @Environment(\.dynamicTypeSize) private var restTypeSize
    @ViewBuilder private var restDock: some View {
        if let paused = restPausedRemaining {
            VStack(alignment: .leading, spacing: 8) {
                Label("休息已暂停 · 剩余 \(Int(ceil(paused))) 秒", systemImage: "pause.circle").font(.subheadline)
                HStack {
                    restButton("继续", symbol: "play") { restPausedRemaining = nil; restEnd = Date().addingTimeInterval(paused) }
                    restButton("结束休息", symbol: "forward.end") { endRest() }
                }
            }.padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20)).padding(.horizontal, 12)
        } else if let end = restEnd {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = max(0, Int(ceil(end.timeIntervalSince(context.date))))
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(remaining > 0 ? String(format: "%02d:%02d", remaining / 60, remaining % 60) : "休息完成")
                            .font(.title3.monospacedDigit().bold())
                        Text("组间恢复").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    }
                    if restTypeSize.isAccessibilitySize {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) { restActions(end: end, remaining: remaining) }
                    } else { HStack(spacing: 6) { restActions(end: end, remaining: remaining) } }
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .clubGlassEffect(in: RoundedRectangle(cornerRadius: 22))
                .padding(.horizontal, 12).padding(.bottom, 4)
            }
        }
    }
    @ViewBuilder private func restActions(end: Date, remaining: Int) -> some View {
        if remaining > 0 {
            restButton("−15秒", symbol: "minus") { restEnd = max(Date(), end.addingTimeInterval(-15)) }
            restButton("+30秒", symbol: "plus") { restEnd = end.addingTimeInterval(30) }
            restButton("暂停", symbol: "pause") { restPausedRemaining = max(0, end.timeIntervalSinceNow); restEnd = nil }
        }
        restButton("跳过", symbol: "forward.end") { endRest() }
    }
    private func restButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: { BojiHaptics.tick(); action() }) {
            Label(title, systemImage: symbol).labelStyle(.titleAndIcon)
                .font(.caption.weight(.medium)).frame(maxWidth: .infinity, minHeight: 44)
                .fixedSize(horizontal: false, vertical: true)
        }.buttonStyle(ClubActionButtonStyle(kind: .secondary, size: .small))
    }
    private func endRest() {
        restEnd = nil; restPausedRemaining = nil
        ClubRestStorage.savePaused(nil, owner: restOwnerID ?? 0, date: selectedDate, sessionID: day.activeWorkoutSessionID)
    }

    private var futurePlanSaveDock: some View {
        VStack(spacing: 10) {
            Text("\(log.exercises.count) 个动作 · \(log.totalSets) 组计划").bojiFont(.label).foregroundStyle(BojiColor.textSecondary)
            Button("保存训练计划") { if store.saveWorkoutPlan(on:selectedDate) { planFeedback &+= 1 } }
                .buttonStyle(BojiButtonStyle(kind: .primary))
            Text("只保存动作和目标数值，未来日期不能确认完成。")
                .bojiFont(.label).foregroundStyle(BojiColor.textSecondary)
        }
        .padding(.horizontal, ClubUI.pageInset)
        .padding(.top, BojiSpace.general)
        .padding(.bottom, 10)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Rectangle().fill(BojiColor.cardSurface.opacity(0.75)).frame(height: 1) }
    }



}

private struct TrainingExerciseCard: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let exercise: Exercise
    let date: Date
    @Binding var expandedID: UUID?
    @State private var activeSetID: UUID?
    @State private var quickAdjustSetID: UUID?
    @State private var editingSetID: UUID?
    @State private var editingWeight = true
    @State private var showMovementHelp = false
    @State private var completeAfterEdit: UUID?
    @State private var pendingTimerSet: TrainingSet?
    @State private var setError: String?
    @State private var exerciseFeedback = 0
    @State private var weightStep = 2.5
    @State private var completionFeedback = 0
    @State private var autoStartFeedback = 0
    @State private var confirmingExerciseRemoval = false
    @State private var replacingExercise: Exercise?
    @State private var explainCompletedReplacement = false
    @State private var actionError: String?
    private let onAddNew: () -> Void
    @State private var timedSet: TrainingSet?
    @AppStorage("training.rest.seconds") private var restSeconds = 60
    @Binding var restEnd: Date?

    init(exercise: Exercise, date: Date, expandedID: Binding<UUID?>, restEnd: Binding<Date?>, onAddNew: @escaping () -> Void) {
        self.exercise = exercise
        self.date = date
        self._expandedID = expandedID
        self._restEnd = restEnd
        self.onAddNew = onAddNew
    }
    private var expanded: Bool { expandedID == exercise.id }
    private func toggleExpanded() {
        withAnimation(reduceMotion ? nil : BojiMotion.cardExpand(reduceMotion: reduceMotion)) {
            expandedID = expanded ? nil : exercise.id
        }
    }

    private var completed: Int { exercise.sets.filter(\.validCompletion).count }
    private var stepKey: String { "training.weight.step." + (exercise.libraryID ?? exercise.customExerciseID?.uuidString ?? exercise.name) }
    private func previousSet(before index: Int) -> TrainingSet? {
        exercise.sets.prefix(index).last(where: { $0.validCompletion })
    }

    var body: some View {
        Group {
            if expanded { expandedCard } else {
                TrainingCollapsedExerciseCard(
                    exercise: exercise,
                    completed: completed,
                    moreMenu: AnyView(moreMenu),
                    toggle: toggleExpanded
                )
            }
        }
        .sheet(item: $replacingExercise) { original in
            ReplaceWorkoutExerciseView(original: original, date: date) { restEnd = nil }
        }
        .sheet(item: $timedSet) { set in
            TimedTrainingSetView(date: date, exerciseID: exercise.id, original: set) { updated in toggleSet(set, updated: updated) }
        }
        .confirmationDialog("删除这个动作及全部训练组？", isPresented: $confirmingExerciseRemoval, titleVisibility: .visible) {
            Button("删除动作", role: .destructive) {
                if store.removeExercise(exercise.id, on: date) { restEnd = nil }
                else { actionError = store.takeMessage(fallback: "动作未能删除。原记录保留，请重试。") }
            }
            Button("取消", role: .cancel) { }
        }
        // F13：更换动作的提示挂在收起/展开共同父层，收起状态下也能弹出。
        .confirmationDialog("这个动作已经练完", isPresented: $explainCompletedReplacement, titleVisibility: .visible) {
            Button("添加其他动作", action: onAddNew)
            Button("继续查看", role: .cancel) { }
        } message: {
            Text("已完成的组保留在原动作下；如需更换请先取消勾选。")
        }
        .alert("操作未完成", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("知道了", role: .cancel) { actionError = nil }
        } message: {
            Text(actionError ?? "请重试。")
        }
    }

    private var expandedCard: some View {
        VStack(alignment: .leading, spacing: BojiSpace.tightRow) {
            TrainingExerciseHeader(
                exercise: exercise,
                completed: completed,
                expanded: expanded,
                moreMenu: AnyView(moreMenu),
                toggle: toggleExpanded
            )

            suggestionBand

            HStack {
                HStack {
                    ExerciseDemoButton(exercise: exercise)
                    Spacer()
                    Button("问教练", systemImage: "bubble.left") { showMovementHelp = true }.font(.footnote).buttonStyle(.borderless).frame(minHeight: 44)
                }
                Spacer()
            }

            setTable

            if let setError { Text(setError).bojiFont(.secondary).foregroundStyle(.red) }

            Button {
                store.addSet(exerciseID: exercise.id, on: date)
            } label: {
                Label("添加一组", systemImage: "plus")
            }
            .buttonStyle(BojiButtonStyle(kind: .secondary))
        }
        .padding(BojiSpace.workoutCardInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BojiColor.cardSurface, in: RoundedRectangle(cornerRadius: BojiRadius.card, style: .continuous))
        .shadow(color: .black.opacity(0.035), radius: 18, x: 0, y: 5)
        .clubMotion(value: exercise.sets.map(\.id))
        .animation(reduceMotion ? nil : .easeInOut(duration: BojiMotion.stateChange), value: activeSetID)
        .sensoryFeedback(.success, trigger: completionFeedback)
        .clubSuccessFeedback("这个动作已完成", trigger: exerciseFeedback)
        .onAppear {
            let saved = UserDefaults.standard.double(forKey: stepKey)
            weightStep = [0.5, 1, 2.5, 5].contains(saved) ? saved : 2.5
        }
        .onChange(of: weightStep) { _, value in UserDefaults.standard.set(value, forKey: stepKey) }
        .clubSuccessFeedback("已自动开始训练", trigger: autoStartFeedback)
    }

    /// 建议只在有可靠依据时展示；无依据不制造加重建议（F8：≥2 组全部达标才提示，且只给条件性选择）。
    @ViewBuilder private var suggestionBand: some View {
        let completedSets = exercise.sets.filter(\.validCompletion)
        if completedSets.count >= 2, completedSets.count == exercise.sets.count,
           let first = completedSets.first,
           completedSets.allSatisfy({ $0.reps == first.reps && $0.weight == first.weight && $0.durationSeconds == nil }),
           first.reps >= 12, first.weight > 0 {
            let suggested = ((first.weight + weightStep) * 10).rounded() / 10
            TrainingSuggestionBand(
                headline: "本次全部 \(completedSets.count) 组都做到了 \(first.reps) 次",
                detail: "如果动作稳定、仍有余力，下次可以小幅尝试 \(suggested.formatted(.number.precision(.fractionLength(0...1))))kg；是否加重由你判断。"
            )
        }
    }

    private var setTable: some View {
        VStack(spacing: BojiSetTable.rowSpacing) {
            let timed = !exercise.sets.isEmpty && exercise.sets.allSatisfy { $0.durationSeconds != nil }
            let mixed = exercise.sets.contains { $0.durationSeconds != nil } && exercise.sets.contains { $0.durationSeconds == nil }
            HStack(spacing: BojiSpace.tightRow) {
                Text("组").bojiFont(.label).foregroundStyle(BojiColor.textTertiary)
                    .frame(width: BojiSetTable.numberColumn)
                if timed {
                    Text("秒").bojiFont(.label).foregroundStyle(BojiColor.textTertiary).frame(maxWidth: .infinity)
                } else {
                    Text("重量 kg").bojiFont(.label).foregroundStyle(BojiColor.textTertiary).frame(maxWidth: .infinity)
                    Text("次数").bojiFont(.label).foregroundStyle(BojiColor.textTertiary).frame(maxWidth: .infinity)
                }
                Text("完成").bojiFont(.label).foregroundStyle(BojiColor.textTertiary)
                    .frame(width: BojiSetTable.completeColumn)
            }
            ForEach(Array(exercise.sets.enumerated()), id: \.element.id) { index, set in
                TrainingInlineSetRow125(number: index + 1, original: set,
                    active: currentSetID == set.id, plan: ClubDates.isFuture(date),
                    save: { value in toggleSet(set, updated: value) },
                    more: { quickAdjustSetID = nil; editingWeight = true; editingSetID = set.id })
            }
        }
        .sheet(isPresented: $showMovementHelp) { ClubMovementHelp(exercise: exercise, date: date).presentationDetents([.medium, .large]) }
        .sheet(item: Binding(get: {
            editingSetID.flatMap { id in exercise.sets.first(where: { $0.id == id }) }
        }, set: { if $0 == nil { editingSetID = nil } }), onDismiss: {
            // 计时页等编辑面板完全关闭后再呈现，避免同层弹层冲突。
            completeAfterEdit = nil
            if let set = pendingTimerSet { pendingTimerSet = nil; timedSet = set }
        }) { set in
            let setIndex = exercise.sets.firstIndex(where: { $0.id == set.id }) ?? 0
            let previous = previousSet(before: setIndex)
            let history = store.lastCompletedSet(matching: exercise, before: date)
            return TrainingSetEditPanel(
                original: set,
                number: setIndex + 1,
                previous: previous,
                // 沿用上一组仅同计量单位（秒/次不互抄），且当前组未完成。
                canUsePrevious: previous.map { ($0.durationSeconds == nil) == (set.durationSeconds == nil) && !set.completed } ?? false,
                history: history,
                canUseHistory: history.map { ($0.durationSeconds == nil) == (set.durationSeconds == nil) && !set.completed } ?? false,
                weightStep: $weightStep,
                allowTimer: !ClubDates.isFuture(date), isPlanTarget: ClubDates.isFuture(date), completeOnSave: completeAfterEdit == set.id, initialWeight: editingWeight,
                save: { updated in toggleSet(set, updated: updated) },
                startTimer: { completeAfterEdit = nil; pendingTimerSet = $0 },
                performDelete: {
                    store.removeSet(set.id, exerciseID: exercise.id, on: date)
                    if activeSetID == set.id { activeSetID = nil }
                    if editingSetID == set.id { editingSetID = nil }
                }
            )
        }
    }

    /// 当前组：完成一组后自动指向下一组；首屏指向第一组未完成。
    private var currentSetID: UUID? {
        activeSetID ?? exercise.sets.first(where: { !$0.validCompletion })?.id
    }

    private var moreMenu: some View {
        Menu {
            Button {
                if !exercise.sets.isEmpty && exercise.sets.allSatisfy(\.validCompletion) { explainCompletedReplacement = true }
                else { replacingExercise = exercise }
            } label: { Label("更换动作", systemImage: "arrow.triangle.2.circlepath") }
            Menu("更正未完成组的记录单位") {
                Button("按次数记录") { _ = store.setRecordingUnit(exerciseID: exercise.id, on: date, timed: false) }
                Button("按秒记录") { _ = store.setRecordingUnit(exerciseID: exercise.id, on: date, timed: true) }
            }
            if exercise.sets.contains(where: { $0.durationSeconds == nil }) {
                Picker("重量调整步长", selection: $weightStep) { ForEach([0.5, 1, 2.5, 5], id: \.self) { Text("\($0.formatted()) kg").tag($0) } }
            }
            Button(role: .destructive) { confirmingExerciseRemoval = true } label: {
                Label("删除动作", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .foregroundStyle(BojiColor.textSecondary)
                .frame(width: BojiSize.minimumTap, height: BojiSize.minimumTap)
                .contentShape(Circle())
        }
        .accessibilityLabel("动作菜单")
    }

    @discardableResult
    private func toggleSet(_ set: TrainingSet, updated: TrainingSet) -> Bool {
        let autoStarted = updated.validCompletion && !set.validCompletion && Calendar.current.isDateInToday(date) && store.log(for:date).workoutStartedAt == nil
        guard let current = store.log(for: date).trainingLog.exercises.first(where: { $0.id == exercise.id })?.sets.first(where: { $0.id == set.id }),
              current.weight == set.weight, current.reps == set.reps,
              current.durationSeconds == set.durationSeconds, current.completed == set.completed else {
            setError = "这组记录已变化，请重新核对后操作。"; return false
        }
        guard store.updateSet(updated, exerciseID: exercise.id, on: date) else {
            setError = store.takeMessage(fallback: "保存失败，原记录保留，请重试。"); return false
        }
        setError = nil
        if set.completed && !updated.completed { restEnd = nil; activeSetID = set.id }
        if autoStarted && store.log(for: date).workoutStartedAt != nil { autoStartFeedback &+= 1 }
        if updated.completed && !set.completed {
            completionFeedback &+= 1
            let savedSets = store.log(for: date).trainingLog.exercises.first(where: { $0.id == exercise.id })?.sets ?? []
            activeSetID = savedSets.first(where: { !$0.validCompletion })?.id
            if !savedSets.isEmpty && savedSets.allSatisfy(\.validCompletion) { exerciseFeedback &+= 1 }
            let day = store.log(for: date).trainingLog
            let restSeconds = exercise.restSeconds ?? self.restSeconds
            if restSeconds > 0 && day.completedSets < day.totalSets && (Calendar.current.isDateInToday(date) || WorkoutTiming.isOngoing(day,on:date)) {
                restEnd = Date().addingTimeInterval(TimeInterval(restSeconds))
            } else { restEnd = nil }
        }
        return true
    }
}

private struct TimedTrainingSetView: View {
    let date: Date
    let exerciseID: UUID
    let original: TrainingSet
    let save: (TrainingSet) -> Bool
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var stopwatch = WorkoutStopwatch()
    @ObservedObject private var workoutPause = WorkoutPauseService.shared
    @State private var resumeSetAfterPause = false
    @State private var owner: Int?
    @State private var sessionID: UUID?
    @State private var error: String?
    @State private var confirmClose = false
    private var unchanged: Bool {
        guard owner != nil, owner == store.editingAccountID, sessionID == store.log(for: date).activeWorkoutSessionID,
              let current = store.log(for: date).trainingLog.exercises.first(where: { $0.id == exerciseID })?.sets.first(where: { $0.id == original.id }) else { return false }
        return (try? CloudMerge.same(current, original)) == true
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Text("目标 \(original.durationSeconds ?? 0) 秒").bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let elapsed = Int(stopwatch.elapsed(at: context.date))
                    VStack(spacing: 20) {
                        Text("\(elapsed) 秒").font(.system(.largeTitle, design: .rounded, weight: .semibold)).monospacedDigit()
                        Text(elapsed >= (original.durationSeconds ?? 0) && elapsed > 0 ? "已达到目标，结束后核对并登记。" : "只记录实际坚持的时间，暂停期间不计时。")
                            .font(.caption).foregroundStyle(.secondary)
                        Button(stopwatch.isRunning ? "暂停" : elapsed > 0 ? "继续计时" : "开始计时", action: toggleTimer)
                            .buttonStyle(PrimaryButton()).disabled(!unchanged)
                        Button("结束并登记实际秒数", action: registerTimedSet)
                            .buttonStyle(SecondaryButton()).disabled(elapsed < 1 || !unchanged)
                    }
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                Text("计时结束后请点击登记完成").font(.caption2).foregroundStyle(.secondary)
            }.padding(ClubUI.pageInset)
            .navigationTitle("动作计时").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { if stopwatch.elapsed() > 0 { stopwatch.pause(); confirmClose = true } else { dismiss() } } } }
            .interactiveDismissDisabled(stopwatch.elapsed() > 0)
            .confirmationDialog("这次计时尚未登记", isPresented: $confirmClose, titleVisibility: .visible) {
                Button("放弃计时，不标记完成", role: .destructive) { dismiss() }
                Button("继续核对", role: .cancel) { }
            }
            .onAppear { if owner == nil { owner = store.editingAccountID; sessionID = store.log(for: date).activeWorkoutSessionID } }
            .onChange(of: store.editingAccountID) { _, id in if id != owner { dismiss() } }
            .onChange(of: workoutPause.state?.isPaused) { _, paused in
                guard workoutPause.state?.sessionID == sessionID else { return }
                if paused == true { resumeSetAfterPause = stopwatch.isRunning; stopwatch.pause() }
                else if resumeSetAfterPause { resumeSetAfterPause = false; stopwatch.start() }
            }
        }
    }

    private func toggleTimer() {
        guard unchanged, !ClubDates.isFuture(date) else { error = "账号、日期或训练组已变化，请重新打开。"; return }
        guard workoutPause.state?.isPaused != true else { error = "请先继续本次训练，再开始动作计时。"; return }
        error = nil
        if stopwatch.isRunning { stopwatch.pause(); return }
        let day = store.log(for: date).trainingLog
        if day.workoutStartedAt == nil && day.completedSets == 0 && ClubDates.calendar.isDateInToday(date) {
            guard store.beginWorkout(on: date) else {
                error = store.takeMessage(fallback: "训练开始时间未保存，请重试。"); return
            }
            // This synchronous mutation can assign the first session ID.
            sessionID = store.log(for: date).activeWorkoutSessionID
        }
        guard unchanged else { error = "这组记录已变化，请关闭后重新核对。"; return }
        stopwatch.start()
    }

    private func registerTimedSet() {
        guard unchanged else { error = "这组记录已变化，计时不会覆盖它，请重新打开核对。"; return }
        stopwatch.pause()
        guard stopwatch.elapsed() >= 1 else { error = "请记录至少 1 秒的实际完成时间。"; return }
        guard stopwatch.elapsed() <= Double(RecordLimits.maximumSeconds) else {
            error = "单组最多登记 6 小时。这次计时已暂停，不会缩短后保存，请核对后分段记录。"; return
        }
        var updated = original
        updated.durationSeconds = max(1, Int(stopwatch.elapsed())); updated.reps = 0; updated.completed = true; updated.actualEntered = true
        if save(updated) { dismiss() } else { error = store.takeMessage(fallback: "保存失败，计时已暂停，可以重试。") }
    }
}



#if DEBUG
struct ExerciseDetailView: View {
    let guide: ExerciseGuide
    let add: () -> Bool
    @EnvironmentObject private var store: AppStore
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(guide.muscle, systemImage: "figure.strengthtraining.traditional")
                    Label(guide.equipment, systemImage: "dumbbell")
                }
                Section("动作要领") {
                    ForEach(Array(guide.steps.enumerated()), id: \.offset) { index, step in Text("\(index + 1). \(step)") }
                }
                Section { Button("加入所选日期的训练计划") { if add() { dismiss() } else { error = store.takeMessage(fallback: "保存失败，请重试。") } }.buttonStyle(PrimaryButton()) }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }.clubListSurface()
            .navigationTitle(guide.name).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        }
    }
}
#endif


private struct ReplaceWorkoutExerciseView: View {
    let original: Exercise
    let date: Date
    let replaced: () -> Void
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var selected: LibraryExercise?
    @State private var confirming = false
    @State private var owner: Int?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("更换：\(original.displayName)").bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
                    Text("仅替换未完成的组，已完成组保留在原动作下。")
                        .font(.caption).foregroundStyle(.secondary)
                    if let error { Text(error).font(.caption).foregroundStyle(.red) }
                    ExerciseLibraryView(date: date, selectionAction: { item in
                        selected = item; confirming = true
                    }, initialQuery: original.muscle, embedded: true) { }
                }.padding(ClubUI.pageInset)
            }
            .background { ClubBackground() }
            .navigationTitle("更换动作").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            .onAppear { if owner == nil { owner = store.editingAccountID } }
            .confirmationDialog("确认更换动作？", isPresented: $confirming, titleVisibility: .visible, presenting: selected) { item in
                Button("更换为\(item.displayName)") {
                    guard owner != nil, owner == store.editingAccountID else { error = "账号已变化，请重新打开。"; return }
                    if store.replaceExercise(original, with: item, on: date) { replaced(); dismiss() }
                    else { error = store.takeMessage(fallback: "更换未保存，请重试。"); store.message = nil }
                }
                Button("取消", role: .cancel) { }
            } message: { _ in Text("已完成训练保留；未来日期的计划不会因此改变。") }
        }
    }
}


struct WorkoutCompletionSnapshot: Identifiable {
    let id = UUID()
    let ownerID: Int
    let date: Date
    let sessionID: UUID?
}

struct WorkoutCompletionView: View {
    let snapshot: WorkoutCompletionSnapshot
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var health: HealthDataService
    @Environment(\.dismiss) private var dismiss
    @State private var healthRequest: HealthShareReviewRequest?
    @State private var matchingHealth: HealthShareReviewRequest?
    @State private var lookingForHealth = true
    @State private var showMeal = false
    @State private var showWeight = false
    @State private var confirmHealthExport = false
    @State private var exportingWorkout = false
    @State private var healthExportMessage: String?
    private var day: DayLog { store.log(for: snapshot.date) }
    private var training: DayLog { day.trainingLog }
    private var validOwner: Bool { store.editingAccountID == snapshot.ownerID && day.activeWorkoutSessionID == snapshot.sessionID }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    completionHeading
                    if let saved = completedSnapshot {
                        Button("AI 复盘本次训练", systemImage: "bubble.left.and.text.bubble.right") {
                            ClubAIEntryContext.open(owner: snapshot.ownerID, date: snapshot.date, sessionID: saved.sessionID)
                        }.buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.regular)
                            .tint(ClubBrand.accent).frame(maxWidth: .infinity).frame(minHeight: 44)
                            .accessibilityIdentifier("workout-ai-review")
                    }
                    healthActions
                    completionSummary
                    Button("完成") { dismiss() }.buttonStyle(SecondaryButton())
                    DisclosureGroup("补记与更多") {
                        VStack(alignment: .leading, spacing: 16) {
                            dailyRecordCard
                            Button("在 Club AI 解读这一天") { if let owner = store.editingAccountID { let scope = ClubReviewScope.make(.daily, through: snapshot.date); ClubAIRoute.open(owner: owner, question: scope.prompt, scope: scope) } }
                        }
                        .padding(.top, BojiSpace.general)
                    }
                    .font(.subheadline.weight(.medium))
                    .tint(BojiColor.textSecondary)
                }.padding(ClubUI.pageInset).frame(maxWidth: ClubUI.contentWidth).frame(maxWidth: .infinity)
            }.background { ClubBackground() }
                .navigationTitle("训练完成").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                .sheet(item: $healthRequest) { HealthShareReviewView(request: $0, onSaved: { matchingHealth = nil }) }
                .sheet(isPresented: $showMeal) { MealEditorView(date: snapshot.date) }
                .sheet(isPresented: $showWeight) { WeightEntryEditor(date: snapshot.date) }
                .task {
                    lookingForHealth = true
                    defer { lookingForHealth = false }
                    guard validOwner, health.enabled, training.linkedDeviceWorkoutID == nil else { return }
                    await health.refresh(snapshot.date)
                    guard !Task.isCancelled, validOwner, let summary = health.summary(for: snapshot.date) ?? day.health else { return }
                    if !WorkoutAssociation.suggestedIDs(for: day, workouts: summary.workouts).isEmpty {
                        matchingHealth = HealthShareReviewRequest(ownerID: snapshot.ownerID, date: snapshot.date, summary: summary, day: day, allowsLink: true)
                    }
                }
                .onChange(of: store.editingAccountID) { _, _ in if !validOwner { dismiss() } }
                .onChange(of: day.activeWorkoutSessionID) { _, _ in if !validOwner { dismiss() } }
                .onChange(of: training.linkedDeviceWorkoutID) { _, value in
                    if value != nil { matchingHealth = nil }
                }
        }
    }

    private var completedSnapshot: ConfirmedWorkoutSnapshot? {
        guard let id = snapshot.sessionID ?? ClubWorkoutSummaryRules.available(state: store.state, date: snapshot.date).last else { return nil }
        return .make(owner: snapshot.ownerID, date: snapshot.date, sessionID: id, day: day)
    }
    @ViewBuilder private var completionHeading: some View {
        let saved = completedSnapshot
        WorkoutCelebration125(facts: WorkoutFacts125(training),
            duration: saved?.activeDuration.map(WorkoutTiming.durationLabel) ?? "未记录")
        Text(ClubDates.label(snapshot.date) + " · " + store.syncStatus.label)
            .font(.caption).foregroundStyle(.secondary)
    }
    @ViewBuilder private var completionSummary: some View {
        if let saved = completedSnapshot {
            WorkoutCharts125(facts: WorkoutFacts125(training))
            NavigationLink("本次训练记录") { ClubWorkoutSummaryView(date: snapshot.date, sessionID: saved.sessionID) }
                .font(.subheadline).frame(minHeight:44)
        }
    }
    @ViewBuilder private var healthActions: some View {
        if let id = completedSnapshot?.sessionID {
            ClubCard {
                if lookingForHealth { Label("正在核对手表与设备记录…", systemImage: "clock").font(.subheadline) }
                else if let matchingHealth {
                    Text("找到可能对应的手表记录").font(.headline)
                    Button("核对并关联这次记录") { healthRequest = matchingHealth }.buttonStyle(PrimaryButton())
                    Text("先核对同一场记录，避免重复写入 Apple 健康。").font(.caption).foregroundStyle(.secondary)
                }
                if !lookingForHealth && matchingHealth == nil {
                    WorkoutHealthSyncCard(date: snapshot.date, sessionID: id, ownerID: snapshot.ownerID)
                }
            }
        }
    }

    @ViewBuilder private var dailyRecordCard: some View {
        ClubCard {
            Text(ClubDates.calendar.isDateInToday(snapshot.date) ? "今天的记录" : "这一天的记录")
                .bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
            Text("当天已完成 \(day.completedSets) 组训练，记录 \(day.meals.count) 餐。").font(.subheadline).foregroundStyle(.secondary)
            Button("记录饮食", systemImage: "fork.knife") { showMeal = true }.buttonStyle(SecondaryButton())
            if day.bodyWeight?.kilograms == nil {
                Button(ClubDates.calendar.isDateInToday(snapshot.date) ? "今天称过体重？登记一下" : "补记这一天实际称过的体重", systemImage: "scalemass") { showWeight = true }.buttonStyle(SecondaryButton())
            }
        }
    }

}


struct AdvanceWorkoutView: View {
    let date: Date
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var owner: Int?
    @State private var selection: Date?
    @State private var sourceSnapshot: DayLog?
    @State private var destinationSnapshot: DayLog?
    @State private var confirming = false
    @State private var busy = false
    @State private var error: String?
    private var candidates: [Date] {
        store.state.days.keys.compactMap(ClubDates.date).filter { value in
            let day = store.log(for: value)
            return ClubDates.isFuture(value) && !day.exercises.isEmpty && !WorkoutEditing.isProtected(day)
        }.sorted()
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("把下一次训练提前到今天").bojiFont(.pageTitle).foregroundStyle(BojiColor.textPrimary)
                    Text("预览并确认将后续训练移至今天，原日期会自动改为休息日。")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if candidates.isEmpty { EmptyNote(title: "没有可提前的安排", detail: "后续没有尚未开始的训练。可以关闭后从动作库临时加练。") }
                    ForEach(candidates, id: \.self) { sourceDate in
                        candidateCard(sourceDate)
                    }
                    if busy { ClubLoadingCard(title: "正在核对最新记录…", detail: "先同步其他设备的改动，再确认移动。原安排与当前记录会保留。") }
                    if let error { Text(error).font(.subheadline).foregroundStyle(.secondary) }
                }.padding(ClubUI.pageInset)
            }.background { ClubBackground() }.navigationTitle("提前训练").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() }.disabled(busy) } }
                .interactiveDismissDisabled(busy)
                .onAppear { owner = store.editingAccountID }
                .onChange(of: store.editingAccountID) { _, current in if current != owner { dismiss() } }
                .alert("确认提前这次训练？", isPresented: $confirming) {
                    Button("确认，移到今天") { move() }
                    Button("取消", role: .cancel) { }
                } message: {
                    Text(destinationSnapshot?.exercises.isEmpty == false ? "今天已有的训练会保留，提前的内容作为独立一次训练加入；原日期转为恢复。" : "整次训练移到今天，原日期转为恢复。请确认今天准备执行这份安排。")
                }
        }
    }
    private func candidateCard(_ sourceDate: Date) -> some View {
        let source = store.log(for: sourceDate)
        return ClubCard {
            Text(ClubDates.label(sourceDate, format: "M月d日 EEEE")).bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
            Text(source.exercises.map { "\($0.displayName) · \($0.sets.count) 组" }.joined(separator: "\n"))
                .font(.subheadline).lineSpacing(4)
            Button("预览完成，提前这次训练") {
                selection = sourceDate; sourceSnapshot = source; destinationSnapshot = store.log(for: date)
                error = nil; confirming = true
            }.buttonStyle(SecondaryButton()).disabled(busy)
        }
    }
    private func move() {
        guard !busy, let owner, owner == store.editingAccountID, let selection, let sourceSnapshot, let destinationSnapshot else { return }
        busy = true; error = nil
        Task {
            defer { busy = false }
            let synchronized = await store.syncForPlanAdoption(ownerID: owner)
            guard owner == store.editingAccountID, !Task.isCancelled else { return }
            guard synchronized else { error = store.takeMessage(fallback: "记录尚未同步完成，请稍后确认提前训练；原安排已保留。"); return }
            if store.advancePlannedWorkout(from: selection, to: date, expectedSource: sourceSnapshot,
                                           expectedDestination: destinationSnapshot, asSeparateSession: !destinationSnapshot.exercises.isEmpty) {
                dismiss()
            } else { error = store.takeMessage(fallback: "安排已变化，请重新预览。") }
        }
    }
}

#if DEBUG
enum WorkoutAuditFactory {
 static func replace(date: Date, exercise: Exercise) -> some View { ReplaceWorkoutExerciseView(original: exercise, date: date, replaced: {}) }
 static func timer(date: Date, exercise: Exercise) -> some View { TimedTrainingSetView(date: date, exerciseID: exercise.id, original: TrainingSet(durationSeconds: 30), save: { _ in true }) }
}
#endif
