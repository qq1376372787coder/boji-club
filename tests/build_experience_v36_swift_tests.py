"""Production Foundation rules; execute generated file with Swift on Mac."""
from pathlib import Path
import runpy,sys
out=Path(sys.argv[1]);runpy.run_path(str(Path(__file__).with_name('build_experience_v35_swift_tests.py')))
root=Path(__file__).resolve().parents[1]
s=out.read_text('utf-8')
weekly=(root/'BojiClub/WeeklyReview.swift').read_text('utf-8')
definitions=weekly[weekly.index('struct WeeklySurvey:'):weekly.index('extension WeeklyReview {')]
s=s.replace('struct WeeklyReview: Codable { var id = UUID() }',definitions)
s+=r'''
do {
    let end = ClubDates.calendar.date(byAdding: .day, value: -1, to: now)!
    let start = ClubDates.calendar.date(byAdding: .day, value: -6, to: end)!
    var cycle = TrainingCycle(start: ClubDates.key(start), plannedDates: [])
    cycle.plannedDates = Array(cycle.dates.prefix(3))
    check(cycle.dates.count == 7 && cycle.end == ClubDates.key(end), "cycle includes seven dates including rest days")
    check(!cycle.ended(now: end) && cycle.ended(now: now), "review waits until the last calendar day has ended")
    var days: [String: DayLog] = [:]
    let meal = Meal(name: "米饭鸡蛋", category: "午餐", calories: 500, protein: 20, carbs: 60, fat: 15)
    for key in cycle.dates.prefix(3) {
        var log = DayLog(meals: [meal]); log.mealCompletion = MealCompletion(signature: MealCompletion.signature(log.meals))
        days[key] = log
    }
    for key in cycle.dates.prefix(2) { days[key]?.exercises = [Exercise(name: "平板支撑", muscle: "核心", sets: [TrainingSet(reps: 0, completed: true, durationSeconds: 30)])]; days[key]?.workoutSavedAt = now }
    check(WeeklyReadiness(cycle: cycle, days: days, now: now).combinedReady, "timed training and three confirmed food days unlock combined review")
    var changed = days; changed[cycle.dates[0]]?.meals[0].calories += 1
    check(changed[cycle.dates[0]]?.mealsComplete == false, "editing meal values invalidates daily completion")
    check(!WeeklyReadiness(cycle: cycle, days: changed, now: now).combinedReady, "edited meal day no longer unlocks combined review")
    check(WeeklyReadiness(cycle: cycle, days: changed, now: now).trainingReady, "food gap still allows training-only review")
    var media = days; media[cycle.dates[0]]?.meals[0].photoRemoteID = UUID().uuidString + ".jpg"
    check(media[cycle.dates[0]]?.mealsComplete == true, "photo sync does not invalidate meal content confirmation")
    var unknown = days; unknown[cycle.dates[0]]?.meals[0].nutritionKnown = false
    let modifiedMeals = unknown[cycle.dates[0]]!.meals
    unknown[cycle.dates[0]]?.mealCompletion = MealCompletion(signature: MealCompletion.signature(modifiedMeals))
    check(!WeeklyReadiness(cycle: cycle, days: unknown, now: now).combinedReady, "confirmed but unknown nutrition is not complete evidence")
    var unsaved = days; unsaved[cycle.dates[0]]?.workoutSavedAt = nil
    check(!WeeklyReadiness(cycle: cycle, days: unsaved, now: now).trainingReady, "checked but unsaved training does not unlock review")
    var once = cycle; once.plannedDates = [cycle.dates[1]]
    check(WeeklyReadiness(cycle: once, days: unsaved, now: now).trainingReady, "one-day original plan has a one-day threshold")
    let markerDates = TrainingCycle.stamp(days: &days, start: start, plannedDates: cycle.plannedDates)
    check(markerDates.count == 7 && days[cycle.end]?.planCycle?.start == cycle.start, "plan cycle is stamped onto rest days too")
    check(days[cycle.dates[0]]?.meals.count == 1, "cycle stamping preserves food")
    let legacyJSON = try JSONSerialization.data(withJSONObject: ["exercises":[],"meals":[]])
    let legacyDay = try JSONDecoder().decode(DayLog.self, from: legacyJSON)
    check(legacyDay.planCycle == nil && !legacyDay.mealsComplete, "old day records decode without fabricated completeness")
    let survey = WeeklySurvey()
    check(survey.fatigue.isEmpty && survey.pain.isEmpty && survey.difficulty.isEmpty && survey.diet.isEmpty, "new questionnaire starts unanswered")
    var profile = MemberProfile(); profile.gender = "男"; profile.height = 175; profile.weight = 50; profile.goal = "减脂瘦身"
    check(BodyProfileAssessment.category(profile) == "偏轻", "Chinese adult BMI low boundary")
    check(NutritionTarget.estimate(profile).strategy != "温和热量缺口", "underweight profile is not prescribed a deficit")
    profile.weight = 80
    check(BodyProfileAssessment.category(profile) == "超重范围", "Chinese adult BMI overweight classification")
    let deficit = NutritionTarget.estimate(profile)
    check(deficit.strategy == "温和热量缺口" && deficit.caloriesMax < (deficit.maintenanceMax ?? 0), "fat-loss goal has explained moderate deficit")
    profile.weight = 65; profile.goal = "增肌塑形"
    check(NutritionTarget.estimate(profile).strategy == "小幅热量盈余", "muscle-gain goal with suitable BMI has small surplus")
    let sedentary = NutritionTarget.estimate(profile); profile.dailyActivity = "经常站立走动"
    check(NutritionTarget.estimate(profile).caloriesMin > sedentary.caloriesMin, "daily activity changes estimated maintenance")
    profile.age = 16
    check(BodyProfileAssessment.bmi(profile) == nil && NutritionTarget.estimate(profile).generalGuidanceOnly == true, "adolescent avoids adult BMI and numeric prescriptions")
    profile.age = 28; profile.nutritionContext = "孕期或哺乳期"
    check(NutritionTarget.estimate(profile).generalGuidanceOnly == true, "special nutrition context requires individual assessment")
    let before = ExperienceDigest.of(days)
    check(before == ExperienceDigest.of(days), "input fingerprint is deterministic")
    let store = AppStore();store.state.days[today] = DayLog(meals: [meal]);store.allowPersistence = false
    check(!store.confirmMeals(on: now, complete: true), "failed confirmation write is reported")
    check(!store.log(for: now).mealsComplete, "failed confirmation write rolls back")
    let planner = AppStore()
    let first = AIPlanSession(date: today, label: "本周期首日", exercises: [AIPlanExercise(name: "深蹲", muscle: "腿", sets: [AIPlanSet(weight: 20, reps: 10)], library_query: nil)])
    let proposed = AIResult(kind: "plan", notes: [], sessions: [first])
    check(planner.applyAIPlan(proposed, jobID: "cycle-today", cycleStart: now), "new cycle can start today before training begins")
    check(planner.state.days.count == 7, "applying plan atomically registers its rest days")
    let applied = planner.state
    check(planner.applyAIPlan(proposed, jobID: "cycle-today", cycleStart: now), "same cycle job remains idempotent")
    check(try CloudMerge.same(applied, planner.state), "reapplying cycle preserves state")
    planner.state.days[today]?.workoutStartedAt = now
    check(!planner.applyAIPlan(proposed, jobID: "overwrite-started", replaceUnstarted: true, cycleStart: now), "started workout cannot be replaced before its first checked set")
    let failure = AppStore(); failure.allowPersistence = false
    check(!failure.applyAIPlan(proposed, jobID: "failed-cycle", cycleStart: now), "failed cycle persistence is reported")
    check(failure.state.days.isEmpty && !failure.hasAppliedAIJob("failed-cycle"), "failed cycle leaves no rest markers or consumed job")
    let source = AppStore()
    let sourceFirst = ClubDates.calendar.date(byAdding: .day, value: -6, to: end)!
    source.state.days[ClubDates.key(sourceFirst)] = DayLog(exercises: [Exercise(name: "平板支撑", muscle: "核心", sets: [TrainingSet(reps: 0, completed: true, durationSeconds: 30)])])
    let copied = source.continuationSessions(starting: sourceFirst, ending: end, nextStart: now)
    check(copied.first?.date == today, "copying previous cycle includes today's unstarted date")
    check(copied.first?.exercises.first?.sets.first?.durationSeconds == 30, "copy preserves timed measurement units")
    let shifted = source.continuationSessions(starting: sourceFirst, ending: end, nextStart: tomorrow)
    check(shifted.first?.date == ClubDates.key(tomorrow), "explicit destination start shifts copied dates together")
    print("PASS v36 cycles, readiness, meal proof, BMI and nutrition context")
}
'''
out.write_text(s,'utf-8')
print('v36 Foundation harness generated; not executed on this Windows host')
