"""Exercise the actual AppStore drain function across reentrant enqueues and account changes."""
from pathlib import Path
import subprocess,sys,tempfile
root=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory() as tmp:
    base=Path(tmp)/'base.swift'
    subprocess.run([sys.executable,str(root/'tests/build_training_commands_swift_tests.py'),str(base)],check=True)
    content=base.read_text()
def block(source,marker):
    start=source.index(marker);i=source.index('{',start);depth=1;j=i+1
    while depth:
        depth+=(source[j]=='{')-(source[j]=='}');j+=1
    return source[start:j]
flush=block((root/'BojiClub/AppStore.swift').read_text(),'private func flushDomainCommands(')
content+=r'''
class QueueAccount { struct User {var id:Int};var user:User?=User(id:7);var isPreviewAccount=false }
var sendHook:(()->Void)?
var deferred=false
extension DomainCommands {
 @MainActor static func send(commandID:String,type:String,payload:[String:JSONValue],owner:Int,account:QueueAccount) async -> DomainCommandOutcome {
  let hook=sendHook;sendHook=nil;hook?()
  return DomainCommandOutcome(kind:deferred ? .deferred : .confirmed)
 }
}
@MainActor class QueueFixture {
 var pendingDomainCommands:[PendingDomainCommand]=[]
 var confirmedFinishSessions:Set<String>=[]
 var accountService:QueueAccount?=QueueAccount()
 var message:String?
 var persists=0
 var state=SavedState()
 var accountChanged=false
 func persistDomainCommands(){persists+=1}
 func persist(changedDates:[String])->Bool{true}
 func checkContext(_ ticket:UUID,_ userID:Int)throws{if accountChanged {throw NSError(domain:"account",code:1)}}
 func run()async{await flushDomainCommands(ticket:UUID(),userID:7)}
'''+flush+r'''
}
func queued(_ id:String,_ attempts:Int=0)->PendingDomainCommand{PendingDomainCommand(commandID:id,type:DomainCommandType.sessionStart,payload:[:],intent:id,owner:7,attempts:attempts,createdAt:Date())}
let q=QueueFixture();q.pendingDomainCommands=[queued("A")]
sendHook={q.pendingDomainCommands.append(queued("B"))};await q.run()
check(q.pendingDomainCommands.map(\.commandID)==["B"],"awaited command does not delete concurrent enqueue")
deferred=true
let retryQueue=QueueFixture();retryQueue.pendingDomainCommands=[queued("R")]
for _ in 0..<3{retryQueue.pendingDomainCommands[0].nextAttemptAt=nil;await retryQueue.run()}
check(retryQueue.pendingDomainCommands.first?.attempts==3 && retryQueue.persists==3,"every retry count persists")
let retainedQueue=QueueFixture();retainedQueue.pendingDomainCommands=[queued("D",5)];await retainedQueue.run()
check(retainedQueue.pendingDomainCommands.count==1 && retainedQueue.pendingDomainCommands[0].blocked!=true && retainedQueue.pendingDomainCommands[0].nextAttemptAt != nil,"deferred commands back off and stay retryable instead of blocking")
let switchQueue=QueueFixture();switchQueue.pendingDomainCommands=[queued("old")]
sendHook={switchQueue.accountChanged=true;switchQueue.pendingDomainCommands=[queued("new")]};await switchQueue.run()
check(switchQueue.pendingDomainCommands[0].commandID=="new" && switchQueue.persists==0,"old network reply cannot mutate new account queue")
print("Action queue: 4 regression assertions passed (production drain function)")
'''
sync=(root/'BojiClub/CloudSync.swift').read_text()
models=(root/'BojiClub/Models.swift').read_text()
content+='\nenum MealNutritionMerge { enum NutritionSource { case edited, current, independent }\n'+block(models,'static func nutritionSource(')+'\n}\n'
content+='extension CloudMerge {\n'+'\n'.join(block(sync,m) for m in ['private static func mergeValue(', 'private static func id(', 'private static func indexed(', 'private static func strings('])+"\nstatic func probe(_ l: JSONValue,_ r: JSONValue,_ b: JSONValue)->JSONValue { mergeValue(l,r,b)! }\n}\n"
content+=r'''
func observation(_ t:Double,_ kg:Double)->JSONValue{.object(["id":.string("sample-A"),"updatedAt":.number(t),"kilograms":.number(kg)])}
let bmBase:JSONValue = .object(["bodyMeasurements":.array([observation(10,70)]),"deletedBodyMeasurementIDs":.array([])])
let bmLocal:JSONValue = .object(["bodyMeasurements":.array([observation(20,71)]),"deletedBodyMeasurementIDs":.array([.string("deleted-local")])])
let bmRemote:JSONValue = .object(["bodyMeasurements":.array([observation(30,72)]),"deletedBodyMeasurementIDs":.array([.string("deleted-remote")])])
let bmMerged=CloudMerge.probe(bmLocal,bmRemote,bmBase)
if case .object(let values)=bmMerged,case .array(let samples)?=values["bodyMeasurements"],case .object(let sample)=samples[0],case .array(let deleted)?=values["deletedBodyMeasurementIDs"]{
 check(sample["kilograms"] == .number(72),"numeric correction uses newest measurement observation rather than freezing baseline")
 check(deleted.count == 2,"measurement tombstones union across devices")
}else{fatalError("invalid merged measurement shape")}
print("Body merge: 2 regression assertions passed (production merge function)")
'''
Path(sys.argv[1]).write_text(content)
