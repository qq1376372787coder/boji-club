"""Extract production rules. SDK, storage and unrelated reconciliation are fixtures.
Run with tests/run_repair_v77.sh on a Mac; this is not an iPhone UI test.
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
models=read('Models.swift');daily=read('DailyExperience.swift');health=read('HealthData.swift');cloud=read('CloudSync.swift');journey=read('JourneyRules.swift');app=read('AppStore.swift');history=read('ClubHistory.swift')
parts=['import Foundation',block(models,'enum ClubDates {'),block(read('RecordReliability.swift'),'final class ClubDateFormatterCache:'),block(read('AIService.swift'),'enum JSONValue:'),block(history,'enum PlanManagementRules {')]
for marker in ['struct TrainingSet:','struct Exercise:','struct CustomExercise:','struct WorkoutBaselineSet:','struct WorkoutExecutionBaseline:','struct WorkoutPauseInterval:','struct WorkoutSession:']:
 parts.append(block(models,marker))
parts.append('enum ExerciseNames { static func display(_ value:String,id:String?,query:String?)->String { value } }')
parts.append('enum RecordLimits { '+daily[daily.index('static let maximumWeight'):daily.index('static func valid(_ meal:')].strip()+' }')
for marker in ['struct HealthSource:','struct DeviceWorkout:']:parts.append(block(health,marker))
parts.append(block(daily,'struct WorkoutStopwatch:'))
parts.append(r'''
struct Meal:Codable { var id=UUID();var photoRemoteID:String?;var photoFilename:String? }
struct Review:Codable { var id=UUID() }
struct HealthDay:Codable { var workouts:[DeviceWorkout]=[] }
struct NutritionTarget:Codable { var calories=0;var generalGuidanceOnly:Bool?=nil }
struct PlanActionStub:Codable { var planID:String="";var kind:String="";var exerciseIDs:[String]=[];var clearsCycle:Bool? }
struct TrainingCycle:Codable { var sourceJobID:String?;var start:String;var plannedDates:[String]=[] }
struct DayLog:Codable {
 var exercises:[Exercise]=[];var meals:[Meal]=[];var health:HealthDay?
 var workoutStartedAt:Date?;var workoutEndedAt:Date?;var workoutSavedAt:Date?;var linkedDeviceWorkoutID:String?
 var workoutSessions:[WorkoutSession]?;var activeWorkoutSessionID:UUID?;var nutritionTarget:NutritionTarget?
 var planCycle:TrainingCycle?;var planActions:[PlanActionStub]?
 var weeklyReviewHistory:[Review]?;var weeklyReviews:[Review] { weeklyReviewHistory ?? [] }
 var completedSets:Int { exercises.flatMap(\.sets).filter(\.validCompletion).count }
''')
parts.append(block(models,'var trainingLog: DayLog')+'\n}')
for marker in ['enum EmptyWorkoutSessionRules {','enum CustomBackupRules {','enum PlanWeightReference {']:parts.append(block(journey,marker))
parts.append(block(health,'enum WorkoutAssociation {'))
parts.append(r'''
struct Job:Codable { var id:String }
struct CloudState:Codable {
 var days:[String:DayLog]=[:];var customExercises:[CustomExercise]?;var deletedCustomExerciseIDs:[String]?
 var deletedExerciseIDs:[String]?;var deletedMealIDs:[String]?;var deletedAIJobIDs:[String]?;var aiJobs:[Job]?
}
// Outside the tested merge/deletion scope, keep validation and unrelated domain rules inert.
enum TrainingExecutionCapture { static func reconcile(_ day:inout DayLog,base:DayLog?,local:DayLog?,remote:DayLog?) {} }
enum RecordIntegrity { static func validateConfirmation(_ day:inout DayLog,local:DayLog?,remote:DayLog?) throws {} }
enum WeeklyVersions { static func reconcile(_ day:inout DayLog) {} }
enum MealPlacement { static func reconcile(days:inout [String:DayLog],base:[String:DayLog]) {} }
''')
parts.append(block(daily,'enum WorkoutSessions {'))
parts.append('enum MealNutritionMerge { '+block(models,'enum NutritionSource {')+'\n'+block(models,'static func nutritionSource(')+' }')
parts.append(block(cloud,'enum CloudMerge {'))
for marker in ['struct CloudMergeWork:','struct CloudMergeComputation:','struct CloudComparisonWork:','enum CloudBackgroundWork {','enum CloudSyncError:']:parts.append(block(cloud,marker))
parts.append(r'''
@MainActor final class StoreFixture {
 var state:CloudState;var generation=UUID();var localEditRevision=UUID();var aiService:JobsFixture?=JobsFixture()
 init(_ state:CloudState) { self.state=state }
 func snapshot(includeLocalPhotos:Bool=false)->CloudState { state }
 func checkContext(_ ticket:UUID,_ id:Int)throws { if ticket != generation { throw CancellationError() } }
}
@MainActor final class JobsFixture { var cloudChangeID=UUID() }
enum ControlledWork {
 @MainActor static var calls=0
 @MainActor static var before:((Int)->Void)?
 @MainActor static func merge(_ input:CloudMergeWork) async throws -> CloudMergeComputation {
  calls+=1;before?(calls);return try await CloudBackgroundWork.merge(input)
 }
}
extension StoreFixture {
''')
parts.append(block(app,'private func mergeCloudSnapshot(').replace('private func','func').replace('CloudBackgroundWork.merge(input)','ControlledWork.merge(input)')+'\n}')
parts.append(r'''
struct TargetState { var nutritionTarget:NutritionTarget? }
struct TargetStore { var state=TargetState();var day=DayLog();func log(for date:Date)->DayLog { day }
''')
parts.append(block(app,'func reportNutritionTarget(')+'\n}')
parts.append(r'''
final class RemovalStore {
 var day:DayLog;var message:String?;var writesAllowed=true
 init(_ day:DayLog) { self.day=day }
 func log(for date:Date)->DayLog { day }
 // Only persistence is substituted: production deletion and session rules run below.
 func mutate(_ date:Date,edit:(inout DayLog)->Void)->Bool {
  let before=day;edit(&day)
  if !writesAllowed { day=before;return false }
  WorkoutSessions.synchronize(&day);return true
 }
''')
parts.append(block(app,'func removeEmptyWorkoutSession(')+'\n}')
parts.append(r'''
var checks=0
func check(_ value:Bool,_ label:String) { if !value { fatalError(label) };checks+=1 }
let now=Date(timeIntervalSince1970:1_800_000_000)
var timer=WorkoutStopwatch();timer.start(at:now);timer.pause(at:now.addingTimeInterval(7200))
check(timer.elapsed(at:now)==7200,"two-hour timer not truncated")
timer.start(at:now);timer.pause(at:now.addingTimeInterval(300));check(timer.elapsed(at:now)==7500,"paused timer resumes consistently")
check(RecordLimits.valid(TrainingSet(reps:300)),"actual repetition range includes 300")
check(RecordLimits.valid(TrainingSet(reps:0,durationSeconds:21600)),"six-hour actual timer accepted")
check(!RecordLimits.valid(TrainingSet(reps:0,durationSeconds:21601)),"invalid actual time rejected")
check(!RecordLimits.valid(TrainingSet(weight:.infinity)),"non-finite actual weight rejected")
let first=UUID(),second=UUID()
var empty=DayLog(workoutSessions:[WorkoutSession(id:first),WorkoutSession(id:second)],activeWorkoutSessionID:second)
check(EmptyWorkoutSessionRules.canRemove(second,from:empty),"blank extra session removable")
var started=empty;started.workoutSessions?[1].startedAt=now
check(!EmptyWorkoutSessionRules.canRemove(second,from:started),"started session protected")
var occupied=empty;occupied.exercises=[Exercise(name:"训练",muscle:"胸",sets:[TrainingSet()],workoutSessionID:second)]
check(!EmptyWorkoutSessionRules.canRemove(second,from:occupied),"unstarted session with action protected")
var only=empty;only.workoutSessions=[WorkoutSession(id:second)]
check(!EmptyWorkoutSessionRules.canRemove(second,from:only),"last session protected")
let removal=RemovalStore(empty)
check(removal.removeEmptyWorkoutSession(second,on:now) && removal.day.activeWorkoutSessionID==first && removal.day.workoutSessions?.count==1,"deletion restores the remaining active session")
let failedRemoval=RemovalStore(empty);failedRemoval.writesAllowed=false
check(!failedRemoval.removeEmptyWorkoutSession(second,on:now) && failedRemoval.day.workoutSessions?.count==2 && failedRemoval.day.activeWorkoutSessionID==second,"failed storage keeps original sessions")
var custom=CustomExercise(name:"私人动作",muscle:"胸",unit:"次")
let restored=CustomBackupRules.recover([custom,custom],into:[],deleted:[])
check(restored.count==1 && restored[0].id==custom.id,"definitions restored once with original ID")
var edited=custom;edited.name="本机修改"
check(CustomBackupRules.recover([custom],into:[edited],deleted:[]).first?.name=="本机修改","backup cannot replace current definition")
check(CustomBackupRules.recover([custom],into:[],deleted:[custom.id.uuidString.lowercased()]).isEmpty,"deleted definition cannot resurrect")
custom.name="";check(CustomBackupRules.recover([custom],into:[],deleted:[]).isEmpty,"invalid definition rejected")
let running=Exercise(name:"跑步",muscle:"有氧",sets:[TrainingSet(reps:0,completed:true,durationSeconds:1200)],libraryID:"0685",workoutSessionID:first)
let lifting=Exercise(name:"卧推",muscle:"胸",sets:[TrainingSet(reps:10,completed:true)],libraryID:"0001",workoutSessionID:first)
var day=DayLog(exercises:[running],workoutStartedAt:now,workoutEndedAt:now.addingTimeInterval(1200),workoutSessions:[WorkoutSession(id:first),WorkoutSession(id:second,linkedDeviceWorkoutID:"reserved")],activeWorkoutSessionID:first)
let source=HealthSource(id:"watch",name:"手表")
func watch(_ id:String,_ kind:String)->DeviceWorkout { DeviceWorkout(id:id,name:"测试",start:now,end:now.addingTimeInterval(1200),minutes:20,source:source,activityKind:kind) }
let candidates=[watch("run","running"),watch("lift","strength"),watch("reserved","running")]
check(WorkoutAssociation.suggestedIDs(for:day,workouts:candidates)==["run"],"cardio matches running and excludes other session's linked workout")
day.exercises=[lifting];check(WorkoutAssociation.suggestedIDs(for:day,workouts:candidates)==["lift"],"strength still matches strength")
day.exercises=[lifting,running];check(WorkoutAssociation.suggestedIDs(for:day,workouts:candidates).isEmpty,"mixed workout requires explicit selection")
day.exercises[0].customExerciseID=UUID();check(WorkoutAssociation.expectedKind(for:day)==nil,"unknown private movement not guessed")
let key="2027-01-15"
let base=CloudState(days:[key:empty]);var local=base;local.days[key]?.workoutSessions?.removeLast()
let deleted=try CloudMerge.merge(local:local,remote:base,base:base)
check(deleted.days[key]?.workoutSessions?.count==1,"sync preserves intended blank deletion")
var remote=base;remote.days[key]?.workoutSessions?[1].startedAt=now
let concurrent=try CloudMerge.merge(local:local,remote:remote,base:base)
check(concurrent.days[key]?.workoutSessions?.count==2 && concurrent.days[key]?.workoutSessions?.last?.startedAt==now,"concurrent start survives blank deletion")
var target=TargetStore();target.state.nutritionTarget=NutritionTarget(calories:2100);target.day.nutritionTarget=NutritionTarget(calories:1800)
check(target.reportNutritionTarget(on:now)?.calories==1800,"historical target takes precedence")
target.state.nutritionTarget=NutritionTarget(generalGuidanceOnly:true)
check(target.reportNutritionTarget(on:now)?.generalGuidanceOnly==true,"special-background safeguard retained")
let background=try await CloudBackgroundWork.merge(.init(local:local,remote:base,base:base))
check(try CloudMerge.same(background.state,deleted),"background merge equals synchronous production merge")
let races=Task { @MainActor in
 let fixture=StoreFixture(base);let ticket=fixture.generation;ControlledWork.calls=0
 ControlledWork.before={ call in if call==1 { fixture.state.days[key]?.exercises=[lifting];fixture.localEditRevision=UUID() } }
 let merged=try await fixture.mergeCloudSnapshot(base,base:base,ticket:ticket,userID:1)
 check(ControlledWork.calls==2 && merged.state.days[key]?.exercises.count==1,"edit during detached merge retries and retains new record")
 ControlledWork.calls=0;ControlledWork.before={ _ in fixture.localEditRevision=UUID() }
 do { _=try await fixture.mergeCloudSnapshot(base,base:base,ticket:ticket,userID:1);fatalError("unbounded changing state should wait") }
 catch CloudSyncError.busy(_) { check(ControlledWork.calls==4,"continual changes produce bounded retry and keep records") }
 ControlledWork.before=nil
}
try await races.value
print("v77 production rule checks passed: \(checks)")
''')
if '--benchmark' in sys.argv:
 parts.append(r'''
// Synthetic history excludes photo bytes and inactive SDK/storage rules. This is
// a CPU sample of merge/comparison, not an iPhone frame-rate or full sync result.
for count in [90,365,730] {
 var records:[String:DayLog]=[:]
 for offset in 0..<count {
  let date=ClubDates.calendar.date(byAdding:.day,value:-offset,to:now)!
  records[ClubDates.key(date)]=DayLog(exercises:(0..<6).map { _ in Exercise(name:"样本训练",muscle:"胸",sets:(0..<4).map { _ in TrainingSet(weight:20,reps:10,completed:true) }) })
 }
 let history=CloudState(days:records)
 let began=Date()
 _=try await CloudBackgroundWork.merge(.init(local:history,remote:history,base:history))
 let mergedTime=Date().timeIntervalSince(began)
 let compared=Date()
 _=try await CloudBackgroundWork.same(.init(left:history,right:history))
 print("history_days=\(count) background_merge_seconds=\(mergedTime) comparison_seconds=\(Date().timeIntervalSince(compared))")
}
''')
Path(sys.argv[1]).write_text('\n'.join(parts),'utf-8')
print('Generated v77 Foundation regression tests; execution requires a Mac.')
