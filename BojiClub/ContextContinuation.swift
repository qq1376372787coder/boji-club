import SwiftUI

/// Typed source reference. The client only sends type + own job id + server
/// version; the server reloads the immutable result and builds the snapshot.
struct ClubContextSource: Codable, Equatable, Identifiable {
    var type: String
    var jobID: String
    var version: String?
    var sessionID: String?
    var title: String
    var id: String { type + "/" + jobID }
}

/// Optional, bounded, once-per-screen/account tips. Copy comes from published
/// remote config; no tip can create a record or mutate state.
struct ContextualTipView: View {
    let screen: String
    @EnvironmentObject private var account: AccountService
    @State private var content: OnboardingContent?
    @State private var dismissed = false

    private var tip: OnboardingContent.Tip? { content?.tip(screen) }

    var body: some View {
        Group {
            if let tip, !dismissed, !ClubContextualTips.seen(screen: screen, owner: account.user?.id ?? 0) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "lightbulb").foregroundStyle(ClubBrand.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(tip.title).font(.footnote.weight(.semibold))
                        Text(tip.body).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 4)
                    Button {
                        ClubContextualTips.mark(screen: screen, owner: account.user?.id ?? 0)
                        dismissed = true
                    } label: { Image(systemName: "xmark").frame(width: 32, height: 32) }
                    .accessibilityLabel("关闭提示")
                }
                .padding(12)
                .background(BojiColor.subtleSurface, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .task(id: account.user?.id) {
            guard let uid = account.user?.id, uid > 0, !account.isPreviewAccount else { return }
            guard let response = try? await account.cloudRequest(path: "/me/onboarding/v2", expectedUserID: uid),
                  response.statusCode == 200,
                  let state = try? JSONDecoder().decode(OnboardingV2State.self, from: response.data) else { return }
            content = state.content
        }
    }
}

enum ClubContextualTips {
    static func seen(screen: String, owner: Int) -> Bool {
        UserDefaults.standard.bool(forKey: "club.tip.v1.\(owner).\(screen)")
    }
    static func mark(screen: String, owner: Int) {
        guard owner > 0 else { return }
        UserDefaults.standard.set(true, forKey: "club.tip.v1.\(owner).\(screen)")
    }
    static func erase(owner: Int) {
        let prefix = "club.tip.v1.\(owner)."
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}

struct ClubWorkoutFeedbackEntry: Codable, Equatable {
    var dateKey: String
    var choice: String
    var note: String
    var savedAt: Date
}

enum ClubWorkoutFeedbackStore {
    private static func key(owner: Int, session: String) -> String { "workout.feedback.v1.\(owner).\(session.lowercased())" }
    static func save(_ entry: ClubWorkoutFeedbackEntry, owner: Int, session: UUID) {
        guard owner > 0, let data = try? JSONEncoder().encode(entry) else { return }
        UserDefaults.standard.set(data, forKey: key(owner: owner, session: session.uuidString))
    }
    static func load(owner: Int, session: UUID) -> ClubWorkoutFeedbackEntry? {
        guard owner > 0, let data = UserDefaults.standard.data(forKey: key(owner: owner, session: session.uuidString)) else { return nil }
        return try? JSONDecoder().decode(ClubWorkoutFeedbackEntry.self, from: data)
    }
    static func erase(owner: Int) {
        let prefix = "workout.feedback.v1.\(owner)."
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
