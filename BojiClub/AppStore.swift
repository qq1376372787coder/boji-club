import Foundation
import Combine
import Network
import CryptoKit
import UserNotifications
import WidgetKit
import ImageIO


struct ClubNotificationRoute: Identifiable {
    let id = UUID()
    let kind: String
    let date: String
    let accountID: Int
    var jobID: String? = nil
}

/// A5：三餐登记提醒设置。默认全关；文案「尚未看到记录」，不认定用户没吃。
struct MealReminderSettings: Codable, Equatable {
    struct Slot: Codable, Equatable {
        var category: String
        var enabled: Bool = false
        var hour: Int = 8
        var minute: Int = 0
    }
    var breakfast = Slot(category: "早餐", hour: 8)
    var lunch = Slot(category: "午餐", hour: 12)
    var dinner = Slot(category: "晚餐", hour: 18)
    var slots: [Slot] { [breakfast, lunch, dinner] }
    var anyEnabled: Bool { slots.contains { $0.enabled } }
}


@MainActor
final class AppNotificationService: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published var route: ClubNotificationRoute?
    private var accountID: Int?
    private static var activeAnalysisOwner: Int?
    private var pendingRoute: ClubNotificationRoute?
    private var restRequestID: String?
    private var restGeneration = UUID()
    func cancelRestReminder() {
        restGeneration = UUID()
        if let id = restRequestID { center.removePendingNotificationRequests(withIdentifiers: [id]) }
        restRequestID = nil
    }
    func scheduleRestReminder(until end: Date, on date: Date) {
        cancelRestReminder()
        guard let owner = accountID, end > Date() else { return }
        let ticket = restGeneration
        let identifier = "boji.rest.\(owner).\(ticket.uuidString)"
        restRequestID = identifier
        Task {
            let settings = await center.notificationSettings()
            guard restGeneration == ticket, accountID == owner,
                  [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus), end > Date() else { return }
            let content = UNMutableNotificationContent()
            content.title = "组间休息结束"
            content.body = "按身体状态继续下一组，准备好了再开始。"
            content.sound = .default
            content.userInfo = ["boji_kind": "training", "boji_date": ClubDates.key(date), "boji_account": owner]
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, end.timeIntervalSinceNow), repeats: false)
            try? await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
            if restGeneration != ticket || accountID != owner { center.removePendingNotificationRequests(withIdentifiers: [identifier]) }
        }
    }
    func activate(_ id: Int?) {
        if accountID != id { cancelRestReminder() }
        accountID = id
        Self.activeAnalysisOwner = id
        if let id {
            ClubAnalysisNotifications.migrateLegacy(owner: id)
            dailyReportEnabled = ClubAnalysisNotifications.enabled(kind: "report", owner: id)
            weeklyReviewEnabled = ClubAnalysisNotifications.enabled(kind: "weekly_review", owner: id)
        }
        Task {
            let pending = await center.pendingNotificationRequests()
            guard accountID == id else { return }
            center.removePendingNotificationRequests(withIdentifiers: pending.filter {
                $0.identifier.hasPrefix("boji.analysis.") && $0.content.userInfo["boji_account"] as? Int != id
            }.map(\.identifier))
        }
        if let pending = pendingRoute, let id {
            if pending.accountID == id { route = pending }
            pendingRoute = nil
        }
        if route?.accountID != id { route = nil }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let kind = info["boji_kind"] as? String
        let providedDate = info["boji_date"] as? String
        let owner = info["boji_account"] as? Int
        let jobID = info["boji_job"] as? String
        completionHandler()
        guard let kind, let owner, let date = ClubNotificationRouting.dateKey(kind: kind, provided: providedDate) else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let target = ClubNotificationRoute(kind: kind, date: date, accountID: owner, jobID: jobID)
            if self.accountID == owner { self.route = target }
            else if self.accountID == nil { self.pendingRoute = target }
        }
    }
    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    @Published var trainingRemindersEnabled: Bool {
        didSet { UserDefaults.standard.set(trainingRemindersEnabled, forKey: "notifications.training") }
    }
    // A4：训练提醒时间用户可设（默认 19:30，沿用历史行为）；时区变化由签名重算。
    @Published var trainingReminderHour: Int {
        didSet { UserDefaults.standard.set(trainingReminderHour, forKey: "notifications.training.hour"); timeRevision &+= 1 }
    }
    @Published var trainingReminderMinute: Int {
        didSet { UserDefaults.standard.set(trainingReminderMinute, forKey: "notifications.training.minute"); timeRevision &+= 1 }
    }
    /// 通知设置变更的统一修订号；BojiClubApp 监听它触发重新排程。
    @Published private(set) var timeRevision = 0
    // A5：早/午/晚三餐登记提醒，分别设置；文案只说「尚未看到记录」。
    @Published var mealReminders: MealReminderSettings {
        didSet {
            if let data = try? JSONEncoder().encode(mealReminders) {
                UserDefaults.standard.set(data, forKey: "notifications.meal.reminders")
            }
            timeRevision &+= 1
        }
    }
    @Published var dailyReportEnabled: Bool {
        didSet {
            if let accountID {
                UserDefaults.standard.set(dailyReportEnabled, forKey: ClubAnalysisNotifications.key(kind: "report", owner: accountID))
                Task { await Self.refreshPendingAnalysis(accountID: accountID) }
            }
        }
    }
    @Published var weeklyReviewEnabled: Bool {
        didSet {
            if let accountID {
                UserDefaults.standard.set(weeklyReviewEnabled, forKey: ClubAnalysisNotifications.key(kind: "weekly_review", owner: accountID))
                Task { await Self.refreshPendingAnalysis(accountID: accountID) }
            }
        }
    }

    private let center = UNUserNotificationCenter.current()

    override init() {
        let defaults = UserDefaults.standard
        trainingRemindersEnabled = (defaults.object(forKey: "notifications.training") as? Bool) ?? false
        trainingReminderHour = (defaults.object(forKey: "notifications.training.hour") as? Int) ?? 19
        trainingReminderMinute = (defaults.object(forKey: "notifications.training.minute") as? Int) ?? 30
        mealReminders = (defaults.data(forKey: "notifications.meal.reminders").flatMap { try? JSONDecoder().decode(MealReminderSettings.self, from: $0) }) ?? MealReminderSettings()
        dailyReportEnabled = (defaults.object(forKey: "notifications.daily_report") as? Bool) ?? true
        weeklyReviewEnabled = (defaults.object(forKey: "notifications.weekly_review") as? Bool) ?? true
        super.init()
        center.delegate = self
        Task { await refreshAuthorizationStatus() }
    }

    func refreshAuthorizationStatus() async {
        let settings = await center.notificationSettings()
        authorizationStatus = settings.authorizationStatus
    }

    func requestAuthorization() async {
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        await refreshAuthorizationStatus()
    }

    private var reminderGeneration = UUID()
    private var lastTrainingSignature: String?
    func syncTrainingReminders(profile: MemberProfile?, plannedDays: [String: DayLog] = [:]) {
        let legacyIDs = (1...7).map { "boji.training.\($0)" } + (0..<28).map { "boji.training.date.\($0)" }
        let enabled = trainingRemindersEnabled && profile != nil &&
            [.authorized, .provisional, .ephemeral].contains(authorizationStatus)
        let calendar = ClubDates.calendar; let now = Date()
        let hour = min(max(trainingReminderHour, 0), 23), minute = min(max(trainingReminderMinute, 0), 59)
        let dates = plannedDays.keys.sorted().compactMap { key -> Date? in
            guard !(plannedDays[key]?.exercises.isEmpty ?? true), plannedDays[key]?.workoutSavedAt == nil,
                  let day = ClubDates.date(fromKey: key),
                  let scheduled = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day),
                  scheduled > now, scheduled.timeIntervalSince(now) < 28 * 86400 else { return nil }
            return scheduled
        }
        let owner = accountID
        let signature = "\(owner ?? 0):\(enabled):\(hour):\(minute):\(ClubDates.key(now)):\(TimeZone.current.identifier):\(dates.map(\.timeIntervalSince1970))"
        guard signature != lastTrainingSignature else { return }
        lastTrainingSignature = signature
        reminderGeneration = UUID(); let ticket = reminderGeneration
        Task {
            let pending = await center.pendingNotificationRequests()
            guard ticket == reminderGeneration else { return }
            center.removePendingNotificationRequests(withIdentifiers: legacyIDs + pending.map(\.identifier).filter { $0.hasPrefix("boji.training.gen.") })
            guard enabled else { return }
            for (index, date) in dates.prefix(28).enumerated() {
                guard ticket == reminderGeneration else { return }
                let id = "boji.training.gen.\(ticket.uuidString).\(index)"
                let content = UNMutableNotificationContent(); content.title = "今天有训练安排"
                content.body = "打开月历查看今天的动作与组数，按身体状态安排训练。"; content.sound = .default
                if let owner { content.userInfo = ["boji_kind": "training", "boji_date": ClubDates.key(date), "boji_account": owner] }
                let components = calendar.dateComponents([.year,.month,.day,.hour,.minute], from: date)
                do { try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))) }
                catch { if ticket == reminderGeneration { lastTrainingSignature = nil } }
                if ticket != reminderGeneration { center.removePendingNotificationRequests(withIdentifiers: [id]); return }
            }
        }
    }

    // A5：三餐登记提醒。文案只说「尚未看到记录」，不认定用户没吃。
    private var lastMealSignature: String?
    private var mealReminderGeneration = UUID()
    func syncMealReminders(days: [String: DayLog]) {
        // F11：与训练提醒一致，排程绑定登录账号——退出后不为无账号状态排程。
        let enabled = mealReminders.anyEnabled && accountID != nil && [.authorized, .provisional, .ephemeral].contains(authorizationStatus)
        let calendar = ClubDates.calendar; let now = Date()
        var planned: [(String, Date)] = [] // (category, fireDate)
        if enabled {
            for dayOffset in 0..<7 {
                guard let day = calendar.date(byAdding: .day, value: dayOffset, to: calendar.startOfDay(for: now)) else { continue }
                let key = ClubDates.key(day)
                for slot in mealReminders.slots where slot.enabled {
                    guard let fire = calendar.date(bySettingHour: slot.hour, minute: slot.minute, second: 0, of: day),
                          fire > now, fire.timeIntervalSince(now) < 7 * 86400 else { continue }
                    // 已有该餐记录的日期不再提醒（记录在，提醒无意义）。
                    let recorded = (days[key]?.meals ?? []).contains { $0.category == slot.category }
                    if !recorded { planned.append((slot.category, fire)) }
                }
            }
        }
        let owner = accountID
        let signature = "\(owner ?? 0):\(enabled):\(TimeZone.current.identifier):\(planned.map { $0.0 + "@" + String($0.1.timeIntervalSince1970) }.joined(separator: ","))"
        guard signature != lastMealSignature else { return }
        lastMealSignature = signature
        mealReminderGeneration = UUID(); let ticket = mealReminderGeneration
        Task {
            let pending = await center.pendingNotificationRequests()
            guard ticket == mealReminderGeneration else { return }
            center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix("boji.meal.gen.") })
            guard enabled else { return }
            for (index, entry) in planned.prefix(21).enumerated() {
                guard ticket == mealReminderGeneration else { return }
                let id = "boji.meal.gen.\(ticket.uuidString).\(index)"
                let content = UNMutableNotificationContent()
                content.title = "\(entry.0)登记提醒"
                content.body = "尚未看到你今天的\(entry.0)记录，需要现在补充登记吗？"
                content.sound = .default
                if let owner { content.userInfo = ["boji_kind": "meal", "boji_date": ClubDates.key(entry.1), "boji_account": owner] }
                let components = calendar.dateComponents([.year,.month,.day,.hour,.minute], from: entry.1)
                do { try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))) }
                catch { if ticket == mealReminderGeneration { lastMealSignature = nil } }
                if ticket != mealReminderGeneration { center.removePendingNotificationRequests(withIdentifiers: [id]); return }
            }
        }
    }

    private static func deliverAnalysis(title: String, body: String, kind: String, date: Date, accountID: Int?, jobID: String? = nil) {
        guard let accountID, activeAnalysisOwner == accountID else { return }
        guard ClubAnalysisNotifications.enabled(kind: kind, owner: accountID),
              let settings = try? ClubAutomationSettings.load(owner: accountID) else { return }
        let content = UNMutableNotificationContent(); content.title = title; content.body = body; content.sound = .default
        content.userInfo = ["boji_kind": kind, "boji_date": ClubDates.key(date), "boji_account": accountID]
        if let jobID { content.userInfo["boji_job"] = jobID }
        let now = Date(); let allowed = settings.nextAllowedNotification(after: now)
        let trigger: UNNotificationTrigger? = allowed > now ? UNCalendarNotificationTrigger(
            dateMatching: ClubDates.calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: allowed), repeats: false) : nil
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "boji.analysis.\(accountID).\(kind).\(ClubDates.key(date))", content: content, trigger: trigger))
    }
    static func refreshPendingAnalysis(accountID: Int) async {
        guard activeAnalysisOwner == accountID else { return }
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        guard activeAnalysisOwner == accountID else { return }
        for request in pending where request.identifier.hasPrefix("boji.analysis.\(accountID).") {
            guard let kind = request.content.userInfo["boji_kind"] as? String,
                  let settings = try? ClubAutomationSettings.load(owner: accountID),
                  ClubAnalysisNotifications.enabled(kind: kind, owner: accountID) else {
                center.removePendingNotificationRequests(withIdentifiers: [request.identifier]); continue
            }
            let now = Date(); let allowed = settings.nextAllowedNotification(after: now)
            let trigger: UNNotificationTrigger? = allowed > now ? UNCalendarNotificationTrigger(
                dateMatching: ClubDates.calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: allowed), repeats: false) : nil
            try? await center.add(UNNotificationRequest(identifier: request.identifier, content: request.content, trigger: trigger))
            if activeAnalysisOwner != accountID { center.removePendingNotificationRequests(withIdentifiers: [request.identifier]); return }
        }
    }
    static func notifyClubFollowupReady(date: Date, weekly: Bool, jobID: String, accountID: Int?) {
        deliverAnalysis(title: weekly ? "每周记录成长报告已准备好" : "本次训练解读已准备好", body: "查看已登记记录的依据与下一步建议。", kind: weekly ? "club_weekly" : "club_workout", date: date, accountID: accountID, jobID: jobID)
    }
    static func notifyDailyReportReady(date: Date, accountID: Int?) {
        deliverAnalysis(title: "\(ClubDates.label(date, format: "M月d日")) 每日分析已生成", body: "查看这一天的训练、饮食和恢复情况。", kind: "report", date: date, accountID: accountID)
    }
    func notifyDailyReportReady(date: Date) { Self.notifyDailyReportReady(date: date, accountID: accountID) }
    static func notifyWeeklyReviewReady(date: Date, accountID: Int?) {
        guard !ClubPushService.shared.ready else { return }
        deliverAnalysis(title: "截至 \(ClubDates.label(date, format: "M月d日")) 的每周成长报告已准备好", body: "回看对应日期的记录和分析。", kind: "weekly_review", date: date, accountID: accountID)
    }
    func notifyWeeklyReviewReady(date: Date) { Self.notifyWeeklyReviewReady(date: date, accountID: accountID) }

}

private struct MonthExport: Codable {
    var month: String
    var days: [String: DayLog]
    var aiJobs: [AILocalJob]
    var customExercises: [CustomExercise]? = nil
    var deletedCustomExerciseIDs: [String]? = nil
}
private struct MonthBackup: Decodable {
    var format: String
    var accountID: Int?
    var records: MonthExport
    var photos: [String: String]
}
private func validateBackupValue(_ value: JSONValue, key: String = "") throws {
    switch value {
    case .number(let number):
        let dates = ["created", "createdAt", "updatedAt", "start", "end", "workoutSavedAt", "workoutStartedAt", "workoutEndedAt", "savedAt", "startedAt", "endedAt", "placementConfirmedAt", "capturedAt", "recordedAt"]
        let valid = dates.contains(key) ? (-978307200.0...10000000000.0).contains(number) : (0.0...10000000.0).contains(number)
        guard number.isFinite, valid else { throw CloudSyncError.message("备份包含不支持的数值。") }
    case .string(let text):
        guard text.count <= 20000 else { throw CloudSyncError.message("备份中的文字过长。") }
    case .array(let values):
        guard values.count <= 20000 else { throw CloudSyncError.message("备份中的列表过长。") }
        for child in values { try validateBackupValue(child, key: key) }
    case .object(let fields):
        for (name, child) in fields {
            guard name.count <= 200 else { throw CloudSyncError.message("备份标识不正确。") }
            try validateBackupValue(child, key: name)
        }
    case .bool, .null: break
    }
}

/// Phase reports are computed off the main actor from a state snapshot. The
/// write must prove the same account and the same store generation still own the
/// store, otherwise a slow computation could append data to another account.
enum PhaseReportWriteGuard {
    static func allows(expectedOwner: Int?, currentOwner: Int?,
                       expectedGeneration: UUID?, currentGeneration: UUID) -> Bool {
        guard let expectedOwner, let expectedGeneration else { return false }
        return expectedOwner == currentOwner && expectedGeneration == currentGeneration
    }
}

@MainActor
final class AppStore: ObservableObject {
    @Published var trainingInterfacePresented = false
    @Published var clubAIInterfacePresented = false
    @Published private(set) var state = SavedState()
    @Published var message: String?
    @Published private(set) var syncStatus: CloudSyncStatus = .idle
    private var fileURL: URL
    private let directory: URL
    @Published private(set) var localRecovery: LocalRecoverySummary?
    @Published private(set) var photoSyncIssues: [PhotoSyncIssue] = []
    @Published private(set) var exportNotice: String?
    @Published private(set) var mediaCleanupNotice: String?
    private var recoveryCandidate: SavedState?
    private var recoverySequence = 0
    private var photoRetryDates: [String: Date] = [:]
    private var canSave = true
    private var activeAccountID: Int?
    var editingAccountID: Int? { activeAccountID }
    /// Opaque generation ticket for work that reads state now and writes later.
    var stateGeneration: UUID { generation }
    var canAnalyzeRecords: Bool { canSave && localRecovery == nil }
    func takeMessage(fallback: String = "操作未完成，请重试。") -> String {
        let result = message ?? fallback
        message = nil
        return result
    }
    private weak var accountService: AccountService?
    private weak var aiService: AIService?
    private var cloudBase: CloudState?
    private var freshInstall = true
    var automationRevision: Int { cloudRevision ?? 0 }
    private var cloudRevision: Int?
    private var cloudPartitionCache = CloudPartitionCache()
    private var dirty = true
    private var journalSequence = 0
    private var snapshotWriteGeneration = UUID()
    private var acknowledgedAIChange: Int?
    private var photosNeedDownload = true
    @Published private(set) var conflictNotice: String?
    @Published private(set) var planMigrationNotice: String?
    /// Phase 1：待发送的域命令（训练开始/完成、直接记录）。断网可累积，恢复后按同一 commandId 重放。
    @Published private(set) var pendingDomainCommands: [PendingDomainCommand] = []
    private var confirmedFinishSessions: Set<String> = []
    private var planMigrationNoticeOwner: Int?
    /// 本机旧草稿文件读取失败时，禁止用一份新的空白草稿覆盖它；按账号记录。
    private var planDraftRecoveryOwners: Set<Int> = []
    private var exportedMonth: (String, URL, Data)?
    @Published private(set) var photoChangeID = UUID()
    var trainingScheduleSignature: String {
        "\(activeAccountID ?? 0):" + state.days.keys.sorted().filter { $0 >= ClubDates.key(Date()) }.map { key in
            key + "/" + (state.days[key]?.exercises.map { $0.id.uuidString }.joined(separator: ",") ?? "") + "/" + String(describing: state.days[key]?.workoutSavedAt)
        }.joined(separator: ";")
    }
    /// A5：餐次提醒重排签名——记录/删除餐食后取消或恢复对应提醒。
    var mealReminderSignature: String {
        let calendar = ClubDates.calendar
        let start = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: Date())) ?? Date()
        let end = calendar.date(byAdding: .day, value: 7, to: calendar.startOfDay(for: Date())) ?? Date()
        return "\(activeAccountID ?? 0):" + state.days.keys.sorted().filter { key in
            guard let date = ClubDates.date(fromKey: key) else { return false }
            return date >= start && date <= end
        }.map { key in
            key + "/" + (state.days[key]?.meals.map { $0.category }.sorted().joined(separator: ",") ?? "")
        }.joined(separator: ";")
    }
    private var journalURL: URL { fileURL.appendingPathExtension("journal") }

    private var generation = UUID()
    private var localEditRevision = UUID()
    private var recordedGoalProfile: MemberProfile?
    private var recordedGoalNutrition: NutritionTarget?
    private var syncTask: Task<Void, Never>?
    private var mediaSyncTask: Task<Void, Never>?
    @Published private(set) var mediaSyncMessage: String?
    private var syncWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var syncInProgress = false
    private var needsAnotherSync = false
    private let networkMonitor = NWPathMonitor()
    private var mediaDirectory: URL {
        directory.appendingPathComponent("media-user-\(activeAccountID ?? 0)", isDirectory: true)
    }

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("BojiClub", isDirectory: true)
        fileURL = directory.appendingPathComponent("records-v1.json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var folder = directory; var values = URLResourceValues(); values.isExcludedFromBackup = true; try folder.setResourceValues(values)
            try loadCurrentFile()
        } catch { canSave = false; message = "本地记录读取失败，原文件已保留。\n\(AppErrorText.message(error))" }
        networkMonitor.pathUpdateHandler = { [weak self] path in
            if path.status == .satisfied {
                Task { @MainActor [weak self] in self?.scheduleSync(after: 0.5) }
            }
        }
        networkMonitor.start(queue: DispatchQueue(label: "com.bojiclub.sync.network"))
    }

    func activateAccount(_ id: Int, profile: MemberProfile? = nil) {
        guard activeAccountID != id else { return }
        resetSync()
        activeAccountID = id
        fileURL = directory.appendingPathComponent("records-user-\(id)-v1.json")
        state = SavedState(); canSave = true; freshInstall = true
        do { try loadCurrentFile() }
        catch {
            canSave = false; freshInstall = false
            if localRecovery == nil { localRecovery = LocalRecoverySummary(readableEntries: 0, unreadableEntries: 1, snapshotReadable: false, detail: "本机文件暂时无法读取，可能是文件损坏或设备尚未解锁。原文件已保留，请解锁后重试或导出原文件。") }
            message = "这个账号的本地记录读取失败，原文件已保留。"
        }
        if freshInstall, let profile { state.profile = profile }
        ensureNutritionTarget()
        loadDomainCommands()
        #if DEBUG
        if ProcessInfo.processInfo.environment["BOJI_UI_TEST_SEED"] == "1" { seedUITestState() }
        #endif
        do { try prepareMediaDirectory(); if canSave { cleanupUnreferencedMealPhotos() } } catch { message = "本机照片保护升级未完成，请解锁设备后重试。" }
        publishWidgetSnapshot()
    }

    #if DEBUG
    /// UI 测试专用固定数据；只在 DEBUG 且显式启动参数下运行，不影响真实账号。
    private func seedUITestState() {
        let calendar = ClubDates.calendar
        let now = Date()
        let today = calendar.startOfDay(for: now)
        let weekStart = today
        var seeded = SavedState()
        seeded.profile = state.profile
        seeded.profile.gender = "男"
        seeded.profile.targetWeightKg = 65
        func key(_ offset: Int) -> String {
            ClubDates.key(calendar.date(byAdding: .day, value: offset, to: today) ?? today)
        }
        func exercise(_ name: String, _ library: String, sets: Int) -> Exercise {
            Exercise(name: name, muscle: "胸", sets: (0..<sets).map { _ in TrainingSet(weight: 20, reps: 10) }, libraryID: library)
        }
        var cycle = TrainingCycle(start: ClubDates.key(weekStart), plannedDates: [])
        cycle.endDate = cycle.end; cycle.sourceJobID = "ui-test"; cycle.explanationVersion = 1
        for dayKey in cycle.dates { seeded.days[dayKey, default: DayLog()].planCycle = cycle }
        let uiSession = UUID()
        var seededToday = DayLog()
        seededToday.exercises = [Exercise(name: "哑铃卧推", muscle: "胸",
            sets: (0..<3).map { _ in TrainingSet(weight: 20, reps: 10) },
            libraryID: "0025", workoutSessionID: uiSession)]
        seededToday.workoutSessions = [WorkoutSession(id: uiSession)]
        seededToday.activeWorkoutSessionID = uiSession
        if ProcessInfo.processInfo.environment["BOJI_PREVIEW_ACTIVE_WORKOUT"] == "1" {
            seededToday.workoutStartedAt = now.addingTimeInterval(-1200)
            seededToday.workoutSessions = [WorkoutSession(id: uiSession, startedAt: seededToday.workoutStartedAt)]
        }
        seeded.days[key(0)] = seededToday
        seeded.days[key(1), default: DayLog()].exercises = [exercise("杠铃深蹲", "0043", sets: 3)]
        seeded.days[key(3), default: DayLog()].exercises = [exercise("坐姿划船", "0027", sets: 3)]
        cycle.plannedDates = [key(0), key(1), key(3)].filter { cycle.dates.contains($0) }
        for dayKey in cycle.dates { seeded.days[dayKey, default: DayLog()].planCycle = cycle }
        let session = UUID()
        var yesterday = DayLog()
        yesterday.exercises = [Exercise(name: "哑铃卧推", muscle: "胸",
            sets: [TrainingSet(weight: 20, reps: 10, completed: true), TrainingSet(weight: 20, reps: 10, completed: true)],
            libraryID: "0025", workoutSessionID: session)]
        yesterday.workoutEndedAt = now.addingTimeInterval(-86000)
        yesterday.workoutSavedAt = now.addingTimeInterval(-86000)
        yesterday.activeWorkoutSessionID = session
        yesterday.workoutSessions = [WorkoutSession(id: session, startedAt: now.addingTimeInterval(-90000),
            endedAt: now.addingTimeInterval(-86000), savedAt: now.addingTimeInterval(-86000))]
        seeded.days[key(-1)] = yesterday
        for (offset, kg) in [(-1, 70.0), (-4, 70.4), (-8, 70.8), (-12, 71.1)] {
            seeded.days[key(offset), default: DayLog()].bodyWeight = BodyWeightEntry(kilograms: kg, updatedAt: now)
        }
        if ProcessInfo.processInfo.environment["BOJI_AUDIT_SCREEN"] != nil || ProcessInfo.processInfo.environment["BOJI_UI_TEST_SEED_MEALS"] == "1" {
            seeded.days[key(-1), default: DayLog()].weeklyReview = BojiAuditFixtures.review(date: today.addingTimeInterval(-86400))
            seeded.days[key(0), default: DayLog()].meals = [
                Meal(name: "燕麦、鸡蛋与无糖酸奶", category: "早餐", calories: 420, protein: 26, carbs: 48, fat: 14),
                Meal(name: "香煎鸡胸肉配杂粮饭与当季蔬菜，少油烹饪", category: "午餐", calories: 650, protein: 45, carbs: 72, fat: 19),
                Meal(name: "清蒸鱼与时蔬", category: "晚餐", calories: 480, protein: 36, carbs: 42, fat: 18)
            ]
        }
        state = seeded
        _ = persist(changedDates: Array(seeded.days.keys))
    }
    #endif

    func deactivateAccount() {
        resetSync()
        accountService = nil; aiService = nil; activeAccountID = nil
        fileURL = directory.appendingPathComponent("records-v1.json")
        state = SavedState(); canSave = true
        pendingDomainCommands = []; confirmedFinishSessions = []
        publishWidgetSnapshot()
        TrainingActivityService.shared.end()
    }

    @discardableResult
    func eraseAccountData(_ id: Int) -> Bool {
        AccountDiagnostics130.erase(owner: id)
        BojiInteraction131.erase(owner: id)
        SubmittedDraftClears130.erase(owner: id)
        guard WeeklyPlanDraftStore130.erase(owner: id) else { return false }
        MutationReceipts130.pending[id] = nil
        ClubRestStorage.erase(owner: id)
        ClubCoachDraftStorage.erase(owner: id)
        if activeAccountID == id { resetSync() }
        let records = directory.appendingPathComponent("records-user-\(id)-v1.json")
        let media = directory.appendingPathComponent("media-user-\(id)", isDirectory: true)
        do {
            let planBackup = records.appendingPathExtension("before-text-limit")
            if FileManager.default.fileExists(atPath: planBackup.path) { try FileManager.default.removeItem(at: planBackup) }
            let conflicts = records.appendingPathExtension("conflict")
            if FileManager.default.fileExists(atPath: conflicts.path) { try FileManager.default.removeItem(at: conflicts) }
            let mealDrafts = directory.appendingPathComponent("meal-drafts-user-\(id)", isDirectory: true)
            if FileManager.default.fileExists(atPath: mealDrafts.path) { try FileManager.default.removeItem(at: mealDrafts) }
            let manualPlans = directory.appendingPathComponent("manual-plans-user-\(id)", isDirectory: true)
            if FileManager.default.fileExists(atPath: manualPlans.path) { try FileManager.default.removeItem(at: manualPlans) }
            let exports = directory.appendingPathComponent("exports-user-\(id)")
            if FileManager.default.fileExists(atPath: exports.path) { try FileManager.default.removeItem(at: exports) }
            for item in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where item.lastPathComponent.hasPrefix("recovery-\(id)-") || item.lastPathComponent.hasPrefix(records.lastPathComponent + ".journal.interrupted-") {
                try FileManager.default.removeItem(at: item)
            }
            let marker = records.appendingPathExtension("recovery-pending")
            if FileManager.default.fileExists(atPath: marker.path) { try FileManager.default.removeItem(at: marker) }
            let journal = records.appendingPathExtension("journal")
            if FileManager.default.fileExists(atPath: journal.path) { try FileManager.default.removeItem(at: journal) }
            if FileManager.default.fileExists(atPath: records.path) { try FileManager.default.removeItem(at: records) }
            let domainCommands = directory.appendingPathComponent("domain-commands-user-\(id)-v1.json")
            if FileManager.default.fileExists(atPath: domainCommands.path) { try FileManager.default.removeItem(at: domainCommands) }
            if FileManager.default.fileExists(atPath: media.path) { try FileManager.default.removeItem(at: media) }
        } catch { return false }
        if activeAccountID == id {
            state = SavedState()
            cloudBase = nil
            freshInstall = true
        }
        return true
    }

    private func resetSync() {
        trainingInterfacePresented = false
        clubAIInterfacePresented = false
        recordedGoalProfile = nil; recordedGoalNutrition = nil
        generation = UUID(); snapshotWriteGeneration = UUID(); localEditRevision = UUID()
        syncTask?.cancel(); syncTask = nil
        mediaSyncTask?.cancel(); mediaSyncTask = nil; mediaSyncMessage = nil
        syncInProgress = false; needsAnotherSync = false
        finishSyncWaiters(completed: false)
        conflictNotice = nil; exportedMonth = nil; localRecovery = nil; recoveryCandidate = nil; photoSyncIssues = []; photoRetryDates = [:]; exportNotice = nil; mediaCleanupNotice = nil
        cloudBase = nil; cloudRevision = nil; cloudPartitionCache = CloudPartitionCache(); dirty = true; journalSequence = 0; acknowledgedAIChange = nil; photosNeedDownload = true; syncStatus = .idle
    }

    func seedProfile(_ profile: MemberProfile) {
        // Never overwrite unsent edits with the account endpoint's older profile.
        if freshInstall && !dirty {
            state.profile = profile
            state.nutritionTarget = NutritionTarget.estimate(profile)
            do { try persistLocalOnly() } catch { message = "资料和营养目标尚未保存在本机，请稍后重试。" }
        }
    }

    /// Project server-confirmed facts into the local compatibility profile.
    /// Missing fields stay at their legacy defaults in storage but are marked
    /// unknown, so AI/rules/nutrition never treat those defaults as facts.
    func applyV2ProfileFacts(_ facts: [String: JSONValue], meta: [String: ProfileFactMeta]) {
        var profile = state.profile
        func string(_ key: String) -> String? { facts[key]?.string }
        func number(_ key: String) -> Double? { facts[key]?.numberValue }
        func int(_ key: String) -> Int? { number(key).map { Int($0) } }
        if let value = string("nickname") { profile.nickname = value }
        profile.equipmentOther = string("equipment_other")
        if case .array(let rows)? = facts["home_training_days"] { profile.homeTrainingDays = rows.compactMap(\.intValue) } else { profile.homeTrainingDays = nil }
        if let value = string("age_group") { profile.ageGroup = value }
        if let value = facts["equipment_exclusions"],case .array(let rows)=value { profile.equipmentExclusions=rows.compactMap(\.string) }
        if let value = string("goal") { profile.goal = value }
        if let value = string("experience") { profile.experience = value }
        if let value = string("venue") { profile.venue = value }
        if let value = string("focus") { profile.focus = value }
        profile.limitations = string("limitations")
        profile.nutritionContext = string("nutritionContext") ?? string("nutrition_context")
        profile.dailyActivity = string("dailyActivity") ?? string("daily_activity")
        if let value = facts["equipment"], case .array(let rows) = value {
            profile.equipment = rows.compactMap(\.string).joined(separator: "、")
        }
        if let value = int("days_per_week") { profile.daysPerWeek = value }
        if let value = int("session_minutes") { profile.sessionMinutes = value }
        if let value = int("age_years") { profile.age = value }
        if let value = number("height_cm") { profile.height = value }
        if let value = number("profile_weight_kg") { profile.weight = value }
        profile.targetWeightKg = number("target_weight_kg")
        let sex = string("sex_for_nutrition")
        profile.gender = sex.flatMap { ["男", "女"].contains($0) ? $0 : nil }
        if let value = facts["training_days"], case .array(let rows) = value {
            profile.trainingDays = rows.compactMap { $0.numberValue.map(Int.init) }
        }
        profile.factState = meta
        if profile != state.profile {
            guard saveProfile(profile) else { return }
        } else { ensureNutritionTarget() }
        do { try persistLocalOnly() } catch { message = "资料已从服务端核对，但本机保存失败；请稍后重试。" }
        scheduleCloudSync()
    }

    private func ensureNutritionTarget() {
        let estimate = NutritionTarget.estimate(state.profile)
        guard state.nutritionTarget == nil || state.nutritionTarget?.calculationVersion != estimate.calculationVersion
            || state.nutritionTarget?.generalGuidanceOnly != estimate.generalGuidanceOnly else { return }
        state.nutritionTarget = NutritionTarget.estimate(state.profile)
        do { try persistLocalOnly() } catch { message = "营养参考暂未保存在本机，原记录保留，请稍后重试。" }
    }

    func beginCloudSync(account: AccountService, ai: AIService) {
        guard activeAccountID != nil else { return }
        accountService = account; aiService = ai
        if freshInstall { cloudBase = snapshot(); freshInstall = false }
        scheduleSync(after: 0)
    }

    func scheduleCloudSync() { scheduleSync(after: 1.2) }

    private func finishSyncWaiters(completed: Bool) {
        let waiting = Array(syncWaiters.values)
        syncWaiters.removeAll()
        for continuation in waiting { continuation.resume(returning: completed) }
    }

    private func waitForCurrentSync() async -> Bool {
        guard syncInProgress else { return true }
        let id = UUID()
        let deadline = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
            self?.syncWaiters.removeValue(forKey: id)?.resume(returning: false)
        }
        defer { deadline.cancel() }
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled, syncInProgress else { continuation.resume(returning: !Task.isCancelled); return }
                syncWaiters[id] = continuation
            }
        }, onCancel: { [weak self] in
            Task { @MainActor in self?.syncWaiters.removeValue(forKey: id)?.resume(returning: false) }
        })
    }

    func syncForPlanAdoption(ownerID: Int) async -> Bool {
        guard canSave else { message = "本机记录尚不能保存，请先完成记录修复，原安排已保留。"; return false }
        guard accountService?.user?.id == ownerID else { message = "登录状态已变化，请重新登录后确认调整。"; return false }
        let ticket = generation
        for _ in 0..<3 {
            guard generation == ticket, activeAccountID == ownerID, accountService?.user?.id == ownerID, !Task.isCancelled else { return false }
            if syncInProgress {
                guard await waitForCurrentSync() else {
                    guard generation == ticket, activeAccountID == ownerID, accountService?.user?.id == ownerID, !Task.isCancelled else { return false }
                    message = "当前同步尚未完成，请稍后再确认调整；原安排已保留。"; return false
                }
            } else { await syncNow() }
            guard generation == ticket, activeAccountID == ownerID, accountService?.user?.id == ownerID, !Task.isCancelled else { return false }
            switch syncStatus {
            case .synced: return true
            case .pending: continue // Edits made during the upload need their own acknowledgment.
            case .failed(let reason): message = "同步未完成：\(reason)。原安排已保留。"
            case .waitingService: message = "服务暂忙，正在等待同步。请稍后确认调整，原安排已保留。"
            case .waiting: message = "同步暂时中断，请检查网络后重试，原安排已保留。"
            default: message = "记录尚未同步完成，请稍后确认调整，原安排已保留。"
            }
            return false
        }
        message = "记录仍在更新，请等同步完成后再确认调整；原安排已保留。"
        return false
    }

    private func mergeCloudSnapshot(_ remote: CloudState, base: CloudState?, ticket: UUID, userID: Int) async throws -> CloudMergeComputation {
        for _ in 0..<4 {
            let revision = localEditRevision, jobsRevision = aiService?.cloudChangeID
            let input = CloudMergeWork(local: snapshot(includeLocalPhotos: true), remote: remote, base: base)
            let result = try await CloudBackgroundWork.merge(input)
            try checkContext(ticket, userID)
            if revision == localEditRevision && jobsRevision == aiService?.cloudChangeID { return result }
        }
        throw CloudSyncError.busy("记录仍在更新，稍后继续同步。")
    }
    private func cloudMatches(_ remote: CloudState, ticket: UUID, userID: Int) async throws -> Bool {
        let revision = localEditRevision, jobsRevision = aiService?.cloudChangeID
        let same = try await CloudBackgroundWork.same(.init(left: snapshot(), right: remote))
        try checkContext(ticket, userID)
        return same && revision == localEditRevision && jobsRevision == aiService?.cloudChangeID
    }

    func syncNow() async {
        guard !syncInProgress else { needsAnotherSync = true; _ = await waitForCurrentSync(); return }
        guard canSave, let account = accountService, let userID = activeAccountID,
              account.user?.id == userID else { return }
        let ticket = generation
        syncInProgress = true; needsAnotherSync = false; syncStatus = .syncing
        var retryDelay = 1.2
        photoSyncIssues.removeAll { issue in state.days[issue.dateKey]?.meals.contains(where: { $0.id == issue.mealID && $0.photoFilename != nil }) != true }
        defer {
            if generation == ticket {
                syncInProgress = false
                finishSyncWaiters(completed: true)
                if needsAnotherSync { scheduleSync(after: retryDelay) }
            }
        }
        do {
            guard aiService?.canSyncJobs != false else { throw CloudSyncError.message("任务文件尚未恢复，云同步已暂停，避免覆盖已保存的分析。原文件和云端报告保留。") }
            // Phase 1: 域命令先于权威读取冲刷，命令造成的 revision 变化随本次读取合并回本机。
            await flushDomainCommands(ticket: ticket, userID: userID)
            try checkContext(ticket, userID)
            let hasBlockedCommands = pendingDomainCommands.contains { $0.owner == userID && $0.blocked == true }
            for _ in 0..<3 {
                let known = cloudBase?.recordIntegrityVersion == 1 ? cloudRevision : nil
                let response = try await CloudPartitionClient.read(account: account, userID: userID, knownRevision: known, cache: cloudPartitionCache)
                try checkContext(ticket, userID)
                if response.statusCode == 409 { continue }
                guard response.statusCode == 200 else { throw cloudError(response.http) }
                guard let envelope = response.envelope else { throw CloudSyncError.message("云端分批读取尚未确认，请重试。") }
                let remoteSnapshot = envelope.unchanged == true ? cloudBase : envelope.state
                if envelope.unchanged == true, !hasBlockedCommands, !dirty, acknowledgedAIChange == aiService?.cloudChangeID {
                    needsAnotherSync = false; syncStatus = .synced(Date())
                    scheduleMediaSync(account, userID: userID, ticket: ticket); return
                }
                if let remote = envelope.state {
                    photosNeedDownload = true
                    let computation = try await mergeCloudSnapshot(remote, base: cloudBase, ticket: ticket, userID: userID)
                    if let backup = computation.conflictBackup {
                        try backup.write(to: fileURL.appendingPathExtension("conflict"), options: [.atomic,.completeFileProtection])
                        conflictNotice = "其他设备同时修改了 \(computation.conflicts) 处记录，合并时保留了本机修改。另一份记录已保存在本机，可在“导出与备份”中导出核对。"
                    }
                    let merged = computation.state
                    state = merged.savedState()
                    ensureNutritionTarget()
                    if let ai = aiService, !ai.replaceCloudJobs(merged.aiJobs ?? []) { throw CloudSyncError.message("分析记录未能在本机保存，已暂停上传；云端原报告保留。") }
                    aiService?.pruneArchivedJobs(Set(merged.deletedAIJobIDs ?? []))
                    aiService?.invalidateDomainQueries()
                    cloudBase = remote
                }
                if hasBlockedCommands { throw CloudSyncError.message("有一项修改需要处理，已更新云端记录。请到设置查看待处理记录。") }
                if pendingDomainCommands.contains(where: { $0.owner == userID && $0.blocked != true }) {
                    cloudBase = remoteSnapshot; cloudRevision = envelope.revision
                    try await checkpoint(ticket: ticket, userID: userID)
                    needsAnotherSync = true; syncStatus = .pending; return
                }
                let sent = snapshot()
                let unchanged: Bool
                if let remoteSnapshot {
                    unchanged = try await CloudBackgroundWork.same(.init(left: sent, right: remoteSnapshot))
                    try checkContext(ticket, userID)
                } else { unchanged = false }
                var acceptedRevision = envelope.revision
                var acceptedState = remoteSnapshot ?? sent
                if !unchanged {
                    let result = try await CloudPartitionClient.write(account: account, userID: userID, baseRevision: envelope.revision, state: sent, base: remoteSnapshot, cache: cloudPartitionCache)
                    try checkContext(ticket, userID)
                    if result.statusCode == 409 { continue }
                    guard result.statusCode == 200 else { throw cloudError(result.http) }
                    guard let acknowledgment = result.envelope else { throw CloudSyncError.message("云端保存结果尚未确认，请重试；本机原记录保留。") }
                    guard let canonical = acknowledgment.state else { throw CloudSyncError.message("云端保存状态尚未确认，请重试同步；本机记录仍保留。") }
                    acceptedRevision = acknowledgment.revision
                    acceptedState = canonical
                    let updatedComputation = try await mergeCloudSnapshot(canonical, base: sent, ticket: ticket, userID: userID)
                    let updated = updatedComputation.state
                    state = updated.savedState()
                    ensureNutritionTarget()
                    if let ai = aiService, !ai.replaceCloudJobs(updated.aiJobs ?? []) { throw CloudSyncError.message("云端已接收记录，本机分析缓存未保存成功，将在恢复后继续同步。") }
                    aiService?.pruneArchivedJobs(Set(updated.deletedAIJobIDs ?? []))
                }
                // Server normalization and edits made during the upload must both survive.
                cloudBase = acceptedState; cloudRevision = acceptedRevision
                let matchesAccepted = try await cloudMatches(acceptedState, ticket: ticket, userID: userID)
                dirty = !matchesAccepted
                acknowledgedAIChange = aiService?.cloudChangeID
                try await checkpoint(ticket: ticket, userID: userID)
                try checkContext(ticket, userID)
                let stillMatches = try await cloudMatches(acceptedState, ticket: ticket, userID: userID)
                if !stillMatches { needsAnotherSync = true }
                cleanupDeletedPhotos()
                aiService?.invalidateDomainQueries(refresh: true)
                syncStatus = needsAnotherSync ? .pending : .synced(Date())
                scheduleMediaSync(account, userID: userID, ticket: ticket)
                return
            }
            throw CloudSyncError.message("其他设备正在更新，请稍后再同步。")
        } catch CloudSyncError.busy(_) {
            if generation == ticket { syncStatus = .waitingService; retryDelay = 5; needsAnotherSync = true }
        } catch is CancellationError {
            if generation == ticket { syncStatus = .waiting }
        } catch let error as URLError {
            if generation == ticket {
                syncStatus = [.notConnectedToInternet, .networkConnectionLost, .timedOut].contains(error.code)
                    ? .waiting : .failed(AppErrorText.message(error))
            }
        } catch {
            if generation == ticket { syncStatus = .failed(AppErrorText.message(error)) }
        }
    }

    func weeklyTemplate130(planID: String) -> ManualPlanTemplate? {
        syncedPlanTemplates().first { $0.draft.operationID == planID && $0.recurrence130 != nil }
    }
    @discardableResult func setWeeklyRepeat130(templateID: UUID, enabled: Bool) -> Bool {
        guard let index = state.planTemplates?.firstIndex(where: { $0.id == templateID }), state.planTemplates?[index].recurrence130 != nil else { return false }
        let previous = state
        state.planTemplates?[index].recurrence130?.enabled = enabled
        state.planTemplates?[index].updatedAt = Date()
        guard persist(changedDates: []) else { state = previous; return false }
        if enabled { extendWeeklyPlans130() }
        return true
    }
    @discardableResult func saveWeeklyPlan130(draft: ManualPlanDraft, weekdays: [ManualPlanDay], repeats: Bool, baseline: [String: DayLog], replacing: UUID?) -> Bool {
        guard canSave, editingAccountID != nil, weekdays.count == 7, draft.validation() == nil, let start = ClubDates.date(fromKey: draft.start),
              baseline.allSatisfy({ PlanAdoptionRules.sameTraining(state.days[$0.key] ?? DayLog(), $0.value) }),
              weekdays.flatMap(\.movements).compactMap(\.customID).allSatisfy({ id in customExercises.contains { $0.id == id } }) else { message = "安排或动作已变化，请重新查看后保存。"; return false }
        let previous = state
        do {
            let result = try draft.result()
            for offset in 0..<28 {
                guard let key = draft.dateKey(offset: offset), let date = ClubDates.date(fromKey: key) else { continue }
                let old = state.days[key] ?? DayLog()
                if PlanAdoptionRules.isProtected(old) { continue }
                var day = old
                state.deletedExerciseIDs = Array(Set((state.deletedExerciseIDs ?? []) + old.exercises.map { $0.id.uuidString })).sorted()
                day.exercises = weeklyExercises130(weekdays[WeeklyPlanRules130.index(date)], date: key, planID: draft.operationID)
                day.plannedMoveDestination = nil; day.movedFromDate = nil
                let weekStart = ClubDates.calendar.date(byAdding: .day, value: (offset / 7) * 7, to: start) ?? start
                let planned = (0..<7).compactMap { n -> String? in
                    guard let d = ClubDates.calendar.date(byAdding: .day, value: n, to: weekStart), !weekdays[WeeklyPlanRules130.index(d)].movements.isEmpty else { return nil }; return ClubDates.key(d)
                }
                day.planCycle = TrainingCycle(start: ClubDates.key(weekStart), plannedDates: planned, sourceJobID: draft.operationID, explanationVersion: 1)
                state.days[key] = day
            }
            if let replacing, let index = state.planTemplates?.firstIndex(where: { $0.id == replacing }) { state.planTemplates?[index].recurrence130?.enabled = false; state.planTemplates?[index].updatedAt = Date() }
            var template = ManualPlanTemplate(id: draft.id, createdAt: Date(), draft: draft)
            template.recurrence130 = WeeklyRecurrence130(enabled: repeats, start: draft.start, days: weekdays); template.updatedAt = Date()
            state.planTemplates = (state.planTemplates ?? []).filter { $0.id != template.id } + [template]
            state.appliedAIJobs = Array(Set((state.appliedAIJobs ?? []) + [draft.operationID]))
            recordPlanHistory(operationID: draft.operationID, result: result, start: start, previous: previous, scope: baseline.keys.sorted(), source: "manual")
            guard persist(changedDates: baseline.keys.sorted()) else { state = previous; return false }
            return true
        } catch { state = previous; message = AppErrorText.message(error); return false }
    }
    private func weeklyExercises130(_ day: ManualPlanDay, date: String, planID: String) -> [Exercise] {
        day.movements.enumerated().map { index, movement in
            let key = "\(planID)/\(date)/\(index)"
            return Exercise(id: stableID(key), name: movement.name, muscle: movement.muscle, sets: movement.effectiveSets.enumerated().map { i, target in
                TrainingSet(id: stableID("\(key)/\(i)"), weight: target.weight ?? 0, reps: target.reps, durationSeconds: target.durationSeconds)
            }, libraryID: movement.libraryID, planID: planID, libraryQuery: movement.query, customExerciseID: movement.customID, customUnit: movement.customID == nil ? nil : movement.unit, restSeconds: movement.restSeconds)
        }
    }
    /// Bounded rolling materialization; stable IDs converge across devices.
    func extendWeeklyPlans130(now: Date = Date()) {
        guard canSave, editingAccountID != nil else { return }
        let previous = state; var changed: [String] = []
        let deleted = Set((state.deletedExerciseIDs ?? []).map { $0.lowercased() })
        for template in syncedPlanTemplates() {
            guard let rule = template.recurrence130, rule.enabled, rule.valid, !planIsEnded(template.draft.operationID) else { continue }
            let pid = template.draft.operationID
            for offset in 0..<28 {
                guard let date = ClubDates.calendar.date(byAdding: .day, value: offset, to: ClubDates.calendar.startOfDay(for: now)) else { continue }
                let key = ClubDates.key(date); if key < rule.start { continue }
                var day = state.days[key] ?? DayLog()
                guard !PlanAdoptionRules.isProtected(day), day.exercises.isEmpty, day.planCycle == nil, day.plannedMoveDestination == nil, day.movedFromDate == nil else { continue }
                let exercises = weeklyExercises130(rule.days[WeeklyPlanRules130.index(date)], date: key, planID: pid)
                if exercises.contains(where: { deleted.contains($0.id.uuidString.lowercased()) }) { continue }
                day.exercises = exercises
                let elapsed = max(0, ClubDates.calendar.dateComponents([.day], from: ClubDates.date(fromKey: rule.start) ?? date, to: date).day ?? 0)
                let cycleStart = ClubDates.calendar.date(byAdding: .day, value: -(elapsed % 7), to: date) ?? date
                let planned = (0..<7).compactMap { n -> String? in
                    guard let d = ClubDates.calendar.date(byAdding: .day, value: n, to: cycleStart), !rule.days[WeeklyPlanRules130.index(d)].movements.isEmpty else { return nil };return ClubDates.key(d)
                }
                day.planCycle = TrainingCycle(start: ClubDates.key(cycleStart), plannedDates: planned, sourceJobID: pid, explanationVersion: 1)
                state.days[key] = day; changed.append(key)
            }
        }
        if !changed.isEmpty, !persist(changedDates: changed) { state = previous }
    }

    func referenceIsUploaded130(_ reference: AIContextReference) -> Bool {
        guard let base = cloudBase else { return false }
        return reference.localFingerprint(state) == reference.localFingerprint(base.savedState())
    }

    private func applyMutationReceipts130(owner: Int) -> Bool {
        guard let receipts = MutationReceipts130.pending[owner], !receipts.isEmpty else { return true }
        let previous = state; var changed = Set<String>()
        do {
            for receipt in receipts {
                guard let diff = receipt.object?["diff"]?.object, let date = diff["date"]?.string, ClubDates.date(fromKey: date) != nil else { continue }
                var day = state.days[date] ?? DayLog()
                if let rows = diff["written_meals"]?.array {
                    for raw in rows {
                        let meal = try JSONDecoder().decode(Meal.self, from: JSONEncoder().encode(raw))
                        if !(state.deletedMealIDs ?? []).contains(where: { $0.lowercased() == meal.id.uuidString.lowercased() }) {
                            if !day.meals.contains(where: { $0.id == meal.id }) { day.meals.append(meal) }
                        }
                    }
                }
                if let raw = diff["written_body_measurements"] {
                    let rows = try JSONDecoder().decode([BodyWeightEntry].self, from: JSONEncoder().encode(raw))
                    let deleted = Set((day.deletedBodyMeasurementIDs ?? []).map { $0.lowercased() })
                    var known = day.bodyMeasurements ?? []
                    for value in rows {
                        guard let id = value.id, !deleted.contains(id.uuidString.lowercased()) else { continue }
                        if !known.contains(where: { $0.id == id }) { known.append(value) }
                    }
                    day.bodyMeasurements = known; day.bodyWeight = known.sorted { ($0.recordedAt ?? $0.updatedAt) < ($1.recordedAt ?? $1.updatedAt) }.last
                }
                state.days[date] = day; changed.insert(date)
            }
            if !changed.isEmpty, !persist(changedDates: Array(changed)) { state = previous; return false }
            MutationReceipts130.pending[owner] = nil
            return true
        } catch { state = previous; message = "记录已保存到账号，手机尚未更新。请刷新记录。"; return false }
    }

    /// Fresh authoritative read independent of unrelated queued writes.
    @discardableResult
    func refreshAfterMutation130() async -> Bool {
        guard canSave, let account = accountService, let userID = activeAccountID, account.user?.id == userID else { return false }
        if syncInProgress { _ = await waitForCurrentSync() }
        guard !syncInProgress, activeAccountID == userID else { return false }
        guard applyMutationReceipts130(owner: userID) else { return false }
        let ticket = generation; syncInProgress = true
        defer { if generation == ticket { syncInProgress = false; finishSyncWaiters(completed: true) } }
        do {
            let response = try await CloudPartitionClient.read(account: account, userID: userID, knownRevision: nil, cache: cloudPartitionCache)
            try checkContext(ticket, userID)
            guard response.statusCode == 200, let envelope = response.envelope, let remote = envelope.state else { throw CloudSyncError.message("记录已保存，正在等待更新到手机。") }
            let computation = try await mergeCloudSnapshot(remote, base: cloudBase, ticket: ticket, userID: userID)
            try checkContext(ticket, userID)
            state = computation.state.savedState()
            if let ai = aiService, !ai.replaceCloudJobs(computation.state.aiJobs ?? []) { throw CloudSyncError.message("回答尚未在手机保存，任务已保留。") }
            cloudBase = remote; cloudRevision = envelope.revision
            dirty = !(try await cloudMatches(remote, ticket: ticket, userID: userID))
            try await checkpoint(ticket: ticket, userID: userID)
            aiService?.invalidateDomainQueries(refresh: true)
            syncStatus = dirty ? .pending : .synced(Date())
            return true
        } catch {
            if generation == ticket { syncStatus = .failed(AppErrorText.message(error)); AccountDiagnostics130.record("record_refresh_failed", detail: String(describing: type(of: error))) }
            return false
        }
    }

    private func loadCurrentFile() throws {
        if let id = activeAccountID { try LocalRecoveryTransaction.finishPending(accountID: id, recordURL: fileURL) }
        localRecovery = nil; recoveryCandidate = nil
        if FileManager.default.fileExists(atPath: fileURL.appendingPathExtension("conflict").path) {
            conflictNotice = "本机保留了一份其他设备同时修改的记录，可在“导出与备份”中导出核对。"
        }
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try replayJournal(after: 0); return
        }
        let data = try Data(contentsOf: fileURL)
        let envelope = try? JSONDecoder().decode(LocalSyncEnvelope.self, from: data)
        let loaded: SavedState
        if let envelope { loaded = envelope.state }
        else {
            do { loaded = try JSONDecoder().decode(SavedState.self, from: data) }
            catch {
                canSave = false; freshInstall = false
                localRecovery = LocalRecoverySummary(readableEntries: 0, unreadableEntries: 1, snapshotReadable: false,
                    detail: "本机主记录暂时无法读取，原文件和保存日志都保留了。可以先导出原文件，重新读取或从云端恢复。")
                throw error
            }
        }
        cloudBase = envelope?.base
        freshInstall = false
        guard loaded.version == 1 else {
            canSave = false; freshInstall = false
            localRecovery = LocalRecoverySummary(readableEntries: 0, unreadableEntries: 1, snapshotReadable: false, detail: "记录版本暂不兼容，原文件已保留。请先导出原文件，再使用兼容版本读取。")
            message = localRecovery?.detail; return
        }
        state = loaded
        if state.importedPlan.count > 16000 {
            try data.write(to: fileURL.appendingPathExtension("before-text-limit"), options: [.atomic,.completeFileProtection])
            state.importedPlan = String(state.importedPlan.prefix(16000))
            message = "旧计划文字超过 16000 字，完整原文件已在本机备份。当前保留前 16000 字，请分段导入。"
        }
        cloudRevision = envelope?.cloudRevision
        try replayJournal(after: envelope?.journalSequence ?? 0)
    }

    func log(for date: Date) -> DayLog { state.days[ClubDates.key(date)] ?? DayLog() }

    @discardableResult
    func saveHealth(_ summary: HealthDay, on date: Date) -> Bool {
        guard summary.date == ClubDates.key(date) else { return false }
        let shared = summary.sharingSummary
        return mutate(date) {
            $0.health = shared
            Self.mergeHealthMeasurements(shared, into: &$0)
            if let linked = $0.linkedDeviceWorkoutID, !shared.workouts.contains(where: { $0.id == linked }) {
                $0.linkedDeviceWorkoutID = nil
            }
        }
    }

    @discardableResult
    func saveHealthAndLink(_ request: HealthShareReviewRequest, workoutID: String?) -> Bool {
        let current = log(for:request.date)
        if let issue = HealthShareConsent.issue(request,workoutID:workoutID,current:current,ownerID:editingAccountID) { message = issue; return false }
        let shared = request.summary.sharingSummary
        let retainedLink = current.linkedDeviceWorkoutID.flatMap { id in shared.workouts.contains(where: { $0.id == id }) ? id : nil }
        let newLink = current.trainingLog.completedSets > 0 ? workoutID ?? retainedLink : nil
        if HealthShareConsent.encoded(current.health) == HealthShareConsent.encoded(shared), current.linkedDeviceWorkoutID == newLink { return true }
        return mutate(request.date) {
            $0.health = shared
            Self.mergeHealthMeasurements(shared, into: &$0)
            $0.linkedDeviceWorkoutID = newLink
        }
    }

    private static func mergeHealthMeasurements(_ shared: HealthDay, into day: inout DayLog) {
        if day.bodyMeasurements == nil { day.bodyMeasurements = [day.bodyWeight].compactMap { $0 }.map { value in var copy = value; copy.id = copy.id ?? BodyMeasurementIdentity.legacy(copy, date: shared.date); return copy } }
        let removed = Set(shared.deletedWeightSampleIDs ?? [])
        let tombstones = day.bodyMeasurements?.filter { $0.source == "healthkit" && removed.contains($0.externalSampleID ?? "") }.compactMap { $0.id?.uuidString.lowercased() } ?? []
        day.deletedBodyMeasurementIDs = Array(Set((day.deletedBodyMeasurementIDs ?? []) + tombstones))
        day.bodyMeasurements?.removeAll { $0.source == "healthkit" && removed.contains($0.externalSampleID ?? "") }
        for sample in shared.weightSamples ?? [] {
            guard let id = UUID(uuidString: sample.id), !(day.deletedBodyMeasurementIDs ?? []).contains(id.uuidString.lowercased()) else { continue }
            if let index = day.bodyMeasurements?.firstIndex(where: { $0.id == id || $0.externalSampleID == sample.externalID }) {
                day.bodyMeasurements?[index].externalSampleID = sample.externalID
            } else {
                day.bodyMeasurements?.append(BodyWeightEntry(kilograms: sample.kilograms, updatedAt: shared.updatedAt, id: id, externalSampleID: sample.externalID, sourceBundle: sample.source.id, recordedAt: sample.date, source: "healthkit"))
            }
        }
        let deleted = Set(day.deletedBodyMeasurementIDs ?? [])
        day.bodyMeasurements?.removeAll { $0.id.map { deleted.contains($0.uuidString.lowercased()) } ?? false }
        day.bodyWeight = day.bodyMeasurements?.sorted { ($0.recordedAt ?? $0.updatedAt) < ($1.recordedAt ?? $1.updatedAt) }.last
    }

    @discardableResult
    func removeHealth(on date: Date) -> Bool { mutate(date) { $0.health = nil; $0.linkedDeviceWorkoutID = nil } }

    @discardableResult
    func saveProfile(_ profile: MemberProfile, initialWeightDate: Date? = nil) -> Bool {
        let previous = state
        let today = ClubDates.key(Date())
        let oldTarget = state.nutritionTarget ?? NutritionTarget.estimate(state.profile)
        var frozen: [String] = []
        for key in state.days.keys.sorted() where key < today && state.days[key]?.nutritionTarget == nil {
            state.days[key]?.nutritionTarget = oldTarget
            frozen.append(key)
        }
        if let date = initialWeightDate {
            guard !ClubDates.isFuture(date), profile.weight.isFinite, (20...400).contains(profile.weight) else { state = previous; message = "称重日期或体重不正确。"; return false }
            let key = ClubDates.key(date)
            if state.days[key]?.bodyWeight == nil {
                var day = state.days[key] ?? DayLog()
                day.bodyWeight = BodyWeightEntry(kilograms: profile.weight, updatedAt: Date())
                state.days[key] = day; frozen.append(key)
            }
        }
        state.profile = profile
        // Compute before the inout dictionary update: reading state during that
        // update violates Swift exclusive access when today already has a log.
        let currentTarget = NutritionTarget.estimate(profile)
        state.nutritionTarget = currentTarget
        if state.days[today] != nil { state.days[today]?.nutritionTarget = currentTarget; frozen.append(today) }
        if persist(changedDates: frozen) { return true }; state = previous; return false
    }

#if DEBUG
    @discardableResult
    func addExercise(_ guide: ExerciseGuide, on date: Date) -> Bool {
        guard log(for: date).exercises.count < 30 else { message = "一天最多安排 30 个动作。"; return false }
        return mutate(date) { day in
            let owner = PlanManagementRules.ownerForAddition(day)
            day.workoutSavedAt = nil
            day.exercises.append(Exercise(name: String(guide.name.prefix(100)), muscle: guide.muscle, sets: (0..<3).map { _ in ExerciseMeasurement.blankSet(name: guide.name) }, planID: owner))
        }
    }
    #endif

    @discardableResult
    func addExercise(_ item: LibraryExercise, on date: Date) -> Bool {
        if let id = item.customID { return addCustomExercise(id, on: date) }
        guard log(for: date).exercises.count < 30 else { message = "一天最多安排 30 个动作。"; return false }
        return mutate(date) {
            let owner = PlanManagementRules.ownerForAddition($0)
            $0.workoutSavedAt = nil
            $0.exercises.append(Exercise(name: String(item.displayName.prefix(100)), muscle: item.muscleLabel, sets: ExerciseMeasurement.initialSets(name: item.displayName, query: item.name, recordingUnit: item.suggestedRecordingUnit, trainingType: item.trainingTypeZH),
                                         libraryID: item.id, equipment: item.equipmentLabel,
                                         imageURL: item.imageURL, gifURL: item.gifURL, planID: owner, libraryQuery: item.name))
        }
    }

    @discardableResult
    func updateSet(_ set: TrainingSet, exerciseID: UUID, on date: Date) -> Bool {
        guard RecordLimits.valid(set) else { message = "训练数值超出记录范围，原数据已保留；计时单组最多 6 小时，请分段登记。"; return false }
        guard !set.completed || !ClubDates.isFuture(date) else { message = "未来日期只能安排训练，到了当天才能勾选完成。"; return false }
        guard log(for:date).trainingLog.exercises.contains(where: { $0.id == exerciseID && $0.sets.contains(where: { $0.id == set.id }) }) else { message = "训练组已切换或删除，请重新打开。"; return false }
        let selected = log(for:date).trainingLog
        let originalSet = selected.exercises.first { $0.id == exerciseID }?.sets.first { $0.id == set.id }
        if set.completed, originalSet?.hasActualEntry != true, set.actualEntered != true {
            message = "请先填写本组实际次数或秒数，再标记完成。"; return false
        }
        let correcting = selected.workoutSavedAt != nil
        if correcting, let originalSet, originalSet.completed != set.completed { message = "已确认场次不能切换完成状态；数值修正会保留勘误记录。"; return false }
        let autoStart = set.validCompletion && Calendar.current.isDateInToday(date) && selected.workoutStartedAt == nil && selected.workoutEndedAt == nil && selected.workoutSavedAt == nil && selected.completedSets == 0
        let saved = mutate(date) { log in
            guard let exerciseIndex = log.exercises.firstIndex(where: { $0.id == exerciseID }),
                  let setIndex = log.exercises[exerciseIndex].sets.firstIndex(where: { $0.id == set.id }) else { return }
            var clean = set
            clean.weight = clean.weight.isFinite ? min(max(0, clean.weight), RecordLimits.maximumWeight) : 0
            clean.reps = min(max(0, clean.reps), RecordLimits.maximumReps)
            clean.durationSeconds = clean.durationSeconds.map { min(max(0, $0), RecordLimits.maximumSeconds) }
            if clean.durationSeconds != nil { clean.reps = 0 }
            if !(clean.durationSeconds.map { $0 > 0 } ?? (clean.reps > 0)) { clean.completed = false }
            if autoStart && clean.validCompletion { log.workoutStartedAt = Date(); log.workoutEndedAt = nil }
            // A late correction must not extend an already finished workout.
            if !correcting && (log.exercises[exerciseIndex].sets[setIndex].completed != clean.completed || log.exercises[exerciseIndex].sets[setIndex].weight != clean.weight || log.exercises[exerciseIndex].sets[setIndex].reps != clean.reps || log.exercises[exerciseIndex].sets[setIndex].durationSeconds != clean.durationSeconds) { log.workoutSavedAt = nil }
            log.exercises[exerciseIndex].sets[setIndex] = clean
        }
        if saved, autoStart { enqueueTrainingStartIfNeeded(for: date) }
        if saved, let originalSet { enqueueSetRecord(set, exerciseID: exerciseID, date: date, original: originalSet, correcting: correcting) }
        return saved
    }

    @discardableResult
    func setRecordingUnit(exerciseID: UUID, on date: Date, timed: Bool) -> Bool {
        guard log(for: date).trainingLog.exercises.contains(where: { $0.id == exerciseID }) else { return false }
        return mutate(date) { day in
            guard let index = day.exercises.firstIndex(where: { $0.id == exerciseID }) else { return }
            day.exercises[index].customUnit = timed ? "秒" : "次"
            for i in day.exercises[index].sets.indices where !day.exercises[index].sets[i].validCompletion {
                day.exercises[index].sets[i].durationSeconds = timed ? 30 : nil
                day.exercises[index].sets[i].reps = timed ? 0 : 10
                day.exercises[index].sets[i].weight = 0
                day.exercises[index].sets[i].actualEntered = false
            }
        }
    }

    func addSet(exerciseID: UUID, on date: Date) {
        guard log(for:date).trainingLog.exercises.contains(where: { $0.id == exerciseID }) else { message = "训练已切换，请重新打开。"; return }
        guard (log(for: date).exercises.first { $0.id == exerciseID }?.sets.count ?? 0) < 50 else { message = "每个动作最多记录 50 组。"; return }
        mutate(date) { log in
            guard let index = log.exercises.firstIndex(where: { $0.id == exerciseID }) else { return }
            log.workoutSavedAt = nil
            let previous = log.exercises[index].sets.last
            log.exercises[index].sets.append(TrainingSet(weight: previous?.weight ?? 0, reps: previous?.reps ?? 10, durationSeconds: previous?.durationSeconds, actualEntered: false))
        }
    }

    func restoreWorkoutPause(on date: Date) {
        let day = log(for: date)
        guard let owner = editingAccountID, let id = day.activeWorkoutSessionID,
              let session = day.workoutSessions?.first(where: { $0.id == id }), let state = WorkoutPauseState.from(session) else { return }
        WorkoutPauseService.shared.adopt(state, owner: owner, date: date)
    }

    @discardableResult
    func setWorkoutPaused(_ paused: Bool, on date: Date, now: Date = Date()) -> Bool {
        let day = log(for: date)
        guard let owner = editingAccountID, let id = day.activeWorkoutSessionID,
              let session = day.workoutSessions?.first(where: { $0.id == id }),
              let start = session.startedAt, session.endedAt == nil else { return false }
        guard !paused || (session.pauseIntervals ?? []).count < 256 else { message = "本场暂停次数过多，请结束并保存当前训练。"; return false }
        guard mutate(date, edit: { log in
            guard let index = log.workoutSessions?.firstIndex(where: { $0.id == id }) else { return }
            var intervals = log.workoutSessions?[index].pauseIntervals ?? []
            if paused {
                if intervals.last?.end != nil || intervals.isEmpty { intervals.append(WorkoutPauseInterval(start: now, end: nil)) }
            } else if let last = intervals.indices.last, intervals[last].end == nil { intervals[last].end = now }
            log.workoutSessions?[index].pauseIntervals = intervals
        }) else { return false }
        if paused, let end = ClubRestStorage.deadline(owner: owner, date: date, sessionID: id, unfinished: true, now: now) {
            ClubRestStorage.savePaused(max(0, end.timeIntervalSince(now)), owner: owner, date: date, sessionID: id)
            ClubRestStorage.save(nil, owner: owner, date: date, sessionID: id)
        } else if !paused, let remaining = ClubRestStorage.pausedRemaining(owner: owner, date: date, sessionID: id, unfinished: true) {
            ClubRestStorage.savePaused(nil, owner: owner, date: date, sessionID: id)
            ClubRestStorage.save(now.addingTimeInterval(remaining), owner: owner, date: date, sessionID: id)
        }
        return WorkoutPauseService.shared.setPaused(paused, owner: owner, date: date, sessionID: id, startedAt: start, now: now)
    }

    @discardableResult
    func saveWorkout(on date: Date, now: Date = Date()) -> Bool {
        guard !ClubDates.isFuture(date,now:now) else { message = "未来训练只能保存计划，不能确认完成。"; return false }
        guard log(for: date).trainingLog.completedSets > 0 else { message = "至少完成一组后才能确认本次训练。"; return false }
        guard mutate(date, edit: {
            $0.workoutSavedAt = now
            if let id = $0.activeWorkoutSessionID, let index = $0.workoutSessions?.firstIndex(where: { $0.id == id }),
               let last = $0.workoutSessions?[index].pauseIntervals?.indices.last, $0.workoutSessions?[index].pauseIntervals?[last].end == nil {
                $0.workoutSessions?[index].pauseIntervals?[last].end = now
            }
            if $0.workoutEndedAt == nil && WorkoutTiming.hasRecentStart($0,on:date,now:now) {
                $0.workoutEndedAt = now
            }
        }) else { return false }
        enqueueTrainingFinishIfNeeded(for: date, now: now)
        return true
    }

    @discardableResult
    func saveWorkoutPlan(on date: Date) -> Bool {
        guard ClubDates.isFuture(date), !log(for:date).exercises.isEmpty else { return false }
        return mutate(date) { day in
            for i in day.exercises.indices {
                for j in day.exercises[i].sets.indices { day.exercises[i].sets[j].completed = false; day.exercises[i].sets[j].actualEntered = false }
            }
            day.workoutSavedAt=nil;day.workoutStartedAt=nil;day.workoutEndedAt=nil;day.linkedDeviceWorkoutID=nil
        }
    }

    /// 把一天明确设为休息日：清空未开始安排并重算所属周期；已完成/已开始记录受保护。
    @discardableResult
    func setPlannedRestDay(on date: Date) -> Bool {
        guard canSave, activeAccountID != nil,
              ClubDates.key(date) >= ClubDates.key(Date()) else {
            message = "只能把今天或未来的计划日设为休息日。"; return false
        }
        let key = ClubDates.key(date)
        let day = state.days[key] ?? DayLog()
        guard !WorkoutEditing.isProtected(day), !day.hasUnconfirmedTraining else {
            message = "这一天已经开始或有未确认训练，不能改为休息日。"; return false
        }
        let previous = state
        state.deletedExerciseIDs = Array(Set((state.deletedExerciseIDs ?? []) + day.exercises.map { $0.id.uuidString })).sorted()
        var updated = day
        updated.exercises = []
        updated.workoutSavedAt = nil
        updated.plannedMoveDestination = nil
        updated.movedFromDate = nil
        WorkoutSessions.synchronize(&updated)
        state.days[key] = updated
        var changed: Set<String> = [key]
        changed.formUnion(TrainingCycle.refreshPlannedDates(covering: key, in: &state.days))
        if persist(changedDates: Array(changed)) { return true }
        state = previous; return false
    }

    func removeSet(_ setID: UUID, exerciseID: UUID, on date: Date) {
        guard log(for:date).trainingLog.exercises.contains(where: { $0.id == exerciseID && $0.sets.contains(where: { $0.id == setID }) }) else { message = "训练组已切换或删除，请重新打开。"; return }
        mutate(date) { log in
            guard let index = log.exercises.firstIndex(where: { $0.id == exerciseID }) else { return }
            log.workoutSavedAt = nil
            log.exercises[index].sets.removeAll { $0.id == setID }
            log.exercises[index].deletedSetIDs = Array(Set((log.exercises[index].deletedSetIDs ?? []) + [setID.uuidString])).sorted()
        }
    }

    @discardableResult
    func removeExercise(_ id: UUID, on date: Date) -> Bool {
        guard log(for:date).trainingLog.exercises.contains(where: { $0.id == id }) else { message = "训练已切换或删除，请重新打开。"; return false }
        let previous = state
        let key = ClubDates.key(date)
        state.days[key]?.workoutSavedAt = nil
        state.days[key]?.exercises.removeAll { $0.id == id }
        state.deletedExerciseIDs = Array(Set((state.deletedExerciseIDs ?? []) + [id.uuidString])).sorted()
        if state.days[key]?.completedSets == 0 { state.days[key]?.linkedDeviceWorkoutID = nil }
        if state.days[key]?.trainingLog.exercises.isEmpty == true {
            state.days[key]?.workoutStartedAt = nil
            state.days[key]?.workoutEndedAt = nil
            state.days[key]?.linkedDeviceWorkoutID = nil
        }
        var changed: Set<String> = [key]
        changed.formUnion(TrainingCycle.refreshPlannedDates(covering: key, in: &state.days))
        if persist(changedDates: Array(changed)) { return true }
        state = previous; return false
    }

    func hasAppliedAIJob(_ id: String) -> Bool { state.appliedAIJobs?.contains(id) == true }

    // C2：行动状态机——阅读状态与行动状态分开；失败可重试，已完成不重复应用。
    // D3：阶段报告保存（挂结束日期；ID 不可变——重生成为新版本，多端按 ID 并集、历史都保留）。
    @discardableResult
    func savePhaseReport(_ report: PhaseReport, expectedOwner: Int?, expectedGeneration: UUID?) -> Bool {
        guard PhaseReportWriteGuard.allows(expectedOwner: expectedOwner, currentOwner: activeAccountID,
                                             expectedGeneration: expectedGeneration,
                                             currentGeneration: generation) else {
            message = "账号或记录已变化，这份阶段报告没有写入；请重新生成。"
            return false
        }
        let key = report.end
        let previous = state
        state.days[key, default: DayLog()].phaseReports = (state.days[key]?.phaseReports ?? []) + [report]
        guard persist(changedDates: [key]) else { state = previous; return false }
        return true
    }
    func phaseReports() -> [PhaseReport] {
        state.days.values.compactMap(\.phaseReports).flatMap { $0 }
            .sorted { $0.end == $1.end ? $0.generatedAt > $1.generatedAt : $0.end > $1.end }
    }

    // E5：自由计划草稿/模板跨设备同步。
    // 读写走 SavedState（随同步、按 ID 合并、删除标记并集）；本地文件继续双写，
    // 既有文件一次性迁入同步态（E8 迁移），迁移后本地副本保留不删。
    private func planSyncMigratedKey(_ owner: Int) -> String { "manual-plan-sync-migrated.v1.\(owner)" }
    /// 本机旧草稿无法读取时，界面必须先停止新建/自动保存，避免空白草稿覆盖原文件。
    func planDraftNeedsRecovery(owner: Int) -> Bool { planDraftRecoveryOwners.contains(owner) }
    /// F2：迁移失败不吞错、不误标完成——本地文件保留，下次启动重试；问题在模板库可见。
    /// 只有所有待迁移内容都成功读取并落盘后，才写入迁移完成标记。
    func migrateLocalPlanStorageIfNeeded(owner: Int) {
        let defaults = UserDefaults.standard
        // 迁移提示按账号区分：切换账号时不把上一个账号的问题显示给新账号。
        if planMigrationNoticeOwner != owner {
            planMigrationNotice = nil
            planMigrationNoticeOwner = nil
        }
        guard owner > 0, !defaults.bool(forKey: planSyncMigratedKey(owner)) else { return }
        let previous = state
        var changed = false
        var draftUnreadable = false
        var templatesUnreadable = false
        if state.planDrafts == nil { state.planDrafts = [] }
        if state.planTemplates == nil { state.planTemplates = [] }
        do {
            if let local = try ManualPlanDraftStorage.load(owner: owner),
               !(state.planDrafts ?? []).contains(where: { $0.id == local.id }) {
                var copy = local; copy.updatedAt = Date()
                state.planDrafts?.append(copy); changed = true
            }
        } catch { draftUnreadable = true; changed = false }
        do {
            let list = try ManualPlanDraftStorage.templates(owner: owner)
            for template in list.items where !(state.planTemplates ?? []).contains(where: { $0.id == template.id }) {
                var copy = template; copy.updatedAt = Date()
                state.planTemplates?.append(copy); changed = true
            }
            if list.unreadableCount > 0 { templatesUnreadable = true }
        } catch { templatesUnreadable = true }
        if changed {
            // 落盘成功才继续；失败恢复迁移前的内存状态，原文件保留。
            guard persist(changedDates: []) else {
                state = previous
                planMigrationNotice = "本机草稿/模板暂未并入云端记录，原文件已保留，稍后会自动重试。"
                planMigrationNoticeOwner = owner
                return
            }
        }
        if draftUnreadable {
            // 不写完成标记，允许安全重试；同时阻止新草稿覆盖原文件。
            planDraftRecoveryOwners.insert(owner)
            planMigrationNotice = "本机旧草稿暂时无法读取，原文件已保留；请先不要新建草稿，稍后会自动重试。"
            planMigrationNoticeOwner = owner
            return
        }
        planDraftRecoveryOwners.remove(owner)
        if templatesUnreadable {
            // 模板文件与草稿分开：不影响新建草稿，但保持未迁移以便重试。
            planMigrationNotice = "有旧计划模板暂时无法读取，原文件已保留；其余草稿已安全迁移。"
            planMigrationNoticeOwner = owner
            return
        }
        defaults.set(true, forKey: planSyncMigratedKey(owner))
        if planMigrationNoticeOwner == owner {
            planMigrationNotice = nil
            planMigrationNoticeOwner = nil
        }
    }
    func syncedPlanTemplates() -> [ManualPlanTemplate] {
        let deleted = Set(state.deletedPlanTemplateIDs ?? [])
        return (state.planTemplates ?? [])
            .filter { $0.deleted != true && !deleted.contains($0.id.uuidString.lowercased()) && !deleted.contains($0.id.uuidString) && $0.draft.structurallyValid }
            .sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString > $1.id.uuidString : $0.createdAt > $1.createdAt }
    }
    /// 云端异常草稿数量：UI 可提示恢复，但绝不按下标直接读取。
    func invalidSyncedPlanDraftCount() -> Int {
        let deleted = Set(state.deletedPlanDraftIDs ?? [])
        return (state.planDrafts ?? []).filter {
            $0.deleted != true && !deleted.contains($0.id.uuidString.lowercased()) && !deleted.contains($0.id.uuidString) && !$0.structurallyValid
        }.count
    }
    @discardableResult
    func saveSyncedPlanTemplate(_ template: ManualPlanTemplate) -> Bool {
        let previous = state
        var copy = template; copy.updatedAt = Date(); copy.deleted = false
        var records = (state.planTemplates ?? []).filter { $0.id != template.id }
        records.append(copy)
        state.planTemplates = records
        state.deletedPlanTemplateIDs = (state.deletedPlanTemplateIDs ?? []).filter { $0 != template.id.uuidString.lowercased() && $0 != template.id.uuidString }
        guard persist(changedDates: []) else { state = previous; return false }
        // 双写本地文件：降级与旧读取路径不丢数据。
        try? ManualPlanDraftStorage.saveTemplate(copy.draft, owner: activeAccountID ?? 0)
        return true
    }
    @discardableResult
    func deleteSyncedPlanTemplate(_ id: UUID) -> Bool {
        let previous = state
        if let index = state.planTemplates?.firstIndex(where: { $0.id == id }) {
            state.planTemplates?[index].deleted = true
            state.planTemplates?[index].updatedAt = Date()
        }
        state.deletedPlanTemplateIDs = Array(Set((state.deletedPlanTemplateIDs ?? []) + [id.uuidString.lowercased()])).sorted()
        guard persist(changedDates: []) else { state = previous; return false }
        return true
    }
    @discardableResult
    func saveSyncedPlanDraft(_ draft: ManualPlanDraft) -> Bool {
        let previous = state
        var copy = draft; copy.updatedAt = Date(); copy.deleted = false
        var records = (state.planDrafts ?? []).filter { $0.id != draft.id }
        records.append(copy)
        state.planDrafts = records
        guard persist(changedDates: []) else { state = previous; return false }
        if let owner = activeAccountID { try? ManualPlanDraftStorage.save(copy, owner: owner) }
        return true
    }
    func syncedPlanDraft() -> ManualPlanDraft? {
        let deleted = Set(state.deletedPlanDraftIDs ?? [])
        return (state.planDrafts ?? [])
            .filter { $0.deleted != true && !deleted.contains($0.id.uuidString.lowercased()) && !deleted.contains($0.id.uuidString) && $0.structurallyValid }
            .max { ($0.updatedAt ?? .distantPast) < ($1.updatedAt ?? .distantPast) }
    }
    @discardableResult
    func clearSyncedPlanDraft(id: UUID) -> Bool {
        let previous = state
        if let index = state.planDrafts?.firstIndex(where: { $0.id == id }) {
            state.planDrafts?[index].deleted = true
            state.planDrafts?[index].updatedAt = Date()
        }
        state.deletedPlanDraftIDs = Array(Set((state.deletedPlanDraftIDs ?? []) + [id.uuidString.lowercased()])).sorted()
        guard persist(changedDates: []) else { state = previous; return false }
        return true
    }

    func actionState(_ id: String) -> ClubActionRecord? {
        state.actionStates?.first { $0.id == id }
    }
    /// 记录行动状态。已完成不允许被回退成待处理/失败（防重复应用与误改）；
    /// 执行失败可再次登记（重试结果）；已过期只允许从非完成状态进入。
    @discardableResult
    func recordActionState(id: String, state newState: String, note: String? = nil) -> Bool {
        let allowed: Set<String> = [ClubActionRecord.statePending, ClubActionRecord.stateCompleted,
                                    ClubActionRecord.stateFailed, ClubActionRecord.stateExpired,
                                    ClubActionRecord.stateReference, ClubActionRecord.stateRejected]
        guard !id.isEmpty, allowed.contains(newState) else {
            message = "行动状态无法识别。"; return false
        }
        let previous = state
        var records = state.actionStates ?? []
        if let index = records.firstIndex(where: { $0.id == id }) {
            let existing = records[index]
            if existing.isCompleted && newState != ClubActionRecord.stateCompleted {
                message = "这项变更已完成，不会重复应用。"; return false
            }
            records[index] = ClubActionRecord(id: id, state: newState, updatedAt: Date(), note: note ?? existing.note)
        } else {
            records.append(ClubActionRecord(id: id, state: newState, updatedAt: Date(), note: note))
        }
        state.actionStates = records
        guard persist(changedDates: []) else { state = previous; return false }
        return true
    }

    @discardableResult
    func handleMealRecognitionIDs(_ ids: [String]) -> Bool {
        let previous = state
        state.appliedAIJobs = Array(Set((state.appliedAIJobs ?? []) + ids)).sorted()
        guard persist(changedDates: []) else { state = previous; return false }
        return true
    }

    @discardableResult
    func saveWeeklyReview(_ review: WeeklyReview) -> Bool {
        guard review.result != nil, ClubDates.date(fromKey: review.date) != nil else { return false }
        if review.recoveredWithoutContext == true {
            // Result-only recovery must never replace original survey/baseline/application state.
            return state.days[review.date]?.weeklyReview?.jobID == review.jobID
        }
        guard !(state.days[review.date]?.deletedWeeklyReviewIDs ?? []).contains(where: { $0.uppercased() == review.id.uuidString }) else {
            message = "这份复盘已删除，不能恢复旧任务覆盖记录。"; return false
        }
        let previous = state
        var summary = review
        summary.photos = []; summary.compareWith = nil; summary.priorJobIDs = nil; summary.recoveredWithoutContext = nil
        var day = state.days[review.date] ?? DayLog()
        WeeklyVersions.insert(summary, into: &day)
        state.days[review.date] = day
        if persist(changedDates: [review.date]) { return true }; state = previous; return false
    }

    /// Archive only coach jobs. Confirmed business records remain authoritative and untouched.
    func deleteCoachConversation(_ conversation: String, jobs: [AILocalJob]) -> Bool {
        guard editingAccountID != nil, UUID(uuidString: conversation) != nil else { return false }
        let ids = ClubCoachRules.turns(jobs, conversation: conversation,
            deleted: Set(state.deletedAIJobIDs ?? [])).map(\.id)
        let previous = state
        state.deletedAIJobIDs = Array(Set((state.deletedAIJobIDs ?? []) + ids)).sorted()
        guard persist(changedDates: []) else { state = previous; return false }
        aiService?.pruneArchivedJobs(Set(ids))
        if let owner = editingAccountID { ClubCoachDraftStorage.clear(owner: owner, conversation: conversation) }
        return true
    }

    func removeWeeklyReview(_ review: WeeklyReview) -> Bool {
        guard ClubDates.date(fromKey: review.date) != nil else { return false }
        let previous = state
        var day = state.days[review.date] ?? DayLog()
        day.deletedWeeklyReviewIDs = Array(Set((day.deletedWeeklyReviewIDs ?? []) + [review.id.uuidString])).sorted()
        WeeklyVersions.reconcile(&day)
        state.days[review.date] = day
        if persist(changedDates: [review.date]) { return true }; state = previous; return false
    }

    func applyWeeklyPlan(_ review: WeeklyReview, sessions: [AIPlanSession], replaceWholeWeek: Bool = true) -> Bool {
        let appliedID = "weekly/" + review.id.uuidString
        if hasAppliedAIJob(appliedID) { return true }
        guard review.result?.decision == "adjust", !sessions.isEmpty, let end = ClubDates.date(fromKey: review.date) else { message = "本次没有可应用的调整。"; return false }
        if let latest = state.days[review.date]?.weeklyReview, latest.id != review.id, latest.updatedAt > review.updatedAt {
            message = "本周期已有更新的复盘，请查看最新建议后再调整。"; return false
        }
        let today = ClubDates.calendar.startOfDay(for: Date())
        let selectedDates = sessions.map(\.date)
        guard Set(selectedDates).count == selectedDates.count else { message = "训练日期重复。"; return false }
        for session in sessions {
            guard let date = ClubDates.date(fromKey: session.date), date >= today,
                  let offset = ClubDates.calendar.dateComponents([.day], from: end, to: date).day, (1...7).contains(offset),
                  (review.survey.trainingDays ?? state.profile.trainingDays ?? [1,3,5]).contains((ClubDates.calendar.component(.weekday, from: date)+5)%7+1),
                  let original = review.baseline[session.date], !session.exercises.isEmpty, session.exercises.count <= 30, session.exercises.allSatisfy({ $0.sets.count <= 50 }),
                  session.exercises.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.sets.isEmpty && $0.sets.allSatisfy { ($0.durationSeconds.map { (1...RecordLimits.maximumSeconds).contains($0) } ?? (1...RecordLimits.maximumReps).contains($0.reps)) && ($0.weight ?? 0).isFinite && ($0.weight ?? 0) >= 0 && ($0.weight ?? 0) <= RecordLimits.maximumWeight } }) else {
                message = "建议日期已到期或训练数据不完整，请重新复盘。"; return false
            }
            let current = state.days[session.date]?.exercises ?? []
            guard !WorkoutEditing.isProtected(state.days[session.date] ?? DayLog()), current.flatMap(\.sets).allSatisfy({ !$0.completed }), (try? CloudMerge.same(current, original)) == true else {
                message = "\(session.date) 的计划已更改或开始训练。为保留你的记录，请重新复盘后再调整。"; return false
            }
        }
        let nextWeek = (1...7).compactMap { ClubDates.calendar.date(byAdding: .day, value: $0, to: end) }.map(ClubDates.key)
        let restDates = replaceWholeWeek ? nextWeek.filter { !selectedDates.contains($0) } : []
        if replaceWholeWeek {
            guard Set(selectedDates) == Set((review.result?.sessions ?? []).map(\.date)) else {
                message = "整周调整需要采用全部建议训练日；只调整部分日期请切换调整方式。"; return false
            }
            for key in restDates {
                guard key >= ClubDates.key(today), let original = review.baseline[key],
                      !WorkoutEditing.isProtected(state.days[key] ?? DayLog()),
                      (try? CloudMerge.same(state.days[key]?.exercises ?? [], original)) == true else {
                    message = "\(key) 已开始训练、已过去或安排有变化，无法整周替换。请保留记录并重新复盘，或只调整选中日期。"; return false
                }
            }
        }
        let previous = state
        for key in restDates {
            var day = state.days[key] ?? DayLog()
            state.deletedExerciseIDs = Array(Set((state.deletedExerciseIDs ?? []) + day.exercises.map { $0.id.uuidString })).sorted()
            day.exercises = []; day.workoutSavedAt = nil; day.plannedMoveDestination = nil; day.movedFromDate = nil
            state.days[key] = day
        }
        for session in sessions {
            let oldIDs = (state.days[session.date]?.exercises ?? []).map { $0.id.uuidString }
            state.deletedExerciseIDs = Array(Set((state.deletedExerciseIDs ?? []) + oldIDs)).sorted()
            var day = state.days[session.date] ?? DayLog()
            day.workoutSavedAt = nil
            day.exercises = session.exercises.enumerated().map { index, exercise in
                let key = appliedID + "/" + session.date + "/" + String(index)
                return Exercise(id: stableID(key), name: exercise.name, muscle: exercise.muscle, sets: exercise.sets.enumerated().map { j, set in TrainingSet(id: stableID(key+"/"+String(j)), weight: set.weight ?? 0, reps: set.reps, durationSeconds: set.durationSeconds) }, libraryID: exercise.library_id, planID: appliedID, libraryQuery: exercise.library_query, customExerciseID: exercise.custom_id, customUnit: exercise.custom_unit, restSeconds: exercise.rest_seconds)
            }
            state.days[session.date] = day
        }
        state.appliedAIJobs = (state.appliedAIJobs ?? []) + [appliedID]
        var saved = review; saved.applied = true; saved.photos = []; saved.updatedAt = Date()
        var reviewDay = state.days[review.date] ?? DayLog()
        WeeklyVersions.insert(saved, into: &reviewDay)
        state.days[review.date] = reviewDay
        let next = ClubDates.calendar.date(byAdding: .day, value: 1, to: end)!
        let cycleDates = TrainingCycle.stamp(days: &state.days, start: next, plannedDates: sessions.map(\.date))
        recordWeeklyPlanHistory(review: review, sessions: sessions, previous: previous, start: next,
            scope: replaceWholeWeek ? nextWeek : selectedDates)
        if persist(changedDates: cycleDates + [review.date]) { return true }
        state = previous; return false
    }

    @discardableResult
    func applyAIPlan(_ result: AIResult, jobID: String, replaceUnstarted: Bool = false, cycleStart: Date? = nil, minimumCycleStart: Date? = nil, expectedDays: [String: DayLog]? = nil, explicitScope: [String]? = nil, singleDay: Bool = false) -> Bool {
        if PlanManagementRules.isCancelled(jobID, days: state.days) { message = "这份计划已结束，请创建新的安排。"; return false }
        if hasAppliedAIJob(jobID) { return true }
        guard result.kind == "plan", let sessions = result.sessions, !sessions.isEmpty,
              sessions.allSatisfy({ ClubDates.date(fromKey: $0.date) != nil }) else {
            message = "计划日期不完整，请重新生成。"
            return false
        }
        if let minimumCycleStart {
            guard let cycleStart, ClubDates.key(cycleStart) >= ClubDates.key(minimumCycleStart) else {
                message = "下一周必须从原安排结束后的日期开始，请重新选择。"
                return false
            }
        }
        var window: Set<String> = []
        if let start = cycleStart {
            guard ClubDates.key(start) >= ClubDates.key(Date()) else { message = "计划开始日期已过去，请重新预览。"; return false }
            let duration = result.plan_days ?? 7
            guard [7,14,28].contains(duration) else { message = "计划长度不正确，请重新预览。"; return false }
            window = Set((0..<duration).compactMap { ClubDates.calendar.date(byAdding: .day, value: $0, to: start) }.map(ClubDates.key))
            if let explicitScope {
                guard !explicitScope.isEmpty, Set(explicitScope).isSubset(of: window) else { message = "计划范围不正确。"; return false }; window = Set(explicitScope)
            }
            guard Set(sessions.map(\.date)).count == sessions.count,
                  sessions.allSatisfy({ window.contains($0.date) && $0.date >= ClubDates.key(Date()) && !PlanAdoptionRules.isProtected(state.days[$0.date] ?? DayLog()) }) else {
                message = "计划日期已过去、重复或已有开始的训练，请重新预览。"; return false
            }
        }
        let affectedDates = replaceUnstarted && cycleStart != nil ? window : Set(sessions.map(\.date))
        if let expectedDays {
            guard affectedDates.allSatisfy({ key in
                guard let expected = expectedDays[key] else { return false }
                return PlanAdoptionRules.sameTraining(state.days[key] ?? DayLog(), expected)
            }) else { message = "安排在预览后发生了变化，请重新核对再保存。"; return false }
        }
        guard sessions.allSatisfy({ session in
            !session.exercises.isEmpty && session.exercises.count <= 30 && session.exercises.allSatisfy { exercise in
                !exercise.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (exercise.rest_seconds.map { (0...3600).contains($0) } ?? true) && (1...50).contains(exercise.sets.count)
                    && exercise.sets.allSatisfy { set in
                        (set.weight ?? 0).isFinite && (0...RecordLimits.maximumWeight).contains(set.weight ?? 0)
                            && (set.durationSeconds.map { (1...RecordLimits.maximumSeconds).contains($0) } ?? (1...RecordLimits.maximumReps).contains(set.reps))
                    }
            }
        }) else { message = "动作或组次数据不完整，请重新核对计划。"; return false }
        let previous = state
        // Rest days belong to the replacement scope too. Leave started records intact.
        let restDates = affectedDates.subtracting(sessions.map(\.date))
        for key in restDates where !PlanAdoptionRules.isProtected(state.days[key] ?? DayLog()) {
            var day = state.days[key] ?? DayLog()
            state.deletedExerciseIDs = Array(Set((state.deletedExerciseIDs ?? []) + day.exercises.map { $0.id.uuidString })).sorted()
            day.exercises = []; day.plannedMoveDestination = nil; day.movedFromDate = nil
            day.workoutSavedAt = nil
            state.days[key] = day
        }
        for session in sessions {
            var log = state.days[session.date] ?? DayLog()
            log.plannedMoveDestination = nil
            if replaceUnstarted && PlanAdoptionRules.isProtected(log) { state = previous; message = "这一天已经开始训练，请保留记录后另选日期。"; return false }
            if replaceUnstarted {
                log.movedFromDate = nil
                let removable = log.exercises.filter { !$0.sets.contains(where: { $0.completed }) }
                state.deletedExerciseIDs = Array(Set((state.deletedExerciseIDs ?? []) + removable.map { $0.id.uuidString })).sorted()
                log.exercises.removeAll { !$0.sets.contains(where: { $0.completed }) }
            }
            guard log.exercises.count + session.exercises.count <= 30 else { state = previous; message = "该日期的动作将超过 30 个，请先精简已有计划。"; return false }
            log.workoutSavedAt = nil
            log.exercises.append(contentsOf: session.exercises.enumerated().map { index, exercise in
                let key = "\(jobID)/\(session.date)/\(index)"
                return Exercise(id: stableID(key), name: exercise.name, muscle: exercise.muscle, sets: exercise.sets.enumerated().map { setIndex, set in
                    TrainingSet(id: stableID("\(key)/\(setIndex)"), weight: set.weight ?? 0, reps: set.reps, durationSeconds: set.durationSeconds)
                }, libraryID: exercise.library_id, planID: jobID, libraryQuery: exercise.library_query, customExerciseID: exercise.custom_id, customUnit: exercise.custom_unit, restSeconds: exercise.rest_seconds)
            })
            state.days[session.date] = log
        }
        state.appliedAIJobs = (state.appliedAIJobs ?? []) + [jobID]
        var cycleDates: [String] = []
        if let start = cycleStart, !singleDay {
            let weeks = (result.plan_days ?? 7) / 7
            for week in 0..<weeks {
                guard let anchor = ClubDates.calendar.date(byAdding: .day, value: week * 7, to: start) else { state = previous; message = "计划日期无法读取。"; return false }
                cycleDates += TrainingCycle.stamp(days: &state.days, start: anchor, plannedDates: sessions.map(\.date) + Array(restDates.filter { !(state.days[$0]?.exercises.isEmpty ?? true) }), sourceJobID: jobID)
            }
        }
        if explicitScope != nil, !singleDay {
            for key in cycleDates where !affectedDates.contains(key) { state.days[key]?.planCycle = previous.days[key]?.planCycle }
            for cycle in TrainingCycle.ownedIntervals(days: state.days) {
                for key in cycle.dates where affectedDates.contains(key) { state.days[key]?.planCycle = cycle }
            }
        }
        if let start = cycleStart {
            recordPlanHistory(operationID: jobID, result: result, start: start, previous: previous, scope: Array(affectedDates))
        }
        if persist(changedDates: Array(affectedDates.union(cycleDates))) { return true }
        state = previous
        return false
    }

    @discardableResult
    func advancePlannedWorkout(from sourceDate: Date, to destinationDate: Date, expectedSource: DayLog, expectedDestination: DayLog, asSeparateSession: Bool) -> Bool {
        guard canSave, activeAccountID != nil, ClubDates.calendar.isDateInToday(destinationDate), ClubDates.isFuture(sourceDate) else {
            message = "只能把尚未开始的未来训练提前到今天。"; return false
        }
        let sourceKey = ClubDates.key(sourceDate), destinationKey = ClubDates.key(destinationDate)
        var source = log(for: sourceDate), destination = log(for: destinationDate)
        guard (try? CloudMerge.same(source.exercises, expectedSource.exercises)) == true,
              (try? CloudMerge.same(destination.exercises, expectedDestination.exercises)) == true,
              source.activeWorkoutSessionID == expectedSource.activeWorkoutSessionID,
              destination.activeWorkoutSessionID == expectedDestination.activeWorkoutSessionID else {
            message = "安排在预览后发生了变化，请重新核对。"; return false
        }
        let active = destination.trainingLog
        let running = active.workoutStartedAt != nil && active.workoutEndedAt == nil && active.workoutSavedAt == nil
        let sourceStarted = source.workoutSessions?.contains { $0.startedAt != nil || $0.savedAt != nil } == true
        guard !source.exercises.isEmpty, !WorkoutEditing.isProtected(source), !sourceStarted, !destination.hasUnconfirmedTraining, !running else {
            message = "原训练已开始，或今天还有未确认的训练；请先保留当前记录。"; return false
        }
        guard destination.exercises.isEmpty || asSeparateSession,
              destination.exercises.count + source.exercises.count <= 30,
              (destination.workoutSessions?.count ?? 1) < 8 else {
            message = "请作为独立训练加入，并保留已有记录；当天动作或训练次数已满时不能添加。"; return false
        }
        let previous = state
        let oldIDs = source.exercises.map { $0.id.uuidString }
        let copies = source.exercises.map { exercise -> Exercise in
            var copy = exercise; copy.id = UUID(); copy.workoutSessionID = nil; copy.deletedSetIDs = nil
            copy.sets = exercise.sets.map { set in var value = set; value.id = UUID(); value.completed = false; value.actualEntered = false; return value }
            return copy
        }
        if destination.exercises.isEmpty && destination.workoutSessions?.isEmpty != false {
            destination.exercises = copies
            WorkoutSessions.initialize(&destination)
        } else {
            WorkoutSessions.initialize(&destination); WorkoutSessions.synchronize(&destination)
            let id = UUID(); destination.workoutSessions?.append(WorkoutSession(id: id))
            destination.activeWorkoutSessionID = id
            destination.exercises += copies.map { item in var copy = item; copy.workoutSessionID = id; return copy }
            WorkoutSessions.restoreActiveFields(&destination)
        }
        destination.movedFromDate = sourceKey
        source.exercises = []
        // Keep even unstarted session IDs: cloud sync must not drop metadata.
        WorkoutSessions.synchronize(&source)
        source.plannedMoveDestination = destinationKey
        state.days[sourceKey] = source; state.days[destinationKey] = destination
        state.deletedExerciseIDs = Array(Set((state.deletedExerciseIDs ?? []) + oldIDs)).sorted()
        var changed = Set([sourceKey, destinationKey])
        for original in [source.planCycle, destination.planCycle].compactMap({ $0 }) {
            var cycle = original
            cycle.plannedDates = cycle.dates.filter { !(state.days[$0]?.exercises.isEmpty ?? true) }
            for key in cycle.dates { state.days[key, default: DayLog()].planCycle = cycle; changed.insert(key) }
        }
        if persist(changedDates: Array(changed)) { return true }
        state = previous; return false
    }

    var archivableMonths: [String] {
        let current = String(ClubDates.key(Date()).prefix(7))
        return Set(state.days.keys.map { String($0.prefix(7)) }).filter { $0 < current }.sorted()
    }
    var exportableMonths: [String] { Set(state.days.keys.map { String($0.prefix(7)) }).sorted(by: >) }
    func exportMonth(_ month: String, includePhotos: Bool = true) async throws -> URL {
        guard let userID = activeAccountID, exportableMonths.contains(month) else { throw CloudSyncError.message("请选择有记录的月份。") }
        let ticket = generation
        let monthDays = state.days.filter { $0.key.hasPrefix(month+"-") }.mapValues { day in
            var copy = day
            copy.weeklyReview = copy.weeklyReview.map { WeeklyVersions.monthCopy($0, month: month) }
            copy.weeklyReviewHistory = copy.weeklyReviewHistory?.map { WeeklyVersions.monthCopy($0, month: month) }
            return copy
        }
        let monthJobs = (aiService?.cloudJobs() ?? []).filter { $0.request.date.hasPrefix(month+"-") && $0.status == "succeeded" }.map { job in
            var copy = job; copy.request.payload = [:]
            if var result = copy.result {
                let monthSessions = result.sessions?.filter { $0.date.hasPrefix(month+"-") }
                result.sessions = monthSessions
                copy.result = result
            }
            copy.digest = "exported-result/" + copy.id
            return copy
        }
        let referencedCustom = Set(monthDays.values.flatMap(\.exercises).compactMap(\.customExerciseID))
        let records = MonthExport(month: month, days: monthDays, aiJobs: monthJobs,
            customExercises: customExercises.filter { referencedCustom.contains($0.id) },
            deletedCustomExerciseIDs: state.deletedCustomExerciseIDs)
        let comparison = try JSONEncoder().encode(records)
        let meals = records.days.values.flatMap(\.meals)
        var photoFiles: [String: URL] = [:]
        let expectedPhotos = Set(meals.compactMap(\.photoFilename))
        if includePhotos {
            for meal in meals {
                if let file = photoFile(for: meal), let name = meal.photoFilename { photoFiles[name] = file }
            }
        }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("boji-export-"+UUID().uuidString+".json")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let writtenPhotos = try await Task.detached(priority: .utility) {
            guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.protectionKey: FileProtectionType.complete]) else { throw CloudSyncError.message("导出文件无法创建。") }
            let handle = try FileHandle(forWritingTo: temporary); defer { try? handle.close() }
            try handle.write(contentsOf: Data("{\"format\":\"BojiClubMonthExport3\",\"accountID\":\(userID),\"records\":".utf8))
            try handle.write(contentsOf: comparison)
            try handle.write(contentsOf: Data(",\"photos\":{".utf8))
            var written = 0
            for name in photoFiles.keys.sorted() {
                try Task.checkCancellation()
                guard let file = photoFiles[name],
                      let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                      size <= 4 * 1024 * 1024,
                      let photo = try? Data(contentsOf: file), photo.count <= 4 * 1024 * 1024,
                      RecordPhoto.isValidJPEG(photo) else { continue }
                let keyData = try JSONEncoder().encode(name), photoData = try JSONEncoder().encode(photo.base64EncodedString())
                if try handle.offset() + UInt64(keyData.count + photoData.count + 32) > 120 * 1024 * 1024 { continue }
                if written > 0 { try handle.write(contentsOf: Data(",".utf8)) }
                try handle.write(contentsOf: keyData); try handle.write(contentsOf: Data(":".utf8))
                try handle.write(contentsOf: photoData); written += 1
            }
            try handle.write(contentsOf: Data("},\"omittedPhotos\":\(expectedPhotos.count - written)}".utf8)); try handle.synchronize()
            return written
        }.value
        guard ticket == generation, activeAccountID == userID, !Task.isCancelled else { throw CancellationError() }
        var folder = directory.appendingPathComponent("exports-user-\(userID)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
        var values = URLResourceValues(); values.isExcludedFromBackup = true; try folder.setResourceValues(values)
        let destination = folder.appendingPathComponent("BojiClub-\(month)-\(UUID().uuidString.prefix(8)).json")
        try FileManager.default.moveItem(at: temporary, to: destination)
        let omitted = expectedPhotos.count - writtenPhotos
        exportNotice = omitted > 0 ? "文字、训练、体重和分析已导出；有 \(omitted) 张照片未包含（未选照片、缺失、无法读取或超出单文件容量）。原照片没有被删除。" : "该月记录与可用照片已导出。"
        exportedMonth = (month,destination,comparison)
        return destination
    }
    /// Restores missing dates only. Existing edits and explicit deletion markers win.
    func importMonth(_ url: URL) async throws -> String {
        guard let userID = activeAccountID, canSave else { throw CloudSyncError.message("请登录并等待本机记录恢复后再导入。") }
        let ticket = generation
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let backup = try await Task.detached(priority: .utility) {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, size <= 128 * 1024 * 1024 else { throw CloudSyncError.message("请选择不超过 128 MB 的月度备份。") }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard data.count <= 128 * 1024 * 1024 else { throw CloudSyncError.message("备份过大。") }
            let value = try JSONDecoder().decode(MonthBackup.self, from: data)
            try validateBackupValue(JSONValue.encode(value.records))
            guard ["BojiClubMonthExport2", "BojiClubMonthExport3"].contains(value.format),
                  value.format != "BojiClubMonthExport3" || value.accountID == userID,
                  value.accountID == nil || value.accountID == userID,
                  ClubDates.date(fromKey: value.records.month + "-01") != nil,
                  value.records.days.count <= 31, value.photos.count <= 1550,
                  value.records.aiJobs.count <= 1000,
                   (value.records.customExercises?.count ?? 0) <= 200,
                   Set((value.records.customExercises ?? []).map(\.id)).count == (value.records.customExercises?.count ?? 0),
                   (value.records.customExercises ?? []).allSatisfy(\.valid),
                   (value.records.deletedCustomExerciseIDs ?? []).allSatisfy({ UUID(uuidString: $0) != nil }) else { throw CloudSyncError.message("备份格式不支持，或它属于其他账号。") }
            for (date, day) in value.records.days {
                guard date.hasPrefix(value.records.month + "-"), ClubDates.date(fromKey: date) != nil,
                      day.health == nil || day.health?.date == date,
                      day.weeklyReviews.allSatisfy({ $0.date == date }),
                      day.exercises.count <= 30, day.meals.count <= 50,
                      day.bodyWeight?.isValid != false,
                      Set(day.exercises.map(\.id)).count == day.exercises.count,
                      Set(day.meals.map(\.id)).count == day.meals.count,
                      day.exercises.allSatisfy({ !$0.name.isEmpty && $0.name.count <= 100 && $0.sets.count <= 50 && Set($0.sets.map(\.id)).count == $0.sets.count && $0.sets.allSatisfy { RecordLimits.valid($0) } }),
                      day.meals.allSatisfy({ !$0.name.isEmpty && $0.name.count <= 100 && RecordLimits.valid($0) }) else { throw CloudSyncError.message("备份中的日期或记录不完整，请使用原始导出文件。") }
            }
            try Task.checkCancellation()
            return value
        }.value
        try checkContext(ticket, userID)
        try Task.checkCancellation()
        let previous = state
        let deletedExercises = Set(state.deletedExerciseIDs ?? [])
        let deletedMeals = Set(state.deletedMealIDs ?? [])
        let deletedMedia = Set((state.deletedMediaIDs ?? []).map { $0.lowercased() })
        var added: [String] = []; var createdPhotos: [URL] = []; var missingPhotos = 0; var restoredCustom = 0
        do {
            let recovered = CustomBackupRules.recover(backup.records.customExercises ?? [],
                into: state.customExercises ?? [], deleted: (state.deletedCustomExerciseIDs ?? []) + (backup.records.deletedCustomExerciseIDs ?? []))
            restoredCustom = recovered.count - (state.customExercises?.count ?? 0)
            guard recovered.count <= 200 else { throw CloudSyncError.message("恢复后个人动作将超过 200 项，请先整理动作库。原记录已保留。") }
            if restoredCustom > 0 { state.customExercises = recovered }
            for date in backup.records.days.keys.sorted() where state.days[date] == nil {
                guard var day = backup.records.days[date] else { continue }
                day.exercises.removeAll { deletedExercises.contains($0.id.uuidString) }
                day.meals.removeAll { deletedMeals.contains($0.id.uuidString) }
                for index in day.meals.indices {
                    let original = day.meals[index].photoFilename
                    day.meals[index].photoFilename = nil; day.meals[index].photoRemoteID = nil
                    guard let original else { continue }
                    guard validMediaID(original), !deletedMedia.contains(original.lowercased()),
                          let encoded = backup.photos[original], encoded.utf8.count <= 6 * 1024 * 1024,
                          let data = Data(base64Encoded: encoded), data.count <= 4 * 1024 * 1024,
                          let source = CGImageSourceCreateWithData(data as CFData, nil),
                          CGImageSourceGetCount(source) > 0,
                          let sourceType = CGImageSourceGetType(source), sourceType as String == "public.jpeg",
                          let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                          let width = props[kCGImagePropertyPixelWidth] as? Int,
                          let height = props[kCGImagePropertyPixelHeight] as? Int,
                          width > 0, height > 0, width <= 8192, height <= 8192,
                          width * height <= 20_000_000 else { missingPhotos += 1; continue }
                    let name = UUID().uuidString.lowercased() + ".jpg"
                    try prepareMediaDirectory()
                    let file = mediaDirectory.appendingPathComponent(name)
                    try data.write(to: file, options: [.atomic, .completeFileProtection])
                    createdPhotos.append(file); day.meals[index].photoFilename = name
                }
                WeeklyVersions.restore(&day, deletedJobIDs: Set(state.deletedAIJobIDs ?? []))
                state.days[date] = day; added.append(date)
            }
            guard state.days.count <= 3660 else { throw CloudSyncError.message("导入后将超过记录容量上限，请先联系支持。") }
            if (!added.isEmpty || restoredCustom > 0) && !persist(changedDates: added) { throw CloudSyncError.message(message ?? "记录保存失败，请重试。") }
        } catch {
            state = previous
            for file in createdPhotos { try? FileManager.default.removeItem(at: file) }
            throw error
        }
        let existingJobs = aiService?.cloudJobs() ?? []
        let existingIDs = Set(existingJobs.map(\.id)).union(state.deletedAIJobIDs ?? [])
        let recoveredJobs = backup.records.aiJobs.filter {
            UUID(uuidString: $0.id) != nil && !existingIDs.contains($0.id) && $0.status == "succeeded" && $0.result != nil &&
            $0.request.date.hasPrefix(backup.records.month + "-") && ClubDates.date(fromKey: $0.request.date) != nil
        }.map { job in
            var copy = job; copy.request.payload = [:]; copy.consumed = true
            copy.digest = "restored-result/" + copy.id
            return copy
        }
        var reportsSaved = true
        if !recoveredJobs.isEmpty {
            reportsSaved = aiService?.replaceCloudJobs(existingJobs + recoveredJobs) == true
            scheduleCloudSync()
        }
        return "已补回 \(added.count) 天记录、\(restoredCustom) 项个人动作，已有日期和手动删除的内容没有覆盖。" + (missingPhotos > 0 ? "有 \(missingPhotos) 张照片缺失，文字记录已保留。" : "") + (reportsSaved ? "" : "AI 报告暂未保存，请保留备份并再次导入。")
    }
    func archiveMonth(_ month: String, backup: URL) -> Bool {
        message = "当前版本暂不提供删除式归档。导出不会移除记录，请另存备份。"
        return false
    }
    func exportConflict() throws -> URL {
        guard let id = activeAccountID else { throw CloudSyncError.message("请先登录。") }
        let source = fileURL.appendingPathExtension("conflict")
        guard FileManager.default.fileExists(atPath: source.path) else { throw CloudSyncError.message("暂无同时修改的备份。") }
        var folder = directory.appendingPathComponent("exports-user-\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
        var values = URLResourceValues(); values.isExcludedFromBackup = true; try folder.setResourceValues(values)
        let destination = folder.appendingPathComponent("BojiClub-other-device-"+UUID().uuidString+".json")
        try FileManager.default.copyItem(at: source, to: destination); return destination
    }

    func continuationSessions(starting start: Date, ending end: Date, nextStart: Date) -> [AIPlanSession] {
        let today = ClubDates.calendar.startOfDay(for: Date())
        let sourceDates = PlanContinuationRules.sourceDates(start: start, end: end)
        return sourceDates.enumerated().compactMap { offset, from in
            guard let to = ClubDates.calendar.date(byAdding: .day, value: offset, to: nextStart), to >= today else { return nil }
            let exercises = log(for: from).exercises
            guard !exercises.isEmpty else { return nil }
            return AIPlanSession(date: ClubDates.key(to), label: "延续 \(ClubDates.label(from)) 的安排", exercises: exercises.map {
                AIPlanExercise(name: $0.name, muscle: $0.muscle, sets: $0.sets.map { AIPlanSet(weight: $0.weight, reps: $0.reps, durationSeconds: $0.durationSeconds) }, library_query: $0.libraryQuery, library_id: $0.libraryID, custom_id: $0.customExerciseID, custom_unit: $0.customUnit, rest_seconds: $0.restSeconds)
            })
        }
    }

    @discardableResult
    func addMeal(_ meal: Meal, photo: Data?, on date: Date, handledAIJobIDs: [String] = []) -> Bool {
        guard !ClubDates.isFuture(date) else { message = "饮食只能记录今天或过去日期。"; return false }
        guard !log(for: date).meals.contains(where: { $0.id == meal.id }), !handledAIJobIDs.contains(where: hasAppliedAIJob) else { message = "这餐或它的识别任务已处理，请查看已有记录。"; return false }
        guard RecordLimits.valid(meal) else { message = "营养数值不正确，请检查后保存。"; return false }
        guard log(for: date).meals.count < 50, !meal.name.isEmpty, meal.name.count <= 100 else { message = "一天最多记录 50 餐，餐食名称需为 1—100 字。"; return false }
        if let id = meal.sourceAIJobID, hasAppliedAIJob(id) {
            message = "这次识别结果已保存，可在饮食记录中查看。"
            return false
        }
        let previous = state
        var meal = meal
        var newPhotoURL: URL?
        if let jobID = meal.sourceAIJobID { meal.id = stableID("meal/\(jobID)") }
        if let photo {
            let filename = UUID().uuidString.lowercased() + ".jpg"
            do {
                try prepareMediaDirectory()
                try photo.write(to: mediaDirectory.appendingPathComponent(filename), options: [.atomic, .completeFileProtection])
                meal.photoFilename = filename
                newPhotoURL = mediaDirectory.appendingPathComponent(filename)
            } catch {
                message = "照片保存失败，饮食数值仍会保存。"
            }
        }
        let key = ClubDates.key(date)
        var log = state.days[key] ?? DayLog()
        log.meals.append(meal)
        state.days[key] = log
        state.appliedAIJobs = Array(Set((state.appliedAIJobs ?? []) + handledAIJobIDs + [meal.sourceAIJobID].compactMap { $0 })).sorted()
        if persist(changedDates: [key]) { enqueueMealRecordIfNeeded(meal, date: date); return true }
        state = previous
        if let newPhotoURL { try? FileManager.default.removeItem(at: newPhotoURL) }
        return false
    }

    func removeMeal(_ id: UUID, on date: Date) {
        let previous = state
        let meal = state.days[ClubDates.key(date)]?.meals.first { $0.id == id }
        let media = [meal?.photoFilename, meal?.photoRemoteID].compactMap { $0 }.filter(validMediaID)
        state.days[ClubDates.key(date)]?.meals.removeAll { $0.id == id }
        state.deletedMealIDs = Array(Set((state.deletedMealIDs ?? []) + [id.uuidString])).sorted()
        let references = Set(state.days.values.flatMap(\.meals).flatMap { [$0.photoFilename, $0.photoRemoteID].compactMap { $0?.lowercased() } })
        state.deletedMediaIDs = Array(Set((state.deletedMediaIDs ?? []) + media.map { $0.lowercased() }.filter { !references.contains($0) })).sorted()
        guard persist(changedDates: [ClubDates.key(date)]) else { state = previous; return }
        cleanupDeletedPhotos()
    }

    private func cleanupUnreferencedMealPhotos() {
        guard canSave else { return }
        guard FileManager.default.fileExists(atPath: mediaDirectory.path) else { mediaCleanupNotice = nil; return }
        let references = Set(state.days.values.flatMap(\.meals).flatMap { [$0.photoFilename, $0.photoRemoteID].compactMap { $0?.lowercased() } })
        do {
            let files = try FileManager.default.contentsOfDirectory(at: mediaDirectory, includingPropertiesForKeys: [.isRegularFileKey])
            var failed = 0
            for file in files where validMediaID(file.lastPathComponent) && !references.contains(file.lastPathComponent.lowercased()) {
                do {
                    guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
                    try FileManager.default.removeItem(at: file)
                } catch { failed += 1 }
            }
            mediaCleanupNotice = failed > 0 ? "有 \(failed) 张已移除的附件尚未从本机清理。请解锁设备后重试。" : nil
        } catch { mediaCleanupNotice = "本机照片清理暂未完成，记录保留。请解锁设备后重试。" }
    }
    private func cleanupDeletedPhotos() { cleanupUnreferencedMealPhotos() }
    func retryPhotoCleanup() { cleanupUnreferencedMealPhotos() }

    func photoFile(for meal: Meal) -> URL? {
        guard let filename = meal.photoFilename, validMediaID(filename) else { return nil }
        let candidates = [mediaDirectory.appendingPathComponent(filename), directory.appendingPathComponent(filename)]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }
    func photoExists(for meal: Meal) -> Bool { photoFile(for: meal).map { RecordPhoto.isValidJPEG(at: $0) } ?? false }
    private func prepareMediaDirectory() throws {
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: mediaDirectory.path)
        var folder = mediaDirectory; var values = URLResourceValues(); values.isExcludedFromBackup = true; try folder.setResourceValues(values)
        let marker = mediaDirectory.appendingPathComponent(".protection-v4-complete")
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        for location in [mediaDirectory,directory] {
            for file in try FileManager.default.contentsOfDirectory(at: location, includingPropertiesForKeys: [.isRegularFileKey,.isSymbolicLinkKey]) where validMediaID(file.lastPathComponent) {
                let properties = try file.resourceValues(forKeys: [.isRegularFileKey,.isSymbolicLinkKey])
                guard properties.isRegularFile == true, properties.isSymbolicLink != true else { continue }
                try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: file.path)
            }
        }
        try Data("v4".utf8).write(to: marker, options: [.atomic,.completeFileProtection])
    }

    func photoData(for meal: Meal) -> Data? {
        guard let filename = meal.photoFilename, validMediaID(filename) else { return nil }
        if let data = try? Data(contentsOf: mediaDirectory.appendingPathComponent(filename)) { return data }
        return try? Data(contentsOf: directory.appendingPathComponent(filename))
    }

    /// base is the meal snapshot the editor opened. Only fields the user
    /// actually changed are written, so a newer value for another field (from
    /// sync or another device) is preserved instead of replaced by a stale
    /// whole-meal snapshot. Passing nil keeps the legacy whole-record behavior.
    func updateMealNutrition(_ edited: Meal, base: Meal? = nil, on date: Date) -> Bool {
        let key = ClubDates.key(date)
        guard RecordLimits.valid(edited) else { message = "营养数值不正确，请检查后保存。"; return false }
        guard !edited.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, edited.name.count <= 100 else { message = "餐食名称需为 1 至 100 字。"; return false }
        guard let index = state.days[key]?.meals.firstIndex(where: { $0.id == edited.id }) else {
            message = "这条饮食记录已被移除，请返回刷新。"
            return false
        }
        let previous = state
        // Preserve the latest cloud photo and AI provenance while editing nutrition.
        let current = state.days[key]!.meals[index]
        state.days[key]?.meals[index] = MealNutritionMerge.merged(edited: edited, base: base, current: current)
        if persist(changedDates: [key]) { return true }
        state = previous
        return false
    }

    @discardableResult
    func savePlanText(_ text: String) -> Bool {
        let clean = String(text.prefix(16000))
        if state.importedPlan == clean { return true }
        let previous = state
        state.importedPlan = clean
        if text.count > 16000 { message = "计划文字最多保存 16000 字，超出部分未保存。请分段导入。" }
        if persist(changedDates: []) { return true }; state = previous; return false
    }

    @discardableResult
    private func mutate(_ date: Date, edit: (inout DayLog) -> Void) -> Bool {
        let previous = state
        let key = ClubDates.key(date)
        var log = state.days[key] ?? DayLog()
        edit(&log)
        let restPreference = (UserDefaults.standard.object(forKey: "training.rest.seconds") as? Int) ?? 60
        TrainingExecutionCapture.capture(before: previous.days[key] ?? DayLog(), after: &log, on: date, restSeconds: restPreference)
        WorkoutSessions.synchronize(&log)
        if log.completedSets == 0 { log.linkedDeviceWorkoutID = nil }
        state.days[key] = log
        // Exercise add/remove changes the cycle's actual training days. Refresh
        // derived plannedDates in the same save transaction (meals/health edits
        // leave the derived value unchanged).
        var changed: Set<String> = [key]
        changed.formUnion(TrainingCycle.refreshPlannedDates(covering: key, in: &state.days))
        guard persist(changedDates: Array(changed)) else { state = previous; return false }
        return true
    }

    private func recordPlanHistory(operationID: String, result: AIResult, start: Date, previous: SavedState,
                                   scope: [String], source: String? = nil, requestedJobID: String? = nil) {
        let origin = source ?? ((aiService?.job(operationID)?.request.kind == "parse_plan") ? "manual" : (operationID.hasPrefix("manual-plan-") || operationID.hasPrefix("coach-plan-")) ? "manual" : aiService?.job(operationID) == nil ? "continuation" : "ai")
        ClubHistoryRules.recordPlan(days: &state.days, previous: previous.days, operationID: operationID,
            result: result, start: start, source: origin, requestedProfile: historyProfile(jobID: requestedJobID ?? operationID),
            adoptedProfile: state.profile, nutrition: state.nutritionTarget ?? NutritionTarget.estimate(state.profile), scope: scope)
    }

    private func recordWeeklyPlanHistory(review: WeeklyReview, sessions: [AIPlanSession], previous: SavedState, start: Date, scope: [String]) {
        let result = AIResult(kind: "plan", notes: [], title: "根据周复盘调整的训练计划", sessions: sessions, plan_days: 7)
        recordPlanHistory(operationID: "weekly/" + review.id.uuidString, result: result, start: start,
            previous: previous, scope: scope, source: "weekly_review", requestedJobID: review.jobID)
    }

    func refreshClubInsights(now: Date = Date()) {
        guard editingAccountID != nil, canSave else { return }
        let today = ClubDates.key(now)
        let expired = state.days.keys.filter { key in
            key < today && ClubInsightLedger.leaves(state.days[key]?.insightEvents ?? []).contains {
                $0.isTodayReminder && $0.state == .active
            }
        }
        let previous = state
        let changed = ClubInsightLedger.reconcile(state: &state, dates: [today] + expired, now: now)
        guard !changed.isEmpty else { return }
        if !persist(changedDates: changed) { state = previous }
    }

    @discardableResult
    func giveInsightFeedback(kind: ClubInsightKind, action: ClubInsightFeedbackAction, eventID: String? = nil,
                             expectedOwner: Int, now: Date = Date()) -> Bool {
        guard editingAccountID == expectedOwner, canSave else { message = "账号状态已变化，请重新打开跟进。"; return false }
        guard kind.supported else { message = "当前版本暂不能修改这类跟进，请更新后重试。"; return false }
        if [ClubInsightFeedbackAction.helpful, .read, .unread, .archive, .unarchive].contains(action), !ClubInsightLedger.events(in: state).contains(where: { $0.id == eventID && $0.kind == kind }) {
            message = "这条跟进已不可用，请重新打开。"; return false
        }
        let previous = state
        guard let key = ClubInsightLedger.recordFeedback(state: &state, kind: kind, action: action, eventID: eventID, now: now) else { return true }
        if persist(changedDates: [key]) { return true }
        state = previous; return false
    }

    private func historyProfile(jobID: String?) -> MemberProfile {
        guard let jobID, let value = aiService?.job(jobID)?.request.payload["profile"],
              let data = try? JSONEncoder().encode(value),
              let profile = try? JSONDecoder().decode(MemberProfile.self, from: data) else { return state.profile }
        return profile
    }

    @discardableResult
    private func persist(changedDates: [String]) -> Bool {
        guard canSave else {
            message = "这次修改还没有保存，关闭 App 后可能丢失。请先保留当前内容，再尝试保存。"
            return false
        }
        let historyNow = Date()
        let previousDays = state.days
        let goalProfile = state.profile.aiProfile
        let goalNutrition = state.nutritionTarget ?? NutritionTarget.estimate(state.profile)
        do {
            var dates = Set(changedDates)
            if recordedGoalProfile != goalProfile || recordedGoalNutrition != goalNutrition {
                if let key = ClubHistoryRules.recordGoal(days: &state.days, profile: goalProfile,
                    nutrition: goalNutrition, now: historyNow) { dates.insert(key) }
            }
            for key in dates {
                if var day = state.days[key] { WorkoutSessions.synchronize(&day); state.days[key] = day }
            }
            dates.formUnion(ClubInsightLedger.reconcile(state: &state, dates: Array(dates), now: historyNow))
            try appendJournal(changedDates: Array(dates).sorted())
            recordedGoalProfile = goalProfile; recordedGoalNutrition = goalNutrition
            localEditRevision = UUID()
            dirty = true; publishWidgetSnapshot()
            aiService?.invalidateDomainQueries()
            scheduleSync(after: 1.2)
            return true
        } catch {
            // Keep history transactional with the record edit; callers restore
            // their own original state when persistence fails.
            state.days = previousDays
            message = "记录未能保存。\(AppErrorText.message(error, fallback: "请重试；如仍无法保存，请检查手机存储空间。"))"
            return false
        }
    }


    private func scheduleSync(after seconds: Double) {
        guard accountService != nil, activeAccountID != nil else { return }
        if syncInProgress { needsAnotherSync = true; return }
        if dirty { syncStatus = .pending }
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            catch { return }
            guard let self, !Task.isCancelled else { return }
            await self.syncNow()
        }
    }

    private func scheduleMediaSync(_ account: AccountService, userID: Int, ticket: UUID) {
        guard mediaSyncTask == nil, generation == ticket, activeAccountID == userID else { return }
        let pending = state.days.values.reduce(0) { total, day in
            total + day.meals.filter { meal in
                meal.photoFilename != nil && (meal.photoRemoteID == nil || !photoExists(for: meal))
            }.count
        }
        guard pending > 0 else { photosNeedDownload = false; mediaSyncMessage = nil; return }
        mediaSyncMessage = "记录与照片分开同步 · 还有 \(pending) 张照片待处理"
        mediaSyncTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.generation == ticket {
                    self.mediaSyncTask = nil
                    if self.dirty { self.scheduleSync(after: 1.2) }
                }
            }
            do {
                try await self.uploadPendingPhotos(account, userID: userID, ticket: ticket)
                try self.checkContext(ticket, userID)
                try await self.downloadMissingPhotos(account, userID: userID, ticket: ticket)
                try self.checkContext(ticket, userID)
                self.photosNeedDownload = false
                let remaining = self.state.days.values.reduce(0) { total, day in
                    total + day.meals.filter { $0.photoFilename != nil && ($0.photoRemoteID == nil || !self.photoExists(for: $0)) }.count
                }
                self.mediaSyncMessage = remaining == 0 ? nil : "记录已保留 · \(remaining) 张照片等待联网或重试"
            } catch {
                guard self.generation == ticket, self.activeAccountID == userID else { return }
                self.mediaSyncMessage = "照片暂未同步，原照片保留在本机；联网后继续。"
            }
        }
    }

    private func snapshot(includeLocalPhotos: Bool = false) -> CloudState {
        var copy = state
        if !includeLocalPhotos {
            for key in copy.days.keys {
                guard var day = copy.days[key] else { continue }
                for index in day.meals.indices where day.meals[index].photoRemoteID == nil { day.meals[index].photoFilename = nil }
                copy.days[key] = day
            }
        }
        return CloudState(copy, aiJobs: (aiService?.cloudJobs() ?? []).filter { !(state.deletedAIJobIDs ?? []).contains($0.id) })
    }

    private func stableID(_ key: String) -> UUID {
        let hex = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        let value = "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20).prefix(12))"
        return UUID(uuidString: value)!
    }

    private func checkContext(_ ticket: UUID, _ userID: Int) throws {
        try Task.checkCancellation()
        guard generation == ticket, activeAccountID == userID, accountService?.user?.id == userID else {
            throw CancellationError()
        }
    }

    private struct JournalEntry: Codable { var sequence: Int; var state: SavedState }
    private func appendJournal(changedDates: [String]) throws {
        var fragment = state
        fragment.days = Dictionary(uniqueKeysWithValues: Set(changedDates).map { ($0, state.days[$0] ?? DayLog()) })
        let entry = JournalEntry(sequence: journalSequence + 1, state: fragment)
        var data = try JSONEncoder().encode(entry); data.append(10)
        if !FileManager.default.fileExists(atPath: journalURL.path) {
            guard FileManager.default.createFile(atPath: journalURL.path, contents: nil, attributes: [.protectionKey: FileProtectionType.complete]) else { throw CloudSyncError.message("记录文件无法创建。") }
        }
        var journal = journalURL; var values = URLResourceValues(); values.isExcludedFromBackup = true; try journal.setResourceValues(values)
        let handle = try FileHandle(forWritingTo: journalURL); defer { try? handle.close() }
        let offset = try handle.seekToEnd()
        do { try handle.write(contentsOf: data); try handle.synchronize() }
        catch { try? handle.truncate(atOffset: offset); throw error }
        journalSequence = entry.sequence
        if offset + UInt64(data.count) > 8 * 1024 * 1024 {
            do { try persistLocalOnly(); try handle.truncate(atOffset: 0) }
            catch { message = "修改已保存在本机，记录整理稍后重试。" }
        }
    }
    private func replayJournal(after sequence: Int) throws {
        journalSequence = sequence
        guard FileManager.default.fileExists(atPath: journalURL.path) else { return }
        let data = try Data(contentsOf: journalURL)
        let scanned = JournalScanner.scan(data, as: JournalEntry.self)
        var candidate = state, last = sequence, bad = scanned.unreadableLines.count
        for entry in scanned.entries {
            guard entry.sequence > 0, entry.state.version == 1 else { bad += 1; continue }
            guard entry.sequence > sequence else { continue }
            guard entry.sequence > last else { bad += 1; continue }
            let days = candidate.days.merging(entry.state.days) { _, new in new }
            candidate = entry.state; candidate.days = days; last = entry.sequence
        }
        if bad > 0 {
            // Do not partially replace the live checkpoint or modify the damaged file.
            recoveryCandidate = candidate; recoverySequence = last; canSave = false; freshInstall = false
            localRecovery = LocalRecoverySummary(readableEntries: scanned.entries.count, unreadableEntries: bad,
                snapshotReadable: true, detail: "保存日志有 \(bad) 条无法读取。已保留原文件，并整理了其余可读取内容；请核对后选择恢复方式。无法读取的条目可能包含尚未同步的修改。")
            message = "本机记录需要恢复，请打开“记录修复”，不要重装 App。"
            return
        }
        if scanned.hasIncompleteTail {
            let backup = journalURL.appendingPathExtension("interrupted-" + UUID().uuidString)
            try data.write(to: backup, options: [.atomic, .completeFileProtection])
            let handle = try FileHandle(forWritingTo: journalURL); defer { try? handle.close() }
            try handle.truncate(atOffset: UInt64(scanned.committedBytes)); try handle.synchronize()
            message = "上次保存被打断，已保留原文件并恢复此前记录。请核对最后一次修改。"
        }
        state = candidate; journalSequence = last
        if last > sequence { freshInstall = false; dirty = true }
    }

    func retryLocalRecords() -> Bool {
        guard activeAccountID != nil else { return false }
        do {
            canSave = true; try loadCurrentFile()
            guard canSave else { return false }
            message = nil; publishWidgetSnapshot(); scheduleCloudSync(); return true
        } catch { canSave = false; message = "仍无法读取，原文件已保留。请先导出或选择恢复方式。"; return false }
    }

    func exportRecoveryFiles() throws -> URL {
        guard let id = activeAccountID else { throw CloudSyncError.message("请先登录。") }
        var files: [String: String] = [:]
        for url in [fileURL, journalURL, fileURL.appendingPathExtension("recovery-pending")] where FileManager.default.fileExists(atPath: url.path) {
            files[url.lastPathComponent] = try Data(contentsOf: url).base64EncodedString()
        }
        let folder = directory.appendingPathComponent("exports-user-\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
        let destination = folder.appendingPathComponent("BojiClub-recovery-" + UUID().uuidString + ".json")
        try JSONEncoder().encode(files).write(to: destination, options: [.atomic, .completeFileProtection])
        return destination
    }

    func restoreReadableRecords() throws {
        guard let id = activeAccountID, let candidate = recoveryCandidate, localRecovery?.snapshotReadable == true else {
            throw CloudSyncError.message("没有可直接恢复的本机记录，请导出原文件或尝试云端恢复。")
        }
        let envelope = LocalSyncEnvelope(state: candidate, base: cloudBase, cloudRevision: cloudRevision, journalSequence: recoverySequence)
        try LocalRecoveryTransaction.commit(JSONEncoder().encode(envelope), accountID: id, recordURL: fileURL)
        state = candidate; journalSequence = recoverySequence; canSave = true; freshInstall = false; dirty = true
        localRecovery = nil; recoveryCandidate = nil; message = nil
        publishWidgetSnapshot(); scheduleCloudSync()
    }

    func restoreCloudRecords() async throws {
        guard let id = activeAccountID, let account = accountService, account.user?.id == id else { throw CloudSyncError.message("请先登录并连接网络。") }
        let ticket = generation
        let response = try await CloudPartitionClient.read(account: account, userID: id, knownRevision: nil, cache: cloudPartitionCache)
        try checkContext(ticket, id)
        guard response.statusCode == 200 else { throw cloudError(response.http) }
        guard let remote = response.envelope, remote.unchanged != true else {
            throw CloudSyncError.message("云端恢复记录尚未读取完整，请重试；原文件已保留。")
        }
        guard let saved = remote.state, saved.savedState().version == 1 else { throw CloudSyncError.message("云端暂无可恢复记录，原文件已保留。") }
        let envelope = LocalSyncEnvelope(state: saved.savedState(), base: saved, cloudRevision: remote.revision, journalSequence: 0)
        try LocalRecoveryTransaction.commit(JSONEncoder().encode(envelope), accountID: id, recordURL: fileURL)
        state = saved.savedState(); cloudBase = saved; cloudRevision = remote.revision; journalSequence = 0
        canSave = true; freshInstall = false; dirty = false; localRecovery = nil; recoveryCandidate = nil; message = nil
        aiService?.replaceCloudJobs(saved.aiJobs ?? []); photosNeedDownload = true
        publishWidgetSnapshot(); scheduleCloudSync()
    }

    private func checkpoint(ticket: UUID, userID: Int) async throws {
        let sequence = journalSequence
        let writeTicket = snapshotWriteGeneration
        let saved = LocalSyncEnvelope(state: state, base: cloudBase, cloudRevision: cloudRevision, journalSequence: sequence)
        let data = try await Task.detached(priority: .utility) { try JSONEncoder().encode(saved) }.value
        try checkContext(ticket, userID)
        guard writeTicket == snapshotWriteGeneration else { needsAnotherSync = true; return }
        try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
        // Edits made while encoding remain in the journal and are replayed after this checkpoint.
        if journalSequence == sequence, FileManager.default.fileExists(atPath: journalURL.path) {
            let handle = try FileHandle(forWritingTo: journalURL); defer { try? handle.close() }
            try? handle.truncate(atOffset: 0)
        }
        publishWidgetSnapshot()
    }

    private func persistLocalOnly() throws {
        guard canSave else { throw CloudSyncError.message("本地记录不可用，暂时无法同步。") }
        let envelope = LocalSyncEnvelope(state: state, base: cloudBase, cloudRevision: cloudRevision, journalSequence: journalSequence)
        try JSONEncoder().encode(envelope).write(to: fileURL, options: [.atomic, .completeFileProtection])
        snapshotWriteGeneration = UUID()
        publishWidgetSnapshot()
    }

    func publishWidgetSnapshot(now: Date = Date()) {
        let shared = UserDefaults(suiteName: "group.com.bojiclub.shared")
        guard activeAccountID != nil else {
            shared?.removeObject(forKey: "training.snapshot")
            shared?.removeObject(forKey: "training.snapshots.v2")
            WidgetCenter.shared.reloadAllTimelines()
            return
        }
        let old = shared?.data(forKey: "training.snapshots.v2").flatMap { try? JSONDecoder().decode(TrainingWidgetCache.self,from:$0) }
        let today=now
        let snapshots=(0..<8).compactMap { offset -> TrainingWidgetSnapshot? in
            guard let dayDate=ClubDates.calendar.date(byAdding:.day,value:offset,to:today) else { return nil }
            let date=ClubDates.key(dayDate);let day=state.days[date] ?? DayLog()
            var value=TrainingWidgetSnapshot(date:date,workoutName:day.exercises.first?.displayName ?? "今天还没有训练计划",completedSets:day.completedSets,totalSets:day.totalSets,calories:day.calories,protein:day.protein,mealCount:day.meals.count,updatedAt:today)
            value.knownMealCount=day.knownMeals.count
            if ClubDates.isFuture(dayDate,now:today) {
                value.completedSets=0;value.calories=0;value.protein=0;value.mealCount=0;value.knownMealCount=0
            }
            if let previous=old?.snapshots.first(where:{$0.date==date}) {
                value.updatedAt=previous.updatedAt
                if value != previous { value.updatedAt=today }
            }
            return value
        }
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        guard let data=try? encoder.encode(TrainingWidgetCache(snapshots:snapshots)),data != shared?.data(forKey:"training.snapshots.v2") else { return }
        shared?.set(data,forKey:"training.snapshots.v2")
        if let current=snapshots.first,let legacy=try? encoder.encode(current) { shared?.set(legacy,forKey:"training.snapshot") }
        WidgetCenter.shared.reloadAllTimelines()

    }

    private func validMediaID(_ value: String) -> Bool {
        value.range(of: #"^[0-9a-fA-F-]{36}\.jpg$"#, options: .regularExpression) != nil
    }

    private func notePhotoIssue(_ day: String, _ meal: Meal, _ detail: String) {
        let issue = PhotoSyncIssue(dateKey: day, mealID: meal.id, mealName: meal.name, detail: detail)
        photoSyncIssues.removeAll { $0.id == issue.id }; photoSyncIssues.append(issue)
        photoRetryDates[issue.id] = Date().addingTimeInterval(300)
    }
    private func clearPhotoIssue(_ day: String, _ meal: Meal) {
        let key = day + "/" + meal.id.uuidString
        photoSyncIssues.removeAll { $0.id == key }; photoRetryDates.removeValue(forKey: key)
    }
    func retryPhotos() {
        photoRetryDates = [:]; photosNeedDownload = true; scheduleSync(after: 0)
    }
    func removeBrokenPhoto(_ issue: PhotoSyncIssue) -> Bool {
        guard canSave, let index = state.days[issue.dateKey]?.meals.firstIndex(where: { $0.id == issue.mealID }) else { return false }
        let old = state
        let remote = state.days[issue.dateKey]?.meals[index].photoRemoteID
        state.days[issue.dateKey]?.meals[index].photoFilename = nil; state.days[issue.dateKey]?.meals[index].photoRemoteID = nil
        if let remote, !state.days.values.contains(where: { $0.meals.contains(where: { $0.photoRemoteID == remote }) }) {
            state.deletedMediaIDs = Array(Set((state.deletedMediaIDs ?? []) + [remote]))
        }
        guard persist(changedDates: [issue.dateKey]) else { state = old; return false }
        photoSyncIssues.removeAll { $0.id == issue.id }; photoRetryDates.removeValue(forKey: issue.id)
        cleanupUnreferencedMealPhotos(); photoChangeID = UUID(); return true
    }
    func replaceBrokenPhoto(_ issue: PhotoSyncIssue, data: Data) async throws {
        guard let user = activeAccountID else { throw CloudSyncError.message("请先登录。") }
        let ticket = generation
        let compressed = await Task.detached(priority: .utility) { RecordPhoto.jpeg(data) }.value
        try checkContext(ticket, user)
        guard canSave, let jpeg = compressed, let index = state.days[issue.dateKey]?.meals.firstIndex(where: { $0.id == issue.mealID }) else { throw CloudSyncError.message("照片无法读取或记录已改变，请重新选择。") }
        try prepareMediaDirectory()
        let name = UUID().uuidString.lowercased() + ".jpg", old = state
        let file = mediaDirectory.appendingPathComponent(name)
        try jpeg.write(to: file, options: [.atomic, .completeFileProtection])
        let remote = state.days[issue.dateKey]?.meals[index].photoRemoteID
        state.days[issue.dateKey]?.meals[index].photoFilename = name; state.days[issue.dateKey]?.meals[index].photoRemoteID = nil
        if let remote, !state.days.values.contains(where: { $0.meals.contains(where: { $0.photoRemoteID == remote }) }) { state.deletedMediaIDs = Array(Set((state.deletedMediaIDs ?? []) + [remote])) }
        guard persist(changedDates: [issue.dateKey]) else { state = old; try? FileManager.default.removeItem(at: file); throw CloudSyncError.message(takeMessage()) }
        photoSyncIssues.removeAll { $0.id == issue.id }; photoRetryDates.removeValue(forKey: issue.id)
        cleanupUnreferencedMealPhotos(); photoChangeID = UUID()
    }
    private func uploadPendingPhotos(_ account: AccountService, userID: Int, ticket: UUID) async throws {
        let photos = state.days.flatMap { date, log in log.meals.map { (date, $0) } }
        for (day, meal) in photos {
            try checkContext(ticket, userID)
            guard meal.photoRemoteID == nil, let filename = meal.photoFilename else { continue }
            let key = day + "/" + meal.id.uuidString
            if let retry = photoRetryDates[key], retry > Date() { continue }
            do {
                guard validMediaID(filename), let photo = photoData(for: meal) else { throw CloudSyncError.message("照片在本机缺失，可以重新选图或只保留文字记录。") }
                guard photo.count <= 4 * 1024 * 1024, photo.starts(with: [0xff,0xd8,0xff]), RecordPhoto.isValidJPEG(photo) else { throw CloudSyncError.message("照片过大或损坏，请重新选图；选择后会自动压缩。") }
                let response = try await account.cloudRequest(path: "/me/media/\(filename.lowercased())", method: "PUT", body: photo, contentType: "image/jpeg", expectedUserID: userID)
                try checkContext(ticket, userID)
                if response.statusCode == 429 { notePhotoIssue(day, meal, "照片上传较密集，稍后重试；文字记录会继续同步。"); return }
                guard response.statusCode == 200 else { throw cloudError(response) }
                if let index = state.days[day]?.meals.firstIndex(where: { $0.id == meal.id }), state.days[day]?.meals[index].photoFilename == filename, state.days[day]?.meals[index].photoRemoteID == nil {
                    let previous = state
                    state.days[day]?.meals[index].photoRemoteID = filename.lowercased()
                    do { try appendJournal(changedDates: [day]); dirty = true }
                    catch { state = previous; throw error }
                    clearPhotoIssue(day, meal)
                }
            } catch is CancellationError { throw CancellationError() }
              catch {
                  try checkContext(ticket, userID); notePhotoIssue(day, meal, AppErrorText.message(error))
                  if let network = error as? URLError, [.notConnectedToInternet, .networkConnectionLost, .timedOut].contains(network.code) { return }
              }
        }
    }
    private func downloadMissingPhotos(_ account: AccountService, userID: Int, ticket: UUID) async throws {
        try prepareMediaDirectory()
        let photos = state.days.flatMap { day, log in log.meals.map { (day, $0) } }
        for (day, meal) in photos {
            try checkContext(ticket, userID)
            guard let remoteID = meal.photoRemoteID, let filename = meal.photoFilename, !photoExists(for: meal) else { continue }
            let key = day + "/" + meal.id.uuidString
            if let retry = photoRetryDates[key], retry > Date() { continue }
            do {
                guard validMediaID(remoteID), validMediaID(filename) else { throw CloudSyncError.message("图片标识无法读取，请重新选图。") }
                let response = try await account.cloudRequest(path: "/me/media/\(remoteID.lowercased())", expectedUserID: userID)
                try checkContext(ticket, userID)
                guard response.statusCode == 200 else { throw cloudError(response) }
                guard response.data.count <= 4 * 1024 * 1024, RecordPhoto.isValidJPEG(response.data) else { throw CloudSyncError.message("下载的照片无法读取，可以重试或重新选图。") }
                guard state.days[day]?.meals.contains(where: { $0.id == meal.id && $0.photoRemoteID == remoteID && $0.photoFilename == filename }) == true else { continue }
                try response.data.write(to: mediaDirectory.appendingPathComponent(filename), options: [.atomic, .completeFileProtection])
                clearPhotoIssue(day, meal); photoChangeID = UUID()
            } catch is CancellationError { throw CancellationError() }
              catch {
                  try checkContext(ticket, userID); notePhotoIssue(day, meal, AppErrorText.message(error))
                  if let network = error as? URLError, [.notConnectedToInternet, .networkConnectionLost, .timedOut].contains(network.code) { return }
              }
        }
    }

    private func cloudError(_ response: AccountRawResponse) -> Error {
        let text = (try? JSONDecoder().decode(CloudErrorEnvelope.self, from: response.data))?.error
        if response.statusCode == 401 { return CloudSyncError.message("登录已过期，请重新登录后同步。本机记录已保留。") }
        return CloudSyncError.message(text ?? "云端同步暂不可用（\(response.statusCode)）。")
    }

    // MARK: - Phase 1: Domain Command 队列（训练生命周期 + 直接记录）

    private struct DomainCommandStore: Codable {
        var pending: [PendingDomainCommand]
        var confirmedFinishSessions: [String]
    }

    /// 远程开关：未开放时所有写入沿用旧的全量同步路径（保守灰度）。
    var domainTrainingCommandsEnabled: Bool { accountService?.remoteConfig?.config.trainingCommands ?? false }
    var domainDirectRecordsEnabled: Bool { accountService?.remoteConfig?.config.directRecords ?? false }

    private var domainCommandFileURL: URL {
        directory.appendingPathComponent("domain-commands-user-\(activeAccountID ?? 0)-v1.json")
    }

    func loadDomainCommands() {
        pendingDomainCommands = []
        confirmedFinishSessions = []
        guard let owner = activeAccountID else { return }
        guard let data = try? Data(contentsOf: domainCommandFileURL),
              let store = try? JSONDecoder().decode(DomainCommandStore.self, from: data) else { return }
        pendingDomainCommands = store.pending.filter { $0.owner == owner }
        confirmedFinishSessions = Set(store.confirmedFinishSessions)
    }

    private func persistDomainCommands() {
        guard let owner = activeAccountID, canSave else { return }
        let store = DomainCommandStore(pending: pendingDomainCommands, confirmedFinishSessions: confirmedFinishSessions.sorted())
        guard let data = try? JSONEncoder().encode(store) else { return }
        do { try data.write(to: domainCommandFileURL, options: [.atomic, .completeFileProtection]) }
        catch { message = "有一笔操作尚未可靠入队，请保持 App 打开重试。" }
    }

    func enqueueDomainCommand(_ command: PendingDomainCommand) {
        guard canSave, activeAccountID == command.owner else {
            message = "这次修改还没有保存，关闭 App 后可能丢失。请先保留当前内容，再尝试保存。"
            return
        }
        pendingDomainCommands.removeAll { $0.commandID == command.commandID }
        pendingDomainCommands.append(command)
        persistDomainCommands()
        scheduleCloudSync()
    }

    /// 同步读取前冲刷：先让服务端应用命令（revision+1），随后的权威读取把结果合并回本机。
    private func flushDomainCommands(ticket: UUID, userID: Int) async {
        guard !pendingDomainCommands.isEmpty,
              let account = accountService, account.user?.id == userID, !account.isPreviewAccount else { return }
        let ids = pendingDomainCommands.filter { $0.owner == userID && $0.blocked != true }.map(\.commandID)
        for id in ids {
            if Task.isCancelled { return }
            guard let command = pendingDomainCommands.first(where: { $0.commandID == id && $0.owner == userID }) else { continue }
            let outcome = await DomainCommands.send(commandID: command.commandID, type: command.type, payload: command.payload, owner: userID, account: account)
            do { try checkContext(ticket, userID) } catch { return }
            guard let index = pendingDomainCommands.firstIndex(where: { $0.commandID == id }) else { continue }
            switch outcome.kind {
            case .confirmed:
                if command.type == DomainCommandType.sessionFinish, let session = command.payload["session_id"]?.string { confirmedFinishSessions.insert(session) }
                if let resume = outcome.resumeSessionID, let date = outcome.resumeDate, command.type == DomainCommandType.sessionStart {
                    message = "已同步进行中的训练（\(date)）。"
                    if let resumed = UUID(uuidString: resume), let key = ClubDates.date(fromKey: date), state.days[date] != nil {
                        state.days[date]?.activeWorkoutSessionID = resumed
                        _ = persist(changedDates: [ClubDates.key(key)])
                    }
                }
                pendingDomainCommands.remove(at: index)
            case .conflict(let reason):
                pendingDomainCommands[index].blocked = true
                pendingDomainCommands[index].lastError = reason
                message = "有一笔操作需要核对：\(reason)；本机与队列均已保留。"
            case .deferred:
                pendingDomainCommands[index].attempts += 1
                pendingDomainCommands[index].lastError = "网络结果未确认，重试沿用原编号。"
                if pendingDomainCommands[index].attempts >= 6 { pendingDomainCommands[index].blocked = true; message = "操作已保留在待同步列表，可查看并重试。" }
            }
            persistDomainCommands()
        }
    }
    func retryDomainCommand(_ id: String) {
        guard let i = pendingDomainCommands.firstIndex(where: { $0.commandID == id && $0.owner == activeAccountID }) else { return }
        pendingDomainCommands[i].blocked = false; pendingDomainCommands[i].attempts = 0; pendingDomainCommands[i].lastError = nil
        persistDomainCommands(); scheduleCloudSync()
    }
    func useCloudDomainDay(_ id: String) async {
        guard let command = pendingDomainCommands.first(where: { $0.commandID == id }), let date = command.payload["date"]?.string,
              let owner = activeAccountID, let account = accountService, command.owner == owner else { return }
        let ticket = generation
        let before = try? JSONEncoder().encode(state.days[date])
        do {
            let response = try await CloudPartitionClient.read(account: account, userID: owner, knownRevision: nil, cache: cloudPartitionCache)
            try checkContext(ticket, owner)
            guard response.statusCode == 200, let remote = response.envelope?.state else { throw CloudSyncError.message("尚未取得权威内容。") }
            guard before == (try? JSONEncoder().encode(state.days[date])) else { throw CloudSyncError.message("读取期间本机内容有变化，请重新核对。") }
            let backup = fileURL.appendingPathExtension("domain-conflict-" + UUID().uuidString)
            try JSONEncoder().encode(state).write(to: backup, options: [.atomic, .completeFileProtection])
            let previous = state
            state.days[date] = remote.savedState().days[date]
            guard persist(changedDates: [date]) else { state = previous; return }
            pendingDomainCommands.removeAll { $0.owner == owner && $0.payload["date"]?.string == date }
            persistDomainCommands(); message = "已采用云端记录，本机冲突内容保留在恢复备份中。"; scheduleCloudSync()
        } catch { message = AppErrorText.message(error) }
    }

    /// 开始训练入队（显式开始或首个完成组自动开始均走此路径）。
    private func enqueueTrainingStartIfNeeded(for date: Date) {
        guard domainTrainingCommandsEnabled, let owner = activeAccountID,
              let account = accountService, account.user?.id == owner, !account.isPreviewAccount else { return }
        let day = log(for: date)
        guard let session = day.activeWorkoutSessionID else { return }
        let dateKey = ClubDates.key(date)
        let sessionKey = session.uuidString.lowercased()
        let intent = "training/start/\(dateKey)/\(sessionKey)"
        guard !pendingDomainCommands.contains(where: { $0.intent == intent }) else { return }
        let identity = DomainCommands.identity(owner: owner, intent: intent)
        enqueueDomainCommand(PendingDomainCommand(commandID: identity.command, type: DomainCommandType.sessionStart,
            payload: DomainCommands.startPayload(date: dateKey, sessionID: session, day: day),
            intent: intent, owner: owner, attempts: 0, createdAt: Date()))
    }

    /// 结束训练入队。已由命令确认过的会话不再重复入队（事后修正沿用旧同步路径及其保护）。
    private func enqueueTrainingFinishIfNeeded(for date: Date, now: Date) {
        guard domainTrainingCommandsEnabled, let owner = activeAccountID,
              let account = accountService, account.user?.id == owner, !account.isPreviewAccount else { return }
        let day = log(for: date)
        guard let session = day.activeWorkoutSessionID else { return }
        let sessionKey = session.uuidString.lowercased()
        guard !confirmedFinishSessions.contains(sessionKey) else { return }
        let dateKey = ClubDates.key(date)
        let intent = "training/finish/\(dateKey)/\(sessionKey)"
        guard !pendingDomainCommands.contains(where: { $0.intent == intent }) else { return }
        let identity = DomainCommands.identity(owner: owner, intent: intent)
        enqueueDomainCommand(PendingDomainCommand(commandID: identity.command, type: DomainCommandType.sessionFinish,
            payload: DomainCommands.finishPayload(date: dateKey, day: day, sessionID: session, savedAt: now),
            intent: intent, owner: owner, attempts: 0, createdAt: Date()))
    }

    private func enqueueMealRecordIfNeeded(_ meal: Meal, date: Date) {
        guard domainDirectRecordsEnabled, let owner = activeAccountID, accountService?.isPreviewAccount == false else { return }
        let intent = "meal/create/" + meal.id.uuidString.lowercased()
        let identity = DomainCommands.identity(owner: owner, intent: intent)
        var item: [String: JSONValue] = ["entry_id": .string(meal.id.uuidString.lowercased()), "name": .string(meal.name), "category": .string(meal.category), "calories": .number(meal.calories), "protein": .number(meal.protein), "carbs": .number(meal.carbs), "fat": .number(meal.fat), "estimated": .bool(meal.estimated ?? false)]
        if let source = meal.sourceAIJobID { item["sourceAIJobID"] = .string(source) }
        enqueueDomainCommand(PendingDomainCommand(commandID: identity.command, type: DomainCommandType.mealCreateDirect, payload: ["date": .string(ClubDates.key(date)), "meals": .array([.object(item)]), "idempotency_key": .string(identity.key)], intent: intent, owner: owner, attempts: 0, createdAt: Date()))
    }
    private func enqueueSetRecord(_ set: TrainingSet, exerciseID: UUID, date: Date, original: TrainingSet, correcting: Bool) {
        guard domainTrainingCommandsEnabled, let owner = activeAccountID, accountService?.isPreviewAccount == false, let session = log(for: date).activeWorkoutSessionID else { return }
        let intent = "training/set/" + UUID().uuidString.lowercased()
        let identity = DomainCommands.identity(owner: owner, intent: intent)
        var payload: [String: JSONValue] = ["date": .string(ClubDates.key(date)), "session_id": .string(session.uuidString.lowercased()), "exercise_id": .string(exerciseID.uuidString.lowercased()), "set_id": .string(set.id.uuidString.lowercased()), "weight": .number(set.weight), "reps": .number(Double(set.reps)), "completed": .bool(set.completed), "expected_set": (try? JSONValue.encode(original)) ?? .null]
        if let duration = set.durationSeconds { payload["duration_seconds"] = .number(Double(duration)) }
        enqueueDomainCommand(PendingDomainCommand(commandID: identity.command, type: correcting ? DomainCommandType.correctSet : DomainCommandType.logSet, payload: payload, intent: intent, owner: owner, attempts: 0, createdAt: Date()))
    }

    /// 手动体重直记录入队（低风险直执行；服务端按 idempotency_key 幂等）。
    private func enqueueBodyWeightRecordIfNeeded(for date: Date, kilograms: Double?,
                                                 bodyFatPercentage: Double?, waistCircumferenceCM: Double?, now: Date, measurementID: UUID) {
        guard domainDirectRecordsEnabled, let owner = activeAccountID, let kilograms,
              let account = accountService, account.user?.id == owner, !account.isPreviewAccount else { return }
        let dateKey = ClubDates.key(date)
        let intent = "body/weight/\(dateKey)/\(UUID().uuidString.lowercased())"
        let identity = DomainCommands.identity(owner: owner, intent: intent)
        var payload = DomainCommands.bodyWeightPayload(date: dateKey, kilograms: kilograms, bodyFatPercentage: bodyFatPercentage, waistCircumferenceCM: waistCircumferenceCM, recordedAt: now)
        payload["idempotency_key"] = .string(identity.key)
        payload["measurement_id"] = .string(measurementID.uuidString.lowercased())
        enqueueDomainCommand(PendingDomainCommand(commandID: identity.command, type: DomainCommandType.bodyWeightCreateDirect,
            payload: payload,
            intent: intent, owner: owner, attempts: 0, createdAt: Date()))
    }
}

#if canImport(ActivityKit)
import ActivityKit

@MainActor
final class TrainingActivityService {
    static let shared = TrainingActivityService()
    private var activity: Activity<TrainingActivityAttributes>?
    private var accountID: Int?

    func activate(_ id: Int?) {
        guard accountID != id || id == nil else { return }
        accountID = id
        let all = Activity<TrainingActivityAttributes>.activities
        activity = all.first { $0.attributes.accountID == id && id != nil && Calendar.current.isDateInToday($0.attributes.startedAt) }
        let retainedID = activity?.id
        Task { for item in all where item.id != retainedID { await item.end(nil, dismissalPolicy: .immediate) } }
    }

    func start(workoutName: String, totalSets: Int, completedSets: Int = 0,
               startedAt: Date = .now, dateKey: String? = nil) {
        guard accountID != nil, ActivityAuthorizationInfo().areActivitiesEnabled, totalSets > 0 else { return }
        if activity == nil {
            activity = Activity<TrainingActivityAttributes>.activities.first { $0.attributes.accountID == accountID && Calendar.current.isDateInToday($0.attributes.startedAt) }
        }
        guard activity == nil else { return }
        let state = TrainingActivityAttributes.ContentState(workoutName: workoutName, completedSets: completedSets, totalSets: totalSets, remainingSeconds: 0, restSeconds: 0, restEndsAt: nil, elapsedSeconds: 0, updatedAt: Date())
        do {
            activity = try Activity.request(attributes: TrainingActivityAttributes(workoutName: workoutName, startedAt: startedAt, accountID: accountID, dateKey: dateKey), content: .init(state: state, staleDate: nil), pushType: nil)
        } catch { NSLog("Training Live Activity failed: %@", AppErrorText.message(error)) }
    }

    func update(workoutName: String, completedSets: Int, totalSets: Int, restEnd: Date?,
                currentExerciseName: String? = nil, currentSetNumber: Int? = nil,
                isPaused: Bool = false, elapsed: TimeInterval = 0,
                restPausedRemaining: TimeInterval? = nil) {
        guard let activity else { return }
        let state = TrainingActivityAttributes.ContentState(
            workoutName: workoutName, completedSets: completedSets, totalSets: totalSets,
            remainingSeconds: max(0, Int(elapsed)), restSeconds: restPausedRemaining.map { max(0, Int($0)) } ?? max(0, Int((restEnd ?? .distantPast).timeIntervalSinceNow)),
            restEndsAt: restPausedRemaining == nil ? restEnd : nil,
            currentExerciseName: currentExerciseName, currentSetNumber: currentSetNumber,
            isPaused: isPaused, pausedElapsedSeconds: isPaused ? max(0, Int(elapsed)) : nil,
            restPausedRemaining: restPausedRemaining.map { max(0, Int($0)) },
            elapsedSeconds: max(0, Int(elapsed)), updatedAt: Date())
        Task { await activity.update(.init(state: state, staleDate: restPausedRemaining == nil ? restEnd : nil)) }
    }

    /// 由持久化快照驱动；任何入口开始的训练都能同步到同一 Activity。
    func sync(snapshot: ActiveWorkoutSnapshot?, restPausedRemaining: TimeInterval? = nil) {
        guard let snapshot, snapshot.totalSets > 0 else { end(); return }
        start(workoutName: snapshot.workoutName, totalSets: snapshot.totalSets,
              completedSets: snapshot.completedSets,
              startedAt: snapshot.startedAt, dateKey: snapshot.dateKey)
        update(workoutName: snapshot.workoutName, completedSets: snapshot.completedSets,
               totalSets: snapshot.totalSets, restEnd: snapshot.restEndsAt,
               currentExerciseName: snapshot.currentExerciseName,
               currentSetNumber: snapshot.currentSetNumber,
               isPaused: snapshot.isPaused, elapsed: snapshot.elapsed,
               restPausedRemaining: restPausedRemaining)
    }

    func end() {
        let activities = Activity<TrainingActivityAttributes>.activities
        self.activity = nil
        Task { for activity in activities { await activity.end(nil, dismissalPolicy: .immediate) } }
    }
}
#endif


extension AppStore {
    func reportNutritionTarget(on date: Date) -> NutritionTarget? {
        let historical = log(for: date).nutritionTarget
        let current = state.nutritionTarget
        if historical?.generalGuidanceOnly == true { return historical }
        if current?.generalGuidanceOnly == true { return current }
        return historical ?? current
    }

    func nutritionTarget(on date: Date) -> NutritionTarget? {
        let target = log(for: date).nutritionTarget ?? state.nutritionTarget
        return target?.generalGuidanceOnly == true ? nil : target
    }

    @discardableResult
    func beginWorkout(on date: Date) -> Bool {
        let original = log(for: date)
        if let sessions = original.workoutSessions, !sessions.isEmpty, sessions.allSatisfy({ $0.cancelledAt != nil }) {
            guard addWorkoutSession(on: date, copyPlan: true) else { return false }
        }
        let day = log(for: date).trainingLog
        guard Calendar.current.isDateInToday(date), !day.exercises.isEmpty,
              day.workoutStartedAt == nil, day.completedSets == 0, day.workoutSavedAt == nil else { return false }
        guard mutate(date, edit: { $0.workoutStartedAt = Date(); $0.workoutEndedAt = nil }) else { return false }
        enqueueTrainingStartIfNeeded(for: date)
        return true
    }

    @discardableResult
    func selectWorkoutSession(_ id: UUID, on date: Date) -> Bool {
        guard log(for: date).workoutSessions?.contains(where: { $0.id == id }) == true else { message = "这次训练已变化，请重新打开。"; return false }
        return mutate(date) { _ = WorkoutSessions.select(id, in: &$0) }
    }

    @discardableResult
    func removeEmptyWorkoutSession(_ id: UUID, on date: Date) -> Bool {
        guard EmptyWorkoutSessionRules.canRemove(id, from: log(for: date)) else {
            message = "只有未开始、没有动作的空白场次可以删除；已有训练记录会保留。"; return false
        }
        return mutate(date) { day in
            WorkoutSessions.synchronize(&day)
            day.workoutSessions?.removeAll { $0.id == id }
            if day.activeWorkoutSessionID == id { day.activeWorkoutSessionID = day.workoutSessions?.last?.id }
            WorkoutSessions.restoreActiveFields(&day)
        }
    }

    @discardableResult
    func addWorkoutSession(on date: Date, copyPlan: Bool) -> Bool {
        let day = log(for: date)
        let allCancelled = day.workoutSessions?.isEmpty == false && day.workoutSessions!.allSatisfy { $0.cancelledAt != nil }
        var selected = day.trainingLog
        if allCancelled, let last = day.workoutSessions?.last { selected.exercises = day.exercises.filter { $0.workoutSessionID == last.id } }
        guard !selected.exercises.isEmpty else { message = "当前训练还是空白，请先添加动作。"; return false }
        guard !ClubDates.isFuture(date), (day.workoutSessions?.count ?? 1) < 8 else { message = "已达到当天的新建上限，已有训练会保留；未来日期请先安排计划。"; return false }
        guard allCancelled || selected.completedSets == 0 || selected.workoutSavedAt != nil else { message = "请先确认当前训练记录，再新建下一次训练。"; return false }
        guard day.exercises.count + (copyPlan ? selected.exercises.count : 0) <= 30 else { message = "一天最多保留 30 个动作，请选择空白训练后按需添加。"; return false }
        return mutate(date) { day in
            WorkoutSessions.initialize(&day); WorkoutSessions.synchronize(&day)
            let id = UUID()
            day.workoutSessions?.append(WorkoutSession(id: id))
            day.activeWorkoutSessionID = id
            day.workoutStartedAt = nil; day.workoutEndedAt = nil; day.workoutSavedAt = nil; day.linkedDeviceWorkoutID = nil
            if copyPlan {
                day.exercises += selected.exercises.map { exercise in
                    var copy = exercise; copy.id = UUID(); copy.workoutSessionID = id; copy.deletedSetIDs = nil
                    copy.sets = exercise.sets.map { set in var result = set; result.id = UUID(); result.completed = false; result.actualEntered = false; return result }
                    return copy
                }
            }
        }
    }

    @discardableResult
    func replaceExercise(_ original: Exercise, with item: LibraryExercise, on date: Date) -> Bool {
        let current = log(for: date)
        guard let existing = current.trainingLog.exercises.first(where: { $0.id == original.id }),
              (try? CloudMerge.same(existing, original)) == true else { message = WorkoutEditError.changed.localizedDescription; return false }
        guard item.customID == nil || existing.customExerciseID != item.customID else { message = "请选择另一个动作。"; return false }
        guard existing.libraryID != item.id else { message = "请选择另一个动作。"; return false }
        let replacement: Exercise
        if let id = item.customID {
            guard let definition = customExercises.first(where: { $0.id == id }) else { message = "这个个人动作已删除，请重新选择。"; return false }
            replacement = definition.exercise()
        } else {
        replacement = Exercise(name: String(item.displayName.prefix(100)), muscle: item.muscleLabel,
                                   libraryID: item.id, equipment: item.equipmentLabel, imageURL: item.imageURL,
                                   gifURL: item.gifURL, libraryQuery: item.name)
        }
        do {
            let updated = try WorkoutEditing.replacing(original, with: replacement, in: current)
            let previous = state
            if !original.sets.contains(where: \.validCompletion) {
                state.deletedExerciseIDs = Array(Set((state.deletedExerciseIDs ?? []) + [original.id.uuidString])).sorted()
            }
            state.days[ClubDates.key(date)] = updated
            if persist(changedDates: [ClubDates.key(date)]) { return true }
            state = previous; return false
        } catch { message = error.localizedDescription; return false }
    }

    @discardableResult
    func linkDeviceWorkout(_ id: String?, on date: Date) -> Bool {
        let day = log(for: date)
        if let id {
            guard day.workoutSessions?.contains(where: { $0.id != day.activeWorkoutSessionID && $0.linkedDeviceWorkoutID == id }) != true else { message = "这条设备记录已关联当天另一次训练，请先取消原关联。"; return false }
            guard day.trainingLog.completedSets > 0, day.health?.workouts.contains(where: { $0.id == id }) == true else {
                message = "请先确认分享该日健康汇总，并至少记录一组已完成训练。"; return false
            }
        }
        return mutate(date) { $0.linkedDeviceWorkoutID = id }
    }
}


extension AppStore {
    @discardableResult
    func applyProfilePlan(_ result: AIResult, jobID: String, start: Date, expectedDays: [String: DayLog]? = nil) -> Bool {
        if hasAppliedAIJob(jobID) { return true }
        let startDay = ClubDates.calendar.startOfDay(for: start)
        guard startDay > ClubDates.calendar.startOfDay(for: Date()),
              result.kind == "plan", let sessions = result.sessions, !sessions.isEmpty else {
            message = "更新计划必须从未来日期开始，请重新选择起始日。"; return false
        }
        let dates = (0..<7).compactMap { ClubDates.calendar.date(byAdding: .day, value: $0, to: startDay) }.map(ClubDates.key)
        let window = Set(dates)
        if let expectedDays {
            guard dates.allSatisfy({ key in
                guard let expected = expectedDays[key] else { return false }
                return PlanAdoptionRules.sameTraining(state.days[key] ?? DayLog(), expected)
            }) else { message = "安排在预览后发生了变化，请返回重新核对。原记录已保留。"; return false }
        }
        let expectedDates = Set(dates.filter { key in
            guard let date = ClubDates.date(fromKey: key) else { return false }
            let weekday = (ClubDates.calendar.component(.weekday, from: date) + 5) % 7 + 1
            return (state.profile.trainingDays ?? []).contains(weekday)
        })
        guard !expectedDates.isEmpty, Set(sessions.map(\.date)) == expectedDates,
              Set(sessions.map(\.date)).count == sessions.count,
              sessions.allSatisfy({ session in
                  guard let dayDate = ClubDates.date(fromKey: session.date) else { return false }
                  let weekday = (ClubDates.calendar.component(.weekday, from: dayDate) + 5) % 7 + 1
                  return window.contains(session.date) && (state.profile.trainingDays ?? []).contains(weekday) &&
                    !session.exercises.isEmpty && session.exercises.count <= 30 && session.exercises.allSatisfy { exercise in
                        !exercise.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !exercise.sets.isEmpty && exercise.sets.count <= 50 &&
                        exercise.sets.allSatisfy { set in
                            let weight = set.weight ?? 0
                            return weight.isFinite && (0...2000).contains(weight) &&
                                (set.durationSeconds.map { (1...RecordLimits.maximumSeconds).contains($0) } ?? (1...RecordLimits.maximumReps).contains(set.reps))
                        }
                    }
              }) else { message = "新方案的日期或训练组不完整，请重新生成。"; return false }
        let previous = state
        for key in dates {
            var day = state.days[key] ?? DayLog()
            guard !WorkoutEditing.isProtected(day) else { continue }
            state.deletedExerciseIDs = Array(Set((state.deletedExerciseIDs ?? []) + day.exercises.map { $0.id.uuidString })).sorted()
            day.exercises = []
            day.workoutSavedAt = nil; day.linkedDeviceWorkoutID = nil; day.workoutEndedAt = nil
            if let session = sessions.first(where: { $0.date == key }) {
                day.exercises = session.exercises.enumerated().map { i, exercise in
                    let prefix = "\(jobID)/\(key)/\(i)"
                    return Exercise(id: stableID(prefix), name: exercise.name, muscle: exercise.muscle,
                                    sets: exercise.sets.enumerated().map { j, set in
                                        TrainingSet(id: stableID("\(prefix)/\(j)"), weight: set.durationSeconds == nil ? (set.weight ?? 0) : 0,
                                                    reps: set.durationSeconds == nil ? set.reps : 0, durationSeconds: set.durationSeconds)
                                    }, libraryID: exercise.library_id, planID: jobID, libraryQuery: exercise.library_query, customExerciseID: exercise.custom_id, customUnit: exercise.custom_unit, restSeconds: exercise.rest_seconds)
                }
            }
            // Rest days still retain all meals, health observations and reviews.
            state.days[key] = day
        }
        state.appliedAIJobs = (state.appliedAIJobs ?? []) + [jobID]
        let cycleDates = TrainingCycle.stamp(days: &state.days, start: startDay, plannedDates: sessions.map(\.date), sourceJobID: jobID)
        recordPlanHistory(operationID: jobID, result: result, start: startDay, previous: previous, scope: dates, source: "ai")
        if persist(changedDates: Array(Set(dates + cycleDates)).sorted()) { return true }
        state = previous; return false
    }
}

extension AppStore {
    @discardableResult
    func saveBodyWeight(_ kilograms: Double?, on date: Date, now: Date = Date()) -> Bool {
        saveBodyMeasurements(kilograms: kilograms, bodyFatPercentage: nil, waistCircumferenceCM: nil,
                             on: date, now: now)
    }
    /// F06：一次手动测量可同时记录体重、体脂率与腰围；来源固定为手动，
    /// 采样时间使用保存时间。清空全部字段时留下墓碑，不删除历史报告。
    @discardableResult
    func saveBodyMeasurements(kilograms: Double?, bodyFatPercentage: Double?, waistCircumferenceCM: Double?,
                              on date: Date, now: Date = Date(), measurementID: UUID? = nil, measuredAt: Date? = nil) -> Bool {
        guard ClubDates.calendar.startOfDay(for: date) <= ClubDates.calendar.startOfDay(for: now) else {
            message = "请选择今天或过去的日期。"; return false
        }
        guard kilograms.map({ $0.isFinite && (20...400).contains($0) }) ?? true,
              bodyFatPercentage.map({ $0.isFinite && (0...70).contains($0) }) ?? true,
              waistCircumferenceCM.map({ $0.isFinite && (30...300).contains($0) }) ?? true else {
            message = "体重范围 20–400 kg，体脂率 0–70%，腰围 30–300 cm；不确定的项目请留空。"; return false
        }
        let kg = kilograms.map { ($0 * 10).rounded() / 10 }
        let fat = bodyFatPercentage.map { ($0 * 10).rounded() / 10 }
        let waist = waistCircumferenceCM.map { ($0 * 10).rounded() / 10 }
        let savedMeasurementID = measurementID ?? UUID()
        let saved = mutate(date) { day in
            if day.bodyMeasurements == nil {
                day.bodyMeasurements = [day.bodyWeight].compactMap { $0 }.map { old in
                    var copy = old; copy.id = copy.id ?? BodyMeasurementIdentity.legacy(copy, date: ClubDates.key(date)); return copy
                }
            }
            if kg == nil && fat == nil && waist == nil {
                if let id = measurementID ?? day.bodyWeight?.id ?? day.bodyMeasurements?.last?.id {
                    day.deletedBodyMeasurementIDs = Array(Set((day.deletedBodyMeasurementIDs ?? []) + [id.uuidString.lowercased()]))
                    day.bodyMeasurements?.removeAll { $0.id == id }
                }
                day.bodyWeight = day.bodyMeasurements?.sorted { ($0.recordedAt ?? $0.updatedAt) < ($1.recordedAt ?? $1.updatedAt) }.last
            } else {
                let old = measurementID.flatMap { id in day.bodyMeasurements?.first { $0.id == id } }
                let entry = BodyWeightEntry(kilograms: kg, updatedAt: now, id: savedMeasurementID, externalSampleID: old?.externalSampleID, sourceBundle: old?.sourceBundle, bodyFatPercentage: fat, waistCircumferenceCM: waist, recordedAt: measuredAt ?? old?.recordedAt ?? now, source: old?.source ?? "manual")
                if let measurementID { day.bodyMeasurements?.removeAll { $0.id == measurementID } }
                day.bodyMeasurements?.append(entry)
                day.bodyWeight = day.bodyMeasurements?.sorted { ($0.recordedAt ?? $0.updatedAt) < ($1.recordedAt ?? $1.updatedAt) }.last
            }
        }
        if saved && measurementID == nil { enqueueBodyWeightRecordIfNeeded(for: date, kilograms: kg, bodyFatPercentage: fat, waistCircumferenceCM: waist, now: measuredAt ?? now, measurementID: savedMeasurementID) }
        return saved
    }

    func bodyWeightPoints(through date: Date, limit: Int = 30) -> [BodyWeightPoint] {
        BodyWeightHistory.points(days: state.days, through: date, limit: limit)
    }

    /// E02/F03：同一动作在上一次训练中最后一个有效完成的组。只回看更早的
    /// 日期，且调用方仍须校验计量单位；不跨单位、不把资料值或计划值当作历史。
    func lastCompletedSet(matching exercise: Exercise, before date: Date) -> TrainingSet? {
        let cutoff = ClubDates.key(date)
        let sameMovement: (Exercise) -> Bool = { candidate in
            if let id = exercise.libraryID, !id.isEmpty { return candidate.libraryID == id }
            if let id = exercise.customExerciseID { return candidate.customExerciseID == id }
            return candidate.name == exercise.name && candidate.muscle == exercise.muscle
        }
        for key in state.days.keys.filter({ $0 < cutoff }).sorted(by: >) {
            guard let day = state.days[key] else { continue }
            for candidate in day.exercises where sameMovement(candidate) {
                if let set = candidate.sets.last(where: { $0.validCompletion }) { return set }
            }
        }
        return nil
    }
}


extension AppStore {
    @discardableResult
    func confirmMeals(on date: Date, complete: Bool) -> Bool {
        guard !ClubDates.isFuture(date), !log(for: date).meals.isEmpty else { message = "请先记录实际吃过的餐食。"; return false }
        return mutate(date) { day in day.mealCompletion = complete ? MealCompletion(signature: MealCompletion.signature(day.meals)) : nil }
    }
}


extension AppStore {
    var customExercises: [CustomExercise] {
        let deleted = Set((state.deletedCustomExerciseIDs ?? []).map { $0.uppercased() })
        return (state.customExercises ?? []).filter { !deleted.contains($0.id.uuidString.uppercased()) }.sorted { $0.updatedAt == $1.updatedAt ? $0.id.uuidString < $1.id.uuidString : $0.updatedAt > $1.updatedAt }
    }
    @discardableResult
    func saveCustomExercise(_ value: CustomExercise) -> Bool {
        guard editingAccountID != nil else { message = "请先登录，再保存个人动作。"; return false }
        var clean = value
        clean.name = clean.name.trimmingCharacters(in: .whitespacesAndNewlines)
        clean.equipment = clean.equipment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.valid else { message = "请填写 1–60 字动作名，选择次数或时长；器械说明最多 60 字。"; return false }
        guard !(state.deletedCustomExerciseIDs ?? []).contains(where: { $0.caseInsensitiveCompare(clean.id.uuidString) == .orderedSame }) else { message = "这个动作已删除，请重新创建。"; return false }
        if let latest = customExercises.first(where: { $0.id == clean.id }), latest.updatedAt != value.updatedAt { message = "这个动作已在另一处更新，请重新打开后编辑。"; return false }
        guard !customExercises.contains(where: { $0.id != clean.id && $0.normalizedName == clean.normalizedName }) else { message = "已有同名个人动作，请直接使用或编辑它。"; return false }
        guard customExercises.contains(where: { $0.id == clean.id }) || customExercises.count < 200 else { message = "最多保存 200 个个人动作，请先整理不用的动作。"; return false }
        let previous = state
        clean.updatedAt = Date()
        var items = state.customExercises ?? []
        if let index = items.firstIndex(where: { $0.id == clean.id }) { items[index] = clean } else { items.append(clean) }
        state.customExercises = items
        if persist(changedDates: []) { return true }
        state = previous; return false
    }
    @discardableResult
    func deleteCustomExercise(_ id: UUID) -> Bool {
        guard editingAccountID != nil, customExercises.contains(where: { $0.id == id }) else { message = "动作或账号已变化，请重新打开。"; return false }
        let previous = state
        state.customExercises?.removeAll { $0.id == id }
        state.deletedCustomExerciseIDs = Array(Set((state.deletedCustomExerciseIDs ?? []) + [id.uuidString.lowercased()])).sorted()
        if persist(changedDates: []) { return true }
        state = previous; return false
    }
    @discardableResult
    func addCustomExercise(_ id: UUID, on date: Date) -> Bool {
        guard editingAccountID != nil, let definition = customExercises.first(where: { $0.id == id }) else { message = "这个个人动作已删除或账号已变化。"; return false }
        guard log(for: date).exercises.count < 30 else { message = "一天最多安排 30 个动作。"; return false }
        return mutate(date) { day in
            var exercise = definition.exercise(); exercise.planID = PlanManagementRules.ownerForAddition(day)
            day.workoutSavedAt = nil; day.exercises.append(exercise)
        }
    }
}


extension AppStore {
    var mealPlacementIssues: [MealPlacementIssue] {
        state.days.keys.sorted().flatMap { key in
            (state.days[key]?.meals ?? []).filter { !($0.placementConflictDates ?? []).isEmpty }
                .map { MealPlacementIssue(date: key, meal: $0) }
        }
    }
    @discardableResult
    func confirmMealPlacement(_ id: UUID, currentDate: String, destination: String) -> Bool {
        guard editingAccountID != nil else { message = "请先登录，再核对记录日期。"; return false }
        guard let date = ClubDates.date(fromKey: destination), !ClubDates.isFuture(date),
              let meal = state.days[currentDate]?.meals.first(where: { $0.id == id }),
              !((meal.placementConflictDates ?? []).isEmpty) else { message = "记录已变化，请重新打开日期核对。"; return false }
        guard currentDate == destination || (state.days[destination]?.meals.count ?? 0) < 50 else { message = "这一天已有 50 餐，请选择正确日期后再处理。"; return false }
        let previous = state
        var resolved = meal; resolved.placementConflictDates = nil; resolved.placementConfirmedAt = Date()
        state.days[currentDate]?.meals.removeAll { $0.id == id }
        var day = state.days[destination] ?? DayLog()
        day.meals.append(resolved); day.mealCompletion = nil
        state.days[destination] = day
        if currentDate != destination { state.days[currentDate]?.mealCompletion = nil }
        if persist(changedDates: [currentDate, destination]) { return true }
        state = previous; return false
    }
}

// MARK: - 计划顺延执行（与 AppStore 持久化事务同文件，才能原子回滚）
extension AppStore {
    /// 顺延执行。moves 为 (原日期, 新日期)；替换目标仅限 replaceTargets 显式列出的 key。
    /// 幂等保护：expectedFingerprint 与当前状态不符则拒绝执行。
    @discardableResult
    func shiftPlannedSchedule(moves: [(String, String)], shiftDays: Int, replaceTargets: Set<String>,
                              expectedFingerprint: String, recordID: String = UUID().uuidString.lowercased(),
                              reason: String = "user_shift", allowTodaySource: Bool = false) -> Bool {
        guard canSave, activeAccountID != nil, !moves.isEmpty, shiftDays > 0 else {
            message = "没有可顺延的安排。"; return false
        }
        // 1) 源日可移动；默认只允许未来，日历内单日调整允许今天尚未开始的安排。
        for (source, _) in moves {
            guard let date = ClubDates.date(fromKey: source),
                  allowTodaySource ? ClubDates.key(date) >= ClubDates.key(Date()) : ClubDates.isFuture(date) else {
                message = "只能顺延尚未开始的未来安排。"; return false
            }
            let day = state.days[source] ?? DayLog()
            guard !day.exercises.isEmpty, !WorkoutEditing.isProtected(day), !day.hasUnconfirmedTraining else {
                message = "所选范围包含已开始或未确认的训练，请缩小范围后重试。"; return false
            }
        }
        // 2) 冲突检查：hard 拒绝；soft 必须在 replaceTargets 中显式选择。
        let problems = ClubShiftRules.conflicts(moves: moves, state: state)
        guard problems.hard.isEmpty else {
            message = "目标日期已有已开始或未确认的训练：" + problems.hard.joined(separator: "、") + "。请更换顺延天数。"; return false
        }
        for target in problems.soft {
            guard replaceTargets.contains(target) else {
                message = "\(target) 已有可编辑安排；请更换顺延天数，或在预览中明确选择替换。"; return false
            }
        }
        // 3) 快照校验：预览后安排变化则拒绝。
        var involved = Set<String>()
        for (source, target) in moves { involved.insert(source); involved.insert(target) }
        var current: [String: DayLog] = [:]
        for key in involved { current[key] = state.days[key] ?? DayLog() }
        guard ClubShiftRules.fingerprint(current) == expectedFingerprint else {
            message = "安排在预览后发生了变化，请重新核对。"; return false
        }
        // 防御：源/目标不能重复（重复会让记录字典崩溃或互相覆盖）。
        var seenSources = Set<String>(), seenTargets = Set<String>()
        for (source, target) in moves {
            guard seenSources.insert(source).inserted, seenTargets.insert(target).inserted else {
                message = "移动日期有重复，请重新预览。"; return false
            }
        }

        let previous = state
        var finalRecord = PlanShiftRecord(id: recordID, createdAt: Date(), shiftDays: shiftDays,
                                          moves: Dictionary(uniqueKeysWithValues: moves))
        var deletedIDs: [String] = []
        var changed = Set<String>()

        // 4) 先确定每个目标日真正归属的周期。跨周/跨月/跨计划时，目标日不能继续
        //    沿用源周期的 start/end（源周期的七天窗口并不覆盖目标日，服务端也会拒绝）。
        let cyclesBefore = TrainingCycle.available(days: state.days)
        let plannedDestinations = ClubShiftRules.destinations(moves: moves, days: state.days, cycles: cyclesBefore)
        let destinationCycles = plannedDestinations.cycles
        let sourceStarts = plannedDestinations.sourceStarts

        // 5) 两阶段执行（与先后顺序无关，向前/向后挪都不会互相覆盖）：
        //    阶段一把所有源日的安排取出并清空；阶段二统一写入目标日。
        var payloads: [(source: String, target: String, copies: [Exercise])] = []
        for (source, target) in moves {
            var sourceDay = state.days[source] ?? DayLog()
            let oldIDs = sourceDay.exercises.map { $0.id.uuidString }
            let copies = sourceDay.exercises.map { exercise -> Exercise in
                var copy = exercise; copy.id = UUID(); copy.workoutSessionID = nil; copy.deletedSetIDs = nil
                copy.sets = exercise.sets.map { set in var value = set; value.id = UUID(); value.completed = false; value.actualEntered = false; return value }
                return copy
            }
            // 源日转恢复，不残留另一份待练。周期标记保留，下一步统一重算。
            sourceDay.exercises = []
            WorkoutSessions.synchronize(&sourceDay)
            sourceDay.plannedMoveDestination = target
            deletedIDs += oldIDs
            state.days[source] = sourceDay
            changed.insert(source)
            payloads.append((source: source, target: target, copies: copies))
        }
        for payload in payloads {
            var targetDay = state.days[payload.target] ?? DayLog()
            // 目标日若是要被替换的可编辑安排：完整快照留档、清空并登记删除（不静默丢内容）。
            if !targetDay.exercises.isEmpty {
                guard replaceTargets.contains(payload.target) else {
                    state = previous
                    message = "\(payload.target) 的安排发生变化，请重新预览。"; return false
                }
                finalRecord.replaced[payload.target] = ClubPlanChangeRules.snapshot(targetDay.exercises)
                deletedIDs += targetDay.exercises.map { $0.id.uuidString }
                targetDay.workoutSavedAt = nil
            }
            targetDay.exercises = payload.copies
            targetDay.movedFromDate = payload.source
            // 目标日采用真正覆盖它的周期；若没有现成周期，则使用与源周期周界对齐的新周期。
            targetDay.planCycle = destinationCycles[payload.target]
            // 目标日收到内容后不是恢复日：清掉可能残留的（链条上被腾空源日的）恢复标记。
            targetDay.plannedMoveDestination = nil
            targetDay.workoutSessions = nil
            targetDay.activeWorkoutSessionID = nil
            WorkoutSessions.initialize(&targetDay)
            state.days[payload.target] = targetDay
            changed.insert(payload.target)
        }

        // 6) 版本记录写入所有涉及日（同 ID 多端合并去重）。
        finalRecord.sourceCycles = sourceStarts.isEmpty ? nil : sourceStarts
        finalRecord.effectScope = involved.sorted()
        finalRecord.reason = reason
        for key in involved {
            state.days[key, default: DayLog()].planShifts = (state.days[key]?.planShifts ?? []) + [finalRecord]
        }
        state.deletedExerciseIDs = Array(Set((state.deletedExerciseIDs ?? []) + deletedIDs)).sorted()
        // 行动状态与本次变更同一次落盘——完成才标记，回滚一并撤销。
        state.actionStates = (state.actionStates ?? []).filter { $0.id != "shift-" + recordID } + [
            ClubActionRecord(id: "shift-" + recordID, state: ClubActionRecord.stateCompleted,
                             updatedAt: Date(), note: finalRecord.note)
        ]

        // 7) 周期归属重算：只重算与本次移动相关的周期，保留其他计划的原标记。
        var affected: [String: TrainingCycle] = [:]
        for cycle in cyclesBefore where !Set(cycle.dates).isDisjoint(with: involved) {
            affected[cycle.start] = cycle
        }
        for key in involved {
            if let cycle = state.days[key]?.planCycle { affected[cycle.start] = cycle }
        }
        for cycle in destinationCycles.values { affected[cycle.start] = cycle }
        var cycleTouched = Set<String>()
        for (cycleStart, original) in affected {
            var updated = original
            updated.plannedDates = updated.dates.filter { !(state.days[$0]?.exercises.isEmpty ?? true) }
            for key in updated.dates {
                // 不覆盖其他计划已有的周期标记；本次明确指定的目标日除外。
                let explicitStart = destinationCycles[key]?.start
                if let current = state.days[key]?.planCycle, current.start != cycleStart,
                   explicitStart != cycleStart { continue }
                state.days[key, default: DayLog()].planCycle = updated
                cycleTouched.insert(key)
            }
        }
        changed.formUnion(cycleTouched)

        if persist(changedDates: Array(changed)) { return true }
        state = previous; return false
    }

}

extension AppStore {
    var managedPlans: [ManagedPlan] {
        var versions: [String: ClubPlanVersion] = [:]
        for day in state.days.values { for version in day.planVersions ?? [] { versions[version.id] = version } }
        // Legacy schedules without a version remain manageable, one owned interval at a time.
        for cycle in TrainingCycle.available(days: state.days) where !cycle.plannedDates.isEmpty {
            let representsPlan = cycle.plannedDates.contains { key in
                guard let day = state.days[key] else { return false }
                return day.planCycle != nil || (key >= ClubDates.key(Date()) && !PlanAdoptionRules.isProtected(day))
            }
            guard representsPlan else { continue }
            let covered = versions.values.contains { !$0.scopeDates.filter { cycle.dates.contains($0) }.isEmpty }
            guard !covered else { continue }
            let id = cycle.sourceJobID ?? "legacy-plan-" + cycle.start
            if versions[id] != nil && versions[id]?.recordedAt != .distantPast { continue }
            let sessions = cycle.dates.compactMap { key -> AIPlanSession? in
                guard let day = state.days[key], !day.exercises.isEmpty else { return nil }
                return AIPlanSession(date: key, label: "训练", exercises: ClubPlanChangeRules.snapshot(day.exercises))
            }
            if let existing = versions[id], existing.recordedAt == .distantPast {
                versions[id] = ClubPlanVersion(id: id, recordedAt: .distantPast, source: existing.source, title: existing.title, start: min(existing.start, cycle.start), duration: min(28, existing.duration + 7), sessions: existing.sessions + sessions, requestedProfile: existing.requestedProfile, adoptedProfile: existing.adoptedProfile, nutrition: existing.nutrition, previousIDs: [], scopeDates: Array(Set(existing.scopeDates + cycle.dates)).sorted(), retainedDates: [])
                continue
            }
            versions[id] = ClubPlanVersion(id: id, recordedAt: .distantPast, source: "manual", title: "训练安排", start: cycle.start, duration: 7, sessions: sessions, requestedProfile: state.profile.aiProfile, adoptedProfile: state.profile.aiProfile, nutrition: state.nutritionTarget ?? NutritionTarget.estimate(state.profile), previousIDs: [], scopeDates: cycle.dates, retainedDates: [])
        }
        return versions.values.map { version in
            let actualDates = state.days.keys.filter { key in state.days[key]?.exercises.contains { $0.planID == version.id } == true }
            return ManagedPlan(version: version, liveDates: Array(Set(version.scopeDates + actualDates)).sorted())
        }.sorted { $0.version.recordedAt == $1.version.recordedAt ? $0.version.start > $1.version.start : $0.version.recordedAt > $1.version.recordedAt }
    }
    var currentPlanUsesAI: Bool {
        let today = ClubDates.key(Date())
        return managedPlans.first { !$0.dates.filter { $0 >= today }.isEmpty && !planIsEnded($0.id) }?.version.source == "ai"
    }
    func planIsEnded(_ id: String) -> Bool { PlanManagementRules.isCancelled(id, days: state.days) }
    func planIsArchived(_ id: String) -> Bool { state.days.values.contains { ($0.planActions ?? []).contains { $0.planID == id && $0.kind == "archived" } } }
    func exercises(in day: DayLog, ownedBy plan: ManagedPlan) -> [Exercise] {
        let expected = Set(plan.version.sessions.flatMap { session in session.exercises.indices.map { stableID("\(plan.id)/\(session.date)/\($0)") } })
        return day.exercises.filter { exercise in
            if let id = exercise.planID { return id == plan.id }
            if expected.contains(exercise.id) { return true }
            guard plan.version.recordedAt == .distantPast else { return false }
            if day.planCycle?.sourceJobID == plan.id || (plan.id.hasPrefix("legacy-plan-") && day.planCycle?.start == plan.version.start) { return true }
            return plan.version.scopeDates.contains { key in
                state.days[key]?.exercises.contains(where: { $0.id == exercise.id }) == true
            }
        }
    }
    func cancellableDates(for plan: ManagedPlan) -> [String] {
        let today = ClubDates.key(Date())
        return state.days.keys.sorted().filter { key in
            guard key >= today, let day = state.days[key], !PlanAdoptionRules.isProtected(day), !day.hasUnconfirmedTraining else { return false }
            return !exercises(in: day, ownedBy: plan).isEmpty
        }
    }
    @discardableResult func managePlan(_ id: String, action: String, expectedDays: [String: DayLog]? = nil) -> Bool {
        guard canSave, editingAccountID != nil, ["ended", "archived"].contains(action), let plan = managedPlans.first(where: { $0.id == id }) else { message = "计划已变化，请重新打开。"; return false }
        if let expectedDays {
            let keys = Set(plan.dates + cancellableDates(for: plan))
            guard keys.allSatisfy({ PlanAdoptionRules.sameTraining(state.days[$0] ?? DayLog(), expectedDays[$0] ?? DayLog()) }) else { message = "计划已变化，请重新核对取消范围。"; return false }
        }
        let previous = state
        let dates = action == "ended" ? Array(Set(plan.dates + state.days.keys.filter { !(state.days[$0].map { exercises(in: $0, ownedBy: plan).isEmpty } ?? true) })).sorted() : [plan.version.start]
        let eventID = UUID().uuidString
        for key in dates {
            var day = state.days[key] ?? DayLog()
            let ids = action == "ended" && key >= ClubDates.key(Date()) ? exercises(in: day, ownedBy: plan).map { $0.id.uuidString } : []
            let event = PlanLifecycleAction(id: eventID, planID: id, kind: action, createdAt: Date(), exerciseIDs: ids, clearsCycle: key >= ClubDates.key(Date()) && (day.planCycle?.sourceJobID == id || (id.hasPrefix("legacy-plan-") && day.planCycle?.start == plan.version.start)))
            day.planActions = (day.planActions ?? []) + [event]
            if key >= ClubDates.key(Date()) { PlanManagementRules.reconcile(&day) }
            state.days[key] = day
        }
        if persist(changedDates: dates) { return true }
        state = previous; return false
    }
}


extension AppStore {
    var isPreviewAccount126: Bool { editingAccountID == AccountService.previewUserID }
    var supersededPlanIDs126: Set<String> {
        Set(state.days.values.flatMap { $0.planVersions ?? [] }.flatMap(\.previousIDs))
    }
    /// One local journal transaction and one version. No row is applied early.
    func commitPlanEdit126(plan: ManagedPlan, draft: [PlanEditDay126], baseline: [String: DayLog], owner: Int) -> String? {
        guard canSave, editingAccountID == owner, let actual = managedPlans.first(where: { $0.id == plan.id }), actual.version == plan.version else {
            message = "账号或计划已变化，请重新打开。"; return nil
        }
        let previous = state
        let id = "manual-edit/" + UUID().uuidString.lowercased()
        do {
            let next = try PlanEditRules126.prepare(plan: plan, draft: draft, baseline: baseline, current: state.days, newID: id)
            state.days = next
            let keys = Set(plan.dates + draft.filter(\.editable).map(\.date))
            let first = keys.min() ?? plan.version.start
            let sessions = keys.sorted().compactMap { key -> AIPlanSession? in
                let exercises = (next[key]?.exercises ?? []).filter { $0.planID == id }
                return exercises.isEmpty ? nil : AIPlanSession(date: key, label: "训练", exercises: ClubPlanChangeRules.snapshot(exercises))
            }
            let retained = draft.filter { !$0.editable }.map(\.id)
            let span = (ClubDates.calendar.dateComponents([.day], from: ClubDates.date(fromKey: first) ?? Date(), to: ClubDates.date(fromKey: keys.max() ?? first) ?? Date()).day ?? 0) + 1
            let version = ClubPlanVersion(id: id, recordedAt: Date(), source: "manual", title: plan.version.title,
                start: first, duration: span <= 7 ? 7 : span <= 14 ? 14 : 28, sessions: sessions,
                requestedProfile: plan.version.requestedProfile, adoptedProfile: plan.version.adoptedProfile, nutrition: plan.version.nutrition,
                previousIDs: [plan.id], scopeDates: keys.sorted(), retainedDates: retained,
                changes: keys.sorted().map { key in ClubPlanDayChange(date: key,
                    before: ClubPlanChangeRules.snapshot(PlanEditRules126.owned(previous.days[key] ?? DayLog(), plan: plan, date: key)),
                    after: retained.contains(key) ? ClubPlanChangeRules.snapshot(PlanEditRules126.owned(previous.days[key] ?? DayLog(), plan: plan, date: key)) : ClubPlanChangeRules.snapshot((next[key]?.exercises ?? []).filter { $0.planID == id }), retained: retained.contains(key)) },
                planDescription: plan.version.planDescription, planIntent: plan.version.planIntent, planPattern: plan.version.planPattern,
                notes: ["成员确认编辑；历史训练与原版本保留。"])
            var day = state.days[first] ?? DayLog(); day.planVersions = (day.planVersions ?? []) + [version]; state.days[first] = day
            let oldIDs = draft.filter(\.editable).flatMap { PlanEditRules126.owned(previous.days[$0.id] ?? DayLog(), plan: plan, date: $0.id).map { $0.id.uuidString } }
            state.deletedExerciseIDs = Array(Set((state.deletedExerciseIDs ?? []) + oldIDs)).sorted()
            var changed = keys
            for key in keys { changed.formUnion(TrainingCycle.refreshPlannedDates(covering: key, in: &state.days)) }
            if persist(changedDates: changed.sorted()) { return id }
            state = previous; return nil
        } catch { state = previous; message = error.localizedDescription; return nil }
    }
}
