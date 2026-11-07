from pathlib import Path
import runpy,sys
out=Path(sys.argv[1])
runpy.run_path(str(Path(__file__).with_name('build_experience_v44_swift_tests.py')))
s=out.read_text('utf-8')
s+=r'''
do {
    let beginning = checks
    let empty = DayLog()
    check(DailyAnalysisReadiness.warnings(empty).count == 1, "rest day is not criticized for lacking training")
    let planned = Exercise(name:"深蹲",muscle:"腿",sets:[TrainingSet(weight:0,reps:10)])
    check(DailyAnalysisReadiness.warnings(DayLog(exercises:[planned])).contains(where:{$0.contains("计划")}), "planned training cannot become completed evidence")
    var finished = planned
    finished.sets[0].completed = true
    var day = DayLog(exercises:[finished])
    check(DailyAnalysisReadiness.warnings(day).contains(where:{$0.contains("保存")}), "unsaved training gets a completion reminder")
    day.workoutSavedAt = Date()
    let meal = Meal(name:"鸡蛋",category:"早餐",calories:150,protein:13,carbs:1,fat:10)
    day.meals = [meal]
    check(DailyAnalysisReadiness.warnings(day).contains(where:{$0.contains("1 餐")}), "unconfirmed meal coverage is explained")
    day.mealCompletion = MealCompletion(signature:MealCompletion.signature(day.meals))
    check(DailyAnalysisReadiness.warnings(day).isEmpty, "one confirmed complete-day meal does not trigger arbitrary three-meal rules")
    day.exercises[0].sets.append(TrainingSet(weight:0,reps:10))
    check(DailyAnalysisReadiness.warnings(day).contains(where:{$0.contains("部分组数")}), "saved partial training remains eligible with context")
    day.exercises = []
    check(DailyAnalysisReadiness.warnings(day).isEmpty, "complete food-only rest day needs no warning")
    day.meals[0].nutritionKnown = false
    day.mealCompletion = MealCompletion(signature:MealCompletion.signature(day.meals))
    check(DailyAnalysisReadiness.warnings(day).contains(where:{$0.contains("营养数据未知")}), "unknown nutrition cannot masquerade as zero calories")
    let suite = "boji-v46-tests-" + UUID().uuidString
    let defaults = UserDefaults(suiteName:suite)!
    defer { defaults.removePersistentDomain(forName:suite) }
    check(!CloudAnalysisConsent.allowed(accountID:10, defaults: defaults), "cloud analysis remains disabled until this account opts in")
    check(!CloudAnalysisConsent.hasDecision(accountID:10,defaults:defaults), "default is not an explicit override")
    CloudAnalysisConsent.set(true,accountID:10,defaults:defaults)
    check(CloudAnalysisConsent.allowed(accountID:10,defaults:defaults), "explicit consent is stored for the account")
    check(!CloudAnalysisConsent.allowed(accountID:11, defaults: defaults), "cloud analysis remains disabled until this account opts in")
    CloudAnalysisConsent.set(false,accountID:10,defaults:defaults)
    check(!CloudAnalysisConsent.allowed(accountID:10,defaults:defaults), "explicit withdrawal overrides a prior grant")
    check(CloudAnalysisConsent.hasDecision(accountID:10,defaults:defaults), "withdrawal remains explicit across login")
    CloudAnalysisConsent.set(true,accountID:0,defaults:defaults)
    check(!CloudAnalysisConsent.allowed(accountID:nil,defaults:defaults), "signed-out context never grants data sharing")
    check(!CloudAnalysisConsent.allowed(accountID:0,defaults:defaults), "invalid account does not gain consent")
    print("PASS \(checks-beginning) additional v46 production readiness checks")
}
'''
out.write_text(s,'utf-8')
print('v46 production readiness harness generated; execute on Mac to confirm')
