from pathlib import Path
import sys
ROOT=Path(__file__).resolve().parents[1]
def source(name):return (ROOT/'BojiClub'/f'{name}.swift').read_text(encoding='utf-8')
rules=source('RecordReliability')
rules=rules.replace('import ImageIO\n','').replace('import UniformTypeIdentifiers\n','')
a=rules.index('enum RecordPhoto {');b=rules.index('enum AIVisibleError',a);rules=rules[:a]+rules[b:]
# macOS has no iOS data-protection flags; this harness checks transaction and
# integrity behavior. Device tests still must verify iOS protection separately.
rules=rules.replace('attributes: [.protectionKey: FileProtectionType.complete]', 'attributes: nil').replace(', .completeFileProtection','')
rules=rules.replace('try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: destination.path)', '// iOS-only data protection is checked in the application build')
types=source('AIService');types=types[types.index('enum JSONValue'):types.index('enum AIClientError')]
food=source('FoodComponents');food=food[food.index('struct FoodComponent'):food.index('struct FoodCompositionEditor')]
batch=source('MealBatchReviewView');batch=batch[batch.index('struct AIBatchMeal'):batch.index('struct MealBatchSeed')]
health=source('HealthData');health=health[health.index('struct HealthSource'):health.index('struct HealthDay')]
daily=source('DailyExperience');daily=daily[:daily.index('enum MealCategorySuggestion')]
tests=r'''
var count = 0
func check(_ value: @autoclosure () -> Bool, _ name: String) {
    precondition(value(), name); count += 1; print("PASS \(name)")
}
func rejects(_ name: String, _ action: () throws -> Void) {
    do { try action(); preconditionFailure(name) } catch { count += 1; print("PASS \(name)") }
}
struct Entry: Codable { let sequence: Int }
let scanner = JournalScanner.scan(Data("{\"sequence\":1}\nBROKEN\n{\"sequence\":3}\nunfinished".utf8), as: Entry.self)
check(scanner.entries.map(\.sequence) == [1,3], "scanner retains valid records after a broken line")
check(scanner.unreadableLines == [2], "scanner reports damaged committed line")
check(scanner.hasIncompleteTail, "scanner detects incomplete append")
check(JournalScanner.scan(Data(), as: Entry.self).entries.isEmpty, "empty journal remains valid")
let partial=JournalScanner.scan(Data("unfinished".utf8),as:Entry.self)
check(partial.committedBytes == 0 && partial.unreadableLines.isEmpty,"partial tail is not a corrupt committed entry")
let cache=ClubDateFormatterCache()
check(cache.date("2026-02-30") == nil,"date cache rejects impossible date")
check(cache.date("2026/10/11") == nil,"date cache requires canonical key")
let epoch=Date(timeIntervalSince1970:0)
check(cache.string(epoch,format:"yyyy-MM-dd",locale:"en_US_POSIX",timezone:TimeZone(secondsFromGMT:0)!) == "1970-01-01","UTC key")
check(cache.string(epoch,format:"yyyy-MM-dd",locale:"en_US_POSIX",timezone:TimeZone(secondsFromGMT:-3600)!) == "1969-12-31","timezone change uses correct formatter")
let folder=FileManager.default.temporaryDirectory.appendingPathComponent("boji-v48-"+UUID().uuidString)
try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
defer { try? FileManager.default.removeItem(at:folder) }
let records=folder.appendingPathComponent("records.json")
try Data("old".utf8).write(to:records);try Data("journal".utf8).write(to:records.appendingPathExtension("journal"))
try LocalRecoveryTransaction.commit(Data("new".utf8),accountID:12,recordURL:records)
check(try String(contentsOf:records,encoding:.utf8)=="new","recovery installs accepted checkpoint")
check(try Data(contentsOf:records.appendingPathExtension("journal")).isEmpty,"recovery clears old journal after checkpoint")
let backups=try FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil).filter{$0.lastPathComponent.hasPrefix("recovery-12-")}
check(backups.count==1,"recovery preserves protected backup folder")
let draftFolder=folder.appendingPathComponent("drafts",isDirectory:true)
try FileManager.default.createDirectory(at:draftFolder,withIntermediateDirectories:true)
let draft=MealEditorDraft(id:UUID(),name:"鸡蛋",category:"早餐",calories:100,protein:10,carbs:1,fat:5,components:[],fraction:0.33,jobID:"latest",sourceJobID:"source",estimateNotes:[],previousRecognitionJobID:"previous")
let draftFile=draftFolder.appendingPathComponent("2026-10-10-test.json")
try JSONEncoder().encode(draft).write(to:draftFile)
try MealDraftLibrary.remove(MealDraftChoice(draft:draft,file:draftFile),in:draftFolder)
check(MealDraftLibrary.abandonedJobIDs(in:draftFolder)==Set(["latest","source","previous"]),"discarded draft abandons fallback recognition too")
check(try String(contentsOf:backups[0].appendingPathComponent("records.json"),encoding:.utf8)=="old","original checkpoint preserved")
let marker=records.appendingPathExtension("recovery-pending")
struct Pending:Codable { let accountID:Int;let checkpoint:Data }
try JSONEncoder().encode(Pending(accountID:12,checkpoint:Data("after-crash".utf8))).write(to:marker)
rejects("different account cannot finish recovery") { try LocalRecoveryTransaction.finishPending(accountID:13,recordURL:records) }
try LocalRecoveryTransaction.finishPending(accountID:12,recordURL:records)
check(try String(contentsOf:records,encoding:.utf8)=="after-crash","pending accepted recovery resumes")
let tasks=folder.appendingPathComponent("tasks.json")
var a=AILocalJob(id:"a",digest:"first",request:AIRequest(id:"a",kind:"food",date:"2026-10-10",payload:["image_base64":.string("photo-input")]))
let b=AILocalJob(id:"b",digest:"second",request:AIRequest(id:"b",kind:"report",date:"2026-10-10",payload:[:]))
try JSONEncoder().encode([a,b]).write(to:tasks)
let disk=AIJobDiskStore();check(try disk.load(tasks)==[a,b],"legacy task array readable")
try disk.save([a,b],to:tasks)
check(try AIJobDiskStore().load(tasks)==[a,b],"sharded task roundtrip preserves photo input")
check(FileManager.default.fileExists(atPath:tasks.appendingPathExtension("legacy").path),"legacy migration backup retained")
let indexBefore=try JSONSerialization.jsonObject(with:Data(contentsOf:tasks)) as! [String:Any]
a.status="failed";try disk.save([a,b],to:tasks)
let indexAfter=try JSONSerialization.jsonObject(with:Data(contentsOf:tasks)) as! [String:Any]
let entriesBefore=indexBefore["entries"] as! [[String:String]],entriesAfter=indexAfter["entries"] as! [[String:String]]
check(entriesBefore[1]["file"]==entriesAfter[1]["file"],"unchanged report is not rewritten")
check(try AIJobDiskStore().load(tasks)==[a,b],"updated task persisted")
rejects("duplicate task IDs rejected") { try disk.save([a,a],to:tasks) }
check(try AIJobDiskStore().load(tasks)==[a,b],"failed save leaves previous index readable")
let corrupt=tasks.appendingPathExtension("parts").appendingPathComponent(entriesAfter[0]["file"]!)
try Data("tampered".utf8).write(to:corrupt)
let partialDisk=AIJobDiskStore()
try check(try partialDisk.load(tasks)==[b],"corrupt task does not hide healthy report")
check(partialDisk.unreadableJobIDs==Set(["a"]),"corrupt task ID is identified")
let committed=try Data(contentsOf:tasks)
rejects("partial task load cannot overwrite committed index") { try partialDisk.save([b],to:tasks) }
try check(try Data(contentsOf:tasks)==committed,"failed partial save preserves original index")
let now=ISO8601DateFormatter().date(from:"2026-10-11T12:00:00Z")!
func activity(_ date:String,_ seconds:String)->String { "<Activity Sport=\"Running\"><Id>\(date)</Id><Lap><TotalTimeSeconds>\(seconds)</TotalTimeSeconds><Calories>50</Calories></Lap></Activity>" }
let valid=activity("2026-10-10T10:00:00Z","1800")
let xml="<TrainingCenterDatabase><Activities>"+valid+activity("bad","120")+activity("2026-10-11T11:50:00Z","1800")+"</Activities></TrainingCenterDatabase>"
let inspection=try TCXImport.inspect(Data(xml.utf8),now:now)
check(inspection.workouts.count==1 && inspection.skippedCount==2,"TCX partial success with explanations")
rejects("malformed TCX fails before import") { _ = try TCXImport.inspect(Data((xml+"<broken").utf8),now:now) }
rejects("TCX DTD rejected") { _ = try TCXImport.inspect(Data("<!DOCTYPE x><x/>".utf8),now:now) }
let many="<TrainingCenterDatabase><Activities>"+String(repeating:valid,count:201)+"</Activities></TrainingCenterDatabase>"
let capped=try TCXImport.inspect(Data(many.utf8),now:now)
check(capped.workouts.count==200 && capped.skippedCount==1,"TCX limit explained without discarding valid records")
check(AIVisibleError.message(code:"all_unavailable",fallback:"Traceback")?.contains("输入已保留")==true,"known service error is actionable")
check(AIVisibleError.message(code:nil,fallback:"Traceback secret")?.contains("secret")==false,"unknown trace hidden")
print("ALL \(count) V48 NATIVE RULES PASSED")
'''
# throwing expressions inside the assertion closure need a throwing signature
tests=tests.replace('func check(_ value: @autoclosure () -> Bool, _ name: String) {\n    precondition(value(), name);', 'func check(_ value: @autoclosure () throws -> Bool, _ name: String) rethrows {\n    precondition(try value(), name);')
# precondition's nonthrowing autoclosure needs the result evaluated first
tests=tests.replace('precondition(try value(), name);','let passed = try value(); precondition(passed, name);')
tests=tests.replace('check(try ', 'try check(try ')
models=source('Models'); feedback=models[models.index('struct TrainingFeedback:'):models.index('struct WorkoutPauseInterval:')]
coach=source('ClubCoach'); coach=coach[:coach.index('enum ClubCoachRules')]
# ClubCoachAnswer 现含 cards:[AICardEnvelope]，卡片协议类型随 coach 一起提取。
cardtypes=source('AICards'); cardtypes=cardtypes[cardtypes.index('struct AICardAction:'):cardtypes.index('extension JSONValue')]
adaptive=source('ClubAdaptive'); params=adaptive[adaptive.index('struct ClubParameterChange:'):adaptive.index('enum ClubAdjustmentRules')]
out=Path(sys.argv[1]);out.parent.mkdir(parents=True,exist_ok=True)
out.write_text('import Foundation\nimport CryptoKit\n'+ 'enum ExerciseNames { static func display(_ name:String,id:String?,query:String?)->String { name } }\n'+food+batch+health+cardtypes+types+daily+rules+params+coach+feedback+source('TCXImport')+tests,encoding='utf-8')
print(out)
