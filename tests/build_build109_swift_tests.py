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
trend=(root/'BojiClub/TrendAnalysis.swift').read_text('utf-8')
shift=(root/'BojiClub/PlanShiftViews.swift').read_text('utf-8')
extra=[]
extra.append('enum AIClientError: Error { case message(String) }\n'+block(trend,'enum ClubTrendRules {'))
extra.append(block(trend,'enum PhaseReportRules {'))
extra.append(block(shift,'enum ClubShiftRules {'))
extra.append(r'''
let build109Now = ClubDates.date(fromKey: "2026-10-15")!
let phaseStart = ClubDates.date(fromKey: "2026-09-01")!
func keyOffset(_ offset: Int) -> String {
    ClubDates.key(ClubDates.calendar.date(byAdding: .day, value: offset, to: phaseStart)!)
}
var phaseState = SavedState()
for offset in 0..<28 {
    var day = DayLog()
    if offset < 10 {
        day.meals = [Meal(name: "早餐", category: "早餐", calories: 400, protein: 30, carbs: 40, fat: 10)]
    }
    phaseState.days[keyOffset(offset)] = day
}
func addTraining(_ key: String, session: UUID, reps: Int, confirmed: Bool) {
    let exercise = Exercise(name: "卧推", muscle: "胸",
        sets: [TrainingSet(weight: 20, reps: reps, completed: true)],
        libraryID: "bench", workoutSessionID: session)
    var day = phaseState.days[key] ?? DayLog()
    day.exercises.append(exercise)
    let stamp = confirmed ? build109Now : nil
    day.workoutSessions = (day.workoutSessions ?? []) + [WorkoutSession(id: session, startedAt: build109Now, endedAt: build109Now, savedAt: stamp)]
    phaseState.days[key] = day
}
let confirmedA = UUID(), confirmedB = UUID(), confirmedC = UUID(), unconfirmedD = UUID()
addTraining(keyOffset(0), session: confirmedA, reps: 10, confirmed: true)
addTraining(keyOffset(1), session: confirmedB, reps: 8, confirmed: true)
addTraining(keyOffset(1), session: unconfirmedD, reps: 99, confirmed: false)
addTraining(keyOffset(2), session: confirmedC, reps: 6, confirmed: true)
phaseState.days[keyOffset(0)]!.bodyWeight = BodyWeightEntry(kilograms: 70, updatedAt: build109Now)
phaseState.days[keyOffset(6)]!.bodyWeight = BodyWeightEntry(kilograms: 71, updatedAt: build109Now)
phaseState.days[keyOffset(9)]!.bodyWeight = BodyWeightEntry(kilograms: nil, updatedAt: build109Now)
phaseState.days[keyOffset(27)] = DayLog()
phaseState.days[keyOffset(27)]!.bodyWeight = BodyWeightEntry(kilograms: nil, updatedAt: build109Now)
let report = try PhaseReportRules.make(state: phaseState, start: phaseStart,
    end: ClubDates.calendar.date(byAdding: .day, value: 27, to: phaseStart)!, now: build109Now)
check(report.measuredDays == 2, "deleted weight tombstones never count as measurements")
check(report.daysCovered == 10, "a day with only a deleted weight tombstone is not covered evidence")
check(report.trainingDaysCompleted == 3, "a confirmed session still counts when the same day has an unconfirmed session")
check(report.confirmedSets == 3, "only confirmed-session sets are counted")
check(!PhaseReportRules.isStale(report, state: phaseState), "fresh report matches its own evidence digest")
var changedState = phaseState
changedState.days[keyOffset(6)]!.bodyWeight = BodyWeightEntry(kilograms: 72, updatedAt: build109Now)
check(PhaseReportRules.isStale(report, state: changedState), "changing a source record marks the report stale")

var trendState = SavedState()
let custom = UUID(uuidString: "ABCDEF01-2345-6789-ABCD-EF0123456789")!
for offset in 0..<3 {
    let key = keyOffset(offset + 12)
    let session = UUID()
    let exercise = Exercise(name: "自定义推举", muscle: "胸",
        sets: [TrainingSet(weight: 30, reps: 10, completed: true)],
        workoutSessionID: session, customExerciseID: custom, customUnit: "次")
    var day = DayLog(); day.exercises = [exercise]
    day.workoutSessions = [WorkoutSession(id: session, startedAt: build109Now, endedAt: build109Now, savedAt: build109Now)]
    trendState.days[key] = day
}
let customTrends = ClubTrendRules.trends(state: trendState, through: build109Now)
check(customTrends.count == 1 && customTrends[0].identity == "custom/" + custom.uuidString.lowercased(),
      "custom exercise identities are canonical lowercase across summary and trend")
check(customTrends[0].sampleCount == 3, "custom UUID containing A-F still matches across sessions")

let sameDayTrends = ClubTrendRules.trends(state: phaseState, through: build109Now)
let bench = sameDayTrends.first { $0.identity == "library/bench" && $0.weight == 20 }
check(bench?.sampleCount == 3, "a confirmed earlier session is not hidden by a later unconfirmed session")

var planDraft = ManualPlanDraft(); planDraft.start = "2026-10-15"
planDraft.title = "Build 109"; planDraft.planDescription = "八周增肌"; planDraft.planIntent = "稳定训练"
planDraft.days[0].movements = [ManualPlanMovement(name: "哑铃卧推", muscle: "胸", query: "dumbbell bench press", libraryID: "sample", count: 3, weight: 10, reps: 12)]
planDraft.applyPattern(.on2off1, weekdays: [], customCycle: [])
planDraft.planPatternLabel = "练二休一 · 28 天"
check(planDraft.placeholderCount > 0, "cycle pattern creates explicit unconfigured days")
let restIndex = planDraft.activeDays.firstIndex(where: \.isUnconfiguredPlaceholder)!
planDraft.setRestDay(at: restIndex)
check(!planDraft.days[restIndex].isUnconfiguredPlaceholder && planDraft.days[restIndex].movements.isEmpty
      && planDraft.days[restIndex].title.isEmpty && planDraft.days[restIndex].placeholder == nil,
      "set rest day clears placeholder, title and movements in one operation")
for index in 0..<planDraft.duration where planDraft.days[index].isUnconfiguredPlaceholder {
    planDraft.days[index].title = ""
}
check(planDraft.validation(now: build109Now) == nil, "cleared title also becomes a valid rest day (no guessing required)")
let planResult = try planDraft.result(now: build109Now)
check(planResult.plan_description == "八周增肌" && planResult.plan_intent == "稳定训练"
      && planResult.plan_pattern == "练二休一 · 28 天", "manual plan context travels with the adoption result")
var historyState = SavedState()
ClubHistoryRules.recordPlan(days: &historyState.days, previous: SavedState().days,
    operationID: "manual-plan-build109", result: planResult, start: build109Now, source: "manual",
    requestedProfile: historyState.profile, adoptedProfile: historyState.profile,
    nutrition: NutritionTarget.estimate(historyState.profile), scope: ["2026-10-15"], now: build109Now)
let version = historyState.days.values.compactMap { $0.planVersions }.flatMap { $0 }.first!
check(version.planDescription == "八周增肌" && version.planIntent == "稳定训练"
      && version.planPattern == "练二休一 · 28 天" && version.notes?.contains { $0.contains("计划描述") } == true,
      "plan version retains description, intent, pattern and notes")

let monday = TrainingCycle.week(anchoredAt: "2026-10-12")!
check(ClubShiftRules.shiftWeekAnchor(sourceCycle: monday, target: "2026-10-20") == "2026-10-19",
      "cross-week shift anchors the destination to the following week, not the source interval")
let destination = TrainingCycle.week(anchoredAt: "2026-10-19")!
check(destination.dates.contains("2026-10-20") && destination.end <= "2026-10-25",
      "destination cycle is a legal seven-day interval containing the moved date")
let sameWeek = TrainingCycle.week(anchoredAt: "2026-10-12")!
check(ClubShiftRules.shiftWeekAnchor(sourceCycle: sameWeek, target: "2026-10-15") == "2026-10-12",
      "same-week shifts keep the original cycle anchor")

func shiftDay(_ cycleStart: String, movingKey: String) -> [String: DayLog] {
    var cycle = TrainingCycle.week(anchoredAt: cycleStart)!
    cycle.plannedDates = [movingKey]
    var days: [String: DayLog] = [:]
    for key in cycle.dates {
        days[key] = DayLog(exercises: key == movingKey ? [Exercise(name: "卧推", muscle: "胸", sets: [TrainingSet(reps: 10, completed: false)], libraryID: "bench")] : [], planCycle: cycle)
    }
    return days
}
var sameWeekDays = shiftDay("2026-10-12", movingKey: "2026-10-16")
let sameWeekPlan = ClubShiftRules.destinations(moves: [("2026-10-16", "2026-10-17")], days: sameWeekDays,
    cycles: TrainingCycle.available(days: sameWeekDays, now: build109Now))
check(sameWeekPlan.cycles["2026-10-17"]?.start == "2026-10-12", "same-week destination keeps the source cycle")
var crossWeekDays = shiftDay("2026-10-12", movingKey: "2026-10-17")
let crossWeekPlan = ClubShiftRules.destinations(moves: [("2026-10-17", "2026-10-19")], days: crossWeekDays,
    cycles: TrainingCycle.available(days: crossWeekDays, now: build109Now))
check(crossWeekPlan.cycles["2026-10-19"]?.start == "2026-10-19", "cross-week destination gets a new aligned cycle")
check(crossWeekPlan.cycles["2026-10-19"]?.dates.contains("2026-10-19") == true, "new cycle covers the moved date")
check(crossWeekPlan.sourceStarts["2026-10-19"] == "2026-10-12", "source cycle is retained for provenance")
var crossMonthDays = shiftDay("2026-10-26", movingKey: "2026-10-31")
let crossMonthPlan = ClubShiftRules.destinations(moves: [("2026-10-31", "2026-11-02")], days: crossMonthDays,
    cycles: TrainingCycle.available(days: crossMonthDays, now: build109Now))
check(crossMonthPlan.cycles["2026-11-02"]?.start == "2026-11-02", "cross-month destination gets a legal new cycle")
var destinationDays = shiftDay("2026-10-12", movingKey: "2026-10-16")
var destinationCycle = TrainingCycle.week(anchoredAt: "2026-10-19")!
destinationCycle.plannedDates = ["2026-10-20"]
for key in destinationCycle.dates { destinationDays[key] = DayLog(exercises: [], planCycle: destinationCycle) }
let plannedOne = ClubShiftRules.destinations(moves: [("2026-10-16", "2026-10-20")], days: destinationDays,
    cycles: TrainingCycle.available(days: destinationDays, now: build109Now))
check(plannedOne.cycles["2026-10-20"]?.start == "2026-10-19", "cross-plan destination joins the target plan cycle")
let chain = ClubShiftRules.destinations(moves: [("2026-10-16", "2026-10-17"), ("2026-10-17", "2026-10-19")],
    days: sameWeekDays, cycles: TrainingCycle.available(days: sameWeekDays, now: build109Now))
check(chain.cycles["2026-10-17"]?.start == "2026-10-12" && chain.cycles["2026-10-19"]?.start == "2026-10-19",
      "chained moves assign each destination independently")
print("Build 109 data/evidence fixes: \(tests) combined checks passed")
''')
Path(sys.argv[1]).write_text(content+'\n\n'+'\n\n'.join(extra),'utf-8')
