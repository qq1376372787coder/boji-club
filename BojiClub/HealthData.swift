import Foundation
import HealthKit
import Combine

struct HealthSource: Codable, Hashable, Identifiable {
    var id: String
    var name: String
}

struct HealthMetric: Codable {
    var value: Double
    var source: HealthSource
    var availableSources: [HealthSource]?
    var recordedAt: Date? = nil
}

struct DeviceWorkout: Codable, Identifiable {
    var id: String
    var name: String
    var start: Date
    var end: Date
    var minutes: Double
    var calories: Double?
    var source: HealthSource
    var activityKind: String? = nil
    var averageHeartRate: Double? = nil

    var comparableKind: String? {
        if let activityKind, activityKind != "other" { return activityKind }
        return ["跑步": "running", "步行": "walking", "骑行": "cycling", "游泳": "swimming",
                "力量训练": "strength", "间歇训练": "interval", "瑜伽": "yoga", "徒步": "hiking", "划船": "rowing",
                "椭圆机": "elliptical", "爬楼梯": "stairs", "跳绳": "jumpRope", "舞蹈": "dance"][name]
    }
}

struct HealthWeightSample: Codable, Identifiable {
    var id: String
    var externalID: String
    var date: Date
    var kilograms: Double
    var source: HealthSource
}
private struct HealthWeightCache: Codable {
    var anchor: Data? = nil
    var samples: [String: HealthWeightSample] = [:]
    var deleted: [String: [String]] = [:]
}

struct HealthDay: Codable {
    var date: String
    var timeZone: String
    var updatedAt: Date
    var steps: HealthMetric?
    var activeEnergy: HealthMetric?
    var heartRate: HealthMetric?
    var restingHeartRate: HealthMetric?
    var sleep: HealthMetric?
    // Local display only. Cloud analysis retains the existing calendar-day sleep contract.
    var nightSleep: HealthMetric? = nil
    var nightSleepStart: Date? = nil
    var nightSleepEnd: Date? = nil
    var napSleep: HealthMetric? = nil
    var recentBodyMass: HealthMetric? = nil
    var recentBodyFatPercentage: HealthMetric? = nil
    var recentWaistCircumference: HealthMetric? = nil
    // Optional HealthKit measurements stay separate from manually entered logs.
    var bodyMass: HealthMetric?
    var bodyFatPercentage: HealthMetric?
    var leanBodyMass: HealthMetric?
    var height: HealthMetric?
    var bodyMassIndex: HealthMetric?
    var waistCircumference: HealthMetric?
    var workouts: [DeviceWorkout] = []
    var weightSamples: [HealthWeightSample]? = nil
    var deletedWeightSampleIDs: [String]? = nil
    var hasData: Bool {
        steps != nil || activeEnergy != nil || heartRate != nil || restingHeartRate != nil || sleep != nil ||
        !(weightSamples ?? []).isEmpty || !(deletedWeightSampleIDs ?? []).isEmpty || bodyMass != nil || bodyFatPercentage != nil || leanBodyMass != nil || height != nil || bodyMassIndex != nil || waistCircumference != nil || !workouts.isEmpty
    }
    var sharingSummary: HealthDay {
        var shared = self
        shared.nightSleep = nil; shared.nightSleepStart = nil; shared.nightSleepEnd = nil; shared.napSleep = nil
        shared.recentBodyMass = nil; shared.recentBodyFatPercentage = nil; shared.recentWaistCircumference = nil
        shared.steps?.availableSources = nil; shared.activeEnergy?.availableSources = nil
        shared.heartRate?.availableSources = nil; shared.restingHeartRate?.availableSources = nil; shared.sleep?.availableSources = nil
        shared.bodyMass?.availableSources = nil; shared.bodyFatPercentage?.availableSources = nil
        shared.leanBodyMass?.availableSources = nil; shared.height?.availableSources = nil
        shared.bodyMassIndex?.availableSources = nil; shared.waistCircumference?.availableSources = nil
        return shared
    }
    var sources: [HealthSource] {
        let metrics = [steps, activeEnergy, heartRate, restingHeartRate, sleep, bodyMass, bodyFatPercentage,
                       leanBodyMass, height, bodyMassIndex, waistCircumference]
        return Array(Set(metrics.compactMap { $0?.source } + workouts.map(\.source))).sorted { $0.name < $1.name }
    }
    static func deduplicated(_ values: [DeviceWorkout], preferred: String) -> [DeviceWorkout] {
        let ordered = values.sorted {
            let l = $0.source.id == preferred ? 0 : $0.source.id == "tcx" ? 2 : 1
            let r = $1.source.id == preferred ? 0 : $1.source.id == "tcx" ? 2 : 1
            return l == r ? $0.id < $1.id : l < r
        }
        var result: [DeviceWorkout] = []
        for workout in ordered {
            let duplicate = result.contains { existing in
                if existing.id == workout.id { return true }
                // Different activities or two entries from one device are not proven duplicates.
                guard existing.source.id != workout.source.id,
                      let kind = existing.comparableKind, kind == workout.comparableKind else { return false }
                let overlap = min(existing.end, workout.end).timeIntervalSince(max(existing.start, workout.start))
                let longest = max(existing.end.timeIntervalSince(existing.start), workout.end.timeIntervalSince(workout.start))
                return longest > 0 && overlap / longest > 0.8
            }
            if !duplicate { result.append(workout) }
        }
        return result.sorted { $0.start < $1.start }
    }
}

struct HealthShareReviewRequest: Identifiable {
    let id = UUID()
    let ownerID: Int
    let date: Date
    let summary: HealthDay
    let expectedSharedHealth: Data?
    let expectedWorkout: Data?
    let expectedSessionID: UUID?
    var allowsLink: Bool { expectedWorkout != nil }

    init(ownerID: Int, date: Date, summary: HealthDay, day: DayLog, allowsLink: Bool) {
        self.ownerID = ownerID; self.date = date; self.summary = summary
        expectedSessionID = day.activeWorkoutSessionID
        expectedSharedHealth = HealthShareConsent.encoded(day.health)
        expectedWorkout = allowsLink && day.trainingLog.completedSets > 0 ? HealthShareConsent.workoutContext(day) : nil
    }
}

enum HealthShareConsent {
    static let disclosure = "确认后，所选日期的体重样本及其来源与删除标识、步数、活动能量、睡眠、心率汇总、身体成分测量、数据来源和设备运动记录会保存到薄肌云端及运营后台；生成复盘时按你确认的 AI 数据使用说明分析。不会上传原始心率序列或 GPS 轨迹。刷新不会自动再次分享。"
    static func encoded<T: Encodable>(_ value: T) -> Data? {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(value)
    }
    private struct WorkoutContext: Encodable {
        let exercises: [Exercise]
        let startedAt, endedAt, savedAt: Date?
        let linkedID: String?
        let sessionID: UUID?
    }
    static func workoutContext(_ day: DayLog) -> Data? {
        let selected = day.trainingLog
        return encoded(WorkoutContext(exercises:selected.exercises,startedAt:selected.workoutStartedAt,endedAt:selected.workoutEndedAt,savedAt:selected.workoutSavedAt,linkedID:selected.linkedDeviceWorkoutID,sessionID:day.activeWorkoutSessionID))
    }
    static func initialWorkoutID(_ request: HealthShareReviewRequest, day: DayLog) -> String? {
        guard request.allowsLink else { return nil }
        if let linked = day.linkedDeviceWorkoutID, request.summary.workouts.contains(where: { $0.id == linked }) { return linked }
        let suggestions = WorkoutAssociation.suggestedIDs(for:day,workouts:request.summary.workouts)
        return suggestions.count == 1 ? suggestions.first : nil
    }
    static func issue(_ request: HealthShareReviewRequest, workoutID: String?, current: DayLog, ownerID: Int?, now: Date = Date()) -> String? {
        guard ownerID == request.ownerID else { return "账号已变化，请重新打开健康确认页。" }
        guard !ClubDates.isFuture(request.date,now:now), request.summary.date == ClubDates.key(request.date) else { return "健康数据日期不匹配，请重新读取。" }
        guard request.summary.hasData else { return "这一天没有可分享的健康数据。" }
        guard valid(request.summary) else { return "健康记录内容异常，请刷新后重新核对。" }
        guard let baseline = request.expectedSharedHealth, baseline == encoded(current.health) else { return "已分享的健康记录发生变化，请重新打开确认页。" }
        if request.expectedSessionID != current.activeWorkoutSessionID { return "当前训练已切换，请重新打开核对页。" }
        if let workoutID {
            if current.workoutSessions?.contains(where: { $0.id != current.activeWorkoutSessionID && $0.linkedDeviceWorkoutID == workoutID }) == true {
                return "这条设备记录已关联当天另一次训练，请选择另一条，或先取消原关联。"
            }
            guard let context = request.expectedWorkout, current.trainingLog.completedSets > 0, context == workoutContext(current) else { return "本次训练发生变化，请重新核对后关联。" }
            guard request.summary.workouts.contains(where: { $0.id == workoutID && ClubDates.key($0.start) == request.summary.date }) else { return "所选设备训练不属于这一天，请重新选择。" }
        }
        return nil
    }
    private static func valid(_ summary: HealthDay) -> Bool {
        func number(_ value: Double?) -> Bool { value.map { $0.isFinite && (0...10_000_000).contains($0) } ?? true }
        func bounded(_ metric: HealthMetric?, _ range: ClosedRange<Double>) -> Bool {
            guard let metric else { return true }
            return range.contains(metric.value) && (metric.recordedAt?.timeIntervalSinceReferenceDate.isFinite ?? true)
        }
        guard summary.updatedAt.timeIntervalSinceReferenceDate.isFinite,
              [summary.steps,summary.activeEnergy,summary.heartRate,summary.restingHeartRate,summary.sleep,
               summary.bodyMass,summary.bodyFatPercentage,summary.leanBodyMass,summary.height,
               summary.bodyMassIndex,summary.waistCircumference].allSatisfy({ number($0?.value) }),
              Set(summary.workouts.map(\.id)).count == summary.workouts.count,
              bounded(summary.bodyMass, 20...400), bounded(summary.bodyFatPercentage, 0...100),
              bounded(summary.leanBodyMass, 1...400), bounded(summary.height, 50...250),
              bounded(summary.bodyMassIndex, 5...100), bounded(summary.waistCircumference, 20...300) else { return false }
        return summary.workouts.allSatisfy {
            !$0.id.isEmpty && $0.start.timeIntervalSinceReferenceDate.isFinite && $0.end.timeIntervalSinceReferenceDate.isFinite &&
            $0.end > $0.start && number($0.minutes) && number($0.calories) && number($0.averageHeartRate) && ClubDates.key($0.start) == summary.date
        }
    }
}

private struct HealthLocalState: Codable {
    var enabled = false
    var writeWorkoutsEnabled = false
    var writtenWorkoutSessionIDs: [String] = []
    var preferredSource = ""
    var days: [String: HealthDay] = [:]
    var imported: [DeviceWorkout] = []

    private enum CodingKeys: String, CodingKey {
        case enabled, writeWorkoutsEnabled, writtenWorkoutSessionIDs, preferredSource, days, imported
    }

    init(enabled: Bool = false, writeWorkoutsEnabled: Bool = false, writtenWorkoutSessionIDs: [String] = [],
         preferredSource: String = "", days: [String: HealthDay] = [:], imported: [DeviceWorkout] = []) {
        self.enabled = enabled
        self.writeWorkoutsEnabled = writeWorkoutsEnabled
        self.writtenWorkoutSessionIDs = writtenWorkoutSessionIDs
        self.preferredSource = preferredSource
        self.days = days
        self.imported = imported
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        writeWorkoutsEnabled = try values.decodeIfPresent(Bool.self, forKey: .writeWorkoutsEnabled) ?? false
        writtenWorkoutSessionIDs = try values.decodeIfPresent([String].self, forKey: .writtenWorkoutSessionIDs) ?? []
        preferredSource = try values.decodeIfPresent(String.self, forKey: .preferredSource) ?? ""
        days = try values.decodeIfPresent([String: HealthDay].self, forKey: .days) ?? [:]
        imported = try values.decodeIfPresent([DeviceWorkout].self, forKey: .imported) ?? []
    }
}

@MainActor
final class HealthDataService: ObservableObject {
    @Published private(set) var days: [String: HealthDay] = [:]
    @Published private(set) var busy = false
    @Published private(set) var enabled = false
    @Published private(set) var writeWorkoutsEnabled = false
    @Published private(set) var preferredSource = ""
    @Published var message: String?
    private let health = HKHealthStore()
    @Published private(set) var writeWeightsEnabled = false
    private var weightCache = HealthWeightCache()
    private var weightCacheAvailable = true
    private var accountID: Int?
    private var generation = UUID()
    private var imported: [DeviceWorkout] = []
    private var writtenWorkoutSessionIDs = Set<String>()
    private var writeInProgress = Set<String>()
    private var storageAvailable = true
    private var queryCancellations: [UUID: () -> Void] = [:]
    private func cancelQuery(_ id: UUID) { queryCancellations.removeValue(forKey: id)?() }
    private func finishQuery(_ id: UUID) -> Bool {
        if let _ = queryCancellations.removeValue(forKey: id) { return true }
        return false
    }
    private func cancelQueries() {
        let cancellations = Array(queryCancellations.values)
        queryCancellations.removeAll()
        cancellations.forEach { $0() }
    }
    var available: Bool { HKHealthStore.isHealthDataAvailable() }
    func connectionStatus(for date: Date) -> String {
        guard available else { return "此设备不支持 Apple 健康" }
        guard enabled else { return "尚未请求 Apple 健康读取授权" }
        if let day=summary(for:date), day.sources.contains(where:{$0.id != "tcx"}) { return "已读取到所选日期的健康数据" }
        return "已请求读取授权，所选日期暂未读到数据"
    }
    var sources: [HealthSource] {
        let values = days.values.flatMap { day in
            [day.steps, day.activeEnergy, day.heartRate, day.restingHeartRate, day.sleep].flatMap { $0?.availableSources ?? [] } + day.sources
        }
        return Array(Set(values)).filter { $0.id != "tcx" }.sorted { $0.name < $1.name }
    }
    private var file: URL? {
        guard let accountID else { return nil }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BojiClub/health-user-\(accountID).json")
    }
    func activate(_ id: Int?) {
        guard accountID != id else { return }
        cancelQueries()
        generation = UUID(); accountID = id; days = [:]; imported = []; enabled = false; writeWorkoutsEnabled = false
        weightCache = HealthWeightCache(); weightCacheAvailable = true
        writeWeightsEnabled = id.map { UserDefaults.standard.bool(forKey: "health.write-weight.user-\($0)") } ?? false
        if let weightFile, FileManager.default.fileExists(atPath: weightFile.path) {
            do { weightCache = try JSONDecoder().decode(HealthWeightCache.self, from: Data(contentsOf: weightFile)) } catch { weightCacheAvailable = false; message = "体重同步缓存无法读取，原文件保留。" }
        }
        writtenWorkoutSessionIDs = []; busy = false; preferredSource = ""; message = nil; storageAvailable = true
        guard let file, FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            let saved = try JSONDecoder().decode(HealthLocalState.self, from: Data(contentsOf: file))
            enabled = saved.enabled; writeWorkoutsEnabled = saved.writeWorkoutsEnabled
            writtenWorkoutSessionIDs = Set(saved.writtenWorkoutSessionIDs)
            preferredSource = saved.preferredSource; days = saved.days; imported = saved.imported
        } catch { storageAvailable = false; message = "本机健康记录暂时无法读取，请解锁设备后重启 App。" }
    }
    @discardableResult
    func eraseAccountData(_ id: Int) -> Bool {
        if accountID == id { cancelQueries(); generation = UUID() }
        let target = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BojiClub/health-user-\(id).json")
        do { if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) } }
        catch { return false }
        let weights = target.deletingLastPathComponent().appendingPathComponent("health-weights-user-\(id).json")
        do { if FileManager.default.fileExists(atPath: weights.path) { try FileManager.default.removeItem(at: weights) } } catch { return false }
        UserDefaults.standard.removeObject(forKey: "health.write-weight.user-\(id)")
        if accountID == id {
            weightCache = HealthWeightCache(); writeWeightsEnabled = false
            days = [:]; imported = []; enabled = false; writeWorkoutsEnabled = false
            writtenWorkoutSessionIDs = []; busy = false; preferredSource = ""; message = nil
        }
        return true
    }
    private func save() throws {
        guard storageAvailable, let file else { throw HealthImportError.message("本机健康记录不可用，请解锁设备后重试。") }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var folder = file.deletingLastPathComponent(); var values = URLResourceValues(); values.isExcludedFromBackup = true; try folder.setResourceValues(values)
        let state = HealthLocalState(enabled: enabled, writeWorkoutsEnabled: writeWorkoutsEnabled,
                                     writtenWorkoutSessionIDs: Array(writtenWorkoutSessionIDs).sorted(),
                                     preferredSource: preferredSource, days: days, imported: imported)
        try JSONEncoder().encode(state).write(to: file, options: [.atomic, .completeFileProtection])
    }
    private var readTypes: Set<HKObjectType> {
        // 系统标准标识符由 HealthKit 保证存在；compactMap 仍避免任何异常路径下的强解包。
        let identifiers: [HKQuantityTypeIdentifier] = [.stepCount, .activeEnergyBurned, .heartRate, .restingHeartRate, .bodyMass, .bodyFatPercentage, .leanBodyMass, .height, .bodyMassIndex, .waistCircumference]
        var types: Set<HKObjectType> = Set(identifiers.compactMap { HKObjectType.quantityType(forIdentifier: $0) })
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { types.insert(sleep) }
        types.insert(HKObjectType.workoutType())
        return types
    }
    func connect(on date: Date = Date()) async {
        guard available, !busy, accountID != nil, storageAvailable else { message = "此设备暂时无法读取健康数据，请在 iPhone 真机上使用。"; return }
        let ticket = generation
        busy = true; message = nil
        do {
            try await health.requestAuthorization(toShare: writeWorkoutsEnabled ? [HKObjectType.workoutType()] : [], read: readTypes)
            guard ticket == generation else { return }
            // Completion means the permission sheet finished, not that read access was granted.
            let previous = enabled; enabled = true
            do { try save() } catch { enabled = previous; throw error }; busy = false
            await refresh(date)
        } catch {
            guard ticket == generation else { return }
            message = "未能完成健康数据授权：\(AppErrorText.message(error))"; busy = false
        }
    }
    func setWorkoutWritingEnabled(_ enabled: Bool) async {
        guard available, !busy, accountID != nil, storageAvailable else {
            message = "请先连接 Apple 健康，再开启训练写入。"; return
        }
        let ticket = generation
        let previous = writeWorkoutsEnabled
        busy = true; message = nil
        do {
            try await health.requestAuthorization(
                toShare: enabled ? [HKObjectType.workoutType()] : [],
                read: readTypes
            )
            guard ticket == generation else { return }
            if enabled && health.authorizationStatus(for: HKObjectType.workoutType()) != .sharingAuthorized {
                writeWorkoutsEnabled = false
                try save()
                message = "未授予训练写入权限。可在 iOS 健康的应用权限中开启后再试。"
                busy = false
                return
            }
            writeWorkoutsEnabled = enabled
            do { try save() } catch { writeWorkoutsEnabled = previous; throw error }
            message = enabled
                ? "已开启训练写入选项。每次结束后仍需你确认；不会写入估算热量或心率。"
                : "已关闭后续训练写入。此前保存到 Apple 健康的记录不会删除。"
        } catch {
            guard ticket == generation else { return }
            writeWorkoutsEnabled = previous
            message = "训练写入授权未完成：\(AppErrorText.message(error))"
        }
        if ticket == generation { busy = false }
    }

    /// Only called after the user confirms export on the completed-workout screen.
    /// The sync identifier makes retries idempotent when HealthKit already saved the sample.
    func hasWrittenWorkout(_ sessionID: UUID) -> Bool {
        writtenWorkoutSessionIDs.contains("com.bojiclub.app.workout." + sessionID.uuidString.lowercased())
    }
    func writeConfirmedWorkout(sessionID: UUID, start: Date, end: Date, completedSets: Int, expectedOwner: Int? = nil, pauseIntervals: [WorkoutPauseInterval] = []) async throws -> String {
        guard writeWorkoutsEnabled, available, accountID != nil else {
            throw HealthImportError.message("请先在设备与健康设置中连接并开启训练写入。")
        }
        let ticket = generation
        let capturedAccountID = accountID
        guard expectedOwner == nil || capturedAccountID == expectedOwner else { throw CancellationError() }
        func validateOwner() throws {
            guard !Task.isCancelled, ticket == generation, capturedAccountID == accountID, writeWorkoutsEnabled else { throw CancellationError() }
        }
        try validateOwner()
        guard completedSets > 0, start < end, end <= Date() else {
            throw HealthImportError.message("本次训练缺少有效的开始、结束时间或完成组数，暂不能写入。")
        }
        let sessionKey = "com.bojiclub.app.workout.\(sessionID.uuidString.lowercased())"
        if writtenWorkoutSessionIDs.contains(sessionKey) { return "这次训练已写入 Apple 健康。" }
        guard writeInProgress.insert(sessionKey).inserted else {
            throw HealthImportError.message("正在写入这次训练，请稍候。")
        }
        defer { writeInProgress.remove(sessionKey) }

        let syncPredicate = HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeySyncIdentifier, allowedValues: [sessionKey])
        let existing = try await samples(type: HKObjectType.workoutType(), start: start, end: end,
                                         metadataPredicate: syncPredicate)
        try validateOwner()
        if existing.contains(where: { $0.metadata?[HKMetadataKeySyncIdentifier] as? String == sessionKey }) {
            writtenWorkoutSessionIDs.insert(sessionKey)
            try save()
            return "这次训练已存在于 Apple 健康，没有重复创建。"
        }

        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .traditionalStrengthTraining
        configuration.locationType = .indoor
        let builder = HKWorkoutBuilder(healthStore: health, configuration: configuration, device: .local())
        try await builder.addMetadata([
            HKMetadataKeySyncIdentifier: sessionKey,
            HKMetadataKeySyncVersion: 1,
            HKMetadataKeyWorkoutBrandName: "薄肌俱乐部"
        ])
        do { try validateOwner() } catch { builder.discardWorkout(); throw error }
        try await builder.beginCollection(at: start)
        do { try validateOwner() } catch { builder.discardWorkout(); throw error }
        let events = pauseIntervals.flatMap { interval -> [HKWorkoutEvent] in
            guard let stop = interval.end, interval.start >= start, stop > interval.start, stop <= end else { return [] }
            return [HKWorkoutEvent(type: .pause, dateInterval: DateInterval(start: interval.start, duration: 0), metadata: nil),
                    HKWorkoutEvent(type: .resume, dateInterval: DateInterval(start: stop, duration: 0), metadata: nil)]
        }
        if !events.isEmpty { try await builder.addWorkoutEvents(events) }
        try await builder.endCollection(at: end)
        do { try validateOwner() } catch { builder.discardWorkout(); throw error }
        let finishedWorkout: HKWorkout?
        do {
            finishedWorkout = try await builder.finishWorkout()
        } catch {
            builder.discardWorkout()
            throw error
        }
        // R07/DI-021: Continuous account generation / owner verification post-await
        guard ticket == generation, capturedAccountID == accountID else {
            throw HealthImportError.message("账号在写入过程中已切换，已放弃保存旧账号写入收据。")
        }
        writtenWorkoutSessionIDs.insert(sessionKey)
        try save()
        if finishedWorkout == nil {
            return "训练已提交到 Apple 健康。设备锁定时，系统可能暂不返回可读取的训练详情；只同步训练时段，不会生成估算热量或心率。"
        }
        return "训练已写入 Apple 健康。只同步训练时段，不会生成估算热量或心率。"
    }
    func disconnect() {
        cancelQueries()
        let previous = HealthLocalState(enabled: enabled, writeWorkoutsEnabled: writeWorkoutsEnabled,
                                        writtenWorkoutSessionIDs: Array(writtenWorkoutSessionIDs),
                                        preferredSource: preferredSource, days: days, imported: imported)
        generation = UUID(); enabled = false; writeWorkoutsEnabled = false; busy = false
        days = [:]; imported = []; preferredSource = ""
        do {
            try save()
            message = "已停止读取并清除本机设备缓存。系统读取权限可在 Apple 健康中关闭；此前确认保存的云端记录和日报继续保留。"
        } catch {
            enabled = previous.enabled; writeWorkoutsEnabled = previous.writeWorkoutsEnabled
            writtenWorkoutSessionIDs = Set(previous.writtenWorkoutSessionIDs)
            preferredSource = previous.preferredSource; days = previous.days; imported = previous.imported
            message = "本机缓存清除未完成，请重试：\(AppErrorText.message(error))"
        }
    }
    func prefer(_ id: String) {
        let previous = preferredSource; preferredSource = id
        do { try save() } catch { preferredSource = previous; message = "来源设置未保存：\(AppErrorText.message(error))" }
    }
    func summary(for date: Date) -> HealthDay? { days[ClubDates.key(date)] }
    func refresh(_ date: Date, force: Bool = false) async {
        if !force, let cached = days[ClubDates.key(date)], Date().timeIntervalSince(cached.updatedAt) < 60 { return }
        let requestedGeneration = generation
        guard enabled, available, accountID != nil, storageAvailable else { return }
        while busy {
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            guard requestedGeneration == generation, enabled else { return }
        }
        guard !Task.isCancelled, requestedGeneration == generation else { return }
        if !force, let cached = days[ClubDates.key(date)], Date().timeIntervalSince(cached.updatedAt) < 60 { return }
        let start = ClubDates.calendar.startOfDay(for: date)
        guard start <= Date(), let end = ClubDates.calendar.date(byAdding: .day, value: 1, to: start) else { return }
        let ticket = generation; let preferred = preferredSource
        busy = true; message = nil
        defer { if ticket == generation { busy = false } }
        do {
            try await refreshWeightDelta(ticket: ticket)
            var day = HealthDay(date: ClubDates.key(date), timeZone: TimeZone.current.identifier, updatedAt: Date())
            day.weightSamples = weightCache.samples.values.filter { $0.date >= start && $0.date < end }.sorted { $0.date < $1.date }
            day.deletedWeightSampleIDs = weightCache.deleted[ClubDates.key(date)]
            async let steps = quantity(.stepCount, unit: .count(), start: start, end: end, cumulative: true, preferred: preferred)
            async let energy = quantity(.activeEnergyBurned, unit: .kilocalorie(), start: start, end: end, cumulative: true, preferred: preferred)
            async let heart = quantity(.heartRate, unit: HKUnit.count().unitDivided(by: .minute()), start: start, end: end, cumulative: false, preferred: preferred)
            async let resting = quantity(.restingHeartRate, unit: HKUnit.count().unitDivided(by: .minute()), start: start, end: end, cumulative: false, preferred: preferred)
            async let sleeping = sleep(start: start, end: end, preferred: preferred)
            async let night = mainSleep(start: start, end: end, preferred: preferred)
            async let recentMass = latestQuantity(.bodyMass, unit: HKUnit.gramUnit(with: .kilo), start: .distantPast, end: end, preferred: preferred)
            async let recentFat = latestQuantity(.bodyFatPercentage, unit: .percent(), start: .distantPast, end: end, preferred: preferred, percent: true)
            async let recentWaist = latestQuantity(.waistCircumference, unit: .meterUnit(with: .centi), start: .distantPast, end: end, preferred: preferred)
            async let bodyMass = latestQuantity(.bodyMass, unit: HKUnit.gramUnit(with: .kilo), start: start, end: end, preferred: preferred)
            async let bodyFat = latestQuantity(.bodyFatPercentage, unit: .percent(), start: start, end: end, preferred: preferred, percent: true)
            async let leanMass = latestQuantity(.leanBodyMass, unit: HKUnit.gramUnit(with: .kilo), start: start, end: end, preferred: preferred)
            async let height = latestQuantity(.height, unit: .meterUnit(with: .centi), start: .distantPast, end: end, preferred: preferred)
            async let bmi = latestQuantity(.bodyMassIndex, unit: .count(), start: start, end: end, preferred: preferred)
            async let waist = latestQuantity(.waistCircumference, unit: .meterUnit(with: .centi), start: start, end: end, preferred: preferred)
            async let workoutSamples = samples(type: HKObjectType.workoutType(), start: start, end: end, strictStart: true)
            let values = try await (steps, energy, heart, resting, sleeping, bodyMass, bodyFat, leanMass, height, bmi, waist, workoutSamples)
            day.steps = values.0; day.activeEnergy = values.1; day.heartRate = values.2
            day.restingHeartRate = values.3; day.sleep = values.4
            let nightValue = try await night
            day.nightSleep = nightValue?.metric; day.nightSleepStart = nightValue?.start; day.nightSleepEnd = nightValue?.end
            day.napSleep = nightValue?.nap
            day.bodyMass = values.5; day.bodyFatPercentage = values.6; day.leanBodyMass = values.7
            let recent = try await (recentMass, recentFat, recentWaist)
            day.recentBodyMass = recent.0; day.recentBodyFatPercentage = recent.1; day.recentWaistCircumference = recent.2
            day.height = values.8; day.bodyMassIndex = values.9; day.waistCircumference = values.10
            let samples = values.11
            let workouts = samples.compactMap { $0 as? HKWorkout }.map { workout in
                DeviceWorkout(id: workout.uuid.uuidString, name: Self.workoutName(workout.workoutActivityType), start: workout.startDate, end: workout.endDate, minutes: workout.duration / 60, calories: workout.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie()), source: Self.source(workout.sourceRevision.source),
                              activityKind: Self.workoutKind(workout.workoutActivityType),
                              averageHeartRate: workout.statistics(for: HKQuantityType(.heartRate))?.averageQuantity()?.doubleValue(for: HKUnit.count().unitDivided(by: .minute())))
            }
            guard ticket == generation, !Task.isCancelled else { return }
            day.workouts = HealthDay.deduplicated(workouts + imported.filter { ClubDates.key($0.start) == day.date }, preferred: preferred)
            let previous = days[day.date]; days[day.date] = day
            do { try save() } catch { days[day.date] = previous; throw error }
            if !day.hasData { message = "该日暂无可读取数据，可能尚未同步、未记录或未允许读取。请先同步品牌 App，再检查 Apple 健康中的数据权限。" }
        } catch {
            guard ticket == generation, !(error is CancellationError), !Task.isCancelled else { return }
            message = "读取未完成，保留上次记录：\(AppErrorText.message(error))"
        }
    }
    func importTCX(_ url: URL) throws -> Date {
        guard accountID != nil, storageAvailable, !busy else { throw HealthImportError.message("请等待当前读取完成后再导入。") }
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 5_000_000 else { throw HealthImportError.message("请选择不超过 5 MB 的 TCX 文件。") }
        let inspection = try TCXImport.inspect(Data(contentsOf: url))
        return try importTCX(inspection, expectedAccountID: accountID)
    }
    func inspectTCX(_ url: URL) throws -> TCXInspection {
        guard accountID != nil, storageAvailable, !busy else { throw HealthImportError.message("请等待当前读取完成后再导入。") }
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 5_000_000 else { throw HealthImportError.message("请选择不超过 5 MB 的 TCX 文件。") }
        return try TCXImport.inspect(Data(contentsOf: url))
    }
    func importTCX(_ inspection: TCXInspection, expectedAccountID: Int?) throws -> Date {
        guard let owner = expectedAccountID, owner == accountID, storageAvailable, !busy else { throw HealthImportError.message("账号已改变或正在读取，请重新进入后导入。") }
        let workouts = inspection.workouts
        guard workouts.allSatisfy({ $0.end <= Date() && $0.start < $0.end }) else { throw HealthImportError.message("导入预览已失效，请重新选择文件。") }
        var ids = Set(imported.map(\.id)); let new = workouts.filter { ids.insert($0.id).inserted }
        guard !new.isEmpty else { throw HealthImportError.message("这份运动记录已经导入。") }
        guard imported.count + new.count <= 1000 else { throw HealthImportError.message("本机已达到 1000 条导入上限。") }
        let previousDays = days; let previousImported = imported
        imported.append(contentsOf: new)
        for workout in new {
            let key = ClubDates.key(workout.start)
            var day = days[key] ?? HealthDay(date: key, timeZone: TimeZone.current.identifier, updatedAt: Date())
            day.workouts = HealthDay.deduplicated(day.workouts + [workout], preferred: preferredSource)
            day.updatedAt = Date(); days[key] = day
        }
        do { try save() } catch { days = previousDays; imported = previousImported; throw error }
        message = "已导入 \(new.count) 条运动记录，重复时段已合并。文件运动热量不会累加到全天活动能量。"
        return new[0].start
    }
    private static func source(_ source: HKSource) -> HealthSource { HealthSource(id: source.bundleIdentifier, name: source.name) }
    private func quantity(_ id: HKQuantityTypeIdentifier, unit: HKUnit, start: Date, end: Date, cumulative: Bool, preferred: String) async throws -> HealthMetric? {
        let type = HKQuantityType(id)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let queryID = UUID()
        return try await withTaskCancellationHandler(operation: {
          try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HealthMetric?, Error>) in
            guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
            let options: HKStatisticsOptions = cumulative ? [.cumulativeSum, .separateBySource] : [.discreteAverage, .separateBySource]
            let query = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate, options: options) { _, stats, error in
                let values: [HealthMetric] = (stats?.sources ?? []).compactMap { source in
                    let quantity = cumulative ? stats?.sumQuantity(for: source) : stats?.averageQuantity(for: source)
                    guard let value = quantity?.doubleValue(for: unit), value.isFinite, value >= 0 else { return nil }
                    return HealthMetric(value: value, source: HealthSource(id: source.bundleIdentifier, name: source.name))
                }
                var chosen = values.first { $0.source.id == preferred } ?? values.sorted {
                    if cumulative && $0.value != $1.value { return $0.value > $1.value }
                    return $0.source.id < $1.source.id
                }.first
                chosen?.availableSources = values.map(\.source)
                let result = chosen
                Task { @MainActor in
                    guard self.finishQuery(queryID) else { return }
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: result) }
                }
            }
            queryCancellations[queryID] = { self.health.stop(query); continuation.resume(throwing: CancellationError()) }
            health.execute(query)
          }
        }, onCancel: { Task { @MainActor in self.cancelQuery(queryID) } })
    }
    private var weightFile: URL? {
        accountID.map { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BojiClub/health-weights-user-\($0).json") }
    }
    private func refreshWeightDelta(ticket: UUID) async throws {
        guard weightCacheAvailable, let target = weightFile else { throw HealthImportError.message("体重缓存需要恢复，未推进健康同步游标。") }
        var candidate = weightCache
        var anchor: HKQueryAnchor?
        if let data = candidate.anchor { anchor = try NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data) }
        for _ in 0..<100 {
            let queryID = UUID()
            let page: ([HKSample], [HKDeletedObject], HKQueryAnchor?) = try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { continuation in
                    let query = HKAnchoredObjectQuery(type: HKQuantityType(.bodyMass), predicate: nil, anchor: anchor, limit: 500) { [weak self] _, samples, deleted, next, error in
                        Task { @MainActor in
                            guard let self, self.finishQuery(queryID) else { return }
                            if let error { continuation.resume(throwing: error) }
                            else { continuation.resume(returning: (samples ?? [], deleted ?? [], next)) }
                        }
                    }
                    queryCancellations[queryID] = { self.health.stop(query); continuation.resume(throwing: CancellationError()) }
                    health.execute(query)
                }
            }, onCancel: { Task { @MainActor in self.cancelQuery(queryID) } })
            guard generation == ticket, !Task.isCancelled else { throw CancellationError() }
            for removed in page.1 {
                let external = removed.uuid.uuidString.lowercased()
                if let sample = candidate.samples.removeValue(forKey: external) {
                    let key = ClubDates.key(sample.date)
                    candidate.deleted[key] = Array(Set((candidate.deleted[key] ?? []) + [external]))
                }
            }
            for object in page.0 {
                guard let sample = object as? HKQuantitySample else { continue }
                let kg = sample.quantity.doubleValue(for: .gramUnit(with: .kilo))
                guard kg.isFinite, (20...400).contains(kg) else { continue }
                let external = sample.uuid.uuidString.lowercased()
                let ownID = sample.metadata?["boji_measurement_id"] as? String
                candidate.samples[external] = HealthWeightSample(id: ownID ?? external, externalID: external, date: sample.endDate, kilograms: kg, source: Self.source(sample.sourceRevision.source))
            }
            anchor = page.2
            if let anchor { candidate.anchor = try NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true) }
            // Data and anchor commit atomically: an interrupted read never advances only the cursor.
            try JSONEncoder().encode(candidate).write(to: target, options: [.atomic, .completeFileProtection])
            weightCache = candidate
            if page.0.count + page.1.count < 500 { return }
        }
        throw HealthImportError.message("健康测量较多，已保存同步进度，请再次刷新继续。")
    }
    func setWeightWritingEnabled(_ value: Bool) async {
        guard let owner = accountID, available else { return }
        let ticket = generation
        do {
            if value { try await health.requestAuthorization(toShare: [HKQuantityType(.bodyMass)], read: readTypes) }
            guard generation == ticket else { return }
            writeWeightsEnabled = value; UserDefaults.standard.set(value, forKey: "health.write-weight.user-\(owner)")
        } catch { message = "未能完成体重写入授权：\(AppErrorText.message(error))" }
    }
    func writeWeight(_ entry: BodyWeightEntry) async {
        guard writeWeightsEnabled, let id = entry.id, let kg = entry.measuredKilograms, let date = entry.recordedAt, accountID != nil else { return }
        let ticket = generation
        do {
            let key = "boji-weight-" + id.uuidString.lowercased()
            let predicate = HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeySyncIdentifier, allowedValues: [key])
            let existing = try await samples(type: HKQuantityType(.bodyMass), start: .distantPast, end: .distantFuture, strictStart: false, metadataPredicate: predicate)
            guard generation == ticket, existing.isEmpty else { return }
            let sample = HKQuantitySample(type: HKQuantityType(.bodyMass), quantity: HKQuantity(unit: .gramUnit(with: .kilo), doubleValue: kg), start: date, end: date, metadata: [HKMetadataKeySyncIdentifier: key, HKMetadataKeySyncVersion: 1, "boji_measurement_id": id.uuidString.lowercased()])
            try await health.save(sample)
        } catch { if generation == ticket { message = "本机测量已保存；写入 Apple 健康未完成：\(AppErrorText.message(error))" } }
    }

    private func latestQuantity(_ id: HKQuantityTypeIdentifier, unit: HKUnit, start: Date, end: Date,
                                preferred: String, percent: Bool = false) async throws -> HealthMetric? {
        let type = HKQuantityType(id)
        let records = try await samples(type: type, start: start, end: end)
        let candidates: [HealthMetric] = records.compactMap { sample in
            guard let quantitySample = sample as? HKQuantitySample else { return nil }
            var value = quantitySample.quantity.doubleValue(for: unit)
            if percent, value >= 0, value <= 1 { value *= 100 }
            guard value.isFinite, value > 0 else { return nil }
            return HealthMetric(value: value, source: Self.source(quantitySample.sourceRevision.source), recordedAt: quantitySample.endDate)
        }
        let preferredCandidates = candidates.filter { $0.source.id == preferred }
        return (preferredCandidates.isEmpty ? candidates : preferredCandidates).max {
            if $0.recordedAt != $1.recordedAt { return ($0.recordedAt ?? .distantPast) < ($1.recordedAt ?? .distantPast) }
            return $0.source.id > $1.source.id
        }
    }
    private func samples(type: HKSampleType, start: Date, end: Date, strictStart: Bool = false,
                         metadataPredicate: NSPredicate? = nil) async throws -> [HKSample] {
        let queryID = UUID()
        return try await withTaskCancellationHandler(operation: {
          try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[HKSample], Error>) in
            guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
            let datePredicate = HKQuery.predicateForSamples(withStart: start, end: end, options: strictStart ? .strictStartDate : [])
            let predicate = metadataPredicate.map { NSCompoundPredicate(andPredicateWithSubpredicates: [datePredicate, $0]) } ?? datePredicate
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                Task { @MainActor in
                    guard self.finishQuery(queryID) else { return }
                    if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: samples ?? []) }
                }
            }
            queryCancellations[queryID] = { self.health.stop(query); continuation.resume(throwing: CancellationError()) }
            health.execute(query)
          }
        }, onCancel: { Task { @MainActor in self.cancelQuery(queryID) } })
    }
    private struct MainSleep {
        let metric: HealthMetric
        let start: Date
        let end: Date
        let nap: HealthMetric?
    }
    private func mainSleep(start: Date, end: Date, preferred: String) async throws -> MainSleep? {
        let previous = ClubDates.calendar.date(byAdding: .day, value: -2, to: start) ?? start
        let records = try await samples(type: HKCategoryType(.sleepAnalysis), start: previous, end: min(end, Date()))
        let asleep = Set([HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue, HKCategoryValueSleepAnalysis.asleepCore.rawValue, HKCategoryValueSleepAnalysis.asleepDeep.rawValue, HKCategoryValueSleepAnalysis.asleepREM.rawValue])
        let groups = Dictionary(grouping: records.compactMap { $0 as? HKCategorySample }.filter { asleep.contains($0.value) && $0.endDate <= min(end, Date()) }, by: { $0.sourceRevision.source.bundleIdentifier })
        var options: [MainSleep] = []
        for values in groups.values {
            guard let first = values.first else { continue }
            let episodes = SleepEpisodeRules.episodes(values.map { DateInterval(start: $0.startDate, end: $0.endDate) }).filter { $0.end >= start && $0.end < end }
            guard let main = episodes.max(by: { $0.seconds < $1.seconds }), main.seconds >= 1800 else { continue }
            let source = Self.source(first.sourceRevision.source)
            let other = episodes.filter { $0.start != main.start }.reduce(0) { $0 + $1.seconds }
            options.append(MainSleep(metric: HealthMetric(value: main.seconds / 3600, source: source, recordedAt: main.end), start: main.start, end: main.end,
                                     nap: other > 0 ? HealthMetric(value: other / 3600, source: source, recordedAt: episodes.map(\.end).max()) : nil))
        }
        return options.first { $0.metric.source.id == preferred } ?? options.max { $0.metric.value == $1.metric.value ? $0.metric.source.id > $1.metric.source.id : $0.metric.value < $1.metric.value }
    }
    private func sleep(start: Date, end: Date, preferred: String) async throws -> HealthMetric? {
        let records = try await samples(type: HKCategoryType(.sleepAnalysis), start: start, end: end)
        let asleep = Set([HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue, HKCategoryValueSleepAnalysis.asleepCore.rawValue, HKCategoryValueSleepAnalysis.asleepDeep.rawValue, HKCategoryValueSleepAnalysis.asleepREM.rawValue])
        let groups = Dictionary(grouping: records.compactMap { $0 as? HKCategorySample }.filter { asleep.contains($0.value) }, by: { $0.sourceRevision.source.bundleIdentifier })
        var metrics: [HealthMetric] = []
        for group in groups.values {
            var intervals = group.map { (max($0.startDate, start), min($0.endDate, end)) }.filter { $0.1 > $0.0 }.sorted { $0.0 < $1.0 }
            guard !intervals.isEmpty, let first = group.first else { continue }
            var current = intervals.removeFirst(); var seconds = 0.0
            for interval in intervals {
                if interval.0 <= current.1 { current.1 = max(current.1, interval.1) }
                else { seconds += current.1.timeIntervalSince(current.0); current = interval }
            }
            seconds += current.1.timeIntervalSince(current.0)
            metrics.append(HealthMetric(value: seconds / 3600, source: Self.source(first.sourceRevision.source)))
        }
        var chosen = metrics.first { $0.source.id == preferred } ?? metrics.sorted { $0.value == $1.value ? $0.source.id < $1.source.id : $0.value > $1.value }.first
        chosen?.availableSources = metrics.map(\.source)
        return chosen
    }
    private static func workoutKind(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .running: return "running"
        case .walking: return "walking"
        case .cycling: return "cycling"
        case .swimming: return "swimming"
        case .traditionalStrengthTraining, .functionalStrengthTraining: return "strength"
        case .highIntensityIntervalTraining: return "interval"
        case .yoga: return "yoga"
        case .hiking: return "hiking"
        case .rowing: return "rowing"
        case .elliptical: return "elliptical"
        case .stairClimbing: return "stairs"
        case .jumpRope: return "jumpRope"
        case .dance: return "dance"
        default: return "hk-\(type.rawValue)"
        }
    }
    private static func workoutName(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .running: return "跑步"
        case .walking: return "步行"
        case .cycling: return "骑行"
        case .swimming: return "游泳"
        case .traditionalStrengthTraining, .functionalStrengthTraining: return "力量训练"
        case .highIntensityIntervalTraining: return "间歇训练"
        case .yoga: return "瑜伽"
        case .hiking: return "徒步"
        case .rowing: return "划船"
        case .elliptical: return "椭圆机"
        case .stairClimbing: return "爬楼梯"
        case .jumpRope: return "跳绳"
        case .dance: return "舞蹈"
        default: return "设备运动"
        }
    }
}


enum WorkoutAssociation {
    private static let catalogKinds: [String: String] = ["0001": "strength", "0002": "strength", "0003": "strength", "0006": "strength", "0007": "strength", "0009": "strength", "0011": "strength", "0015": "strength", "0017": "strength", "0019": "strength", "0024": "strength", "0025": "strength", "0026": "strength", "0027": "strength", "0030": "strength", "0031": "strength", "0032": "strength", "0033": "strength", "0038": "strength", "0041": "strength", "0042": "strength", "0043": "strength", "0044": "strength", "0047": "strength", "0049": "strength", "0054": "strength", "0060": "strength", "0063": "strength", "0069": "strength", "0070": "strength", "0072": "strength", "0073": "strength", "0074": "strength", "0076": "strength", "0078": "strength", "0080": "strength", "0081": "strength", "0082": "strength", "0084": "strength", "0085": "strength", "0088": "strength", "0091": "strength", "0092": "strength", "0094": "strength", "0095": "strength", "0098": "strength", "0099": "strength", "0104": "strength", "0106": "strength", "0113": "strength", "0114": "strength", "0116": "strength", "0117": "strength", "0118": "strength", "0120": "strength", "0122": "strength", "0123": "strength", "0124": "strength", "0126": "strength", "0129": "strength", "0150": "strength", "0151": "strength", "0154": "strength", "0158": "strength", "0160": "strength", "0162": "strength", "0165": "strength", "0167": "strength", "0168": "strength", "0169": "strength", "0171": "strength", "0173": "strength", "0175": "strength", "0177": "strength", "0178": "strength", "0179": "strength", "0184": "strength", "0185": "strength", "0188": "strength", "0189": "strength", "0190": "strength", "0192": "strength", "0193": "strength", "0194": "strength", "0195": "strength", "0196": "strength", "0200": "strength", "0201": "strength", "0202": "strength", "0203": "strength", "0206": "strength", "0207": "strength", "0208": "strength", "0209": "strength", "0210": "strength", "0212": "strength", "0214": "strength", "0215": "strength", "0216": "strength", "0218": "strength", "0219": "strength", "0220": "strength", "0222": "strength", "0223": "strength", "0225": "strength", "0226": "strength", "0228": "strength", "0230": "strength", "0233": "strength", "0234": "strength", "0235": "strength", "0237": "strength", "0238": "strength", "0241": "strength", "0242": "strength", "0243": "strength", "0245": "strength", "0246": "strength", "0247": "strength", "0251": "strength", "0253": "strength", "0259": "strength", "0260": "strength", "0262": "strength", "0267": "strength", "0271": "strength", "0272": "strength", "0274": "strength", "0276": "strength", "0277": "strength", "0279": "strength", "0282": "strength", "0283": "strength", "0284": "strength", "0285": "strength", "0289": "strength", "0291": "strength", "0292": "strength", "0293": "strength", "0294": "strength", "0297": "strength", "0298": "strength", "0299": "strength", "0300": "strength", "0301": "strength", "0302": "strength", "0303": "strength", "0308": "strength", "0310": "strength", "0313": "strength", "0314": "strength", "0315": "strength", "0319": "strength", "0320": "strength", "0321": "strength", "0323": "strength", "0326": "strength", "0327": "strength", "0329": "strength", "0330": "strength", "0333": "strength", "0334": "strength", "0336": "strength", "0339": "strength", "0340": "strength", "0344": "strength", "0351": "strength", "0355": "strength", "0356": "strength", "0358": "strength", "0359": "strength", "0361": "strength", "0364": "strength", "0369": "strength", "0372": "strength", "0375": "strength", "0377": "strength", "0381": "strength", "0383": "strength", "0384": "strength", "0387": "strength", "0388": "strength", "0389": "strength", "0391": "strength", "0392": "strength", "0396": "strength", "0398": "strength", "0399": "strength", "0400": "strength", "0404": "strength", "0405": "strength", "0407": "strength", "0409": "strength", "0410": "strength", "0411": "strength", "0413": "strength", "0414": "strength", "0417": "strength", "0425": "strength", "0426": "strength", "0427": "strength", "0430": "strength", "0431": "strength", "0437": "strength", "0439": "strength", "0443": "strength", "0446": "strength", "0447": "strength", "0449": "strength", "0451": "strength", "0452": "strength", "0453": "strength", "0454": "strength", "0455": "strength", "0459": "strength", "0464": "strength", "0474": "strength", "0475": "strength", "0476": "strength", "0488": "strength", "0489": "strength", "0490": "strength", "0491": "strength", "0493": "strength", "0495": "strength", "0496": "strength", "0498": "strength", "0499": "strength", "0507": "strength", "0514": "strength", "0519": "strength", "0520": "strength", "0521": "strength", "0522": "strength", "0528": "strength", "0532": "strength", "0533": "strength", "0534": "strength", "0537": "strength", "0540": "strength", "0541": "strength", "0542": "strength", "0546": "strength", "0549": "strength", "0552": "strength", "0553": "strength", "0554": "strength", "0562": "strength", "0570": "strength", "0571": "strength", "0573": "strength", "0575": "strength", "0577": "strength", "0578": "strength", "0579": "strength", "0581": "strength", "0582": "strength", "0583": "strength", "0584": "strength", "0585": "strength", "0586": "strength", "0588": "strength", "0590": "strength", "0592": "strength", "0593": "strength", "0594": "strength", "0595": "strength", "0596": "strength", "0597": "strength", "0598": "strength", "0599": "strength", "0600": "strength", "0601": "strength", "0602": "strength", "0603": "strength", "0604": "strength", "0605": "strength", "0606": "strength", "0607": "strength", "0620": "strength", "0628": "strength", "0634": "strength", "0635": "strength", "0641": "strength", "0650": "strength", "0651": "strength", "0652": "strength", "0659": "strength", "0660": "strength", "0662": "strength", "0663": "strength", "0664": "strength", "0675": "strength", "0677": "strength", "0684": "running", "0685": "running", "0687": "strength", "0688": "strength", "0689": "strength", "0691": "strength", "0696": "strength", "0699": "strength", "0705": "strength", "0710": "strength", "0717": "strength", "0730": "strength", "0735": "strength", "0738": "strength", "0739": "strength", "0740": "strength", "0741": "strength", "0743": "strength", "0744": "strength", "0748": "strength", "0750": "strength", "0751": "strength", "0752": "strength", "0753": "strength", "0755": "strength", "0756": "strength", "0757": "strength", "0761": "strength", "0762": "strength", "0763": "strength", "0764": "strength", "0765": "strength", "0767": "strength", "0768": "strength", "0770": "strength", "0773": "strength", "0774": "strength", "0775": "strength", "0795": "strength", "0805": "strength", "0806": "strength", "0807": "strength", "0808": "strength", "0809": "strength", "0811": "strength", "0812": "strength", "0814": "strength", "0815": "strength", "0818": "strength", "0826": "strength", "0830": "strength", "0832": "strength", "0833": "strength", "0834": "strength", "0841": "strength", "0845": "strength", "0846": "strength", "0856": "strength", "0857": "strength", "0859": "strength", "0860": "strength", "0861": "strength", "0862": "strength", "0863": "strength", "0864": "strength", "0865": "strength", "0866": "strength", "0868": "strength", "0871": "strength", "0872": "strength", "0873": "strength", "0874": "strength", "0968": "strength", "0969": "strength", "0970": "strength", "0971": "strength", "0972": "strength", "0974": "strength", "0975": "strength", "0976": "strength", "0978": "strength", "0979": "strength", "0980": "strength", "0983": "strength", "0984": "strength", "0985": "strength", "0988": "strength", "0989": "strength", "0990": "strength", "0991": "strength", "0993": "strength", "0994": "strength", "0997": "strength", "0998": "strength", "0999": "strength", "1000": "strength", "1001": "strength", "1002": "strength", "1004": "strength", "1005": "strength", "1007": "strength", "1008": "strength", "1009": "strength", "1011": "strength", "1015": "strength", "1016": "strength", "1017": "strength", "1022": "strength", "1253": "strength", "1254": "strength", "1261": "strength", "1265": "strength", "1273": "strength", "1274": "strength", "1275": "strength", "1281": "strength", "1297": "strength", "1298": "strength", "1299": "strength", "1300": "strength", "1302": "strength", "1306": "strength", "1311": "strength", "1313": "strength", "1314": "strength", "1316": "strength", "1317": "strength", "1318": "strength", "1323": "strength", "1326": "strength", "1327": "strength", "1328": "strength", "1329": "strength", "1331": "strength", "1345": "strength", "1347": "strength", "1348": "strength", "1350": "strength", "1351": "strength", "1356": "strength", "1359": "strength", "1360": "strength", "1361": "strength", "1362": "strength", "1372": "strength", "1373": "strength", "1375": "strength", "1376": "strength", "1379": "strength", "1383": "strength", "1384": "strength", "1387": "strength", "1392": "strength", "1393": "strength", "1396": "strength", "1408": "strength", "1409": "strength", "1410": "strength", "1413": "strength", "1415": "strength", "1422": "strength", "1423": "strength", "1425": "strength", "1427": "strength", "1429": "strength", "1431": "strength", "1433": "strength", "1434": "strength", "1435": "strength", "1436": "strength", "1437": "strength", "1451": "strength", "1452": "strength", "1456": "strength", "1458": "strength", "1459": "strength", "1460": "strength", "1468": "strength", "1471": "strength", "1489": "strength", "1490": "strength", "1615": "strength", "1630": "strength", "1631": "strength", "1632": "strength", "1633": "strength", "1634": "strength", "1636": "strength", "1639": "strength", "1641": "strength", "1663": "strength", "1669": "strength", "1674": "strength", "1678": "strength", "1688": "strength", "1700": "strength", "1705": "strength", "1717": "strength", "1719": "strength", "1722": "strength", "1723": "strength", "1724": "strength", "1726": "strength", "1728": "strength", "1729": "strength", "1748": "strength", "1749": "strength", "1751": "strength", "1755": "strength", "1756": "strength", "1757": "strength", "1758": "strength", "1759": "strength", "1760": "strength", "1761": "strength", "1764": "strength", "1771": "strength", "1774": "strength", "2135": "strength", "2137": "strength", "2138": "cycling", "2141": "elliptical", "2144": "strength", "2186": "strength", "2204": "strength", "2285": "strength", "2286": "strength", "2288": "strength", "2300": "strength", "2311": "stairs", "2317": "strength", "2329": "strength", "2333": "strength", "2355": "strength", "2368": "strength", "2398": "strength", "2399": "strength", "2400": "strength", "2429": "strength", "2611": "strength", "2612": "jumpRope", "2616": "strength", "2736": "strength", "2741": "strength", "2796": "strength", "2799": "strength", "2802": "strength", "2803": "strength", "2805": "strength", "2963": "strength", "3006": "strength", "3007": "strength", "3010": "strength", "3011": "strength", "3013": "strength", "3017": "strength", "3021": "strength", "3122": "strength", "3123": "strength", "3124": "strength", "3132": "strength", "3142": "strength", "3144": "strength", "3145": "strength", "3193": "strength", "3195": "strength", "3200": "strength", "3202": "strength", "3211": "strength", "3213": "strength", "3236": "strength", "3237": "strength", "3239": "strength", "3294": "strength", "3470": "strength", "3523": "strength", "3541": "strength", "3544": "strength", "3545": "strength", "3548": "strength", "3561": "strength", "3563": "strength", "3582": "strength", "3635": "strength", "3640": "strength", "3645": "strength", "3656": "running", "3663": "strength", "3666": "walking", "3667": "strength", "3670": "strength", "3679": "strength", "3699": "strength", "3759": "strength", "3769": "strength", "5201": "strength", "boji-basic-bird-dog": "strength", "boji-basic-plank": "strength", "boji-basic-squat": "strength", "boji-basic-wall-sit": "strength", "boji-cardio-cycle": "cycling", "boji-cardio-dance": "dance", "boji-cardio-row": "rowing", "boji-cardio-stairs": "stairs", "boji-cardio-swim-breast": "swimming", "boji-cardio-swim-free": "swimming", "boji-cardio-walk": "walking"]
    static func activityKind(for exercise: Exercise) -> String? {
        guard exercise.customExerciseID == nil else { return nil }
        if let id = exercise.libraryID { return catalogKinds[id] }
        // Legacy strength records without a catalog ID retain the previous matching behavior.
        return exercise.sets.contains { $0.validCompletion && $0.durationSeconds == nil } ? "strength" : nil
    }
    static func expectedKind(for day: DayLog) -> String? {
        let completed = day.trainingLog.exercises.filter { $0.sets.contains(where: \.validCompletion) }
        let values = completed.compactMap(activityKind)
        guard !completed.isEmpty, values.count == completed.count, Set(values).count == 1 else { return nil }
        return values.first
    }
    static func suggestedIDs(for day: DayLog, workouts: [DeviceWorkout]) -> Set<String> {
        let reserved=Set((day.workoutSessions ?? []).filter { $0.id != day.activeWorkoutSessionID }.compactMap(\.linkedDeviceWorkoutID))
        guard let expected = expectedKind(for: day) else { return [] }
        let day = day.trainingLog
        guard let start = day.workoutStartedAt, let end = day.workoutEndedAt,
              end > start, end.timeIntervalSince(start) <= 6 * 3600 else { return [] }
        return Set(workouts.filter { workout in
            guard workout.comparableKind == expected, !reserved.contains(workout.id) else { return false }
            let longest = max(end.timeIntervalSince(start), workout.end.timeIntervalSince(workout.start))
            let overlap = min(end, workout.end).timeIntervalSince(max(start, workout.start))
            return longest > 0 && overlap / longest >= 0.5
        }.map(\.id))
    }
}

struct SleepEpisode: Equatable {
    var start: Date
    var end: Date
    var seconds: Double
}
enum SleepEpisodeRules {
    static func episodes(_ values: [DateInterval]) -> [SleepEpisode] {
        var union: [DateInterval] = []
        for interval in values.filter({ $0.duration > 0 }).sorted(by: { $0.start < $1.start }) {
            if let last = union.last, interval.start <= last.end {
                union[union.count - 1] = DateInterval(start: last.start, end: max(last.end, interval.end))
            } else { union.append(interval) }
        }
        var result: [SleepEpisode] = []
        for interval in union {
            if let last = result.last, interval.start.timeIntervalSince(last.end) <= 90 * 60 {
                result[result.count - 1].end = interval.end
                result[result.count - 1].seconds += interval.duration
            } else { result.append(SleepEpisode(start: interval.start, end: interval.end, seconds: interval.duration)) }
        }
        return result
    }
}
