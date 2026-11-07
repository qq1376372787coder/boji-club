from pathlib import Path
import subprocess,sys,tempfile
root=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory() as tmp:
 p=Path(tmp)/'plans.swift'
 subprocess.run([sys.executable,str(root/'tests/build_plan_changes_swift_tests.py'),str(p)],check=True)
 content=p.read_text('utf-8')
def block(s,marker):
 start=s.index(marker);i=s.index('{',start);depth=1;j=i+1
 while depth:
  if s[j]=='{':depth+=1
  elif s[j]=='}':depth-=1
  j+=1
 return s[start:j]
daily=(root/'BojiClub/DailyExperience.swift').read_text('utf-8')
extra='enum WorkoutSessions { '+block(daily,'static func initialize(_ day:')+' }\n'+block(daily,'enum TrainingExecutionCapture {')
extra+=r'''
func summaryDay(on date:Date,weight:Double=20,reps:Int=10,count:Int=2,time:Int?=nil,saved:Bool=true) -> DayLog {
    let session=UUID();let exercise=Exercise(name:time == nil ? "卧推" : "平板支撑",muscle:"全身",sets:(0..<count).map { _ in TrainingSet(weight:time == nil ? weight : 0,reps:time == nil ? reps : 0,completed:true,durationSeconds:time) },libraryID:time == nil ? "bench" : "plank",workoutSessionID:session)
    var day=DayLog();day.exercises=[exercise];day.workoutStartedAt=date;day.workoutEndedAt=date.addingTimeInterval(60);day.workoutSavedAt=saved ? date.addingTimeInterval(61):nil
    day.activeWorkoutSessionID=session;day.workoutSessions=[WorkoutSession(id:session,startedAt:date,endedAt:day.workoutEndedAt,savedAt:day.workoutSavedAt)]
    return day
}
let summaryNow=now.addingTimeInterval(3600)
var summaryState=SavedState();summaryState.days[ClubDates.key(yesterday)]=summaryDay(on:yesterday,reps:10)
summaryState.days[today]=summaryDay(on:now,reps:12)
let sessionID=summaryState.days[today]!.activeWorkoutSessionID!
let summary=ClubWorkoutSummaryRules.make(state:summaryState,date:now,sessionID:sessionID,now:summaryNow)!
check(summary.completedSets==2 && summary.comparisons.count==1 && summary.comparisons[0].currentValue==24 && summary.comparisons[0].priorValue==20, "same exercise, unit, weight and group count produce traceable actual rep comparison")
check(summary.comparisons[0].priorSessionID==summaryState.days[ClubDates.key(yesterday)]!.activeWorkoutSessionID, "comparison records the exact prior session")
check(summary.targetSets==nil && summary.limitations.contains { $0.contains("不补造") }, "old sessions never receive invented target baselines")
var moreGroups=summaryState;moreGroups.days[today]=summaryDay(on:now,reps:12,count:3)
let moreReport=ClubWorkoutSummaryRules.make(state:moreGroups,date:now,sessionID:moreGroups.days[today]!.activeWorkoutSessionID!,now:summaryNow)!
check(!moreReport.comparisons[0].comparable, "different group counts cannot claim progress from aggregate reps")
var heavier=summaryState;heavier.days[today]=summaryDay(on:now,weight:25)
check(ClubWorkoutSummaryRules.make(state:heavier,date:now,sessionID:heavier.days[today]!.activeWorkoutSessionID!,now:summaryNow)!.comparisons.isEmpty, "different weight does not masquerade as same-load improvement")
var unconfirmed=summaryState;unconfirmed.days[ClubDates.key(yesterday)]!.workoutSessions![0].savedAt=nil
check(ClubWorkoutSummaryRules.make(state:unconfirmed,date:now,sessionID:sessionID,now:summaryNow)!.comparisons.isEmpty, "unconfirmed previous training is not a comparison source")
var unknown=summaryState;unknown.days[today]!.exercises[0].libraryID=nil;unknown.days[ClubDates.key(yesterday)]!.exercises[0].libraryID=nil
check(ClubWorkoutSummaryRules.make(state:unknown,date:now,sessionID:sessionID,now:summaryNow)!.comparisons.isEmpty, "free-text names alone do not prove a matching variant")
var timedSummary=SavedState();timedSummary.days[ClubDates.key(yesterday)]=summaryDay(on:yesterday,time:30);timedSummary.days[today]=summaryDay(on:now,time:40)
let timeReport=ClubWorkoutSummaryRules.make(state:timedSummary,date:now,sessionID:timedSummary.days[today]!.activeWorkoutSessionID!,now:summaryNow)!
check(timeReport.timedSeconds==80 && timeReport.comparisons[0].unit=="time" && timeReport.comparisons[0].currentValue==80, "timed activities compare seconds without inventing volume or load")
var duplicateSummary=summaryState;var duplicateExercise=duplicateSummary.days[today]!.exercises[0];duplicateExercise.id=UUID();duplicateExercise.sets=duplicateExercise.sets.map { set in var copy=set;copy.id=UUID();return copy };duplicateSummary.days[today]!.exercises.append(duplicateExercise)
check(ClubWorkoutSummaryRules.make(state:duplicateSummary,date:now,sessionID:sessionID,now:summaryNow)!.comparisons.isEmpty, "duplicated exercise variants are not paired arbitrarily")
check(ClubWorkoutSummaryRules.make(state:summaryState,date:tomorrow,sessionID:sessionID,now:summaryNow)==nil, "future training cannot produce a summary")
var captureBefore=DayLog(exercises:[Exercise(name:"卧推",muscle:"胸",sets:[TrainingSet(weight:20,reps:10)],libraryID:"bench")])
var captureAfter=captureBefore;captureAfter.workoutStartedAt=Date();captureAfter.exercises[0].sets[0].weight=25;captureAfter.exercises[0].sets[0].reps=8;captureAfter.exercises[0].sets[0].completed=true
TrainingExecutionCapture.capture(before:captureBefore,after:&captureAfter,on:Date(),restSeconds:90)
let executionSnapshot=captureAfter.workoutSessions!.first!.executionBaseline!
check(executionSnapshot.sets[0].targetWeight==20 && executionSnapshot.sets[0].targetReps==10 && executionSnapshot.restSeconds==90, "first completion freezes BEFORE values and configured rest, not the entered actual result")
var changedCapture=captureAfter;changedCapture.exercises[0].sets[0].weight=30
TrainingExecutionCapture.capture(before:captureAfter,after:&changedCapture,on:Date(),restSeconds:120)
check(changedCapture.workoutSessions!.first!.executionBaseline==executionSnapshot, "later edits never overwrite captured targets")
var oldCapture=captureBefore;oldCapture.workoutStartedAt=Date()
TrainingExecutionCapture.capture(before:captureBefore,after:&oldCapture,on:ClubDates.calendar.date(byAdding:.day,value:-1,to:Date())!)
check(oldCapture.workoutSessions==nil, "historical backfill never manufactures a start-time baseline")
var perSession=summaryState;let second=summaryDay(on:now.addingTimeInterval(300),reps:14)
perSession.days[today]!.exercises+=second.exercises;perSession.days[today]!.workoutSessions!+=second.workoutSessions!
let sessions=ClubWorkoutSummaryRules.available(state:perSession,date:now,now:summaryNow)
check(sessions.count==2, "same-day workouts remain separate summary identities")
_ = ClubInsightLedger.reconcile(state:&perSession,dates:[today],now:summaryNow)
let sessionEvents=ClubInsightLedger.events(in:perSession).filter { $0.kind == .workout }
check(sessionEvents.count==2 && Set(sessionEvents.map(\.groupID)).count==2, "one workout summary group per confirmed session")
check(ClubInsightLedger.reconcile(state:&perSession,dates:[today],now:summaryNow.addingTimeInterval(1)).isEmpty, "reopening or retry does not duplicate session summaries")
let summaryEvent=sessionEvents.first { $0.sourceSessionID==sessionID }!
_ = ClubInsightLedger.recordFeedback(state:&perSession,kind:.workout,action:.read,eventID:summaryEvent.id,now:summaryNow)
_ = ClubInsightLedger.recordFeedback(state:&perSession,kind:.workout,action:.archive,eventID:summaryEvent.id,now:summaryNow)
check(ClubInsightLedger.isRead(summaryEvent,in:perSession) && ClubInsightLedger.isArchived(summaryEvent,in:perSession), "read and archived are independent from evidence validity")
check(ClubInsightLedger.displayState(summaryEvent,in:perSession,now:summaryNow) == .current && !ClubInsightLedger.current(in:perSession,date:now,now:summaryNow).contains { $0.id==summaryEvent.id }, "archiving hides home card without declaring its evidence stale")
_ = ClubInsightLedger.recordFeedback(state:&perSession,kind:.workout,action:.unarchive,eventID:summaryEvent.id,now:summaryNow)
check(!ClubInsightLedger.isArchived(summaryEvent,in:perSession) && ClubInsightLedger.isRead(summaryEvent,in:perSession), "unarchive restores display while preserving read state")
perSession.days[today]!.exercises[0].gifURL="https://example.invalid/changed.gif"
check(ClubInsightLedger.reconcile(state:&perSession,dates:[today],now:summaryNow).isEmpty, "GIF URL changes do not manufacture new training summary evidence")
perSession.days[ClubDates.key(yesterday)]!.exercises[0].sets[0].reps=5
let changedSummaryDates=ClubInsightLedger.reconcile(state:&perSession,dates:[ClubDates.key(yesterday)],now:summaryNow)
check(changedSummaryDates.contains(today), "correcting an earlier source updates dependent later summaries offline")
check(ClubInsightLedger.displayState(summaryEvent,in:perSession,now:summaryNow) == .updated, "superseded comparison is visibly out of date")
let newSummaryEvent=ClubInsightLedger.current(in:perSession,date:now,now:summaryNow).first { $0.kind == .workout && $0.sourceSessionID==sessionID }!
check(!ClubInsightLedger.isRead(newSummaryEvent,in:perSession), "new evidence is unread rather than inheriting old version reading state")
var isolated=SavedState();isolated.days[today]=summaryDay(on:now,reps:12)
check(ClubWorkoutSummaryRules.make(state:isolated,date:now,sessionID:isolated.days[today]!.activeWorkoutSessionID!,now:summaryNow)!.comparisons.isEmpty, "another account has no access to prior comparison records")
let summaryBytes=try JSONEncoder().encode(summary)
let decodedSummary=try JSONDecoder().decode(ClubWorkoutSummary.self,from:summaryBytes)
check(decodedSummary==summary, "computed report includes exact evidence and completion flags through Codable")
print("Workout summaries: \(tests) combined behavioral checks passed")
'''
Path(sys.argv[1]).write_text(content+'\n'+extra,'utf-8')
