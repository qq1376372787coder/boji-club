"""Extract the production measurement rules for a Foundation-only Mac Swift check."""
from pathlib import Path
import sys,json
root=Path(__file__).resolve().parents[1]
source=(root/'BojiClub/DailyExperience.swift').read_text(encoding='utf-8')
start=source.index('enum ExerciseMeasurement {');end=source.index('\nstruct BodyWeightEntry:',start)
rules=source[start:end]
model='''import Foundation
struct AIPlanSet { var weight: Double?; var reps: Int; var durationSeconds: Int? }
struct TrainingSet {
 var reps = 10
 var durationSeconds: Int? = nil
 var completed = false
}
func check(_ value: Bool, _ label: String) { precondition(value,label); print("PASS " + label) }
'''
rows=json.loads((root/'exercise-server/exercise-catalog.json').read_text(encoding='utf-8'))
checks=''
for x in rows:
 checks+='check(ExerciseMeasurement.usesSeconds(name: '+json.dumps(x['name_zh'],ensure_ascii=False)+', query: '+json.dumps(x['name'],ensure_ascii=False)+') == '+('true' if x['suggested_recording_unit']=='time' else 'false')+', '+json.dumps(x['id'])+')\n'
checks+='''
let running = ExerciseMeasurement.initialSets(name:"跑步",query:"run")
check(running.count == 1 && running[0].durationSeconds == 600 && running[0].reps == 0 && !running[0].completed,"aerobic duration starts as one unfinished target")
let squat = ExerciseMeasurement.initialSets(name:"徒手深蹲",query:"bodyweight squat")
check(squat.count == 3 && squat.allSatisfy{$0.durationSeconds == nil && $0.reps == 10 && !$0.completed},"strength starts as three unfinished groups")
let remote = ExerciseMeasurement.initialSets(name:"新有氧项目",query:"future cardio",recordingUnit:"time",trainingType:"有氧")
check(remote.count == 1 && remote[0].durationSeconds == 600,"new remote cardio metadata works without guessing")
let counted = ExerciseMeasurement.initialSets(name:"新计次动作",query:"future counted",recordingUnit:"reps",trainingType:"力量／稳定性")
check(counted.count == 3 && counted.allSatisfy{$0.durationSeconds == nil},"explicit server reps stay counted")
'''
Path(sys.argv[1]).write_text(model+rules+checks,encoding='utf-8')
print('Prepared 682 checks from actual production measurement rules; run with xcrun swift on Mac.')
