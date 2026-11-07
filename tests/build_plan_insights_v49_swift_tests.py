"""Generate Foundation tests against production rationale, cycle, and Codable rules.

Run on macOS; generation or syntax parsing alone is not a Swift compile/test pass.
"""
from pathlib import Path
import runpy
import sys
out = Path(sys.argv[1])
runpy.run_path(str(Path(__file__).with_name('build_repair_v46_swift_tests.py')))
root = Path(__file__).resolve().parents[1]
source = (root / 'BojiClub/PlanExplanation.swift').read_text('utf-8')
rules = source[source.index('enum PlanExplanationRules'):source.index('struct PlanExplanationCard')]
code = out.read_text('utf-8') + '\n' + rules
code += r'''
do {
    let beginning = checks
    let legacy = try JSONDecoder().decode(AIResult.self, from: Data("{\"kind\":\"plan\",\"notes\":[],\"sessions\":[]}".utf8))
    check(legacy.explanation == nil, "legacy result decodes without reasons")
    let legacyCycle = try JSONDecoder().decode(TrainingCycle.self, from: Data("{\"start\":\"2026-10-11\",\"plannedDates\":[\"2026-10-11\"]}".utf8))
    check(legacyCycle.sourceJobID == nil && legacyCycle.explanationVersion == nil, "legacy cycle decodes without source")
    let reason = AIPlanReason(id: "body", title: "身体背景", basis: "生成时的资料", detail: "身高体重不能代替体能评估。")
    let purpose = AIPlanPurpose(date: today, purpose: "建立基础推拉记录。")
    let explanation = AIPlanExplanation(version: 1, summary: ["目标", "日期", "器械"], sections: [reason], sessions: [purpose])
    var result = legacy; result.explanation = explanation
    check(try JSONDecoder().decode(AIResult.self, from: JSONEncoder().encode(result)) == result, "new result roundtrips explanation")
    let profile = MemberProfile()
    let snapshot = try JSONValue.encode(profile.aiProfile)
    check(PlanExplanationRules.profileDiffers(snapshot, from: profile) == false, "unchanged profile has no stale warning")
    var updated = profile; updated.weight += 1
    check(PlanExplanationRules.profileDiffers(snapshot, from: updated) == true, "weight change is compared with original snapshot")
    updated = profile; updated.goal = "不同的目标"
    check(PlanExplanationRules.profileDiffers(snapshot, from: updated) == true, "goal change is compared with original snapshot")
    updated = profile; updated.nickname = "新昵称"
    check(PlanExplanationRules.profileDiffers(snapshot, from: updated) == false, "nickname does not change training rationale")
    check(PlanExplanationRules.profileDiffers(nil, from: profile) == nil, "missing snapshot cannot imply an unchanged profile")
    let movement = AIPlanExercise(name: "俯卧撑", muscle: "胸", sets: [AIPlanSet(weight: nil, reps: 10)], library_query: "push up", library_id: "fixture")
    let session = AIPlanSession(date: today, label: "基础训练", exercises: [movement])
    var actual = session; actual.exercises[0].sets[0].weight = 25
    check(PlanExplanationRules.sameStructure([session], [actual]), "entering actual load does not replace the AI prescription")
    actual.exercises[0].sets[0].reps = 12
    check(!PlanExplanationRules.sameStructure([session], [actual]), "changed repetitions invalidate class purpose")
    actual = session; actual.exercises[0].sets.append(AIPlanSet(weight: nil, reps: 10))
    check(!PlanExplanationRules.sameStructure([session], [actual]), "changed set count invalidates class purpose")
    actual = session; actual.exercises[0].library_id = "different"
    check(!PlanExplanationRules.sameStructure([session], [actual]), "replacement movement invalidates class purpose")
    actual = session; actual.exercises[0].sets[0].durationSeconds = 30
    check(!PlanExplanationRules.sameStructure([session], [actual]), "changed recording unit invalidates class purpose")
    actual = session; actual.date = ClubDates.key(tomorrow)
    check(!PlanExplanationRules.sameStructure([session], [actual]), "moved class is not explained by the old date")
    var two = session; var other = movement; other.name = "深蹲"; other.library_id = "squat"; two.exercises.append(other)
    actual = two; actual.exercises.reverse()
    check(!PlanExplanationRules.sameStructure([two], [actual]), "changed movement order invalidates purpose")
    check(!PlanExplanationRules.sameStructure([session], []), "removed class cannot keep a matching purpose")
    let exercise = Exercise(name: "俯卧撑", muscle: "胸", sets: [TrainingSet(weight: 20, reps: 10, completed: true)], libraryID: "fixture", libraryQuery: "push up")
    check(PlanExplanationRules.sameStructure([session], [PlanExplanationRules.session(date: today, exercises: [exercise])]), "completion and actual weight preserve prescription identity")
    var days = [today: DayLog(exercises: [exercise])]
    let touched = TrainingCycle.stamp(days: &days, start: now, plannedDates: [today], sourceJobID: "source-49")
    check(touched.count == 7 && touched.allSatisfy { days[$0]?.planCycle?.sourceJobID == "source-49" }, "source is stamped across the full cycle atomically")
    let cycle = days[today]!.planCycle!
    check(cycle.explanationVersion == 1, "new cycle marks support for source preservation")
    check(PlanExplanationRules.sameStructure([session], PlanExplanationRules.sessions(in: cycle, days: days)), "saved cycle reconstructs matching original prescription")
    days[today]!.exercises[0].sets[0].reps = 11
    check(!PlanExplanationRules.sameStructure([session], PlanExplanationRules.sessions(in: cycle, days: days)), "saved changes produce original-scheme notice")
    _ = TrainingCycle.stamp(days: &days, start: now, plannedDates: [today])
    check(days[today]?.planCycle?.sourceJobID == nil && days[today]?.planCycle?.explanationVersion == 1, "continuing or replacing the week explicitly clears AI origin")
    check(PlanExplanationRules.notice(profileChanged: false, planChanged: false) == nil, "original plan needs no warning")
    check(PlanExplanationRules.notice(profileChanged: true, planChanged: false)?.contains("个人资料") == true, "changed profile explanation stays historical")
    check(PlanExplanationRules.notice(profileChanged: false, planChanged: true)?.contains("原方案") == true, "modified plan explanation stays historical")
    check(PlanExplanationRules.notice(profileChanged: nil, planChanged: false) != nil, "unknown snapshot is explained")
    print("PASS \(checks-beginning) additional v49 production rationale checks")
}
'''
out.write_text(code, 'utf-8')
print('v49 harness generated; execute on Mac to validate production Swift rules')
