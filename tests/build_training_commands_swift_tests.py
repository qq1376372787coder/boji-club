from pathlib import Path
import subprocess,sys,tempfile
root=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory() as tmp:
    p=Path(tmp)/'base.swift'
    subprocess.run([sys.executable,str(root/'tests/build_history_swift_tests.py'),str(p)],check=True)
    content=p.read_text('utf-8')
def block(s,marker):
    start=s.index(marker);i=s.index('{',start);depth=1;j=i+1
    while depth:
        if s[j]=='{':depth+=1
        elif s[j]=='}':depth-=1
        j+=1
    return s[start:j]
ai=(root/'BojiClub/AIService.swift').read_text('utf-8')
sync=(root/'BojiClub/ClubProposalSync.swift').read_text('utf-8')
cards=(root/'BojiClub/AICards.swift').read_text('utf-8')
coach=(root/'BojiClub/ClubCoach.swift').read_text('utf-8')
store=(root/'BojiClub/AppStore.swift').read_text('utf-8')
extra=[block(ai,'enum JSONValue:')]
extra.append('enum ClubProposalSync {\n'+block(sync,'static func operationIdentity(')+'\n}')
extra.append(block(sync,'enum DomainCommandType {'))
extra.append(block(sync,'struct DomainCommandOutcome'))
extra.append('enum DomainCommands {\n'
    + block(sync,'static func identity(owner')
    + '\n' + block(sync,'static func startPayload(')
    + '\n' + block(sync,'static func finishPayload(')
    + '\n' + block(sync,'static func bodyWeightPayload(')
    + '\n}')
extra.append(block(sync,'struct PendingDomainCommand:'))
extra.append(block(coach,'struct CapabilityCall:'))
extra.append(block(cards,'struct AICardAction:'))
extra.append(block(cards,'extension JSONValue {'))
extra.append(block(cards,'struct AICardEnvelope:'))
extra.append(block(cards,'enum AICardRegistry {'))
extra.append(block(cards,'struct AIAdviceCardPayload:'))
extra.append(block(cards,'struct AIProposalPreviewPayload:'))
extra.append(block(cards,'struct AIClubProgressPayload:'))
extra.append('enum CapabilityRouter {\n'
    + block(sync,'static func commandType(forProposalKind')
    + '\n}')
extra.append(r'''
func tcArray(_ value: JSONValue?) -> [JSONValue] { if case .array(let items)? = value { return items }; return [] }
func tcObject(_ value: JSONValue?) -> [String: JSONValue] { if case .object(let dict)? = value { return dict }; return [:] }
func tcNumber(_ value: JSONValue?) -> Double? { if case .number(let n)? = value { return n }; return nil }
func tcBool(_ value: JSONValue?) -> Bool? { if case .bool(let b)? = value { return b }; return nil }

let tcSession = UUID()
// 操作身份确定性：同一意图 → 稳定 commandId/幂等键；换会话 → 新命令。
let tcID = ClubProposalSync.operationIdentity(owner: 7, intent: "training/start/2026-10-25/\(tcSession.uuidString.lowercased())")
let tcIDSame = ClubProposalSync.operationIdentity(owner: 7, intent: "training/start/2026-10-25/\(tcSession.uuidString.lowercased())")
let tcIDOther = ClubProposalSync.operationIdentity(owner: 7, intent: "training/start/2026-10-25/\(UUID().uuidString.lowercased())")
check(tcID.command == tcIDSame.command && tcID.key == tcIDSame.key, "the same intent yields a stable operation identity")
check(tcID.command != tcIDOther.command && tcID.key != tcIDOther.key, "a different session yields a new operation")
check(tcID.command.count == 36 && tcID.key.count == 64, "identity carries a UUID command id and a 64-hex idempotency key")
check(ClubProposalSync.operationIdentity(owner: 8, intent: "training/start/2026-10-25/\(tcSession.uuidString.lowercased())").key != tcID.key, "the key is bound to the account")

// 开始命令载荷只含服务端约定字段。
let tcStart = DomainCommands.startPayload(date: "2026-10-25", sessionID: tcSession)
check(tcStart["date"]?.string == "2026-10-25" && tcStart["session_id"]?.string == tcSession.uuidString.lowercased(), "start payload matches the server contract")

// 完成快照：只携带当前会话的动作，时间戳用 2001 参考基准。
var tcDay = DayLog(exercises: [
    Exercise(name: "杠铃卧推", muscle: "胸", sets: [TrainingSet(weight: 20, reps: 10, completed: true)], workoutSessionID: tcSession),
    Exercise(name: "杠铃深蹲", muscle: "腿", sets: [TrainingSet(weight: 40, reps: 8, completed: true)], workoutSessionID: UUID()),
])
tcDay.workoutStartedAt = now.addingTimeInterval(-1800)
tcDay.workoutEndedAt = now.addingTimeInterval(-60)
let tcFinish = DomainCommands.finishPayload(date: "2026-10-25", day: tcDay, sessionID: tcSession, savedAt: now)
check(tcFinish["session_id"]?.string == tcSession.uuidString.lowercased(), "finish payload binds the session")
check(tcArray(tcFinish["exercises"]).count == 1, "finish snapshot excludes other sessions' exercises")
let tcFirstSet = tcObject(tcArray(tcObject(tcArray(tcFinish["exercises"]).first)["sets"]).first)
check(tcBool(tcFirstSet["completed"]) == true && tcNumber(tcFirstSet["reps"]) == 10 && tcNumber(tcFirstSet["weight"]) == 20, "set completion rides in the snapshot")
check(abs((tcNumber(tcFinish["saved_at"]) ?? 0) - now.timeIntervalSinceReferenceDate) < 0.001, "saved_at uses the 2001 reference base")
check(abs((tcNumber(tcFinish["started_at"]) ?? 0) - now.addingTimeInterval(-1800).timeIntervalSinceReferenceDate) < 0.001, "started_at carries the real start")

// 无会话标识的历史动作仍归入当前会话（旧数据兼容）。
var tcLegacy = DayLog(exercises: [Exercise(name: "俯卧撑", muscle: "胸", sets: [TrainingSet(weight: 0, reps: 15, completed: true)])])
let tcLegacyPayload = DomainCommands.finishPayload(date: "2026-10-24", day: tcLegacy, sessionID: tcSession, savedAt: now)
check(tcArray(tcLegacyPayload["exercises"]).count == 1, "legacy exercises without a session id belong to the active session")

// 计时组带 duration_seconds 别名（服务端接受两种写法）。
var tcTimed = DayLog(exercises: [Exercise(name: "平板支撑", muscle: "核心", sets: [TrainingSet(weight: 0, reps: 0, completed: true, durationSeconds: 30)], workoutSessionID: tcSession)])
let tcTimedPayload = DomainCommands.finishPayload(date: "2026-10-25", day: tcTimed, sessionID: tcSession, savedAt: now)
check(tcNumber(tcObject(tcArray(tcObject(tcArray(tcTimedPayload["exercises"]).first)["sets"]).first)["duration_seconds"]) == 30, "timed sets carry the duration alias")

// 体重直记录载荷：空的可选字段不出现。
let tcWeight = DomainCommands.bodyWeightPayload(date: "2026-10-25", kilograms: 70.5, bodyFatPercentage: nil, waistCircumferenceCM: nil, recordedAt: now)
check(tcNumber(tcWeight["kilograms"]) == 70.5 && tcWeight["bodyFatPercentage"] == nil && abs((tcNumber(tcWeight["recorded_at"]) ?? 0) - now.timeIntervalSinceReferenceDate) < 0.001, "direct weight payload omits empty optional fields")
let tcWeightFull = DomainCommands.bodyWeightPayload(date: "2026-10-25", kilograms: 70.5, bodyFatPercentage: 18.2, waistCircumferenceCM: 82, recordedAt: now)
check(tcNumber(tcWeightFull["bodyFatPercentage"]) == 18.2 && tcNumber(tcWeightFull["waistCircumferenceCM"]) == 82, "direct weight payload carries optional measurements")

// 队列条目可持久化并可复原（离线重放的基础）。
let tcCommand = PendingDomainCommand(commandID: tcID.command, type: DomainCommandType.sessionFinish,
    payload: tcFinish, intent: "training/finish/2026-10-25/\(tcSession.uuidString.lowercased())",
    owner: 7, attempts: 2, createdAt: now)
let tcEncoded = try JSONEncoder().encode(tcCommand)
let tcDecoded = try JSONDecoder().decode(PendingDomainCommand.self, from: tcEncoded)
check(tcDecoded == tcCommand, "a queued command survives persistence")
check(tcDecoded.payload == tcCommand.payload && tcDecoded.type == DomainCommandType.sessionFinish, "persisted queue entry keeps its payload and type")

// Phase 2：卡片注册表覆盖新增类型，客户端白名单拒绝未知动作。
check(AICardRegistry.knownTypes.contains("advice") && AICardRegistry.knownTypes.contains("schedule_preview"), "phase 2 card types are registered")
check(AICardRegistry.knownTypes.contains("plan_swap_preview") && AICardRegistry.knownTypes.contains("plan_activate_preview"), "plan preview cards are registered")
check(AICardRegistry.actionWhitelist.contains("confirm_proposal") && AICardRegistry.actionWhitelist.contains("dismiss_proposal"), "proposal actions stay whitelisted")
check(AICardRegistry.actionWhitelist.contains("check_execution") && AICardRegistry.actionWhitelist.contains("undo_action"), "execution and undo actions are whitelisted")
check(!AICardRegistry.knownTypes.contains("delete_everything"), "unknown card types never become renderable")

// 建议卡载荷：缺字段 → nil，绝不猜测。
let tcAdvice = AIAdviceCardPayload(json: .object([
    "options": .array([.object(["choice": .string("rest"), "label": .string("休息"), "reason": .string("近 7 天训练 6 天")])]),
    "note": .string("只依据已确认记录")
]))
check(tcAdvice != nil && tcAdvice!.options.count == 1 && tcAdvice!.options[0].label == "休息", "advice card decodes its options")
check(AIAdviceCardPayload(json: .object(["options": .array([])])) == nil, "an advice card without options is rejected")

// 提案预览卡必须绑定 proposal_id。
let tcProposal = AIProposalPreviewPayload(json: .object([
    "proposal_id": .string("prop-01"), "kind": .string("exercise_swap"), "expires_at": .string("2026-10-25T00:00:00+08:00")
]))
check(tcProposal != nil && tcProposal!.kind == "exercise_swap" && tcProposal!.proposalID == "prop-01", "preview card binds the server proposal")
check(AIProposalPreviewPayload(json: .object(["kind": .string("exercise_swap")])) == nil, "a preview card without a proposal id is rejected")

// 提案类型 → 执行命令映射（服务端只认这些类型）。
check(CapabilityRouter.commandType(forProposalKind: "plan_change_proposal") == "PlanReschedule.Confirm", "schedule proposal maps to its confirm command")
check(CapabilityRouter.commandType(forProposalKind: "exercise_swap") == "ExerciseSwap.Confirm", "exercise swap maps to its confirm command")
check(CapabilityRouter.commandType(forProposalKind: "plan_activation") == "PlanVersion.Activate", "plan activation maps to its confirm command")
check(CapabilityRouter.commandType(forProposalKind: "meal_draft") == "Meal.Create", "meal draft maps to its confirm command")
check(CapabilityRouter.commandType(forProposalKind: "unknown_kind") == nil, "an unknown proposal kind has no command")

// 能力调用载荷可持久化（离线队列基础）。
let tcCall = CapabilityCall(capability: "training.get_today", input: ["date": .string("2026-10-25")])
let tcCallData = try JSONEncoder().encode(tcCall)
let tcCallDecoded = try JSONDecoder().decode(CapabilityCall.self, from: tcCallData)
check(tcCallDecoded == tcCall, "a capability call survives persistence")
print("Training commands: \(tests) combined behavioral checks passed")
''')
Path(sys.argv[1]).write_text(content+'\n'+'\n'.join(extra)+'\n','utf-8')
