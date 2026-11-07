"""Use actual production Codable, persistence and merge rules; Mac Swift required."""
from pathlib import Path
import sys,runpy
out=Path(sys.argv[1])
runpy.run_path(str(Path(__file__).with_name('build_experience_v25_swift_tests.py')))
code=out.read_text('utf-8')
module=runpy.run_path(str(Path(__file__).with_name('build_phase1_swift_tests.py')))
code+='\nextension AppStore {\n'+module['method'](module['read']('AppStore.swift'),'handleMealRecognitionIDs')+'\n}\n'
code+=r'''
do {
let root=UUID().uuidString.lowercased()
let first=MealBatchIdentity.sourceID(root:root,item:"m1")
let second=MealBatchIdentity.sourceID(root:root,item:"m2")
check(first != second,"each card has independent save identity")
check(MealBatchIdentity.parentID(first) == root,"child resolves to parent")
check(MealBatchIdentity.parentID("meal-batch/not-a-uuid/m1") == nil,"invalid parent rejected")
let old=try JSONDecoder().decode(AIResult.self,from:Data(#"{"kind":"meal","notes":[],"name":"旧餐食","is_food":true}"#.utf8))
check(old.meals == nil && old.name == "旧餐食","legacy single meal decodes")
let item=AIBatchMeal(id:"m1",date:today,category:"早餐",name:"鸡蛋",notes:[],components:[],estimated:true,calories:150,protein:13,carbs:1,fat:10)
let value=AIResult(kind:"meal_batch",notes:[],meals:[item])
let decoded=try JSONDecoder().decode(AIResult.self,from:JSONEncoder().encode(value))
check(decoded.meals?.first?.date == today,"cloud result preserves child date")
let store=AppStore()
let meal=Meal(name:"鸡蛋",category:"早餐",calories:150,protein:13,carbs:1,fat:10,sourceAIJobID:first)
check(store.addMeal(meal,photo:nil,on:now,handledAIJobIDs:[first]),"first batch card saved")
check(!store.hasAppliedAIJob(root) && !store.hasAppliedAIJob(second),"saving breakfast keeps other cards pending")
check(!store.addMeal(meal,photo:nil,on:yesterday,handledAIJobIDs:[first]),"same child cannot save again on another day")
store.allowPersistence=false
check(!store.handleMealRecognitionIDs([second]),"failed skip persistence reported")
check(!store.hasAppliedAIJob(second),"failed skip does not consume lunch")
store.allowPersistence=true
check(store.handleMealRecognitionIDs([second]),"skip is persisted separately")
check(store.state.days[today]?.meals.count == 1,"skip creates no fake meal")
let left=SavedState(days:[today:DayLog(meals:[meal])])
let right=SavedState(days:[ClubDates.key(yesterday):DayLog(meals:[meal])])
let forward=try CloudMerge.merge(local:CloudState(left),remote:CloudState(right),base:nil)
let backward=try CloudMerge.merge(local:CloudState(right),remote:CloudState(left),base:nil)
check(forward.days.values.reduce(0) { $0+$1.meals.count } == 1,"offline concurrent cross-day child saves deduplicated")
check(try CloudMerge.same(forward,backward),"cross-day conflict resolves identically on both devices")
print("MULTI-MEAL RULES PASSED")
}
'''
out.write_text(code,'utf-8')
