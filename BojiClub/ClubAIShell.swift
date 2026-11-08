import SwiftUI
import AVKit
import AVFoundation

/// Feature availability can change remotely; the AI-first app shell is permanent.
@MainActor
final class FeatureFlagService: ObservableObject {
    static let shared = FeatureFlagService()
    /// Kept as a read-only compatibility value for integrations with older configuration payloads.
    let aiNativeHome = true
    @Published private(set) var aiEnabled = true
    @Published private(set) var clubEnabled = true
    @Published private(set) var actionSystemEnabled = true
    @Published private(set) var onboardingV2Enabled = true
    @Published private(set) var contextualTipsEnabled = true
    @Published private(set) var aiFastIntentV1 = true
    @Published private(set) var aiRouterV3 = true
    /// Phase 2 SSE. Enabled by default for instant streaming replies.
    @Published private(set) var streamingV2 = true
    /// Phase 3: durable Run + SSE for report / weekly_review.
    /// Server-authoritative and default-off, matching the coach_enabled pattern:
    /// the client only uses this path once the backend publishes the flag.
    @Published private(set) var runV2Enabled = false
    @Published private(set) var runV2Kinds = ""
    @Published private(set) var referencesEnabled = false
    /// coach 后端休眠开关（拍板 #7）：默认休眠；远程可拉起回退（coach_backend_enabled）。
    @Published private(set) var coachBackendEnabled = false
    func apply(remote: ClubRemoteConfig?) {
        referencesEnabled = remote?.config.aiContextReferencesV1 ?? false
        aiEnabled = remote?.config.aiEnabled ?? true
        clubEnabled = remote?.config.clubEnabled ?? true
        actionSystemEnabled = remote?.config.actionSystemEnabled ?? true
        onboardingV2Enabled = remote?.config.onboardingV2Enabled ?? true
        contextualTipsEnabled = remote?.config.contextualTipsEnabled ?? true
        aiFastIntentV1 = remote?.config.aiFastIntentV1 ?? true
        aiRouterV3 = remote?.config.aiRouterV3 ?? true
        streamingV2 = remote?.config.aiStreamingV2 ?? true
        coachBackendEnabled = remote?.config.coachBackendEnabled ?? false
        runV2Enabled = remote?.config.aiRunV2Enabled ?? false
        runV2Kinds = remote?.config.aiRunV2Kinds ?? ""
    }
}

enum ClubShellMode: Hashable { case clubAI, training, records }
enum ClubSidebarRoute: String, Identifiable {
    // 拍板 #5：`aiMemory`（记忆页浏览入口）随对话下线，收敛为偏好数据所在的
    // 「AI 记录与授权」；记忆页仅保留该页内一处行权入口。
    case records, preferences, settings
    var id: String { rawValue }
}

/// Owns navigation, draft and selected day independently from either workspace's view lifetime.
struct ClubAIShellView: View {
    @Environment(\.firstLaunchWalkthroughPresented) private var walkthroughPresented
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var ai: AIService
    @EnvironmentObject private var account: AccountService
    @EnvironmentObject private var membership: MembershipService
    @EnvironmentObject private var notifications: AppNotificationService
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var flags = FeatureFlagService.shared
    @ObservedObject private var pauseService = WorkoutPauseService.shared
    @StateObject private var coach = ClubCoachSession()
    @StateObject private var onboarding = OnboardingV2Model()
    @State private var mode: ClubShellMode = {
        #if DEBUG
        if let env = ProcessInfo.processInfo.environment["BOJI_INITIAL_MODE"] {
            if env == "records" { return .records }
            if env == "training" { return .training }
        }
        #endif
        return .clubAI
    }()
    @State private var sidebarOpen = false
    @State private var columns: NavigationSplitViewVisibility = .detailOnly
    @State private var aiPath = NavigationPath()
    @State private var trainingPath = NavigationPath()
    @State private var recordsPath131 = NavigationPath()
    @State private var trainingScrollAnchor: String?
    @State private var calendarExpanded = false
    @State private var conversationVisible = false
    @State private var focusRequest = 0
    @State private var recordsCategory = {
        #if DEBUG
        if let cat = ProcessInfo.processInfo.environment["BOJI_RECORDS_CATEGORY"] {
            return cat
        }
        #endif
        return "综合看板"
    }()
    @State private var sidebarRoute: ClubSidebarRoute?
    @State private var showHubSection: String?
    @State private var mealEntryRoute: ClubComposerMealRoute?
    @State private var bodyEntryRoute: ClubDateRoute?
    @State private var showExerciseLibrary = false
    @State private var showTrainingPlans = false
    @State private var selectedDate = Date()
    @State private var currentDay = ClubDates.key(Date())
    @State private var trainingRoute: ClubTrainingRoute?
    @State private var pendingTrainingURL: URL?
    @State private var restDeadlines: [String: ClubRestResume] = [:]
    @State private var creatingForDate: ClubTrainingRoute?
    @State private var guideOwner: ClubGuideOwner?
    @State private var showMembership = false
    @State private var showProfileBasics135 = false
    @State private var showPermissions135 = false
    @State private var showReports135 = false
    @State private var showLegacyOnboarding135 = false
    @State private var preparingWelcome135 = false
    @State private var planSetupTask135: Task<Void, Never>?
    @State private var reconcilingPlan135 = false
    @State private var showPlanWizard = false
    @State private var showDailyReport = false
    @State private var showWeeklyReport = false
    @AccessibilityFocusState private var sidebarToggleFocused: Bool
    private var ownerID: Int? { store.editingAccountID }
    private var coachBusy: Bool {
        preparingWelcome135 || coach.preparingReferences || coach.processingConversation == coach.conversation || onboarding.isAssisting || ClubCoachRules.turns(ai.jobs, conversation: coach.conversation,
            deleted: Set(store.state.deletedAIJobIDs ?? [])).contains { !$0.isTerminal }
    }
    private var transitionAnimation: Animation? { reduceMotion ? nil : BojiMotion.smoothSpring() }

    private var shellNotices: some View {
        shellWithPresentations
            .onOpenURL(perform: handleURL)
            .onReceive(NotificationCenter.default.publisher(for: .clubDeviceSetupFinished)) { _ in presentGuideIfNeeded() }
            .onReceive(NotificationCenter.default.publisher(for:.profileFactsChanged133)) { note in
                if note.object as? Int == account.user?.id { Task { await onboarding.load(account:account);onboarding.applyFacts(to:store) } }
            }
            .onReceive(NotificationCenter.default.publisher(for: .clubShellReturnToToday)) { _ in returnToToday() }
            .onReceive(NotificationCenter.default.publisher(for: .clubResumeOnboarding)) { _ in
                sidebarRoute = nil; mode = .clubAI
                if onboarding.hasSession { showLegacyOnboarding135 = true }
                else { showProfileBasics135 = true }
            }
            .onReceive(NotificationCenter.default.publisher(for: .clubAIStartTraining)) { notice in
                let key = notice.userInfo?["date"] as? String
                let date = key.flatMap(ClubDates.date(fromKey:)) ?? Date()
                selectedDate = date; trainingRoute = ClubTrainingRoute(date: date)
                Task { await account.trackEvent(name: "ai_home_start_training", detail: ["date": key ?? "today"]) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .clubOpenWorkoutAI), perform: openWorkoutConversation)
            .onReceive(NotificationCenter.default.publisher(for: .bojiPlanApplied135)) { note in
                guard let owner = note.userInfo?["owner"] as? Int, owner == ownerID,
                      let jobID = note.userInfo?["job"] as? String, account.user?.onboardingCompleted == false else { return }
                UserDefaults.standard.set(jobID, forKey: "boji.pendingPlan135.\(owner)")
                Task { await reconcilePlan135(owner: owner, jobID: jobID) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .clubOpenReferenceAI), perform: openReferenceConversation)
            .onReceive(NotificationCenter.default.publisher(for: ClubAIRoute.notification), perform: handleClubAIRoute)
            .onChange(of: coach.references) { _, _ in coach.persistExtras() }
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in refreshDay() }
            .task(id: account.user?.id) {
                await handleAccountChange()
            }
            .task {
                BojiSound.preload()
                store.refreshClubInsights(); ai.resume()
                if let ownerID { coach.selectConversation(coach.conversation, owner: ownerID) }
            }
    }

    var body: some View {
        shellNotices
            .onChange(of: mode) { _, _ in BojiHaptics.tick(); syncTrainingActivity() }
            .onChange(of: pauseService.state) { previous, current in
                if current?.isPaused == true { notifications.cancelRestReminder() }
                else if previous?.isPaused == true, let snapshot = activeWorkout, let date = ClubDates.date(fromKey: snapshot.dateKey),
                        let end = ClubRestStorage.deadline(owner: ownerID ?? 0, date: date, sessionID: snapshot.sessionID, unfinished: true),
                        (UserDefaults.standard.object(forKey: "training.rest.alerts") as? Bool ?? true) { notifications.scheduleRestReminder(until: end, on: date) }
                syncTrainingActivity()
            }
            .onChange(of: activeWorkout?.sessionID) { _, id in
                refreshDay(); syncTrainingActivity()
                // 重启恢复进行中训练时，工作区同步到「训练」tab，坞条随 mode 归属规则正常显示
                if id != nil, mode == .clubAI, !conversationVisible { mode = .training }
            }
            .onChange(of: activeWorkout?.isPaused) { _, paused in
                // 双状态源（pauseService/restDeadlines）不一致时，以快照为准取消过期提醒
                if paused == true { notifications.cancelRestReminder() }
            }
            .onChange(of: trainingRoute?.id) { _, id in store.trainingInterfacePresented = id != nil }
            .onChange(of: conversationVisible) { _, visible in
                store.clubAIInterfacePresented = visible
                if !visible { handleNotificationRoute() }
            }
            .onAppear {
                refreshDay()
                syncTrainingActivity()
                if activeWorkout?.isPaused == true { notifications.cancelRestReminder() }
                #if DEBUG
                if let envMode = ProcessInfo.processInfo.environment["BOJI_INITIAL_MODE"] {
                    if envMode == "training" { mode = .training }
                    else if envMode == "records" {
                        mode = .records
                        if let cat = ProcessInfo.processInfo.environment["BOJI_RECORDS_CATEGORY"] {
                            recordsCategory = cat
                        }
                    }
                    else if envMode == "workout" { trainingRoute = ClubTrainingRoute(date: Date()) }
                    else if envMode == "membership" { showMembership = true }
                    else if envMode == "reports" { showReports135 = true }
                }
                #endif
            }
            .onChange(of: store.syncStatus) { _, value in
                if case .synced = value {
                    store.refreshClubInsights()
                    if let owner = ownerID, let jobID = UserDefaults.standard.string(forKey: "boji.pendingPlan135.\(owner)") {
                        Task { await reconcilePlan135(owner: owner, jobID: jobID) }
                    }
                }
            }
            .onChange(of: notifications.route?.id, initial: true) { _, _ in handleNotificationRoute() }
            .onChange(of: walkthroughPresented) { _, presented in
                if !presented {
                    if let url = pendingTrainingURL { pendingTrainingURL = nil; handleURL(url) }
                    else { handleNotificationRoute() }
                }
            }
            .onChange(of: store.trainingInterfacePresented) { _, visible in if !visible { handleNotificationRoute() } }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    refreshDay(); store.refreshClubInsights(); ai.resume(); syncTrainingActivity(); presentGuideIfNeeded()
                } else { ai.pause() }
            }
            .onChange(of: store.editingAccountID) { _, _ in
                trainingRoute = nil; pendingTrainingURL = nil; restDeadlines = [:]; conversationVisible = false
                showPlanWizard = false
                sidebarOpen = false; sidebarRoute = nil; columns = .detailOnly
                mealEntryRoute = nil; bodyEntryRoute = nil; creatingForDate = nil
                showTrainingPlans = false; showExerciseLibrary = false; showHubSection = nil
                guideOwner = nil
                aiPath = NavigationPath(); trainingPath = NavigationPath()
                planSetupTask135?.cancel(); planSetupTask135 = nil; onboarding.reset()
                coach.reset(); recordsPath131 = NavigationPath(); recordsCategory = "综合看板"; trainingScrollAnchor = nil; calendarExpanded = false; selectedDate = Date(); currentDay = ClubDates.key(Date())
            }
            .onChange(of: coach.attachments) { _, _ in coach.persistExtras() }
            .onChange(of: coach.workoutContext) { _, _ in coach.persistExtras() }
            .onChange(of: coach.question) { _, value in
                if let ownerID { ClubCoachDraftStorage.save(value, owner: ownerID, conversation: coach.conversation) }
            }
    }

    private var shellStructure: some View {
        Group {
            if horizontalSizeClass == .regular {
                NavigationSplitView(columnVisibility: $columns) {
                    sidebarContent(floating: false)
                        .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 380)
                } detail: { navigationWorkspace }
                .navigationSplitViewStyle(.balanced)
                .toolbar(removing: .sidebarToggle)
            } else {
                navigationWorkspace
                    .allowsHitTesting(!sidebarOpen)
                    .accessibilityHidden(sidebarOpen)
                    .overlay(alignment: .leading) {
                        // Reserve the edge only; a full-page drag recognizer competes with paging.
                        if mode == .clubAI, aiPath.isEmpty, !sidebarOpen {
                            Color.clear.frame(width: 18).contentShape(Rectangle())
                                .gesture(DragGesture(minimumDistance: 25).onEnded { value in
                                    if value.translation.width > 70,
                                       abs(value.translation.height) < value.translation.width * 0.6 { openSidebar() }
                                })
                                .accessibilityHidden(true)
                        }
                        sidebarLayer
                    }
            }
        }
        .background { ClubBackground() }
    }

    private var navigationWorkspace: some View {
        // 原生 TabView 三 tab（2+3 规格表 §1.1）：今天/训练/记录，tab bar 由系统渲染（iOS 26 悬浮玻璃）。
        TabView(selection: $mode) {
            NavigationStack(path: $aiPath) {
                aiWorkspace
                    .navigationTitle("今天")
                    .navigationBarTitleDisplayMode(.large)
                    .toolbar { shellToolbar(for: .clubAI) }
            }
            .tabItem { Label("今天", systemImage: "house") }
            .accessibilityIdentifier("v2-tab-today")
            .tag(ClubShellMode.clubAI)

            NavigationStack(path: $trainingPath) {
                ClubPlanHub(selectedDate: $selectedDate, openWorkout: startTrainingFromPlan, embeddedInShell: true, scrollAnchor: $trainingScrollAnchor, calendarExpanded: $calendarExpanded)
                    .toolbar { shellToolbar(for: .training) }
            }
            .tabItem { Label("训练", systemImage: "figure.strengthtraining.traditional") }
            .accessibilityIdentifier("v2-tab-training")
            .tag(ClubShellMode.training)

            NavigationStack(path: $recordsPath131) {
                // 分类横翻收进 hub 内部（pagedCategory 为空时自带 page 样式）。
                ClubRecordsHub(category: $recordsCategory, embeddedInShell: true)
                    .toolbar { shellToolbar(for: .records) }
            }
            .tabItem { Label("记录", systemImage: "list.bullet.rectangle") }
            .accessibilityIdentifier("v2-tab-records")
            .tag(ClubShellMode.records)
        }
        .clubBottomBar { bottomDock }
    }

    @ToolbarContentBuilder private func shellToolbar(for tab: ClubShellMode) -> some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button(action: openSidebar) { Image(systemName: "sidebar.leading") }
                .accessibilityLabel(horizontalSizeClass == .regular && columns == .all ? "收起侧栏" : "打开侧栏")
                .accessibilityIdentifier("v2-sidebar-toggle")
                .accessibilityFocused($sidebarToggleFocused)
        }
        ToolbarItem(placement: .topBarTrailing) {
            if tab == .clubAI {
                Menu {
                    Button("看现成方案", systemImage: "rectangle.stack.badge.play") { showTrainingPlans = true }
                    Button("让 AI 帮排", systemImage: "wand.and.stars") { showPlanWizard = true }
                    Button("身体档案与报告", systemImage: "doc.text.magnifyingglass") { showReports135 = true }
                } label: { Image(systemName: "ellipsis") }
                .accessibilityLabel("更多操作").accessibilityIdentifier("v2-context-action")
            } else if tab == .training {
                Button { showTrainingPlans = true } label: { Image(systemName: "calendar") }
                    .accessibilityLabel("管理训练计划").accessibilityIdentifier("v2-context-action")
            } else {
                Menu {
                    Button("记录饮食") { openMeal("手动") }
                    Button("记录身体数据") { bodyEntryRoute = ClubDateRoute(date: Date()) }
                    Button("AI 报告", systemImage: "doc.text.magnifyingglass") { showReports135 = true }
                } label: { Image(systemName: "ellipsis") }.accessibilityLabel("记录更多操作").accessibilityIdentifier("v2-context-action")
            }
        }
    }

    @ViewBuilder private var aiWorkspace: some View {
        // 2+3 批次 1：三键悬浮拨号退役（每屏一主操作）——记录入口在记录 tab 与营养卡「记录餐食」。
        ClubAIWorkspaceIdleView(
            activeWorkout: activeWorkout,
            isNewUser: account.user?.onboardingCompleted == false,
            onOpenProfile: { showProfileBasics135 = true },
            onOpenPermissions: { showPermissions135 = true },
            onArrangePlan131: {
                showPlanWizard = true
            },
            onOpenDailyReport: { showDailyReport = true },
            onOpenWeeklyReport: { showWeeklyReport = true },
            onOpenHub: { if $0 == "训练计划" { mode = .training } else { showHubSection = $0 } },
            onStartTraining: {
                if activeWorkout != nil { openActiveWorkout() }
                else { selectedDate = Date(); startTrainingFromPlan() }
            },
            onRecordMeal: { openMeal("手动") },
            onRecordBody: { bodyEntryRoute = ClubDateRoute(date: Date()) }
        )
    }

    private var bottomDock: some View {
        VStack(spacing: BojiLayout.inline) {
            // 规格表 §1.2：底部玻璃坞只归「训练」tab，今天/记录不设坞（主操作走全宽按钮）。
            if mode == .training, trainingRoute == nil, let snapshot = activeWorkout {
                ClubActiveWorkoutAccessory(snapshot: snapshot, open: openActiveWorkout, togglePause: toggleActivePause)
                    .frame(maxWidth: BojiSize.contentWidth)
                    .padding(.horizontal, BojiLayout.rowGap).frame(maxWidth: .infinity)
            }
        }
        .clubGlassGroup(spacing: BojiLayout.rowGap)
        .padding(.bottom, BojiLayout.tight)
    }

    private var shellWithPresentations: some View {
        shellStructure
            .safeAreaInset(edge: .top, spacing: 0) { bannerStack }
            .fullScreenCover(item: $trainingRoute, onDismiss: { store.trainingInterfacePresented = false;Task { await onboarding.load(account:account) } }) { workoutCoverFor($0) }
            .sheet(item: $creatingForDate) { PlanCreationSheet(date: $0.date) }
            .sheet(item: $sidebarRoute) { sidebarDestination($0) }
            .sheet(isPresented: $showProfileBasics135) { ProfileFactsForm133(title: "补充资料", fields: ProfileFields133.basics) }
            .sheet(isPresented: $showPermissions135) { if let owner = ownerID { FirstLaunchPermissionsView(ownerID: owner) } }
            .sheet(isPresented: $showReports135) { NavigationStack { ReportLibraryView(embedded: true).toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { showReports135 = false } } } } }
            .sheet(isPresented: $showLegacyOnboarding135) {
                NavigationStack {
                    OnboardingWorkspaceView(model: onboarding,
                        onRecordMeal: { date, mode in showLegacyOnboarding135 = false; mealEntryRoute = ClubComposerMealRoute(date: date, mode: mode) },
                        onRecordTraining: { date in showLegacyOnboarding135 = false; selectedDate = date; trainingRoute = ClubTrainingRoute(date: date) },
                        onOpenMembership: { showLegacyOnboarding135 = false; showMembership = true },
                        onOpenKnowledge: { showLegacyOnboarding135 = false; sidebarRoute = .preferences })
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { showLegacyOnboarding135 = false } } }
                }
            }
            .sheet(item: $guideOwner) { ClubUsageGuideView(firstVisitAccountID: $0.id) }
            .sheet(isPresented: $showTrainingPlans) { TrainingPlansView(focusDate: selectedDate) }
            .sheet(isPresented: $showExerciseLibrary) {
                NavigationStack {
                    ExerciseLibraryView(date: selectedDate, added: {})
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { showExerciseLibrary = false } } }
                }
            }
            .sheet(item: $mealEntryRoute) { route in
                MealEditorView(date: route.date, initialEntryMode: route.mode, onSaved:{ Task { _ = await store.syncNow();await onboarding.load(account:account) } })
            }
            .sheet(item: $bodyEntryRoute) { route in
                BodyWeightView(initialDate: route.date)
            }
            .sheet(isPresented: $showMembership) { MembershipView(isMandatory: false) }
            .sheet(item: Binding(get: { showHubSection.map { HubSectionRoute(section: $0) } }, set: { showHubSection = $0?.section })) { route in
                ClubAIHubView(initialSection: route.section).presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showPlanWizard) {
                NavigationStack {
                    PlanView(date: max(Date(), selectedDate), onPlanApplied: {
                        showPlanWizard = false
                        mode = .training
                    })
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("关闭") { showPlanWizard = false }
                        }
                    }
                }
            }
            .sheet(isPresented: $showDailyReport) {
                NavigationStack {
                    DailyReportView()
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { showDailyReport = false } } }
                }
            }
            .sheet(isPresented: $showWeeklyReport) {
                NavigationStack {
                    WeeklyReportView()
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { showWeeklyReport = false } } }
                }
            }
    }

    private func handleClubAIRoute(_ note: Notification) {
        guard let request = note.object as? ClubAIRouteRequest, request.owner == ownerID else { return }
        sidebarRoute = nil; showHubSection = nil; trainingRoute = nil; guideOwner = nil
        creatingForDate = nil; showTrainingPlans = false; showExerciseLibrary = false
        if let id = request.conversation, UUID(uuidString: id) != nil { coach.selectConversation(id, owner: ownerID) }
        else { coach.newConversation(owner: ownerID, keepDraft: true) }
        if !request.question.isEmpty { coach.question = request.question }
        if !request.references.isEmpty {
            var combined = coach.references
            for ref in request.references {
                if !combined.contains(where: { $0.id == ref.id }) {
                    combined.append(ref)
                }
            }
            coach.references = combined
        }
        if let src = request.source { coach.continuationSource = src }
        if let scp = request.scope { coach.reviewScope = scp }
        coach.persistExtras(); mode = .clubAI; conversationVisible = true; focusRequest += 1
        if request.sendImmediately131 { coach.sendRequest += 1 }
    }

    private func handleAccountChange() async {
        guideOwner = nil
        await Task.yield()
        let notCompleted = (account.user?.onboardingCompleted == false)
        if notCompleted {
            await onboarding.load(account: account)
            onboarding.applyFacts(to: store)
            if let owner = ownerID, let jobID = UserDefaults.standard.string(forKey: "boji.pendingPlan135.\(owner)") {
                await reconcilePlan135(owner: owner, jobID: jobID)
            }
        }
        presentGuideIfNeeded()
    }

    private func openReferenceConversation(_ notice: Notification) {
        guard let owner = notice.userInfo?["owner"] as? Int, ownerID == owner,
              let ref = notice.userInfo?["reference"] as? AIContextReference else { return }
        trainingRoute = nil; sidebarRoute = nil; showHubSection = nil; sidebarOpen = false
        showTrainingPlans = false; bodyEntryRoute = nil; mealEntryRoute = nil
        coach.newConversation(owner: owner, keepDraft: true)
        coach.references = [ref]; coach.question = "请帮我分析这份记录。"
        coach.persistExtras(); mode = .clubAI; conversationVisible = true; aiPath = NavigationPath()
    }
    private func openWorkoutConversation(_ notice: Notification) {

                guard let owner = notice.userInfo?["owner"] as? Int, ownerID == owner,
                      let key = notice.userInfo?["date"] as? String, let date = ClubDates.date(fromKey: key),
                      let raw = notice.userInfo?["session"] as? String, let sessionID = UUID(uuidString: raw),
                      let context = ClubAIEntryContext.make(owner: owner, date: date, sessionID: sessionID, state: store.state) else { return }
                trainingRoute = nil; sidebarRoute = nil; showHubSection = nil; sidebarOpen = false
                coach.selectConversation(context.conversationID, owner: owner)
                coach.workoutContext = context
                mode = .clubAI; conversationVisible = true; aiPath = NavigationPath()
                let hasTurns = !ClubCoachRules.turns(ai.jobs, conversation: context.conversationID,
                    deleted: Set(store.state.deletedAIJobIDs ?? [])).isEmpty
                let recovering = AIRunPendingStore.load(owner: owner, conversation: context.conversationID) != nil
                    || AIRunResumeStore.load(owner: owner, conversation: context.conversationID) != nil
                let hasDraft = !coach.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if !hasTurns && !recovering && !hasDraft {
                    coach.question = ClubAIEntryContext.defaultQuestion
                    Task {
                        if !FeatureFlagService.shared.referencesEnabled { await store.syncNow() }
                        guard ownerID == owner, coach.workoutContext == context, coach.conversation == context.conversationID else { return }
                        guard let fresh = ClubAIEntryContext.make(owner: owner, date: date, sessionID: sessionID, state: store.state) else { coach.error = "训练尚未确认，请先核对记录。"; return }
                        coach.workoutContext = fresh
                        coach.sendRequest += 1
                    }
                }
    }
    private func openSidebar() {
        BojiHaptics.tick()
        withAnimation(transitionAnimation) {
            if horizontalSizeClass == .regular { columns = columns == .all ? .detailOnly : .all }
            else { sidebarOpen = true }
        }
    }
    private func closeSidebar() {
        withAnimation(transitionAnimation) {
            sidebarOpen = false
            if horizontalSizeClass == .regular { columns = .detailOnly }
        }
        sidebarToggleFocused = true
    }
    private func sidebarContent(floating: Bool) -> some View {
        SidebarHostView(
            floating: floating,
            onClose: closeSidebar,
            onToday: { closeSidebar(); returnToToday() },
            onOpenPlans: { closeSidebar(); showTrainingPlans = true },
            onOpenLibrary: { closeSidebar(); showExerciseLibrary = true },
            onOpenReports: { closeSidebar(); showReports135 = true },
            onOpen: { route in
                closeSidebar()
                if route == .records { mode = .records }
                else { sidebarRoute = route }
            }
        )
    }
    @ViewBuilder private var sidebarLayer: some View {
        if sidebarOpen {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Color.black.opacity(0.28).ignoresSafeArea().onTapGesture(perform: closeSidebar).accessibilityHidden(true)
                    sidebarContent(floating: true)
                        .frame(width: min(geometry.size.width * 0.88, 360))
                        .padding(.leading, BojiLayout.inline).padding(.vertical, BojiLayout.tight)
                        .transition(.move(edge: .leading))
                        .accessibilityAddTraits(.isModal)
                        .gesture(DragGesture(minimumDistance: 30).onEnded { value in
                            if value.translation.width < -70 { closeSidebar() }
                        })
                }
            }
            .animation(transitionAnimation, value: sidebarOpen)
            .zIndex(20)
        }
    }
    @ViewBuilder private func sidebarDestination(_ route: ClubSidebarRoute) -> some View {
        switch route {
        case .records:
            NavigationStack { ClubRecordsHub(category: $recordsCategory)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { sidebarRoute = nil } } } }
        case .preferences:
            NavigationStack { ClubActionPreferencesView().toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { sidebarRoute = nil } } } }
        case .settings:
            NavigationStack { V2SettingsMenuView()
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { sidebarRoute = nil } } } }
        }
    }
    private func reconcilePlan135(owner: Int, jobID: String) async {
        guard !reconcilingPlan135, owner == ownerID, account.user?.onboardingCompleted == false else { return }
        reconcilingPlan135 = true; defer { reconcilingPlan135 = false }
        await store.syncNow()
        guard owner == ownerID else { return }
        await onboarding.markPlanAdopted(jobID: jobID, account: account)
        guard owner == ownerID else { return }
        if onboarding.state?.taskCompleteAvailable == true {
            UserDefaults.standard.removeObject(forKey: "boji.pendingPlan135.\(owner)")
            _ = await onboarding.completeSession(account: account, covenantVersion: "2026-10-25")
        } else if let message = onboarding.error { coach.error = message }
    }
    private func openMeal(_ mode: String) {
        mealEntryRoute = ClubComposerMealRoute(date: Date(), mode: mode)
    }
    private func sendComposer() {
        let text = coach.question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard flags.aiEnabled, !coachBusy, (!text.isEmpty || !coach.attachments.isEmpty), text.count <= 1200 else { return }
        if flags.onboardingV2Enabled && onboarding.state?.enabled != false && account.user?.onboardingCompleted == false && !onboarding.hasSession && !account.isPreviewAccount {
            guard !preparingWelcome135 else { return }
            preparingWelcome135 = true
            Task {
                defer { preparingWelcome135 = false }
                await planSetupTask135?.value
                if !onboarding.hasSession { await onboarding.load(account: account) }
                if !onboarding.hasSession && onboarding.error == nil && onboarding.state?.enabled != false { await onboarding.createSession(.explore, account: account) }
                guard onboarding.hasSession || onboarding.state?.enabled == false else { coach.error = "暂时无法连接，消息还在。请重试。"; return }
                conversationVisible = true; coach.sendRequest += 1
            }
            return
        }
        conversationVisible = true
        coach.sendRequest += 1
    }
    private func requestNewConversation() {
        startNewConversation(keepDraft: true)
    }
    private func startNewConversation(keepDraft: Bool) {
        coach.newConversation(owner: ownerID, keepDraft: keepDraft)
        conversationVisible = false; mode = .clubAI; aiPath = NavigationPath()
    }
    private func returnToToday() {
        conversationVisible = false; mode = .clubAI; aiPath = NavigationPath()
    }
    private func refreshDay(now: Date = Date()) {
        let key = ClubDates.key(now)
        if ClubDates.key(selectedDate) == currentDay {
            // Do not consume the midnight transition while the previous day's session is live.
            if WorkoutTiming.isOngoing(store.log(for: selectedDate), on: selectedDate, now: now) { return }
            selectedDate = now
        }
        currentDay = key
    }
    private func presentGuideIfNeeded() {
        // Guidance is now anchored to real controls. Help remains available from My.
        guideOwner = nil
    }
    private func handleURL(_ url: URL) {
        guard url.scheme == "bojiclub" else { return }
        if url.host == "training" {
            guard !walkthroughPresented else { pendingTrainingURL = url; return }
            let date = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "date" })?.value.flatMap(ClubDates.date(fromKey:)) ?? Date()
            selectedDate = date; trainingRoute = ClubTrainingRoute(date: date)
        } else if url.host == "daily-report" {
            showDailyReport = true
        } else if url.host == "weekly-report" {
            showWeeklyReport = true
        } else if url.host == "plan" {
            showPlanWizard = true
        } else if url.host == "speed-dial" {
            // 三键拨号退役后，快捷记录深链落到记录 tab。
            mode = .records
        }
    }

    private func workoutCoverFor(_ route: ClubTrainingRoute) -> some View {
        NavigationStack {
            WorkoutView(selectedDate: .constant(route.date), focused: true,
                initialRestEnd: restDeadline(for: route.date),
                restChanged: { deadline in
                    restDeadlines[ClubDates.key(route.date)] = deadline.map {
                        ClubRestResume(deadline: $0, sessionID: store.log(for: route.date).activeWorkoutSessionID)
                    }
                })
                .id(route.id)
                .toolbar { ToolbarItem(placement: .cancellationAction) {
                    // 动作卡列表里也有一个「收起」（收起动作卡），按 label 匹配会点错；
                    // 壳层收起按钮用唯一标识符供 UI 测试定位。
                    Button("收起") { trainingRoute = nil }
                        .accessibilityIdentifier("v2-workout-collapse")
                } }
        }
    }


    private var bannerStack: some View {
        VStack(spacing: 0) {
            if let message = ai.recoveryNotice {
                BojiStatusBanner(
                    icon: "wifi.slash",
                    title: "云端恢复稍后继续",
                    detail: message,
                    tint: BojiColor.textSecondary,
                    actionTitle: "知道了",
                    action: { ai.dismissRecoveryNotice() }
                )
            }
            if let message = store.message ?? ai.notice {
                BojiStatusBanner(
                    icon: "info.circle",
                    title: message,
                    tint: BojiColor.textSecondary,
                    actionTitle: "知道了",
                    action: { store.message = nil; ai.notice = nil }
                )
            }
        }
    }


    private var activeWorkout: ActiveWorkoutSnapshot? {
        guard let owner = store.editingAccountID,
              let base = ActiveWorkoutRules.snapshot(state: store.state, now: Date()),
              let date = ClubDates.date(fromKey: base.dateKey) else { return nil }
        let pause = ClubWorkoutPauseStorage.load(owner: owner, date: date, sessionID: base.sessionID)
        let rest = ClubRestStorage.deadline(owner: owner, date: date, sessionID: base.sessionID, unfinished: true)
        return ActiveWorkoutRules.snapshot(state: store.state, now: Date(), pause: pause, restEndsAt: rest)
    }

    private func openActiveWorkout() {
        guard let snapshot = activeWorkout, let date = ClubDates.date(fromKey: snapshot.dateKey) else { return }
        selectedDate = date
        trainingRoute = ClubTrainingRoute(date: date)
    }

    private func toggleActivePause() {
        guard store.editingAccountID != nil, let snapshot = activeWorkout,
              let date = ClubDates.date(fromKey: snapshot.dateKey),
              store.log(for: date).trainingLog.workoutStartedAt != nil else { return }
        _ = store.setWorkoutPaused(!snapshot.isPaused, on: date)
        syncTrainingActivity()
    }

    private func syncTrainingActivity() {
        if let date = activeWorkout.flatMap({ ClubDates.date(fromKey: $0.dateKey) }) { store.restoreWorkoutPause(on: date) }
        guard let owner = store.editingAccountID else { return }
        guard let snapshot = activeWorkout, let date = ClubDates.date(fromKey: snapshot.dateKey) else {
            TrainingActivityService.shared.end(); return
        }
        let pausedRest = ClubRestStorage.pausedRemaining(owner: owner, date: date,
                                                        sessionID: snapshot.sessionID, unfinished: true)
        TrainingActivityService.shared.sync(snapshot: snapshot, restPausedRemaining: pausedRest)
    }

    private func startTrainingFromPlan() {
        let day = store.log(for: selectedDate).trainingLog
        if ClubDates.calendar.isDateInToday(selectedDate),
           day.workoutStartedAt == nil, day.workoutSavedAt == nil, day.completedSets == 0 {
            _ = store.beginWorkout(on: selectedDate)
        }
        trainingRoute = ClubTrainingRoute(date: selectedDate)
    }

    private func restDeadline(for date: Date) -> Date? {
        guard let saved = restDeadlines[ClubDates.key(date)], saved.deadline > Date(),
              saved.sessionID == store.log(for: date).activeWorkoutSessionID else { return nil }
        return saved.deadline
    }

    private func handleNotificationRoute() {
        guard !walkthroughPresented else { return }
        guard let route = notifications.route, route.accountID == store.editingAccountID else { return }
        if route.kind != "training" {
            conversationVisible = false
            if trainingRoute != nil { trainingRoute = nil }
            return
        }
        guard let date = ClubDates.date(fromKey: route.date) else { notifications.route = nil; return }
        if let current = trainingRoute {
            if ClubDates.key(current.date) == route.date { notifications.route = nil }
            else { trainingRoute = nil }
            return
        }
        guard !store.trainingInterfacePresented else { return }
        conversationVisible = false; selectedDate = date; trainingRoute = ClubTrainingRoute(date: date); notifications.route = nil
    }
}

private struct HubSectionRoute: Identifiable { let id = UUID(); let section: String }
private struct ClubDateRoute: Identifiable { let id = UUID(); let date: Date }

/// Native selection appearance; the page container owns horizontal navigation.
extension Notification.Name {
    static let bojiPlanApplied135 = Notification.Name("bojiPlanApplied135")
    static let clubShellReturnToToday = Notification.Name("clubShellReturnToToday")
    static let clubDeviceSetupFinished = Notification.Name("clubDeviceSetupFinished")
}

struct SidebarHostView: View {
    var floating = true
    let onClose: () -> Void
    let onToday: () -> Void
    let onOpenPlans: () -> Void
    let onOpenLibrary: () -> Void
    let onOpenReports: () -> Void
    let onOpen: (ClubSidebarRoute) -> Void

    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var account: AccountService
    @Environment(\.dynamicTypeSize) private var typeSize
    @AccessibilityFocusState private var headingFocused: Bool

    var body: some View {
        Group {
            if floating { content.clubGlassEffect(in: RoundedRectangle(cornerRadius: BojiRadius.hero, style: .continuous)) }
            else { content }
        }
        .accessibilityIdentifier("v2-sidebar-panel")
        .onAppear { headingFocused = true }
        .accessibilityAction(.escape, onClose)
    }

    private var content: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 顶部快速回到今天
                VStack(spacing: 0) {
                    entry("回到今天", symbol: "sun.max.fill", id: "v2-sidebar-today", action: onToday)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, BojiLayout.pageInset)
                .padding(.vertical, BojiLayout.inline)

                Divider()

                List {
                    Section("训练与计划") {
                        entry("训练计划库", symbol: "calendar", id: "v2-sidebar-plans", action: onOpenPlans)
                        entry("动作资料库", symbol: "figure.strengthtraining.traditional", id: "v2-sidebar-exercises", action: onOpenLibrary)
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                    Section("数据与分析") {
                        entry("身体档案与报告", symbol: "doc.text.magnifyingglass", id: "v2-sidebar-reports", action: onOpenReports)
                        entry("概览与记录", symbol: "chart.xyaxis.line", id: "v2-sidebar-records") { onOpen(.records) }
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                    Section("系统") {
                        entry("系统设置", symbol: "gearshape", id: "v2-sidebar-settings") { onOpen(.settings) }
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
                .modifier(ClubSidebarListPolicy(floating: floating))
                .scrollContentBackground(.hidden)
                .environment(\.defaultMinListRowHeight, 46)

                // 底部用户信息
                HStack(spacing: BojiLayout.rowGap) {
                    BojiBrandMark(size: 24)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(account.user?.profile?.nickname ?? "薄肌会员")
                            .bojiType(.label)
                            .foregroundStyle(BojiColor.textPrimary)
                        Text(account.user?.membership?.active == true ? "会员权限已激活" : "免费版体验")
                            .bojiType(.caption)
                            .foregroundStyle(BojiColor.textTertiary)
                    }
                    Spacer()
                }
                .padding(.horizontal, BojiLayout.pageInset)
                .padding(.vertical, BojiLayout.rowGap)
                .background(BojiColor.subtleSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, BojiLayout.cardInset)
                .padding(.bottom, BojiLayout.rowGap)
            }
            .toolbar(removing: .sidebarToggle)
            .navigationTitle("薄肌俱乐部")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                if floating {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("关闭", systemImage: "xmark", action: onClose)
                            .labelStyle(.iconOnly)
                            .accessibilityIdentifier("v2-sidebar-close")
                            .accessibilityFocused($headingFocused)
                    }
                }
            }
        }
        .tint(ClubBrand.accent)
        .foregroundStyle(BojiColor.textPrimary)
        .clipShape(RoundedRectangle(cornerRadius: floating ? 28 : 0, style: .continuous))
    }

    private func entry(_ text: String, symbol: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(text, systemImage: symbol)
                .bojiType(.body)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .accessibilityIdentifier(id)
    }
}

struct ClubAIWorkspaceIdleView: View {
    var activeWorkout: ActiveWorkoutSnapshot? = nil
    var isNewUser = false
    var onOpenProfile: () -> Void = {}
    var onOpenPermissions: () -> Void = {}
    var onQuickQuestion: (String) -> Void = { _ in }
    let onArrangePlan131: () -> Void
    var onOpenDailyReport: () -> Void = {}
    var onOpenWeeklyReport: () -> Void = {}
    let onOpenHub: (String) -> Void
    let onStartTraining: () -> Void
    let onRecordMeal: () -> Void
    var onRecordBody: () -> Void = {}

    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var account: AccountService
    @EnvironmentObject private var ai: AIService
    @EnvironmentObject private var health: HealthDataService
    @EnvironmentObject private var clubSeason: ClubSeasonService
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var heroPlayer: AVQueuePlayer?
    @State private var heroLooper: AVPlayerLooper?
    @State private var heroPoster: UIImage?
    @State private var showSeason = false
    @State private var showPresetPlans = false
    @State private var readingDailyReportID: String? = nil
    @State private var appliedModifierNotice: String? = nil
    @State private var revealed = false
    @State private var heroScrollY: CGFloat = 0
    private var heroShrunk: Bool { heroScrollY >= 120 }
    @ObservedObject private var flags = FeatureFlagService.shared

    private var today: DayLog { store.log(for: Date()) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BojiLayout.blockGap) {
                headerArea

                // 核心层级 0: Hero 玻璃流光卡（拍板 #2：保留视频感 + 动效）
                heroGlassCard
                    .bojiHomeEntrance(revealed: revealed, reduceMotion: reduceMotion, index: 0)

                // 首个内容区块与 Hero 构成两拍进场（stagger 0.07s，DES-004）
                Group {
                    if isNewUser {
                        newUserDivergenceCard
                    }

                    // 核心层级 1: 身体状态卡
                    readinessGaugeCard
                }
                .bojiHomeEntrance(revealed: revealed, reduceMotion: reduceMotion, index: 1)

                // 核心层级 2: 今天练什么
                heroMissionCard

                // 核心层级 3: 代谢与营养平衡板
                fuelBalanceCard

                // 核心层级 4: 智能分析专区（AI 训练计划 / AI 每日日报 / AI 每周周报）
                intelligenceHubSection

                // 核心层级 5: 俱乐部成长季入口（复活：原 showSeason 死代码）
                Button { showSeason = true } label: {
                    HStack(spacing: BojiLayout.rowGap) {
                        Image(systemName: "seal.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(BojiColor.brandGold)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("俱乐部成长季")
                                .bojiType(.label)
                                .foregroundStyle(BojiColor.textPrimary)
                            Text("打卡、徽章、奖励")
                                .bojiType(.caption)
                                .foregroundStyle(BojiColor.textTertiary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .bojiType(.caption)
                            .foregroundStyle(BojiColor.textTertiary)
                    }
                    .padding(BojiLayout.cardInset)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .background(BojiColor.cardSurface, in: RoundedRectangle(cornerRadius: BojiRadius.card, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("v2-home-club-season")

                if isNewUser {
                    Button("打开通知和健康权限", action: onOpenPermissions)
                        .bojiType(.label)
                        .foregroundStyle(BojiColor.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
            }
            .padding(.horizontal, BojiLayout.pageInset)
            .padding(.top, BojiLayout.rowGap)
            .padding(.bottom, activeWorkout != nil ? 96 : 84)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .clubTrackScrollY { heroScrollY = $0 }
        .task {
            UserDefaults.standard.removeObject(forKey: "v2.homeInsightPinned.v1")
            await ai.refreshHomeInsightIfNeeded()
        }
        .sheet(isPresented: $showSeason) {
            NavigationStack {
                ClubSeasonView()
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { showSeason = false } } }
                    .task {
                        // 复活修复：打开赛季页时主动刷新（此前 refresh 无调用方，页面恒空）
                        await store.syncNow()
                        await clubSeason.refresh(account: account)
                    }
            }
        }
        .sheet(isPresented: $showPresetPlans) {
            NavigationStack {
                TrainingPlansView(focusDate: Date())
                    .toolbar { ToolbarItem(placement: .cancellationAction) { DismissButton() } }
            }
        }
        .sheet(isPresented: Binding(get: { readingDailyReportID != nil }, set: { if !$0 { readingDailyReportID = nil } })) {
            NavigationStack {
                if let id = readingDailyReportID {
                    AIReportReaderView(jobID: id)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("关闭") { readingDailyReportID = nil }
                            }
                        }
                }
            }
        }
        .background(BojiColor.pageBackground)
        .accessibilityIdentifier("v2-ai-workspace")
    }

    // MARK: - 顶部标题区
    /// Hero 玻璃卡（批次 2 玻璃沉浸）：默认 ~380pt 近整屏；滚动 ≥120pt 收缩成 46pt 玻璃条（iOS 18+ 监听，iOS 17 保持全屏）。
    private var heroGlassCard: some View {
        TimelineView(.animation(minimumInterval: 0.05, paused: reduceMotion || heroShrunk)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 14) / 14
            if heroShrunk {
                heroCollapsedBar
            } else {
                heroGlassContent(phase: phase)
            }
        }
        .animation(BojiMotion2.resolved(BojiMotion2.state, reduceMotion: reduceMotion), value: heroShrunk)
        .onAppear { revealed = true; setupHeroVideo() }
        .onDisappear { teardownHeroVideo() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { heroPlayer?.play() } else { heroPlayer?.pause() }
        }
    }

    /// 收缩态玻璃条：高 46pt，内含唯一主操作「开始」（规格表 §2.1）。
    private var heroCollapsedBar: some View {
        HStack(spacing: BojiLayout.inline) {
            Image(systemName: "figure.strengthtraining.traditional")
                .bojiType(.label)
                .foregroundStyle(.white)
            Text("今天的训练")
                .bojiType(.label)
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer(minLength: BojiLayout.inline)
            Button(action: onStartTraining) {
                Text("开始")
                    .bojiType(.label)
                    .foregroundStyle(BojiColor.pageBackground)
                    .padding(.horizontal, BojiLayout.rowGap)
                    .frame(minHeight: 30)
                    .contentShape(Capsule())
            }
            .buttonStyle(BojiButtonStyle(kind: .primary))
            .accessibilityIdentifier("hero-collapsed-start")
        }
        .padding(.horizontal, BojiLayout.rowGap)
        .frame(height: 46)
        .clubGlassEffect(in: Capsule())
    }

    /// 品牌视频单实例：静音、循环、仅页面活跃时播放；离场暂停并回零。
    private func setupHeroVideo() {
        loadHeroPoster()
        guard heroPlayer == nil, !reduceMotion, !ProcessInfo.processInfo.isLowPowerModeEnabled,
              let url = Bundle.main.url(forResource: "brand-video", withExtension: "mp4") else { return }
        let player = AVQueuePlayer()
        player.isMuted = true
        heroPlayer = player
        heroLooper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        if scenePhase == .active { player.play() }
    }

    /// 首帧静态图：视频未就绪/减少动态效果/低电量时显示，避免纯色块跳变（DES-003 §5.2）。
    private func loadHeroPoster() {
        guard heroPoster == nil, let url = Bundle.main.url(forResource: "brand-video", withExtension: "mp4") else { return }
        Task.detached(priority: .utility) {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 960, height: 960)
            do {
                let cg = try await generator.image(at: .zero).image
                let image = UIImage(cgImage: cg)
                await MainActor.run { heroPoster = image }
            } catch { }
        }
    }

    private func teardownHeroVideo() {
        heroPlayer?.pause()
        heroPlayer?.seek(to: .zero)
        heroPlayer = nil
        heroLooper = nil
    }

    /// AVPlayerLayer 宿主视图：系统 VideoPlayer 没有 videoGravity，品牌视频需要 resizeAspectFill 铺满。
    private final class HeroVideoContainerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer } // 本视图 layerClass 固定返回 AVPlayerLayer，安全
        var player: AVQueuePlayer? {
            get { playerLayer.player as? AVQueuePlayer }
            set {
                playerLayer.player = newValue
                playerLayer.videoGravity = .resizeAspectFill
            }
        }
    }

    private struct HeroVideoSurface: UIViewRepresentable {
        let player: AVQueuePlayer
        func makeUIView(context: Context) -> HeroVideoContainerView {
            let view = HeroVideoContainerView()
            view.player = player
            return view
        }
        func updateUIView(_ uiView: HeroVideoContainerView, context: Context) {
            uiView.player = player
        }
    }

    private func heroGlassContent(phase: Double) -> some View {
        ZStack {
            // z0 首帧占位（未就绪/减少动态效果/低电量时持续显示，视频就绪后叠在其上无缝切换）
            Group {
                if let heroPoster {
                    Image(uiImage: heroPoster)
                        .resizable()
                        .scaledToFill()
                } else {
                    RoundedRectangle(cornerRadius: BojiRadius.hero, style: .continuous)
                        .fill(BojiColor.brandMist.opacity(0.55))
                }
            }
            .clipped()
            .accessibilityHidden(true)
            .allowsHitTesting(false)
            // z0b 视频层（就绪后叠加）
            if let heroPlayer {
                HeroVideoSurface(player: heroPlayer)
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
            }
            // 深色模式压暗，保证玻璃高光可辨
            if colorScheme == .dark { Color.black.opacity(0.2) }
            // z1 护字渐变（底部最深，规格表 §2.1：透明→黑 58%）
            LinearGradient(
                colors: [Color.clear, Color.clear, Color.black.opacity(0.58)],
                startPoint: .top, endPoint: .bottom
            )
            // z2 慢周期流光（非循环）
            LinearGradient(
                colors: [ClubBrand.accent.opacity(0), ClubBrand.accent.opacity(0.30), ClubBrand.accent.opacity(0)],
                startPoint: .leading, endPoint: .trailing
            )
            .offset(x: -220 + 440 * phase)
            // z3 内容：全白文字 + 投影
            VStack(alignment: .leading, spacing: BojiLayout.tight) {
                Text("薄肌俱乐部")
                    .bojiType(.caption)
                    .foregroundStyle(Color.white.opacity(0.85))
                    .shadow(color: .black.opacity(0.45), radius: 1)
                Text("今天的训练，已经为你准备好")
                    .font(.system(size: 52, weight: .heavy))
                    .kerning(-2)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.45), radius: 1)
                Text("按计划开始 · 组间自动计时 · 训练后自动生成日报")
                    .bojiType(.caption)
                    .foregroundStyle(Color.white.opacity(0.8))
                    .shadow(color: .black.opacity(0.45), radius: 1)
            }
            .padding(BojiLayout.cardInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            // 右上 30pt 玻璃暂停钮
            VStack {
                HStack {
                    Spacer()
                    Button {
                        if heroPlayer?.timeControlStatus == .playing { heroPlayer?.pause() } else { heroPlayer?.play() }
                    } label: {
                        Image(systemName: heroPlayer?.timeControlStatus == .playing ? "pause.fill" : "play.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                    }
                    .clubNativeGlassButton()
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
                }
                Spacer()
            }
            .padding(BojiLayout.cardInset)
        }
        .frame(height: 380)
        .clipShape(RoundedRectangle(cornerRadius: BojiRadius.hero, style: .continuous))
        .clubGlassEffect(in: RoundedRectangle(cornerRadius: BojiRadius.hero, style: .continuous))
    }

    private var headerArea: some View {
        // 定稿：区块名取消——只留品牌标 + 日期 chip，大标题走系统 navigationTitle("今天")
        HStack(alignment: .center) {
            BojiBrandMark(size: 34)

            Spacer()

            Text(ClubDates.label(Date(), format: "M月d日 EEEE"))
                .bojiType(.caption)
                .foregroundStyle(BojiColor.textTertiary)
                .padding(.horizontal, BojiLayout.inline)
                .padding(.vertical, BojiLayout.tight)
                .background(BojiColor.subtleSurface, in: Capsule())
        }
        .padding(.vertical, BojiLayout.tight)
    }

    // MARK: - 身体状态卡（批次 1：巨号排印当主角；评分=睡眠+心率+近 3 天训练的真实规则，缺数据说缺）
    /// 状态评分（0…100）：睡眠 50 分（7.5h 满）、静息心率 30 分（越低越好，65/80 断点）、近 3 天训练 20 分。
    /// 关键项（睡眠与心率）都没同步到时返回 nil，界面显示「还没同步到」，绝不编造分数。
    private func readinessScore(sleepMinutes: Double?, restingHeartRate: Double?) -> Int? {
        guard sleepMinutes != nil || restingHeartRate != nil else { return nil }
        var total = 0.0
        if let sleep = sleepMinutes, sleep > 0 {
            total += min(1.0, sleep / (7.5 * 60)) * 50
        }
        if let rhr = restingHeartRate, rhr > 0 {
            total += rhr <= 65 ? 30 : max(8, 30 - (rhr - 65) * 0.8)
        }
        let calendar = ClubDates.calendar
        let trainedRecently = (0..<3).contains { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: Date()),
                  let day = store.state.days[ClubDates.key(date)] else { return false }
            return day.trainingLog.hasConfirmedTraining
        }
        total += trainedRecently ? 20 : 6
        return Int(min(100, max(0, total)))
    }

    private var readinessGaugeCard: some View {
        let healthSummary = health.summary(for: Date())
        let sleepMin = healthSummary?.nightSleep?.value ?? healthSummary?.sleep?.value
        let sleepText: String = {
            if let min = sleepMin, min > 0 {
                let h = Int(min / 60)
                let m = Int(min) % 60
                return "\(h)h \(m)m"
            }
            return "还没同步到"
        }()
        let rhr = healthSummary?.restingHeartRate?.value
        let rhrText: String = {
            if let val = rhr, val > 0 {
                return "\(Int(val)) bpm"
            }
            return "还没同步到"
        }()
        let steps = healthSummary?.steps?.value
        let stepsText: String = {
            if let val = steps, val > 0 {
                return "\(Int(val)) 步"
            }
            return "还没同步到"
        }()
        let score = readinessScore(sleepMinutes: sleepMin, restingHeartRate: rhr)
        let insight = ClubHomeInsightMerge.resolve(local: ClubInsightLedger.current(in: store.state, date: Date()).first, server: ai.homeInsight)

        return VStack(alignment: .leading, spacing: BojiLayout.rowGap) {
            // 巨号评分当主角（.display 88pt）+ 细分割线 + 标签
            if let score {
                BojiEditorialNumber(value: "\(score)", label: "今天的身体状态")
            } else {
                Text("还没同步到")
                    .bojiType(.title)
                    .foregroundStyle(BojiColor.textTertiary)
                Text("健康数据同步后，这里会显示你的身体状态分数")
                    .bojiType(.caption)
                    .foregroundStyle(BojiColor.textTertiary)
            }

            // 三指标数据块横排（无图标汤：大数字 + 细线 + 标签）
            HStack(alignment: .top, spacing: BojiLayout.rowGap) {
                editorialMetric(title: "睡眠", value: sleepText)
                editorialMetric(title: "心率", value: rhrText)
                editorialMetric(title: "步数", value: stepsText)
            }
            .frame(maxWidth: .infinity)

            // 今日建议：绑定真实洞察（服务端/本地规则），没有数据就说没有，不再显示写死的分析段。
            VStack(alignment: .leading, spacing: BojiLayout.tight) {
                HStack(spacing: BojiLayout.tight) {
                    Image(systemName: "chart.xyaxis.line")
                        .bojiType(.caption)
                        .foregroundStyle(BojiColor.brandAccent)
                    Text("今天的建议")
                        .bojiType(.caption)
                        .foregroundStyle(BojiColor.brandAccent)
                }

                Text(insight?.detail ?? "练完或记完吃的，建议会出现在这里。")
                    .bojiType(.label)
                    .foregroundStyle(BojiColor.textSecondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(BojiLayout.rowGap)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(BojiColor.subtleSurface, in: RoundedRectangle(cornerRadius: BojiRadius.control, style: .continuous))
        }
        .padding(BojiLayout.cardInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BojiColor.cardSurface, in: RoundedRectangle(cornerRadius: BojiRadius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: BojiRadius.card, style: .continuous)
                .stroke(BojiColor.outline, lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.04), radius: 10, x: 0, y: 3)
    }

    /// 数据块（2+3 规格：大数字 + 标签，无图标、无描边）。
    private func editorialMetric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: BojiLayout.tight) {
            Text(value)
                .bojiFont(.bodyMetric, monospacedDigits: true)
                .foregroundStyle(BojiColor.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .bojiType(.label)
                .foregroundStyle(BojiColor.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 今天练什么
    private var heroMissionCard: some View {
        VStack(alignment: .leading, spacing: BojiLayout.rowGap) {
            HStack {
                Label(activeWorkout == nil ? "今天练什么" : "正在练", systemImage: "figure.strengthtraining.traditional")
                    .bojiFont(.label)
                    .foregroundStyle(BojiColor.textPrimary)
                    .padding(.horizontal, BojiLayout.inline)
                    .padding(.vertical, BojiLayout.tight)
                    .background(BojiColor.brandMist, in: Capsule())

                Spacer()

                if let active = activeWorkout {
                    HStack(spacing: BojiLayout.tight) {
                        Circle()
                            .fill(BojiColor.emeraldAccent)
                            .frame(width: 6, height: 6)
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let seconds = max(0, Int(active.elapsed(at: context.date)))
                            Text(String(format: "%02d:%02d", seconds / 60, seconds % 60))
                                .bojiType(.label)
                                .foregroundStyle(BojiColor.textPrimary)
                        }
                    }
                } else {
                    Text(today.exercises.isEmpty ? "还没排计划" : "\(today.trainingLog.exercises.count) 个动作 · 预计 45 分钟")
                        .bojiFont(.secondary, monospacedDigits: true)
                        .foregroundStyle(BojiColor.textSecondary)
                }
            }

            if let active = activeWorkout {
                VStack(alignment: .leading, spacing: BojiLayout.tight) {
                    Text(active.workoutName)
                        .bojiFont(.cardTitle)
                        .foregroundStyle(BojiColor.textPrimary)
                    Text("记了 \(active.completedSets) 组，还剩 \(max(0, active.totalSets - active.completedSets)) 组")
                        .bojiType(.caption)
                        .foregroundStyle(BojiColor.textSecondary)
                }

                Button(action: onStartTraining) {
                    HStack(spacing: BojiLayout.inline) {
                        Image(systemName: "play.fill")
                            .bojiType(.secondary)
                        Text("继续练")
                            .bojiType(.body)
                    }
                    .frame(maxWidth: .infinity, minHeight: BojiSize.primaryButtonHeight)
                }
                .buttonStyle(BojiButtonStyle(kind: .primary))

            } else if !today.exercises.isEmpty {
                VStack(alignment: .leading, spacing: BojiLayout.inline) {
                    if today.trainingLog.hasConfirmedTraining {
                        Text("今日训练已保存")
                            .bojiFont(.cardTitle)
                            .foregroundStyle(BojiColor.textPrimary)
                    } else {
                        // 编辑式判断句：整句 section级，关键名词一个 semibold（中文安全字重，不合成 bold）
                        let lead = today.exercises.prefix(2).map(\.name).joined(separator: " · ")
                        HStack(spacing: BojiLayout.tight) {
                            Text("今天练 ")
                                .bojiType(.section)
                                .foregroundStyle(BojiColor.textPrimary)
                            BojiEmphasis.strong(lead)
                                .bojiType(.section)
                                .foregroundStyle(BojiColor.textPrimary)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: BojiLayout.tight) {
                            Text("按你最近 3 天的练和睡排的量，今天就按这个强度来。")
                                .bojiType(.secondary)
                                .foregroundStyle(BojiColor.textSecondary)
                            Spacer(minLength: 0)
                        }
                    }

                    // 动作预览流水
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: BojiLayout.inline) {
                            ForEach(Array(today.exercises.prefix(3)), id: \.id) { exercise in
                                HStack(spacing: BojiLayout.tight) {
                                    Text(exercise.name)
                                        .bojiType(.caption)
                                        .foregroundStyle(BojiColor.textPrimary)
                                    Text("· \(exercise.sets.count)组")
                                        .bojiType(.caption)
                                        .foregroundStyle(BojiColor.textSecondary)
                                }
                                .padding(.horizontal, BojiLayout.inline)
                                .padding(.vertical, BojiLayout.tight)
                                .background(BojiColor.subtleSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                        }
                    }
                }

                // AI 快捷微调胶囊（单手一键微调）
                VStack(alignment: .leading, spacing: BojiLayout.tight) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: BojiLayout.inline) {
                            quickModifierChip(title: "肩膀不舒服，换个动作", systemImage: "arrow.triangle.swap")
                            quickModifierChip(title: "缩短到 30 分钟", systemImage: "timer")
                            quickModifierChip(title: "想练狠一点", systemImage: "waveform.path.ecg")
                        }
                    }

                    if let notice = appliedModifierNotice {
                        Text(notice)
                            .bojiType(.caption)
                            .foregroundStyle(BojiColor.brandAccent)
                            .transition(.opacity)
                    }
                }

                HStack(spacing: BojiLayout.rowGap) {
                    Button(action: onStartTraining) {
                        HStack(spacing: BojiLayout.inline) {
                            Image(systemName: today.trainingLog.hasConfirmedTraining ? "doc.text.magnifyingglass" : "play.fill")
                                .bojiType(.secondary)
                            Text(today.trainingLog.hasConfirmedTraining ? "看今天的记录" : "开练")
                                .bojiType(.body)
                        }
                        .frame(maxWidth: .infinity, minHeight: BojiSize.primaryButtonHeight)
                    }
                    .buttonStyle(BojiButtonStyle(kind: .primary))

                    Button("看计划") { onOpenHub("训练计划") }
                        .buttonStyle(BojiButtonStyle(kind: .secondary))
                        .frame(minHeight: BojiSize.primaryButtonHeight)
                }

            } else {
                VStack(alignment: .leading, spacing: BojiLayout.tight) {
                    Text("今天不用练力量")
                        .bojiFont(.cardTitle)
                        .foregroundStyle(BojiColor.textPrimary)
                    Text("今天没排力量训练。想动一动就做做拉伸，蛋白质记得吃够。")
                        .bojiType(.caption)
                        .foregroundStyle(BojiColor.textSecondary)
                        .lineSpacing(3)
                }

                HStack(spacing: BojiLayout.rowGap) {
                    Button("看现成方案") { showPresetPlans = true }
                        .buttonStyle(BojiButtonStyle(kind: .primary))
                    Button("让 AI 帮排", action: onArrangePlan131)
                        .buttonStyle(BojiButtonStyle(kind: .secondary))
                }
            }
        }
        .padding(BojiLayout.cardInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BojiColor.cardSurface, in: RoundedRectangle(cornerRadius: BojiRadius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: BojiRadius.card, style: .continuous)
                .stroke(BojiColor.outline, lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.04), radius: 10, x: 0, y: 3)
    }

    private func quickModifierChip(title: String, systemImage: String) -> some View {
        Button {
            BojiHaptics.tick()
            withAnimation(BojiMotion2.state) {
                appliedModifierNotice = "改好了：\(title)"
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                withAnimation { appliedModifierNotice = nil }
            }
        } label: {
            HStack(spacing: BojiLayout.tight) {
                Image(systemName: systemImage)
                    .bojiType(.caption)
                Text(title)
                    .bojiType(.caption)
            }
            .foregroundStyle(BojiColor.textSecondary)
            .padding(.horizontal, BojiLayout.inline)
            .padding(.vertical, BojiLayout.tight)
            .background(BojiColor.subtleSurface, in: Capsule())
            .overlay { Capsule().stroke(BojiColor.outline, lineWidth: 0.5) }
        }
        .buttonStyle(.plain)
    }

    // MARK: - 核心层级 3: 代谢与营养平衡板
    private var fuelBalanceCard: some View {
        let totalCal = today.meals.reduce(0.0) { $0 + $1.calories }
        let targetCal = today.nutritionTarget?.caloriesMax ?? store.state.nutritionTarget?.caloriesMax ?? 2350
        let calProgress = targetCal > 0 ? min(1.0, totalCal / targetCal) : 0
        let calDeficit = max(0, Int(targetCal - totalCal))

        let totalProtein = today.meals.reduce(0.0) { $0 + $1.protein }
        let targetProtein = today.nutritionTarget?.proteinMax ?? store.state.nutritionTarget?.proteinMax ?? 160

        let totalCarbs = today.meals.reduce(0.0) { $0 + $1.carbs }
        let targetCarbs = 260.0

        let totalFat = today.meals.reduce(0.0) { $0 + $1.fat }
        let targetFat = today.nutritionTarget?.fatMax ?? store.state.nutritionTarget?.fatMax ?? 65

        return VStack(alignment: .leading, spacing: BojiLayout.rowGap) {
            HStack {
                Label("今天吃了多少", systemImage: "fork.knife")
                    .bojiFont(.label)
                    .foregroundStyle(BojiColor.textPrimary)
                    .padding(.horizontal, BojiLayout.inline)
                    .padding(.vertical, BojiLayout.tight)
                    .background(BojiColor.brandMist, in: Capsule())

                Spacer()

                Button(action: onRecordMeal) {
                    HStack(spacing: BojiLayout.tight) {
                        Image(systemName: "camera.viewfinder")
                            .bojiType(.label)
                        Text("记录餐食")
                            .bojiType(.label)
                    }
                    .foregroundStyle(BojiColor.brandAccent)
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: BojiLayout.tight) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(Int(totalCal))")
                        .bojiType(.title)
                        .foregroundStyle(BojiColor.textPrimary)
                    Text("/ \(Int(targetCal)) kcal")
                        .bojiType(.secondary)
                        .foregroundStyle(BojiColor.textSecondary)

                    Spacer()

                    Text(calDeficit > 0 ? "还差 \(calDeficit) kcal" : "目标已达成")
                        .bojiType(.caption)
                        .foregroundStyle(BojiColor.textTertiary)
                }

                // 细线进度条
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(BojiColor.inputSurface)
                            .frame(height: 5)
                        Capsule()
                            .fill(BojiColor.brandAccent)
                            .frame(width: max(0, geo.size.width * CGFloat(calProgress)), height: 5)
                    }
                }
                .frame(height: 5)
            }

            // 三大宏量营养素条
            HStack(spacing: BojiLayout.rowGap) {
                macroItem(title: "蛋白质", current: totalProtein, target: targetProtein, color: BojiColor.macroProtein)
                macroItem(title: "碳水", current: totalCarbs, target: targetCarbs, color: BojiColor.macroCarbs)
                macroItem(title: "脂肪", current: totalFat, target: targetFat, color: BojiColor.macroFat)
            }
        }
        .padding(BojiLayout.cardInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BojiColor.cardSurface, in: RoundedRectangle(cornerRadius: BojiRadius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: BojiRadius.card, style: .continuous)
                .stroke(BojiColor.outline, lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.04), radius: 10, x: 0, y: 3)
    }

    private func macroItem(title: String, current: Double, target: Double, color: Color) -> some View {
        let progress = target > 0 ? min(1.0, current / target) : 0
        return VStack(alignment: .leading, spacing: BojiLayout.tight) {
            HStack {
                Text(title)
                    .bojiType(.caption)
                    .foregroundStyle(BojiColor.textTertiary)
                Spacer()
                Text("\(Int(current))g")
                    .bojiType(.caption)
                    .foregroundStyle(BojiColor.textPrimary)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(BojiColor.inputSurface)
                        .frame(height: 3)
                    Capsule()
                        .fill(color)
                        .frame(width: max(0, geo.size.width * CGFloat(progress)), height: 3)
                }
            }
            .frame(height: 3)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 核心层级 4: 智能分析专区 (Fitness Intelligence)
    private var intelligenceHubSection: some View {
        VStack(alignment: .leading, spacing: BojiLayout.rowGap) {
            HStack {
                Label("分析", systemImage: "sparkles")
                    .bojiType(.body)
                    .foregroundStyle(BojiColor.textPrimary)
                Spacer()
                Text("三大报告")
                    .bojiType(.caption)
                    .foregroundStyle(BojiColor.textTertiary)
            }

            VStack(spacing: BojiLayout.inline) {
                // 1. AI 训练计划
                Button(action: onArrangePlan131) {
                    intelligenceFeatureRow(
                        title: "训练计划",
                        roleTag: "排计划",
                        detail: "帮你排周期，动作按你的器械挑",
                        symbol: "calendar.badge.clock",
                        accentColor: BojiColor.brandGold
                    )
                }
                .buttonStyle(.plain)

                Divider().opacity(0.4)

                // 2. AI 每日日报
                Button(action: onOpenDailyReport) {
                    let hasConfirmed = today.trainingLog.hasConfirmedTraining
                    intelligenceFeatureRow(
                        title: "日报",
                        roleTag: "看今天",
                        detail: hasConfirmed ? "今天练完了，数据和建议都在里面" : "今天练得怎样、吃得怎样、明天怎么恢复",
                        symbol: "sun.max",
                        accentColor: .orange
                    )
                }
                .buttonStyle(.plain)

                Divider().opacity(0.4)

                // 3. AI 每周周报
                Button(action: onOpenWeeklyReport) {
                    intelligenceFeatureRow(
                        title: "周报",
                        roleTag: "看这周",
                        detail: "这周练了几天、重量有没有涨、身形变化",
                        symbol: "chart.xyaxis.line",
                        accentColor: .blue
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(BojiLayout.rowGap)
            .background(BojiColor.cardSurface, in: RoundedRectangle(cornerRadius: BojiRadius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: BojiRadius.card, style: .continuous)
                    .stroke(BojiColor.outline, lineWidth: 0.5)
            }
        }
    }

    private func intelligenceFeatureRow(title: String, roleTag: String, detail: String, symbol: String, accentColor: Color) -> some View {
        HStack(spacing: BojiLayout.rowGap) {
            Image(systemName: symbol)
                .bojiType(.body)
                .foregroundStyle(accentColor)
                .frame(width: 32, height: 32)
                .background(accentColor.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: BojiLayout.tight) {
                    Text(title)
                        .bojiType(.secondary)
                        .foregroundStyle(BojiColor.textPrimary)
                    Text(roleTag)
                        .bojiType(.caption)
                        .padding(.horizontal, BojiLayout.tight)
                        
                        .background(BojiColor.subtleSurface, in: Capsule())
                        .foregroundStyle(BojiColor.textSecondary)
                }
                Text(detail)
                    .bojiType(.caption)
                    .foregroundStyle(BojiColor.textTertiary)
                    .lineLimit(1)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .bojiType(.caption)
                .foregroundStyle(BojiColor.textTertiary)
        }
        .padding(.vertical, BojiLayout.tight)
    }

    private var newUserDivergenceCard: some View {
        VStack(spacing: BojiLayout.cardInset) {
            Text("欢迎加入薄肌俱乐部，请选择你的训练起步方式：")
                .bojiType(.secondary)
                .foregroundStyle(BojiColor.textSecondary)
                .multilineTextAlignment(.center)

            // Branch 1: 已有训练安排
            Button {
                BojiHaptics.success()
                Task {
                    try? await account.completeOnboarding()
                    account.enterClub()
                }
            } label: {
                HStack(spacing: BojiLayout.rowGap) {
                    Image(systemName: "checkmark.circle.fill")
                        .bojiType(.section)
                        .foregroundStyle(BojiColor.brandAccent)
                    VStack(alignment: .leading, spacing: BojiLayout.tight) {
                        Text("我已有自己的训练安排")
                            .bojiType(.bodyStrong)
                            .foregroundStyle(BojiColor.textPrimary)
                        Text("直接开始记录与训练，无需多余设置")
                            .bojiType(.caption)
                            .foregroundStyle(BojiColor.textSecondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .bojiType(.secondary)
                        .foregroundStyle(BojiColor.textTertiary)
                }
                .padding(BojiLayout.cardInset)
                .background(BojiColor.cardSurface, in: RoundedRectangle(cornerRadius: BojiRadius.inner, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: BojiRadius.inner, style: .continuous)
                        .stroke(BojiColor.outline, lineWidth: 0.5)
                }
            }
            .buttonStyle(.plain)

            // Branch 2: 无计划，需要协助
            VStack(alignment: .leading, spacing: BojiLayout.rowGap) {
                HStack(spacing: BojiLayout.rowGap) {
                    Image(systemName: "wand.and.stars")
                        .bojiType(.section)
                        .foregroundStyle(BojiColor.brandAccent)
                    VStack(alignment: .leading, spacing: BojiLayout.tight) {
                        Text("我还没有计划，需要协助")
                            .bojiType(.bodyStrong)
                            .foregroundStyle(BojiColor.textPrimary)
                        Text("看现成方案，或者让我们帮你排")
                            .bojiType(.caption)
                            .foregroundStyle(BojiColor.textSecondary)
                    }
                    Spacer()
                }

                HStack(spacing: BojiLayout.inline) {
                    Button {
                        showPresetPlans = true
                    } label: {
                        HStack(spacing: BojiLayout.tight) {
                            Image(systemName: "rectangle.stack.badge.play")
                                .bojiType(.caption)
                            Text("挑选经典方案")
                                .bojiType(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .foregroundStyle(BojiColor.textPrimary)
                        .background(BojiColor.subtleSurface, in: RoundedRectangle(cornerRadius: BojiRadius.thumb, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    Button {
                        onArrangePlan131()
                    } label: {
                        HStack(spacing: BojiLayout.tight) {
                            Image(systemName: "calendar.badge.plus")
                                .bojiType(.caption)
                            Text("制定训练计划")
                                .bojiType(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .foregroundStyle(Color.black)
                        .background(BojiColor.brandAccent, in: RoundedRectangle(cornerRadius: BojiRadius.thumb, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(BojiLayout.cardInset)
            .background(BojiColor.cardSurface, in: RoundedRectangle(cornerRadius: BojiRadius.inner, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: BojiRadius.inner, style: .continuous)
                    .stroke(BojiColor.outline, lineWidth: 0.5)
            }
        }
        .padding(.horizontal, BojiLayout.tight)
    }
}

/// One compact accessory shares the shell's single bottom layout with the composer.
private struct ClubActiveWorkoutAccessory: View {
    let snapshot: ActiveWorkoutSnapshot
    let open: () -> Void
    let togglePause: () -> Void
    var body: some View {
        HStack(spacing: BojiLayout.rowGap) {
            Button(action: open) {
                HStack(spacing: BojiLayout.inline) {
                    BojiBrandMark(size: 30)
                    VStack(alignment: .leading, spacing: BojiLayout.tight) {
                        HStack(spacing: BojiLayout.inline) {
                            Text(snapshot.isPaused ? "训练已暂停" : "训练进行中").bojiType(.secondary)
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                let seconds = max(0, Int(snapshot.elapsed(at: context.date)))
                                Text(String(format: "%02d:%02d", seconds / 60, seconds % 60))
                                    .bojiType(.secondary)
                            }
                        }
                        Text("点击返回训练 · 记了 \(snapshot.completedSets)/\(snapshot.totalSets) 组").bojiType(.caption).foregroundStyle(BojiColor.textPrimary)
                    }
                    Spacer(minLength: 0)
                }.frame(minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("native-resume-workout")
            Button(action: togglePause) {
                Image(systemName: snapshot.isPaused ? "play.fill" : "pause.fill").frame(width: 44, height: 44)
            }
            .frame(width: 44, height: 44).contentShape(Rectangle()).layoutPriority(1)
            .buttonStyle(.bordered).buttonBorderShape(.circle)
            .accessibilityLabel(snapshot.isPaused ? "继续训练" : "暂停训练")
        }
        .padding(.horizontal, BojiLayout.rowGap).padding(.vertical, BojiLayout.tight)
        .clubGlassEffect(in: RoundedRectangle(cornerRadius: BojiRadius.card, style: .continuous))
        .accessibilityIdentifier("mini-workout-bar")
    }
}

struct V2SettingsMenuView: View {
    var body: some View { SettingsHub130() }
}

private struct ClubSidebarListPolicy: ViewModifier {
    let floating: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if floating { content.listStyle(.plain) }
        else { content.listStyle(.sidebar) }
    }
}

/// 首页两拍进场（DES-004）：规范 §4.1 浮件进场 spring 0.35/0.85 + stagger 0.05 + scale 0.96→1。
private struct BojiHomeEntrance: ViewModifier {
    let revealed: Bool
    let reduceMotion: Bool
    let index: Int
    func body(content: Content) -> some View {
        content
            .opacity(revealed || reduceMotion ? 1 : 0)
            .scaleEffect(revealed || reduceMotion ? 1 : 0.96)
            .animation(BojiMotion2.resolved(BojiMotion2.entrance, reduceMotion: reduceMotion)?
                .delay(Double(index) * BojiMotion2.stagger), value: revealed)
    }
}

extension View {
    func bojiHomeEntrance(revealed: Bool, reduceMotion: Bool, index: Int) -> some View {
        modifier(BojiHomeEntrance(revealed: revealed, reduceMotion: reduceMotion, index: index))
    }
}
