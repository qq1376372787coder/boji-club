import SwiftUI

// 计划页组件（任务书 4.3）：淡蓝灰日程卡＋计划封面卡。
// 日期语义必须分开表达：已完成、当天有安排、未来安排、休息日、无计划。

// MARK: - 日程卡

enum PlanDayState: Equatable {
    case completed          // 已完成
    case todayPending       // 今天有待练
    case futurePlanned      // 未来安排
    case pastMissed         // 过去有安排、未见完成记录
    case restDay            // 计划休息日
    case moved(destination: String)
    case none               // 无计划
}

/// 计划日历的纯规则：今天居中的 7 天窗口、周一开头的月网格、周/月切换。
enum PlanCalendarRules {
    static func window(centeredOn date: Date) -> [Date] {
        CalendarWindow.dates(centeredOn: date)
    }
    static func monthAnchor(_ date: Date) -> Date {
        let calendar = ClubDates.calendar
        return calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
    }
    static func shiftWeeks(_ date: Date, by weeks: Int) -> Date {
        ClubDates.calendar.date(byAdding: .day, value: weeks * 7, to: date) ?? date
    }
    static func shiftMonth(_ date: Date, by months: Int) -> Date {
        ClubDates.calendar.date(byAdding: .month, value: months, to: monthAnchor(date)) ?? date
    }
    static func contains(_ window: [Date], _ date: Date) -> Bool {
        window.contains { ClubDates.calendar.isDate($0, inSameDayAs: date) }
    }
    /// 周一开头、补齐前后空位的月网格；nil 表示空位。
    static func monthCells(anchor: Date) -> [Date?] {
        let calendar = ClubDates.calendar
        let start = monthAnchor(anchor)
        guard let range = calendar.range(of: .day, in: .month, for: start) else { return [] }
        let weekday = calendar.component(.weekday, from: start)
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        var cells: [Date?] = Array(repeating: nil, count: leading)
        for day in range {
            cells.append(calendar.date(byAdding: .day, value: day - 1, to: start))
        }
        while cells.count % 7 != 0 { cells.append(nil) }
        return cells
    }
    static func monthLabel(_ anchor: Date) -> String {
        ClubDates.label(anchor, format: "yyyy年M月")
    }
}

/// F10：周条/日期摘要共用同一套日期状态，语义不再各说各话。
enum PlanDayStatus {
    static func resolve(date: Date, state: SavedState) -> PlanDayState {
        let key = ClubDates.key(date)
        let log = state.days[key]
        let isFuture = ClubDates.isFuture(date)
        let isToday = ClubDates.calendar.isDateInToday(date)
        if let log {
            if let destination = log.plannedMoveDestination {
                return .moved(destination: destination)
            }
            // A day can have several sessions. One confirmed session must not be
            // hidden because another same-day session is still unconfirmed.
            if isToday && (log.hasUnconfirmedTraining || (log.trainingLog.workoutStartedAt != nil && log.trainingLog.workoutSavedAt == nil)) { return .todayPending }
            if log.hasConfirmedTraining { return .completed }
            if !log.exercises.isEmpty {
                if isFuture { return .futurePlanned }
                return isToday ? .todayPending : .pastMissed
            }
            if let cycle = log.planCycle, cycle.dates.contains(key), !cycle.plannedDates.contains(key) {
                return .restDay
            }
        }
        return .none
    }
}

struct PlanWeekCard: View {
    @Binding var selectedDate: Date
    @EnvironmentObject private var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var localShowingMonth: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.environment["BOJI_PREVIEW_PLAN_EXPANDED"] == "1"
        #else
        return false
        #endif
    }()
    var monthExpanded: Binding<Bool>? = nil
    private var showingMonth: Bool {
        get { monthExpanded?.wrappedValue ?? localShowingMonth }
        nonmutating set {
            if let monthExpanded { monthExpanded.wrappedValue = newValue }
            else { localShowingMonth = newValue }
        }
    }
    @State private var centerDate = Date()
    @State private var displayedMonth = Date()
    @State private var loaded = false
    var cycleTitle: String? = nil
    var cycleDetail: String? = nil
    var openPlan: (() -> Void)? = nil

    private var window: [Date] { PlanCalendarRules.window(centeredOn: centerDate) }
    private var animation: Animation? { reduceMotion ? .easeOut(duration: 0.12) : BojiMotion.cardExpand(reduceMotion: false) }

    var body: some View {
        VStack(alignment: .leading, spacing: BojiSpace.tight) {
            VStack(alignment: .leading, spacing: 4) {
                header
                Text(headerSubtitle)
                    .bojiFont(.label).foregroundStyle(BojiColor.textSecondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)
                    .minimumScaleFactor(0.82)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Group {
                if showingMonth { monthGrid } else { weekStrip }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            if !showingMonth, !PlanCalendarRules.contains(window, selectedDate) {
                Button("已选 \(ClubDates.label(selectedDate, format: "M月d日")) · 回到所选日期") {
                    withAnimation(animation) { centerDate = selectedDate }
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(BojiColor.textSecondary)
            }
            if showingMonth, !ClubDates.calendar.isDate(displayedMonth, equalTo: selectedDate, toGranularity: .month) {
                Button("回到所选月份") {
                    withAnimation(animation) {
                        displayedMonth = selectedDate
                        centerDate = selectedDate
                    }
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(BojiColor.textSecondary)
            }
        }
        .padding(BojiSpace.cardInset)
        .background(BojiColor.calendarSurface, in: RoundedRectangle(cornerRadius: BojiRadius.card, style: .continuous))
        .onAppear {
            guard !loaded else { return }
            loaded = true
            centerDate = selectedDate
            displayedMonth = selectedDate
        }
        .onChange(of: selectedDate) { _, date in
            if showingMonth {
                if !ClubDates.calendar.isDate(displayedMonth, equalTo: date, toGranularity: .month) { displayedMonth = date }
            } else if !PlanCalendarRules.contains(window, date) {
                centerDate = date
            }
        }
    }

    private var header: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    headerTitle
                    HStack(spacing: BojiSpace.tightRow) {
                        if let openPlan {
                            Button("查看计划", action: openPlan)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(BojiColor.textPrimary)
                                .lineLimit(1).fixedSize()
                        }
                        Spacer(minLength: 4)
                        headerButtons
                    }
                }
            } else {
                HStack(spacing: BojiSpace.tightRow) {
                    headerTitle
                    Spacer(minLength: 4)
                    if let openPlan {
                        Button("查看计划", action: openPlan)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(BojiColor.textPrimary)
                    }
                    headerButtons
                }
            }
        }
    }

    private var headerSubtitle: String {
        cycleDetail ?? PlanCalendarRules.monthLabel(showingMonth ? displayedMonth : centerDate)
    }

    private var headerTitle: some View {
        Text(cycleTitle ?? (showingMonth ? PlanCalendarRules.monthLabel(displayedMonth) : "本周"))
            .bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var headerButtons: some View {
        HStack(spacing: BojiSpace.tightRow) {
            Button("今天") { withAnimation(animation) { selectedDate = Date(); centerDate = selectedDate; displayedMonth = selectedDate } }.font(.subheadline.weight(.medium)).accessibilityIdentifier("plan-return-today130")
            circleButton("chevron.left") {
                withAnimation(animation) {
                    if showingMonth { displayedMonth = PlanCalendarRules.shiftMonth(displayedMonth, by: -1) }
                    else { centerDate = PlanCalendarRules.shiftWeeks(centerDate, by: -1) }
                }
            }
            circleButton("chevron.right") {
                withAnimation(animation) {
                    if showingMonth { displayedMonth = PlanCalendarRules.shiftMonth(displayedMonth, by: 1) }
                    else { centerDate = PlanCalendarRules.shiftWeeks(centerDate, by: 1) }
                }
            }
            circleButton(showingMonth ? "chevron.up" : "calendar") {
                withAnimation(animation) {
                    showingMonth.toggle()
                    if showingMonth { displayedMonth = selectedDate }
                }
            }
        }
    }

    private var weekStrip: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                // AUD-019：辅助字号改为可横向滚动的日期条，日期与状态不再硬挤 7 列。
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(window, id: \.self) { date in
                            dayCell(date).frame(minWidth: 62)
                        }
                    }
                }
            } else {
                HStack(spacing: 6) {
                    ForEach(window, id: \.self) { date in dayCell(date) }
                }
            }
        }
    }

    private var monthGrid: some View {
        let cells = PlanCalendarRules.monthCells(anchor: displayedMonth)
        return Group {
            if dynamicTypeSize.isAccessibilitySize {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(Array(cells.enumerated()), id: \.offset) { _, date in
                            if let date {
                                VStack(spacing: 4) {
                                    Text(weekdayLabel(date))
                                        .font(.caption2).foregroundStyle(BojiColor.textTertiary)
                                    dayCell(date).frame(minWidth: 62)
                                }
                            }
                        }
                    }
                }
            } else {
                VStack(spacing: 6) {
                    HStack(spacing: 6) {
                        ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) { label in
                            Text(label).font(.caption2).foregroundStyle(BojiColor.textTertiary)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
                        ForEach(Array(cells.enumerated()), id: \.offset) { _, date in
                            if let date { dayCell(date) } else { Color.clear.frame(height: 40) }
                        }
                    }
                }
            }
        }
    }

    private func weekdayLabel(_ date: Date) -> String {
        let weekday = ClubDates.calendar.component(.weekday, from: date)
        let labels = ["日", "一", "二", "三", "四", "五", "六"]
        return labels[max(0, min(6, weekday - 1))]
    }

    private func dayCell(_ date: Date) -> some View {
        let state = state(for: date)
        let isToday = ClubDates.calendar.isDateInToday(date)
        let isSelected = ClubDates.calendar.isDate(date, inSameDayAs: selectedDate)
        return Button {
            withAnimation(animation) {
                selectedDate = date
                centerDate = date
                if showingMonth { displayedMonth = date }
            }
        } label: {
            VStack(spacing: 3) {
                ZStack {
                    Capsule()
                        .fill(isSelected ? BojiColor.textPrimary : BojiColor.cardSurface.opacity(isToday ? 1 : 0.55))
                        .frame(width: dynamicTypeSize.isAccessibilitySize ? 52 : 40,
                               height: dynamicTypeSize.isAccessibilitySize ? 44 : 28)
                    if state == .completed {
                        Image(systemName: "checkmark")
                            .font(.footnote.weight(.bold))
                            .foregroundStyle(isSelected ? BojiColor.pageBackground : BojiColor.textPrimary)
                    } else {
                        Text("\(ClubDates.calendar.component(.day, from: date))")
                            .bojiFont(.label, monospacedDigits: true)
                            .lineLimit(1).minimumScaleFactor(0.65)
                            .foregroundStyle(isSelected ? BojiColor.pageBackground : BojiColor.textPrimary)
                    }
                }
                .overlay {
                    if isToday && !isSelected {
                        Capsule().stroke(BojiColor.textPrimary, lineWidth: 1.5)
                    }
                }
                Text(dayHint(state, date: date))
                    .font(.caption2)
                    .foregroundStyle(BojiColor.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(BojiRowPressStylePublic())
        .accessibilityLabel(accessibilityLabel(state, date: date))
    }

    private func dayHint(_ state: PlanDayState, date: Date) -> String {
        switch state {
        case .completed: "已完成"
        case .todayPending: "待练"
        case .futurePlanned: "安排"
        case .pastMissed: "未见记录"
        case .restDay: "休息"
        case .moved(let destination): "移至 " + (ClubDates.date(fromKey: destination).map { ClubDates.label($0, format: "M月d日") } ?? destination)
        case .none: ClubDates.calendar.isDateInToday(date) ? "今天" : " "
        }
    }

    private func accessibilityLabel(_ state: PlanDayState, date: Date) -> String {
        let day = ClubDates.label(date, format: "M月d日")
        switch state {
        case .completed: return "\(day)，训练已完成"
        case .todayPending: return "\(day)，今天有待练安排"
        case .futurePlanned: return "\(day)，已有训练安排"
        case .pastMissed: return "\(day)，有安排但没有完成记录"
        case .restDay: return "\(day)，计划休息日"
        case .moved(let destination): return "\(day)，安排已移至 \(destination)"
        case .none: return "\(day)，没有安排"
        }
    }

    func state(for date: Date) -> PlanDayState {
        PlanDayStatus.resolve(date: date, state: store.state)
    }

    private func circleButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
        }
        .buttonStyle(BojiCircleButtonStyle(visualDiameter: 36))
        .accessibilityLabel(symbol == "chevron.left" ? "上一页" : symbol == "chevron.right" ? "下一页" : showingMonth ? "收起月历" : "展开月历")
        .accessibilityIdentifier(symbol == "chevron.left" ? "plan-calendar-prev" : symbol == "chevron.right" ? "plan-calendar-next" : "plan-calendar-toggle")
    }
}

// MARK: - 所选日期摘要

struct PlanDaySummaryCard: View {
    let date: Date
    let openWorkout: () -> Void
    var onMove: () -> Void = {}
    var onRest: () -> Void = {}
    var onAdvance: () -> Void = {}
    var openPlan: () -> Void = {}
    var selectDate: (Date) -> Void = { _ in }
    @EnvironmentObject private var store: AppStore

    private var day: DayLog { store.log(for: date) }
    private var state: PlanDayState { PlanDayStatus.resolve(date: date, state: store.state) }
    private var canEditRest: Bool {
        !day.exercises.isEmpty && ClubDates.key(date) >= ClubDates.key(Date())
            && !PlanAdoptionRules.isProtected(day) && !day.hasUnconfirmedTraining
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BojiSpace.general) {
            Text(ClubDates.label(date, format: "M月d日 EEEE") + (ClubDates.calendar.isDateInToday(date) ? " · 今天" : ""))
                .bojiFont(.label)
                .foregroundStyle(BojiColor.textSecondary)

            switch state {
            case .moved(let destination):
                Text("安排已移至 " + (ClubDates.date(fromKey: destination).map { ClubDates.label($0, format: "M月d日") } ?? destination))
                    .bojiFont(.body).foregroundStyle(BojiColor.textPrimary)
                if let target = ClubDates.date(fromKey: destination) {
                    Button("查看去向") { selectDate(target) }.buttonStyle(BojiButtonStyle(kind: .secondary))
                }
            case .restDay:
                Text("计划休息日 · 恢复已经包含在计划中").bojiFont(.body)
                actionButtons(primary: ("提前练其他安排", onAdvance), secondary: ("自由加练", openWorkout))
            case .completed:
                exerciseList
                actionButtons(primary: ("查看本次训练", openWorkout), secondary: nil)
            case .todayPending:
                exerciseList
                actionButtons(primary: (day.hasUnconfirmedTraining && day.trainingLog.workoutEndedAt != nil ? "保存修改" : day.trainingLog.workoutStartedAt != nil ? "继续训练" : "开始训练", openWorkout), secondary: ("调整安排", onMove))
            case .futurePlanned:
                exerciseList
                actionButtons(primary: ("编辑当天安排", openWorkout), secondary: ("调整安排", onMove))
            case .pastMissed:
                exerciseList
                actionButtons(primary: ("补记", openWorkout), secondary: nil)
            case .none:
                Text("这一天没有动作安排").bojiFont(.body).foregroundStyle(BojiColor.textPrimary)
                actionButtons(primary: ("安排训练", openPlan), secondary: nil)
            }

        }
        .bojiCard()
    }

    @ViewBuilder private var exerciseList: some View {
        if !day.exercises.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(day.exercises.prefix(4)) { exercise in
                    HStack(spacing: 8) {
                        let actual = exercise.sets.filter(\.validCompletion).count
                        let complete = !exercise.sets.isEmpty && actual == exercise.sets.count
                        Image(systemName: complete ? "checkmark.circle.fill" : actual > 0 ? "circle.lefthalf.filled" : "circle")
                            .foregroundStyle(complete ? ClubBrand.accent : BojiColor.textTertiary)
                        Text(exercise.displayName).bojiFont(.body).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Text(ClubDates.isFuture(date) ? "计划 \(exercise.sets.count) 组" : "已登记 \(actual)/\(exercise.sets.count) 组").bojiFont(.label, monospacedDigits: true)
                            .foregroundStyle(BojiColor.textSecondary)
                    }
                }
                if day.exercises.count > 4 {
                    Text("还有 \(day.exercises.count - 4) 个动作").bojiFont(.label)
                        .foregroundStyle(BojiColor.textSecondary)
                }
            }
        }
    }

    private func actionButtons(primary: (String, () -> Void), secondary: (String, () -> Void)?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(primary.0, action: primary.1).buttonStyle(BojiButtonStyle(kind: .primary))
            if let secondary {
                BojiAdaptiveGroup {
                    Button(secondary.0, action: secondary.1)
                        .frame(maxWidth: .infinity, minHeight: 44)
                    if canEditRest {
                        Button("设为休息日", action: onRest)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                }.font(.subheadline.weight(.medium)).buttonStyle(.plain).foregroundStyle(BojiColor.textSecondary)
            }
        }
    }
}
