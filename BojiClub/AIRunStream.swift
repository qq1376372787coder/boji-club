import Foundation
import CryptoKit

extension JSONValue {
    subscript(key: String) -> JSONValue? {
        if case .object(let value) = self { return value[key] }
        return nil
    }
}

/// Phase 2 §3.2–3.4: SSE frame parsing, ordered run reducer and reconnect loop.
/// The server owns the durable run; this client only renders validated deltas
/// and never treats a transport error as business cancellation.

struct SSEFrame: Equatable {
    var id: Int?
    var event: String
    var data: String
}

/// Stateful parser for one SSE stream. Handles CRLF, comments, multi-line data
/// and the blank-line dispatch rule. UTF-8 boundaries are handled by
/// `URLSession.AsyncBytes.lines` before lines reach this parser.
struct SSEFrameParser {
    private var id: Int?
    private var event: String?
    private var dataLines: [String] = []

    mutating func consume(line raw: String) -> SSEFrame? {
        var line = raw
        if line.hasSuffix("\r") { line.removeLast() }
        if line.isEmpty {
            guard !dataLines.isEmpty else { reset(); return nil }
            let frame = SSEFrame(id: id, event: event ?? "message", data: dataLines.joined(separator: "\n"))
            reset()
            return frame
        }
        if line.hasPrefix(":") { return nil }
        let field: String, value: String
        if let colon = line.firstIndex(of: ":") {
            field = String(line[..<colon])
            var remainder = String(line[line.index(after: colon)...])
            if remainder.hasPrefix(" ") { remainder.removeFirst() }
            value = remainder
        } else {
            field = line; value = ""
        }
        switch field {
        case "id": id = Int(value)
        case "event": event = value
        case "data": dataLines.append(value)
        default: break
        }
        return nil
    }

    private mutating func reset() { id = nil; event = nil; dataLines.removeAll(keepingCapacity: true) }
}

struct AIRunEvent: Decodable, Equatable {
    var run_id: String
    var seq: Int
    var event_id: String
    var type: String
    var ts: String
    var data: JSONValue

    static func decode(_ frame: SSEFrame) throws -> AIRunEvent {
        try JSONDecoder().decode(AIRunEvent.self, from: Data(frame.data.utf8))
    }

    var object: [String: JSONValue] {
        if case .object(let value) = data { return value }
        return [:]
    }
}

struct AIRunReducer {
    private(set) var lastSeq = 0
    private(set) var text = ""
    private(set) var status = "queued"
    private(set) var cards: [String: AICardEnvelope] = [:]
    private(set) var error: String?
    private(set) var completed = false
    private(set) var traceID: String?
    private(set) var usage: [String: JSONValue]?
    private(set) var needsResync = false

    mutating func reset() {
        lastSeq = 0; text = ""; status = "queued"; cards = [:]; error = nil
        completed = false; traceID = nil; usage = nil; needsResync = false
    }

    /// Returns false for duplicates, out-of-order frames and gaps (a gap needs
    /// a snapshot resync; replaying deltas would corrupt the text).
    mutating func apply(_ event: AIRunEvent) -> Bool {
        if event.seq <= lastSeq { return false }
        if lastSeq > 0, event.seq != lastSeq + 1 { needsResync = true; return false }
        lastSeq = event.seq
        let data = event.object
        switch event.type {
        case "run.created":
            if let trace = data["trace_id"]?.string { traceID = trace }
            if let value = data["status"]?.string { status = value }
        case "run.status":
            if let value = data["status"]?.string { status = value }
        case "assistant.text.delta":
            if let delta = data["delta"]?.string { text += delta }
        case "assistant.text.snapshot":
            if let value = data["text"]?.string { text = value }
        case "card.upsert":
            guard let cardValue = data["card"], let raw = try? JSONEncoder().encode(cardValue),
                  let card = try? JSONDecoder().decode(AICardEnvelope.self, from: raw) else { break }
            cards[card.card_id] = card
        case "usage.summary":
            if case .object(let value) = data["usage"] ?? event.data { usage = value }
        case "run.completed":
            completed = true
            status = "completed"
        case "run.failed":
            error = data["message"]?.string ?? "这次分析未能完成，输入已保留。"
            status = "failed"
        case "run.cancelled":
            error = "这次对话已取消。"
            status = "cancelled"
        default:
            break
        }
        return true
    }

    mutating func requireResync() { needsResync = true }

    mutating func adopt(snapshot: AIRunSnapshot) {
        lastSeq = snapshot.run.last_event_seq
        status = snapshot.run.status
        traceID = snapshot.run.trace_id
        completed = snapshot.run.terminal
        needsResync = false
        if let coach = snapshot.message?.coach {
            text = coach.answer
        }
        if let errorCode = snapshot.run.error_code, status == "failed" {
            error = AIRunFailureText125.message(code: errorCode)
        }
    }
}

// MARK: - Wire models

struct AIRunCreateResponse: Decodable {
    var run_id: String
    var message_id: String
    var status: String
    var stream_url: String
    var last_event_seq: Int
    var trace_id: String
    var idempotent: Bool?
}

struct AIRunSnapshot: Decodable {
    struct Run: Decodable {
        var run_id: String
        var message_id: String
        var status: String
        var last_event_seq: Int
        var trace_id: String
        var terminal: Bool
        var error_code: String?
    }
    struct Message: Decodable {
        var id: Int
        var role: String
        var content: String
        var coach: ClubCoachAnswer?
    }
    var run: Run
    var message: Message?
    var cards: [AICardEnvelope]?
    /// Authoritative result object for non-coach runs (report / weekly_review).
    /// Coach runs keep using `message.coach`; this stays nil for them.
    var result: JSONValue?
}

enum AIRunStreamError: Error, LocalizedError {
    case unavailable(String)
    case createRejected(String)
    case createUncertain(String)
    case failed(String)
    case resyncUnavailable

    var errorDescription: String? {
        switch self {
        case .unavailable(let text), .createRejected(let text), .createUncertain(let text), .failed(let text): return text
        case .resyncUnavailable: return "流式连接中断，暂时无法恢复这次回答。"
        }
    }
}

struct AIRunCompletion {
    var runID: String
    var messageID: String
    var traceID: String
    var coach: ClubCoachAnswer
}

// MARK: - Resume state (per account, per conversation)

struct AIRunResume: Codable, Equatable {
    var runID: String
    var messageID: String
    var conversation: String
    var traceID: String
    var input: AIInput
    var updatedAt: Date
}

enum AIRunResumeStore {
    private static func key(owner: Int, conversation: String) -> String {
        "club-ai-run.v1.\(owner).\(conversation)"
    }
    private static func indexKey(owner: Int) -> String { "club-ai-run-index.v1.\(owner)" }

    static func save(_ value: AIRunResume, owner: Int, defaults: UserDefaults = .standard) {
        guard owner != 0, UUID(uuidString: value.conversation) != nil,
              let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key(owner: owner, conversation: value.conversation))
        var ids = defaults.stringArray(forKey: indexKey(owner: owner)) ?? []
        ids.removeAll { $0 == value.conversation }
        ids.insert(value.conversation, at: 0)
        defaults.set(Array(ids.prefix(20)), forKey: indexKey(owner: owner))
    }

    static func load(owner: Int, conversation: String, defaults: UserDefaults = .standard) -> AIRunResume? {
        guard owner != 0, let data = defaults.data(forKey: key(owner: owner, conversation: conversation)) else { return nil }
        return try? JSONDecoder().decode(AIRunResume.self, from: data)
    }

    static func clear(owner: Int, conversation: String, defaults: UserDefaults = .standard) {
        guard owner != 0 else { return }
        defaults.removeObject(forKey: key(owner: owner, conversation: conversation))
        var ids = defaults.stringArray(forKey: indexKey(owner: owner)) ?? []
        ids.removeAll { $0 == conversation }
        defaults.set(ids, forKey: indexKey(owner: owner))
    }

    static func erase(owner: Int, defaults: UserDefaults = .standard) {
        guard owner != 0 else { return }
        let prefix = "club-ai-run.v1.\(owner)."
        for item in defaults.dictionaryRepresentation().keys where item.hasPrefix(prefix) {
            defaults.removeObject(forKey: item)
        }
        defaults.removeObject(forKey: indexKey(owner: owner))
    }
}

// MARK: - Transport (injectable for reconnect tests)

@MainActor
protocol AIRunStreamTransport: AnyObject {
    func create(input: AIInput, conversation: String, clientMessageID: String, owner: Int) async throws -> AIRunCreateResponse
    func events(runID: String, afterSeq: Int, owner: Int, traceID: String?) async throws -> (lines: AsyncThrowingStream<String, Error>, status: Int)
    func snapshot(runID: String, owner: Int) async throws -> AIRunSnapshot
    func cancel(runID: String, owner: Int) async
}

@MainActor
final class AccountRunTransport: AIRunStreamTransport {
    private let account: AccountService
    init(_ account: AccountService) { self.account = account }

    static func creationError(status: Int, data: Data) -> AIRunStreamError {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let message = object?["error"] as? String
        if status == 404 || (status == 503 && message == "流式对话暂未开放，请稍后再试。") {
            return .unavailable("流式对话暂不可用，正在改用原方式。")
        }
        if status >= 500 {
            return .createUncertain("服务器尚未确认提交结果，已保留原消息，请稍后恢复。")
        }
        return .createRejected(message ?? "消息未被接受（\(status)），请稍后重试。")
    }

    private struct CreateBody: Encodable {
        struct Message: Encodable { var type = "text"; var text: String }
        var client_message_id: String
        var message: Message
        var request: AIRequest
        var locale: String
        var client_timezone: String
        var attachments: [JSONValue]
        var onboarding_session_id: String?
        var context_source: JSONValue?
    }

    func create(input: AIInput, conversation: String, clientMessageID: String, owner: Int) async throws -> AIRunCreateResponse {
        try await account.syncAIConsentDecision(owner: owner)
        var payload = input.payload
        payload["_routing_version"] = .number(Double(CloudAnalysisConsent.routerVersion(accountID: owner)))
        var request = AIRequest(id: clientMessageID, kind: input.kind, date: input.date, payload: payload)
        request.onboardingSessionID = input.payload["_onboarding_session_id"]?.string
        let body = CreateBody(client_message_id: clientMessageID,
                              message: .init(text: input.payload["question"]?.string ?? ""),
                              request: request, locale: "zh-CN",
                              client_timezone: TimeZone.current.identifier, attachments: [],
                              onboarding_session_id: input.payload["_onboarding_session_id"]?.string,
                              context_source: input.payload["_context_source"])
        let response = try await account.cloudRequest(
            path: "/me/ai/conversations/" + conversation + "/runs", method: "POST",
            body: try JSONEncoder().encode(body), expectedUserID: owner,
            headers: ["Idempotency-Key": clientMessageID])
        guard response.statusCode == 202 || response.statusCode == 200 else {
            throw Self.creationError(status: response.statusCode, data: response.data)
        }
        return try JSONDecoder().decode(AIRunCreateResponse.self, from: response.data)
    }

    func events(runID: String, afterSeq: Int, owner: Int, traceID: String?) async throws -> (lines: AsyncThrowingStream<String, Error>, status: Int) {
        let (bytes, response) = try await account.cloudStream(
            path: "/me/ai/runs/" + runID + "/events?after_seq=\(afterSeq)",
            expectedUserID: owner, afterSeq: afterSeq, traceID: traceID)
        let lines = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines { continuation.yield(line) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return (lines, response.statusCode)
    }

    func snapshot(runID: String, owner: Int) async throws -> AIRunSnapshot {
        let response = try await account.cloudRequest(path: "/me/ai/runs/" + runID, expectedUserID: owner)
        guard response.statusCode == 200 else { throw AIRunStreamError.resyncUnavailable }
        return try JSONDecoder().decode(AIRunSnapshot.self, from: response.data)
    }

    func cancel(runID: String, owner: Int) async {
        _ = try? await account.cloudRequest(path: "/me/ai/runs/" + runID + "/cancel", method: "POST",
                                           body: Data("{}".utf8), expectedUserID: owner)
    }
}

// MARK: - Pending send identity (survives a lost POST response)

struct AIRunPendingSend: Codable, Equatable {
    var clientMessageID: String
    var conversation: String
    var input: AIInput
    var requestHash: String
    var createdAt: Date
}

enum AIRunPendingStore {
    private static func key(owner: Int, conversation: String) -> String {
        "club-ai-pending-run.v1.\(owner).\(conversation)"
    }
    private static func indexKey(owner: Int) -> String { "club-ai-pending-run-index.v1.\(owner)" }

    static func requestHash(_ input: AIInput) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(input)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func save(_ value: AIRunPendingSend, owner: Int, defaults: UserDefaults = .standard) {
        guard owner != 0, let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key(owner: owner, conversation: value.conversation))
        var ids = defaults.stringArray(forKey: indexKey(owner: owner)) ?? []
        ids.removeAll { $0 == value.conversation }
        ids.insert(value.conversation, at: 0)
        defaults.set(Array(ids.prefix(20)), forKey: indexKey(owner: owner))
    }

    static func load(owner: Int, conversation: String, defaults: UserDefaults = .standard) -> AIRunPendingSend? {
        guard owner != 0, let data = defaults.data(forKey: key(owner: owner, conversation: conversation)) else { return nil }
        return try? JSONDecoder().decode(AIRunPendingSend.self, from: data)
    }

    static func clear(owner: Int, conversation: String, defaults: UserDefaults = .standard) {
        guard owner != 0 else { return }
        defaults.removeObject(forKey: key(owner: owner, conversation: conversation))
        var ids = defaults.stringArray(forKey: indexKey(owner: owner)) ?? []
        ids.removeAll { $0 == conversation }
        defaults.set(ids, forKey: indexKey(owner: owner))
    }

    static func erase(owner: Int, defaults: UserDefaults = .standard) {
        guard owner != 0 else { return }
        let prefix = "club-ai-pending-run.v1.\(owner)."
        for item in defaults.dictionaryRepresentation().keys where item.hasPrefix(prefix) {
            defaults.removeObject(forKey: item)
        }
        defaults.removeObject(forKey: indexKey(owner: owner))
    }
}

enum AIRunOutcomeUnknown: Error { case create }

// MARK: - Observable live run

@MainActor
final class AIRunStreamStore: ObservableObject {
    enum Phase: Equatable { case idle, creating, streaming, saving, finished, failed }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var streamText = ""
    @Published private(set) var statusLine: String?
    @Published private(set) var error: String?
    @Published private(set) var traceID: String?
    @Published private(set) var question: String?
    @Published private(set) var didCreateRun = false
    /// The POST may have reached the server but no response was received.
    /// The caller must NOT fall back to a new polling job in this state.
    @Published private(set) var outcomeUnknown = false
    @Published private(set) var allowsLegacyFallback = false

    private var generation = UUID()
    private var reducer = AIRunReducer()
    private var task: Task<AIRunCompletion?, Never>?
    private var runID: String?
    private var pendingIdentity: AIRunPendingSend?
    private var transport: AIRunStreamTransport?
    private var owner = 0
    private var conversation = ""
    private(set) var clientMessageID = ""
    private var cleanupTimer: Task<Void, Never>?
    private var textFlush: Task<Void, Never>?

    var isActive: Bool { phase == .creating || phase == .streaming || phase == .saving }
    /// Test seam: inject a scripted transport without an account session.
    func useTransport(_ value: AIRunStreamTransport) { transport = value }
    var conversationKey: String { conversation }

    func start(input: AIInput, conversation: String, owner: Int, account: AccountService? = nil, preferredMessageID: String? = nil) async -> AIRunCompletion? {
        stopTask()
        reset()
        if let account { transport = AccountRunTransport(account) }
        guard transport != nil else { return nil }
        self.owner = owner; self.conversation = conversation
        self.question = input.payload["question"]?.string
        let hash = AIRunPendingStore.requestHash(input)
        if let pending = AIRunPendingStore.load(owner: owner, conversation: conversation) {
            guard pending.requestHash == hash else {
                error = "上一条消息仍在确认中，请稍后重试或重新打开对话。"
                phase = .failed
                return nil
            }
            pendingIdentity = pending
            clientMessageID = pending.clientMessageID
        } else {
            let pending = AIRunPendingSend(clientMessageID: preferredMessageID ?? UUID().uuidString.lowercased(),
                                           conversation: conversation, input: input,
                                           requestHash: hash, createdAt: Date())
            AIRunPendingStore.save(pending, owner: owner)
            pendingIdentity = pending
            clientMessageID = pending.clientMessageID
        }
        didCreateRun = false; outcomeUnknown = false; allowsLegacyFallback = false
        phase = .creating
        statusLine = "正在连接 Club AI…"
        let task = Task { [weak self] () -> AIRunCompletion? in
            guard let self else { return nil }
            return await self.run(input: input)
        }
        let operation = generation
        self.task = task
        let outcome = await task.value
        guard operation == generation else { return nil }
        if outcome == nil, phase != .failed { error = "回答暂时中断，原消息已保留。"; phase = .failed }
        return outcome
    }

    /// Resume a durable run after foreground/relaunch. Events are replayed from
    /// seq 0 so text is rebuilt without trusting local partial state.
    func resume(_ saved: AIRunResume, owner: Int, account: AccountService? = nil) async -> AIRunCompletion? {
        stopTask()
        reset()
        if let account { transport = AccountRunTransport(account) }
        guard transport != nil else { return nil }
        self.owner = owner; self.conversation = saved.conversation
        self.clientMessageID = saved.messageID; self.runID = saved.runID
        self.pendingIdentity = nil
        self.outcomeUnknown = false
        self.question = saved.input.payload["question"]?.string
        phase = .streaming
        statusLine = "正在恢复对话…"
        let task = Task { [weak self] () -> AIRunCompletion? in
            guard let self else { return nil }
            return await self.stream(resumeInput: saved.input)
        }
        let operation = generation
        self.task = task
        let outcome = await task.value
        guard operation == generation else { return nil }
        if outcome == nil, phase != .failed { error = "回答暂时中断，原消息已保留。"; phase = .failed }
        return outcome
    }

    func cancel() {
        stopTask(cancelRemote: true)
        if owner != 0, !conversation.isEmpty {
            AIRunPendingStore.clear(owner: owner, conversation: conversation)
        }
        pendingIdentity = nil
        phase = .idle
    }

    private func stopTask(cancelRemote: Bool = false) {
        cleanupTimer?.cancel(); textFlush?.cancel()
        task?.cancel(); task = nil
        if cancelRemote, let transport, let runID, owner != 0, phase == .streaming || phase == .creating {
            let ownerID = owner
            Task { await transport.cancel(runID: runID, owner: ownerID) }
        }
    }

    /// Remove the live bubble as soon as the finished turn is imported into
    /// the normal local transcript (jobs are inserted synchronously).
    func clearAfterImport() {
        cleanupTimer?.cancel()
        if owner != 0, !conversation.isEmpty {
            AIRunResumeStore.clear(owner: owner, conversation: conversation)
            AIRunPendingStore.clear(owner: owner, conversation: conversation)
        }
        reset()
    }

    // MARK: internals

    func preserveImportFailure130() {
        phase = .failed
        error = "回答已生成，正在等待保存到手机。可恢复这次回答。"
        statusLine = nil
    }

    private func reset() {
        generation = UUID()
        reducer.reset()
        streamText = ""; statusLine = nil; error = nil; traceID = nil
        question = nil; runID = nil; clientMessageID = ""; phase = .idle; didCreateRun = false; outcomeUnknown = false; allowsLegacyFallback = false
    }

    private func run(input: AIInput) async -> AIRunCompletion? {
        guard let transport else { return nil }
        let operation = generation
        do {
            let created = try await createWithRetry(transport: transport, input: input)
            guard !Task.isCancelled, operation == generation else { return nil }
            runID = created.run_id
            traceID = created.trace_id
            didCreateRun = true
            outcomeUnknown = false
            reducer.reset()
            AIRunResumeStore.save(AIRunResume(runID: created.run_id, messageID: created.message_id,
                                              conversation: conversation, traceID: created.trace_id,
                                              input: input, updatedAt: Date()), owner: owner)
            // The durable run identity is now recoverable; a pending POST is no
            // longer needed.
            AIRunPendingStore.clear(owner: owner, conversation: conversation)
            pendingIdentity = nil
            phase = .streaming
            statusLine = "正在分析…"
            return await stream(resumeInput: input)
        } catch let error as AIRunStreamError {
            guard !Task.isCancelled, operation == generation else { return nil }
            if case .createUncertain = error {
                outcomeUnknown = true
                self.error = error.errorDescription
                phase = .failed
                return nil
            }
            // A conflict, quota rejection or auth error never opens a second channel.
            if case .unavailable = error { allowsLegacyFallback = true }
            AIRunPendingStore.clear(owner: owner, conversation: conversation)
            pendingIdentity = nil
            self.error = error.errorDescription
            phase = .failed
            outcomeUnknown = false
            return nil
        } catch {
            guard !Task.isCancelled, operation == generation else { return nil }
            // Timeout / connection lost after the request may have been
            // committed. Keep the same identity and never create a second job.
            outcomeUnknown = true
            self.error = "提交结果暂未确认，已保留同一条消息；正在等待恢复，不会重复创建任务。"
            phase = .failed
            return nil
        }
    }

    private func createWithRetry(transport: AIRunStreamTransport, input: AIInput) async throws -> AIRunCreateResponse {
        var attempt = 0
        while true {
            do {
                return try await transport.create(input: input, conversation: conversation,
                                                  clientMessageID: clientMessageID, owner: owner)
            } catch let error as AIRunStreamError {
                throw error
            } catch {
                if Task.isCancelled { throw CancellationError() }
                attempt += 1
                if attempt >= 3 { throw AIRunOutcomeUnknown.create }
                try? await Task.sleep(for: .milliseconds(400 * attempt))
            }
        }
    }

    /// The connection reader and the authority snapshot are independent. A silent
    /// HTTP 200 connection cannot keep the composer busy forever.
    private func stream(resumeInput: AIInput) async -> AIRunCompletion? {
        guard let transport, let runID else { return nil }
        let ticket = generation
        let started = Date()
        let budget: TimeInterval = resumeInput.payload["deep_analysis"] == .bool(true) ? 180 : 90
        var attempt = 0
        var lastProgress = Date()
        var lastCheck = Date()
        var sequence = reducer.lastSeq
        while !Task.isCancelled {
            let connection = AIRunConnectionState()
            let reader = Task { @MainActor [weak self] in
                guard let self, self.generation == ticket else { connection.ended = true; return }
                defer { connection.ended = true }
                do {
                    let (lines, status) = try await transport.events(runID: runID, afterSeq: self.reducer.lastSeq, owner: self.owner, traceID: self.traceID)
                    guard status == 200 else { connection.error = AIRunStreamError.resyncUnavailable; return }
                    var parser = SSEFrameParser()
                    for try await line in lines {
                        if Task.isCancelled || self.generation != ticket { return }
                        guard let frame = parser.consume(line: line), let event = try? AIRunEvent.decode(frame) else { continue }
                        if self.reducer.apply(event) {
                            self.applyReducer(flush: self.reducer.completed || self.reducer.status == "failed")
                        }
                        if self.reducer.completed || ["failed", "cancelled"].contains(self.reducer.status) || self.reducer.needsResync { return }
                    }
                } catch { if !Task.isCancelled { connection.error = error } }
            }
            // Cancellation only closes this reader. It never cancels the server run.
            defer { reader.cancel() }
            while !Task.isCancelled, generation == ticket {
                if sequence != reducer.lastSeq { sequence = reducer.lastSeq; lastProgress = Date() }
                let now = Date()
                let terminal = reducer.completed || ["failed", "cancelled"].contains(reducer.status)
                if terminal || connection.ended || reducer.needsResync || now.timeIntervalSince(lastCheck) >= 10 {
                    lastCheck = now
                    if let completion = await resync(input: resumeInput) { reader.cancel(); return completion }
                    if phase == .failed { reader.cancel(); return nil }
                }
                if now.timeIntervalSince(started) >= budget {
                    reader.cancel()
                    error = "回答仍在服务器处理，已保留原任务。可离开页面，稍后重新打开本对话恢复，不会重复提交。"
                    phase = .failed
                    return nil
                }
                if now.timeIntervalSince(lastProgress) >= 30 { statusLine = "仍在处理，可以离开后再查看…" }
                if connection.ended { break }
                do { try await Task.sleep(for: .milliseconds(250)) } catch { reader.cancel(); return nil }
            }
            reader.cancel()
            if Task.isCancelled { return nil }
            attempt += 1
            if attempt >= 6 {
                error = "连接暂时无法恢复，原任务与问题已保留；重新打开本对话可继续查看。"
                phase = .failed
                return nil
            }
            do { try await Task.sleep(for: .seconds(min(6, 0.5 * pow(2, Double(attempt))))) } catch { return nil }
        }
        return nil
    }

    private func applyReducer(flush: Bool) {
        statusLine = {
            switch reducer.status {
            case "queued": return "已排队…"
            case "running", "composing": return "正在分析…"
            case "resolving_actions": return "正在核对操作结果…"
            case "retrying": return "分析服务繁忙，正在重试…"
            case "completed": return "正在保存结果…"
            case "failed": return "本次分析未完成"
            case "cancelled": return "已取消"
            default: return "正在分析…"
            }
        }()
        if let trace = reducer.traceID { traceID = trace }
        if flush {
            textFlush?.cancel(); textFlush = nil
            streamText = reducer.text
        } else if textFlush == nil {
            textFlush = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, !Task.isCancelled else { return }
                self.streamText = self.reducer.text
                self.textFlush = nil
            }
        }
    }

    private func finish(input: AIInput) async -> AIRunCompletion? {
        if let message = reducer.error {
            error = message
            phase = .failed
            return nil
        }
        if let completion = await resync(input: input) { return completion }
        if reducer.status == "failed" {
            phase = .failed
            return nil
        }
        return nil
    }

    private func resync(input: AIInput) async -> AIRunCompletion? {
        guard let transport, let runID else { return nil }
        let ticket = generation
        for attempt in 0..<3 {
            do {
                let snapshot = try await transport.snapshot(runID: runID, owner: owner)
                guard !Task.isCancelled, generation == ticket else { return nil }
                reducer.adopt(snapshot: snapshot)
                applyReducer(flush: true)
                if let coach = snapshot.message?.coach {
                    phase = .saving
                    return AIRunCompletion(runID: runID, messageID: snapshot.run.message_id,
                                           traceID: snapshot.run.trace_id, coach: coach)
                }
                if snapshot.run.terminal {
                    if snapshot.run.status == "completed" && attempt < 2 {
                        // Completed but the message read is not visible yet
                        // (commit/replica race): keep verifying, never go idle
                        // with a silent empty answer.
                        try? await Task.sleep(for: .milliseconds(250 * (attempt + 1)))
                        continue
                    }
                    if snapshot.run.status == "failed" {
                        error = reducer.error ?? "这次分析未能完成，输入已保留。"
                        phase = .failed
                    } else if snapshot.run.status == "cancelled" {
                        error = "这次对话已取消。"; phase = .failed
                    } else {
                        error = "回答已完成但消息暂不可见，已保留任务；请重新打开对话核对。"
                        phase = .failed
                    }
                    return nil
                }
                return nil
            } catch {
                if attempt < 2 { try? await Task.sleep(for: .milliseconds(250 * (attempt + 1))); continue }
                return nil
            }
        }
        return nil
    }
}

@MainActor private final class AIRunConnectionState {
    var ended = false
    var error: Error?
}

// MARK: - Phase 3: non-coach kinds (report / weekly_review)

/// Phase 3: durable Run + SSE client for the non-coach analysis kinds
/// (report / weekly_review).
///
/// Deliberately self-contained: it reuses `SSEFrameParser` from AIRunStream but
/// owns a separate reducer, because these results are structured JSON rather
/// than chat text. The server owns the durable run; this client only renders
/// validated snapshots and never treats a transport error as cancellation.
///
/// Fallback contract:
/// - `disabled` / `rejected`  → the caller may retry through the legacy polling
///   path with the same `client_job_id` (the server maps both to one Python job).
/// - `uncertain`              → the create POST may have been accepted. The
///   caller must NOT start a second job; it resumes by snapshot instead.

enum AIRunKindError: Error, LocalizedError {
    case disabled(String)
    case rejected(String)
    case uncertain(String)
    case failed(String)
    case resyncUnavailable

    var errorDescription: String? {
        switch self {
        case .disabled(let text), .rejected(let text), .uncertain(let text), .failed(let text): return text
        case .resyncUnavailable: return "流式连接中断，暂时无法恢复这次分析。"
        }
    }
}

/// Raw result payload plus trace identity. Callers decode `result` into the
/// type their view model already uses (`AIResult` for report, `WeeklyResult`
/// for weekly_review) so nothing is lost for either kind.
struct AIRunKindOutcome {
    var result: JSONValue
    var traceID: String
    var runID: String

    func aiResult() throws -> AIResult {
        let raw = try JSONEncoder().encode(result)
        return try JSONDecoder().decode(AIResult.self, from: raw)
    }

    func weeklyResult() throws -> WeeklyResult {
        let raw = try JSONEncoder().encode(result)
        return try JSONDecoder().decode(WeeklyResult.self, from: raw)
    }
}

/// Wire event envelope emitted by `aiRunStream` / the durable run worker.
struct AIRunKindEvent: Decodable {
    var run_id: String
    var seq: Int
    var event_id: String
    var type: String
    var ts: String?
    var data: JSONValue
}

@MainActor
enum AIRunKindRunner {

    // MARK: - Create

    private struct CreateBody: Encodable {
        var client_job_id: String
        var kind: String
        var request: AIRequest
        var client_timezone: String
    }

    private static func create(input: AIInput, clientJobID: String, owner: Int,
                               account: AccountService) async throws -> AIRunCreateResponse {
        try await account.syncAIConsentDecision(owner: owner)
        var payload = input.payload
        payload["_routing_version"] = .number(Double(CloudAnalysisConsent.routerVersion(accountID: owner)))
        let request = AIRequest(id: clientJobID, kind: input.kind, date: input.date, payload: payload)
        let body = CreateBody(client_job_id: clientJobID, kind: input.kind, request: request,
                              client_timezone: TimeZone.current.identifier)
        let response = try await account.cloudRequest(
            path: "/me/ai/jobs/runs", method: "POST",
            body: try JSONEncoder().encode(body), expectedUserID: owner,
            headers: ["Idempotency-Key": clientJobID])
        if response.statusCode == 200 || response.statusCode == 202 {
            return try JSONDecoder().decode(AIRunCreateResponse.self, from: response.data)
        }
        let object = (try? JSONSerialization.jsonObject(with: response.data)) as? [String: Any]
        let message = (object?["error"] as? String) ?? "分析未被接受（\(response.statusCode)）。"
        let code = object?["error_code"] as? String
        // Not enabled, kind not in the allowlist, or the route is gone: fall back.
        if response.statusCode == 404 || response.statusCode == 503 || code == "run_v2_disabled" || code == "run_v2_kind_disabled" {
            throw AIRunKindError.disabled(message)
        }
        // The server may already be working on this client_job_id. Never resubmit.
        if response.statusCode >= 500 { throw AIRunKindError.uncertain(message) }
        throw AIRunKindError.rejected(message)
    }

    // MARK: - Run

    /// Runs one analysis to a terminal state. `deadline` bounds the whole attempt
    /// so a silently broken stream cannot spin forever.
    static func run(input: AIInput, clientJobID: String, owner: Int, account: AccountService,
                    deadline: Date = Date().addingTimeInterval(600)) async throws -> AIRunKindOutcome {
        let created = try await create(input: input, clientJobID: clientJobID, owner: owner, account: account)
        let runID = created.run_id
        var afterSeq = created.last_event_seq

        while Date() < deadline {
            if Task.isCancelled { throw CancellationError() }
            do {
                let (bytes, response) = try await account.cloudStream(
                    path: "/me/ai/runs/" + runID + "/events?after_seq=\(afterSeq)",
                    expectedUserID: owner, afterSeq: afterSeq, traceID: created.trace_id)
                if response.statusCode == 410 {
                    // Event log pruned: resync from the authoritative snapshot.
                    let snapshot = try await snapshot(runID: runID, owner: owner, account: account)
                    if let result = snapshot.result { return AIRunKindOutcome(result: result, traceID: created.trace_id, runID: runID) }
                    if snapshot.run.terminal {
                        throw AIRunKindError.failed(snapshot.run.error_code.map(AIRunFailureText125.message) ?? "这次分析未能完成。")
                    }
                    afterSeq = snapshot.run.last_event_seq
                    continue
                }
                guard (200..<300).contains(response.statusCode) else {
                    if response.statusCode >= 500 { throw AIRunKindError.uncertain("流式服务暂时不可用。") }
                    throw AIRunKindError.disabled("流式服务暂不可用。")
                }
                let reduced = try await consume(bytes: bytes, startSeq: afterSeq)
                afterSeq = reduced.lastSeq
                if let result = reduced.result { return AIRunKindOutcome(result: result, traceID: created.trace_id, runID: runID) }
                if let failure = reduced.failure { throw AIRunKindError.failed(failure) }
                if reduced.cancelled { throw AIRunKindError.failed("这次分析已取消。") }
            } catch let error as AIRunKindError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Transport dropped without a terminal frame: reconnect by cursor.
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        throw AIRunKindError.failed("分析耗时较久，已保留输入，可稍后继续查看。")
    }

    private struct Reduced {
        var lastSeq: Int
        var result: JSONValue?
        var failure: String?
        var cancelled = false
    }

    private static func consume(bytes: URLSession.AsyncBytes, startSeq: Int) async throws -> Reduced {
        var parser = SSEFrameParser()
        var state = Reduced(lastSeq: startSeq)
        for try await line in bytes.lines {
            if Task.isCancelled { throw CancellationError() }
            guard let frame = parser.consume(line: line) else { continue }
            let seq = frame.id ?? state.lastSeq
            guard seq > state.lastSeq else { continue }   // dedupe by cursor
            guard let data = frame.data.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = try? JSONSerialization.data(withJSONObject: object),
                  let event = try? JSONDecoder().decode(AIRunKindEvent.self, from: payload) else { continue }
            state.lastSeq = seq
            switch event.type {
            case "result.snapshot":
                state.result = event.data["result"] ?? .null
            case "run.failed":
                state.failure = event.data["message"]?.string ?? "这次分析未能完成。"
            case "run.cancelled":
                state.cancelled = true
            default:
                break   // run.created / run.status / progress / usage.summary / tool.*
            }
        }
        return state
    }

    private static func snapshot(runID: String, owner: Int, account: AccountService) async throws -> AIRunSnapshot {
        let response = try await account.cloudRequest(path: "/me/ai/runs/" + runID, expectedUserID: owner)
        guard (200..<300).contains(response.statusCode),
              let snapshot = try? JSONDecoder().decode(AIRunSnapshot.self, from: response.data) else {
            throw AIRunKindError.resyncUnavailable
        }
        return snapshot
    }
}
