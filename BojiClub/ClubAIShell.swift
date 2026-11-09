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
                // BUG-020：坞挂进训练 tab 内容层（safeAreaInset 自动为 tab 栏让位），不再叠压 tab 栏
                ClubPlanHub(selectedDate: $selectedDate, openWorkout: startTrainingFromPlan, embeddedInShell: true, scrollAnchor: $trainingScrollAnchor, calendarExpanded: $calendarExpanded)
                    .clubBottomBar { bottomDock }
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
            // BUG-020：挂在 shell 层会叠到 tab 栏上，改挂训练 tab 内容层让系统自动避让。
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
    @State private var showScoreBreakdown = false
    @ObservedObject private var flags = FeatureFlagService.shared

    private var today: DayLog { store.log(for: Date()) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BojiLayout.blockGap) {
                // 返工·三段式 Hero：视频带（仅 12pt 品牌小字+暂停钮）→ 页面底色排印区（巨号评分+指标+建议）
                heroGlassCard
                    .bojiHomeEntrance(revealed: revealed, reduceMotion: reduceMotion, index: 0)

                // 首个内容区块与 Hero 构成两拍进场（stagger，DES-004）
                Group {
                    if isNewUser {
                        newUserDivergenceCard
                    }
                }
                .bojiHomeEntrance(revealed: revealed, reduceMotion: reduceMotion, index: 1)

                // 细线数据条（施工卡 §二）：无值不渲染，三项全无换引导卡
                heroMetricStrip
                    .bojiHomeEntrance(revealed: revealed, reduceMotion: reduceMotion, index: 2)

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
                            .imageScale(.large)
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
            // 甲-1 §四：列表底部预留 78pt（主操作 54 + 24），不再硬编码 96/84
            .padding(.bottom, BojiLayout.actionClearance)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .clubTrackScrollY { heroScrollY = $0 }
        // 甲-1 §四：本屏唯一主操作 = B1 玻璃胶囊 54，走 safeAreaInset 让系统为 tab 栏避让
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button(action: homePrimaryAction) {
                Text(homePrimaryLabel)
                    .frame(maxWidth: .infinity, minHeight: BojiLayout.actionHeight)
                    .contentShape(Rectangle())
                    // 玻璃 buttonStyle 会包一层，标识放 label 内层才查得到（巡检 R01 断言用）
                    .accessibilityIdentifier("v2-home-primary")
            }
            .clubNativeGlassButton(prominent: true)
            .accessibilityIdentifier("v2-home-primary")
            .padding(.horizontal, BojiLayout.pageInset)
            .padding(.bottom, BojiLayout.inline)
        }
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
        .sheet(isPresented: $showScoreBreakdown) {
            NavigationStack {
                scoreBreakdownCard
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { showScoreBreakdown = false } } }
            }
            .presentationDetents([.medium, .large])
        }
        .background(BojiColor.pageBackground)
        .accessibilityIdentifier("v2-ai-workspace")
    }

    // MARK: - 顶部标题区
    /// Hero 三段式（施工卡 §一）：视频带（只有品牌小字 + 暂停钮）→ 页面底色排印区 → 细线数据条。
    /// 滚动收缩玻璃条已废止并删除（规范 §2 最高优先级；组件已于 `63e0b27` 移除）：
    /// 主操作交给底部玻璃胶囊，滚动动效走 M6 视差（`clubTrackScrollY` 继续喂 `heroParallaxProgress`）。
    private var heroGlassCard: some View {
        TimelineView(.animation(minimumInterval: 0.05, paused: reduceMotion)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 14) / 14
            VStack(alignment: .leading, spacing: 0) {
                heroVideoBand(phase: phase, empty: heroReadiness.score == nil)
                heroTypeBlock
            }
        }
        .onAppear { revealed = true; setupHeroVideo() }
        .onDisappear { teardownHeroVideo() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { heroPlayer?.play() } else { heroPlayer?.pause() }
        }
    }

    /// M6 滚动视差进度（0…1，200pt 内走完）：视频带 0.3 倍速、缩放 1→0.96、淡出至 0.85。
    private var heroParallaxProgress: CGFloat {
        guard !reduceMotion else { return 0 }
        return min(1, max(0, heroScrollY / 200))
    }

    /// M6 视差：媒体层比页面慢（在裁切框内下移），同时轻微缩放与淡出；减动效恒定不动。
    /// 缩放永远 ≥1.0，保证媒体始终铺满裁切框（缩到 1 以下会露底色）。
    private struct HeroParallax: ViewModifier {
        let progress: CGFloat
        let reduceMotion: Bool
        func body(content: Content) -> some View {
            content
                .scaleEffect(reduceMotion ? 1.08 : 1.08 - 0.08 * progress)
                .offset(y: reduceMotion ? 0 : progress * 40)
                .opacity(reduceMotion ? 1 : 1 - 0.15 * progress)
        }
    }

    /// 第一段：视频带（甲稿权威值：有数据 238pt / 空态 200pt，300 作废）。
    /// 除品牌小字（12pt）与暂停钮（44pt 命中区）外零文字——>20pt 禁止压媒体。
    private func heroVideoBand(phase: Double, empty: Bool) -> some View {
        ZStack(alignment: .top) {
            // z0 首帧占位（未就绪/减少动态效果/低电量时持续显示，视频就绪后叠在其上无缝切换）
            Group {
                if let heroPoster {
                    Image(uiImage: heroPoster)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle()
                        .fill(BojiColor.brandMist.opacity(0.55))
                }
            }
            .modifier(HeroParallax(progress: heroParallaxProgress, reduceMotion: reduceMotion))
            .clipped()
            .accessibilityHidden(true)
            .allowsHitTesting(false)
            // z0b 视频层（就绪后叠加）
            if let heroPlayer {
                HeroVideoSurface(player: heroPlayer)
                    .modifier(HeroParallax(progress: heroParallaxProgress, reduceMotion: reduceMotion))
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
            }
            // 深色模式压暗
            if colorScheme == .dark { Color.black.opacity(0.2) }
            // z2 慢周期流光（非循环）
            LinearGradient(
                colors: [ClubBrand.accent.opacity(0), ClubBrand.accent.opacity(0.30), ClubBrand.accent.opacity(0)],
                startPoint: .leading, endPoint: .trailing
            )
            .offset(x: -220 + 440 * phase)
            // 底部 52pt 渐隐：视频与页面底色缝合（施工卡 §一 权威值；不再需要压字渐变）
            VStack {
                Spacer(minLength: 0)
                LinearGradient(colors: [Color.clear, BojiColor.pageBackground], startPoint: .top, endPoint: .bottom)
                    .frame(height: 52)
                    .allowsHitTesting(false)
            }
            // 顶栏：左上品牌小字 T5 11（白 0.94 + 1px 黑投影）；右上暂停钮（视觉 30、命中 44×44、玻璃）
            HStack(alignment: .top) {
                Text("薄肌俱乐部")
                    .bojiType(.caption)
                    .foregroundStyle(.white.opacity(0.94))
                    .shadow(color: .black.opacity(0.4), radius: 1)
                Spacer()
                Button {
                    if heroPlayer?.timeControlStatus == .playing { heroPlayer?.pause() } else { heroPlayer?.play() }
                } label: {
                    Image(systemName: heroPlayer?.timeControlStatus == .playing ? "pause.fill" : "play.fill")
                        .imageScale(.medium)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                }
                .clubNativeGlassButton()
                .frame(width: 44, height: 44)
                .contentShape(Circle())
                .accessibilityLabel(heroPlayer?.timeControlStatus == .playing ? "暂停视频" : "播放视频")
            }
            .padding(.leading, 14)
            .padding(.trailing, 11)
            .padding(.top, 13)
        }
        .frame(height: empty ? 200 : 238)
        .frame(maxWidth: .infinity)
        // 施工卡 §一：C1 24 圆角 + 上留 10（左右 20 由页面 pageInset 提供，不重复加）
        .clipShape(RoundedRectangle(cornerRadius: BojiLayout.Radius.card, style: .continuous))
        .padding(.top, 10)
    }

    /// 细线数据条的一项（施工卡 §二：标签 T5 11 + 数值 T2 28 + 可选单位）。
    private struct HeroMetric {
        let label: String
        let value: String
        let unit: String?
    }

    private struct HeroReadiness {
        let score: Int?
        let breakdown: ScoreBreakdown?
        let metrics: [HeroMetric]
    }

    /// 排印区数据源：真实健康值 + 诚实评分；无关键数据 → score nil，无值指标整块不渲染（不摆 0/—）。
    private var heroReadiness: HeroReadiness {
        let healthSummary = health.summary(for: Date())
        let sleepMin = healthSummary?.nightSleep?.value ?? healthSummary?.sleep?.value
        let sleepText = sleepMin.flatMap { min -> String? in
            guard min > 0 else { return nil }
            return "\(Int(min / 60))h \(Int(min) % 60)m"
        }
        let rhr = healthSummary?.restingHeartRate?.value
        let rhrText = rhr.flatMap { val -> String? in
            guard val > 0 else { return nil }
            return "\(Int(val))"
        }
        let steps = healthSummary?.steps?.value
        let stepsText = steps.flatMap { val -> String? in
            guard val > 0 else { return nil }
            return "\(Int(val))"
        }
        var metrics: [HeroMetric] = []
        if let sleepText { metrics.append(HeroMetric(label: "睡眠", value: sleepText, unit: nil)) }
        if let rhrText { metrics.append(HeroMetric(label: "心率", value: rhrText, unit: "bpm")) }
        if let stepsText { metrics.append(HeroMetric(label: "步数", value: stepsText, unit: "步")) }
        let breakdown = scoreBreakdown(sleepMinutes: sleepMin, restingHeartRate: rhr)
        return HeroReadiness(score: breakdown?.total, breakdown: breakdown, metrics: metrics)
    }

    /// 第二段（施工卡 §一 C 区）：页面底色上的排印区——eyebrow T5 + 巨号 T1 88 +「状态分」T5 + 一句话 T4 15。
    /// 空态不摆数字与 0/—，改出今天的安排句（T2 28）。文字全部在页面底色上，绝不压视频。
    private var heroTypeBlock: some View {
        let data = heroReadiness
        let insight = ClubHomeInsightMerge.resolve(local: ClubInsightLedger.current(in: store.state, date: Date()).first, server: ai.homeInsight)
        let planLead = today.exercises.prefix(2).map(\.displayName).joined(separator: " · ")

        return VStack(alignment: .leading, spacing: 0) {
            Text("今天 · \(ClubDates.label(Date(), format: "M月d日 EEEE"))")
                .bojiType(.caption)
                .foregroundStyle(BojiColor.textTertiary)
                .padding(.bottom, BojiLayout.tight)

            if let score = data.score {
                // 巨号评分当主角（T1 88 heavy 等宽，M8 数字滚动在组件内），右侧「状态分 ›」可点看分项构成
                Button { showScoreBreakdown = true } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        BojiEditorialNumber(value: "\(score)")
                        Text("状态分 ›")
                            .bojiType(.caption)
                            .foregroundStyle(BojiColor.textTertiary)
                            .bojiHomeEntrance(revealed: revealed, reduceMotion: reduceMotion, index: 1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("v2-home-score-detail")
                .accessibilityLabel("状态分 \(score)，点按查看怎么算的")
            } else {
                Text(today.exercises.isEmpty ? "今天还没排训练" : "今天练 \(planLead)")
                    .bojiType(.title)
                    .foregroundStyle(BojiColor.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // 一句话（T4 15）：绑定真实洞察，无洞察整块隐藏
            if let insight {
                Text(insight.title)
                    .bojiType(.body15)
                    .foregroundStyle(BojiColor.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }
        }
        .padding(.horizontal, BojiLayout.pageInset)
        .padding(.top, 16)
        .padding(.bottom, BojiLayout.inline)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 细线数据条（施工卡 §二）：数值 T2 28 + 单位与标签 T5 11，上下发丝线、列间竖发丝线；
    /// 无值指标整块不渲染；三项全无 → 引导卡（T3 标题 + T4 说明 + B2 44「去连接」）。
    private var heroMetricStrip: some View {
        let metrics = heroReadiness.metrics
        return Group {
            if metrics.isEmpty {
                // 甲-2 空态引导卡（大改稿 §② mock + 施工卡 ④ 裁决）：细边框卡 + B2 44 描边「去连接」
                // ——同屏底部已有 B1「开始练」，「去连接」不升 B1，避免两个主操作；连接是增益不是门槛。
                VStack(alignment: .leading, spacing: BojiLayout.tight) {
                    // 文案定稿 §19.2 场景 1：符号 + 单句 15pt（守 R5）+「去连接」44 胶囊
                    Image(systemName: "heart.text.square")
                        .font(.system(size: 44))
                        .foregroundStyle(BojiColor.textTertiary)
                    Text("连上 Apple 健康，这里有睡眠、心率和训练")
                        .bojiType(.body15)
                        .foregroundStyle(BojiColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("去连接", action: onOpenPermissions)
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .bojiType(.body15)
                        .frame(maxWidth: .infinity, minHeight: BojiLayout.controlHeight)
                        .padding(.top, BojiLayout.tight)
                }
                .padding(BojiLayout.cardInset)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay {
                    RoundedRectangle(cornerRadius: BojiLayout.Radius.card, style: .continuous)
                        .stroke(BojiColor.divider, lineWidth: BojiLayout.hairline)
                }
                // 不挡路的次要出口（mock §② .ghost）：灰字一行，主操作仍是底部「开始练」
                Text("也可以直接开始练，之后补都行")
                    .bojiType(.caption)
                    .foregroundStyle(BojiColor.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, BojiLayout.tight)
            } else {
                // 细线数据条走唯一指标组件（规格表 §2.6），跨页同名指标同一档同一字重
                MetricRowGroup(metrics: metrics.map {
                    MetricValue(value: $0.value, unit: $0.unit, label: $0.label)
                })
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("v2-home-metrics")
    }

    /// 本屏唯一主操作文案（定稿 G5：开始练 / 继续练 / 记一顿 / 记体重 / 去连接）
    private var homePrimaryLabel: String {
        if activeWorkout != nil { return "继续练" }
        if today.exercises.isEmpty || today.trainingLog.hasConfirmedTraining { return "记一顿" }
        return "开始练"
    }

    private func homePrimaryAction() {
        // 三联动：触感 + 音效随按压（减动效只关动效，触感与音效照常）
        BojiHaptics.selection()
        BojiSound.play(.tap)
        if homePrimaryLabel == "记一顿" { onRecordMeal() } else { onStartTraining() }
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

    // MARK: - 身体状态评分（巨号排印当主角；评分=睡眠+心率+近 3 天训练的真实规则，缺数据说缺）
    /// 状态分构成：睡眠 50（7.5 小时满）、静息心率 30（越低越好，65 断点）、近 3 天训练 20（练过）/6（没练）。
    struct ScoreBreakdown {
        let total: Int
        let sleep: Int
        let heart: Int
        let training: Int
        /// 缺数据的那项分值写「未同步」，不写 `0 / 50`（口径表 §5.3：0 分会被读成"我这项很差"）。
        let missingSleep: Bool
        let missingHeart: Bool
    }

    /// 关键项（睡眠与心率）都没同步到时返回 nil，界面不给分，绝不编造分数。
    private func scoreBreakdown(sleepMinutes: Double?, restingHeartRate: Double?) -> ScoreBreakdown? {
        guard sleepMinutes != nil || restingHeartRate != nil else { return nil }
        let sleepPoints: Double = {
            guard let sleep = sleepMinutes, sleep > 0 else { return 0 }
            return min(1.0, sleep / (7.5 * 60)) * 50
        }()
        let heartPoints: Double = {
            guard let rhr = restingHeartRate, rhr > 0 else { return 0 }
            return rhr <= 65 ? 30 : max(8, 30 - (rhr - 65) * 0.8)
        }()
        let calendar = ClubDates.calendar
        let trainedRecently = (0..<3).contains { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: Date()),
                  let day = store.state.days[ClubDates.key(date)] else { return false }
            return day.trainingLog.hasConfirmedTraining
        }
        let trainingPoints: Double = trainedRecently ? 20 : 6
        // 一票否决项：总分必须由「已取整的分项」相加得出，三项与巨号同源，用户自己加永远相等。
        let sleepInt = Int(sleepPoints.rounded())
        let heartInt = Int(heartPoints.rounded())
        let trainingInt = Int(trainingPoints)
        let total = min(100, max(0, sleepInt + heartInt + trainingInt))
        return ScoreBreakdown(total: total, sleep: sleepInt, heart: heartInt, training: trainingInt,
                              missingSleep: (sleepMinutes ?? 0) <= 0,
                              missingHeart: (restingHeartRate ?? 0) <= 0)
    }

    private func readinessScore(sleepMinutes: Double?, restingHeartRate: Double?) -> Int? {
        scoreBreakdown(sleepMinutes: sleepMinutes, restingHeartRate: restingHeartRate)?.total
    }

    /// 状态分分项卡（信息感裁决③：点「状态分 ›」弹出，写清算法，不加首页文字行）。
    private var scoreBreakdownCard: some View {
        let data = heroReadiness
        return VStack(alignment: .leading, spacing: BojiLayout.rowGap) {
            Text("状态分怎么来的")
                .bojiType(.title)
                .foregroundStyle(BojiColor.textPrimary)

            if let score = data.score, let b = data.breakdown {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    BojiEditorialNumber(value: "\(score)")
                    Text("今天")
                        .bojiType(.caption)
                        .foregroundStyle(BojiColor.textTertiary)
                }
                VStack(spacing: 0) {
                    breakdownRow(label: "睡眠", anchor: "睡够 7.5 小时记 50 分，按实际时长折算", value: b.sleep, of: 50, unsynced: b.missingSleep)
                    breakdownRow(label: "静息心率", anchor: "65 次/分记 30 分，越高越低，最低也记 8 分", value: b.heart, of: 30, unsynced: b.missingHeart)
                    breakdownRow(label: "近三天练过", anchor: "练过记 20 分，没练过也记 6 分", value: b.training, of: 20)
                }
                .overlay(alignment: .top) { Rectangle().fill(BojiColor.divider).frame(height: BojiLayout.hairline) }
                // 施工卡 §〇之三解释句定稿三行（界面设计 2026-11-09）：两句正文 + 心率下限脚注。
                // 「连上 Apple 健康就能拿满」已删——训练项满分靠近三天真练过，与连接无关。
                Text("就这三项相加。没同步到的那项按 0 分算，其余照常算。")
                    .bojiType(.body15)
                    .foregroundStyle(BojiColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("练过记 20 分，没练过也记 6 分。")
                    .bojiType(.body15)
                    .foregroundStyle(BojiColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("静息心率最低也给 8 分。")
                    .bojiType(.caption)
                    .foregroundStyle(BojiColor.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("今天还没拿到睡眠和心率，先不给分。")
                    .bojiType(.body15)
                    .foregroundStyle(BojiColor.textSecondary)
                Button("去连接", action: onOpenPermissions)
                    .clubNativeGlassButton()
                    .frame(maxWidth: .infinity, minHeight: BojiLayout.controlHeight)
            }
            Spacer(minLength: 0)
        }
        .padding(BojiLayout.pageInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BojiColor.pageBackground)
        .accessibilityIdentifier("v2-score-breakdown")
    }

    /// 分项行（施工卡 §〇之三定稿）：标签 T3 17 + 锚点 T5 11 + 右侧分值；
    /// 缺数据的那项分值写「未同步」，绝不出现 `0 / 50`。
    private func breakdownRow(label: String, anchor: String, value: Int, of: Int, unsynced: Bool = false) -> some View {
        HStack(alignment: .center, spacing: BojiLayout.inline) {
            VStack(alignment: .leading, spacing: BojiLayout.tight) {
                Text(label)
                    .bojiType(.data)
                    .fontWeight(.semibold)
                    .foregroundStyle(BojiColor.textPrimary)
                Text(anchor)
                    .bojiType(.caption)
                    .foregroundStyle(BojiColor.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: BojiLayout.inline)
            if unsynced {
                Text("未同步")
                    .bojiType(.caption)
                    .foregroundStyle(BojiColor.textTertiary)
            } else {
                Text("\(value)/\(of)")
                    .bojiTypeFixed(.title, monospacedDigits: true)
                    .foregroundStyle(BojiColor.textPrimary)
            }
        }
        .padding(.vertical, 13)
        .overlay(alignment: .bottom) { Rectangle().fill(BojiColor.divider).frame(height: BojiLayout.hairline) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(unsynced ? "\(label) 未同步。\(anchor)" : "\(label) \(value) 分，满分 \(of)。\(anchor)")
    }

    // MARK: - 今天安排（施工卡 §三：编号 + 名称 + 组次右对齐 + 发丝线；不套卡，屏内主操作只留底部那一个）
    private var heroMissionCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(activeWorkout == nil ? "今天安排" : "正在练")
                    .bojiType(.caption)
                    .fontWeight(.semibold)
                    .tracking(0.8)
                    .foregroundStyle(BojiColor.textTertiary)
                Spacer()
                if let active = activeWorkout {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let seconds = max(0, Int(active.elapsed(at: context.date)))
                        Text(String(format: "%02d:%02d", seconds / 60, seconds % 60))
                            .bojiType(.caption, monospacedDigits: true)
                            .foregroundStyle(BojiColor.textSecondary)
                    }
                } else if !today.exercises.isEmpty {
                    Button { onOpenHub("训练计划") } label: {
                        Text("全部 ›")
                            .bojiType(.caption)
                            .foregroundStyle(BojiColor.textSecondary)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("v2-home-all-plan")
                }
            }
            .padding(.bottom, BojiLayout.inline)

            if let active = activeWorkout {
                // 训练进行中：巨号那句已报「完成几组」，这里只给新信息（去重）
                VStack(alignment: .leading, spacing: BojiLayout.tight) {
                    Text(active.workoutName)
                        .bojiType(.data)
                        .foregroundStyle(BojiColor.textPrimary)
                    let left = max(0, active.totalSets - active.completedSets)
                    Text(left > 0 ? "还剩 \(left) 组 · 约 \(left * 3) 分钟" : "就剩最后一组，练完能看日报")
                        .bojiType(.body15)
                        .foregroundStyle(BojiColor.textSecondary)
                }
                .padding(.bottom, BojiLayout.inline)
            } else if today.exercises.isEmpty {
                VStack(alignment: .leading, spacing: BojiLayout.tight) {
                    Text("今天没排力量训练")
                        .bojiType(.data)
                        .foregroundStyle(BojiColor.textPrimary)
                    Text("想动就拉伸，蛋白质吃够。")
                        .bojiType(.body15)
                        .foregroundStyle(BojiColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.bottom, BojiLayout.inline)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(today.exercises.prefix(6).enumerated()), id: \.element.id) { index, exercise in
                        HStack(alignment: .firstTextBaseline, spacing: 11) {
                            Text(String(format: "%02d", index + 1))
                                .bojiType(.caption, monospacedDigits: true)
                                .foregroundStyle(BojiColor.textTertiary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(exercise.displayName)
                                    .bojiType(.data)
                                    .foregroundStyle(BojiColor.textPrimary)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(exercise.muscle)
                                    .bojiType(.caption)
                                    .foregroundStyle(BojiColor.textTertiary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: BojiLayout.inline)
                            Text("\(exercise.sets.count)×\(exercise.sets.first?.reps ?? 0)")
                                .bojiType(.caption, monospacedDigits: true)
                                .foregroundStyle(BojiColor.textSecondary)
                        }
                        .padding(.vertical, 13)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(BojiColor.divider).frame(height: BojiLayout.hairline)
                        }
                        // 反向红线：stagger 只做前 6 行，第 7 行起不做动画（多了拖沓）
                        .modifier(BojiStaggerFirstSix(index: index, revealed: revealed, reduceMotion: reduceMotion))
                    }
                }
                .overlay(alignment: .top) { Rectangle().fill(BojiColor.divider).frame(height: BojiLayout.hairline) }
            }

            // AI 快捷微调胶囊（保留：单手一键微调，次操作不是主操作）
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
            .padding(.top, BojiLayout.inline)
        }
        .accessibilityIdentifier("v2-home-mission")
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

    // MARK: - 核心层级 3: 今天吃了多少（细线数据条，空态不摆 0）
    private var fuelBalanceCard: some View {
        let known = today.knownMeals
        let totalCal = known.reduce(0.0) { $0 + $1.calories }
        let targetCal = today.nutritionTarget?.caloriesMax ?? store.state.nutritionTarget?.caloriesMax ?? 2350
        let calProgress = targetCal > 0 ? min(1.0, totalCal / targetCal) : 0
        let calDeficit = max(0, Int(targetCal - totalCal))
        let totalProtein = known.reduce(0.0) { $0 + $1.protein }
        let totalCarbs = known.reduce(0.0) { $0 + $1.carbs }
        let totalFat = known.reduce(0.0) { $0 + $1.fat }

        return VStack(alignment: .leading, spacing: BojiLayout.rowGap) {
            HStack {
                Text("今天吃了多少")
                    .bojiType(.caption)
                    .fontWeight(.semibold)
                    .tracking(0.8)
                    .foregroundStyle(BojiColor.textTertiary)
                Spacer()
                Button(action: onRecordMeal) {
                    Text("记一顿")
                        .bojiType(.caption)
                        .foregroundStyle(BojiColor.brandAccent)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("v2-home-record-meal")
            }

            if known.isEmpty {
                // 空态：不摆 0 kcal，一句说明 + 一句做什么（18.3 口径）
                VStack(alignment: .leading, spacing: BojiLayout.tight) {
                    Text("今天还没记吃的")
                        .bojiType(.data)
                        .foregroundStyle(BojiColor.textPrimary)
                    Text("记一顿，这里就开始算热量和蛋白质。")
                        .bojiType(.body15)
                        .foregroundStyle(BojiColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                VStack(alignment: .leading, spacing: BojiLayout.tight) {
                    MetricRowGroup(metrics: [
                        MetricValue(value: "\(Int(totalCal))", unit: "kcal", label: "摄入热量"),
                        MetricValue(value: "\(Int(totalProtein))", unit: "g", label: "蛋白质"),
                        MetricValue(value: "\(Int(totalCarbs))", unit: "g", label: "碳水"),
                        MetricValue(value: "\(Int(totalFat))", unit: "g", label: "脂肪")
                    ])
                    // 细线进度条（有数据才画）
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(BojiColor.inputSurface)
                                .frame(height: 3)
                            Capsule()
                                .fill(BojiColor.brandAccent)
                                .frame(width: max(0, geo.size.width * CGFloat(calProgress)), height: 3)
                        }
                    }
                    .frame(height: 3)
                    Text(calDeficit > 0 ? "还差 \(calDeficit) kcal 到目标" : "已到目标")
                        .bojiType(.caption)
                        .foregroundStyle(BojiColor.textTertiary)
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
        .accessibilityIdentifier("v2-home-fuel-card")
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
                        .frame(maxWidth: .infinity, minHeight: BojiLayout.controlHeight)
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
                        .frame(maxWidth: .infinity, minHeight: BojiLayout.controlHeight)
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

/// 列表 stagger 上限（动效规格反向红线）：只给前 6 行做进场错开，第 7 行起直接显示——
/// 全列表错开会拖沓，而且第 7 行多在首屏外，看不见却占着动画。
private struct BojiStaggerFirstSix: ViewModifier {
    let index: Int
    let revealed: Bool
    let reduceMotion: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if index < 6 {
            content.modifier(BojiHomeEntrance(revealed: revealed, reduceMotion: reduceMotion, index: index))
        } else {
            content
        }
    }
}
