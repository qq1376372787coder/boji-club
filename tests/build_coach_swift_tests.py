from pathlib import Path
import sys
root=Path(__file__).resolve().parents[1]/'BojiClub'
def block(s,marker):
 i=s.index(marker);j=s.index('{',i);depth=1;k=j+1
 while depth:
  if s[k]=='{':depth+=1
  elif s[k]=='}':depth-=1
  k+=1
 return s[i:k]
ai=(root/'AIService.swift').read_text('utf-8')
coach=(root/'ClubCoach.swift').read_text('utf-8').split('extension AIService {')[0]
# ClubCoachAnswer 现含 cards:[AICardEnvelope]，卡片协议类型随 coach 一起提取。
cards=(root/'AICards.swift').read_text('utf-8')
source='import Foundation\n'+block(ai,'enum JSONValue:')+'\n'+block(ai,'struct AIRequest:')
source+='\n'+block(ai,'struct AIPlanSet:')+'\n'+block(ai,'struct AIPlanExercise:')+'\n'+block(ai,'struct AIPlanSession:')+'\n'+block((root/'ClubAdaptive.swift').read_text('utf-8'),'struct ClubParameterChange:')+'\n'+block((root/'ClubAdaptive.swift').read_text('utf-8'),'struct ClubParameterProposal:')
source+='\n'+block(cards,'struct AICardAction:')+'\n'+block(cards,'struct AICardEnvelope:')
source+='\nstruct AIResult:Codable,Equatable { var coach:ClubCoachAnswer? = nil }\n'+block(ai,'struct AILocalJob:')+'\n'+coach
source+=r'''
enum AIClientError: Error { case message(String) }
// The history contract only needs the attachment draft index API; filesystem
// protection and image payload behavior are covered by SharedComposer tests.
enum ClubChatDraftStorage {
    struct Draft { var attachments: [Int] = [] }
    static func erase(owner: Int) {}
    static func conversations(owner: Int) -> [String] { [] }
    static func load(owner: Int, conversation: String) -> Draft? { nil }
}
struct BodyWeightEntry { var kilograms: Double?; var hasMeasurement: Bool { kilograms != nil } }
struct TrainingCycle { var plannedDates: [String] = [] }
struct DayLog {
    var hasConfirmedTraining = false
    var bodyWeight: BodyWeightEntry? = nil
    var meals: [Any] = []
    var planCycle: TrainingCycle? = nil
}
struct SavedState { var days:[String:DayLog]=[:] }
enum ClubDates {
    static let calendar=Calendar(identifier:.gregorian)
    static func key(_ date:Date)->String{ String(format:"%04d-%02d-%02d",calendar.component(.year,from:date),calendar.component(.month,from:date),calendar.component(.day,from:date)) }
    static func date(fromKey:String)->Date?{ let parts=fromKey.split(separator:"-").compactMap{Int($0)};guard parts.count==3 else{return nil};return calendar.date(from:DateComponents(year:parts[0],month:parts[1],day:parts[2])) }
    static func isFuture(_ date:Date,now:Date=Date())->Bool{ calendar.startOfDay(for:date)>calendar.startOfDay(for:now) }
}
enum ClubShiftRules { static func movableDates(state:SavedState,now:Date=Date())->[Date]{[]} }
enum ClubAdjustmentRules { static func upcoming(state:SavedState,after:Date)->[AIPlanSession]{[]} }
'''
source+=r'''
var checks=0
func check(_ value:Bool,_ label:String){precondition(value,label);checks+=1}
let conversation=UUID().uuidString.lowercased()
func turn(_ id:String=UUID().uuidString,question:String="怎么练",answer:String="按实际表现继续核对",status:String="succeeded",when:Date=Date())->AILocalJob {
 let request=AIRequest(id:id,kind:"coach",date:"2026-10-15",payload:["conversation_id":.string(conversation),"question":.string(question)])
 return AILocalJob(id:id,digest:"fixture",request:request,status:status,result:status=="succeeded" ? AIResult(coach:ClubCoachAnswer(answer:answer,sources:[],actions:[])):nil,created:when)
}
let first=turn(when:Date(timeIntervalSince1970:1));let second=turn(when:Date(timeIntervalSince1970:2))
check(ClubCoachRules.turns([second,first],conversation:conversation,deleted:[]).map(\.id)==[first.id,second.id],"dialogue preserves actual turn ordering")
check(ClubCoachRules.turns([first,second],conversation:conversation,deleted:[first.id]).map(\.id)==[second.id],"archived/deleted task does not return to conversation")
check(ClubCoachRules.turns([first],conversation:UUID().uuidString,deleted:[]).isEmpty,"conversation isolation")
let history=ClubCoachRules.history([first,second]);check(history.count==4,"completed pairs supply compact multi-turn history")
if case .object(let value)=history[0]{check(value["role"]==.string("user"),"history begins with user data")}
check(ClubCoachRules.history([turn(status:"failed"),turn(status:"running")]).isEmpty,"unfinished and failed replies are never invented as history")
let many=(0..<20).map{turn(when:Date(timeIntervalSince1970:Double($0)))}
check(ClubCoachRules.history(many).count==12,"history has at most six complete pairs")
check(ClubCoachRules.history((0..<8).map{turn(answer:String(repeating:"长",count:4000),when:Date(timeIntervalSince1970:Double($0)))}).count<=6,"character cap cannot grow without bound")
let restored=try JSONDecoder().decode(AILocalJob.self,from:JSONEncoder().encode(first))
check(restored==first,"cold task restore retains coach answer, question and conversation")
var recovered=first;recovered.request.payload=[:]
check(ClubCoachRules.conversation(recovered)==first.id,"recovered reply remains discoverable without inventing the missing question")
var replaced=first;replaced.replacementID=second.id
check(ClubCoachRules.turns([replaced,second],conversation:conversation,deleted:[]).count==1,"superseded retry does not duplicate a turn")
check(ClubCoachAction(type:"plans",date:"2026-10-15").label.contains("预览"),"plan action promises a preview rather than claiming a mutation")
print("PASS \(checks) native coach history/model checks")
'''
# Space enum comparisons so Swift cannot interpret ==. as an operator.
source=source.replace(']==.string','] == .string')
Path(sys.argv[1]).write_text(source,'utf-8')
