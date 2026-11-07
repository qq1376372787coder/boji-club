"""Extract production cycle/adoption/history rules. Storage and SDK fixtures only.
Run on Mac with tests/run_repair_v75.sh; not an iPhone/SwiftUI verification.
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
models=read('Models.swift');ai=read('AIService.swift');weekly=read('WeeklyReview.swift')
parts=['import Foundation',block(models,'enum ClubDates {'),block(read('RecordReliability.swift'),'final class ClubDateFormatterCache:'),block(models,'struct TrainingSet:'),block(models,'struct Exercise:')]
limits=read('DailyExperience.swift')
parts.append('enum RecordLimits { '+limits[limits.index('static let maximumWeight'):limits.index('static func valid(_ meal:')].strip()+' }')
for marker in ['struct AIPlanSet:','struct AIPlanExercise:','struct AIPlanSession:']:parts.append(block(ai,marker))
for marker in ['struct AIWeeklyTrainingMetrics:','struct AIWeeklyNutritionMetrics:','struct AIWeeklyBodyMetrics:','struct AIWeeklyMetrics:','struct WeeklySurvey:','struct ReviewPhoto:','struct WeeklyResult:','struct WeeklyReview:']:parts.append(block(weekly,marker))
parts.append('enum ExerciseNames { static func display(_ value:String,id:String?,query:String?)->String { value } }')
parts.append('enum WorkoutEditing { '+block(models,'static func isProtected(')+' }')
parts.append(r'''
struct BodyWeightEntry:Codable { var kilograms:Double?;var updatedAt=Date() }
struct HealthDay:Codable { var hasData=false }
struct DayLog:Codable {
    var exercises:[Exercise]=[];var meals:[String]=[];var health:HealthDay?
    var weeklyReview:WeeklyReview?;var planCycle:TrainingCycle?
    var workoutStartedAt:Date?;var workoutSavedAt:Date?;var bodyWeight:BodyWeightEntry?
    var plannedMoveDestination:String?;var movedFromDate:String?
    var completedSets:Int { exercises.flatMap(\.sets).filter(\.validCompletion).count }
}
struct MemberProfile:Codable { var trainingDays:[Int]?=[1,3,5] }
struct SavedState:Codable { var days:[String:DayLog]=[:];var profile=MemberProfile();var deletedExerciseIDs:[String]?;var appliedAIJobs:[String]? }
enum WeeklyVersions { static func insert(_ value:WeeklyReview,into day:inout DayLog) { day.weeklyReview=value } }
enum CloudMerge {
    static func same<T:Encodable>(_ a:T,_ b:T)throws->Bool {
        let e=JSONEncoder();e.outputFormatting=[.sortedKeys];return try e.encode(a)==e.encode(b)
    }
}
final class StoreFixture {
    var state=SavedState();var message:String?;var writesAllowed=true;var changedDates:[String]=[]
    func stableID(_ value:String)->UUID { UUID() }
    func hasAppliedAIJob(_ value:String)->Bool { state.appliedAIJobs?.contains(value)==true }
    func persist(changedDates:[String])->Bool { self.changedDates=changedDates;return writesAllowed }
    func recordWeeklyPlanHistory(review:WeeklyReview,sessions:[AIPlanSession],previous:SavedState,start:Date,scope:[String]) {}
'''.replace('\\.','\\.'))
parts.append(block(read('AppStore.swift'),'func applyWeeklyPlan(')+'\n}')
parts.append(block(read('DailyExperience.swift'),'struct TrainingCycle:'))
parts.append(block(read('JourneyRules.swift'),'enum HistoryVisibility {'))
parts.append(block(read('JourneyRules.swift'),'enum WorkoutSessionTransition {'))
parts.append(block(read('JourneyRules.swift'),'enum ClubNotificationRouting {'))
parts.append(block(read('JourneyRules.swift'),'enum MembershipUpgradePolicy {'))
parts.append('enum PlanExplanationRules {\n'+'\n'.join(block(read('PlanExplanation.swift'),m) for m in ['static func sameStructure(','static func originalSessions(','static func sessions(in','static func session(date:'])+'\n}')
parts.append(r'''
var checks=0
func check(_ value:Bool,_ label:String) { guard value else { fatalError(label) };checks+=1 }
func date(_ key:String)->Date { ClubDates.date(fromKey:key)! }
func movement(_ name:String="旧动作")->Exercise { Exercise(name:name,muscle:"全身",sets:[TrainingSet(reps:10)]) }
let future=ClubDates.calendar.date(byAdding:.day,value:14,to:Date())!
let monday=ClubDates.calendar.nextDate(after:future,matching:DateComponents(weekday:2),matchingPolicy:.nextTime)!
let start=ClubDates.calendar.startOfDay(for:monday)
let dates=(0..<28).map { ClubDates.key(ClubDates.calendar.date(byAdding:.day,value:$0,to:start)!) }
var old:[String:DayLog]=[:]
for i in 0..<14 { old[dates[i]]=DayLog(exercises:[movement()]) }
let originalIDs=old.mapValues { $0.exercises.map(\.id) }
_ = TrainingCycle.stamp(days:&old,start:start,plannedDates:dates,sourceJobID:"old-job")
_ = TrainingCycle.stamp(days:&old,start:date(dates[7]),plannedDates:dates,sourceJobID:"old-job")
let changed=TrainingCycle.stamp(days:&old,start:date(dates[2]),plannedDates:Array(dates[2..<9]),sourceJobID:"new-job")
let intervals=TrainingCycle.available(days:old)
check(Set(intervals.flatMap(\.dates)).count==intervals.flatMap(\.dates).count,"no overlapping cycles after mid-cycle adoption")
check(old[dates[0]]?.planCycle?.end==dates[1] && old[dates[0]]?.planCycle?.sourceJobID=="old-job","old prefix and provenance retained")
check(old[dates[9]]?.planCycle?.end==dates[13] && old[dates[9]]?.planCycle?.sourceJobID=="old-job","old suffix and provenance retained")
check(changed.contains(dates[0]) && changed.contains(dates[13]),"surviving interval changes included in persistence transaction")
check(old.mapValues { $0.exercises.map(\.id) }==originalIDs,"cycle repair does not delete movements")
let encoded=try JSONEncoder().encode(old)
let restored=try JSONDecoder().decode([String:DayLog].self,from:encoded)
check(TrainingCycle.available(days:restored)==intervals,"new intervals survive serialization")
var legacy:[String:DayLog]=[:]
let first=TrainingCycle(start:dates[0],plannedDates:Array(dates[0..<7]),sourceJobID:"old")
let second=TrainingCycle(start:dates[2],plannedDates:Array(dates[2..<9]),sourceJobID:"new")
for key in first.dates { legacy[key]=DayLog(exercises:[movement()],planCycle:first) }
for key in second.dates { legacy[key]=DayLog(exercises:[movement()],planCycle:second) }
let recovered=TrainingCycle.available(days:legacy)
check(Set(recovered.flatMap(\.dates)).count==recovered.flatMap(\.dates).count,"existing overlapping markers resolved by actual ownership")
for duration in [14,28] {
    var logs:[String:DayLog]=[:];var full:[AIPlanSession]=[]
    for i in 0..<duration where i%7==0 || i%7==2 || i%7==4 {
        let ex=movement();logs[dates[i]]=DayLog(exercises:[ex]);full.append(PlanExplanationRules.session(date:dates[i],exercises:[ex]))
    }
    for i in stride(from:0,to:duration,by:7) {
        _=TrainingCycle.stamp(days:&logs,start:date(dates[i]),plannedDates:full.map(\.date),sourceJobID:"long-job")
    }
    for cycle in TrainingCycle.available(days:logs) {
        let expected=PlanExplanationRules.originalSessions(full,in:cycle)
        check(PlanExplanationRules.sameStructure(expected,PlanExplanationRules.sessions(in:cycle,days:logs)),"unchanged long plan is not labelled modified")
        var actual=PlanExplanationRules.sessions(in:cycle,days:logs)
        actual[0].exercises[0].sets[0].reps+=1
        check(!PlanExplanationRules.sameStructure(expected,actual),"actual target edits remain detected")
    }
}
check(!HistoryVisibility.hasRecordedActivity(DayLog(bodyWeight:BodyWeightEntry(kilograms:nil))),"weight deletion tombstone does not create record day")
check(HistoryVisibility.hasRecordedActivity(DayLog(bodyWeight:BodyWeightEntry(kilograms:68))),"actual weight retains record day")
check(HistoryVisibility.hasRecordedActivity(DayLog(meals:["早餐"],bodyWeight:BodyWeightEntry(kilograms:nil))),"other actual records survive weight deletion")
check(!HistoryVisibility.hasRecordedActivity(DayLog(exercises:[movement()],bodyWeight:BodyWeightEntry(kilograms:nil))),"uncompleted schedule alone is not a recorded day")
check(!WorkoutSessionTransition.shouldResetRest(previous:nil,current:UUID()),"automatic first start keeps rest countdown")
check(WorkoutSessionTransition.shouldResetRest(previous:UUID(),current:UUID()),"actual session switch resets rest countdown")
check(WorkoutSessionTransition.shouldResetRest(previous:UUID(),current:nil),"closing session resets rest countdown")
check(ClubNotificationRouting.dateKey(kind:"weekly_center",provided:nil,now:start)==ClubDates.key(start),"periodic reminder opens current review without stale scheduled date")
check(ClubNotificationRouting.dateKey(kind:"weekly_center",provided:"2000-01-01",now:start)==ClubDates.key(start),"periodic reminder date resolved at tap time")
check(ClubNotificationRouting.dateKey(kind:"weekly_review",provided:"2026-10-01",now:start)=="2026-10-01","completed report notification retains exact report date")
check(ClubNotificationRouting.dateKey(kind:"report",provided:"2026-02-30",now:start)==nil,"malformed notification date cannot navigate")
check(ClubNotificationRouting.dateKey(kind:"unsupported",provided:dates[0],now:start)==nil,"unknown notification kind ignored")
check(MembershipUpgradePolicy.permitsPurchase(activeMember:true,lifetimeOwned:false,lifetimePackage:true),"subscriber can buy lifetime")
check(!MembershipUpgradePolicy.permitsPurchase(activeMember:true,lifetimeOwned:false,lifetimePackage:false),"subscriber cannot buy duplicate subscription through upgrade path")
check(!MembershipUpgradePolicy.permitsPurchase(activeMember:true,lifetimeOwned:true,lifetimePackage:true),"permanent member cannot buy again")
check(MembershipUpgradePolicy.permitsPurchase(activeMember:false,lifetimeOwned:false,lifetimePackage:false),"non-member may buy subscription")

func prepared()->(StoreFixture,WeeklyReview,[AIPlanSession]) {
    let store=StoreFixture()
    for i in 0..<7 { store.state.days[dates[i]]=DayLog(exercises:i<5 ? [movement()] : [],meals:["早餐"],bodyWeight:BodyWeightEntry(kilograms:68)) }
    let sessions=[0,2,4].map { i in PlanExplanationRules.session(date:dates[i],exercises:[movement("新动作")]) }
    let result=WeeklyResult(kind:"weekly_review",summary:"",training:"",nutrition:"",recovery:"",appearance:"",photoFeedback:[],decision:"adjust",reason:"",notes:[],sessions:sessions)
    var review=WeeklyReview(date:ClubDates.key(ClubDates.calendar.date(byAdding:.day,value:-1,to:start)!),result:result)
    review.survey.trainingDays=[1,3,5];review.baseline=store.state.days.mapValues(\.exercises)
    return (store,review,sessions)
}
let (store,review,sessions)=prepared()
let oldRemoved=store.state.days[dates[1]]!.exercises[0].id.uuidString
check(store.applyWeeklyPlan(review,sessions:sessions),"whole-week adjustment succeeds")
check(dates.prefix(7).filter { !(store.state.days[$0]?.exercises.isEmpty ?? true) }.count==3,"five training days actually reduced to three")
check(store.state.days[dates[1]]?.meals==["早餐"] && store.state.days[dates[1]]?.bodyWeight?.kilograms==68,"rest day keeps food and weight")
check(store.state.deletedExerciseIDs?.contains(oldRemoved)==true,"removed old exercise receives cloud tombstone")
check(store.applyWeeklyPlan(review,sessions:sessions) && store.state.days[dates[0]]?.exercises.count==1,"second apply is idempotent")
let (partial,pReview,pSessions)=prepared()
check(partial.applyWeeklyPlan(pReview,sessions:[pSessions[0]],replaceWholeWeek:false),"explicit partial adjustment remains available")
check(partial.state.days[dates[1]]?.exercises.count==1,"partial adjustment preserves other dates")
let (protected,qReview,qSessions)=prepared();protected.state.days[dates[1]]!.workoutStartedAt=Date()
let beforeProtected=try JSONEncoder().encode(protected.state)
check(!protected.applyWeeklyPlan(qReview,sessions:qSessions),"started rest-day workout blocks entire transaction")
check(try CloudMerge.same(protected.state,JSONDecoder().decode(SavedState.self,from:beforeProtected)),"blocked whole-week change preserves all data")
let (edited,eReview,eSessions)=prepared();edited.state.days[dates[1]]!.exercises[0].sets[0].reps=12
check(!edited.applyWeeklyPlan(eReview,sessions:eSessions),"concurrent edit on removed rest day blocks replacement")
let (failed,fReview,fSessions)=prepared();failed.writesAllowed=false
let previous=failed.state
check(!failed.applyWeeklyPlan(fReview,sessions:fSessions),"storage failure is reported")
check(try CloudMerge.same(previous,failed.state),"storage failure rolls back rest-day removal and replacements")
let (missing,mReview,mSessions)=prepared();var withoutBaseline=mReview;withoutBaseline.baseline.removeValue(forKey:dates[1])
check(!missing.applyWeeklyPlan(withoutBaseline,sessions:mSessions),"missing baseline cannot remove an old arrangement")
print("PASS \(checks) production v75 cycle/adoption/history rules")
'''.replace('\\.','\\.'))
Path(sys.argv[1]).write_text('\n'.join(parts),'utf-8')
