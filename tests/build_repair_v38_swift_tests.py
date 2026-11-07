"""Generate tests using production Foundation rules. Run with Swift on Mac."""
from pathlib import Path
import runpy, sys, re
out = Path(sys.argv[1])
runpy.run_path(str(Path(__file__).with_name('build_experience_v37_swift_tests.py')))
root = Path(__file__).resolve().parents[1]
s = out.read_text('utf-8')
store = (root/'BojiClub/AppStore.swift').read_text('utf-8')
def method(name):
    match = re.search(r'(?m)^    (?:private )?func '+name+r'\(',store)
    start = store.index('{',match.start()); end=start+1; depth=1
    while depth:
        if store[end]=='{': depth+=1
        elif store[end]=='}': depth-=1
        end+=1
    return store[match.start():end]
backup_start = store.index('private func validateBackupValue(')
s += '\n' + store[backup_start:store.index('@MainActor', backup_start)].replace('private func validateBackupValue(', 'func validateBackupValue(')
s=s.replace('final class AppStore {', 'final class AppStore {\n'+method('saveWeeklyReview')+'\n'+method('removeWeeklyReview'), 1)
s+=r'''
do {
    var a = SavedState(), b = SavedState()
    let source = UUID().uuidString.lowercased()
    var shared = Meal(name: "鸡蛋", category: "早餐", calories: 150, protein: 12, carbs: 1, fat: 10, sourceAIJobID: source)
    let dateA = "2026-10-08", dateB = "2026-10-09"
    a.days[dateA] = DayLog(meals: [shared]); b.days[dateB] = DayLog(meals: [shared])
    let collapsed = try CloudMerge.merge(local: CloudState(a), remote: CloudState(b), base: CloudState(SavedState()))
    check(collapsed.days.values.flatMap(\.meals).count == 1, "single AI meal cannot count on two dates")
    check(collapsed.days[dateA]?.meals.first?.placementConflictDates == [dateA,dateB], "date ambiguity remains visible")
    let reverse = try CloudMerge.merge(local: CloudState(b), remote: CloudState(a), base: CloudState(SavedState()))
    check(try CloudMerge.same(collapsed.days, reverse.days), "meal date conflict converges in either merge direction")
    var manual = shared; manual.id = UUID(); manual.sourceAIJobID = nil
    a.days[dateA]?.meals.append(manual);b.days[dateB]?.meals.append(manual)
    let withManual = try CloudMerge.merge(local: CloudState(a), remote: CloudState(b), base: nil)
    check(withManual.days.values.flatMap(\.meals).count == 3, "unrelated manual meals are not deduplicated by name")
    let resolver = AppStore(); resolver.state = collapsed.savedState()
    resolver.allowPersistence=false
    let unresolved=resolver.state
    check(!resolver.confirmMealPlacement(shared.id,currentDate:dateA,destination:dateB), "failed date choice reports failure")
    check(try CloudMerge.same(unresolved,resolver.state), "failed date choice retains the original conflict and meal")
    resolver.allowPersistence=true
    check(resolver.confirmMealPlacement(shared.id, currentDate: dateA, destination: dateB), "user can choose the correct meal date")
    let resolved = try CloudMerge.merge(local: CloudState(resolver.state), remote: CloudState(a), base: collapsed)
    check(resolved.days[dateA]?.meals.filter { $0.sourceAIJobID == source }.isEmpty != false, "old offline copy cannot undo a confirmed placement")
    check(resolved.days[dateB]?.meals.first?.placementConflictDates == nil, "resolved date does not re-prompt for a stale duplicate")
    let beforeFailure = resolver.state;resolver.allowPersistence=false
    check(!resolver.confirmMealPlacement(shared.id, currentDate: dateB, destination: dateA), "resolved meal is protected against a stale picker")
    check(try CloudMerge.same(beforeFailure, resolver.state), "stale placement does not mutate records")

    let sid=UUID(); let ex=Exercise(name:"哑铃弯举",muscle:"手臂",sets:[TrainingSet(weight:10,reps:10,completed:true)],workoutSessionID:sid)
    var original=DayLog(exercises:[ex],workoutSessions:[WorkoutSession(id:sid)],activeWorkoutSessionID:sid)
    var edit=original, finish=original
    edit.exercises[0].sets[0].reps=12
    finish.workoutSavedAt=now;finish.workoutSessions?[0].savedAt=now
    var base=SavedState(), left=base, right=base
    base.days[today]=original;left.days[today]=edit;right.days[today]=finish
    let mixed=try CloudMerge.merge(local:CloudState(left),remote:CloudState(right),base:CloudState(base))
    check(mixed.days[today]?.exercises[0].sets[0].reps==12, "merged edit is preserved")
    check(mixed.days[today]?.isTrainingConfirmed==false, "confirmation never applies to different merged reps")
    check(mixed.days[today]?.workoutSessions?[0].savedAt==nil, "session confirmation also invalidates")
    left.days[today]=original
    let clean=try CloudMerge.merge(local:CloudState(left),remote:CloudState(right),base:CloudState(base))
    check(clean.days[today]?.isTrainingConfirmed==true, "unchanged training keeps a valid remote confirmation")
    original.workoutSessions=nil;original.activeWorkoutSessionID=nil
    edit=original;finish=original;edit.exercises[0].sets[0].weight=12;finish.workoutSavedAt=now
    base.days[today]=original;left.days[today]=edit;right.days[today]=finish
    let legacy=try CloudMerge.merge(local:CloudState(left),remote:CloudState(right),base:CloudState(base))
    check(legacy.days[today]?.workoutSavedAt==nil, "legacy single session also requires content-bound confirmation")

    check(RecordLimits.valid(TrainingSet(weight: 2000, reps: 1000)), "maximum saved training values are valid for restore")
    check(RecordLimits.valid(TrainingSet(reps: 300)), "300 reps can be restored")
    check(!RecordLimits.valid(TrainingSet(weight: .infinity)), "nonfinite weights remain invalid")
    check(!RecordLimits.valid(TrainingSet(reps: 1001)), "out-of-contract reps remain invalid")
    var excessive=shared;excessive.calories=100001
    check(!RecordLimits.valid(excessive), "out-of-contract nutrition remains invalid")
    let emojis=CustomExercise(name:"自定义动作"+String(repeating:"💪🏻",count:35))
    check(!emojis.valid, "combined emoji cannot pass native length then fail server")
    check(CustomExercise(name:"自定义动作"+String(repeating:"💪🏻",count:20)).valid, "ordinary emoji names remain supported")

    let reports=AppStore()
    let result=WeeklyResult(kind:"weekly_review",summary:"总结",training:"训练",nutrition:"饮食",recovery:"恢复",appearance:"",photoFeedback:[],decision:"keep",reason:"保持",notes:[],sessions:[])
    var old=WeeklyReview(date:today);old.result=result;old.updatedAt=now
    var fresh=old;fresh.id=UUID();fresh.updatedAt=now.addingTimeInterval(1)
    check(reports.saveWeeklyReview(old), "first weekly result saves")
    check(reports.saveWeeklyReview(fresh), "updated weekly result saves without a permanent retry trap")
    check(reports.state.days[today]?.weeklyReview?.id==fresh.id, "newest weekly version is canonical")
    check(reports.state.days[today]?.weeklyReviewHistory?.first?.id==old.id, "older weekly version remains in history")
    var concurrentLeft=SavedState(), concurrentRight=SavedState()
    concurrentLeft.days[today]=DayLog(weeklyReview:old)
    concurrentRight.days[today]=DayLog(weeklyReview:fresh)
    let versions=try CloudMerge.merge(local:CloudState(concurrentLeft),remote:CloudState(concurrentRight),base:CloudState(SavedState()))
    check(versions.days[today]?.weeklyReviews.count==2, "two devices generating reports retain both IDs")
    var restored=versions.days[today]!
    WeeklyVersions.restore(&restored,deletedJobIDs:[])
    check(restored.weeklyReviews.allSatisfy { $0.applied && $0.photos.isEmpty }, "restored history cannot reapply old recommendations")
    let timedBackup=DayLog(workoutSessions:[WorkoutSession(id:sid,startedAt:now,endedAt:now,savedAt:now)])
    try validateBackupValue(JSONValue.encode(timedBackup))
    check(true, "session confirmation timestamp passes monthly restore validation")
    var confirmedMeal=shared;confirmedMeal.placementConfirmedAt=now
    try validateBackupValue(JSONValue.encode(confirmedMeal))
    check(true, "meal placement timestamp passes monthly restore validation")
    check(reports.saveWeeklyReview(old), "late result can be retained as history")
    check(reports.state.days[today]?.weeklyReview?.id==fresh.id, "late older result does not replace newer summary")
    check(reports.removeWeeklyReview(fresh), "delete one weekly version")
    check(reports.state.days[today]?.weeklyReview?.id==old.id, "deleting latest promotes remaining report")
    check(!reports.saveWeeklyReview(fresh), "late task cannot resurrect deleted report")
    reports.allowPersistence=false;let before=reports.state
    var fail=old;fail.id=UUID();fail.updatedAt=now.addingTimeInterval(3)
    check(!reports.saveWeeklyReview(fail), "weekly save failure is reported")
    check(try CloudMerge.same(before,reports.state), "weekly version rollback preserves original state")
}
'''
out.write_text(s,'utf-8')
print('v38 production Foundation regression harness generated; execute with Swift on Mac')
