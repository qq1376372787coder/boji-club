"""Build native tests from production facts/models. Run on macOS with Swift.
Unrelated media/health/review payloads are Codable fixtures, not their real SDKs.
"""
from pathlib import Path
import sys
root=Path(__file__).resolve().parents[1]/'BojiClub'
def read(name):return (root/name).read_text('utf-8')
def block(source,marker):
    start=source.index(marker);i=source.index('{',start);depth=1;j=i+1
    while depth:
        if source[j]=='{':depth+=1
        elif source[j]=='}':depth-=1
        j+=1
    return source[start:j]
models=read('Models.swift');daily=read('DailyExperience.swift')
parts=['import Foundation\nimport CryptoKit',block(models,'enum ClubDates {'),block(read('RecordReliability.swift'),'final class ClubDateFormatterCache:')]
for marker in ['struct TrainingSet:','struct Exercise:','struct Meal:','struct WorkoutBaselineSet:','struct WorkoutExecutionBaseline:','struct WorkoutPauseInterval:','struct WorkoutSession:','struct DayLog:','struct MemberProfile:','struct NutritionTarget:','struct PostDraft:','struct CustomExercise:','struct SavedState:']:
    parts.append(block(models,marker))
for marker in ['enum BodyMeasurementIdentity {','struct BodyWeightEntry:','struct BodyWeightPoint:','enum BodyWeightHistory {','struct MealCompletion:','enum BodyProfileAssessment {','enum ExperienceDigest {']:
    parts.append(block(daily,marker))
parts.append('enum RecordLimits { '+daily[daily.index('static let maximumWeight'):daily.index('static func valid(_ meal:')].strip()+' }')
parts.append(read('ManualPlan.swift').split('enum ManualPlanDraftStorage {')[0])
parts.append('''
struct FoodComponent: Codable {}
struct HealthDay: Codable {}
struct WeeklyReview: Codable { var result: String? = nil }
enum ExerciseNames { static func display(_ name:String,id:String?,query:String?)->String { name } }
''')
ai=read('AIService.swift')
for marker in ['struct AIPlanSet:','struct AIPlanExercise:','struct AIPlanSession:']:
    parts.append(block(ai,marker))
parts.append(block(ai,'extension AIPlanExercise {'))
parts.append('struct FixtureExplanation { var version = 1 }\nstruct AIResult { var kind:String;var notes:[String] = [];var title:String? = nil;var sessions:[AIPlanSession]?;var plan_days:Int? = nil;var explanation:FixtureExplanation? = nil;var plan_description:String? = nil;var plan_intent:String? = nil;var plan_pattern:String? = nil }')
trend=read('TrendAnalysis.swift')
parts.append(block(trend,'enum ClubTrendThresholds {'))
parts.append(block(trend,'enum ClubExerciseIdentity {'))
parts.append(block(trend,'enum TrainingEvidence {'))
parts.append(block(trend,'struct ClubTrendPoint:'))
parts.append(block(trend,'struct ClubTrendResult:'))
parts.append(block(trend,'struct PhaseReport:'))
parts.append(block(read('PlanShiftViews.swift'),'struct PlanShiftRecord:'))
parts.append(block(daily,'struct TrainingCycle:'))
parts.append('enum WorkoutEditing { '+block(models,'static func isProtected(')+' }')
parts.append('enum PlanAdoptionRules { '+block(read('JourneyRules.swift'),'static func isProtected(')+' }')
parts.append(read('ClubHistory.swift'))
parts.append(read('ClubWorkoutSummary.swift'))
parts.append(read('ClubInsightRules.swift'))
parts.append(read('ClubInsightLedger.swift'))
parts.append(r'''
var tests = 0
func check(_ value: @autoclosure () -> Bool, _ name: String) {
    precondition(value(), name); tests += 1
}
let now = ClubDates.date(fromKey: "2026-10-15")!
let today = ClubDates.key(now)
let yesterday = ClubDates.calendar.date(byAdding: .day, value: -1, to: now)!
let tomorrow = ClubDates.calendar.date(byAdding: .day, value: 1, to: now)!
func facts(_ state: SavedState, date: Date = now) -> [ClubInsightFact] {
    ClubInsightRules.facts(state: state, date: date, now: now)
}
var state = SavedState()
// This nutrition comparison fixture assumes the member has confirmed the
// legacy profile values. New accounts intentionally start with unknown facts.
state.profile.factState = nil
check(facts(state).isEmpty, "profile weight is not a measured weight")
var meal = Meal(name: "鸡蛋", category: "早餐", calories: 150, protein: 12, carbs: 1, fat: 10)
var day = DayLog(); day.meals = [meal]; state.days[today] = day
check(facts(state).first!.detail.contains("补齐漏记的餐次"), "single meal must not infer a daily shortfall")
day.mealCompletion = MealCompletion(signature: MealCompletion.signature(day.meals)); state.days[today] = day
check(facts(state).first!.detail.contains("低于参考下限"), "explicit complete records can compare a reference")
day.meals[0].nutritionKnown = false
day.mealCompletion = MealCompletion(signature: MealCompletion.signature(day.meals)); state.days[today] = day
check(facts(state).first!.detail.contains("没有可汇总的营养估算"), "unknown nutrition blocks daily judgement even after confirmation")
state.days[ClubDates.key(tomorrow)] = day
check(facts(state,date:tomorrow).isEmpty, "future records never produce insights")
day.meals[0].nutritionKnown = true
day.mealCompletion = MealCompletion(signature: MealCompletion.signature(day.meals))
state.days[ClubDates.key(yesterday)] = day
check(facts(state,date:yesterday).first!.detail.contains("缺少当时"), "historical target cannot be invented")
day.nutritionTarget = NutritionTarget.estimate(state.profile)
day.nutritionTarget!.proteinMin = 5
state.days[ClubDates.key(yesterday)] = day
check(!facts(state,date:yesterday).first!.detail.contains("低于参考下限"), "historical target wins over today's target")
var timed = DayLog()
timed.exercises = [Exercise(name:"平板支撑",muscle:"核心",sets:[TrainingSet(reps:0,completed:true,durationSeconds:60)])]
state.days[today] = timed
check(facts(state).first!.title == "训练记录待确认", "completed set is not a confirmed workout")
timed.workoutSavedAt = now; state.days[today] = timed
check(facts(state).first(where: { $0.kind == .training })!.detail.contains("60 秒"), "timed training is not zero training")
check(facts(state).first(where: { $0.kind == .training })!.title == "训练已保存", "confirmed workout becomes completion feedback")
let first = facts(state)
check(first == facts(state), "re-reading does not manufacture messages or timestamps")
state.days[today] = DayLog()
check(facts(state).isEmpty, "deleted training retracts the current fact")
var rest = DayLog(); rest.planCycle = TrainingCycle(start:today,plannedDates:[])
state.days[today] = rest
check(facts(state).first!.title == "今天按计划休息", "rest days are not missed workouts")
rest.bodyWeight = BodyWeightEntry(kilograms:70,updatedAt:now); state.days[today] = rest
check(facts(state).filter { $0.kind == .body }.count == 1, "actual measured point is visible")
check(!facts(state).contains { $0.detail.contains("平台期") }, "one measurement cannot establish a plateau")
state.days[today]!.bodyWeight = nil
check(!facts(state).contains { $0.kind == .body }, "deleted measurement removes fact")
check(facts(SavedState()).isEmpty, "a different empty account inherits no facts")
var special = SavedState(); special.profile.nutritionContext = "孕期或哺乳期"
special.days[today] = day; special.days[today]!.nutritionTarget = nil
check(facts(special).first!.detail.contains("个别评估"), "special context does not receive generic deficits")
print("Club AI foundation: \(tests) behavioral checks passed")
''')
Path(sys.argv[1]).write_text('\n\n'.join(parts),'utf-8')
