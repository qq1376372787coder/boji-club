"""Exercise actual Foundation stage logic; this harness must be executed on a Mac."""
from pathlib import Path
import runpy, sys
out = Path(sys.argv[1])
runpy.run_path(str(Path(__file__).with_name('build_experience_v43_swift_tests.py')))
s = out.read_text('utf-8')
s += r'''
do {
    let beginning = checks
    check(AIWaitPhase(status:"pending") == .submitting, "local pending cannot claim server receipt")
    check(AIWaitPhase(status:"submitting").completedStages == 0, "submission has no acknowledged completed stage")
    check(AIWaitPhase(status:"queued").completedStages == 1, "queue means the server accepted input")
    check(AIWaitPhase(status:"queued").activeStage == 1, "queue cannot claim AI processing")
    check(AIWaitPhase(status:"running").activeStage == 2, "processing only follows actual running state")
    check(AIWaitPhase(status:"running").completedStages == 2, "running never claims completion")
    check(AIWaitPhase(status:"retrying").activeStage == 1, "scheduled retry is a wait, not active model processing")
    check(AIWaitPhase(status:"retrying").message.contains("等待自动重试"), "retry does not promise immediate execution")
    check(!AIWaitPhase(status:"waiting_connection").isActive, "network interruption pauses activity")
    check(!AIWaitPhase(status:"waiting_connection").showsStages, "interruption must not invent the last known server stage")
    check(AIWaitPhase(status:"waiting_connection").completedStages == 0, "offline recovery has no fabricated progress")
    check(AIWaitPhase(status:"succeeded").completedStages == 4, "only actual success completes all stages")
    check(!AIWaitPhase(status:"succeeded").isActive, "completion stops loading animation")
    for status in ["draft","failed","deleted","expired","rejected","discarded"] {
        check(!AIWaitPhase(status:status).isActive && !AIWaitPhase(status:status).showsStages,
              "stopped or unstarted task never displays a running stage: \(status)")
    }
    check(!AIWaitPhase(status:"future_state").showsStages, "unknown server state does not fabricate milestones")
    check(AIWaitPhase(status:nil) == .unknown, "absent state uses neutral waiting feedback")
    for status in ["pending","queued","running","retrying"] {
        let phase = AIWaitPhase(status:status)
        check(phase.isActive && (0...2).contains(phase.activeStage ?? -1), "valid active stage index: \(status)")
    }
    print("PASS \(checks - beginning) additional v44 production waiting checks")
}
'''
out.write_text(s, 'utf-8')
print('v44 production stage checks generated; execute on Mac to confirm')
