from pathlib import Path
import subprocess,sys,tempfile
root=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory() as tmp:
    p=Path(tmp)/'ledger.swift'
    subprocess.run([sys.executable,str(root/'tests/build_insight_ledger_swift_tests.py'),str(p)],check=True)
    content=p.read_text('utf-8')
extra=r''' 
var contextState=SavedState()
// 默认资料 factState 为空字典＝来源未确认；历史目标用例模拟已确认的旧资料。
contextState.profile.factState=nil
let baselineDate=ClubDates.calendar.date(byAdding:.day,value:-2,to:now)!
_ = ClubHistoryRules.recordGoal(days:&contextState.days,profile:contextState.profile,nutrition:NutritionTarget.estimate(contextState.profile),now:baselineDate)
let unknownDate=ClubDates.calendar.date(byAdding:.day,value:-3,to:now)!
let unknownContext=ClubAIContext.make(state:contextState,start:unknownDate,end:unknownDate,now:now)
check(unknownContext.days[0].profile == nil, "today profile does not backfill an unobserved historical goal")
contextState.profile.goal="减脂";contextState.profile.nickname="不应发送";contextState.profile.avatarImage=Data([1,2])
_ = ClubHistoryRules.recordGoal(days:&contextState.days,profile:contextState.profile,nutrition:NutritionTarget.estimate(contextState.profile),now:now.addingTimeInterval(60))
let oldContext=ClubAIContext.make(state:contextState,start:yesterday,end:yesterday,now:now)
check(oldContext.days[0].profile?.goal == "增肌", "historical record retains its historical goal")
let contextNow=now.addingTimeInterval(120)
let newContext=ClubAIContext.make(state:contextState,start:now,end:now,now:contextNow)
check(newContext.days[0].profile?.goal == "减脂" && newContext.days[0].goalChangedDuringDay, "same-day target change is explicit")
check(newContext.days[0].profile?.avatarImage == nil && newContext.days[0].profile?.nickname == "薄肌成员", "historical AI context strips identity and avatar")
check(ClubAIContext.make(state:contextState,start:tomorrow,end:tomorrow,now:now).days.isEmpty, "future dates never masquerade as observed context")
let originalContext=newContext
_ = ClubHistoryRules.recordGoal(days:&contextState.days,profile:contextState.profile,nutrition:NutritionTarget.estimate(contextState.profile),now:tomorrow)
check(ClubAIContext.make(state:contextState,start:now,end:now,now:contextNow) == originalContext, "future-dated synced goal is not current evidence")
let week=ClubAIContext.make(state:contextState,start:unknownDate,end:now,now:contextNow)
check(week.days.count == 4 && week.days[0].profile == nil && week.days[1].profile?.goal == "增肌" && week.days[3].profile?.goal == "减脂", "mixed-target week keeps separate dates instead of overwriting all days")
let contextData=try JSONEncoder().encode(week)
let decodedContext=try JSONDecoder().decode(ClubAIContext.self,from:contextData)
check(decodedContext == week, "goal context survives request persistence")
print("Goal context: \(tests) combined behavioral checks passed")
'''
Path(sys.argv[1]).write_text(content+'\n'+extra,'utf-8')
