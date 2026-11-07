import Foundation
import AuthenticationServices

@MainActor protocol AccountCredentialStore127: AnyObject {
    var accessToken: String? { get set }
    var appleUser: String? { get set }
}

/// Injectable credential storage used by isolated tests; production uses Keychain.
@MainActor final class MemoryAccountCredentials127: AccountCredentialStore127 {
    var accessToken: String?
    var appleUser: String?
    init(token: String? = nil, appleUser: String? = nil) { accessToken = token; self.appleUser = appleUser }
}

enum ChatContextPurpose127: String {
    case dialogue, daily, weekly, workout, contextContinue
    static func restored(payload: [String: JSONValue], sourceSession: UUID? = nil) -> Self {
        if payload["context_source"]?.object != nil || payload["_context_source"]?.object != nil || payload["purpose"]?.string == "context_continue" { return .contextContinue }
        if sourceSession != nil || payload["purpose"]?.string == "workout" { return .workout }
        if payload["review_scope"]?.object?["kind"]?.string == "daily" { return .daily }
        if payload["purpose"]?.string == "weekly" { return .weekly }
        return .dialogue
    }
    func accepts(days: Int) -> Bool {
        switch self {
        case .dialogue: return [7,14].contains(days)
        case .daily: return days == 1
        case .weekly: return [7,14].contains(days)
        case .workout: return days == 7
        case .contextContinue: return days == 0
        }
    }
}

/// Recording only appends the new segment once and cannot cross conversation owners.
struct VoiceDraft127 {
    let owner: Int
    let conversation: String
    let prefix: String
    func result(transcript: String, currentOwner: Int?, currentConversation: String) -> String? {
        guard owner == currentOwner, conversation == currentConversation else { return nil }
        let words = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return prefix }
        return prefix + (prefix.isEmpty || prefix.hasSuffix("\n") ? "" : "\n") + words
    }
}
