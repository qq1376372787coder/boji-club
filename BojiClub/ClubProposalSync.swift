import Foundation
import CryptoKit

struct ClubProposalCreatedResponse: Decodable {
    let proposalId: String
    let status: String
    enum CodingKeys: String, CodingKey { case proposalId = "proposal_id", status }
}
struct ClubCommandResponse: Decodable { let status: String?; let idempotent: Bool? }
struct ClubCommandErrorResponse: Decodable { let error: String?; let conflict: Bool? }

/// Phase 1：离线域命令队列条目。稳定 commandId + 服务端 data_operations 幂等保证重放安全。
struct PendingDomainCommand: Codable, Equatable {
    let commandID: String
    let type: String
    let payload: [String: JSONValue]
    let intent: String
    let owner: Int
    var attempts: Int
    let createdAt: Date
    var blocked: Bool? = nil
    var lastError: String? = nil
    /// 指数退避后的下次可重试时间；到期前不再重复发送。
    var nextAttemptAt: Date? = nil
}

/// 弱网/服务异常后的重试节奏：2s、5s、15s、60s、5min、15min、1h。
/// 只对「结果未确认」的命令生效；网络恢复后按同一编号自动续同步，永不因次数被 blocked。
enum DomainCommandBackoff {
    static let delays: [TimeInterval] = [2, 5, 15, 60, 300, 900, 3600]
    static func delay(attempts: Int) -> TimeInterval {
        let index = max(0, min(max(attempts, 1) - 1, delays.count - 1))
        return delays[index]
    }
}

/// Phase 2：模型请求的能力调用（只读请求，尚未执行）。
struct ClubRemoteActionDraft: Decodable { var draft_id: String; var result: AIResult; var request: AIRequest; var hash: String }

typealias ClubCapabilityCall = ClubCoachAnswer.CapabilityCall

/// Phase 2：能力路由结果（服务端按五种处理模式给出终态）。
struct CapabilityRouteResult: Codable, Equatable, Identifiable {
    var capability: String?
    var status: String
    var proposal_id: String?
    var execution_id: String?
    var error: String?
    var card: AICardEnvelope?
    var data: JSONValue?
    var id: String { (capability ?? "unknown") + "|" + (proposal_id ?? execution_id ?? status) }

    /// 只有服务端明确回报完成，才算完成；其余一律显示为待确认/处理中/失败。
    var isCompleted: Bool { ["completed", "succeeded", "draft_ready"].contains(status) }
    var isAwaitingConfirmation: Bool { status == "awaiting_confirmation" }
    var isAccepted: Bool { ["accepted", "running", "pending", "verifying_result", "failed_retryable"].contains(status) }
    var needsAttention: Bool { status == "conflict" || status == "failed" || status == "rejected" }
}

/// Phase 2：能力路由客户端。模型只能"请求"能力，执行方式由服务端决定。
@MainActor
enum CapabilityRouter {
    struct ResolveEnvelope: Decodable { var results: [CapabilityRouteResult] }
    struct StatusEnvelope: Decodable { var execution: CapabilityRouteResult }

    static func resolve(calls: [ClubCapabilityCall], messageID: String, owner: Int,
                        account: any ClubProposalAccount) async -> [CapabilityRouteResult] {
        guard !calls.isEmpty else { return [] }
        do {
            let response = try await account.proposalRequest(path: "/me/ai/actions/messages/" + messageID.lowercased(), method: "GET", body: nil, expectedUserID: owner)
            guard response.statusCode == 200 else { return [CapabilityRouteResult(status: "failed_retryable", error: "行动状态暂未取得，可按原消息重新查询。")] }
            return try JSONDecoder().decode(ResolveEnvelope.self, from: response.data).results
        } catch { return [CapabilityRouteResult(status: "failed_retryable", error: "网络未确认，操作不会以新编号重复提交。")] }
    }

    /// 执行状态查询：确认后断网时用它核对真实结果，而不是提示用户重试。
    static func status(executionID: String, owner: Int,
                       account: any ClubProposalAccount) async -> CapabilityRouteResult? {
        guard !executionID.isEmpty else { return nil }
        do {
            let response = try await account.proposalRequest(path: "/me/ai/actions/" + executionID.lowercased(),
                                                            method: "GET", body: nil, expectedUserID: owner)
            guard response.statusCode == 200 else { return nil }
            return (try? JSONDecoder().decode(StatusEnvelope.self, from: response.data))?.execution
        } catch {
            return nil
        }
    }

    /// 取消尚未确认的提案（规范 §6 的 cancel 端点）。
    static func cancelProposal(proposalID: String, owner: Int,
                               account: any ClubProposalAccount) async -> Bool {
        guard !proposalID.isEmpty else { return false }
        do {
            let response = try await account.proposalRequest(path: "/me/ai/proposals/" + proposalID.lowercased() + "/cancel",
                                                            method: "POST", body: Data("{}".utf8), expectedUserID: owner)
            return response.statusCode == 200
        } catch {
            return false
        }
    }

    /// 投影新鲜度：权威数据始终直读领域状态，派生投影滞后时给出可见提示（spec §8）。
    struct ProjectionStatus: Decodable, Equatable {
        struct Consumer: Decodable, Equatable {
            var consumer: String
            var last_event_at: String?
            var processed_events: Int
        }
        var consumers: [Consumer]
        var pending_events: Int
        var dead_letter_events: Int
        var in_sync: Bool
    }

    static func projectionStatus(owner: Int, account: any ClubProposalAccount) async -> ProjectionStatus? {
        do {
            let response = try await account.proposalRequest(path: "/me/ai/projections", method: "GET", body: nil, expectedUserID: owner)
            guard response.statusCode == 200 else { return nil }
            return try? JSONDecoder().decode(ProjectionStatus.self, from: response.data)
        } catch {
            return nil
        }
    }

    /// 提案类型 → 执行命令（服务端只认这些类型，载荷一律取服务端存储的那份）。
    static func commandType(forProposalKind kind: String) -> String? {
        switch kind {
        case "plan_change_proposal": return "PlanReschedule.Confirm"
        case "exercise_swap": return "ExerciseSwap.Confirm"
        case "plan_activation": return "PlanVersion.Activate"
        case "meal_draft": return "Meal.Create"
        case "weight_entry": return "BodyWeight.Create"
        case "training_finish": return "Training.FinishConfirm"
        default: return nil
        }
    }

    /// 确认提案：只传 proposalId，内容由服务端存储决定（防偷换）。
    static func confirmProposal(kind: String, proposalID: String, owner: Int,
                                account: any ClubProposalAccount) async -> ClubProposalSync.Outcome {
        guard let type = commandType(forProposalKind: kind) else { return .conflict("这份提案暂不支持确认。") }
        do {
            let response = try await account.proposalRequest(path: "/me/ai/proposals/" + proposalID.lowercased() + "/confirm", method: "POST", body: Data("{}".utf8), expectedUserID: owner)
            guard response.statusCode == 200 else {
                return .conflict((try? JSONDecoder().decode(ClubCommandErrorResponse.self, from: response.data))?.error ?? "请重新核对提案状态。")
            }
            MutationReceipts130.capture(response.data, owner: owner)
            let value = try JSONDecoder().decode(ClubCommandResponse.self, from: response.data)
            return value.status == "succeeded" ? .confirmed : .conflict("正在核对执行状态。")
        } catch {
            if let current = await status(executionID: proposalID, owner: owner, account: account), current.isCompleted { return .confirmed }
            return .conflict("尚未确认结果，请查询原提案状态；不会重新创建操作。")
        }
    }
    static func preparePlan(draftID: String, result: AIResult, expectedHash: String, baseline: [String: DayLog], replace: Bool, previewID: String, owner: Int, account: any ClubProposalAccount, onDraftSaved: (String) -> Void = { _ in }) async throws -> (CapabilityRouteResult, String) {
        let body: [String: JSONValue] = ["result": try .encode(result), "expected_hash": .string(expectedHash)]
        let saved = try await account.proposalRequest(path: "/me/ai/drafts/" + draftID, method: "PUT", body: try JSONEncoder().encode(body), expectedUserID: owner)
        guard saved.statusCode == 200 else { throw AIClientError.message((try? JSONDecoder().decode(ClubCommandErrorResponse.self, from: saved.data))?.error ?? "草稿已变化，请重新读取。") }
        struct Saved: Decodable { var hash: String }
        let hash = try JSONDecoder().decode(Saved.self, from: saved.data).hash
        onDraftSaved(hash)
        let preview: [String: JSONValue] = ["expected_days": try .encode(baseline), "replace": .bool(replace), "preview_id": .string(previewID)]
        let response = try await account.proposalRequest(path: "/me/ai/drafts/" + draftID + "/preview", method: "POST", body: try JSONEncoder().encode(preview), expectedUserID: owner)
        guard response.statusCode == 200 else { throw AIClientError.message((try? JSONDecoder().decode(ClubCommandErrorResponse.self, from: response.data))?.error ?? "安排已变化，请重新预览。") }
        return (try JSONDecoder().decode(CapabilityRouteResult.self, from: response.data), hash)
    }
    static func undo(commandID: String, owner: Int, account: any ClubProposalAccount) async -> Bool {
        guard let response = try? await account.proposalRequest(path: "/me/ai/actions/" + commandID.lowercased() + "/undo", method: "POST", body: Data("{}".utf8), expectedUserID: owner) else { return false }
        return response.statusCode == 200
    }

}

@MainActor
protocol ClubProposalAccount {
    var proposalOwnerID: Int? { get }
    var proposalPreview: Bool { get }
    func proposalRequest(path: String, method: String, body: Data?, expectedUserID: Int) async throws -> AccountRawResponse
}

extension AccountService: ClubProposalAccount {
    var proposalOwnerID: Int? { user?.id }
    var proposalPreview: Bool { isPreviewAccount }
    func proposalRequest(path: String, method: String, body: Data?, expectedUserID: Int) async throws -> AccountRawResponse {
        try await cloudRequest(path: path, method: method, body: body, expectedUserID: expectedUserID)
    }
}

/// A stable operation identifies one user intent. A retry reuses it; another card/preview does not.
@MainActor
enum ClubProposalSync {
    enum Outcome: Equatable { case confirmed, fallback, conflict(String) }

    static func operationIdentity(owner: Int, intent: String, generation: Int = 0) -> (key: String, command: String) {
        let digest = SHA256.hash(data: Data("\(owner)/\(intent)/\(generation)".utf8)).map { String(format: "%02x", $0) }.joined()
        let chars = Array(digest.prefix(32))
        let uuid = [String(chars[0..<8]), String(chars[8..<12]), String(chars[12..<16]), String(chars[16..<20]), String(chars[20..<32])].joined(separator: "-")
        return (digest, uuid)
    }

    struct PreparedSchedule {
        let owner: Int
        let proposalID: String
        let commandID: String
    }

    /// Opening a preview may register its baseline, but never confirms or executes it.
    static func prepareScheduleMoves(_ moves: [ClubScheduleMove], baseline: [String: DayLog], operationID: String,
                                     account: any ClubProposalAccount) async throws -> PreparedSchedule {
        guard let owner = account.proposalOwnerID, !account.proposalPreview, !moves.isEmpty, moves.count <= 7 else {
            throw AIClientError.message("请登录后重新核对提案。")
        }
        let days = try JSONSerialization.jsonObject(with: JSONEncoder().encode(baseline))
        let identity = operationIdentity(owner: owner, intent: "schedule/" + operationID)
        let body: [String: Any] = ["kind": "plan_change_proposal", "payload": ["moves": moves.map { ["from": $0.from, "to": $0.to] }],
                                  "evidence_refs": [], "baseline_days": days, "idempotency_key": identity.key]
        let response = try await account.proposalRequest(path: "/me/ai/proposals", method: "POST",
            body: JSONSerialization.data(withJSONObject: body), expectedUserID: owner)
        guard response.statusCode == 200 else {
            throw AIClientError.message((try? JSONDecoder().decode(ClubCommandErrorResponse.self, from: response.data))?.error ?? "提案尚未核对，请重试。")
        }
        let proposal = try JSONDecoder().decode(ClubProposalCreatedResponse.self, from: response.data)
        guard proposal.status == "awaiting_confirmation" || proposal.status == "succeeded" else {
            throw AIClientError.message("提案已过期，请重新核对。")
        }
        return PreparedSchedule(owner: owner, proposalID: proposal.proposalId, commandID: identity.command)
    }

    static func confirmScheduleMoves(_ prepared: PreparedSchedule, account: any ClubProposalAccount) async -> Outcome {
        guard account.proposalOwnerID == prepared.owner else { return .conflict("账号已变化，请重新打开提案。") }
        do {
            let body: [String: Any] = ["commandId": prepared.commandID, "type": "PlanReschedule.Confirm",
                "payload": ["proposalId": prepared.proposalID], "actor": "user"]
            let response = try await account.proposalRequest(path: "/me/commands", method: "POST",
                body: JSONSerialization.data(withJSONObject: body), expectedUserID: prepared.owner)
            guard response.statusCode == 200 else { return errorOutcome(response.data) }
            MutationReceipts130.capture(response.data, owner: prepared.owner)
            let result = try JSONDecoder().decode(ClubCommandResponse.self, from: response.data)
            return result.status == "succeeded" ? .confirmed : .conflict("尚未确认执行，请重试。")
        } catch { return .conflict("暂未取得执行结果。请联网重试，同一提案不会重复执行。") }
    }

    static func confirmDraftCard(_ card: AICardEnvelope, account: any ClubProposalAccount) async -> Outcome {
        guard AICardRegistry.isRenderable(card), !card.isExpired else { return .conflict("卡片已过期或版本不受支持，请重新生成。") }
        let payload: [String: Any]
        switch card.card_type {
        case "meal_draft":
            guard let draft = AIMealDraftPayload(json: card.payload) else { return .conflict("饮食草稿不完整。") }
            guard let raw = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(card.payload)) as? [String: Any], let meals = raw["meals"] else { return .conflict("饮食草稿不完整。") }
            payload = ["date": draft.date, "meals": meals]
        case "weight_entry":
            guard let entry = AIWeightEntryPayload(json: card.payload) else { return .conflict("身体记录草稿不完整。") }
            var value: [String: Any] = ["date": entry.date, "kilograms": entry.kilograms]
            if let fat = entry.bodyFatPercentage { value["bodyFatPercentage"] = fat }
            if let waist = entry.waistCircumferenceCM { value["waistCircumferenceCM"] = waist }
            payload = value
        default: return .conflict("这张卡片不支持写入。")
        }
        return await perform(kind: card.card_type, payload: payload, evidence: card.evidence_refs,
                             intent: "card/" + card.card_id, baseline: nil, account: account)
    }

    private static func perform(kind: String, payload: [String: Any], evidence: [String], intent: String,
                                baseline: Any?, account: any ClubProposalAccount) async -> Outcome {
        if account.proposalPreview { return .fallback }
        guard let owner = account.proposalOwnerID else { return .conflict("请先登录后确认。") }
        let storageKey = "boji.proposal-attempt.\(owner)." + operationIdentity(owner: owner, intent: intent).key
        let generation = UserDefaults.standard.integer(forKey: storageKey)
        let identity = operationIdentity(owner: owner, intent: intent, generation: generation)
        do {
            var body: [String: Any] = ["kind": kind, "payload": payload, "evidence_refs": evidence, "idempotency_key": identity.key]
            if let baseline { body["baseline_days"] = baseline }
            let created = try await account.proposalRequest(path: "/me/ai/proposals", method: "POST",
                body: JSONSerialization.data(withJSONObject: body), expectedUserID: owner)
            guard created.statusCode == 200 else { return errorOutcome(created.data) }
            let proposal = try JSONDecoder().decode(ClubProposalCreatedResponse.self, from: created.data)
            if proposal.status == "succeeded" { return .confirmed }
            guard proposal.status == "awaiting_confirmation" else {
                UserDefaults.standard.set(generation + 1, forKey: storageKey)
                return .conflict("提案已过期或失效，请重新核对后重试。")
            }
            let type = ["plan_change_proposal": "PlanReschedule.Confirm", "meal_draft": "Meal.Create", "weight_entry": "BodyWeight.Create"][kind]!
            let command: [String: Any] = ["commandId": identity.command, "type": type,
                "payload": ["proposalId": proposal.proposalId], "actor": "user"]
            let response = try await account.proposalRequest(path: "/me/commands", method: "POST",
                body: JSONSerialization.data(withJSONObject: command), expectedUserID: owner)
            guard response.statusCode == 200 else {
                if response.statusCode == 409 { UserDefaults.standard.set(generation + 1, forKey: storageKey) }
                return errorOutcome(response.data)
            }
            MutationReceipts130.capture(response.data, owner: owner)
            let result = try JSONDecoder().decode(ClubCommandResponse.self, from: response.data)
            return result.status == "succeeded" ? .confirmed : .conflict("尚未确认保存，请重试。")
        } catch {
            // Never apply a second local mutation after an ambiguous HTTP outcome.
            return .conflict("暂未取得保存结果。请联网重试，同一操作不会重复写入。")
        }
    }

    private static func errorOutcome(_ data: Data) -> Outcome {
        let message = (try? JSONDecoder().decode(ClubCommandErrorResponse.self, from: data))?.error
        return .conflict(message ?? "操作未确认，请稍后重试。")
    }
}

// MARK: - Phase 1: Domain Command 客户端（训练生命周期 + 直接记录）
//
// 与提案确认共用同一约定：稳定 commandId（队列持久化，重试复用）、服务端
// data_operations 幂等兜底。命令是唯一权威写入口（P0-1 收敛）；功能未开放或
// 未登录时调用方根本不入队，沿用旧的全量同步写路径。

/// Phase 1 命令类型（服务端 commands.php 白名单，与 account-server/public/training-commands.php 对应）。
enum DomainCommandType {
    static let sessionStart = "Training.SessionStart"
    static let sessionFinish = "Training.SessionFinish"
    static let logSet = "Training.LogSet"
    static let bodyWeightCreateDirect = "BodyWeight.CreateDirect"
    static let mealCreateDirect = "Meal.CreateDirect"
    static let correctSet = "Training.CorrectSet"
}

struct DomainCommandOutcome: Equatable {
    /// URLErrors that mean the request never reached the server: retrying while
    /// offline must not count against the retry schedule.
    static let offlineURLErrorCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost,
        .cannotConnectToHost, .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff,
    ]

    enum Kind: Equatable { case confirmed, deferred, offline, conflict(String) }
    let kind: Kind
    /// SessionStart 命中已存在的进行中会话时，服务端返回的会话信息。
    var resumeSessionID: String?
    var resumeDate: String?
}

@MainActor
enum DomainCommands {
    /// 稳定操作身份：与提案同步同一约定——同一意图重试复用同一 commandId。
    static func identity(owner: Int, intent: String) -> (key: String, command: String) {
        ClubProposalSync.operationIdentity(owner: owner, intent: intent)
    }

    static func startPayload(date: String, sessionID: UUID, day: DayLog? = nil) -> [String: JSONValue] {
        var p: [String: JSONValue] = ["date": .string(date), "session_id": .string(sessionID.uuidString.lowercased())]
        if let day { p["exercises"] = finishPayload(date: date, day: day, sessionID: sessionID, savedAt: Date())["exercises"] }
        return p
    }

    /// 训练完成快照：只携带当前会话的动作与组；服务端按稳定 ID 合并，未见动作原样追加。
    static func finishPayload(date: String, day: DayLog, sessionID: UUID, savedAt: Date) -> [String: JSONValue] {
        let started = (day.workoutStartedAt ?? savedAt).timeIntervalSinceReferenceDate
        let ended = (day.workoutEndedAt ?? savedAt).timeIntervalSinceReferenceDate
        var exercises: [JSONValue] = []
        for exercise in day.exercises where exercise.workoutSessionID == nil || exercise.workoutSessionID == sessionID {
            var sets: [JSONValue] = []
            for set in exercise.sets {
                var entry: [String: JSONValue] = [
                    "id": .string(set.id.uuidString.lowercased()),
                    "weight": .number(set.weight),
                    "reps": .number(Double(set.reps)),
                    "completed": .bool(set.completed)
                ]
                if let seconds = set.durationSeconds { entry["duration_seconds"] = .number(Double(seconds)) }
                sets.append(.object(entry))
            }
            exercises.append(.object([
                "id": .string(exercise.id.uuidString.lowercased()),
                "name": .string(exercise.name),
                "muscle": .string(exercise.muscle),
                "sets": .array(sets)
            ]))
        }
        return [
            "date": .string(date),
            "session_id": .string(sessionID.uuidString.lowercased()),
            "started_at": .number(started),
            "ended_at": .number(ended),
            "saved_at": .number(savedAt.timeIntervalSinceReferenceDate),
            "exercises": .array(exercises)
        ]
    }

    static func bodyWeightPayload(date: String, kilograms: Double, bodyFatPercentage: Double?,
                                  waistCircumferenceCM: Double?, recordedAt: Date) -> [String: JSONValue] {
        var payload: [String: JSONValue] = [
            "date": .string(date),
            "kilograms": .number(kilograms),
            "recorded_at": .number(recordedAt.timeIntervalSinceReferenceDate)
        ]
        if let bodyFatPercentage { payload["bodyFatPercentage"] = .number(bodyFatPercentage) }
        if let waistCircumferenceCM { payload["waistCircumferenceCM"] = .number(waistCircumferenceCM) }
        return payload
    }

    /// 发送命令。只有明确的服务端回答才改变队列状态：
    /// 200+succeeded → confirmed；409/未确认 → conflict（放弃并提示，不静默）；
    /// 网络异常或非 409 错误 → deferred（保留队列，按同一 commandId 重试）。
    static func send(commandID: String, type: String, payload: [String: JSONValue], owner: Int,
                     account: any ClubProposalAccount) async -> DomainCommandOutcome {
        let body: [String: JSONValue] = [
            "commandId": .string(commandID), "type": .string(type),
            "payload": .object(payload), "actor": .string("user")
        ]
        guard let data = try? JSONEncoder().encode(body) else { return DomainCommandOutcome(kind: .deferred) }
        do {
            let response = try await account.proposalRequest(path: "/me/commands", method: "POST", body: data, expectedUserID: owner)
            guard response.statusCode == 200 else {
                if [400, 403, 409, 422, 426].contains(response.statusCode) {
                    let message = (try? JSONDecoder().decode(ClubCommandErrorResponse.self, from: response.data))?.error ?? "操作未确认，请重试。"
                    return DomainCommandOutcome(kind: .conflict(message))
                }
                return DomainCommandOutcome(kind: .deferred)
            }
            struct Ack: Decodable {
                var status: String?
                var resume: Bool?
                var session_id: String?
                var date: String?
                enum CodingKeys: String, CodingKey { case status, resume, session_id, date }
            }
            guard let ack = try? JSONDecoder().decode(Ack.self, from: response.data), ack.status == "succeeded" else {
                return DomainCommandOutcome(kind: .conflict("尚未确认执行，请重试。"))
            }
            return DomainCommandOutcome(kind: .confirmed, resumeSessionID: ack.session_id, resumeDate: ack.date)
        } catch {
            // 响应丢失按未确认处理：命令留在队列中按同一 commandId 重试，服务端幂等兜底。
            // 明确的"请求未发出"类错误单独标记：离线重试不累计失败次数，避免
            // 前台 12 分钟断网就把命令打成 blocked。
            if let urlError = error as? URLError, DomainCommandOutcome.offlineURLErrorCodes.contains(urlError.code) {
                return DomainCommandOutcome(kind: .offline)
            }
            return DomainCommandOutcome(kind: .deferred)
        }
    }
}
