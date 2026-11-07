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
                        if let problem { Text(problem).bojiType(.secondary).foregroundStyle(.secondary) }
                        Button("刷新用量") { Task { await refresh() } }.buttonStyle(SecondaryButton()).disabled(loading)
                    }
                    ClubCard {
                        SectionTitle(title: "记录同步", symbol: "icloud")
                        Text(store.syncStatus.label).bojiType(.body)
                        if let message = store.mediaSyncMessage { Text(message).bojiType(.secondary).foregroundStyle(.secondary) }
                        Text("训练、饮食与分析记录支持增量同步与云端备份。").bojiType(.secondary).foregroundStyle(.secondary)
                        Button("立即同步") { Task { await store.syncNow() } }.buttonStyle(SecondaryButton())
                    }
                    Section {
                        NavigationLink { ClubActionPreferencesView(pendingOnly132: true).clubPushDestination132() } label: { Text("待同步项目") }
                        NavigationLink { RecordArchiveView().clubPushDestination132() } label: { Text("导出与备份") }
                        NavigationLink { RecordRepairView().clubPushDestination132() } label: { Text("导入与修复记录") }
                    }
                    Text("离线或上传失败时，原记录和照片仍保留在手机。调整空间额度不会删除已上传内容；需要另存记录时，可返回“导出与备份”。").bojiType(.secondary).foregroundStyle(.secondary)

        }.clubManagementList132()
            .navigationTitle("云端照片与同步")
            .toolbar { ToolbarItem(placement: .confirmationAction) { DismissButton() } }
            .task { await refresh() }
        }
    }
    private func usageContent(_ usage: CloudPhotoUsage) -> some View {
        VStack(alignment: .leading, spacing: BojiLayout.inline) {
            Text("已上传 \(usage.photo_files) 张 · \(Double(usage.photo_bytes) / 1048576, specifier: "%.1f") MB").bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
            Text(usage.photo_limit_bytes == 0 ? "照片空间：不设账号总量上限" : "照片空间：\((Double(usage.photo_limit_bytes) / 1048576).formatted(.number.precision(.fractionLength(0)))) MB").bojiType(.secondary)
            Text(usage.photo_limit_files == 0 ? "照片数量：不设账号总量上限" : "照片数量：最多 \(usage.photo_limit_files) 张").bojiType(.secondary)
            if usage.photo_limit_bytes > 0 {
                ProgressView(value: min(1, Double(usage.photo_bytes) / Double(usage.photo_limit_bytes)))
            }
            Text("服务器仍有实际磁盘容量；单张云端JPEG附件最多4MB，必要时App会压缩后上传。").bojiType(.caption).foregroundStyle(.secondary)
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
    @State private var showIdentity = false
    @State private var selectedKeepsake: ClubCollectedReward?
    @State private var showKeepsakeVault = false

    init(recordAccessOnly: Bool = false, routeToKeepsakeVault: Binding<Bool> = .constant(false)) {
        self.recordAccessOnly = recordAccessOnly
        self._routeToKeepsakeVault = routeToKeepsakeVault
    }
    private var statisticsLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: BojiLayout.inline)) : AnyLayout(HStackLayout(spacing: BojiLayout.inline))
    }
    private var monthLogs: [DayLog] {
        let prefix = String(ClubDates.key(Date()).prefix(7))
        return store.state.days.filter { $0.key.hasPrefix(prefix) }.map(\.value)
    }

    var body: some View {
        List {
            Section {
                Button { showIdentity = true } label: {
                    HStack(spacing: BojiLayout.rowGap) {
                        ClubAvatarView(profile: store.state.profile, size: 52)
                        VStack(alignment: .leading, spacing: BojiLayout.tight) {
                            Text(store.state.profile.nickname.isEmpty ? "薄肌成员" : store.state.profile.nickname).bojiType(.bodyStrong).foregroundStyle(.primary)
                            if let number = account.user?.clubNumber { Text(number).bojiType(.secondary).foregroundStyle(.secondary) }
                        }
                    }.padding(.vertical, BojiLayout.tight)
                }.buttonStyle(.plain).accessibilityLabel("编辑头像与昵称")
            }
            Section {
                // 拍板 #5：原「AI 对我的了解」（记忆页浏览入口）下线，
                // 偏好数据改在「AI 记录与授权」内展示，此处收敛到该页。
                NavigationLink { ClubActionPreferencesView().clubPushDestination132() } label: { Label("个人资料", systemImage: "person.text.rectangle") }
                NavigationLink { ManagedPlanList(focusDate: Date(), initialCycleStart: nil).clubPushDestination132() } label: { Label("我的计划", systemImage: "calendar") }
                NavigationLink { MembershipView().clubPushDestination132() } label: { Label("会员与订阅", systemImage: "crown") }
                NavigationLink { SettingsHub130().clubPushDestination132() } label: { Label("设置", systemImage: "gearshape") }
            }
            if recordAccessOnly { Section { NavigationLink("历史报告") { ReportLibraryView().clubPushDestination132() } } }
        }.clubManagementList132()
        .background { ClubBackground() }
        .navigationTitle("我的").navigationBarTitleDisplayMode(.inline)

        .task(id: account.user?.id) { await store.syncNow(); await clubSeason.refreshCollection(account: account) }
        .onChange(of: routeToKeepsakeVault, initial: true) { _, shouldOpen in
            guard shouldOpen else { return }
            showKeepsakeVault = true
            routeToKeepsakeVault = false
        }
        .sheet(isPresented: $showIdentity) { MemberIdentityEditor() }
        .sheet(isPresented: $showKeepsakeVault) { ClubKeepsakeVaultView() }
        .sheet(item: $selectedKeepsake) { reward in
            ClubKeepsakeDetailView(
                title: reward.title,
                detail: reward.detail ?? "这是在成长季中完成真实记录后获得的 俱乐部奖励。",
                icon: reward.icon,
                rewardType: reward.rewardType, rewardID: reward.id, imagePath: reward.imagePath, revision: reward.artworkRevision, canShare: true
            )
        }
    }
}

struct MembershipGateView: View {
    @State private var showingAccount = false
    /// 付费墙退出确认文案（果果/知知定稿 4 句，缺一不可；不承诺一键重登）。
    private static let exitMessage = [
        "记录保留在本机，重新登录同一 Apple 账号后继续同步",
        "请用同一 Apple 账号登录，更换账号无法查看原记录",
        "退出不影响你的会员与购买",
        "本机记录换设备或删 App 会丢失，建议先同步再退出"
    ].joined(separator: "\n")
    var body: some View {
        MembershipView(isMandatory: true)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: BojiLayout.rowGap) {
                    Button("账号管理") { showingAccount = true }
                        .buttonStyle(SecondaryButton()).accessibilityIdentifier("membership-account-settings")
                    ClubLogoutButton(
                        title: "先退出，稍后再来",
                        message: Self.exitMessage,
                        cancelTitle: "留在本页",
                        accessibilityLabel: "先退出，稍后再来，返回登录页"
                    )
                }
                .frame(maxWidth: .infinity).padding(ClubUI.pageInset).background(.regularMaterial)
            }
            .sheet(isPresented: $showingAccount) { AccountSettings132() }
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
                    Text("提醒补充未记录的餐次；有记录后不再提醒。").bojiType(.caption).foregroundStyle(.secondary)
                    MealReminderSlotEditor(slot: $notifications.mealReminders.breakfast)
                    MealReminderSlotEditor(slot: $notifications.mealReminders.lunch)
                    MealReminderSlotEditor(slot: $notifications.mealReminders.dinner)
                }
                Section("日报提醒") {
                    Toggle("日总结完成", isOn: $notifications.dailyReportEnabled)
                    Toggle("周总结完成", isOn: $notifications.weeklyReviewEnabled)
                }
                Section {
                    Text("本页管理本机提醒时间；关掉通知不影响日常记录与手动分析。")
                        .bojiType(.caption).foregroundStyle(.secondary)
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
                            .bojiType(.label)
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
                        .bojiType(.caption).foregroundStyle(.secondary)
                    Picker("性别", selection: Binding(get: { profile.gender ?? v2Editor.facts?.facts["sex_for_nutrition"]?.value.string ?? "" }, set: { profile.gender = $0 })) {
                        Text("请选择").tag("")
                        Text("男").tag("男")
                        Text("女").tag("女")
                        Text("不愿提供").tag("不愿提供")
                    }
                    if showValidation { ForEach(Array(validationIssues.filter{$0.id == "basics"}.enumerated()),id:\.offset) { _, issue in Text(issue.text).bojiType(.caption).foregroundStyle(.red) } }
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
                    if showValidation { ForEach(Array(validationIssues.filter{$0.id == "training"}.enumerated()),id:\.offset) { _, issue in Text(issue.text).bojiType(.caption).foregroundStyle(.red) } }
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
                        if showValidation { ForEach(Array(validationIssues.filter{$0.id == "equipment"}.enumerated()),id:\.offset) { _, issue in Text(issue.text).bojiType(.caption).foregroundStyle(.red) } }
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
                    } else { Text(newTarget.note).bojiType(.label) }
                    Text("资料和营养目标保存后立即生效。历史记录保留原目标，已完成训练不会被改写。")
                        .bojiType(.caption).foregroundStyle(.secondary)
                }
                if trainingChanged && allowPlanUpdate && store.currentPlanUsesAI {
                    Section("接下来一周的训练") {
                        Picker("更新安排", selection: $planChoice) {
                            Text("保留现有计划").tag("保留")
                            Text("我想从明天重新安排").tag("明天")
                            Text("我想从下周一重新安排").tag("下周")
                        }
                        Text("保存资料后预览新方案，确认后才更新所选 7 天。已开始或已确认的训练日完整保留；其余日期按新训练日安排，旧的休息日安排也会一并清理。")
                            .bojiType(.caption).foregroundStyle(.secondary)
                    }
                }
                if trainingChanged && allowPlanUpdate && !store.currentPlanUsesAI {
                    Section("现有训练安排") {
                        Text("保存资料会保留你的计划。你可以稍后在计划页手动调整日期、动作和组次。")
                            .bojiType(.secondary).foregroundStyle(.secondary)
                    }
                }
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
                if profile.factState != nil && !account.isPreviewAccount {
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
                        HStack(spacing: BojiLayout.tight) { if saving { ClubActivityMark(size: 16) }; Text(saving ? "保存中…" : "保存") }
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
                else if let saveError {
                    Text(saveError).bojiType(.secondary).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading).padding(BojiSpace.workoutCardInset).background(.regularMaterial)
                        .accessibilityIdentifier("profile-save-error")
                }
                else if let saveMessage {
                    Text(saveMessage).bojiType(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(BojiSpace.workoutCardInset).background(.regularMaterial)
                        .accessibilityIdentifier("profile-save-result")
                }
                else if !validationIssues.isEmpty {
                    Text(validationIssues.map{$0.text}.joined(separator:" ")).bojiType(.caption).foregroundStyle(showValidation ? Color.red : Color.secondary)
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
        if savedProfile.factState != nil && !account.isPreviewAccount {
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
                    LazyVStack(spacing: BojiLayout.cardInset) {
                        if loading && clubSeason.collection.isEmpty { ClubLoadingCard(title: "正在打开收藏…") }
                        else if clubSeason.collection.isEmpty {
                            ContentUnavailableView("还没有 俱乐部奖励", systemImage: "seal", description: Text(clubSeason.notice ?? "参加月度成长季并完成任务后，纪念会收藏在这里。"))
                            Button("重新加载") { Task { await refresh() } }.buttonStyle(SecondaryButton()).bojiType(.secondary)
                        } else {
                            Text("\(clubSeason.collection.count) 枚纪念 · 每一枚都来自真实记录").bojiType(.caption).foregroundStyle(.secondary)
                            LazyVGrid(columns: typeSize.isAccessibilitySize ? [GridItem(.flexible())] : [GridItem(.adaptive(minimum: 148), spacing: BojiLayout.cardInset)], spacing: BojiLayout.blockGap) {
                                ForEach(clubSeason.collection) { reward in
                                    Button { selected = reward } label: {
                                        VStack(spacing: BojiLayout.inline) {
                                            ClubRewardArtwork(rewardID: reward.id, imagePath: reward.imagePath, icon: "seal.fill", revision: reward.artworkRevision)
                                                .frame(width: 92, height: 92)
                                                .shadow(color: .black.opacity(0.08), radius: 8, y: 4)
                                            Text(reward.title).bojiType(.secondary)
                                                .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.center)
                                                .foregroundStyle(BojiColor.textPrimary)
                                            Text(reward.seasonTitle).bojiType(.caption).foregroundStyle(BojiColor.textSecondary).lineLimit(2)
                                        }
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, BojiSpace.pageInset)
                                        .padding(.horizontal, BojiLayout.inline)
                                        .clubGlassEffect(in: RoundedRectangle(cornerRadius: BojiRadius.card, style: .continuous))
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
                    Text("导出包含所选月份的训练、饮食、健康摘要、已完成的结果和已下载的饮食照片。本机身体照片与健康来源缓存不包含在内。文件含个人信息，请保存在你信任的位置。")
                    Text("导出不会删除本机或云端记录。恢复只补回缺失的日期，不覆盖已有日期或手动删除的内容。旧版文件没有账号标记，请只导入你自己的备份。暂不提供删除式归档。")
                    }
                    Text("备份文件包含个人记录，请妥善保管。").bojiType(.label).foregroundStyle(.secondary)
                }.bojiType(.caption)
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
                    Text("缺失或损坏的照片会被注明并跳过，文字记录仍能导出。关闭照片可以减小文件。导入支持最多 128 MB 的月度文件。").bojiType(.caption).foregroundStyle(.secondary)
                    if let notice = store.exportNotice { Text(notice).bojiType(.caption) }
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
                    VStack(alignment: .leading, spacing: BojiLayout.tight) {
                        Text(exercise.displayName).bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
                        ForEach(Array(exercise.sets.enumerated()), id: \.element.id) { index, set in
                            Text("第 \(index + 1) 组 · \(set.durationSeconds.map { "\($0) 秒" } ?? "\(set.weight.formatted()) kg × \(set.reps) 次") · \(set.validCompletion ? "已完成" : "未完成")")
                                .bojiType(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("饮食") {
                ForEach(log.meals) { meal in
                    VStack(alignment: .leading, spacing: BojiLayout.tight) {
                        Text(meal.category + " · " + meal.name)
                        Text(meal.hasNutrition ? "\(meal.calories.formatted()) kcal · 蛋白质 \(meal.protein.formatted()) g · 碳水 \(meal.carbs.formatted()) g · 脂肪 \(meal.fat.formatted()) g" : "营养数据未知，尚未计入营养汇总")
                            .bojiType(.caption).foregroundStyle(.secondary)
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
                    Label("直接提问：在 Club AI 输入框说出你的问题。", systemImage: "bubble.left")
                    Label("引用记录：输入 @ 或点＋，挑一条记录再提问。", systemImage: "at")
                    Label("登记训练：点重量、次数或秒数，做完一组再完成。", systemImage: "dumbbell")
                }
                Section {
                    Text("首次使用会显示简短提示。拍照识别需核对后保存。").bojiType(.label).foregroundStyle(.secondary)
                    Button("重新显示操作提示") {
                        if let id = firstVisitAccountID {
                            for step in ["chat", "first_set"] { UserDefaults.standard.removeObject(forKey: "club.guide123.\(id).\(step)") }
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

// Apple iOS 原生符号化健身头像
private struct ClubAvatarArtwork: View {
    let index: Int
    private var symbol: String {
        let symbols = [
            "figure.strengthtraining.traditional",
            "figure.run",
            "figure.hiking",
            "figure.mind.and.body",
            "figure.outdoor.cycle",
            "figure.cross.training",
            "figure.cooldown",
            "figure.walk",
            "figure.core.training",
            "figure.mixed.cardio",
            "figure.flexibility",
            "person.fill"
        ]
        return symbols[index % symbols.count]
    }
    private var color: Color {
        let colors: [Color] = [
            BojiColor.aiGold,
            BojiColor.mistAccent,
            BojiColor.emeraldAccent,
            BojiColor.aiViolet,
            BojiColor.brandAccent,
            .orange,
            .blue,
            .teal,
            .indigo,
            .cyan,
            .mint,
            BojiColor.textSecondary
        ]
        return colors[index % colors.count]
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [color.opacity(0.22), color.opacity(0.08)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .bojiType(.title)
                .foregroundStyle(color)
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
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 70, maximum: 96), spacing: BojiLayout.rowGap)], spacing: BojiLayout.cardInset) {
                        ForEach(Array(ClubAvatars.ids.enumerated()), id: \.element) { index, id in
                            Button {
                                profile.avatarID = id; profile.avatarImage = nil
                            } label: {
                                VStack(spacing: BojiLayout.inline) {
                                    ClubAvatarView(profile: avatarProfile(id), size: 58)
                                        .overlay(Circle().stroke(profile.avatarImage == nil && (profile.avatarID ?? "avatar-01") == id ? ClubBrand.accent : .clear, lineWidth: 2))
                                    Text(ClubAvatars.names[index]).bojiType(.caption).foregroundStyle(.primary)
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
                    Text("分享训练或分析时可以展示头像与昵称；分享前可以关闭。头像会随账号记录同步。").bojiType(.secondary).foregroundStyle(.secondary)
                    if let error { Text(error).foregroundStyle(.red).bojiType(.secondary) }
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
            VStack(spacing: BojiLayout.sectionGap) {
                Text("拖动照片调整位置").bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
                let position = clamped(CGSize(width: offset.width + drag.width, height: offset.height + drag.height))
                Image(uiImage: image).resizable().frame(width: drawingSize.width, height: drawingSize.height)
                    .offset(x: position.width, y: position.height).frame(width: 240, height: 240).clipShape(Circle())
                    .contentShape(Circle()).gesture(DragGesture().updating($drag) { value, state, _ in state = value.translation }.onEnded { value in offset = clamped(CGSize(width: offset.width + value.translation.width, height: offset.height + value.translation.height)) })
                Slider(value: $zoom, in: 1...3).accessibilityLabel("头像缩放").onChange(of: zoom) { _, _ in offset = clamped(offset) }
                if let error { Text(error).foregroundStyle(.red) }
                Button("使用这张头像") { render() }.buttonStyle(PrimaryButton())
                Spacer()
            }.padding(BojiLayout.sectionGap).navigationTitle("裁剪头像").navigationBarTitleDisplayMode(.inline)
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


/// 拍板 #5：偏好数据（目标 / 训练限制 / 装备排除 / 每周天数 / 明确偏好）并入
/// 「AI 记录与授权」展示。这里**直读 `user_profile_documents`（profileFacts）**，
/// 不经过 `user_memory_items`——记忆表里的资料条目只是派生投影，走同一条链路会留下
/// 第二份可变副本（见《AI记忆迁移方案-v1》§2）。
/// `memory_display_version` 是**展示层**独立版本号，不动 `PROFILE_FACTS_SCHEMA_VERSION`
/// （=1），避免连带影响资料契约与后端校验。
private enum MemoryDisplayPreference {
    static let version = 1
    struct Row: Identifiable {
        let field: OnboardingFieldSpec
        let label: String
        var id: String { field.apiKey }
    }
    /// 只列拍板 #5 点名的偏好类事实；行为习惯（habit）随对话下线，不在此展示。
    static let rows: [Row] = [
        Row(field: .goal, label: "主要目标"),
        Row(field: .limitations, label: "训练限制"),
        Row(field: .equipmentExclusions, label: "装备排除"),
        Row(field: .daysPerWeek, label: "每周训练天数"),
        Row(field: .personalPreferences, label: "我明确填写的偏好"),
    ]
}

struct ClubActionPreferencesView: View {
    var pendingOnly132 = false
    @EnvironmentObject private var account: AccountService
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var health: HealthDataService
    @Environment(\.dismiss) private var dismiss
    @StateObject private var facts = ProfileFactsEditor()
    @State private var fast = false
    @State private var unit = "kg"
    @State private var zone = TimeZone.current.identifier
    @State private var proactive = true
    @State private var personalization = true
    @State private var loaded = false
    @State private var busy = false
    @State private var error: String?
    @State private var cloudChoice: String?
    var body: some View {
        ClubNavigationStack132 {
            Form {
                if !pendingOnly132 {
                // PIPL 阶段4（言言③）：学习与使用拆成**两个独立开关**，不是一个。
                // 每个回执都写明「已停止什么 / 仍保留什么 / 已发出的请求可能已完成」，
                // 两者关闭均前瞻即时生效，且不得因关闭而拒绝核心记录功能（第16条）。
                Section("AI 记忆") {
                    Toggle("停止学习：不再从我的记录中归纳新记忆", isOn: $proactive)
                    Text("已停止：写入新的长期记忆、生成首页主动洞察。仍保留：已保存的记忆，可在下方查看、纠正或撤回。不受影响：训练、记录与报告。关闭前已发出并完成的 AI 分析仍保留在历史结果中。")
                        .bojiType(.label).foregroundStyle(.secondary)
                    Toggle("停用 AI 记忆处理：不让已保存的记忆进入 AI 回答", isOn: $personalization)
                    Text("已停止：把记忆喂给模型做个性化回答与建议。仍保留：记忆本身，以及纠正、撤回入口。不受影响：训练、记录、计划与报告。关闭前已发出并完成的 AI 分析仍保留。")
                        .bojiType(.label).foregroundStyle(.secondary)
                }
                Section("数据授权") {
                    Toggle("明确的体重和饮食记录可快速保存", isOn: $fast)
                    Text("默认先预览。开启后，仅明确的低风险记录可以直存，并保留撤销入口；改期和换计划仍须确认。").bojiType(.label).foregroundStyle(.secondary)
                    Picker("未说明单位时使用", selection: $unit) { Text("公斤 kg").tag("kg"); Text("磅 lb").tag("lb") }
                    Text("账号时区：" + zone).bojiType(.label)
                    if zone != TimeZone.current.identifier {
                        Button("改用设备时区 \(TimeZone.current.identifier)") { zone = TimeZone.current.identifier }
                            .bojiType(.label).buttonStyle(.borderless)
                    }
                    Button(busy ? "正在保存…" : "保存设置") { Task { await save() } }.disabled(!loaded || busy)
                }
                Section("Apple 健康") {
                    Toggle("手动称重后写入 Apple 健康", isOn: Binding(get: { health.writeWeightsEnabled }, set: { value in Task { await health.setWeightWritingEnabled(value) } }))
                    Text("此选项单独申请系统写入权限。读取到的健康样本仍需在健康确认页明确分享后才保存到云端。").bojiType(.label).foregroundStyle(.secondary)
                }
                Section {
                    if facts.facts == nil {
                        Text(account.isPreviewAccount ? "预览账号没有云端偏好数据。" : "偏好数据暂未取得，稍后会自动重试。")
                            .bojiType(.label).foregroundStyle(.secondary)
                    } else {
                        ForEach(MemoryDisplayPreference.rows) { row in
                            let summary = facts.facts?.facts[row.field.apiKey]
                            HStack(alignment: .firstTextBaseline) {
                                Text(row.label).bojiType(.body)
                                Spacer(minLength: BojiLayout.inline)
                                Text(summary?.value.displayText ?? "未填写")
                                    .bojiType(.body)
                                    .foregroundStyle(summary == nil ? Color.secondary : Color.primary)
                                    .multilineTextAlignment(.trailing)
                            }
                        }
                    }
                    // 行权入口恒在，不随偏好数据是否加载而消失：
                    // 记忆页保留这唯一一处用于纠正 / 撤回 / 暂停（PIPL 更正权、撤回权），
                    // 其余浏览型入口已按拍板 #5 全部下线。
                    NavigationLink { ClubAIMemoryView().clubPushDestination132() } label: {
                        Label("管理 AI 记忆（纠正 / 撤回）", systemImage: "list.clipboard")
                    }
                } header: {
                    Text("我的偏好数据 v\(MemoryDisplayPreference.version)")
                } footer: {
                    Text("以上直接读取你的个人资料，与资料页同源，修改资料后此处立即变化；AI 从记录中归纳的习惯与推断不再在此展示。")
                }
                }
                if pendingOnly132 {
                Section("未上传的修改") {
                    if store.pendingDomainCommands.isEmpty { Text("没有待处理的操作") }
                    ForEach(store.pendingDomainCommands, id: \.commandID) { item in
                        VStack(alignment: .leading, spacing: BojiLayout.inline) {
                            Text(item.type).bojiType(.bodyStrong)
                            if let message = item.lastError { Text(message).bojiType(.secondary).foregroundStyle(.secondary) }
                            Text("已尝试 \(item.attempts) 次；重试保持原操作编号。").bojiType(.caption)
                            Button("重试这笔操作") { store.retryDomainCommand(item.commandID) }
                            if item.blocked == true { Button("改用该日云端内容…", role: .destructive) { cloudChoice = item.commandID } }
                        }
                    }
                }
                }
                if let error { Section { Text(error).foregroundStyle(.secondary) } }
            }.clubManagementList132().navigationTitle(pendingOnly132 ? "待同步项目" : "个人资料与授权")
                .toolbar { ToolbarItem(placement: .confirmationAction) { DismissButton() } }
                .task { if !pendingOnly132 { await load() } }
                .confirmationDialog("改用该日云端记录？", isPresented: Binding(get: { cloudChoice != nil }, set: { if !$0 { cloudChoice = nil } }), titleVisibility: .visible) {
                    Button("备份手机记录并使用账号中的版本", role: .destructive) { if let id = cloudChoice { Task { await store.useCloudDomainDay(id); cloudChoice = nil } } }
                    Button("取消", role: .cancel) { cloudChoice = nil }
                } message: { Text("该日的未同步本机内容会保存为恢复备份，再读取云端内容；其他日期不变。") }
        }
    }
    private func load() async {
        // 偏好数据区块与授权设置同源加载；preview 账号由编辑器自行置空。
        await facts.load(account: account)
        guard let owner = account.user?.id, !account.isPreviewAccount else { error = "真实账号登录后可以管理行动授权。"; return }
        do {
            let response = try await account.proposalRequest(path: "/me/ai/action-preferences", method: "GET", body: nil, expectedUserID: owner)
            guard response.statusCode == 200 else { throw AIClientError.message("行动设置暂未取得。") }
            let p = try JSONDecoder().decode(ActionPreferences.self, from: response.data)
            guard account.user?.id == owner else { return }
            fast = p.fast_records; unit = p.weight_unit
            zone = p.time_zone.isEmpty ? TimeZone.current.identifier : p.time_zone
            proactive = p.proactive_learning ?? true
            personalization = p.personalization_enabled ?? true; loaded = true
        } catch { self.error = AppErrorText.message(error) }
    }
    private func save() async {
        guard let owner = account.user?.id else { return }; busy = true; defer { busy = false }
        do {
            let body = try JSONEncoder().encode(ActionPreferences(fast_records: fast, time_zone: zone, weight_unit: unit, proactive_learning: proactive, personalization_enabled: personalization))
            let response = try await account.proposalRequest(path: "/me/ai/action-preferences", method: "PUT", body: body, expectedUserID: owner)
            guard response.statusCode == 200 else { throw AIClientError.message("设置未保存，请重试。") }
            error = "设置已保存。"
        } catch { self.error = AppErrorText.message(error) }
    }
    private struct ActionPreferences: Codable { var fast_records: Bool; var time_zone: String; var weight_unit: String; var proactive_learning: Bool?; var personalization_enabled: Bool? }
}
