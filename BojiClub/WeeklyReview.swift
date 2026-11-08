import Foundation
import Combine
import UserNotifications
import CryptoKit

struct WeeklySurvey: Codable {
    var weight: Double?
    var waist: Double?
    var bodyFat: Double?
    var bodyFatSource = ""
    var fatigue = ""
    var pain = ""
    var difficulty = ""
    var diet = ""
    var notes = ""
    var days = 3
    var trainingDays: [Int]? = nil
}
struct ReviewPhoto: Codable, Identifiable {
    var id = UUID()
    var pose: String
    var filename: String
}
struct AIWeeklyTrainingMetrics: Codable, Equatable {
    var training_days: Int?
    var total_sessions: Int?
    var total_duration_minutes: Int?
    var total_completed_sets: Int?
    var total_volume_kg: Double?
    var volume_change_pct: Double?
}

struct AIWeeklyNutritionMetrics: Codable, Equatable {
    var average_calories: Double?
    var average_protein: Double?
    var days_with_records: Int?
    var complete_days_count: Int?
}

struct AIWeeklyBodyMetrics: Codable, Equatable {
    var start_weight_kg: Double?
    var end_weight_kg: Double?
    var weight_change_kg: Double?
    var weight_trend: String?
    var samples_count: Int?
}

struct AIWeeklyMetrics: Codable, Equatable {
    var training: AIWeeklyTrainingMetrics?
    var nutrition: AIWeeklyNutritionMetrics?
    var body: AIWeeklyBodyMetrics?
    var is_sufficient_for_analysis: Bool?
}

struct WeeklyResult: Codable {
    var kind: String
    var summary: String
    var training: String
    var nutrition: String
    var recovery: String
    var appearance: String
    var photoFeedback: [String]
    var decision: String
    var reason: String
    var notes: [String]
    var sessions: [AIPlanSession]
    var metrics: AIWeeklyMetrics? = nil
}
struct WeeklyReview: Codable, Identifiable {
    var id = UUID()
    var date: String
    var survey = WeeklySurvey()
    var photos: [ReviewPhoto] = []
    var compareWith: UUID?
    var jobID: String?
    var status = "draft"
    var result: WeeklyResult?
    var baseline: [String: [Exercise]] = [:]
    var applied = false
    var updatedAt = Date()
    var recoveredWithoutContext: Bool? = nil
    var priorJobIDs: [String]? = nil
    var cycle: TrainingCycle? = nil
    var scope: String? = nil
    var inputFingerprint: String? = nil
}
enum WeeklyVersions {
    // Use the same view of history on the home, plan and report-library pages.
    // Tombstones apply to both synced and local copies, including late jobs.
    static func visible(days: [String: DayLog], local: [WeeklyReview], deletedJobIDs: Set<String>) -> [WeeklyReview] {
        let deleted = Set(days.values.flatMap { $0.deletedWeeklyReviewIDs ?? [] }.map { $0.uppercased() })
        var records: [UUID: WeeklyReview] = [:]
        for item in days.values.flatMap(\.weeklyReviews) + local {
            guard item.status != "deleted", !deleted.contains(item.id.uuidString.uppercased()),
                  item.jobID.map({ !deletedJobIDs.contains($0) }) ?? true else { continue }
            if let existing = records[item.id] {
                if existing.recoveredWithoutContext != true && item.recoveredWithoutContext == true { continue }
                if (existing.recoveredWithoutContext == true) == (item.recoveredWithoutContext == true) && existing.updatedAt >= item.updatedAt { continue }
            }
            records[item.id] = item
        }
        let ordered = records.values.sorted {
            if ($0.recoveredWithoutContext == true) != ($1.recoveredWithoutContext == true) { return $0.recoveredWithoutContext != true }
            return $0.updatedAt == $1.updatedAt ? $0.id.uuidString > $1.id.uuidString : $0.updatedAt > $1.updatedAt
        }
        var jobs = Set<String>()
        return ordered.filter { item in
            guard let job = item.jobID else { return true }
            return jobs.insert(job).inserted
        }.sorted {
            $0.date == $1.date ? ($0.updatedAt == $1.updatedAt ? $0.id.uuidString > $1.id.uuidString : $0.updatedAt > $1.updatedAt) : $0.date > $1.date
        }
    }
    static func reconcile(_ day: inout DayLog) {
        let deleted = Set((day.deletedWeeklyReviewIDs ?? []).map { $0.uppercased() })
        var records: [UUID: WeeklyReview] = [:]
        for item in (day.weeklyReviewHistory ?? []) + [day.weeklyReview].compactMap({ $0 }) {
            guard item.result != nil, !deleted.contains(item.id.uuidString.uppercased()) else { continue }
            if let existing = records[item.id], existing.updatedAt > item.updatedAt { continue }
            records[item.id] = item
        }
        let ordered = records.values.sorted {
            $0.updatedAt == $1.updatedAt ? $0.id.uuidString > $1.id.uuidString : $0.updatedAt > $1.updatedAt
        }
        day.weeklyReview = ordered.first
        day.weeklyReviewHistory = ordered.count > 1 ? Array(ordered.dropFirst()) : nil
    }
    static func insert(_ review: WeeklyReview, into day: inout DayLog) {
        day.weeklyReviewHistory = (day.weeklyReviewHistory ?? []) + [review]
        reconcile(&day)
    }
    static func monthCopy(_ review: WeeklyReview, month: String) -> WeeklyReview {
        var copy = review
        copy.baseline = copy.baseline.filter { $0.key.hasPrefix(month + "-") }
        copy.result?.sessions.removeAll { !$0.date.hasPrefix(month + "-") }
        copy.photos = []; copy.compareWith = nil
        return copy
    }
    static func restore(_ day: inout DayLog, deletedJobIDs: Set<String>) {
        day.weeklyReviewHistory = day.weeklyReviews.filter { review in
            review.jobID.map { !deletedJobIDs.contains($0) } ?? true
        }.map { review in
            var copy = review; copy.photos = []; copy.applied = true; return copy
        }
        day.weeklyReview = nil
        reconcile(&day)
    }
}
extension DayLog {
    var weeklyReviews: [WeeklyReview] { [weeklyReview].compactMap { $0 } + (weeklyReviewHistory ?? []) }
}
extension WeeklyReview {
    var statusLabel: String {
        switch status {
        case "draft": return "待填写"
        case "submitting": return "正在提交"
        case "queued": return "等待分析"
        case "running": return "正在分析"
        case "retrying": return "正在重试"
        case "waiting_connection": return "等待网络连接"
        case "succeeded": return "已完成"
        case "failed", "rejected": return "未完成，可修改后重试"
        case "deleted": return "已删除"
        case "expired": return "已过期，请重新生成"
        default: return "正在确认分析进度"
        }
    }
}
private struct WeeklyResponse: Decodable {
    var status: String
    var result: WeeklyResult?
    var error_message: String?
    var error_code: String?
}
private struct WeeklyLocal: Codable {
    var reviews: [WeeklyReview] = []
    var reminder = false
    var weekday = 1
    var skippedUntil: Date?
}

/// Cross-device submission dedupe. A deterministic client job ID makes the
/// server's existing idempotent job creation collapse two devices submitting
/// the same fingerprint, while the local check also blocks a pending/succeeded
/// review that another device already synced.
enum WeeklyReviewSubmissionRules {
    static func isDuplicate(fingerprint: String, candidateFingerprint: String?, hasResult: Bool,
                            jobID: String?, status: String) -> Bool {
        guard candidateFingerprint == fingerprint else { return false }
        if hasResult { return true }
        guard let jobID, !jobID.isEmpty else { return false }
        return !["deleted", "expired", "rejected", "discarded"].contains(status)
    }
    static func deterministicJobID(owner: Int, cycleStart: String, fingerprint: String, attempt: Int = 0) -> String {
        let seed = "weekly-review|\(owner)|\(cycleStart)|\(fingerprint)|\(max(0, attempt))"
        let digest = Array(SHA256.hash(data: Data(seed.utf8)).prefix(16))
        let uuid = UUID(uuid: (digest[0], digest[1], digest[2], digest[3], digest[4], digest[5],
                               digest[6], digest[7], digest[8], digest[9], digest[10], digest[11],
                               digest[12], digest[13], digest[14], digest[15]))
        return uuid.uuidString.lowercased()
    }
}

@MainActor
final class WeeklyReviewService: ObservableObject {
    @Published private(set) var reviews: [WeeklyReview] = []
    @Published private(set) var busy = false
    @Published var message: String?
    @Published private(set) var reminder = false
    @Published private(set) var weekday = 1
    @Published private(set) var skippedUntil: Date?
    private var accountID: Int?
    private var generation = UUID()
    private var reminderGeneration = UUID()
    private var task: Task<Void, Never>?
    private var foregroundActive = true
    func setForeground(_ active: Bool) { foregroundActive = active }
    private var canSave = true
    private var reminderIDs: [String] { ["boji.weekly"] + (0..<8).map { "boji.weekly.skip.\($0)" } }
    private var folder: URL? {
        guard let accountID else { return nil }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BojiClub/weekly-\(accountID)")
    }
    func activate(_ id: Int?) {
        guard id != accountID else { return }
        task?.cancel(); task = nil; generation = UUID(); reminderGeneration = UUID(); busy = false
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: reminderIDs)
        accountID = id; reviews = []; reminder = false; weekday = 1; skippedUntil = nil; message = nil; canSave = true
        Task { await scheduleReminder() }
        guard let folder else { return }
        let file = folder.appendingPathComponent("reviews.json")
        do {
            if FileManager.default.fileExists(atPath: file.path) {
                let saved = try JSONDecoder().decode(WeeklyLocal.self, from: Data(contentsOf: file))
                reviews = saved.reviews; reminder = saved.reminder; weekday = saved.weekday; skippedUntil = saved.skippedUntil
            }
        } catch { canSave = false; message = "复盘记录暂时无法读取，请解锁手机后重新打开 App。" }
        if canSave && !cleanupUnreferencedPhotos() { message = "部分已移除的照片尚未清理，解锁手机后重新打开 App 会继续处理。" }
    }
    @discardableResult
    func eraseAccountData(_ id: Int) -> Bool {
        if accountID == id { task?.cancel(); task = nil; reminderGeneration = UUID(); UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: reminderIDs) }
        let target = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BojiClub/weekly-\(id)", isDirectory: true)
        do { if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) } }
        catch { return false }
        if accountID == id {
            reviews = []; reminder = false; weekday = 1; skippedUntil = nil; busy = false; message = nil
            Task { await scheduleReminder() }
        }
        return true
    }
    func persist() throws {
        guard canSave, var folder else { throw AccountError.message("本机复盘存储暂不可用。") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        let state = WeeklyLocal(reviews: reviews, reminder: reminder, weekday: weekday, skippedUntil: skippedUntil)
        try JSONEncoder().encode(state).write(to: folder.appendingPathComponent("reviews.json"), options: [.atomic, .completeFileProtection])
    }
    @discardableResult
    func save(_ review: WeeklyReview) -> Bool {
        let previous = reviews
        if let i = reviews.firstIndex(where: { $0.id == review.id }) { reviews[i] = review } else { reviews.insert(review, at: 0) }
        do { try persist(); return true } catch { reviews = previous; message = AppErrorText.message(error); return false }
    }
    func photo(_ value: ReviewPhoto) -> Data? {
        guard value.filename == value.id.uuidString.lowercased()+".jpg", let folder else { return nil }
        return try? Data(contentsOf: folder.appendingPathComponent(value.filename))
    }
    func addPhoto(_ data: Data, pose: String, to id: UUID) throws {
        guard !busy, let folder, let i = reviews.firstIndex(where: { $0.id == id && $0.result == nil && $0.jobID == nil }) else { throw AccountError.message("请先创建或重新打开复盘草稿。") }
        let photoID = UUID(); let filename = photoID.uuidString.lowercased()+".jpg"
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appendingPathComponent(filename), options: [.atomic, .completeFileProtection])
        var copy = reviews[i]; copy.photos.removeAll { $0.pose == pose }
        copy.photos.append(ReviewPhoto(id: photoID, pose: pose, filename: filename))
        let previous = reviews[i]; reviews[i] = copy
        do { try persist() }
        catch { reviews[i] = previous; try? FileManager.default.removeItem(at: folder.appendingPathComponent(filename)); throw error }
        // Updated drafts can share a photo with earlier reports. Delete only files
        // that no persisted review still references, after the new JSON is durable.
        if !cleanupUnreferencedPhotos() { message = "新照片已保存，部分不再使用的旧照片会在解锁后继续清理。" }
    }
    func removePhotos(_ id: UUID) throws {
        guard !busy, let i = reviews.firstIndex(where: { $0.id == id }), folder != nil else { return }
        let photos = reviews[i].photos; reviews[i].photos = []
        do { try persist() } catch { reviews[i].photos = photos; throw error }
        if !cleanupUnreferencedPhotos() { throw AccountError.message("照片已从记录移除，但本机文件尚未清理；解锁手机后重新打开 App 会继续处理。") }
    }
    private func cleanupUnreferencedPhotos() -> Bool {
        guard canSave, let folder else { return true }
        guard FileManager.default.fileExists(atPath: folder.path) else { return true }
        let retained = Set(reviews.flatMap(\.photos).map(\.filename))
        do {
            var complete = true
            for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
                let name = file.lastPathComponent
                guard file.pathExtension == "jpg", let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                      name == id.uuidString.lowercased()+".jpg", !retained.contains(name) else { continue }
                do { try FileManager.default.removeItem(at: file) } catch { complete = false }
            }
            return complete
        } catch { return false }
    }
    @discardableResult
    func skip() -> Bool {
        reminderGeneration = UUID()
        let previous = skippedUntil
        skippedUntil = Calendar.current.date(byAdding: .day, value: 7, to: Date())
        do { try persist() } catch { skippedUntil = previous; message = AppErrorText.message(error); return false }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: reminderIDs)
        Task { await scheduleReminder() }
        return true
    }
    func setReminder(_ enabled: Bool, weekday: Int) async {
        reminderGeneration = UUID(); let settingsTicket = reminderGeneration
        let ticket = generation
        let previous = (reminder, self.weekday)
        self.weekday = min(7, max(1, weekday))
        if enabled {
            do {
                let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert,.sound])
                guard ticket == generation, settingsTicket == reminderGeneration else { return }; reminder = allowed
            }
            catch { guard ticket == generation, settingsTicket == reminderGeneration else { return }; reminder = false; message = AppErrorText.message(error) }
            if !reminder { message = "提醒未开启，可在系统设置中允许通知；仍可从侧栏“我的记录 → 报告”主动复盘。" }
        } else { reminder = false }
        guard ticket == generation, settingsTicket == reminderGeneration else { return }
        do { try persist() } catch { reminder = previous.0; self.weekday = previous.1; message = AppErrorText.message(error) }
        await scheduleReminder()
    }
    private func scheduleReminder() async {
        reminderGeneration = UUID(); let ticket = reminderGeneration; let accountTicket = generation
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        guard ticket == reminderGeneration, accountTicket == generation else { return }
        center.removePendingNotificationRequests(withIdentifiers: reminderIDs + pending.map(\.identifier).filter { $0.hasPrefix("boji.weekly.gen.") })
        guard reminder, let owner = accountID else { return }
        let content = UNMutableNotificationContent(); content.title = "本周总结"; content.body = "本周训练、饮食和身体感受可生成总结。"; content.sound = .default
        content.userInfo = ["boji_kind": "weekly_center", "boji_account": owner]
        var components = DateComponents(); components.calendar = Calendar.current; components.weekday = weekday; components.hour = 19; components.minute = 0; components.second = 0
        var occurrences: [(DateComponents, Bool)] = []
        if let skippedUntil, skippedUntil > Date() {
            let calendar = Calendar.current
            guard var next = calendar.nextDate(after: skippedUntil, matching: components, matchingPolicy: .nextTime) else { return }
            for _ in 0..<8 {
                occurrences.append((calendar.dateComponents([.year,.month,.day,.hour,.minute], from: next), false))
                guard let following = calendar.date(byAdding:.day,value:7,to:next) else { break }; next = following
            }
        } else { occurrences = [(components, true)] }
        for (index, occurrence) in occurrences.enumerated() {
            guard ticket == reminderGeneration, accountTicket == generation else { return }
            let id = "boji.weekly.gen.\(ticket.uuidString).\(index)"
            do { try await center.add(UNNotificationRequest(identifier:id,content:content,trigger:UNCalendarNotificationTrigger(dateMatching:occurrence.0,repeats:occurrence.1))) }
            catch { if ticket == reminderGeneration, accountTicket == generation { message = "提醒保存失败：\(AppErrorText.message(error))" } }
            if ticket != reminderGeneration || accountTicket != generation { center.removePendingNotificationRequests(withIdentifiers:[id]); return }
        }
    }
    func submit(_ id: UUID, account: AccountService, store: AppStore, ai: AIService) {
        guard !busy, let user = accountID, account.user?.id == user, let i = reviews.firstIndex(where: { $0.id == id }), reviews[i].jobID == nil else { return }
        guard ai.routingConsentGranted else { message = "云端分析未开启。请在“设置 → 云端分析与隐私”开启后，再回来提交本周回顾。"; return }
        let ticket = generation; var review = reviews[i]
        guard let end = ClubDates.date(fromKey: review.date) else { return }
        do {
            let cycle = review.cycle ?? TrainingCycle(start: ClubDates.key(ClubDates.calendar.date(byAdding: .day, value: -6, to: end) ?? end.addingTimeInterval(-6 * 86_400)), plannedDates: [])
            let readiness = WeeklyReadiness(cycle: cycle, days: store.state.days)
            guard readiness.allowed(scope: review.scope ?? "combined") else { throw AccountError.message(readiness.explanation) }
            guard store.state.profile.hasConfirmedBasics else {
                throw AccountError.message("请先确认年龄、身高和资料体重，再生成每周回顾；未填写不会用示例数代替。你仍可正常记录训练与饮食。")
            }
            guard !review.survey.fatigue.isEmpty, !review.survey.difficulty.isEmpty, !review.survey.pain.isEmpty,
                  review.scope == "training" || !review.survey.diet.isEmpty else { throw AccountError.message("请先填写训练感受、难度、疼痛情况和适用的饮食反馈。") }
            var days: [JSONValue] = []; var upcoming: [JSONValue] = []
            review.baseline = [:]; review.recoveredWithoutContext = nil
            let currentNutritionTarget = store.state.nutritionTarget ?? NutritionTarget.estimate(store.state.profile)
            for key in cycle.dates {
                guard let date = ClubDates.date(fromKey: key) else { throw AccountError.message("训练周期日期不完整，请重新选择。") }
                let target = currentNutritionTarget.generalGuidanceOnly == true ? currentNutritionTarget : store.nutritionTarget(on: date)
                let input = try ai.reportInput(date: date, log: store.log(for: date), nutritionTarget: target, weightHistory: store.bodyWeightPoints(through: date), goalContext: ClubAIContext.make(state: store.state, start: date, end: date), allowEmpty: true)
                days.append(.object(["date":.string(ClubDates.key(date)), "payload":.object(input.payload)]))
            }
            for offset in 1...7 {
                guard let date = ClubDates.calendar.date(byAdding: .day, value: offset, to: end) else {
                    throw AccountError.message("日期计算失败，请重新进入每周回顾。")
                }
                let log = store.log(for: date); let key = ClubDates.key(date)
                review.baseline[key] = log.exercises
                upcoming.append(.object(["date":.string(key),"exercises":.array(try ai.planExercisesInput(log))]))
            }
            var photos: [JSONValue] = []
            let comparison = reviews.first { $0.id == review.compareWith }
            for entry in [Optional(review),comparison].compactMap({ $0 }) {
                for photo in entry.photos {
                    guard let data = self.photo(photo) else { throw AccountError.message("部分本机照片无法读取，请重新选图或不带照片提交。") }
                    photos.append(.object(["label":.string("\(entry.date) · \(photo.pose)"),"image_base64":.string(data.base64EncodedString())]))
                }
            }
            var historyByID: [UUID: WeeklyReview] = [:]
            for item in store.state.days.values.flatMap(\.weeklyReviews) { historyByID[item.id] = item }
            for item in reviews { historyByID[item.id] = item }
            let history: [JSONValue] = try historyByID.values.filter { $0.date < review.date && $0.result != nil }.sorted { $0.date > $1.date }.prefix(8).map {
                .object(["date":.string($0.date),"weight":try JSONValue.encode($0.survey.weight),"waist":try JSONValue.encode($0.survey.waist)])
            }
            let nutrition = currentNutritionTarget
            let nutritionReference: JSONValue
            if nutrition.generalGuidanceOnly == true {
                nutritionReference = .object(["generalGuidanceOnly": .bool(true)])
            } else {
                nutritionReference = try JSONValue.encode(nutrition)
            }
            let goalContext = try JSONValue.encode(ClubAIContext.make(state: store.state, start: ClubDates.date(fromKey: cycle.start) ?? end, end: end))
            let fingerprint: [String: JSONValue] = ["goal_context": goalContext, "cycle": try .encode(cycle), "scope": .string(review.scope ?? "combined"), "days": .array(days), "survey": try .encode(review.survey), "upcoming": .array(upcoming), "profile": try .encode(store.state.profile.aiProfile), "photos": .array(photos), "history": .array(history), "nutritionTarget": nutritionReference]
            let digest = ExperienceDigest.of(fingerprint)
            let candidates = reviews + store.state.days.values.flatMap(\.weeklyReviews)
            if let existing = candidates.first(where: { candidate in
                candidate.id != review.id && WeeklyReviewSubmissionRules.isDuplicate(
                    fingerprint: digest, candidateFingerprint: candidate.inputFingerprint,
                    hasResult: candidate.result != nil, jobID: candidate.jobID, status: candidate.status)
            }) {
                message = existing.result != nil
                    ? "相同记录已有复盘（\(existing.date)），请直接查看；补充记录后再更新分析。"
                    : "相同记录已有复盘正在生成（\(existing.date)），请稍后查看，避免重复提交。"
                return
            }
            review.inputFingerprint = digest; review.cycle = cycle
            // Deterministic ID so another device with the same fingerprint maps
            // to the same server job instead of creating a duplicate AI job.
            // A retry must create a fresh server job; the first attempt remains
            // device-independent so two devices submitting the same data collapse.
            let attempt = (review.priorJobIDs ?? []).count
            let jobID = WeeklyReviewSubmissionRules.deterministicJobID(owner: user, cycleStart: cycle.start,
                                                                       fingerprint: digest, attempt: attempt)
            review.jobID = jobID; review.status = "pending"
            let request = AIRequest(id: jobID, kind: "weekly_review", date: review.date, payload: ["goal_context":goalContext,"coaching_version":.number(1),"review_version":.number(1),"timeZone":.string(ClubDates.calendar.timeZone.identifier),"cycle":try .encode(cycle),"scope":.string(review.scope ?? "combined"),"_routing_version":.number(2),"analysis_version":.number(2),"profile":try JSONValue.encode(store.state.profile.aiProfile),"survey":try JSONValue.encode(review.survey),"days":.array(days),"upcoming":.array(upcoming),"photos":.array(photos),"history":.array(history),"nutritionTarget":nutritionReference])
            let body = try JSONEncoder().encode(request)
            guard body.count < 5_900_000 else { throw AccountError.message("照片较大，请减少对比照片后重试。") }
            let previous = reviews[i]; reviews[i] = review
            do { try persist() } catch { reviews[i] = previous; throw error }
            busy = true; message = nil
            task = Task {
                defer { if ticket == self.generation { self.busy = false } }
                do {
                    // Phase 3: durable Run + SSE. Tried first when the server has
                    // published the flag; any refusal falls back to the legacy
                    // POST + polling path with the same deterministic job id, so
                    // the server maps both to one analysis.
                    if await self.runKindPath(jobID: jobID, request: request, account: account, user: user,
                                              store: store, ticket: ticket, id: id) { return }
                    _ = try await self.call(jobID, method: "POST", body: body, account: account, user: user)
                    try await self.poll(id, account: account, store: store, user: user, ticket: ticket)
                } catch {
                    if ticket == self.generation, !Task.isCancelled {
                        self.handleSubmissionError(error, id: id)
                    }
                }
            }
        } catch { message = AppErrorText.message(error) }
    }
    func prepareRetry(_ id: UUID) {
        guard let index = reviews.firstIndex(where: { $0.id == id }), reviews[index].result == nil else { return }
        let previous = reviews[index]
        if let jobID = reviews[index].jobID { reviews[index].priorJobIDs = Array(Set((reviews[index].priorJobIDs ?? []) + [jobID])).sorted() }
        reviews[index].jobID = nil; reviews[index].status = "draft"
        do { try persist(); message = "问卷与本机照片已保留，请确认后重新提交。" }
        catch { reviews[index] = previous; message = "草稿保存失败，请稍后重试。" }
    }

    func reconcileCloudReviews(store: AppStore) {
        guard canSave, !busy else { return }
        let previous = reviews
        let deleted = Set(store.state.days.values.flatMap { $0.deletedWeeklyReviewIDs ?? [] }.map { $0.uppercased() })
        reviews.removeAll { deleted.contains($0.id.uuidString) }
        for canonical in store.state.days.values.flatMap(\.weeklyReviews) {
            guard let jobID = canonical.jobID else { continue }
            if let i = reviews.firstIndex(where: { $0.jobID == jobID && $0.recoveredWithoutContext == true }) {
                reviews.remove(at: i)
                if !reviews.contains(where: { $0.id == canonical.id }) { reviews.append(canonical) }
            }
        }
        guard (try? CloudMerge.same(previous, reviews)) != true else { return }
        do { try persist(); _ = cleanupUnreferencedPhotos() } catch { reviews = previous; message = "回顾合并暂未保存，请稍后重试。" }
    }

    func recoverTask(_ item: AIService.RecoveredTask, store: AppStore) {
        guard canSave, accountID != nil,
              !reviews.contains(where: { $0.jobID == item.id || ($0.priorJobIDs ?? []).contains(item.id) }) else { return }
        let previous = reviews
        if let canonical = store.state.days.values.flatMap(\.weeklyReviews).first(where: { $0.jobID == item.id }) {
            if !reviews.contains(where: { $0.id == canonical.id }) { reviews.append(canonical) }
        } else {
            let id = UUID(uuidString: item.id) ?? UUID()
            guard !reviews.contains(where: { $0.id == id }) else { return }
            var recovered = WeeklyReview(id: id, date: item.date, jobID: item.id, status: item.status)
            recovered.recoveredWithoutContext = true
            reviews.append(recovered)
        }
        do { try persist() } catch { reviews = previous; message = "后台回顾暂未恢复，请稍后重试。" }
    }

    func resume(_ id: UUID, account: AccountService, store: AppStore) {
        guard !busy, let user = accountID else { return }
        let ticket = generation; busy = true; message = nil
        task = Task {
            defer { if ticket == self.generation { self.busy = false } }
            do { try await self.poll(id, account: account, store: store, user: user, ticket: ticket) }
            catch { if ticket == self.generation, !Task.isCancelled { self.handleSubmissionError(error, id: id) } }
        }
    }
    /// Phase 3: durable Run + SSE for weekly_review. Returns true when the run
    /// reached a terminal state; false means the caller keeps the legacy path.
    private func runKindPath(jobID: String, request: AIRequest, account: AccountService, user: Int,
                             store: AppStore, ticket: UUID, id: UUID) async -> Bool {
        guard ticket == generation, !Task.isCancelled,
              FeatureFlagService.shared.runV2Enabled,
              AIService.runV2KindAllowed(request.kind) else { return false }
        let input = AIInput(kind: request.kind, date: request.date, payload: request.payload)
        do {
            let outcome = try await AIRunKindRunner.run(input: input, clientJobID: jobID, owner: user, account: account,
                                                         deadline: Date().addingTimeInterval(450))
            guard ticket == generation, !Task.isCancelled else { return true }
            let result = try outcome.weeklyResult()
            guard let i = reviews.firstIndex(where: { $0.id == id }) else { return true }
            let previous = reviews[i]
            reviews[i].result = result
            reviews[i].status = "succeeded"
            reviews[i].updatedAt = Date()
            do { try persist() } catch { reviews[i] = previous; message = AppErrorText.message(error) }
            if !store.saveWeeklyReview(reviews[i]) {
                message = "回顾结果已保存在这台手机，暂时没有同步成功。可在结果页重新同步。"
            }
            return true
        } catch let error as AIRunKindError {
            switch error {
            case .uncertain:
                // The create may have been accepted: never resubmit, resume by polling.
                return false
            case .disabled, .rejected:
                return false
            case .failed, .resyncUnavailable:
                guard ticket == generation, !Task.isCancelled else { return true }
                guard let i = reviews.firstIndex(where: { $0.id == id }) else { return true }
                let previous = reviews[i]
                reviews[i].status = "failed"
                do { try persist() } catch { reviews[i] = previous }
                message = error.localizedDescription + " 问卷和本机照片已保留，可以确认后重新提交。"
                return true
            }
        } catch {
            return false
        }
    }

    private func handleSubmissionError(_ error: Error, id: UUID) {
        if case AIClientError.http(let status, _, _) = error, [400, 403, 404, 409, 413, 422, 429].contains(status),
           let index = reviews.firstIndex(where: { $0.id == id }) {
            if let jobID = reviews[index].jobID { reviews[index].priorJobIDs = Array(Set((reviews[index].priorJobIDs ?? []) + [jobID])).sorted() }
        reviews[index].jobID = nil; reviews[index].status = "draft"
            do { try persist(); message = "\(AppErrorText.message(error)) 问卷和本机照片已保留，可以修改后重新提交。" }
            catch { message = "草稿保存失败，请稍后重试。" }
        } else { message = "\(AppErrorText.message(error)) 可继续查询；服务器没有受理时会恢复草稿。" }
    }

    private func call(_ id: String, method: String = "GET", body: Data? = nil, account: AccountService, user: Int) async throws -> Data {
        let response = try await account.cloudRequest(path: "/me/weekly/jobs/\(id)", method: method, body: body, expectedUserID: user)
        guard (200..<300).contains(response.statusCode) else {
            let reason = (try? JSONDecoder().decode(CloudErrorEnvelope.self, from: response.data))?.error ?? "复盘服务暂不可用。"
            throw AIClientError.http(response.statusCode, nil, reason)
        }
        return response.data
    }
    private func poll(_ id: UUID, account: AccountService, store: AppStore, user: Int, ticket: UUID) async throws {
        guard let job = reviews.first(where: { $0.id == id })?.jobID else { return }
        let deadline = Date().addingTimeInterval(450)
        for attempt in 0..<150 {
            try Task.checkCancellation()
            while !foregroundActive {
                try await Task.sleep(for: .seconds(2))
                guard generation == ticket, accountID == user else { return }
            }
            let raw = try await call(job, account: account, user: user)
            guard generation == ticket, let i = reviews.firstIndex(where: { $0.id == id }) else { return }
            let response = try JSONDecoder().decode(WeeklyResponse.self, from: raw)
            let statusChanged = reviews[i].status != response.status
            reviews[i].status = response.status
            if response.status == "succeeded", let result = response.result {
                let firstCompletion = reviews[i].result == nil
                reviews[i].result = result; reviews[i].updatedAt = Date(); try persist()
                if firstCompletion { AppNotificationService.notifyWeeklyReviewReady(date: ClubDates.date(fromKey: reviews[i].date) ?? Date(), accountID: accountID) }
                if reviews[i].recoveredWithoutContext == true {
                    message = "分析结果已恢复，原问卷和计划对比资料将继续通过账号同步恢复。"
                } else if !store.saveWeeklyReview(reviews[i]) { message = "回顾结果已保存在这台手机，暂时没有同步成功。可在结果页重新同步。" }; return
            }
            if statusChanged { try persist() }
            if ["failed","deleted","expired","rejected"].contains(response.status) {
                prepareRetry(id)
                let reason = AIVisibleError.message(code: response.error_code, fallback: response.error_message)
                if let reason { message = reason + " 问卷和本机照片已保留，可以确认后重新提交。" }
                return
            }
            if Date() >= deadline { break }
            try await Task.sleep(for: .seconds(min(15, 3 + Double(attempt) * 1.5)))
        }
        message = "还在分析中，可以稍后回来查看。"
    }
    func delete(_ review: WeeklyReview, account: AccountService, store: AppStore) async {
        guard let user = accountID else { return }
        task?.cancel(); generation = UUID(); busy = true
        let ticket = generation
        defer { if ticket == generation { busy = false } }
        do {
            if let job = review.jobID { _ = try await call(job, method: "DELETE", account: account, user: user) }
            guard ticket == generation else { return }
            let previous = reviews
            reviews.removeAll { $0.id == review.id }
            do { try persist() } catch { reviews = previous; throw error }
            guard store.removeWeeklyReview(review) else {
                reviews = previous; try persist()
                throw AccountError.message("云端摘要的删除尚未保存，请重试。")
            }
            message = cleanupUnreferencedPhotos()
                ? "复盘记录及本机照片已删除，云端摘要将在联网后同步删除。已采用的训练安排继续保留。"
                : "复盘记录已删除，部分本机照片尚未清理；解锁手机后重新打开 App 会继续处理。"
        } catch { if ticket == generation { message = "删除未完成，请联网后重试：\(AppErrorText.message(error))" } }
    }
}
