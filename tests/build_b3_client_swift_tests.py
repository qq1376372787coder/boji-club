"""Batch 3 client data-correctness rules.

Reuses the generated offline Swift fixture (the repository has no XCTest unit
target) and appends the production helpers plus focused checks for:
workout end/ongoing, plannedDates refresh, plan day status, cross-midnight
entry, membership verification, AI consent default, phase-report guard, weekly review
dedupe, meal nutrition merge, and the protected account cache.
Run with tests/run_b3_client.sh on a Mac. This is not an iPhone UI test.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]

def source(name):
    return (root / "BojiClub" / name).read_text("utf-8")

def block(text, marker):
    start = text.index(marker)
    i = text.index("{", start)
    depth = 1
    j = i + 1
    while depth:
        if text[j] == "{":
            depth += 1
        elif text[j] == "}":
            depth -= 1
        j += 1
    return text[start:j]

with tempfile.TemporaryDirectory() as tmp:
    base = Path(tmp) / "base.swift"
    subprocess.run([sys.executable, str(root / "tests/build_experience_v150_swift_tests.py"), str(base)],
                   check=True, stdout=subprocess.DEVNULL)
    fixture = base.read_text("utf-8")

models = source("Models.swift")
daily = source("DailyExperience.swift")
journey = source("JourneyRules.swift")
app = source("AppStore.swift")
membership = source("MembershipService.swift")
weekly = source("WeeklyReview.swift")
account = source("AccountService.swift")
plans = source("PlanHubViews.swift")
onboarding = source("OnboardingView.swift")

appendix = ["import CryptoKit"]
appendix.append(block(models, "enum MealNutritionMerge {"))
appendix.append(block(journey, "enum CloudAnalysisConsent {"))
appendix.append(block(app, "enum PhaseReportWriteGuard {"))
appendix.append(block(membership, "enum MembershipAccessPolicy {"))
appendix.append(block(weekly, "enum WeeklyReviewSubmissionRules {"))
appendix.append(block(account, "enum AccountProfileCacheStore {"))
appendix.append(block(onboarding, "enum OnboardingDraftStore {"))
appendix.append(block(daily, "enum WorkoutEntryRules {"))
appendix.append(block(daily, "struct WeeklyReadiness {"))
appendix.append(block(journey, "enum TrainingHandoff {"))
appendix.append(block(plans, "enum PlanDayState: Equatable {"))
appendix.append(block(plans, "enum PlanDayStatus {"))
appendix.append("extension FoodComponent: Equatable {}")

appendix.append(r'''
// The generated fixture has no account model; the protected cache only needs a
// Codable account payload, so a minimal stand-in is enough here.
struct ClubAccount: Codable, Equatable { var id: Int; var nickname: String }

func b3Meal(calories: Double = 400, protein: Double = 30,
            components: [FoodComponent]? = nil, fraction: Double? = nil) -> Meal {
    Meal(name: "鸡胸", category: "午餐", calories: calories, protein: protein,
         carbs: 40, fat: 10, photoFilename: nil, sourceAIJobID: nil,
         estimated: nil, estimateNotes: nil, components: components,
         consumedFraction: fraction, nutritionKnown: true)
}
func b3Exercise(_ name: String, session: UUID, completed: Bool = true) -> Exercise {
    Exercise(name: name, muscle: "胸", sets: [TrainingSet(weight: 20, reps: 10, completed: completed)],
             libraryID: "b3", workoutSessionID: session)
}

// 1. Editing a saved/ended workout keeps the end time (duration unchanged) and
// must never resurrect it as "ongoing" while saying the modification is unsaved.
let b3Now = Date(timeIntervalSince1970: 1_800_000_000)
let b3Session = UUID()
var b3Day = DayLog()
b3Day.workoutStartedAt = b3Now
b3Day.workoutEndedAt = b3Now.addingTimeInterval(3600)
b3Day.workoutSavedAt = b3Now.addingTimeInterval(3600)
b3Day.activeWorkoutSessionID = b3Session
b3Day.workoutSessions = [WorkoutSession(id: b3Session, startedAt: b3Now,
                                        endedAt: b3Now.addingTimeInterval(3600),
                                        savedAt: b3Now.addingTimeInterval(3600))]
b3Day.exercises = [b3Exercise("卧推", session: b3Session)]
var b3State = SavedState(); b3State.days[ClubDates.key(b3Now)] = b3Day
check(HomeTrainingState.resolve(date: b3Now, state: b3State, now: b3Now.addingTimeInterval(4000)) == .completed(sessionID: b3Session),
      "saved workout resolves to completed")
b3Day.workoutSavedAt = nil // updateSet/addSet/removeExercise invalidation
b3Day.workoutSessions?[0].savedAt = nil // WorkoutSessions.synchronize mirrors the day fields
b3State.days[ClubDates.key(b3Now)] = b3Day
check(!WorkoutTiming.isOngoing(b3Day, on: b3Now, now: b3Now.addingTimeInterval(4000)),
      "edited ended workout is not ongoing")
check(ActiveWorkoutRules.snapshot(state: b3State, now: b3Now.addingTimeInterval(4000)) == nil,
      "edited ended workout has no active snapshot")
check(HomeTrainingState.resolve(date: b3Now, state: b3State, now: b3Now.addingTimeInterval(4000)) == .needsConfirmation,
      "edited ended workout asks for confirmation instead of ongoing")
check(WorkoutTiming.completedDuration(b3Day, on: b3Now, now: b3Now.addingTimeInterval(4000)) == 3600,
      "editing preserves the original workout duration")
var b3Open = b3Day; b3Open.workoutEndedAt = nil; b3Open.workoutSessions?[0].endedAt = nil
check(WorkoutTiming.isOngoing(b3Open, on: b3Now, now: b3Now.addingTimeInterval(4000)),
      "a workout without an end time can still be ongoing")
check(ActiveWorkoutRules.snapshot(state: { var s = SavedState(); s.days[ClubDates.key(b3Now)] = b3Open; return s }(),
                                  now: b3Now.addingTimeInterval(4000)) != nil,
      "an unended session still has an active snapshot")

// 2. plannedDates follows actual exercises after manual add/remove.
let b3Start = "2026-10-05"
var b3Cycle = TrainingCycle(start: b3Start, plannedDates: [])
b3Cycle.endDate = b3Cycle.end
var b3Days: [String: DayLog] = [:]
for key in b3Cycle.dates { b3Days[key] = DayLog(planCycle: b3Cycle) }
b3Days[b3Cycle.dates[0]]?.exercises = [b3Exercise("卧推", session: UUID())]
b3Days[b3Cycle.dates[2]]?.exercises = [b3Exercise("深蹲", session: UUID())]
var b3Changed = TrainingCycle.refreshPlannedDates(covering: b3Cycle.dates[0], in: &b3Days)
check(b3Changed.contains(b3Cycle.dates[0]) && b3Days[b3Cycle.dates.first!]?.planCycle?.plannedDates == [b3Cycle.dates[0], b3Cycle.dates[2]],
      "cycle plannedDates counts actual training days")
let b3Rest = b3Cycle.dates[3]
check(PlanDayStatus.resolve(date: ClubDates.date(fromKey: b3Rest)!, state: { var s = SavedState(); s.days = b3Days; return s }()) == .restDay,
      "a date without exercises is a rest day")
b3Days[b3Rest]?.exercises = [b3Exercise("划船", session: UUID())]
_ = TrainingCycle.refreshPlannedDates(covering: b3Rest, in: &b3Days)
check(b3Days[b3Rest]?.planCycle?.plannedDates.contains(b3Rest) == true,
      "adding an exercise turns a rest day into a planned day")
check(PlanDayStatus.resolve(date: ClubDates.date(fromKey: b3Rest)!, state: { var s = SavedState(); s.days = b3Days; return s }()) == .todayPending
      || PlanDayStatus.resolve(date: ClubDates.date(fromKey: b3Rest)!, state: { var s = SavedState(); s.days = b3Days; return s }()) == .pastMissed,
      "the former rest day is no longer rendered as rest")
b3Days[b3Cycle.dates[2]]?.exercises = []
_ = TrainingCycle.refreshPlannedDates(covering: b3Cycle.dates[2], in: &b3Days)
check(!(b3Days[b3Cycle.dates[2]]?.planCycle?.plannedDates.contains(b3Cycle.dates[2]) ?? true),
      "removing the last exercise removes the planned date")
check(b3Days[b3Start]?.planCycle?.plannedDates.count == 2,
      "all cycle day copies share the recomputed plan count")

// 3. WeeklyReadiness / handoff use the refreshed counts.
var b3PastCycle = TrainingCycle(start: "2026-09-01", plannedDates: [])
b3PastCycle.endDate = b3PastCycle.end
let b3PastDays = b3PastCycle.dates
var b3ReadinessDays: [String: DayLog] = [:]
for key in b3PastCycle.dates { b3ReadinessDays[key] = DayLog(planCycle: b3PastCycle) }
b3ReadinessDays[b3PastDays[0]]?.exercises = [b3Exercise("卧推", session: UUID())]
b3ReadinessDays[b3PastDays[0]]?.workoutSavedAt = Date(timeIntervalSince1970: 1_700_000_000)
b3ReadinessDays[b3PastDays[2]]?.exercises = [b3Exercise("深蹲", session: UUID())]
var b3TwoPlanned = b3PastCycle; b3TwoPlanned.plannedDates = [b3PastDays[0], b3PastDays[2]]
check(WeeklyReadiness(cycle: b3TwoPlanned, days: b3ReadinessDays).neededTrainingDays == 2,
      "two planned days require two confirmed trainings")
var b3OnePlanned = b3PastCycle; b3OnePlanned.plannedDates = [b3PastDays[0]]
check(WeeklyReadiness(cycle: b3OnePlanned, days: b3ReadinessDays).trainingReady,
      "removing an unconfirmed planned day lets the confirmed day satisfy the review gate")

let b3Today = ClubDates.calendar.startOfDay(for: Date())
let b3TodayKey = ClubDates.key(b3Today)
let b3HandoffStart = ClubDates.key(ClubDates.calendar.date(byAdding: .day, value: -3, to: b3Today)!)
var b3HandoffCycle = TrainingCycle(start: b3HandoffStart, plannedDates: [b3TodayKey])
var b3HandoffDays: [String: DayLog] = [:]
for key in b3HandoffCycle.dates { b3HandoffDays[key] = DayLog(planCycle: b3HandoffCycle) }
b3HandoffDays[b3TodayKey]?.exercises = [b3Exercise("卧推", session: UUID())]
b3HandoffDays[b3TodayKey]?.workoutSavedAt = Date()
check(TrainingHandoff.pending(on: b3Today, days: b3HandoffDays) != nil,
      "handoff appears when every planned day is confirmed near the cycle end")
check(TrainingHandoff.detail(b3HandoffCycle, days: b3HandoffDays).contains("都已保存"),
      "handoff detail uses confirmed planned days")
b3HandoffDays[b3TodayKey]?.exercises = []
_ = TrainingCycle.refreshPlannedDates(covering: b3TodayKey, in: &b3HandoffDays)
check(TrainingHandoff.pending(on: b3Today, days: b3HandoffDays) == nil,
      "removing the last exercise removes an empty plan from handoff")

// 4. Cross-midnight entry uses the persisted active session date.
let b3Yesterday = ClubDates.calendar.date(byAdding: .day, value: -1, to: b3Today)!
check(WorkoutEntryRules.date(selected: b3Today, activeDateKey: ClubDates.key(b3Yesterday)) == b3Yesterday,
      "continue-training opens the active session's start date")
check(WorkoutEntryRules.date(selected: b3Today, activeDateKey: nil) == b3Today,
      "no active session keeps the selected date")

// 5. Store confirmation does not grant business access before server verification.
check(!MembershipAccessPolicy.grantsAccess(serverActive: false, storeActive: true),
      "store purchase stays behind membership gate until server verifies")
check(!MembershipAccessPolicy.grantsAccess(serverActive: false, storeActive: false),
      "unpaid account stays behind membership gate")
check(MembershipAccessPolicy.grantsAccess(serverActive: true, storeActive: false),
      "server membership remains authoritative")

// 6. AI consent: no per-account decision means not allowed.
let b3Defaults = UserDefaults(suiteName: "boji-b3-consent-\(UUID().uuidString)")!
check(!CloudAnalysisConsent.allowed(accountID: 77, defaults: b3Defaults), "missing AI consent defaults to denied")
check(!CloudAnalysisConsent.hasDecision(accountID: 77, defaults: b3Defaults), "missing decision is visible to first-use UI")
CloudAnalysisConsent.set(true, accountID: 77, defaults: b3Defaults)
check(CloudAnalysisConsent.allowed(accountID: 77, defaults: b3Defaults), "explicit opt-in is respected")
CloudAnalysisConsent.set(false, accountID: 77, defaults: b3Defaults)
check(!CloudAnalysisConsent.allowed(accountID: 77, defaults: b3Defaults), "explicit opt-out is respected")

// 7. Phase report owner/generation guard.
let b3Generation = UUID()
check(PhaseReportWriteGuard.allows(expectedOwner: 1, currentOwner: 1,
                                   expectedGeneration: b3Generation, currentGeneration: b3Generation),
      "same account and generation may write a phase report")
check(!PhaseReportWriteGuard.allows(expectedOwner: 1, currentOwner: 2,
                                    expectedGeneration: b3Generation, currentGeneration: b3Generation),
      "account switch blocks the phase report write")
check(!PhaseReportWriteGuard.allows(expectedOwner: 1, currentOwner: 1,
                                    expectedGeneration: b3Generation, currentGeneration: UUID()),
      "store generation change blocks the phase report write")
check(!PhaseReportWriteGuard.allows(expectedOwner: nil, currentOwner: 1,
                                    expectedGeneration: b3Generation, currentGeneration: b3Generation),
      "missing owner ticket is rejected")

// 8. Weekly review duplicate guard covers pending and succeeded, and the
// deterministic job ID collapses the same submission across devices.
check(WeeklyReviewSubmissionRules.isDuplicate(fingerprint: "fp", candidateFingerprint: "fp",
                                              hasResult: true, jobID: nil, status: "succeeded"),
      "completed review blocks a duplicate")
check(WeeklyReviewSubmissionRules.isDuplicate(fingerprint: "fp", candidateFingerprint: "fp",
                                              hasResult: false, jobID: "job", status: "pending"),
      "pending review blocks a duplicate")
check(!WeeklyReviewSubmissionRules.isDuplicate(fingerprint: "fp", candidateFingerprint: "fp",
                                               hasResult: false, jobID: nil, status: "draft"),
      "an unsubmitted draft does not block")
check(!WeeklyReviewSubmissionRules.isDuplicate(fingerprint: "fp", candidateFingerprint: "other",
                                               hasResult: true, jobID: "job", status: "succeeded"),
      "different input fingerprint is not a duplicate")
let b3JobA = WeeklyReviewSubmissionRules.deterministicJobID(owner: 7, cycleStart: "2026-10-01", fingerprint: "fp")
let b3JobB = WeeklyReviewSubmissionRules.deterministicJobID(owner: 7, cycleStart: "2026-10-01", fingerprint: "fp")
let b3JobC = WeeklyReviewSubmissionRules.deterministicJobID(owner: 8, cycleStart: "2026-10-01", fingerprint: "fp")
let b3JobRetry = WeeklyReviewSubmissionRules.deterministicJobID(owner: 7, cycleStart: "2026-10-01", fingerprint: "fp", attempt: 1)
check(b3JobA == b3JobB && UUID(uuidString: b3JobA) != nil, "same device-independent submission has one job ID")
check(b3JobA != b3JobC, "different accounts do not share a weekly job ID")
check(b3JobA != b3JobRetry, "a failed-review retry receives a fresh job ID")

// 9. Meal nutrition merge keeps a remote field when the local editor did not touch it.
let b3BaseMeal = b3Meal(calories: 400, protein: 30)
var b3RemoteMeal = b3BaseMeal; b3RemoteMeal.calories = 500
var b3LocalEdit = b3BaseMeal; b3LocalEdit.protein = 40
let b3Merged = MealNutritionMerge.merged(edited: b3LocalEdit, base: b3BaseMeal, current: b3RemoteMeal)
check(b3Merged.calories == 500 && b3Merged.protein == 40,
      "different-field meal edits merge instead of overwriting")
var b3BothEdit = b3BaseMeal; b3BothEdit.calories = 450
var b3RemoteSameField = b3BaseMeal; b3RemoteSameField.calories = 500
check(MealNutritionMerge.merged(edited: b3BothEdit, base: b3BaseMeal, current: b3RemoteSameField).calories == 450,
      "same-field conflict keeps the local intentional edit")
var b3ComponentsEdit = b3BaseMeal; b3ComponentsEdit.components = [FoodComponent()]
b3ComponentsEdit.consumedFraction = 0.5; b3ComponentsEdit.calories = 200
let b3ComponentResult = MealNutritionMerge.merged(edited: b3ComponentsEdit, base: b3BaseMeal, current: b3RemoteMeal)
check(b3ComponentResult.components != nil && b3ComponentResult.calories == 200,
      "component edits write a coherent component/total set")
check(MealNutritionMerge.merged(edited: b3LocalEdit, base: nil, current: b3RemoteMeal).calories == 400,
      "legacy no-base call still writes the whole meal")

// 10. Protected account cache: no PII blob in UserDefaults, offline restore
// still works, legacy data migrates, and clear removes both copies.
let b3CacheDir = FileManager.default.temporaryDirectory.appendingPathComponent("boji-b3-cache-\(UUID().uuidString)", isDirectory: true)
let b3CacheDefaults = UserDefaults(suiteName: "boji-b3-cache-\(UUID().uuidString)")!
let b3Account = ClubAccount(id: 7, nickname: "测试")
check(AccountProfileCacheStore.save(b3Account, directory: b3CacheDir, defaults: b3CacheDefaults),
      "protected account cache saves")
check(b3CacheDefaults.data(forKey: "account.cached-user") == nil,
      "profile is no longer stored as a UserDefaults blob")
check(b3CacheDefaults.integer(forKey: "account.cached-user-id") == 7,
      "only the non-PII account pointer remains in preferences")
check(AccountProfileCacheStore.load(directory: b3CacheDir, defaults: b3CacheDefaults) == b3Account,
      "offline restore reads the protected account cache")
check(FileManager.default.fileExists(atPath: AccountProfileCacheStore.fileURL(owner: 7, directory: b3CacheDir).path),
      "account cache is a separate protected file")
b3CacheDefaults.removeObject(forKey: "account.cached-user-id")
let b3Legacy = try! JSONEncoder().encode(b3Account)
b3CacheDefaults.set(b3Legacy, forKey: "account.cached-user")
check(AccountProfileCacheStore.load(directory: b3CacheDir, defaults: b3CacheDefaults) == b3Account,
      "legacy UserDefaults cache still restores once")
check(b3CacheDefaults.data(forKey: "account.cached-user") == nil,
      "legacy blob is removed after migration")
AccountProfileCacheStore.clear(directory: b3CacheDir, defaults: b3CacheDefaults)
check(AccountProfileCacheStore.load(directory: b3CacheDir, defaults: b3CacheDefaults) == nil,
      "clearing the cache removes offline restore data")

let b3DraftDir = FileManager.default.temporaryDirectory.appendingPathComponent("boji-b3-draft-" + UUID().uuidString, isDirectory: true)
let b3DraftDefaults = UserDefaults(suiteName: "boji-b3-draft-" + UUID().uuidString)!
let b3DraftData = Data("draft-payload".utf8)
check(OnboardingDraftStore.save(b3DraftData, owner: 7, directory: b3DraftDir, defaults: b3DraftDefaults),
      "onboarding draft saves to a protected file")
check(b3DraftDefaults.data(forKey: "onboarding.design2.7") == nil,
      "onboarding draft is no longer a UserDefaults blob")
check(OnboardingDraftStore.load(owner: 7, directory: b3DraftDir, defaults: b3DraftDefaults) == b3DraftData,
      "onboarding draft reloads")
b3DraftDefaults.set(b3DraftData, forKey: "onboarding.design2.7")
check(OnboardingDraftStore.load(owner: 7, directory: b3DraftDir, defaults: b3DraftDefaults) == b3DraftData,
      "legacy onboarding draft still loads during migration")
check(b3DraftDefaults.data(forKey: "onboarding.design2.7") == nil,
      "legacy onboarding draft is removed after protected write")
OnboardingDraftStore.clear(owner: 7, directory: b3DraftDir, defaults: b3DraftDefaults)
check(OnboardingDraftStore.load(owner: 7, directory: b3DraftDir, defaults: b3DraftDefaults) == nil,
      "clearing onboarding draft removes offline data")

print("Batch 3 client rules passed: \(tests) combined checks")
''')

Path(sys.argv[1]).write_text(fixture + "\n\n" + "\n\n".join(appendix) + "\n", "utf-8")
