import XCTest
@testable import BojiClub

/// Phase 4 §5.3（D-11）：主动程度三档映射契约。
final class ClubProactiveModeTests: XCTestCase {
    func testQuietTurnsEverythingOff() {
        var settings = ClubAutomationSettings()
        settings.automaticDaily = true
        settings.weeklyEnabled = true
        settings.workoutEnabled = true
        settings.includePartial = true
        let quiet = ClubAutomationSettings.applying(.quiet, to: settings)
        XCTAssertFalse(quiet.automaticDaily)
        XCTAssertFalse(quiet.weeklyEnabled)
        XCTAssertFalse(quiet.workoutEnabled)
        XCTAssertFalse(quiet.includePartial)
        XCTAssertFalse(quiet.anyAutomatic, "安静＝暂停全部主动分析")
    }

    func testBalancedMatchesDefaults() {
        let balanced = ClubAutomationSettings.applying(.balanced, to: ClubAutomationSettings())
        XCTAssertTrue(balanced.automaticDaily)
        XCTAssertTrue(balanced.weeklyEnabled)
        XCTAssertFalse(balanced.workoutEnabled)
        XCTAssertFalse(balanced.includePartial)
        XCTAssertEqual(ClubAutomationSettings.applying(.balanced, to: ClubAutomationSettings()).modeLabel, .balanced)
    }

    func testActiveTurnsAllOn() {
        let active = ClubAutomationSettings.applying(.active, to: ClubAutomationSettings())
        XCTAssertTrue(active.automaticDaily && active.weeklyEnabled && active.workoutEnabled && active.includePartial)
    }

    func testModeLabelDerivesFromSwitches() {
        var settings = ClubAutomationSettings.applying(.balanced, to: ClubAutomationSettings())
        XCTAssertEqual(settings.modeLabel, .balanced)
        // 细调任一开关 → 与预设分叉 → 自定义（nil）。
        settings.workoutEnabled = true
        XCTAssertNil(settings.modeLabel)
        // 回到预设组合 → 档位恢复。
        settings.workoutEnabled = false
        XCTAssertEqual(settings.modeLabel, .balanced)
    }

    func testNonMappedSettingsSurviveModeApplication() {
        var settings = ClubAutomationSettings()
        settings.dailyHour = 8
        settings.quietStart = 23
        let active = ClubAutomationSettings.applying(.active, to: settings)
        XCTAssertEqual(active.dailyHour, 8, "档位只映射四个开关，其余设置保持不动")
        XCTAssertEqual(active.quietStart, 23)
    }

    func testStoredLegacyJSONDecodesWithoutMode() throws {
        // 旧版本存储的 JSON 没有 proactiveMode 字段 → 解码为 nil（向后兼容）。
        let legacy = """
        {"version":1,"automaticDaily":true,"includePartial":false,"dailyHour":21,"quietEnabled":true,"quietStart":22,"quietEnd":8}
        """
        let settings = try JSONDecoder().decode(ClubAutomationSettings.self, from: Data(legacy.utf8))
        XCTAssertNil(settings.proactiveMode, "旧版本存储无 mode 字段 → nil")
        XCTAssertNil(settings.modeLabel, "weekly 未开的旧组合不匹配任何预设 → 自定义")
        // 与平衡档完全一致的旧数据 → 档位从开关组合推出（即使字段缺失）。
        let balanced = "{"
        + "\"version\":1,\"automaticDaily\":true,\"automaticWeekly\":true,\"includePartial\":false,\"dailyHour\":21,\"quietEnabled\":true,\"quietStart\":22,\"quietEnd\":8}"
        let decoded = try JSONDecoder().decode(ClubAutomationSettings.self, from: Data(balanced.utf8))
        XCTAssertEqual(decoded.modeLabel, .balanced, "开关组合与预设一致时档位自动恢复")
    }
}
