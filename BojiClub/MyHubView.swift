import SwiftUI

/// 我的（Tab 4）——全页面新蓝图 §十七（2026-11-09 推倒重来）：
/// 设置、会员、更多（成长季/报告库等杂物全收进「更多」，主界面不再放）。
/// 原生 List 分组（§十二：设置要绝对清晰），本页零玻璃。
struct MyHubView: View {
    @EnvironmentObject private var account: AccountService
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var membership: MembershipService

    var body: some View {
        List {
            Section {
                NavigationLink { AccountSettings132().clubPushDestination132() } label: {
                    HStack(spacing: BojiLayout.rowGap) {
                        Image(systemName: "person.crop.circle.fill")
                            .imageScale(.large)
                            .foregroundStyle(BojiColor.textSecondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(store.state.profile.nickname.isEmpty ? "薄肌成员" : store.state.profile.nickname)
                                .bojiType(.data)
                                .foregroundStyle(BojiColor.textPrimary)
                            Text("账号与资料")
                                .bojiType(.caption)
                                .foregroundStyle(BojiColor.textTertiary)
                        }
                    }
                    .padding(.vertical, BojiLayout.tight)
                }
            }

            Section {
                NavigationLink { ProfileView().clubPushDestination132() } label: {
                    Label("资料与目标", systemImage: "figure.walk")
                }
                NavigationLink { MembershipView().clubPushDestination132() } label: {
                    Label("会员", systemImage: "crown")
                }
                NavigationLink { SettingsHub130().clubPushDestination132() } label: {
                    Label("设置", systemImage: "gearshape")
                }
            }

            Section("更多") {
                NavigationLink { ClubSeasonView().clubPushDestination132(ownsNavigationContainer: false) } label: {
                    Label("俱乐部成长季", systemImage: "seal")
                }
                NavigationLink { ReportLibraryView().clubPushDestination132(ownsNavigationContainer: false) } label: {
                    Label("报告库", systemImage: "doc.text")
                }
                NavigationLink { ClubAISettingsView().clubPushDestination132() } label: {
                    Label("跟进", systemImage: "bell.badge")
                }
                NavigationLink { MemberFeedbackHub128().clubPushDestination132(ownsNavigationContainer: false) } label: {
                    Label("意见反馈", systemImage: "bubble.left.and.text.bubble.right")
                }
                NavigationLink { AboutSettings132() } label: {
                    Label("关于薄肌俱乐部", systemImage: "info.circle")
                }
            }
        }
        .clubManagementList132()
        .navigationTitle("我的")
        .navigationBarTitleDisplayMode(.large)
    }
}
