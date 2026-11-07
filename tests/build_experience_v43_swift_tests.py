"""Build regression checks from production Foundation logic; UIKit checks require Xcode/device."""
from pathlib import Path
import runpy,sys
out=Path(sys.argv[1])
runpy.run_path(str(Path(__file__).with_name('build_experience_v42_swift_tests.py')))
s=out.read_text('utf-8')
s+=r'''
do {
    let beginning = checks
    check(JourneyScrollRules.clamped(-50, minimum: -20, maximum: 500) == -20, "scroll respects the adjusted top inset")
    check(JourneyScrollRules.clamped(750, minimum: -20, maximum: 500) == 500, "scroll position clamps to shortened content")
    check(JourneyScrollRules.clamped(320, minimum: -20, maximum: 500) == 320, "scroll restores the user's exact position")
    check(JourneyScrollRules.clamped(.nan, minimum: -20, maximum: 500) == -20, "invalid saved offset cannot corrupt scroll")
    check(JourneyScrollRules.clamped(100, minimum: 0, maximum: -200) == 0, "short steps return to the top")
    let viewport = CGRect(x:0,y:0,width:100,height:100)
    check(JourneyVisibility.intersects(CGRect(x:10,y:10,width:20,height:20),viewport), "visible loading card may animate")
    check(!JourneyVisibility.intersects(CGRect(x:0,y:101,width:20,height:20),viewport), "offscreen loading card must stop")
    check(!JourneyVisibility.intersects(CGRect(x:0,y:100,width:20,height:20),viewport), "touching an edge has no visible pixels")
    check(JourneyVisibility.intersects(CGRect(x:0,y:99,width:20,height:20),viewport), "partially visible loading card is detected")
    check(!JourneyVisibility.intersects(.zero,viewport), "unlaid-out probe cannot start animation")
    check(!JourneyVisibility.intersects(.null,viewport), "a clipped-out ancestor cannot start animation")
    check(!JourneyVisibility.intersects(CGRect(x:CGFloat.nan,y:0,width:20,height:20),viewport), "invalid geometry stops animation")

    let fixedNow = ClubDates.date(fromKey:"2026-10-10")!
    let start = ClubDates.calendar.date(byAdding:.day,value:-2,to:fixedNow)!
    let first = ClubDates.key(start), last = ClubDates.key(fixedNow)
    let cycle = TrainingCycle(start:first, plannedDates:[first,last])
    let set = TrainingSet(weight:20,reps:10,completed:true)
    let exercise = Exercise(name:"深蹲",muscle:"大腿",sets:[set])
    var done = DayLog(exercises:[exercise], workoutSavedAt:fixedNow); done.planCycle=cycle
    var unconfirmed = done; unconfirmed.workoutSavedAt=nil
    var complete = [first:done,last:done]
    for key in cycle.dates where complete[key] == nil { var rest = DayLog(); rest.planCycle = cycle; complete[key] = rest }
    check(TrainingHandoff.pending(on:fixedNow,days:complete,now:fixedNow)?.id == cycle.id, "last confirmed planned training offers next week before remaining rest days")
    check(TrainingHandoff.pending(on:fixedNow,days:complete.merging([last:unconfirmed]) { _, new in new },now:fixedNow) == nil, "ticked but unconfirmed groups cannot finish an early cycle")
    check(TrainingHandoff.pending(on:start,days:complete,now:fixedNow) == nil, "historical page has no current-week continuation prompt")
    let tomorrow = ClubDates.calendar.date(byAdding:.day,value:1,to:fixedNow)!
    check(TrainingHandoff.pending(on:tomorrow,days:complete,now:fixedNow) == nil, "future page has no record-completion continuation prompt")
    check(TrainingHandoff.pending(on:fixedNow,days:[:],now:fixedNow) == nil, "no plan has no imaginary completed cycle")
    let nextStart = ClubDates.calendar.date(byAdding:.day,value:7,to:start)!
    var withNext = complete
    withNext[ClubDates.key(nextStart)] = DayLog(exercises:[Exercise(name:"卧推",muscle:"胸",sets:[TrainingSet()])])
    check(TrainingHandoff.pending(on:fixedNow,days:withNext,now:fixedNow) == nil, "existing next-week training suppresses redundant prompts")
    let end = ClubDates.date(fromKey:cycle.end)!
    check(TrainingHandoff.pending(on:end,days:[first:unconfirmed],now:end)?.id == cycle.id, "last calendar day permits preparation without pretending training is complete")
    let after = ClubDates.calendar.date(byAdding:.day,value:1,to:end)!
    check(TrainingHandoff.pending(on:after,days:complete,now:after)?.id == cycle.id, "expired plan can be resumed from today")
    check(TrainingHandoff.detail(cycle,days:complete,now:after).contains("已经结束"), "ended cycle explanation is accurate")
    check(TrainingHandoff.detail(cycle,days:complete,now:fixedNow).contains("都已保存"), "early completion explanation is accurate")
    check(TrainingHandoff.detail(cycle,days:[first:unconfirmed],now:end).contains("快结束"), "unfinished cycle is not described as completed")
    print("PASS \(checks - beginning) additional v43 production Swift checks")
}
'''
root=Path(__file__).resolve().parents[1]
source=(root/'BojiClub/AIService.swift').read_text('utf-8')
latest=source[source.index('    func latest(kind:'):source.index('    func reportInput(')]
s+='\nstruct PlanTaskLookup { var jobs: [AILocalJob]\n'+latest+'}\n'
s+=r'''
do {
    let now = ClubDates.date(fromKey: "2026-10-10")!
    let request = AIRequest(id: "original", kind: "parse_plan", date: ClubDates.key(now), payload: [:])
    let plan = AILocalJob(id: "original", digest: "plan-input", request: request)
    var localNotes = AILocalJob(id: "notes", digest: "notes-input", request: request)
    localNotes.request.payload["operation"] = .string("notes_only")
    check(PlanTaskLookup(jobs: [localNotes, plan]).latest(kind: "parse_plan", date: now)?.id == plan.id,
        "text-only processing never replaces the latest imported plan")
    var recoveredNotes = AILocalJob(id: "recovered-notes", digest: "recovered/notes", request: request)
    recoveredNotes.result = AIResult(kind: "plan_notes", notes: ["休息90秒"])
    check(PlanTaskLookup(jobs: [recoveredNotes, plan]).latest(kind: "parse_plan", date: now)?.id == plan.id,
        "notes recovered without original input cannot be mistaken for a plan")
    let unknown = AILocalJob(id: "unknown", digest: "recovered/unknown", request: request)
    check(PlanTaskLookup(jobs: [unknown]).latest(kind: "parse_plan", date: now) == nil,
        "unknown recovered task waits for its actual result")
    var recoveredPlan = unknown; recoveredPlan.result = AIResult(kind: "plan", notes: [], sessions: [])
    check(PlanTaskLookup(jobs: [recoveredPlan]).latest(kind: "parse_plan", date: now)?.id == unknown.id,
        "a recovered imported plan remains available after its result is known")
    print("PASS 4 additional v43 production plan lookup checks")
}
'''
out.write_text(s,'utf-8')
print('v43 production Foundation checks generated; run on Mac for actual execution')
