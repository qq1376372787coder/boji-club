"""Extract changed production Foundation rules and timer methods, with storage fixtures.
Run on Mac: python3 tests/build_pretestflight_v74_swift_tests.py /tmp/boji-v74.swift
            swift /tmp/boji-v74.swift
This does not replace a SwiftUI/iPhone test.
"""
import re,sys
from pathlib import Path
root=Path(__file__).resolve().parents[1]/'BojiClub'
def read(name):return (root/name).read_text('utf-8')
def block(source, marker):
    start=source.index(marker);opening=source.index('{',start);depth=1;end=opening+1
    while depth:
        if source[end]=='{':depth+=1
        elif source[end]=='}':depth-=1
        end+=1
    return source[start:end]
models=read('Models.swift');daily=read('DailyExperience.swift');timer=read('WorkoutView.swift')
timer=timer[timer.index('private struct TimedTrainingSetView:'):timer.index('struct ExerciseDetailView:')]
weekly=read('WeeklyReview.swift')
parts=['import Foundation',
    block(models,'enum ClubDates {'),block(read('RecordReliability.swift'),'final class ClubDateFormatterCache:'),
    block(models,'struct TrainingSet:'),block(read('AIService.swift'),'struct AIPlanSet:'),
    block(daily,'enum ExerciseMeasurement {'),block(daily,'struct WorkoutStopwatch:'),
    block(read('JourneyRules.swift'),'enum NewPlanDateRules {'),
    read('MealSpeechInput.swift')[read('MealSpeechInput.swift').index('struct MealDescriptionHint {'):]]
limits=read('DailyExperience.swift')
parts.append('enum RecordLimits { '+limits[limits.index('static let maximumWeight'):limits.index('static func valid(_ meal:')].strip()+' }')
fixtures=r'''
enum AccountError: Error { case message(String) }
enum CloudMerge {
    static func same<T:Encodable>(_ a:T,_ b:T) throws -> Bool {
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        return try encoder.encode(a)==encoder.encode(b)
    }
}
struct FixtureExercise { var id:UUID; var sets:[TrainingSet] }
struct FixtureDay {
    var activeWorkoutSessionID:UUID?;var workoutStartedAt:Date?;var exercises:[FixtureExercise]
    var completedSets:Int { exercises.flatMap(\.sets).filter(\.validCompletion).count }
    var trainingLog:FixtureDay { self }
}
final class TimerStore {
    var editingAccountID:Int?=1;var allowBegin=true;var beginCount=0
    var day:FixtureDay
    init(exerciseID:UUID,set:TrainingSet) { day=FixtureDay(exercises:[FixtureExercise(id:exerciseID,sets:[set])]) }
    func log(for date:Date)->FixtureDay { day }
    func beginWorkout(on date:Date)->Bool {
        guard allowBegin else { return false }
        beginCount+=1;day.workoutStartedAt=Date()
        if day.activeWorkoutSessionID==nil { day.activeWorkoutSessionID=UUID() }
        return true
    }
    func takeMessage(fallback:String)->String { fallback }
}
struct WorkoutPauseState { var isPaused=false; var sessionID:UUID? }
final class WorkoutPauseStub { var state:WorkoutPauseState? }
final class TimerFixture {
    var date=Date();let exerciseID=UUID()
    var original=TrainingSet(reps:0,durationSeconds:30)
    var workoutPause=WorkoutPauseStub()
    lazy var store=TimerStore(exerciseID:exerciseID,set:original)
    var stopwatch=WorkoutStopwatch();var owner:Int?=1;var sessionID:UUID?;var error:String?
    var saveAllowed=true;var saved:TrainingSet?;var dismissed=false
    func save(_ set:TrainingSet)->Bool { if saveAllowed { saved=set };return saveAllowed }
    func dismiss() { dismissed=true }
'''
fixtures+='\n'+block(timer,'private var unchanged:').replace('private var','var')
fixtures+='\n'+block(timer,'private func toggleTimer(').replace('private func','func')
fixtures+='\n'+block(timer,'private func registerTimedSet(').replace('private func','func')+'\n}\n'
fixtures+=block(weekly,'struct ReviewPhoto:')
fixtures+=r'''
struct WeeklyReview:Codable { var id=UUID();var photos:[ReviewPhoto]=[];var result:String?;var jobID:String? }
final class PhotoFixture {
    var busy=false;var canSave=true;var message:String?;var failPersistence=false
    var reviews:[WeeklyReview]=[];var folder:URL?
    init(_ folder:URL) { self.folder=folder }
    func persist() throws {
        if failPersistence { throw AccountError.message("injected write failure") }
        try JSONEncoder().encode(reviews).write(to:folder!.appendingPathComponent("reviews.json"),options:.atomic)
    }
'''
for marker in ['func photo(','func addPhoto(','func removePhotos(','private func cleanupUnreferencedPhotos(']:
    fixtures+='\n'+block(weekly,marker).replace('private func','func')
fixtures+='\n}\n'
parts.append(fixtures)
parts.append(r'''
var checks=0
func check(_ condition:Bool,_ message:String) { guard condition else { fatalError(message) };checks+=1 }
let now=ClubDates.date(fromKey:"2026-10-14")!.addingTimeInterval(12*3600)
func hint(_ text:String)->MealDescriptionHint { MealDescriptionUnderstanding.inspect(text,date:now,category:"早餐",now:now) }
for text in ["10月13日早餐吃了两个鸡蛋","10 月 13 号早餐吃了两个鸡蛋","十月十三日早餐吃了两个鸡蛋","2026年10月13日早餐吃了两个鸡蛋","二〇二六年十月十三日早餐吃了两个鸡蛋","2026-10-13早餐吃了两个鸡蛋","2026/10/13早餐吃了两个鸡蛋"] {
    check(ClubDates.key(hint(text).date)=="2026-10-13" && hint(text).problem==nil,text)
}
check(hint("10月14日早餐吃了鸡蛋").requiresDateConfirmation,"explicit same-day date requires review")
check(hint("10月15日早餐吃了鸡蛋").problem != nil,"future date rejected")
check(hint("明年10月13日吃了鸡蛋").problem != nil,"future year rejected")
check(hint("10月13日今天吃了鸡蛋").problem != nil,"conflicting relative and calendar dates rejected")
check(hint("10月13日昨天吃了鸡蛋").problem==nil,"equivalent dates accepted")
check(hint("10月12日和10月13日吃了鸡蛋").problem != nil,"different dates require batch")
check(hint("2月30日吃了鸡蛋").problem != nil,"invalid day cannot normalize into March")
check(hint("2026年2月29日吃了鸡蛋").problem != nil,"invalid leap date rejected")
check(hint("2024年2月29日吃了鸡蛋").problem==nil,"valid leap date retained")
check(ClubDates.key(hint("去年十月十三日吃了鸡蛋").date)=="2025-10-13","explicit past year")
check(!hint("吃了1/2碗饭和2.5克油").requiresDateConfirmation,"quantities are not dates")
check(ClubDates.key(hint("昨天早餐吃了鸡蛋").date)=="2026-10-13","relative date retained")
check(hint("今天早上加餐吃了鸡蛋").category=="加餐","morning snack remains a snack")
check(NewPlanDateRules.isValidStart("2026-10-14",now:now),"local today valid")
check(!NewPlanDateRules.isValidStart("2026-10-13",now:now),"local past rejected")
check(NewPlanDateRules.isValidStart("2027-01-01",now:now),"future year valid")
check(!NewPlanDateRules.isValidStart("2026-02-30",now:now),"invalid plan date rejected")
check(!NewPlanDateRules.isValidStart("2026-10-14",replacingProfileWeek:true,now:now),"profile replacement protects today before requesting AI")
check(NewPlanDateRules.isValidStart("2026-10-15",replacingProfileWeek:true,now:now),"profile replacement can start tomorrow")
let counted=ExerciseMeasurement.planReplacementSets(count:4,name:"哑铃卧推",query:"dumbbell bench press",recordingUnit:"reps")
check(counted.count==4 && counted.allSatisfy { $0.durationSeconds==nil && $0.reps==10 && $0.weight==nil },"timed -> counted resets target and weight")
let timed=ExerciseMeasurement.planReplacementSets(count:4,name:"平板支撑",query:"plank",recordingUnit:"time")
check(timed.count==4 && timed.allSatisfy { $0.durationSeconds==30 && $0.reps==0 && $0.weight==nil },"counted -> timed resets target and weight")
check(ExerciseMeasurement.planReplacementSets(count:2,name:"跑步",query:"run",recordingUnit:"time",trainingType:"有氧").allSatisfy { $0.durationSeconds==600 },"cardio uses existing catalog defaults")
let timer=TimerFixture()
check(timer.unchanged && timer.sessionID==nil,"first timer accepts no session before start")
timer.toggleTimer()
check(timer.unchanged && timer.sessionID != nil && timer.stopwatch.isRunning,"first start binds newly created session")
timer.toggleTimer()
check(!timer.stopwatch.isRunning && timer.error==nil,"first timer can pause")
timer.toggleTimer()
check(timer.stopwatch.isRunning && timer.store.beginCount==1,"resume never starts another workout")
timer.stopwatch=WorkoutStopwatch();timer.stopwatch.start(at:Date().addingTimeInterval(-3))
timer.saveAllowed=false;timer.registerTimedSet()
check(timer.saved==nil && !timer.dismissed && timer.error != nil && !timer.stopwatch.isRunning,"failed save retains paused timer")
timer.saveAllowed=true;timer.registerTimedSet()
check(timer.saved?.validCompletion==true && timer.dismissed,"failed save can be retried")
let failed=TimerFixture();failed.store.allowBegin=false;failed.toggleTimer()
check(!failed.stopwatch.isRunning && failed.sessionID==nil && failed.error != nil,"start persistence failure does not start clock")
let changed=TimerFixture();changed.toggleTimer();changed.store.day.activeWorkoutSessionID=UUID()
changed.stopwatch.start(at:Date().addingTimeInterval(-3));changed.registerTimedSet()
check(changed.saved==nil && changed.error != nil,"another session cannot accept stale timer")
let other=TimerFixture();other.store.editingAccountID=2;other.toggleTimer()
check(!other.stopwatch.isRunning && other.store.beginCount==0,"account switch cannot start stale timer")
let folder=FileManager.default.temporaryDirectory.appendingPathComponent("boji-v74-"+UUID().uuidString)
try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
defer { try? FileManager.default.removeItem(at:folder) }
let photos=PhotoFixture(folder);let id=UUID()
let old=ReviewPhoto(id:id,pose:"front",filename:id.uuidString.lowercased()+".jpg")
try Data("old-photo".utf8).write(to:folder.appendingPathComponent(old.filename))
var first=WeeklyReview(photos:[old],result:"completed")
let draft=WeeklyReview(photos:[old])
photos.reviews=[first,draft];try photos.persist()
try photos.addPhoto(Data("new-photo".utf8),pose:"front",to:draft.id)
check(photos.photo(old)==Data("old-photo".utf8),"replace draft preserves photo still used by older report")
let new=photos.reviews[1].photos[0]
check(photos.photo(new)==Data("new-photo".utf8),"replacement saved and readable")
try photos.removePhotos(first.id)
check(photos.photo(old)==nil && photos.photo(new) != nil,"only last old reference deletion removes old file")
let before=photos.reviews[1].photos
photos.failPersistence=true
do { try photos.addPhoto(Data("failure-photo".utf8),pose:"front",to:draft.id);fatalError("injected failure was not thrown") } catch {}
check(photos.reviews[1].photos.map(\.id)==before.map(\.id),"failed JSON persistence restores old references")
check(photos.photo(new) != nil,"failed replacement keeps existing photo")
let remaining=try FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil).filter { $0.pathExtension=="jpg" }
check(remaining.count==1,"failed replacement leaves no new orphan")
print("PASS \(checks) v74 production-rule checks. SwiftUI and device behavior still require TestFlight.")
''')
out=Path(sys.argv[1]);out.write_text('\n\n'.join(parts),encoding='utf-8')
print('Generated production Swift checks; not executed by this generator.')
