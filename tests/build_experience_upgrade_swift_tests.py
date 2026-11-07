"""Exercise production adoption, lifecycle, merge and sleep rules; no UI/SDK stubs asserted as UI tests."""
from pathlib import Path
import subprocess,sys,tempfile
root=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory() as tmp:
 base=Path(tmp)/'base.swift'
 subprocess.run([sys.executable,str(root/'tests/build_product_consistency_swift_tests.py'),str(base)],check=True)
 content=base.read_text()
manual=(root/'BojiClub/ManualPlan.swift').read_text().split('enum ManualPlanDraftStorage {')[0]
experience=(root/'BojiClub/Experience130.swift').read_text()
recurrence=experience[experience.index('struct WeeklyRecurrence130:'):experience.index('enum WeeklyPlanRules130 {')]
manual=recurrence+'\n'+manual
content=content.replace('struct ManualPlanDraft: Codable {}',manual).replace('struct ManualPlanTemplate: Codable {}','')
health=(root/'BojiClub/HealthData.swift').read_text()
if 'struct SleepEpisode:' not in content: content+='\n'+health[health.index('struct SleepEpisode:'):]
checks=r'''
var upgradeChecks = 0
func upgradeCheck(_ value: Bool, _ label: String) { precondition(value,label); upgradeChecks += 1; print("UPGRADE PASS", label) }
let future = ClubDates.calendar.date(byAdding:.day,value:2,to:Date())!
let next = ClubDates.calendar.date(byAdding:.day,value:1,to:future)!
let key = ClubDates.key(future), nextKey = ClubDates.key(next)
var one = ManualPlanDraft(); one.start = key; one.singleDay = true
one.days[0].movements = [ManualPlanMovement(name:"卧推",muscle:"胸")]
one.days[1].movements = [ManualPlanMovement(name:"划船",muscle:"背")]
let oneResult = try one.result()
upgradeCheck(oneResult.sessions?.map(\.date) == [key], "single-day draft never exports hidden dates")
let roundTrip = try JSONDecoder().decode(ManualPlanDraft.self,from:JSONEncoder().encode(one))
upgradeCheck(roundTrip.singleDay == true && roundTrip.editingDuration == 1,"single-day scope survives roundtrip")
let owner = AppStore()
var untouched = DayLog(); untouched.exercises = [Exercise(name:"原腿部安排",muscle:"腿")]
owner.state.days[nextKey] = untouched
let untouchedBytes = try JSONEncoder().encode(CloudState(owner.state))
upgradeCheck(owner.applyAIPlan(oneResult,jobID:one.operationID,replaceUnstarted:true,cycleStart:future,expectedDays:[key:DayLog()],explicitScope:[key],singleDay:true),"single-day adoption succeeds")
let sameNext = try CloudMerge.same(owner.state.days[nextKey],untouched)
upgradeCheck(sameNext,"single-day adoption preserves other dates")
upgradeCheck(owner.state.days[nextKey]?.planCycle == nil,"single-day adoption creates no extra rest week")
upgradeCheck(owner.state.days[key]?.exercises.first?.planID == one.operationID,"adoption keeps stable plan ownership")
let oldState = owner.state
upgradeCheck(owner.managePlan(one.operationID,action:"ended"),"unstarted plan can end")
upgradeCheck(owner.state.days[key]?.exercises.isEmpty == true,"ending removes owned pending exercises")
upgradeCheck(owner.state.days[nextKey]?.exercises.count == 1,"ending preserves unrelated dates")
upgradeCheck(owner.planIsEnded(one.operationID),"ended status is durable")
upgradeCheck(!owner.applyAIPlan(oneResult,jobID:one.operationID,cycleStart:future),"old result cannot replay ended plan")
let merged = try CloudMerge.merge(local:CloudState(owner.state),remote:CloudState(oldState),base:CloudState(oldState))
upgradeCheck(merged.days[key]?.exercises.isEmpty == true,"stale device cannot resurrect cancelled exercise")
upgradeCheck(merged.days[key]?.planActions?.count == 1,"cancellation observation survives merge")
var concurrent = oldState
concurrent.days[key]?.workoutStartedAt = Date()
let concurrentMerge = try CloudMerge.merge(local:CloudState(owner.state),remote:CloudState(concurrent),base:CloudState(oldState))
upgradeCheck(concurrentMerge.days[key]?.exercises.count == 1,"concurrent workout start wins over cancellation")
var completed = oldState
completed.days[key]?.exercises[0].sets[0].completed = true
completed.days[key]?.workoutSavedAt = Date()
let completedMerge = try CloudMerge.merge(local:CloudState(owner.state),remote:CloudState(completed),base:CloudState(oldState))
upgradeCheck(completedMerge.days[key]?.completedSets == 1,"concurrent confirmed sets survive cancellation")
var replacement = merged.days[key]!
replacement.exercises = [Exercise(name:"新计划",muscle:"背",planID:"new-plan")]
replacement.planCycle = TrainingCycle(start:key,plannedDates:[key],sourceJobID:"new-plan")
PlanManagementRules.reconcile(&replacement)
upgradeCheck(replacement.exercises.count == 1 && replacement.planCycle?.sourceJobID == "new-plan","old cancellation preserves replacement plan and cycle")
let failing = AppStore(); failing.state = oldState; failing.allowPersistence = false
upgradeCheck(!failing.managePlan(one.operationID,action:"ended"),"failed cancellation reports failure")
let rolledBack = try CloudMerge.same(failing.state,oldState)
upgradeCheck(rolledBack,"failed cancellation rolls back all mutations")
let multi = AppStore()
var full = ManualPlanDraft(); full.start = key; full.duration = 14
full.days[0].movements = [ManualPlanMovement(name:"推",muscle:"胸")]
full.days[7].movements = [ManualPlanMovement(name:"拉",muscle:"背")]
upgradeCheck(multi.applyAIPlan(try full.result(),jobID:full.operationID,replaceUnstarted:true,cycleStart:future),"14 day plan adoption succeeds")
let secondKey = full.dateKey(offset:7)!
multi.state.days[key]?.workoutStartedAt = Date()
upgradeCheck(multi.managePlan(full.operationID,action:"ended"),"partially started long plan ends")
upgradeCheck(multi.state.days[key]?.exercises.count == 1,"started day is protected")
upgradeCheck(multi.state.days[secondKey]?.exercises.isEmpty == true,"whole plan cancellation reaches second week")
upgradeCheck(multi.managePlan(full.operationID,action:"archived") && multi.planIsArchived(full.operationID),"archival preserves ended plan history")
let zero = Date(timeIntervalSince1970:0)
let sleep = SleepEpisodeRules.episodes([DateInterval(start:zero,end:zero.addingTimeInterval(4*3600)),DateInterval(start:zero.addingTimeInterval(3*3600),end:zero.addingTimeInterval(7*3600))])
upgradeCheck(sleep.count == 1 && sleep[0].seconds == 7*3600,"overlapping sleep stages are not double counted")
let awake = SleepEpisodeRules.episodes([DateInterval(start:zero,end:zero.addingTimeInterval(2*3600)),DateInterval(start:zero.addingTimeInterval(3*3600),end:zero.addingTimeInterval(5*3600)),DateInterval(start:zero.addingTimeInterval(12*3600),end:zero.addingTimeInterval(13*3600))])
upgradeCheck(awake.count == 2 && awake[0].seconds == 4*3600,"awake gaps excluded and naps separated")
var legacyDay = DayLog(); legacyDay.exercises = [Exercise(name:"旧安排",muscle:"背")]
legacyDay.planCycle = TrainingCycle(start:key,plannedDates:[key],sourceJobID:"legacy-ai-job")
let legacyOwner = AppStore(); legacyOwner.state.days[key] = legacyDay
upgradeCheck(legacyOwner.managedPlans.count == 1 && legacyOwner.exercises(in:legacyDay,ownedBy:legacyOwner.managedPlans[0]).count == 1,"legacy cycle without versions retains visible exercises")
upgradeCheck(legacyOwner.managePlan("legacy-ai-job",action:"ended") && legacyOwner.state.days[key]?.exercises.isEmpty == true,"legacy plan without versions can be cancelled")
var patternDraft = ManualPlanDraft(); patternDraft.days[0].movements = [ManualPlanMovement(name:"推",muscle:"胸")]
_ = patternDraft.fillPattern(.on2off1,weekdays:[],customCycle:[])
upgradeCheck(patternDraft.placeholderCount == 0 && patternDraft.activeDays.filter { !$0.movements.isEmpty }.count == 5,"cycles repeat actual actions without empty placeholders")
var replacementDay = DayLog(); let ownedExercise = Exercise(name:"卧推",muscle:"胸",planID:"owned-plan")
replacementDay.exercises = [ownedExercise]
let replacedDay = try WorkoutEditing.replacing(ownedExercise,with:Exercise(name:"划船",muscle:"背"),in:replacementDay)
upgradeCheck(replacedDay.exercises.first?.planID == "owned-plan","exercise replacement preserves plan ownership")
let historyOnly = AppStore(); var recordedDay = DayLog()
recordedDay.exercises = [Exercise(name:"已完成",muscle:"胸",sets:[TrainingSet(reps:10,completed:true)])]; recordedDay.workoutSavedAt = Date()
historyOnly.state.days[ClubDates.key(ClubDates.calendar.date(byAdding:.day,value:-1,to:Date())!)] = recordedDay
upgradeCheck(historyOnly.managedPlans.isEmpty,"historical workout alone does not reappear as a deleted plan")
var localHealth = HealthDay(date:key,timeZone:"Asia/Shanghai",updatedAt:Date())
localHealth.recentBodyMass = HealthMetric(value:70,source:HealthSource(id:"test",name:"test"),recordedAt:Date())
upgradeCheck(localHealth.sharingSummary.recentBodyMass == nil,"recent measurement lookup stays local and does not change cloud daily sharing")
let standalone = AppStore(); var standaloneDay = DayLog()
standaloneDay.exercises = [Exercise(name:"临时安排",muscle:"胸")]; standalone.state.days[key] = standaloneDay
upgradeCheck(standalone.managedPlans.count == 1 && standalone.exercises(in:standaloneDay,ownedBy:standalone.managedPlans[0]).count == 1,"unmarked pending schedules remain visible and manageable")
let standaloneID = standalone.managedPlans[0].id
upgradeCheck(standalone.managePlan(standaloneID,action:"ended") && standalone.state.days[key]?.exercises.isEmpty == true,"unmarked legacy schedule can be deleted")
upgradeCheck(PlanManagementRules.ownerForAddition(oldState.days[key]!) == one.operationID,"later additions inherit the single-day plan owner")
print("EXPERIENCE UPGRADE PASSED: \(upgradeChecks) behavioral checks")
'''
Path(sys.argv[1]).write_text(content+'\ndo {\n'+checks+'\n}\n')
