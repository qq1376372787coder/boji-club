import SwiftUI
import Combine
import UserNotifications
import CryptoKit

@MainActor
final class ClubAutomationService: ObservableObject {
    @Published private(set) var settings = ClubAutomationSettings()
    @Published private(set) var status = "自动分析尚未开启"
    @Published private(set) var error: String?
    @Published private(set) var serverStatus = "服务器跟进尚未连接"
    @Published private(set) var serverConflict = false
    private var lastServerProbe = Date.distantPast
    private var serverVersion: Int?
    private var serverDigest: String?
    private var serverBusy = false
    private var owner: Int?
    private var readable = true

    func activate(_ id: Int?) {
        guard owner != id else { return }
        owner = id; serverConflict = false; settings = ClubAutomationSettings(); error = nil; readable = true; lastServerProbe = .distantPast; serverVersion = nil; serverDigest = nil; serverBusy = false; serverStatus = "等待核对服务器设置"
        guard let id else { status = "请先登录"; return }
        do { settings = try ClubAutomationSettings.load(owner: id); status = settings.anyAutomatic ? "等待检查记录" : "自动分析尚未开启" }
        catch { readable = false; self.error = AppErrorText.message(error); status = "设置待核对，自动提交已暂停" }
    }
    func update(_ value: ClubAutomationSettings, expectedOwner: Int) {
        guard expectedOwner == owner else { return }
        var value = value
        let serverChanged = value.automaticDaily != settings.automaticDaily || value.weeklyEnabled != settings.weeklyEnabled || value.workoutEnabled != settings.workoutEnabled || value.serverEnabled != settings.serverEnabled || value.includePartial != settings.includePartial || value.dailyHour != settings.dailyHour
        if serverChanged { serverVersion = nil; serverDigest = nil; value.serverZone = nil }
        if value.anyAutomatic && (!settings.anyAutomatic || value.enabledFrom == nil || value.enabledAt == nil) { value.enabledFrom = ClubDates.key(Date()); value.enabledAt = Date() }
        do {
            try value.save(owner: expectedOwner); settings = value; readable = true; error = nil
            status = value.anyAutomatic ? (value.serverEnabled ? "设置已保存，记录同步后由服务器跟进" : "设置已保存，将在使用 App 时检查") : "自动分析已关闭，已提交任务和报告保留"
            // Re-evaluate deferred reminders instead of silently deleting them.
            Task {
                guard owner == expectedOwner else { return }
                await AppNotificationService.refreshPendingAnalysis(accountID: expectedOwner)
            }
        } catch { self.error = AppErrorText.message(error) }
    }
    func syncServer(account: AccountService, ai: AIService, store: AppStore) async {
        guard let owner, owner == account.user?.id, !account.isPreviewAccount, readable, !serverBusy else { return }
        guard settings.serverAutomation != nil || !ai.routingConsentGranted else { serverStatus = "尚未在本设备设置服务器跟进"; return }
        // Explicit privacy revocation remains possible during a setting conflict.
        guard !serverConflict || !ai.routingConsentGranted || !settings.serverEnabled || !settings.anyAutomatic else { return }
        let submittedSettings = settings; let submittedConsent = ai.routingConsentGranted
        struct Preferences: Encodable {
            let version = 1
            let enabled: Bool
            let daily: Bool
            let weekly: Bool
            let workout: Bool
            let partial: Bool
            let hour: Int
            let zone: String
            let enabled_at: Double
            let cloud_revision: Int
            let coverage: [String: Bool]
        }
        let value = Preferences(enabled: settings.serverEnabled && settings.anyAutomatic && ai.routingConsentGranted,
            daily: settings.automaticDaily, weekly: settings.weeklyEnabled, workout: settings.workoutEnabled,
            partial: settings.includePartial, hour: settings.dailyHour, zone: settings.serverZone ?? TimeZone.current.identifier,
            enabled_at: settings.enabledAt?.timeIntervalSince1970 ?? 0,
            cloud_revision: store.automationRevision,
            coverage: Dictionary(uniqueKeysWithValues: (0..<14).compactMap { offset -> (String, Bool)? in
                guard let date = ClubDates.calendar.date(byAdding: .day, value: -offset, to: Date()) else { return nil }
                return (ClubDates.key(date), store.log(for: date).mealsComplete)
            }))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value), let digest = String(data: data, encoding: .utf8) else { return }
        if digest == serverDigest { await refreshServerStatus(account: account, expectedOwner: owner); return }
        // An untouched device must not disable another device's account-wide opt-in.
        guard settings.serverAutomation != nil || !ai.routingConsentGranted else { serverStatus = "尚未在本设备设置服务器跟进"; return }
        serverBusy = true
        defer { if self.owner == owner { serverBusy = false } }
        do {
            if value.enabled { guard case .synced = store.syncStatus else { serverStatus = "等待记录同步后保存跟进设置"; return } }
            struct Version: Decodable { let revision: Int }
            if serverVersion == nil {
                let existing = try await account.cloudRequest(path: "/me/automation", expectedUserID: owner)
                guard self.owner == owner else { return }
                guard existing.statusCode == 200 else { throw AIClientError.message("暂时无法读取服务器跟进设置。") }
                serverVersion = try JSONDecoder().decode(Version.self, from: existing.data).revision
            }
            guard self.owner == owner else { return }
            var object = try JSONDecoder().decode([String: JSONValue].self, from: data)
            object["expected_revision"] = .number(Double(serverVersion ?? 0))
            let response = try await account.cloudRequest(path: "/me/automation", method: "PUT", body: JSONEncoder().encode(object), expectedUserID: owner)
            guard self.owner == owner, account.user?.id == owner else { return }
            if response.statusCode == 409 {
                let detail = try? JSONDecoder().decode([String: JSONValue].self, from: response.data)
                if detail?["code"]?.string == "record_conflict" {
                    serverDigest = nil; serverStatus = "记录已更新，同步完成后继续保存跟进设置。"; return
                }
                // Do not repeatedly send the stale revision, or silently adopt
                // another device's changes as permission to overwrite them.
                serverVersion = nil; serverDigest = nil; serverConflict = true
                serverStatus = "账号或记录已有新版本。同步后选择读取账号设置，或明确保存本机选择。"
                return
            }
            guard response.statusCode == 200 else {
                let body = try? JSONDecoder().decode([String: JSONValue].self, from: response.data)
                let message = body?["error"]?.string
                throw AIClientError.message(message ?? "服务器跟进设置未保存，请联网重试。")
            }
            serverVersion = try JSONDecoder().decode(Version.self, from: response.data).revision
            serverConflict = false; serverDigest = digest; serverStatus = value.enabled ? "服务器跟进已启用，持续检查已同步记录" : "服务器跟进已关闭，已有报告保留"
            if submittedSettings != settings || submittedConsent != ai.routingConsentGranted {
                serverBusy = false
                await syncServer(account: account, ai: ai, store: store)
            }
        } catch { if self.owner == owner { serverStatus = AppErrorText.message(error) } }
    }
    func resolveServerConflict(useAccount: Bool, account: AccountService, ai: AIService, store: AppStore) async {
        guard let owner, owner == account.user?.id, !serverBusy else { return }
        if !useAccount {
            serverConflict = false; serverVersion = nil; serverDigest = nil
            await store.syncNow()
            guard self.owner == owner else { return }
            await syncServer(account: account, ai: ai, store: store)
            return
        }
        struct Preferences: Decodable {
            let enabled: Bool; let daily: Bool; let weekly: Bool; let workout: Bool
            let partial: Bool; let hour: Int; let zone: String; let enabled_at: Double
        }
        struct Receipt: Decodable { let revision: Int; let preferences: Preferences? }
        serverBusy = true
        defer { if self.owner == owner { serverBusy = false } }
        do {
            let response = try await account.cloudRequest(path: "/me/automation", expectedUserID: owner)
            guard self.owner == owner else { return }
            guard response.statusCode == 200 else { throw AIClientError.message("暂时无法读取账号设置，请联网重试。") }
            let receipt = try JSONDecoder().decode(Receipt.self, from: response.data)
            guard let value = receipt.preferences else { throw AIClientError.message("账号暂无已保存的跟进设置，可使用本机选择。") }
            var copy = settings
            copy.automaticDaily = value.daily; copy.weeklyEnabled = value.weekly; copy.workoutEnabled = value.workout
            copy.serverEnabled = value.enabled; copy.includePartial = value.partial; copy.dailyHour = value.hour; copy.serverZone = value.zone
            copy.enabledAt = value.enabled_at > 0 ? Date(timeIntervalSince1970: value.enabled_at) : nil
            copy.enabledFrom = copy.enabledAt.map(ClubDates.key)
            try copy.save(owner: owner)
            settings = copy; serverVersion = receipt.revision; serverDigest = nil; serverConflict = false; error = nil
            serverStatus = "已读取账号最新设置；本机免打扰设置保留。"
        } catch { if self.owner == owner { serverStatus = AppErrorText.message(error) } }
    }
    private func refreshServerStatus(account: AccountService, expectedOwner: Int) async {
        guard owner == expectedOwner, !serverBusy, Date().timeIntervalSince(lastServerProbe) >= 30 else { return }
        lastServerProbe = Date(); serverBusy = true
        defer { if owner == expectedOwner { serverBusy = false } }
        do {
            struct Receipt: Decodable { let enabled: Bool; let status: String? }
            let response = try await account.cloudRequest(path: "/me/automation", expectedUserID: expectedOwner)
            guard owner == expectedOwner, response.statusCode == 200 else { return }
            let value = try JSONDecoder().decode(Receipt.self, from: response.data)
            if !value.enabled { serverStatus = "账号的服务器跟进已关闭；已有报告保留"; return }
            switch value.status {
            case "membership_required": serverStatus = "会员状态就绪后继续自动跟进"
            case "retry_pending": serverStatus = "自动跟进暂未提交，稍后会重试；原记录保留"
            case "needs_record_check": serverStatus = "有部分记录暂无法分析，请进入对应日期核对；原记录保留"
            case "submitted": serverStatus = "已提交自动分析，可以在报告中查看进度"
            default: serverStatus = "服务器已检查，等待合适时刻与足够记录"
            }
        } catch { if owner == expectedOwner { serverStatus = "暂时无法核对服务器状态，设置与记录仍保留" } }
    }
    private func evaluateCoach(store: AppStore, ai: AIService, now: Date) {
        guard let owner, let first = settings.enabledFrom else { return }
        if settings.workoutEnabled {
            for key in ClubAutomationRules.recentWorkoutDates(now: now).map(ClubDates.key) where key >= first {
                guard let date = ClubDates.date(fromKey: key) else { continue }
                let sessionIDs: [UUID] = ClubWorkoutSummaryRules.available(state: store.state, date: date, now: now)
                for sessionID in sessionIDs {
                    guard let session = store.state.days[key]?.workoutSessions?.first(where: { $0.id == sessionID }),
                          let saved = session.savedAt, saved >= (settings.enabledAt ?? now), saved <= now else { continue }
                    let id = ClubAutomaticReports.jobID(owner: owner, mode: "workout", key: session.id.uuidString.lowercased())
                    guard ai.job(id) == nil else { continue }
                    do {
                        var input = try ai.coachInput(question: "请锐评本次已确认训练：先核对完成情况与开始目标，明确哪些比较有依据，最后给下一次一个可执行建议。不能编造动作技术或恢复情况。", conversation: id, history: [], through: date, contextDays: 7, store: store, sessionID: session.id)
                        input.payload["purpose"] = JSONValue.string("workout")
                        input.payload["source_session"] = JSONValue.string(sessionID.uuidString.lowercased())
                        _ = try ai.submit(input, submissionID: id)
                    } catch { self.error = AppErrorText.message(error) }
                    return
                }
            }
        }
        if settings.weeklyEnabled {
            let today = ClubDates.calendar.startOfDay(for: now)
            let weekday = (ClubDates.calendar.component(.weekday, from: today) + 5) % 7
            guard let end = ClubDates.calendar.date(byAdding: .day, value: -weekday-1, to: today),
                  let start = ClubDates.calendar.date(byAdding: .day, value: -6, to: end), ClubDates.key(start) >= first else { return }
            let days = (0..<7).compactMap { ClubDates.calendar.date(byAdding: .day, value: $0, to: start) }.map { store.log(for: $0) }
            guard days.filter({ $0.hasConfirmedTraining && $0.confirmedCompletedSets > 0 }).count >= 2 || days.filter(\.mealsComplete).count >= 3 else { return }
            let id = ClubAutomaticReports.jobID(owner: owner, mode: "weekly", key: ClubDates.key(end))
            guard ai.job(id) == nil else { return }
            do {
                var input = try ai.coachInput(question: "生成截至请求日期这七天的记录成长报告：训练执行、饮食覆盖、身体测量趋势、最值得肯定与最需要改正的行为、下一周一件事。此前额外七天仅作为上一周对照，缺少可比数据时说明，不合并成两周评价。专业直白、有适度幽默；不代填感受，不把缺记录当未完成。", conversation: id, history: [], through: end, contextDays: 14, store: store)
                input.payload["purpose"] = .string("weekly")
                input.payload["review_scope"] = try JSONValue.encode(ClubReviewScope(kind: .completedCalendarWeek, from: ClubDates.key(start), to: ClubDates.key(end), timeZone: ClubDates.calendar.timeZone.identifier))
                _ = try ai.submit(input, submissionID: id)
            } catch { self.error = AppErrorText.message(error) }
        }
    }
    func evaluate(store: AppStore, ai: AIService, account: AccountService, membership: MembershipService, now: Date = Date()) {
        guard let owner, owner == store.editingAccountID, owner == account.user?.id else { return }
        guard readable else { return }
        guard settings.anyAutomatic else { status = "自动分析尚未开启"; return }
        guard case .ready = account.phase, membership.hasMemberAccess, !account.isPreviewAccount else { status = "会员与账号就绪后再检查"; return }
        guard ai.routingConsentGranted else { status = "云端分析已关闭，未提交自动分析"; return }
        guard store.canAnalyzeRecords, ai.canSyncJobs else { status = "本机记录需要恢复，未提交自动分析"; return }
        // Do not analyze a stale local snapshot while another device is uploading.
        guard case .synced = store.syncStatus else { status = "联网同步完成后检查，不会丢失记录"; return }
        if settings.serverEnabled { status = "服务器按已同步记录检查，未同步的手机记录不会凭空纳入"; return }
        evaluateCoach(store: store, ai: ai, now: now)
        guard settings.automaticDaily else { return }
        let dates = ClubAutomationRules.candidates(settings: settings, now: now)
        guard !dates.isEmpty else { status = "到 \(settings.dailyHour):00 后，在使用 App 时检查；未打开时下次补查"; return }
        for key in dates.reversed() {
            guard let date = ClubDates.date(fromKey: key), let id = ClubAutomationRules.jobID(owner: owner, date: key) else { continue }
            let reports = ai.jobs.filter { $0.request.kind == "report" && $0.request.date == key && $0.replacementID == nil && !["deleted", "discarded", "expired", "rejected"].contains($0.status) }
            guard !reports.contains(where: { !$0.isTerminal }) else { status = "\(key) 已有分析进行中，不重复提交"; continue }
            let day = store.log(for: date)
            guard ClubAutomationRules.eligible(day, partialAllowed: settings.includePartial) else {
                status = "\(key) 记录不足或训练尚未确认，暂不自动分析"; continue
            }
            do {
                var input = try ai.reportInput(date: date, log: day, nutritionTarget: store.reportNutritionTarget(on: date),
                    weightHistory: store.bodyWeightPoints(through: date), goalContext: ClubAIContext.make(state: store.state, start: date, end: date))
                let revision = ClubReviewRevision.fingerprint(input.payload)
                guard !reports.contains(where: { ($0.request.payload["_automatic_source_hash"]?.string ?? ClubReviewRevision.fingerprint($0.request.payload)) == revision }) else {
                    status = "\(key) 记录版本已有分析；失败任务请手动恢复"; continue
                }
                input.payload["_automatic_source_hash"] = .string(revision)
                let identity = reports.isEmpty ? id : ClubAutomaticReports.jobID(owner: owner, mode: "daily_revision", key: key + "/" + revision)
                guard ai.job(identity) == nil else { continue }
                _ = try ai.submit(input, submissionID: identity)
                status = "\(key) 已提交自动分析，可以继续使用 App"; error = nil
            } catch { self.error = AppErrorText.message(error); status = "自动分析未提交，原记录保留" }
            return
        }
    }
}

struct ClubAutomationSettingsSection: View {
    let ownerID: Int?
    @EnvironmentObject private var account: AccountService
    @EnvironmentObject private var ai: AIService
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var automation: ClubAutomationService
    @EnvironmentObject private var notifications: AppNotificationService
    private var modeBinding: Binding<String?> {
        Binding(get: {
            automation.settings.modeLabel?.rawValue ?? "custom"
        }, set: { newValue in
            guard let ownerID, let raw = newValue, raw != "custom", let mode = ClubProactiveMode(rawValue: raw) else { return }
            automation.update(ClubAutomationSettings.applying(mode, to: automation.settings), expectedOwner: ownerID)
        })
    }
    private func binding<T>(_ path: WritableKeyPath<ClubAutomationSettings, T>) -> Binding<T> {
        Binding(get: { automation.settings[keyPath: path] }, set: { value in
            guard let ownerID else { return }
            var copy = automation.settings; copy[keyPath: path] = value
            automation.update(copy, expectedOwner: ownerID)
        })
    }
    var body: some View {
        ClubCard {
            Text("AI 自动跟进").font(.headline)
            Picker("跟进程度", selection: modeBinding) {
                ForEach(ClubProactiveMode.allCases, id: \.self) { Text($0.label).tag(Optional($0.rawValue)) }
                if automation.settings.modeLabel == nil { Text("自定义").tag(Optional("custom")) }
            }.clubAdaptivePicker().accessibilityIdentifier("proactive-mode-picker")
            Text(modeDescription130).font(.subheadline).foregroundStyle(.secondary)
            DisclosureGroup("自定义") {
                Toggle("每日总结", isOn: binding(\.automaticDaily))
                Toggle("训练后总结", isOn: binding(\.workoutEnabled))
                Toggle("每周总结", isOn: binding(\.weeklyEnabled))
                Toggle("离开 App 后继续分析", isOn: binding(\.serverEnabled))
                if automation.settings.automaticDaily {
                    Picker("每日时间", selection: binding(\.dailyHour)) { ForEach(0..<24) { Text(String(format: "%02d:00", $0)).tag($0) } }
                    Toggle("也分析未记全的日期", isOn: binding(\.includePartial))
                }
                Text(automation.serverStatus).font(.caption).foregroundStyle(.secondary)
                if automation.serverConflict {
                    Button("使用账号最新设置") { Task { await automation.resolveServerConflict(useAccount: true, account: account, ai: ai, store: store) } }
                    Button("保留我的选择") { Task { await automation.resolveServerConflict(useAccount: false, account: account, ai: ai, store: store) } }
                }
            }
            if let error = automation.error { FlowError(message: error) }
        }
        ClubCard {
            DisclosureGroup("通知时间") {
                Toggle("每日总结完成提醒", isOn: $notifications.dailyReportEnabled)
                Toggle("每周总结完成提醒", isOn: $notifications.weeklyReviewEnabled)
                Toggle("免打扰", isOn: binding(\.quietEnabled))
                if automation.settings.quietEnabled {
                    Picker("开始", selection: binding(\.quietStart)) { ForEach((0..<24).filter { $0 != automation.settings.quietEnd }, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) } }
                    Picker("结束", selection: binding(\.quietEnd)) { ForEach((0..<24).filter { $0 != automation.settings.quietStart }, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) } }
                }
                if notifications.authorizationStatus == .notDetermined { Button("允许手机通知") { Task { await notifications.requestAuthorization() } } }
                else if notifications.authorizationStatus == .denied { Text("可到 iPhone 设置中开启通知。").font(.caption) }
            }
            DisclosureGroup("了解运行规则") {
                Text("手动提问不受档位影响。自动总结只分析已同步的记录，关闭云端分析会暂停。手机通知遵循权限和免打扰；训练提醒单独设置。").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var modeDescription130: String {
        switch automation.settings.modeLabel {
        case .quiet: return "暂停主动分析，随时可以手动问 AI。"
        case .balanced: return "生成每日与每周总结。"
        case .active: return "再加上训练后总结，也分析部分记录。"
        case nil: return "按你选择的功能跟进。"
        }
    }
}

enum ClubReviewRevision {
    static func fingerprint(_ payload: [String: JSONValue]) -> String {
        let fields = payload.filter { !$0.key.hasPrefix("_") && !["conversation_id", "history", "question"].contains($0.key) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(fields)) ?? Data()
        return SHA256.hash(data: data).prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
