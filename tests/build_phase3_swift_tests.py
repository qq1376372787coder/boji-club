"""Execute actual Foundation rules; does not compile SwiftUI or HealthKit.

AUD-007/FIX-007: this generator used to inherit the entire phase-2 AppStore
fixture and every AppStore extension, so each new model member broke the
compile even though the phase-3 assertions only cover review, reward and report
rules. It now reuses the phase-1 model/rules preamble up to the fixture class
and adds only the production rules it actually exercises. The iOS build remains
the authority for full app compilation.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = Path(sys.argv[1])


def read(name):
    return (ROOT / 'BojiClub' / name).read_text('utf-8')


def method(source, name):
    import re
    match = re.search(r'^    (?:private )?func ' + re.escape(name) + r'\(', source, re.M)
    assert match, name
    opening = source.index('{', match.start())
    depth = 1
    end = opening + 1
    while depth:
        if source[end] == '{': depth += 1
        elif source[end] == '}': depth -= 1
        end += 1
    return source[match.start():end].replace('private func mutate', 'func mutate')


# Older generators load this module and expect a nested helper table.
module = {'read': read, 'method': method}


# Direct phase-3 runs use the focused model fixture. Historical callers need
# the phase-2 AppStore fixture as well; retain their original assertions.
inherited = __name__ != '__main__'
with tempfile.TemporaryDirectory() as directory:
    generated = Path(directory) / 'base.swift'
    parent = 'build_phase2_swift_tests.py' if inherited else 'build_phase1_swift_tests.py'
    subprocess.run([sys.executable, str(Path(__file__).with_name(parent)), str(generated)],
                   check=True, stdout=subprocess.DEVNULL)
    full = generated.read_text('utf-8')
code = full if inherited else full[:full.index('\nfinal class AppStore {')]
weekly = read('WeeklyReview.swift')
if 'struct WeeklyResult:' not in code:
    code += '\n' + weekly[weekly.index('struct WeeklyResult:'):weekly.index('struct WeeklyReview:')]
club = read('ClubSeason.swift')
code += '\n' + club[club.index('struct ClubSeason:'):club.index('@MainActor')]
if not inherited:
    code += '\nfinal class ReportInputBuilder {\n' + method(read('AIService.swift'), 'reportInput') + '\n}\n'
    code += r'''
var checks = 0
func check(_ value: Bool, _ label: String) {
    guard value else { fatalError("FAILED: \(label)") }
    checks += 1
    print("PASS \(label)")
}
let now = Date()
func meal(_ category: String) -> Meal {
    Meal(name: "fixture", category: category, calories: 100, protein: 10, carbs: 10, fat: 2)
}
let builder = ReportInputBuilder()
'''

code += r'''
do {
let phaseThreeStart = checks
let noData = ReviewMetrics(logs:[])
check(noData.plannedSets == 0 && noData.completedSets == 0,"empty review has no training")
check(noData.averageCalories == nil && noData.averageProtein == nil,"empty nutrition is unknown, not zero")
check(noData.completionLabel == "—","empty review does not show a fabricated percentage")
let partial = DayLog(exercises:[Exercise(name:"测试",muscle:"全身",sets:[TrainingSet(weight:20,reps:5,completed:true),TrainingSet(weight:20,reps:5)])],meals:[meal("早餐")])
let totals = ReviewMetrics(logs:[DayLog(),partial])
check(totals.plannedSets == 2 && totals.completedSets == 1 && totals.remainingSets == 1,"partial plan donut preserves denominator")
check(totals.trainingDays == 1 && totals.finishedDays == 0,"partial and fully finished training days differ")
check(totals.completionLabel == "50%","half the valid groups equals fifty percent")
check(totals.averageCalories == 100 && totals.averageProtein == 10,"unlogged days excluded from food average")
check(totals.mealDays == 1 && totals.meals == 1,"meals and recorded days kept separately")
let fullDay=DayLog(exercises:[Exercise(name:"保持",muscle:"核心",sets:[TrainingSet(weight:10,reps:0,completed:true,durationSeconds:30)])])
let fullMetrics=ReviewMetrics(logs:[fullDay])
check(fullMetrics.finishedDays == 1 && fullMetrics.completionLabel == "100%","timed valid set counts as completed")
check(fullDay.volume == 0,"timed set does not fabricate kilograms")
let invalidDay=DayLog(exercises:[Exercise(name:"无效保持",muscle:"核心",sets:[TrainingSet(weight:0,reps:0,completed:true,durationSeconds:0)])])
check(ReviewMetrics(logs:[invalidDay]).completedSets == 0,"invalid checked set does not inflate completion")
let legacyRewardData=Data(#"{"id":1,"title":"Old","detail":"old","type":"badge","icon":"seal","unlocked":true}"#.utf8)
let oldReward=try JSONDecoder().decode(ClubSeasonReward.self,from:legacyRewardData)
check(oldReward.taskID == nil && oldReward.unlockScope == nil,"old reward JSON remains compatible")
var taskReward=oldReward;taskReward.taskID=7;taskReward.unlockScope="task"
let physical=ClubSeasonReward(id:2,title:"Gift",detail:"all tasks",type:"physical",icon:"gift",unlocked:false,claimStatus:nil,trackingCompany:nil,trackingNumber:nil,taskID:7,unlockScope:"season")
var other=oldReward;other.taskID=8;other.unlockScope="task"
let rewards=[taskReward,physical,other,oldReward]
check(ClubRewardGrouping.taskRewards(rewards,taskID:7).count == 1,"physical all-tasks reward never appears as a single-task reward")
check(ClubRewardGrouping.taskRewards(rewards,taskID:99).isEmpty,"unmatched task does not steal a reward")
check(ClubRewardGrouping.finale(rewards).count == 1,"physical reward is a season finale")
check(ClubRewardGrouping.unlinked(rewards,taskIDs:[7]).count == 2,"old and orphan reward stays visible")
let oldCollection=try JSONDecoder().decode(ClubCollectedReward.self,from:Data(#"{"id":1,"title":"Old","icon":"seal","reward_type":"badge","season_title":"Season","slug":"old"}"#.utf8))
check(oldCollection.detail == nil,"legacy collection accepts absent description")
let newCollection=try JSONDecoder().decode(ClubCollectedReward.self,from:Data(#"{"id":1,"title":"New","detail":"Official description","icon":"seal","reward_type":"badge","season_title":"Season","slug":"new"}"#.utf8))
check(newCollection.detail == "Official description","collection preserves official detail")
let dailyRaw:JSONValue = .object(["kind":.string("report"),"notes":.array([]),"summary":.string(String(repeating:"据记录分析。\n",count:200)),"training":.string("实际训练"),"nutrition":.string("实际饮食"),"recovery":.string("恢复")])
let longResult=try JSONDecoder().decode(AIResult.self,from:JSONEncoder().encode(dailyRaw))
check(longResult.summary?.count == 1400,"long report decodes in the actual app model")
let longRoundtrip=try JSONDecoder().decode(AIResult.self,from:JSONEncoder().encode(longResult))
check(longRoundtrip.summary == longResult.summary,"long report persistence has no truncation")
let versionedInput=try builder.reportInput(date:now,log:partial)
check(versionedInput.payload["analysis_version"] == .number(2),"new analysis does not match an old short report")
let weeklyLong=WeeklyResult(kind:"weekly_review",summary:longResult.summary!,training:longResult.summary!,nutrition:"实际饮食",recovery:"恢复",appearance:"无照片",photoFeedback:[],decision:"keep",reason:longResult.summary!,notes:[],sessions:[])
let weeklyRoundtrip=try JSONDecoder().decode(WeeklyResult.self,from:JSONEncoder().encode(weeklyLong))
check(weeklyRoundtrip.summary == weeklyLong.summary && weeklyRoundtrip.reason == weeklyLong.reason,"actual weekly model retains detailed analysis")
check(weeklyRoundtrip.sessions.isEmpty && weeklyRoundtrip.decision == "keep","long analysis does not imply an unconfirmed plan change")
print("PASS \(checks-phaseThreeStart) phase3 production Swift rule checks")
}
'''
OUTPUT.write_text(code, 'utf-8')
print('Added actual phase3 review, badge grouping and long report tests')
