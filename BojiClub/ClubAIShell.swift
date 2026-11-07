import SwiftUI

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
    }
}

enum ClubShellMode: Hashable { case clubAI, training, records }
private enum ClubShellPage: Hashable { case clubAI, training, records(String) }
enum ClubSidebarRoute: String, Identifiable {
    case records, aiMemory, settings
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
            .onChange(of: conversationVisible) { _, visible in
                store.clubAIInterfacePresented = visible
                if !visible { handleNotificationRoute() }
            }
            .onAppear {
                refreshDay()
                syncTrainingActivity()
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

    private var workspacePath: Binding<NavigationPath> {
        switch mode {
        case .clubAI: return $aiPath
        case .training: return $trainingPath
        case .records: return $recordsPath131
        }
    }
    private var workspacePage: Binding<ClubShellPage> {
        Binding(get: {
            switch mode {
            case .clubAI: return .clubAI
            case .training: return .training
            case .records:
                return .records(ClubRecordsHub.pageCategories.contains(recordsCategory) ? recordsCategory : "综合看板")
            }
        }, set: { page in
            switch page {
            case .clubAI: mode = .clubAI
            case .training: mode = .training
            case .records(let category): recordsCategory = category; mode = .records
            }
        })
    }
    private var navigationWorkspace: some View {
        NavigationStack(path: workspacePath) {
            // One pager owns horizontal gestures, including the record categories.
            TabView(selection: workspacePage) {
                aiWorkspace.tag(ClubShellPage.clubAI)
                    .accessibilityHidden(mode != .clubAI)
                ClubPlanHub(selectedDate: $selectedDate, openWorkout: startTrainingFromPlan, embeddedInShell: true, scrollAnchor: $trainingScrollAnchor, calendarExpanded: $calendarExpanded)
                    .tag(ClubShellPage.training)
                    .accessibilityHidden(mode != .training)
                ForEach(ClubRecordsHub.pageCategories, id: \.self) { category in
                    ClubRecordsHub(category: $recordsCategory, embeddedInShell: true, pagedCategory: category)
                        .tag(ClubShellPage.records(category))
                        .accessibilityHidden(workspacePage.wrappedValue != .records(category))
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(transitionAnimation, value: workspacePage.wrappedValue)
            .clubBottomBar { bottomDock }
            .toolbar { rootToolbar }
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ToolbarContentBuilder private var rootToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button(action: openSidebar) { Image(systemName: "sidebar.leading") }
                .accessibilityLabel(horizontalSizeClass == .regular && columns == .all ? "收起侧栏" : "打开侧栏")
                .accessibilityIdentifier("v2-sidebar-toggle")
                .accessibilityFocused($sidebarToggleFocused)
        }
        ToolbarItem(placement: .principal) { ClubModeCapsulePicker(mode: $mode) }
        ToolbarItem(placement: .topBarTrailing) {
            if mode == .clubAI {
                Menu {
                    Button("挑选经典方案", systemImage: "rectangle.stack.badge.play") { showTrainingPlans = true }
                    Button("AI 定制训练计划", systemImage: "wand.and.stars") { showPlanWizard = true }
                    Button("身体档案与报告", systemImage: "doc.text.magnifyingglass") { showReports135 = true }
                } label: { Image(systemName: "ellipsis") }
                .accessibilityLabel("更多操作").accessibilityIdentifier("v2-context-action")
            } else if mode == .training {
                Button { showTrainingPlans = true } label: { Image(systemName: "calendar") }
                    .accessibilityLabel("管理训练计划").accessibilityIdentifier("v2-context-action")
            } else {
                Menu {
                    Button("记录饮食") { openMeal("手动") }
                    Button("记录身体数据") { bodyEntryRoute = ClubDateRoute(date: Date()) }
                    Button("AI 解读档案", systemImage: "doc.text.magnifyingglass") { showReports135 = true }
                } label: { Image(systemName: "ellipsis") }.accessibilityLabel("记录更多操作").accessibilityIdentifier("v2-context-action")
            }
        }
    }

    @ViewBuilder private var aiWorkspace: some View {
        ZStack(alignment: .bottomTrailing) {
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

            ClubHomeSpeedDial(
                hasActiveWorkout: activeWorkout != nil,
                onStartTraining: {
                    if activeWorkout != nil { openActiveWorkout() }
                    else { selectedDate = Date(); startTrainingFromPlan() }
                },
                onRecordMeal: { openMeal("手动") },
                onRecordBody: { bodyEntryRoute = ClubDateRoute(date: Date()) }
            )
            .padding(.trailing, BojiLayout.blockGap)
            .padding(.bottom, activeWorkout != nil ? 76 : 24)
        }
    }

    private var bottomDock: some View {
        VStack(spacing: BojiLayout.inline) {
            if trainingRoute == nil, let snapshot = activeWorkout {
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
        case .aiMemory:
            NavigationStack { ClubAIMemoryView().toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { sidebarRoute = nil } } } }
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
            NotificationCenter.default.post(name: Notification.Name("expandSpeedDial"), object: nil)
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
            Text("首页").tag(ClubShellMode.clubAI)
            Text("训练").tag(ClubShellMode.training)
            Text("记录").tag(ClubShellMode.records)
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
                        entry("综合看板与记录", symbol: "chart.xyaxis.line", id: "v2-sidebar-records") { onOpen(.records) }
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

struct ClubHomeSpeedDial: View {
    let hasActiveWorkout: Bool
    let onStartTraining: () -> Void
    let onRecordMeal: () -> Void
    let onRecordBody: () -> Void

    @State private var isExpanded = ProcessInfo.processInfo.environment["BOJI_EXPAND_SPEED_DIAL"] == "1"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if isExpanded {
                Color.black.opacity(0.18)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(reduceMotion ? nil : BojiMotion.smoothSpring()) {
                            isExpanded = false
                        }
                    }
                    .transition(.opacity)
            }

            VStack(alignment: .trailing, spacing: BojiLayout.rowGap) {
                if isExpanded {
                    VStack(alignment: .trailing, spacing: BojiLayout.rowGap) {
                        speedDialItem(
                            title: hasActiveWorkout ? "继续训练" : "开始训练",
                            systemImage: "figure.strengthtraining.traditional",
                            action: onStartTraining
                        )
                        speedDialItem(
                            title: "记录饮食",
                            systemImage: "fork.knife",
                            action: onRecordMeal
                        )
                        speedDialItem(
                            title: "记录体重",
                            systemImage: "scalemass.fill",
                            action: onRecordBody
                        )
                    }
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.85, anchor: .bottomTrailing)).combined(with: .offset(y: 16)),
                        removal: .opacity.combined(with: .scale(scale: 0.85, anchor: .bottomTrailing))
                    ))
                }

                Button {
                    BojiHaptics.pressDown()
                    withAnimation(reduceMotion ? nil : BojiMotion2.state) {
                        isExpanded.toggle()
                    }
                    if isExpanded {
                        BojiHaptics.latch()
                    } else {
                        BojiHaptics.pressRelease()
                    }
                } label: {
                    Image(systemName: "plus")
                        .bojiType(.section)
                        .foregroundStyle(isExpanded ? BojiColor.brandAccent : BojiColor.textPrimary)
                        .rotationEffect(.degrees(isExpanded ? 45 : 0))
                        .frame(width: 56, height: 56)
                        .clubGlassEffect(in: Circle())
                        .overlay {
                            Circle()
                                .stroke(isExpanded ? BojiColor.brandAccent.opacity(0.5) : BojiColor.outline, lineWidth: 0.8)
                        }
                        .shadow(color: .black.opacity(0.12), radius: 10, x: 0, y: 5)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "收起操作菜单" : "展开快捷记录")
            }
            .clubGlassGroup(spacing: BojiLayout.rowGap)
        }
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("-expandSpeedDial") || ProcessInfo.processInfo.environment["BOJI_EXPAND_SPEED_DIAL"] == "1" {
                isExpanded = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("expandSpeedDial"))) { _ in
            withAnimation(BojiMotion2.state) {
                isExpanded = true
            }
        }
    }

    private func speedDialItem(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button {
            BojiHaptics.tick()
            withAnimation(reduceMotion ? nil : BojiMotion.smoothSpring()) {
                isExpanded = false
            }
            action()
        } label: {
            HStack(spacing: BojiLayout.inline) {
                Text(title)
                    .bojiType(.secondary)
                    .foregroundStyle(BojiColor.textPrimary)
                    .padding(.horizontal, BojiLayout.rowGap)
                    .padding(.vertical, BojiLayout.inline)
                    .clubGlassEffect(in: Capsule())
                    .overlay {
                        Capsule().stroke(BojiColor.outline, lineWidth: 0.5)
                    }

                Image(systemName: systemImage)
                    .bojiType(.body)
                    .foregroundStyle(BojiColor.brandAccent)
                    .frame(width: 44, height: 44)
                    .clubGlassEffect(in: Circle())
                    .overlay {
                        Circle().stroke(BojiColor.outline, lineWidth: 0.5)
                    }
            }
            .shadow(color: .black.opacity(0.08), radius: 8, x: 0, y: 4)
        }
        .buttonStyle(.plain)
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
    @State private var showSeason = false
    @State private var showPresetPlans = false
    @State private var readingDailyReportID: String? = nil
    @State private var appliedModifierNotice: String? = nil
    @ObservedObject private var flags = FeatureFlagService.shared

    private var today: DayLog { store.log(for: Date()) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BojiLayout.blockGap) {
                headerArea

                if isNewUser {
                    newUserDivergenceCard
                }

                // 核心层级 1: 身体战备与恢复就绪卡
                readinessGaugeCard

                // 核心层级 2: 今日战术任务看板
                heroMissionCard

                // 核心层级 3: 代谢与营养平衡板
                fuelBalanceCard

                // 核心层级 4: 智能分析专区（AI 训练计划 / AI 每日日报 / AI 每周周报）
                intelligenceHubSection

                if isNewUser {
                    Button("设置通知与健康授权", action: onOpenPermissions)
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
        .task {
            UserDefaults.standard.removeObject(forKey: "v2.homeInsightPinned.v1")
            await ai.refreshHomeInsightIfNeeded()
        }
        .sheet(isPresented: $showSeason) {
            NavigationStack {
                ClubSeasonView()
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { showSeason = false } } }
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
    private var headerArea: some View {
        HStack(alignment: .center) {
            HStack(spacing: BojiLayout.rowGap) {
                BojiBrandMark(size: 34)
                VStack(alignment: .leading, spacing: 0) {
                    Text("薄肌俱乐部")
                        .bojiType(.caption)
                        .foregroundStyle(BojiColor.textTertiary)
                    Text("战备决策舱")
                        .bojiType(.section)
                        .foregroundStyle(BojiColor.textPrimary)
                }
            }

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

    // MARK: - 核心层级 1: 身体战备与恢复就绪卡
    private var readinessGaugeCard: some View {
        let healthSummary = health.summary(for: Date())
        let sleepMin = healthSummary?.nightSleep?.value ?? healthSummary?.sleep?.value
        let sleepText: String = {
            if let min = sleepMin, min > 0 {
                let h = Int(min / 60)
                let m = Int(min) % 60
                return "\(h)h \(m)m"
            }
            return "7.5h 计划"
        }()
        let rhr = healthSummary?.restingHeartRate?.value
        let rhrText: String = {
            if let val = rhr, val > 0 {
                return "\(Int(val)) bpm"
            }
            return "54 bpm"
        }()
        let steps = healthSummary?.steps?.value
        let stepsText: String = {
            if let val = steps, val > 0 {
                return "\(Int(val)) 步"
            }
            return "-- 步"
        }()

        return VStack(alignment: .leading, spacing: BojiLayout.rowGap) {
            HStack(alignment: .center) {
                Label("战备状态", systemImage: "gauge.with.needle")
                    .bojiFont(.label)
                    .foregroundStyle(BojiColor.textPrimary)
                    .padding(.horizontal, BojiLayout.inline)
                    .padding(.vertical, BojiLayout.tight)
                    .background(BojiColor.brandMist, in: Capsule())

                Spacer()

                Text("神经负荷恢复良好")
                    .bojiType(.caption)
                    .foregroundStyle(BojiColor.emeraldAccent)
            }

            HStack(spacing: BojiLayout.cardInset) {
                // 就绪指数
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text("88")
                            .bojiType(.hero)
                            .foregroundStyle(BojiColor.textPrimary)
                        Text("%")
                            .bojiType(.secondary)
                            .foregroundStyle(BojiColor.textSecondary)
                    }
                    Text("综合充能")
                        .bojiType(.caption)
                        .foregroundStyle(BojiColor.textTertiary)
                }
                .frame(width: 88, alignment: .leading)

                Divider()
                    .frame(height: 48)
                    .overlay(BojiColor.divider)

                // 2x2 极简矩阵
                VStack(spacing: BojiLayout.inline) {
                    HStack(spacing: BojiLayout.rowGap) {
                        metricItem(title: "睡眠时长", value: sleepText, systemImage: "bed.double.fill")
                        metricItem(title: "静息心率", value: rhrText, systemImage: "heart.fill")
                    }
                    HStack(spacing: BojiLayout.rowGap) {
                        metricItem(title: "恢复窗口", value: "上肢推类", systemImage: "figure.strengthtraining.traditional")
                        metricItem(title: "今日步数", value: stepsText, systemImage: "figure.walk")
                    }
                }
                .frame(maxWidth: .infinity)
            }

            // AI 战术决策微简报
            VStack(alignment: .leading, spacing: BojiLayout.tight) {
                HStack(spacing: BojiLayout.tight) {
                    Image(systemName: "chart.xyaxis.line")
                        .bojiType(.caption)
                        .foregroundStyle(BojiColor.brandAccent)
                    Text("战术简报")
                        .bojiType(.caption)
                        .foregroundStyle(BojiColor.brandAccent)
                }

                Text("依据近期训练容量与静息心率测算，上肢肌群已完成超量恢复，神经疲劳指数处于良好区间。建议按计划推进核心复合动作。")
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
        .clubGlassEffect(in: RoundedRectangle(cornerRadius: BojiRadius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: BojiRadius.card, style: .continuous)
                .stroke(BojiColor.outline, lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.04), radius: 10, x: 0, y: 3)
    }

    private func metricItem(title: String, value: String, systemImage: String) -> some View {
        HStack(spacing: BojiLayout.tight) {
            Image(systemName: systemImage)
                .bojiType(.caption)
                .foregroundStyle(BojiColor.textTertiary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .bojiType(.caption)
                    .foregroundStyle(BojiColor.textTertiary)
                Text(value)
                    .bojiType(.label)
                    .foregroundStyle(BojiColor.textPrimary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 核心层级 2: 今日战术任务看板
    private var heroMissionCard: some View {
        VStack(alignment: .leading, spacing: BojiLayout.rowGap) {
            HStack {
                Label(activeWorkout == nil ? "今日战术任务" : "进行中的训练", systemImage: "figure.strengthtraining.traditional")
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
                    Text(today.exercises.isEmpty ? "暂无预设计划" : "\(today.trainingLog.exercises.count) 个动作 · 预计 45 分钟")
                        .bojiFont(.secondary, monospacedDigits: true)
                        .foregroundStyle(BojiColor.textSecondary)
                }
            }

            if let active = activeWorkout {
                VStack(alignment: .leading, spacing: BojiLayout.tight) {
                    Text(active.workoutName)
                        .bojiFont(.cardTitle)
                        .foregroundStyle(BojiColor.textPrimary)
                    Text("已确认登记 \(active.completedSets)/\(active.totalSets) 组 · 保持组间专注")
                        .bojiType(.caption)
                        .foregroundStyle(BojiColor.textSecondary)
                }

                Button(action: onStartTraining) {
                    HStack(spacing: BojiLayout.inline) {
                        Image(systemName: "play.fill")
                            .bojiType(.secondary)
                        Text("继续当前训练")
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
                            Text("依据：近 3 天训练量与睡眠，强度已对齐你的恢复窗口")
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
                            quickModifierChip(title: "肩峰受限换动作", systemImage: "arrow.triangle.swap")
                            quickModifierChip(title: "压缩至30分钟", systemImage: "timer")
                            quickModifierChip(title: "递减组强泵感", systemImage: "waveform.path.ecg")
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
                            Text(today.trainingLog.hasConfirmedTraining ? "查看训练记录" : "开始今日训练")
                                .bojiType(.body)
                        }
                        .frame(maxWidth: .infinity, minHeight: BojiSize.primaryButtonHeight)
                    }
                    .buttonStyle(BojiButtonStyle(kind: .primary))

                    Button("计划详情") { onOpenHub("训练计划") }
                        .buttonStyle(BojiButtonStyle(kind: .secondary))
                        .frame(minHeight: BojiSize.primaryButtonHeight)
                }

            } else {
                VStack(alignment: .leading, spacing: BojiLayout.tight) {
                    Text("超量恢复日")
                        .bojiFont(.cardTitle)
                        .foregroundStyle(BojiColor.textPrimary)
                    Text("今日未安排力量训练任务，适宜进行轻度拉伸、筋膜放松或补充充足蛋白质。")
                        .bojiType(.caption)
                        .foregroundStyle(BojiColor.textSecondary)
                        .lineSpacing(3)
                }

                HStack(spacing: BojiLayout.rowGap) {
                    Button("挑选经典方案") { showPresetPlans = true }
                        .buttonStyle(BojiButtonStyle(kind: .secondary))
                    Button("AI 制定计划", action: onArrangePlan131)
                        .buttonStyle(BojiButtonStyle(kind: .primary))
                }
            }
        }
        .padding(BojiLayout.cardInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clubGlassEffect(in: RoundedRectangle(cornerRadius: BojiRadius.card, style: .continuous))
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
                appliedModifierNotice = "已根据「\(title)」微调动作编排"
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
                Label("能量与营养", systemImage: "fork.knife")
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
        .clubGlassEffect(in: RoundedRectangle(cornerRadius: BojiRadius.card, style: .continuous))
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
                Label("智能分析", systemImage: "sparkles")
                    .bojiType(.body)
                    .foregroundStyle(BojiColor.textPrimary)
                Spacer()
                Text("三大专业进阶引擎")
                    .bojiType(.caption)
                    .foregroundStyle(BojiColor.textTertiary)
            }

            VStack(spacing: BojiLayout.inline) {
                // 1. AI 训练计划
                Button(action: onArrangePlan131) {
                    intelligenceFeatureRow(
                        title: "AI 训练计划",
                        roleTag: "规划未来",
                        detail: "个性化周期定制 · 动作库与器械校验",
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
                        title: "AI 每日日报",
                        roleTag: "总结当下",
                        detail: hasConfirmed ? "今日训练已确认 · 查看客观数据与建议" : "今日出勤核算、餐食营养与明日恢复",
                        symbol: "sun.max",
                        accentColor: .orange
                    )
                }
                .buttonStyle(.plain)

                Divider().opacity(0.4)

                // 3. AI 每周周报
                Button(action: onOpenWeeklyReport) {
                    intelligenceFeatureRow(
                        title: "AI 每周周报",
                        roleTag: "长期进步",
                        detail: "7天出勤、总容量变化对比与体型趋势复盘",
                        symbol: "chart.xyaxis.line",
                        accentColor: .blue
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(BojiLayout.rowGap)
            .clubGlassEffect(in: RoundedRectangle(cornerRadius: BojiRadius.card, style: .continuous))
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
                .clubGlassEffect(in: RoundedRectangle(cornerRadius: BojiRadius.inner, style: .continuous))
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
                        Text("挑选经典成熟方案，或定制属于你的计划")
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
            .clubGlassEffect(in: RoundedRectangle(cornerRadius: BojiRadius.inner, style: .continuous))
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
                        Text("点击返回训练 · 已登记 \(snapshot.completedSets)/\(snapshot.totalSets) 组").bojiType(.caption).foregroundStyle(BojiColor.textPrimary)
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
