"""Exercise the production automation caller, not only its UUID-returning rule.

Run generated Foundation/CryptoKit fixtures on macOS. Network/UI objects below
are fakes; the caller, eligible session selection, ID and history rules are real.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory() as directory:
    path = Path(directory) / 'automation.swift'
    subprocess.run([sys.executable, str(root / 'tests/build_automation_swift_tests.py'), str(path)], check=True)
    source = path.read_text('utf-8')

def block(text, marker):
    start = text.index(marker)
    opening = text.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        if text[end] == '{': depth += 1
        elif text[end] == '}': depth -= 1
        end += 1
    return text[start:end]

ai = (root / 'BojiClub/AIService.swift').read_text('utf-8')
adaptive = (root / 'BojiClub/ClubAdaptive.swift').read_text('utf-8')
service = (root / 'BojiClub/ClubAutomationService.swift').read_text('utf-8')
source += '\n' + block(ai, 'struct AIInput:')
source += '\nenum ClubAutomaticReports {\n' + block(adaptive, 'static func jobID(owner: Int, mode: String, key: String)') + '\n}\n'
source += r'''
enum AppErrorText { static func message(_ error: Error) -> String { error.localizedDescription } }
enum V107Failure: Error { case unavailable }
final class AppStore {
    var state = SavedState()
    func log(for date: Date) -> DayLog { state.days[ClubDates.key(date)] ?? DayLog() }
}
final class AIService {
    var known = Set<String>()
    var inputs: [AIInput] = []
    var sourceSessions: [UUID?] = []
    var shouldFail = false
    func job(_ id: String) -> Bool? { known.contains(id) ? true : nil }
    func coachInput(question: String, conversation: String, history: [JSONValue], through date: Date,
                    contextDays: Int, store: AppStore, sessionID: UUID? = nil) throws -> AIInput {
        sourceSessions.append(sessionID)
        return AIInput(kind: "coach", date: ClubDates.key(date), payload: ["context_days": .number(Double(contextDays))])
    }
    func submit(_ input: AIInput, submissionID: String) throws -> String {
        if shouldFail { throw V107Failure.unavailable }
        inputs.append(input); known.insert(submissionID)
        return submissionID
    }
}
final class AutomationCallerFixture {
    var owner: Int? = 71
    var settings = ClubAutomationSettings()
    var error: String?
'''
source += block(service, 'private func evaluateCoach(').replace('private func evaluateCoach(', 'func evaluateCoach(', 1)
source += '\n}\n'
source += r'''
let compileStore = AppStore()
compileStore.state.days[today] = summaryDay(on: now)
let compileSession = compileStore.state.days[today]!.activeWorkoutSessionID!
let compileCaller = AutomationCallerFixture()
compileCaller.settings.enabledFrom = today
compileCaller.settings.enabledAt = now
compileCaller.settings.workoutEnabled = true
let compileAI = AIService()
compileCaller.evaluateCoach(store: compileStore, ai: compileAI, now: summaryNow)
check(compileAI.inputs.count == 1, "actual caller accepts UUID returned by available and submits confirmed training")
check(compileAI.sourceSessions.first! == compileSession, "actual caller passes the exact session UUID into coach context")
check(compileAI.inputs[0].payload["purpose"] == JSONValue.string("workout"), "workout purpose payload has the concrete JSON value type")
check(compileAI.inputs[0].payload["source_session"] == JSONValue.string(compileSession.uuidString.lowercased()), "payload retains the UUID rather than a summary object")
compileCaller.evaluateCoach(store: compileStore, ai: compileAI, now: summaryNow)
check(compileAI.inputs.count == 1, "repeated evaluation does not generate a duplicate training report")

let compileUnconfirmed = AppStore()
compileUnconfirmed.state.days[today] = summaryDay(on: now, saved: false)
let compileUnconfirmedAI = AIService()
compileCaller.evaluateCoach(store: compileUnconfirmed, ai: compileUnconfirmedAI, now: summaryNow)
check(compileUnconfirmedAI.inputs.isEmpty, "actual caller never submits a training that was not confirmed")

let compileBeforeEnable = AppStore()
compileBeforeEnable.state.days[today] = summaryDay(on: now)
compileCaller.settings.enabledAt = now.addingTimeInterval(120)
let compileBeforeEnableAI = AIService()
compileCaller.evaluateCoach(store: compileBeforeEnable, ai: compileBeforeEnableAI, now: summaryNow)
check(compileBeforeEnableAI.inputs.isEmpty, "a workout saved before opt-in does not trigger retrospective model use")
compileCaller.settings.enabledAt = now
let compileFailAI = AIService(); compileFailAI.shouldFail = true
compileCaller.evaluateCoach(store: compileStore, ai: compileFailAI, now: summaryNow)
check(compileCaller.error != nil && compileStore.state.days[today]!.isTrainingConfirmed, "submission failure surfaces an error and preserves the saved workout")

let weeklyCaller = AutomationCallerFixture()
weeklyCaller.settings.weeklyEnabled = true
weeklyCaller.settings.enabledFrom = "2026-10-05"
let weeklyStore = AppStore()
let weeklyNow = ClubDates.date(fromKey: "2026-10-19")!
for key in ["2026-10-13", "2026-10-15"] {
    weeklyStore.state.days[key] = summaryDay(on: ClubDates.date(fromKey: key)!)
}
let weeklyAI = AIService()
weeklyCaller.evaluateCoach(store: weeklyStore, ai: weeklyAI, now: weeklyNow)
check(weeklyAI.inputs.count == 1 && weeklyAI.inputs[0].payload["purpose"] == JSONValue.string("weekly"), "weekly branch still submits when two confirmed dates meet the rule")
check(weeklyAI.inputs[0].date == "2026-10-18" && weeklyAI.inputs[0].payload["context_days"] == JSONValue.number(14), "weekly report keeps a seven-day scope and fourteen-day comparison context")

// Preserve exact date and UUID tie ordering after replacing overloaded chains.
var tieState = SavedState()
var lowerProfile = tieState.profile; lowerProfile.goal = "低编号"
var higherProfile = tieState.profile; higherProfile.goal = "高编号"
let lowerGoal = ClubGoalVersion(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, recordedAt: now, profile: lowerProfile.aiProfile, nutrition: initialTarget)
let higherGoal = ClubGoalVersion(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, recordedAt: now, profile: higherProfile.aiProfile, nutrition: initialTarget)
tieState.days[today] = DayLog()
tieState.days[today]!.goalVersions = [higherGoal, lowerGoal]
check(ClubHistoryRules.profile(on: now, days: tieState.days)?.goal == "高编号", "historical profile preserves deterministic UUID tie breaking")
let tieContext = ClubAIContext.make(state: tieState, start: now, end: now, now: summaryNow)
check(tieContext.days[0].goalVersionID == higherGoal.id.uuidString.lowercased(), "AI context uses the same deterministic goal ordering")
check(ClubHistoryRules.recordGoal(days: &tieState.days, profile: higherProfile, nutrition: initialTarget, now: now) == nil, "same target is not duplicated after explicit latest-version selection")
print("PASS Build 107 actual automation caller and history regression checks; combined assertions: \(tests)")
'''
Path(sys.argv[1]).write_text(source, 'utf-8')
