from pathlib import Path
import subprocess,sys,tempfile
root=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory() as tmp:
 p=Path(tmp)/'source.swift'
 subprocess.run([sys.executable,str(root/'tests/build_workout_summary_swift_tests.py'),str(p)],check=True)
 source=p.read_text('utf-8')
source+='\n'+(root/'BojiClub/ClubPlanFollowup.swift').read_text('utf-8')
source+=r'''
func followBaseline(_ day:DayLog)->WorkoutExecutionBaseline {
 WorkoutExecutionBaseline(capturedAt:day.workoutSessions!.first!.startedAt!,sets:day.exercises.flatMap { exercise in
  exercise.sets.map { set in WorkoutBaselineSet(id:set.id,exerciseID:exercise.id,unit:set.durationSeconds == nil ? "reps":"time",targetSeconds:set.durationSeconds,targetReps:set.durationSeconds == nil ? set.reps:nil,targetWeight:set.durationSeconds == nil ? set.weight:nil) }
 })
}
var followState=summaryState
followState.days[today]!.workoutSessions![0].executionBaseline=followBaseline(followState.days[today]!)
let followPlan=ClubPlanChangeRules.snapshot(followState.days[today]!.exercises)
let followProfile=MemberProfile()
let followVersion=ClubPlanVersion(id:"follow-plan",recordedAt:now.addingTimeInterval(-60),source:"weekly_review",title:"调整后的计划",start:today,duration:7,
 sessions:[AIPlanSession(date:today,label:"训练",exercises:followPlan)],requestedProfile:followProfile,adoptedProfile:followProfile,nutrition:NutritionTarget.estimate(followProfile),
 previousIDs:[],scopeDates:[today],retainedDates:[],changes:[ClubPlanDayChange(date:today,before:[],after:followPlan,retained:false)])
followState.days[today]!.planVersions=[followVersion]
let followNow=now.addingTimeInterval(3600)
func followDay(_ state:SavedState,_ version:ClubPlanVersion=followVersion,_ time:Date=followNow)->ClubPlanFollowupDay {
 ClubPlanFollowupRules.make(version:version,state:state,now:time).days.first!
}
let followReport=ClubPlanFollowupRules.make(version:followVersion,state:followState,now:followNow)
check(followReport.confirmedDays==1 && followReport.days[0].completedOriginalSets==2 && followReport.days[0].achievedTargets==2,"only a confirmed session with matching start targets counts as a plan execution observation")
check(followReport.days[0].comparisons.first?.priorDate==ClubDates.key(yesterday),"comparison cites the exact before-plan date")
var followSparse=followState;followSparse.days[today]!.exercises=[];followSparse.days[today]!.workoutSessions=nil;followSparse.days[today]!.workoutSavedAt=nil
check(followDay(followSparse).status == .notObserved,"missing records remain unobserved rather than judged skipped")
var followOpen=followState;followOpen.days[today]!.workoutSessions![0].savedAt=nil
check(followDay(followOpen).status == .inProgress,"an ongoing session is never counted as a finished plan day")
var followLegacy=followState;followLegacy.days[today]!.workoutSessions![0].executionBaseline=nil
check(followDay(followLegacy).status == .unknown,"old and backfilled training cannot acquire an invented original target")
var followMissingLoad=followState;followMissingLoad.days[today]!.workoutSessions![0].executionBaseline!.sets[0].targetWeight=nil
check(followDay(followMissingLoad).status == .unknown,"partial legacy target data does not prove the adopted parameters")
var followChanged=followState;followChanged.days[today]!.workoutSessions![0].executionBaseline!.sets[0].targetReps=8
check(followDay(followChanged).status == .changed,"edits before starting are explained rather than attributed to original prescription")
var followActual=followState;followActual.days[today]!.exercises[0].sets[0].reps=6
check(followDay(followActual).status == .confirmed && followDay(followActual).achievedTargets==1,"changed actual performance never rewrites the original target")
var followHeavy=followState;followHeavy.days[today]!.exercises[0].sets[0].weight=25
check(followDay(followHeavy).changedLoadOrUnitSets==1 && followDay(followHeavy).achievedTargets==1,"a heavier actual load is not automatically counted as meeting a same-load rep target")
var followExtra=followState;followExtra.days[today]!.exercises[0].sets.append(TrainingSet(weight:20,reps:20,completed:true))
check(followDay(followExtra).completedOriginalSets==2 && followDay(followExtra).targetSets==2,"new actual groups cannot inflate original-goal completion")
check(followDay(followExtra).comparisons.isEmpty,"different group counts do not turn aggregate reps into progress")
var followDelete=followState;followDelete.days[today]!.exercises[0].sets.removeLast()
check(followDay(followDelete).completedOriginalSets==1 && followDay(followDelete).changedLoadOrUnitSets==1,"removed original group remains missing in execution audit")
var followInvalid=followState;for index in followInvalid.days[today]!.exercises[0].sets.indices {followInvalid.days[today]!.exercises[0].sets[index].completed=false}
check(followDay(followInvalid).status == .unknown,"a stale confirmation flag without completed groups is not accepted as evidence")
var followEarlier=followState;followEarlier.days[today]!.workoutSessions![0].startedAt=now.addingTimeInterval(-120)
check(followDay(followEarlier).status == .unknown,"training that began before adoption is not attributed to a later plan")
var followNoAudit=followVersion;followNoAudit.changes=nil
var followOldState=followState;followOldState.days[today]!.planVersions=[followNoAudit]
check(followDay(followOldState,followNoAudit).status == .unknown,"legacy proposal sessions cannot replace a missing actual-adoption snapshot")
check(!ClubPlanFollowupRules.make(version:followNoAudit,state:followOldState,now:followNow).hasCompleteAdoptionSnapshot,"missing old snapshots do not become a fictional zero-training-day total")
var followRetained=followVersion
followRetained=ClubPlanVersion(id:followVersion.id,recordedAt:followVersion.recordedAt,source:followVersion.source,title:followVersion.title,start:today,duration:7,sessions:followVersion.sessions,requestedProfile:followProfile,adoptedProfile:followProfile,nutrition:followVersion.nutrition,previousIDs:[],scopeDates:[today],retainedDates:[today],changes:followVersion.changes)
var followRetainedState=followState;followRetainedState.days[today]!.planVersions=[followRetained]
check(followDay(followRetainedState,followRetained).status == .retained,"protected pre-existing training stays outside the adjustment evaluation")
func followChild(_ id:String,_ adopted:Date)->ClubPlanVersion {
 ClubPlanVersion(id:id,recordedAt:adopted,source:"manual",title:"后续计划",start:today,duration:7,sessions:followVersion.sessions,requestedProfile:followProfile,adoptedProfile:followProfile,nutrition:followVersion.nutrition,previousIDs:[followVersion.id],scopeDates:[today],retainedDates:[],changes:followVersion.changes)
}
let followReplacement=followChild("replacement",now.addingTimeInterval(-30))
var followReplaced=followState;followReplaced.days[today]!.planVersions!.append(followReplacement)
check(followDay(followReplaced).status == .superseded,"a matching-looking workout after replacement is not assigned back to the old plan")
check(followDay(followReplaced,followReplacement).status == .confirmed,"the active descendant can match its own start-time targets")
let followLater=followChild("later",now.addingTimeInterval(90))
var followLaterState=followState;followLaterState.days[today]!.planVersions!.append(followLater)
check(followDay(followLaterState).status == .confirmed,"later adoption never relabels an earlier observed execution")
check(followDay(followLaterState,followLater).status == .unknown,"old completed work cannot satisfy a plan adopted afterward")
var followBranches=followReplaced;followBranches.days[today]!.planVersions!.append(followChild("concurrent",now.addingTimeInterval(-20)))
check(followDay(followBranches).status == .unknown && followDay(followBranches,followReplacement).status == .unknown,"concurrent branches remain ambiguous regardless of clock order")
let followRetainingChild=ClubPlanVersion(id:"retaining-child",recordedAt:now.addingTimeInterval(-40),source:"manual",title:"保留当天",start:today,duration:7,sessions:[],requestedProfile:followProfile,adoptedProfile:followProfile,nutrition:followVersion.nutrition,previousIDs:[followVersion.id],scopeDates:[today],retainedDates:[today],changes:followVersion.changes)
let followGrandchild=ClubPlanVersion(id:"grandchild",recordedAt:now.addingTimeInterval(-20),source:"manual",title:"后续采用",start:today,duration:7,sessions:[],requestedProfile:followProfile,adoptedProfile:followProfile,nutrition:followVersion.nutrition,previousIDs:[followRetainingChild.id],scopeDates:[today],retainedDates:[],changes:followVersion.changes)
var followAncestry=followState;followAncestry.days[today]!.planVersions! += [followRetainingChild,followGrandchild]
check(ClubPlanFollowupRules.frontier(followAncestry.days[today]!.planVersions!,date:today,through:now).map(\.id)==[followGrandchild.id],"causal ancestors are followed through retained intermediate versions")
check(followDay(followAncestry,followGrandchild).status == .confirmed,"known causal succession does not become a false concurrent conflict")
var followTwo=followState;var followSecond=summaryDay(on:now.addingTimeInterval(120),reps:12)
followSecond.workoutSessions![0].executionBaseline=followBaseline(followSecond)
followTwo.days[today]!.exercises+=followSecond.exercises;followTwo.days[today]!.workoutSessions!+=followSecond.workoutSessions!
check(followDay(followTwo).status == .unknown,"identical extra sessions are not arbitrarily assigned to the schedule")
let followFutureKey=ClubDates.key(tomorrow)
let followFutureVersion=ClubPlanVersion(id:"future-plan",recordedAt:now.addingTimeInterval(-60),source:"manual",title:"明日安排",start:followFutureKey,duration:7,sessions:[],requestedProfile:followProfile,adoptedProfile:followProfile,nutrition:followVersion.nutrition,previousIDs:[],scopeDates:[followFutureKey],retainedDates:[],changes:[ClubPlanDayChange(date:followFutureKey,before:[],after:followPlan,retained:false)])
var followFutureState=followState;followFutureState.days[today]!.planVersions!.append(followFutureVersion)
check(followDay(followFutureState,followFutureVersion).status == .waiting,"future days never count as missed or completed")
let followFutureChild=ClubPlanVersion(id:"future-child",recordedAt:now.addingTimeInterval(-30),source:"manual",title:"新明日安排",start:followFutureKey,duration:7,sessions:[],requestedProfile:followProfile,adoptedProfile:followProfile,nutrition:followVersion.nutrition,previousIDs:[followFutureVersion.id],scopeDates:[followFutureKey],retainedDates:[],changes:followFutureVersion.changes)
followFutureState.days[today]!.planVersions!.append(followFutureChild)
check(followDay(followFutureState,followFutureVersion).status == .superseded,"a future superseded date stops waiting for the old arrangement")
var followOtherAccount=followState;followOtherAccount.days[today]!.planVersions=nil
check(followDay(followOtherAccount).status == .unknown,"a version absent from the active account state cannot inherit its workout records")
var followWindow=followState
var followNextDay=summaryDay(on:tomorrow,reps:12);followNextDay.workoutSessions![0].executionBaseline=followBaseline(followNextDay)
let followNextPlan=ClubPlanChangeRules.snapshot(followNextDay.exercises)
let followWindowVersion=ClubPlanVersion(id:"window-plan",recordedAt:now.addingTimeInterval(-60),source:"manual",title:"多日方案",start:today,duration:7,sessions:[],requestedProfile:followProfile,adoptedProfile:followProfile,nutrition:followVersion.nutrition,previousIDs:[],scopeDates:[today,followFutureKey],retainedDates:[],changes:[ClubPlanDayChange(date:today,before:[],after:followPlan,retained:false),ClubPlanDayChange(date:followFutureKey,before:[],after:followNextPlan,retained:false)])
followWindow.days[today]!.planVersions=[followWindowVersion];followWindow.days[followFutureKey]=followNextDay
let followWindowReport=ClubPlanFollowupRules.make(version:followWindowVersion,state:followWindow,now:tomorrow.addingTimeInterval(3600))
check(followWindowReport.days[1].comparisons.first?.priorDate==ClubDates.key(yesterday),"a workout within the new plan never masquerades as the pre-adjustment comparison baseline")
let followRestVersion=ClubPlanVersion(id:"rest-plan",recordedAt:now.addingTimeInterval(-60),source:"manual",title:"恢复",start:today,duration:7,sessions:[],requestedProfile:followProfile,adoptedProfile:followProfile,nutrition:followVersion.nutrition,previousIDs:[],scopeDates:[today],retainedDates:[],changes:[ClubPlanDayChange(date:today,before:[],after:[],retained:false)])
var followRestState=followSparse;followRestState.days[today]!.planVersions=[followRestVersion]
check(followDay(followRestState,followRestVersion).status == .rest,"rest schedule does not require a fictitious completion tick")
var followTimed=SavedState();followTimed.days[today]=summaryDay(on:now,time:30)
followTimed.days[today]!.workoutSessions![0].executionBaseline=followBaseline(followTimed.days[today]!)
let followTimedPlan=ClubPlanChangeRules.snapshot(followTimed.days[today]!.exercises)
let followTimedVersion=ClubPlanVersion(id:"timed",recordedAt:now.addingTimeInterval(-60),source:"manual",title:"计时",start:today,duration:7,sessions:[],requestedProfile:followProfile,adoptedProfile:followProfile,nutrition:followVersion.nutrition,previousIDs:[],scopeDates:[today],retainedDates:[],changes:[ClubPlanDayChange(date:today,before:[],after:followTimedPlan,retained:false)])
followTimed.days[today]!.planVersions=[followTimedVersion];followTimed.days[today]!.exercises[0].sets[0].durationSeconds=20
check(followDay(followTimed,followTimedVersion).achievedTargets==1,"timed completion compares actual seconds to the frozen seconds, with no rep conversion")
print("Plan follow-up native fixtures: \(tests) combined checks")
'''
Path(sys.argv[1]).write_text(source,'utf-8')
