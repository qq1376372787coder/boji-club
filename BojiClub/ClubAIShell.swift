import SwiftUI

/// Feature availability can change remotely; the AI-first app shell is permanent.
@MainActor
final class FeatureFlagService: ObservableObject {
    static let shared = FeatureFlagService()
    /// Kept as a read-only compatibility value for integrations with older configuration payloads.
    let aiNativeHome = true
    @Published private(set) var aiEnabled = true
    @Published private(set) var clubEnabled = true
    /// Phase 2 SSE. Server flag defaults to off; DEBUG can force it for local tests.
    @Published private(set) var streamingV2 = false
    @Published private(set) var referencesEnabled = false
    func apply(remote: ClubRemoteConfig?) {
        referencesEnabled = remote?.config.aiContextReferencesV1 ?? false
        aiEnabled = remote?.config.aiEnabled ?? true
        clubEnabled = remote?.config.clubEnabled ?? true
        #if DEBUG
        streamingV2 = ProcessInfo.processInfo.environment["BOJI_STREAMING_V2"] == "1" || (remote?.config.aiStreamingV2 ?? false)
        #else
        streamingV2 = remote?.config.aiStreamingV2 ?? false
        #endif
    }
}

/// 四个顶层工作区，对应 v3 原型的四个 Tab：主页 / 训练 / 记录 / 我的。
/// `.clubAI` 是主页（AI 收拢后这里只放日报、周报、AI 食物识别、AI 计划生成四个入口）。
enum ClubShellMode: Hashable { case clubAI, training, records, profile }
enum ClubSidebarRoute: String, Identifiable {
    case records, tasks, club, aiMemory, profile, settings, feedback
    var id: String { rawValue }
}

/// Owns navigation, draft and selected day independently from either workspace's view lifetime.
struct ClubAIShellView: View {
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
    @State private var mode: ClubShellMode = .clubAI
    @State private var sidebarOpen = false
    @State private var columns: NavigationSplitViewVisibility = .detailOnly
    @State private var aiPath = NavigationPath()
    @State private var trainingPath = NavigationPath()
    @State private var recordsPath131 = NavigationPath()
    @State private var trainingScrollAnchor: String?
    @State private var calendarExpanded = false
    @State private var recordsCategory = "训练"
    @State private var sidebarRoute: ClubSidebarRoute?
    @State private var showHubSection: String?
    @State private var mealEntryRoute: ClubComposerMealRoute?
    @State private var bodyEntryRoute: ClubDateRoute?
    @State private var showExerciseLibrary = false
    @State private var showTrainingPlans = false
    @State private var selectedDate = Date()
    @State private var currentDay = ClubDates.key(Date())
    @State private var trainingRoute: ClubTrainingRoute?
    @State private var restDeadlines: [String: ClubRestResume] = [:]
    @State private var creatingForDate: ClubTrainingRoute?
    @State private var guideOwner: ClubGuideOwner?
    @State private var keepsakeRoute = false
    @State private var showMembership = false
    @State private var showProfileBasics135 = false
    @State private var showPermissions135 = false
    @State private var showReports135 = false
    @State private var reportLibraryKind135: ReportLibraryKind = .all
    @State private var showLegacyOnboarding135 = false
    @State private var planSetupTask135: Task<Void, Never>?
    @State private var showFinishOnboarding135 = false
    @State private var reconcilingPlan135 = false
    @AccessibilityFocusState private var sidebarToggleFocused: Bool
    private var ownerID: Int? { store.editingAccountID }
    private var transitionAnimation: Animation? { reduceMotion ? nil : BojiMotion.smoothSpring() }

    private var shellNotices: some View {
        shellWithPresentations
            .onOpenURL(perform: handleURL)
            .onReceive(NotificationCenter.default.publisher(for: .clubDeviceSetupFinished)) { _ in presentGuideIfNeeded() }
            .onReceive(NotificationCenter.default.publisher(for:.profileFactsChanged133)) { note in
                if note.object as? Int == account.user?.id { Task { await onboarding.load(account:account);onboarding.applyFacts(to:store) } }
            }
            .onReceive(NotificationCenter.default.publisher(for: .clubShellReturnToToday)) { _ in
                mode = .clubAI; aiPath = NavigationPath()
            }
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
            .onReceive(NotificationCenter.default.publisher(for: .bojiPlanApplied135)) { note in
                guard let owner = note.userInfo?["owner"] as? Int, owner == ownerID,
                      let jobID = note.userInfo?["job"] as? String, account.user?.onboardingCompleted == false else { return }
                UserDefaults.standard.set(jobID, forKey: "boji.pendingPlan135.\(owner)")
                Task { await reconcilePlan135(owner: owner, jobID: jobID) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in refreshDay() }
            .task(id: account.user?.id) {
                guideOwner = nil
                await Task.yield()
                if account.user?.onboardingCompleted == false {
                    await onboarding.load(account: account)
                    onboarding.applyFacts(to: store)
                    if let owner = ownerID, let jobID = UserDefaults.standard.string(forKey: "boji.pendingPlan135.\(owner)") {
                        await reconcilePlan135(owner: owner, jobID: jobID)
                    }
                }
                presentGuideIfNeeded()
            }
            .task {
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
            .onChange(of: activeWorkout?.sessionID) { _, _ in refreshDay(); syncTrainingActivity() }
            .onChange(of: trainingRoute?.id) { _, id in store.trainingInterfacePresented = id != nil }
            .onAppear { refreshDay(); syncTrainingActivity() }
            .onChange(of: store.syncStatus) { _, value in
                if case .synced = value {
                    store.refreshClubInsights()
                    if let owner = ownerID, let jobID = UserDefaults.standard.string(forKey: "boji.pendingPlan135.\(owner)") {
                        Task { await reconcilePlan135(owner: owner, jobID: jobID) }
                    }
                }
            }
            .onChange(of: notifications.route?.id, initial: true) { _, _ in handleNotificationRoute() }
            .onChange(of: store.trainingInterfacePresented) { _, visible in if !visible { handleNotificationRoute() } }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    refreshDay(); store.refreshClubInsights(); ai.resume(); syncTrainingActivity(); presentGuideIfNeeded()
                } else { ai.pause() }
            }
            .onChange(of: store.editingAccountID) { _, _ in
                trainingRoute = nil; restDeadlines = [:]
                sidebarOpen = false; sidebarRoute = nil; columns = .detailOnly
                mealEntryRoute = nil; bodyEntryRoute = nil; creatingForDate = nil
                showTrainingPlans = false; showExerciseLibrary = false; showHubSection = nil
                guideOwner = nil
                aiPath = NavigationPath(); trainingPath = NavigationPath()
                planSetupTask135?.cancel(); planSetupTask135 = nil; onboarding.reset()
                coach.reset(); recordsPath131 = NavigationPath(); recordsCategory = "训练"; trainingScrollAnchor = nil; calendarExpanded = false; selectedDate = Date(); currentDay = ClubDates.key(Date())
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
                    .simultaneousGesture(DragGesture(minimumDistance: 25).onEnded { value in
                        if value.startLocation.x < 24, value.translation.width > 70,
                           abs(value.translation.height) < value.translation.width * 0.6 { openSidebar() }
                    })
                    .overlay(alignment: .leading) { sidebarLayer }
            }
        }
        .background { ClubBackground() }
    }

    /// iPad（regular）继续用侧栏 + 详情列；iPhone（compact）用 v3 原型的四个 Tab。
    @ViewBuilder private var navigationWorkspace: some View {
        if horizontalSizeClass == .regular { regularWorkspace } else { tabWorkspace }
    }

    @ViewBuilder private var regularWorkspace: some View {
        if mode == .clubAI {
            NavigationStack(path: $aiPath) {
                aiWorkspace
                    .clubBottomBar { bottomDock }
                    .toolbar { rootToolbar }
                    .navigationBarTitleDisplayMode(.inline)
            }
        } else if mode == .training {
            NavigationStack(path: $trainingPath) {
                ClubPlanHub(selectedDate: $selectedDate, openWorkout: startTrainingFromPlan, embeddedInShell: true, scrollAnchor: $trainingScrollAnchor, calendarExpanded: $calendarExpanded)
                    .toolbar { rootToolbar }
                    .navigationBarTitleDisplayMode(.inline)
            }
            .clubBottomBar { bottomDock }
        } else if mode == .profile {
            NavigationStack {
                ProfileView(routeToKeepsakeVault: $keepsakeRoute)
                    .toolbar { rootToolbar }
                    .navigationBarTitleDisplayMode(.inline)
            }.clubBottomBar { bottomDock }
        } else {
            NavigationStack(path: $recordsPath131) {
                ClubRecordsHub(category: $recordsCategory, embeddedInShell: true)
                    .toolbar { rootToolbar }
                    .navigationBarTitleDisplayMode(.inline)
            }.clubBottomBar { bottomDock }
        }
    }

    /// v3 原型的四 Tab 外壳：主页 / 训练 / 记录 / 我的。
    /// 每个 Tab 各自持有 NavigationStack；底部 mini 训练条用 safeAreaInset 落在 TabBar 之上。
    private var tabWorkspace: some View {
        TabView(selection: $mode) {
            NavigationStack(path: $aiPath) {
                aiWorkspace
                    .clubBottomBar { bottomDock }
                    .toolbar { rootToolbar }
                    .navigationBarTitleDisplayMode(.inline)
            }
            .tabItem { Label("主页", systemImage: "house") }
            .tag(ClubShellMode.clubAI)

            NavigationStack(path: $trainingPath) {
                ClubPlanHub(selectedDate: $selectedDate, openWorkout: startTrainingFromPlan, embeddedInShell: true, scrollAnchor: $trainingScrollAnchor, calendarExpanded: $calendarExpanded)
                    .clubBottomBar { bottomDock }
                    .toolbar { rootToolbar }
                    .navigationBarTitleDisplayMode(.inline)
            }
            .tabItem { Label("训练", systemImage: "dumbbell") }
            .tag(ClubShellMode.training)

            NavigationStack(path: $recordsPath131) {
                ClubRecordsHub(category: $recordsCategory, embeddedInShell: true)
                    .clubBottomBar { bottomDock }
                    .toolbar { rootToolbar }
                    .navigationBarTitleDisplayMode(.inline)
            }
            .tabItem { Label("记录", systemImage: "chart.bar.doc.horizontal") }
            .tag(ClubShellMode.records)

            NavigationStack {
                ProfileView(routeToKeepsakeVault: $keepsakeRoute)
                    .clubBottomBar { bottomDock }
                    .toolbar { rootToolbar }
                    .navigationBarTitleDisplayMode(.inline)
            }
            .tabItem { Label("我的", systemImage: "person.crop.circle") }
            .tag(ClubShellMode.profile)
        }
        .tint(BojiV2.accent)
    }

    @ToolbarContentBuilder private var rootToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button(action: openSidebar) { Image(systemName: "sidebar.leading") }
                .accessibilityLabel(horizontalSizeClass == .regular && columns == .all ? "收起侧栏" : "打开侧栏")
                .accessibilityIdentifier("v2-sidebar-toggle")
                .accessibilityFocused($sidebarToggleFocused)
        }
        if horizontalSizeClass == .regular {
            ToolbarItem(placement: .principal) { ClubModeCapsulePicker(mode: $mode) }
        }
        ToolbarItem(placement: .topBarTrailing) {
            if mode == .training {
                Menu {
                    Button("管理训练计划", systemImage: "calendar") { showTrainingPlans = true }
                    Button("创建训练计划", systemImage: "plus") { creatingForDate = ClubTrainingRoute(date: selectedDate) }
                    Button("动作库", systemImage: "rectangle.stack") { showExerciseLibrary = true }
                } label: { Image(systemName: "ellipsis") }
                .accessibilityLabel("训练更多操作").accessibilityIdentifier("v2-context-action")
            } else if mode == .profile {
                Menu {
                    Button("记录饮食") { openMeal("手动") }
                    Button("记录身体数据") { bodyEntryRoute = ClubDateRoute(date: Date()) }
                    Button("AI 解读档案", systemImage: "doc.text.magnifyingglass") { showReports135 = true }
                } label: { Image(systemName: "ellipsis") }
                .accessibilityLabel("我的更多操作").accessibilityIdentifier("v2-context-action")
            } else {
                // 主页与记录共用：自由对话已下线，这里只保留记录与解读档案入口。
                Menu {
                    Button("记录饮食") { openMeal("手动") }
                    Button("记录身体数据") { bodyEntryRoute = ClubDateRoute(date: Date()) }
                    Button("AI 解读档案", systemImage: "doc.text.magnifyingglass") { showReports135 = true }
                } label: { Image(systemName: "ellipsis") }.accessibilityLabel("更多操作").accessibilityIdentifier("v2-context-action")
            }
        }
    }

    /// AI 收拢后的主工作台：始终是「首页 + 四个 AI 功能入口」。
    ///
    /// 自由对话已下线，任何深链都不会再进入聊天界面；计划生成走独立的计划卡，
    /// 不经过对话。
    @ViewBuilder private var aiWorkspace: some View {
        VStack(spacing:0) {
            if onboarding.state?.taskCompleteAvailable == true && account.user?.onboardingCompleted == false {
                Button("完成设置") { showFinishOnboarding135 = true }.font(.subheadline).frame(minHeight: 44)
            }
            if coach.planIntake131 {
                ScrollView {
                    PlanConversationCard131(conversation: coach.conversation,
                                            onboardingSessionID: coach.onboardingPlanSession135)
                        .padding(.horizontal, 16)
                }
            } else {
                ClubAIWorkspaceIdleView(activeWorkout: activeWorkout, isNewUser: account.user?.onboardingCompleted == false,
                    onOpenProfile: { showProfileBasics135 = true }, onOpenPermissions: { showPermissions135 = true },
                    onQuickQuestion: { _ in },
                    onArrangePlan131: {
                        coach.newConversation(owner: ownerID, keepDraft: true)
                        coach.planIntake131 = true
                        if account.user?.onboardingCompleted == false {
                            planSetupTask135 = Task {
                                let owner = ownerID, conversation = coach.conversation
                                await onboarding.load(account: account)
                                if onboarding.taskKind != .planCreate { await onboarding.createSession(.planCreate, account: account) }
                                guard owner == ownerID, conversation == coach.conversation else { return }
                                coach.onboardingPlanSession135 = onboarding.state?.session?.id
                                if onboarding.error != nil { coach.error = "训练计划暂时无法准备，请稍后重试。" }
                            }
                        }
                    },
                    onOpenHub: { if $0 == "训练计划" { mode = .training } else { showHubSection = $0 } },
                    onStartTraining: {
                        if activeWorkout != nil { openActiveWorkout() }
                        else { selectedDate = Date(); startTrainingFromPlan() }
                    },
                    onRecordMeal: { openMeal("手动") },
                    onDailyReport: { openReportLibrary(.daily) },
                    onWeeklyReview: { openReportLibrary(.weekly) },
                    onFoodRecognition: { openMeal("照片") },
                    onOpenData: { mode = .records })
            }
        }
    }
    private var bottomDock: some View {
        VStack(spacing: 8) {
            if trainingRoute == nil, let snapshot = activeWorkout {
                ClubActiveWorkoutAccessory(snapshot: snapshot, open: openActiveWorkout, togglePause: toggleActivePause)
                    .frame(maxWidth: BojiSize.contentWidth)
                    .padding(.horizontal, 14).frame(maxWidth: .infinity)
            }
        }
        .clubGlassGroup(spacing: 12)
        .padding(.bottom, 4)
    }

    private var shellWithPresentations: some View {
        shellStructure
            .safeAreaInset(edge: .top, spacing: 0) { bannerStack }
            .fullScreenCover(item: $trainingRoute, onDismiss: { store.trainingInterfacePresented = false;Task { await onboarding.load(account:account) } }) { workoutCoverFor($0) }
            .sheet(item: $creatingForDate) { PlanCreationSheet(date: $0.date) }
            .sheet(item: $sidebarRoute) { sidebarDestination($0) }
            .sheet(isPresented: $showProfileBasics135) { ProfileFactsForm133(title: "补充资料", fields: ProfileFields133.basics) }
            .sheet(isPresented: $showPermissions135) { if let owner = ownerID { FirstLaunchPermissionsView(ownerID: owner) } }
            .sheet(isPresented: $showReports135) { NavigationStack { ReportLibraryView(initialKind: reportLibraryKind135, embedded: true).toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { showReports135 = false } } } } }
            .sheet(isPresented: $showLegacyOnboarding135) {
                NavigationStack {
                    OnboardingWorkspaceView(model: onboarding,
                        onRecordMeal: { date, mode in showLegacyOnboarding135 = false; mealEntryRoute = ClubComposerMealRoute(date: date, mode: mode) },
                        onRecordTraining: { date in showLegacyOnboarding135 = false; selectedDate = date; trainingRoute = ClubTrainingRoute(date: date) },
                        onOpenMembership: { showLegacyOnboarding135 = false; showMembership = true },
                        onOpenKnowledge: { showLegacyOnboarding135 = false; sidebarRoute = .aiMemory })
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
            .alert("计划已保存", isPresented: $showFinishOnboarding135) {
                Button("完成设置") {
                    Task { if !(await onboarding.completeSession(account: account, covenantVersion: "2026-10-25")) { coach.error = onboarding.error ?? "暂时无法完成设置，请重试。" } }
                }
                Button("稍后", role: .cancel) { }
            } message: { Text("完成设置后，可以选择会员方案。") }
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
        SidebarHostView(floating: floating,
            onClose: closeSidebar,
            onToday: { closeSidebar(); mode = .clubAI; aiPath = NavigationPath() },
            onOpen: { route in
                closeSidebar()
                // 记录 / 我的 已是顶层 Tab，直接切换而不是一层多余的 sheet。
                if route == .records { mode = .records }
                else if route == .profile { mode = .profile }
                else if flags.clubEnabled || route != .club { sidebarRoute = route }
            })
    }
    @ViewBuilder private var sidebarLayer: some View {
        if sidebarOpen {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Color.black.opacity(0.28).ignoresSafeArea().onTapGesture(perform: closeSidebar).accessibilityHidden(true)
                    sidebarContent(floating: true)
                        .frame(width: min(geometry.size.width * 0.88, 360))
                        .padding(.leading, 8).padding(.vertical, 6)
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
        case .tasks:
            NavigationStack { TaskCenterView()
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { sidebarRoute = nil } } } }
        case .club:
            NavigationStack { ClubSeasonView()
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { sidebarRoute = nil } } } }
        case .aiMemory:
            NavigationStack { ReportLibraryView(embedded: true).toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { sidebarRoute = nil } } } }
        case .profile:
            NavigationStack { ProfileView(routeToKeepsakeVault: $keepsakeRoute)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { sidebarRoute = nil } } } }
        case .feedback:
            NavigationStack { MemberFeedbackHub128().toolbar { ToolbarItem(placement:.cancellationAction) { Button("关闭") { sidebarRoute = nil } } } }
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
            showFinishOnboarding135 = true
        } else if let message = onboarding.error { coach.error = message }
    }
    /// 打开报告库并定位到指定类型（日报 / 周报）。
    private func openReportLibrary(_ kind: ReportLibraryKind) {
        reportLibraryKind135 = kind
        showReports135 = true
    }
    private func openMeal(_ mode: String) {
        mealEntryRoute = ClubComposerMealRoute(date: Date(), mode: mode)
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
        guard url.scheme == "bojiclub", url.host == "training" else { return }
        let date = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "date" })?.value.flatMap(ClubDates.date(fromKey:)) ?? Date()
        selectedDate = date; trainingRoute = ClubTrainingRoute(date: date)
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
            if membership.isVerifyingMembership {
                BojiStatusBanner(
                    icon: "crown.fill",
                    title: "会员已购买，正在核验",
                    detail: "可使用全部功能；服务器核验完成后会自动更新，请勿重复购买。",
                    tint: BojiColor.aiGold,
                    actionTitle: membership.isBusy ? nil : "重新查询",
                    action: { membership.refreshMembershipStatus() }
                )
            }
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
        guard let owner = store.editingAccountID, let snapshot = activeWorkout,
              let date = ClubDates.date(fromKey: snapshot.dateKey),
              let startedAt = store.log(for: date).trainingLog.workoutStartedAt else { return }
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
        if ClubDates.calendar.isDateInToday(selectedDate), !day.exercises.isEmpty,
           day.workoutStartedAt == nil, day.workoutSavedAt == nil, day.completedSets == 0 {
            guard store.beginWorkout(on: selectedDate) else { return }
        }
        trainingRoute = ClubTrainingRoute(date: selectedDate)
    }

    private func restDeadline(for date: Date) -> Date? {
        guard let saved = restDeadlines[ClubDates.key(date)], saved.deadline > Date(),
              saved.sessionID == store.log(for: date).activeWorkoutSessionID else { return nil }
        return saved.deadline
    }

    private func handleNotificationRoute() {
        guard let route = notifications.route, route.accountID == store.editingAccountID else { return }
        if route.kind != "training" {
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
        selectedDate = date; trainingRoute = ClubTrainingRoute(date: date); notifications.route = nil
    }
}

private struct HubSectionRoute: Identifiable { let id = UUID(); let section: String }
private struct ClubDateRoute: Identifiable { let id = UUID(); let date: Date }

/// The system segmented control supplies its own native selection surface and gestures.
struct ClubModeCapsulePicker: View {
    @Binding var mode: ClubShellMode
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                Picker("工作区", selection: $mode) { options }.pickerStyle(.menu)
            } else {
                Picker("工作区", selection: $mode) { options }
                    .pickerStyle(.segmented).frame(idealWidth: 240, maxWidth: 300)
            }
        }
        .accessibilityIdentifier("v2-mode-picker")
    }
    private var options: some View {
        Group {
            Text("主页").tag(ClubShellMode.clubAI)
            Text("训练").tag(ClubShellMode.training)
            Text("记录").tag(ClubShellMode.records)
            Text("我的").tag(ClubShellMode.profile)
        }
    }
}

extension Notification.Name {
    static let bojiPlanApplied135 = Notification.Name("bojiPlanApplied135")
    static let clubShellReturnToToday = Notification.Name("clubShellReturnToToday")
    static let clubDeviceSetupFinished = Notification.Name("clubDeviceSetupFinished")
}

struct SidebarHostView: View {
    var floating = true
    let onClose: () -> Void
    let onToday: () -> Void
    let onOpen: (ClubSidebarRoute) -> Void
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var ai: AIService
    @EnvironmentObject private var account: AccountService
    @EnvironmentObject private var weekly: WeeklyReviewService
    @Environment(\.dynamicTypeSize) private var typeSize
    @ObservedObject private var flags = FeatureFlagService.shared
    @AccessibilityFocusState private var headingFocused: Bool

    var body: some View {
        Group {
            if floating { content.clubGlassEffect(in: RoundedRectangle(cornerRadius: 28, style: .continuous)) }
            else { content }
        }
        .accessibilityIdentifier("v2-sidebar-panel")
        .onAppear { headingFocused = true }
        .accessibilityAction(.escape, onClose)
    }
    private var content: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    entry("今天", symbol: "sun.max", id: "v2-sidebar-today", action: onToday)
                    entry("俱乐部", symbol: "seal", id: "v2-sidebar-club") { onOpen(.club) }.disabled(!flags.clubEnabled)
                }.buttonStyle(.plain).padding(.horizontal, 20).padding(.vertical, 6)
                Divider()
                List {
                    Section {
                        entry("处理进度", symbol: "checklist", id: "v2-sidebar-tasks") { onOpen(.tasks) }
                        entry("AI 解读档案", symbol: "doc.text.magnifyingglass", id: "v2-sidebar-aimemory") { onOpen(.aiMemory) }
                        entry("反馈与回复", symbol: "exclamationmark.bubble", id: "v2-sidebar-feedback") { onOpen(.feedback) }
                    }
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
                .modifier(ClubSidebarListPolicy(floating: floating))
                .scrollContentBackground(.hidden)
                .environment(\.defaultMinListRowHeight, 44)
                .refreshable { await ai.recoverTasks(account: account, weekly: weekly, store: store) }
                Group {
                    if typeSize.isAccessibilitySize { VStack(spacing: 8) { accountEntries } }
                    else { HStack(spacing: 20) { accountEntries } }
                }
                .buttonStyle(.plain).padding(.horizontal, 20).padding(.vertical, 10)
            }
            .toolbar(removing: .sidebarToggle)
            .navigationTitle("薄肌俱乐部").navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement:.principal) { Text("BOJI CLUB").font(.headline).foregroundStyle(BojiColor.textPrimary) }
                if floating {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("关闭侧栏", systemImage: "xmark", action: onClose)
                            .labelStyle(.iconOnly).accessibilityIdentifier("v2-sidebar-close")
                            .accessibilityFocused($headingFocused)
                    }
                }
            }
        }
        .tint(BojiV2.accent).foregroundStyle(BojiColor.textPrimary)
        .clipShape(RoundedRectangle(cornerRadius: floating ? 28 : 0, style: .continuous))
    }
    private var accountEntries: some View {
        Group {
            entry("我的", symbol: "person.crop.circle", id: "v2-sidebar-profile") { onOpen(.profile) }
            entry("设置", symbol: "gearshape", id: "v2-sidebar-settings") { onOpen(.settings) }
        }
    }
    private func entry(_ text: String, symbol: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(text, systemImage: symbol).font(.body).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading) }
            .listRowBackground(Color.clear).listRowSeparator(.hidden)
            .accessibilityIdentifier(id)
    }
}

struct ClubAIWorkspaceIdleView: View {
    var activeWorkout: ActiveWorkoutSnapshot? = nil
    var isNewUser = false
    var onOpenProfile: () -> Void = {}
    var onOpenPermissions: () -> Void = {}
    let onQuickQuestion: (String) -> Void
    let onArrangePlan131: () -> Void
    let onOpenHub: (String) -> Void
    let onStartTraining: () -> Void
    let onRecordMeal: () -> Void
    let onDailyReport: () -> Void
    let onWeeklyReview: () -> Void
    let onFoodRecognition: () -> Void
    /// v3 原型顶部右侧「看数据 ›」：直达记录 Tab 的数据面板。
    var onOpenData: () -> Void = {}
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var ai: AIService
    @EnvironmentObject private var clubSeason: ClubSeasonService
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var showSeason = false
    @ObservedObject private var flags = FeatureFlagService.shared
    @State private var selectedInsight: ClubHomeInsightSelection?
    private var today: DayLog { store.log(for: Date()) }
    private var insightCandidates: [ClubHomeInsightSelection] {
        guard let owner = store.editingAccountID else { return [] }
        let key = ClubDates.key(Date())
        var local: [ClubInsightEvent] = []
        for offset in 0...7 {
            guard let date = ClubDates.calendar.date(byAdding: .day, value: -offset, to: Date()) else { continue }
            local += ClubInsightLedger.current(in: store.state, date: date).filter(ClubInsightPriorityRules.isActionable)
        }
        var values = local.map { ClubHomeInsightSelection(id: $0.id + "/" + $0.evidenceDigest,
            owner: owner, day: key, kind: $0.kind, title: $0.title, detail: $0.detail, priority: $0.priority) }
        if let server = ai.homeInsight, let kind = server.insightKind {
            values.append(ClubHomeInsightSelection(id: server.id + "/" + server.detail, owner: owner,
                day: key, kind: kind, title: server.title, detail: server.detail, priority: server.priority))
        }
        return values
    }
    /// 设计稿 §10.1：顶部左侧「早上好，梦雨」15 Semibold + 日期 13。
    /// 自由对话已下线，这里不再出现「我是 Club AI」那种对话式开场；
    /// 训练状态由紧随其下的今日焦点卡表达，不挤进问候语。
    private var greeting: String {
        let hour = ClubDates.calendar.component(.hour, from: Date())
        let part: String
        switch hour {
        case 5..<12: part = "早上好"
        case 12..<18: part = "下午好"
        default: part = "晚上好"
        }
        // 只有用户真正填过昵称才署名；默认占位名不走进问候语。
        let name = store.state.profile.nickname.trimmingCharacters(in: .whitespaces)
        if name.isEmpty || name == "薄肌新成员" { return part }
        return "\(part)，\(name)"
    }
    // Revalidate against current candidates even before onChange runs: withdrawn/other-owner text never renders.
    private var insight: ClubHomeInsightSelection? {
        ClubHomeInsightStability.select(current: selectedInsight, candidates: insightCandidates)
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(greeting)
                            .font(.system(size: 15, weight: .semibold)).foregroundStyle(BojiV2.textPrimary)
                        Text(todayLabel).font(BojiV2.caption).foregroundStyle(BojiV2.textSecondary)
                    }
                    Spacer(minLength: 8)
                    // v3 原型：顶部右侧「看数据 ›」胶囊，落点是记录 Tab 的数据面板。
                    Button(action: onOpenData) {
                        HStack(spacing: 2) {
                            Text("看数据").font(BojiV2.caption)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .accessibilityHidden(true)
                        }
                        .foregroundStyle(BojiV2.textPrimary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.75), in: Capsule())
                        .overlay { Capsule().strokeBorder(Color.white.opacity(0.95), lineWidth: 1) }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("v2-home-data")
                    ZStack {
                        Circle().fill(BojiV2.accentFill)
                        Image(systemName: "person.crop.circle")
                            .font(.system(size: 22)).foregroundStyle(BojiV2.accent)
                    }
                    .frame(width: 36, height: 36)
                    .accessibilityHidden(true)
                }
                .padding(.horizontal, BojiV2.titleInset)
                .padding(.top, 12)
                heroVisual
                todayFocusCard
                if flags.aiEnabled {
                    aiFeatureCard
                    Group {
                        if typeSize.isAccessibilitySize { VStack(alignment: .leading, spacing: 4) { quickActions } }
                        else { ViewThatFits(in: .horizontal) { HStack(spacing: 14) { quickActions }; VStack(alignment: .leading, spacing: 4) { quickActions } } }
                    }.frame(maxWidth: .infinity)
                    if isNewUser { Button("设置通知与健康", action: onOpenPermissions).font(.footnote).frame(maxWidth: .infinity, minHeight: 44) }
                } else {
                    Text("AI 暂不可用，训练与记录照常使用。").font(.subheadline).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 24).padding(.bottom, 24)
            .frame(maxWidth: 620).frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .task {
            UserDefaults.standard.removeObject(forKey: "v2.homeInsightPinned.v1")
            await ai.refreshHomeInsightIfNeeded()
        }
        .onChange(of: insightCandidates, initial: true) { _, values in
            selectedInsight = ClubHomeInsightStability.select(current: selectedInsight, candidates: values)
        }
        .sheet(isPresented: $showSeason) { NavigationStack { ClubSeasonView()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { showSeason = false } } } } }
        .background(BojiColor.pageBackground)
        .accessibilityIdentifier("v2-ai-workspace")
    }
    private var quickActions: some View {
        Group {
            Button(action: onArrangePlan131) {
                Text("安排训练").font(.body).fixedSize(horizontal: false, vertical: true).frame(minHeight: 44)
            }
            Button(action: onRecordMeal) {
                Text("记录饮食").font(.body).fixedSize(horizontal: false, vertical: true).frame(minHeight: 44)
            }
            if isNewUser {

                Button("补充资料", action: onOpenProfile).frame(minHeight: 44)
            }
        }.buttonStyle(.borderless).tint(BojiV2.accent)
    }
    private static let dayLabelFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 EEEE"
        return formatter
    }()
    private var todayLabel: String { Self.dayLabelFormatter.string(from: Date()) }

    /// 首页主视觉：6 层漂浮立体小物（设计稿 §6 / §8 M1–M3）。
    /// 素材是 Apple clay/glass 风格的透明 PNG，各层独立漂浮，按景深做陀螺仪视差。
    private var heroVisual: some View {
        HeroLayersView(layers: HeroLayer.home, size: CGSize(width: 340, height: 250))
            .frame(maxWidth: .infinity)
            .bojiHeroEntrance()
            .padding(.vertical, 4)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("漂浮的健身用品插图")
    }
    /// v3 原型首页底部大玻璃卡：今日训练焦点 + 环形完成度 + 三格数据 + 日报行 + 主按钮。
    ///
    /// 环形进度只表示「已确认完成组 / 今日安排组」，不引入设计稿里那个没有数据
    /// 来源的综合评分。三格数据全部取自当天记录本身，缺失时显示占位而不是 0。
    private var todayFocusCard: some View {
        let total = today.totalSets
        let completed = today.completedSets
        let report = todayReport
        let generated = report?.status == "succeeded"
        let hasRecords = DailyReportEligibility.hasRecords(today)
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(focusTitle).font(BojiV2.title).foregroundStyle(BojiV2.textPrimary)
                Text(focusSubtitle).font(BojiV2.caption).foregroundStyle(BojiV2.textSecondary)
            }
            BojiGlassCard(radius: BojiV2.glassDockRadius, padding: BojiV2.glassPadding) {
                VStack(spacing: 18) {
                    HStack(alignment: .center, spacing: 16) {
                        ZStack {
                            BojiProgressRing(progress: completionProgress, lineWidth: 8)
                            VStack(spacing: 0) {
                                Text("\(completed)").bojiNumeral(34)
                                    .foregroundStyle(BojiV2.textPrimary)
                                Text("/ \(total)").font(BojiV2.microEm)
                                    .foregroundStyle(BojiV2.textSecondary)
                            }
                        }
                        .frame(width: 92, height: 92)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("今日训练完成度").font(BojiV2.bodyEm)
                                .foregroundStyle(BojiV2.textPrimary)
                            Text(total > 0 ? "已确认 \(completed) / \(total) 组" : "今天还没有安排组次")
                                .font(BojiV2.caption).foregroundStyle(BojiV2.textSecondary)
                            if let snapshot = activeWorkout {
                                Text(snapshot.isPaused ? "训练已暂停" : "训练进行中")
                                    .font(BojiV2.micro).foregroundStyle(BojiV2.accent)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    BojiStatStrip(items: [
                        BojiStatStrip.Item(value: "\(completed)", label: "训练组"),
                        BojiStatStrip.Item(value: calorieValue, label: "摄入 kcal"),
                        BojiStatStrip.Item(value: weightValue, label: "体重 kg")
                    ])
                    Rectangle().fill(BojiV2.hairline).frame(height: 1)
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(generated ? "今日日报已生成" : "日报还没生成")
                                .font(BojiV2.bodyEm).foregroundStyle(BojiV2.textPrimary)
                            Text(generated ? "点击查看或重新生成"
                                 : hasRecords ? "已有今日记录 · 可立即生成" : "每晚 22:00 自动生成")
                                .font(BojiV2.caption).foregroundStyle(BojiV2.textSecondary)
                        }
                        Spacer(minLength: 8)
                        Button(generated ? "查看" : "生成分析") { onDailyReport() }
                            .font(BojiV2.bodyEm).foregroundStyle(BojiV2.accent)
                            .frame(minHeight: 44)
                    }
                    BojiPrimaryButton(title: activeWorkout != nil ? "继续训练" : "开始训练") { onStartTraining() }
                }
            }
            .accessibilityIdentifier("v2-today-focus-card")
        }
        .padding(.horizontal, BojiV2.cardInset)
    }
    /// 今日训练焦点：用动作肌群概括（保持记录顺序，不用 Set 的随机序），没有安排时给一句事实描述。
    private var focusTitle: String {
        if activeWorkout != nil { return "进行中的训练" }
        var seen = Set<String>()
        let muscles = today.exercises.map(\.muscle).filter { !$0.isEmpty && seen.insert($0).inserted }
        guard !muscles.isEmpty else { return today.exercises.isEmpty ? "今天还没有安排" : "今天的训练" }
        return "今天练" + muscles.prefix(3).joined(separator: " · ")
    }
    private var focusSubtitle: String {
        if let snapshot = activeWorkout { return "\(snapshot.completedSets)/\(snapshot.totalSets) 组 · 点击继续" }
        let count = today.exercises.count
        guard count > 0 else { return "从一条记录开始，也很好。" }
        return "\(count) 个动作 · \(today.totalSets) 组"
    }
    private var completionProgress: Double {
        let total = today.totalSets
        guard total > 0 else { return 0 }
        return Double(today.completedSets) / Double(total)
    }
    /// 当天实测体重优先；没有实测时退回资料体重，取不到才占位。
    private var weightValue: String {
        if let kg = today.bodyWeight?.kilograms, kg > 0 { return String(format: "%.1f", kg) }
        let profile = store.state.profile.weight
        return profile > 0 ? String(format: "%.1f", profile) : "—"
    }
    private var calorieValue: String {
        let kcal = today.calories
        guard kcal > 0 else { return "—" }
        return Self.calorieFormatter.string(from: NSNumber(value: kcal.rounded())) ?? "—"
    }
    private static let calorieFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        formatter.groupingSeparator = ","
        return formatter
    }()
    private var todayReport: AILocalJob? {
        ReportHistory.visible(ai.jobs, dateKey: ClubDates.key(Date()),
                             deleted: Set(store.state.deletedAIJobIDs ?? [])).first
    }
    /// AI 收拢后的四个功能入口：每日分析 / 每周复盘 / AI 食物识别 / AI 计划生成。
    /// 自由对话已下线，这里是 App 内唯一的 AI 功能入口集合。
    private var aiFeatureCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("AI 功能").font(.system(size: 17, weight: .semibold)).foregroundStyle(BojiV2.textPrimary)
                Spacer()
                Text("4 项").font(BojiV2.caption).foregroundStyle(BojiV2.textSecondary)
            }
            VStack(spacing: 10) {
                BojiItemRow(title: "每日分析", subtitle: "今天练了什么、吃得怎样、明天调什么",
                            systemImage: "sun.max", showsChevron: true, action: onDailyReport)
                    .bojiStagger(index: 0)
                BojiItemRow(title: "每周复盘", subtitle: "本周节奏回顾与下周安排",
                            systemImage: "calendar.badge.checkmark", showsChevron: true, action: onWeeklyReview)
                    .bojiStagger(index: 1)
                BojiItemRow(title: "AI 食物识别", subtitle: "拍一张照片，自动拆出热量与蛋白",
                            systemImage: "camera.viewfinder", showsChevron: true, action: onFoodRecognition)
                    .bojiStagger(index: 2)
                BojiItemRow(title: "AI 计划生成", subtitle: "按目标生成一周训练安排",
                            systemImage: "figure.strengthtraining.traditional", showsChevron: true, action: onArrangePlan131)
                    .bojiStagger(index: 3)
            }
        }
        .accessibilityIdentifier("v2-ai-features")
    }
    private func insightCard(_ insight: ClubHomeInsightSelection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("今日发现").font(.subheadline).foregroundStyle(.secondary)
            Text(insight.title).font(.headline)
            if !insight.detail.isEmpty { Text(insight.detail).font(.subheadline).foregroundStyle(.secondary) }
            HStack {
                Button("查看跟进") { onOpenHub("动态") }.buttonStyle(.borderless).frame(minHeight: 44)
                if insightCandidates.count > 1 {
                    Spacer()
                    Button("还有 \(insightCandidates.count - 1) 条") { onOpenHub("动态") }
                        .font(.footnote).buttonStyle(.borderless)
                }
            }
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .background(BojiColor.cardSurface, in: RoundedRectangle(cornerRadius: 22))
        .overlay { RoundedRectangle(cornerRadius: 22).stroke(BojiColor.outline, lineWidth: 0.5) }
        .accessibilityIdentifier("v2-insight-card")
    }
}

/// One compact accessory shares the shell's single bottom layout with the composer.
private struct ClubActiveWorkoutAccessory: View {
    let snapshot: ActiveWorkoutSnapshot
    let open: () -> Void
    let togglePause: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Button(action: open) {
                HStack(spacing: 10) {
                    BojiBrandMark(size: 30)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(snapshot.isPaused ? "训练已暂停" : "训练进行中").font(.subheadline.weight(.medium))
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                let seconds = max(0, Int(snapshot.elapsed(at: context.date)))
                                Text(String(format: "%02d:%02d", seconds / 60, seconds % 60))
                                    .font(.subheadline.monospacedDigit().weight(.semibold))
                            }
                        }
                        Text("点击返回训练 · 已登记 \(snapshot.completedSets)/\(snapshot.totalSets) 组").font(.caption).foregroundStyle(BojiColor.textPrimary)
                    }
                    Spacer(minLength: 0)
                }.frame(minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("native-resume-workout")
            Button(action: togglePause) {
                Image(systemName: snapshot.isPaused ? "play.fill" : "pause.fill").frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.plain).accessibilityLabel(snapshot.isPaused ? "继续训练" : "暂停训练")
        }
        .padding(.horizontal, 14).padding(.vertical, 4)
        .clubGlassEffect(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
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
