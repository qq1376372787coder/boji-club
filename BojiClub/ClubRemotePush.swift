import SwiftUI
import UserNotifications
import UIKit

// The default build never calls APNs registration without a signed entitlement.
// scripts/enable-remote-push.py opts in after Apple capabilities are configured.
#if BOJI_REMOTE_PUSH
@MainActor final class ClubPushDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
        ClubPushService.shared.receive(token)
    }
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        ClubPushService.shared.registrationFailed()
    }
}
@MainActor final class ClubPushService: ObservableObject {
    static let shared = ClubPushService()
    @Published private(set) var token: String?
    private(set) var ready = false
    private var owner: Int?
    private var digest: Data?
    private var busy = false
    private var requested = false
    private var deviceID: String {
        if let saved = UserDefaults.standard.string(forKey: "club.push.installation"), UUID(uuidString: saved) != nil { return saved }
        let value = UUID().uuidString.lowercased(); UserDefaults.standard.set(value, forKey: "club.push.installation"); return value
    }
    func activate(_ id: Int?) { if owner != id { owner = id; digest = nil; ready = false; busy = false } }
    func receive(_ value: Data) { token = value.map { String(format: "%02x", $0) }.joined(); requested = true }
    func registrationFailed() { requested = false; ready = false }
    func sync(account: AccountService, ai: AIService, notifications: AppNotificationService, settings: ClubAutomationSettings) async {
        guard let owner, owner == account.user?.id, !account.isPreviewAccount, !busy,
              case .ready = account.phase else { return }
        let submittedToken = token
        let authorized = [.authorized, .provisional, .ephemeral].contains(notifications.authorizationStatus)
        if authorized && !requested { requested = true; UIApplication.shared.registerForRemoteNotifications() }
        let enabled = authorized && ai.routingConsentGranted && (notifications.dailyReportEnabled || notifications.weeklyReviewEnabled)
        if enabled && token == nil { return }
        struct Preferences: Encodable { let enabled: Bool; let daily: Bool; let weekly: Bool; let quiet: Bool; let quiet_start: Int; let quiet_end: Int; let zone: String }
        struct Registration: Encodable { let device_id: String; let token: String; let environment: String; let preferences: Preferences }
        let pushEnvironment = (Bundle.main.object(forInfoDictionaryKey: "BojiAPNSEnvironment") as? String) ?? "production"
        let value = Registration(device_id: deviceID, token: token ?? "", environment: pushEnvironment,
            preferences: Preferences(enabled: enabled, daily: notifications.dailyReportEnabled, weekly: notifications.weeklyReviewEnabled,
                quiet: settings.quietEnabled, quiet_start: settings.quietStart, quiet_end: settings.quietEnd, zone: TimeZone.current.identifier))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value), data != digest else { return }
        busy = true
        defer { if self.owner == owner { busy = false } }
        do {
            let response = try await account.cloudRequest(path: "/me/push-device", method: "PUT", body: data, expectedUserID: owner)
            guard self.owner == owner else { return }
            guard response.statusCode == 200 else { ready = false; return }
            struct Receipt: Decodable { let push_ready: Bool }
            let receipt = try JSONDecoder().decode(Receipt.self, from: response.data)
            ready = enabled && receipt.push_ready
            // If the server key is not configured, continue local reminders and
            // retry readiness next time; never silently suppress both channels.
            digest = receipt.push_ready || !enabled ? data : nil
            let latest = (try? ClubAutomationSettings.load(owner: owner)) ?? settings
            let stillAuthorized = [.authorized, .provisional, .ephemeral].contains(notifications.authorizationStatus)
            if latest != settings || submittedToken != token || authorized != stillAuthorized ||
                enabled != (stillAuthorized && ai.routingConsentGranted && (notifications.dailyReportEnabled || notifications.weeklyReviewEnabled)) ||
                value.preferences.daily != notifications.dailyReportEnabled || value.preferences.weekly != notifications.weeklyReviewEnabled {
                busy = false
                await sync(account: account, ai: ai, notifications: notifications, settings: latest)
            }
        } catch { if self.owner == owner { ready = false } }
    }
}
#else
@MainActor final class ClubPushDelegate: NSObject, UIApplicationDelegate { }
@MainActor final class ClubPushService: ObservableObject {
    static let shared = ClubPushService()
    @Published private(set) var token: String?
    let ready = false
    func activate(_ id: Int?) { }
    func sync(account: AccountService, ai: AIService, notifications: AppNotificationService, settings: ClubAutomationSettings) async { }
}
#endif
