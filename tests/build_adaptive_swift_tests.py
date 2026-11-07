"""Extract production proposal rules; execute with Swift on macOS."""
from pathlib import Path
import subprocess,sys,tempfile
root=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory() as tmp:
    fixture=Path(tmp)/'manual.swift'
    subprocess.run([sys.executable,str(root/'tests/build_manual_plan_swift_tests.py'),str(fixture)],check=True)
    source=fixture.read_text('utf-8')
def block(text,marker):
    start=text.index(marker);i=text.index('{',start);depth=1;j=i+1
    while depth:
        if text[j]=='{':depth+=1
        elif text[j]=='}':depth-=1
        j+=1
    return text[start:j]
production=(root/'BojiClub/ClubAdaptive.swift').read_text('utf-8')
source+='\nstruct AdaptiveRequest { var date:String }\nstruct AILocalJob { var id:String;var request:AdaptiveRequest }\n'
for marker in ['struct ClubParameterChange:','struct ClubParameterProposal:','enum ClubAdjustmentRules {']:
    source+='\n'+block(production,marker)
source+=r'''
var adaptiveState=SavedState()
let adaptiveKey=ClubDates.key(tomorrow)
adaptiveState.days[adaptiveKey]=DayLog(exercises:[Exercise(name:"卧推",muscle:"胸",sets:[TrainingSet(weight:20,reps:10),TrainingSet(weight:20,reps:8)],libraryID:"bench",restSeconds:60)])
let adaptiveBefore=ClubAdjustmentRules.upcoming(state:adaptiveState,after:now)
let adaptiveJob=AILocalJob(id:"11111111-1111-1111-1111-111111111111",request:AdaptiveRequest(date:today))
func adaptiveChange(_ field:String="reps",_ value:Double=11,_ group:Int?=0)->ClubParameterChange {
 ClubParameterChange(date:adaptiveKey,exercise:0,setIndex:group,field:field,value:value,reason:"核对已确认的实际表现")
}
func adaptiveProposal(_ changes:[ClubParameterChange])->ClubParameterProposal { ClubParameterProposal(version:1,changes:changes,baseline:adaptiveBefore) }
func adaptiveReject(_ label:String,_ operation:() throws->Void){do{try operation();preconditionFailure(label)}catch{check(true,label)}}
let adaptiveBoth=adaptiveProposal([adaptiveChange(),adaptiveChange("rest_seconds",90,nil)])
let adaptiveDraft=try ClubAdjustmentRules.draft(adaptiveBoth,job:adaptiveJob,selected:[0,1],state:adaptiveState,now:now)
let adaptiveResult=try adaptiveDraft.result(now:tomorrow)
check(adaptiveDraft.start==adaptiveKey && adaptiveDraft.duration==7,"proposal creates a future seven-day draft")
check(adaptiveResult.sessions![0].exercises[0].sets[0].reps==11,"confirmed parameter goes to its exact group")
check(adaptiveResult.sessions![0].exercises[0].sets[1].reps==8,"unselected group targets remain unchanged")
check(adaptiveResult.sessions![0].exercises[0].rest_seconds==90,"rest suggestion survives the common editor")
check(adaptiveState.days[adaptiveKey]!.exercises[0].sets[0].reps==10,"preview cannot mutate saved training")
check(adaptiveDraft.operationID=="coach-plan-"+adaptiveJob.id,"proposal adoption has a stable operation identity")
check(adaptiveDraft.suggestedForProfile==adaptiveState.profile.aiProfile,"proposal captures the goal profile for rechecking")
let adaptiveSelected=try ClubAdjustmentRules.draft(adaptiveBoth,job:adaptiveJob,selected:[1],state:adaptiveState,now:now)
let adaptiveSelectedResult=try adaptiveSelected.result(now:tomorrow)
check(adaptiveSelectedResult.sessions![0].exercises[0].sets[0].reps==10,"deselected suggestion is not applied")
adaptiveReject("empty selection is not adoptable"){_ = try ClubAdjustmentRules.draft(adaptiveBoth,job:adaptiveJob,selected:[],state:adaptiveState,now:now)}
adaptiveReject("selection cannot refer to a missing suggestion"){_ = try ClubAdjustmentRules.draft(adaptiveBoth,job:adaptiveJob,selected:[2],state:adaptiveState,now:now)}
var adaptiveChanged=adaptiveState;adaptiveChanged.days[adaptiveKey]!.exercises[0].sets[0].weight=21
adaptiveReject("changed future target invalidates the old proposal"){_ = try ClubAdjustmentRules.draft(adaptiveBoth,job:adaptiveJob,selected:[0],state:adaptiveChanged,now:now)}
var adaptiveStarted=adaptiveState;adaptiveStarted.days[adaptiveKey]!.workoutStartedAt=now
check(ClubAdjustmentRules.upcoming(state:adaptiveStarted,after:now).isEmpty,"started training is excluded from future adjustment")
adaptiveReject("started date is protected during draft creation"){_ = try ClubAdjustmentRules.draft(adaptiveBoth,job:adaptiveJob,selected:[0],state:adaptiveStarted,now:now)}
adaptiveReject("yesterday's advice requires fresh checking"){_ = try ClubAdjustmentRules.draft(adaptiveBoth,job:AILocalJob(id:adaptiveJob.id,request:AdaptiveRequest(date:ClubDates.key(yesterday))),selected:[0],state:adaptiveState,now:now)}
adaptiveReject("duplicate parameter assignments rejected"){_ = try ClubAdjustmentRules.draft(adaptiveProposal([adaptiveChange(),adaptiveChange()]),job:adaptiveJob,selected:[0,1],state:adaptiveState,now:now)}
adaptiveReject("repetition training cannot become timed through a parameter patch"){_ = try ClubAdjustmentRules.draft(adaptiveProposal([adaptiveChange("durationSeconds",12)]),job:adaptiveJob,selected:[0],state:adaptiveState,now:now)}
adaptiveReject("excessive load increase rejected on the client too"){_ = try ClubAdjustmentRules.draft(adaptiveProposal([adaptiveChange("weight",30)]),job:adaptiveJob,selected:[0],state:adaptiveState,now:now)}
adaptiveReject("out-of-range rest rejected"){_ = try ClubAdjustmentRules.draft(adaptiveProposal([adaptiveChange("rest_seconds",3601,nil)]),job:adaptiveJob,selected:[0],state:adaptiveState,now:now)}
adaptiveReject("rest is an action-level parameter"){_ = try ClubAdjustmentRules.draft(adaptiveProposal([adaptiveChange("rest_seconds",90,0)]),job:adaptiveJob,selected:[0],state:adaptiveState,now:now)}
adaptiveReject("unknown mutation fields rejected"){_ = try ClubAdjustmentRules.draft(adaptiveProposal([adaptiveChange("delete",1)]),job:adaptiveJob,selected:[0],state:adaptiveState,now:now)}
print("PASS adaptive proposal rules with foundation: \(tests) checks")
'''
Path(sys.argv[1]).write_text(source,'utf-8')
