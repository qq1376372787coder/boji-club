"""Extract actual production plan transactions and sync waiting methods.
Foundation fixtures replace disk/cloud I/O only; run on Mac, not a SwiftUI/device test.
"""
from pathlib import Path
import sys
root=Path(__file__).resolve().parents[1]/'BojiClub'
def read(name):return (root/name).read_text('utf-8')
def block(source,marker):
    start=source.index(marker);i=source.index('{',start);depth=1;j=i+1
    while depth:
        if source[j]=='{':depth+=1
        elif source[j]=='}':depth-=1
        j+=1
    return source[start:j]
models=read('Models.swift');ai=read('AIService.swift');app=read('AppStore.swift')
parts=['import Foundation',block(models,'enum ClubDates {'),block(read('RecordReliability.swift'),'final class ClubDateFormatterCache:'),block(models,'struct TrainingSet:'),block(models,'struct Exercise:')]
limits=read('DailyExperience.swift')
parts.append('enum RecordLimits { '+limits[limits.index('static let maximumWeight'):limits.index('static func valid(_ meal:')].strip()+' }')
for marker in ['struct AIPlanSet:','struct AIPlanExercise:','struct AIPlanSession:']:parts.append(block(ai,marker))
parts.append(r'''
enum ExerciseNames { static func display(_ value:String,id:String?,query:String?)->String { value } }
struct Explanation:Codable { var version=1 }
struct AIResult { var kind:String;var sessions:[AIPlanSession]?;var explanation:Explanation?;var plan_days:Int? }
struct WorkoutSession:Codable { var id=UUID();var startedAt:Date?;var savedAt:Date? }
struct HealthDay:Codable { var hasData=false }
struct BodyWeightEntry:Codable { var kilograms:Double? }
struct WeeklyStub:Codable { var result:String? }
struct MemberProfile:Codable { var trainingDays:[Int]?=[1,3,5] }
struct PlanActionStub:Codable { var planID:String="";var kind:String="";var exerciseIDs:[String]=[];var clearsCycle:Bool? }
struct DayLog:Codable {
    var exercises:[Exercise]=[];var meals:[String]=[];var health:HealthDay?;var bodyWeight:BodyWeightEntry?
    var workoutStartedAt:Date?;var workoutSavedAt:Date?;var workoutSessions:[WorkoutSession]?;var activeWorkoutSessionID:UUID?
    var planCycle:TrainingCycle?;var plannedMoveDestination:String?;var movedFromDate:String?;var weeklyReview:WeeklyStub?
    var planActions:[PlanActionStub]?;var workoutEndedAt:Date?
    var trainingLog:DayLog { self }
    var completedSets:Int { exercises.flatMap(\.sets).filter(\.validCompletion).count }
}
struct SavedState:Codable { var days:[String:DayLog]=[:];var profile=MemberProfile();var deletedExerciseIDs:[String]?;var appliedAIJobs:[String]? }
enum CloudMerge {
    static func same<T:Encodable>(_ a:T,_ b:T)throws->Bool { let e=JSONEncoder();e.outputFormatting=[.sortedKeys];return try e.encode(a)==e.encode(b) }
}
final class StoreFixture {
    var state=SavedState();var message:String?;var writesAllowed=true;var changedDates:[String]=[]
    func stableID(_ value:String)->UUID { UUID() }
    func hasAppliedAIJob(_ value:String)->Bool { state.appliedAIJobs?.contains(value)==true }
    func persist(changedDates:[String])->Bool { self.changedDates=changedDates;return writesAllowed }
    func recordPlanHistory(operationID:String,result:AIResult,start:Date,previous:SavedState,scope:[String],source:String?=nil,requestedJobID:String?=nil) {}
    func log(for date:Date)->DayLog { state.days[ClubDates.key(date)] ?? DayLog() }
''')
parts.append(block(read('ClubHistory.swift'),'enum PlanManagementRules {'))
parts.append(block(app,'func applyAIPlan('))
parts.append(block(app,'func continuationSessions(')+'\n}')
parts.append('enum WorkoutEditing { '+block(models,'static func isProtected(')+' }')
parts.append(block(read('DailyExperience.swift'),'struct TrainingCycle:'))
for marker in ['enum PlanAdoptionRules {','enum PlanContinuationRules {']:parts.append(block(read('JourneyRules.swift'),marker))
parts.append(block(read('CloudSync.swift'),'enum CloudSyncStatus:'))
parts.append(r'''
struct SyncUser { var id=1 }
struct SyncAccount { var user:SyncUser?=SyncUser() }
@MainActor final class SyncFixture {
    var canSave=true;var accountService:SyncAccount?=SyncAccount()
    var generation=UUID();var activeAccountID:Int?=1;var syncInProgress=false
    var syncWaiters:[UUID:CheckedContinuation<Bool,Never>]=[:]
    var syncStatus:CloudSyncStatus = .idle;var message:String?;var calls=0
    var nextStatus:CloudSyncStatus = .synced(Date())
    func syncNow() async { calls += 1;syncStatus=nextStatus }
''')
for marker in ['private func finishSyncWaiters(','private func waitForCurrentSync(','func syncForPlanAdoption(']:
    # Accelerate only the watchdog clock for the native test; production retains 60 seconds.
    parts.append(block(app,marker).replace('private func','func').replace('60_000_000_000','100_000_000'))
parts.append('}')
parts.append(r'''
func sortedJSON<T:Encodable>(_ value:T)throws->Data { let e=JSONEncoder();e.outputFormatting=[.sortedKeys];return try e.encode(value) }
var checks=0
func check(_ value:Bool,_ label:String) { guard value else { fatalError(label) };checks+=1 }
func day(_ key:String)->Date { ClubDates.date(fromKey:key)! }
func movement(_ name:String="旧动作")->Exercise { Exercise(name:name,muscle:"全身",sets:[TrainingSet(reps:10)]) }
let start=ClubDates.calendar.startOfDay(for:ClubDates.calendar.date(byAdding:.day,value:14,to:Date())!)
let keys=(0..<35).map { ClubDates.key(ClubDates.calendar.date(byAdding:.day,value:$0,to:start)!) }
func session(_ key:String)->AIPlanSession { AIPlanSession(date:key,label:"训练",exercises:[AIPlanExercise(name:"新动作",muscle:"全身",sets:[AIPlanSet(weight:10,reps:10)])]) }
func initial(_ duration:Int)->StoreFixture {
    let store=StoreFixture()
    for i in 0..<duration { store.state.days[keys[i]]=DayLog(exercises:[movement()],meals:["晚餐"],health:HealthDay(hasData:true),bodyWeight:BodyWeightEntry(kilograms:68)) }
    return store
}
for duration in [7,14,28] {
    let store=initial(duration);let baseline=store.state.days
    let oldIDs=baseline.values.flatMap { $0.exercises.map { $0.id.uuidString } }
    let training=(0..<duration).filter { $0%7==0 || $0%7==2 || $0%7==4 }.map { session(keys[$0]) }
    let result=AIResult(kind:"plan",sessions:training,plan_days:duration)
    check(store.applyAIPlan(result,jobID:"replace-\(duration)",replaceUnstarted:true,cycleStart:start,expectedDays:baseline),"replace entire \(duration)-day window")
    for i in 0..<duration {
        check(store.state.days[keys[i]]?.exercises.isEmpty == !(i%7==0 || i%7==2 || i%7==4),"rest days have no residual training")
        check(store.state.days[keys[i]]?.meals==["晚餐"] && store.state.days[keys[i]]?.bodyWeight?.kilograms==68 && store.state.days[keys[i]]?.health?.hasData==true,"food, weight, health retained")
    }
    check(Set(oldIDs).isSubset(of:Set(store.state.deletedExerciseIDs ?? [])),"deleted movement tombstones prevent sync resurrection")
    check(Set(keys.prefix(duration)).isSubset(of:Set(store.changedDates)),"all replaced dates persisted")
    let saved=try sortedJSON(store.state)
    check(store.applyAIPlan(result,jobID:"replace-\(duration)",replaceUnstarted:true,cycleStart:start),"same AI job is idempotent")
    check(try sortedJSON(store.state)==saved,"duplicate AI apply does not mutate data")
}
let protected=initial(7)
protected.state.days[keys[1]]?.workoutSessions=[WorkoutSession(startedAt:Date())]
let protectedID=protected.state.days[keys[1]]!.exercises[0].id
check(protected.applyAIPlan(AIResult(kind:"plan",sessions:[session(keys[0])],plan_days:7),jobID:"protected",replaceUnstarted:true,cycleStart:start),"started rest day is preserved")
check(protected.state.days[keys[1]]?.exercises.first?.id==protectedID,"inactive started session survives rest-day cleanup")
check(protected.state.days[keys[1]]?.planCycle?.plannedDates.contains(keys[1])==true,"retained real training remains visible in cycle")
let rollback=initial(7);let before=try sortedJSON(rollback.state);rollback.writesAllowed=false
check(!rollback.applyAIPlan(AIResult(kind:"plan",sessions:[session(keys[0])],plan_days:7),jobID:"rollback",replaceUnstarted:true,cycleStart:start),"disk failure rejects save")
check(try sortedJSON(rollback.state)==before,"disk failure rolls back movements, tombstones, cycle and applied IDs")
let concurrent=initial(7);let snapshot=concurrent.state.days;concurrent.state.days[keys[1]]?.exercises.append(movement("临时加练"))
let concurrentBefore=try sortedJSON(concurrent.state)
check(!concurrent.applyAIPlan(AIResult(kind:"plan",sessions:[session(keys[0])],plan_days:7),jobID:"conflict",replaceUnstarted:true,cycleStart:start,expectedDays:snapshot),"changed rest-day plan rejects stale confirmation")
check(try sortedJSON(concurrent.state)==concurrentBefore,"conflict does not erase concurrent changes")
let append=initial(7)
check(append.applyAIPlan(AIResult(kind:"plan",sessions:[session(keys[0])],plan_days:7),jobID:"append",cycleStart:start),"append remains available")
check(append.state.days[keys[1]]?.exercises.count==1,"append does not clear rest-day existing plan")
let imported=initial(7)
check(imported.applyAIPlan(AIResult(kind:"plan",sessions:[session(keys[0])]),jobID:"import",replaceUnstarted:true),"sparse import succeeds")
check(imported.state.days[keys[1]]?.exercises.count==1,"sparse import does not infer missing rest days")
let source=initial(7)
let clipped=source.continuationSessions(starting:day(keys[5]),ending:day(keys[6]),nextStart:day(keys[14]))
check(clipped.count==2 && clipped.map(\.date)==[keys[14],keys[15]],"two-day cycle copies only its two dates")
let full=source.continuationSessions(starting:start,ending:day(keys[6]),nextStart:day(keys[14]))
check(full.count==7,"normal full-week source remains seven days")
check(source.continuationSessions(starting:start,ending:day(keys[7]),nextStart:day(keys[14])).isEmpty,"invalid overlong source rejected")
source.state.days[keys[1]]?.exercises=[]
check(source.continuationSessions(starting:start,ending:day(keys[6]),nextStart:day(keys[14])).map(\.date)==[keys[14],keys[16],keys[17],keys[18],keys[19],keys[20]],"source rest day retains offset instead of compressing schedule")
let copy=StoreFixture();let copied=AIResult(kind:"plan",sessions:clipped)
let firstID=PlanContinuationRules.operationID(UUID()),secondID=PlanContinuationRules.operationID(UUID())
check(firstID != secondID,"separate copy operations have distinct IDs")
check(copy.applyAIPlan(copied,jobID:firstID,cycleStart:day(keys[14])),"first copy adds actual training")
check(copy.applyAIPlan(copied,jobID:firstID,cycleStart:day(keys[14])) && copy.state.days[keys[14]]?.exercises.count==1,"same operation double tap does not duplicate")
for key in [keys[14],keys[15]] {
    let ids=copy.state.days[key]!.exercises.map { $0.id.uuidString }
    copy.state.deletedExerciseIDs=(copy.state.deletedExerciseIDs ?? [])+ids
    copy.state.days[key]?.exercises=[]
}
check(copy.applyAIPlan(copied,jobID:secondID,cycleStart:day(keys[14])),"new explicit operation can copy after deletion")
check(copy.state.days[keys[14]]?.exercises.count==1 && copy.state.days[keys[15]]?.exercises.count==1,"recopy success means real records exist")
let retry=StoreFixture();retry.writesAllowed=false
check(!retry.applyAIPlan(copied,jobID:firstID,cycleStart:day(keys[14])),"failed copy is not adopted")
retry.writesAllowed=true
check(retry.applyAIPlan(copied,jobID:firstID,cycleStart:day(keys[14])),"same operation can retry a disk failure")

let ranges=StoreFixture()
let rangeSessions=[AIPlanSession(date:keys[14],label:"实际次数",exercises:[AIPlanExercise(name:"自重训练",muscle:"全身",sets:[AIPlanSet(weight:0,reps:300)])]),
                   AIPlanSession(date:keys[15],label:"有氧训练",exercises:[AIPlanExercise(name:"骑行",muscle:"有氧",sets:[AIPlanSet(weight:0,reps:0,durationSeconds:7200)])])]
check(ranges.applyAIPlan(AIResult(kind:"plan",sessions:rangeSessions),jobID:"range-copy",cycleStart:day(keys[14])),"continuation accepts actual 300 reps and two-hour timing")
check(ranges.state.days[keys[14]]?.exercises.first?.sets.first?.reps==300 && ranges.state.days[keys[15]]?.exercises.first?.sets.first?.durationSeconds==7200,"copy does not clip real targets")
var tooLong=rangeSessions;tooLong[1].exercises[0].sets[0].durationSeconds=21601
let untouched=try sortedJSON(ranges.state)
let rangeRejected = !ranges.applyAIPlan(AIResult(kind:"plan",sessions:tooLong),jobID:"invalid-range",cycleStart:day(keys[14]))
let afterRejection = try sortedJSON(ranges.state)
check(rangeRejected && afterRejection==untouched,"invalid target cannot partly modify a plan")

let asyncTests=Task { @MainActor in
    let joining=SyncFixture();joining.syncInProgress=true;joining.syncStatus = .syncing
    let waiter=Task { await joining.syncForPlanAdoption(ownerID:1) }
    try? await Task.sleep(nanoseconds:10_000_000)
    check(joining.syncWaiters.count==1,"plan adoption really awaits active sync")
    joining.syncInProgress=false;joining.syncStatus = .synced(Date());joining.finishSyncWaiters(completed:true)
    let joined=await waiter.value
    check(joined && joining.calls==0 && joining.message==nil,"completed current sync succeeds without false offline message or redundant upload")
    let pending=SyncFixture();pending.syncInProgress=true;pending.syncStatus = .syncing
    let next=Task { await pending.syncForPlanAdoption(ownerID:1) }
    try? await Task.sleep(nanoseconds:10_000_000)
    pending.syncInProgress=false;pending.syncStatus = .pending;pending.finishSyncWaiters(completed:true)
    let nextResult=await next.value
    check(nextResult && pending.calls==1,"concurrent edits await an additional acknowledgment")
    let failed=SyncFixture();failed.nextStatus = .failed("写入失败")
    let failure=await failed.syncForPlanAdoption(ownerID:1)
    check(!failure && failed.message?.contains("写入失败")==true,"real failure exposes specific reason")
    let changed=SyncFixture();changed.syncInProgress=true
    let old=Task { await changed.syncForPlanAdoption(ownerID:1) }
    try? await Task.sleep(nanoseconds:10_000_000)
    changed.generation=UUID();changed.activeAccountID=2;changed.syncInProgress=false;changed.finishSyncWaiters(completed:false)
    let oldResult=await old.value
    check(!oldResult && changed.message==nil && changed.syncWaiters.isEmpty,"account switch releases old waiter without modifying new account message")
    let canceled=SyncFixture();canceled.syncInProgress=true
    let cancelTask=Task { await canceled.syncForPlanAdoption(ownerID:1) }
    try? await Task.sleep(nanoseconds:10_000_000);cancelTask.cancel()
    let canceledResult=await cancelTask.value
    check(!canceledResult && canceled.syncWaiters.isEmpty && canceled.message==nil,"cancellation releases continuation and does not overwrite message")
    let timeout=SyncFixture();timeout.syncInProgress=true
    let expired=await timeout.syncForPlanAdoption(ownerID:1)
    check(!expired && timeout.message?.contains("尚未完成")==true && timeout.syncInProgress && timeout.syncWaiters.isEmpty,"timeout explains waiting without canceling background sync")
    timeout.finishSyncWaiters(completed:true) // No double continuation resume after the watchdog fired.
}
await asyncTests.value
print("v76 production rule checks passed: \(checks)")
''')
Path(sys.argv[1]).write_text('\n'.join(parts),'utf-8')
print('Generated production plan and async sync tests (execution pending until Swift runtime is available).')
