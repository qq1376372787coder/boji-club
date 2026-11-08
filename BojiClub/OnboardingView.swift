import SwiftUI
import AuthenticationServices
import UIKit
import WebKit

/// Onboarding drafts contain profile/health-adjacent answers. Keep them out of
/// UserDefaults in a complete-protected, backup-excluded file; migrate the old
/// per-account UserDefaults blob once the protected write succeeds.
enum OnboardingDraftStore {
    static let legacyPrefix = "onboarding.design2."
    static func defaultDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BojiClub/onboarding-cache", isDirectory: true)
    }
    static func fileURL(owner: Int, directory: URL = defaultDirectory()) -> URL {
        directory.appendingPathComponent("user-\(owner).json")
    }
    @discardableResult
    static func save(_ data: Data, owner: Int, directory: URL = defaultDirectory(),
                     defaults: UserDefaults = .standard) -> Bool {
        guard owner > 0 else { return false }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var folder = directory
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try? folder.setResourceValues(values)
            try data.write(to: fileURL(owner: owner, directory: directory),
                           options: [.atomic, .completeFileProtection])
            defaults.removeObject(forKey: legacyPrefix + String(owner))
            return true
        } catch { return false }
    }
    static func load(owner: Int, directory: URL = defaultDirectory(),
                     defaults: UserDefaults = .standard) -> Data? {
        guard owner > 0 else { return nil }
        if let legacy = defaults.data(forKey: legacyPrefix + String(owner)) {
            if save(legacy, owner: owner, directory: directory, defaults: defaults) { return legacy }
            return legacy
        }
        return try? Data(contentsOf: fileURL(owner: owner, directory: directory))
    }
    static func clear(owner: Int, directory: URL = defaultDirectory(), defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: legacyPrefix + String(owner))
        guard owner > 0 else { return }
        try? FileManager.default.removeItem(at: fileURL(owner: owner, directory: directory))
    }
}

struct AccountEntryView: View {
    @EnvironmentObject private var account: AccountService
    /// 协议勾选持久化（付费墙方案 A 可选项）：协议版本未变时免重复勾选，减少重登摩擦。
    /// 版本与 covenantVersion 同步（2026-10-25）；协议内容变更时更新版本号即可重新征询。
    static let legalAgreementVersion = "2026-10-25"
    private static let legalAcceptedKey = "boji.legal-accepted-version"
    @State private var legalAccepted = UserDefaults.standard.string(forKey: AccountEntryView.legalAcceptedKey) == AccountEntryView.legalAgreementVersion
    @State private var busy = false
    @State private var error: String?
    @State private var appleNonce = ""
    @State private var legalDocument: LegalDocument?
    @State private var showServerTestLogin = false

    var body: some View {
        ZStack {
            FlowBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    VStack(alignment: .leading, spacing: BojiLayout.cardInset) {
                        BojiBrandMark(size: 76)
                        Text("薄肌俱乐部").bojiType(.display)
                        Text("和 Club AI 一起，安排适合你的训练。")
                            .bojiType(.body).foregroundStyle(.secondary)
                    }.padding(.top, BojiLayout.Rhythm.footerClearance).padding(.bottom, BojiLayout.Rhythm.headerToContent)
                    if busy { ClubLoadingCard(title: "正在登录…", detail: "正在连接账号并恢复已同步的记录。") }
                    if let error { FlowError(message: error) }
                    if let notice = account.notice { Text(notice).bojiType(.caption).foregroundStyle(.secondary) }
                    if !account.pendingLocalErasureIDs.isEmpty { Button("重试本机清理") { account.retryLocalErasure() }.buttonStyle(SecondaryButton()).bojiType(.caption) }

                }.padding(ClubUI.pageInset).frame(maxWidth: ClubUI.contentWidth).frame(maxWidth: .infinity)
            }
        }
        .safeAreaInset(edge: .bottom) {
            FlowDock {
                Menu("协议与数据使用详情") {
                    Button("用户协议") { legalDocument = .terms }
                    Button("隐私政策") { legalDocument = .privacy }
                    Button("AI 服务说明") { legalDocument = .aiNotice }
                    Button("健康与运动风险提示") { legalDocument = .healthDisclaimer }
                    Button("购买与退款政策") { legalDocument = .purchase }
                    Button("注销说明") { legalDocument = .deletion }
                    Link("管理 Apple 登录授权", destination: URL(string: "https://support.apple.com/zh-cn/102571")!)
                }.bojiType(.label)
                Button {
                    legalAccepted.toggle()
                    // 协议勾选持久化：勾选后按版本记住，换账号重登免重复勾选；取消勾选即撤销记忆。
                    UserDefaults.standard.set(legalAccepted ? Self.legalAgreementVersion : nil, forKey: Self.legalAcceptedKey)
                } label: {
                    HStack(alignment: .top, spacing: BojiLayout.inline) {
                        Image(systemName: legalAccepted ? "checkmark.circle.fill" : "circle").bojiType(.section)
                        Text("我同意用户协议、隐私政策，并允许将主动发送的内容用于云端 AI 分析。")
                            .bojiType(.caption).multilineTextAlignment(.leading)
                    }.foregroundStyle(FlowPalette.secondaryInk).frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).disabled(busy)
                    .accessibilityLabel("同意协议与 AI 数据使用")
                    .accessibilityValue(legalAccepted ? "已同意" : "未同意")
                ZStack {
                    SignInWithAppleButton(.continue) { request in
                        appleNonce = UUID().uuidString.lowercased()
                        request.nonce = appleNonce
                    } onCompletion: { result in
                        completeAppleSignIn(result)
                    }
                    .signInWithAppleButtonStyle(.black)
                    .frame(height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: BojiRadius.inner, style: .continuous))
                    .opacity(legalAccepted && !busy ? 1 : 0.55)
                    .disabled(busy || !legalAccepted)
                    .accessibilityHidden(!legalAccepted)
                    if !legalAccepted && !busy {
                        Button { error = "请先阅读并同意协议，再继续登录。" } label: {
                            Color.clear.frame(height: 52).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .accessibilityLabel("继续使用 Apple 登录，需先同意协议")
                    }
                }
                Text("云端分析可在设置中关闭；设备权限由你另行选择。")
                    .bojiType(.caption).foregroundStyle(.secondary)
                #if DEBUG
                DisclosureGroup("开发工具") {
                NavigationLink("开发预览：会员价格页面") { MembershipView(screenshotPreview: true) }
                    .buttonStyle(SecondaryButton())
                Button("服务器测试登录 · 真实数据与动作库") { showServerTestLogin = true }
                    .buttonStyle(SecondaryButton()).disabled(busy || !legalAccepted)
                Button("开发预览：体验完整新手流程") {
                    error = nil
                    account.signInPreviewAsNewUser()
                }
                .buttonStyle(PrimaryButton())
                .disabled(busy)
                Button("开发预览：直接进入 App") {
                    error = nil
                    account.signInPreview()
                }
                .buttonStyle(SecondaryButton())
                .disabled(busy)
                Text("仅用于界面开发；不会登录 Apple ID，也不能使用云端同步或购买。")
                    .bojiType(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                #endif
            }
        }
        .tint(ClubBrand.accent)
        .sheet(item: $legalDocument) { document in LegalDocumentView(document: document) }
        .sheet(isPresented: $showServerTestLogin) {
            #if DEBUG
            ServerTestLoginView()
            #endif
        }
    }

    private func completeAppleSignIn(_ result: Result<ASAuthorization, Error>) {
        guard legalAccepted else { error = "请先阅读并勾选下方协议。"; return }
        guard case let .success(authorization) = result,
              let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = credential.identityToken,
              let identityToken = String(data: tokenData, encoding: .utf8),
              !appleNonce.isEmpty else {
            if case let .failure(value) = result, (value as? ASAuthorizationError)?.code == .canceled { return }
            error = "Apple 登录信息不完整，请重试。"
            return
        }
        busy = true; error = nil
        Task {
            defer { busy = false }
            do { try await account.signInWithApple(identityToken: identityToken, nonce: appleNonce, authorizationCode: credential.authorizationCode.flatMap { String(data: $0, encoding: .utf8) }, appleUserID: credential.user, allowCloudAnalysis: legalAccepted) }
            catch { self.error = AppErrorText.message(error) }
        }
    }
}

#if DEBUG
private struct ServerTestLoginView: View {
    @EnvironmentObject private var account: AccountService
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("独立服务器测试账号") {
                    SecureField("粘贴测试登录码", text: $code)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .textContentType(.password).disabled(busy)
                    Text("填写资料后会同步到你的账号。请使用自己的训练资料。")
                        .bojiType(.caption).foregroundStyle(.secondary)
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
                Section {
                    Button(busy ? "正在连接测试账号…" : "登录服务器测试账号") {
                        busy = true; error = nil
                        Task {
                            defer { busy = false }
                            do { try await account.signInServerTest(code: code, allowCloudAnalysis: true); code = ""; dismiss() }
                            catch { self.error = AppErrorText.message(error) }
                        }
                    }.buttonStyle(PrimaryButton()).disabled(busy || code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.clubGroupedSurface().navigationTitle("服务器测试登录").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { code = ""; dismiss() }.disabled(busy) } }
                .interactiveDismissDisabled(busy)
        }
    }
}
#endif

enum LegalDocument: String, Identifiable {
    case terms, privacy, purchase, deletion, aiNotice = "ai-notice", healthDisclaimer = "health-disclaimer", about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .terms: return "用户协议"
        case .privacy: return "隐私政策"
        case .purchase: return "购买与退款政策"
        case .deletion: return "注销账号与数据删除"
        case .aiNotice: return "AI 服务说明"
        case .healthDisclaimer: return "健康与运动风险提示"
        case .about: return "关于我们"
        }
    }

    var pagePath: String { "/doc/\(rawValue)" }
}

struct LegalDocumentView: View {
    @EnvironmentObject private var ai: AIService
    @EnvironmentObject private var account: AccountService
    let document: LegalDocument
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var reloadToken = 0
    @State private var loading = true
    @State private var loadFailed = false

    private var legalURL: URL? {
        var components = URLComponents(string: "https://bojiclub.fun\(document.pagePath)")
        components?.queryItems = [
            URLQueryItem(name: "lang", value: LegalSiteLanguage.current),
            URLQueryItem(name: "theme", value: colorScheme == .dark ? "dark" : "light")
        ]
        return components?.url
    }

    var body: some View {
        ClubNavigationStack132 {
            VStack(spacing: 0) {
                if document == .privacy, account.user != nil, !account.isPreviewAccount {
                    ClubCard {
                        Toggle("允许云端 AI 分析", isOn: Binding(get: { ai.routingConsentGranted }, set: { value in
                            if value { ai.acceptRoutingConsent() } else { ai.revokeRoutingConsent() }
                        }))
                        Text("关闭后，新的 AI 分析不会提交；已发出的请求可能仍会完成。")
                            .bojiType(.label).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, ClubUI.pageInset)
                    .padding(.vertical, BojiLayout.inline)
                }
                if let legalURL {
                    ZStack {
                        LegalSiteWebView(url: legalURL, reloadToken: reloadToken, onStarted: {
                            loading = true
                            loadFailed = false
                        }, onFinished: {
                            loading = false
                            loadFailed = false
                        }, onFailed: {
                            loading = false
                            loadFailed = true
                        })
                        if loading {
                            ProgressView("正在载入协议")
                                .padding(BojiLayout.cardInset)
                                .background(BojiColor.cardSurface, in: RoundedRectangle(cornerRadius: BojiRadius.inner, style: .continuous))
                        } else if loadFailed {
                            VStack(spacing: BojiLayout.rowGap) {
                                Text("协议页面暂时打不开")
                                    .bojiType(.bodyStrong)
                                Text("检查网络后重试。你可以稍后再回来查看。")
                                    .bojiType(.secondary).foregroundStyle(.secondary).multilineTextAlignment(.center)
                                Button("重试") { reloadToken += 1 }
                                    .buttonStyle(PrimaryButton())
                            }
                            .padding(BojiLayout.Rhythm.headerToContent)
                            .frame(maxWidth: 300)
                            .background(BojiColor.cardSurface, in: RoundedRectangle(cornerRadius: BojiRadius.cardSmall, style: .continuous))
                        }
                    }
                } else {
                    ContentUnavailableView("协议页面暂不可用", systemImage: "doc.text", description: Text("请检查网络后重试。"))
                }
            }
            .background { ClubBackground() }
            .navigationTitle(document.title).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { DismissButton() } }
        }
    }
}

private enum LegalSiteLanguage {
    static var current: String {
        let preferred = Locale.preferredLanguages.first?.lowercased() ?? "zh-cn"
        if preferred.contains("hant") || preferred.hasPrefix("zh-tw") || preferred.hasPrefix("zh-hk") || preferred.hasPrefix("zh-mo") { return "zh-TW" }
        if preferred.hasPrefix("zh") { return "zh-CN" }
        for lang in ["en", "ja", "ko", "th", "vi", "id", "ms"] where preferred.hasPrefix(lang) { return lang }
        return "zh-CN"
    }
}

private struct LegalSiteWebView: UIViewRepresentable {
    let url: URL
    let reloadToken: Int
    let onStarted: () -> Void
    let onFinished: () -> Void
    let onFailed: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero)
        view.navigationDelegate = context.coordinator
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.allowsBackForwardNavigationGestures = true
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self
        guard context.coordinator.lastURL != url || context.coordinator.lastReloadToken != reloadToken else { return }
        context.coordinator.lastURL = url
        context.coordinator.lastReloadToken = reloadToken
        onStarted()
        view.load(URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 20))
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: LegalSiteWebView
        var lastURL: URL?
        var lastReloadToken: Int?

        init(_ parent: LegalSiteWebView) { self.parent = parent }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { parent.onFinished() }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { parent.onFailed() }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { parent.onFailed() }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard action.navigationType == .linkActivated, let target = action.request.url else {
                decisionHandler(.allow)
                return
            }
            if target.host == parent.url.host {
                decisionHandler(.allow)
            } else if ["https", "http", "mailto"].contains(target.scheme?.lowercased() ?? "") {
                UIApplication.shared.open(target)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.cancel)
            }
        }
    }
}

private struct OnboardingGoalReference: View {
    let profile: MemberProfile
    let details: () -> Void

    var body: some View {
        HStack(spacing: BojiLayout.inline) {
            VStack(alignment: .leading, spacing: BojiLayout.tight) {
                if let bmi = BodyProfileAssessment.bmi(profile) {
                    Text("BMI \(bmi.formatted(.number.precision(.fractionLength(1)))) · \(BodyProfileAssessment.category(profile))")
                        .bojiType(.secondary)
                } else { Text("身体参考 · 按填写值评估").bojiType(.secondary) }
                Text("参考方向：\(BodyProfileAssessment.suggestedGoal(profile))")
                    .bojiType(.body).foregroundStyle(FlowPalette.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button(action: details) {
                Image(systemName: "info.circle").bojiType(.section).frame(width: 44, height: 44)
            }.buttonStyle(ClubMotionButton()).accessibilityLabel("查看 BMI 说明；参考不替代你的目标选择")
        }
        .padding(BojiSpace.general).frame(maxWidth: .infinity, alignment: .leading)
        .background(ClubUI.surface, in: RoundedRectangle(cornerRadius: ClubUI.cardRadius, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: ClubUI.cardRadius, style: .continuous).stroke(ClubUI.border).allowsHitTesting(false) }
    }
}

private struct OnboardingGoalChoice: View {
    let title: String
    let detail: String
    let symbol: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: BojiLayout.rowGap) {
                Image(systemName: symbol).bojiType(.section).frame(width: 24)
                VStack(alignment: .leading, spacing: BojiLayout.tight) {
                    Text(title).bojiType(.body)
                    if selected {
                        Text(detail).bojiType(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle").bojiType(.section)
                    .opacity(selected ? 1 : 0.4)
            }
            .padding(.horizontal, BojiLayout.cardInset).padding(.vertical, BojiSpace.general).frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .foregroundStyle(selected ? ClubBrand.onAccent : FlowPalette.ink)
            .background(selected ? ClubBrand.accent : ClubUI.surface, in: RoundedRectangle(cornerRadius: BojiRadius.inner, style: .continuous))
        }
        .buttonStyle(ClubMotionButton())
        .accessibilityHint(detail)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct OnboardingNavigation: View {
    let title: String
    let busy: Bool
    let error: String?
    let validation: String?
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: BojiLayout.inline) {
            if let error { FlowError(message: error) }
            else if let validation { Text(validation).bojiType(.secondary).foregroundStyle(FlowPalette.secondaryInk) }
            HStack(spacing: BojiLayout.cardInset) {
                Text(busy ? "正在保存资料…" : title)
                    .bojiType(.secondary)
                    .foregroundStyle(FlowPalette.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button(action: action) {
                    ZStack {
                        Circle().fill(ClubBrand.accent)
                        if busy { ClubActivityMark(size: 20, tint: ClubBrand.onAccent) }
                        else { Image(systemName: "arrow.right").bojiType(.section).foregroundStyle(ClubBrand.onAccent) }
                    }.frame(width: 52, height: 52)
                }
                .buttonStyle(ClubMotionButton()).disabled(busy)
                .accessibilityLabel(busy ? "正在保存资料" : title)
                .accessibilityHint("核对本页内容后继续；必填项缺失时会提示具体位置")
            }
        }
        .padding(.horizontal, ClubUI.pageInset).padding(.vertical, BojiLayout.inline).frame(maxWidth: ClubUI.contentWidth)
        .frame(maxWidth: .infinity).clubGlassEffect(in: RoundedRectangle(cornerRadius: BojiRadius.input, style: .continuous))
    }
}

private struct OnboardingDraft: Codable {
    var profile: MemberProfile
    var step: Int
    var planMode: String
    var covenantAccepted: Bool
    var planApplied: Bool
    var flowVersion: Int?
    var weightDateKey: String?
    var registerStartingWeight: Bool?
    var skipPlan: Bool?
    var manualPlan: Bool? = nil
    var conditionSection: Int?
    var identitySection: Int?
    var weightSource: String?
    var goalSection: Int? = nil
    var deferredJobID: String? = nil

    var restoredStep: Int {
        if [4, 5].contains(flowVersion ?? 0) { return min(4, max(0, step)) }
        if flowVersion == 3 { return min(3, max(0, step)) }
        return [0, 0, 1, 1, 2, 2, 3, 3][min(7, max(0, step))]
    }
    var restoredGoalSection: Int { min(1, max(0, goalSection ?? 0)) }
}

@MainActor
/// One-time, non-confirming import of the retired five-stage local draft.
/// Numeric values that still equal the old example defaults are deliberately
/// not imported; the member must confirm anything that becomes a fact.
enum LegacyOnboardingDraftMigration {
    static func snapshot(owner: Int) -> (taskKind: String, fields: [String: JSONValue])? {
        guard owner > 0, let data = OnboardingDraftStore.load(owner: owner),
              let draft = try? JSONDecoder().decode(OnboardingDraft.self, from: data) else { return nil }
        let profile = draft.profile
        let taskKind = draft.planMode == "parse_plan" ? "plan_import" : "plan_create"
        var fields: [String: JSONValue] = [:]
        let planImport = taskKind == "plan_import"
        let goal = profile.goal == "增肌" ? "增肌塑形" : profile.goal
        let goals = ["增肌塑形", "减脂瘦身", "紧致线条", "提升力量", "养成运动习惯"]
        if goals.contains(goal) { fields["goal"] = .string(goal) }
        if ["新手", "有基础", "进阶"].contains(profile.experience) { fields["experience"] = .string(profile.experience) }
        if ["健身房", "在家", "两者都有"].contains(profile.venue) { fields["venue"] = .string(profile.venue) }
        if let equipment = profile.equipment, !equipment.isEmpty {
            fields["equipment"] = .array(equipment.split(separator: "、").map { .string(String($0)) })
        }
        if let minutes = profile.sessionMinutes, (15...180).contains(minutes) { fields["session_minutes"] = .number(Double(minutes)) }
        if !planImport {
            if (1...7).contains(profile.daysPerWeek) { fields["days_per_week"] = .number(Double(profile.daysPerWeek)) }
            if let days = profile.trainingDays, !days.isEmpty, days.allSatisfy({ (1...7).contains($0) }) {
                fields["training_days"] = .array(days.sorted().map { .number(Double($0)) })
            }
            if !profile.focus.isEmpty { fields["focus"] = .string(profile.focus) }
            if let limitations = profile.limitations?.trimmingCharacters(in: .whitespacesAndNewlines), !limitations.isEmpty, !["无", "暂无", "没有"].contains(limitations) {
                fields["limitations"] = .string(limitations)
            }
            // Defaults are not facts. Only import numbers the old draft moved
            // away from its example defaults.
            if profile.age != 28, (13...100).contains(profile.age) {
                fields["age_years"] = .number(Double(profile.age))
                fields["age_group"] = .string(profile.age < 18 ? "minor" : "adult")
            }
            if abs(profile.height - 175) > 0.01, (50...250).contains(profile.height) { fields["height_cm"] = .number(profile.height) }
            if abs(profile.weight - 68) > 0.01, (20...400).contains(profile.weight) {
                fields["profile_weight_kg"] = .number(profile.weight)
                fields["weight_measurement_kind"] = .string("estimated")
            }
            if let gender = profile.gender, ["男", "女"].contains(gender) { fields["sex_for_nutrition"] = .string(gender) }
        } else {
            if profile.age != 28, (13...100).contains(profile.age) {
                fields["age_years"] = .number(Double(profile.age))
                fields["age_group"] = .string(profile.age < 18 ? "minor" : "adult")
            }
        }
        return fields.isEmpty ? nil : (taskKind, fields)
    }
}

struct OnboardingView: View {
    @EnvironmentObject private var account: AccountService
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var ai: AIService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var inputFocused: Bool
    @StateObject private var scrollMemory = ClubScrollMemory()
    @State private var step = 0
    @State private var conditionSection = 0
    @State private var identitySection = 0
    @State private var goalSection = 0
    @State private var deferredJobID: String?
    @State private var weightSource = ""
    @State private var weightMeasurementDate = Date()
    @State private var skipPlan = false
    @State private var manualPlan = false
    @State private var profile = MemberProfile()
    @State private var planMode = "generate_plan"
    @State private var covenantAccepted = false
    @State private var planApplied = false
    @State private var loaded = false
    @State private var draftOwner: Int?
    @State private var forward = true
    @State private var showPlan = false
    @State private var showNutritionPreferences = false
    @State private var showBodyReference = false
    @State private var showMemberCard = false
    @State private var busy = false
    @State private var error: String?
    @State private var selectionFeedback = 0
    @State private var successFeedback = 0
    @State private var validationField: String?
    @State private var validationRequest = 0
    private var ownsAccount: Bool { draftOwner != nil && draftOwner == account.user?.id && draftOwner == store.editingAccountID }
    private let stages = ["认识你", "训练目标", "训练条件", "确认资料", "俱乐部约定"]
    private var pageID: String {
        switch step {
        case 0: return "identity-\(identitySection)"
        case 1: return "goal-\(goalSection)"
        case 2: return "conditions-\(conditionSection)"
        default: return "stage-\(step)"
        }
    }
    private var startingWeightDate: Date? {
        StartingWeightSource(rawValue: weightSource)?.recordDate(selected: weightMeasurementDate, now: Date(), calendar: ClubDates.calendar)
    }
    private var registerStartingWeight: Bool { startingWeightDate != nil }
    private var transition: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(insertion: .offset(x: forward ? 22 : -22).combined(with: .opacity), removal: .opacity)
    }

    var body: some View {
        observedOnboarding
            .sheet(isPresented: $showNutritionPreferences) { nutritionPreferencesSheet }
            .sheet(isPresented: $showBodyReference) { bodyReferenceSheet }
            .fullScreenCover(isPresented: $showPlan, onDismiss: { if planApplied { complete() } }) { planCover }
            .overlay {
                if showMemberCard, deferredJobID != nil {
                    MemberCardCelebration(account: account.user, nickname: profile.nickname) {
                        OnboardingDraftStore.clear(owner: draftOwner ?? account.user?.id ?? 0); account.enterClub()
                    }
                }
            }
    }

    private var onboardingContent: some View {
        ZStack {
            FlowBackground()
            VStack(spacing: 0) {
                header
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: step == 1 || (step == 0 && identitySection == 1) ? 16 : 28) { page }
                            .padding(.horizontal, ClubUI.pageInset).padding(.top, step == 1 || (step == 0 && identitySection == 1) ? 12 : 30).padding(.bottom, BojiSpace.showcase)
                            .frame(maxWidth: ClubUI.contentWidth).frame(maxWidth: .infinity)
                            .id(pageID).transition(transition)
                            .background { ClubScrollPositionProbe(memory: scrollMemory, key: pageID) }
                    }.scrollDismissesKeyboard(.interactively).disabled(busy)
                        .task(id: validationRequest) {
                            guard validationRequest > 0, let field = validationField else { return }
                            await Task.yield()
                            guard !Task.isCancelled else { return }
                            withAnimation(reduceMotion ? nil : ClubMotion.standard) { proxy.scrollTo(field, anchor: .center) }
                        }
                }
            }
        }
        .tint(ClubBrand.accent)
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .bottom) { if !showMemberCard { navigation } }
        .overlay { if showMemberCard { MemberCardCelebration(account: account.user, nickname: profile.nickname) { OnboardingDraftStore.clear(owner: draftOwner ?? account.user?.id ?? 0); account.enterClub() } } }
        .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("完成") { inputFocused = false } } }
    }

    private var observedOnboarding: some View {
        onboardingDestination
        .onAppear(perform: restore)
        .onChange(of: scenePhase) { _, phase in if phase != .active { persistDraft() } }
        .onChange(of: draftData) { _, _ in if loaded { persistDraft() } }
        .onChange(of: profile.venue) { _, venue in
            if venue == "健身房" {
                profile.equipment = nil; profile.equipmentOther = nil; profile.homeTrainingDays = nil
            } else {
                profile.homeTrainingDays = (profile.homeTrainingDays ?? []).filter { (profile.trainingDays ?? []).contains($0) }
            }
        }
        .sensoryFeedback(.selection, trigger: step)
        .sensoryFeedback(.selection, trigger: selectionFeedback)
        .sensoryFeedback(.success, trigger: successFeedback)
    }

    @ViewBuilder private var onboardingDestination: some View {
        if let id = deferredJobID {
            FirstPlanPreviewView(initialPlanJobID: id, onPlanApplied: {
                         planApplied = true; persistDraft(); complete()
                     }, onReturnToOnboarding: { deferredJobID = nil; persistDraft() },
                     completionBusy: busy, completionError: error)
                .disabled(busy)
                .toolbar(.visible, for: .navigationBar)
        } else { onboardingContent }
    }

    private var nutritionPreferencesSheet: some View {
        NavigationStack {
            ScrollView { ActivityProfileFields(profile: $profile).padding(ClubUI.pageInset) }
                .background { ClubBackground() }
                .navigationTitle("饮食参考设置").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showNutritionPreferences = false } } }
        }
    }

    private var bodyReferenceSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: BojiLayout.blockGap) {
                    BodyAssessmentCard(profile: profile, readable: true)
                    Text("身体数据提供一个起点，不能单独判断体脂、肌肉量或健康状况。你的实际目标和训练条件仍会参与计划安排。")
                        .bojiType(.body).foregroundStyle(FlowPalette.secondaryInk)
                }.padding(ClubUI.pageInset)
            }
            .navigationTitle("身体参考").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showBodyReference = false } } }
        }
    }

    @ViewBuilder private var planCover: some View {
        if manualPlan { ManualPlanView(onSaved: { profile = store.state.profile; planApplied = true; persistDraft(); showPlan = false }) } else {
        PlanView(date: Date(), initialMode: planMode, onDeferred: { id in
            deferredJobID = id; persistDraft()
        }) {
            profile = store.state.profile
            planApplied = true; persistDraft(); showPlan = false
        }.environmentObject(store).environmentObject(ai)
        }
    }

    private var header: some View {
        VStack(spacing: BojiLayout.blockGap) {
            HStack {
                Button(action: back) {
                    Image(systemName: "arrow.left").frame(width: 44, height: 44)
                        .background(BojiColor.cardSurface.opacity(0.8), in: Circle())
                }.buttonStyle(ClubIconButtonStyle()).disabled((step == 0 && identitySection == 0) || busy).opacity(step == 0 && identitySection == 0 ? 0 : 1).accessibilityLabel("上一步")
                Spacer()
                Text("薄肌俱乐部").bojiType(.secondary)
                Spacer()
                Text(String(format: "%02d", step + 1)).bojiType(.caption).foregroundStyle(.secondary).frame(width: 44)
            }
            HStack(spacing: BojiLayout.tight) {
                ForEach(stages.indices, id: \.self) { index in
                    Capsule().fill(index <= step ? ClubBrand.accent : FlowPalette.ink.opacity(0.08)).frame(height: 3)
                }
            }.accessibilityLabel("第 \(step + 1) 步，共 \(stages.count) 步，\(stages[step])")
        }.padding(.horizontal, ClubUI.pageInset).padding(.top, BojiSpace.general).padding(.bottom, BojiLayout.tight)
    }

    @ViewBuilder private var page: some View {
        switch step {
        case 0: identityPage
        case 1: goalPage
        case 2: conditionsPage
        case 3: confirmationPage
        default: covenantPage
        }
    }

    @ViewBuilder private var identityPage: some View {
        if identitySection == 0 {
            FlowHeading(eyebrow: "认识你 · 1 / 2", title: "先认识一下。", subtitle: "建立你的档案，接下来再填写身体起点。")
            FlowSurface {
                Text("在俱乐部，我们如何称呼你").bojiType(.secondary).foregroundStyle(.secondary)
                TextField("你的昵称", text: $profile.nickname).bojiFont(.cardTitle)
                    .focused($inputFocused).submitLabel(.done)
            }.id("nickname")
            sectionLabel("性别").id("gender")
            FlowChips(values: ["男", "女"], selection: Binding(get: { profile.gender ?? "" }, set: { profile.gender = $0 }))
            FlowSurface { numberRow("年龄", unit: "岁", value: $profile.age) }.id("age")
            Text("用于选择适用的身体与营养参考，之后可以修改。").bojiType(.label).foregroundStyle(.secondary)
        } else {
            FlowHeading(eyebrow: "认识你 · 2 / 2", title: "记下身体起点。", subtitle: "请核对身高与体重。估计体重也能建立资料，不会当作实测记录。")
            FlowSurface {
                decimalRow("身高", unit: "cm", value: $profile.height).id("height")
                Divider()
                decimalRow("体重", unit: "kg", value: $profile.weight).id("weight")
            }
            OnboardingGoalReference(profile: profile) { showBodyReference = true }
            Text("这个体重是什么时候称的？").bojiType(.secondary).id("weight-source")
            VStack(spacing: BojiLayout.inline) {
                ForEach(StartingWeightSource.allCases, id: \.rawValue) { source in
                    ClubOptionRow(title: source.rawValue, selected: weightSource == source.rawValue) {
                        weightSource = source.rawValue
                        if source == .today { weightMeasurementDate = Date() }
                    }
                }
            }
            if weightSource == StartingWeightSource.earlier.rawValue {
                DatePicker("称重日期", selection: $weightMeasurementDate, in: ...Date(), displayedComponents: .date).id("weight-date")
            }
            Text(startingWeightDate.map { "会登记为 \(ClubDates.label($0)) 的实测体重；该日已有记录时保留原值。" } ?? "估计值只用于身体资料，不进入体重变化曲线。")
                .bojiType(.label).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var goalPage: some View {
        if goalSection == 0 {
            FlowHeading(eyebrow: "训练目标 · 1 / 2", title: "你想先改变什么？", subtitle: "先选一个目标。下一步再确认训练经验与重点部位。")
            OnboardingGoalReference(profile: profile) { showBodyReference = true }
            VStack(spacing: BojiLayout.inline) {
                goal("增肌塑形", "增加肌肉，让身体更有力量感", "figure.strengthtraining.traditional")
                goal("减脂瘦身", "规律训练，逐步改善身体组成", "flame")
                goal("紧致线条", "关注肌肉线条与身体比例", "figure.cooldown")
                goal("提升力量", "稳步提高动作表现与负重能力", "dumbbell")
                goal("养成运动习惯", "从容易坚持的训练节奏开始", "sun.max")
            }.id("goal")
        } else {
            FlowHeading(eyebrow: "训练目标 · 2 / 2", title: "让训练更适合你。", subtitle: "告诉我们训练经验和重点部位，用来选择动作与起始强度。")
            FlowSurface {
                sectionLabel("你的训练经验").id("experience")
                FlowChips(values: ["新手", "有基础", "进阶"], selection: $profile.experience)
            }
            FlowSurface {
                sectionLabel("优先关注的部位").id("focus")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 75))], spacing: BojiLayout.inline) {
                    ForEach(["全身", "胸部", "背部", "肩部", "手臂", "臀腿", "核心"], id: \.self) { part in
                        focusButton(part: part)
                    }
                }
            }
        }
    }

    @ViewBuilder private var conditionsPage: some View {
            FlowHeading(eyebrow: "03 / YOUR ROUTINE", title: "让安排适合你的生活。", subtitle: "先确认可用器械，再安排做得到的训练日。")
            Picker("训练条件", selection: $conditionSection) {
                Text("场所与器械").tag(0)
                Text("日程与时长").tag(1)
            }.clubAdaptivePicker()
            if conditionSection == 0 {
            sectionLabel("训练场地")
            FlowChips(values: ["健身房", "在家", "两者都有"], selection: $profile.venue)
            if profile.venue != "健身房" {
                FlowSurface {
                    sectionLabel("居家可用器械").id("equipment")
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: BojiLayout.inline), count: 2), spacing: BojiLayout.inline) {
                        ForEach(["徒手", "哑铃", "弹力带", "壶铃", "引体向上杆", "瑜伽垫", "小杠铃", "卧推凳", "有氧器械", "其他"], id: \.self) { item in
                            equipmentButton(item: item)
                        }
                    }
                    if equipmentSelection.contains("其他") {
                        TextField("补充其他器械", text: optionalText(\.equipmentOther))
                            .focused($inputFocused)
                    }
                    Text(profile.venue == "在家"
                         ? "居家训练只使用上面选择的器械。"
                         : "健身房按标准器械安排；居家训练日只使用上面选择的器械。")
                        .bojiType(.caption).foregroundStyle(.secondary)

                }
            } else {
                FlowSurface {
                    Label("将按标准健身房器械编排训练", systemImage: "dumbbell")
                        .bojiType(.secondary)
                    Text("杠铃、哑铃、绳索、深蹲架、卧推凳和常见固定器械均可使用。")
                        .bojiType(.caption).foregroundStyle(.secondary)
                }
            }
            } else {
            FlowSurface {
                HStack { sectionLabel("每周训练日").id("training-days"); Spacer(); Text("\(profile.daysPerWeek) 天").bojiFont(.setNumber, monospacedDigits: true).foregroundStyle(BojiColor.textPrimary) }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: BojiLayout.tight), count: 7), spacing: BojiLayout.inline) {
                    ForEach(1...7, id: \.self) { day in
                        trainingDayButton(day: day)
                    }
                }
                Text("至少保留一个训练日。")
                    .bojiType(.caption).foregroundStyle(.secondary)
            }
            if profile.venue == "两者都有" {
                FlowSurface {

                        Divider()
                        HStack {
                            sectionLabel("在家训练日")
                            Spacer()
                            if (profile.homeTrainingDays ?? []).isEmpty {
                                Text("按所选训练日顺序交替安排健身房和居家，从健身房开始").bojiType(.caption).foregroundStyle(.secondary)
                            }
                        }
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: BojiLayout.tight), count: 7), spacing: BojiLayout.inline) {
                            ForEach(1...7, id: \.self) { day in
                                homeTrainingDayButton(day: day)
                            }
                        }
                        Button("不固定训练地点") { profile.homeTrainingDays = [] }.buttonStyle(SecondaryButton()).bojiType(.caption)
                }
            }
            FlowSurface {
                HStack {
                    sectionLabel("每次训练时长")
                    Spacer()
                    Text("\(profile.sessionMinutes ?? 45) 分钟").bojiType(.bodyStrong)
                }
                Slider(value: Binding(get: { Double(profile.sessionMinutes ?? 45) }, set: { profile.sessionMinutes = Int($0) }), in: 15...120, step: 5)
                    .accessibilityLabel("每次训练时长，分钟")
            }
            FlowSurface {
                sectionLabel("先安排多长时间？")
                Picker("计划长度", selection: Binding(get: { profile.planDurationDays ?? 14 }, set: { profile.planDurationDays = $0 })) {
                    Text("7 天").tag(7); Text("14 天").tag(14); Text("28 天").tag(28)
                }.clubAdaptivePicker()
                Text("先制定基础一周；后续周沿用动作与组次，不自动加重。每完成一周，可通过回顾确认调整下一周。").bojiType(.secondary).foregroundStyle(.secondary)
            }
            DisclosureGroup {
                FlowSurface {
                    sectionLabel("需要我们留意的情况 · 选填")
                    TextField("例如：膝盖不适，避免跳跃", text: optionalText(\.limitations), axis: .vertical)
                        .lineLimit(2...4).focused($inputFocused)
                }
            } label: {
                Label("更多训练设置", systemImage: "slider.horizontal.3")
                    .bojiType(.secondary)
            }
            }
    }

    @ViewBuilder private var confirmationPage: some View {
            FlowHeading(eyebrow: "04 / READY TO START", title: "确认资料，准备开始。", subtitle: "选择制定计划后，可以先查看、修改并保存安排，再决定是否加入会员。")
            FlowSurface {
                reviewRow("昵称与性别", "\(profile.nickname) · \(profile.gender ?? "待选择")", step: 0, identity: 0)
                Divider()
                reviewRow("主要目标", profile.goal, step: 1, goal: 0)
                Divider()
                reviewRow("训练安排", "\(profile.venue) · 每周 \(profile.daysPerWeek) 天 · \(profile.sessionMinutes ?? 45) 分钟", step: 2, section: 1)
                Divider()
                reviewRow("计划跨度", "\(profile.planDurationDays ?? 14) 天 · 每周可确认调整", step: 2, section: 1)
            }.disabled(planApplied)
            DisclosureGroup {
                FlowSurface {
                    reviewRow("身体数据", "\(profile.height.formatted()) 厘米 · \(profile.weight.formatted()) 公斤", step: 0, identity: 1)
                    Divider()
                    reviewRow("训练偏好", "\(profile.experience) · \(profile.focus)", step: 1, goal: 1)
                    Divider()
                    reviewRow("器械与地点", profile.venue == "健身房" ? "标准健身房器械" : (profile.equipment ?? "未设置"), step: 2, section: 0)
                }
            } label: {
                Label("检查完整资料", systemImage: "checklist")
                    .bojiType(.secondary)
            }
            ClubRouteRow(title: "饮食参考设置", symbol: "fork.knife", detail: "日常活动与特殊饮食情况 · 可稍后修改") { showNutritionPreferences = true }
            if !planApplied && canUseCloudAnalysis {
                FlowChoice(title: "专属训练计划", detail: "先生成并核对 \(profile.planDurationDays ?? 14) 天安排；后续周沿用基础安排。加入前最多生成 5 份候选计划", symbol: "sparkles", selected: !skipPlan && !manualPlan && planMode == "generate_plan") { manualPlan = false; skipPlan = false; planMode = "generate_plan" }
                FlowChoice(title: "整理我的训练计划", detail: "先把已有安排整理成训练日程；加入前最多生成 5 份候选计划", symbol: "doc.text", selected: !skipPlan && !manualPlan && planMode == "parse_plan") { manualPlan = false; skipPlan = false; planMode = "parse_plan" }
            }
            if !planApplied && !canUseCloudAnalysis {
                Text("云端分析已在隐私设置中关闭。完成引导并加入会员后仍可手动记录；之后可在“设置 → 云端分析与隐私”重新开启专属计划。")
                    .bojiType(.secondary).foregroundStyle(FlowPalette.secondaryInk)
            }
            if !planApplied {
                FlowChoice(title: "自己安排训练", detail: "选择动作与组次，不需要生成计划", symbol: "slider.horizontal.3", selected: manualPlan && !skipPlan) { manualPlan = true; skipPlan = false }
                FlowChoice(title: "先不制定计划", detail: "完成引导后选择会员方案，加入后再开始记录和添加动作", symbol: "arrow.right.circle", selected: skipPlan) { manualPlan = false; skipPlan = true }
            }
    }

    @ViewBuilder private var covenantPage: some View {
        FlowHeading(eyebrow: "欢迎加入薄肌俱乐部", title: "准备开始训练。", subtitle: "先选适合自己的安排，再记录每次训练。")
        FlowSurface {
            covenant("01", "为自己赴约", "把训练留在日程里，也允许自己重新开始。")
            Divider()
            covenant("02", "记录真实的自己", "认真观察每一次训练、饮食与变化。")
            Divider()
            covenant("03", "尊重身体的节奏", "坚持，也给恢复留出空间。")
        }.clubReveal()
        Text("这是我们的俱乐部约定。你的数据使用选择可以在“设置 → 云端分析与隐私”里随时查看和修改。")
            .bojiType(.label).foregroundStyle(.secondary)
    }

    private var navigation: some View {
        OnboardingNavigation(title: buttonTitle, busy: busy, error: error, validation: validation, action: advance)
    }
    private var buttonTitle: String {
        if planApplied && step == 4 { return "我准备好了，领取俱乐部卡片" }
        if step == 0 { return identitySection == 0 ? "下一步：身体起点" : "下一步：训练目标" }
        if step == 1 { return goalSection == 0 ? "下一步：训练偏好" : "下一步：训练条件" }
        if step == 2 && conditionSection == 0 { return "下一步：训练时间" }
        if step == 3 { return "下一步：俱乐部约定" }
        if step == 4 { return "我准备好了，加入俱乐部" }
        return "下一步"
    }

    private var canUseCloudAnalysis: Bool { account.isPreviewAccount || CloudAnalysisConsent.allowed(accountID: account.user?.id) }
    private struct ValidationIssue {
        let message: String
        let step: Int
        let section: Int
        let field: String
    }
    private var validation: String? { validationIssue?.message }
    private var validationIssue: ValidationIssue? {
        let all = step >= 3
        func issue(_ message: String, _ step: Int, _ section: Int, _ field: String) -> ValidationIssue {
            ValidationIssue(message: message, step: step, section: section, field: field)
        }
        if all || (step == 0 && identitySection == 0) {
            if !(2...20).contains(profile.nickname.trimmingCharacters(in: .whitespacesAndNewlines).count) { return issue("请填写 2—20 个字符的昵称。", 0, 0, "nickname") }
            if !["男", "女"].contains(profile.gender ?? "") { return issue("请选择性别。", 0, 0, "gender") }
            if !entered("age_years") || !(13...100).contains(profile.age) { return issue("请填写 13—100 岁的年龄。", 0, 0, "age") }
        }
        if all || (step == 0 && identitySection == 1) {
            if !entered("height_cm") || !profile.height.isFinite || !(50...250).contains(profile.height) { return issue("请填写 50—250 cm 的身高。", 0, 1, "height") }
            if !entered("profile_weight_kg") || !profile.weight.isFinite || !(20...400).contains(profile.weight) { return issue("请填写 20—400 kg 的体重。", 0, 1, "weight") }
            if StartingWeightSource(rawValue: weightSource) == nil { return issue("请选择这个体重的来源；估计值也可以继续。", 0, 1, "weight-source") }
            if weightSource != StartingWeightSource.estimate.rawValue && startingWeightDate == nil { return issue("称重日期不能在未来，请重新选择实际称重日期。", 0, 1, "weight-date") }
        }
        if all || (step == 1 && goalSection == 0) {
            if !["增肌塑形", "减脂瘦身", "紧致线条", "提升力量", "养成运动习惯"].contains(profile.goal) {
                return issue("请选择一个主要训练目标。", 1, 0, "goal")
            }
        }
        if all || (step == 1 && goalSection == 1) {
            if !["新手", "有基础", "进阶"].contains(profile.experience) {
                return issue("请选择你的训练经验。", 1, 1, "experience")
            }
            let focus = Set(profile.focus.split(separator: "、").map { String($0) })
            if focus.isEmpty || !focus.isSubset(of: Set(["全身", "胸部", "背部", "肩部", "手臂", "臀腿", "核心"])) {
                return issue("请选择优先关注的部位。", 1, 1, "focus")
            }
        }
        if all || (step == 2 && conditionSection == 0) {
            if profile.venue != "健身房" {
                if equipmentSelection.isEmpty { return issue("请至少选择一种居家可用器械。", 2, 0, "equipment") }
                if equipmentSelection.contains("其他") && (profile.equipmentOther ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return issue("请补充其他器械名称。", 2, 0, "equipment") }
            }
        }
        if all || (step == 2 && conditionSection == 1) {
            if (profile.trainingDays ?? []).isEmpty { return issue("请选择至少一个训练日。", 2, 1, "training-days") }
        }
        return nil
    }
    private func sectionLabel(_ title: String) -> some View { Text(title).bojiType(.secondary).foregroundStyle(FlowPalette.secondaryInk) }
    private func entered(_ field: String) -> Bool { profile.isFactConfirmed(field) || profile.factState?[field]?.sourceKind == "draft" }
    private func markEntered(_ field: String) { if profile.factState == nil { return }; profile.factState?[field] = ProfileFactMeta(sourceKind: "draft", confirmedAt: nil, revision: nil) }
    private func confirmLegacySummary() {
        guard profile.factState != nil else { return }
        for field in ["age_years","height_cm","profile_weight_kg","sex_for_nutrition","goal","experience","venue","equipment","training_days","days_per_week","session_minutes","focus"] {
            profile.factState?[field] = ProfileFactMeta(sourceKind: "confirmed", confirmedAt: nil, revision: nil)
        }
    }
    private func numberRow(_ title: String, unit: String, value: Binding<Int>) -> some View {
        HStack {
            Text(title).bojiType(.secondary); Spacer()
            TextField(title, text: Binding(get: { entered("age_years") ? String(value.wrappedValue) : "" }, set: { if let n=Int($0) { value.wrappedValue=n; markEntered("age_years") } })).keyboardType(.numberPad).focused($inputFocused)
                .bojiType(.title).multilineTextAlignment(.trailing)
                .accessibilityLabel("\(title)，\(unit)")
            Text(unit).bojiType(.caption).foregroundStyle(.secondary).frame(width: 25)
        }.padding(.vertical, BojiSpace.general)
    }
    private func decimalRow(_ title: String, unit: String, value: Binding<Double>) -> some View {
        HStack {
            Text(title).bojiType(.secondary); Spacer()
            TextField(title, text: Binding(get: { entered(title == "身高" ? "height_cm" : "profile_weight_kg") ? value.wrappedValue.formatted() : "" }, set: { if let n=Double($0.replacingOccurrences(of: ",", with: ".")) { value.wrappedValue=n; markEntered(title == "身高" ? "height_cm" : "profile_weight_kg") } })).keyboardType(.decimalPad).focused($inputFocused)
                .bojiType(.title).multilineTextAlignment(.trailing)
                .accessibilityLabel("\(title)，\(unit)")
            Text(unit).bojiType(.caption).foregroundStyle(.secondary).frame(width: 25)
        }.padding(.vertical, BojiSpace.general)
    }
    private func goal(_ title: String, _ detail: String, _ symbol: String) -> some View {
        OnboardingGoalChoice(title: title, detail: detail, symbol: symbol, selected: profile.goal == title) { profile.goal = title }
    }
    private func covenant(_ number: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: BojiLayout.blockGap) {
            Text(number).bojiType(.caption).foregroundStyle(ClubBrand.accent).padding(.top, BojiLayout.tight)
            VStack(alignment: .leading, spacing: BojiLayout.inline) {
                Text(title).bojiType(.section); Text(detail).bojiType(.secondary).foregroundStyle(.secondary).lineSpacing(5)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, BojiLayout.Rhythm.headerToContent)
    }
    private func reviewRow(_ label: String, _ value: String, step: Int, section: Int? = nil, identity: Int? = nil, goal: Int? = nil) -> some View {
        Button {
            // Capture the page being left before updating its substep identity.
            scrollMemory.capture()
            if let section { conditionSection = section }
            if let identity { identitySection = identity }
            if let goal { goalSection = goal }
            move(to: step)
        } label: {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: BojiLayout.tight) { Text(label).bojiType(.caption).foregroundStyle(.secondary); Text(value).bojiType(.secondary) }
                Spacer(); Image(systemName: "arrow.up.right").bojiType(.caption).foregroundStyle(.secondary)
            }.padding(.vertical, BojiLayout.tight)
        }.buttonStyle(ClubMotionButton())
    }
    private func optionalText(_ key: WritableKeyPath<MemberProfile, String?>) -> Binding<String> {
        Binding(get: { profile[keyPath: key] ?? "" }, set: { profile[keyPath: key] = $0 })
    }
    private func trainingDayButton(day: Int) -> some View {
        let selected = (profile.trainingDays ?? []).contains(day)
        return Button {
            toggleDay(day)
        } label: {
            Text(weekdayLabel(day))
                .bojiType(.secondary)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 46)
                .foregroundStyle(selected ? ClubBrand.onAccent : FlowPalette.ink)
                .background(selected ? ClubBrand.accent : FlowPalette.paper, in: Capsule())
        }
        .buttonStyle(ClubMotionButton())
        .accessibilityLabel("周" + weekdayLabel(day))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func homeTrainingDayButton(day: Int) -> some View {
        let selected = (profile.homeTrainingDays ?? []).contains(day)
        let available = (profile.trainingDays ?? []).contains(day)
        return Button {
            toggleHomeDay(day)
        } label: {
            Text(weekdayLabel(day))
                .bojiType(.caption)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
                .foregroundStyle(selected ? ClubBrand.onAccent : FlowPalette.ink)
                .background(selected ? ClubBrand.accent : FlowPalette.paper, in: Capsule())
                .opacity(available ? 1 : 0.35)
        }
        .buttonStyle(ClubMotionButton())
        .disabled(!available)
        .accessibilityLabel("周" + weekdayLabel(day) + "在家训练")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .onChange(of: selected) { _, _ in selectionFeedback &+= 1 }
    }

    private func focusButton(part: String) -> some View {
        let selected = profile.focus.components(separatedBy: "、").contains(part)
        return Button {
            toggleFocus(part)
        } label: {
            Text(part)
                .bojiType(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, BojiSpace.general)
                .foregroundStyle(selected ? ClubBrand.onAccent : FlowPalette.ink)
                .background(selected ? ClubBrand.accent : FlowPalette.paper, in: Capsule())
        }
        .buttonStyle(ClubMotionButton())
        .accessibilityLabel("重点部位：\(part)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func equipmentButton(item: String) -> some View {
        let selected = equipmentSelection.contains(item)
        return Button {
            toggleEquipment(item)
        } label: {
            Text(item)
                .bojiType(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, BojiLayout.rowGap)
                .foregroundStyle(selected ? ClubBrand.onAccent : FlowPalette.ink)
                .background(selected ? ClubBrand.accent : FlowPalette.paper, in: Capsule())
        }
        .buttonStyle(ClubMotionButton())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func weekdayLabel(_ day: Int) -> String {
        ["一", "二", "三", "四", "五", "六", "日"][max(0, min(6, day - 1))]
    }
    private func toggleFocus(_ part: String) {
        var parts = profile.focus.components(separatedBy: "、").filter { $0 != "全身" }
        if part == "全身" { parts = [] }
        else if parts.contains(part) { parts.removeAll { $0 == part } }
        else { parts.append(part) }
        profile.focus = parts.isEmpty ? "全身" : parts.joined(separator: "、")
    }
    private func toggleDay(_ day: Int) {
        var days = profile.trainingDays ?? []
        if days.contains(day) { guard days.count > 1 else { return }; days.removeAll { $0 == day } }
        else { days.append(day) }
        profile.trainingDays = days.sorted(); profile.daysPerWeek = days.count
        profile.homeTrainingDays = (profile.homeTrainingDays ?? []).filter { days.contains($0) }
        if profile.venue == "两者都有" && (profile.homeTrainingDays ?? []).isEmpty { profile.homeTrainingDays = [] }
    }
    private var equipmentSelection: [String] {
        (profile.equipment ?? "").components(separatedBy: "、").filter { !$0.isEmpty }
    }
    private func toggleEquipment(_ item: String) {
        var values = equipmentSelection
        if values.contains(item) {
            values.removeAll { $0 == item }
            if item == "其他" { profile.equipmentOther = nil }
        } else { values.append(item) }
        profile.equipment = values.isEmpty ? nil : values.joined(separator: "、")
    }
    private func toggleHomeDay(_ day: Int) {
        guard (profile.trainingDays ?? []).contains(day) else { return }
        var days = profile.homeTrainingDays ?? []
        if days.contains(day) { days.removeAll { $0 == day } } else { days.append(day) }
        profile.homeTrainingDays = days.sorted()
    }
    private func back() {
        scrollMemory.capture()
        inputFocused = false; error = nil; forward = false
        if step == 0 && identitySection == 1 { identitySection = 0; persistDraft(); return }
        if step == 1 && goalSection == 1 { moveGoal(to: 0); return }
        if step == 2 && conditionSection == 1 { conditionSection = 0; persistDraft(); return }
        if step == 1 { identitySection = 1 }
        if step == 2 { goalSection = 1 }
        move(to: step - 1)
    }
    private func move(to next: Int) {
        scrollMemory.capture()
        inputFocused = false; error = nil; forward = next > step
        withAnimation(reduceMotion ? nil : BojiMotion2.state) { step = min(4, max(0, next)) }
        persistDraft()
    }
    private func moveGoal(to section: Int) {
        scrollMemory.capture(); inputFocused = false; error = nil; forward = section > goalSection
        withAnimation(reduceMotion ? nil : ClubMotion.standard) { goalSection = min(1, max(0, section)) }
        selectionFeedback &+= 1; persistDraft()
    }
    private func advance() {
        inputFocused = false
        guard !busy else { return }
        guard ownsAccount else { error = "账号正在准备或已经变化，请返回登录页后重新进入；已填写的内容会保留。"; ClubAccessibility.announce(error ?? ""); return }
        if let issue = validationIssue {
            error = issue.message
            scrollMemory.capture(); forward = issue.step >= step
            identitySection = issue.step == 0 ? issue.section : identitySection
            goalSection = issue.step == 1 ? issue.section : goalSection
            conditionSection = issue.step == 2 ? issue.section : conditionSection
            step = issue.step; validationField = issue.field; validationRequest &+= 1
            scrollMemory.prepareForFieldFocus(key: pageID)
            ClubAccessibility.announce(issue.message)
            return
        }
        if step == 0 && identitySection == 0 { scrollMemory.capture(); identitySection = 1; persistDraft(); return }
        if step == 1 && goalSection == 0 { moveGoal(to: 1); return }
        if step == 2 && conditionSection == 0 { scrollMemory.capture(); conditionSection = 1; persistDraft(); return }
        if step < 4 { move(to: step + 1); return }
        confirmLegacySummary()
        covenantAccepted = true
        if planApplied { complete(); return }
        if !canUseCloudAnalysis && !manualPlan { skipPlan = true; complete(); return }
        if skipPlan { complete(); return }
        busy = true; error = nil
        Task {
            defer { busy = false }
            do {
                guard ownsAccount, !Task.isCancelled else { return }
                try await account.saveOnboarding(profile: profile, planMode: planMode)
                guard ownsAccount, !Task.isCancelled else { return }
                guard store.saveProfile(profile, initialWeightDate: startingWeightDate) else { error = store.takeMessage(fallback: "资料保存失败，请重试。"); return }
                persistDraft()
                showPlan = true
                successFeedback &+= 1
            } catch { self.error = AppErrorText.message(error) }
        }
    }
    private func complete() {
        guard !busy, ownsAccount, covenantAccepted else { return }
        guard store.saveProfile(profile, initialWeightDate: startingWeightDate) else { error = store.takeMessage(fallback: "资料保存失败，请重试。"); return }
        busy = true; error = nil
        Task {
            defer { busy = false }
            do {
                guard ownsAccount, !Task.isCancelled else { return }
                try await account.saveOnboarding(profile: profile, planMode: planMode)
                guard ownsAccount, !Task.isCancelled else { return }
                try await account.completeOnboarding()
                guard ownsAccount, !Task.isCancelled else { return }
                showMemberCard = true
            }
            catch { self.error = "资料已保存。卡片领取失败，请重试：\(AppErrorText.message(error))" }
        }
    }
    private var draftData: Data? {
        try? JSONEncoder().encode(OnboardingDraft(profile: profile, step: step, planMode: planMode, covenantAccepted: covenantAccepted, planApplied: planApplied, flowVersion: 5, weightDateKey: ClubDates.key(weightMeasurementDate), registerStartingWeight: registerStartingWeight, skipPlan: skipPlan, manualPlan: manualPlan, conditionSection: conditionSection, identitySection: identitySection, weightSource: weightSource, goalSection: goalSection, deferredJobID: deferredJobID))
    }
    private func persistDraft() {
        if loaded, ownsAccount, let data = draftData {
            _ = OnboardingDraftStore.save(data, owner: draftOwner ?? account.user?.id ?? 0)
        }
    }
    private func restore() {
        guard !loaded else { return }
        draftOwner = account.user?.id
        if let data = OnboardingDraftStore.load(owner: draftOwner ?? account.user?.id ?? 0), let draft = try? JSONDecoder().decode(OnboardingDraft.self, from: data) {
            profile = draft.profile
            step = draft.restoredStep
            identitySection = min(1, max(0, draft.identitySection ?? 0))
            goalSection = draft.restoredGoalSection
            deferredJobID = draft.deferredJobID
            conditionSection = min(1, max(0, draft.conditionSection ?? (draft.step == 5 ? 1 : 0)))
            if let key = draft.weightDateKey, let date = ClubDates.date(fromKey: key) { weightMeasurementDate = date }
            weightSource = draft.weightSource ?? ""; skipPlan = draft.skipPlan ?? false; manualPlan = draft.manualPlan ?? false
            if weightSource == StartingWeightSource.today.rawValue && !ClubDates.calendar.isDateInToday(weightMeasurementDate) { weightSource = StartingWeightSource.earlier.rawValue }
            if ![4, 5].contains(draft.flowVersion ?? 0) && weightSource.isEmpty { step = 0; identitySection = 1 }
            planMode = draft.planMode
            covenantAccepted = draft.covenantAccepted; planApplied = draft.planApplied
        } else {
            profile = account.user?.profile ?? store.state.profile
            if profile.nickname == "薄肌新成员" { profile.nickname = "" }
            if profile.goal == "增肌" { profile.goal = "增肌塑形" }
            planMode = account.user?.planMode ?? "generate_plan"
        }
        if profile.goal == "增肌" { profile.goal = "增肌塑形" }
        if !canUseCloudAnalysis && !manualPlan { manualPlan = false; skipPlan = true }
        if (profile.trainingDays ?? []).isEmpty {
            profile.trainingDays = Array([1, 3, 5, 2, 4, 6, 7].prefix(max(1, min(7, profile.daysPerWeek)))).sorted()
        }
        profile.daysPerWeek = profile.trainingDays?.count ?? 3
        loaded = true
        if account.user?.onboardingCompleted == true { showMemberCard = true }
        if profile.planDurationDays == nil { profile.planDurationDays = 14 }
        if planApplied && StartingWeightSource(rawValue: weightSource) != nil { step = 3 }
    }
}

private struct MemberCardCelebration: View {
    let account: ClubAccount?
    let nickname: String
    let enter: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false
    var body: some View {
        ZStack {
            FlowBackground()
            if !reduceMotion { ConfettiView().accessibilityHidden(true) }
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    FlowHeading(eyebrow: "WELCOME TO 薄肌俱乐部", title: "设置完成。", subtitle: "\(nickname)，欢迎来到薄肌俱乐部。")
                    VStack(alignment: .leading, spacing: 32) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: BojiLayout.inline) { Text("薄肌俱乐部").bojiType(.section); Text("俱乐部成员").bojiType(.eyebrow) }
                            Spacer(); BojiBrandMark(size:36,style:.onDark)
                        }
                        Text(nickname).bojiType(.title).padding(.top, BojiSpace.pageInset)
                        Rectangle().fill(.white.opacity(0.16)).frame(height: 1)
                        HStack { Text(account?.clubNumber ?? "NO. —").bojiType(.secondary); Spacer(); Text("专属成员卡").bojiType(.caption) }
                    }.padding(BojiLayout.sectionGap).foregroundStyle(.white)
                        .background(LinearGradient(colors: [FlowPalette.ink, Color(white: 0.22)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: BojiRadius.hero))
                        .overlay { RoundedRectangle(cornerRadius: BojiRadius.hero).strokeBorder(FlowPalette.silver.opacity(0.5)) }
                        .overlay(alignment: .topLeading) {
                            Capsule().fill(ClubBrand.accent).frame(width: 48, height: 4).padding(BojiLayout.sectionGap).allowsHitTesting(false)
                        }
                        .shadow(color: FlowPalette.ink.opacity(0.2), radius: 22, y: 16)
                        .scaleEffect(revealed || reduceMotion ? 1 : 0.94).opacity(revealed ? 1 : 0)
                        .rotation3DEffect(.degrees(revealed || reduceMotion ? 0 : 8), axis: (x: 1, y: 0, z: 0))
                    Text("为身体投入时间，\n为每一次进步留下记录。")
                        .bojiType(.section).lineSpacing(9).foregroundStyle(FlowPalette.secondaryInk)
                }.padding(BojiLayout.sectionGap).padding(.top, BojiLayout.Rhythm.pageTop).frame(maxWidth: ClubUI.contentWidth).frame(maxWidth: .infinity)
            }
        }.safeAreaInset(edge: .bottom) { FlowDock { Button("开始我的第一天", action: enter).buttonStyle(FlowButtonStyle()) } }
            .onAppear { withAnimation(reduceMotion ? nil : BojiMotion2.celebrate) { revealed = true } }
            .sensoryFeedback(.success, trigger: revealed)
    }
}

private struct ConfettiView: View {
    @State private var falling = false
    var body: some View {
        GeometryReader { proxy in
            ForEach(0..<22, id: \.self) { index in
                Capsule().fill(index.isMultiple(of: 3) ? FlowPalette.silver : FlowPalette.secondaryInk.opacity(0.35))
                    .frame(width: 3, height: CGFloat(7 + index % 5))
                    .rotationEffect(.degrees(falling ? Double(index * 53) : 0))
                    .position(x: CGFloat((index * 47) % 100) / 100 * proxy.size.width, y: falling ? proxy.size.height + 25 : -CGFloat(30 + index * 13))
                    .opacity(falling ? 0 : 1)
                    .animation(.easeInOut(duration: 0.5) /* 呼吸脉冲：原 3s 线性改为 0.5s 进退，L2 层级 */.delay(Double(index % 7) * 0.1), value: falling)
            }
        }.allowsHitTesting(false).onAppear { falling = true }
    }
}


struct BodyAssessmentCard: View {
    let profile: MemberProfile
    var readable = false
    var body: some View {
        VStack(alignment: .leading, spacing: BojiLayout.inline) {
            if let bmi = BodyProfileAssessment.bmi(profile) {
                HStack { Text("BMI \(bmi.formatted(.number.precision(.fractionLength(1))))").bojiFont(.setNumber, monospacedDigits: true); Spacer(); Text(BodyProfileAssessment.category(profile)).bojiType(.secondary) }
                Text("按当前填写值计算 · 中国成人 BMI 参考范围 18.5–23.9")
                    .font(readable ? .subheadline : .caption).foregroundStyle(.secondary)
            }
            Text(BodyProfileAssessment.explanation(profile))
                .font(readable ? .body : .footnote)
                .foregroundStyle(readable ? FlowPalette.ink : FlowPalette.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
        }.padding(BojiLayout.cardInset).background(.black.opacity(0.035), in: RoundedRectangle(cornerRadius: BojiRadius.inner))
    }
}
struct ActivityProfileFields: View {
    @Binding var profile: MemberProfile
    private func activityDetail(_ value: String) -> String {
        switch value {
        case "主要久坐": return "办公、学习为主，训练之外走动较少"
        case "经常站立走动": return "平时经常走路、站立或做家务"
        default: return "工作或生活中经常搬动、劳动"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: BojiLayout.inline) {
            Text("训练之外，平时活动多吗？").bojiType(.secondary)
            ForEach(BodyProfileAssessment.activityOptions, id: \.self) { value in
                ClubOptionRow(title: value, detail: activityDetail(value), selected: (profile.dailyActivity ?? "主要久坐") == value) { profile.dailyActivity = value }
            }
            Text("帮助估计你一天大致消耗多少；之后可随时修改。").bojiType(.label).foregroundStyle(.secondary)
            DisclosureGroup("特殊饮食情况 · 如适用请补充") {
                Picker("饮食评估方式", selection: Binding(get: { profile.nutritionContext ?? "普通成人" }, set: { profile.nutritionContext = $0 })) {
                    ForEach(BodyProfileAssessment.contextOptions, id: \.self) { Text($0).tag($0) }
                }.pickerStyle(.menu)
                Text("选填信息随账号资料保存，用于选择适用的饮食评估方式；可在资料页修改。").bojiType(.caption).foregroundStyle(.secondary)
            }.bojiType(.label)
        }
    }
}

#if DEBUG
@MainActor enum OnboardingAuditFactory {
 static func welcome(account: ClubAccount?) -> some View { MemberCardCelebration(account: account, nickname: "BOJI MEMBER", enter: {}) }
 static func page(step: Int) -> some View { OnboardingView.auditPage(step: step) }
 static func login() -> some View { ServerTestLoginView() }
}
#endif

#if DEBUG
extension OnboardingView {
 static func auditPage(step: Int) -> Self {
  var page = Self()
  page._step = State(initialValue: step)
  page._loaded = State(initialValue: true)
  page._draftOwner = State(initialValue: AccountService.previewUserID)
  return page
 }
}
#endif
