import SwiftUI

struct ClubAIHubView: View {
    var initialSection = "动态"
    var body: some View {
        if initialSection == "报告" { NavigationStack { ReportLibraryView() } }
        else { ClubAIEntryBridge() }
    }
}

struct ClubAIHomeView: View {
    var body: some View {
        ClubInsightTimelineView(embedded: true)
    }
}

/// Kept by the shell so mode switches do not destroy drafts, navigation context or scroll position.
@MainActor
final class ClubCoachSession: ObservableObject {
    @Published var conversation: String
    @Published var question: String { didSet { composerRevision130 &+= 1 } }
    @Published var contextDays = 14
    @Published var planIntake131 = false
    @Published var onboardingPlanSession135: String?
    @Published var workoutContext: ClubAIEntryContext?
    @Published var attachments: [ClubChatAttachment] = [] { didSet { composerRevision130 &+= 1 } }
    @Published var references: [AIContextReference] = [] { didSet { composerRevision130 &+= 1 } }
    @Published var continuationSource: ClubContextSource?
    @Published var reviewScope: ClubReviewScope?
    @Published var deepAnalysis = false { didSet { composerRevision130 &+= 1 } }
    @Published var preparingReferences = false
    @Published var processingConversation: String?
    @Published var scrollAnchor: String?
    @Published var sendRequest = 0
    @Published var error: String?
    @Published var followLatest = true
    @Published var focusRequest = 0
    @Published fileprivate var draftCardOutcomes: [String: ClubDraftCardOutcome] = [:]
    @Published fileprivate var cardActionError: String?
    fileprivate var composerRevision130 = 0
    fileprivate var submittedDraftRevisions130: [String: Int] = [:]
    var referenceSendTask130: Task<Void, Never>?
    func cancelReferenceSend130() {
        referenceSendTask130?.cancel(); referenceSendTask130 = nil; preparingReferences = false
        error = "发送已取消，草稿已保留。"
    }
    fileprivate var consumedSendRequest = 0
    fileprivate var ownerID: Int?
    fileprivate var initialized = false
    private var scrollAnchors: [String: String] = [:]

    init(conversation: String = UUID().uuidString.lowercased(), question: String = "") {
        self.conversation = conversation
        self.question = question
    }

    func reset(conversation: String = UUID().uuidString.lowercased(), question: String = "") {
        referenceSendTask130?.cancel(); referenceSendTask130 = nil
        self.conversation = conversation; self.question = question
        planIntake131 = false; onboardingPlanSession135 = nil; contextDays = 14; scrollAnchor = nil; sendRequest = 0; consumedSendRequest = 0
        error = nil; cardActionError = nil; draftCardOutcomes = [:]; followLatest = true; focusRequest = 0
        ownerID = nil; initialized = false; scrollAnchors = [:]; workoutContext = nil; continuationSource = nil; reviewScope = nil; attachments = []; references = []; deepAnalysis = false; preparingReferences = false; processingConversation = nil
    }

    func persistExtras() {
        guard let ownerID else { return }
        if !ClubChatDraftStorage.save(owner: ownerID, conversation: conversation, attachments: attachments, context: workoutContext, references: references, source: continuationSource, scope: reviewScope) {
            error = "照片草稿未能保存到本机，请保留当前页面并重试。"
        }
    }

    /// A render or mode switch cannot submit the same queued question twice.
    func takePendingSend() -> Bool {
        guard sendRequest != consumedSendRequest else { return false }
        consumedSendRequest = sendRequest
        return true
    }

    func selectConversation(_ id: String, owner: Int?) {
        if owner == ownerID || ownerID == nil, let owner {
            ClubCoachDraftStorage.save(question, owner: owner, conversation: conversation)
            persistExtras()
            if let scrollAnchor { scrollAnchors[conversation] = scrollAnchor }
        }
        if owner != ownerID { scrollAnchors = [:] }
        ownerID = owner
        planIntake131 = false
        conversation = id
        let draft = owner.flatMap { ClubChatDraftStorage.load(owner: $0, conversation: id) }
        continuationSource = draft?.source; reviewScope = draft?.scope
        workoutContext = draft?.context
        attachments = draft?.attachments ?? []; references = draft?.references ?? []
        question = owner.map { ClubCoachDraftStorage.load(owner: $0, conversation: id) } ?? ""
        if !references.isEmpty {
            // Migrate old rich-text reference prefixes once when opening a draft.
            var migrated = question
            for ref in references {
                let prefix = "@" + ref.title
                if migrated.hasPrefix(prefix) { migrated = String(migrated.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines) }
            }
            if migrated != question { question = migrated; if let owner { ClubCoachDraftStorage.save(migrated, owner: owner, conversation: id) } }
        }

        scrollAnchor = scrollAnchors[id]
        error = nil; cardActionError = nil; followLatest = scrollAnchor == nil
        initialized = true
        consumedSendRequest = sendRequest
    }

    func newConversation(owner: Int?, keepDraft: Bool) {
        planIntake131 = false
        if let owner {
            if keepDraft { ClubCoachDraftStorage.save(question, owner: owner, conversation: conversation); persistExtras() }
            else { ClubCoachDraftStorage.clear(owner: owner, conversation: conversation); ClubChatDraftStorage.clear(owner: owner, conversation: conversation) }
        }
        conversation = UUID().uuidString.lowercased()
        question = ""; scrollAnchor = nil; followLatest = true; workoutContext = nil; continuationSource = nil; reviewScope = nil; attachments = []; references = []; deepAnalysis = false; preparingReferences = false; processingConversation = nil
        error = nil; cardActionError = nil; draftCardOutcomes = [:]
        ownerID = owner; initialized = true; consumedSendRequest = sendRequest
    }
}


enum ClubCoachTimelineRow: Identifiable {
    case job(AILocalJob)
    case live

    var id: String {
        switch self {
        case .job(let job): return "job/" + job.id
        case .live: return "coach-live"
        }
    }
}

enum ClubCoachTimelineBuilder {
    /// The live turn always follows the sorted history. It never appears above
    /// old messages, and the same row identity is reused after import.
    static func rows(turns: [AILocalJob], liveActive: Bool) -> [ClubCoachTimelineRow] {
        turns.map { .job($0) } + (liveActive ? [.live] : [])
    }
}

