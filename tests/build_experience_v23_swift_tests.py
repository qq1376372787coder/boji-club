"""Exercise the actual draft filesystem, report sections and artwork metadata rules."""
from pathlib import Path
import runpy,sys
output=Path(sys.argv[1])
module=runpy.run_path(str(Path(__file__).with_name('build_experience_v22_swift_tests.py')))
code=output.read_text('utf-8')
code+=r'''
do {
let before=checks
let folder=FileManager.default.temporaryDirectory.appendingPathComponent("boji-v23-drafts-"+UUID().uuidString,isDirectory:true)
try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
defer { try? FileManager.default.removeItem(at:folder) }
let created=now.addingTimeInterval(-3600)
func draft(_ category:String,_ job:String?,_ time:Date) -> MealEditorDraft {
    MealEditorDraft(id:UUID(),name:category,category:category,calories:0,protein:0,carbs:0,fat:0,components:[],fraction:1,jobID:job,sourceJobID:nil,estimateNotes:[],updatedAt:time,createdAt:created)
}
func write(_ draft:MealEditorDraft,day:String=today,legacy:Bool=false) throws -> URL {
    let file=folder.appendingPathComponent(day+(legacy ? "" : "-"+draft.id.uuidString.lowercased())+".json")
    try JSONEncoder().encode(draft).write(to:file)
    return file
}
var breakfast=draft("早餐","shared",created)
let morningFile=try write(breakfast)
let dinner=draft("晚餐","shared",now)
let dinnerFile=try write(dinner)
_ = try write(draft("午餐",nil,now),day:ClubDates.key(yesterday))
var choices=try MealDraftLibrary.choices(in:folder,dateKey:today,category:"早餐")
check(choices.count == 2 && choices.first?.draft.id == breakfast.id,"requested breakfast precedes a newer dinner and excludes other days")
choices=try MealDraftLibrary.choices(in:folder,dateKey:today,category:"晚餐")
check(choices.first?.draft.id == dinner.id,"requested dinner is prioritised independently")
check(choices.allSatisfy{$0.draft.createdAt == created},"each draft retains its own creation timestamp")
breakfast.updatedAt=now.addingTimeInterval(10);_ = try write(breakfast)
check(try MealDraftLibrary.choices(in:folder,dateKey:today,category:"早餐").first!.draft.createdAt == created,"resaving does not reset draft creation time")
var old=draft("加餐","legacy",now);old.createdAt=nil
let legacyFile=try write(old,legacy:true)
let restored=try MealDraftLibrary.choices(in:folder,dateKey:today,category:"加餐").first!
check(restored.draft.id == old.id && restored.draft.createdAt != nil,"date-only old draft is retained and obtains a filesystem timestamp")
let legacyData=try JSONSerialization.jsonObject(with:JSONEncoder().encode(old)) as! [String:Any]
check(legacyData["createdAt"] == nil,"legacy optional timestamp remains absent until migration")
let broken=folder.appendingPathComponent(today+"-broken.json");try Data("broken".utf8).write(to:broken)
check(try MealDraftLibrary.choices(in:folder,dateKey:today,category:"早餐").count == 3 && FileManager.default.fileExists(atPath:broken.path),"unreadable draft is preserved and never replaces valid choices")
try FileManager.default.removeItem(at:broken)
let morning=MealDraftChoice(draft:breakfast,file:morningFile)
try Data("photo".utf8).write(to:morningFile.deletingPathExtension().appendingPathExtension("jpg"))
try MealDraftLibrary.remove(morning,in:folder)
check(!FileManager.default.fileExists(atPath:morningFile.path) && FileManager.default.fileExists(atPath:dinnerFile.path),"deleting breakfast leaves dinner intact")
check(!FileManager.default.fileExists(atPath:morningFile.deletingPathExtension().appendingPathExtension("jpg").path),"deleting a draft removes its matching photo only")
check(MealDraftLibrary.abandonedJobIDs(in:folder).isEmpty,"shared recognition is not abandoned while another draft references it")
try MealDraftLibrary.remove(MealDraftChoice(draft:dinner,file:dinnerFile),in:folder)
check(MealDraftLibrary.abandonedJobIDs(in:folder) == ["shared"],"last referencing draft deletion durably records the abandoned AI task")
check(try MealDraftLibrary.choices(in:folder,dateKey:today,category:"加餐").count == 1,"discarded files are not offered for restoration")
let outside=folder.deletingLastPathComponent().appendingPathComponent(UUID().uuidString+".json")
try JSONEncoder().encode(old).write(to:outside)
defer { try? FileManager.default.removeItem(at:outside) }
do { try MealDraftLibrary.remove(MealDraftChoice(draft:old,file:outside),in:folder);check(false,"reject deletion outside account folder") }
catch { check(FileManager.default.fileExists(atPath:outside.path),"reject deletion outside account folder") }
check(FileManager.default.fileExists(atPath:legacyFile.path),"unrelated legacy draft remains recoverable")
let note=String(repeating:"需要完整保留的中文 English 123 👩🏽‍💻。\n",count:200)
let sections=ReportShareContent.sections(summary:"当天结论",training:note,nutrition:"营养完整内容",recovery:"下一步要做到位。\n恢复的后续内容",facts:["完成4组"])
check(sections.map(\.title) == ["结论与记录","训练分析","饮食与恢复"],"report cards follow conclusion, training, food and recovery order")
check(sections[0].text.contains("完成4组") && sections[0].text.contains("下一步摘录：下一步要做到位"),"first card includes recorded facts and a labelled next-step excerpt")
let reportPages=ReportShareContent.pages(sections){$0.count <= 80}
check(reportPages.count > 3 && reportPages.allSatisfy{$0.text.count <= 80},"long mixed-language report continues inside its measured section")
check(reportPages.filter{$0.title.hasPrefix("训练分析")}.map(\.text).joined() == note,"training pagination preserves every grapheme")
check(reportPages.last!.text.contains("恢复的后续内容"),"complete recovery survives the overview excerpt")
check(ReportShareContent.sections(summary:nil,training:" ",nutrition:nil,recovery:nil).isEmpty,"missing report sections do not invent an evaluation")
let weeklyCards=ReportShareContent.sections(summary:"周结论",training:"训练",nutrition:"饮食",recovery:nil,planReason:note)
check(weeklyCards.first!.text.contains(note),"weekly plan reason is preserved without truncation")
let full=String(repeating:"a",count:64), thumb=String(repeating:"b",count:64), version=String(repeating:"c",count:64)
let revision=ClubArtworkRevision(version:version,fullSHA256:full,thumbnailSHA256:thumb)
check(revision.accepts(full,thumbnail:false) && revision.accepts(thumb,thumbnail:true),"full and thumbnail artwork use their own checksums")
check(!revision.accepts(full,thumbnail:true) && !revision.accepts(thumb,thumbnail:false),"wrong size content cannot be cached as verified artwork")
check(!revision.accepts(String(repeating:"d",count:64),thumbnail:false),"corrupt or changed download is rejected")
check(!ClubArtworkRevision.validHash("../image") && !ClubArtworkRevision.validHash(String(repeating:"A",count:64)),"malformed version is rejected before a download")
let changed=ClubArtworkRevision(version:String(repeating:"d",count:64),fullSHA256:full,thumbnailSHA256:thumb)
check(revision.cacheIdentity != changed.cacheIdentity,"same filename with new version has a different cache identity")
let rewardJSON=#"{"id":1,"title":"badge","detail":"official","type":"badge","icon":"seal","unlocked":true,"image_path":"same.png"}"#
let oldBadge=try JSONDecoder().decode(ClubSeasonReward.self,from:Data(rewardJSON.utf8))
check(oldBadge.artworkRevision == nil,"legacy cached badge metadata remains readable")
var currentBadge=oldBadge;currentBadge.imageVersion=version;currentBadge.imageSHA256=full;currentBadge.thumbnailSHA256=thumb
check(currentBadge.artworkRevision == revision,"new badge model exposes all validation fields")
let catalogJSON=#"{"id":1,"title":"badge","icon":"seal","reward_type":"badge","season_title":"season","slug":"s","image_version":""# + version + #"","image_sha256":""# + full + #"","thumbnail_sha256":""# + thumb + #""}"#
let collected=try JSONDecoder().decode(ClubCollectedReward.self,from:Data(catalogJSON.utf8))
check(collected.artworkRevision == revision,"collection and season metadata use the same validation protocol")
print("PASS \(checks-before) v23 production Swift rule checks; total \(checks)")
}
'''
editor=module['read']('MealEditorView.swift')
data_property=editor[editor.index('    private var draftData:'):editor.index('    private func prepareDraftFolder()')]
code+=r'''
final class DraftPersistenceFixture {
    var store=AppStore()
    var folder: URL
    var draftOwner: Int?=1
    var draftLoaded=true, draftReadable=true, saved=false, restoredDraft=false
    var draftID=UUID(), draftCreatedAt=Date()
    var date=Date(), name="餐食", category="早餐"
    var mealDescription="", entryMode="手动", multipleMeals=false
    var calories=0.0, protein=0.0, carbs=0.0, fat=0.0, fraction=1.0
    var components: [FoodComponent]=[]
    var jobID: String?, sourceJobID: String?, cameraMessage: String?
    var previousRecognitionJobID: String?
    var estimateNotes: [String]=[]
    var photo: Data?
    var legacyDraftFile: URL?
    init(_ folder: URL) { self.folder=folder }
    func prepareDraftFolder() throws -> URL { folder }
'''+data_property+module['method'](editor,'persistDraft').replace('private func persistDraft','func persistDraft')+'\n}\n'
code+=r'''
do {
let before=checks
let folder=FileManager.default.temporaryDirectory.appendingPathComponent("boji-v23-persist-"+UUID().uuidString,isDirectory:true)
try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
defer { try? FileManager.default.removeItem(at:folder) }
let fixture=DraftPersistenceFixture(folder)
check(fixture.persistDraft(),"actual editor persistence reports a successful write")
let stem=ClubDates.key(fixture.date)+"-"+fixture.draftID.uuidString.lowercased()
let file=folder.appendingPathComponent(stem+".json")
let persisted=try JSONDecoder().decode(MealEditorDraft.self,from:Data(contentsOf:file))
check(persisted.createdAt == fixture.draftCreatedAt && persisted.updatedAt != nil,"actual editor stores stable creation and current update timestamps")
fixture.store.editingAccountID=2
check(!fixture.persistDraft(),"actual editor refuses persistence after account switch")
fixture.store.editingAccountID=1
try FileManager.default.removeItem(at:file)
try FileManager.default.createDirectory(at:file,withIntermediateDirectories:true)
let legacy=folder.appendingPathComponent(ClubDates.key(fixture.date)+".json")
try JSONEncoder().encode(persisted).write(to:legacy)
let photoFile=legacy.deletingPathExtension().appendingPathExtension("jpg")
try Data("old-photo".utf8).write(to:photoFile)
fixture.legacyDraftFile=legacy;fixture.photo=Data("old-photo".utf8)
check(!fixture.persistDraft() && fixture.cameraMessage != nil,"actual editor exposes a failed write so draft switching can be refused")
check(FileManager.default.fileExists(atPath:legacy.path) && FileManager.default.fileExists(atPath:photoFile.path) && fixture.legacyDraftFile == legacy,"failed migration retains original JSON and photo")
try FileManager.default.removeItem(at:file)
check(fixture.persistDraft() && !FileManager.default.fileExists(atPath:legacy.path) && !FileManager.default.fileExists(atPath:photoFile.path),"successful retry migrates before removing old draft files")
check(fixture.legacyDraftFile == nil && fixture.name == "餐食", "successful migration clears legacy reference and retains the user's input")
print("PASS \(checks-before) v23 editor persistence checks; total \(checks)")
}
'''
output.write_text(code,'utf-8')
print('Built v23 production Swift rules')
