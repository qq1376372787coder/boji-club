import XCTest
import AVFoundation
import UIKit
import ImageIO
import CryptoKit
@testable import BojiClub

/// Phase 2 §3.2–3.3 contract tests: SSE framing, ordered dedupe, gap resync,
/// reconnect with `after_seq`, and the 410 snapshot fallback. The transport is
/// scripted, so no server or network is required.
@MainActor
final class AIRunStreamTests: XCTestCase {

    // MARK: framing

    func testParserHandlesCommentsMultiLineAndEmptyData() {
        var parser = SSEFrameParser()
        XCTAssertNil(parser.consume(line: ": heartbeat"))
        XCTAssertNil(parser.consume(line: "id: 7"))
        XCTAssertNil(parser.consume(line: "event: assistant.text.delta"))
        XCTAssertNil(parser.consume(line: "data: {\"a\":1}"))
        XCTAssertNil(parser.consume(line: "data: second"))
        XCTAssertNil(parser.consume(line: "data:"))
        let frame = try! XCTUnwrap(parser.consume(line: ""))
        XCTAssertEqual(frame.id, 7)
        XCTAssertEqual(frame.event, "assistant.text.delta")
        XCTAssertEqual(frame.data, "{\"a\":1}\nsecond\n")
    }

    func testParserCRLFAndBlankWithoutData() {
        var parser = SSEFrameParser()
        XCTAssertNil(parser.consume(line: ""))
        XCTAssertNil(parser.consume(line: "data: one\r"))
        let frame = try! XCTUnwrap(parser.consume(line: "\r"))
        XCTAssertEqual(frame.event, "message", "unnamed events default to message")
        XCTAssertEqual(frame.data, "one")
        XCTAssertNil(parser.consume(line: ""), "an empty dispatch is ignored")
    }

    // MARK: reducer

    func testReducerDeduplicatesSnapshotAndCards() throws {
        var reducer = AIRunReducer()
        XCTAssertTrue(reducer.apply(event(1, "run.created", ["status": .string("queued"), "trace_id": .string("abc")])))
        XCTAssertTrue(reducer.apply(event(2, "assistant.text.delta", ["delta": .string("你")])))
        XCTAssertFalse(reducer.apply(event(2, "assistant.text.delta", ["delta": .string("你")])), "duplicate seq ignored")
        XCTAssertTrue(reducer.apply(event(3, "assistant.text.snapshot", ["text": .string("你好")])))
        XCTAssertEqual(reducer.text, "你好", "snapshot replaces replayed deltas")
        let card = """
        {"card_id":"c1","card_type":"today_training","schema_version":1,"title":"今日训练",
         "payload":{"date":"2026-10-25"},"actions":[],"evidence_refs":[]}
        """
        let cardValue = try JSONDecoder().decode(JSONValue.self, from: Data(card.utf8))
        XCTAssertTrue(reducer.apply(event(4, "card.upsert", ["card": cardValue])))
        XCTAssertEqual(reducer.cards["c1"]?.card_type, "today_training")
        XCTAssertTrue(reducer.apply(event(5, "run.completed", ["final_message_id": .string("m")])))
        XCTAssertTrue(reducer.completed)
        XCTAssertEqual(reducer.traceID, "abc")
    }

    func testReducerSignalsResyncOnGap() {
        var reducer = AIRunReducer()
        XCTAssertTrue(reducer.apply(event(1, "run.created", [:])))
        XCTAssertTrue(reducer.apply(event(2, "assistant.text.delta", ["delta": .string("a")])))
        XCTAssertFalse(reducer.apply(event(4, "assistant.text.delta", ["delta": .string("c")])), "gap is not applied")
        XCTAssertTrue(reducer.needsResync)
        XCTAssertEqual(reducer.lastSeq, 2)
        XCTAssertEqual(reducer.text, "a")
    }

    func testReducerFailureEventIsVisible() {
        var reducer = AIRunReducer()
        _ = reducer.apply(event(1, "run.failed", ["message": .string("模型暂不可用")]))
        XCTAssertEqual(reducer.error, "模型暂不可用")
        XCTAssertEqual(reducer.status, "failed")
    }

    // MARK: store reconnect

    func testReconnectUsesAfterSeqAndDoesNotDuplicateText() async throws {
        let fake = FakeTransport()
        fake.createResult = AIRunCreateResponse(run_id: "run-1", message_id: "msg-1", status: "queued",
                                                stream_url: "/events", last_event_seq: 1, trace_id: "trace-1", idempotent: false)
        fake.eventScripts = [
            lines([frame(1, "run.created", ["status": .string("queued")]),
                   frame(2, "assistant.text.delta", ["delta": .string("你")]),
                   frame(3, "assistant.text.delta", ["delta": .string("好")])]),
            // Replays seq 2–3 (dedupe) and then finishes.
            lines([frame(2, "assistant.text.delta", ["delta": .string("你")]),
                   frame(3, "assistant.text.delta", ["delta": .string("好")]),
                   frame(4, "assistant.text.delta", ["delta": .string("！")]),
                   frame(5, "run.completed", ["final_message_id": .string("msg-1")])]),
        ]
        // EOF now checks server authority before reconnecting. Keep the first
        // snapshot nonterminal to exercise actual event replay on connection two.
        fake.snapshots = [AIRunSnapshot(run: .init(run_id: "run-1", message_id: "msg-1", status: "running", last_event_seq: 3, trace_id: "trace-1", terminal: false, error_code: nil), message: nil, cards: []), snapshot(status: "completed", terminal: true, answer: "你好！")]

        let store = AIRunStreamStore()
        store.useTransport(fake)
        let completion = await store.start(input: input(), conversation: "conv-1", owner: 7)

        XCTAssertEqual(completion?.coach.answer, "你好！")
        XCTAssertEqual(fake.eventAfterSeq, [0, 3], "reconnect resumes from the last processed seq")
        XCTAssertEqual(store.streamText, "你好！", "replayed deltas must not duplicate")
        XCTAssertEqual(store.phase, .saving)
    }

    func testCancelledOldCreationCannotReplaceNewConversation() async throws {
        defer { AIRunPendingStore.erase(owner: 8123); AIRunResumeStore.erase(owner: 8123) }
        let fake = FakeTransport(); fake.createDelays = [200_000_000, 0]
        fake.snapshots = [snapshot(status: "completed", terminal: true, answer: "新会话回答")]
        let store = AIRunStreamStore(); store.useTransport(fake)
        let old = Task { await store.start(input: input(), conversation: UUID().uuidString.lowercased(), owner: 8123) }
        while fake.createdClientIDs.isEmpty { await Task.yield() }
        let next = UUID().uuidString.lowercased()
        let result = await store.start(input: input(), conversation: next, owner: 8123)
        _ = await old.value
        XCTAssertEqual(result?.coach.answer, "新会话回答")
        XCTAssertEqual(store.conversationKey, next)
        XCTAssertEqual(store.phase, .saving)
    }

    func testCleanEOFRecoversCompletedAnswerWithoutTerminalEvent() async throws {
        let fake = FakeTransport()
        fake.eventScripts = [lines([frame(1, "run.created", ["status": .string("running")])])]
        fake.snapshots = [snapshot(status: "completed", terminal: true, answer: "EOF后恢复的真实回答")]
        let store = AIRunStreamStore(); store.useTransport(fake)
        let result = await store.start(input: input(), conversation: UUID().uuidString.lowercased(), owner: 7123)
        XCTAssertEqual(result?.coach.answer, "EOF后恢复的真实回答")
        XCTAssertEqual(fake.createdClientIDs.count, 1)
        XCTAssertEqual(fake.eventAfterSeq.count, 1)
        XCTAssertEqual(fake.snapshotCalls, 1)
    }

    func testResyncOnExpiredLog() async throws {
        let fake = FakeTransport()
        fake.createResult = AIRunCreateResponse(run_id: "run-2", message_id: "msg-2", status: "queued",
                                                stream_url: "/events", last_event_seq: 1, trace_id: "trace-2", idempotent: false)
        fake.forceStatus = 410
        fake.snapshots = [snapshot(status: "completed", terminal: true, answer: "快照回答")]

        let store = AIRunStreamStore()
        store.useTransport(fake)
        let completion = await store.start(input: input(), conversation: "conv-2", owner: 7)

        XCTAssertEqual(completion?.coach.answer, "快照回答")
        XCTAssertEqual(fake.snapshotCalls, 1)
    }

    func testCreateHTTPRejectionsNeverFallback() async {
        for status in [400, 401, 403, 409, 422, 429] {
            let fake = FakeTransport()
            fake.createError = AccountRunTransport.creationError(status: status, data: Data("{\"error\":\"请求被拒绝\"}".utf8))
            let store = AIRunStreamStore()
            store.useTransport(fake)
            _ = await store.start(input: input(), conversation: "http-\(status)", owner: 771)
            XCTAssertFalse(store.allowsLegacyFallback)
            XCTAssertFalse(store.outcomeUnknown)
        }
    }

    func testCreateHTTPServerErrorsKeepIdentity() async {
        for status in [500, 502, 503, 504] {
            let conversation = "uncertain-\(status)"
            let fake = FakeTransport()
            fake.createError = AccountRunTransport.creationError(status: status, data: Data())
            let store = AIRunStreamStore()
            store.useTransport(fake)
            _ = await store.start(input: input(), conversation: conversation, owner: 772)
            XCTAssertTrue(store.outcomeUnknown)
            XCTAssertFalse(store.allowsLegacyFallback)
            XCTAssertNotNil(AIRunPendingStore.load(owner: 772, conversation: conversation))
        }
        AIRunPendingStore.erase(owner: 772)
    }

    func testFoodIdentityEditInvalidatesOldNutrition() {
        var item = FoodComponent(name: "米饭", amount: 100, unit: "g", calories: 130, protein: 2.6, carbs: 28, fat: 0.3, basis: "visible", details: [])
        item.sourceDatabase = "USDA_FDC_SR_LEGACY"
        item.confidenceLow = 100; item.confidenceHigh = 160; item.edibleGrams = 100
        item.resize(to: 200)
        XCTAssertEqual(item.confidenceLow, 200)
        XCTAssertEqual(item.edibleGrams, 200)
        item.rename(to: "鸡胸肉")
        XCTAssertEqual(item.calories, 0)
        XCTAssertNil(item.sourceDatabase)
        XCTAssertTrue(item.uncertaintyFlags?.contains("nutrition_unknown") == true)
        item.editNutrient(\.calories, value: 165)
        XCTAssertNil(item.sourceDatabase)
        XCTAssertEqual(item.sourceKind, "user_input")
    }

    func testCreateUnavailableSignalsFallback() async {
        let fake = FakeTransport()
        fake.createError = AIRunStreamError.unavailable("off")
        let store = AIRunStreamStore()
        store.useTransport(fake)
        let completion = await store.start(input: input(), conversation: "conv-3", owner: 7)
        XCTAssertNil(completion)
        XCTAssertFalse(store.didCreateRun, "caller may fall back to the polling path")
        XCTAssertNotNil(store.error)
    }

    func testLostCreateResponseRetriesSameIdentity() async throws {
        let owner = 91
        let conversation = "conv-91"
        AIRunPendingStore.erase(owner: owner)
        let fake = FakeTransport()
        fake.createErrors = [URLError(.timedOut), URLError(.networkConnectionLost)]
        fake.eventScripts = [lines([frame(1, "run.completed", ["final_message_id": .string("msg-91")])])]
        fake.snapshots = [snapshot(status: "completed", terminal: true, answer: "recovered")]

        let store = AIRunStreamStore()
        store.useTransport(fake)
        let completion = await store.start(input: input(conversation: conversation), conversation: conversation, owner: owner)

        XCTAssertEqual(completion?.coach.answer, "recovered")
        XCTAssertEqual(Set(fake.createdClientIDs).count, 1, "all retries use one operation identity")
        XCTAssertEqual(fake.createdClientIDs.count, 3, "two lost responses, then success")
        XCTAssertTrue(store.didCreateRun)
        XCTAssertFalse(store.outcomeUnknown)
        AIRunPendingStore.erase(owner: owner)
    }

    func testUnknownCreateOutcomeKeepsPendingAndNeverFallsBack() async {
        let owner = 92
        let conversation = "conv-92"
        AIRunPendingStore.erase(owner: owner)
        let fake = FakeTransport()
        fake.createErrors = [URLError(.timedOut), URLError(.timedOut), URLError(.timedOut)]
        let store = AIRunStreamStore()
        store.useTransport(fake)
        let first = await store.start(input: input(conversation: conversation), conversation: conversation, owner: owner)
        XCTAssertNil(first)
        XCTAssertTrue(store.outcomeUnknown, "caller must not use a new polling job")
        XCTAssertFalse(store.didCreateRun)
        let pending = AIRunPendingStore.load(owner: owner, conversation: conversation)
        XCTAssertNotNil(pending, "identity must survive the unknown outcome")
        XCTAssertEqual(fake.createdClientIDs.count, 3)
        XCTAssertEqual(Set(fake.createdClientIDs).count, 1)

        // A later foreground retry reuses the same identity and succeeds.
        let retry = FakeTransport()
        retry.eventScripts = [lines([frame(1, "run.completed", ["final_message_id": .string("msg-92")])])]
        retry.snapshots = [snapshot(status: "completed", terminal: true, answer: "after retry")]
        let store2 = AIRunStreamStore()
        store2.useTransport(retry)
        let second = await store2.start(input: input(conversation: conversation), conversation: conversation, owner: owner)
        XCTAssertEqual(second?.coach.answer, "after retry")
        XCTAssertEqual(Set(retry.createdClientIDs), Set(fake.createdClientIDs))
        AIRunPendingStore.erase(owner: owner)
    }

    func testCompletedWithoutMessageKeepsVerifyingThenShowsError() async {
        let owner = 93
        let conversation = "conv-93"
        AIRunPendingStore.erase(owner: owner)
        let fake = FakeTransport()
        fake.eventScripts = [lines([frame(1, "run.completed", ["final_message_id": .string("msg-93")])])]
        fake.snapshots = [snapshotWithoutMessage(), snapshotWithoutMessage(), snapshotWithoutMessage()]
        let store = AIRunStreamStore()
        store.useTransport(fake)
        let completion = await store.start(input: input(conversation: conversation), conversation: conversation, owner: owner)

        XCTAssertNil(completion)
        XCTAssertEqual(fake.snapshotCalls, 3, "completed-without-message must be re-verified")
        XCTAssertEqual(store.phase, .failed)
        XCTAssertNotNil(store.error, "never silently drop the turn")
        AIRunPendingStore.erase(owner: owner)
    }

    private func input(conversation: String) -> AIInput {
        AIInput(kind: "coach", date: "2026-10-25",
                payload: ["question": .string("你好"), "conversation_id": .string(conversation)])
    }

    private func snapshotWithoutMessage() -> AIRunSnapshot {
        AIRunSnapshot(
            run: .init(run_id: "run", message_id: "msg-93", status: "completed", last_event_seq: 1,
                       trace_id: "trace", terminal: true, error_code: nil),
            message: nil, cards: [])
    }

    func testLiveTimelineRowIsAppendedAfterHistory() {
        let request = AIRequest(id: "job-1", kind: "coach", date: "2026-10-25",
                                payload: ["question": .string("one")])
        let second = AIRequest(id: "job-2", kind: "coach", date: "2026-10-25",
                               payload: ["question": .string("two")])
        let jobs = [AILocalJob(id: "job-1", digest: "a", request: request),
                    AILocalJob(id: "job-2", digest: "b", request: second)]
        let rows = ClubCoachTimelineBuilder.rows(turns: jobs, liveActive: true)
        XCTAssertEqual(rows.count, 3)
        if case .job(let first) = rows[0] { XCTAssertEqual(first.id, "job-1") } else { XCTFail("history first") }
        if case .live = rows[2] { } else { XCTFail("live turn must be last") }
        let idle = ClubCoachTimelineBuilder.rows(turns: jobs, liveActive: false)
        XCTAssertEqual(idle.count, 2)
        if case .live = idle.last! { XCTFail("no live row when idle") }
    }

    // MARK: fixtures

    private func input() -> AIInput {
        AIInput(kind: "coach", date: "2026-10-25",
                payload: ["question": .string("你好"), "conversation_id": .string("conv-1")])
    }

    private func event(_ seq: Int, _ type: String, _ data: [String: JSONValue]) -> AIRunEvent {
        AIRunEvent(run_id: "run", seq: seq, event_id: "e\(seq)", type: type, ts: "", data: .object(data))
    }

    private func frame(_ seq: Int, _ type: String, _ data: [String: JSONValue]) -> [String] {
        let envelope: [String: JSONValue] = [
            "run_id": .string("run"), "seq": .number(Double(seq)), "event_id": .string("e\(seq)"),
            "type": .string(type), "ts": .string("2026-10-25T00:00:00Z"), "data": .object(data),
        ]
        let raw = try! JSONEncoder().encode(JSONValue.object(envelope))
        let json = String(data: raw, encoding: .utf8)!
        return ["id: \(seq)", "event: \(type)", "data: \(json)", ""]
    }

    private func lines(_ frames: [[String]]) -> AsyncThrowingStream<String, Error> {
        let flat = frames.flatMap { $0 }
        return AsyncThrowingStream { continuation in
            for line in flat { continuation.yield(line) }
            continuation.finish()
        }
    }

    private func snapshot(status: String, terminal: Bool, answer: String) -> AIRunSnapshot {
        AIRunSnapshot(
            run: .init(run_id: "run", message_id: "msg-1", status: status, last_event_seq: 5,
                       trace_id: "trace", terminal: terminal, error_code: nil),
            message: .init(id: 1, role: "assistant", content: answer,
                           coach: ClubCoachAnswer(answer: answer, sources: [], actions: [])),
            cards: []
        )
    }
}

@MainActor
private final class FakeTransport: AIRunStreamTransport {
    var createResult = AIRunCreateResponse(run_id: "run", message_id: "msg", status: "queued",
                                           stream_url: "/events", last_event_seq: 1, trace_id: "trace", idempotent: false)
    var createError: Error?
    var createErrors: [Error] = []
    var createDelays: [UInt64] = []
    var createdClientIDs: [String] = []
    var eventScripts: [AsyncThrowingStream<String, Error>] = []
    var forceStatus: Int?
    var eventAfterSeq: [Int] = []
    var snapshotCalls = 0
    var snapshots: [AIRunSnapshot] = []

    func create(input: AIInput, conversation: String, clientMessageID: String, owner: Int) async throws -> AIRunCreateResponse {
        createdClientIDs.append(clientMessageID)
        if !createDelays.isEmpty { try await Task.sleep(nanoseconds: createDelays.removeFirst()) }
        if !createErrors.isEmpty { throw createErrors.removeFirst() }
        if let createError { throw createError }
        return createResult
    }

    func events(runID: String, afterSeq: Int, owner: Int, traceID: String?) async throws -> (lines: AsyncThrowingStream<String, Error>, status: Int) {
        eventAfterSeq.append(afterSeq)
        if let forceStatus { return (AsyncThrowingStream { $0.finish() }, forceStatus) }
        let stream = eventScripts.isEmpty ? AsyncThrowingStream<String, Error> { $0.finish() } : eventScripts.removeFirst()
        return (stream, 200)
    }

    func snapshot(runID: String, owner: Int) async throws -> AIRunSnapshot {
        snapshotCalls += 1
        return snapshots.isEmpty ? AIRunSnapshot(
            run: .init(run_id: runID, message_id: "msg", status: "running", last_event_seq: 0,
                       trace_id: "trace", terminal: false, error_code: nil),
            message: nil, cards: []) : snapshots.removeFirst()
    }

    func cancel(runID: String, owner: Int) async {}
}

@MainActor
final class Workout125Tests: XCTestCase {
    func testPlanTargetsNeverBecomeActualByClickingAnEmptyRow() {
        let target = TrainingSet(weight:40,reps:10,actualEntered:false)
        XCTAssertThrowsError(try TrainingSetDraft125(target).saved(over:target,completed:true))
    }
    func testDecimalWeightAndActualCountAreSavedTogether() throws {
        let target = TrainingSet(weight:40,reps:10,actualEntered:false)
        var draft = TrainingSetDraft125(target);draft.weight="12.5";draft.amount="8"
        let saved=try draft.saved(over:target,completed:true)
        XCTAssertEqual(saved.weight,12.5);XCTAssertEqual(saved.reps,8)
        XCTAssertTrue(saved.validCompletion);XCTAssertTrue(saved.hasActualEntry)
        XCTAssertEqual(saved.id,target.id)
    }
    func testCommaAndQuarterKilogramsPreserved() throws {
        let target=TrainingSet();var draft=TrainingSetDraft125(target)
        draft.weight="1,25";draft.amount="6"
        XCTAssertEqual(try draft.saved(over:target,completed:true).weight,1.25)
    }
    func testFractionalCountsAndMissingWeightCannotSilentlySave() {
        let target=TrainingSet();var draft=TrainingSetDraft125(target)
        draft.weight="20";draft.amount="1.5"
        XCTAssertThrowsError(try draft.saved(over:target,completed:true))
        draft.weight="";draft.amount="8"
        XCTAssertThrowsError(try draft.saved(over:target,completed:true))
    }
    func testTimedEntryDoesNotRequireWeightOrInventReps() throws {
        let target=TrainingSet(durationSeconds:30,actualEntered:false)
        var draft=TrainingSetDraft125(target);draft.amount="45"
        let saved=try draft.saved(over:target,completed:true)
        XCTAssertEqual(saved.durationSeconds,45);XCTAssertEqual(saved.reps,0);XCTAssertTrue(saved.validCompletion)
    }
    func testFuturePlanEditingNeverCompletesTheSet() throws {
        let target=TrainingSet(weight:40,reps:10,actualEntered:false)
        let saved=try TrainingSetDraft125(target,plan:true).saved(over:target,completed:true,plan:true)
        XCTAssertFalse(saved.completed);XCTAssertFalse(saved.hasActualEntry)
    }
    func testSummaryExcludesTargetsAndFalseActualFlags() {
        let done=TrainingSet(weight:12.5,reps:8,completed:true,actualEntered:true)
        let unrecorded=TrainingSet(weight:40,reps:10,actualEntered:false)
        let invalid=TrainingSet(weight:100,reps:10,completed:true,actualEntered:false)
        var day=DayLog();day.exercises=[Exercise(name:"卧推",muscle:"胸",sets:[done,unrecorded]),Exercise(name:"卧推",muscle:"胸",sets:[invalid])]
        let facts=WorkoutFacts125(day)
        XCTAssertEqual(facts.completed,1);XCTAssertEqual(facts.planned,3)
        XCTAssertEqual(facts.registeredExercises,1);XCTAssertEqual(facts.volume,100)
        XCTAssertEqual(facts.exercises.map(\.ordinal),[1,2]);XCTAssertEqual(facts.exercises[1].completed,0)
    }
    func testInvalidOutputHasUserFacingMessageAndKeepsDiagnosticsSeparate() {
        XCTAssertFalse(AIRunFailureText125.message(code:"invalid_output").contains("invalid_output"))
        XCTAssertTrue(AIRunFailureText125.message(code:"RESULT_PERSIST_FAILED").contains("回执"))
    }
}

@MainActor
final class ProfilePlan126Tests: XCTestCase {
    private let today = ClubDates.date(fromKey: "2030-01-07")!
    private func movement(_ owner: String = "plan-a") -> Exercise {
        Exercise(name: "平板杠铃卧推", muscle: "胸部", sets: [TrainingSet(weight: 12.5, reps: 8, actualEntered: false)], planID: owner)
    }
    private func fixture() -> (ManagedPlan, [String: DayLog]) {
        let a = movement(); let b = movement()
        let days = ["2030-01-07": DayLog(exercises: [a]), "2030-01-14": DayLog(exercises: [b])]
        let p = MemberProfile()
        let v = ClubPlanVersion(id: "plan-a", recordedAt: today, source: "manual", title: "我的训练", start: "2030-01-07", duration: 14,
            sessions: days.keys.sorted().map { .init(date: $0, label: "训练", exercises: ClubPlanChangeRules.snapshot(days[$0]!.exercises)) }, requestedProfile: p, adoptedProfile: p,
            nutrition: NutritionTarget.estimate(p), previousIDs: [], scopeDates: days.keys.sorted(), retainedDates: [])
        return (ManagedPlan(version: v), days)
    }
    private func edited(_ p: ManagedPlan, _ days: [String: DayLog]) -> [PlanEditDay126] {
        var rows = PlanEditRules126.draft(plan: p, days: days, now: today)
        rows[0].exercises[0].sets[0].weight = 15
        return rows
    }
    func testEditOnlyChangesSelectedPlanAndNeverWritesActuals() throws {
        var (p, days) = fixture(); days["2030-01-07"]!.exercises.append(movement("plan-b"))
        let other = days["2030-01-07"]!.exercises[1]
        let result = try PlanEditRules126.prepare(plan: p, draft: edited(p,days), baseline: days, current: days, newID: "new-plan", now: today)
        let saved = try XCTUnwrap(result["2030-01-07"])
        XCTAssertEqual(saved.exercises.first(where: { $0.planID == "plan-b" })?.id, other.id)
        let new = try XCTUnwrap(saved.exercises.first(where: { $0.planID == "new-plan" }))
        XCTAssertEqual(new.sets[0].weight,15); XCTAssertFalse(new.sets[0].completed); XCTAssertFalse(new.sets[0].hasActualEntry)
        XCTAssertNotEqual(new.id,days["2030-01-07"]!.exercises[0].id)
    }
    func testConcurrentTrainingChangeRejectsWholeTransaction() {
        let (p, days) = fixture(); var concurrent = days
        concurrent["2030-01-14"]!.exercises[0].sets[0].weight = 22.5
        XCTAssertThrowsError(try PlanEditRules126.prepare(plan: p, draft: edited(p,days), baseline: days, current: concurrent, newID: "new", now: today))
    }
    func testStartedDayIsRetainedAndCannotBeForcedEditable() throws {
        let (p, original) = fixture(); var days = original
        days["2030-01-14"]!.workoutStartedAt = today
        var rows = edited(p,days)
        XCTAssertFalse(rows[1].editable)
        let result = try PlanEditRules126.prepare(plan: p, draft: rows, baseline: days, current: days, newID: "new", now: today)
        XCTAssertTrue(try CloudMerge.same(result["2030-01-14"]!,days["2030-01-14"]!))
        rows[1] = .init(id: rows[1].id,date: rows[1].date,exercises: rows[1].exercises,editable: true)
        XCTAssertThrowsError(try PlanEditRules126.prepare(plan: p, draft: rows, baseline: days, current: days, newID: "new", now: today))
    }
    func testReadonlyTamperingIsRejected() {
        let (p, original) = fixture(); var days = original
        days["2030-01-14"]!.workoutSavedAt = today
        var rows = edited(p,days); rows[1].exercises[0].sets[0].reps = 99
        XCTAssertThrowsError(try PlanEditRules126.prepare(plan: p, draft: rows, baseline: days, current: days, newID: "new", now: today))
    }
    func testMoveConflictsWithOtherPlanAreRejected() {
        let (p, original) = fixture(); var days = original
        days["2030-01-08"] = DayLog(exercises: [movement("plan-b")])
        var rows = edited(p,days); rows[0].date = "2030-01-08"
        XCTAssertThrowsError(try PlanEditRules126.prepare(plan: p, draft: rows, baseline: days, current: days, newID: "new", now: today))
    }
    func testMoveKeepsSourceHistoryAndTargetsNewDate() throws {
        let (p, days) = fixture(); var rows = edited(p,days); rows[0].date = "2030-01-08"
        let result = try PlanEditRules126.prepare(plan: p, draft: rows, baseline: days, current: days, newID: "new", now: today)
        XCTAssertTrue(result["2030-01-07"]!.exercises.isEmpty)
        XCTAssertEqual(result["2030-01-08"]!.exercises[0].sets[0].weight,15)
        XCTAssertEqual(result["2030-01-07"]!.planActions?.first?.planID,p.id)
    }
    func testDuplicateTargetsAndInvalidNumbersAreRejected() {
        let (p, days) = fixture(); var rows = edited(p,days)
        rows[1].date = rows[0].date
        XCTAssertThrowsError(try PlanEditRules126.prepare(plan: p, draft: rows, baseline: days, current: days, newID: "new", now: today))
        rows = edited(p,days); rows[0].exercises[0].sets[0].weight = .nan
        XCTAssertThrowsError(try PlanEditRules126.prepare(plan: p, draft: rows, baseline: days, current: days, newID: "new", now: today))
        rows = edited(p,days); rows[0].exercises[0].sets[0].actualEntered = true
        XCTAssertThrowsError(try PlanEditRules126.prepare(plan: p, draft: rows, baseline: days, current: days, newID: "new", now: today))
    }
    func testUnchangedOrEmptyPlanDoesNotCreateVersion() {
        let (p, days) = fixture(); var rows = PlanEditRules126.draft(plan: p,days: days,now: today)
        XCTAssertThrowsError(try PlanEditRules126.prepare(plan: p,draft: rows,baseline: days,current: days,newID: "new",now: today))
        for i in rows.indices { rows[i].exercises = [] }
        XCTAssertThrowsError(try PlanEditRules126.prepare(plan: p,draft: rows,baseline: days,current: days,newID: "new",now: today))
    }
    func testFollowingWeekdayOnlyUsesEditableRowsAndFreshIDs() {
        let (p, days) = fixture(); var rows = edited(p,days)
        let previousID = rows[0].exercises[0].id
        XCTAssertEqual(PlanEditRules126.applyFollowing(source: rows[0].id,rows: &rows),1)
        XCTAssertEqual(rows[1].exercises[0].sets[0].weight,15)
        XCTAssertNotEqual(rows[1].exercises[0].id,previousID)
        rows[1] = .init(id:rows[1].id,date:rows[1].date,exercises:rows[1].exercises,editable:false)
        XCTAssertEqual(PlanEditRules126.applyFollowing(source:rows[0].id,rows:&rows),0)
    }
    func testConcurrentMealDataSurvivesPlanEdit() throws {
        let (p, days) = fixture(); var current = days
        current["2030-01-07"]!.bodyWeight = BodyWeightEntry(kilograms: 66, updatedAt: today)
        let result = try PlanEditRules126.prepare(plan:p,draft:edited(p,days),baseline:days,current:current,newID:"new",now:today)
        XCTAssertEqual(result["2030-01-07"]!.bodyWeight?.kilograms,66)
    }
    func testConcurrentArchiveRequiresFreshReview() {
        let (p, days) = fixture(); var current = days
        current["2030-01-07"]!.planActions = [.init(id:"archive",planID:p.id,kind:"archived",createdAt:today,exerciseIDs:[])]
        XCTAssertThrowsError(try PlanEditRules126.prepare(plan:p,draft:edited(p,days),baseline:days,current:current,newID:"new",now:today))
    }
    func testEndedPlanCannotBeEdited() {
        let (p, days) = fixture(); var current = days
        current["2030-01-07"]!.planActions = [.init(id:"end",planID:p.id,kind:"ended",createdAt:today,exerciseIDs:[])]
        XCTAssertThrowsError(try PlanEditRules126.prepare(plan:p,draft:edited(p,days),baseline:days,current:current,newID:"new",now:today))
    }
    func testBMIDoesNotInventUnknownMeasurements() {
        var p = MemberProfile(); p.factState = [:]
        XCTAssertNil(ProfileBodyRules126.bmi(profile:p))
        p.factState = ["age_years":.init(sourceKind:"confirmed"),"height_cm":.init(sourceKind:"confirmed"),"profile_weight_kg":.init(sourceKind:"confirmed")]
        p.height = 175; p.weight = 70
        XCTAssertEqual(ProfileBodyRules126.bmi(profile:p),22.9)
        p.age = 16; XCTAssertNil(ProfileBodyRules126.bmi(profile:p))
        p.age = 28; p.nutritionContext = "孕期或哺乳期"; XCTAssertNil(ProfileBodyRules126.bmi(profile:p))
    }
    func testLatestMeasurementSkipsFutureAndDeletedRows() {
        let id = UUID(); var old = DayLog(); old.bodyWeight = .init(kilograms:65,updatedAt:today)
        var removed = DayLog(); removed.bodyWeight = .init(kilograms:66,updatedAt:today,id:id); removed.deletedBodyMeasurementIDs = [id.uuidString]
        var future = DayLog(); future.bodyWeight = .init(kilograms:99,updatedAt:today)
        let result = ProfileBodyRules126.latestMeasurement(["2030-01-05":old,"2030-01-06":removed,"2030-01-08":future],now:today)
        XCTAssertEqual(result?.value,65); XCTAssertEqual(result?.date,"2030-01-05")
    }
}

private final class Transport127: URLProtocol {
    static var respond: ((URLRequest) throws -> (Int, Data, Double))!
    private let lock = NSLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status,data,delay) = try Self.respond(request)
            DispatchQueue.global().asyncAfter(deadline: .now()+delay) { [weak self] in
                guard let self else { return }
                self.lock.lock(); let stopped=self.stopped; self.lock.unlock(); guard !stopped else { return }
                let response=HTTPURLResponse(url:self.request.url!,statusCode:status,httpVersion:"HTTP/1.1",headerFields:["Content-Type":"application/json"])!
                self.client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
                self.client?.urlProtocol(self,didLoad:data)
                self.client?.urlProtocolDidFinishLoading(self)
            }
        } catch { client?.urlProtocol(self,didFailWithError:error) }
    }
    override func stopLoading() { lock.lock(); stopped=true; lock.unlock() }
}

@MainActor
final class ChatStability127Tests: XCTestCase {
    private func data(owner: Int = 715) -> Data {
        Data("{\"user\":{\"id\":\(owner),\"phone_masked\":\"fixture\",\"club_number\":\"fixture\",\"onboarding_completed\":true,\"membership\":{\"active\":false}}}".utf8)
    }
    private func network() -> URLSession {
        let config=URLSessionConfiguration.ephemeral; config.protocolClasses=[Transport127.self];return URLSession(configuration:config)
    }
    func testAppleNotFoundKeepsServerVerifiedSessionInBothBuildConfigurations() async {
        let body=data();Transport127.respond={ _ in (200,body,0) }
        let credentials=MemoryAccountCredentials127(token:"fixture-token-A",appleUser:"fixture-apple")
        let session=network();defer{session.invalidateAndCancel()}
        let service=AccountService(networkSession:session,credentialStore:credentials,appleCredentialLookup:{ _ in .notFound })
        await service.restore()
        XCTAssertEqual(service.phase,.ready);XCTAssertEqual(service.user?.id,715)
        await service.checkAppleCredential(force:true)
        XCTAssertEqual(credentials.accessToken,"fixture-token-A");XCTAssertEqual(service.phase,.ready)
    }
    func testAppleRevocationStillInvalidatesSession() async {
        let body=data();Transport127.respond={ _ in (200,body,0) }
        let credentials=MemoryAccountCredentials127(token:"fixture",appleUser:"fixture-apple")
        let session=network();defer{session.invalidateAndCancel()}
        let service=AccountService(networkSession:session,credentialStore:credentials,appleCredentialLookup:{ _ in .revoked })
        await service.restore()
        XCTAssertEqual(service.phase,.ready, "passive Apple state must revalidate the app session")
        await service.checkAppleCredential(force:true)
        XCTAssertEqual(service.phase,.signedOut);XCTAssertNil(credentials.accessToken)
    }
    func testTransientMe401KeepsRevalidatedSession130() async {
        let body = data(); Transport127.respond = { _ in (200,body,0) }
        let credentials = MemoryAccountCredentials127(token:"fixture")
        let session = network(); defer { session.invalidateAndCancel() }
        let service = AccountService(networkSession:session,credentialStore:credentials); await service.restore()
        var calls = 0
        Transport127.respond = { _ in calls += 1; return calls == 1 ? (401,Data(),0) : (200,body,0) }
        do { _ = try await service.cloudRequest(path:"/me",expectedUserID:715); XCTFail("initial rejection must surface") } catch { }
        XCTAssertEqual(service.phase,.ready); XCTAssertEqual(credentials.accessToken,"fixture")
        XCTAssertEqual(calls,2)
    }
    func testBusiness401DoesNotEraseValidLogin() async {
        let body=data();Transport127.respond={ request in request.url!.path.hasSuffix("/me") ? (200,body,0) : (401,Data(),0) }
        let credentials=MemoryAccountCredentials127(token:"fixture")
        let session=network();defer{session.invalidateAndCancel()}
        let service=AccountService(networkSession:session,credentialStore:credentials)
        await service.restore()
        do { _ = try await service.cloudRequest(path:"/me/restricted",expectedUserID:715);XCTFail("401 must not become success") } catch { }
        XCTAssertEqual(service.phase,.ready);XCTAssertEqual(credentials.accessToken,"fixture")
    }
    func testAuthoritative401InvalidatesCurrentSession() async {
        let body=data();Transport127.respond={ _ in (200,body,0) }
        let credentials=MemoryAccountCredentials127(token:"fixture")
        let session=network();defer{session.invalidateAndCancel()}
        let service=AccountService(networkSession:session,credentialStore:credentials);await service.restore()
        Transport127.respond={ _ in (401,Data(),0) }
        do { _ = try await service.cloudRequest(path:"/me/restricted",expectedUserID:715);XCTFail("Invalid login cannot continue") } catch { }
        XCTAssertEqual(service.phase,.signedOut);XCTAssertNil(credentials.accessToken)
    }
    func testUnavailableAuthenticationCheckPreservesCredential() async {
        let body=data();Transport127.respond={ _ in (200,body,0) }
        let credentials=MemoryAccountCredentials127(token:"fixture")
        let session=network();defer{session.invalidateAndCancel()}
        let service=AccountService(networkSession:session,credentialStore:credentials);await service.restore()
        Transport127.respond={ request in
            if request.url!.path.hasSuffix("/me") { throw URLError(.notConnectedToInternet) }
            return (401,Data(),0)
        }
        do { _ = try await service.cloudRequest(path:"/me/restricted",expectedUserID:715) } catch { }
        XCTAssertEqual(service.phase,.ready);XCTAssertNotNil(credentials.accessToken)
    }
    func testLateStream401CannotLogOutNewAccount() async {
        let a=data(),b=data(owner:716)
        Transport127.respond={ request in
            if request.url!.path.hasSuffix("/events") { return (401,Data(),0.4) }
            return (200,request.value(forHTTPHeaderField:"Authorization")=="Bearer token-B" ? b:a,0)
        }
        let credentials=MemoryAccountCredentials127(token:"token-A")
        let session=network();defer{session.invalidateAndCancel()}
        let service=AccountService(networkSession:session,credentialStore:credentials);await service.restore()
        let old=Task { try? await service.cloudStream(path:"/me/events",expectedUserID:715,afterSeq:0) }
        try? await Task.sleep(for:.milliseconds(50));await service.logout()
        credentials.accessToken="token-B";await service.restore();_ = await old.value
        XCTAssertEqual(service.user?.id,716);XCTAssertEqual(service.phase,.ready);XCTAssertEqual(credentials.accessToken,"token-B")
    }
    func testLateRestoreFailureCannotReopenExplicitlyLoggedOutSession() async {
        Transport127.respond = { request in
            if request.url!.path.hasSuffix("/me") {
                Thread.sleep(forTimeInterval: 0.25)
                throw URLError(.notConnectedToInternet)
            }
            return (200, Data(), 0)
        }
        let credentials = MemoryAccountCredentials127(token: "fixture")
        let session = network(); defer { session.invalidateAndCancel() }
        let service = AccountService(networkSession: session, credentialStore: credentials)
        let old = Task { await service.restore() }
        try? await Task.sleep(for: .milliseconds(30))
        await service.logout(); await old.value
        XCTAssertEqual(service.phase, .signedOut)
        XCTAssertNil(service.user); XCTAssertNil(credentials.accessToken)
    }
    func testAppleForegroundChecksAreThrottled() async {
        var count=0;let body=data();Transport127.respond={ _ in (200,body,0) }
        let credentials=MemoryAccountCredentials127(token:"fixture",appleUser:"fixture-apple")
        let session=network();defer{session.invalidateAndCancel()}
        let service=AccountService(networkSession:session,credentialStore:credentials,appleCredentialLookup:{ _ in count+=1;return .authorized })
        await service.restore();for _ in 0..<5 { await service.checkAppleCredential() }
        XCTAssertEqual(count,1);await service.checkAppleCredential(force:true);XCTAssertEqual(count,2)
    }
    func testContextPurposesAcceptDailyAndReportWithoutOpeningArbitraryRanges() {
        XCTAssertEqual(ChatContextPurpose127.restored(payload: ["review_scope": .object(["kind": .string("daily")])]), .daily)
        XCTAssertEqual(ChatContextPurpose127.restored(payload: ["context_source": .object(["id": .string("fixture")])]), .contextContinue)
        XCTAssertEqual(ChatContextPurpose127.restored(payload: [:]), .dialogue)
        XCTAssertEqual(ChatContextPurpose127.restored(payload: [:], sourceSession: UUID()), .workout)
        XCTAssertTrue(ChatContextPurpose127.daily.accepts(days:1));XCTAssertTrue(ChatContextPurpose127.contextContinue.accepts(days:0))
        XCTAssertFalse(ChatContextPurpose127.dialogue.accepts(days:0));XCTAssertFalse(ChatContextPurpose127.dialogue.accepts(days:1))
        XCTAssertFalse(ChatContextPurpose127.workout.accepts(days:14));XCTAssertFalse(ChatContextPurpose127.daily.accepts(days:28))
    }
    func testActualDailyAndReportInputBuildersAcceptTheirTypedContext() throws {
        let service=AIService();let store=AppStore();let conversation=UUID().uuidString;let date=ClubDates.date(fromKey:"2020-01-15")!
        let daily=try service.coachInput(question:"帮我看看当天记录",conversation:conversation,history:[],through:date,contextDays:1,store:store,contextPurpose:.daily)
        XCTAssertEqual(daily.payload["days"]?.arrayValue?.count,1)
        let report=try service.coachInput(question:"继续解释这份报告",conversation:conversation,history:[],through:date,contextDays:0,store:store,contextPurpose:.contextContinue)
        XCTAssertEqual(report.payload["days"]?.arrayValue?.count,0)
        XCTAssertThrowsError(try service.coachInput(question:"普通对话",conversation:conversation,history:[],through:date,contextDays:0,store:store))
    }
    private func source() -> (DayLog,UUID,Date) {
        let date=ClubDates.date(fromKey:"2020-01-15")!, id=UUID()
        let session=WorkoutSession(id:id,startedAt:date,endedAt:date.addingTimeInterval(600),savedAt:date.addingTimeInterval(601))
        let exercise=Exercise(name:"卧推",muscle:"胸部",sets:[TrainingSet(weight:12.5,reps:8,completed:true,actualEntered:true)],libraryID:"fixture",workoutSessionID:id)
        return (DayLog(exercises:[exercise],workoutSessions:[session],activeWorkoutSessionID:id),id,date)
    }
    func testPresentationMetadataAndReceiptClockDoNotInvalidateWorkoutSource() throws {
        let (original,id,date)=source();var updated=original
        updated.exercises[0].imageURL="https://example.test/new-signed-image"
        updated.exercises[0].name="新的展示名称";updated.workoutSessions![0].savedAt=date.addingTimeInterval(602)
        let a=try XCTUnwrap(ConfirmedWorkoutSnapshot.make(owner:1,date:date,sessionID:id,day:original))
        let b=try XCTUnwrap(ConfirmedWorkoutSnapshot.make(owner:1,date:date,sessionID:id,day:updated))
        XCTAssertEqual(a.signature,b.signature)
    }
    func testTrueSetCorrectionAndPauseChangesInvalidateWorkoutSource() throws {
        let (original,id,date)=source();var updated=original
        let a=try XCTUnwrap(ConfirmedWorkoutSnapshot.make(owner:1,date:date,sessionID:id,day:original))
        updated.exercises[0].sets[0].reps=9
        XCTAssertNotEqual(a.signature,ConfirmedWorkoutSnapshot.make(owner:1,date:date,sessionID:id,day:updated)?.signature)
        updated=original;updated.workoutSessions![0].pauseIntervals=[.init(start:date.addingTimeInterval(10),end:date.addingTimeInterval(20))]
        XCTAssertNotEqual(a.signature,ConfirmedWorkoutSnapshot.make(owner:1,date:date,sessionID:id,day:updated)?.signature)
    }
    func testVoiceResultPreservesPrefixAndRejectsDifferentOwnerOrConversation() {
        let draft=VoiceDraft127(owner:7,conversation:"a",prefix:"已有草稿 @记录")
        XCTAssertEqual(draft.result(transcript:" 新的话 ",currentOwner:7,currentConversation:"a"),"已有草稿 @记录\n新的话")
        XCTAssertNil(draft.result(transcript:"新话",currentOwner:8,currentConversation:"a"))
        XCTAssertNil(draft.result(transcript:"新话",currentOwner:7,currentConversation:"b"))
        XCTAssertEqual(draft.result(transcript:"",currentOwner:7,currentConversation:"a"),draft.prefix)
    }
}

@MainActor final class MemberFeedback128Tests: XCTestCase {
    private let owner = 1280901
    override func tearDown() { FeedbackDraftStore128.erase(owner:owner); super.tearDown() }
    func testDraftRequiresTextOrAttachmentAndBoundsText() {
        var draft=FeedbackDraft128();XCTAssertFalse(draft.canSubmit)
        draft.text="  \n ";XCTAssertFalse(draft.canSubmit)
        draft.text="输入框遮挡";XCTAssertTrue(draft.canSubmit)
        draft.text=String(repeating:"字",count:4001);XCTAssertFalse(draft.canSubmit)
        draft.text="";draft.attachments=[.init(id:UUID().uuidString,mime:"image/jpeg",bytes:50,sha256:"fixture")];XCTAssertTrue(draft.canSubmit)
    }
    func testProtectedDraftRoundTripSeparatesOwnersAndKeepsSubmissionIdentity() throws {
        var draft=FeedbackDraft128();draft.text="保留的反馈";draft.pending=true;draft.metadata=["build":"128"]
        try FeedbackDraftStore128.save(draft,owner:owner,ticket:nil)
        let restored=FeedbackDraftStore128.load(owner:owner,ticket:nil)
        XCTAssertEqual(restored.id,draft.id);XCTAssertEqual(restored.text,draft.text);XCTAssertTrue(restored.pending);XCTAssertEqual(restored.metadata,draft.metadata)
        XCTAssertTrue(FeedbackDraftStore128.load(owner:owner+1,ticket:nil).text.isEmpty)
        XCTAssertTrue(FeedbackDraftStore128.load(owner:owner,ticket:UUID().uuidString).text.isEmpty)
        let resource=try FeedbackDraftStore128.folder(owner).resourceValues(forKeys:[.isExcludedFromBackupKey]);XCTAssertEqual(resource.isExcludedFromBackup,true)
    }
    func testPicturePreparationHasCorrectHashAndNoPersonalMetadata() throws {
        let image=UIGraphicsImageRenderer(size:CGSize(width:800,height:1200)).image { context in UIColor.red.setFill();context.fill(CGRect(x:0,y:0,width:800,height:1200)) }
        let original=CFDataCreateMutable(kCFAllocatorDefault,0)!
        let writer=try XCTUnwrap(CGImageDestinationCreateWithData(original,"public.jpeg" as CFString,1,nil))
        CGImageDestinationAddImage(writer,try XCTUnwrap(image.cgImage),[kCGImagePropertyGPSDictionary:[kCGImagePropertyGPSLatitude:10,kCGImagePropertyGPSLongitude:20],kCGImagePropertyExifDictionary:[kCGImagePropertyExifDateTimeOriginal:"2020:01:15 12:00:00",kCGImagePropertyExifUserComment:"private fixture metadata"]] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(writer))
        let attachment=try FeedbackMedia128.picture(original as Data,owner:owner)
        let data=try Data(contentsOf:attachment.url(owner:owner));XCTAssertLessThan(data.count,3*1024*1024)
        XCTAssertEqual(attachment.sha256,SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined())
        let source=try XCTUnwrap(CGImageSourceCreateWithData(data as CFData,nil));let p=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [String:Any]
        XCTAssertNil(p?[kCGImagePropertyGPSDictionary as String])
        let exif=p?[kCGImagePropertyExifDictionary as String] as? [String:Any]
        XCTAssertNil(exif?[kCGImagePropertyExifDateTimeOriginal as String]);XCTAssertNil(exif?[kCGImagePropertyExifUserComment as String])
    }
    func testInvalidPictureIsRejected() { XCTAssertThrowsError(try FeedbackMedia128.picture(Data("not-an-image".utf8),owner:owner)) }
    func testErrorResponseNeverLooksLikeSuccessfulSubmission() {
        XCTAssertThrowsError(try MemberFeedbackAPI128.decode(AccountRawResponse(statusCode:422,data:Data("{\"error\":\"视频过长\"}".utf8)),as:MemberFeedbackDetail128.self)) { error in XCTAssertEqual((error as? FeedbackHTTPError128)?.status,422) }
    }
    func testRetryMetadataIsFrozenAcrossSerialization() throws {
        var draft=FeedbackDraft128();draft.text="same payload";draft.metadata=["build":"128"];draft.pending=true
        let restored=try JSONDecoder().decode(FeedbackDraft128.self,from:JSONEncoder().encode(draft))
        XCTAssertEqual(restored.metadata?["build"],"128");XCTAssertEqual(restored.id,draft.id)
    }
    private func movie(seconds:Int) async throws -> URL {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".mp4")
        let writer=try AVAssetWriter(outputURL:url,fileType:.mp4)
        let input=AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:64,AVVideoHeightKey:64])
        let adaptor=AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32ARGB,kCVPixelBufferWidthKey as String:64,kCVPixelBufferHeightKey as String:64])
        writer.add(input);XCTAssertTrue(writer.startWriting());writer.startSession(atSourceTime:.zero)
        for n in 0..<seconds {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for:.milliseconds(5)) }
            var buffer:CVPixelBuffer?;CVPixelBufferCreate(kCFAllocatorDefault,64,64,kCVPixelFormatType_32ARGB,nil,&buffer)
            let pixel=try XCTUnwrap(buffer);CVPixelBufferLockBaseAddress(pixel,[]);memset(CVPixelBufferGetBaseAddress(pixel),170,CVPixelBufferGetDataSize(pixel));CVPixelBufferUnlockBaseAddress(pixel,[])
            XCTAssertTrue(adaptor.append(pixel,withPresentationTime:CMTime(value:Int64(n),timescale:1)))
        }
        writer.endSession(atSourceTime:CMTime(value:Int64(seconds),timescale:1));input.markAsFinished()
        await withCheckedContinuation { (c:CheckedContinuation<Void,Never>) in writer.finishWriting { c.resume() } }
        XCTAssertEqual(writer.status,.completed);return url
    }
    func testVideoTransformsToBoundedMP4() async throws {
        let input=try await movie(seconds:1);defer { try? FileManager.default.removeItem(at:input) }
        let output=try await FeedbackMedia128.video(input,owner:owner)
        XCTAssertEqual(output.mime,"video/mp4");XCTAssertLessThanOrEqual(output.bytes,20*1024*1024)
        let duration=try await AVURLAsset(url:output.url(owner:owner)).load(.duration).seconds
        XCTAssertGreaterThan(duration,0);XCTAssertLessThan(duration,2)
    }
    func testLongVideoIsRejectedBeforeUpload() async throws {
        let input=try await movie(seconds:62);defer { try? FileManager.default.removeItem(at:input) }
        do { _ = try await FeedbackMedia128.video(input,owner:owner);XCTFail("Long video cannot upload") } catch { XCTAssertTrue(error.localizedDescription.contains("60")) }
    }
}


@MainActor final class Experience130Tests: XCTestCase {
    func testStaleCloudSnapshotCannotEraseReplyButExplicitDeletionWins130() {
        let owner = Int.random(in: 9131000...9131999)
        let service = AIService(), account = AccountService(credentialStore:MemoryAccountCredentials127())
        service.activateAccount(owner, account:account)
        defer { _ = service.eraseAccountData(owner) }
        let id = UUID().uuidString.lowercased()
        let request = AIRequest(id:id,kind:"coach",date:"2026-10-27",payload:[:])
        var done = AILocalJob(id:id,digest:id,request:request)
        done.status = "succeeded"; done.result = AIResult(kind:"coach",notes:[])
        done.result?.coach = ClubCoachAnswer(answer:"已完成的回答",sources:[],actions:[])
        XCTAssertTrue(service.replaceCloudJobs([done]))
        var stale = done; stale.status = "running"; stale.result = nil
        XCTAssertTrue(service.replaceCloudJobs([stale]))
        XCTAssertEqual(service.jobs.first?.result?.coach?.answer,"已完成的回答")
        stale.status = "deleted"
        XCTAssertTrue(service.replaceCloudJobs([stale]))
        XCTAssertEqual(service.jobs.first?.status,"deleted")
    }
    func testAcceptedDraftClearsOnlyOnceAcrossSessionObjects130() {
        let owner = 9130003; defer { SubmittedDraftClears130.erase(owner:owner); SubmittedDraftClears130.erase(owner:owner+1) }
        let id = UUID().uuidString
        XCTAssertTrue(SubmittedDraftClears130.claim(owner:owner,messageID:id))
        XCTAssertFalse(SubmittedDraftClears130.claim(owner:owner,messageID:id))
        XCTAssertTrue(SubmittedDraftClears130.claim(owner:owner+1,messageID:id))
    }
    func testWeeklyCalendarMapsRealWeekdaysAndSkipsPastDays() {
        let start = ClubDates.date(fromKey: "2026-10-28")! // Wednesday
        var days = Array(repeating: ManualPlanDay(), count: 7)
        days[0].title = "周一"; days[2].title = "周三"; days[6].title = "周日"
        let draft = WeeklyPlanRules130.draft(days: days, start: start, title: "测试")
        XCTAssertEqual(draft.start, "2026-10-28")
        XCTAssertEqual(draft.days[0].title, "周三")
        XCTAssertEqual(draft.days[4].title, "周日")
        XCTAssertEqual(draft.days[5].title, "周一")
        XCTAssertEqual(draft.days[7].title, "周三")
        XCTAssertEqual(draft.dateKey(offset: 27), "2026-11-24")
    }
    func testIndependentMealsFromOneAIProposalSurviveMerge() throws {
        let a = Meal(name: "鸡蛋", category: "早餐", calories: 150, protein: 13, carbs: 1, fat: 10, sourceAIJobID: "same-proposal")
        let b = Meal(name: "米饭", category: "午餐", calories: 200, protein: 4, carbs: 44, fat: 1, sourceAIJobID: "same-proposal")
        let key = "2026-10-27"
        let state = SavedState(days: [key: DayLog(meals: [a,b])])
        let merged = try CloudMerge.merge(local: CloudState(state), remote: CloudState(state), base: nil)
        XCTAssertEqual(Set(merged.days[key]!.meals.map(\.id)), Set([a.id,b.id]))
    }
    func testWeeklyDraftRecoveryIsAccountScopedAndPreservesIdentity() throws {
        let owner = 9130001, other = 9130002
        defer { WeeklyPlanDraftStore130.erase(owner: owner); WeeklyPlanDraftStore130.erase(owner: other) }
        let value = WeeklyPlanDraft130(days: Array(repeating: ManualPlanDay(), count: 7), start: Date(), title: "测试草稿", repeats: true, identity: UUID())
        try WeeklyPlanDraftStore130.save(value, owner: owner, template: nil)
        XCTAssertEqual(try WeeklyPlanDraftStore130.load(owner: owner, template: nil)?.identity, value.identity)
        XCTAssertNil(try WeeklyPlanDraftStore130.load(owner: other, template: nil))
        WeeklyPlanDraftStore130.erase(owner: owner)
        XCTAssertNil(try WeeklyPlanDraftStore130.load(owner: owner, template: nil))
    }
    func testRecurrenceExtendsStablyPausesAndPreservesActualTraining() throws {
        let store = AppStore(); let owner = Int.random(in: 9130100...9130999)
        store.activateAccount(owner)
        defer { _ = store.eraseAccountData(owner) }
        let today = ClubDates.calendar.startOfDay(for: Date())
        var days = Array(repeating: ManualPlanDay(), count: 7)
        for index in days.indices { days[index].movements = [ManualPlanMovement(name: "卧推", muscle: "胸")] }
        let draft = WeeklyPlanRules130.draft(days: days, start: today, title: "自动续排测试")
        let baseline = Dictionary(uniqueKeysWithValues: (0..<28).compactMap { draft.dateKey(offset: $0).map { ($0, DayLog()) } })
        XCTAssertTrue(store.saveWeeklyPlan130(draft: draft, weekdays: days, repeats: true, baseline: baseline, replacing: nil), store.message ?? "")
        let future = ClubDates.calendar.date(byAdding: .day, value: 40, to: today)!
        let advance = ClubDates.calendar.date(byAdding: .day, value: 27, to: today)!
        store.extendWeeklyPlans130(now: advance)
        let ids = store.log(for: future).exercises.map(\.id)
        XCTAssertEqual(ids.count, 1)
        store.extendWeeklyPlans130(now: advance)
        XCTAssertEqual(store.log(for: future).exercises.map(\.id), ids)
        XCTAssertTrue(store.setWeeklyRepeat130(templateID: draft.id, enabled: false))
        let far = ClubDates.calendar.date(byAdding: .day, value: 80, to: today)!
        store.extendWeeklyPlans130(now: far)
        XCTAssertTrue(store.log(for: far).exercises.isEmpty)
        XCTAssertEqual(store.log(for: future).exercises.map(\.id), ids, "pause retains existing dates")
        let exercise = try XCTUnwrap(store.log(for: today).exercises.first)
        var actual = exercise.sets[0]; actual.completed = true; actual.actualEntered = true
        XCTAssertTrue(store.updateSet(actual, exerciseID: exercise.id, on: today))
        var changed = days; changed[WeeklyPlanRules130.index(today)].movements[0].name = "深蹲"
        let replacement = WeeklyPlanRules130.draft(days: changed, start: today, title: "修改")
        let newerBaseline = Dictionary(uniqueKeysWithValues: (0..<28).compactMap { replacement.dateKey(offset: $0).map { ($0, store.state.days[$0] ?? DayLog()) } })
        XCTAssertTrue(store.saveWeeklyPlan130(draft: replacement, weekdays: changed, repeats: true, baseline: newerBaseline, replacing: draft.id))
        XCTAssertEqual(store.log(for: today).exercises.first?.name, "卧推")
        XCTAssertTrue(store.log(for: today).exercises.first?.sets.first?.completed == true)
    }
    func testNaturalWeekAndRollingRangeAreDistinct() {
        let wednesday = ClubDates.date(fromKey: "2026-10-21")!
        let week = ClubReviewScope.make(.completedCalendarWeek, through: wednesday)
        let rolling = ClubReviewScope.make(.rolling7, through: wednesday)
        XCTAssertEqual(week.from, "2026-10-12"); XCTAssertEqual(week.to, "2026-10-18")
        XCTAssertEqual(rolling.from, "2026-10-15"); XCTAssertEqual(rolling.to, "2026-10-21")
    }
}
