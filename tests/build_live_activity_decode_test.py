"""FIX-004 regression: decode legacy Training Activity state without new keys."""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[1]
src = (root / 'BojiClubWidget' / 'TrainingShared.swift').read_text()
start = src.index('    struct ContentState: Codable, Hashable {')
i = src.index('{', start); depth = 1; j = i + 1
while depth:
    depth += (src[j] == '{') - (src[j] == '}')
    j += 1
block = '\n'.join(line[4:] if line.startswith('    ') else line for line in src[start:j].splitlines())
code = 'import Foundation\nstruct TrainingActivityAttributes {\n' + block + r'''
}
func check(_ v: Bool, _ s: String) { if !v { fatalError(s) }; print("PASS \(s)") }
let old = #"{"workoutName":"训练","completedSets":1,"totalSets":3,"remainingSeconds":95,"restSeconds":30,"restEndsAt":null,"currentExerciseName":"卧推","currentSetNumber":2}"#.data(using:.utf8)!
let d = try JSONDecoder().decode(TrainingActivityAttributes.ContentState.self, from: old)
check(!d.isPaused, "old activity defaults to running")
check(d.pausedElapsedSeconds == nil && d.elapsedSeconds == nil, "old activity has no clock reference")
check(d.elapsedClockStart == nil, "legacy state has no running clock")

let newer = #"{"workoutName":"训练","completedSets":1,"totalSets":3,"remainingSeconds":95,"restSeconds":30,"restEndsAt":null,"isPaused":true,"pausedElapsedSeconds":95,"elapsedSeconds":95,"updatedAt":770000000}"#.data(using:.utf8)!
let p = try JSONDecoder().decode(TrainingActivityAttributes.ContentState.self, from: newer)
check(p.isPaused && p.pausedElapsedSeconds == 95, "new paused activity decodes")
check(p.elapsedClockStart == nil, "paused activity freezes the clock")

let round = try JSONDecoder().decode(TrainingActivityAttributes.ContentState.self, from: JSONEncoder().encode(p))
check(round == p, "activity state round-trips")
let runningData = #"{"workoutName":"训练","completedSets":1,"totalSets":3,"remainingSeconds":95,"restSeconds":0,"restEndsAt":null,"isPaused":false,"elapsedSeconds":95,"updatedAt":770000000}"#.data(using:.utf8)!
let running = try JSONDecoder().decode(TrainingActivityAttributes.ContentState.self, from: runningData)
check(abs((running.elapsedClockStart?.timeIntervalSinceReferenceDate ?? 0) - 769999905) < 0.001, "running clock reference subtracts elapsed time")
print("LIVE_ACTIVITY_DECODE_OK")
'''
with tempfile.TemporaryDirectory() as d:
    path = Path(d) / 'probe.swift'; path.write_text(code)
    binary = Path(d) / 'probe'
    subprocess.run(['swiftc', '-o', str(binary), str(path)], check=True)
    subprocess.run([str(binary)], check=True)
