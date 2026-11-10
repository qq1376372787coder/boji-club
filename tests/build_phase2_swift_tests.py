"""Run production Foundation rules; UI/camera need Xcode and a real iPhone."""
from pathlib import Path
import runpy, sys
output=Path(sys.argv[1])
module=runpy.run_path(str(Path(__file__).with_name('build_phase1_swift_tests.py')))
read=module['read'];method=module['method']
code=output.read_text('utf-8')
history=read('ClubHistory.swift')
if 'struct ClubAIDayContext:' not in code:
    code+='\n'+history[history.index('struct ClubAIDayContext:'):history.index('    static func make(state:')]+'}\n'
code+='\nfinal class ReportInputBuilder {\n'+method(read('AIService.swift'),'reportInput')+'\n}\n'
store_source=read('AppStore.swift')
backup_start=store_source.index('private func validateBackupValue(')
code+='\n'+store_source[backup_start:store_source.index('@MainActor',backup_start)].replace('private func validateBackupValue(', 'func validateBackupValue(')
draft_source=read('MealEditorView.swift')
if 'private struct MealEditorDraft:' in draft_source:
    code+='\n'+draft_source[draft_source.index('private struct MealEditorDraft:'):draft_source.index('struct MealEditorView:')].replace('private struct MealEditorDraft:', 'struct MealEditorDraft:')
code+=r'''
let phaseTwoStart = checks
let legacyDraft = Data(#"{"id":"550E8400-E29B-41D4-A716-446655440000","name":"meal","category":"早餐","calories":100,"protein":10,"carbs":10,"fat":2,"components":[],"fraction":1,"estimateNotes":[]}"#.utf8)
var decodedDraft = try JSONDecoder().decode(MealEditorDraft.self,from:legacyDraft)
check(decodedDraft.photoAttached == nil,"old meal drafts retain legacy photo lookup")
decodedDraft.photoAttached = false
let retakeDraft = try JSONDecoder().decode(MealEditorDraft.self,from:JSONEncoder().encode(decodedDraft))
check(retakeDraft.photoAttached == false,"cleared draft explicitly prevents stale photo recovery")
let backupDay = DayLog(workoutStartedAt:now,workoutEndedAt:now,bodyWeight:BodyWeightEntry(kilograms:68,updatedAt:now))
try validateBackupValue(JSONValue.encode(backupDay))
check(true,"month backup accepts new workout and weight timestamps")
rejected("backup still rejects oversized non-timestamp values") { try validateBackupValue(.number(812000000),key:"calories") }
let fixedDate = ClubDates.date(fromKey:"2026-10-04")!
func time(_ hour: Int, _ minute: Int = 0) -> Date {
    ClubDates.calendar.date(bySettingHour:hour,minute:minute,second:0,of:fixedDate)!
}
func meal(_ category: String) -> Meal { Meal(name:"fixture",category:category,calories:100,protein:10,carbs:10,fat:2) }
for (hour,expected) in [(4,"加餐"),(5,"早餐"),(9,"早餐"),(10,"午餐"),(14,"午餐"),(15,"加餐"),(16,"加餐"),(17,"晚餐"),(21,"晚餐"),(22,"加餐")] {
    check(MealCategorySuggestion.recommended(for:fixedDate,now:time(hour),meals:[]) == expected,"meal boundary \(hour)")
}
check(MealCategorySuggestion.recommended(for:fixedDate,now:time(8),meals:[meal("早餐")]) == "加餐","already recorded breakfast suggests snack")
check(MealCategorySuggestion.recommended(for:fixedDate,now:time(8),meals:[meal("加餐")]) == "早餐","snack does not block breakfast")
let priorDate = ClubDates.date(fromKey:"2026-10-03")!
check(MealCategorySuggestion.recommended(for:priorDate,now:time(20),meals:[]) == "早餐","historical record does not infer current dinner")
check(MealCategorySuggestion.recommended(for:priorDate,now:time(20),meals:[meal("早餐")]) == "午餐","historical suggestion chooses unrecorded main meal")
let boundaryCenter = ClubDates.date(fromKey:"2026-10-01")!
let centered = CalendarWindow.dates(centeredOn:boundaryCenter)
check(centered.count == 7 && ClubDates.key(centered[3]) == "2026-10-01","selected date is calendar center")
check(ClubDates.key(centered[0]) == "2026-09-28" && ClubDates.key(centered[6]) == "2026-10-04","calendar crosses month safely")
var dst = Calendar(identifier:.gregorian);dst.timeZone = TimeZone(identifier:"America/New_York")!
let dstCenter = dst.date(from:DateComponents(year:2026,month:3,day:8,hour:12))!
let dstWindow = CalendarWindow.dates(centeredOn:dstCenter,calendar:dst)
check(dstWindow.count == 7 && Set(dstWindow.map { dst.component(.day,from:$0) }).count == 7,"calendar DST dates remain distinct")
for name in ["plank","weighted side plank","wall sit","dead hang","hamstring stretch","stationary bike","rowing machine","平板支撑","靠墙静蹲","股四头肌拉伸","run","farmers walk","walking on stepmill","hands bike","short stride run"] {
    check(ExerciseMeasurement.usesSeconds(name:name),"timed default: \(name)")
}
for name in ["dumbbell row","push-up","plank jack","side plank hip raise","plank shoulder tap","平板支撑抬腿","侧平板转体","卧推","深蹲","kneeling plank tap shoulder (male)","push-up to side plank","isometric wipers","wheel run","power point plank"] {
    check(!ExerciseMeasurement.usesSeconds(name:name),"reps default: \(name)")
}
let timedBlank = ExerciseMeasurement.blankSet(name:"plank")
check(timedBlank.durationSeconds == 30 && timedBlank.reps == 0 && timedBlank.weight == 0 && !timedBlank.completed,"timed new sets start empty and uncompleted")
let timedStore = AppStore()
let loadedTimed = Exercise(name:"farmers walk",muscle:"全身",sets:[TrainingSet(weight:20,reps:0,completed:true,durationSeconds:60)])
timedStore.state.days[today] = DayLog(exercises:[loadedTimed])
check(timedStore.updateSet(loadedTimed.sets[0],exerciseID:loadedTimed.id,on:now),"timed load editing saves")
check(timedStore.log(for:now).exercises[0].sets[0].weight == 20 && timedStore.log(for:now).volume == 0,"timed load preserved without inventing reps volume")
let timedReplacement = Exercise(name:"平板支撑",muscle:"核心",libraryQuery:"plank")
let replacedTimed = try WorkoutEditing.replacing(old,with:timedReplacement,in:partial)
check(replacedTimed.exercises[1].sets.allSatisfy { $0.durationSeconds == 30 && !$0.completed },"replacement adopts timed defaults")
check(try CloudMerge.same(replacedTimed.exercises[0].sets,old.sets.filter(\.validCompletion)),"timed replacement preserves old completed values")
let weights = AppStore(); let originalProfile = weights.state.profile
check(weights.saveBodyWeight(68.26,on:now),"daily weight saves")
check(weights.log(for:now).bodyWeight?.kilograms == 68.3,"weight rounds to one decimal")
check(weights.state.profile == originalProfile,"daily weight does not rewrite profile or plan")
check(!weights.saveBodyWeight(68,on:tomorrow),"future measurement rejected")
check(!weights.saveBodyWeight(Double.nan,on:now),"invalid numeric weight rejected")
let savedWeightState = weights.state; weights.allowPersistence = false
check(!weights.saveBodyWeight(69,on:now),"failed weight persistence reported")
check(try CloudMerge.same(weights.state,savedWeightState),"failed weight save rolls back")
weights.allowPersistence = true
check(weights.saveBodyWeight(68,on:yesterday),"missed date can be recorded")
check(weights.bodyWeightPoints(through:now).count == 2,"history contains actual measurements only")
check(weights.bodyWeightPoints(through:yesterday).count == 1,"historical AI excludes later measurements")
check(weights.saveBodyWeight(nil,on:now),"weight delete saves tombstone")
check(weights.bodyWeightPoints(through:now).count == 1 && weights.log(for:now).bodyWeight?.updatedAt != nil,"deleted date is absent from chart but keeps deletion timestamp")
var remoteWeight = SavedState();remoteWeight.days[today] = DayLog(bodyWeight:BodyWeightEntry(kilograms:70,updatedAt:now.addingTimeInterval(-60)))
let mergedDelete = try CloudMerge.merge(local:CloudState(weights.state),remote:CloudState(remoteWeight),base:nil)
check(mergedDelete.days[today]?.bodyWeight?.kilograms == nil,"stale first sync cannot resurrect deleted weight")
var left = remoteWeight;var right = remoteWeight
left.days[today]?.bodyWeight = BodyWeightEntry(kilograms:71,updatedAt:now)
right.days[today]?.bodyWeight = BodyWeightEntry(kilograms:72,updatedAt:now.addingTimeInterval(1))
let atomicWeight = try CloudMerge.merge(local:CloudState(left),remote:CloudState(right),base:CloudState(remoteWeight))
check(atomicWeight.days[today]?.bodyWeight == right.days[today]?.bodyWeight,"concurrent weight value and timestamp stay together")
let oldDay = try JSONDecoder().decode(DayLog.self,from:Data(#"{"exercises":[],"meals":[]}"#.utf8))
check(oldDay.bodyWeight == nil,"legacy day has no invented weight")
let builder = ReportInputBuilder()
let measuredInput = try builder.reportInput(date:yesterday,log:weights.log(for:yesterday),weightHistory:weights.bodyWeightPoints(through:yesterday))
check(measuredInput.payload["body_weight_kg"] == .number(68),"AI receives actual measured weight")
check(measuredInput.payload["body_weight_history"] != nil,"AI receives sparse date-stamped history")
let deletedInput = try builder.reportInput(date:now,log:weights.log(for:now),weightHistory:weights.bodyWeightPoints(through:now),allowEmpty:true)
check(deletedInput.payload["body_weight_kg"] == nil && deletedInput.payload["body_weight_history"] != nil,"missing today weight is not filled from prior date")
print("PASS \(checks-phaseTwoStart) phase2 production Swift rule checks")
if CommandLine.arguments.count > 1 {
    let rows = try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [[String:String]]
    let classifications = rows.map { row in ["id":row["id"]!,"name":row["name"]!,"unit":ExerciseMeasurement.usesSeconds(name:row["name"]!) ? "seconds" : "reps"] }
    try JSONSerialization.data(withJSONObject:classifications,options:[.sortedKeys,.prettyPrinted]).write(to:URL(fileURLWithPath:"movement-measurements-v19.json"))
    print("CLASSIFIED \(rows.count) exercise catalog entries")
}
'''
output.write_text(code,'utf-8')
print('Added production phase2 rules and actual report-input tests')
