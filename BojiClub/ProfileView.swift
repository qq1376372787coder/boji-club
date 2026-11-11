import SwiftUI
import UniformTypeIdentifiers
import PhotosUI
import UIKit

private struct CloudPhotoUsage: Decodable {
    let photo_bytes: Int64
    let photo_files: Int
    let photo_limit_bytes: Int64
    let photo_limit_files: Int
}

struct CloudStorageUsageView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var account: AccountService
    @EnvironmentObject private var store: AppStore
    @State private var usage: CloudPhotoUsage?
    @State private var loading = false
    @State private var problem: String?

    var body: some View {
        ClubNavigationStack132 {
            List {
                    ClubCard {
                        SectionTitle(title: "云端照片", symbol: "photo.on.rectangle")
                        if let usage { usageContent(usage) }
                        else if loading { ProgressView("正在读取照片用量…") }
                        if let problem { Text(problem).font(.subheadline).foregroundStyle(.secondary) }
                        Button("刷新用量") { Task { await refresh() } }.buttonStyle(SecondaryButton()).disabled(loading)
                    }
                    ClubCard {
                        SectionTitle(title: "记录同步", symbol: "icloud")
                        Text(store.syncStatus.label).font(.body)
                        if let message = store.mediaSyncMessage { Text(message).font(.subheadline).foregroundStyle(.secondary) }
                        Text("训练、饮食与分析记录支持增量同步与云端备份。").font(.subheadline).foregroundStyle(.secondary)
                        Button("立即同步") { Task { await store.syncNow() } }.buttonStyle(SecondaryButton())
                    }
                    Section {
                        NavigationLink { ClubActionPreferencesView(pendingOnly132: true).clubPushDestination132() } label: { Text("待同步项目") }
                        NavigationLink { RecordArchiveView().clubPushDestination132() } label: { Text("导出与备份") }
                        NavigationLink { RecordRepairView().clubPushDestination132() } label: { Text("导入与修复记录") }
                    }
                    Text("离线或上传失败时，原记录和照片仍保留在手机。调整空间额度不会删除已上传内容；需要另存记录时，可返回“导出与备份”。").font(.subheadline).foregroundStyle(.secondary)

        }.clubManagementList132()
            .navigationTitle("云端照片与同步")
            .toolbar { ToolbarItem(placement: .confirmationAction) { DismissButton() } }
            .task { await refresh() }
        }
    }
    private func usageContent(_ usage: CloudPhotoUsage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("已上传 \(usage.photo_files) 张 · \(Double(usage.photo_bytes) / 1048576, specifier: "%.1f") MB").bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
            Text(usage.photo_limit_bytes == 0 ? "照片空间：不设账号总量上限" : "照片空间：\((Double(usage.photo_limit_bytes) / 1048576).formatted(.number.precision(.fractionLength(0)))) MB").font(.subheadline)
            Text(usage.photo_limit_files == 0 ? "照片数量：不设账号总量上限" : "照片数量：最多 \(usage.photo_limit_files) 张").font(.subheadline)
            if usage.photo_limit_bytes > 0 {
                ProgressView(value: min(1, Double(usage.photo_bytes) / Double(usage.photo_limit_bytes)))
            }
            Text("服务器仍有实际磁盘容量；单张云端JPEG附件最多4MB，必要时App会压缩后上传。").font(.caption).foregroundStyle(.secondary)
        }
    }
    @MainActor private func refresh() async {
        guard !loading, let id = account.user?.id else { return }
        loading = true; problem = nil
        defer { loading = false }
        do {
            let response = try await account.cloudRequest(path: "/me/storage", expectedUserID: id)
            guard response.statusCode == 200 else { throw CloudSyncError.message("照片用量暂时无法读取，请稍后刷新。") }
            usage = try JSONDecoder().decode(CloudPhotoUsage.self, from: response.data)
        } catch is CancellationError { }
        catch { problem = AppErrorText.message(error) }
    }
}

struct ProfileView: View {
    var recordAccessOnly = false
    @Binding var routeToKeepsakeVault: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var account: AccountService
    @EnvironmentObject private var clubSeason: ClubSeasonService
    @State private var showProfile = false
    @State private var showIdentity = false
    @State private var showMembership = false
    @State private var showHealth = false
    @State private var showArchive = false
    @State private var showStorage = false
    @State private var showNotifications = false
    @State private var selectedKeepsake: ClubCollectedReward?
    @State private var showKeepsakeVault = false
    @State private var showGuide = false
    @State private var showActionSettings = false
    @State private var showReportLibrary = false
    @State private var accountExpanded = false
    @State private var showClubAISettings = false
    @State private var showAbout = false
    @State private var showFeedback128 = false
    @State private var legalDocument: LegalDocument?
    @State private var showDeleteConfirmation = false
    @State private var deletingAccount = false
    @State private var deleteError: String?
    @State private var showPlanList = false
    @State private var showSettings = false
    @State private var showLogoutConfirm = false
    @State private var loggingOut = false
    @State private var logoutTarget: Int?

    init(recordAccessOnly: Bool = false, routeToKeepsakeVault: Binding<Bool> = .constant(false)) {
        self.recordAccessOnly = recordAccessOnly
        self._routeToKeepsakeVault = routeToKeepsakeVault
    }
    private var statisticsLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
    }
    private var monthLogs: [DayLog] {
        let prefix = String(ClubDates.key(Date()).prefix(7))
        return store.state.days.filter { $0.key.hasPrefix(prefix) }.map(\.value)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 16) {
                    profileHeader
                    BojiGlassCard(radius: BojiV2.glassCardRadius, padding: BojiV2.glassPadding) {
                        BojiStatStrip(items: profileStats)
                    }
                    VStack(spacing: 10) {
                        BojiItemRow(title: "我的计划", systemImage: "calendar", showsChevron: true,
                                    action: { showPlanList = true }).bojiStagger(index: 0)
                        BojiItemRow(title: "会员与订阅", systemImage: "crown", showsChevron: true,
                                    action: { showMembership = true }).bojiStagger(index: 1)
                        BojiItemRow(title: "通知与提醒", systemImage: "bell", showsChevron: true,
                                    action: { showNotifications = true }).bojiStagger(index: 2)
                        BojiItemRow(title: "设置", systemImage: "gearshape", showsChevron: true,
                                    action: { showSettings = true }).bojiStagger(index: 3)
                    }
                    if recordAccessOnly {
                        BojiItemRow(title: "历史报告", systemImage: "doc.text", showsChevron: true,
                                    action: { showReportLibrary = true })
                    }
                }
                .padding(.horizontal, BojiV2.cardInset)
                .padding(.top, 12)
                .padding(.bottom, 16)
            }
            logoutDock
        }
        .background { ClubBackground() }
        .navigationTitle("我的").navigationBarTitleDisplayMode(.inline)

        .task(id: account.user?.id) { await store.syncNow(); await clubSeason.refreshCollection(account: account) }
        .onChange(of: routeToKeepsakeVault, initial: true) { _, shouldOpen in
            guard shouldOpen else { return }
            showKeepsakeVault = true
            routeToKeepsakeVault = false
        }
        .sheet(isPresented: $showActionSettings) { ClubActionPreferencesView() }
        .sheet(isPresented: $showClubAISettings) { ClubAISettingsView() }
        .sheet(isPresented: $showFeedback128) { ClubNavigationStack132 { MemberFeedbackHub128().toolbar { ToolbarItem(placement:.confirmationAction) { Button("关闭") { showFeedback128 = false } } } } }
        .sheet(isPresented: $showAbout) { ClubNavigationStack132 { BojiAboutView().toolbar { ToolbarItem(placement:.confirmationAction) { Button("完成") { showAbout = false } } } } }
        .sheet(isPresented: $showMembership) { MembershipView() }
        .sheet(isPresented: $showPlanList) {
            ClubNavigationStack132 { ManagedPlanList(focusDate: Date(), initialCycleStart: nil).clubPushDestination132() }
        }
        .sheet(isPresented: $showSettings) {
            ClubNavigationStack132 { SettingsHub130() }
        }
        .sheet(isPresented: $showHealth) {
            HealthConnectionsView(date: Date())
        }
        .sheet(isPresented: $showIdentity) { MemberIdentityEditor() }
        .sheet(isPresented: $showArchive) { RecordArchiveView(allowImport: !recordAccessOnly) }
        .sheet(isPresented: $showStorage) { CloudStorageUsageView() }
        .sheet(isPresented: $showNotifications) { NotificationSettingsView() }
        .sheet(item: $legalDocument) { document in LegalDocumentView(document: document) }
        .sheet(isPresented: $showGuide) { ClubUsageGuideView(firstVisitAccountID:account.user?.id) }
        .sheet(isPresented: $showReportLibrary) {
            ClubNavigationStack132 {
                ReportLibraryView()
                    .toolbar { ToolbarItem(placement: .cancellationAction) { DismissButton() } }
            }
        }
        .sheet(isPresented: $showKeepsakeVault) { ClubKeepsakeVaultView() }
        .sheet(item: $selectedKeepsake) { reward in
                ClubKeepsakeDetailView(
                    title: reward.title,
                    detail: reward.detail ?? "这是在成长季中完成真实记录后获得的 俱乐部奖励。",
                    icon: reward.icon,
                    rewardType: reward.rewardType, rewardID: reward.id, imagePath: reward.imagePath, revision: reward.artworkRevision, canShare: true
                )
        }
        .alert("确认注销账号？", isPresented: $showDeleteConfirmation) {
            Button("注销账号", role: .destructive) { deleteAccount() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("确认后账号立即停用，本机记录清除；服务器在后台删除资料、照片和 AI 记录，清理失败会继续重试。\n\n此操作无法恢复。\n尚未结束的礼品申领需先处理；Apple 自动续订需到系统订阅设置中取消。")
        }
        .alert("暂时无法注销", isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })) {
            Button("知道了") { deleteError = nil }
        } message: { Text(deleteError ?? "") }
    }

    /// §10.8：居中 88pt 头像 + 名字 + 副标题。名字用 .title2（22pt）而不是固定 24pt，
    /// 理由是系统没有 24pt 的 text style，固定磅值会被无障碍审计判为「无法改变字号」。
    private var profileHeader: some View {
        VStack(spacing: 10) {
            Button { showIdentity = true } label: {
                ClubAvatarView(profile: store.state.profile, size: 88)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("编辑头像与昵称")
            .bojiHeroEntrance()
            Text(store.state.profile.nickname.isEmpty ? "薄肌成员" : store.state.profile.nickname)
                .font(.system(.title2, design: .default, weight: .semibold))
                .foregroundStyle(BojiV2.textPrimary)
            Text(profileSubtitle).font(BojiV2.caption).foregroundStyle(BojiV2.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var profileSubtitle: String {
        var parts: [String] = []
        if let cycle = currentCycle, let start = ClubDates.date(fromKey: cycle.start) {
            let elapsed = ClubDates.calendar.dateComponents([.day], from: start, to: Date()).day ?? 0
            parts.append("第 \(max(1, elapsed / 7 + 1)) 周")
        }
        if trainingDayStreak > 0 { parts.append("连续 \(trainingDayStreak) 天") }
        return parts.isEmpty ? "薄肌俱乐部成员" : parts.joined(separator: " · ")
    }

    private var profileStats: [BojiStatStrip.Item] {
        [
            BojiStatStrip.Item(value: "\(trainingDayStreak)", label: "连续天"),
            BojiStatStrip.Item(value: "\(totalTrainingDays)", label: "累计训练"),
            // membership 挂在 ClubAccount 上，不在 AccountService 上。
            BojiStatStrip.Item(value: account.user?.membership?.active == true ? "Pro" : "免费", label: "会员", isNumeric: false)
        ]
    }

    /// 连续训练天数：今天没练不算中断，从昨天继续往回数。
    private var trainingDayStreak: Int {
        let calendar = ClubDates.calendar
        var cursor = calendar.startOfDay(for: Date())
        if !(store.log(for: cursor).confirmedTraining.hasTraining),
           let previous = calendar.date(byAdding: .day, value: -1, to: cursor) {
            cursor = previous
        }
        var count = 0
        while store.log(for: cursor).confirmedTraining.hasTraining {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return count
    }

    private var totalTrainingDays: Int {
        store.state.days.values.filter { $0.confirmedTraining.hasTraining }.count
    }

    private var currentCycle: TrainingCycle? {
        let today = ClubDates.key(Date())
        let cycles = TrainingCycle.available(days: store.state.days)
        return cycles.first { $0.dates.contains(today) && $0.end >= today }
            ?? cycles.filter { $0.start > today }.min { $0.start < $1.start }
    }

    /// 固定 Ghost「退出登录」贴 Tab 上方（§10.8，h 50）。
    private var logoutDock: some View {
        Button("退出登录") {
            guard let id = account.user?.id else { return }
            logoutTarget = id
            showLogoutConfirm = true
        }
        .buttonStyle(BojiGhostButtonStyle())
        .disabled(loggingOut || account.user == nil)
        .padding(.horizontal, BojiV2.cardInset)
        .padding(.bottom, 10)
        .confirmationDialog("退出当前账号？", isPresented: $showLogoutConfirm, titleVisibility: .visible) {
            Button("退出登录", role: .destructive) {
                guard !loggingOut, let id = logoutTarget, id == account.user?.id else { return }
                loggingOut = true
                Task { await account.logout(); loggingOut = false }
            }
            Button("继续使用", role: .cancel) { }
        } message: {
            Text("当前同步状态：\(store.syncStatus.label)。记录会保留在本机，重新登录同一账号后可以继续同步；退出登录不会注销账号。")
        }
    }

    private var keepsakeHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                SectionTitle(title: "我的 俱乐部奖励", symbol: "seal.fill")
                Spacer(minLength: 8)
                keepsakeCollectionButton
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(title: "我的 俱乐部奖励", symbol: "seal.fill")
                keepsakeCollectionButton
            }
        }
    }

    private var keepsakeCollectionButton: some View {
        Button { showKeepsakeVault = true } label: {
            Label("收藏与奖品", systemImage: "chevron.right").font(.subheadline)
        }.buttonStyle(ClubActionButtonStyle(kind: .row))
    }

    private func profileButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { ClubProfileEntryLabel131(title: title, symbol: symbol) }.buttonStyle(.plain)
    }

    private var syncSymbol: String {
        switch store.syncStatus {
        case .synced: return "checkmark.icloud"
        case .syncing: return "arrow.triangle.2.circlepath.icloud"
        case .waiting, .waitingService, .failed: return "icloud.slash"
        case .idle, .pending: return "icloud"
        }
    }

    private func deleteAccount() {
        Task {
            deletingAccount = true
            defer { deletingAccount = false }
            do {
                _ = try await account.deleteAccount()
                clubSeason.clear()
            } catch {
                deleteError = AppErrorText.message(error)
            }
        }
    }
}

struct MembershipGateView: View {
    @State private var showingPlans = false
    @State private var showingAccount = false
    @State private var showingTasks = false
    var body: some View {
        Group {
            if showingPlans { MembershipView(isMandatory: true) }
            else { MembershipPreviewView { showingPlans = true } }
        }
        .safeAreaInset(edge: .bottom) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { accountAccessActions }
                VStack(alignment: .leading, spacing: 12) { accountAccessActions }
            }.frame(maxWidth: .infinity).padding(ClubUI.pageInset).background(.regularMaterial)
        }
        .sheet(isPresented: $showingTasks) {
            ClubNavigationStack132 {
                TaskCenterView()
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { showingTasks = false } } }
            }
        }
        .sheet(isPresented: $showingAccount) {
            ClubNavigationStack132 {
                VStack(spacing: 0) {
                    HStack(alignment: .top, spacing: 12) {
                        Text("已有记录可查看和导出；新增训练、饮食与 AI 功能需要有效会员。").font(.footnote)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("关闭") { showingAccount = false }.buttonStyle(SecondaryButton())
                    }.padding(ClubUI.pageInset)
                    List {
                        NavigationLink("查看已有训练与饮食") { MembershipRecordHistoryView() }
                        NavigationLink("查看历史分析与报告") { ReportLibraryView() }
                        NavigationLink("管理账号与查看历史报告") { ProfileView(recordAccessOnly: true) }
                    }.clubListSurface()
                    .navigationTitle("已有记录与账号").navigationBarTitleDisplayMode(.inline)
                }
            }
        }
    }
    @ViewBuilder private var accountAccessActions: some View {
        Button("返回原任务与草稿") { showingTasks = true }.buttonStyle(SecondaryButton())
        Button("查看已有记录与管理账号") { showingAccount = true }.buttonStyle(SecondaryButton())
        ClubLogoutButton()
    }
}

private struct MembershipPreviewView: View {
    let continueAction: () -> Void
    @EnvironmentObject private var store: AppStore
    private var upcomingPlanDates: [String] {
        let today = ClubDates.key(Date())
        return Array(store.state.days.keys.filter { key in
            key >= today && !(store.state.days[key]?.exercises.isEmpty ?? true)
        }.sorted().prefix(7))
    }
    private var firstPlanDateLabel: String {
        guard let first = upcomingPlanDates.first, let date = ClubDates.date(fromKey: first) else { return "待定" }
        return ClubDates.label(date)
    }

    var body: some View {
        ClubNavigationStack132 {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack {
                        VStack(alignment: .leading, spacing: 8) {
                            BojiBrandSignature(size:28)
                            Text("认真训练，认真记录。").bojiFont(.pageTitle).foregroundStyle(BojiColor.textPrimary)
                        }
                        Spacer()
                        Image(systemName: "dumbbell.fill").font(.largeTitle)
                    }
                    Text("薄肌俱乐部把训练、饮食、身体数据和 AI 复盘放进同一条成长路径。")
                        .bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary).foregroundStyle(.secondary)

                    if !upcomingPlanDates.isEmpty {
                        ClubCard {
                            SectionTitle(title: "你的训练安排已保存", symbol: "calendar.badge.checkmark")
                            Text("接下来已安排 \(upcomingPlanDates.count) 个训练日，首个训练日是 \(firstPlanDateLabel)。")
                                .font(.subheadline)
                            Text("开通会员后即可按这份安排开始记录，计划不会因为暂时离开付费页而丢失。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    ClubCard {
                        SectionTitle(title: "产品预览", symbol: "sparkles")
                        previewRow("专属训练计划", "按目标、经验和训练条件编排第一周")
                        Divider()
                        previewRow("每日营养目标", "记录热量和蛋白质，不规定你必须吃什么")
                        Divider()
                        previewRow("每日复盘", "完成训练和饮食后，回看今天发生了什么")
                        Divider()
                        previewRow("每周回顾", "观察 7 天趋势，决定是否调整下周计划")
                    }

                    ClubCard {
                        SectionTitle(title: "你会得到", symbol: "checkmark.seal")
                        Label("训练计划与逐组记录", systemImage: "dumbbell").font(.subheadline)
                        Label("拍照记饮食与营养目标", systemImage: "camera").font(.subheadline)
                        Label("Apple 健康数据", systemImage: "heart").font(.subheadline)
                        Label("每日复盘与综合回顾", systemImage: "chart.bar").font(.subheadline)
                    }

                    Button("查看会员方案") { continueAction() }
                        .buttonStyle(PrimaryButton())
                    Text("开通会员后，可制定训练计划、记录饮食并使用 AI 回顾。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(ClubUI.pageInset)
            }
            .background { ClubBackground() }
        }
    }

    private func previewRow(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct NotificationSettingsView: View {
    @EnvironmentObject private var notifications: AppNotificationService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ClubNavigationStack132 {
            Form {
                Section("系统通知") {
                    LabeledContent("通知权限", value: notifications.authorizationStatus == .authorized ? "已开启" : (notifications.authorizationStatus == .denied ? "已关闭" : "未设置"))
                    if notifications.authorizationStatus == .denied {
                        Button("前往设置，开启提醒") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }.buttonStyle(ClubActionButtonStyle(kind: .row))
                    } else {
                        Button("允许发送提醒") { Task { await notifications.requestAuthorization() } }.buttonStyle(ClubActionButtonStyle(kind: .row))
                            .disabled(notifications.authorizationStatus == .authorized)
                    }
                }
                Section("训练安排提醒") {
                    Toggle("训练日提醒", isOn: $notifications.trainingRemindersEnabled)
                    if notifications.trainingRemindersEnabled {
                        DatePicker("提醒时间", selection: trainingTime, displayedComponents: .hourAndMinute)
                    }
                }
                Section("餐次登记提醒") {
                    Text("提醒补充未记录的餐次；有记录后不再提醒。").font(.caption).foregroundStyle(.secondary)
                    MealReminderSlotEditor(slot: $notifications.mealReminders.breakfast)
                    MealReminderSlotEditor(slot: $notifications.mealReminders.lunch)
                    MealReminderSlotEditor(slot: $notifications.mealReminders.dinner)
                }
                Section("AI 总结提醒") {
                    Toggle("日总结完成", isOn: $notifications.dailyReportEnabled)
                    Toggle("周总结完成", isOn: $notifications.weeklyReviewEnabled)
                }
                Section {
                    Text("本页管理本机提醒时间；关掉通知不影响日常记录与手动分析。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.clubManagementList132().clubGroupedSurface()
            .navigationTitle("通知与提醒")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { DismissButton() } }
        }
    }

    /// 训练提醒时间（时/分）与 Date 的双向转换。
    private var trainingTime: Binding<Date> {
        Binding(
            get: {
                var comps = DateComponents(); comps.hour = notifications.trainingReminderHour; comps.minute = notifications.trainingReminderMinute
                return Calendar.current.date(bySettingHour: comps.hour ?? 19, minute: comps.minute ?? 30, second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
                notifications.trainingReminderHour = comps.hour ?? 19
                notifications.trainingReminderMinute = comps.minute ?? 30
            }
        )
    }
}

/// 单个餐次提醒：开关＋时间。
private struct MealReminderSlotEditor: View {
    @Binding var slot: MealReminderSettings.Slot
    var body: some View {
        Toggle("\(slot.category)提醒", isOn: $slot.enabled)
        if slot.enabled {
            DatePicker("提醒时间", selection: Binding(
                get: {
                    Calendar.current.date(bySettingHour: slot.hour, minute: slot.minute, second: 0, of: Date()) ?? Date()
                },
                set: { date in
                    let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
                    slot.hour = comps.hour ?? 8; slot.minute = comps.minute ?? 0
                }), displayedComponents: .hourAndMinute)
        }
    }
}

struct ProfileEditor: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var allowPlanUpdate = true
    var section: ProfileEditSection126? = nil
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var account: AccountService
    @Environment(\.dismiss) private var dismiss
    @State private var profile = MemberProfile()
    @StateObject private var v2Editor = ProfileFactsEditor()
    @State private var loadingFacts = false
    @State private var saving = false
    @State private var saveError: String?
    @State private var editingAccountID: Int?
    @State private var loaded = false
    @State private var originalProfile = MemberProfile()
    @State private var planChoice = "保留"
    @State private var showUpdatedPlan = false
    @State private var planStart = Date()
    @State private var saveMessage: String?
    @State private var confirmSave = false
    @State private var confirmLeave = false
    @State private var showValidation = false
    private var needsFactReview: Bool {
        profile.factState != nil && !profile.hasConfirmedBasics
    }
    private var validationIssues: [(id:String,text:String)] {
        var issues: [(String,String)] = []
        let nickname=profile.nickname.trimmingCharacters(in:.whitespacesAndNewlines)
        if nickname.isEmpty || nickname.count > 40 { issues.append(("basics","请填写 1–40 字昵称。")) }
        if (profile.factState == nil || profile.isFactConfirmed("height_cm") || profile.height != originalProfile.height) && (!profile.height.isFinite || !(50...250).contains(profile.height)) { issues.append(("basics","身高需要在 50–250 cm 之间。")) }
        if (profile.factState == nil || profile.isFactConfirmed("profile_weight_kg") || profile.weight != originalProfile.weight) && (!profile.weight.isFinite || !(20...400).contains(profile.weight)) { issues.append(("basics","体重需要在 20–400 kg 之间。")) }
        if let target = profile.targetWeightKg, (!target.isFinite || !(20...400).contains(target)) { issues.append(("basics","目标体重需要在 20–400 kg 之间，或留空。")) }
        if profile.factState == nil || profile.hasConfirmedBasics,
           !["男","女"].contains(profile.gender ?? "") { issues.append(("basics","请选择性别，用于估算营养目标。")) }
        if (profile.factState == nil || profile.isFactConfirmed("training_days") || profile.trainingDays != originalProfile.trainingDays) && (profile.trainingDays ?? []).isEmpty { issues.append(("training","请至少选择一个训练日。")) }
        if profile.venue != "健身房" && (profile.factState == nil || profile.isFactConfirmed("venue") || profile.venue != originalProfile.venue) {
            if equipmentSelection.isEmpty { issues.append(("equipment","请选择居家器械；没有器械可选“徒手”。")) }
            if equipmentSelection.contains("其他") && (profile.equipmentOther ?? "").trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { issues.append(("equipment","选择了其他器械，请补填名称。")) }
        }
        return issues
    }
    private var newTarget: NutritionTarget { NutritionTarget.estimate(profile) }
    private var originalTarget: NutritionTarget { store.state.nutritionTarget ?? NutritionTarget.estimate(originalProfile) }
    private var trainingChanged: Bool {
        var before = originalProfile.aiProfile; var after = profile.aiProfile
        before.dailyActivity = nil; after.dailyActivity = nil
        before.nutritionContext = before.nutritionContext ?? "普通成人"
        after.nutritionContext = after.nutritionContext ?? "普通成人"
        return before != after
    }
    var body: some View {
        ClubNavigationStack132 {
            ScrollViewReader { proxy in
            Form {
                if needsFactReview {
                    Section {
                        Text("基本身体资料尚未确认。页面中的年龄、身高、体重示例值不会作为事实提交；请通过“记录身体数字”或新手资料卡明确填写。只修改目标或训练条件也可以保存。")
                            .font(.footnote)
                    }
                }
                if section != .training {
                Section("基础资料") {
                    TextField("昵称", text: $profile.nickname)
                    Stepper("年龄：\(profile.age) 岁", value: $profile.age, in: 13...100)
                    HStack { Text("身高 cm"); Spacer(); TextField("身高", value: $profile.height, format: .number).keyboardType(.decimalPad).multilineTextAlignment(.trailing) }
                    HStack { Text("体重 kg（资料）"); Spacer(); TextField("体重", value: $profile.weight, format: .number).keyboardType(.decimalPad).multilineTextAlignment(.trailing) }
                    HStack {
                        Text("目标体重 kg（可选）")
                        Spacer()
                        TextField("未设置", value: $profile.targetWeightKg, format: .number.precision(.fractionLength(0...1)))
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    }
                    Text("修改目标体重不会影响历史实测记录。")
                        .font(.caption).foregroundStyle(.secondary)
                    Picker("性别", selection: Binding(get: { profile.gender ?? v2Editor.facts?.facts["sex_for_nutrition"]?.value.string ?? "" }, set: { profile.gender = $0 })) {
                        Text("请选择").tag("")
                        Text("男").tag("男")
                        Text("女").tag("女")
                        Text("不愿提供").tag("不愿提供")
                    }
                    if showValidation { ForEach(Array(validationIssues.filter{$0.id == "basics"}.enumerated()),id:\.offset) { _, issue in Text(issue.text).font(.caption).foregroundStyle(.red) } }
                }.id("basics")
                Section("身体参考与日常活动") {
                    BodyAssessmentCard(profile: profile)
                    ActivityProfileFields(profile: $profile)
                }
                }
                if section != .body {
                Section("训练偏好") {
                    Picker("目标", selection: $profile.goal) { ForEach(["增肌塑形", "减脂瘦身", "紧致线条", "提升力量", "养成运动习惯"], id: \.self) { Text($0).tag($0) } }
                    Picker("经验", selection: $profile.experience) { ForEach(["新手", "有基础", "进阶"], id: \.self) { Text($0).tag($0) } }
                    Picker("场地", selection: $profile.venue) { ForEach(["健身房", "在家", "两者都有"], id: \.self) { Text($0).tag($0) } }
                    Text("每周 \(profile.daysPerWeek) 天，请选择具体训练日")
                    ForEach(1...7, id: \.self) { day in
                        Toggle("周\(["一", "二", "三", "四", "五", "六", "日"][day - 1])", isOn: Binding(
                            get: { (profile.trainingDays ?? []).contains(day) },
                            set: { enabled in
                                var days = profile.trainingDays ?? []
                                if enabled { if !days.contains(day) { days.append(day) } }
                                else { days.removeAll { $0 == day } }
                                profile.trainingDays = days.sorted(); profile.daysPerWeek = days.count
                                profile.homeTrainingDays = (profile.homeTrainingDays ?? []).filter { days.contains($0) }
                            }
                        ))
                    }
                    Stepper("每次 \(profile.sessionMinutes ?? 45) 分钟", value: Binding(get: { profile.sessionMinutes ?? 45 }, set: { profile.sessionMinutes = $0 }), in: 15...180, step: 5)
                    TextField("疼痛、受伤或需要避开的动作", text: Binding(get: { profile.limitations ?? "" }, set: { profile.limitations = $0 }), axis: .vertical)
                    TextField("重点训练部位", text: $profile.focus)
                    if showValidation { ForEach(Array(validationIssues.filter{$0.id == "training"}.enumerated()),id:\.offset) { _, issue in Text(issue.text).font(.caption).foregroundStyle(.red) } }
                }.id("training")
                if profile.venue != "健身房" {
                    Section("居家可用器械") {
                        ForEach(["徒手", "哑铃", "弹力带", "壶铃", "引体向上杆", "瑜伽垫", "小杠铃", "卧推凳", "有氧器械", "其他"], id: \.self) { item in
                            Toggle(item, isOn: Binding(
                                get: { equipmentSelection.contains(item) },
                                set: { _ in toggleEquipment(item) }
                            ))
                        }
                        if equipmentSelection.contains("其他") {
                            TextField("其他器械名称", text: Binding(
                                get: { profile.equipmentOther ?? "" },
                                set: { profile.equipmentOther = $0 }
                            ))
                        }
                        if showValidation { ForEach(Array(validationIssues.filter{$0.id == "equipment"}.enumerated()),id:\.offset) { _, issue in Text(issue.text).font(.caption).foregroundStyle(.red) } }
                    }.id("equipment")
                }
                if profile.venue == "两者都有" {
                    Section {
                        ForEach(1...7, id: \.self) { day in
                            Toggle("周\(["一", "二", "三", "四", "五", "六", "日"][day - 1])在家训练", isOn: Binding(
                                get: { (profile.homeTrainingDays ?? []).contains(day) },
                                set: { enabled in
                                    var days = profile.homeTrainingDays ?? []
                                    if enabled && (profile.trainingDays ?? []).contains(day) { days.append(day) }
                                    else { days.removeAll { $0 == day } }
                                    profile.homeTrainingDays = days.sorted()
                                }
                            ))
                            .disabled(!(profile.trainingDays ?? []).contains(day))
                        }
                        Button("不固定训练地点") { profile.homeTrainingDays = [] }.buttonStyle(ClubActionButtonStyle(kind: .row))
                    } header: { Text("在家训练日") } footer: { Text("不固定居家日期时，按所选训练日顺序交替安排健身房和居家，从健身房开始；每次地点会在计划中标明。") }
                }
                }
                Section("保存后会有什么变化") {
                    LabeledContent("每周训练", value: "\(originalProfile.daysPerWeek) 天 → \(profile.daysPerWeek) 天")
                    LabeledContent("目标", value: profile.goal)
                    if newTarget.generalGuidanceOnly != true {
                    Text("热量：\(Int(originalTarget.caloriesMin))–\(Int(originalTarget.caloriesMax)) → \(Int(newTarget.caloriesMin))–\(Int(newTarget.caloriesMax)) kcal / 天")
                    Text("蛋白质：\(Int(originalTarget.proteinMin))–\(Int(originalTarget.proteinMax)) → \(Int(newTarget.proteinMin))–\(Int(newTarget.proteinMax)) g / 天")
                    } else { Text(newTarget.note).font(.footnote) }
                    Text("资料和营养目标保存后立即生效。历史记录保留原目标，已完成训练不会被改写。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if trainingChanged && allowPlanUpdate && store.currentPlanUsesAI {
                    Section("接下来一周的训练") {
                        Picker("更新安排", selection: $planChoice) {
                            Text("保留现有计划").tag("保留")
                            Text("我想用 AI 从明天重新安排").tag("明天")
                            Text("我想用 AI 从下周一重新安排").tag("下周")
                        }
                        Text("保存资料后预览新方案，确认后才更新所选 7 天。已开始或已确认的训练日完整保留；其余日期按新训练日安排，旧的休息日安排也会一并清理。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if trainingChanged && allowPlanUpdate && !store.currentPlanUsesAI {
                    Section("现有训练安排") {
                        Text("保存资料会保留你的计划。你可以稍后在计划页手动调整日期、动作和组次。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                if let saveError { Section { Text(saveError).foregroundStyle(.red) } }
            }.clubManagementList132().clubGroupedSurface()
            .disabled(saving || loadingFacts)
            .navigationTitle(section?.title ?? "编辑资料与目标").navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(saving || (loaded && profile != originalProfile))
            .onAppear {
                guard !loaded else { return }
                loaded = true; editingAccountID = store.editingAccountID
                profile = store.state.profile
                profile.goal = ["增肌":"增肌塑形", "减脂":"减脂瘦身", "保持健康":"养成运动习惯"][profile.goal] ?? profile.goal
                if section != .body { normalizeTrainingDays() }
                originalProfile = profile
                if profile.factState != nil {
                    loadingFacts=true
                    Task { @MainActor in
                        defer { loadingFacts=false }
                        await v2Editor.load(account:account)
                        guard editingAccountID==store.editingAccountID,let doc=v2Editor.facts else { saveError=v2Editor.error;return }
                        store.applyV2ProfileFacts(doc.facts.mapValues(\.value),meta:doc.facts.mapValues { ProfileFactMeta(sourceKind:$0.sourceKind ?? "legacy_recorded",confirmedAt:nil,revision:nil) })
                        profile=store.state.profile;originalProfile=profile
                    }
                }
            }
            .onChange(of: profile.venue) { _, venue in
                if venue == "健身房" {
                    profile.equipment = nil; profile.equipmentOther = nil; profile.homeTrainingDays = nil
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(saveMessage == nil ? "取消" : "完成") {
                        if loaded && profile != originalProfile { confirmLeave = true } else { dismiss() }
                    }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        showValidation=true
                        if let first=validationIssues.first {
                            saveError=first.text
                            withAnimation(reduceMotion ? nil : ClubMotion.standard) { proxy.scrollTo(first.id,anchor:.top) }
                        } else if profile == originalProfile && store.state.nutritionTarget == newTarget { saveError=nil;saveMessage="资料没有发生变化。" }
                        else { saveError=nil;confirmSave=true }
                    } label: {
                        HStack(spacing: 6) { if saving { ClubActivityMark(size: 16) }; Text(saving ? "保存中…" : "保存") }
                    }
                        .disabled(saving || loadingFacts || !loaded)
                }
            }
            .confirmationDialog("还有未保存的资料修改", isPresented: $confirmLeave, titleVisibility: .visible) {
                Button("检查并保存") { showValidation = true; if validationIssues.isEmpty { confirmSave = true } else { saveError = validationIssues.first?.text } }
                Button("放弃修改并关闭", role: .destructive) { dismiss() }
                Button("继续编辑", role: .cancel) { }
            }
            .confirmationDialog("保存资料与目标？", isPresented: $confirmSave, titleVisibility: .visible) {
                Button(trainingChanged && allowPlanUpdate && planChoice != "保留" ? "保存并预览新计划" : "保存资料与目标") { saveProfile() }
                Button("取消", role: .cancel) { }
            } message: {
                Text("营养目标将更新。过去记录保留原目标；新训练方案需要预览确认后才应用。")
            }
            .sheet(isPresented: $showUpdatedPlan) {
                PlanView(date: planStart, replacesProfileWeek: true, onPlanApplied: {
                    saveMessage = "资料与目标已生效，所选一周的未开始训练已按新方案更新。"
                })
            }
            .safeAreaInset(edge:.bottom) {
                if saving { ClubLoadingCard(title: "正在保存资料与目标…").padding(BojiSpace.workoutCardInset).background(.regularMaterial) }
                else if let saveMessage {
                    Text(saveMessage).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading).padding(BojiSpace.workoutCardInset).background(.regularMaterial)
                        .accessibilityIdentifier("profile-save-result")
                }
                else if !validationIssues.isEmpty {
                    Text(validationIssues.map{$0.text}.joined(separator:" ")).font(.caption).foregroundStyle(showValidation ? Color.red : Color.secondary)
                        .frame(maxWidth:.infinity,alignment:.leading).padding(BojiSpace.workoutCardInset).background(.regularMaterial)
                }
            }
            }
        }
    }

    private func saveProfile() {
        guard validationIssues.isEmpty else { showValidation=true;saveError=validationIssues.first?.text;return }
        guard !saving, let owner = editingAccountID, owner == account.user?.id, owner == store.editingAccountID else {
            saveError = "账号已变化，请重新打开资料页。"; return
        }
        if section != .body { normalizeTrainingDays() }
        profile.nickname = String(profile.nickname.trimmingCharacters(in: .whitespacesAndNewlines).prefix(30))
        let savedProfile = profile
        let shouldPlan = trainingChanged && allowPlanUpdate && store.currentPlanUsesAI && planChoice != "保留"
        let today = ClubDates.calendar.startOfDay(for: Date())
        let weekday = (ClubDates.calendar.component(.weekday, from: today) + 5) % 7 + 1
        let offset = planChoice == "下周" ? 8 - weekday : 1
        let start = ClubDates.calendar.date(byAdding: .day, value: offset, to: today) ?? today
        saving = true; saveError = nil; saveMessage = nil
        if savedProfile.factState != nil {
            Task { await saveV2Facts(savedProfile, shouldPlan: shouldPlan, start: start) }
            return
        }
        Task {
            defer { saving = false }
            do {
                try await account.saveOnboarding(profile: savedProfile, planMode: account.user?.planMode ?? "generate_plan")
                guard owner == store.editingAccountID, owner == account.user?.id else { return }
                // This form edits body / training settings, not avatar artwork.
                // Keep an avatar received from cloud while the form was open.
                var profileToPersist = savedProfile
                profileToPersist.avatarID = store.state.profile.avatarID
                profileToPersist.avatarImage = store.state.profile.avatarImage
                profileToPersist.identityVersion = store.state.profile.identityVersion
                guard store.saveProfile(profileToPersist) else {
                    saveError = "账号资料已保存，但本机记录尚未更新。请重试保存：" + store.takeMessage(fallback: "本机保存失败。")
                    return
                }
                originalProfile = profileToPersist; profile = profileToPersist
                saveMessage = shouldPlan ? "资料和营养目标已生效。请生成并确认新计划；关闭预览会继续保留原训练安排。" : "资料和营养目标已生效，现有训练安排保留。"
                if shouldPlan { planStart = start; showUpdatedPlan = true }
            } catch {
                guard owner == store.editingAccountID else { return }
                saveError = AppErrorText.message(error)
            }
        }
    }


    /// V2 members without confirmed basics cannot go through the legacy full
    /// PUT (it would turn default numbers into facts). Save only fields the user
    /// actually changed, through the facts proposal/confirm service.
    @MainActor
    private func saveV2Facts(_ saved: MemberProfile, shouldPlan: Bool, start: Date) async {
        defer { saving = false }
        var changes: [[String: Any]] = []
        func changed<T: Equatable>(_ old: T, _ new: T, _ field: OnboardingFieldSpec, _ value: Any) {
            if old != new { changes.append(["field": field.apiKey, "value": value, "unit": field.unit ?? NSNull()]) }
        }
        if originalProfile.nickname != saved.nickname { changes.append(["field":"nickname", "value":saved.nickname]) }
        changed(originalProfile.goal, saved.goal, .goal, saved.goal)
        changed(originalProfile.experience, saved.experience, .experience, saved.experience)
        changed(originalProfile.venue, saved.venue, .venue, saved.venue)
        changed(originalProfile.focus, saved.focus, .focus, saved.focus)
        if let text = saved.limitations, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { changed(originalProfile.limitations ?? "", text, .limitations, text) }
        changed(originalProfile.daysPerWeek, saved.daysPerWeek, .daysPerWeek, saved.daysPerWeek)
        changed(originalProfile.sessionMinutes ?? 45, saved.sessionMinutes ?? 45, .sessionMinutes, saved.sessionMinutes ?? 45)
        changed(originalProfile.trainingDays ?? [], saved.trainingDays ?? [], .trainingDays, saved.trainingDays ?? [])
        changed(originalProfile.equipment ?? "", saved.equipment ?? "", .equipment,
                (saved.equipment ?? "").split(separator: "、").map(String.init))
        if let other = saved.equipmentOther, !other.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            changed(originalProfile.equipmentOther ?? "", other, .equipmentOther, other)
        }
        changed(originalProfile.homeTrainingDays ?? [], saved.homeTrainingDays ?? [], .homeTrainingDays, saved.homeTrainingDays ?? [])
        if let context = saved.nutritionContext, context != originalProfile.nutritionContext { changes.append(["field": "nutrition_context", "value": context, "unit": NSNull()]) }
        if let activity = saved.dailyActivity, activity != originalProfile.dailyActivity { changes.append(["field": "daily_activity", "value": activity, "unit": NSNull()]) }
        if let target = saved.targetWeightKg, target != originalProfile.targetWeightKg { changes.append(["field": "target_weight_kg", "value": target, "unit": "kg"]) }
        if saved.age != originalProfile.age { changes.append(["field": "age_years", "value": saved.age, "unit": "years"]) }
        if saved.height != originalProfile.height { changes.append(["field": "height_cm", "value": saved.height, "unit": "cm"]) }
        if saved.weight != originalProfile.weight { changes.append(["field": "profile_weight_kg", "value": saved.weight, "unit": "kg", "measurement_kind": "estimated"]) }
        if let gender = saved.gender, gender != originalProfile.gender, ["男", "女", "不愿提供"].contains(gender) { changes.append(["field": "sex_for_nutrition", "value": gender, "unit": NSNull()]) }
        guard !changes.isEmpty else {
            saveMessage = "没有检测到资料变化。未填写的字段仍保持未知。"
            return
        }
        let editor = v2Editor
        guard await editor.apply(changes: changes, account: account) else {
            saveError = editor.error ?? "资料保存未完成，原资料与本机记录已保留。"
            return
        }
        if let document = editor.facts {
            store.applyV2ProfileFacts(document.facts.mapValues(\.value),
                meta: document.facts.mapValues { ProfileFactMeta(sourceKind: $0.sourceKind ?? "confirmed", confirmedAt: nil, revision: nil) })
            originalProfile = store.state.profile
            profile = store.state.profile
        }
        saveMessage = shouldPlan && store.state.profile.canPrepareTrainingPlan
            ? "资料已保存。计划不会自动改变；可预览并单独确认新计划。"
            : "资料已保存，现有训练安排保留。未填写的基本资料仍为未知。"
        if shouldPlan, store.state.profile.canPrepareTrainingPlan { planStart = start; showUpdatedPlan = true }
    }
    private func normalizeTrainingDays() {
        var days = Array(Set((profile.trainingDays ?? []).filter { (1...7).contains($0) })).sorted()
        if days.isEmpty { days = Array([1,3,5,2,4,6,7].prefix(max(1,min(7,profile.daysPerWeek)))).sorted() }
        profile.trainingDays = days; profile.daysPerWeek = days.count
        profile.homeTrainingDays = (profile.homeTrainingDays ?? []).filter { days.contains($0) }
    }

    private var equipmentSelection: [String] {
        (profile.equipment ?? "").components(separatedBy: "、").filter { !$0.isEmpty }
    }

    private func toggleEquipment(_ item: String) {
        var values = equipmentSelection
        if values.contains(item) {
            values.removeAll { $0 == item }
            if item == "其他" { profile.equipmentOther = nil }
        } else {
            values.append(item)
        }
        profile.equipment = values.isEmpty ? nil : values.joined(separator: "、")
    }
}


struct ClubKeepsakeVaultView: View {
    var embedded = false
    @Environment(\.dynamicTypeSize) private var typeSize
    @EnvironmentObject private var clubSeason: ClubSeasonService
    @EnvironmentObject private var account: AccountService
    @Environment(\.dismiss) private var dismiss
    @State private var selected: ClubCollectedReward?
    @State private var loading = true
    @State private var tab = "收藏"
    var body: some View {
        if embedded { content }
        else { ClubNavigationStack132 { content.toolbar { ToolbarItem(placement: .confirmationAction) { DismissButton() } } } }
    }
    private var content: some View {
        VStack(spacing: 0) {
            Picker("收藏和奖品", selection: $tab) {
                Text("我的收藏").tag("收藏")
                Text("成长季与奖品").tag("奖品")
            }.clubAdaptivePicker().padding(.horizontal, ClubUI.pageInset).padding(.vertical, BojiSpace.general)
            if tab == "奖品" { ClubHistoryView().navigationTitle("俱乐部奖励") }
            else {
                ScrollView {
                    LazyVStack(spacing: 16) {
                        if loading && clubSeason.collection.isEmpty { ClubLoadingCard(title: "正在打开收藏…") }
                        else if clubSeason.collection.isEmpty {
                            ContentUnavailableView("还没有 俱乐部奖励", systemImage: "seal", description: Text(clubSeason.notice ?? "参加月度成长季并完成任务后，纪念会收藏在这里。"))
                            Button("重新加载") { Task { await refresh() } }.buttonStyle(SecondaryButton()).font(.subheadline)
                        } else {
                            Text("\(clubSeason.collection.count) 枚纪念 · 每一枚都来自真实记录").font(.caption).foregroundStyle(.secondary)
                            LazyVGrid(columns: typeSize.isAccessibilitySize ? [GridItem(.flexible())] : [GridItem(.adaptive(minimum: 148), spacing: 16)], spacing: 20) {
                                ForEach(clubSeason.collection) { reward in
                                    Button { selected = reward } label: {
                                        VStack(spacing: 10) {
                                            ClubRewardArtwork(rewardID: reward.id, imagePath: reward.imagePath, icon: "seal.fill", revision: reward.artworkRevision).frame(width: 92, height: 92)
                                            Text(reward.title).font(.subheadline.weight(.semibold)).fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.center)
                                            Text(reward.seasonTitle).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                                        }.frame(maxWidth: .infinity).padding(.vertical, BojiSpace.pageInset)
                                            .background(BojiColor.subtleSurface, in: RoundedRectangle(cornerRadius: BojiRadius.inner))
                                    }.buttonStyle(ClubMotionButton())
                                }
                            }
                        }
                    }.padding(ClubUI.pageInset)
                }.refreshable { await refresh() }
            }
        }
        .background { ClubBackground() }
        .navigationTitle("俱乐部奖励").navigationBarTitleDisplayMode(.inline)
        .onChange(of: account.user?.id) { _, _ in selected = nil }
        .task(id: account.user?.id) { await refresh() }
        .sheet(item: $selected) { reward in
            ClubKeepsakeDetailView(title: reward.title, detail: "\(reward.seasonTitle) · \(reward.detail ?? "这是在成长季中完成真实记录后获得的 俱乐部奖励。")", icon: reward.icon, rewardType: reward.rewardType, rewardID: reward.id, imagePath: reward.imagePath, revision: reward.artworkRevision, canShare: true)
        }
    }
    private func refresh() async {
        loading = true
        await clubSeason.refreshCollection(account: account)
        loading = false
    }
}

struct RecordArchiveView: View {
    @State private var includePhotos = true
    @State private var showRepair = false
    var allowImport = true
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var month = ""
    @State private var file: URL?
    @State private var conflictFile: URL?
    @State private var busy = false
    @State private var error: String?
    @State private var importing = false
    @State private var importResult: String?
    var body: some View {
        ClubNavigationStack132 {
            List {
                Section {
                    DisclosureGroup("了解备份内容") {
                    Text("导出包含所选月份的训练、饮食、健康摘要、已完成 AI 结果和已下载的饮食照片。本机身体照片与健康来源缓存不包含在内。文件含个人信息，请保存在你信任的位置。")
                    Text("导出不会删除本机或云端记录。恢复只补回缺失的日期，不覆盖已有日期或手动删除的内容。旧版文件没有账号标记，请只导入你自己的备份。暂不提供删除式归档。")
                    }
                    Text("备份文件包含个人记录，请妥善保管。").font(.footnote).foregroundStyle(.secondary)
                }.font(.caption)
                Picker("月份", selection: $month) { ForEach(store.exportableMonths, id: \.self) { Text($0).tag($0) } }.disabled(busy)
                Button(busy ? "正在导出…" : "导出所选月份") {
                    busy = true; error = nil; file = nil
                    let exportingMonth = month
                    Task { defer { busy = false }; do {
                        let exported = try await store.exportMonth(exportingMonth, includePhotos: includePhotos)
                        guard month == exportingMonth else { return }; file = exported
                    } catch { self.error = AppErrorText.message(error) } }
                }.buttonStyle(PrimaryButton()).disabled(busy || month.isEmpty)
                if busy { ClubLoadingCard(title: "正在处理备份…", detail: "处理结束前请保持此页面打开。") }
                if let file {
                    ShareLink("另存／分享导出文件", item: file).buttonStyle(ClubActionButtonStyle(kind: .row))
                }
                if store.conflictNotice != nil {
                    Button("导出其他设备同时修改的备份") { do { conflictFile = try store.exportConflict() } catch { self.error = AppErrorText.message(error) } }.buttonStyle(ClubActionButtonStyle(kind: .row))
                }
                if let conflictFile { ShareLink("另存其他设备的备份", item: conflictFile).buttonStyle(ClubActionButtonStyle(kind: .row)) }
                if allowImport {
                    Button("从月度备份补回记录") { importing = true }.buttonStyle(ClubActionButtonStyle(kind: .row)).disabled(busy)
                }
                if let importResult { Text(importResult).foregroundStyle(.secondary) }
                if let error { Text(error).foregroundStyle(.red) }
                Section("备份选项") {
                    Toggle("导出时包含可用照片", isOn: $includePhotos)
                    Text("缺失或损坏的照片会被注明并跳过，文字记录仍能导出。关闭照片可以减小文件。导入支持最多 128 MB 的月度文件。").font(.caption).foregroundStyle(.secondary)
                    if let notice = store.exportNotice { Text(notice).font(.caption) }
                    Button("记录与照片修复") { showRepair = true }.buttonStyle(ClubActionButtonStyle(kind: .row))
                }
            }.clubManagementList132().clubListSurface().navigationTitle("导出与备份").navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showRepair) { RecordRepairView() }
            .onAppear { month = store.exportableMonths.first ?? "" }
            .onChange(of: month) { _, _ in file = nil }
            .toolbar { ToolbarItem(placement: .cancellationAction) { DismissButton().disabled(busy) } }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                switch result {
                case .success(let url):
                    busy = true; error = nil; importResult = nil
                    Task {
                        defer { busy = false }
                        do { importResult = try await store.importMonth(url) }
                        catch { self.error = AppErrorText.message(error) }
                    }
                case .failure(let error): self.error = AppErrorText.message(error)
                }
            }

        }
    }
}

// Membership-expired access has no editing bindings or routes to paid entry forms.
private struct MembershipRecordHistoryView: View {
    @EnvironmentObject private var store: AppStore
    var body: some View {
        List {
            if store.state.days.isEmpty { Text("暂无历史记录") }
            ForEach(store.state.days.keys.sorted(by: >), id: \.self) { date in
                if let log = store.state.days[date] {
                    NavigationLink(date) { MembershipDayRecordView(date: date, log: log) }
                }
            }
        }.clubListSurface().navigationTitle("历史记录（只读）").navigationBarTitleDisplayMode(.inline)
    }
}

private struct MembershipDayRecordView: View {
    let date: String
    let log: DayLog
    var body: some View {
        List {
            Section("训练") {
                ForEach(log.exercises) { exercise in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(exercise.displayName).bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
                        ForEach(Array(exercise.sets.enumerated()), id: \.element.id) { index, set in
                            Text("第 \(index + 1) 组 · \(set.durationSeconds.map { "\($0) 秒" } ?? "\(set.weight.formatted()) kg × \(set.reps) 次") · \(set.validCompletion ? "已完成" : "未完成")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("饮食") {
                ForEach(log.meals) { meal in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(meal.category + " · " + meal.name)
                        Text(meal.hasNutrition ? "\(meal.calories.formatted()) kcal · 蛋白质 \(meal.protein.formatted()) g · 碳水 \(meal.carbs.formatted()) g · 脂肪 \(meal.fat.formatted()) g" : "营养数据未知，尚未计入营养汇总")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let health = log.health {
                Section("健康摘要") {
                    if let value = health.steps { LabeledContent("步数", value: value.value.formatted()) }
                    if let value = health.activeEnergy { LabeledContent("活动能量（kcal）", value: value.value.formatted()) }
                    if let value = health.sleep { LabeledContent("睡眠（小时）", value: value.value.formatted()) }
                    if let value = health.heartRate { LabeledContent("心率", value: value.value.formatted()) }
                    if let value = health.restingHeartRate { LabeledContent("静息心率", value: value.value.formatted()) }
                }
            }
        }.clubListSurface().navigationTitle(date).navigationBarTitleDisplayMode(.inline)
    }
}


struct ClubGuideOwner: Identifiable { let id: Int }

struct ClubUsageGuideView: View {
    var firstVisitAccountID: Int? = nil
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        ClubNavigationStack132 {
            List {
                Section("边用边学") {
                    Label("每日分析：在首页点「每日分析」，读当天的训练、饮食与恢复解读。", systemImage: "chart.bar")
                    Label("每周复盘：在首页点「每周复盘」，看这一周的整体进展。", systemImage: "calendar")
                    Label("拍照识别：在饮食页点「照片」，识别食物后核对份量再保存。", systemImage: "camera")
                    Label("AI 计划：在首页点「AI 计划生成」，按你的目标与时间安排训练。", systemImage: "dumbbell")
                }
                Section {
                    Text("首次使用时，相关位置会显示简短操作提示；不需要先读完说明书。拍照识别与 AI 建议都需要你核对后保存。").font(.footnote).foregroundStyle(.secondary)
                    Button("重新显示操作提示") {
                        if let id = firstVisitAccountID {
                            UserDefaults.standard.removeObject(forKey: "club.guide123.\(id).first_set")
                        }
                        dismiss()
                    }
                }
            }.clubManagementList132().navigationTitle("使用帮助").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { DismissButton() } }
        }
    }
}


enum ClubAvatars {
    static let ids = (1...12).map { String(format: "avatar-%02d", $0) }
    static let names = ["晨练", "清风", "山峰", "夜跑", "向阳", "海岸", "稳步", "远行", "跃动", "星光", "松林", "起点"]
    static func index(_ id: String?) -> Int { ids.firstIndex(of: id ?? "") ?? 0 }
}

struct ClubAvatarView: View {
    let profile: MemberProfile
    var size: CGFloat = 60
    private var customImage: UIImage? {
        guard let data = profile.avatarImage, data.count <= 32768 else { return nil }
        return UIImage(data: data)
    }
    var body: some View {
        Group {
            if let image = customImage { Image(uiImage: image).resizable().scaledToFill() }
            else { ClubAvatarArtwork(index: ClubAvatars.index(profile.avatarID)) }
        }.frame(width: size, height: size).clipShape(Circle())
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
            .accessibilityLabel("\(profile.nickname)的头像")
    }
}

// Twelve vector portraits share a single drawing system and scale without blur.
private struct ClubAvatarArtwork: View {
    let index: Int
    var body: some View {
        Canvas { context, size in
            var context = context
            let scale = min(size.width, size.height) / 100
            context.scaleBy(x: scale, y: scale)
            let backgrounds: [Color] = [
                Color(red:0.88,green:0.95,blue:0.91), Color(red:0.96,green:0.90,blue:0.84), Color(red:0.87,green:0.92,blue:0.98),
                Color(red:0.94,green:0.89,blue:0.96), Color(red:0.98,green:0.94,blue:0.79), Color(red:0.98,green:0.87,blue:0.85),
                Color(red:0.84,green:0.94,blue:0.93), Color(red:0.85,green:0.89,blue:0.97), Color(red:0.97,green:0.88,blue:0.91),
                Color(red:0.84,green:0.94,blue:0.97), Color(red:0.97,green:0.90,blue:0.79), Color(red:0.90,green:0.87,blue:0.97)
            ]
            let shirts: [Color] = [
                Color(red:0.19,green:0.48,blue:0.36), Color(red:0.76,green:0.36,blue:0.23), Color(red:0.23,green:0.43,blue:0.72),
                Color(red:0.47,green:0.31,blue:0.65), Color(red:0.83,green:0.56,blue:0.13), Color(red:0.72,green:0.28,blue:0.30),
                Color(red:0.12,green:0.50,blue:0.52), Color(red:0.25,green:0.34,blue:0.65), Color(red:0.70,green:0.29,blue:0.45),
                Color(red:0.11,green:0.48,blue:0.64), Color(red:0.68,green:0.42,blue:0.16), Color(red:0.45,green:0.32,blue:0.67)
            ]
            let skins: [Color] = [Color(red:0.96,green:0.79,blue:0.66), Color(red:0.87,green:0.66,blue:0.50), Color(red:0.73,green:0.49,blue:0.34), Color(red:0.92,green:0.72,blue:0.57)]
            let hairs: [Color] = [Color(red:0.16,green:0.11,blue:0.09), Color(red:0.25,green:0.15,blue:0.10), Color(red:0.11,green:0.12,blue:0.14), Color(red:0.34,green:0.20,blue:0.12)]
            context.fill(Path(CGRect(x: 0, y: 0, width: 100, height: 100)), with: .color(backgrounds[index % 12]))
            context.fill(Path(ellipseIn: CGRect(x: 16, y: 69, width: 68, height: 65)), with: .color(shirts[index % 12]))
            context.fill(Path(roundedRect: CGRect(x: 42, y: 55, width: 16, height: 25), cornerRadius: 5), with: .color(skins[index % 4]))
            if index % 4 == 2 {
                context.fill(Path(ellipseIn: CGRect(x: 20, y: 19, width: 61, height: 61)), with: .color(hairs[index % 4]))
            }
            let skin = skins[index % 4]
            context.fill(Path(ellipseIn: CGRect(x: 27, y: 19, width: 46, height: 53)), with: .linearGradient(Gradient(colors: [skin, skin.opacity(0.82)]), startPoint: CGPoint(x: 35,y: 20), endPoint: CGPoint(x: 67,y: 73)))
            var hair = Path()
            hair.move(to: CGPoint(x: 26, y: 39)); hair.addCurve(to: CGPoint(x: 75, y: 36), control1: CGPoint(x: 22, y: 8), control2: CGPoint(x: 77, y: 7))
            if index % 4 == 0 { hair.addLine(to: CGPoint(x: 57, y: 28)); hair.addLine(to: CGPoint(x: 32, y: 38)) }
            else if index % 4 == 1 { hair.addLine(to: CGPoint(x: 39,y: 25)); hair.addLine(to: CGPoint(x: 27,y: 47)) }
            else if index % 4 == 2 { hair.addLine(to: CGPoint(x: 68,y: 24)); hair.addLine(to: CGPoint(x: 30,y: 32)) }
            else { hair.addLine(to: CGPoint(x: 70,y: 29)); hair.addLine(to: CGPoint(x: 31,y: 29)) }
            hair.closeSubpath(); context.fill(hair, with: .color(hairs[index % 4]))
            for x in [39.0, 59.0] {
                context.fill(Path(ellipseIn: CGRect(x: x, y: 43, width: 3.5, height: 4)), with: .color(Color(white: 0.12)))
            }
            var mouth = Path(); mouth.move(to: CGPoint(x: 44, y: 58)); mouth.addQuadCurve(to: CGPoint(x: 57,y: 58), control: CGPoint(x: 50,y: index % 3 == 0 ? 66 : 61))
            context.stroke(mouth, with: .color(Color(white: 0.36)), style: StrokeStyle(lineWidth: 1.7, lineCap: .round))
            if index >= 8 {
                for x in [32.0, 54.0] { context.stroke(Path(roundedRect: CGRect(x:x,y:39,width:17,height:13),cornerRadius:5), with:.color(Color(white:0.25)),lineWidth:1.6) }
                var bridge = Path(); bridge.move(to:CGPoint(x:49,y:44));bridge.addLine(to:CGPoint(x:54,y:44));context.stroke(bridge,with:.color(Color(white:0.25)),lineWidth:1.5)
            }
            if index >= 4 && index < 8 {
                context.fill(Path(roundedRect: CGRect(x:25,y:25,width:50,height:7),cornerRadius:3),with:.color(backgrounds[(index + 5) % 12]))
            }
            var collar = Path(); collar.move(to:CGPoint(x:36,y:74));collar.addQuadCurve(to:CGPoint(x:64,y:74),control:CGPoint(x:50,y:88))
            context.stroke(collar,with:.color(Color.white.opacity(0.65)),style:StrokeStyle(lineWidth:2,lineCap:.round))
        }
    }
}

struct MemberIdentityEditor: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var account: AccountService
    @Environment(\.dismiss) private var dismiss
    @State private var profile = MemberProfile()
    @State private var owner: Int?
    @State private var photoItem: PhotosPickerItem?
    @State private var crop: AvatarCropInput?
    @State private var error: String?
    @State private var saving = false
    @State private var readingPhoto = false
    @State private var loadedIdentity = false
    @State private var photoTicket = UUID()
    var body: some View {
        ClubNavigationStack132 {
            List {
                    ClubAvatarView(profile: profile, size: 104)
                    Section("昵称") { TextField("2—20 个字符", text: $profile.nickname) }
                    Section("头像") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 70, maximum: 96), spacing: 14)], spacing: 18) {
                        ForEach(Array(ClubAvatars.ids.enumerated()), id: \.element) { index, id in
                            Button {
                                profile.avatarID = id; profile.avatarImage = nil
                            } label: {
                                VStack(spacing: 7) {
                                    ClubAvatarView(profile: avatarProfile(id), size: 58)
                                        .overlay(Circle().stroke(profile.avatarImage == nil && (profile.avatarID ?? "avatar-01") == id ? ClubBrand.accent : .clear, lineWidth: 2))
                                    Text(ClubAvatars.names[index]).font(.caption).foregroundStyle(.primary)
                                }
                            }.buttonStyle(ClubMotionButton())
                                .accessibilityAddTraits(profile.avatarImage == nil && (profile.avatarID ?? "avatar-01") == id ? .isSelected : [])
                        }
                    }
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label("从相册上传头像", systemImage: "photo")
                    }.buttonStyle(SecondaryButton()).disabled(readingPhoto || saving)
                    }
                    if readingPhoto { ClubLoadingCard(title: "正在读取照片…") }
                    Text("分享训练或分析时可以展示头像与昵称；分享前可以关闭。头像会随账号记录同步。").font(.subheadline).foregroundStyle(.secondary)
                    if let error { Text(error).foregroundStyle(.red).font(.subheadline) }
                    if saving { ClubLoadingCard(title: "正在保存头像与昵称…") }

        }.clubManagementList132().disabled(saving || readingPhoto).background { ClubBackground() }.navigationTitle("头像与昵称").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(saving) }
                    ToolbarItem(placement: .confirmationAction) { Button("完成", action: save).disabled(saving || readingPhoto) }
                }
                .onAppear {
                    guard !loadedIdentity else { return }
                    loadedIdentity = true; owner = store.editingAccountID; profile = store.state.profile
                }
                .task(id: photoItem) {
                    guard let selected = photoItem else { return }
                    let ticket = UUID(); photoTicket = ticket; readingPhoto = true; error = nil
                    defer { if photoTicket == ticket { readingPhoto = false } }
                    do {
                        guard let data = try await selected.loadTransferable(type: Data.self), let image = await ClubImage.preview(data, pixels: 900) else { throw AccountError.message("照片未能读取，请换一张。") }
                        guard !Task.isCancelled, photoTicket == ticket, owner == store.editingAccountID else { return }
                        crop = AvatarCropInput(image: image)
                    } catch { if !Task.isCancelled, photoTicket == ticket { self.error = AppErrorText.message(error) } }
                }
                .sheet(item: $crop, onDismiss: { photoItem = nil }) { input in
                    AvatarCropEditor(image: input.image) { data in profile.avatarImage = data; profile.avatarID = nil }
                }
                .onChange(of: store.editingAccountID) { _, _ in dismiss() }
        }.interactiveDismissDisabled(saving)
    }
    private func avatarProfile(_ id: String) -> MemberProfile {
        var value = profile; value.avatarID = id; value.avatarImage = nil; return value
    }
    private func save() {
        guard owner != nil, owner == store.editingAccountID else { return }
        profile.nickname = profile.nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...20).contains(profile.nickname.count) else { error = "请填写2—20个字符的昵称。"; return }
        guard (profile.avatarImage?.count ?? 0) <= 32768 else { error = "头像过大，请重新选择。"; return }
        // Merge into the latest body / training profile; identity editing must
        // not overwrite concurrent changes to goals or the user's schedule.
        var current = store.state.profile
        current.identityVersion = 1
        current.nickname = profile.nickname; current.avatarID = profile.avatarID; current.avatarImage = profile.avatarImage
        guard store.saveProfile(current) else { error = store.takeMessage(); return }
        saving = true
        Task {
            defer { saving = false }
            do {
                guard owner == store.editingAccountID, owner == account.user?.id, !Task.isCancelled else { return }
                try await account.saveOnboarding(profile: current, planMode: account.user?.planMode ?? "generate_plan")
                guard owner == store.editingAccountID else { return }; dismiss()
            } catch {
                guard owner == store.editingAccountID else { return }
                self.error = "已保存在本机，账号昵称暂未更新。联网后可再次点保存：" + AppErrorText.message(error)
            }
        }
    }
}

private struct AvatarCropInput: Identifiable { let id = UUID(); let image: UIImage }
private struct AvatarCropEditor: View {
    let image: UIImage
    let save: (Data) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var zoom = 1.0
    @State private var offset = CGSize.zero
    @GestureState private var drag = CGSize.zero
    @State private var error: String?
    private var baseScale: CGFloat { 240 / min(image.size.width, image.size.height) }
    private var drawingSize: CGSize { CGSize(width: image.size.width * baseScale * zoom, height: image.size.height * baseScale * zoom) }
    private func clamped(_ raw: CGSize) -> CGSize {
        let size = drawingSize
        return CGSize(width: min(max(raw.width, -(size.width - 240) / 2), (size.width - 240) / 2), height: min(max(raw.height, -(size.height - 240) / 2), (size.height - 240) / 2))
    }
    var body: some View {
        ClubNavigationStack132 {
            VStack(spacing: 28) {
                Text("拖动照片调整位置").bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
                let position = clamped(CGSize(width: offset.width + drag.width, height: offset.height + drag.height))
                Image(uiImage: image).resizable().frame(width: drawingSize.width, height: drawingSize.height)
                    .offset(x: position.width, y: position.height).frame(width: 240, height: 240).clipShape(Circle())
                    .contentShape(Circle()).gesture(DragGesture().updating($drag) { value, state, _ in state = value.translation }.onEnded { value in offset = clamped(CGSize(width: offset.width + value.translation.width, height: offset.height + value.translation.height)) })
                Slider(value: $zoom, in: 1...3).accessibilityLabel("头像缩放").onChange(of: zoom) { _, _ in offset = clamped(offset) }
                if let error { Text(error).foregroundStyle(.red) }
                Button("使用这张头像") { render() }.buttonStyle(PrimaryButton())
                Spacer()
            }.padding(28).navigationTitle("裁剪头像").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
    }
    private func render() {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let size = drawingSize; let position = clamped(offset); let ratio = 256.0 / 240
        let cropped = UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256), format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
            image.draw(in: CGRect(x: ((240 - size.width) / 2 + position.width) * ratio, y: ((240 - size.height) / 2 + position.height) * ratio, width: size.width * ratio, height: size.height * ratio))
        }
        for quality in [0.8, 0.65, 0.5, 0.35, 0.2] {
            if let data = cropped.jpegData(compressionQuality: quality), data.count <= 32768 { save(data); dismiss(); return }
        }
        error = "这张照片压缩后仍然过大，请选择另一张。"
    }
}

#if DEBUG
enum ProfileAuditFactory {
 static func crop() -> some View { AvatarCropEditor(image: UIImage(named: "ClubKeepsakeHero")!, save: { _ in }) }
 static func history() -> some View { MembershipRecordHistoryView() }
}
#endif


struct ClubActionPreferencesView: View {
    var pendingOnly132 = false
    @EnvironmentObject private var account: AccountService
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var health: HealthDataService
    @Environment(\.dismiss) private var dismiss
    @State private var fast = false
    @State private var unit = "kg"
    @State private var zone = TimeZone.current.identifier
    @State private var proactive = true
    @State private var loaded = false
    @State private var busy = false
    @State private var error: String?
    @State private var cloudChoice: String?
    var body: some View {
        ClubNavigationStack132 {
            Form {
                if !pendingOnly132 {
                Section("主动学习") {
                    Toggle("允许从我的记录中学习偏好并生成主动建议", isOn: $proactive)
                    Text("关闭后不再提取新的长期记忆或生成首页主动洞察；已确认的记忆仍可用于回答，训练与记录功能不受影响。").font(.footnote).foregroundStyle(.secondary)
                }
                Section("AI 记录授权") {
                    Toggle("明确的体重和饮食记录可快速保存", isOn: $fast)
                    Text("默认先预览。开启后，仅明确的低风险记录可以直存，并保留撤销入口；改期和换计划仍须确认。").font(.footnote).foregroundStyle(.secondary)
                    Picker("未说明单位时使用", selection: $unit) { Text("公斤 kg").tag("kg"); Text("磅 lb").tag("lb") }
                    Text("当前时区：" + zone).font(.footnote)
                    Button(busy ? "正在保存…" : "保存设置") { Task { await save() } }.disabled(!loaded || busy)
                }
                Section("Apple 健康") {
                    Toggle("手动称重后写入 Apple 健康", isOn: Binding(get: { health.writeWeightsEnabled }, set: { value in Task { await health.setWeightWritingEnabled(value) } }))
                    Text("此选项单独申请系统写入权限。读取到的健康样本仍需在健康确认页明确分享后才保存到云端。").font(.footnote).foregroundStyle(.secondary)
                }
                }
                if pendingOnly132 {
                Section("未上传的修改") {
                    if store.pendingDomainCommands.isEmpty { Text("没有待处理的操作") }
                    ForEach(store.pendingDomainCommands, id: \.commandID) { item in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(item.type).font(.headline)
                            if let message = item.lastError { Text(message).font(.subheadline).foregroundStyle(.secondary) }
                            Text("已尝试 \(item.attempts) 次；重试保持原操作编号。").font(.caption)
                            Button("重试这笔操作") { store.retryDomainCommand(item.commandID) }
                            if item.blocked == true { Button("改用该日云端内容…", role: .destructive) { cloudChoice = item.commandID } }
                        }
                    }
                }
                }
                if let error { Section { Text(error).foregroundStyle(.secondary) } }
            }.clubManagementList132().navigationTitle(pendingOnly132 ? "待同步项目" : "AI 记录与授权")
                .toolbar { ToolbarItem(placement: .confirmationAction) { DismissButton() } }
                .task { if !pendingOnly132 { await load() } }
                .confirmationDialog("改用该日云端记录？", isPresented: Binding(get: { cloudChoice != nil }, set: { if !$0 { cloudChoice = nil } }), titleVisibility: .visible) {
                    Button("备份手机记录并使用账号中的版本", role: .destructive) { if let id = cloudChoice { Task { await store.useCloudDomainDay(id); cloudChoice = nil } } }
                    Button("取消", role: .cancel) { cloudChoice = nil }
                } message: { Text("该日的未同步本机内容会保存为恢复备份，再读取云端内容；其他日期不变。") }
        }
    }
    private func load() async {
        guard let owner = account.user?.id, !account.isPreviewAccount else { error = "真实账号登录后可以管理行动授权。"; return }
        do {
            let response = try await account.proposalRequest(path: "/me/ai/action-preferences", method: "GET", body: nil, expectedUserID: owner)
            guard response.statusCode == 200 else { throw AIClientError.message("行动设置暂未取得。") }
            let p = try JSONDecoder().decode(ActionPreferences.self, from: response.data)
            guard account.user?.id == owner else { return }
            fast = p.fast_records; unit = p.weight_unit; zone = TimeZone.current.identifier; proactive = p.proactive_learning ?? true; loaded = true
        } catch { self.error = AppErrorText.message(error) }
    }
    private func save() async {
        guard let owner = account.user?.id else { return }; busy = true; defer { busy = false }
        do {
            let body = try JSONEncoder().encode(ActionPreferences(fast_records: fast, time_zone: zone, weight_unit: unit, proactive_learning: proactive))
            let response = try await account.proposalRequest(path: "/me/ai/action-preferences", method: "PUT", body: body, expectedUserID: owner)
            guard response.statusCode == 200 else { throw AIClientError.message("设置未保存，请重试。") }
            error = "设置已保存。"
        } catch { self.error = AppErrorText.message(error) }
    }
    private struct ActionPreferences: Codable { var fast_records: Bool; var time_zone: String; var weight_unit: String; var proactive_learning: Bool? }
}
