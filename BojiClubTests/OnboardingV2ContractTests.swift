import XCTest
import UIKit
import SwiftUI
@testable import BojiClub

@MainActor
final class OnboardingV2ContractTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    func testOnboardingStateDecodesUnknownSchemaAndEmptyMaps() throws {
        let json = """
        {"schema_version":2,"session":{"id":"00f975d1-a20a-40ae-97c2-51dce60e5647","schema_version":2,"revision":3,
          "status":"collecting","task_kind":"plan_create","conversation_id":"8b6e1f50-2a2b-4f31-9bc0-23c42cd4a7bb",
          "first_job_id":null,"first_proposal_id":null,"first_command_id":null,"created_at":null,"updated_at":null,
          "completed_at":null,"deferred_at":null},
         "profile_revision":0,"confirmed_facts":{},"draft":{"task_kind":"plan_create","fields":{},"skipped":[],"artifacts":{},"first_plan":{}},
         "skipped_fields":[],"required_fields":["goal","training_days"],"required_missing_fields":["goal"],
         "plan_ready":false,"capabilities":{"assist_available":true,"assist_budget_remaining":8,"initial_plan_available":false,
          "initial_plan_jobs_used":0,"initial_plan_limit":5,"membership_active":false},
         "content":{"welcome_title":"今天，想先做什么？","welcome_body":"选一件小事开始","task_labels":{"plan_create":"帮我安排训练"},"tips":[]},
         "recent_messages":[],"assist_usage":{"used":2,"limit":10,"remaining":8},"enabled":true,"empty":false,
         "prompt_version":"boji.onboarding_assist.v1"}
        """
        let state = try decode(OnboardingV2State.self, json)
        XCTAssertEqual(state.schemaVersion, 2)
        XCTAssertEqual(state.session?.taskKind, "plan_create")
        XCTAssertEqual(state.session?.revision, 3)
        XCTAssertEqual(state.requiredMissing, ["goal"])
        XCTAssertTrue(state.capabilities.assistAvailable)
        XCTAssertEqual(state.capabilities.assistBudgetRemaining, 8)
        XCTAssertEqual(state.content.label(.planCreate), "帮我安排训练")
    }

    func testEmptyFactsEndpointShapeDecodes() throws {
        let json = #"{"schema_version":1,"revision":0,"facts":{},"definitions":{}}"#
        let document = try decode(ProfileFactsDocument.self, json)
        XCTAssertEqual(document.revision, 0)
        XCTAssertTrue(document.facts.isEmpty)
    }

    func testUnknownFactStateStopsDefaultNumbersFromEnteringRules() {
        var profile = MemberProfile()
        profile.age = 28; profile.height = 175; profile.weight = 68
        profile.factState = [:]
        XCTAssertFalse(profile.hasConfirmedBasics)
        XCTAssertNil(BodyProfileAssessment.bmi(profile))
        let target = NutritionTarget.estimate(profile)
        XCTAssertTrue(target.generalGuidanceOnly == true)
        XCTAssertEqual(target.caloriesMin, 0)
        XCTAssertEqual(target.calculationVersion, 3)
    }

    func testDraftProvenanceIsNotConfirmed() {
        XCTAssertFalse(ProfileFactMeta(sourceKind:"draft",confirmedAt:nil,revision:nil).known)
        XCTAssertFalse(ProfileFactMeta(sourceKind:"model_candidate",confirmedAt:nil,revision:nil).known)
    }
    func testTrainingPlanWithConfirmedConditionsDoesNotInventBodyFacts() {
        var p=MemberProfile();p.goal="增肌塑形";p.experience="新手";p.venue="在家";p.equipment="哑铃"
        p.trainingDays=[1,3,5];p.daysPerWeek=3;p.sessionMinutes=30;p.ageGroup="adult"
        p.factState=Dictionary(uniqueKeysWithValues:["goal","experience","venue","equipment","training_days","session_minutes","age_group"].map { ($0,ProfileFactMeta(sourceKind:"confirmed",confirmedAt:nil,revision:1)) })
        XCTAssertTrue(p.canPrepareTrainingPlan)
        XCTAssertFalse(p.hasConfirmedBasics)
        XCTAssertNil(p.v2PlanProfile["age"]);XCTAssertNil(p.v2PlanProfile["height"]);XCTAssertNil(p.v2PlanProfile["weight"])
        p.daysPerWeek=2;XCTAssertFalse(p.canPrepareTrainingPlan)
        p.daysPerWeek=3;p.factState?.removeValue(forKey:"equipment");XCTAssertFalse(p.canPrepareTrainingPlan)
    }
    func testFirstSentenceChoosesRelevantTask() {
        XCTAssertEqual(OnboardingTaskKind.suggested(for:"我想增肌，在家有哑铃，一周三次"),.planCreate)
        XCTAssertEqual(OnboardingTaskKind.suggested(for:"我想导入已有的计划"),.planImport)
        XCTAssertEqual(OnboardingTaskKind.suggested(for:"先记录午餐"),.mealLog)
    }
    func testMutationIdentityBindsOwnerEndpointAndPayload() throws {
        let a=try OnboardingMutationRecovery.key(owner:1,path:"/me/profile-facts/preview",method:"POST",body:["revision":1,"field":"goal"])
        let retry=try OnboardingMutationRecovery.key(owner:1,path:"/me/profile-facts/preview",method:"POST",body:["field":"goal","revision":1])
        XCTAssertEqual(a,retry)
        XCTAssertNotEqual(a,try OnboardingMutationRecovery.key(owner:2,path:"/me/profile-facts/preview",method:"POST",body:["revision":1,"field":"goal"]))
        XCTAssertNotEqual(a,try OnboardingMutationRecovery.key(owner:1,path:"/me/profile-facts/preview",method:"POST",body:["revision":2,"field":"goal"]))
    }
    func testProtectedRecoveryJournalSeparatesAccounts() throws {
        let owner=Int.random(in:90000000...99999990),other=owner+1
        defer { OnboardingMutationRecovery.clear(owner:owner);OnboardingMutationRecovery.clear(owner:other) }
        let item=OnboardingMutationRecovery.Entry(id:UUID().uuidString,path:"/me/profile-facts/preview",method:"POST",body:Data("{}".utf8),createdAt:Date())
        try OnboardingMutationRecovery.persist(item,owner:owner)
        XCTAssertEqual(OnboardingMutationRecovery.entries(owner:owner).map(\.id),[item.id])
        XCTAssertTrue(OnboardingMutationRecovery.entries(owner:other).isEmpty)
        OnboardingMutationRecovery.saveState(Data("{\"draft\":1}".utf8),owner:owner)
        XCTAssertNotNil(OnboardingMutationRecovery.cachedState(owner:owner))
        XCTAssertNil(OnboardingMutationRecovery.cachedState(owner:other))
    }

    func testExplicitWholeMealFractionDoesNotGuessComponentOrAdditionalIntake() {
        XCTAssertEqual(MealCorrectionRules.explicitFraction("只吃了一半"),0.5)
        XCTAssertEqual(MealCorrectionRules.explicitFraction("这餐吃了四分之一"),0.25)
        XCTAssertNil(MealCorrectionRules.explicitFraction("又吃了一半"))
        XCTAssertNil(MealCorrectionRules.explicitFraction("米饭吃了一半"))
        XCTAssertNil(MealCorrectionRules.explicitFraction("不是一半，是三分之一"))
    }
    func testFreshProfileDefaultsAreNotConfirmed() {
        let profile = MemberProfile()
        XCTAssertFalse(profile.hasConfirmedBasics)
        XCTAssertFalse(profile.isFactConfirmed("profile_weight_kg"))
        XCTAssertTrue(NutritionTarget.estimate(profile).generalGuidanceOnly == true)
    }

    func testLegacyProfileWithValidValuesStaysUsable() throws {
        // A genuine old payload has no provenance key; a newly created profile is unknown.
        let encoded = try JSONEncoder().encode(MemberProfile())
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "factState")
        let profile = try JSONDecoder().decode(MemberProfile.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(profile.factState)
        XCTAssertTrue(profile.hasConfirmedBasics)
        let target = NutritionTarget.estimate(profile)
        XCTAssertNotEqual(target.generalGuidanceOnly, true)
        XCTAssertGreaterThan(target.caloriesMin, 0)
    }

    func testOnboardingCandidatesDecodeAndDoNotBecomeConfirmed() throws {
        let json = """
        {"answer":"这些条件我先记为待核对资料。你之前有规律做过力量训练吗？","sources":[],"actions":[],
         "purpose":"onboarding_assist","prompt_version":"boji.onboarding_assist.v1",
         "onboarding":{"schema_version":1,"candidates":[
           {"field":"goal","value":"增肌塑形","unit":null,"evidence_quote":"我想增肌"},
           {"field":"days_per_week","value":3,"unit":"days_per_week","evidence_quote":"一周三次"}]}}
        """
        let answer = try decode(ClubCoachAnswer.self, json)
        XCTAssertEqual(answer.onboarding?.candidates.count, 2)
        XCTAssertEqual(answer.onboarding?.candidates.first?.field, "goal")
        XCTAssertEqual(answer.onboarding?.candidates.last?.value.numberValue, 3)
    }

    func testTaskBusinessAndSyncStatusesStaySeparate() throws {
        let json = """
        {"task_type":"ai_job","task_id":"7d69796b-fdbb-4e6d-8240-130488515357","task_key":"ai_job/7d69796b-fdbb-4e6d-8240-130488515357",
         "kind":"generate_plan","title_key":"task.initial_plan","status":"succeeded","business_status":"syncing","group":"processing",
         "updated_at":"2026-10-25 08:00:00","available_actions":["open_source","open_preview"],
         "source_ref":{"type":"conversation","id":"example-conversation","job_id":"7d69796b-fdbb-4e6d-8240-130488515357"},
         "sync":{"pending":2,"failed":0,"published":1}}
        """
        let task = try decode(UserTask.self, json)
        XCTAssertEqual(task.statusLabel, "已完成")
        XCTAssertEqual(task.businessLabel, "已提交 · 正在同步")
        XCTAssertEqual(task.availableActions, ["open_source", "open_preview"])
        XCTAssertEqual(task.sync?.pending, 2)
    }

    func testTrainingDayAndUnitDisplay() {
        let value = JSONValue.array([.number(1), .number(3), .number(5)])
        XCTAssertEqual(OnboardingFieldSpec.trainingDays.displayValue(value), "周一、周三、周五")
        // displayUnit133 对 sessionMinutes 返回中文「分钟」（见 BodyFactsView.swift），
        // 断言与之一致；旧断言 "30 minutes" 是 displayUnit133 引入前的遗留。
        XCTAssertEqual(OnboardingFieldSpec.sessionMinutes.displayValue(.number(30)), "30 分钟")
        XCTAssertEqual(OnboardingFieldSpec.ageGroup.displayValue(.string("minor")), "未满 18 岁")
        XCTAssertEqual(OnboardingFieldSpec.weightMeasurementKind.displayValue(.string("estimated")), "估计")
    }

    func testAIRequestKeepsServerOwnedPurposeFieldsOutOfClientPayload() throws {
        let request = AIRequest(id: "7d69796b-fdbb-4e6d-8240-130488515357", kind: "coach", date: "2026-10-25",
                                payload: ["question": .string("你好")],
                                onboardingSessionID: "00f975d1-a20a-40ae-97c2-51dce60e5647",
                                contextSource: .object(["type": .string("report"), "id": .string("8b6e1f50-2a2b-4f31-9bc0-23c42cd4a7bb")]))
        let data = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["onboarding_session_id"] as? String, "00f975d1-a20a-40ae-97c2-51dce60e5647")
        XCTAssertNotNil(object["context_source"])
        XCTAssertNil((object["payload"] as? [String: Any])?["purpose"])
    }

    func testProfileChangeProposalWithoutAfterDecodesSafely() throws {
        let json = #"{"proposal_id":"2aa0f7ea-b7b1-42d3-8c67-969b2cb7e651","expires_at":"2026-10-25T09:00:00+08:00","profile_revision":2,"before":{}}"#
        let proposal = try decode(OnboardingProposal.self, json)
        XCTAssertEqual(proposal.profileRevision, 2)
        XCTAssertEqual(proposal.sessionRevision, 0)
        XCTAssertTrue(proposal.after.isEmpty)
    }

    func testUnknownOnboardingFieldIsNotMapped() {
        XCTAssertNil(OnboardingFieldSpec.from(apiKey: "medical_diagnosis"))
        XCTAssertEqual(OnboardingFieldSpec.from(apiKey: "profile_weight_kg"), .profileWeightKg)
    }
}


@MainActor
final class Build121OwnershipAndUXTests: XCTestCase {
    private let owner = 99121001
    private let a = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
    private let b = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
    private var date: Date { Date().addingTimeInterval(-86400) }
    private func fixture() -> DayLog {
        let start = date.addingTimeInterval(-2000)
        var day = DayLog()
        day.workoutSessions = [WorkoutSession(id: a, startedAt: start, endedAt: start.addingTimeInterval(600), savedAt: start.addingTimeInterval(601)),
            WorkoutSession(id: b, startedAt: start.addingTimeInterval(1000), endedAt: start.addingTimeInterval(1600), savedAt: start.addingTimeInterval(1601))]
        day.exercises = [Exercise(name: "卧推", muscle: "胸", sets: (0..<2).map { _ in TrainingSet(weight: 20, reps: 8, completed: true, actualEntered: true) }, workoutSessionID: a),
            Exercise(name: "划船", muscle: "背", sets: (0..<5).map { _ in TrainingSet(weight: 30, reps: 12, completed: true, actualEntered: true) }, workoutSessionID: b)]
        day.activeWorkoutSessionID = b
        day.workoutStartedAt = day.workoutSessions![1].startedAt; day.workoutEndedAt = day.workoutSessions![1].endedAt
        day.workoutSavedAt = day.workoutSessions![1].savedAt
        return day
    }
    func testHistoricalSessionExportIgnoresActiveSession() throws {
        let day = fixture()
        let saved = try XCTUnwrap(ConfirmedWorkoutSnapshot.make(owner: owner, date: date, sessionID: a, day: day))
        XCTAssertEqual(saved.startedAt, day.workoutSessions![0].startedAt)
        XCTAssertEqual(saved.completedSets, 2)
        XCTAssertEqual(saved.sessionID, a)
        XCTAssertNotEqual(saved.startedAt, day.workoutStartedAt)
        XCTAssertNotNil(ConfirmedWorkoutSnapshot.make(owner: -1001, date: date, sessionID: a, day: day), "Local preview identity must still render the confirmed session")
    }
    func testExportRejectsUnconfirmedAndCancelledSessions() {
        var day = fixture(); day.workoutSessions![0].savedAt = nil
        XCTAssertNil(ConfirmedWorkoutSnapshot.make(owner: owner, date: date, sessionID: a, day: day))
        day = fixture(); day.workoutSessions![0].cancelledAt = Date()
        XCTAssertNil(ConfirmedWorkoutSnapshot.make(owner: owner, date: date, sessionID: a, day: day))
    }
    func testSourceVersionChangesOnlyForSelectedSessionAndOwner() throws {
        var state = SavedState(); state.days[ClubDates.key(date)] = fixture()
        let context = try XCTUnwrap(ClubAIEntryContext.make(owner: owner, date: date, sessionID: a, state: state))
        XCTAssertTrue(context.isCurrent(owner: owner, state: state))
        XCTAssertFalse(context.isCurrent(owner: owner + 1, state: state))
        state.days[ClubDates.key(date)]!.exercises[1].sets[0].reps = 5
        XCTAssertTrue(context.isCurrent(owner: owner, state: state))
        state.days[ClubDates.key(date)]!.exercises[0].sets[0].reps = 6
        XCTAssertFalse(context.isCurrent(owner: owner, state: state))
    }
    func testExplicitlyDeletedWorkoutConversationGetsStableNewIdentity() throws {
        var state = SavedState(); state.days[ClubDates.key(date)] = fixture()
        let original = try XCTUnwrap(ClubAIEntryContext.make(owner: owner, date: date, sessionID: a, state: state))
        state.deletedAIJobIDs = [original.conversationID]
        let reopened = try XCTUnwrap(ClubAIEntryContext.make(owner: owner, date: date, sessionID: a, state: state))
        XCTAssertNotEqual(original.conversationID, reopened.conversationID)
        XCTAssertEqual(reopened.conversationID, ClubAIEntryContext.make(owner: owner, date: date, sessionID: a, state: state)?.conversationID)
        XCTAssertTrue(reopened.isCurrent(owner: owner, state: state))
    }

    func testUntouchedTargetsAreNotActualAndHistorySurvives() {
        let target = TrainingSet()
        XCTAssertFalse(target.hasActualEntry)
        XCTAssertFalse(target.validCompletion)
        var invalid = target; invalid.actualEntered = false; invalid.completed = true
        XCTAssertFalse(invalid.validCompletion)
        let history = TrainingSet(weight: 0, reps: 10, completed: true)
        XCTAssertTrue(history.hasActualEntry); XCTAssertTrue(history.validCompletion)
        let actual = TrainingSet(weight: 0, reps: 8, actualEntered: true)
        XCTAssertTrue(actual.hasActualEntry)
    }
    private func insight(_ id: String, owner: Int? = nil, priority: Int = 50) -> ClubHomeInsightSelection {
        .init(id: id, owner: owner ?? self.owner, day: "2026-10-25", kind: .training, title: id, detail: "synthetic", priority: priority)
    }
    func testInsightNeverRetainsAnotherAccountOrWithdrawnSource() {
        let first = insight("A")
        let next = insight("B", owner: owner + 1)
        XCTAssertEqual(ClubHomeInsightStability.select(current: first, candidates: [next]), next)
        XCTAssertNil(ClubHomeInsightStability.select(current: first, candidates: []))
        XCTAssertEqual(ClubHomeInsightStability.select(current: first, candidates: [insight("replacement")])?.id, "replacement")
    }
    func testOrdinaryInsightDoesNotRotateButHighPriorityCanReplace() {
        let first = insight("stable")
        XCTAssertEqual(ClubHomeInsightStability.select(current: first, candidates: [first, insight("new", priority: 60)]), first)
        XCTAssertEqual(ClubHomeInsightStability.select(current: first, candidates: [first, insight("urgent", priority: 120)])?.id, "urgent")
    }
    private func attachment(conversation: String) throws -> ClubChatAttachment {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { c in
            UIColor.blue.setFill(); c.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        return try ClubChatAttachment.prepare(try XCTUnwrap(image.jpegData(compressionQuality: 0.8)), owner: owner, conversation: conversation)
    }
    func testAttachmentCannotMoveAcrossOwnerOrConversation() throws {
        let c = UUID().uuidString.lowercased(); let item = try attachment(conversation: c)
        XCTAssertNoThrow(try ClubChatAttachment.payload([item], owner: owner, conversation: c))
        XCTAssertThrowsError(try ClubChatAttachment.payload([item], owner: owner + 1, conversation: c))
        XCTAssertThrowsError(try ClubChatAttachment.payload([item], owner: owner, conversation: UUID().uuidString.lowercased()))
        XCTAssertThrowsError(try ClubChatAttachment.payload([item, item], owner: owner, conversation: c))
    }
    func testProtectedImageDraftIsDiscoverableAndAccountIsolated() throws {
        let c = UUID().uuidString.lowercased(); defer { ClubChatDraftStorage.clear(owner: owner, conversation: c) }
        let item = try attachment(conversation: c)
        XCTAssertTrue(ClubChatDraftStorage.save(owner: owner, conversation: c, attachments: [item], context: nil))
        XCTAssertEqual(ClubChatDraftStorage.load(owner: owner, conversation: c)?.attachments, [item])
        XCTAssertNil(ClubChatDraftStorage.load(owner: owner + 1, conversation: c))
        XCTAssertTrue(ClubChatDraftStorage.conversations(owner: owner).contains(c))
        XCTAssertFalse(ClubChatDraftStorage.save(owner: owner + 1, conversation: c, attachments: [item], context: nil))
    }
    func testWorkoutTurnsAreVisibleInUnifiedChat() {
        let id = UUID().uuidString.lowercased()
        let request = AIRequest(id: id, kind: "coach", date: ClubDates.key(date), payload: ["purpose": .string("workout"), "conversation_id": .string(id), "question": .string("复盘本次训练")])
        let job = AILocalJob(id: id, digest: "test121", request: request)
        XCTAssertEqual(ClubCoachRules.turns([job], conversation: id, deleted: []).count, 1)
    }
}

@MainActor
final class Build122ReferenceTests: XCTestCase {
    func testBodyReferenceIgnoresUnrelatedTrainingUpdates() {
        var state = SavedState(); state.days["2026-10-25"] = DayLog()
        let ref = AIContextReference(kind: "body_range", from: "2026-10-25", to: "2026-10-25", title: "测量")
        let before = ref.localFingerprint(state)
        state.days["2026-10-25"]?.exercises = [Exercise(name: "卧推", muscle: "胸")]
        XCTAssertEqual(before, ref.localFingerprint(state))
        state.days["2026-10-25"]?.bodyWeight = BodyWeightEntry(kilograms: 70, updatedAt: Date())
        XCTAssertNotEqual(before, ref.localFingerprint(state))
    }
    func testReferenceWireDoesNotTrustDisplaySnapshot() throws {
        let ref = AIContextReference(kind: "meal_day", from: "2026-10-25", to: "2026-10-25", title: "Fake title", snapshot: .object(["forged": .number(999)]))
        let fields = try XCTUnwrap(ref.wire.object)
        XCTAssertNil(fields["title"]); XCTAssertNil(fields["snapshot"])
        XCTAssertEqual(fields["kind"], .string("meal_day"))
    }
    func testNewConsentDoesNotUpgradePreviousProviderScope() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(true, forKey: CloudAnalysisConsent.key(accountID: 42))
        XCTAssertEqual(CloudAnalysisConsent.routerVersion(accountID: 42, defaults: defaults), 2)
        CloudAnalysisConsent.set(true, accountID: 42, defaults: defaults)
        XCTAssertEqual(CloudAnalysisConsent.routerVersion(accountID: 42, defaults: defaults), 3)
        CloudAnalysisConsent.set(false, accountID: 42, defaults: defaults)
        XCTAssertFalse(CloudAnalysisConsent.allowed(accountID: 42, defaults: defaults))
    }
    func testReferenceOnlyDraftPersistsAndSeparatesOwners() throws {
        let id = UUID().uuidString.lowercased()
        let refs = [AIContextReference(kind: "plan_day", from: "2026-10-25", to: "2026-10-25", title: "计划")]
        defer { ClubChatDraftStorage.clear(owner: -122, conversation: id) }
        XCTAssertTrue(ClubChatDraftStorage.save(owner: -122, conversation: id, attachments: [], context: nil, references: refs))
        XCTAssertEqual(ClubChatDraftStorage.load(owner: -122, conversation: id)?.references, refs)
        XCTAssertTrue(ClubChatDraftStorage.conversations(owner: -122).contains(id))
        XCTAssertNil(ClubChatDraftStorage.load(owner: -123, conversation: id))
    }
}

@MainActor final class Build123RegressionTests: XCTestCase {
    func testPersistedPauseFreezesAndConfirmedDurationExcludesExplicitPause() throws {
        let end = Date().addingTimeInterval(-10), start = end.addingTimeInterval(-600), id = UUID()
        let session = WorkoutSession(id: id, startedAt: start, endedAt: end, savedAt: end,
            pauseIntervals: [WorkoutPauseInterval(start: start.addingTimeInterval(120), end: start.addingTimeInterval(180)),
                             WorkoutPauseInterval(start: start.addingTimeInterval(300), end: start.addingTimeInterval(420))])
        var day = DayLog()
        day.workoutStartedAt = start; day.workoutEndedAt = end; day.workoutSavedAt = end
        day.activeWorkoutSessionID = id; day.workoutSessions = [session]
        day.exercises = [Exercise(name: "卧推", muscle: "胸", sets: [TrainingSet(weight: 2.5, reps: 8, completed: true, actualEntered: true)], workoutSessionID: id)]
        XCTAssertEqual(day.confirmedTraining.elapsedSeconds, 420)
        XCTAssertEqual(WorkoutTiming.completedDuration(day, on: start), 420)
        let snapshot = try XCTUnwrap(ConfirmedWorkoutSnapshot.make(owner: 123, date: start, sessionID: id, day: day))
        XCTAssertEqual(snapshot.activeDuration, 420)
        XCTAssertEqual(snapshot.pauseIntervals?.count, 2)
        let restored = try JSONDecoder().decode(WorkoutSession.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(restored.pausedSeconds(through: end), 180)
    }
    func testOpenPauseDoesNotAdvanceWhileClockMoves() throws {
        let start = Date().addingTimeInterval(-600), id = UUID()
        let session = WorkoutSession(id: id, startedAt: start,
            pauseIntervals: [WorkoutPauseInterval(start: start.addingTimeInterval(100), end: start.addingTimeInterval(150)),
                             WorkoutPauseInterval(start: start.addingTimeInterval(300), end: nil)])
        let pause = try XCTUnwrap(WorkoutPauseState.from(session))
        XCTAssertTrue(pause.isPaused)
        XCTAssertEqual(pause.elapsed(startedAt: start, now: start.addingTimeInterval(500)), 250)
        XCTAssertEqual(pause.elapsed(startedAt: start, now: start.addingTimeInterval(900)), 250)
        XCTAssertEqual(pause.sessionID, id)
    }
    func testPartialMealCannotBeCalledAchievement() {
        var day = DayLog()
        day.meals = [Meal(name: "一餐", category: "午餐", calories: 300, protein: 20, carbs: 30, fat: 10)]
        var target = NutritionTarget.estimate(MemberProfile())
        target.generalGuidanceOnly = false; target.caloriesMin = 1800; target.caloriesMax = 2400
        XCTAssertNil(DashboardMetricProvider.nutritionStatus(day, target: target))
        day.mealCompletion = MealCompletion(signature: MealCompletion.signature(day.meals))
        XCTAssertEqual(DashboardMetricProvider.nutritionStatus(day, target: target), false)
        day.meals[0].calories = 2100
        day.mealCompletion = MealCompletion(signature: MealCompletion.signature(day.meals))
        XCTAssertEqual(DashboardMetricProvider.nutritionStatus(day, target: target), true)
        target.generalGuidanceOnly = true
        XCTAssertNil(DashboardMetricProvider.nutritionStatus(day, target: target))
    }
    func testCalendarWeekAndRollingWindowAreExplicit() throws {
        let wednesday = try XCTUnwrap(ClubDates.date(fromKey: "2020-01-15"))
        let week = ClubReviewScope.make(.completedCalendarWeek, through: wednesday)
        XCTAssertEqual(week.from, "2020-01-06"); XCTAssertEqual(week.to, "2020-01-12")
        let rolling = ClubReviewScope.make(.rolling7, through: wednesday)
        XCTAssertEqual(rolling.from, "2020-01-09"); XCTAssertEqual(rolling.to, "2020-01-15")
        XCTAssertEqual(rolling.contextDays, 14)
        XCTAssertEqual(ClubReviewScope.make(.daily, through: wednesday).contextDays, 1)
    }
    func testLegacySessionDecodesWithoutInventedPause() throws {
        let old = #"{"id":"12345678-1234-1234-1234-123456789012","startedAt":100,"endedAt":400,"savedAt":401}"#
        let session = try JSONDecoder().decode(WorkoutSession.self, from: Data(old.utf8))
        XCTAssertNil(session.pauseIntervals)
        XCTAssertEqual(session.pausedSeconds(through: Date()), 0)
    }
}

@MainActor extension Build123RegressionTests {
    func testChipReferenceRemainsIndependentWhenTextChanges() {
        var text = "😀问问 今天训练 后面"
        var refs = [AIContextReference.day("workout_range", date: Date(), title: "今天训练")]
        let editor = ClubReferenceTextEditor(text: Binding(get: { text }, set: { text = $0 }), references: Binding(get: { refs }, set: { refs = $0 }), focusRequest: 0, onMention: { _ in })
        let coordinator = editor.makeCoordinator(); let view = UITextView(); view.text = text
        let range = (text as NSString).range(of: "今天训练")
        XCTAssertTrue(coordinator.textView(view, shouldChangeTextIn: range, replacementText: ""))
        view.text = "😀问问  后面"; coordinator.textViewDidChange(view)
        XCTAssertEqual(refs.count, 1, "Only removing the chip removes an authorized reference")
        XCTAssertEqual(text, "😀问问  后面")
    }
    func testAtSuggestionsDoNotTreatEmailAsReference() {
        var text = "a@b.com"; var refs: [AIContextReference] = []
        let editor = ClubReferenceTextEditor(text: Binding(get: { text }, set: { text = $0 }), references: Binding(get: { refs }, set: { refs = $0 }), focusRequest: 0, onMention: { _ in })
        let coordinator = editor.makeCoordinator(); let view = UITextView(); view.text = text; view.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        XCTAssertNil(coordinator.mentionRange(in: view))
        view.text = "😀 @体重"; view.selectedRange = NSRange(location: (view.text as NSString).length, length: 0)
        let range = coordinator.mentionRange(in: view)
        XCTAssertEqual(range.map { (view.text as NSString).substring(with: $0) }, "@体重")
        XCTAssertTrue(refs.isEmpty, "Typing a label must not create an authorized reference")
    }
    func testReportFingerprintTracksDataRatherThanTransportMetadata() {
        let a: [String: JSONValue] = ["meals": .array([.string("一餐")]), "_routing_version": .number(2)]
        let b: [String: JSONValue] = ["meals": .array([.string("一餐")]), "_routing_version": .number(3), "_automatic_source_hash": .string("old")]
        XCTAssertEqual(ClubReviewRevision.fingerprint(a), ClubReviewRevision.fingerprint(b))
        XCTAssertNotEqual(ClubReviewRevision.fingerprint(a), ClubReviewRevision.fingerprint(["meals": .array([.string("两餐")])]))
    }
}

@MainActor final class Build131ExperienceTests: XCTestCase {
    func testReturnSendsWithoutAddingNewline() {
        var text = "你好"; var refs: [AIContextReference] = []; var sent = 0
        let editor = ClubReferenceTextEditor(text: Binding(get: { text }, set: { text = $0 }), references: Binding(get: { refs }, set: { refs = $0 }), focusRequest: 0, onMention: { _ in }, onSubmit: { sent += 1 })
        let coordinator = editor.makeCoordinator(); let view = ClubComposerTextView130(); view.text = text
        XCTAssertFalse(coordinator.textView(view, shouldChangeTextIn: NSRange(location: 2, length: 0), replacementText: "\n"))
        XCTAssertEqual(sent,1); XCTAssertEqual(text,"你好")
    }
    func testExplicitLineBreakDoesNotSend() {
        var text = "你好"; var refs: [AIContextReference] = []; var sent = 0
        let editor = ClubReferenceTextEditor(text: Binding(get: { text }, set: { text = $0 }), references: Binding(get: { refs }, set: { refs = $0 }), focusRequest: 0, onMention: { _ in }, onSubmit: { sent += 1 })
        let view = ClubComposerTextView130(); view.insertingLineBreak130 = true
        XCTAssertTrue(editor.makeCoordinator().textView(view, shouldChangeTextIn: NSRange(location: 0, length: 0), replacementText: "\n")); XCTAssertEqual(sent,0)
    }
    func testMissingTrainingConditionsAreSpecific() {
        let profile = MemberProfile()
        XCTAssertTrue(profile.missingPlanFields131.contains(.goal))
        XCTAssertTrue(profile.missingPlanFields131.contains(.trainingDays))
        XCTAssertTrue(profile.missingPlanFields131.contains(.ageGroup))
        XCTAssertFalse(profile.missingPlanFields131.contains(.heightCm), "Height is not required for a general training plan")
    }
    func testLocalReferencePayloadContainsSelectedRecordsOnly() throws {
        var state = SavedState(); var day = DayLog(); day.bodyWeight = BodyWeightEntry(kilograms:70,updatedAt:Date())
        state.days["2026-10-27"] = day
        let ref = AIContextReference(kind:"body_range",from:"2026-10-27",to:"2026-10-27",title:"体重")
        let payload = try ReferenceSnapshot131.payload(references:[ref],state:state,jobs:[])
        let fields = try XCTUnwrap(payload.object?["local_records131"]?.object?["2026-10-27"]?.object)
        XCTAssertNotNil(fields["bodyWeight"]); XCTAssertNil(fields["health"]); XCTAssertNil(fields["profile"])
        XCTAssertEqual(payload.object?["references"]?.array?.count,1)
    }
    func testLocalReferenceRejectsUnboundedRange() {
        let ref = AIContextReference(kind:"body_range",from:"2026-01-01",to:"2026-10-27",title:"全部")
        XCTAssertThrowsError(try ReferenceSnapshot131.payload(references:[ref],state:SavedState(),jobs:[]))
    }
}

@MainActor final class NativeInterface132Tests: XCTestCase {
    private func render<V: View>(_ view: V, name: String, height: CGFloat = 844, style: UIUserInterfaceStyle = .light) async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: height))
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let previous = scene?.windows.first(where: \.isKeyWindow)
        window.windowScene = scene
        window.frame = CGRect(x: 0, y: 0, width: 390, height: height)
        window.overrideUserInterfaceStyle = style
        let host = UIHostingController(rootView: view)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        host.view.setNeedsLayout(); host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(350))
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        XCTAssertEqual(image.size.width, 390); XCTAssertEqual(image.size.height, height)
        let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(name + ".png")
        try XCTUnwrap(image.pngData()).write(to: file)
        print("NATIVE132_PREVIEW " + file.path)
    }
    func testSettingsLightAppearance() async throws {
        try await render(ClubNavigationStack132 { SettingsHub130() }.environmentObject(AccountService()), name: "Build132-settings-light")
    }
    func testSettingsDarkAppearance() async throws {
        try await render(ClubNavigationStack132 { SettingsHub130() }.environmentObject(AccountService()), name: "Build132-settings-dark", style: .dark)
    }
    func testReferenceComposerAppearance() async throws {
        let account = AccountService(); let store = AppStore(); let ai = AIService()
        let refs = [AIContextReference.day("workout_range", date: Date(), title: "今天的训练")]
        let input = ClubSharedComposer(text: .constant("这次训练怎么安排？"), attachments: .constant([]), references: .constant(refs), deepAnalysis: .constant(false), conversationID: "native132-preview", busy: false, onSend: {}, onRecordMeal: { _ in }, onRecordBody: {})
        try await render(VStack { Spacer(); input.padding(.horizontal, 14).padding(.bottom, 12) }.background(Color(uiColor: .systemBackground)).environmentObject(account).environmentObject(store).environmentObject(ai), name: "Build132-composer", height: 240)
    }
    func testNativeCardSectionAppearance() async throws {
        let fixture = List {
            ClubCard { LabeledContent("资料体重", value: "70 kg"); LabeledContent("目标体重", value: "68 kg") }
            ClubCard { Toggle("训练日提醒", isOn: .constant(true)); Text("只在已安排训练的日期提醒。").font(.footnote).foregroundStyle(.secondary) }
        }.clubManagementList132()
        try await render(fixture, name: "Build132-native-sections", height: 420)
    }
}

@MainActor final class Build133UnifiedProfileTests:XCTestCase {
    func testExploreDoesNotRequestTrainingData() { XCTAssertTrue(ProfileFields133.task(.explore).isEmpty) }
    func testClearingExistingTextCannotSilentlySucceed() throws {
        let doc=try JSONDecoder().decode(ProfileFactsDocument.self,from:Data(#"{"schema_version":1,"revision":1,"facts":{"nickname":{"value":"原昵称"}}}"#.utf8))
        XCTAssertThrowsError(try ProfileFactInputs133().changes(fields:[.nickname],facts:doc.facts))
    }
    func testFirstTrainingDaySelectionSavesWithoutTextSeed() throws {
        var form=ProfileFactInputs133();form.selected["training_days"]=["周一","周三","周五"]
        let changes=try form.changes(fields:[.trainingDays],facts:[:])
        XCTAssertEqual(changes.first { $0["field"] as? String == "training_days" }?["value"] as? [Double],[1,3,5])
        XCTAssertEqual(changes.first { $0["field"] as? String == "days_per_week" }?["value"] as? Int,3)
    }
    func testHomeDaysAreIntegersAndSubsetOfSelectedDays() throws {
        var form=ProfileFactInputs133();form.selected["training_days"]=["周一","周三"];form.selected["home_training_days"]=["周三"]
        let rows=try form.changes(fields:[.trainingDays,.homeTrainingDays],facts:[:])
        XCTAssertEqual(rows.first { $0["field"] as? String == "home_training_days" }?["value"] as? [Double],[3])
        form.selected["home_training_days"]=["周日"]
        XCTAssertThrowsError(try form.changes(fields:[.homeTrainingDays],facts:[:]))
    }
    func testBasicAgeCreatesSameConfirmedAgeGroupForPlanning() throws {
        var form=ProfileFactInputs133();form.text["age_years"]="16"
        let changes=try form.changes(fields:ProfileFields133.basics,facts:[:])
        XCTAssertEqual(changes.first { $0["field"] as? String == "age_group" }?["value"] as? String,"minor")
    }
    func testDecimalAndRangeValidation() throws {
        var form=ProfileFactInputs133();form.text["profile_weight_kg"]="70,5"
        XCTAssertEqual(try form.value(.profileWeightKg)?.numberValue,70.5)
        form.text["height_cm"]="abc";XCTAssertThrowsError(try form.value(.heightCm))
        form.text["age_years"]="2";XCTAssertThrowsError(try form.value(.ageYears))
        form.text["height_cm"]="";XCTAssertNil(try form.value(.heightCm))
    }
    func testDisplayDoesNotExposeAPIUnits() {
        XCTAssertEqual(OnboardingFieldSpec.daysPerWeek.displayValue(.number(3)),"3 次/周")
        XCTAssertEqual(OnboardingFieldSpec.sessionMinutes.displayValue(.number(60)),"60 分钟")
    }
    func testIntakeAndMemoryReadTheSameFacts() throws {
        let doc=try JSONDecoder().decode(ProfileFactsDocument.self,from:Data(#"{"schema_version":1,"revision":7,"facts":{"nickname":{"value":"薄肌","source_kind":"confirmed"},"height_cm":{"value":175,"source_kind":"confirmed"},"training_days":{"value":[1,3,5],"source_kind":"confirmed"}}}"#.utf8))
        var form=ProfileFactInputs133()
        for field in OnboardingFieldSpec.allCases { if let fact=doc.facts[field.apiKey] { form.set(fact.value,field:field) } }
        XCTAssertEqual(form.text["nickname"],"薄肌");XCTAssertEqual(form.selected["training_days"],["周一","周三","周五"])
        XCTAssertTrue(try form.changes(fields:ProfileFields133.body+ProfileFields133.training,facts:doc.facts).isEmpty)
    }
    func testSharedDraftSurvivesRestartAndSeparatesAccounts() throws {
        let owner=9133001;defer { ProfileFormDraft133.erase(owner) }
        var input=ProfileFactInputs133();input.text["nickname"]="尚未保存";input.selected["training_days"]=["周六"]
        ProfileFormDraft133(input:input,baseline:ProfileFactInputs133()).save(owner)
        XCTAssertEqual(ProfileFormDraft133.load(owner)?.input,input);XCTAssertNil(ProfileFormDraft133.load(owner+1))
    }
    func testServerCheckpointAndQuotaStateDecodeTogether() throws {
        let raw=#"{"basic_profile_status":"skipped","task_complete_available":false,"assist_usage":{"used":0,"limit":10,"remaining":10},"capabilities":{"assist_budget_remaining":10}}"#
        let state=try JSONDecoder().decode(OnboardingV2State.self,from:Data(raw.utf8))
        XCTAssertEqual(state.basicProfileStatus,"skipped");XCTAssertFalse(state.taskCompleteAvailable);XCTAssertEqual(state.assistUsage.remaining,10)
    }
}

private final class ProfileTransport133:URLProtocol {
    static var respond:((URLRequest)throws->(Int,Data))!
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() {
        do { let (code,data)=try Self.respond(request)
            DispatchQueue.global().asyncAfter(deadline:.now()+0.03) { [self] in
                client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:code,httpVersion:"HTTP/1.1",headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed)
                client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self)
            }
        } catch { client?.urlProtocol(self,didFailWithError:error) }
    }
    override func stopLoading() {}
}

extension Build133UnifiedProfileTests {
    func testRapidDraftChangesUseSuccessiveRevisions() async throws {
        let owner=9133777
        defer { OnboardingMutationRecovery.clear(owner:owner) }
        let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[ProfileTransport133.self]
        let network=URLSession(configuration:config);defer { network.invalidateAndCancel() }
        var revision=1;var seen:[Int]=[];var fields:[String:Any]=[:];let lock=NSLock()
        let sid="8b6e1f50-2a2b-4f31-9bc0-23c42cd4a7bb"
        func state()->[String:Any] { ["session":["id":sid,"schema_version":1,"revision":revision,"status":"collecting","task_kind":"plan_create"],"draft":["fields":fields,"skipped":[],"artifacts":[:],"first_plan":[:]],"profile_revision":0,"confirmed_facts":[:]] }
        ProfileTransport133.respond={ request in
            lock.lock();defer { lock.unlock() }
            let path=request.url!.path
            if path.hasSuffix("/me") { return (200,try JSONSerialization.data(withJSONObject:["user":["id":owner,"phone_masked":"synthetic","club_number":"synthetic","onboarding_completed":false,"membership":["active":false]]])) }
            if path.hasSuffix("profile-facts") { return (200,Data(#"{"schema_version":1,"revision":0,"facts":{}}"#.utf8)) }
            if request.httpMethod == "PATCH" {
                var data=request.httpBody ?? Data()
                if data.isEmpty,let stream=request.httpBodyStream { stream.open();defer { stream.close() };var buffer=[UInt8](repeating:0,count:4096);while stream.hasBytesAvailable { let n=stream.read(&buffer,maxLength:buffer.count);if n<=0 { break };data.append(contentsOf:buffer.prefix(n)) } }
                let body=try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any]);let expected=try XCTUnwrap(body["expected_session_revision"] as? Int);seen.append(expected)
                guard expected==revision else { return (409,Data(#"{"error":"stale"}"#.utf8)) }
                for change in body["changes"] as? [[String:Any]] ?? [] { if let key=change["field"] as? String { fields[key]=["value":change["value"] ?? NSNull(),"origin":"user_form"] } }
                revision += 1
            }
            return (200,try JSONSerialization.data(withJSONObject:state()))
        }
        let account=AccountService(networkSession:network,credentialStore:MemoryAccountCredentials127(token:"synthetic133"))
        await account.restore();XCTAssertEqual(account.user?.id,owner)
        let model=OnboardingV2Model();await model.load(account:account)
        async let first:Void=model.patch(field:.goal,value:.string("提升力量"),account:account)
        async let second:Void=model.patch(field:.experience,value:.string("新手"),account:account)
        _ = await (first,second)
        XCTAssertEqual(seen,[1,2]);XCTAssertNil(model.error)
        XCTAssertEqual(model.state?.draft.fields["goal"]?.value.string,"提升力量")
        XCTAssertEqual(model.state?.draft.fields["experience"]?.value.string,"新手")
    }
}

@MainActor final class NativeData134Tests: XCTestCase {
    func testChartsKeepIdentityWhenValuesChange() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(BojiBarTrendChart.Bar(date: date, value: nil).id, BojiBarTrendChart.Bar(date: date, value: 500).id)
        XCTAssertNotEqual(BojiBarTrendChart.Bar(date: date, value: nil), BojiBarTrendChart.Bar(date: date, value: 0))
        XCTAssertEqual(BojiTrendPoint(date: date, value: 70).id, BojiTrendPoint(date: date, value: 69).id)
        XCTAssertNotEqual(BojiTrendPoint(date: date, value: 70, sourceID: "measure-A").id,
                          BojiTrendPoint(date: date, value: 71, sourceID: "measure-B").id)
        XCTAssertEqual(BojiMacroDonut.Slice(name: "蛋白质", grams: 20, factor: 4, color: .blue).id,
                       BojiMacroDonut.Slice(name: "蛋白质", grams: 30, factor: 4, color: .blue).id)
    }
    func testMacroSharesUseEnergyRatherThanGramMass() {
        let protein = NativeData134.energy(10, factor: 4), fat = NativeData134.energy(10, factor: 9)
        XCTAssertEqual(protein, 40); XCTAssertEqual(fat, 90)
        XCTAssertEqual(NativeData134.share(fat, total: protein + fat), 90.0 / 130, accuracy: 0.00001)
        XCTAssertEqual(NativeData134.energy(-1, factor: 4), 0)
        XCTAssertEqual(NativeData134.energy(.nan, factor: 4), 0)
    }
    func testEmptyAndSingleMeasurementDomainsStayFiniteAndContainTarget() {
        let empty = NativeData134.domain([], target: nil)
        XCTAssertLessThan(empty.lowerBound, empty.upperBound)
        let one = NativeData134.domain([70], target: 65)
        XCTAssertTrue(one.contains(70)); XCTAssertTrue(one.contains(65))
        let invalid = NativeData134.domain([.nan, .infinity], target: nil)
        XCTAssertTrue(invalid.lowerBound.isFinite); XCTAssertTrue(invalid.upperBound.isFinite)
    }
    func testTrainingFrequencyRejectsInvalidDatesAndImpossibleCounts() {
        XCTAssertEqual(NativeData134.frequency(trainingDays: 3, start: "2026-10-20", end: "2026-10-26"), 3.0 / 7)
        XCTAssertEqual(NativeData134.frequency(trainingDays: 0, start: "2026-10-26", end: "2026-10-26"), 0)
        XCTAssertNil(NativeData134.frequency(trainingDays: 8, start: "2026-10-20", end: "2026-10-26"))
        XCTAssertNil(NativeData134.frequency(trainingDays: 1, start: "bad", end: "2026-10-26"))
        XCTAssertNil(NativeData134.frequency(trainingDays: 1, start: "2026-10-26", end: "2026-10-20"))
    }
    func testCompletionChartExcludesUnfinishedSetsAndTimedWeightVolume() {
        var day = DayLog()
        day.exercises = [Exercise(name: "卧推", muscle: "胸", sets: [
            TrainingSet(weight: 20, reps: 8, completed: true, actualEntered: true),
            TrainingSet(weight: 50, reps: 10, completed: false, actualEntered: false)]),
            Exercise(name: "平板支撑", muscle: "核心", sets: [
                TrainingSet(weight: 0, reps: 0, completed: true, durationSeconds: 45, actualEntered: true)])]
        let facts = WorkoutFacts125(day)
        XCTAssertEqual(facts.completed, 2); XCTAssertEqual(facts.planned, 3)
        XCTAssertEqual(facts.volume, 160); XCTAssertEqual(facts.seconds, 45)
        XCTAssertEqual(facts.exercises[0].completed, 1)
        XCTAssertEqual(NativeData134.share(0, total: 0), 0)
    }
    private var flowers: [MusclePetal134] { [
        .init(name: "胸", sets: 16), .init(name: "背", sets: 20), .init(name: "腿", sets: 12),
        .init(name: "肩", sets: 8), .init(name: "手臂", sets: 6), .init(name: "核心", sets: 10)] }
    func testRenderNativeChartsLightDarkAndLargeText() async throws {
        let overview = VStack(alignment: .leading, spacing: 22) {
            Text("训练记录").font(.largeTitle.bold())
            Text("示例数据 · 仅用于界面检查").font(.caption).foregroundStyle(.secondary)
            HStack { DataMetric134(title: "训练天数", value: "12", unit: "天"); DataMetric134(title: "完成组数", value: "72", unit: "组"); DataMetric134(title: "额外负重总量", value: "8,240", unit: "kg·次") }
            ClubCard { Text("练到了哪些部位").font(.title3.weight(.semibold)); MuscleFlower134(items: flowers) }
            Spacer(minLength: 0)
        }.padding(20).background(Color(uiColor: .systemGroupedBackground))
        try await render134(overview, name: "Build134-training-light")
        try await render134(overview, name: "Build134-training-dark", style: .dark)
        let date = ClubDates.date(fromKey: "2026-10-26")!
        let chart = VStack(alignment: .leading, spacing: 18) {
            Text("饮食与身体趋势").font(.title2.bold())
            Text("示例数据 · 仅用于界面检查").font(.caption).foregroundStyle(.secondary)
            ClubCard {
                BojiMacroDonut(protein: 90, carbs: 180, fat: 55, centerTitle: "已记录热量", centerValue: "1,575 kcal", size: 200).frame(maxWidth: .infinity)
                Text("供能占比：蛋白质/碳水 4 kcal/g，脂肪 9 kcal/g").font(.caption).foregroundStyle(.secondary)
            }
            ClubCard {
                Text("体重变化 · kg").font(.headline)
                BojiLineTrendChart(points: (0..<7).map { BojiTrendPoint(date: date.addingTimeInterval(Double($0) * 86400), value: [72.1, 71.9, 72.0, 71.5, 71.4, 71.7, 71.3][$0]) }, target: 70, unit: "kg", height: 180)
            }
            Spacer(minLength: 0)
        }.padding(20).background(Color(uiColor: .systemGroupedBackground))
        try await render134(chart, name: "Build134-nutrition-body")
        var workout = DayLog()
        workout.exercises = [Exercise(name: "哑铃卧推", muscle: "胸", sets: [
            TrainingSet(weight: 20, reps: 10, completed: true, actualEntered: true),
            TrainingSet(weight: 20, reps: 10, completed: true, actualEntered: true),
            TrainingSet(weight: 20, reps: 10, completed: false, actualEntered: false)]),
            Exercise(name: "坐姿划船", muscle: "背", sets: [TrainingSet(weight: 30, reps: 12, completed: true, actualEntered: true)])]
        let completion = VStack(alignment: .leading, spacing: 18) {
            Text("示例训练 · 仅用于界面检查").font(.caption).foregroundStyle(.secondary)
            WorkoutCelebration125(facts: WorkoutFacts125(workout), duration: "32分钟")
            WorkoutCharts125(facts: WorkoutFacts125(workout))
        }.padding(20).background(Color(uiColor: .systemGroupedBackground))
        try await render134(completion, name: "Build134-workout-completion", height: 1550)
        try await render134(MuscleFlower134(items: flowers).padding(20).environment(\.dynamicTypeSize, .accessibility1), name: "Build134-large-text", height: 1000)
    }
    private func render134<V: View>(_ view: V, name: String, height: CGFloat = 844, style: UIUserInterfaceStyle = .light) async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: height))
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let previous = scene?.windows.first(where: \.isKeyWindow)
        window.windowScene = scene; window.frame = CGRect(x: 0, y: 0, width: 390, height: height)
        window.overrideUserInterfaceStyle = style
        let host = UIHostingController(rootView: view); window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        host.view.setNeedsLayout(); host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(650))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        XCTAssertEqual(image.size.width, 390)
        let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(name + ".png")
        try XCTUnwrap(image.pngData()).write(to: file)
        print("NATIVE134_PREVIEW " + file.path)
    }
}

@MainActor final class Build135NaturalProfileTests: XCTestCase {
    func testWeightProfileIsNotAWeighIn() throws {
        var input = ProfileFactInputs133()
        input.text["profile_weight_kg"] = "70.5"
        let changes = try input.changes(fields: [.profileWeightKg], facts: [:])
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes.first?["field"] as? String, "profile_weight_kg")
        XCTAssertEqual(changes.first?["value"] as? Double, 70.5)
        XCTAssertNil(changes.first?["observed_at"])
        XCTAssertNil(changes.first?["measurement_kind"])
    }
    func testWeekdaysKeepDerivedTrainingCountInOneMutation() throws {
        var input = ProfileFactInputs133()
        input.selected["training_days"] = ["周一", "周三", "周五"]
        let changes = try input.changes(fields: [.trainingDays], facts: [:])
        XCTAssertEqual(changes.filter { $0["field"] as? String == "training_days" }.count, 1)
        XCTAssertEqual(changes.filter { $0["field"] as? String == "days_per_week" }.count, 1)
        XCTAssertEqual(changes.first { $0["field"] as? String == "days_per_week" }?["value"] as? Int, 3)
    }
    func testConfirmedProfileResponseIsImmediatelyAvailable() throws {
        let data = Data("""
        {"status":"committed","profile_revision":2,"profile":{"schema_version":1,"revision":2,
         "facts":{"goal":{"value":"减脂","source_kind":"confirmed"}}}}
        """.utf8)
        let result = try JSONDecoder().decode(OnboardingConfirmResponse.self, from: data)
        XCTAssertEqual(result.profile?.revision, 2)
        XCTAssertEqual(result.profile?.facts["goal"]?.value.string, "减脂")
    }
}
