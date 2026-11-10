from pathlib import Path
import subprocess,sys,tempfile
root=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory() as tmp:
    source=Path(tmp)/'manual.swift'
    subprocess.run([sys.executable,str(root/'tests/build_manual_plan_swift_tests.py'),str(source)],check=True)
    content=source.read_text('utf-8')
def block(s,marker):
    start=s.index(marker);i=s.index('{',start);depth=1;j=i+1
    while depth:
        if s[j]=='{':depth+=1
        elif s[j]=='}':depth-=1
        j+=1
    return s[start:j]
app=(root/'BojiClub/AppStore.swift').read_text('utf-8')
journey=(root/'BojiClub/JourneyRules.swift').read_text('utf-8')
extra=[r'''
enum CloudMerge {
    static func same<T:Encodable>(_ lhs:T,_ rhs:T) throws -> Bool {
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        return try encoder.encode(lhs)==encoder.encode(rhs)
    }
}
extension PlanAdoptionRules {
''',block(journey,'static func sameTraining('),'}',r'''
final class FixtureJobService {
    struct Request { let kind: String }
    struct Job { let request: Request }
    func job(_ id:String)->Job? { nil }
}
final class AdoptionFixture {
    var state=SavedState();var message:String?;var writesAllowed=true
    var aiService:FixtureJobService?
    func historyProfile(jobID:String?)->MemberProfile { state.profile }
    func hasAppliedAIJob(_ id:String)->Bool { state.appliedAIJobs?.contains(id)==true }
    func persist(changedDates:[String])->Bool { writesAllowed }
''',block(app,'private func stableID(').replace('private func','func'),block(app,'private func recordPlanHistory(').replace('private func','func'),block(app,'func applyAIPlan('),'}']
extra.append(r'''
var historyState = SavedState()
let initialTarget = NutritionTarget.estimate(historyState.profile)
let firstAnchor = ClubHistoryRules.recordGoal(days:&historyState.days,profile:historyState.profile,nutrition:initialTarget,now:now)
check(firstAnchor == today, "first observed goal anchors to its actual date")
check(ClubHistoryRules.profile(on:yesterday,days:historyState.days) == nil, "migration does not invent historical goals")
check(ClubHistoryRules.recordGoal(days:&historyState.days,profile:historyState.profile,nutrition:initialTarget,now:now) == nil, "unchanged goal does not create repeated versions")
let originalGoal = historyState.days[today]!.goalVersions![0]
historyState.profile.goal = "减脂"
_ = ClubHistoryRules.recordGoal(days:&historyState.days,profile:historyState.profile,nutrition:NutritionTarget.estimate(historyState.profile),now:now.addingTimeInterval(60))
check(historyState.days[today]!.goalVersions!.count == 2, "changed goal appends a version")
check(historyState.days[today]!.goalVersions![0] == originalGoal, "old goal is immutable")
check(ClubHistoryRules.profile(on:now,days:historyState.days)?.goal == "减脂", "date resolves its last observed goal")
historyState.profile.avatarImage = Data([1,2,3]);historyState.profile.nickname = "私人昵称"
_ = ClubHistoryRules.recordGoal(days:&historyState.days,profile:historyState.profile,nutrition:NutritionTarget.estimate(historyState.profile),now:now.addingTimeInterval(120))
check(historyState.days[today]!.goalVersions!.count == 2, "cosmetic profile changes are not new fitness goals")
let futureStart = ClubDates.calendar.date(byAdding:.day,value:14,to:Date())!
let futureKey = ClubDates.key(futureStart)
var package = ManualPlanDraft();package.start=futureKey;package.days[0].title="胸肩";package.days[0].movements=[movement]
let prepared = try package.result()
let adoption = AdoptionFixture()
let window = (0..<7).map { ClubDates.key(ClubDates.calendar.date(byAdding:.day,value:$0,to:futureStart)!) }
for key in window { adoption.state.days[key] = DayLog(exercises:[Exercise(name:"旧动作",muscle:"全身")]) }
let baseline = adoption.state.days
check(adoption.applyAIPlan(prepared,jobID:package.operationID,replaceUnstarted:true,cycleStart:futureStart,expectedDays:baseline), "manual package uses actual production adoption")
check(adoption.state.days[window[1]]!.exercises.isEmpty, "rest dates clear old unstarted schedules")
let savedVersion = adoption.state.days[futureKey]!.planVersions!.first!
check(savedVersion.title == package.title && savedVersion.sessions[0].label == "胸肩", "package and daily titles survive adoption")
check(savedVersion.source == "manual" && savedVersion.scopeDates.count == 7, "manual origin and full replacement scope retained")
let retainedIDs = adoption.state.days[futureKey]!.exercises.map(\.id)
check(adoption.applyAIPlan(prepared,jobID:package.operationID,replaceUnstarted:true,cycleStart:futureStart), "repeated confirm remains successful")
check(adoption.state.days[futureKey]!.exercises.map(\.id) == retainedIDs && adoption.state.days[futureKey]!.planVersions!.count == 1, "retry adds neither actions nor versions")
let diskFailure = AdoptionFixture();diskFailure.writesAllowed=false
check(!diskFailure.applyAIPlan(prepared,jobID:package.operationID,replaceUnstarted:true,cycleStart:futureStart), "disk failure rejects adoption")
check(diskFailure.state.days.isEmpty && diskFailure.state.appliedAIJobs == nil, "failed save rolls back snapshot, records and operation marker")
let changed = AdoptionFixture();changed.state.days=baseline
changed.state.days[window[1]]!.exercises.append(Exercise(name:"新动作",muscle:"背"))
check(!changed.applyAIPlan(prepared,jobID:package.operationID,replaceUnstarted:true,cycleStart:futureStart,expectedDays:baseline), "concurrent schedule change rejects stale preview")
let protected = AdoptionFixture();protected.state.days[futureKey]=DayLog(exercises:[Exercise(name:"已开始",muscle:"背")],workoutStartedAt:Date())
check(!protected.applyAIPlan(prepared,jobID:package.operationID,replaceUnstarted:true,cycleStart:futureStart), "started workout cannot be overwritten")
let nextID="manual-plan-next"
check(adoption.applyAIPlan(prepared,jobID:nextID,replaceUnstarted:true,cycleStart:futureStart), "subsequent plan can update unstarted window")
let chain=adoption.state.days[futureKey]!.planVersions!
check(chain.count==2 && chain.last!.previousIDs.contains(package.operationID), "overlapping updates preserve parent references")
let restoredHistory = try JSONDecoder().decode(SavedState.self,from:JSONEncoder().encode(adoption.state))
check(restoredHistory.days[futureKey]!.planVersions! == chain, "plan history survives local and cloud Codable round-trip")
print("History and production adoption: \(tests) total checks passed")
''')
Path(sys.argv[1]).write_text(content+'\n\n'+'\n\n'.join(extra),'utf-8')
