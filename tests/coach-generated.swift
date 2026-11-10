import Foundation
enum JSONValue: Codable, Equatable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([JSONValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    var string: String? { if case .string(let v) = self { return v }; return nil }
    static func encode<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }
}
struct AIRequest: Codable, Equatable {
    var id: String
    var kind: String
    var date: String
    var payload: [String: JSONValue]
}
struct AIPlanSet: Codable, Equatable { var weight: Double?; var reps: Int; var durationSeconds: Int? = nil
    var repetitionLabel: String { durationSeconds.map { "\($0) 秒" } ?? "\(reps) 次" }
}
struct AIPlanExercise: Codable, Equatable { var name: String; var muscle: String; var sets: [AIPlanSet]; var library_query: String?; var library_id: String? = nil; var custom_id: UUID? = nil; var custom_unit: String? = nil; var rest_seconds: Int? = nil }
struct AIPlanSession: Codable, Equatable { var date: String; var label: String; var exercises: [AIPlanExercise] }
struct ClubParameterChange: Codable, Equatable {
    let date: String
    let exercise: Int
    let setIndex: Int?
    let field: String
    let value: Double
    let reason: String
    enum CodingKeys: String, CodingKey { case date, exercise, field, value, reason; case setIndex = "set" }
}
struct ClubParameterProposal: Codable, Equatable {
    let version: Int
    let changes: [ClubParameterChange]
    let baseline: [AIPlanSession]
}
struct AIResult:Codable,Equatable { var coach:ClubCoachAnswer? = nil }
struct AILocalJob: Identifiable, Codable, Equatable {
    var id: String
    var digest: String
    var request: AIRequest
    var status = "pending"
    var result: AIResult?
    var error: String?
    var provider: String?
    var model: String?
    var created = Date()
    var consumed = false
    var errorCode: String?
    var replacementID: String?
    var retryAfter: Date? = nil
    var connectionFailures: Int? = nil
    var isWaiting: Bool { ["waiting_connection", "waiting_service"].contains(status) }
    var isTerminal: Bool { ["succeeded", "failed", "deleted", "expired", "rejected", "discarded"].contains(status) }
}
import Foundation

struct ClubCoachSource: Identifiable, Codable, Equatable {
    let id: String
    let date: String
    let label: String
    let detail: String
}
struct ClubCoachAction: Codable, Equatable, Identifiable {
    let type: String
    let date: String
    var id: String { type + "/" + date }
    var label: String {
        switch type {
        case "training": return "查看当天训练"
        case "nutrition": return "登记饮食"
        case "body": return "查看身体记录"
        case "plans": return "预览新的训练方案"
        case "daily": return "查看当天分析"
        case "weekly": return "进入每周复盘"
        default: return "暂不支持的操作"
        }
    }
}
struct ClubCoachAnswer: Codable, Equatable {
    let answer: String
    let sources: [ClubCoachSource]
    let actions: [ClubCoachAction]
    var purpose: String? = nil
    var source_session: String? = nil
    var proposal: ClubParameterProposal? = nil
}

enum ClubCoachRules {
    static func conversation(_ job: AILocalJob) -> String? {
        guard job.request.kind == "coach", (job.result?.coach?.purpose ?? job.request.payload["purpose"]?.string ?? "dialogue") == "dialogue" else { return nil }
        return job.request.payload["conversation_id"]?.string ?? job.id
    }
    static func turns(_ jobs: [AILocalJob], conversation: String, deleted: Set<String>) -> [AILocalJob] {
        jobs.filter { self.conversation($0) == conversation && !deleted.contains($0.id) && $0.replacementID == nil }
            .sorted { $0.created == $1.created ? $0.id < $1.id : $0.created < $1.created }
    }
    static func history(_ jobs: [AILocalJob]) -> [JSONValue] {
        var pairs: [[JSONValue]] = []; var characters = 0
        for job in jobs.reversed() {
            guard job.status == "succeeded", let question = job.request.payload["question"]?.string,
                  let answer = job.result?.coach?.answer else { continue }
            let shortAnswer = String(answer.prefix(4000))
            guard pairs.count < 6, characters + question.count + shortAnswer.count <= 16000 else { break }
            characters += question.count + shortAnswer.count
            pairs.insert([.object(["role": .string("user"), "text": .string(question)]),
                          .object(["role": .string("assistant"), "text": .string(shortAnswer)])], at: 0)
        }
        return pairs.flatMap { $0 }
    }
}


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
if case .object(let value)=history[0]{check(value["role"] == .string("user"),"history begins with user data")}
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
