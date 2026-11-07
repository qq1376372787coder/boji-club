import Foundation
import Combine
import Security
import AuthenticationServices

enum AccountPhase: Equatable {
    case checking, signedOut, onboarding, ready
}

struct ClubAccount: Codable {
    var id: Int
    var phoneMasked: String
    var clubNumber: String
    var onboardingCompleted: Bool
    var profile: MemberProfile?
    var planMode: String?
    var membership: MembershipInfo?
    var createdAt: String? = nil

    enum CodingKeys: String, CodingKey {
        case id
        case phoneMasked = "phone_masked"
        case clubNumber = "club_number"
        case onboardingCompleted = "onboarding_completed"
        case profile
        case planMode = "plan_mode"
        case membership
        case createdAt = "created_at"
    }
}

struct MembershipInfo: Codable {
    var active: Bool
    var source: String?
    var planCode: String?
    var startsAt: String?
    var expiresAt: String?
    /// Server-authoritative flag for a non-expiring lifetime entitlement.
    var lifetime: Bool?

    enum CodingKeys: String, CodingKey {
        case active, source, lifetime
        case planCode = "plan_code"
        case startsAt = "starts_at"
        case expiresAt = "expires_at"
    }
}

struct AuthResponse: Codable {
    var accessToken: String
    var user: ClubAccount

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case user
    }
}

enum AccountError: LocalizedError {
    case message(String)
    case unauthorized
    case http(Int, String)
    var errorDescription: String? {
        switch self { case .message(let value): return value; case .unauthorized: return "登录已过期，请重新登录。"; case .http(_, let text): return text }
    }
}

private struct AccountErrorBody: Decodable {
    let error: String
    let errorCode: String?
    enum CodingKeys: String, CodingKey { case error, errorCode = "error_code" }
}

struct AccountRawResponse {
    let statusCode: Int
    let data: Data
}

// MARK: Phase 4 §5.5 / Phase 5 §6.3 反馈闭环 + 最小埋点（R-31）
extension AccountService {
    /// 事件批量上报（fire-and-forget：预览/未登录/离线静默丢弃，绝不阻塞用户路径）。
    func trackEvents(_ events: [[String: Any]]) async {
        guard let user, user.id > 0, isPreviewAccount == false, !events.isEmpty,
              let body = try? JSONSerialization.data(withJSONObject: ["events": events]) else { return }
        guard let id = user.id as Int? else { return }
        _ = try? await cloudRequest(path: "/me/ai/feedback", method: "POST", body: body, expectedUserID: id)
    }

    func trackEvent(name: String, kind: String = "metric", target: String? = nil, action: String? = nil,
                    detail: [String: Any]? = nil) async {
        var entry: [String: Any] = ["kind": kind, "name": name]
        if let target { entry["target_id"] = target }
        if let action { entry["action"] = action }
        if let detail { entry["detail"] = detail }
        await trackEvents([entry])
    }
}

/// Offline account restore cache. The full ClubAccount (including profile and
/// avatar) used to live in UserDefaults, which is backed up and unprotected.
/// It now lives in an app-support file with complete file protection and backup
/// exclusion. Only a non-PII account ID pointer remains in preferences; the old
/// UserDefaults blob is migrated and removed after a successful protected write.
enum AccountProfileCacheStore {
    static let legacyKey = "account.cached-user"
    static let pointerKey = "account.cached-user-id"
    static func defaultDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BojiClub/account-cache", isDirectory: true)
    }
    static func fileURL(owner: Int, directory: URL) -> URL {
        directory.appendingPathComponent("user-\(owner).json")
    }
    @discardableResult
    static func save(_ account: ClubAccount, directory: URL = defaultDirectory(),
                     defaults: UserDefaults = .standard) -> Bool {
        guard account.id > 0 else { return false }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var folder = directory
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try? folder.setResourceValues(values)
            let data = try JSONEncoder().encode(account)
            try data.write(to: fileURL(owner: account.id, directory: directory),
                           options: [.atomic, .completeFileProtection])
            defaults.set(account.id, forKey: pointerKey)
            defaults.removeObject(forKey: legacyKey)
            return true
        } catch { return false }
    }
    static func load(directory: URL = defaultDirectory(), defaults: UserDefaults = .standard) -> ClubAccount? {
        if let data = defaults.data(forKey: legacyKey),
           let account = try? JSONDecoder().decode(ClubAccount.self, from: data) {
            // Keep the legacy copy until the protected write succeeds.
            if save(account, directory: directory, defaults: defaults) { return account }
            return account
        }
        guard let owner = defaults.object(forKey: pointerKey) as? Int, owner > 0,
              let data = try? Data(contentsOf: fileURL(owner: owner, directory: directory)),
              let account = try? JSONDecoder().decode(ClubAccount.self, from: data),
              account.id == owner else { return nil }
        return account
    }
    static func clear(owner: Int? = nil, directory: URL = defaultDirectory(),
                      defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: legacyKey)
        defaults.removeObject(forKey: pointerKey)
        let manager = FileManager.default
        if let owner {
            try? manager.removeItem(at: fileURL(owner: owner, directory: directory))
            return
        }
        guard let files = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "json" { try? manager.removeItem(at: file) }
    }
}

struct ClubRemoteAnnouncement: Codable, Equatable {
    var enabled: Bool
    var title: String
    var body: String
}

struct ClubRemoteConfig: Codable, Equatable {
    struct Values: Codable, Equatable {
        var aiEnabled: Bool
        var clubEnabled: Bool
        /// 旧客户端首页兼容字段。保留远程配置解码；本客户端固定采用 AI 主界面，不以此字段选择入口。
        var aiNativeHome: Bool?
        var minimumBuild: Int
        var latestBuild: Int
        var announcement: ClubRemoteAnnouncement
        /// Phase 1  rollout gates（旧服务端缺失这两个键时按关闭处理，客户端沿用旧写路径）。
        var actionSystemEnabled: Bool?
        var trainingCommands: Bool?
        var directRecords: Bool?
        var aiContextReferencesV1: Bool?
        var aiFastIntentV1: Bool?
        var aiRouterV3: Bool?
        var aiStreamingV2: Bool?
        var onboardingV2Enabled: Bool?
        var contextualTipsEnabled: Bool?
        /// coach 后端休眠开关（拍板 #7）：false=对话链路休眠不发请求；可远程拉起回退。
        var coachBackendEnabled: Bool?
        enum CodingKeys: String, CodingKey {
            case aiEnabled = "ai_enabled", clubEnabled = "club_enabled", aiNativeHome = "ai_native_home"
            case actionSystemEnabled = "action_system_enabled"
            case minimumBuild = "minimum_build", latestBuild = "latest_build", announcement
            case trainingCommands = "training_commands", directRecords = "direct_records"
            case aiContextReferencesV1 = "ai_context_references_v1"
            case aiFastIntentV1 = "ai_fast_intent_v1"
            case aiRouterV3 = "ai_router_v3"
            case aiStreamingV2 = "ai_streaming_v2"
            case onboardingV2Enabled = "onboarding_v2_enabled"
            case contextualTipsEnabled = "contextual_tips_enabled"
            case coachBackendEnabled = "coach_backend_enabled"
        }
    }
    var version: Int
    var publishedAt: String?
    var config: Values
    enum CodingKeys: String, CodingKey { case version, publishedAt = "published_at", config }

    static func currentBuild() -> Int {
        Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0
    }
    var requiresUpdateNotice: Bool {
        config.minimumBuild > 0 && Self.currentBuild() < config.minimumBuild
    }
    var hasNotice: Bool { config.announcement.enabled || requiresUpdateNotice }
}

@MainActor
final class AccountService: ObservableObject {
    @Published private(set) var phase: AccountPhase = .checking
    @Published private(set) var user: ClubAccount?
    @Published var notice: String?
    @Published private(set) var pendingLocalErasureIDs: [Int] = (UserDefaults.standard.array(forKey: "account.local-erasure") as? [Int]) ?? []
    @Published private(set) var localErasureRetry = 0
    @Published private(set) var pendingDeletionID: Int? = UserDefaults.standard.object(forKey: "account.pending-deletion") as? Int
    @Published private(set) var deletedAccountID: Int?
    @Published private(set) var remoteConfig: ClubRemoteConfig?
    private var remoteConfigFetchedAt: Date?
    private let pendingDeletionKey = "account.pending-deletion"

    private var productionBaseURL: String {
        if let configured = Bundle.main.object(forInfoDictionaryKey: "AccountAPIBaseURL") as? String, let url = URL(string: configured), url.scheme == "https" { return configured }
        return "https://117.50.119.49/account/v1"
    }
    private var baseURL: String {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["BOJI_ACCOUNT_BASE_URL"],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return override.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return "https://117.50.119.49/account/v1"
        #elseif BOJI_TESTFLIGHT
        return "https://117.50.119.49/account/v1"
        #else
        return productionBaseURL
        #endif
    }
    private static let keychainService = "com.bojiclub.account"
    private static let tokenAccount = "access-token"
    private static let previewAccountKey = "account.preview-enabled"
    static let previewUserID = -1001

    /// True only for the local DEBUG preview account. Cloud and purchase APIs are unavailable.
    var isPreviewAccount: Bool { user?.id == Self.previewUserID }

    static func previewAccount(onboardingCompleted: Bool = true) -> ClubAccount {
        ClubAccount(
            id: previewUserID,
            phoneMasked: "开发预览",
            clubNumber: "DEV-0001",
            onboardingCompleted: onboardingCompleted,
            profile: MemberProfile(),
            planMode: "generate_plan",
            membership: MembershipInfo(active: true, source: "debug_preview", planCode: "preview", startsAt: nil, expiresAt: nil)
        )
    }

    private let networkSession: URLSession
    private let credentialStore: (any AccountCredentialStore127)?
    private let appleCredentialLookup: ((String) async -> ASAuthorizationAppleIDProvider.CredentialState?)?
    private var sessionGeneration = UUID()
    private var cachedAccessToken: String?
    private var lastAppleCheck: Date?
    private var validationTask: (generation: UUID, task: Task<Bool?, Never>)?
    init(networkSession: URLSession = .shared, credentialStore: (any AccountCredentialStore127)? = nil,
         appleCredentialLookup: ((String) async -> ASAuthorizationAppleIDProvider.CredentialState?)? = nil) {
        self.networkSession = networkSession; self.credentialStore = credentialStore; self.appleCredentialLookup = appleCredentialLookup
    }
    private typealias SessionTicket = (generation: UUID, owner: Int?, token: String)
    private func ticket(_ token: String) -> SessionTicket { (sessionGeneration, user?.id, token) }
    private func matches(_ ticket: SessionTicket) -> Bool {
        sessionGeneration == ticket.generation && user?.id == ticket.owner && token == ticket.token
    }
    private func validateSession(_ ticket: SessionTicket) async -> Bool? {
        if let existing = validationTask, existing.generation == ticket.generation { return await existing.task.value }
        let task = Task<Bool?, Never> { @MainActor [weak self] in
            guard let self, self.matches(ticket), let url = URL(string: self.baseURL + "/me") else { return nil }
            var request = URLRequest(url: url, timeoutInterval: 12)
            request.setValue(BojiInstall131.identifier, forHTTPHeaderField: "X-Boji-Install")
            request.setValue("Bearer " + ticket.token, forHTTPHeaderField: "Authorization")
            do {
                let (_, response) = try await self.networkSession.data(for: request)
                guard self.matches(ticket), let http = response as? HTTPURLResponse else { return nil }
                if http.statusCode == 200 { return true }
                if http.statusCode == 401 { return false }
            } catch { }
            return nil
        }
        validationTask = (ticket.generation, task)
        let result = await task.value
        if validationTask?.generation == ticket.generation { validationTask = nil }
        return result
    }
    private func rejectUnauthorized(_ ticket: SessionTicket, path: String) async throws -> Never {
        guard matches(ticket), !Task.isCancelled else { throw CancellationError() }
        if path == "/me" { try? await Task.sleep(for: .milliseconds(500)) }
        let valid = await validateSession(ticket)
        guard matches(ticket), !Task.isCancelled else { throw CancellationError() }
        if valid == false {
            authenticationDiagnostic = "current_session_invalid"
            AccountDiagnostics130.record("session_invalid", detail: path)
            invalidateSession(); throw AccountError.unauthorized
        }
        authenticationDiagnostic = valid == true ? "operation_unauthorized_session_valid" : "session_verification_deferred"
        throw AccountError.http(401, valid == true ? "这项请求暂未获授权，登录已保留，请重试。" : "暂时无法核对登录状态，登录信息已保留，请联网后重试。")
    }

    private var restoreTask: Task<Void, Never>?
    private var credentialCheckRunning = false
    @Published private(set) var authenticationDiagnostic = ""

    func restore() async {
        if let restoreTask { await restoreTask.value; return }
        let task = Task { @MainActor [weak self] in await self?.performRestore() }
        let wrapped = Task<Void, Never> { _ = await task.value }
        restoreTask = wrapped
        await wrapped.value
        restoreTask = nil
    }

    private func performRestore() async {
        if let id = pendingDeletionID, token != nil {
            do {
                struct Status: Decodable { let accepted: Bool }
                let response: Status = try await request(path: "/me/deletion", body: Optional<EmptyBody>.none)
                if response.accepted { finishDeletion(id); return }
                UserDefaults.standard.removeObject(forKey: pendingDeletionKey); pendingDeletionID = nil
            } catch { if pendingDeletionID == id { notice = "注销申请状态暂时无法确认，请联网后重试。"; phase = .signedOut }; return }
        }
        if pendingDeletionID != nil && token == nil {
            notice = "注销凭证暂不可用。可使用申请时的 Apple 账号重新验证，以找回注销状态。"; phase = .signedOut; return
        }
        #if DEBUG
        if credentialStore == nil {
        if let mode = ProcessInfo.processInfo.environment["BOJI_PREVIEW_ACCOUNT"] {
            accept(Self.previewAccount(onboardingCompleted: mode == "complete"))
            return
        }
        if let mode = UserDefaults.standard.string(forKey: Self.previewAccountKey) {
            accept(Self.previewAccount(onboardingCompleted: mode == "complete"))
            return
        }
        }
        #endif
        guard token != nil else {
            if lastKeychainStatus != errSecItemNotFound && lastKeychainStatus != errSecSuccess {
                authenticationDiagnostic = "keychain:\(lastKeychainStatus)"
                notice = "设备凭证暂不可读取，请解锁设备后重试。"
                phase = .checking
            } else { phase = .signedOut }
            return
        }
        // The server session restores first; Apple validation is a separate,
        // single-flight foreground check and never races this restore.
        authenticationDiagnostic = "restoring_server_session"
        guard let restoreToken = token else { return }
        let restoreTicket = ticket(restoreToken)
        do {
            let response: UserEnvelope = try await request(path: "/me", body: Optional<EmptyBody>.none)
            accept(response.user)
            await checkAppleCredential()
        } catch is CancellationError {
            // A newer sign-in or explicit logout owns the current state.
            return
        } catch AccountError.unauthorized {
            // Only the request's current epoch may invalidate. Never clear a newer login here.
            return
        } catch {
            guard matches(restoreTicket), !Task.isCancelled else { return }
            if let cached = AccountProfileCacheStore.load() { accept(cached) }
            else { notice = "暂时无法恢复账号，请联网后重试。登录凭证仍保留。"; phase = .checking }
        }
    }

    #if DEBUG
    /// UI-development-only entry point. Never compiled into Release and never contacts Apple or the account server.
    func signInPreview() {
        UserDefaults.standard.set("complete", forKey: Self.previewAccountKey)
        accept(Self.previewAccount(onboardingCompleted: true))
    }

    /// A short-lived server test session, entered by the tester and never bundled in source.
    func signInServerTest(code: String, allowCloudAnalysis: Bool? = nil) async throws {
        guard user == nil, pendingDeletionID == nil else { throw AccountError.message("请先完成当前账号的退出或注销处理。") }
        let clean = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.range(of: "^[A-Za-z0-9_-]{64}$", options: .regularExpression) != nil else { throw AccountError.message("请完整复制测试登录码，不要包含标题或说明。") }
        guard let url = URL(string: baseURL + "/me"), url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { throw AccountError.message("测试服务器地址不正确。") }
        var trustedTestEndpoint = url.scheme == "https" && url.host == "117.50.119.49"
        #if DEBUG
        // An explicit launch override permits isolated TLS staging, or a local
        // simulator SSH tunnel. Release/TestFlight retain the production gate.
        if ProcessInfo.processInfo.environment["BOJI_ACCOUNT_BASE_URL"] != nil {
            trustedTestEndpoint = url.scheme == "https" || (url.scheme == "http" && ["127.0.0.1", "localhost", "::1"].contains(url.host ?? ""))
        }
        #endif
        guard trustedTestEndpoint else { throw AccountError.message("请使用 HTTPS 测试入口，或 Debug 显式配置的本机隔离测试隧道。") }
        let oldToken = token
        var request = URLRequest(url: url, timeoutInterval: 25)
        request.setValue(BojiInstall131.identifier, forHTTPHeaderField: "X-Boji-Install")
        request.setValue("Bearer " + clean, forHTTPHeaderField: "Authorization")
        let (data, raw) = try await networkSession.data(for: request)
        guard !Task.isCancelled, user == nil, pendingDeletionID == nil, token == oldToken else { throw CancellationError() }
        guard let response = raw as? HTTPURLResponse else { throw AccountError.message("测试账号响应异常，请重试。") }
        guard response.statusCode == 200 else { throw AccountError.message(response.statusCode == 401 ? "测试登录码已失效；退出登录后需要重新签发。" : "测试账号暂不可用，请稍后重试。") }
        let envelope = try JSONDecoder().decode(UserEnvelope.self, from: data)
        guard envelope.user.membership?.active == true else { throw AccountError.message("测试会员已到期，请联系管理员。") }
        // Clear an old Apple identity so its revocation cannot log out this unrelated test account.
        clearToken()
        guard saveToken(clean) else { throw AccountError.message("测试登录信息保存失败，请重试。") }
        UserDefaults.standard.removeObject(forKey: Self.previewAccountKey)
        if let allowed = allowCloudAnalysis, !CloudAnalysisConsent.hasDecision(accountID: envelope.user.id) {
            AIService.recordRoutingConsent(accountID: envelope.user.id, allowed: allowed)
        }
        accept(envelope.user)
    }

    /// Starts the full local onboarding questionnaire and plan-preview flow.
    func signInPreviewAsNewUser() {
        UserDefaults.standard.set("new_user", forKey: Self.previewAccountKey)
        OnboardingDraftStore.clear(owner: Self.previewUserID)
        accept(Self.previewAccount(onboardingCompleted: false))
    }
    #endif

    func signInWithApple(identityToken: String, nonce: String, authorizationCode: String?, appleUserID: String, allowCloudAnalysis: Bool? = nil) async throws {
        struct Body: Encodable {
            let identity_token: String
            let nonce: String
            let authorization_code: String?
        }
        if let id = pendingDeletionID {
            struct RecoveryBody: Encodable { let identity_token: String; let nonce: String; let account_id: Int }
            struct Status: Decodable { let accepted: Bool }
            let status: Status = try await request(path: "/auth/apple/deletion-status", method: "POST", body: RecoveryBody(identity_token: identityToken, nonce: nonce, account_id: id), authenticated: false)
            if status.accepted { finishDeletion(id); return }
            // The server verified that this exact Apple account still owns the original active user.
            UserDefaults.standard.removeObject(forKey: pendingDeletionKey); pendingDeletionID = nil
        }
        let response: AuthResponse = try await request(path: "/auth/apple/verify", method: "POST",
                                                       body: Body(identity_token: identityToken, nonce: nonce, authorization_code: authorizationCode), authenticated: false)
        guard saveToken(response.accessToken) else { throw AccountError.message("登录信息保存失败，请重试。") }
        guard saveAppleUserID(appleUserID) else { clearToken(); throw AccountError.message("Apple 登录凭证保存失败，请重试。") }
        if let allowed = allowCloudAnalysis, !CloudAnalysisConsent.hasDecision(accountID: response.user.id) {
            AIService.recordRoutingConsent(accountID: response.user.id, allowed: allowed)
        }
        accept(response.user)
    }

    func saveOnboarding(profile: MemberProfile, planMode: String) async throws {
        if isPreviewAccount {
            var preview = user ?? Self.previewAccount(onboardingCompleted: false)
            preview.profile = profile
            preview.planMode = planMode
            user = preview
            cacheUser(preview)
            return
        }
        struct Body: Encodable {
            let profile: MemberProfile
            let plan_mode: String
            let covenant_version: String
        }
        let response: UserEnvelope = try await request(path: "/me/onboarding", method: "PUT",
            body: Body(profile: profile, plan_mode: planMode, covenant_version: "2026-09-27"))
        user = response.user
        cacheUser(response.user)
    }

    func completeOnboarding() async throws {
        if isPreviewAccount {
            var preview = user ?? Self.previewAccount(onboardingCompleted: true)
            preview.onboardingCompleted = true
            user = preview
            cacheUser(preview)
            UserDefaults.standard.set("complete", forKey: Self.previewAccountKey)
            return
        }
        let response: UserEnvelope = try await request(path: "/me/onboarding/complete", method: "POST", body: EmptyBody())
        user = response.user
        cacheUser(response.user)
    }

    func enterClub() {
        guard user?.onboardingCompleted == true else { return }
        phase = .ready
    }

    /// Refreshes server-authoritative membership and profile fields.
    func refreshAccount() async {
        guard token != nil, UserDefaults.standard.object(forKey: pendingDeletionKey) == nil else { return }
        do {
            let response: UserEnvelope = try await request(path: "/me", body: Optional<EmptyBody>.none)
            let wasOnboarding = phase == .onboarding
            accept(response.user)
            if wasOnboarding { phase = .onboarding }
        } catch {
            // Retain the last verified account while the network is unavailable.
        }
    }

    /// The server derives the RevenueCat identity from this authenticated account.
    /// No entitlement flag, purchase ID or other user's identity comes from the client.
    func verifyMembership() async throws -> Bool {
        guard let owner = user?.id, !isPreviewAccount else { return false }
        struct Response: Decodable { let user: ClubAccount; let verification: String }
        let response: Response = try await request(path: "/me/membership/verify", method: "POST", body: EmptyBody())
        guard user?.id == owner else { throw CancellationError() }
        user = response.user
        cacheUser(response.user)
        return response.verification == "verified"
    }

    func loadRemoteConfig(force: Bool = false) async {
        if !force, let fetched = remoteConfigFetchedAt, Date().timeIntervalSince(fetched) < 300 { return }
        guard let url = URL(string: baseURL + "/config") else { return }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue(BojiInstall131.identifier, forHTTPHeaderField: "X-Boji-Install")
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await networkSession.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            let decoded = try JSONDecoder().decode(ClubRemoteConfig.self, from: data)
            guard decoded.version >= 0 else { return }
            remoteConfig = decoded
            remoteConfigFetchedAt = Date()
            // 远程开关在此处生效（历史问题⑩闭环）：ai/club 开关驱动客户端入口，
            // ai_native_home 驱动 V2 新壳灰度。
            FeatureFlagService.shared.apply(remote: decoded)
        } catch {
            // Config is advisory; a network or schema failure must never block the app.
        }
    }

    func logout() async {
        guard pendingDeletionID == nil else { await restore(); return }
        let previousToken = isPreviewAccount ? nil : token
        clearToken()
        UserDefaults.standard.removeObject(forKey: Self.previewAccountKey)
        AccountProfileCacheStore.clear()
        user = nil
        phase = .signedOut
        if let previousToken, let url = URL(string: baseURL + "/auth/logout") {
            var request = URLRequest(url: url, timeoutInterval: 10)
            request.setValue(BojiInstall131.identifier, forHTTPHeaderField: "X-Boji-Install")
            request.httpMethod = "POST"
            request.setValue("Bearer " + previousToken, forHTTPHeaderField: "Authorization")
            _ = try? await networkSession.data(for: request)
        }
    }

    @discardableResult
    func deleteAccount() async throws -> Int {
        guard let current = user else { throw AccountError.unauthorized }
        UserDefaults.standard.set(current.id, forKey: pendingDeletionKey); pendingDeletionID = current.id
        struct DeleteBody: Encodable { let confirmation: String }
        do {
            let _: EmptyResponse = try await request(path: "/me", method: "DELETE", body: DeleteBody(confirmation: "DELETE"))
            finishDeletion(current.id)
            return current.id
        } catch AccountError.unauthorized {
            UserDefaults.standard.removeObject(forKey: pendingDeletionKey); pendingDeletionID = nil
            throw AccountError.unauthorized
        } catch AccountError.http(let status, let text) {
            if (400..<500).contains(status) { UserDefaults.standard.removeObject(forKey: pendingDeletionKey); pendingDeletionID = nil }
            throw AccountError.message(text)
        } catch { throw AccountError.message("注销申请状态尚未确认，请联网后点击检查状态；已受理的申请不会重复执行。") }
    }

    private func finishDeletion(_ id: Int) {
        pendingDeletionID = nil
        pendingLocalErasureIDs = Array(Set(pendingLocalErasureIDs + [id])).sorted()
        UserDefaults.standard.set(pendingLocalErasureIDs, forKey: "account.local-erasure")
        deletedAccountID = id
        clearToken()
        UserDefaults.standard.removeObject(forKey: pendingDeletionKey)
        AccountProfileCacheStore.clear()
        OnboardingDraftStore.clear(owner: id)
        OnboardingMutationRecovery.clear(owner:id)
        ProfileFormDraft133.erase(id)
        AIRunResumeStore.erase(owner: id)
        AIRunPendingStore.erase(owner: id)
        ClubContextualTips.erase(owner: id)
        ClubWorkoutFeedbackStore.erase(owner: id)
        FeedbackDraftStore128.erase(owner: id)
        AccountDiagnostics130.erase(owner: id)
        SubmittedDraftClears130.erase(owner: id)
        WeeklyPlanDraftStore130.erase(owner: id)
        UserDefaults.standard.removeObject(forKey: "ai.routing-consent.v2.\(id)")
        UserDefaults.standard.removeObject(forKey: "ai.routing-consent.v3.\(id)")
        UserDefaults.standard.removeObject(forKey: Self.previewAccountKey)
        user = nil; phase = .signedOut
        notice = "账号已停用，本机数据正在清除。服务器会继续清理照片和记录，失败时自动重试。Apple 订阅请在系统设置中管理；旧账号未保存 Apple 授权凭证时，请通过登录页的“管理 Apple 登录授权”手动移除。"
    }

    /// Private support uploads use a file body and retain the same account-epoch checks as JSON/SSE.
    func feedbackUpload128(file: URL, id: String, mime: String, sha256: String, expectedUserID: Int) async throws -> AccountRawResponse {
        guard user?.id == expectedUserID, UUID(uuidString: id) != nil,
              UserDefaults.standard.object(forKey: pendingDeletionKey) == nil else { throw CancellationError() }
        guard let token, let url = URL(string: baseURL + "/me/feedback/attachments/" + id) else { throw AccountError.unauthorized }
        let sessionTicket = ticket(token)
        var request = URLRequest(url: url, timeoutInterval: 150)
        request.setValue(BojiInstall131.identifier, forHTTPHeaderField: "X-Boji-Install")
        request.httpMethod = "PUT"; request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue(mime, forHTTPHeaderField: "Content-Type"); request.setValue(sha256, forHTTPHeaderField: "X-Content-SHA256")
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        request.setValue(String(size), forHTTPHeaderField: "Content-Length")
        let (data, raw) = try await networkSession.upload(for: request, fromFile: file)
        guard matches(sessionTicket), !Task.isCancelled else { throw CancellationError() }
        guard let response = raw as? HTTPURLResponse else { throw AccountError.message("附件上传响应异常。") }
        if response.statusCode == 401 { try await rejectUnauthorized(sessionTicket, path: "/me/feedback/attachments/" + id) }
        return .init(statusCode: response.statusCode, data: data)
    }

    func cloudRequest(path: String, method: String = "GET", body: Data? = nil, contentType: String = "application/json", expectedUserID: Int, deadline: Date? = nil, headers: [String: String] = [:]) async throws -> AccountRawResponse {
        guard user?.id == expectedUserID else { throw CancellationError() }
        guard UserDefaults.standard.object(forKey: pendingDeletionKey) == nil else { throw AccountError.message("请先确认注销申请状态。") }
        guard let url = URL(string: baseURL + path) else { throw AccountError.message("账号服务地址不可用。") }
        guard let token else { throw AccountError.message("登录已过期，请重新登录。") }
        let sessionTicket = ticket(token)
        let budget = min(40, deadline?.timeIntervalSinceNow ?? 40)
        guard budget > 0 else { throw URLError(.timedOut) }
        var request = URLRequest(url: url, timeoutInterval: budget)
        request.setValue(BojiInstall131.identifier, forHTTPHeaderField: "X-Boji-Install")
        request.httpMethod = method
        request.httpBody = body
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let operation = Task { try await networkSession.data(for: request) }
        let watchdog = Task {
            do { try await Task.sleep(for: .seconds(budget)); operation.cancel() } catch { }
        }
        defer { watchdog.cancel() }
        let result: (Data, URLResponse)
        do {
            result = try await withTaskCancellationHandler(operation: { try await operation.value }, onCancel: { operation.cancel() })
        } catch {
            if deadline.map({ $0 <= Date() }) == true || (operation.isCancelled && !Task.isCancelled) { throw URLError(.timedOut) }
            throw error
        }
        let (data, rawResponse) = result
        guard user?.id == expectedUserID, matches(sessionTicket), !Task.isCancelled else { throw CancellationError() }
        guard let response = rawResponse as? HTTPURLResponse else { throw AccountError.message("云端同步响应异常。") }
        if response.statusCode == 401 { try await rejectUnauthorized(sessionTicket, path: path) }
        applyMembershipRejection(statusCode: response.statusCode, data: data)
        return AccountRawResponse(statusCode: response.statusCode, data: data)
    }

    /// Phase 2 §3.3: an authenticated GET SSE subscription. Closing the
    /// connection never cancels the server-side run; callers reconnect with
    /// `after_seq` / Last-Event-ID.
    func cloudStream(path: String, expectedUserID: Int, afterSeq: Int, traceID: String? = nil,
                     timeout: TimeInterval = 45) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        guard user?.id == expectedUserID else { throw CancellationError() }
        guard UserDefaults.standard.object(forKey: pendingDeletionKey) == nil else { throw AccountError.message("请先确认注销申请状态。") }
        guard let url = URL(string: baseURL + path), let token else { throw AccountError.message("登录已过期，请重新登录。") }
        let sessionTicket = ticket(token)
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue(BojiInstall131.identifier, forHTTPHeaderField: "X-Boji-Install")
        request.httpMethod = "GET"
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        if afterSeq > 0 { request.setValue(String(afterSeq), forHTTPHeaderField: "Last-Event-ID") }
        if let traceID, !traceID.isEmpty { request.setValue(traceID, forHTTPHeaderField: "X-Boji-Trace") }
        let (bytes, rawResponse) = try await networkSession.bytes(for: request)
        guard matches(sessionTicket), !Task.isCancelled else { throw CancellationError() }
        guard let response = rawResponse as? HTTPURLResponse else { throw AccountError.message("流式响应异常。") }
        if response.statusCode == 401 { try await rejectUnauthorized(sessionTicket, path: path) }
        return (bytes, response)
    }

    private struct UserEnvelope: Decodable { let user: ClubAccount }
    private struct EmptyBody: Encodable { }
    private struct EmptyResponse: Decodable { }

    /// A membership denial updates entitlement without invalidating login or local records.
    private func applyMembershipRejection(statusCode: Int, data: Data) {
        guard statusCode == 403,
              (try? JSONDecoder().decode(AccountErrorBody.self, from: data))?.errorCode == "membership_required",
              var current = user, var entitlement = current.membership else { return }
        entitlement.active = false
        current.membership = entitlement
        accept(current)
    }

    private func accept(_ account: ClubAccount) {
        AccountDiagnostics130.activate(account.id)
        user = account
        cacheUser(account)
        phase = account.onboardingCompleted ? .ready : .onboarding
    }

    private func cacheUser(_ account: ClubAccount) {
        _ = AccountProfileCacheStore.save(account)
    }

    private func request<Response: Decodable, Body: Encodable>(path: String, method: String = "GET", body: Body? = nil, authenticated: Bool = true) async throws -> Response {
        guard let url = URL(string: baseURL + path) else { throw AccountError.message("账号服务地址不可用。") }
        let sessionToken = authenticated ? token : nil
        let requestGeneration = sessionGeneration
        let requestOwner = user?.id
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(BojiInstall131.identifier, forHTTPHeaderField: "X-Boji-Install")
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { request.httpBody = try JSONEncoder().encode(body) }
        if authenticated {
            guard let token else { throw AccountError.message("登录已过期，请重新登录。") }
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        }
        let (data, rawResponse) = try await networkSession.data(for: request)
        if authenticated && (sessionToken != token || requestGeneration != sessionGeneration || requestOwner != user?.id || Task.isCancelled) { throw CancellationError() }
        guard let response = rawResponse as? HTTPURLResponse else { throw AccountError.message("账号服务响应异常。") }
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 401 && authenticated, let sessionToken { try await rejectUnauthorized((requestGeneration, requestOwner, sessionToken), path: path) }
            if authenticated { applyMembershipRejection(statusCode: response.statusCode, data: data) }
            let message = (try? JSONDecoder().decode(AccountErrorBody.self, from: data))?.error ?? "暂时无法连接账号服务，请稍后重试。"
            throw AccountError.http(response.statusCode, message)
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private var lastKeychainStatus: OSStatus = errSecSuccess
    private var token: String? {
        if let credentialStore { lastKeychainStatus = credentialStore.accessToken == nil ? errSecItemNotFound : errSecSuccess; return credentialStore.accessToken }
        if let cachedAccessToken { return cachedAccessToken }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService, kSecAttrAccount as String: Self.tokenAccount,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        lastKeychainStatus = SecItemCopyMatching(query as CFDictionary, &item)
        guard lastKeychainStatus == errSecSuccess, let data = item as? Data else { return nil }
        cachedAccessToken = String(data: data, encoding: .utf8)
        return cachedAccessToken
    }

    private func saveToken(_ value: String) -> Bool {
        if let credentialStore { credentialStore.accessToken = value; sessionGeneration = UUID(); cachedAccessToken = value; lastAppleCheck = nil; return true }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService, kSecAttrAccount as String: Self.tokenAccount]
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        let saved = status == errSecItemNotFound ? SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) == errSecSuccess : status == errSecSuccess
        if saved { sessionGeneration = UUID(); cachedAccessToken = value; lastAppleCheck = nil }
        return saved
    }

    private func invalidateSession() {
        clearToken()
        AccountProfileCacheStore.clear()
        user = nil
        phase = .signedOut
    }

    func completeLocalErasure(_ id: Int, success: Bool) {
        if success {
            pendingLocalErasureIDs.removeAll { $0 == id }
            UserDefaults.standard.set(pendingLocalErasureIDs, forKey: "account.local-erasure")
        } else { notice = "账号已停用，但部分本机文件未能清除。请解锁设备并重试本机清理；下次启动也会自动重试。" }
    }
    func retryLocalErasure() { localErasureRetry &+= 1 }

    /// Leave the blocking deletion-status screen without clearing the pending
    /// marker: the request may have reached the server even if the response was
    /// lost. Signing in with the same Apple account resumes the check.
    func returnToSignInForUnconfirmedDeletion() {
        guard pendingDeletionID != nil else { return }
        phase = .signedOut
        notice = "注销申请状态尚未确认。重新使用申请时的 Apple 账号登录，可继续核对；不会重复提交。"
    }

    func checkAppleCredential(force: Bool = false) async {
        guard !credentialCheckRunning, phase != .checking, !isPreviewAccount, pendingDeletionID == nil,
              let identifier = appleUserID, let token else { return }
        if !force, let lastAppleCheck, Date().timeIntervalSince(lastAppleCheck) < 300 { return }
        let sessionTicket = ticket(token)
        credentialCheckRunning = true; lastAppleCheck = Date()
        defer { credentialCheckRunning = false }
        let state: ASAuthorizationAppleIDProvider.CredentialState?
        if let appleCredentialLookup { state = await appleCredentialLookup(identifier) }
        else {
            state = await withCheckedContinuation { continuation in
                ASAuthorizationAppleIDProvider().getCredentialState(forUserID: identifier) { state, error in continuation.resume(returning: error == nil ? state : nil) }
            }
        }
        guard matches(sessionTicket), appleUserID == identifier, pendingDeletionID == nil, !Task.isCancelled else { return }
        authenticationDiagnostic = state.map { "apple:\($0.rawValue)" } ?? "apple:temporarily_unavailable"
        AccountDiagnostics130.record("apple_check", detail: authenticationDiagnostic)
        if state == .revoked {
            if force { await logout(); notice = "Apple 登录授权已撤销，请重新登录。"; return }
            let valid = await validateSession(sessionTicket)
            guard matches(sessionTicket), !Task.isCancelled else { return }
            if valid == false { invalidateSession(); notice = "登录已失效，请重新使用 Apple 登录。" }
            else {
                authenticationDiagnostic = valid == true ? "apple:revoked_server_session_valid" : "apple:verification_deferred"
                notice = "Apple 登录需要重新确认，现有记录已保留。"
            }
            return
        }
        if state == .notFound {
            // A device-local lookup is not the server session. Recheck its authority
            // before deciding whether to clear a verified login; never treat a permission sheet as logout.
            let valid = await validateSession(sessionTicket)
            guard matches(sessionTicket), !Task.isCancelled else { return }
            if valid == false { invalidateSession(); notice = "登录已失效，请重新使用 Apple 登录。" }
            else { authenticationDiagnostic = valid == true ? "apple:not_found_server_session_valid" : "apple:verification_deferred" }
        }
    }

    private var appleUserID: String? {
        if let credentialStore { return credentialStore.appleUser }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.keychainService, kSecAttrAccount as String: "apple-user", kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    private func saveAppleUserID(_ identifier: String) -> Bool {
        if let credentialStore { credentialStore.appleUser = identifier; return true }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.keychainService, kSecAttrAccount as String: "apple-user"]
        let attributes: [String: Any] = [kSecValueData as String: Data(identifier.utf8), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound { return SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) == errSecSuccess }
        return status == errSecSuccess
    }

    private func clearToken() {
        sessionGeneration = UUID(); cachedAccessToken = nil; lastAppleCheck = nil
        validationTask?.task.cancel(); validationTask = nil
        if let credentialStore { credentialStore.accessToken = nil; credentialStore.appleUser = nil; return }
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.keychainService, kSecAttrAccount as String: "apple-user"] as CFDictionary)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService, kSecAttrAccount as String: Self.tokenAccount]
        SecItemDelete(query as CFDictionary)
    }
}

extension AccountService {
    func saveProfileIntake133(status:String) async throws {
        guard let owner=user?.id,owner>0 else { throw AccountError.unauthorized }
        let body=try JSONSerialization.data(withJSONObject:["status":status])
        let response=try await cloudRequest(path:"/me/onboarding/v2/checkpoints/basic-profile",method:"POST",body:body,expectedUserID:owner,headers:["Idempotency-Key":UUID().uuidString.lowercased()])
        guard (200..<300).contains(response.statusCode) else { throw OnboardingAPIError(message:"资料已保留，进度暂未保存，请重试。",status:response.statusCode) }
    }
}
