from pathlib import Path
import subprocess,sys,tempfile
root=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory() as tmp:
    existing=Path(tmp)/'base.swift'
    subprocess.run([sys.executable,str(root/'tests/build_upgrade_v140_swift_tests.py'),str(existing)],check=True)
    content=existing.read_text('utf-8')
def block(s,marker):
    start=s.index(marker);i=s.index('{',start);depth=1;j=i+1
    while depth:
        if s[j]=='{':depth+=1
        elif s[j]=='}':depth-=1
        j+=1
    return s[start:j]
daily=(root/'BojiClub/DailyExperience.swift').read_text('utf-8')
automation=(root/'BojiClub/ClubAutomation.swift').read_text('utf-8')
trend=(root/'BojiClub/TrendAnalysis.swift').read_text('utf-8')
models=(root/'BojiClub/Models.swift').read_text('utf-8')
ai=(root/'BojiClub/AIService.swift').read_text('utf-8')
experience=(root/'BojiClub/Experience130.swift').read_text('utf-8')
extra=[]
# Build135 added per-field fact provenance to MemberProfile and uses the app's
# JSONValue for its plan projection. Keep the generated rule fixture aligned
# with those production model dependencies.
# ProfileFactMeta / JSONValue / WeeklyRecurrence130 now come from upgrade_v140.
if 'struct ProfileFactMeta:' not in content: extra.append(block(models,'struct ProfileFactMeta:'))
if 'enum JSONValue:' not in content: extra.append(block(ai,'enum JSONValue:'))
if 'struct WeeklyRecurrence130:' not in content: extra.append(block(experience,'struct WeeklyRecurrence130:'))
extra.append(block(daily,'enum WorkoutTiming {'))
extra.append(block(daily,'struct ActiveWorkoutSnapshot:'))
extra.append(block(daily,'enum ActiveWorkoutRules {'))
extra.append(block(daily,'enum HomeTrainingState:'))
extra.append(block(automation,'struct ClubRestResume:'))
extra.append(block(automation,'struct WorkoutPauseState:'))
extra.append(block(automation,'enum ClubWorkoutPauseStorage {'))
extra.append(block(automation,'enum ClubRestStorage {'))
extra.append('enum ClubAutomationSettings { static func key(_ owner:Int)->String { "fixture-settings" } }\nenum ClubAnalysisNotifications { static func key(kind:String,owner:Int)->String { "fixture-\(kind)" } }')
for marker in ['enum ReviewTrendScale:','enum ReviewTrendMetric:','struct ReviewTrendPoint:','struct ReviewTrendSeries:','enum ReviewTrendRules {']:
    extra.append(block(trend,marker))
extra.append(r'''
func v150Day(_ date: Date, session: UUID, started: Date, sets: [(Double, Int, Bool)],
             savedAt: Date? = nil, library: String = "bench") -> DayLog {
    var day = DayLog()
    day.workoutStartedAt = started
    day.activeWorkoutSessionID = savedAt == nil ? session : nil
    day.workoutSavedAt = savedAt
    day.workoutSessions = [WorkoutSession(id: session, startedAt: started,
        endedAt: savedAt, savedAt: savedAt)]
    day.exercises = [Exercise(name: "卧推", muscle: "胸", sets: sets.map { TrainingSet(weight: $0.0, reps: $0.1, completed: $0.2) },
        libraryID: library, workoutSessionID: session)]
    return day
}
let v150Now = now.addingTimeInterval(6 * 3600)
var activeState = SavedState()
let activeSession = UUID()
activeState.days[today] = v150Day(now, session: activeSession, started: v150Now.addingTimeInterval(-1800),
    sets: [(20, 10, true), (20, 10, false), (20, 10, false)])
let active = ActiveWorkoutRules.snapshot(state: activeState, now: v150Now)!
check(active.sessionID == activeSession && active.completedSets == 1 && active.totalSets == 3,
      "active workout snapshot uses the persisted session and completed sets")
check(active.currentSetNumber == 2 && active.currentExerciseName == "卧推",
      "active snapshot points at the next incomplete set")
check(abs(active.elapsed - 1800) < 5, "active elapsed comes from persisted start time, not an in-memory timer")
let pausedState = WorkoutPauseState(pausedAt: v150Now.addingTimeInterval(-600), accumulated: 300, sessionID: activeSession)
let paused = ActiveWorkoutRules.snapshot(state: activeState, now: v150Now, pause: pausedState)!
check(paused.isPaused && abs(paused.elapsed - (1800 - 600 - 300)) < 5,
      "pause freezes elapsed and subtracts accumulated pause time")
var savedActive = activeState
savedActive.days[today] = v150Day(now, session: activeSession, started: v150Now.addingTimeInterval(-1800),
    sets: [(20, 10, true)], savedAt: v150Now)
check(ActiveWorkoutRules.snapshot(state: savedActive, now: v150Now) == nil,
      "saved sessions never appear as an active workout")
var yesterdayState = SavedState()
let crossSession = UUID()
let yesterdayMorning = ClubDates.calendar.date(byAdding: .hour, value: 23, to: yesterday)!
yesterdayState.days[ClubDates.key(yesterday)] = v150Day(yesterday, session: crossSession,
    started: yesterdayMorning, sets: [(20, 10, true), (20, 10, false)])
let cross = ActiveWorkoutRules.snapshot(state: yesterdayState, now: v150Now)
check(cross?.dateKey == ClubDates.key(yesterday), "cross-midnight workout is found from yesterday")

check(HomeTrainingState.resolve(date: now, state: SavedState(), now: v150Now) == .none,
      "empty day resolves to none")
var plannedState = SavedState()
var plannedDay = DayLog()
plannedDay.exercises = [Exercise(name: "卧推", muscle: "胸",
    sets: [TrainingSet(weight: 20, reps: 10), TrainingSet(weight: 20, reps: 10)], libraryID: "bench")]
plannedState.days[today] = plannedDay
check(HomeTrainingState.resolve(date: now, state: plannedState, now: v150Now) == .planned(title: "卧推", exerciseCount: 1, setCount: 2),
      "unsaved plan resolves to planned")
check(HomeTrainingState.resolve(date: now, state: activeState, now: v150Now).isInProgress,
      "active persisted workout wins over planned state")
var restState = SavedState(); restState.days[today] = DayLog(planCycle: TrainingCycle(start: today, plannedDates: []))
check(HomeTrainingState.resolve(date: now, state: restState, now: v150Now) == .restDay,
      "planned rest day resolves explicitly")

let defaults = UserDefaults(suiteName: "boji-v150-\(UUID().uuidString)")!
let pauseOwner = 4242
ClubWorkoutPauseStorage.save(WorkoutPauseState(pausedAt: v150Now.addingTimeInterval(-120), accumulated: 60, sessionID: activeSession),
                             owner: pauseOwner, date: now, defaults: defaults)
let restoredPause = ClubWorkoutPauseStorage.load(owner: pauseOwner, date: now, sessionID: activeSession,
                                                 now: v150Now, defaults: defaults)
check(restoredPause?.isPaused == true && restoredPause?.accumulated == 60,
      "pause state survives process restart for the same session")
ClubRestStorage.savePaused(45, owner: pauseOwner, date: now, sessionID: activeSession, defaults: defaults)
check(ClubRestStorage.pausedRemaining(owner: pauseOwner, date: now, sessionID: activeSession,
                                      unfinished: true, now: v150Now, defaults: defaults) == 45,
      "paused rest remaining survives storage")
check(ClubRestStorage.deadline(owner: pauseOwner, date: now, sessionID: activeSession,
                               unfinished: true, now: v150Now, defaults: defaults) == nil,
      "paused rest is not treated as a running deadline")
ClubRestStorage.savePaused(nil, owner: pauseOwner, date: now, sessionID: activeSession, defaults: defaults)
check(ClubRestStorage.pausedRemaining(owner: pauseOwner, date: now, sessionID: activeSession,
                                      unfinished: true, now: v150Now, defaults: defaults) == nil,
      "resuming rest clears the paused remaining")

var trendState = SavedState()
let monthCalendar = ClubDates.calendar
func monthKey(_ monthsAgo: Int, day: Int = 10) -> String {
    let base = monthCalendar.date(byAdding: .month, value: -monthsAgo, to: v150Now)!
    let start = monthCalendar.date(from: monthCalendar.dateComponents([.year, .month], from: base))!
    return ClubDates.key(monthCalendar.date(byAdding: .day, value: day - 1, to: start)!)
}
for (index, monthsAgo) in [2, 1, 0].enumerated() {
    let key = monthKey(monthsAgo)
    var day = DayLog()
    let session = UUID()
    day.exercises = [Exercise(name: "卧推", muscle: "胸",
        sets: (0..<(index + 1)).map { _ in TrainingSet(weight: 20, reps: 10, completed: true) },
        libraryID: "bench", workoutSessionID: session)]
    day.workoutSessions = [WorkoutSession(id: session, startedAt: ClubDates.date(fromKey: key)!.addingTimeInterval(3600),
        endedAt: ClubDates.date(fromKey: key)!.addingTimeInterval(7200), savedAt: ClubDates.date(fromKey: key)!.addingTimeInterval(7200))]
    day.bodyWeight = BodyWeightEntry(kilograms: 70 + Double(index), updatedAt: v150Now)
    trendState.days[key] = day
}
let setSeries = ReviewTrendRules.series(state: trendState, scale: .months3, metric: .confirmedSets, now: v150Now)
check(setSeries.points.count == 3 && setSeries.points.map(\.value) == [1, 2, 3],
      "three-month trend buckets confirmed sets without zero fill")
let weightSeries = ReviewTrendRules.series(state: trendState, scale: .months3, metric: .weight, now: v150Now)
check(weightSeries.points.count == 3 && weightSeries.points.first?.value == 70,
      "weight trend uses actual measurements only")
var missingState = trendState
missingState.days.removeValue(forKey: monthKey(1))
let missingSeries = ReviewTrendRules.series(state: missingState, scale: .months3, metric: .confirmedSets, now: v150Now)
check(missingSeries.points.count == 2 && !missingSeries.points.contains { $0.value == 0 },
      "missing month is omitted rather than plotted as zero")
let customSeries = ReviewTrendRules.series(state: trendState, scale: .custom(start: v150Now.addingTimeInterval(-20*86400), end: v150Now),
                                           metric: .trainingDays, now: v150Now)
check(customSeries.monthly == false, "short custom range uses daily buckets")

let eventA = ClubInsightEvent(id: "a", date: today, groupID: today + "/training", kind: .training,
    recordedAt: v150Now, previousIDs: [], state: .active, evidenceDigest: String(repeating: "a", count: 64),
    title: "训练", detail: "详情", evidence: "依据", priority: 100, isTodayReminder: false)
let eventB = ClubInsightEvent(id: "b", date: ClubDates.key(yesterday), groupID: ClubDates.key(yesterday) + "/nutrition",
    kind: .nutrition, recordedAt: v150Now.addingTimeInterval(-86400), previousIDs: [], state: .active,
    evidenceDigest: String(repeating: "b", count: 64), title: "饮食", detail: "详情", evidence: "依据",
    priority: 60, isTodayReminder: false)
let sections = ClubInsightTimelineRules.sections([eventB, eventA], now: v150Now)
check(sections.count == 2 && sections[0].title == "今天" && sections[0].events.first?.id == "a",
      "timeline groups today before earlier")
check(ClubInsightTimelineRules.filter([eventA, eventB], kind: .training).map(\.id) == ["a"],
      "training filter includes workout/training family only")
print("Build 111 Phase 0 rules: \(tests) combined checks passed")
''')
Path(sys.argv[1]).write_text(content+'\n\n'+'\n\n'.join(extra),'utf-8')
