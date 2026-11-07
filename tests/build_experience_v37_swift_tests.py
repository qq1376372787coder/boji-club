"""Exercise snapshots and account sync rules. Execute generated Swift on Mac."""
from pathlib import Path
import runpy,sys
out=Path(sys.argv[1]);runpy.run_path(str(Path(__file__).with_name('build_experience_v36_swift_tests.py')))
s=out.read_text('utf-8')
s+=r'''
do {
    let owner = AppStore()
    let definition = CustomExercise(name: " 我的平板支撑 ", muscle: "核心", equipment: "瑜伽垫", unit: "秒")
    check(owner.saveCustomExercise(definition), "personal definition persists")
    let stored = owner.customExercises[0]
    check(stored.name == "我的平板支撑", "personal name trimmed")
    check(owner.addCustomExercise(stored.id, on: now), "personal movement joins workout")
    let snapshot = owner.log(for: now).exercises[0]
    check(snapshot.customExerciseID == stored.id && snapshot.libraryID == nil && snapshot.gifURL == nil, "personal movement does not claim catalog media")
    check(snapshot.sets.allSatisfy { $0.durationSeconds == 30 && $0.reps == 0 && !$0.completed }, "explicit timed unit beats name heuristics")
    let previousDay = owner.log(for: now)
    var renamed = stored; renamed.name = "深蹲"; renamed.unit = "次"
    check(owner.saveCustomExercise(renamed), "personal definition can change")
    check(!owner.saveCustomExercise(stored), "stale editor cannot overwrite a more recent definition")
    check(try CloudMerge.same(previousDay, owner.log(for: now)), "renaming and unit changes preserve existing workout snapshot")
    var duplicate = renamed; duplicate.id = UUID(); duplicate.name = " 深蹲 "
    check(!owner.saveCustomExercise(duplicate), "duplicate normalized personal name refused")
    var bad = renamed; bad.name = String(repeating: "字", count: 61)
    check(!owner.saveCustomExercise(bad), "long personal name rejected")
    bad.name = "动作\n注入"; check(!owner.saveCustomExercise(bad), "multiline personal name rejected")
    bad.name = "动作"; bad.unit = "分钟"; check(!owner.saveCustomExercise(bad), "invalid record unit rejected")
    let english = CustomExercise(name: "bench press", unit: "秒").exercise()
    check(english.displayName == "bench press" && english.sets[0].durationSeconds == 30, "personal labels remain exact and record unit explicit")
    let replacedCustom = try WorkoutEditing.replacing(old, with: definition.exercise(), in: partial)
    check(replacedCustom.exercises[0].sets[0].id == finished.id, "replacement retains completed original set")
    check(replacedCustom.exercises[1].customExerciseID == definition.id && replacedCustom.exercises[1].sets[0].durationSeconds == 30, "custom replacement carries explicit timed identity")
    owner.allowPersistence = false; let beforeFailure = owner.state
    check(!owner.saveCustomExercise(CustomExercise(name: "保存失败测试")), "personal persistence failure reported")
    check(try CloudMerge.same(beforeFailure, owner.state), "personal save failure rolls back")
    check(!owner.deleteCustomExercise(stored.id) && owner.customExercises.count == 1, "personal deletion failure rolls back")
    owner.allowPersistence = true
    check(owner.deleteCustomExercise(stored.id), "personal deletion records tombstone")
    check(owner.log(for: now).exercises[0].customExerciseID == stored.id, "definition deletion preserves training")
    check(!owner.addCustomExercise(stored.id, on: now), "deleted definition cannot be added")
    check(!owner.saveCustomExercise(stored), "stale editor cannot resurrect deleted definition")
    var baseState = SavedState(); baseState.customExercises = [stored]
    var removed = baseState; removed.customExercises = []; removed.deletedCustomExerciseIDs = [stored.id.uuidString.lowercased()]
    let deletionMerge = try CloudMerge.merge(local: CloudState(baseState), remote: CloudState(removed), base: nil)
    check(deletionMerge.customExercises?.isEmpty == true, "offline stale custom list cannot undo remote deletion")
    var left = baseState; var right = baseState
    var editLeft = stored; editLeft.name = "左侧修改"; editLeft.unit = "次"; editLeft.updatedAt = now
    var editRight = stored; editRight.name = "右侧修改"; editRight.unit = "秒"; editRight.updatedAt = now.addingTimeInterval(10)
    left.customExercises = [editLeft]; right.customExercises = [editRight]
    let conflict = try CloudMerge.merge(local: CloudState(left), remote: CloudState(right), base: CloudState(baseState))
    check(conflict.customExercises?.first == editRight, "concurrent definition edits remain one indivisible observation")
    var newLeft = SavedState(); newLeft.customExercises = [CustomExercise(name: "左侧新增")]
    var newRight = SavedState(); newRight.customExercises = [CustomExercise(name: "右侧新增")]
    let additions = try CloudMerge.merge(local: CloudState(newLeft), remote: CloudState(newRight), base: CloudState(SavedState()))
    check(additions.customExercises?.count == 2, "concurrent personal additions both survive")
    let cloud = CloudState(newLeft); let restored = cloud.savedState()
    check(restored.customExercises == newLeft.customExercises, "private list survives cloud conversion")
    owner.editingAccountID = nil
    check(!owner.saveCustomExercise(CustomExercise(name: "未登录动作")), "personal create requires active account")
    let copier = AppStore(); copier.state.days[today] = DayLog(exercises: [definition.exercise()])
    let copied = copier.continuationSessions(starting: now, ending: ClubDates.calendar.date(byAdding: .day, value: 6, to: now)!, nextStart: tomorrow)
    check(copied.first?.exercises.first?.custom_id == definition.id && copied.first?.exercises.first?.custom_unit == "秒", "next-cycle copy preserves personal identity and unit")
    check(copier.applyAIPlan(AIResult(kind: "plan", notes: [], sessions: copied), jobID: "copy-custom"), "copied personal plan applies")
    let copiedDay = copier.state.days[copied[0].date]!
    check(copiedDay.exercises[0].customExerciseID == definition.id && copiedDay.exercises[0].sets[0].durationSeconds == 30, "applied copy preserves personal timed snapshot")
}
'''
out.write_text(s,'utf-8')
print('v37 Foundation harness generated; not executed on Windows')
