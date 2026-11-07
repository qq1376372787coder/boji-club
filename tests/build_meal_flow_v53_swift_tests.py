from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
source = (root / 'BojiClub/JourneyRules.swift').read_text(encoding='utf-8')

def declaration(marker):
    start = source.index(marker)
    opening = source.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

types = '\n\n'.join([
    declaration('enum MealRecognitionReviewPolicy {'),
    declaration('struct RecordedCalorieProgress:'),
])
tests = r'''
var passed = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message); passed += 1; print("PASS \(message)")
}
func intake(_ recorded: Double, _ upper: Double = 2000, _ known: Int = 1, _ unknown: Int = 0) -> RecordedCalorieProgress {
    RecordedCalorieProgress(recorded: recorded, upperBound: upper, knownMeals: known, unknownMeals: unknown)
}
let partial = intake(500)
check(partial.fraction == 0.25 && !partial.exceedsUpperBound, "recorded intake uses reference upper bound")
let exact = intake(2000)
check(exact.fraction == 1 && !exact.exceedsUpperBound && exact.excess == 0, "exactly at upper bound is not over target")
let over = intake(2400)
check(over.fraction == 1 && over.exceedsUpperBound && over.excess == 400, "over target is clamped visually while retaining excess")
let empty = intake(0, 2000, 0)
check(empty.fraction == 0 && !empty.hasKnownIntake, "no meals must not imply measured zero intake")
let unknownOnly = intake(0, 2000, 0, 2)
check(unknownOnly.isIncomplete && !unknownOnly.hasKnownIntake && unknownOnly.fraction == 0, "unknown-only meals do not become zero-calorie intake")
let mixed = intake(500, 2000, 1, 2)
check(mixed.isIncomplete && mixed.fraction == 0.25, "mixed record progress includes only known meals")
check(intake(0).hasKnownIntake, "explicit known zero remains distinct from missing meals")
check(!intake(500, 0).hasValidTarget && intake(500, 0).fraction == 0, "zero target cannot divide by zero")
check(!intake(500, -100).hasValidTarget && intake(500, -100).fraction == 0, "negative target cannot make a misleading progress")
check(!intake(500, .nan).hasValidTarget && intake(500, .nan).fraction == 0, "NaN target cannot enter progress UI")
check(!intake(500, .infinity).hasValidTarget && intake(500, .infinity).fraction == 0, "infinite target cannot enter progress UI")
check(!intake(.nan).hasKnownIntake && intake(.nan).fraction == 0, "NaN intake cannot enter progress UI")
check(!intake(.infinity).hasKnownIntake && !intake(.infinity).exceedsUpperBound, "infinite intake cannot trigger a false over-target warning")
check(!intake(-1).hasKnownIntake && intake(-1).fraction == 0, "negative intake is not displayed as progress")
check(!MealRecognitionReviewPolicy.requiresConfirmation(dateChanged: false, categoryChanged: false, replacesExisting: false), "new same-date same-category recognition starts directly")
check(MealRecognitionReviewPolicy.requiresConfirmation(dateChanged: true, categoryChanged: false, replacesExisting: false), "inferred historical date is confirmed")
check(MealRecognitionReviewPolicy.requiresConfirmation(dateChanged: false, categoryChanged: true, replacesExisting: false), "inferred meal category is confirmed")
check(MealRecognitionReviewPolicy.requiresConfirmation(dateChanged: false, categoryChanged: false, replacesExisting: true), "replacing manually edited nutrition requires confirmation")
print("ALL \(passed) MEAL FLOW V53 RULE CHECKS PASSED")
'''
output = Path(sys.argv[1])
output.parent.mkdir(parents=True, exist_ok=True)
output.write_text('import Foundation\n\n' + types + '\n\n' + tests, encoding='utf-8')
print(str(output))
