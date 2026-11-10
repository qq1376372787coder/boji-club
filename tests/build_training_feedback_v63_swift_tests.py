"""Run actual Foundation model/capture/session rules on Mac, without mocking the rules."""
from pathlib import Path
import sys, subprocess, tempfile
root=Path(__file__).resolve().parents[1]
models=(root/'BojiClub/Models.swift').read_text(encoding='utf-8')
daily=(root/'BojiClub/DailyExperience.swift').read_text(encoding='utf-8')
actual=models[models.index('struct TrainingSet:'):models.index('struct MemberProfile:')]
rules=daily[daily.index('enum TrainingExecutionCapture {'):daily.index('// A confirmation belongs')]
service=(root/'BojiClub/AIService.swift').read_text(encoding='utf-8')
jsonvalue=service[service.index('enum JSONValue:'):service.index('struct AIInput:')]
store=(root/'BojiClub/AppStore.swift').read_text(encoding='utf-8')
start=store.index('private func validateBackupValue(')
backup=store[start:store.index('@MainActor',start)].replace('private func validateBackupValue(', 'func validateBackupValue(')
stubs='''import Foundation
enum ExerciseNames { static func display(_ name: String,id: String? = nil,query: String? = nil) -> String { name } }
enum ClubDates { static var calendar: Calendar { Calendar(identifier:.gregorian) } }
struct FoodComponent: Codable { }
struct HealthWorkout: Codable { var id: String }
struct HealthDay: Codable { var workouts: [HealthWorkout] = [] }
struct WeeklyReview: Codable { }
struct NutritionTarget: Codable { }
struct BodyWeightEntry: Codable { }
struct TrainingCycle: Codable { }
struct MealCompletion: Codable { var signature: String; static func signature(_ meals: [Meal]) -> String { "fixture" } }
enum CloudSyncError: Error { case message(String) }
var checks = 0
func check(_ value: Bool,_ label: String) { precondition(value,label); checks += 1; print("PASS " + label) }
'''
tests=r'''
var checks = 0
func check(_ value: Bool, _ label: String) { precondition(value, label); checks += 1; print("PASS \(label)") }
let today=Date()
let movement=Exercise(name:"测试动作",muscle:"核心",sets:[TrainingSet(reps:0,durationSeconds:600),TrainingSet(reps:10),TrainingSet(reps:10)])
let blank=DayLog(exercises:[movement])
var started=blank;started.workoutStartedAt=today
TrainingExecutionCapture.capture(before:blank,after:&started,on:today)
WorkoutSessions.synchronize(&started)
check(started.workoutSessions?.count == 1,"first start initializes session")
let original=started.workoutSessions!.first!.executionBaseline!
check(original.sets.count == 3 && original.sets[0].targetSeconds == 600,"capture records pre-training targets")
check(original.sets[0].id == movement.sets[0].id && original.sets[0].exerciseID == movement.id,"target references actual set and exercise identities")
check(started.workoutSessions!.first!.startedAt == today,"start timestamp preserved")
var edited=started;edited.exercises[0].sets.removeLast()
TrainingExecutionCapture.capture(before:started,after:&edited,on:today)
check(edited.workoutSessions!.first!.executionBaseline == original,"deletion never rewrites baseline")
var direct=blank;direct.exercises[0].sets[0].durationSeconds=60;direct.exercises[0].sets[0].completed=true
TrainingExecutionCapture.capture(before:blank,after:&direct,on:today)
check(direct.workoutSessions!.first!.executionBaseline!.sets[0].targetSeconds == 600,"first completion captures before actual duration replaces target")
var old=blank;old.workoutStartedAt=today.addingTimeInterval(-60);var changed=old;changed.exercises[0].sets[0].completed=true
TrainingExecutionCapture.capture(before:old,after:&changed,on:today)
check(changed.workoutSessions?.isEmpty != false,"pre-upgrade started workout is not backfilled")
var history=blank;history.exercises[0].sets[0].completed=true
let yesterday=ClubDates.calendar.date(byAdding:.day,value:-1,to:today)!
TrainingExecutionCapture.capture(before:blank,after:&history,on:yesterday)
check(history.workoutSessions?.isEmpty != false,"historical training does not invent a capture")
var swapped=blank;swapped.activeWorkoutSessionID=UUID();swapped.workoutStartedAt=today
TrainingExecutionCapture.capture(before:blank,after:&swapped,on:today)
check(swapped.workoutSessions?.isEmpty != false,"switching sessions never captures another session's targets")
var copied=started;let nextID=UUID();copied.workoutSessions!.append(WorkoutSession(id:nextID));copied.activeWorkoutSessionID=nextID;WorkoutSessions.restoreActiveFields(&copied)
check(copied.workoutSessions!.last!.executionBaseline == nil,"new session starts without previous baseline")
let data=try JSONEncoder().encode(started);let restored=try JSONDecoder().decode(DayLog.self,from:data)
check(restored.workoutSessions!.first!.executionBaseline == original,"capture survives Codable persistence")
let legacy=try JSONDecoder().decode(WorkoutSession.self,from:Data(("{\"id\":\""+UUID().uuidString+"\"}").utf8))
check(legacy.executionBaseline == nil,"legacy session remains decodable")
let green=TrainingFeedback(version:1,status:"green",reason:"target_completed",evidence:["已完成"],next_step:"保持")
check(green.presentation.title == "执行到位","known green label")
let future=TrainingFeedback(version:2,status:"green",reason:"future",evidence:[],next_step:"")
check(future.presentation.status == "gray","unsupported future schema cannot manufacture green")
let rest=TrainingFeedback(version:1,status:"gray",reason:"rest_day",evidence:[],next_step:"")
check(rest.title == "按计划休息","rest day is not labeled bad training")
var altered=started;altered.workoutSessions![0].executionBaseline!.sets.removeLast()
TrainingExecutionCapture.reconcile(&altered,base:started,local:started,remote:altered)
check(altered.workoutSessions![0].executionBaseline == original,"whole-object merge cannot shorten committed targets")
var omitted=started;omitted.workoutSessions![0].executionBaseline=nil
TrainingExecutionCapture.reconcile(&omitted,base:started,local:started,remote:omitted)
check(omitted.workoutSessions![0].executionBaseline == original,"old device omission preserves original targets")
try validateBackupValue(JSONValue.encode(started))
check(true,"backup accepts persisted capture timestamp")
do { try validateBackupValue(.number(812000000),key:"weight"); check(false,"weight cannot use timestamp bounds") } catch { check(true,"non-date backup fields keep numeric protection") }
print("Training feedback rules passed: \(checks)")
'''
# Reuse the real model dependency graph instead of stale empty Codable stubs.
with tempfile.TemporaryDirectory() as directory:
    base = Path(directory) / 'base.swift'
    subprocess.run([sys.executable, str(Path(__file__).with_name('build_phase1_swift_tests.py')), str(base)], check=True, stdout=subprocess.DEVNULL)
    preamble = base.read_text('utf-8').split('\nfinal class AppStore {', 1)[0]
Path(sys.argv[1]).write_text(preamble + "\n" + backup + tests, encoding='utf-8')
print('Prepared 19 tests using production snapshot, session and backup rules. Execute with xcrun swift on Mac.')
