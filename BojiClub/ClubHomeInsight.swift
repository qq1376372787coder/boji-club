import Foundation

// MARK: - 服务端首页洞察（Phase 2 §2.5 / D-09）
//
// 服务端只下发它自己能核验的事实（已核验复盘、确认训练节奏），不镜像本地规则
// （D-03：文档类事实保持客户端计算，避免 PHP/Swift 双实现漂移）。
// 工作台按优先级合并：服务端**严格更高**才取代本地 top；离线/预览/失败一律本地兜底。

struct ClubServerInsight: Codable, Equatable {
    let id: String
    let kind: String
    let title: String
    let detail: String
    let evidence: String
    let priority: Int
    let evidenceRefs: [String]

    enum CodingKeys: String, CodingKey {
        case id, kind, title, detail, evidence, priority
        case evidenceRefs = "evidence_refs"
    }

    /// 仅接受客户端支持呈现的洞察类别；未知类别整条忽略（向后兼容）。
    var insightKind: ClubInsightKind? {
        let candidate = ClubInsightKind(rawValue: kind)
        return candidate.supported ? candidate : nil
    }
}

struct ClubServerInsightResponse: Codable, Equatable {
    let insight: ClubServerInsight?
}

enum ClubHomeInsightMerge {
    /// 合并规则：server 存在且 priority 严格高于本地 top 且类别受支持 → 服务端；
    /// 否则本地（可为 nil）。
    static func resolve(local: ClubInsightEvent?, server: ClubServerInsight?) -> (kind: ClubInsightKind, title: String, detail: String)? {
        if let server, server.priority > (local?.priority ?? Int.min), let kind = server.insightKind {
            return (kind, server.title, server.detail)
        }
        guard let local else { return nil }
        return (local.kind, local.title, local.detail)
    }
}

/// Only a presentation selection; never persisted health text. Recompute current sources first.
struct ClubHomeInsightSelection: Equatable, Identifiable {
    let id: String
    let owner: Int
    let day: String
    let kind: ClubInsightKind
    let title: String
    let detail: String
    let priority: Int
}
enum ClubHomeInsightStability {
    static func select(current: ClubHomeInsightSelection?, candidates: [ClubHomeInsightSelection]) -> ClubHomeInsightSelection? {
        guard let best = candidates.sorted(by: { $0.priority == $1.priority ? $0.id < $1.id : $0.priority > $1.priority }).first else { return nil }
        guard let current, current.owner == best.owner, current.day == best.day,
              let valid = candidates.first(where: { $0.id == current.id && $0.owner == current.owner && $0.day == current.day }) else { return best }
        // Ordinary sync candidates do not rotate the card. Higher-priority safety/action facts do.
        return best.priority >= 100 && best.priority > valid.priority ? best : valid
    }
}
