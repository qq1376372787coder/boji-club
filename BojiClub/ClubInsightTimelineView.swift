import SwiftUI

extension ClubInsightKind {
    var label: String {
        switch self {
        case .training: return "训练洞察"
        case .nutrition: return "营养反馈"
        case .body: return "身体动态"
        case .workout: return "完成小结"
        case .plan: return "日程跟进"
        default: return "分析"
        }
    }
    var symbol: String {
        switch self {
        case .training: return "dumbbell.fill"
        case .nutrition: return "fork.knife"
        case .body: return "scalemass.fill"
        case .workout: return "checkmark.seal.fill"
        case .plan: return "calendar.badge.clock"
        default: return "sparkles"
        }
    }
    var accentColor: Color {
        switch self {
        case .training: return BojiColor.timerAccent
        case .workout: return Color.green
        case .nutrition: return Color.orange
        case .body: return BojiColor.aiViolet
        case .plan: return Color.teal
        default: return BojiColor.aiGold
        }
    }
}

#if DEBUG
/// 核心依据展示组件（保留兼容签名并优化为高质感无嵌套卡片）
struct ClubEvidenceDisclosure: View {
    let evidence: String
    var recordDate: String? = nil
    var observedAt: Date? = nil
    var display: ClubInsightDisplayState = .current
    var body: some View {
        ClubEvidenceBox(evidence: evidence, recordDate: recordDate, observedAt: observedAt, display: display)
    }
}
#endif

/// 高亮内联分析依据卡片（无深层嵌套折叠，关键依据直接透出）
struct ClubEvidenceBox: View {
    let evidence: String
    var recordDate: String? = nil
    var observedAt: Date? = nil
    var display: ClubInsightDisplayState = .current

    var body: some View {
        VStack(alignment: .leading, spacing: BojiLayout.tight) {
            HStack(spacing: BojiLayout.tight) {
                Image(systemName: "chart.bar.doc.horizontal")
                    .bojiType(.caption)
                    .foregroundStyle(BojiColor.aiGold)
                Text("核心依据")
                    .bojiType(.caption)
                    .foregroundStyle(BojiColor.textTertiary)
                Spacer()
                if let recordDate {
                    Text("记录于 \(recordDate)")
                        .bojiType(.caption)
                        .foregroundStyle(BojiColor.textTertiary)
                }
            }
            Text(evidence)
                .bojiType(.caption)
                .foregroundStyle(BojiColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if display != .current {
                Text(display == .updated ? "依据已发生变化，以最新记录为准。" : display == .withdrawn ? "这条跟进已撤回。" : display == .expired ? "此项当日提醒已结束。" : "当前版本无法核对这条依据。")
                    .bojiType(.caption)
                    .foregroundStyle(Color.orange)
                    
            }
        }
        .padding(BojiLayout.inline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BojiColor.subtleSurface, in: RoundedRectangle(cornerRadius: BojiRadius.inner, style: .continuous))
    }
}

/// 重构后的高质感单卡片：突出教练体感、行动闭环与直通教练追问
struct ClubInsightMessageView: View {
    let event: ClubInsightEvent
    let ownerID: Int?
    @EnvironmentObject private var store: AppStore
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var error: String?
    @State private var feedbackCount = 0
    @State private var destination: ClubInsightOpen?
    @State private var showCoachChat = false
    @State private var coachPrompt = ""
    @State private var detailExpanded = false

    private var display: ClubInsightDisplayState { ClubInsightLedger.displayState(event, in: store.state) }
    private var helpful: Bool {
        ClubInsightLedger.feedback(in: store.state).contains { $0.eventID == event.id && $0.action == .helpful }
    }
    private var isRead: Bool { ClubInsightLedger.isRead(event, in: store.state) }
    private var isArchived: Bool { ClubInsightLedger.isArchived(event, in: store.state) }

    var body: some View {
        VStack(alignment: .leading, spacing: BojiLayout.rowGap) {
            // 顶部：分类徽章 + 自然时间 + 状态药丸
            BojiAdaptiveGroup(spacing: BojiLayout.inline) {
                HStack(spacing: BojiLayout.tight) {
                    Image(systemName: event.kind.symbol).bojiType(.caption)
                    Text(event.kind.label).bojiType(.caption)
                }
                .padding(.horizontal, BojiSpace.tightRow)
                .padding(.vertical, BojiLayout.tight)
                .background(event.kind.accentColor.opacity(0.12), in: Capsule())
                .foregroundStyle(event.kind.accentColor)

                Text(ClubDates.label(event.recordedAt, format: "M月d日 HH:mm"))
                    .bojiType(.caption)
                    .foregroundStyle(BojiColor.textTertiary)

                if display == .updated {
                    Text("已按新记录更新")
                        .bojiType(.caption)
                        .foregroundStyle(Color.orange)
                        .padding(.horizontal, BojiSpace.tight)
                        
                        .background(Color.orange.opacity(0.1), in: Capsule())
                }

                Spacer()

                if ownerID != nil && event.version == 1 && event.kind.supported && event.state.supported {
                    feedbackMenu
                }
            }

            // 标题与教练正文
            Text(event.title)
                .bojiType(.section)
                .foregroundStyle(BojiColor.textPrimary)

            Text(event.detail)
                .bojiType(.secondary)
                .foregroundStyle(BojiColor.textSecondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(detailExpanded || typeSize.isAccessibilitySize ? nil : 6)

            if event.detail.count > 90 && !typeSize.isAccessibilitySize {
                Button(detailExpanded ? "收起" : "展开全文") { detailExpanded.toggle() }
                    .bojiType(.caption)
                    .foregroundStyle(BojiColor.textTertiary)
            }

            // 内联核心依据
            DisclosureGroup("查看记录依据") {
                ClubEvidenceBox(evidence: event.evidence, recordDate: event.date,
                                observedAt: event.recordedAt, display: display)
                    .padding(.top, BojiSpace.tightRow)
            }.bojiType(.label).tint(BojiColor.textSecondary)
            if display != .current {
                Text(display == .updated ? "记录已更新，请以最新依据为准" : "这条洞察不可执行")
                    .bojiType(.label).foregroundStyle(BojiColor.textSecondary)
            }

            // 操作闭环区：主行动
            if let action = openingAction {
                Button {
                    guard let ownerID, ownerID == store.editingAccountID else { return }
                    respond(.read)
                    if error == nil { destination = ClubInsightOpen(action: action) }
                } label: {
                    HStack(spacing: BojiLayout.tight) {
                        Text(actionLabel(action))
                    }
                    .bojiType(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(BojiColor.textPrimary, in: Capsule())
                    .foregroundStyle(BojiColor.pageBackground)
                }
                .buttonStyle(.plain)
                
            }

            if helpful {
                HStack(spacing: BojiLayout.tight) {
                    Image(systemName: "hand.thumbsup.fill").bojiType(.caption)
                    Text("已标记有帮助").bojiType(.caption)
                }
                .foregroundStyle(BojiColor.textTertiary)
            }

            if let error { FlowError(message: error) }
        }
        .sensoryFeedback(.success, trigger: feedbackCount)
        .contextMenu { feedbackMenuItems }
        .sheet(item: $destination) { route in ClubInsightDestinationView(action: route.action, ownerID: ownerID) }
        .sheet(isPresented: $showCoachChat) {
            ClubNavigationStack132 {
                ClubAIEntryBridge(question: coachPrompt)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { showCoachChat = false } } }
            }
        }
        .onChange(of: store.editingAccountID) { _, value in
            if value != ownerID { destination = nil; showCoachChat = false }
        }
    }

    private var openingAction: ClubInsightAction? {
        guard display == .current else { return nil }
        if let action = event.action { return action }
        if event.kind == .workout, let session = event.sourceSessionID {
            return ClubInsightAction(type: "workout_summary", date: event.date, sessionID: session)
        }
        guard [ClubInsightKind.training, .nutrition, .body].contains(event.kind) else { return nil }
        return ClubInsightAction(type: event.kind.rawValue, date: event.date)
    }

    private func actionLabel(_ action: ClubInsightAction) -> String {
        switch action.type {
        case "workout_summary": return "查看本次总结"
        case "training": return "打开当天训练"
        case "nutrition": return "登记补充饮食"
        case "schedule_shift": return "调整日程排期"
        default: return "查看身体记录"
        }
    }

    @ViewBuilder private var feedbackMenuItems: some View {
        Button(helpful ? "已标记有帮助" : "有帮助", systemImage: "hand.thumbsup") { respond(.helpful) }.disabled(helpful)
        Button("今天暂停此类提醒", systemImage: "bell.slash") { respond(.dismissToday) }
        Button(isArchived ? "取消归档" : "归档这条跟进", systemImage: "archivebox") { respond(isArchived ? .unarchive : .archive) }
    }

    private var feedbackMenu: some View {
        Menu {
            feedbackMenuItems
        } label: {
            Image(systemName: "ellipsis")
                .bojiType(.label)
                .foregroundStyle(BojiColor.textTertiary)
                .frame(minWidth: 28, minHeight: 28)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("\(event.kind.label)选项")
    }

    private func respond(_ action: ClubInsightFeedbackAction) {
        guard let ownerID else { return }
        if store.giveInsightFeedback(kind: event.kind, action: action, eventID: event.id, expectedOwner: ownerID) {
            error = nil; feedbackCount &+= 1
        } else {
            error = store.takeMessage(fallback: "跟进偏好未保存，请重试。")
        }
    }
}

private struct ClubInsightOpen: Identifiable { let id = UUID(); let action: ClubInsightAction }

private struct ClubInsightDestinationView: View {
    let action: ClubInsightAction
    let ownerID: Int?
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let date = ClubDates.date(fromKey: action.date), !ClubDates.isFuture(date), ownerID != nil, store.editingAccountID == ownerID {
                switch action.type {
                case "workout_summary":
                    ClubNavigationStack132 {
                        if let session = action.sessionID {
                            ClubWorkoutSummaryView(date: date, sessionID: session)
                                .toolbar { ToolbarItem(placement: .confirmationAction) { DismissButton() } }
                        } else {
                            EmptyNote(title: "缺少训练场次", detail: "请返回查看当前记录。")
                        }
                    }
                case "training":
                    ClubNavigationStack132 {
                        WorkoutView(selectedDate: .constant(date), focused: true)
                            .toolbar { ToolbarItem(placement: .cancellationAction) { DismissButton() } }
                    }
                    .onAppear { store.trainingInterfacePresented = true }
                    .onDisappear { store.trainingInterfacePresented = false }
                case "nutrition":
                    MealEditorView(date: date)
                case "body":
                    BodyWeightView(initialDate: date)
                case "schedule_shift":
                    ClubNavigationStack132 {
                        ShiftScheduleView()
                            .toolbar { ToolbarItem(placement: .cancellationAction) { DismissButton() } }
                    }
                default:
                    EmptyNote(title: "暂不支持这项操作", detail: "请更新 App 后重试。")
                }
            } else {
                EmptyNote(title: "记录状态已变化", detail: "请关闭页面，回到当前账号核对。")
            }
        }
        .onChange(of: store.editingAccountID) { _, value in if value != ownerID { dismiss() } }
    }
}

private struct ClubInsightThread: Identifiable {
    let id: String
    let events: [ClubInsightEvent]
    var head: ClubInsightEvent { ClubInsightLedger.leaves(events).first ?? events[0] }
}

/// 线索卡片视图：只呈现当前最新有效洞察，避免审计式历史更迭折叠干扰用户
private struct ClubInsightThreadView: View {
    let head: ClubInsightEvent
    let ownerID: Int?

    var body: some View {
        ClubCard {
            ClubInsightMessageView(event: head, ownerID: ownerID)
        }
    }
}

/// 重构后的 Club AI Insights 时间线与看板视图
struct ClubInsightTimelineView: View {
    var embedded = false
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var ai: AIService
    @EnvironmentObject private var weekly: WeeklyReviewService
    @Environment(\.dismiss) private var dismiss
    @State private var ownerID: Int?
    @State private var kind = "全部"
    @State private var rangeDays = 30
    @State private var visible = 30
    @State private var settings = false
    @State private var reading = "未归档"
    @State private var showDailyReport = false
    @State private var showWeeklyReview = false

    private var allEvents: [ClubInsightEvent] {
        let today = ClubDates.key(Date())
        return ClubInsightLedger.events(in: store.state).filter { $0.date <= today && ClubInsightPriorityRules.isActionable($0) }
    }

    private var threads: [ClubInsightThread] {
        let from = ClubDates.calendar.date(byAdding: .day, value: 1 - rangeDays,
                                           to: ClubDates.calendar.startOfDay(for: Date())) ?? Date()
        let grouped = Dictionary(grouping: allEvents, by: \.groupID).map { key, records in
            let ordered = records.sorted { $0.recordedAt == $1.recordedAt ? $0.id > $1.id : $0.recordedAt > $1.recordedAt }
            return ClubInsightThread(id: key, events: ordered)
        }
        return grouped.filter { thread in
            let head = thread.head
            let archived = ClubInsightLedger.isArchived(head, in: store.state)
            let included: Bool
            if reading == "已归档" { included = archived }
            else if reading == "未读" { included = !archived && !ClubInsightLedger.isRead(head, in: store.state) }
            else { included = !archived }

            let matchesKind: Bool
            switch kind {
            case "训练": matchesKind = head.kind == .training || head.kind == .workout
            case "饮食": matchesKind = head.kind == .nutrition
            case "身体": matchesKind = head.kind == .body
            case "计划": matchesKind = head.kind == .plan
            default: matchesKind = true
            }
            let inRange = rangeDays == 0 || head.recordedAt >= from
            return included && matchesKind && inRange
        }.sorted { left, right in
            left.head.recordedAt == right.head.recordedAt ? left.id > right.id : left.head.recordedAt > right.head.recordedAt
        }
    }

    @ViewBuilder var body: some View {
        if embedded { timelineContent }
        else { ClubNavigationStack132 { timelineContent } }
    }

    private var timelineContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: BojiLayout.rowGap) {
                // 顶部看板概览与日报/周报快捷栏
                headerPulse
                reportQuickBar

                // 筛选行
                filterSection

                if threads.isEmpty {
                    EmptyNote(title: "还没有洞察", detail: "记录训练、饮食或称重后显示。")
                        .padding(.top, BojiLayout.blockGap)
                }

                ForEach(Array(threads.prefix(visible))) { thread in
                    ClubInsightThreadView(
                        head: thread.head,
                        ownerID: ownerID
                    )
                }

                if visible < threads.count {
                    Button("查看更多跟进") { visible += 30 }
                        .buttonStyle(SecondaryButton())
                        .padding(.top, BojiSpace.tight)
                }
            }
            .padding(ClubUI.pageInset)
            .frame(maxWidth: ClubUI.contentWidth)
            .frame(maxWidth: .infinity)
        }
        .background { ClubBackground() }
        .navigationTitle("洞察")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !embedded {
                ToolbarItem(placement: .cancellationAction) { DismissButton() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { settings = true } label: { Image(systemName: "slider.horizontal.3") }
                        .accessibilityLabel("跟进设置")
                }
            }
        }
        .onAppear {
            ownerID = store.editingAccountID
            store.refreshClubInsights()
        }
        .onChange(of: store.editingAccountID) { _, id in if id != ownerID { dismiss() } }
        .onChange(of: kind) { _, _ in visible = 30 }
        .onChange(of: rangeDays) { _, _ in visible = 30 }
        .onChange(of: reading) { _, _ in visible = 30 }
        .sheet(isPresented: $settings) { ClubAISettingsView() }
        .sheet(isPresented: $showDailyReport) {
            let todayKey = ClubDates.key(Date())
            let deleted = Set(store.state.deletedAIJobIDs ?? [])
            let report = ReportHistory.visible(ai.jobs, dateKey: todayKey, deleted: deleted).first
            NavigationStack {
                if let report {
                    AIReportReaderView(jobID: report.id)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { DismissButton() } }
                } else {
                    ClubAIEntryBridge(scope: .make(.daily))
                }
            }
        }
        .sheet(isPresented: $showWeeklyReview) {
            WeeklyReviewCenter()
        }
    }

    /// 日报与周报一键生成/查看快捷栏
    private var reportQuickBar: some View {
        let todayKey = ClubDates.key(Date())
        let deleted = Set(store.state.deletedAIJobIDs ?? [])
        let hasDaily = ReportHistory.visible(ai.jobs, dateKey: todayKey, deleted: deleted).first?.status == "succeeded"
        let cycle = TrainingCycle.preferred(days: store.state.days)
        let readiness = WeeklyReadiness(cycle: cycle, days: store.state.days)
        let hasWeekly = WeeklyVersions.visible(days: store.state.days, local: weekly.reviews, deletedJobIDs: deleted)
            .contains { $0.date == cycle.end && $0.result != nil }

        return HStack(spacing: BojiLayout.inline) {
            Button { showDailyReport = true } label: {
                HStack(spacing: BojiLayout.inline) {
                    Image(systemName: "sun.max.fill").foregroundStyle(BojiColor.aiGold)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("今日").bojiType(.secondary).foregroundStyle(BojiColor.textPrimary)
                        Text(hasDaily ? "已生成" : "按今日记录生成")
                            .bojiType(.caption).foregroundStyle(BojiColor.textSecondary).lineLimit(1)
                    }
                    Spacer(minLength: 2)
                    Image(systemName: "chevron.right").bojiType(.caption).foregroundStyle(BojiColor.textTertiary)
                }
                .padding(BojiSpace.general)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(BojiColor.cardSurface, in: RoundedRectangle(cornerRadius: BojiRadius.inner, style: .continuous))
            }
            .buttonStyle(.plain)

            Button { showWeeklyReview = true } label: {
                HStack(spacing: BojiLayout.inline) {
                    Image(systemName: "calendar.badge.checkmark").foregroundStyle(BojiColor.aiViolet)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("上周解读").bojiType(.secondary).foregroundStyle(BojiColor.textPrimary)
                        Text(hasWeekly ? "已完成 · 点击查看" : readiness.trainingReady ? "已达标 · 可生成周报" : "训练 \(readiness.trainingDays)/\(readiness.neededTrainingDays) 天")
                            .bojiType(.caption).foregroundStyle(BojiColor.textSecondary).lineLimit(1)
                    }
                    Spacer(minLength: 2)
                    Image(systemName: "chevron.right").bojiType(.caption).foregroundStyle(BojiColor.textTertiary)
                }
                .padding(BojiSpace.general)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(BojiColor.cardSurface, in: RoundedRectangle(cornerRadius: BojiRadius.inner, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    /// 顶部教练速览看板
    private var headerPulse: some View {
        VStack(alignment: .leading, spacing: BojiLayout.tight) {
            Text(ClubAIStatusRules.summary(state: store.state, date: Date()))
                .bojiFont(.secondary)
                .foregroundStyle(BojiColor.textSecondary)
            Text("今日重点")
                .bojiFont(.pageTitle)
                .foregroundStyle(BojiColor.textPrimary)
        }
        
    }

    /// 分类筛选栏（单层直观筛选）
    private var filterSection: some View {
        HStack(spacing: BojiLayout.inline) {
            BojiChipRow(items: ["全部", "训练", "饮食", "身体", "计划"], selection: $kind)
            Menu {
                Picker("显示范围", selection: $reading) {
                    ForEach(["未归档", "未读", "已归档"], id: \.self) { Text($0).tag($0) }
                }
            } label: {
                Image(systemName: reading == "未归档" ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    .bojiType(.secondary)
                    .foregroundStyle(BojiColor.textSecondary)
                    .frame(width: 34, height: 34)
                    .background(BojiColor.subtleSurface, in: Circle())
            }
            .accessibilityLabel("筛选已归档或未读跟进")
        }
    }
}

struct ClubAISettingsView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var ownerID: Int?
    @State private var error: String?

    var body: some View {
        ClubNavigationStack132 {
            List {


                    ClubCard {
                        DisclosureGroup("首页提醒内容") {
                        VStack(spacing: 0) {
                            ForEach([ClubInsightKind.training, .nutrition, .body, .plan], id: \.rawValue) { kind in
                                VStack(alignment: .leading, spacing: BojiLayout.inline) {
                                    Toggle(kind.label, isOn: Binding(
                                        get: { !ClubInsightLedger.reduced(kind, in: store.state) },
                                        set: { enabled in respond(kind, action: enabled ? .normal : .reduce) }
                                    )).frame(minHeight: 44)
                                    if ClubInsightLedger.dismissedToday(kind, in: store.state) {
                                        Text("今天已暂停此类首页提醒").bojiType(.label).foregroundStyle(.secondary)
                                        Button("恢复今天提醒") { respond(kind, action: .restoreToday) }.buttonStyle(SecondaryButton())
                                    }
                                }
                                if kind != .plan { Divider().overlay(BojiColor.divider) }
                            }
                        }
                        }
                    }
                    ClubAutomationSettingsSection(ownerID: ownerID)
                    if let error { FlowError(message: error) }

        }.clubManagementList132()
            .background { ClubBackground() }
            .navigationTitle("自动跟进")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { DismissButton() } }
            .onAppear { ownerID = store.editingAccountID }
            .onChange(of: store.editingAccountID) { _, id in if id != ownerID { dismiss() } }
        }
    }

    private func respond(_ kind: ClubInsightKind, action: ClubInsightFeedbackAction) {
        guard let ownerID else { return }
        if store.giveInsightFeedback(kind: kind, action: action, expectedOwner: ownerID) {
            error = nil
        } else {
            error = store.takeMessage(fallback: "跟进偏好未保存，请重试。")
        }
    }
}
