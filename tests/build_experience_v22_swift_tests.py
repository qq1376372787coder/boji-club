"""Test production rules with an authorization stub; no HealthKit or iOS UI is emulated."""
from pathlib import Path
import runpy,sys

output=Path(sys.argv[1])
module=runpy.run_path(str(Path(__file__).with_name('build_experience_v21_swift_tests.py')))
read,method=module['read'],module['method']
code=output.read_text('utf-8')
shared=(Path(__file__).resolve().parents[1]/'BojiClubWidget/TrainingShared.swift').read_text('utf-8')
code+='\n'+shared[:shared.index('#if canImport(ActivityKit)')]
code+=r'''
enum HKObjectType { static func workoutType() -> Int { 1 } }
enum AppErrorText { static func message(_ error: Error) -> String { error.localizedDescription } }
enum ConnectionFixtureError: Error { case failed }
final class AuthorizationFixture {
    var onRequest: (() -> Void)?
    var fail=false
    func requestAuthorization(toShare: [Int], read: Set<Int>) async throws {
        onRequest?()
        if fail { throw ConnectionFixtureError.failed }
    }
}
final class HealthConnectionFixture {
    var available=true
    var busy=false
    var accountID: Int?=1
    var storageAvailable=true
    var generation=UUID()
    var enabled=false
    var writeWorkoutsEnabled=false
    var message: String?
    var health=AuthorizationFixture()
    var readTypes: Set<Int>=[]
    var failSave=false
    var refreshedDates: [Date]=[]
    func save() throws { if failSave { throw ConnectionFixtureError.failed } }
    func refresh(_ date: Date) async { refreshedDates.append(date) }
'''+method(read('HealthData.swift'),'connect')+'\n}\n'
code+='\nfinal class RootDayFixture { var selectedDate=Date();var homeDate=Date();var currentDay="";var store=AppStore()\n'+method(read('ClubAIShell.swift'),'refreshDay').replace('private func refreshDay','func refreshDay')+'\n}\n'
code+='\nlet widgetTestSuite="boji-v22-widget-test-"+UUID().uuidString\nfinal class WidgetCenter { static let shared=WidgetCenter();var reloads=0;func reloadAllTimelines(){reloads+=1} }\n'
code+='\nextension AppStore {\n'+method(read('AppStore.swift'),'publishWidgetSnapshot').replace('UserDefaults(suiteName: "group.com.bojiclub.shared")','UserDefaults(suiteName: widgetTestSuite)')+'\n}\n'
code+=r'''
do {
let before=checks
let midnight=ClubDates.calendar.startOfDay(for:now)
let started=midnight.addingTimeInterval(-600)
let finishedAfterMidnight=midnight.addingTimeInterval(1200)
let nightDate=ClubDates.calendar.startOfDay(for:started)
let timedMovement=Exercise(name:"平板支撑",muscle:"核心",sets:[TrainingSet(reps:0,completed:true,durationSeconds:65)])
var night=DayLog(exercises:[timedMovement],workoutStartedAt:started)
check(WorkoutTiming.isOngoing(night,on:nightDate,now:finishedAfterMidnight),"unfinished workout continues across midnight")
let rootDay=RootDayFixture();rootDay.selectedDate=started;rootDay.currentDay=ClubDates.key(nightDate);rootDay.store.state.days[ClubDates.key(nightDate)]=night
rootDay.refreshDay(now:finishedAfterMidnight)
check(ClubDates.key(rootDay.selectedDate) == ClubDates.key(nightDate) && rootDay.currentDay == ClubDates.key(nightDate),"midnight rollover preserves selected session and defers automatic date advancement")
guard rootDay.store.saveWorkout(on:nightDate,now:finishedAfterMidnight) else { fatalError("fixture save failed") }
rootDay.refreshDay(now:finishedAfterMidnight)
check(ClubDates.key(rootDay.selectedDate) == ClubDates.key(finishedAfterMidnight) && rootDay.currentDay == ClubDates.key(finishedAfterMidnight),"after workout confirmation the deferred date rollover resumes")
let historicalFocus=RootDayFixture();historicalFocus.selectedDate=nightDate.addingTimeInterval(-86400);historicalFocus.currentDay=ClubDates.key(nightDate)
historicalFocus.refreshDay(now:finishedAfterMidnight)
check(historicalFocus.selectedDate == nightDate.addingTimeInterval(-86400),"intentional historical browsing is not reset by midnight rollover")
check(!WorkoutTiming.isOngoing(night,on:midnight,now:finishedAfterMidnight),"started workout is not silently moved to the new date")
night.workoutSavedAt=finishedAfterMidnight
check(!WorkoutTiming.isOngoing(night,on:nightDate,now:finishedAfterMidnight),"confirmed workout does not keep an old date selected")
night.workoutSavedAt=nil
check(!WorkoutTiming.hasRecentStart(night,on:nightDate,now:started.addingTimeInterval(-1)),"future start never fabricates an end")
check(!WorkoutTiming.isOngoing(night,on:nightDate,now:started.addingTimeInterval(12*3600+1)),"stale unfinished diary is not treated as an ongoing session")
let nightStore=AppStore();nightStore.state.days[ClubDates.key(nightDate)]=night
check(nightStore.saveWorkout(on:nightDate,now:finishedAfterMidnight),"cross-midnight workout saves under its starting date")
check(nightStore.log(for:nightDate).workoutEndedAt == finishedAfterMidnight,"cross-midnight save records the actual finish timestamp")
check(nightStore.saveWorkout(on:nightDate,now:finishedAfterMidnight.addingTimeInterval(60)) && nightStore.log(for:nightDate).workoutEndedAt == finishedAfterMidnight,"cross-midnight resave preserves original finish")
let failedNight=AppStore();failedNight.state.days[ClubDates.key(nightDate)]=night;failedNight.allowPersistence=false
check(!failedNight.saveWorkout(on:nightDate,now:finishedAfterMidnight) && failedNight.log(for:nightDate).workoutEndedAt == nil,"failed cross-midnight save rolls back the end timestamp")
let staleStore=AppStore();var stale=night;stale.workoutStartedAt=started.addingTimeInterval(-86400)
let staleDate=ClubDates.calendar.startOfDay(for:stale.workoutStartedAt!);staleStore.state.days[ClubDates.key(staleDate)]=stale
check(staleStore.saveWorkout(on:staleDate,now:finishedAfterMidnight) && staleStore.log(for:staleDate).workoutEndedAt == nil,"historical unfinished diary does not invent a present finish")
let timedText=TrainingRecordText.summary(night)
check(timedText.contains("计时动作合计 1 分 5 秒") && !timedText.contains(where:{$0.contains("kg")}),"timed workout sharing shows duration instead of zero kilograms")
let bodyweight=DayLog(exercises:[Exercise(name:"俯卧撑",muscle:"胸",sets:[TrainingSet(reps:10,completed:true)])])
check(TrainingRecordText.measurements(bodyweight) == ["按次训练，以完成组数统计"],"zero external load still shows completed counted training")
let mixedTraining=DayLog(exercises:[timedMovement,Exercise(name:"卧推",muscle:"胸",sets:[TrainingSet(weight:20,reps:10,completed:true)])])
check(TrainingRecordText.measurements(mixedTraining).count == 2,"mixed training retains both weight volume and timed duration")
check(TrainingRecordText.completedSets(mixedTraining,on:tomorrow,now:now) == 0 && mixedTraining.completedSets == 2,"legacy future completion is hidden without deleting stored records")
check(TrainingRecordText.completedSets(mixedTraining,on:now,now:now) == 2,"today's recorded completion is still shown")
let unknownWidget=TrainingWidgetSnapshot(mealCount:1,knownMealCount:0)
check(unknownWidget.nutritionSummary == "饮食已记录 · 营养待补填","unknown-only widget does not display zero calorie intake")
let mixedWidget=TrainingWidgetSnapshot(calories:300,protein:20,mealCount:2,knownMealCount:1)
check(mixedWidget.nutritionSummary.contains("300 kcal") && mixedWidget.nutritionSummary.contains("1餐待补填"),"widget displays known nutrition and missing meal separately")
check(TrainingWidgetSnapshot().nutritionSummary == "尚未记录饮食","empty widget does not claim an unknown meal exists")
let legacyWidget=try JSONDecoder().decode(TrainingWidgetSnapshot.self,from:Data(#"{"date":"2026-10-03","workoutName":"训练","completedSets":1,"totalSets":2,"calories":400,"protein":30,"mealCount":1,"updatedAt":0}"#.utf8))
check(legacyWidget.knownMealCount == nil && legacyWidget.nutritionSummary.contains("400 kcal"),"previous-version widget cache remains decodable")
let restoredWidget=try JSONDecoder().decode(TrainingWidgetSnapshot.self,from:JSONEncoder().encode(unknownWidget))
check(restoredWidget == unknownWidget && restoredWidget.nutritionSummary == unknownWidget.nutritionSummary,"unknown nutrition survives widget cache serialization")
let widgetDefaults=UserDefaults(suiteName:widgetTestSuite)!
defer { widgetDefaults.removePersistentDomain(forName:widgetTestSuite) }
let publishing=AppStore();var missingMeal=Meal(name:"晚餐",category:"晚餐",calories:0,protein:0,carbs:0,fat:0);missingMeal.nutritionKnown=false
publishing.state.days[today]=DayLog(meals:[missingMeal])
publishing.state.days[ClubDates.key(tomorrow)]=DayLog(exercises:[timedMovement],meals:[missingMeal])
let reloadsBefore=WidgetCenter.shared.reloads;publishing.publishWidgetSnapshot(now:now)
let widgetData=widgetDefaults.data(forKey:"training.snapshots.v2")!
let widgetCache=try JSONDecoder().decode(TrainingWidgetCache.self,from:widgetData)
check(widgetCache.snapshots.first?.knownMealCount == 0 && widgetCache.snapshots.first?.mealCount == 1,"widget publisher persists unknown meal count without losing the record")
let futureWidget=widgetCache.snapshots.first(where:{$0.date==ClubDates.key(tomorrow)})!
check(futureWidget.completedSets == 0 && futureWidget.mealCount == 0 && futureWidget.totalSets == 1,"future widget publishes plan only even with legacy completed data")
publishing.publishWidgetSnapshot(now:now.addingTimeInterval(30))
check(widgetDefaults.data(forKey:"training.snapshots.v2") == widgetData && WidgetCenter.shared.reloads == reloadsBefore+1,"unchanged widget snapshot does not write or reload on the next heartbeat")
publishing.state.days[today]!.meals[0].nutritionKnown=true;publishing.state.days[today]!.meals[0].calories=300
publishing.publishWidgetSnapshot(now:now.addingTimeInterval(60))
let filledWidget=try JSONDecoder().decode(TrainingWidgetCache.self,from:widgetDefaults.data(forKey:"training.snapshots.v2")!).snapshots.first!
check(filledWidget.knownMealCount == 1 && filledWidget.calories == 300 && filledWidget.updatedAt == now.addingTimeInterval(60),"nutrition fill updates widget data and freshness")
publishing.editingAccountID=nil;publishing.publishWidgetSnapshot(now:now)
check(widgetDefaults.data(forKey:"training.snapshots.v2") == nil && widgetDefaults.data(forKey:"training.snapshot") == nil,"sign-out clears both generations of widget cache")
let connected=HealthConnectionFixture();await connected.connect(on:yesterday)
check(connected.refreshedDates.count == 1 && ClubDates.key(connected.refreshedDates[0]) == ClubDates.key(yesterday),"authorization refreshes the selected historical date")
let failedConnection=HealthConnectionFixture();failedConnection.failSave=true;await failedConnection.connect(on:yesterday)
check(!failedConnection.enabled && !failedConnection.busy && failedConnection.refreshedDates.isEmpty && failedConnection.message != nil,"failed authorization persistence restores disconnected state")
let changedConnection=HealthConnectionFixture()
changedConnection.health.onRequest={changedConnection.generation=UUID();changedConnection.accountID=2;changedConnection.busy=false}
await changedConnection.connect(on:yesterday)
check(!changedConnection.enabled && changedConnection.refreshedDates.isEmpty,"authorization completion cannot read for a switched account")
let rejectedConnection=HealthConnectionFixture();rejectedConnection.health.fail=true;await rejectedConnection.connect(on:yesterday)
check(!rejectedConnection.busy && !rejectedConnection.enabled && rejectedConnection.refreshedDates.isEmpty,"authorization error clears loading and preserves disconnected state")
print("PASS \(checks-before) v22 production Swift rule checks; total \(checks)")
}
'''
output.write_text(code,'utf-8')
print('Built v22 production Swift rules')
