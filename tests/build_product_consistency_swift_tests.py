"""Run real model, aggregation, editor and CloudMerge rules without iOS SDK UI.
Build: python3 tests/build_product_consistency_swift_tests.py /tmp/product.swift
Run: xcrun swift -swift-version 5 /tmp/product.swift
The reused phase1 fixture stubs persistence/SDK services, not these rules.
"""
from pathlib import Path
import subprocess, sys, tempfile
root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory() as tmp:
    base = Path(tmp) / 'base.swift'
    subprocess.run([sys.executable, str(root/'tests/build_phase1_swift_tests.py'), str(base)], check=True, stdout=subprocess.DEVNULL)
    content = base.read_text('utf-8')
checks = r'''
var productChecks = 0
func productCheck(_ ok: Bool, _ name: String) {
    guard ok else { fatalError("PRODUCT REGRESSION: \(name)") }
    productChecks += 1; print("PRODUCT PASS \(name)")
}
// First-day profile saves must not overlap an inout dictionary write with
// another read of AppStore.state (Swift traps instead of reporting an error).
do {
    let owner = AppStore()
    var profile = owner.state.profile; profile.weight = 72.4
    let today = ClubDates.key(Date())
    productCheck(owner.saveProfile(profile, initialWeightDate: Date()), "first measured profile saves without an access conflict")
    productCheck(owner.state.days[today]?.bodyWeight?.kilograms == 72.4, "first measurement is retained")
    profile.weight = 73
    productCheck(owner.saveProfile(profile, initialWeightDate: Date()), "same-day profile update saves without an access conflict")
    productCheck(owner.state.days[today]?.bodyWeight?.kilograms == 72.4, "profile retry preserves the actual measurement")
    productCheck(owner.state.days[today]?.nutritionTarget == owner.state.nutritionTarget, "today uses the newly calculated target")
    owner.allowPersistence = false
    let before = owner.state
    profile.weight = 74
    let saved = owner.saveProfile(profile)
    let rolledBack = try CloudMerge.same(before, owner.state)
    productCheck(!saved && rolledBack, "failed profile write rolls back both target and record")
}
let chinese = ReportTextLayout.blocks("2、保留实际记录\n3.14 kg 是普通正文")
productCheck(chinese.first?.marker == "2、" && chinese.first?.text == "保留实际记录", "Chinese list without a space is parsed")
productCheck(chinese.last?.kind == .paragraph && chinese.last?.text == "3.14 kg 是普通正文", "decimal at line start remains prose")
let productNow = ClubDates.date(fromKey: "2026-10-18")!.addingTimeInterval(12 * 3600)
let productDate = ClubDates.key(productNow)
let productSaved = UUID(), productPending = UUID()
func productExercise(_ session: UUID?, seconds: Int? = nil, weight: Double = 0, reps: Int = 0, done: Bool = true) -> Exercise {
    Exercise(name: "动作", muscle: "核心", sets: [TrainingSet(weight: weight, reps: reps, completed: done, durationSeconds: seconds)],
             libraryID: seconds == nil ? "strength" : "plank", workoutSessionID: session)
}
var productDay = DayLog()
productDay.workoutSessions = [
    WorkoutSession(id: productSaved, startedAt: productNow.addingTimeInterval(-1200), endedAt: productNow.addingTimeInterval(-600), savedAt: productNow),
    WorkoutSession(id: productPending, startedAt: productNow)]
productDay.activeWorkoutSessionID = productPending
productDay.exercises = [productExercise(productSaved, weight: 20, reps: 10), productExercise(productPending, seconds: 600)]
func productCheckTraining(_ day: DayLog, sets: Int, seconds: Int, volume: Double, days: Int, label: String) {
    let summary = ReviewMetrics(logs: [day])
    var state = SavedState(); state.days[productDate] = day
    func value(_ metric: ReviewTrendMetric) -> Double {
        ReviewTrendRules.series(state: state, scale: .custom(start: productNow, end: productNow), metric: metric, now: productNow).points.reduce(0) { $0 + $1.value }
    }
    productCheck(summary.confirmedSets == sets && day.confirmedCompletedSets == sets && TrainingEvidence.confirmedSetCount(day: day) == sets && value(.confirmedSets) == Double(sets), label + " set count agrees")
    productCheck(summary.confirmedTimedSeconds == seconds && value(.timedMinutes) == Double(seconds)/60, label + " timing agrees")
    productCheck(summary.confirmedVolume == volume && value(.volume) == volume, label + " volume agrees")
    productCheck(summary.confirmedTrainingDays == days && value(.trainingDays) == Double(days), label + " confirmed days agree")
}
productCheckTraining(productDay, sets: 1, seconds: 0, volume: 200, days: 1, label: "saved strength + pending timed")
productCheck(ReviewMetrics(logs: [productDay]).confirmedElapsedSeconds == 600, "pending session excluded from elapsed duration")
productCheck(productDay.completedSets == 2 && productDay.timedSeconds == 600 && productDay.hasUnconfirmedTraining, "live progress is preserved separately")
var productState = SavedState(); productState.days[productDate] = productDay
let productFact = ClubInsightRules.facts(state: productState, date: productNow, now: productNow).first { $0.kind == .training }!
productCheck(!productFact.detail.contains("600 秒"), "saved insight does not include pending timed performance")
productDay.workoutSessions![1].savedAt = productNow
productDay.workoutSessions![1].endedAt = productNow.addingTimeInterval(300)
productCheckTraining(productDay, sets: 2, seconds: 600, volume: 200, days: 1, label: "both saved")
productDay.workoutSessions![1].savedAt = nil
productCheckTraining(productDay, sets: 1, seconds: 0, volume: 200, days: 1, label: "confirmation revoked")
productDay.workoutSessions![0].savedAt = nil
productCheckTraining(productDay, sets: 0, seconds: 0, volume: 0, days: 0, label: "all pending")
var productLegacy = DayLog()
productLegacy.exercises = [productExercise(nil, seconds: 90)]
productCheckTraining(productLegacy, sets: 0, seconds: 0, volume: 0, days: 0, label: "legacy pending")
productLegacy.workoutSavedAt = productNow
productCheckTraining(productLegacy, sets: 1, seconds: 90, volume: 0, days: 1, label: "legacy saved")
let productRoundTrip = try JSONDecoder().decode(DayLog.self, from: JSONEncoder().encode(productLegacy))
productCheck(productRoundTrip.confirmedTraining.timedSeconds == 90, "old record roundtrip retains confirmed facts without new stored fields")
var productInvalid = productLegacy
productInvalid.exercises = [productExercise(nil, seconds: 0)]
productCheckTraining(productInvalid, sets: 0, seconds: 0, volume: 0, days: 0, label: "invalid completed timed set")
for (label, entry, expected) in [
    ("waist only", BodyWeightEntry(kilograms: nil, updatedAt: productNow, waistCircumferenceCM: 80), 0),
    ("fat only", BodyWeightEntry(kilograms: nil, updatedAt: productNow, bodyFatPercentage: 20), 0),
    ("weight only", BodyWeightEntry(kilograms: 70, updatedAt: productNow), 1),
    ("mixed", BodyWeightEntry(kilograms: 70, updatedAt: productNow, bodyFatPercentage: 20, waistCircumferenceCM: 80), 1),
    ("deleted", BodyWeightEntry(kilograms: nil, updatedAt: productNow), 0),
    ("invalid weight", BodyWeightEntry(kilograms: 0, updatedAt: productNow), 0)] {
    var day = DayLog(); day.bodyWeight = entry
    var state = SavedState(); state.days[productDate] = day
    let summary = ReviewMetrics(logs: [day])
    let count = ReviewTrendRules.series(state: state, scale: .custom(start: productNow, end: productNow), metric: .measurements, now: productNow).points.reduce(0) { $0 + $1.value }
    let history = BodyWeightHistory.points(days: state.days, through: productNow)
    productCheck(summary.weightMeasurements == expected && count == Double(expected) && history.count == expected, label + " measurement count agrees across summary/trend/history")
}
productCheck(BodyWeightEntry(kilograms: nil, updatedAt: productNow, waistCircumferenceCM: 80).hasMeasurement, "waist remains an actual body measurement")
func productMeal(_ calories: Double) -> Meal {
    Meal(name: "餐食", category: "午餐", calories: calories, protein: calories/10, carbs: calories/20, fat: calories/25,
         components: [FoodComponent(id: "part-1", name: "食物", amount: 1, unit: "份", calories: calories, protein: calories/10, carbs: calories/20, fat: calories/25, basis: "user", details: [])], consumedFraction: 1, nutritionKnown: true)
}
func productNutritionEqual(_ lhs: Meal, _ rhs: Meal) -> Bool {
    lhs.components == rhs.components && lhs.consumedFraction == rhs.consumedFraction && lhs.calories == rhs.calories && lhs.protein == rhs.protein && lhs.carbs == rhs.carbs && lhs.fat == rhs.fat && lhs.nutritionKnown == rhs.nutritionKnown
}
func productCloudMeal(_ local: Meal, _ remote: Meal, _ baseline: Meal) throws -> Meal {
    func cloud(_ meal: Meal) -> CloudState {
        var state = SavedState(); state.days[productDate] = DayLog(meals: [meal]); return CloudState(state)
    }
    return try CloudMerge.merge(local: cloud(local), remote: cloud(remote), base: cloud(baseline)).days[productDate]!.meals[0]
}
let productBase = productMeal(100)
var productFraction = productBase
productFraction.consumedFraction = 0.5; productFraction.calories = 50; productFraction.protein = 5; productFraction.carbs = 2.5; productFraction.fat = 2
var productComponents = productMeal(200); productComponents.id = productBase.id
for (label, edited, current, expected) in [
    ("fraction vs components", productFraction, productComponents, productFraction),
    ("components vs fraction", productComponents, productFraction, productComponents)] {
    let editor = MealNutritionMerge.merged(edited: edited, base: productBase, current: current)
    let cloud = try productCloudMeal(edited, current, productBase)
    productCheck(productNutritionEqual(editor, expected) && productNutritionEqual(cloud, expected), label + " editor and cloud choose the same coherent observation")
    let calculated = FoodComponent.total(\.calories, components: cloud.components ?? [], fraction: cloud.consumedFraction ?? 1, fallback: cloud.calories)
    productCheck(calculated == cloud.calories, label + " total matches components times fraction")
}
var productRename = productBase; productRename.name = "修改餐名"
let productRenamedEditor = MealNutritionMerge.merged(edited: productRename, base: productBase, current: productComponents)
let productRenamedCloud = try productCloudMeal(productRename, productComponents, productBase)
productCheck(productRenamedEditor.name == "修改餐名" && productRenamedCloud.name == "修改餐名" && productNutritionEqual(productRenamedEditor, productComponents) && productNutritionEqual(productRenamedCloud, productComponents), "metadata-only edit preserves new remote structure and totals")
var productUnknown = productBase; productUnknown.components = nil; productUnknown.consumedFraction = nil; productUnknown.nutritionKnown = false
let productUnknownCloud = try productCloudMeal(productUnknown, productComponents, productBase)
productCheck(!productUnknownCloud.hasNutrition && productUnknownCloud.components == nil && productUnknownCloud.consumedFraction == nil, "unknown nutrition remains part of the same observation")
var productScalarBase = productBase; productScalarBase.components = nil; productScalarBase.consumedFraction = nil
var productScalarLocal = productScalarBase; productScalarLocal.protein = 30
var productScalarRemote = productScalarBase; productScalarRemote.calories = 250
let productScalarEditor = MealNutritionMerge.merged(edited: productScalarLocal, base: productScalarBase, current: productScalarRemote)
let productScalarCloud = try productCloudMeal(productScalarLocal, productScalarRemote, productScalarBase)
productCheck(productScalarEditor.protein == 30 && productScalarEditor.calories == 250 && productNutritionEqual(productScalarEditor, productScalarCloud), "independent manual scalar edits continue to merge")
var productKnownBase = productBase; productKnownBase.components = nil; productKnownBase.consumedFraction = nil
var productWithdrawn = productKnownBase; productWithdrawn.nutritionKnown = false
var productConcurrent = productKnownBase; productConcurrent.calories = 400
let productWithdrawnEditor = MealNutritionMerge.merged(edited: productWithdrawn, base: productKnownBase, current: productConcurrent)
let productWithdrawnCloud = try productCloudMeal(productWithdrawn, productConcurrent, productKnownBase)
productCheck(!productWithdrawnCloud.hasNutrition && productWithdrawnCloud.calories == productKnownBase.calories && productNutritionEqual(productWithdrawnEditor, productWithdrawnCloud), "unknown flag and its values merge as one observation")
let productRemoteWithdrawn = try productCloudMeal(productKnownBase, productWithdrawn, productKnownBase)
productCheck(!productRemoteWithdrawn.hasNutrition && productRemoteWithdrawn.calories == productKnownBase.calories, "remote-only unknown change is retained")
let productOneSided = try productCloudMeal(productBase, productComponents, productBase)
productCheck(productNutritionEqual(productOneSided, productComponents), "one-sided structural edit preserved")
var productPhotoCurrent = productComponents; productPhotoCurrent.photoFilename = "keep.jpg"
let productPhotoResult = MealNutritionMerge.merged(edited: productFraction, base: productBase, current: productPhotoCurrent)
productCheck(productPhotoResult.photoFilename == "keep.jpg", "editor nutrition conflict does not replace unrelated photo")
productCheck(ReviewTrendMetric.volume.unit == "kg·次", "volume unit is kg times repetitions")
print("PRODUCT CONSISTENCY PASSED: \(productChecks) focused regression checks; UI and real Apple services are separate")
'''
Path(sys.argv[1]).write_text(content + '\n' + checks, encoding='utf-8')
