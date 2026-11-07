from pathlib import Path
import subprocess,sys,tempfile
root=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory() as tmp:
    p=Path(tmp)/'goals.swift'
    subprocess.run([sys.executable,str(root/'tests/build_goal_context_swift_tests.py'),str(p)],check=True)
    content=p.read_text('utf-8')
def block(s,marker):
    start=s.index(marker);i=s.index('{',start);depth=1;j=i+1
    while depth:
        if s[j]=='{':depth+=1
        elif s[j]=='}':depth-=1
        j+=1
    return s[start:j]
method=block((root/'BojiClub/AppStore.swift').read_text('utf-8'),'func applyProfilePlan(')
extra=r'''
let comparisonKey=window[0]
let oldMovement=Exercise(name:"俯卧撑",muscle:"胸",sets:[TrainingSet(weight:0,reps:10)],libraryID:"push")
let updatedMovement=AIPlanExercise(name:"俯卧撑",muscle:"胸",sets:[AIPlanSet(weight:nil,reps:12)],library_query:nil,library_id:"push")
let oldComparison=[comparisonKey:DayLog(exercises:[oldMovement])]
let newSession=AIPlanSession(date:comparisonKey,label:"胸",exercises:[updatedMovement])
let diffs=ClubPlanChangeRules.preview(before:oldComparison,sessions:[newSession],scope:[comparisonKey,comparisonKey,window[1]],replace:true)
check(diffs.count==2 && diffs[0].changed, "preview deduplicates scope and detects a changed rep target")
let diffRows=ClubPlanChangeRules.movements(diffs[0])
check(diffRows.count==1 && diffRows[0].label=="参数更新", "stable movement identity yields a per-set comparison")
check(diffRows[0].before?.sets[0].reps==10 && diffRows[0].after?.sets[0].reps==12, "before and after retain actual per-set values")
let appended=ClubPlanChangeRules.preview(before:oldComparison,sessions:[newSession],scope:[comparisonKey],replace:false)
check(appended[0].after.count==2, "append preview retains old movements and adds the proposal")
let rested=ClubPlanChangeRules.preview(before:oldComparison,sessions:[],scope:[comparisonKey],replace:true)
check(rested[0].label=="改为休息日" && rested[0].before.count==1 && rested[0].after.isEmpty, "rest-day replacement explicitly removes old schedule")
var startedComparison=oldComparison;startedComparison[comparisonKey]!.workoutStartedAt=Date()
let retainedDiff=ClubPlanChangeRules.preview(before:startedComparison,sessions:[newSession],scope:[comparisonKey],replace:true)
check(retainedDiff[0].retained && !retainedDiff[0].changed && retainedDiff[0].before==retainedDiff[0].after, "protected date preview never pretends a proposal was applied")
let noID=AIPlanExercise(name:"俯卧撑",muscle:"不同的标签",sets:[AIPlanSet(weight:0,reps:10)],library_query:"old query")
check(ClubPlanChangeRules.sameContents(ClubPlanChangeRules.snapshot([oldMovement]),[noID]), "nonfunctional metadata changes do not claim training parameters changed")
let timedMovement=AIPlanExercise(name:"平板支撑",muscle:"核心",sets:[AIPlanSet(weight:nil,reps:0,durationSeconds:30)],library_query:nil)
let timedDay=ClubPlanDayChange(date:comparisonKey,before:[noID],after:[timedMovement],retained:false)
let timedRows=ClubPlanChangeRules.movements(timedDay)
check(timedRows.count==2 && timedRows[0].before==nil && timedRows[1].after==nil, "different movement and time unit appear as add/remove rather than a false weight comparison")
check(ClubPlanChangeRules.setLabel(timedMovement.sets[0])=="30 秒", "timed targets display seconds without an invented weight")
let swapped=ClubPlanDayChange(date:comparisonKey,before:[noID,timedMovement],after:[timedMovement,noID],retained:false)
check(ClubPlanChangeRules.movements(swapped).allSatisfy { $0.label=="调整顺序" }, "reordering retains identity and marks order changes")
let duplicate=ClubPlanDayChange(date:comparisonKey,before:[noID,noID],after:[noID,noID],retained:false)
check(ClubPlanChangeRules.movements(duplicate).count==2 && !duplicate.changed, "repeated movements pair one-to-one without duplicate rows")
check(savedVersion.changes?.count==7 && savedVersion.changes?.first?.before.first?.name=="旧动作", "production adoption archives the actual previous arrangement")
check(savedVersion.changes?.first?.after.first?.name==prepared.sessions?.first?.exercises.first?.displayName, "production audit is built from saved schedule rather than unadopted proposal")
var oldVersion=savedVersion;oldVersion.changes=nil
let oldData=try JSONEncoder().encode(oldVersion)
let decodedOld=try JSONDecoder().decode(ClubPlanVersion.self,from:oldData)
check(decodedOld.changes==nil, "old versions decode without fabricating a before/after audit")
var profileFixture=AdoptionFixture();profileFixture.state.profile.trainingDays=[1,3,5]
let profileBaseline=Dictionary(uniqueKeysWithValues:window.map { ($0,DayLog()) })
let validProfileSessions=window.filter { key in
    let day=ClubDates.date(fromKey:key)!;let weekday=(ClubDates.calendar.component(.weekday,from:day)+5)%7+1
    return [1,3,5].contains(weekday)
}.map { AIPlanSession(date:$0,label:"更新",exercises:[updatedMovement]) }
let profileResult=AIResult(kind:"plan",sessions:validProfileSessions,plan_days:7)
profileFixture.state.days=profileBaseline
profileFixture.state.days[window[0]]!.exercises=[oldMovement]
check(!profileFixture.applyProfilePlan(profileResult,jobID:"profile-stale",start:futureStart,expectedDays:profileBaseline), "profile-generated plan rejects a stale training preview")
check(profileFixture.state.days[window[0]]!.exercises.first?.id==oldMovement.id, "stale profile adoption leaves original schedule intact")
profileFixture.state.days=profileBaseline
check(profileFixture.applyProfilePlan(profileResult,jobID:"profile-fresh",start:futureStart,expectedDays:profileBaseline), "profile-generated plan accepts unchanged confirmed baseline")
check(profileFixture.state.days[window[0]]!.planVersions?.first?.changes?.count==7, "profile adoption stores the same exact audit trail")
print("Plan changes: \(tests) combined behavioral checks passed")
'''
Path(sys.argv[1]).write_text(content+'\nextension AdoptionFixture {\n'+method+'\n}\n'+extra,'utf-8')
