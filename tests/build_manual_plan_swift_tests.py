from pathlib import Path
import subprocess,sys,tempfile
root=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory() as tmp:
    existing=Path(tmp)/'facts.swift'
    subprocess.run([sys.executable,str(root/'tests/build_upgrade_v140_swift_tests.py'),str(existing)],check=True)
    content=existing.read_text('utf-8')
def block(s,marker):
    start=s.index(marker);i=s.index('{',start);depth=1;j=i+1
    while depth:
        if s[j]=='{':depth+=1
        elif s[j]=='}':depth-=1
        j+=1
    return s[start:j]
ai=(root/'BojiClub/AIService.swift').read_text('utf-8')
daily=(root/'BojiClub/DailyExperience.swift').read_text('utf-8')
extra=[]
extra.append(r'''
var draft = ManualPlanDraft();draft.start = today
check(draft.validation(now:now) != nil, "empty plan is not adoptable")
let movement = ManualPlanMovement(name:"哑铃卧推",muscle:"胸",query:"dumbbell bench press",libraryID:"sample",customID:nil,count:3,weight:10,reps:12)
draft.days[0].movements = [movement]
check(draft.validation(now:now) == nil, "one training day and rest days is valid")
let result = try draft.result(now:now)
check(result.sessions!.count == 1 && result.sessions![0].date == today, "rest days do not become fake workouts")
check(result.sessions![0].exercises[0].sets.count == 3, "set count is retained")
check(result.sessions![0].exercises[0].sets[0].weight == 10, "load retained")
draft.duration = 28;draft.repeatFirstWeek()
let longResult = try draft.result(now:now)
check(longResult.sessions!.count == 4, "four weeks repeat the same weekday")
check(Set(draft.activeDays.flatMap(\.movements).map(\.id)).count == 4, "copied movements get independent IDs")
draft.duration = 7
check(try draft.result(now:now).sessions!.count == 1, "short cycle excludes hidden dates")
draft.duration = 28
check(draft.days[21].movements.count == 1, "shortening preserves hidden draft days")
draft.copyDay(from:0,to:1)
check(draft.days[1].movements[0].name == draft.days[0].movements[0].name, "daily copy retains movement")
check(draft.days[1].movements[0].id != draft.days[0].movements[0].id, "daily copy can be edited independently")
draft.days[1].movements=[]
draft.days[0].movements[0].reps = 0
check(draft.validation(now:now) != nil, "zero repetitions rejected")
draft.days[0].movements[0].unit = "秒";draft.days[0].movements[0].seconds = 120
let timedPlan = try draft.result(now:now)
check(timedPlan.sessions![0].exercises[0].sets[0].durationSeconds == 120, "time target retained")
check(timedPlan.sessions![0].exercises[0].sets[0].reps == 0, "timed target does not carry repetitions")
check(timedPlan.sessions![0].exercises[0].sets[0].weight == 0, "timed target does not inherit load")
let operation = draft.operationID
let reused = draft.reusable(start:tomorrow)
check(reused.id != draft.id && reused.operationID != operation, "reused template creates a fresh adoption operation")
check(reused.start == ClubDates.key(tomorrow) && draft.start == today, "template reuse reanchors without changing the original")
check(reused.days[0].movements[0].id != draft.days[0].movements[0].id && reused.days[0].movements[0].seconds == draft.days[0].movements[0].seconds, "template clone preserves numeric targets with independent movement identities")
let template = ManualPlanTemplate(createdAt:now,draft:draft)
let restoredTemplate = try JSONDecoder().decode(ManualPlanTemplate.self,from:JSONEncoder().encode(template))
check(restoredTemplate==template,"template survives local restoration without applying a schedule")
let restored = try JSONDecoder().decode(ManualPlanDraft.self,from:JSONEncoder().encode(draft))
check(restored == draft && restored.operationID == operation, "draft restoration retains idempotency key")
draft.start = ClubDates.key(yesterday)
check(draft.validation(now:now) != nil, "past start rejected before adoption")
draft.start = today;draft.duration = 8
check(draft.validation(now:now) != nil, "unsupported duration rejected")

let variedExercise = AIPlanExercise(name:"卧推",muscle:"胸",sets:[AIPlanSet(weight:20,reps:10),AIPlanSet(weight:22.5,reps:8)],library_query:"bench",library_id:"bench",rest_seconds:90)
let variedResult = AIResult(kind:"plan",title:"逐组方案",sessions:[AIPlanSession(date:today,label:"训练",exercises:[variedExercise])],plan_days:7)
let variedDraft = try ManualPlanDraft.importing(variedResult,originalStart:today,start:tomorrow)
let variedExport = try variedDraft.result(now:tomorrow)
check(variedExport.sessions![0].date == ClubDates.key(tomorrow),"AI import reanchors without changing the sequence")
check(variedExport.sessions![0].exercises[0].sets == variedExercise.sets,"individual loads and reps survive import and adoption payload")
check(variedExport.sessions![0].exercises[0].rest_seconds == 90,"per-exercise rest survives editable draft")
var invalidCount = movement;invalidCount.count=51
check(!invalidCount.valid,"too many uniform sets cannot be silently clamped")
var invalidRest = movement;invalidRest.restSeconds=3601
check(!invalidRest.valid,"out-of-range rest rejected before preview")
var proposedDraft=variedDraft;proposedDraft.proposalJobID="proposal-job"
check(proposedDraft.operationID=="coach-plan-proposal-job","accepted suggestions retain an idempotent proposal source")
check(proposedDraft.reusable(start:tomorrow).proposalJobID==nil,"template reuse is a new operation rather than replaying an applied proposal")
var explicitDefault=Exercise(name:"卧推",muscle:"胸");explicitDefault.restSeconds=nil
let restJSON=try JSONSerialization.jsonObject(with:JSONEncoder().encode(explicitDefault)) as! [String:Any]
check(restJSON["restSeconds"] is NSNull,"default rest reset is explicit and distinguishable from old-client omission")
print("Manual plan and insight foundation: \(tests) checks passed")
''')
# Throwing calls cannot be passed to a nonthrowing autoclosure.
tail='\n\n'.join(extra).replace('check(try draft.result(now:now).sessions!.count == 1,','let shortResult = try draft.result(now:now)\ncheck(shortResult.sessions!.count == 1,')
Path(sys.argv[1]).write_text(content+'\n'+tail,'utf-8')
