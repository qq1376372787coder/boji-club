import XCTest
@testable import BojiClub

/// 卡片协议 v1 契约测试：fixtures 与 backend/card_composer.py 产出逐字段对应。
/// 服务端契约样例变化时，这里的失败即代表两端契约漂移。
@MainActor
final class AICardContractTests: XCTestCase {

    private func decode(_ json: String) throws -> AICardEnvelope {
        try JSONDecoder().decode(AICardEnvelope.self, from: Data(json.replacingOccurrences(of: "2026-10-25T00:00:00+08:00", with: ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))).utf8))
    }

    func testTodayTrainingFullPayloadDecodes() throws {
        let json = """
        {"card_id":"card-abc123","card_type":"today_training","schema_version":1,"title":"今日训练",
         "payload":{"date":"2026-10-24","display_name":"今日训练安排","exercise_count":3,"total_sets":10,
                    "estimated_minutes":30,"estimation_basis":"按 10 组、每组约 3 分钟估算"},
         "actions":[{"action_id":"start_training","label":"开始训练","kind":"navigate"},
                    {"action_id":"view_plan","label":"查看计划","kind":"navigate"}],
         "evidence_refs":["day/2026-10-24"],
         "created_at":"2026-10-24T09:30:00+08:00","expires_at":"2026-10-25T00:00:00+08:00"}
        """
        let card = try decode(json)
        XCTAssertEqual(card.card_type, "today_training")
        XCTAssertEqual(card.schema_version, 1)
        XCTAssertTrue(AICardRegistry.isRenderable(card))
        XCTAssertFalse(card.isExpired)
        XCTAssertEqual(card.actions.map(\.action_id), ["start_training", "view_plan"])
        XCTAssertEqual(card.payloadDate, "2026-10-24")
        let payload = try XCTUnwrap(AITodayTrainingPayload(json: card.payload))
        XCTAssertEqual(payload.exerciseCount, 3)
        XCTAssertEqual(payload.totalSets, 10)
        XCTAssertEqual(payload.estimatedMinutes, 30)
        XCTAssertFalse(payload.isEmpty)
    }

    func testTodayTrainingEmptyStateDecodes() throws {
        let json = """
        {"card_id":"card-emp","card_type":"today_training","schema_version":1,"title":"今日训练",
         "payload":{"date":"2026-10-24","empty":true,"reason":"no_planned_session",
                    "hint":"今天没有已安排的训练。可以安排一次，或把今天留给恢复。"},
         "actions":[{"action_id":"create_plan","label":"创建安排","kind":"navigate"}],
         "evidence_refs":[],"created_at":null,"expires_at":null}
        """
        let card = try decode(json)
        let payload = try XCTUnwrap(AITodayTrainingPayload(json: card.payload))
        XCTAssertTrue(payload.isEmpty)
        XCTAssertEqual(payload.reason, "no_planned_session")
        XCTAssertNotNil(payload.hint)
    }

    func testTrainingProgressPayloadDecodes() throws {
        let json = """
        {"card_id":"card-tp","card_type":"training_progress","schema_version":1,"title":"近期训练进度",
         "payload":{"window_start":"2026-10-18","window_end":"2026-10-24","training_days":3,
                    "completed_sets":42,"confirmed_sessions":3},
         "actions":[{"action_id":"view_records","label":"查看记录","kind":"navigate"}],
         "evidence_refs":["day/2026-10-23","day/2026-10-21","day/2026-10-19"],
         "created_at":"2026-10-24T09:30:00+08:00","expires_at":"2026-10-25T00:00:00+08:00"}
        """
        let card = try decode(json)
        let payload = try XCTUnwrap(AITrainingProgressPayload(json: card.payload))
        XCTAssertEqual(payload.trainingDays, 3)
        XCTAssertEqual(payload.completedSets, 42)
        XCTAssertEqual(payload.confirmedSessions, 3)
        XCTAssertFalse(payload.isEmpty)
    }

    func testInsightPayloadDecodes() throws {
        let json = """
        {"card_id":"card-ins","card_type":"insight","schema_version":1,"title":"训练节奏",
         "payload":{"text":"近 7 天已确认 2 个训练日、共 36 组。","window_days":7,
                    "training_days":2,"completed_sets":36,"evidence_dates":["2026-10-23","2026-10-22"]},
         "actions":[{"action_id":"view_records","label":"查看记录","kind":"navigate"}],
         "evidence_refs":["day/2026-10-23","day/2026-10-22"],
         "created_at":"2026-10-24T09:30:00+08:00","expires_at":"2026-10-25T00:00:00+08:00"}
        """
        let card = try decode(json)
        let payload = try XCTUnwrap(AIInsightCardPayload(json: card.payload))
        XCTAssertEqual(payload.text, "近 7 天已确认 2 个训练日、共 36 组。")
        XCTAssertEqual(payload.windowDays, 7)
    }

    func testUnknownCardTypeIsNotRenderable() throws {
        let json = """
        {"card_id":"card-x","card_type":"future_card","schema_version":1,"title":"?",
         "payload":{},"actions":[],"evidence_refs":[],"created_at":null,"expires_at":null}
        """
        XCTAssertFalse(AICardRegistry.isRenderable(try decode(json)))
    }

    func testFutureSchemaVersionIsNotRenderable() throws {
        let json = """
        {"card_id":"card-v2","card_type":"today_training","schema_version":2,"title":"今日训练",
         "payload":{},"actions":[],"evidence_refs":[],"created_at":null,"expires_at":null}
        """
        XCTAssertFalse(AICardRegistry.isRenderable(try decode(json)))
    }

    func testFutureExpiryIsNotExpired() throws {
        let json = """
        {"card_id":"card-old","card_type":"today_training","schema_version":1,"title":"今日训练",
         "payload":{"date":"2026-10-24"},
         "actions":[{"action_id":"start_training","label":"开始训练","kind":"navigate"}],
         "evidence_refs":[],"created_at":"2026-10-24T09:30:00+08:00","expires_at":"2026-10-25T00:00:00+08:00"}
        """
        XCTAssertFalse(try decode(json).isExpired, "未到期的卡片不应判为过期")
    }

    func testRouterIgnoresUnknownAndExpiredActions() throws {
        let expiredJSON = """
        {"card_id":"card-e","card_type":"today_training","schema_version":1,"title":"今日训练",
         "payload":{"date":"2026-10-24"},
         "actions":[{"action_id":"start_training","label":"开始训练","kind":"navigate"}],
         "evidence_refs":[],"created_at":null,"expires_at":"2000-01-01T00:00:00+08:00"}
        """
        let expired = try decode(expiredJSON)
        XCTAssertTrue(expired.isExpired)
        var opened = false
        XCTAssertFalse(AICardActionRouter.handle(
            expired.actions[0], card: expired, requestDate: "2026-10-24",
            openDestination: { _ in opened = true }))
        XCTAssertFalse(opened, "过期卡片的动作必须被拒绝")

        let unknownJSON = """
        {"card_id":"card-u","card_type":"today_training","schema_version":1,"title":"今日训练",
         "payload":{"date":"2026-10-24"},
         "actions":[{"action_id":"delete_everything","label":"危险","kind":"domain_command"}],
         "evidence_refs":[],"created_at":null,"expires_at":null}
        """
        let unknown = try decode(unknownJSON)
        XCTAssertFalse(AICardActionRouter.handle(
            unknown.actions[0], card: unknown, requestDate: "2026-10-24",
            openDestination: { _ in opened = true }))
        XCTAssertFalse(opened, "白名单外的动作必须被拒绝")
    }

    func testRouterMapsWhitelistedActions() throws {
        let json = """
        {"card_id":"card-ok","card_type":"today_training","schema_version":1,"title":"今日训练",
         "payload":{"date":"2026-10-24"},
         "actions":[{"action_id":"view_plan","label":"查看计划","kind":"navigate"}],
         "evidence_refs":[],"created_at":null,"expires_at":null}
        """
        let card = try decode(json)
        var destination: ClubCoachAction?
        XCTAssertTrue(AICardActionRouter.handle(
            card.actions[0], card: card, requestDate: "2026-10-24",
            openDestination: { destination = $0 }))
        XCTAssertEqual(destination?.type, "plans")
        XCTAssertEqual(destination?.date, "2026-10-24")
    }

    func testCoachAnswerDecodesWithCardsAndWithoutCards() throws {
        let withCards = """
        {"answer":"今天的安排如下。","sources":[],"actions":[],
         "cards":[{"card_id":"card-1","card_type":"today_training","schema_version":1,"title":"今日训练",
                   "payload":{"date":"2026-10-24"},"actions":[],"evidence_refs":[],
                   "created_at":null,"expires_at":null}]}
        """
        let answer = try JSONDecoder().decode(ClubCoachAnswer.self, from: Data(withCards.utf8))
        XCTAssertEqual(answer.cards?.count, 1)

        let legacy = """
        {"answer":"旧服务端的回答没有卡片字段。","sources":[],"actions":[]}
        """
        let legacyAnswer = try JSONDecoder().decode(ClubCoachAnswer.self, from: Data(legacy.utf8))
        XCTAssertNil(legacyAnswer.cards, "旧服务端载荷必须照常解码（向后兼容）")
    }

    // MARK: - Phase 3 §4 起草卡（meal_draft / weight_entry）

    private let mealDraftJSON = """
    {"card_id":"card-draft-meal","card_type":"meal_draft","schema_version":1,"title":"待确认的饮食记录",
     "payload":{"date":"2026-10-25","meals":[{"name":"鸡胸肉","category":"午餐","calories":320,"protein":48}]},
     "actions":[{"action_id":"confirm_proposal","label":"确认记录","kind":"confirm"},
                {"action_id":"dismiss_proposal","label":"不采用","kind":"dismiss"}],
     "evidence_refs":["day/2026-10-25"],"created_at":null,"expires_at":null}
    """

    func testMealDraftCardDecodeAndRenderable() throws {
        let card = try decode(mealDraftJSON)
        XCTAssertTrue(AICardRegistry.isRenderable(card))
        let payload = try XCTUnwrap(AIMealDraftPayload(json: card.payload))
        XCTAssertEqual(payload.date, "2026-10-25")
        XCTAssertEqual(payload.meals.count, 1)
        XCTAssertEqual(payload.meals[0].name, "鸡胸肉")
        XCTAssertEqual(payload.meals[0].calories, 320)
        XCTAssertTrue(payload.meals[0].nutritionText.contains("千卡"))
    }

    func testMealDraftMalformedPayloadFailsClosed() throws {
        let bad = mealDraftJSON.replacingOccurrences(of: "\"meals\":[{\"name\":\"鸡胸肉\",\"category\":\"午餐\",\"calories\":320,\"protein\":48}]},", with: "\"payload_removed\":1},")
        let card = try decode(bad)
        XCTAssertNil(AIMealDraftPayload(json: card.payload), "缺 meals 的载荷必须解析失败（fail-closed）")
    }

    private let weightDraftJSON = """
    {"card_id":"card-draft-weight","card_type":"weight_entry","schema_version":1,"title":"待确认的体重记录",
     "payload":{"date":"2026-10-25","kilograms":72.5,"bodyFatPercentage":18.2},
     "actions":[{"action_id":"confirm_proposal","label":"确认记录","kind":"confirm"},
                {"action_id":"dismiss_proposal","label":"不采用","kind":"dismiss"}],
     "evidence_refs":["day/2026-10-25"],"created_at":null,"expires_at":null}
    """

    func testWeightDraftCardDecodeAndRenderable() throws {
        let card = try decode(weightDraftJSON)
        XCTAssertTrue(AICardRegistry.isRenderable(card))
        let payload = try XCTUnwrap(AIWeightEntryPayload(json: card.payload))
        XCTAssertEqual(payload.primaryText, "72.5 kg")
        XCTAssertEqual(payload.extraText, "体脂 18.2%")
    }

    func testDraftActionsInWhitelistAndRouterGuards() {
        XCTAssertTrue(AICardRegistry.actionWhitelist.contains("confirm_proposal"))
        XCTAssertTrue(AICardRegistry.actionWhitelist.contains("dismiss_proposal"))
        let unknown = AICardAction(action_id: "wipe_records", label: "清空记录", kind: "confirm")
        XCTAssertFalse(AICardRegistry.actionWhitelist.contains(unknown.action_id),
                       "写入类外部动作永远不在白名单")
    }
}


extension AICardContractTests {
    func testMemoryHTTPEnvelopeDecodesEmptyAndNonemptyPages() throws {
        let empty = Data(#"{"columns":{"confirmed":[],"habits":[],"inferred":[]}}"#.utf8)
        XCTAssertTrue(try JSONDecoder().decode(ClubMemoryResponse.self, from: empty).columns.isEmpty)
        let populated = Data(#"{"columns":{"confirmed":[{"memory_id":"m1","kind":"goal","status":"active","origin":"extracted","content":"力量","confidence":100}],"habits":[],"inferred":[]}}"#.utf8)
        let response = try JSONDecoder().decode(ClubMemoryResponse.self, from: populated)
        XCTAssertEqual(response.columns.confirmed.first?.content, "力量")
    }

    @MainActor
    func testProposalRetryIdentitySeparatesOwnersIntentsAndNewAttempts() {
        let a = ClubProposalSync.operationIdentity(owner: 1, intent: "card/first")
        let retry = ClubProposalSync.operationIdentity(owner: 1, intent: "card/first")
        XCTAssertEqual(a.key, retry.key)
        XCTAssertEqual(a.command, retry.command)
        XCTAssertNotNil(UUID(uuidString: a.command))
        XCTAssertNotEqual(a.key, ClubProposalSync.operationIdentity(owner: 2, intent: "card/first").key)
        XCTAssertNotEqual(a.key, ClubProposalSync.operationIdentity(owner: 1, intent: "card/second").key)
        XCTAssertNotEqual(a.key, ClubProposalSync.operationIdentity(owner: 1, intent: "card/first", generation: 1).key)
    }
}


extension AICardContractTests {
    @MainActor
    func testInsightCacheResetsForAnotherOwner() async {
        let account = AccountService()
        var calls: [Int] = []
        let service = AIService(intelligenceTransport: { owner, _ in
            calls.append(owner)
            return Data(#"{"insight":{"id":"fixture","kind":"training","title":"训练","detail":"摘要","evidence":"fixture","priority":104,"evidence_refs":[]}}"#.utf8)
        })
        service.activateAccount(90101, account: account)
        await service.refreshHomeInsightIfNeeded()
        XCTAssertNotNil(service.homeInsight)
        service.deactivateAccount()
        XCTAssertNil(service.homeInsight)
        service.activateAccount(90102, account: account)
        await service.refreshHomeInsightIfNeeded()
        XCTAssertEqual(calls, [90101, 90102], "Same-day cache must be scoped to its owner")
    }

    @MainActor
    func testLateInsightResponseCannotPopulateAnotherAccount() async {
        let account = AccountService()
        var pending: CheckedContinuation<Data, Error>?
        let service = AIService(intelligenceTransport: { _, _ in
            try await withCheckedThrowingContinuation { pending = $0 }
        })
        service.activateAccount(90201, account: account)
        let work = Task { await service.refreshHomeInsightIfNeeded() }
        for _ in 0..<20 { if pending != nil { break }; await Task.yield() }
        XCTAssertNotNil(pending)
        service.activateAccount(90202, account: account)
        pending?.resume(returning: Data(#"{"insight":{"id":"foreign","kind":"training","title":"A的训练","detail":"A的内容","evidence":"fixture","priority":104,"evidence_refs":[]}}"#.utf8))
        await work.value
        XCTAssertNil(service.homeInsight, "A late response must not enter B's cache")
    }
}


@MainActor
private final class ProposalContractAccount: ClubProposalAccount {
    var proposalOwnerID: Int? = 901
    var proposalPreview = false
    var paths: [String] = []
    func proposalRequest(path: String, method: String, body: Data?, expectedUserID: Int) async throws -> AccountRawResponse {
        paths.append(path)
        XCTAssertEqual(expectedUserID, proposalOwnerID)
        let json = path == "/me/ai/proposals"
            ? #"{"proposal_id":"11111111-2222-3333-4444-555555555555","status":"awaiting_confirmation"}"#
            : #"{"status":"succeeded"}"#
        return AccountRawResponse(statusCode: 200, data: Data(json.replacingOccurrences(of: "2026-10-25T00:00:00+08:00", with: ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))).utf8))
    }
}

extension AICardContractTests {
    @MainActor
    func testSchedulePreviewCreatesOnlyProposalUntilFinalConfirmation() async throws {
        let account = ProposalContractAccount()
        let prepared = try await ClubProposalSync.prepareScheduleMoves(
            [ClubScheduleMove(from: "2026-10-26", to: "2026-10-28")], baseline: [:], operationID: "fixture", account: account)
        XCTAssertEqual(account.paths, ["/me/ai/proposals"], "Preview must never send a command")
        let result = await ClubProposalSync.confirmScheduleMoves(prepared, account: account)
        XCTAssertEqual(result, .confirmed)
        XCTAssertEqual(account.paths, ["/me/ai/proposals", "/me/commands"])
    }
}

@MainActor
final class ClubCoachSessionTests: XCTestCase {
    func testSendRequestConsumedOnceAcrossRendering() {
        let session = ClubCoachSession()
        XCTAssertFalse(session.takePendingSend())
        session.sendRequest += 1
        XCTAssertTrue(session.takePendingSend())
        XCTAssertFalse(session.takePendingSend(), "Recreating the conversation view must not resubmit")
        session.sendRequest += 1
        XCTAssertTrue(session.takePendingSend())
        session.reset()
        XCTAssertFalse(session.takePendingSend())
    }

    func testConversationSelectionRestoresDraftAndScroll() {
        let owner = 987_654_301
        let first = UUID().uuidString.lowercased(), second = UUID().uuidString.lowercased()
        defer {
            ClubCoachDraftStorage.clear(owner: owner, conversation: first)
            ClubCoachDraftStorage.clear(owner: owner, conversation: second)
        }
        let session = ClubCoachSession(conversation: first, question: "尚未发送的第一段")
        session.selectConversation(first, owner: owner)
        session.scrollAnchor = "earlier-job-id"
        session.selectConversation(second, owner: owner)
        session.question = "第二段草稿"
        session.selectConversation(first, owner: owner)
        XCTAssertEqual(session.question, "尚未发送的第一段")
        XCTAssertEqual(session.scrollAnchor, "earlier-job-id")
        XCTAssertFalse(session.followLatest, "Reading history should not jump to latest after a mode switch")
        XCTAssertEqual(ClubCoachDraftStorage.load(owner: owner, conversation: second), "第二段草稿")
    }

    func testNewConversationKeepsDraftUnderOriginalConversation() {
        let owner = 987_654_302
        let original = UUID().uuidString.lowercased()
        let session = ClubCoachSession(conversation: original, question: "保留这段草稿")
        defer { ClubCoachDraftStorage.clear(owner: owner, conversation: original) }
        session.newConversation(owner: owner, keepDraft: true)
        XCTAssertNotEqual(session.conversation, original)
        XCTAssertEqual(session.question, "")
        XCTAssertEqual(ClubCoachDraftStorage.load(owner: owner, conversation: original), "保留这段草稿")
        session.selectConversation(original, owner: owner)
        XCTAssertEqual(session.question, "保留这段草稿")
    }

    func testDiscardDoesNotResurrectDraft() {
        let owner = 987_654_303
        let original = UUID().uuidString.lowercased()
        ClubCoachDraftStorage.save("已保存旧草稿", owner: owner, conversation: original)
        let session = ClubCoachSession(conversation: original, question: "现在放弃")
        session.newConversation(owner: owner, keepDraft: false)
        XCTAssertEqual(ClubCoachDraftStorage.load(owner: owner, conversation: original), "")
        session.selectConversation(original, owner: owner)
        XCTAssertEqual(session.question, "")
    }

    func testAccountResetClearsTransientConversationState() {
        let session = ClubCoachSession(question: "上一账号草稿")
        session.scrollAnchor = "private-history-anchor"
        session.contextDays = 7
        session.error = "上一账号错误"
        session.sendRequest = 4
        _ = session.takePendingSend()
        session.reset()
        XCTAssertEqual(session.question, "")
        XCTAssertNil(session.scrollAnchor)
        XCTAssertNil(session.error)
        XCTAssertEqual(session.contextDays, 14)
        XCTAssertFalse(session.takePendingSend())
    }
}

@MainActor
final class ClubCoachDraftErasureTests: XCTestCase {
    func testErasureRemovesIndexedAndLegacyDraftsForExactOwnerOnly() throws {
        let suite = "boji-ui-draft-erasure-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = UUID().uuidString.lowercased(), legacy = UUID().uuidString.lowercased()
        let other = UUID().uuidString.lowercased(), preview = UUID().uuidString.lowercased()
        ClubCoachDraftStorage.save("要删除的草稿", owner: 1, conversation: first, defaults: defaults)
        defaults.set("无索引的旧草稿", forKey: "club-coach-draft.v1.1." + legacy)
        ClubCoachDraftStorage.save("另一个账号", owner: 12, conversation: other, defaults: defaults)
        ClubCoachDraftStorage.save("开发预览账号", owner: -1001, conversation: preview, defaults: defaults)

        ClubCoachDraftStorage.erase(owner: 1, defaults: defaults)

        XCTAssertEqual(ClubCoachDraftStorage.load(owner: 1, conversation: first, defaults: defaults), "")
        XCTAssertEqual(ClubCoachDraftStorage.load(owner: 1, conversation: legacy, defaults: defaults), "")
        XCTAssertNil(defaults.object(forKey: "club-coach-draft-index.v1.1"))
        XCTAssertTrue(ClubCoachDraftStorage.conversations(owner: 1, defaults: defaults).isEmpty)
        XCTAssertEqual(ClubCoachDraftStorage.load(owner: 12, conversation: other, defaults: defaults), "另一个账号")
        XCTAssertEqual(ClubCoachDraftStorage.load(owner: -1001, conversation: preview, defaults: defaults), "开发预览账号")
    }

    func testNegativePreviewOwnerErasureAndRepeatedErasureAreSafe() throws {
        let suite = "boji-ui-preview-erasure-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preview = UUID().uuidString.lowercased(), other = UUID().uuidString.lowercased()
        ClubCoachDraftStorage.save("预览草稿", owner: -1001, conversation: preview, defaults: defaults)
        ClubCoachDraftStorage.save("真实账号草稿", owner: 1001, conversation: other, defaults: defaults)

        ClubCoachDraftStorage.erase(owner: -1001, defaults: defaults)
        ClubCoachDraftStorage.erase(owner: -1001, defaults: defaults)

        XCTAssertEqual(ClubCoachDraftStorage.load(owner: -1001, conversation: preview, defaults: defaults), "")
        XCTAssertNil(defaults.object(forKey: "club-coach-draft-index.v1.-1001"))
        XCTAssertEqual(ClubCoachDraftStorage.load(owner: 1001, conversation: other, defaults: defaults), "真实账号草稿")
    }
}
