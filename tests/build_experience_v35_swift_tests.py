"""Append saved workout timing regressions to the real Foundation harness."""
from pathlib import Path
import runpy, sys
out = Path(sys.argv[1])
runpy.run_path(str(Path(__file__).with_name('build_experience_v34_swift_tests.py')))
source = out.read_text('utf-8')
source += r'''
do {
    let start = ClubDates.calendar.date(bySettingHour: 10, minute: 0, second: 0, of: Date())!
    let end = start.addingTimeInterval(46 * 60)
    let now = end.addingTimeInterval(60)
    var log = DayLog()
    var exercise = Exercise(name: "哑铃卧推", muscle: "胸")
    var set = TrainingSet(); set.reps = 10; set.completed = true
    exercise.sets = [set]; log.exercises = [exercise]
    log.workoutStartedAt = start; log.workoutEndedAt = end; log.workoutSavedAt = end
    check(WorkoutTiming.completedDuration(log, on: start, now: now) == 2760, "whole workout uses its real start and end, including rest")
    check(WorkoutTiming.durationLabel(2760) == "46 分钟", "completed workout duration is readable")
    check(WorkoutTiming.durationLabel(45) == "45 秒", "short workout does not appear as zero minutes")
    check(WorkoutTiming.durationLabel(3660) == "1 小时 1 分钟", "long workout uses hours and minutes")
    check(WorkoutTiming.durationLabel(.infinity) == "未记录", "invalid duration cannot overflow integer conversion")
    var incomplete = log; incomplete.workoutStartedAt = nil
    check(WorkoutTiming.completedDuration(incomplete, on: start, now: now) == nil, "backfilled training does not invent a starting time")
    incomplete = log; incomplete.workoutEndedAt = nil
    check(WorkoutTiming.completedDuration(incomplete, on: start, now: now) == nil, "saved timestamp is not used as an end timestamp")
    incomplete = log; incomplete.workoutEndedAt = start.addingTimeInterval(-1)
    check(WorkoutTiming.completedDuration(incomplete, on: start, now: now) == nil, "negative intervals are rejected")
    incomplete = log; incomplete.workoutEndedAt = start
    check(WorkoutTiming.completedDuration(incomplete, on: start, now: now) == nil, "equal start and end do not claim zero training")
    incomplete = log; incomplete.workoutEndedAt = start.addingTimeInterval(12 * 3600 + 1)
    check(WorkoutTiming.completedDuration(incomplete, on: start, now: incomplete.workoutEndedAt!) == nil, "abandoned session longer than the save limit is rejected")
    incomplete = log; incomplete.exercises = []
    check(WorkoutTiming.completedDuration(incomplete, on: start, now: now) == nil, "empty plan does not count as completed training")
    check(WorkoutTiming.completedDuration(log, on: start, now: start) == nil, "end time ahead of the device clock is not shown")
    let tomorrow = ClubDates.calendar.date(byAdding: .day, value: 1, to: start)!
    check(WorkoutTiming.completedDuration(log, on: tomorrow, now: now) == nil, "future date never has a completed duration")
    let yesterday = ClubDates.calendar.date(byAdding: .day, value: -1, to: start)!
    check(WorkoutTiming.completedDuration(log, on: yesterday, now: now) == nil, "start time must belong to the selected date")
    let lateStart = ClubDates.calendar.date(bySettingHour: 23, minute: 50, second: 0, of: yesterday)!
    var midnight = log; midnight.workoutStartedAt = lateStart; midnight.workoutEndedAt = lateStart.addingTimeInterval(1200)
    check(WorkoutTiming.completedDuration(midnight, on: yesterday, now: now) == 1200, "a genuine workout crossing midnight keeps its starting date")
    var separate = log
    let active = UUID(), other = UUID()
    separate.exercises[0].workoutSessionID = active
    var unselected = exercise; unselected.workoutSessionID = other
    separate.exercises.append(unselected)
    separate.workoutSessions = [WorkoutSession(id: active, startedAt: start, endedAt: end, savedAt: end), WorkoutSession(id: other)]
    separate.activeWorkoutSessionID = active
    check(WorkoutTiming.completedDuration(separate, on: start, now: now) == 2760, "same-day other sessions do not add to this workout duration")
    separate.exercises[0].sets[0].completed = false
    check(WorkoutTiming.completedDuration(separate, on: start, now: now) == nil, "other-session completions cannot validate the selected session")
    print("PASS v35 saved workout duration, incomplete timings, midnight and session separation")
}
'''
out.write_text(source, 'utf-8')
print('v35 production-rule harness generated; execute with xcrun swift on Mac')
