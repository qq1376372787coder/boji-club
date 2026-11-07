"""Run the real adoption control flow with injected storage failure on macOS."""
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
view=(root/'BojiClub/ManualPlanView.swift').read_text('utf-8')
source+='\n'+block(view,'private struct ManualPlanPreview:').replace('private struct','struct',1)
source+=r'''
final class RetryStore {
 var editingAccountID:Int?=10;var state=SavedState();var customExercises:[CustomExercise]=[]
 var applied=false;var applications=0
 func hasAppliedAIJob(_ id:String)->Bool { applied }
 func clearSyncedPlanDraft(id:UUID)->Bool { true }
 func takeMessage()->String { "fixture" }
 func applyAIPlan(_ result:AIResult,jobID:String,replaceUnstarted:Bool,cycleStart:Date?,expectedDays:[String:DayLog]?,explicitScope:[String]?=nil,singleDay:Bool=false)->Bool {
  if !applied { applications+=1;applied=true };return true
 }
}
enum RetryArchive {
 static var attempts=0
 static var cleared=0
 static func archive(_ draft:ManualPlanDraft,owner:Int)throws {
  attempts+=1;if attempts==1{throw NSError(domain:"synthetic-storage-failure",code:1)}
 }
 static func clear(owner:Int)throws { cleared+=1 }
}
final class RetryHarness {
 let store=RetryStore();var owner:Int?=10;var preview:ManualPlanPreview?;var error:String?
 var onSaved:(()->Void)? = nil
 var evidenceChecks=0;var dismissed=false
 func dismiss(){dismissed=true}
 func checkProposalEvidence(_ draft:ManualPlanDraft)throws {
  evidenceChecks+=1
  if store.applied{throw NSError(domain:"original-evidence-no-longer-current",code:2)}
 }
 func confirm(_ value:ManualPlanPreview){apply(value)}
'''
source+='\n'+block(view,'private func apply(_ value: ManualPlanPreview)').replace('ManualPlanDraftStorage.','RetryArchive.')+'\n}\n'
source+=r'''
var retryDraft=variedDraft;retryDraft.start=ClubDates.key(Date());retryDraft.proposalJobID=UUID().uuidString.lowercased()
let retryPreview=ManualPlanPreview(draft:retryDraft,baseline:[:])
let retryHarness=RetryHarness()
retryHarness.confirm(retryPreview)
check(retryHarness.store.applications==1,"first confirmation applies the plan once")
check(!retryHarness.dismissed && retryHarness.error != nil,"archive failure leaves a clear recovery path")
retryHarness.confirm(retryPreview)
check(retryHarness.evidenceChecks==1,"archive-only retry does not revalidate obsolete original evidence")
check(retryHarness.store.applications==1,"storage retry cannot apply the same plan twice")
check(RetryArchive.attempts==2 && RetryArchive.cleared==1 && retryHarness.dismissed,"retry finishes archive and draft cleanup")
print("PASS Build 106 adoption failure recovery: \(tests) total assertions")
'''
Path(sys.argv[1]).write_text(source,'utf-8')
