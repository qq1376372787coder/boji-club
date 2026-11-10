from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
def declaration(file, marker):
    source = (root / 'BojiClub' / file).read_text(encoding='utf-8')
    start = source.index(marker)
    opening = source.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

types = '\n\n'.join([
    declaration('Models.swift', 'struct MemberProfile:'),
    # The standalone fixture has no app module boundary; normalize visibility
    # so its top-level fixture constants can refer to the extracted type.
    declaration('OnboardingView.swift', 'private struct OnboardingDraft:').replace('private struct OnboardingDraft:', 'struct OnboardingDraft:', 1),
    declaration('JourneyRules.swift', 'enum CloudAnalysisConsent {'),
])
tests = r'''
var passed = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message); passed += 1; print("PASS \(message)")
}
var profile = MemberProfile()
profile.nickname = "测试新成员"; profile.goal = "减脂瘦身"; profile.experience = "有基础"; profile.focus = "背部、核心"
let draft = OnboardingDraft(profile: profile, step: 4, planMode: "generate_plan", covenantAccepted: false, planApplied: false,
    flowVersion: 5, weightDateKey: "2026-10-11", registerStartingWeight: true, skipPlan: false,
    conditionSection: 1, identitySection: 1, weightSource: "今天刚称", goalSection: 1)
let bytes = try JSONEncoder().encode(draft)
let restored = try JSONDecoder().decode(OnboardingDraft.self, from: bytes)
check(restored.profile == profile, "draft preserves all training preferences")
check(restored.restoredStep == 4, "v5 retains independent covenant page")
check(restored.restoredGoalSection == 1, "restart resumes training preferences rather than skipping them")
var old = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
old["flowVersion"] = 4; old.removeValue(forKey: "goalSection")
let legacy = try JSONDecoder().decode(OnboardingDraft.self, from: JSONSerialization.data(withJSONObject: old))
check(legacy.restoredStep == 4, "v4 covenant is not mapped to confirmation")
check(legacy.restoredGoalSection == 0 && legacy.profile == profile, "old draft without substep keeps profile and starts goal selection")
var invalid = restored
invalid.goalSection = Int.max; invalid.step = Int.max
check(invalid.restoredGoalSection == 1 && invalid.restoredStep == 4, "out of range current draft cannot index a missing page")
invalid.goalSection = -2; invalid.step = -1
check(invalid.restoredGoalSection == 0 && invalid.restoredStep == 0, "negative current draft positions normalize")
invalid.flowVersion = 3; invalid.step = 7
check(invalid.restoredStep == 3, "v3 last page migrates safely")
invalid.flowVersion = nil; invalid.step = Int.max
check(invalid.restoredStep == 3, "legacy eight step draft is safely bounded")
let suite = "boji-onboarding-v52-" + UUID().uuidString
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
check(!CloudAnalysisConsent.allowed(accountID: 51, defaults: defaults), "cloud analysis remains disabled until this account opts in")
check(!CloudAnalysisConsent.hasDecision(accountID: 51, defaults: defaults), "default does not pretend the user changed the setting")
CloudAnalysisConsent.set(true, accountID: 51, defaults: defaults)
check(CloudAnalysisConsent.allowed(accountID: 51, defaults: defaults), "explicit enabled setting remains readable")
check(CloudAnalysisConsent.hasDecision(accountID: 51, defaults: defaults), "explicit setting is remembered")
check(!CloudAnalysisConsent.allowed(accountID: 52, defaults: defaults), "cloud analysis remains disabled until this account opts in")
CloudAnalysisConsent.set(false, accountID: 51, defaults: defaults)
check(!CloudAnalysisConsent.allowed(accountID: 51, defaults: defaults), "privacy setting can disable cloud analysis for one account")
check(CloudAnalysisConsent.hasDecision(accountID: 51, defaults: defaults), "disabled setting survives the next login")
check(!CloudAnalysisConsent.allowed(accountID: 52, defaults: defaults), "cloud analysis remains disabled until this account opts in")
CloudAnalysisConsent.set(true, accountID: 0, defaults: defaults)
check(!CloudAnalysisConsent.allowed(accountID: nil, defaults: defaults) && !CloudAnalysisConsent.allowed(accountID: 0, defaults: defaults), "signed out or invalid owner cannot grant analysis")
print("ALL \(passed) ONBOARDING V52 RULE CHECKS PASSED")
'''
out = Path(sys.argv[1])
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text('import Foundation\n\n' + types + '\n\n' + tests, encoding='utf-8')
print(str(out))
