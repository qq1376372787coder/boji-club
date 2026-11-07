import SwiftUI

private struct ClubManagementSurfaceKey132: EnvironmentKey { static let defaultValue = false }
private struct ClubNativeSectionsKey132: EnvironmentKey { static let defaultValue = false }
private struct ClubEmbeddedNavigationKey132: EnvironmentKey { static let defaultValue = false }
private struct ClubPushedKey132: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var clubManagementSurface132: Bool { get { self[ClubManagementSurfaceKey132.self] } set { self[ClubManagementSurfaceKey132.self] = newValue } }
    var clubNativeSections132: Bool { get { self[ClubNativeSectionsKey132.self] } set { self[ClubNativeSectionsKey132.self] = newValue } }
    var clubEmbeddedNavigation132: Bool { get { self[ClubEmbeddedNavigationKey132.self] } set { self[ClubEmbeddedNavigationKey132.self] = newValue } }
    var clubPushed132: Bool { get { self[ClubPushedKey132.self] } set { self[ClubPushedKey132.self] = newValue } }
}

/// A page owns one navigation container. Pushed destinations reuse their parent's;
/// sheets and dedicated editors create their own, with fresh presentation context.
struct ClubNavigationStack132<Content: View>: View {
    @Environment(\.clubEmbeddedNavigation132) private var embedded
    private let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        if embedded { content.environment(\.clubEmbeddedNavigation132, false) }
        else { NavigationStack { content.environment(\.clubEmbeddedNavigation132, false).environment(\.clubPushed132, false).environment(\.clubManagementSurface132, false).environment(\.clubNativeSections132, false) } }
    }
}

extension View {
    func clubPushDestination132(ownsNavigationContainer: Bool = true) -> some View {
        environment(\.clubEmbeddedNavigation132, ownsNavigationContainer).environment(\.clubPushed132, true).environment(\.clubManagementSurface132, false).environment(\.clubNativeSections132, false)
    }
    func clubManagementList132() -> some View {
        listStyle(.insetGrouped)
            .environment(\.clubManagementSurface132, true)
            .environment(\.clubNativeSections132, true)
            .tint(.primary)
            .scrollDismissesKeyboard(.interactively)
    }
    func clubComposerGlass132() -> some View { modifier(ClubComposerGlass132()) }
}
private struct ClubComposerGlass132: ViewModifier {
    func body(content: Content) -> some View {
        content.clubGlassEffect(in: RoundedRectangle(cornerRadius: BojiRadius.hero, style: .continuous))
    }
}

struct AccountSettings132: View {
    @EnvironmentObject private var account: AccountService
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var owner132: Int?
    @State private var identity = false
    @State private var logout = false
    @State private var deletion = false
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        ClubNavigationStack132 {
            Form {
                Section {
                    Button { identity = true } label: {
                        HStack(spacing: BojiLayout.rowGap) {
                            ClubAvatarView(profile: store.state.profile, size: 48)
                            VStack(alignment: .leading, spacing: BojiLayout.tight) {
                                Text(store.state.profile.nickname.isEmpty ? "薄肌成员" : store.state.profile.nickname).foregroundStyle(.primary)
                                Text(account.user?.clubNumber ?? "未登录").bojiType(.secondary).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, BojiLayout.tight)
                    }.buttonStyle(.plain)
                    if let masked = account.user?.phoneMasked, !masked.isEmpty { LabeledContent("登录账号", value: masked) }
                }
                Section { Button("退出登录", role: .destructive) { logout = true }.disabled(busy || account.user == nil) }
                Section {
                    Button("注销账号", role: .destructive) { deletion = true }.disabled(busy || account.user == nil)
                } footer: { Text("删除账号、个人记录与媒体，此操作不可恢复。Apple 订阅需在系统中另行取消。") }
                if busy { ProgressView("正在处理…") }
                if let error { Text(error).foregroundStyle(.red) }
            }.clubManagementList132().navigationTitle("账号").navigationBarTitleDisplayMode(.inline)
                .onAppear { if owner132 == nil { owner132 = account.user?.id } }
                .onChange(of: account.user?.id) { _, value in
                    if value != owner132 { logout = false; deletion = false; identity = false; dismiss() }
                }
                .sheet(isPresented: $identity) { MemberIdentityEditor() }
                .confirmationDialog("退出当前账号？", isPresented: $logout, titleVisibility: .visible) {
                    Button("退出登录", role: .destructive) { Task { guard let owner132, owner132 == account.user?.id else { return }; await account.logout() } }
                }
                .confirmationDialog("确认永久注销账号？", isPresented: $deletion, titleVisibility: .visible) {
                    Button("注销账号及个人数据", role: .destructive) {
                        guard let owner132, owner132 == account.user?.id else { return }
                        busy = true
                        Task {
                            defer { busy = false }
                            guard owner132 == account.user?.id else { return }
                            do { _ = try await account.deleteAccount() }
                            catch { if owner132 == account.user?.id { self.error = AppErrorText.message(error) } }
                        }
                    }
                } message: { Text("账号将停用，个人资料、记录、照片视频和 AI 数据进入删除流程，无法撤销。") }
        }
    }
}

struct AboutSettings132: View {
    var body: some View {
        List {
            Section {
                HStack(spacing: BojiLayout.rowGap) { BojiBrandMark(size: 44); Text("薄肌俱乐部").bojiType(.bodyStrong) }
                LabeledContent("版本", value: Self.version)
            }
            Section {
                NavigationLink("用户协议") { LegalDocumentView(document: .terms).clubPushDestination132() }
                NavigationLink("隐私政策") { LegalDocumentView(document: .privacy).clubPushDestination132() }
                NavigationLink("购买与退款政策") { LegalDocumentView(document: .purchase).clubPushDestination132() }
                NavigationLink("注销账号与数据删除") { LegalDocumentView(document: .deletion).clubPushDestination132() }
                NavigationLink("AI 服务说明") { LegalDocumentView(document: .aiNotice).clubPushDestination132() }
                NavigationLink("健康与运动风险提示") { LegalDocumentView(document: .healthDisclaimer).clubPushDestination132() }
                NavigationLink("同步与诊断") { DiagnosticsView130().clubPushDestination132() }
                NavigationLink("意见反馈") { MemberFeedbackHub128().clubPushDestination132() }
            }
        }.clubManagementList132().navigationTitle("关于").navigationBarTitleDisplayMode(.inline)
    }
    static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "—") (\(info["CFBundleVersion"] as? String ?? "—"))"
    }
}

struct ManagedPlanList: View {
    let focusDate: Date
    let initialCycleStart: String?
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var ai: AIService
    @State private var creation = false
    @State private var openInitial = false
    @State private var restored = false
    private var current: [ManagedPlan] { store.managedPlans.filter { !store.planIsEnded($0.id) && !store.planIsArchived($0.id) && (!store.supersededPlanIDs126.contains($0.id) || !store.cancellableDates(for: $0).isEmpty) } }
    private var history: [ManagedPlan] { store.managedPlans.filter { store.planIsEnded($0.id) || store.planIsArchived($0.id) || (store.supersededPlanIDs126.contains($0.id) && store.cancellableDates(for: $0).isEmpty) } }
    private var drafts: [AILocalJob] {
        ai.jobs.filter { ["generate_plan","parse_plan"].contains($0.request.kind) && $0.status == "succeeded" && !$0.consumed && $0.replacementID == nil && !store.hasAppliedAIJob($0.id) && !(store.state.deletedAIJobIDs ?? []).contains($0.id) }
    }
    var body: some View {
        ClubNavigationStack132 {
            List {
                Section("当前计划") {
                    if current.isEmpty { Text("暂无当前计划").foregroundStyle(.secondary) }
                    ForEach(current) { plan in planRow(plan) }
                }
                if !drafts.isEmpty {
                    Section("待采用的方案") {
                        ForEach(drafts) { job in
                            NavigationLink {
                                PlanView(date: ClubDates.date(fromKey: job.request.date) ?? focusDate, initialMode: job.request.kind, initialJobID: job.id).clubPushDestination132()
                            } label: { VStack(alignment: .leading, spacing: BojiLayout.tight) { Text(job.request.kind == "parse_plan" ? "导入的计划" : "AI 制定的计划"); Text(job.request.date).bojiType(.secondary).foregroundStyle(.secondary) } }
                        }
                    }
                }
                if !history.isEmpty { Section("历史计划") { ForEach(history) { plan in planRow(plan) } } }
                Section { Button("创建新计划", systemImage: "plus") { creation = true } }
            }.clubManagementList132().navigationTitle("我的计划").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { DismissButton() } }
                .sheet(isPresented: $creation) { PlanCreationSheet(date: max(focusDate, Date())) }
                .navigationDestination(isPresented: $openInitial) { ManagedPlanDetail132(focusDate: focusDate, initialCycleStart: initialCycleStart).clubPushDestination132() }
                .task { if !restored { restored = true; openInitial = initialCycleStart != nil } }
        }
    }
    private func planRow(_ plan: ManagedPlan) -> some View {
        NavigationLink {
            ManagedPlanDetail132(initialPlanID132: plan.id, focusDate: focusDate, initialCycleStart: initialCycleStart).clubPushDestination132()
        } label: {
            VStack(alignment: .leading, spacing: BojiLayout.tight) {
                Text(plan.version.title)
                Text(plan.range).bojiType(.secondary).foregroundStyle(.secondary)
            }
        }
    }
}
