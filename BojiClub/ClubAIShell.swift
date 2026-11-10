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

enum ClubShellMode: Hashable { case clubAI, training, records }
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
    @State private var conversationVisible = false
    @State private var focusRequest = 0
    @State private var recordsCategory = "训练"
    @State private var sidebarRoute: ClubSidebarRoute?
    @State private var showNewConversationConfirm = false
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
    @State private var showLegacyOnboarding135 = false
    @State private var preparingWelcome135 = false
    @State private var planSetupTask135: Task<Void, Never>?
    @State private var showFinishOnboarding135 = false
    @State private var reconcilingPlan135 = false
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
            .onReceive(NotificationCenter.default.publisher(for: ClubAIRoute.notification)) { note in
                guard let request = note.object as? ClubAIRouteRequest, request.owner == ownerID else { return }
                sidebarRoute = nil; showHubSection = nil; trainingRoute = nil; guideOwner = nil
                creatingForDate = nil; showTrainingPlans = false; showExerciseLibrary = false
                if let id = request.conversation, UUID(uuidString: id) != nil { coach.selectConversation(id, owner: ownerID) }
                else { coach.newConversation(owner: ownerID, keepDraft: true) }
                if !request.question.isEmpty { coach.question = request.question }
                coach.references = request.references; coach.continuationSource = request.source; coach.reviewScope = request.scope
                coach.persistExtras(); mode = .clubAI; conversationVisible = true; focusRequest += 1
                if request.sendImmediately131 { coach.sendRequest += 1 }
            }
            .onChange(of: coach.references) { _, _ in coach.persistExtras() }
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
            .onChange(of: conversationVisible) { _, visible in
                store.clubAIInterfacePresented = visible
                if !visible { handleNotificationRoute() }
            }
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
                trainingRoute = nil; restDeadlines = [:]; conversationVisible = false
                sidebarOpen = false; sidebarRoute = nil; columns = .detailOnly
                mealEntryRoute = nil; bodyEntryRoute = nil; creatingForDate = nil
                showTrainingPlans = false; showExerciseLibrary = false; showHubSection = nil
                guideOwner = nil; showNewConversationConfirm = false
                aiPath = NavigationPath(); trainingPath = NavigationPath()
                planSetupTask135?.cancel(); planSetupTask135 = nil; onboarding.reset()
                coach.reset(); recordsPath131 = NavigationPath(); recordsCategory = "训练"; trainingScrollAnchor = nil; calendarExpanded = false; selectedDate = Date(); currentDay = ClubDates.key(Date())
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
                    .simultaneousGesture(DragGesture(minimumDistance: 25).onEnded { value in
                        if value.startLocation.x < 24, value.translation.width > 70,
                           abs(value.translation.height) < value.translation.width * 0.6 { openSidebar() }
                    })
                    .overlay(alignment: .leading) { sidebarLayer }
            }
        }
        .background { ClubBackground() }
    }

    @ViewBuilder private var navigationWorkspace: some View {
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
        } else {
            NavigationStack(path: $recordsPath131) {
                ClubRecordsHub(category: $recordsCategory, embeddedInShell: true)
                    .toolbar { rootToolbar }
                    .navigationBarTitleDisplayMode(.inline)
            }.clubBottomBar { bottomDock }
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
                    Button("开启新对话", systemImage: "square.and.pencil", action: requestNewConversation)
                    Picker("下一条回答方式", selection: $coach.deepAnalysis) { Text("自动").tag(false); Text("深入").tag(true) }
                } label: { Image(systemName: "ellipsis") }
                .accessibilityLabel("对话选项").accessibilityIdentifier("v2-context-action")
            } else if mode == .training {
                Menu {
                    Button("管理训练计划", systemImage: "calendar") { showTrainingPlans = true }
                    Button("创建训练计划", systemImage: "plus") { creatingForDate = ClubTrainingRoute(date: selectedDate) }
                    Button("动作库", systemImage: "rectangle.stack") { showExerciseLibrary = true }
                } label: { Image(systemName: "ellipsis") }
                .accessibilityLabel("训练更多操作").accessibilityIdentifier("v2-context-action")
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
        if conversationVisible {
            ClubCoachView(session: coach, embeddedInShell: true)
        } else {
            VStack(spacing:0) {
                if onboarding.state?.taskCompleteAvailable == true && account.user?.onboardingCompleted == false {
                    Button("完成设置") { showFinishOnboarding135 = true }.font(.subheadline).frame(minHeight: 44)
                }
            ClubAIWorkspaceIdleView(activeWorkout: activeWorkout, isNewUser: account.user?.onboardingCompleted == false, onOpenProfile: { showProfileBasics135 = true }, onOpenPermissions: { showPermissions135 = true }, onQuickQuestion: { question in
                coach.question = question; focusRequest += 1
            }, onArrangePlan131: {
                coach.newConversation(owner: ownerID, keepDraft: true)
                coach.planIntake131 = true; conversationVisible = true
                if account.user?.onboardingCompleted == false {
                    planSetupTask135 = Task {
                        let owner = ownerID, conversation = coach.conversation
                        await onboarding.load(account: account)
                        if onboarding.taskKind != .planCreate { await onboarding.createSession(.planCreate, account: account) }
                        guard owner == ownerID, conversation == coach.conversation else { return }
                        coach.onboardingPlanSession135 = onboarding.taskKind == .planCreate ? onboarding.state?.session?.id : nil
                        if onboarding.error != nil { coach.error = "训练计划暂时无法准备，请稍后重试。" }
                    }
                }
            }, onOpenHub: { if $0 == "训练计划" { mode = .training } else { showHubSection = $0 } }, onStartTraining: {
                if activeWorkout != nil { openActiveWorkout() }
                else { selectedDate = Date(); startTrainingFromPlan() }
            }, onRecordMeal: { openMeal("手动") })
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
            if mode == .clubAI {
                if let source = coach.continuationSource {
                    HStack {
                        Label("引用解读：" + source.title, systemImage: "doc.text").font(.caption).lineLimit(1)
                        Spacer()
                        Button("移除") { coach.continuationSource = nil; coach.persistExtras() }.font(.caption).frame(minHeight: 44)
                    }.padding(.horizontal, 20).background(BojiColor.brandMist, in: Capsule()).padding(.horizontal, 14)
                }
                ClubSharedComposer(text: $coach.question, attachments: $coach.attachments, references: $coach.references, deepAnalysis: $coach.deepAnalysis, conversationID: coach.conversation, busy: coachBusy, enabled: flags.aiEnabled,
                    focusRequest: focusRequest + coach.focusRequest, errorText: coach.error, onSend: sendComposer,
                    onRecordMeal: { openMeal($0) },
                    onRecordBody: { bodyEntryRoute = ClubDateRoute(date: Date()) }, waitingForReferences130: coach.preparingReferences, onCancelWaiting130: coach.cancelReferenceSend130)
                    .frame(maxWidth: BojiSize.contentWidth)
                    .padding(.horizontal, 14).frame(maxWidth: .infinity)
                    .id(ownerID)
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
            .alert("计划已保存", isPresented: $showFinishOnboarding135) {
                Button("完成设置") {
                    Task { if !(await onboarding.completeSession(account: account, covenantVersion: "2026-10-25")) { coach.error = onboarding.error ?? "暂时无法完成设置，请重试。" } }
                }
                Button("稍后", role: .cancel) { }
            } message: { Text("完成设置后，可以选择会员方案。") }
            .confirmationDialog("开始新对话", isPresented: $showNewConversationConfirm, titleVisibility: .visible) {
                Button("保存草稿并开始新对话") { startNewConversation(keepDraft: true) }
                Button("放弃当前输入", role: .destructive) { startNewConversation(keepDraft: false) }
                Button("继续当前输入", role: .cancel) {}
            } message: { Text("未发送的内容可保存到侧栏草稿。已保存的对话与训练记录会保留。") }
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
                if !hasTurns && !recovering {
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
        SidebarHostView(floating: floating, selectedConversation: conversationVisible ? coach.conversation : nil,
            onClose: closeSidebar, onToday: { closeSidebar(); returnToToday() },
            onNewConversation: { closeSidebar(); mode = .clubAI; requestNewConversation() },
            onOpenConversation: { conversation in
                closeSidebar(); mode = .clubAI
                coach.selectConversation(conversation, owner: ownerID)
                conversationVisible = true
            }, onDeleteConversation: { conversation in
                if store.deleteCoachConversation(conversation, jobs: ai.jobs) {
                    if let ownerID { ClubChatDraftStorage.clear(owner: ownerID, conversation: conversation) }
                    if conversation == coach.conversation { startNewConversation(keepDraft: false) }
                }
            }, onOpen: { route in
                closeSidebar()
                if route == .records { mode = .records }
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
            NavigationStack { ClubAIMemoryView().toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { sidebarRoute = nil } } } }
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
    private func openMeal(_ mode: String) {
        mealEntryRoute = ClubComposerMealRoute(date: Date(), mode: mode)
    }
    private func sendComposer() {
        let text = coach.question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard flags.aiEnabled, !coachBusy, (!text.isEmpty || !coach.attachments.isEmpty), text.count <= 1200 else { return }
        if account.user?.onboardingCompleted == false && !onboarding.hasSession && !account.isPreviewAccount {
            guard !preparingWelcome135 else { return }
            preparingWelcome135 = true
            Task {
                defer { preparingWelcome135 = false }
                await planSetupTask135?.value
                if !onboarding.hasSession { await onboarding.load(account: account) }
                if !onboarding.hasSession && onboarding.error == nil { await onboarding.createSession(.explore, account: account) }
                guard onboarding.hasSession else { coach.error = "暂时无法连接，消息还在。请重试。"; return }
                conversationVisible = true; coach.sendRequest += 1
            }
            return
        }
        conversationVisible = true
        coach.sendRequest += 1
    }
    private func requestNewConversation() {
        if coach.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && coach.attachments.isEmpty { startNewConversation(keepDraft: true) }
        else { showNewConversationConfirm = true }
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
            Text("Club AI").tag(ClubShellMode.clubAI)
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
    var selectedConversation: String?
    let onClose: () -> Void
    let onToday: () -> Void
    let onNewConversation: () -> Void
    let onOpenConversation: (String) -> Void
    let onDeleteConversation: (String) -> Void
    let onOpen: (ClubSidebarRoute) -> Void
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var ai: AIService
    @EnvironmentObject private var account: AccountService
    @EnvironmentObject private var weekly: WeeklyReviewService
    @Environment(\.dynamicTypeSize) private var typeSize
    @ObservedObject private var flags = FeatureFlagService.shared
    @State private var recentExpanded = false
    @State private var allExpanded = false
    @State private var draftsExpanded = false
    @State private var preSearchExpansion: [Bool]?
    @State private var search = ""
    @State private var historyLimit = 30
    @State private var loadingHistory = false
    @State private var deletingConversation: String?
    @AccessibilityFocusState private var headingFocused: Bool

    private var conversations: [String] {
        var seen = Set<String>()
        let deleted = Set(store.state.deletedAIJobIDs ?? [])
        return ai.jobs.filter { !deleted.contains($0.id) }.sorted { $0.created > $1.created }
            .compactMap { ClubCoachRules.conversation($0) }.filter { seen.insert($0).inserted }
    }
    private func turns(_ conversation: String) -> [AILocalJob] {
        ClubCoachRules.turns(ai.jobs, conversation: conversation, deleted: Set(store.state.deletedAIJobIDs ?? []))
    }
    private func title(_ conversation: String) -> String {
        turns(conversation).first?.request.payload["question"]?.string ?? "此前对话"
    }
    private var filteredHistory: [String] {
        guard !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return conversations }
        return conversations.filter { id in
            turns(id).contains { job in
                (job.request.payload["question"]?.string ?? "").localizedCaseInsensitiveContains(search) ||
                (job.result?.coach?.answer ?? "").localizedCaseInsensitiveContains(search)
            }
        }
    }
    private var drafts: [String] {
        guard let owner = store.editingAccountID else { return [] }
        return ClubCoachDraftStorage.conversations(owner: owner).filter { id in
            search.isEmpty || ClubCoachDraftStorage.load(owner: owner, conversation: id).localizedCaseInsensitiveContains(search)
                || ("照片".localizedCaseInsensitiveContains(search) && ClubChatDraftStorage.load(owner: owner, conversation: id)?.attachments.isEmpty == false)
        }
    }
    var body: some View {
        Group {
            if floating { content.clubGlassEffect(in: RoundedRectangle(cornerRadius: 28, style: .continuous)) }
            else { content }
        }
        .accessibilityIdentifier("v2-sidebar-panel")
        .onAppear { headingFocused = true }
        .accessibilityAction(.escape, onClose)
        .confirmationDialog("删除这段对话？", isPresented: Binding(get: { deletingConversation != nil }, set: { if !$0 { deletingConversation = nil } }), titleVisibility: .visible) {
            if let deletingConversation {
                Button("删除对话", role: .destructive) { onDeleteConversation(deletingConversation); self.deletingConversation = nil }
            }
            Button("取消", role: .cancel) { deletingConversation = nil }
        } message: { Text("删除对话不会删除已确认保存的训练、饮食和身体记录。") }
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
                        entry("新对话", symbol: "square.and.pencil", id: "v2-sidebar-newchat", action: onNewConversation)
                    }
                    Section {
                        DisclosureGroup("草稿", isExpanded: $draftsExpanded) {
                            if drafts.isEmpty { Text("没有待发送的草稿").foregroundStyle(.secondary) }
                            ForEach(drafts, id: \.self) { id in
                                Button { onOpenConversation(id) } label: {
                                    Label(draftTitle(id), systemImage: "square.and.pencil")
                                        .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                                }.accessibilityIdentifier("v2-sidebar-draft")
                            }
                        }
                        DisclosureGroup("最近对话", isExpanded: $recentExpanded) {
                            if filteredHistory.isEmpty { Text(search.isEmpty ? "还没有保存的对话" : "没有匹配结果").foregroundStyle(.secondary) }
                            ForEach(Array(filteredHistory.prefix(3)), id: \.self) { historyRow($0) }
                        }
                        DisclosureGroup("全部历史对话", isExpanded: $allExpanded) {
                            if filteredHistory.isEmpty { Text(search.isEmpty ? "还没有保存的对话" : "没有匹配结果").foregroundStyle(.secondary) }
                            ForEach(Array(filteredHistory.prefix(historyLimit)), id: \.self) { historyRow($0) }
                            if filteredHistory.count > historyLimit || ai.hasMoreTaskHistory {
                                Button(loadingHistory ? "正在同步…" : "加载更早的对话") { loadMoreHistory() }
                                    .disabled(loadingHistory).accessibilityIdentifier("v2-history-load-more")
                            }
                        }.accessibilityIdentifier("v2-sidebar-history")
                    }
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
                    Section {
                        entry("处理进度", symbol: "checklist", id: "v2-sidebar-tasks") { onOpen(.tasks) }
                        entry("AI 对我的了解", symbol: "brain.head.profile", id: "v2-sidebar-aimemory") { onOpen(.aiMemory) }
                    }
                }
                .modifier(ClubSidebarListPolicy(floating: floating))
                .scrollContentBackground(.hidden)
                .environment(\.defaultMinListRowHeight, 44)
                .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索历史对话")
                .onChange(of: search) { old, value in
                    if !value.isEmpty {
                        if old.isEmpty { preSearchExpansion = [recentExpanded, allExpanded, draftsExpanded] }
                        recentExpanded = true; allExpanded = true; draftsExpanded = true
                        historyLimit = max(30, conversations.count)
                    } else if let previous = preSearchExpansion {
                        recentExpanded = previous[0]; allExpanded = previous[1]; draftsExpanded = previous[2]; preSearchExpansion = nil
                    }
                }
                .onChange(of: store.editingAccountID) { _, _ in
                    recentExpanded = false; allExpanded = false; draftsExpanded = false; search = ""; preSearchExpansion = nil
                }
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
        .tint(ClubBrand.accent).foregroundStyle(BojiColor.textPrimary)
        .clipShape(RoundedRectangle(cornerRadius: floating ? 28 : 0, style: .continuous))
    }
    private var accountEntries: some View {
        Group {
            entry("我的", symbol: "person.crop.circle", id: "v2-sidebar-profile") { onOpen(.profile) }
            entry("设置", symbol: "gearshape", id: "v2-sidebar-settings") { onOpen(.settings) }
        }
    }
    private func draftTitle(_ id: String) -> String {
        let owner = store.editingAccountID ?? 0
        let text = ClubCoachDraftStorage.load(owner: owner, conversation: id)
        if !text.isEmpty { return text }
        if let refs = ClubChatDraftStorage.load(owner: owner, conversation: id)?.references, !refs.isEmpty { return "待发送引用 · \(refs.count) 项" }
        return "待发送照片 · \(ClubChatDraftStorage.load(owner: owner, conversation: id)?.attachments.count ?? 0) 张"
    }
    private func sidebarHeading(_ text: String) -> some View {
        Text(text).font(.body.weight(.medium)).foregroundColor(BojiColor.textPrimary)
            .accessibilityAddTraits(.isHeader).listRowBackground(Color.clear).listRowSeparator(.hidden)
    }
    private func entry(_ text: String, symbol: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(text, systemImage: symbol).font(.body).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading) }
            .listRowBackground(Color.clear).listRowSeparator(.hidden)
            .accessibilityIdentifier(id)
    }
    private func historyRow(_ conversation: String) -> some View {
        Button { onOpenConversation(conversation) } label: {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title(conversation)).font(.body).lineLimit(typeSize.isAccessibilitySize ? nil : 2).fixedSize(horizontal: false, vertical: true)
                    if let last = turns(conversation).last {
                        Text(ClubDates.label(last.created, format: "M月d日 HH:mm")).font(.caption).foregroundStyle(BojiColor.textSecondary)
                    }
                }
                Spacer(minLength: 0)
                if conversation == selectedConversation { Image(systemName: "checkmark").accessibilityLabel("当前对话") }
            }.frame(minHeight: 44)
        }
        .listRowBackground(Color.clear).listRowSeparator(.hidden)
        .contextMenu {
            Button("打开对话", systemImage: "bubble.left") { onOpenConversation(conversation) }
            Button("删除对话", systemImage: "trash", role: .destructive) { deletingConversation = conversation }
        }
        .swipeActions { Button("删除", role: .destructive) { deletingConversation = conversation } }
    }
    private func loadMoreHistory() {
        historyLimit += 30
        guard ai.hasMoreTaskHistory, !loadingHistory else { return }
        loadingHistory = true
        Task { await ai.recoverTasks(account: account, weekly: weekly, store: store); loadingHistory = false }
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
    @State private var greetingSeed = Int.random(in: 0..<1000)
    private var greeting: String {
        let options = activeWorkout != nil ? ["训练进行得怎么样？", "这一组，按自己的节奏来。"] : today.exercises.isEmpty ? ["今天，想先聊点什么？", "从一条记录开始，也很好。", "想聊聊最近的训练吗？"] : ["准备好，开始今天的训练吗？", "今天，想先聊点什么？", "看看今天的安排？"]
        return options[greetingSeed % options.count]
    }
    // Revalidate against current candidates even before onChange runs: withdrawn/other-owner text never renders.
    private var insight: ClubHomeInsightSelection? {
        ClubHomeInsightStability.select(current: selectedInsight, candidates: insightCandidates)
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(spacing: 10) {
                    BojiBrandMark(size:64)
                    Text("薄肌俱乐部").font(.caption).tracking(2).foregroundStyle(.secondary)
                    Text(isNewUser ? "嗨，我是 Club AI" : greeting).font(.title2.weight(.medium))
                    if isNewUser { Text("想安排训练，还是先记录今天的饮食？").font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center) }
                }
                .frame(maxWidth: .infinity).padding(.top, 24).padding(.bottom, 12)
                if activeWorkout != nil || !today.exercises.isEmpty { trainingCard }
                if flags.aiEnabled {
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
                Button("先聊聊") { onQuickQuestion("") }.frame(minHeight: 44)
                Button("补充资料", action: onOpenProfile).frame(minHeight: 44)
            }
        }.buttonStyle(.borderless).tint(ClubBrand.accent)
    }
    private var trainingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(activeWorkout == nil ? "今日训练" : "进行中的训练").font(.subheadline).foregroundStyle(.secondary)
            Text(activeWorkout?.workoutName ?? (today.trainingLog.hasConfirmedTraining ? "今天的训练已保存" : today.trainingLog.exercises.prefix(2).map(\.name).joined(separator: " · ")))
                .font(.headline)
            Text(activeWorkout.map { "\($0.dateKey) · \($0.completedSets)/\($0.totalSets) 组" } ?? "\(today.trainingLog.exercises.count) 个动作")
                .font(.subheadline).foregroundStyle(.secondary)
            HStack(spacing: 16) {
                Button(activeWorkout != nil ? "继续训练" : today.trainingLog.hasConfirmedTraining ? "查看训练" : "开始训练", action: onStartTraining)
                    .clubNativeGlassButton(prominent: true).tint(BojiColor.brandMist).foregroundStyle(BojiColor.brandContent).frame(minHeight: 44)
                Button("查看计划") { onOpenHub("训练计划") }.buttonStyle(.borderless)
            }.tint(ClubBrand.accent)
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .background(BojiColor.cardSurface, in: RoundedRectangle(cornerRadius: 22))
        .overlay { RoundedRectangle(cornerRadius: 22).stroke(BojiColor.outline, lineWidth: 0.5) }
        .accessibilityIdentifier("v2-today-training")
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
