"""Run production Foundation rules with the existing persistence fixtures."""
from pathlib import Path
import runpy, sys

output = Path(sys.argv[1])
module = runpy.run_path(str(Path(__file__).with_name('build_phase3_swift_tests.py')))
read, method = module['read'], module['module']['method']
code = output.read_text('utf-8')
code = code.replace('    var state = SavedState()', '''    var state = SavedState()
    var mediaDirectory = FileManager.default.temporaryDirectory
    func prepareMediaDirectory() throws { }
''', 1)
store = read('AppStore.swift')
code += '\nextension AppStore {\n' + method(store, 'saveWorkoutPlan') + '\n' + method(store, 'addMeal') + '\n}\n'
code += '\nextension ReportInputBuilder {\n' + method(read('AIService.swift'),'planExercisesInput') + '\n}\n'
code += r'''
do {
let before=checks
let futureStore=AppStore()
let pendingMovement=Exercise(name:"计划",muscle:"核心",sets:[TrainingSet(reps:0,durationSeconds:30)])
futureStore.state.days[ClubDates.key(tomorrow)]=DayLog(exercises:[pendingMovement])
var checked=pendingMovement.sets[0];checked.completed=true;checked.actualEntered=true
check(!futureStore.updateSet(checked,exerciseID:pendingMovement.id,on:tomorrow),"future set completion is refused at store boundary")
check(futureStore.log(for:tomorrow).completedSets == 0,"future rejected write leaves plan intact")
check(!futureStore.saveWorkout(on:tomorrow),"future workout cannot be confirmed")
var planned=pendingMovement.sets[0];planned.durationSeconds=50
check(futureStore.updateSet(planned,exerciseID:pendingMovement.id,on:tomorrow),"future target duration remains editable")
check(futureStore.saveWorkoutPlan(on:tomorrow),"future plan saves without completed history")
check(futureStore.log(for:tomorrow).workoutSavedAt == nil && futureStore.log(for:tomorrow).workoutStartedAt == nil,"plan has no fabricated start or finish")
check(!futureStore.addMeal(meal("午餐"),photo:nil,on:tomorrow),"future meal rejected by store")
rejected("future daily report rejected") { _=try builder.reportInput(date:tomorrow,log:DayLog()) }
let plannedJSON=try builder.planExercisesInput(DayLog(exercises:[Exercise(name:"未来基线",muscle:"核心",sets:[checked])]))
if case .object(let exercise)=plannedJSON[0],case .array(let sets)?=exercise["sets"],case .object(let values)=sets[0] { check(values["completed"] == .bool(false),"weekly future plan input is allowed without fabricating completion") } else { fatalError("missing plan input") }
check(!ClubDates.isFuture(now) && ClubDates.isFuture(tomorrow),"future rule compares natural days")
let startedStore=AppStore()
startedStore.state.days[today]=DayLog(exercises:[pendingMovement])
check(startedStore.updateSet(checked,exerciseID:pendingMovement.id,on:now),"first completed set starts today's workout")
let firstStart=startedStore.log(for:now).workoutStartedAt
check(firstStart != nil,"automatic start timestamp persisted")
check(startedStore.updateSet(checked,exerciseID:pendingMovement.id,on:now) && startedStore.log(for:now).workoutStartedAt == firstStart,"editing completed group never resets start")
check(startedStore.log(for:now).timedSeconds == 30 && startedStore.log(for:now).completedSets == 1 && startedStore.log(for:now).volume == 0,"timed completion is visible without invented kilograms")
let historyStore=AppStore();historyStore.state.days[ClubDates.key(yesterday)]=DayLog(exercises:[pendingMovement])
check(historyStore.updateSet(checked,exerciseID:pendingMovement.id,on:yesterday) && historyStore.log(for:yesterday).workoutStartedAt == nil,"historical completion never invents present start time")
let rollback=AppStore();rollback.state.days[today]=DayLog(exercises:[pendingMovement]);rollback.allowPersistence=false
check(!rollback.updateSet(checked,exerciseID:pendingMovement.id,on:now) && rollback.log(for:now).workoutStartedAt == nil,"failed persistence rolls back automatic start and completion")
var unknown=meal("早餐");unknown.nutritionKnown=false;unknown.calories=0;unknown.protein=0
let foodStore=AppStore()
check(foodStore.addMeal(unknown,photo:nil,on:now,handledAIJobIDs:["waiting-food"]),"manual meal and pending food task handled in one persistent write")
check(foodStore.hasAppliedAIJob("waiting-food"),"late AI result remains durably handled")
check(!foodStore.addMeal(unknown,photo:nil,on:now),"same draft cannot be saved twice")
check(!foodStore.addMeal(meal("早餐"),photo:nil,on:now,handledAIJobIDs:["waiting-food"]),"same food task cannot create a second meal")
check(foodStore.log(for:now).unknownNutritionMeals == 1 && foodStore.log(for:now).knownMeals.isEmpty,"unknown meal stays explicitly unknown")
check(ReviewMetrics(logs:[foodStore.log(for:now)]).averageCalories == nil,"unknown-only day does not become zero-calorie average")
let input=try builder.reportInput(date:now,log:foodStore.log(for:now))
if case .array(let meals)?=input.payload["meals"],case .object(let values)=meals[0] { check(values["nutrition_known"] == .bool(false),"AI input declares missing nutrition") } else { fatalError("missing meal") }
let oldMeal=try JSONDecoder().decode(Meal.self,from:Data(#"{"id":"550E8400-E29B-41D4-A716-446655440000","name":"old","category":"早餐","calories":100,"protein":10,"carbs":10,"fat":2}"#.utf8))
check(oldMeal.hasNutrition,"legacy nutrition remains decodable and known")
let mixed=DayLog(meals:[unknown,oldMeal])
check(mixed.calories == 100 && mixed.unknownNutritionMeals == 1,"known meal totals exclude missing meal")
var nutritionBase=SavedState();nutritionBase.days[today]=DayLog(meals:[unknown])
var nutritionLocal=nutritionBase;var nutritionRemote=nutritionBase
nutritionLocal.days[today]!.meals[0].name="补充菜名"
nutritionRemote.days[today]!.meals[0].calories=300;nutritionRemote.days[today]!.meals[0].protein=20;nutritionRemote.days[today]!.meals[0].nutritionKnown=true
let nutritionMerged=try CloudMerge.merge(local:CloudState(nutritionLocal),remote:CloudState(nutritionRemote),base:CloudState(nutritionBase)).savedState().days[today]!.meals[0]
check(nutritionMerged.name == "补充菜名" && nutritionMerged.hasNutrition && nutritionMerged.calories == 300 && nutritionMerged.protein == 20,"remote nutrition fill combines safely with local meal name edit")
nutritionLocal.days[today]!.meals[0].nutritionKnown=true;nutritionLocal.days[today]!.meals[0].calories=200;nutritionLocal.days[today]!.meals[0].protein=10
let nutritionConflict=try CloudMerge.merge(local:CloudState(nutritionLocal),remote:CloudState(nutritionRemote),base:CloudState(nutritionBase)).savedState().days[today]!.meals[0]
check(nutritionConflict.hasNutrition && nutritionConflict.calories == 200 && nutritionConflict.protein == 10,"concurrent manual nutrition edits keep one coherent set of values")
nutritionBase=nutritionRemote;nutritionLocal=nutritionBase;nutritionLocal.days[today]!.meals[0].nutritionKnown=false
nutritionRemote.days[today]!.meals[0].calories=400
let unknownConflict=try CloudMerge.merge(local:CloudState(nutritionLocal),remote:CloudState(nutritionRemote),base:CloudState(nutritionBase)).savedState().days[today]!.meals[0]
check(!unknownConflict.hasNutrition && unknownConflict.calories == 300,"unknown flag never inherits unrelated remote nutrition values")
let mixedText=String(repeating:"训练记录。中文 English 123\n👨‍👩‍👦 继续！",count:300)
let pages=ShareTextPages.split(mixedText){$0.count <= 120}
check(pages.count > 1 && pages.joined() == mixedText,"pagination preserves every character and emoji")
check(pages.allSatisfy{!$0.isEmpty && $0.count <= 120},"page boundary never exceeds measured capacity")
check(ShareTextPages.split(""){_ in true} == [""],"empty share text remains one valid page")
let longWord=String(repeating:"A",count:5000)
check(ShareTextPages.split(longWord){$0.count<=80}.joined() == longWord,"unbroken English text paginates without data loss")
let suite="boji-v21-test-"+UUID().uuidString;let defaults=UserDefaults(suiteName:suite)!
defer { defaults.removePersistentDomain(forName:suite) }
let owner=9876
check(ClubGuideProgress.shouldShow(owner,now:now,defaults:defaults),"new member guide is pending")
defaults.set(now,forKey:"boji.usage-guide.v2.9876.snoozed")
check(!ClubGuideProgress.shouldShow(owner,now:now,defaults:defaults),"postponed guide stays quiet today")
check(ClubGuideProgress.shouldShow(owner,now:tomorrow,defaults:defaults),"postponing does not mark guide complete")
defaults.set(true,forKey:"boji.usage-guide.v2.9876.completed")
check(!ClubGuideProgress.shouldShow(owner,now:tomorrow,defaults:defaults),"completed guide is not automatically repeated")
defaults.removeObject(forKey:"boji.usage-guide.v2.9876.completed");defaults.set(true,forKey:"boji.usage-guide.v2.9876.muted")
check(!ClubGuideProgress.shouldShow(owner,now:tomorrow,defaults:defaults),"explicit guide mute respected")
let pendingJob=AILocalJob(id:"x",digest:"x",request:AIRequest(id:"x",kind:"food",date:today,payload:[:]),status:"discarded",consumed:true)
check(pendingJob.isTerminal,"discarded recognition never resumes")
print("PASS \(checks-before) v21 production Swift rule checks; total \(checks)")
}
'''
output.write_text(code,'utf-8')
print('Built v21 production Swift rules')
