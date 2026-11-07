import XCTest
@testable import BojiClub

/// FeatureFlagService 契约测试：固定 AI 主界面、功能开关流转、新旧服务端载荷兼容。
/// 历史问题⑩的回归：客户端消费 ai_enabled / club_enabled；历史首页开关不再改变新构建入口。
@MainActor
final class FeatureFlagServiceTests: XCTestCase {

    private func makeConfig(aiEnabled: Bool = true,
                            clubEnabled: Bool = true,
                            aiNativeHome: Bool? = nil) -> ClubRemoteConfig {
        ClubRemoteConfig(version: 1, publishedAt: nil, config: .init(
            aiEnabled: aiEnabled,
            clubEnabled: clubEnabled,
            aiNativeHome: aiNativeHome,
            minimumBuild: 0,
            latestBuild: 0,
            announcement: .init(enabled: false, title: "", body: "")))
    }

    func testDefaultsAreSafe() {
        let flags = FeatureFlagService()
        XCTAssertTrue(flags.aiNativeHome, "AI 主界面是唯一入口")
        XCTAssertTrue(flags.aiEnabled)
        XCTAssertTrue(flags.clubEnabled)
    }

    func testLegacyRemoteShellFlagCannotRestoreRemovedUI() {
        let flags = FeatureFlagService()
        flags.apply(remote: makeConfig(aiNativeHome: true))
        XCTAssertTrue(flags.aiNativeHome)
        flags.apply(remote: makeConfig(aiNativeHome: false))
        XCTAssertTrue(flags.aiNativeHome, "历史开关关闭时仍使用同一 AI 主界面")
    }

    func testFeatureGatesFlowFromRemote() {
        let flags = FeatureFlagService()
        var cfg = makeConfig(aiEnabled: false, clubEnabled: false)
        cfg.config.actionSystemEnabled = false
        cfg.config.onboardingV2Enabled = false
        cfg.config.contextualTipsEnabled = false
        cfg.config.aiContextReferencesV1 = true
        flags.apply(remote: cfg)
        XCTAssertFalse(flags.aiEnabled, "ai_enabled=false 必须被客户端消费")
        XCTAssertFalse(flags.clubEnabled, "club_enabled=false 必须被客户端消费")
        XCTAssertFalse(flags.actionSystemEnabled, "action_system_enabled=false 必须被客户端消费")
        XCTAssertFalse(flags.onboardingV2Enabled, "onboarding_v2_enabled=false 必须被客户端消费")
        XCTAssertFalse(flags.contextualTipsEnabled, "contextual_tips_enabled=false 必须被客户端消费")
        XCTAssertTrue(flags.referencesEnabled, "ai_context_references_v1=true 必须被客户端消费")
        flags.apply(remote: makeConfig(aiEnabled: true, clubEnabled: true))
        XCTAssertTrue(flags.aiEnabled)
        XCTAssertTrue(flags.clubEnabled)
        XCTAssertTrue(flags.actionSystemEnabled)
        XCTAssertTrue(flags.onboardingV2Enabled)
        XCTAssertTrue(flags.contextualTipsEnabled)
    }

    func testNilRemoteKeepsDefaults() {
        let flags = FeatureFlagService()
        flags.apply(remote: nil)
        XCTAssertTrue(flags.aiNativeHome)
        XCTAssertTrue(flags.aiEnabled)
        XCTAssertTrue(flags.clubEnabled)
    }

    func testLegacyServerPayloadDecodesWithoutShellKey() throws {
        // 旧服务端（未部署 ai_native_home）不下发该键 → 解码为 nil → 仍使用唯一新界面。
        let json = """
        {"version":2,"published_at":"2026-10-24T00:00:00Z","config":{"ai_enabled":true,"club_enabled":true,"minimum_build":0,"latest_build":0,"announcement":{"enabled":false,"title":"","body":""}}}
        """
        let decoded = try JSONDecoder().decode(ClubRemoteConfig.self, from: Data(json.utf8))
        XCTAssertNil(decoded.config.aiNativeHome)
        XCTAssertTrue(decoded.config.aiEnabled)
    }

    func testNewServerPayloadDecodesShellKey() throws {
        let json = """
        {"version":3,"config":{"ai_enabled":true,"club_enabled":true,"ai_native_home":true,"minimum_build":0,"latest_build":0,"announcement":{"enabled":false,"title":"","body":""}}}
        """
        let decoded = try JSONDecoder().decode(ClubRemoteConfig.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.config.aiNativeHome, true)
        let flags = FeatureFlagService()
        flags.apply(remote: decoded)
        XCTAssertTrue(flags.aiNativeHome)
    }
}

final class ClubDiscoverableDraftTests: XCTestCase {
    func testSavedAndLegacyDraftsAreDiscoverableAndAccountScoped() {
        let name = "draft-discovery-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let first = UUID().uuidString.lowercased(), legacy = UUID().uuidString.lowercased(), other = UUID().uuidString.lowercased()
        ClubCoachDraftStorage.save("未发送的训练问题", owner: 11, conversation: first, defaults: defaults)
        defaults.set("旧版本草稿", forKey: "club-coach-draft.v1.11." + legacy)
        ClubCoachDraftStorage.save("另一账号", owner: 22, conversation: other, defaults: defaults)
        XCTAssertEqual(Set(ClubCoachDraftStorage.conversations(owner: 11, defaults: defaults)), Set([first, legacy]))
        XCTAssertEqual(ClubCoachDraftStorage.conversations(owner: 22, defaults: defaults), [other])
        ClubCoachDraftStorage.clear(owner: 11, conversation: first, defaults: defaults)
        XCTAssertEqual(ClubCoachDraftStorage.conversations(owner: 11, defaults: defaults), [legacy])
        XCTAssertTrue(ClubCoachDraftStorage.conversations(owner: -1, defaults: defaults).isEmpty)
    }
}
