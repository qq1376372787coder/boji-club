"""Build a test of production Swift rules with memory persistence fixtures.

UIKit and HealthKit query APIs are not emulated or validated by this harness.
Run: python3 tests/build_phase1_swift_tests.py /tmp/boji-phase1.swift
     swift /tmp/boji-phase1.swift
"""
import hashlib,json,re,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def read(name): return (ROOT/'BojiClub'/name).read_text('utf-8')
def method(source,name):
    match=re.search(r'^    (?:private )?func '+re.escape(name)+r'\(',source,re.M)
    assert match,name
    opening=source.index('{',match.start())
    depth=1;end=opening+1
    while depth:
        if source[end]=='{': depth+=1
        elif source[end]=='}': depth-=1
        end+=1
    return source[match.start():end].replace('private func mutate','func mutate')
health=read('HealthData.swift')
health=health[health.index('struct HealthSource:'):health.index('private struct HealthLocalState:')]+'\n'+health[health.index('enum WorkoutAssociation {'):]
ai=read('AIService.swift');ai=ai[ai.index('enum JSONValue:'):ai.index('@MainActor')]
batch=read('MealBatchReviewView.swift');batch=batch[batch.index('struct AIBatchMeal:'):batch.index('private struct SavedBatchMeal')]
ai=batch+'\n'+ai
food=read('FoodComponents.swift');food=food[food.index('struct FoodComponent:'):food.index('struct FoodCompositionEditor:')]
library=read('ExerciseLibraryView.swift');library=library[library.index('struct LibraryExercise:'):library.index('struct LibraryExerciseDetail:')]
store=read('AppStore.swift')
methods=['log','saveProfile','saveWorkout','saveHealth','removeHealth','updateSet','removeSet','removeExercise','hasAppliedAIJob','mutate','applyAIPlan','applyWeeklyPlan','continuationSessions','recordPlanHistory','recordWeeklyPlanHistory','historyProfile']
store_code='\n'.join(method(store,name) for name in methods)
extensions=store[store.index('\nextension AppStore {'):]
# Build 132 moved the plan list out of PlanManagement.swift; only the row model
# still lives here. Pin the slice to the next declaration so the harness does not
# depend on a removed type name.
plan_management=read('PlanManagement.swift'); plan_management=plan_management[plan_management.index('struct ManagedPlan:'):plan_management.index('struct ManagedPlanDetail132:')]
editor=read('ManagedPlanEditor126.swift'); editor=editor[editor.index('struct PlanEditDay126:'):editor.index('struct ManagedPlanEditor126:')]
plan_management=editor+'\n'+plan_management
fixtures=plan_management+r'''
struct WeeklyReview: Codable { var id = UUID() }
func equipmentName(_ value: String) -> String { value }
func muscleName(_ value: String) -> String { value }
final class AppStore {
    var state = SavedState()
    var message: String?
    var editingAccountID: Int? = 1
    var allowPersistence = true
    var canSave = true
    var activeAccountID: Int? { editingAccountID }
    var aiService: AIService? { nil }
    var writtenDates: [String] = []
    var stableIDs: [String:UUID] = [:]
    func stableID(_ key: String) -> UUID {
        if let value = stableIDs[key] { return value }
        let value = UUID(); stableIDs[key] = value; return value
    }
    func persist(changedDates: [String]) -> Bool { writtenDates = changedDates; return allowPersistence }
    // Phase 1: the production write paths enqueue domain commands; the queue
    // itself lives outside this fixture (ClubProposalSync.swift + AppStore
    // class body), so the extracted methods only need inert hooks here.
    func enqueueTrainingStartIfNeeded(for date: Date) {}
    func enqueueTrainingFinishIfNeeded(for date: Date, now: Date) {}
    func enqueueSetRecord(_ set: TrainingSet, exerciseID: UUID, date: Date, original: TrainingSet, correcting: Bool) {}
    func enqueueMealRecordIfNeeded(_ meal: Meal, date: Date) {}
    func enqueueBodyWeightRecordIfNeeded(for date: Date, kilograms: Double?, bodyFatPercentage: Double?, waistCircumferenceCM: Double?, now: Date, measurementID: UUID) {}
    static func mergeHealthMeasurements(_ shared: HealthDay, into day: inout DayLog) {}
'''+store_code+'\n}\n'+extensions
checks=r'''
var checks = 0
func check(_ value: Bool, _ label: String) {
    guard value else { fatalError("FAILED: \(label)") }
    checks += 1; print("PASS \(label)")
}
func rejected(_ label: String, _ operation: () throws -> Void) {
    do { try operation(); fatalError("FAILED: \(label)") } catch { check(true,label) }
}
let now = Date()
let today = ClubDates.key(now)
let yesterday = ClubDates.calendar.date(byAdding:.day,value:-1,to:now)!
let tomorrow = ClubDates.calendar.date(byAdding:.day,value:1,to:now)!
let finished = TrainingSet(weight:30,reps:8,completed:true)
let pending = TrainingSet(weight:60,reps:12)
let old = Exercise(name:"卧推",muscle:"胸",sets:[finished,pending],libraryID:"0025")
let replacement = Exercise(name:"俯卧撑",muscle:"胸")
let partial = DayLog(exercises:[old],workoutSavedAt:now)
let replaced = try WorkoutEditing.replacing(old,with:replacement,in:partial)
check(replaced.exercises.count == 2,"partial replacement keeps completed exercise")
check(replaced.exercises[0].sets[0].id == finished.id,"completed set identity retained")
check(replaced.exercises[0].sets[0].weight == 30 && replaced.exercises[0].name == "卧推","recorded movement and load retained")
check(replaced.exercises[1].sets.count == 1 && replaced.exercises[1].sets[0].weight == 0,"new movement load reset")
check(!replaced.exercises[1].sets[0].completed,"new movement is uncompleted")
check(replaced.workoutSavedAt == nil,"new workout confirmation required")
check(replaced.exercises[0].deletedSetIDs == [pending.id.uuidString],"removed pending set has tombstone")
var unstarted=old;unstarted.sets=[pending]
let one=try WorkoutEditing.replacing(unstarted,with:replacement,in:DayLog(exercises:[unstarted]))
check(one.exercises.count == 1 && one.exercises[0].id != old.id,"unstarted replacement creates one new movement")
var allDone=old;allDone.sets=[finished]
rejected("completed movement cannot be overwritten") { _=try WorkoutEditing.replacing(allDone,with:replacement,in:DayLog(exercises:[allDone])) }
rejected("missing original rejected") { _=try WorkoutEditing.replacing(old,with:replacement,in:DayLog()) }
let full=DayLog(exercises:[old]+(0..<29).map { _ in replacement })
rejected("daily movement limit respected") { _=try WorkoutEditing.replacing(old,with:replacement,in:full) }
check(WorkoutEditing.isProtected(partial),"confirmed day protected")
check(WorkoutEditing.isProtected(DayLog(exercises:[unstarted],workoutStartedAt:now)),"started day protected")
check(!WorkoutEditing.isProtected(DayLog(exercises:[unstarted])),"unstarted day editable")

let a=HealthSource(id:"watch",name:"Watch"), b=HealthSource(id:"sync",name:"Sync")
let start=now.addingTimeInterval(-3600)
let watch=DeviceWorkout(id:"watch-1",name:"力量训练",start:start,end:now,minutes:60,calories:200,source:a,activityKind:"strength")
var mirror=watch;mirror.id="mirror";mirror.source=b
check(HealthDay.deduplicated([mirror,watch],preferred:"watch").map(\.id) == ["watch-1"],"same activity across sources deduplicated")
var other=mirror;other.activityKind="running";other.name="跑步"
check(HealthDay.deduplicated([watch,other],preferred:"").count == 2,"overlapping different activities preserved")
var same=watch;same.id="watch-2"
check(HealthDay.deduplicated([watch,same],preferred:"").count == 2,"two records from one source preserved")
var unknown=mirror;unknown.activityKind=nil;unknown.name="运动"
check(HealthDay.deduplicated([watch,unknown],preferred:"").count == 2,"unknown activity not silently deleted")
check(HealthDay.deduplicated([watch,watch],preferred:"").count == 1,"same record ID deduplicates")
let session=DayLog(exercises:[old],workoutStartedAt:start,workoutEndedAt:now)
check(WorkoutAssociation.suggestedIDs(for:session,workouts:[watch,other]) == [watch.id],"only matching strength session suggested")
check(WorkoutAssociation.suggestedIDs(for:DayLog(),workouts:[watch]).isEmpty,"missing start time never guessed")
let abandoned=DayLog(workoutStartedAt:now.addingTimeInterval(-8*3600),workoutEndedAt:now)
check(WorkoutAssociation.suggestedIDs(for:abandoned,workouts:[watch]).isEmpty,"abandoned start cannot produce confident match")
let legacy=try JSONDecoder().decode(DayLog.self,from:Data("{\"exercises\":[],\"meals\":[]}".utf8))
check(legacy.workoutStartedAt == nil && legacy.nutritionTarget == nil,"old day decodes")
var legacyWatch=try JSONSerialization.jsonObject(with:JSONEncoder().encode(watch)) as! [String:Any]
legacyWatch.removeValue(forKey:"activityKind");legacyWatch.removeValue(forKey:"averageHeartRate")
let decoded=try JSONDecoder().decode(DeviceWorkout.self,from:JSONSerialization.data(withJSONObject:legacyWatch))
check(decoded.averageHeartRate == nil && decoded.comparableKind == "strength","old device data has no invented heart rate")

var local=SavedState();local.days[today]=replaced
var remote=SavedState();remote.days[today]=partial
let merged=try CloudMerge.merge(local:CloudState(local),remote:CloudState(remote),base:nil)
check(merged.days[today]!.exercises.flatMap(\.sets).allSatisfy { $0.id != pending.id },"stale first sync cannot resurrect removed pending set")
check(merged.days[today]!.completedSets == 1,"cloud merge preserves completed set")

let store=AppStore();store.state.days[ClubDates.key(yesterday)]=partial
// factState 为空字典表示“逐字段来源未知”，默认资料会被当作未确认，
// 营养目标只给通用说明。这里验证历史版本目标冻结，按旧资料语义置 nil。
store.state.profile.factState=nil
store.state.nutritionTarget=NutritionTarget.estimate(store.state.profile)
let oldTarget=store.state.nutritionTarget!
var profile=store.state.profile;profile.weight=90;profile.trainingDays=[1,3,5]
check(store.saveProfile(profile),"profile save succeeds")
check(store.state.profile.weight == 90 && store.state.nutritionTarget != oldTarget,"profile updates current target")
check(store.nutritionTarget(on:yesterday) == oldTarget,"historical target retained")
check(store.writtenDates.contains(ClubDates.key(yesterday)),"historical target included in journal")
let before=store.state;store.allowPersistence=false;profile.weight=100
check(!store.saveProfile(profile),"failed profile save reported")
check(try CloudMerge.same(before,store.state),"failed profile save rolls back")
store.allowPersistence=true
check(!store.beginWorkout(on:yesterday),"historical record never gets current start")
store.state.days[today]=DayLog(exercises:[unstarted])
check(store.beginWorkout(on:now),"explicit start recorded")
let recordedStart=store.log(for:now).workoutStartedAt
check(!store.beginWorkout(on:now) && store.log(for:now).workoutStartedAt == recordedStart,"repeated start does not reset time")
check(!store.saveWorkout(on:now),"zero completed sets cannot be confirmed")
store.state.days[today]=session
check(store.saveWorkout(on:now),"completed session saves")
let recordedEnd=store.log(for:now).workoutEndedAt
check(store.saveWorkout(on:now) && store.log(for:now).workoutEndedAt == recordedEnd,"resave does not move workout end")
let health=HealthDay(date:today,timeZone:"Asia/Shanghai",updatedAt:now,workouts:[watch])
check(!store.linkDeviceWorkout(watch.id,on:now),"local-only health cannot be implicitly uploaded by link")
check(store.saveHealth(health,on:now),"confirmed health saves")
check(store.linkDeviceWorkout(watch.id,on:now),"explicit existing link saves")
check(!store.linkDeviceWorkout("unknown",on:now),"missing device ID rejected")
var emptyHealth=health;emptyHealth.workouts=[]
check(store.saveHealth(emptyHealth,on:now) && store.log(for:now).linkedDeviceWorkoutID == nil,"disappeared shared workout clears link")
_=store.saveHealth(health,on:now);_=store.linkDeviceWorkout(watch.id,on:now)
var undone=finished;undone.completed=false
// 已确认场次不能切换完成状态（AppStore.updateSet 的 correcting 分支），
// 设备运动关联也随原记录保留，避免确认后的历史被静默改写。
check(!store.updateSet(undone,exerciseID:old.id,on:now) && store.log(for:now).linkedDeviceWorkoutID == watch.id,"confirmed workout completion cannot be undone")

let planning=AppStore();planning.state.profile.trainingDays=[(ClubDates.calendar.component(.weekday,from:tomorrow)+5)%7+1]
let keys=(0..<7).map { ClubDates.key(ClubDates.calendar.date(byAdding:.day,value:$0,to:tomorrow)!) }
for key in keys { planning.state.days[key]=DayLog(exercises:[unstarted]) }
planning.state.days[keys[1]]=DayLog(exercises:[old],workoutSavedAt:now)
planning.state.days[keys[2]]=DayLog(exercises:[unstarted],workoutStartedAt:now)
planning.state.days[keys[3]]!.meals=[Meal(name:"test",category:"午餐",calories:100,protein:10,carbs:10,fat:2)]
let newSession=AIPlanSession(date:keys[0],label:"new",exercises:[AIPlanExercise(name:"深蹲",muscle:"腿",sets:[AIPlanSet(weight:20,reps:8)],library_query:nil)])
let plan=AIResult(kind:"plan",notes:[],sessions:[newSession])
check(planning.applyProfilePlan(plan,jobID:"profile",start:tomorrow),"whole selected profile week updates")
check(planning.state.days[keys[0]]!.exercises.first!.name == "深蹲","planned day replaced")
check(planning.state.days[keys[3]]!.exercises.isEmpty,"removed training day becomes rest")
check(planning.state.days[keys[3]]!.meals.count == 1,"rest-day update preserves meals")
check(planning.state.days[keys[1]]!.completedSets == 1,"completed day retained during replan")
check(planning.state.days[keys[2]]!.exercises.first!.name == unstarted.name,"started day retained during replan")
let appliedState=planning.state
check(planning.applyProfilePlan(plan,jobID:"profile",start:tomorrow),"same plan reapply succeeds")
check(try CloudMerge.same(appliedState,planning.state),"same plan reapply is idempotent")
let failed=AppStore();failed.state.profile.trainingDays=planning.state.profile.trainingDays;failed.allowPersistence=false
let failedBefore=failed.state
check(!failed.applyProfilePlan(plan,jobID:"fail",start:tomorrow),"plan persistence failure reported")
check(try CloudMerge.same(failedBefore,failed.state),"plan persistence failure rolls back all days and tombstones")
check(!planning.applyProfilePlan(plan,jobID:"past",start:yesterday),"profile plan cannot replace past")
var duplicate=plan;duplicate.sessions=[newSession,newSession]
check(!planning.applyProfilePlan(duplicate,jobID:"dup",start:tomorrow),"duplicate plan dates rejected")
print("PASS \(checks) production Swift rule checks; UIKit/HealthKit need Xcode/iPhone")
'''
weekly=read('WeeklyReview.swift')
weekly_types=weekly[weekly.index('struct WeeklySurvey:'):weekly.index('extension WeeklyReview {')]
fixtures=fixtures.replace('struct WeeklyReview: Codable { var id = UUID() }',weekly_types)
output=Path(sys.argv[1])
reliability = read('RecordReliability.swift')
date_cache = reliability[reliability.index('final class ClubDateFormatterCache:'):reliability.index('struct PhotoSyncIssue:')]
stubs='''
struct ManualPlanDraft: Codable {}
struct ManualPlanTemplate: Codable {}
struct WorkoutPauseState: Codable, Equatable {
    var pausedAt: Date?
    var accumulated: TimeInterval
    var sessionID: UUID?
    var isPaused: Bool { pausedAt != nil }
    func elapsed(startedAt: Date, now: Date = Date()) -> TimeInterval {
        guard startedAt <= now else { return 0 }
        return max(0, (pausedAt ?? now).timeIntervalSince(startedAt) - max(0, accumulated))
    }
}
struct ClubCoachSource: Codable, Equatable {}
struct ClubCoachAction: Codable, Equatable {}
struct ClubParameterProposal: Codable, Equatable {}
struct ClubScheduleProposal: Codable, Equatable {}
struct ClubCoachAnswer: Codable, Equatable {
    var answer: String; var sources: [ClubCoachSource]; var actions: [ClubCoachAction]
    var purpose: String? = nil; var source_session: String? = nil
    var proposal: ClubParameterProposal? = nil; var schedule_proposal: ClubScheduleProposal? = nil
}
struct AccountRawResponse { let statusCode: Int; let data: Data }
@MainActor final class AccountService {
    static let previewUserID = -1001
    func cloudRequest(path: String, method: String = "GET", body: Data? = nil,
                      expectedUserID: Int, deadline: Date? = nil) async throws -> AccountRawResponse {
        AccountRawResponse(statusCode: 200, data: Data())
    }
}
final class AIService { func job(_ id: String) -> AILocalJob? { nil } }
'''
stubs += '\nimport CoreGraphics\n' + read('JourneyRules.swift')
shift_source=read('PlanShiftViews.swift')
stubs += '\n' + shift_source[shift_source.index('struct PlanShiftRecord:'):shift_source.index('struct PlanMoveSheet: View')]
stubs += '\n' + read('ClubHistory.swift')
stubs += '\n' + read('ClubInsightRules.swift') + '\n' + read('ClubInsightLedger.swift') + '\n' + read('TrendAnalysis.swift') + '\n' + read('ClubWorkoutSummary.swift')
output.write_text('\n'.join([read('Models.swift'),stubs,date_cache,read('DailyExperience.swift'),health,ai,food,library,read('CloudSync.swift'),fixtures,checks]),'utf-8')
print(json.dumps({'output':str(output),'sha256':hashlib.sha256(output.read_bytes()).hexdigest(),'scope':'Production Swift Foundation rules with memory fixtures; not an iOS build'}))
