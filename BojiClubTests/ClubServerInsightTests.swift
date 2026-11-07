import Foundation
import XCTest
@testable import BojiClub

/// §2.5/D-09 服务端首页洞察：解码契约 + 与本地 top 的合并规则。
final class ClubServerInsightTests: XCTestCase {
    private let weeklyJSON = """
    {"id":"server/weekly-review/2026-10-20","kind":"workout","title":"训练复盘已生成",
     "detail":"这一期的复盘已按已确认记录生成。可以查看内容，再核对下一周的安排。",
     "evidence":"依据：2026-10-20 的复盘结果已通过服务端核验（任务 abc）。",
     "priority":108,"evidence_refs":["job/abc","day/2026-10-20"]}
    """

    func testDecodeSnakeCaseRefs() throws {
        let insight = try JSONDecoder().decode(ClubServerInsight.self, from: Data(weeklyJSON.utf8))
        XCTAssertEqual(insight.evidenceRefs, ["job/abc", "day/2026-10-20"])
        XCTAssertEqual(insight.priority, 108)
        XCTAssertEqual(insight.insightKind, .workout)
    }

    func testNullInsightResponse() throws {
        let decoded = try JSONDecoder().decode(ClubServerInsightResponse.self, from: Data(#"{"insight":null}"#.utf8))
        XCTAssertNil(decoded.insight)
    }

    func testUnsupportedKindIsIgnored() throws {
        let json = weeklyJSON.replacingOccurrences(of: "\"workout\"", with: "\"unknown-kind\"")
        let insight = try JSONDecoder().decode(ClubServerInsight.self, from: Data(json.utf8))
        XCTAssertNil(insight.insightKind, "未知类别必须整条忽略（向后兼容）")
    }

    private func localEvent(priority: Int) -> ClubInsightEvent {
        ClubInsightEvent(id: "local/1", date: "2026-10-24", groupID: "g", kind: .training,
                         recordedAt: Date(timeIntervalSince1970: 0), previousIDs: [],
                         state: .active, evidenceDigest: "d", title: "本地洞察", detail: "本地明细",
                         evidence: "本地依据", priority: priority, isTodayReminder: true)
    }

    private func serverInsight(priority: Int, kind: String = "workout") throws -> ClubServerInsight {
        let json = weeklyJSON
            .replacingOccurrences(of: "\"priority\":108", with: "\"priority\":\(priority)")
            .replacingOccurrences(of: "\"workout\"", with: "\"\(kind)\"")
        return try JSONDecoder().decode(ClubServerInsight.self, from: Data(json.utf8))
    }

    func testServerWinsOnlyOnStrictlyHigherPriority() throws {
        let local = localEvent(priority: 100)
        let resolved = try ClubHomeInsightMerge.resolve(local: local, server: serverInsight(priority: 104))
        XCTAssertEqual(resolved?.title, "训练复盘已生成")

        // 同优先级不取代（本地是设备上最新事实，服务端不覆盖平级）。
        let tied = try ClubHomeInsightMerge.resolve(local: local, server: serverInsight(priority: 100))
        XCTAssertEqual(tied?.title, "本地洞察")

        // 本地更高时服务端不生效。
        let lower = try ClubHomeInsightMerge.resolve(local: local, server: serverInsight(priority: 90))
        XCTAssertEqual(lower?.title, "本地洞察")
    }

    func testServerWithoutLocalApplies() throws {
        let resolved = try ClubHomeInsightMerge.resolve(local: nil, server: serverInsight(priority: 104))
        XCTAssertEqual(resolved?.kind, .workout)
        XCTAssertEqual(resolved?.detail.contains("复盘"), true)
    }

    func testUnsupportedKindFallsBackToLocal() throws {
        let local = localEvent(priority: 60)
        let resolved = try ClubHomeInsightMerge.resolve(local: local, server: serverInsight(priority: 200, kind: "future-kind"))
        XCTAssertEqual(resolved?.title, "本地洞察")
    }

    func testBothNilResolvesNil() {
        XCTAssertNil(ClubHomeInsightMerge.resolve(local: nil, server: nil))
    }

    func testLocalOnlyResolvesLocal() {
        let local = localEvent(priority: 60)
        let resolved = ClubHomeInsightMerge.resolve(local: local, server: nil)
        XCTAssertEqual(resolved?.title, "本地洞察")
        XCTAssertEqual(resolved?.kind, .training)
    }
}
