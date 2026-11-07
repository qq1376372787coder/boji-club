"""Execute current production Foundation rules, plus v25 session/time boundaries."""
from pathlib import Path
import runpy,sys
out=Path(sys.argv[1])
runpy.run_path(str(Path(__file__).with_name('build_experience_v24_swift_tests.py')))
s=out.read_text('utf-8')
s=s.replace('func persist(changedDates: [String]) -> Bool { persistenceCalls+=1;', 'func persist(changedDates: [String]) -> Bool { for key in changedDates { if var day=state.days[key] { WorkoutSessions.synchronize(&day); state.days[key]=day } }; persistenceCalls+=1;',1)
s+=r'''
do {
let before=checks
let builder=ReportInputBuilder()
rejected("empty daily report blocked") { _=try builder.reportInput(date:now,log:DayLog()) }
check(!DailyReportEligibility.hasRecords(DayLog()),"empty day has no report entry")
check(DailyReportEligibility.hasRecords(DayLog(exercises:[old])),"partial completed training qualifies for daily report")
check(DailyReportEligibility.hasRecords(DayLog(bodyWeight:BodyWeightEntry(kilograms:70,updatedAt:now))),"weight-only day qualifies")
let ended=now.addingTimeInterval(-600)
let store=AppStore();store.state.days[today]=DayLog(exercises:[old],workoutSavedAt:ended,workoutStartedAt:ended.addingTimeInterval(-3600),workoutEndedAt:ended)
var late=pending;late.completed=true;late.actualEntered=true
// 已确认场次禁止切换完成状态（AppStore.updateSet correcting 分支），
// 补记需通过新的训练会话完成，避免历史总组数被静默改写。
check(!store.updateSet(late,exerciseID:old.id,on:now),"confirmed workout completion cannot be toggled")
check(store.log(for:now).completedSets == 1,"rejected late completion keeps confirmed totals")
check(store.log(for:now).workoutEndedAt == ended,"rejected late correction leaves original end")
check(store.saveWorkout(on:now) && store.log(for:now).workoutEndedAt == ended,"reconfirmation does not stretch session time")
check(store.addWorkoutSession(on:now,copyPlan:true),"second same-day session can be created")
let firstID=old.id;let secondID=store.log(for:now).activeWorkoutSessionID!
check(store.log(for:now).workoutSessions?.count == 2,"two sessions have separate metadata")
check(store.log(for:now).trainingLog.completedSets == 0,"second session starts uncompleted")
check(store.log(for:now).completedSets == 1,"daily aggregate retains first session")
check(store.log(for:now).isTrainingConfirmed,"unstarted second plan does not undo confirmed first session")
let secondExercise=store.log(for:now).trainingLog.exercises[0]
check(secondExercise.id != old.id && secondExercise.sets[0].id != old.sets[0].id,"copy creates new movement and set identities")
var set=secondExercise.sets[0];set.completed=true;set.actualEntered=true
check(store.updateSet(set,exerciseID:secondExercise.id,on:now),"second session records independently")
check(store.log(for:now).hasUnconfirmedTraining,"second completed session requires own confirmation")
check(store.log(for:now).workoutSessions?.first(where:{$0.id == firstID})?.savedAt != nil,"first confirmation survives second edits")
check(!store.addWorkoutSession(on:now,copyPlan:false),"cannot skip confirmation of completed current session")
check(store.saveWorkout(on:now),"second confirmation saves")
check(store.log(for:now).isTrainingConfirmed && store.log(for:now).completedSets == 2,"day becomes confirmed with aggregate groups")
check(store.selectWorkoutSession(firstID,on:now),"user can revisit first session")
check(store.log(for:now).trainingLog.completedSets == 1 && store.log(for:now).workoutEndedAt == ended,"first times and groups restored")
let encoded=try JSONEncoder().encode(store.state)
check(try JSONDecoder().decode(SavedState.self,from:encoded).days[today]?.workoutSessions?.count == 2,"session metadata survives disk encoding")
let input=try builder.reportInput(date:now,log:store.log(for:now))
check(input.payload["workout_sessions"] != nil && input.payload["workout_link"] == nil,"AI receives separate session metadata without duplicate legacy link")
let prior=store.state;store.allowPersistence=false
check(!store.addWorkoutSession(on:now,copyPlan:false),"failed new session persistence reported")
check(try CloudMerge.same(prior,store.state),"failed new session rolls back metadata and groups")
store.allowPersistence=true
check(!store.addWorkoutSession(on:tomorrow,copyPlan:false),"future training cannot be started as second session")
var replaceDay=store.log(for:now);let original=replaceDay.trainingLog.exercises[0]
var incomplete=original;incomplete.sets.append(pending);replaceDay.exercises[0]=incomplete
let result=try WorkoutEditing.replacing(incomplete,with:replacement,in:replaceDay)
check(result.exercises.first(where:{$0.id != incomplete.id && $0.name == replacement.name})?.workoutSessionID == firstID,"replacement belongs to original session")
let base=store.state;let left=AppStore();left.state=base;let right=AppStore();right.state=base
check(left.addWorkoutSession(on:now,copyPlan:true) && right.addWorkoutSession(on:now,copyPlan:true),"two devices create independent sessions")
let merged=try CloudMerge.merge(local:CloudState(left.state),remote:CloudState(right.state),base:CloudState(base))
check(merged.days[today]?.workoutSessions?.count == 4,"concurrent new sessions both retained")
check(merged.days[today]?.completedSets == 2,"merge does not duplicate existing completions")
check(merged.days[today]?.exercises.count == 4,"all distinct copied plans retained")
var timer=WorkoutStopwatch();timer.start(at:now);timer.start(at:now.addingTimeInterval(10))
check(timer.elapsed(at:now.addingTimeInterval(30)) == 30,"double start cannot reset timer")
timer.pause(at:now.addingTimeInterval(40))
check(!timer.isRunning && timer.elapsed(at:now.addingTimeInterval(100)) == 40,"pause freezes elapsed duration")
timer.start(at:now.addingTimeInterval(100));timer.pause(at:now.addingTimeInterval(125))
check(timer.elapsed(at:now.addingTimeInterval(200)) == 65,"resume excludes paused time")
check(!ReviewWeek.contains(ClubDates.key(now.addingTimeInterval(-8*86400)),inWeekOf:now),"different natural week is not reused")
check(ReviewWeek.contains(today,inWeekOf:now),"current week is reused")

let noStart=AppStore();noStart.state.days[today]=DayLog(exercises:[old],workoutSavedAt:ended,workoutEndedAt:ended)
check(!noStart.updateSet(late,exerciseID:old.id,on:now),"confirmed legacy session cannot toggle completion")
check(noStart.log(for:now).workoutStartedAt == nil && noStart.log(for:now).workoutEndedAt == ended,"rejected legacy correction does not invent a new start or erase end")
check(store.selectWorkoutSession(secondID,on:now),"second session selected for stale callback test")
check(!store.updateSet(late,exerciseID:old.id,on:now),"stale editor cannot update another session")
check(!store.removeExercise(old.id,on:now),"stale deletion cannot remove another session")
let deleteCurrent=AppStore();deleteCurrent.state=store.state
check(!deleteCurrent.removeExercise(secondExercise.id,on:now),"confirmed movement cannot be deleted")
check(deleteCurrent.addWorkoutSession(on:now,copyPlan:true),"new unconfirmed session can be created")
let currentExercise = deleteCurrent.log(for:now).trainingLog.exercises[0]
check(deleteCurrent.removeExercise(currentExercise.id,on:now),"active movement can be removed")
check(deleteCurrent.log(for:now).trainingLog.workoutStartedAt == nil && deleteCurrent.log(for:now).trainingLog.workoutEndedAt == nil,"cleared current session has no stale timer")
check(deleteCurrent.log(for:now).workoutSessions?.first(where:{$0.id == firstID})?.savedAt != nil,"deleting current session preserves first confirmation")
print("PASS \(checks-before) v25 production rule checks; total \(checks)")
}
'''

import re
source=(Path(__file__).resolve().parents[1]/'BojiClub/ClubSeason.swift').read_text('utf-8')
start=source.index('    func refreshAfterSync(');opening=source.index('{',start);depth=1;end=opening+1
while depth:
 if source[end]=='{':depth+=1
 elif source[end]=='}':depth-=1
 end+=1
actual=source[start:end]
refreshCode="import Foundation\nvar checks=0\nfunc check(_ value:Bool,_ label:String) { guard value else { fatalError(label) };checks+=1;print(\"PASS \\(label)\") }\n"+r'''
@MainActor final class AccountService { struct User { let id:Int }; var user:User?=User(id:1) }
@MainActor final class SeasonRefreshFixture {
 var generation=UUID();var accountID:Int?=1;var loading=false;var lastProgressRefresh=Date()
 var progressRefreshTask:Task<Void,Never>?;var pendingProgressRefresh=false;var calls=0
 func activate(_ id:Int?) { if id != accountID { generation=UUID();accountID=id;progressRefreshTask?.cancel();progressRefreshTask=nil;pendingProgressRefresh=false } }
 func refresh(account:AccountService) async { calls+=1;loading=true;lastProgressRefresh=Date();try? await Task.sleep(for:.milliseconds(100));loading=false }
'''+actual+"\n}\n"
refreshCode+=r'''
let refreshAccount=await AccountService();let refresher=await SeasonRefreshFixture()
await refresher.refreshAfterSync(account:refreshAccount)
await refresher.refreshAfterSync(account:refreshAccount)
try await Task.sleep(for:.seconds(3.4))
check(await refresher.calls == 1,"rapid sync callbacks coalesce without dropping refresh")
await MainActor.run { refresher.loading=true }
await refresher.refreshAfterSync(account:refreshAccount)
try await Task.sleep(for:.milliseconds(100))
await MainActor.run { refresher.loading=false }
try await Task.sleep(for:.seconds(3.2))
check(await refresher.calls == 2,"sync waits for active request then refreshes progress")
await refresher.refreshAfterSync(account:refreshAccount)
await MainActor.run { refreshAccount.user=AccountService.User(id:2);refresher.activate(2) }
try await Task.sleep(for:.seconds(3.3))
check(await refresher.calls == 2,"account switch cancels queued progress refresh")
print("PASS progress refresh rules: \(checks)")
'''

out.write_text(s,'utf-8')
out.with_name('v25-progress-refresh.swift').write_text(refreshCode,'utf-8')
