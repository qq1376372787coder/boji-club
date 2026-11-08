import SwiftUI
import AuthenticationServices
import UserNotifications

@main
struct BojiClubApp: App {
    @UIApplicationDelegateAdaptor(ClubPushDelegate.self) private var pushDelegate
    @StateObject private var store = AppStore()
    @StateObject private var ai = AIService()
    @StateObject private var account = AccountService()
    @StateObject private var health = HealthDataService()
    @StateObject private var weekly = WeeklyReviewService()
    @StateObject private var clubSeason = ClubSeasonService()
    @StateObject private var membership = MembershipService()
    @StateObject private var notifications = AppNotificationService()
    @StateObject private var automation = ClubAutomationService()

    var body: some Scene {
        WindowGroup {
            AppRootContainerView()
                .environmentObject(store)
                .environmentObject(ai)
                .environmentObject(account)
                .environmentObject(health)
                .environmentObject(weekly)
                .environmentObject(clubSeason)
                .environmentObject(membership)
                .environmentObject(notifications)
                .environmentObject(automation)
                .tint(ClubBrand.accent)
                .environment(\.locale, Locale(identifier: "zh_CN"))
        }
    }
}

private struct AppRootContainerView: View {
    @AppStorage("boji.hasCompletedFirstLaunchWalkthrough") private var hasCompletedWalkthrough = false
    @State private var showingLaunch = true
    @State private var showingWalkthrough = false

    var body: some View {
        ZStack {
            RootView()
                .environment(\.firstLaunchWalkthroughPresented, showingWalkthrough)
                .allowsHitTesting(!showingWalkthrough && !showingLaunch)
                .accessibilityHidden(showingWalkthrough || showingLaunch)

            if showingWalkthrough {
                FirstLaunchWalkthroughView(isPresented: $showingWalkthrough)
                    .zIndex(20)
                    .transition(.opacity)
            }

            if showingLaunch {
                LaunchArtworkView(isPresented: $showingLaunch)
                    .zIndex(30)
                    .transition(.opacity)
            }
        }
        .onAppear {
            #if DEBUG
            let force = ProcessInfo.processInfo.environment["BOJI_SHOW_ONBOARDING"] == "1" ||
                        ProcessInfo.processInfo.arguments.contains("-showOnboarding")
            showingWalkthrough = force
            #else
            // Account setup has its own entrance. The introduction remains available from Help.
            showingWalkthrough = false
            #endif
        }
        .onReceive(NotificationCenter.default.publisher(for: .bojiShowWalkthrough)) { _ in
            showingWalkthrough = true
        }
    }
}

extension Notification.Name {
    static let bojiShowWalkthrough = Notification.Name("bojiShowWalkthrough")
}

private struct LaunchArtworkView: View {
    @Binding var isPresented: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            Color("LaunchBackground").ignoresSafeArea()
            BojiBrandMark(size:96)
        }
        .allowsHitTesting(false).accessibilityHidden(true)
        .task {
            guard isPresented else { return }
            // Match the native launch screen and yield immediately to the real UI.
            await Task.yield()
            withAnimation(reduceMotion ? nil : BojiMotion2.state) { isPresented = false }
        }
    }
}

struct RootView: View {
    @Environment(\.firstLaunchWalkthroughPresented) private var walkthroughPresented
    @EnvironmentObject private var automation: ClubAutomationService
    @EnvironmentObject private var clubSeason: ClubSeasonService
    @EnvironmentObject private var weekly: WeeklyReviewService
    @EnvironmentObject private var health: HealthDataService
    @EnvironmentObject private var account: AccountService
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var ai: AIService
    @EnvironmentObject private var membership: MembershipService
    @EnvironmentObject private var notifications: AppNotificationService
    @Environment(\.scenePhase) private var scenePhase
    @State private var showRecordRepair = false
    @State private var pendingRouteNotice = false
    @State private var defaultsSyncTask: Task<Void, Never>?
    @AppStorage("remoteConfig.dismissedVersion") private var dismissedConfigVersion = -1
    var body: some View { foregroundContent }

    @ViewBuilder private var remoteConfigNotice: some View {
        if !walkthroughPresented, let config = account.remoteConfig, config.hasNotice, config.version > dismissedConfigVersion {
            RemoteConfigNoticeView(config: config, dismiss: { dismissedConfigVersion = config.version })
        }
    }

    private var activeMemberAccountID: Int? {
        guard account.phase == .ready, account.user?.membership?.active == true,
              membership.hasMemberAccess(for: account.user?.id) else { return nil }
        return account.user?.id
    }

    private var accountContent: some View {
        Group {
            if account.pendingDeletionID != nil, account.phase != .signedOut { AccountDeletionStatusView() }
            else { switch account.phase {
            case .checking:
                ZStack { ClubBackground(); VStack { ClubLoadingCard(title: "正在连接薄肌俱乐部…", detail: account.notice ?? "正在恢复你的账号与记录。"); if account.notice != nil { Button("重新连接") { Task { await account.restore() } }.buttonStyle(SecondaryButton()) } }.padding(BojiLayout.sectionGap).frame(maxWidth: 420) }
            case .signedOut:
                NavigationStack { AccountEntryView().toolbar(.hidden, for: .navigationBar) }
            case .onboarding:
                IndependentProfileOnboardingView().id(account.user?.id)
            case .ready:
                if activeMemberAccountID == nil { MembershipGateView() }
                else { mainOrAuditContent }
            } }
        }
    }

    @ViewBuilder private var mainOrAuditContent: some View {
        #if DEBUG
        let auditScreen = ProcessInfo.processInfo.environment["BOJI_AUDIT_SCREEN"] ?? ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("-audit:") })?.replacingOccurrences(of: "-audit:", with: "")
        if let screen = auditScreen {
            BojiAuditHost(initialScreen: screen)
        } else { ClubAIShellView().id(account.user?.id) }
        #else
        ClubAIShellView().id(account.user?.id)
        #endif
    }

    private var recoveryContent: some View {
        accountContent
    }

    private var accountLifecycleContent: some View {
        recoveryContent
        .task { if case .checking = account.phase { await account.restore() } }
        .onReceive(NotificationCenter.default.publisher(for: ASAuthorizationAppleIDProvider.credentialRevokedNotification)) { _ in Task { await account.checkAppleCredential(force: true) } }
        .onChange(of: scenePhase, initial: true) { _, phase in
            weekly.setForeground(phase == .active)
            if phase == .active { Task { await notifications.refreshAuthorizationStatus(); membership.refresh(force: true) } }
        }
        .onChange(of: account.user?.id, initial: true) { _, id in
            if id == nil, case .checking = account.phase { return }
            notifications.activate(id)
            ClubPushService.shared.activate(id)
            Task { await FoodCutout.clearCache() }
            if let id {
                store.activateAccount(id, profile: account.user?.profile)
                if let profile = account.user?.profile { store.seedProfile(profile) }
            }
            else { store.deactivateAccount(); ai.deactivateAccount() }
            membership.activate(account: account.user, accountService: account)
        }
        .onChange(of: activeMemberAccountID, initial: true) { _, id in
            automation.activate(id)
            clubSeason.activate(id)
            TrainingActivityService.shared.activate(id)
            health.activate(id)
            weekly.activate(id)
            if let id {
                ai.activateAccount(id, account: account)
                if !account.isPreviewAccount { store.beginCloudSync(account: account, ai: ai) }
            } else {
                ai.deactivateAccount()
                store.suspendCloudSyncForMembership()
                notifications.syncTrainingReminders(profile: nil)
                notifications.syncMealReminders(days: [:])
            }
        }
        .task(id: "\(account.pendingLocalErasureIDs)") {
            for id in account.pendingLocalErasureIDs {
                _ = store.eraseAccountData(id)
                _ = ai.eraseAccountData(id)
                _ = weekly.eraseAccountData(id)
                _ = health.eraseAccountData(id)
                _ = await ClubDiskCache.shared.erase(id)
                account.completeLocalErasure(id, success: true)
            }
        }
        .onChange(of: account.phase) { _, phase in
            if case .signedOut = phase {
                clubSeason.clear()
                TrainingActivityService.shared.activate(nil)
                store.deactivateAccount()
                notifications.syncTrainingReminders(profile: nil)
                notifications.syncMealReminders(days: [:])
            }
        }
    }

    private var notificationRoutingContent: some View {
        accountLifecycleContent
        .sheet(item: Binding(get: { activeMemberAccountID == nil || walkthroughPresented || notifications.route?.kind == "training" || store.trainingInterfacePresented || store.clubAIInterfacePresented ? nil : notifications.route }, set: { notifications.route = $0 })) { route in
            NavigationStack {
                Group {
                    if ["club_weekly","club_workout"].contains(route.kind) {
                        if let id = route.jobID { ClubAutomaticReportReader(jobID: id) }
                        else { ReportLibraryView(initialKind: route.kind == "club_weekly" ? .weekly : .workout) }
                    }
                    else if route.kind == "weekly_center" || route.kind == "weekly_review" { WeeklyReportView() }
                    else if route.kind == "report" { DailyReportView(initialDateKey: route.date) }
                    else if route.kind == "task" || route.kind == "task_center" { ReportLibraryView() }
                    else if route.kind == "body" { BodyWeightView(initialDate: ClubDates.date(fromKey: route.date) ?? Date()) }
                    else if route.kind == "meal" {
                        if let date = ClubDates.date(fromKey: route.date) { MealEditorView(date: date) }
                        else { EmptyNote(title: "日期不可用", detail: "请从输入框左侧“＋”或侧栏“我的记录 → 饮食”重新打开记录。") }
                    }
                    else { ReportLibraryView() }
                }
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { notifications.route = nil } } }
            }
        }
        .onChange(of: notifications.route) { _, route in
            let blocked = activeMemberAccountID == nil || walkthroughPresented || route?.kind == "training" || store.trainingInterfacePresented || store.clubAIInterfacePresented
            pendingRouteNotice = route != nil && blocked
        }
        .safeAreaInset(edge: .top) {
            if pendingRouteNotice, let kind = notifications.route?.kind {
                BojiStatusBanner(
                    icon: "bell.badge",
                    title: "「\(RootView.routeDisplayName(kind))」已保留",
                    detail: kind == "training"
                        ? "训练进行中不会自动弹出，请稍后从通知中心重新打开本条通知。"
                        : "当前界面不便弹出，退出训练或对话后会自动打开。",
                    tint: ClubBrand.accent,
                    actionTitle: "知道了") { pendingRouteNotice = false }
            }
        }
    }

    private static func routeDisplayName(_ kind: String) -> String {
        switch kind {
        case "club_weekly", "club_workout": return "俱乐部报告"
        case "weekly_center", "weekly_review": return "每周回顾"
        case "report": return "日报"
        case "task", "task_center": return "任务中心"
        case "body": return "身体记录"
        case "meal": return "饮食记录"
        case "training": return "训练提醒"
        default: return "提醒"
        }
    }

    private var reminderContent: some View {
        notificationRoutingContent
        .onChange(of: store.trainingScheduleSignature, initial: true) { _, _ in
            notifications.syncTrainingReminders(profile: activeMemberAccountID == nil ? nil : store.state.profile, plannedDays: store.state.days)
            notifications.syncMealReminders(days: activeMemberAccountID == nil ? [:] : store.state.days)
        }
        .onChange(of: notifications.trainingRemindersEnabled) { _, _ in
            notifications.syncTrainingReminders(profile: activeMemberAccountID == nil ? nil : store.state.profile, plannedDays: store.state.days)
        }
        .onChange(of: notifications.timeRevision) { _, _ in
            // A4/A5：提醒时间或餐次设置变化后重排；签名幂等，不会重复添加。
            notifications.syncTrainingReminders(profile: activeMemberAccountID == nil ? nil : store.state.profile, plannedDays: store.state.days)
            notifications.syncMealReminders(days: activeMemberAccountID == nil ? [:] : store.state.days)
        }
        .onChange(of: notifications.mealReminders) { _, _ in
            notifications.syncMealReminders(days: activeMemberAccountID == nil ? [:] : store.state.days)
        }
        .onChange(of: store.mealReminderSignature) { _, _ in
            // 记录/删除餐食后重排：已有记录的餐次不再提醒。
            notifications.syncMealReminders(days: activeMemberAccountID == nil ? [:] : store.state.days)
        }
        .onChange(of: notifications.authorizationStatus) { _, _ in
            notifications.syncTrainingReminders(profile: activeMemberAccountID == nil ? nil : store.state.profile, plannedDays: store.state.days)
            // F11：首次授权后餐次提醒立即生效，不等其他事件触发。
            notifications.syncMealReminders(days: activeMemberAccountID == nil ? [:] : store.state.days)
            Task { await ClubPushService.shared.sync(account: account, ai: ai, notifications: notifications, settings: automation.settings) }
        }
        .onChange(of: account.user?.membership?.active) { _, _ in
            membership.activate(account: account.user, accountService: account)
        }
        .onChange(of: ai.cloudChangeID) { _, _ in store.scheduleCloudSync() }
    }

    @MainActor private func syncMemberAutomation() async {
        guard activeMemberAccountID != nil else { return }
        await automation.syncServer(account: account, ai: ai, store: store)
    }

    private var automationContent: some View {
        reminderContent
        .onReceive(ClubPushService.shared.$token) { _ in
            Task { await ClubPushService.shared.sync(account: account, ai: ai, notifications: notifications, settings: automation.settings) }
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            defaultsSyncTask?.cancel()
            guard activeMemberAccountID != nil else { return }
            defaultsSyncTask = Task {
                do { try await Task.sleep(for: .milliseconds(1500)) } catch { return }
                guard !Task.isCancelled else { return }
                guard activeMemberAccountID != nil else { return }
                await syncMemberAutomation()
            }
        }
        .onChange(of: ai.routingConsentGranted) { _, _ in Task {
            await syncMemberAutomation()
            await ClubPushService.shared.sync(account: account, ai: ai, notifications: notifications, settings: automation.settings)
        } }
        .onChange(of: notifications.dailyReportEnabled) { _, _ in Task { await ClubPushService.shared.sync(account: account, ai: ai, notifications: notifications, settings: automation.settings) } }
        .onChange(of: notifications.weeklyReviewEnabled) { _, _ in Task { await ClubPushService.shared.sync(account: account, ai: ai, notifications: notifications, settings: automation.settings) } }
        .onChange(of: automation.settings) { _, _ in
            Task {
                await syncMemberAutomation()
                await ClubPushService.shared.sync(account: account, ai: ai, notifications: notifications, settings: automation.settings)
            }
            if scenePhase == .active { automation.evaluate(store: store, ai: ai, account: account, membership: membership) }
        }
    }

    private var foregroundContent: some View {
        automationContent
        .safeAreaInset(edge: .top, spacing: 0) { remoteConfigNotice }
        .task(id: "\(account.user?.id ?? 0)-\(activeMemberAccountID ?? 0)-\(scenePhase == .active)") {
            guard let userID = account.user?.id, scenePhase == .active else { return }
            await account.loadRemoteConfig()
            while !Task.isCancelled {
                await account.refreshAccount()
                guard !Task.isCancelled, account.user?.id == userID else { return }
                if activeMemberAccountID == userID {
                    store.extendWeeklyPlans130()
                    notifications.syncTrainingReminders(profile: activeMemberAccountID == nil ? nil : store.state.profile, plannedDays: store.state.days)
                    store.publishWidgetSnapshot()
                    await store.syncNow()
                    guard !Task.isCancelled, account.user?.id == userID else { return }
                    weekly.reconcileCloudReviews(store: store)
                    await ClubPushService.shared.sync(account: account, ai: ai, notifications: notifications, settings: automation.settings)
                    await ai.recoverTasks(account: account, weekly: weekly, store: store)
                    guard !Task.isCancelled, account.user?.id == userID, scenePhase == .active else { return }
                    await syncMemberAutomation()
                    automation.evaluate(store: store, ai: ai, account: account, membership: membership)
                }
                // 保护电池寿命与服务器吞吐，前台维持5分钟一次的稳态健康心跳
                do { try await Task.sleep(for: .seconds(300)) } catch { return }
            }
        }
    }
}

private struct RemoteConfigNoticeView: View {
    let config: ClubRemoteConfig
    let dismiss: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: BojiLayout.inline) {
            Image(systemName: config.requiresUpdateNotice ? "arrow.down.circle.fill" : "megaphone.fill")
                .foregroundStyle(ClubBrand.accent)
                
            VStack(alignment: .leading, spacing: BojiLayout.tight) {
                Text(config.config.announcement.enabled ? config.config.announcement.title : "版本更新提示")
                    .bojiType(.label)
                if config.config.announcement.enabled {
                    Text(config.config.announcement.body)
                        .bojiType(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if config.requiresUpdateNotice {
                    Text("当前构建号 \(ClubRemoteConfig.currentBuild())，请更新至 \(config.config.minimumBuild) 或以上以获得完整修复。")
                        .bojiType(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 6)
            Button("收起提示", action: dismiss)
                .bojiType(.caption)
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, BojiLayout.cardInset)
        .padding(.vertical, BojiLayout.inline)
        .clubGlassEffect(in: RoundedRectangle(cornerRadius: BojiRadius.input, style: .continuous))
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct AccountDeletionStatusView: View {
    @EnvironmentObject private var account: AccountService
    @State private var checking = false
    @State private var nonce = ""
    var body: some View {
        VStack(spacing: BojiLayout.blockGap) {
            Image(systemName: "person.crop.circle.badge.clock").bojiType(.display)
            Text("正在确认注销申请").bojiFont(.pageTitle).foregroundStyle(BojiColor.textPrimary)
            Text(account.notice ?? "请保持网络连接。确认申请已受理后，会清除本机记录并退出账号。").foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button(checking ? "检查中…" : "检查注销状态") {
                checking = true
                Task { await account.restore(); checking = false }
            }.buttonStyle(PrimaryButton()).disabled(checking)
            Button("稍后检查，返回登录") { account.returnToSignInForUnconfirmedDeletion() }
                .buttonStyle(SecondaryButton()).disabled(checking)
            Text("注销申请状态会保留；重新使用申请时的 Apple 账号登录，可继续核对，不会重复提交。").bojiType(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            SignInWithAppleButton(.continue) { request in
                nonce = UUID().uuidString.lowercased(); request.nonce = nonce
            } onCompletion: { result in
                guard case .success(let authorization) = result,
                      let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                      let data = credential.identityToken, let token = String(data: data, encoding: .utf8) else { return }
                checking = true
                Task {
                    defer { checking = false }
                    do { try await account.signInWithApple(identityToken: token, nonce: nonce, authorizationCode: credential.authorizationCode.flatMap { String(data: $0, encoding: .utf8) }, appleUserID: credential.user) }
                    catch { account.notice = AppErrorText.message(error) }
                }
            }.signInWithAppleButtonStyle(.black).frame(height: 48).disabled(checking)
        }.padding(BojiLayout.sectionGap)
    }
}

struct FirstLaunchPermissionsView: View {
    let ownerID: Int
    @EnvironmentObject private var account: AccountService
    @EnvironmentObject private var notifications: AppNotificationService
    @EnvironmentObject private var health: HealthDataService
    @Environment(\.dismiss) private var dismiss

    private var notificationsAuthorized: Bool {
        [.authorized, .provisional, .ephemeral].contains(notifications.authorizationStatus)
    }

    var body: some View {
        ZStack {
            FlowBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: BojiLayout.sectionGap) {
                    FlowHeading(eyebrow: "首次设置", title: "开启提醒与健康同步", subtitle: "可随时在设置中更改，也可以先跳过。")
                    ClubCard {
                        HStack(alignment: .top, spacing: BojiLayout.rowGap) {
                            Image(systemName: "bell.badge").bojiType(.section).foregroundStyle(ClubBrand.accent)
                            VStack(alignment: .leading, spacing: BojiLayout.tight) {
                                Text("训练与餐次提醒").bojiType(.bodyStrong)
                                Text("完成后提醒你训练、同步每周回顾。").bojiType(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Button(notificationsAuthorized ? "已开启" : "打开通知") {
                            Task { await notifications.requestAuthorization() }
                        }
                        .buttonStyle(SecondaryButton())
                        .disabled(notificationsAuthorized)
                    }
                    ClubCard {
                        HStack(alignment: .top, spacing: BojiLayout.rowGap) {
                            Image(systemName: "heart.text.square").bojiType(.section).foregroundStyle(ClubBrand.accent)
                            VStack(alignment: .leading, spacing: BojiLayout.tight) {
                                Text("Apple 健康").bojiType(.bodyStrong)
                                Text(health.enabled ? "已完成连接设置；只显示系统实际可读取的数据。" : "按你的选择读取步数和设备训练；训练写入需另行开启。").bojiType(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Button("连接 Apple 健康") {
                            Task { await health.connect() }
                        }
                        .buttonStyle(SecondaryButton()).disabled(health.busy)
                        Button(health.writeWorkoutsEnabled ? "已开启训练写入" : "允许同步已确认训练") {
                            Task { await health.setWorkoutWritingEnabled(true) }
                        }.buttonStyle(SecondaryButton()).disabled(health.busy || health.writeWorkoutsEnabled)
                        if let message = health.message { Text(message).bojiType(.label).foregroundStyle(.secondary) }
                    }
                    Button("暂不开启") { finish() }
                        .buttonStyle(SecondaryButton())
                    Button("完成") { finish() }
                        .buttonStyle(PrimaryButton())
                }
                .padding(ClubUI.pageInset).frame(maxWidth: ClubUI.contentWidth).frame(maxWidth: .infinity)
            }
        }
        .onChange(of: account.user?.id) { _, id in if id != ownerID { dismiss() } }
    }
    private func finish() {
        guard account.user?.id == ownerID else { dismiss(); return }
        UserDefaults.standard.set(true, forKey: "firstLaunchPermissions.\(ownerID)")
        dismiss()
    }
}
