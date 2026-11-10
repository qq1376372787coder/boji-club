from pathlib import Path
import subprocess,sys,tempfile
root=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory() as tmp:
    source=Path(tmp)/'history.swift'
    subprocess.run([sys.executable,str(root/'tests/build_history_swift_tests.py'),str(source)],check=True)
    content=source.read_text('utf-8')
def block(s,marker):
    start=s.index(marker);i=s.index('{',start);depth=1;j=i+1
    while depth:
        if s[j]=='{':depth+=1
        elif s[j]=='}':depth-=1
        j+=1
    return s[start:j]
cloud=(root/'BojiClub/CloudSync.swift').read_text('utf-8')
ai=(root/'BojiClub/AIService.swift').read_text('utf-8')
nutrition=(root/'BojiClub/Models.swift').read_text('utf-8')
policy='enum MealNutritionMerge { '+block(nutrition,'enum NutritionSource {')+'\n'+block(nutrition,'static func nutritionSource(')+' }'
extra=[policy,block(ai,'enum JSONValue:'),'extension CloudMerge {']
for marker in ['private static func mergeValue(','private static func id(','private static func indexed(','private static func strings(']:
    extra.append(block(cloud,marker))
extra.append(r'''
static func testLedgerMerge<T:Codable>(_ local:T?,_ remote:T?,_ base:T?,key:String) throws -> T? {
    let l=try local.map { try JSONValue.encode($0) }
    let r=try remote.map { try JSONValue.encode($0) }
    let b=try base.map { try JSONValue.encode($0) }
    guard let value=mergeValue(l,r,b,key:key) else { return nil }
    return try JSONDecoder().decode(T.self,from:JSONEncoder().encode(value))
}
}

var ledgerState=SavedState()
let ledgerMovement=Exercise(name:"哑铃卧推",muscle:"胸",sets:[TrainingSet(weight:10,reps:12)])
ledgerState.days[today]=DayLog(exercises:[ledgerMovement])
let untouched=ledgerState
check(ClubInsightLedger.reconcile(state:&ledgerState,dates:[today],now:now)==[today], "saving a schedule observes it once")
let firstObservation=ledgerState.days[today]!.insightEvents!.first!
check(firstObservation.isTodayReminder, "unstarted schedule is a time-bound reminder")
check(ClubInsightLedger.reconcile(state:&ledgerState,dates:[today],now:now.addingTimeInterval(1)).isEmpty, "repeated read/save does not manufacture events")
var concurrentObservation=untouched
_ = ClubInsightLedger.reconcile(state:&concurrentObservation,dates:[today],now:now.addingTimeInterval(10))
check(concurrentObservation.days[today]!.insightEvents!.first!.id==firstObservation.id, "same evidence and parents deduplicate across devices")
ledgerState.days[today]!.exercises[0].imageURL="https://example.invalid/image"
ledgerState.days[today]!.exercises[0].gifURL="https://example.invalid/gif"
check(ClubInsightLedger.reconcile(state:&ledgerState,dates:[today],now:now).isEmpty, "media loading is not new training evidence")
ledgerState.days[today]!.workoutStartedAt=now
_ = ClubInsightLedger.reconcile(state:&ledgerState,dates:[today],now:now.addingTimeInterval(20))
check(ClubInsightLedger.current(in:ledgerState,date:now,now:now).first(where: { $0.kind == .training })!.title.contains("已开始"), "started session is not described as waiting to start")
ledgerState.days[today]!.exercises[0].sets[0].completed=true
_ = ClubInsightLedger.reconcile(state:&ledgerState,dates:[today],now:now.addingTimeInterval(30))
check(ClubInsightLedger.current(in:ledgerState,date:now,now:now).first(where: { $0.kind == .training })!.title.contains("待确认"), "checked set is not a confirmed workout")
ledgerState.days[today]!.workoutSavedAt=now
_ = ClubInsightLedger.reconcile(state:&ledgerState,dates:[today],now:now.addingTimeInterval(40))
let savedObservation=ClubInsightLedger.current(in:ledgerState,date:now,now:now).first(where: { $0.kind == .training })!
check(savedObservation.title=="训练已保存", "confirmed record becomes completion feedback")
ledgerState.days[today]!.exercises[0].sets[0].weight=12
_ = ClubInsightLedger.reconcile(state:&ledgerState,dates:[today],now:now.addingTimeInterval(50))
let updatedObservation=ClubInsightLedger.current(in:ledgerState,date:now,now:now).first(where: { $0.kind == .training })!
check(updatedObservation.id != savedObservation.id && updatedObservation.evidenceDigest != savedObservation.evidenceDigest, "weight changes update evidence even if summary counts match")
check(ClubInsightLedger.displayState(savedObservation,in:ledgerState,now:now) == .updated, "old observation is visibly superseded")
let completedDay=ledgerState.days[today]!
ledgerState.days[today]!.exercises=[];ledgerState.days[today]!.workoutStartedAt=nil;ledgerState.days[today]!.workoutSavedAt=nil
_ = ClubInsightLedger.reconcile(state:&ledgerState,dates:[today],now:now.addingTimeInterval(60))
check(ClubInsightLedger.current(in:ledgerState,date:now,now:now).isEmpty, "deleted source cannot remain current on home")
check(ClubInsightLedger.leaves(ledgerState.days[today]!.insightEvents!).first!.state == .withdrawn, "deletion records a retraction without destroying old evidence")
ledgerState.days[today]!.exercises=completedDay.exercises;ledgerState.days[today]!.workoutStartedAt=completedDay.workoutStartedAt;ledgerState.days[today]!.workoutSavedAt=completedDay.workoutSavedAt
_ = ClubInsightLedger.reconcile(state:&ledgerState,dates:[today],now:now.addingTimeInterval(70))
let restoredObservation=ClubInsightLedger.current(in:ledgerState,date:now,now:now).first(where: { $0.kind == .training })!
check(restoredObservation.id != updatedObservation.id, "restoring identical data after a retraction creates a new causal observation")
var expiredState=untouched
_ = ClubInsightLedger.reconcile(state:&expiredState,dates:[today],now:now)
_ = ClubInsightLedger.reconcile(state:&expiredState,dates:[today],now:tomorrow)
check(ClubInsightLedger.leaves(expiredState.days[today]!.insightEvents!).first!.state == .expired, "past-day reminder expires without accusing user of missing training")
expiredState.days[ClubDates.key(tomorrow)]=DayLog(exercises:[ledgerMovement])
check(ClubInsightLedger.reconcile(state:&expiredState,dates:[ClubDates.key(tomorrow)],now:now).isEmpty, "future records cannot create observations")
var bodyLedger=SavedState();bodyLedger.days[ClubDates.key(yesterday)]=DayLog(bodyWeight:BodyWeightEntry(kilograms:69,updatedAt:yesterday))
bodyLedger.days[today]=DayLog(bodyWeight:BodyWeightEntry(kilograms:70,updatedAt:now))
_ = ClubInsightLedger.reconcile(state:&bodyLedger,dates:[today],now:now)
check(ClubInsightLedger.events(in:bodyLedger).count==1, "actual measurement creates one body observation")
check(ClubInsightLedger.reconcile(state:&bodyLedger,dates:[ClubDates.key(tomorrow)],now:tomorrow).isEmpty, "old weight is not republished as a new daily measurement")
bodyLedger.days[today]!.bodyWeight=nil
_ = ClubInsightLedger.reconcile(state:&bodyLedger,dates:[today],now:now)
check(ClubInsightLedger.current(in:bodyLedger,date:now,now:now).isEmpty, "deleting weight does not promote an older point into a new measurement event")
var foodLedger=SavedState();foodLedger.days[today]=DayLog(meals:[meal])
_ = ClubInsightLedger.reconcile(state:&foodLedger,dates:[today],now:now)
let foodObservation=ClubInsightLedger.events(in:foodLedger).first!
check(foodObservation.detail.contains("补齐漏记的餐次"), "one meal still cannot prove a daily deficit")
foodLedger.days[today]!.meals[0].photoFilename="local.jpg";foodLedger.days[today]!.meals[0].photoRemoteID="remote.jpg"
foodLedger.days[today]!.meals[0].sourceAIJobID="upload-complete"
check(ClubInsightLedger.reconcile(state:&foodLedger,dates:[today],now:now).isEmpty, "photo/provenance sync does not duplicate nutrition events")
foodLedger.days[today]!.meals[0].protein=20
_ = ClubInsightLedger.reconcile(state:&foodLedger,dates:[today],now:now)
check(ClubInsightLedger.events(in:foodLedger).count==2, "nutrition edits retain both observations")
let feedbackKey=ClubInsightLedger.recordFeedback(state:&ledgerState,kind:.training,action:.helpful,eventID:restoredObservation.id,now:now)
check(feedbackKey==today, "helpful feedback attaches to current account/date")
check(ClubInsightLedger.recordFeedback(state:&ledgerState,kind:.training,action:.helpful,eventID:restoredObservation.id,now:now)==nil, "repeated helpful tap is idempotent")
_ = ClubInsightLedger.recordFeedback(state:&ledgerState,kind:.training,action:.reduce,now:now)
check(ClubInsightLedger.current(in:ledgerState,date:now,now:now).isEmpty, "reduced category leaves home")
check(!ClubInsightLedger.events(in:ledgerState).isEmpty, "reducing reminders preserves timeline")
_ = ClubInsightLedger.recordFeedback(state:&ledgerState,kind:.training,action:.normal,now:now.addingTimeInterval(-60))
check(!ClubInsightLedger.reduced(.training,in:ledgerState), "causal restore works despite device clock moving backwards")
_ = ClubInsightLedger.recordFeedback(state:&ledgerState,kind:.training,action:.dismissToday,now:now)
check(ClubInsightLedger.dismissedToday(.training,in:ledgerState,now:now), "day dismissal hides current reminder")
check(!ClubInsightLedger.dismissedToday(.training,in:ledgerState,now:tomorrow), "today dismissal expires tomorrow")
_ = ClubInsightLedger.recordFeedback(state:&ledgerState,kind:.training,action:.restoreToday,now:now)
check(!ClubInsightLedger.current(in:ledgerState,date:now,now:now).isEmpty, "explicit restore shows current evidence")
let roundTripLedger=try JSONDecoder().decode(SavedState.self,from:JSONEncoder().encode(ledgerState))
check(ClubInsightLedger.events(in:roundTripLedger)==ClubInsightLedger.events(in:ledgerState), "observations survive restart/Codable round-trip")
check(ClubInsightLedger.feedback(in:roundTripLedger)==ClubInsightLedger.feedback(in:ledgerState), "preferences survive restart/Codable round-trip")
check(ClubInsightLedger.events(in:SavedState()).isEmpty && ClubInsightLedger.feedback(in:SavedState()).isEmpty, "empty account inherits no observations or preferences")
let mergedObservations: [ClubInsightEvent]? = try CloudMerge.testLedgerMerge([firstObservation],[updatedObservation],nil,key:"insightEvents")
check(mergedObservations!.count==2, "actual cloud merge retains concurrent observations")
let omittedObservations: [ClubInsightEvent]? = try CloudMerge.testLedgerMerge(nil,[firstObservation],[firstObservation],key:"insightEvents")
check(omittedObservations==[firstObservation], "omission cannot delete a committed observation")
var leftPreference=SavedState(),rightPreference=SavedState()
_ = ClubInsightLedger.recordFeedback(state:&leftPreference,kind:.training,action:.reduce,now:now)
_ = ClubInsightLedger.recordFeedback(state:&rightPreference,kind:.training,action:.normal,now:now.addingTimeInterval(60))
let mergedPreferences: [ClubInsightFeedback]? = try CloudMerge.testLedgerMerge(ClubInsightLedger.feedback(in:leftPreference),ClubInsightLedger.feedback(in:rightPreference),nil,key:"insightFeedback")
var conflictPreferences=SavedState();conflictPreferences.days[today]=DayLog(insightFeedback:mergedPreferences)
check(ClubInsightLedger.reduced(.training,in:conflictPreferences), "concurrent reduction wins without guessing timestamp authority")
_ = ClubInsightLedger.recordFeedback(state:&conflictPreferences,kind:.training,action:.normal,now:now.addingTimeInterval(70))
check(!ClubInsightLedger.reduced(.training,in:conflictPreferences), "explicit restore closes both concurrent preference branches")
var otherDayPreference=SavedState()
_ = ClubInsightLedger.recordFeedback(state:&otherDayPreference,kind:.training,action:.reduce,now:tomorrow)
check(ClubInsightLedger.feedback(in:leftPreference).first!.id != ClubInsightLedger.feedback(in:otherDayPreference).first!.id, "offline preferences from different days cannot collide")
let futureKind = try JSONDecoder().decode(ClubInsightKind.self,from:Data("\"future_kind\"".utf8))
let futureKindEncoded=try JSONEncoder().encode(futureKind)
check(futureKind.rawValue=="future_kind" && String(data:futureKindEncoded,encoding:.utf8)=="\"future_kind\"", "unknown future kind preserves exact raw value")
let futureStatus = try JSONDecoder().decode(ClubInsightState.self,from:Data("\"future_state\"".utf8))
check(!futureStatus.supported, "future event state does not break decoding or become a current claim")
print("Insights, history and adoption: \(tests) total behavioral checks passed")
''')
Path(sys.argv[1]).write_text(content+'\n\n'+'\n\n'.join(extra),'utf-8')
