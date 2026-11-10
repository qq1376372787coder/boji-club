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
    @State private var showingLaunch = true
    var body: some Scene {
        WindowGroup {
            ZStack {
                RootView().environmentObject(store).environmentObject(ai).environmentObject(account)
                    .environmentObject(health)
                    .environmentObject(weekly)
                    .environmentObject(clubSeason)
                    .environmentObject(membership)
                    .environmentObject(notifications)
                    .environmentObject(automation)
                if showingLaunch {
                    LaunchArtworkView(isPresented: $showingLaunch)
                        .zIndex(10)
                        .transition(.opacity)
                }
            }
            .tint(ClubBrand.accent)
            .environment(\.locale, Locale(identifier: "zh_CN"))
        }
    }
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
            withAnimation(reduceMotion ? nil : .easeOut(duration:0.18)) { isPresented = false }
        }
    }
}

struct RootView: View {
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
    @State private var defaultsSyncTask: Task<Void, Never>?
    @AppStorage("remoteConfig.dismissedVersion") private var dismissedConfigVersion = -1
    var body: some View { foregroundContent }

    @ViewBuilder private var remoteConfigNotice: some View {
        if let config = account.remoteConfig, config.hasNotice, config.version > dismissedConfigVersion {
            RemoteConfigNoticeView(config: config, dismiss: { dismissedConfigVersion = config.version })
        }
    }

    private var accountContent: some View {
        Group {
            if account.pendingDeletionID != nil, account.phase != .signedOut { AccountDeletionStatusView() }
            else { switch account.phase {
            case .checking:
                ZStack { ClubBackground(); VStack { ClubLoadingCard(title: "正在连接薄肌俱乐部…", detail: account.notice ?? "正在恢复你的账号与记录。"); if account.notice != nil { Button("重新连接") { Task { await account.restore() } }.buttonStyle(SecondaryButton()) } }.padding(28).frame(maxWidth: 420) }
            case .signedOut:
                NavigationStack { AccountEntryView().toolbar(.hidden, for: .navigationBar) }
            case .onboarding:
                // Same AI shell, restricted onboarding state. The legacy full
                // questionnaire remains available as an explicit fallback, but
                // is no longer the required five-stage entrance.
                ClubAIShellView().id(account.user?.id)
            case .ready:
                if membership.requiresMembershipPurchase { MembershipGateView() }
                else { mainOrAuditContent }
            } }
        }
    }

    @ViewBuilder private var mainOrAuditContent: some View {
        #if DEBUG
        if let screen = ProcessInfo.processInfo.environment["BOJI_AUDIT_SCREEN"] {
            BojiAuditHost(initialScreen: screen)
        } else { ClubAIShellView().id(account.user?.id) }
        #else
        ClubAIShellView().id(account.user?.id)
        #endif
    }

    private var recoveryContent: some View {
        accountContent
        .safeAreaInset(edge: .top) {
            if account.user != nil, store.localRecovery != nil || !store.photoSyncIssues.isEmpty || store.mediaCleanupNotice != nil {
                BojiStatusBanner(
                    icon: "exclamationmark.triangle.fill",
                    title: store.localRecovery != nil ? "本机记录需要恢复" : store.photoSyncIssues.isEmpty ? "有照片附件待清理" : "记录已保留 · \(store.photoSyncIssues.count) 张照片待处理",
                    detail: "点击查看安全的处理与恢复方式",
                    tint: BojiColor.timerAccent,
                    actionTitle: "处理",
                    action: { showRecordRepair = true }
                )
            }
        }
        .sheet(isPresented: $showRecordRepair) { RecordRepairView() }
        .onChange(of: account.user?.id) { _, _ in showRecordRepair = false }
    }

    private var accountLifecycleContent: some View {
        recoveryContent
        .task { if case .checking = account.phase { await account.restore() } }
        .onReceive(NotificationCenter.default.publisher(for: ASAuthorizationAppleIDProvider.credentialRevokedNotification)) { _ in Task { await account.checkAppleCredential(force: true) } }
        .onChange(of: scenePhase, initial: true) { _, phase in
            weekly.setForeground(phase == .active)
            if phase == .active { Task { await account.checkAppleCredential(); await notifications.refreshAuthorizationStatus(); membership.refresh(force: true) } }
        }
        .onChange(of: account.user?.id, initial: true) { _, id in
            if id == nil, case .checking = account.phase { return }
            notifications.activate(id)
            automation.activate(id)
            ClubPushService.shared.activate(id)
            Task { await FoodCutout.clearCache() }
            clubSeason.activate(id)
            TrainingActivityService.shared.activate(id)
            health.activate(id)
            weekly.activate(id)
            if let id {
                store.activateAccount(id, profile: account.user?.profile)
                ai.activateAccount(id, account: account)
                if let profile = account.user?.profile { store.seedProfile(profile) }
                if !account.isPreviewAccount {
                    store.beginCloudSync(account: account, ai: ai)
                }
            }
            else { store.deactivateAccount(); ai.deactivateAccount() }
            membership.activate(account: account.user, accountService: account)
        }
        .task(id: "\(account.pendingLocalErasureIDs)-\(account.localErasureRetry)") {
            for id in account.pendingLocalErasureIDs {
                let saved = store.eraseAccountData(id)
                let jobs = ai.eraseAccountData(id)
                let reviews = weekly.eraseAccountData(id)
                let devices = health.eraseAccountData(id)
                let keepsakes = await ClubDiskCache.shared.erase(id)
                account.completeLocalErasure(id, success: saved && jobs && reviews && devices && keepsakes)
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
        .sheet(item: Binding(get: { notifications.route?.kind == "training" || store.trainingInterfacePresented ? nil : notifications.route }, set: { notifications.route = $0 })) { route in
            // 每周回顾提醒直接进入专属复盘页（自带导航与“完成”按钮），不再经过对话。
            if route.kind == "weekly_center" || route.kind == "weekly_review" {
                WeeklyReviewCenter().background { ClubBackground() }
            } else {
                NavigationStack {
                    Group {
                        if ["club_weekly","club_workout"].contains(route.kind) {
                            if let id = route.jobID { ClubAutomaticReportReader(jobID: id) }
                            else { ReportLibraryView(initialKind: route.kind == "club_weekly" ? .weekly : .workout) }
                        }
                        else if route.kind == "report" { AIReportHistoryView(dateKey: route.date) }
                        else if route.kind == "task" || route.kind == "task_center" { TaskCenterView() }
                        else if route.kind == "body" { BodyWeightView(initialDate: ClubDates.date(fromKey: route.date) ?? Date()) }
                        else if route.kind == "meal" {
                            if let date = ClubDates.date(fromKey: route.date) { MealEditorView(date: date) }
                            else { EmptyNote(title: "日期不可用", detail: "请从输入框左侧“＋”或侧栏“我的记录 → 饮食”重新打开登记。") }
                        }
                        else { TaskCenterView() }
                    }
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { notifications.route = nil } } }
                }
            }
        }
    }

    private var reminderContent: some View {
        notificationRoutingContent
        .onChange(of: store.trainingScheduleSignature, initial: true) { _, _ in
            notifications.syncTrainingReminders(profile: account.user == nil ? nil : store.state.profile, plannedDays: store.state.days)
            notifications.syncMealReminders(days: store.state.days)
        }
        .onChange(of: notifications.trainingRemindersEnabled) { _, _ in
            notifications.syncTrainingReminders(profile: account.user == nil ? nil : store.state.profile, plannedDays: store.state.days)
        }
        .onChange(of: notifications.timeRevision) { _, _ in
            // A4/A5：提醒时间或餐次设置变化后重排；签名幂等，不会重复添加。
            notifications.syncTrainingReminders(profile: account.user == nil ? nil : store.state.profile, plannedDays: store.state.days)
            notifications.syncMealReminders(days: store.state.days)
        }
        .onChange(of: notifications.mealReminders) { _, _ in
            notifications.syncMealReminders(days: store.state.days)
        }
        .onChange(of: store.mealReminderSignature) { _, _ in
            // 记录/删除餐食后重排：已有记录的餐次不再提醒。
            notifications.syncMealReminders(days: store.state.days)
        }
        .onChange(of: notifications.authorizationStatus) { _, _ in
            notifications.syncTrainingReminders(profile: account.user == nil ? nil : store.state.profile, plannedDays: store.state.days)
            // F11：首次授权后餐次提醒立即生效，不等其他事件触发。
            notifications.syncMealReminders(days: store.state.days)
            Task { await ClubPushService.shared.sync(account: account, ai: ai, notifications: notifications, settings: automation.settings) }
        }
        .onChange(of: account.user?.membership?.active) { _, _ in
            membership.activate(account: account.user, accountService: account)
        }
        .onChange(of: ai.cloudChangeID) { _, _ in store.scheduleCloudSync() }
    }

    private var automationContent: some View {
        reminderContent
        .onReceive(ClubPushService.shared.$token) { _ in
            Task { await ClubPushService.shared.sync(account: account, ai: ai, notifications: notifications, settings: automation.settings) }
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            defaultsSyncTask?.cancel()
            defaultsSyncTask = Task {
                do { try await Task.sleep(for: .milliseconds(1500)) } catch { return }
                guard !Task.isCancelled else { return }
                await automation.syncServer(account: account, ai: ai, store: store)
            }
        }
        .onChange(of: ai.routingConsentGranted) { _, _ in Task {
            await automation.syncServer(account: account, ai: ai, store: store)
            await ClubPushService.shared.sync(account: account, ai: ai, notifications: notifications, settings: automation.settings)
        } }
        .onChange(of: notifications.dailyReportEnabled) { _, _ in Task { await ClubPushService.shared.sync(account: account, ai: ai, notifications: notifications, settings: automation.settings) } }
        .onChange(of: notifications.weeklyReviewEnabled) { _, _ in Task { await ClubPushService.shared.sync(account: account, ai: ai, notifications: notifications, settings: automation.settings) } }
        .onChange(of: automation.settings) { _, _ in
            Task {
                await automation.syncServer(account: account, ai: ai, store: store)
                await ClubPushService.shared.sync(account: account, ai: ai, notifications: notifications, settings: automation.settings)
            }
            if scenePhase == .active { automation.evaluate(store: store, ai: ai, account: account, membership: membership) }
        }
    }

    private var foregroundContent: some View {
        automationContent
        .safeAreaInset(edge: .top, spacing: 0) { remoteConfigNotice }
        .task(id: "\(account.user?.id ?? 0)-\(scenePhase == .active)") {
            guard let userID = account.user?.id, scenePhase == .active else { return }
            await account.loadRemoteConfig()
            while !Task.isCancelled {
                await account.refreshAccount()
                guard !Task.isCancelled, account.user?.id == userID else { return }
                store.extendWeeklyPlans130()
                notifications.syncTrainingReminders(profile: store.state.profile, plannedDays: store.state.days)
                store.publishWidgetSnapshot()
                await store.syncNow()
                guard !Task.isCancelled, account.user?.id == userID else { return }
                weekly.reconcileCloudReviews(store: store)
                await ClubPushService.shared.sync(account: account, ai: ai, notifications: notifications, settings: automation.settings)
                await ai.recoverTasks(account: account, weekly: weekly, store: store)
                guard !Task.isCancelled, account.user?.id == userID, scenePhase == .active else { return }
                await automation.syncServer(account: account, ai: ai, store: store)
                automation.evaluate(store: store, ai: ai, account: account, membership: membership)
                do { try await Task.sleep(for: .seconds(120)) } catch { return }
            }
        }
    }
}

private struct RemoteConfigNoticeView: View {
    let config: ClubRemoteConfig
    let dismiss: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: config.requiresUpdateNotice ? "arrow.down.circle.fill" : "megaphone.fill")
                .foregroundStyle(ClubBrand.accent)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(config.config.announcement.enabled ? config.config.announcement.title : "版本更新提示")
                    .font(.system(size: 13, weight: .semibold))
                if config.config.announcement.enabled {
                    Text(config.config.announcement.body)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if config.requiresUpdateNotice {
                    Text("当前构建号 \(ClubRemoteConfig.currentBuild())，请更新至 \(config.config.minimumBuild) 或以上以获得完整修复。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 6)
            Button("收起提示", action: dismiss)
                .font(.system(size: 12, weight: .semibold))
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct AccountDeletionStatusView: View {
    @EnvironmentObject private var account: AccountService
    @State private var checking = false
    @State private var nonce = ""
    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "person.crop.circle.badge.clock").font(.largeTitle)
            Text("正在确认注销申请").bojiFont(.pageTitle).foregroundStyle(BojiColor.textPrimary)
            Text(account.notice ?? "请保持网络连接。确认申请已受理后，会清除本机记录并退出账号。").foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button(checking ? "检查中…" : "检查注销状态") {
                checking = true
                Task { await account.restore(); checking = false }
            }.buttonStyle(PrimaryButton()).disabled(checking)
            Button("稍后检查，返回登录") { account.returnToSignInForUnconfirmedDeletion() }
                .buttonStyle(SecondaryButton()).disabled(checking)
            Text("注销申请状态会保留；重新使用申请时的 Apple 账号登录，可继续核对，不会重复提交。").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
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
        }.padding(28)
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
                VStack(alignment: .leading, spacing: 28) {
                    FlowHeading(eyebrow: "首次设置", title: "开启提醒与健康同步", subtitle: "随时可以在「设置」里更改；也可以先跳过，不影响记录。")
                    ClubCard {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "bell.badge").font(.title2).foregroundStyle(ClubBrand.accent)
                            VStack(alignment: .leading, spacing: 6) {
                                Text("训练与餐次提醒").font(.headline)
                                Text("完成后提醒你训练、同步每周复盘。").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Button(notificationsAuthorized ? "已开启" : "打开通知") {
                            Task { await notifications.requestAuthorization() }
                        }
                        .buttonStyle(SecondaryButton())
                        .disabled(notificationsAuthorized)
                    }
                    ClubCard {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "heart.text.square").font(.title2).foregroundStyle(ClubBrand.accent)
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Apple 健康").font(.headline)
                                Text(health.enabled ? "已完成连接设置；只显示系统实际可读取的数据。" : "按你的选择读取步数和设备训练；训练写入需另行开启。").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Button("连接 Apple 健康") {
                            Task { await health.connect() }
                        }
                        .buttonStyle(SecondaryButton()).disabled(health.busy)
                        Button(health.writeWorkoutsEnabled ? "已开启训练写入" : "允许同步已确认训练") {
                            Task { await health.setWorkoutWritingEnabled(true) }
                        }.buttonStyle(SecondaryButton()).disabled(health.busy || health.writeWorkoutsEnabled)
                        if let message = health.message { Text(message).font(.footnote).foregroundStyle(.secondary) }
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
