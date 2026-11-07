"""Verify the actual combined health consent, atomic save and AI/merge paths."""
from pathlib import Path
import runpy,sys
output=Path(sys.argv[1])
module=runpy.run_path(str(Path(__file__).with_name('build_experience_v23_swift_tests.py')))
code=output.read_text('utf-8')
# Provider disclosure lives in the explicit opt-in and the legal AI notice.
# Build 130+ uses DeepSeek/MiniMax; the old OnboardingView copy is gone.
root = Path(__file__).resolve().parents[1]
onboarding = (root/'BojiClub/AIContextReference.swift').read_text('utf-8')
notice = (root/'legal-site/seed/zh-CN/ai-notice.md').read_text('utf-8')
assert all(name in onboarding for name in ['DeepSeek', 'MiniMax']), 'AI opt-in must name its recipients'
assert all(name in notice for name in ['DeepSeek', 'MiniMax']), 'AI notice must name its recipients'
code=code.replace('    var writtenDates: [String] = []','    var writtenDates: [String] = []\n    var persistenceCalls=0',1)
code=code.replace('func persist(changedDates: [String]) -> Bool { writtenDates = changedDates; return allowPersistence }','func persist(changedDates: [String]) -> Bool { persistenceCalls+=1; writtenDates = changedDates; return allowPersistence }',1)
code+='\nextension AppStore {\n'+module['module']['method'](module['module']['read']('AppStore.swift'),'saveHealthAndLink')+'\n}\n'
code+=r'''
do {
let before=checks
let recordedDate=yesterday
let start=ClubDates.calendar.date(bySettingHour:10,minute:0,second:0,of:recordedDate)!
let end=start.addingTimeInterval(3600)
let watchSource=HealthSource(id:"watch-source",name:"Apple Watch")
let metric=HealthMetric(value:500,source:watchSource,availableSources:[watchSource,HealthSource(id:"other",name:"Other")])
let device=DeviceWorkout(id:"watch-one",name:"力量训练",start:start,end:end,minutes:55,calories:250,source:watchSource,activityKind:"strength",averageHeartRate:120)
let completedExercise=Exercise(name:"卧推",muscle:"胸",sets:[TrainingSet(weight:20,reps:10,completed:true)])
let recorded=DayLog(exercises:[completedExercise],workoutSavedAt:end,workoutStartedAt:start,workoutEndedAt:end)
let summary=HealthDay(date:ClubDates.key(recordedDate),timeZone:"Asia/Shanghai",updatedAt:now,steps:metric,activeEnergy:metric,heartRate:HealthMetric(value:80,source:watchSource,availableSources:[watchSource]),restingHeartRate:HealthMetric(value:60,source:watchSource,availableSources:[watchSource]),sleep:HealthMetric(value:7,source:watchSource,availableSources:[watchSource]),workouts:[device])
func storeWith(_ day:DayLog=recorded) -> AppStore { let store=AppStore();store.state.days[ClubDates.key(recordedDate)]=day;return store }
func review(_ store:AppStore,_ value:HealthDay=summary,_ linking:Bool=true) -> HealthShareReviewRequest {
    HealthShareReviewRequest(ownerID:1,date:recordedDate,summary:value,day:store.log(for:recordedDate),allowsLink:linking)
}
let consentStore=storeWith();let request=review(consentStore)
check(request.allowsLink && consentStore.log(for:recordedDate).health == nil && consentStore.persistenceCalls == 0,"opening/cancelling consent is read-only and does not share local health")
check(HealthShareConsent.initialWorkoutID(request,day:recorded) == device.id,"single time-matched device workout is preselected for explicit confirmation")
var second=device;second.id="watch-two";second.source=HealthSource(id:"second",name:"Second Watch")
var multiple=summary;multiple.workouts.append(second)
check(HealthShareConsent.initialWorkoutID(review(consentStore,multiple),day:recorded) == nil,"multiple time matches require a user selection")
var running=device;running.id="run";running.activityKind="running";running.name="跑步"
var otherKind=summary;otherKind.workouts=[running]
check(HealthShareConsent.initialWorkoutID(review(consentStore,otherKind),day:recorded) == nil,"non-strength workout is never guessed as a strength session")
check(consentStore.saveHealthAndLink(request,workoutID:device.id),"one explicit confirmation saves health and association")
let saved=consentStore.log(for:recordedDate)
check(saved.health?.workouts.first?.id == device.id && saved.linkedDeviceWorkoutID == device.id && consentStore.persistenceCalls == 1,"combined save performs one persistence call for both values")
check(saved.completedSets == recorded.completedSets && saved.exercises.count == recorded.exercises.count,"device association never adds an App training session or group")
check(saved.health?.activeEnergy?.value == 500 && saved.health?.workouts.first?.calories == 250,"daily energy and workout energy stay separate instead of being summed")
check([saved.health?.steps,saved.health?.activeEnergy,saved.health?.heartRate,saved.health?.restingHeartRate,saved.health?.sleep].allSatisfy{$0?.availableSources == nil},"only chosen source summaries are persisted, not alternative source lists")
check(!consentStore.saveHealthAndLink(request,workoutID:device.id) && consentStore.persistenceCalls == 1,"repeated old confirmation cannot create a second write")
let noChange=review(consentStore,summary)
check(consentStore.saveHealthAndLink(noChange,workoutID:device.id) && consentStore.persistenceCalls == 1,"reconfirming identical already-shared data is a no-op")
let failed=storeWith();failed.allowPersistence=false
check(!failed.saveHealthAndLink(review(failed),workoutID:device.id),"failed disk persistence returns failure")
check(failed.log(for:recordedDate).health == nil && failed.log(for:recordedDate).linkedDeviceWorkoutID == nil && failed.log(for:recordedDate).completedSets == 1,"failed combined write rolls back both health and association while retaining training")
failed.allowPersistence=true
check(failed.saveHealthAndLink(review(failed),workoutID:device.id),"combined save can be retried after persistence failure")
let changedOwner=storeWith();let ownerRequest=review(changedOwner);changedOwner.editingAccountID=2
check(!changedOwner.saveHealthAndLink(ownerRequest,workoutID:device.id) && changedOwner.persistenceCalls == 0,"switched account rejects old consent without any write")
changedOwner.editingAccountID=nil
check(!changedOwner.saveHealthAndLink(ownerRequest,workoutID:nil),"logged-out account cannot share the old snapshot")
let wrongDay=storeWith();var futureSummary=summary;futureSummary.date=ClubDates.key(tomorrow)
check(!wrongDay.saveHealthAndLink(review(wrongDay,futureSummary),workoutID:device.id),"mismatched summary date is rejected")
let futureRequest=HealthShareReviewRequest(ownerID:1,date:tomorrow,summary:futureSummary,day:DayLog(),allowsLink:false)
check(!wrongDay.saveHealthAndLink(futureRequest,workoutID:nil),"future health summary cannot enter diary or AI")
let missing=storeWith()
check(!missing.saveHealthAndLink(review(missing),workoutID:"missing") && missing.log(for:recordedDate).health == nil,"invalid selected ID cannot partially share health")
var empty=summary;empty.steps=nil;empty.activeEnergy=nil;empty.heartRate=nil;empty.restingHeartRate=nil;empty.sleep=nil;empty.workouts=[]
check(!missing.saveHealthAndLink(review(missing,empty,false),workoutID:nil),"no-data snapshot is rejected instead of writing false zeros")
var duplicated=summary;duplicated.workouts.append(device)
check(!missing.saveHealthAndLink(review(missing,duplicated),workoutID:device.id),"duplicate device identifiers are rejected before persistence")
var invalidValue=summary;invalidValue.activeEnergy?.value = .nan
check(!missing.saveHealthAndLink(review(missing,invalidValue),workoutID:device.id),"non-finite health value cannot contaminate the cloud or AI")
var invalidTime=summary;invalidTime.workouts[0].end=start
check(!missing.saveHealthAndLink(review(missing,invalidTime),workoutID:device.id),"invalid device time interval is rejected")
var differentDay=summary;differentDay.workouts[0].start=start.addingTimeInterval(-86400);differentDay.workouts[0].end=end.addingTimeInterval(-86400)
check(!missing.saveHealthAndLink(review(missing,differentDay),workoutID:device.id),"another day's device workout cannot be attached")
let edited=storeWith();let editingRequest=review(edited)
edited.state.days[ClubDates.key(recordedDate)]!.exercises[0].sets[0].weight=25
check(!edited.saveHealthAndLink(editingRequest,workoutID:device.id) && edited.persistenceCalls == 0,"same group count with changed weight still invalidates stale association consent")
check(edited.saveHealthAndLink(editingRequest,workoutID:nil),"user may explicitly share only daily health after training changes")
let replaced=storeWith();let replaceRequest=review(replaced)
replaced.state.days[ClubDates.key(recordedDate)]!.workoutStartedAt=start.addingTimeInterval(60)
check(!replaced.saveHealthAndLink(replaceRequest,workoutID:device.id),"changed session timestamp invalidates old association")
let deleted=storeWith();let deleteRequest=review(deleted);deleted.state.days[ClubDates.key(recordedDate)]!.exercises=[]
check(!deleted.saveHealthAndLink(deleteRequest,workoutID:device.id),"deleted App training cannot be associated by a stale page")
let cloudChanged=storeWith();let cloudRequest=review(cloudChanged)
cloudChanged.state.days[ClubDates.key(recordedDate)]!.health=summary.sharingSummary
check(!cloudChanged.saveHealthAndLink(cloudRequest,workoutID:nil) && cloudChanged.persistenceCalls == 0,"newly shared remote health invalidates an older unconfirmed snapshot")
let linkedChange=storeWith(saved);let linkRequest=review(linkedChange)
linkedChange.state.days[ClubDates.key(recordedDate)]!.linkedDeviceWorkoutID=nil
check(!linkedChange.saveHealthAndLink(linkRequest,workoutID:device.id),"concurrent unlink invalidates old association consent")
let onlyHealth=storeWith(DayLog());let shareRequest=review(onlyHealth,summary,false)
check(!shareRequest.allowsLink && HealthShareConsent.initialWorkoutID(shareRequest,day:DayLog()) == nil,"health-only entry has no automatic workout selection")
check(onlyHealth.saveHealthAndLink(shareRequest,workoutID:nil) && onlyHealth.log(for:recordedDate).linkedDeviceWorkoutID == nil,"daily health can be explicitly shared without an App workout")
let noPermissionToLink=storeWith()
check(!noPermissionToLink.saveHealthAndLink(review(noPermissionToLink,summary,false),workoutID:device.id),"health-only consent cannot be used to add an association")
let retaining=storeWith(saved);var updated=summary;updated.steps?.value=550
check(retaining.saveHealthAndLink(review(retaining,updated),workoutID:nil) && retaining.log(for:recordedDate).linkedDeviceWorkoutID == device.id,"sharing daily updates preserves a still-present prior association")
let disappeared=storeWith(saved);var noWorkout=summary;noWorkout.workouts=[]
check(disappeared.saveHealthAndLink(review(disappeared,noWorkout),workoutID:nil) && disappeared.log(for:recordedDate).linkedDeviceWorkoutID == nil,"a removed device record clears its dangling association in the same write")
let mutableSource=summary;var refreshedSource=mutableSource;refreshedSource.steps?.value=999
let frozen=review(storeWith(),mutableSource)
check(frozen.summary.steps?.value == 500 && refreshedSource.steps?.value == 999,"later local device refresh does not alter the reviewed snapshot")
let historical=DayLog(exercises:[completedExercise]);let historicalStore=storeWith(historical)
check(HealthShareConsent.initialWorkoutID(review(historicalStore),day:historical) == nil,"historical backfill without timestamps does not fabricate a time match")
check(historicalStore.saveHealthAndLink(review(historicalStore),workoutID:device.id) && historicalStore.log(for:recordedDate).workoutStartedAt == nil,"explicit historical association preserves absent training timestamps")
let midnight=ClubDates.calendar.startOfDay(for:now)
var nightDevice=device;nightDevice.start=midnight.addingTimeInterval(-1800);nightDevice.end=midnight.addingTimeInterval(1800);nightDevice.minutes=60
var nightSummary=summary;nightSummary.workouts=[nightDevice]
let nightLog=DayLog(exercises:[completedExercise],workoutSavedAt:nightDevice.end,workoutStartedAt:nightDevice.start,workoutEndedAt:nightDevice.end)
let nightStore=storeWith(nightLog)
check(HealthShareConsent.initialWorkoutID(review(nightStore,nightSummary),day:nightLog) == device.id && nightStore.saveHealthAndLink(review(nightStore,nightSummary),workoutID:device.id),"cross-midnight device training remains attached to its starting date")
let aiInput=try builder.reportInput(date:recordedDate,log:saved)
if case .object(let link)?=aiInput.payload["workout_link"] {
    check(link["device_workout_id"] == .string(device.id) && link["confirmed_by_user"] == .bool(true),"AI input receives only the explicitly confirmed association")
} else { check(false,"AI input receives only the explicitly confirmed association") }
check(try builder.reportInput(date:recordedDate,log:recorded).payload["health"] == nil,"cancelled/unshared local data stays out of AI input")
let cloudRoundtrip=try CloudState(consentStore.state).savedState().days[ClubDates.key(recordedDate)]!
check(cloudRoundtrip.linkedDeviceWorkoutID == device.id && cloudRoundtrip.health?.workouts.first?.averageHeartRate == 120,"combined confirmation survives actual cloud serialization")
var base=SavedState();base.days[ClubDates.key(recordedDate)]=recorded
let local=consentStore.state;var remote=base;remote.days[ClubDates.key(recordedDate)]!.meals=[meal("午餐")]
let merged=try CloudMerge.merge(local:CloudState(local),remote:CloudState(remote),base:CloudState(base)).savedState().days[ClubDates.key(recordedDate)]!
check(merged.linkedDeviceWorkoutID == device.id && merged.health?.workouts.first?.id == device.id && merged.meals.count == 1,"remote meal edit merges with the confirmed health association")
check(HealthShareConsent.disclosure.contains("按你确认的 AI 数据使用说明") && HealthShareConsent.disclosure.contains("原始心率序列") && HealthShareConsent.disclosure.contains("GPS"),"health consent references the explicit AI consent and explains data boundaries")
print("PASS \(checks-before) v24 combined health checks; total \(checks)")
}
'''
output.write_text(code,'utf-8')
print('Built v24 production Swift rules')
