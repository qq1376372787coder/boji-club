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

enum ContextSourceVersion {
    @MainActor
    static func load(_ source: ClubContextSource, account: AccountService) async -> String? {
        guard let uid = account.user?.id, source.jobID.count == 36 else { return nil }
        struct Detail: Decodable {
            struct Task: Decodable { var createdAt: String?; enum CodingKeys: String, CodingKey { case createdAt = "created_at" } }
            var task: Task
        }
        guard let response = try? await account.cloudRequest(path: "/me/tasks/ai_job/\(source.jobID.lowercased())", expectedUserID: uid),
              response.statusCode == 200,
              let detail = try? JSONDecoder().decode(Detail.self, from: response.data) else { return nil }
        return detail.task.createdAt
    }
}

struct ContextAskView: View {
    let source: ClubContextSource
    @EnvironmentObject private var account: AccountService
    @EnvironmentObject private var ai: AIService
    @Environment(\.dismiss) private var dismiss
    @State private var question = ""
    @State private var jobID: String?
    @State private var busy = false
    @State private var error: String?
    @State private var version: String?

    private var job: AILocalJob? { jobID.flatMap(ai.job) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(source.title).font(.title3.weight(.semibold))
                    Text("这次追问只加载服务端保存的 \(source.type == "report" ? "报告" : source.type == "weekly" ? "周报" : "训练解读")快照；不会把客户端全文当作事实。旧报告不会被新记录改写。")
                        .font(.footnote).foregroundStyle(.secondary)
                    TextField("想问这份来源什么？", text: $question, axis: .vertical).lineLimit(2...5)
                        .textFieldStyle(.roundedBorder)
                    Button(busy ? "正在提交…" : "继续问 AI") { Task { await submit() } }
                        .buttonStyle(PrimaryButton()).disabled(busy || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if let jobID {
                        AIJobStatusView(id: jobID, animated: true)
                        if let job, job.status == "succeeded", let answer = job.result?.coach?.answer {
                            BojiBrandMark(size:22,style:.monochrome)
                            Text(answer).font(.body).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                            if let context = job.result?.coach?.prompt_version {
                                Text("来源版本已由服务端核对 · \(context)").font(.caption2).foregroundStyle(.secondary)
                            }
                        } else if let job, job.status == "failed" {
                            Text(job.error ?? "这次追问未完成，来源仍保留。").font(.footnote).foregroundStyle(.red)
                        }
                    }
                    if let error { Text(error).font(.footnote).foregroundStyle(.red) }
                }.padding(20)
            }
            .background(BojiColor.pageBackground)
            .navigationTitle("继续问 AI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .task { version = await ContextSourceVersion.load(source, account: account) }
        }
    }

    private func submit() async {
        guard ai.routingConsentGranted else { error = "云端分析尚未开启，可在隐私说明中开启。"; return }
        guard let uid = account.user?.id, uid > 0 else { return }
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 1200 else { return }
        var selected = source; selected.version = version ?? source.version
        ClubAIRoute.open(owner: uid, question: text, source: selected)
        dismiss()
    }
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
