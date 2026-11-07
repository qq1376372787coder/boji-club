import Foundation
import CryptoKit

enum CloudSyncStatus: Equatable {
    case idle, pending, syncing, synced(Date), waiting, waitingService, failed(String)

    var label: String {
        switch self {
        case .idle: return "已保存在本机，等待同步"
        case .pending: return "记录已保存在本机，等待同步"
        case .syncing: return "正在同步云端记录…"
        case .synced(let date):
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "HH:mm"
            return "已同步 · \(formatter.string(from: date))"
        case .waiting: return "离线记录已保留，联网后自动同步"
        case .waitingService: return "云端繁忙，正在等待自动同步"
        case .failed: return "云端同步暂不可用，记录已保存在本机"
        }
    }
}

struct CloudState: Codable {
    var version = 1
    var emptySessionDeletionVersion: Int? = 1
    var experienceVersion: Int? = 1
    var customExerciseVersion: Int? = 1
    var recordIntegrityVersion: Int? = 1
    var customExercises: [CustomExercise]? = nil
    var deletedCustomExerciseIDs: [String]? = nil
    var days: [String: DayLog]
    var profile: MemberProfile
    var drafts: [PostDraft]
    var importedPlan: String
    var appliedAIJobs: [String]?
    var deletedExerciseIDs: [String]?
    var deletedMealIDs: [String]?
    var deletedMediaIDs: [String]?
    var deletedAIJobIDs: [String]?
    var nutritionTarget: NutritionTarget?
    var aiJobs: [AILocalJob]?
    var actionStates: [ClubActionRecord]? = nil
    var planDrafts: [ManualPlanDraft]? = nil
    var planTemplates: [ManualPlanTemplate]? = nil
    var deletedPlanDraftIDs: [String]? = nil
    var deletedPlanTemplateIDs: [String]? = nil
    var syncSchemaVersion: Int? = 2

    init(_ state: SavedState, aiJobs: [AILocalJob] = []) {
        customExercises = state.customExercises
        deletedCustomExerciseIDs = state.deletedCustomExerciseIDs
        days = state.days
        profile = state.profile
        nutritionTarget = state.nutritionTarget
        drafts = state.drafts
        importedPlan = state.importedPlan
        appliedAIJobs = state.appliedAIJobs
        deletedExerciseIDs = state.deletedExerciseIDs
        deletedMealIDs = state.deletedMealIDs
        deletedMediaIDs = state.deletedMediaIDs
        deletedAIJobIDs = state.deletedAIJobIDs
        actionStates = state.actionStates
        planDrafts = state.planDrafts
        planTemplates = state.planTemplates
        deletedPlanDraftIDs = state.deletedPlanDraftIDs
        deletedPlanTemplateIDs = state.deletedPlanTemplateIDs
        syncSchemaVersion = state.syncSchemaVersion ?? 2
        self.aiJobs = aiJobs
    }

    func savedState() -> SavedState {
        var value = SavedState(version: 1, days: days, profile: profile, drafts: drafts, importedPlan: importedPlan, appliedAIJobs: appliedAIJobs, deletedExerciseIDs: deletedExerciseIDs, deletedMealIDs: deletedMealIDs, deletedMediaIDs: deletedMediaIDs, deletedAIJobIDs: deletedAIJobIDs, nutritionTarget: nutritionTarget, customExercises: customExercises, deletedCustomExerciseIDs: deletedCustomExerciseIDs)
        value.actionStates = actionStates
        value.planDrafts = planDrafts
        value.planTemplates = planTemplates
        value.deletedPlanDraftIDs = deletedPlanDraftIDs
        value.deletedPlanTemplateIDs = deletedPlanTemplateIDs
        value.syncSchemaVersion = syncSchemaVersion ?? 2
        return value
    }
}

struct CloudStateEnvelope: Codable {
    let revision: Int
    let state: CloudState?
    var unchanged: Bool?
    var media_cleanup_pending: Int?
    init(revision: Int, state: CloudState?, unchanged: Bool? = nil, media_cleanup_pending: Int? = nil) {
        self.revision = revision; self.state = state; self.unchanged = unchanged; self.media_cleanup_pending = media_cleanup_pending
    }
}

struct CloudErrorEnvelope: Decodable {
    let error: String
}

struct LocalSyncEnvelope: Codable {
    var state: SavedState
    var base: CloudState?
    var cloudRevision: Int? = nil
    var journalSequence: Int? = nil
}

// Compare against the last cloud snapshot, so unchanged stale local values cannot
// overwrite edits made on another device. Concurrent edits of one field keep local.
enum CloudMerge {
    static func merge(local: CloudState, remote: CloudState, base: CloudState?) throws -> CloudState {
        let localValue = try JSONValue.encode(local)
        let remoteValue = try JSONValue.encode(remote)
        let baseValue = try base.map { try JSONValue.encode($0) }
        let combined = mergeValue(localValue, remoteValue, baseValue) ?? remoteValue
        var result = try JSONDecoder().decode(CloudState.self, from: JSONEncoder().encode(combined))
        let deletedCustom = Set((result.deletedCustomExerciseIDs ?? []).map { $0.lowercased() })
        result.customExercises?.removeAll { deletedCustom.contains($0.id.uuidString.lowercased()) }
        let deletedExercises = Set((result.deletedExerciseIDs ?? []).map { $0.lowercased() })
        let deletedMeals = Set((result.deletedMealIDs ?? []).map { $0.lowercased() })
        for date in Array(result.days.keys) {
            result.days[date]?.exercises.removeAll { deletedExercises.contains($0.id.uuidString.lowercased()) }
            result.days[date]?.meals.removeAll { deletedMeals.contains($0.id.uuidString.lowercased()) }
            if var day = result.days[date] {
                let deletedMeasurements = Set((day.deletedBodyMeasurementIDs ?? []).map { $0.lowercased() })
                if day.bodyMeasurements != nil || !deletedMeasurements.isEmpty {
                    var measurements = day.bodyMeasurements ?? []
                    // Old clients only have the scalar field. Promote those values
                    // using the same identity as local/server migration, then apply
                    // the merged tombstones in both synchronization directions.
                    for source in [base?.days[date], remote.days[date], local.days[date]].compactMap({ $0 }) where source.bodyMeasurements == nil {
                        guard var entry = source.bodyWeight else { continue }
                        entry.id = entry.id ?? BodyMeasurementIdentity.legacy(entry, date: date)
                        if let index = measurements.firstIndex(where: { $0.id == entry.id }) {
                            if measurements[index].updatedAt < entry.updatedAt { measurements[index] = entry }
                        } else { measurements.append(entry) }
                    }
                    measurements.removeAll { entry in
                        let id = entry.id ?? BodyMeasurementIdentity.legacy(entry, date: date)
                        return deletedMeasurements.contains(id.uuidString.lowercased())
                    }
                    day.bodyMeasurements = measurements
                    day.bodyWeight = measurements.max {
                        let left = $0.recordedAt ?? $0.updatedAt, right = $1.recordedAt ?? $1.updatedAt
                        return left == right ? ($0.id?.uuidString ?? "") < ($1.id?.uuidString ?? "") : left < right
                    }
                }
                for index in day.exercises.indices {
                    let deleted = Set((day.exercises[index].deletedSetIDs ?? []).map { $0.lowercased() })
                    day.exercises[index].sets.removeAll { deleted.contains($0.id.uuidString.lowercased()) }
                }
                // A filename without a remote ID is meaningful only on its own device.
                let localMeals: [UUID: Meal] = Dictionary(local.days[date]?.meals.map { ($0.id, $0) } ?? [], uniquingKeysWith: { first, _ in first })
                for index in day.meals.indices where day.meals[index].photoRemoteID == nil {
                    day.meals[index].photoFilename = localMeals[day.meals[index].id]?.photoFilename
                }
                if day.completedSets == 0 { day.linkedDeviceWorkoutID = nil }
                if let linked = day.linkedDeviceWorkoutID, day.health?.workouts.contains(where: { $0.id == linked }) != true {
                    day.linkedDeviceWorkoutID = nil
                }
                // A concurrent device may start a formerly empty session during deletion.
                // Restore any nonempty/started source session instead of deleting its real record.
                for source in [local.days[date], remote.days[date]].compactMap({ $0 }) {
                    for session in source.workoutSessions ?? [] where day.workoutSessions?.contains(where: { $0.id == session.id }) != true {
                        if !EmptyWorkoutSessionRules.canRemove(session.id, from: source) {
                            day.workoutSessions = (day.workoutSessions ?? []) + [session]
                        }
                    }
                }
                // R01: Mutually exclusive schedule replacement resolution.
                // When both devices replaced an unstarted schedule from base with disjoint sets of movements,
                // do not union them into a dual schedule; retain local replacement to avoid double training.
                if let baseDay = base?.days[date], let localDay = local.days[date], let remoteDay = remote.days[date] {
                    let baseUnstarted = (baseDay.workoutStartedAt == nil && baseDay.completedSets == 0 && baseDay.workoutSavedAt == nil)
                    let localUnstarted = (localDay.workoutStartedAt == nil && localDay.completedSets == 0 && localDay.workoutSavedAt == nil)
                    let remoteUnstarted = (remoteDay.workoutStartedAt == nil && remoteDay.completedSets == 0 && remoteDay.workoutSavedAt == nil)
                    if baseUnstarted && localUnstarted && remoteUnstarted && !baseDay.exercises.isEmpty {
                        let baseIDs = Set(baseDay.exercises.map(\.id))
                        let localIDs = Set(localDay.exercises.map(\.id))
                        let remoteIDs = Set(remoteDay.exercises.map(\.id))
                        let localReplaced = localIDs.isDisjoint(with: baseIDs) && !localIDs.isEmpty
                        let remoteReplaced = remoteIDs.isDisjoint(with: baseIDs) && !remoteIDs.isEmpty
                        if localReplaced && remoteReplaced && localIDs.isDisjoint(with: remoteIDs) {
                            day.exercises = localDay.exercises
                            if let localSessions = localDay.workoutSessions, !localSessions.isEmpty {
                                day.workoutSessions = localSessions
                            }
                        }
                    }
                }
                TrainingExecutionCapture.reconcile(&day, base: base?.days[date], local: local.days[date], remote: remote.days[date])
                PlanManagementRules.restoreConcurrentExecution(&day, sources: [local.days[date], remote.days[date]].compactMap { $0 })
                day.exercises.removeAll { deletedExercises.contains($0.id.uuidString) }
                PlanManagementRules.reconcile(&day)
                result.days[date] = day
                if day.workoutSessions?.isEmpty == false {
                    WorkoutSessions.restoreActiveFields(&day)
                    WorkoutSessions.synchronize(&day)
                }
                try RecordIntegrity.validateConfirmation(&day, local: local.days[date], remote: remote.days[date])
                // Concurrent new reports can have different IDs. Retain both observations,
                // including the former latest; explicit tombstones decide deletion.
                day.weeklyReviewHistory = (day.weeklyReviewHistory ?? []) +
                    (local.days[date]?.weeklyReviews ?? []) + (remote.days[date]?.weeklyReviews ?? [])
                WeeklyVersions.reconcile(&day)
                PlanManagementRules.reconcile(&day)
                result.days[date] = day
            }
        }
        let archivedJobs = Set(result.deletedAIJobIDs ?? [])
        result.aiJobs?.removeAll { archivedJobs.contains($0.id) }
        MealPlacement.reconcile(days: &result.days, base: base?.days ?? [:])
        return result
    }

    static func conflictCount(local: CloudState, remote: CloudState, base: CloudState?) throws -> Int {
        guard let base else { return 0 }
        func count(_ l: JSONValue?, _ r: JSONValue?, _ b: JSONValue?, key: String = "") -> Int {
            if l == r || l == b || r == b || key.hasPrefix("deleted") || key == "appliedAIJobs" || key == "aiJobs" { return 0 }
            if case .object(let left)? = l, case .object(let right)? = r {
                let baseline: [String: JSONValue]; if case .object(let value)? = b { baseline = value } else { baseline = [:] }
                return Set(left.keys).union(right.keys).reduce(0) { $0 + count(left[$1], right[$1], baseline[$1], key: $1) }
            }
            if ["exercises","sets","meals","drafts","workoutSessions","customExercises"].contains(key), case .array(let left)? = l, case .array(let right)? = r {
                let baseline: [JSONValue]; if case .array(let value)? = b { baseline = value } else { baseline = [] }
                let lm = indexed(left), rm = indexed(right), bm = indexed(baseline)
                return Set(lm.keys).union(rm.keys).reduce(0) { $0 + count(lm[$1],rm[$1],bm[$1]) }
            }
            return 1
        }
        return count(try JSONValue.encode(local), try JSONValue.encode(remote), try JSONValue.encode(base))
    }

    static func same<T: Encodable>(_ left: T, _ right: T) throws -> Bool {
        try JSONValue.encode(left) == JSONValue.encode(right)
    }

    private static func mergeValue(_ local: JSONValue?, _ remote: JSONValue?, _ base: JSONValue?, key: String = "") -> JSONValue? {
        if key == "coach" {
            // A finished task's response is immutable. Old readers omit this field.
            if let base { return base }
            return remote ?? local
        }
        if ["planActions", "goalVersions", "planVersions", "insightEvents", "insightFeedback", "planShifts", "phaseReports"].contains(key) {
            func values(_ item: JSONValue?) -> [JSONValue] { if case .array(let items)? = item { return items }; return [] }
            var records: [String: JSONValue] = [:]
            for value in values(base) + values(remote) + values(local) {
                guard let id = id(value)?.lowercased() else { continue }
                if records[id] == nil { records[id] = value; continue }
                // 顺延记录不可变；新版本补充的可选溯源字段（sourceCycles/effectScope/reason）
                // 不应因为基线里已有同 ID 的旧记录而丢失。
                if key == "planShifts", case .object(var existing)? = records[id], case .object(let incoming) = value {
                    for (field, fieldValue) in incoming where existing[field] == nil { existing[field] = fieldValue }
                    records[id] = .object(existing)
                }
            }
            return records.isEmpty && local == nil && remote == nil && base == nil ? nil : .array(records.keys.sorted().compactMap { records[$0] })
        }
        // 行动状态与计划草稿/模板会变化：同 ID 取 updatedAt 最新的一条（现有可靠冲突机制——
        // 同一观察取最新，不冻结首次状态、不丢最新稿）。
        if ["bodyMeasurements", "actionStates", "planDrafts", "planTemplates"].contains(key) {
            func values(_ item: JSONValue?) -> [JSONValue] { if case .array(let items)? = item { return items }; return [] }
            func stamp(_ value: JSONValue) -> Double {
                if case .object(let o) = value, case .number(let t)? = o["updatedAt"] { return t }
                return -1
            }
            var records: [String: JSONValue] = [:]
            for value in values(base) + values(remote) + values(local) {
                guard let id = id(value)?.lowercased() else { continue }
                if let existing = records[id], stamp(existing) >= stamp(value) { continue }
                records[id] = value
            }
            return records.isEmpty && local == nil && remote == nil && base == nil ? nil : .array(records.keys.sorted().compactMap { records[$0] })
        }
        let unions = ["appliedAIJobs", "deletedExerciseIDs", "deletedMealIDs", "deletedMediaIDs", "deletedAIJobIDs", "deletedSetIDs", "deletedCustomExerciseIDs", "deletedWeeklyReviewIDs", "deletedPlanDraftIDs", "deletedPlanTemplateIDs", "deletedBodyMeasurementIDs"]
        if unions.contains(key) {
            let l = strings(local); let r = strings(remote)
            return .array(Array(Set(l + r)).sorted().map { .string($0) })
        }
        // Never let a one-sided edit or an old client's omission rewrite a committed start target.
        if key == "executionBaseline" {
            if let base, case .object = base { return base }
            if case .object(let l)? = local, case .object(let r)? = remote {
                if case .number(let lt)? = l["capturedAt"], case .number(let rt)? = r["capturedAt"] { return lt <= rt ? local : remote }
            }
            return local ?? remote
        }
        if local == remote { return local }
        if local == base { return remote }
        if remote == base { return local }
        // Health summaries are indivisible observations, never merge metric fragments.
        if ["health", "weeklyReview", "bodyWeight", "mealCompletion", "planCycle", "nutritionTarget"].contains(key), case .object(let l)? = local, case .object(let r)? = remote {
            if case .number(let lt)? = l["updatedAt"], case .number(let rt)? = r["updatedAt"] {
                return lt >= rt ? local : remote
            }
            return local
        }
        if case .object(let l)? = local, case .object(let r)? = remote, l["unit"] != nil, r["unit"] != nil, l["updatedAt"] != nil, r["updatedAt"] != nil {
            if case .number(let lt)? = l["updatedAt"], case .number(let rt)? = r["updatedAt"] { return lt >= rt ? local : remote }
            return local
        }
        if case .object(let l)? = local, case .object(let r)? = remote, l["survey"] != nil, r["survey"] != nil {
            if case .number(let lt)? = l["updatedAt"], case .number(let rt)? = r["updatedAt"] { return lt >= rt ? local : remote }
            return local
        }
        if case .object(let l)? = local, case .object(let r)? = remote {
            let b: [String: JSONValue]
            if case .object(let values)? = base { b = values } else { b = [:] }
            var output: [String: JSONValue] = [:]
            for field in Set(l.keys).union(r.keys).union(b.keys) {
                output[field] = mergeValue(l[field], r[field], b[field], key: field)
            }
            // An avatar choice is one observation. Do not combine a new
            // default avatar with an old uploaded photo from another device.
            if l["nickname"] != nil && r["nickname"] != nil {
                let avatarKeys = ["avatarID", "avatarImage", "identityVersion"]
                let source = avatarKeys.allSatisfy { l[$0] == b[$0] } ? r : l
                for field in avatarKeys { output[field] = source[field] }
            }
            // Keep the same nutrition conflict policy as the meal editor.
            if l["category"] != nil, l["calories"] != nil {
                // Known/unknown belongs to the same observation as its nutrient values.
                let structureKeys = ["components", "consumedFraction", "nutritionKnown"]
                let nutritionKeys = structureKeys + ["calories", "protein", "carbs", "fat"]
                let source = MealNutritionMerge.nutritionSource(
                    editedStructureChanged: structureKeys.contains { l[$0] != b[$0] },
                    currentStructureChanged: structureKeys.contains { r[$0] != b[$0] },
                    editedNutritionChanged: nutritionKeys.contains { l[$0] != b[$0] })
                switch source {
                case .edited: for field in nutritionKeys { output[field] = l[field] }
                case .current: for field in nutritionKeys { output[field] = r[field] }
                case .independent: break
                }
                let placementKeys = ["placementConfirmedAt", "placementConflictDates"]
                let placementSource = placementKeys.allSatisfy { l[$0] == b[$0] } ? r : l
                for field in placementKeys { output[field] = placementSource[field] }
            }
            return .object(output)
        }
        if ["exercises", "sets", "meals", "drafts", "aiJobs", "workoutSessions", "customExercises", "weeklyReviewHistory"].contains(key),
           case .array(let l)? = local, case .array(let r)? = remote {
            let b: [JSONValue]
            if case .array(let values)? = base { b = values } else { b = [] }
            let lm = indexed(l), rm = indexed(r), bm = indexed(b)
            var seen = Set<String>()
            let order = (r + l + b).compactMap(id).filter { seen.insert($0).inserted }
            return .array(order.compactMap { mergeValue(lm[$0], rm[$0], bm[$0]) })
        }
        // Deletion wins when the record was present at the common baseline.
        if base != nil && (local == nil || remote == nil) { return nil }
        return local ?? remote
    }

    private static func id(_ value: JSONValue) -> String? {
        guard case .object(let fields) = value else { return nil }
        return fields["id"]?.string
    }
    private static func indexed(_ values: [JSONValue]) -> [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        for value in values { if let key = id(value) { result[key] = value } }
        return result
    }
    private static func strings(_ value: JSONValue?) -> [String] {
        guard case .array(let values)? = value else { return [] }
        return values.compactMap(\.string)
    }
}

enum CloudSyncError: LocalizedError {
    case message(String), busy(String)
    var errorDescription: String? {
        switch self { case .message(let text), .busy(let text): return text }
    }
}

@MainActor
final class CloudPartitionCache {
    var hashes: [String: String] = [:]
    var values: [String: JSONValue] = [:]
}

enum CloudPartitionUnits {
    static func jobKey(_ id: String) -> String {
        "j/" + SHA256.hash(data: Data(id.lowercased().utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func split(_ state: CloudState) throws -> [String: JSONValue] {
        guard case .object(var meta) = try JSONValue.encode(state) else {
            throw CloudSyncError.message("记录格式不正确，本机原记录保留。")
        }
        var parts: [String: JSONValue] = [:]
        if case .object(let days)? = meta.removeValue(forKey: "days") {
            for (date, day) in days { parts["d/" + date] = day }
        }
        if case .array(let jobs)? = meta.removeValue(forKey: "aiJobs") {
            for job in jobs {
                guard case .object(let item) = job, let id = item["id"]?.string else {
                    throw CloudSyncError.message("分析记录编号不完整，本机原记录保留。")
                }
                parts[jobKey(id)] = job
            }
        }
        parts["meta"] = .object(meta)
        return parts
    }
    static func combine(_ parts: [String: JSONValue]) throws -> CloudState? {
        if parts.isEmpty { return nil }
        guard case .object(var meta)? = parts["meta"] else {
            throw CloudSyncError.message("云端资料分块未读完整，请重试；原记录保留。")
        }
        var days: [String: JSONValue] = [:]
        var jobs: [JSONValue] = []
        for key in parts.keys.sorted() {
            if key.hasPrefix("d/"), let value = parts[key] { days[String(key.dropFirst(2))] = value }
            if key.hasPrefix("j/"), let value = parts[key] { jobs.append(value) }
        }
        meta["days"] = .object(days); meta["aiJobs"] = .array(jobs)
        return try JSONDecoder().decode(CloudState.self, from: JSONEncoder().encode(CloudWireValue(value: .object(meta))))
    }
}

private struct CloudPartDescriptor: Decodable { let key: String; let hash: String }
private struct CloudPartManifest: Decodable {
    let revision: Int
    var unchanged: Bool?
    var parts: [CloudPartDescriptor]?
    var next: String?
}
private struct CloudPartPayload: Decodable { let key: String; let json: String; let hash: String }
private struct CloudPartRead: Decodable { let revision: Int; let parts: [CloudPartPayload] }
private struct CloudPartReadRequest: Encodable { let revision: Int; let keys: [String] }
// JSONValue stores all numbers as Double. Emit mathematically whole values as
// integers for the PHP schema's version/count fields; preserve real fractions.
private struct CloudWireValue: Encodable {
    let value: JSONValue
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case .number(let number):
            if number.isFinite, number.rounded(.towardZero) == number,
               number >= Double(Int64.min), number < 9_223_372_036_854_775_808 {
                try container.encode(Int64(number))
            } else { try container.encode(number) }
        case .object(let fields): try container.encode(fields.mapValues { CloudWireValue(value: $0) })
        case .array(let values): try container.encode(values.map { CloudWireValue(value: $0) })
        case .string(let text): try container.encode(text)
        case .bool(let flag): try container.encode(flag)
        case .null: try container.encodeNil()
        }
    }
}
private struct CloudPartChange: Encodable {
    let key: String
    let value: JSONValue
    private enum CodingKeys: String, CodingKey { case key, value }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encode(CloudWireValue(value: value), forKey: .value)
    }
}
private struct CloudPartUploadRequest: Encodable { let parts: [CloudPartChange] }
private struct CloudPartBegin: Encodable { let id: String; let base_revision: Int; let part_count: Int }
private struct CloudPartAck: Decodable { let accepted: Int }

struct CloudPartitionResponse {
    let http: AccountRawResponse
    let envelope: CloudStateEnvelope?
    var statusCode: Int { http.statusCode }
    init(_ http: AccountRawResponse, envelope: CloudStateEnvelope? = nil) {
        self.http = http; self.envelope = envelope
    }
}

@MainActor
enum CloudPartitionClient {
    private static func checked(_ response: AccountRawResponse) throws {
        if response.statusCode == 429 || response.statusCode == 503 {
            throw CloudSyncError.busy("云端暂时繁忙，本机记录保留，稍后自动重试。")
        }
    }
    static func read(account: AccountService, userID: Int, knownRevision: Int?, cache: CloudPartitionCache, deadline: Date? = nil) async throws -> CloudPartitionResponse {
        let query = knownRevision.map { "?known_revision=\($0)" } ?? ""
        let first = try await account.cloudRequest(path: "/me/sync" + query, expectedUserID: userID, deadline: deadline)
        try checked(first)
        guard first.statusCode == 200 else { return CloudPartitionResponse(first) }
        let initial = try JSONDecoder().decode(CloudPartManifest.self, from: first.data)
        if initial.unchanged == true { return CloudPartitionResponse(first, envelope: CloudStateEnvelope(revision: initial.revision, state: nil, unchanged: true, media_cleanup_pending: nil)) }
        var descriptors = initial.parts ?? []
        var next = initial.next
        while let cursor = next {
            let response = try await account.cloudRequest(path: "/me/sync?revision=\(initial.revision)&after=\(cursor)", expectedUserID: userID, deadline: deadline)
            try checked(response); guard response.statusCode == 200 else { return CloudPartitionResponse(response) }
            let page = try JSONDecoder().decode(CloudPartManifest.self, from: response.data)
            guard page.revision == initial.revision, page.next != cursor else { throw CloudSyncError.message("云端目录读取异常，请重试。") }
            descriptors.append(contentsOf: page.parts ?? []); next = page.next
        }
        let validKeys = Set(descriptors.map(\.key))
        var values = cache.values.filter { validKeys.contains($0.key) }
        var hashes = cache.hashes.filter { validKeys.contains($0.key) }
        var pending = descriptors.filter { hashes[$0.key] != $0.hash || values[$0.key] == nil }.map(\.key)
        while !pending.isEmpty {
            let keys = Array(pending.prefix(64))
            let data = try JSONEncoder().encode(CloudPartReadRequest(revision: initial.revision, keys: keys))
            let response = try await account.cloudRequest(path: "/me/sync/read", method: "POST", body: data, expectedUserID: userID, deadline: deadline)
            try checked(response); guard response.statusCode == 200 else { return CloudPartitionResponse(response) }
            let page = try JSONDecoder().decode(CloudPartRead.self, from: response.data)
            guard page.revision == initial.revision, !page.parts.isEmpty, page.parts.count <= keys.count else { throw CloudSyncError.message("云端分块没有读完整，请重试。") }
            // Align by key, not by position: a server that returns the parts in a
            // different order (or a subset) must not corrupt the mapping.
            let requested = Set(keys)
            var fetched: Set<String> = []
            for part in page.parts {
                let raw = Data(part.json.utf8)
                let digest = SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined()
                guard requested.contains(part.key), digest == part.hash else { throw CloudSyncError.message("云端分块校验未通过，原记录保留，请重试。") }
                values[part.key] = try JSONDecoder().decode(JSONValue.self, from: raw); hashes[part.key] = part.hash
                fetched.insert(part.key)
            }
            guard !fetched.isEmpty else { throw CloudSyncError.message("云端分块没有读完整，请重试。") }
            pending.removeAll { fetched.contains($0) }
            // Validated chunks can be reused after an interrupted large restore.
            // Never publish a partial CloudState to the app or upload it.
            cache.values = values; cache.hashes = hashes
        }
        let state = try CloudPartitionUnits.combine(values)
        let envelope = CloudStateEnvelope(revision: initial.revision, state: state, unchanged: false, media_cleanup_pending: nil)
        cache.values = values; cache.hashes = hashes
        return CloudPartitionResponse(AccountRawResponse(statusCode: 200, data: Data()), envelope: envelope)
    }
    static func write(account: AccountService, userID: Int, baseRevision: Int, state: CloudState, base: CloudState?, cache: CloudPartitionCache, deadline: Date? = nil) async throws -> CloudPartitionResponse {
        let sent = try CloudPartitionUnits.split(state)
        let previous = try base.map(CloudPartitionUnits.split) ?? [:]
        let keys = Set(sent.keys).union(previous.keys).sorted()
        let changes = keys.compactMap { key -> CloudPartChange? in
            guard sent[key] != previous[key] else { return nil }
            return CloudPartChange(key: key, value: sent[key] ?? .null)
        }
        for change in changes {
            guard try JSONEncoder().encode(change.value).count <= 4 * 1024 * 1024 else { throw CloudSyncError.message("单日记录或单份分析超过4MiB，请联系支持；本机和云端原记录保留。") }
        }
        let id = UUID().uuidString.lowercased()
        let begin = try JSONEncoder().encode(CloudPartBegin(id: id, base_revision: baseRevision, part_count: changes.count))
        let start = try await account.cloudRequest(path: "/me/sync/uploads", method: "POST", body: begin, expectedUserID: userID, deadline: deadline)
        try checked(start); guard start.statusCode == 200 else { return CloudPartitionResponse(start) }
        var index = 0
        while index < changes.count {
            var count = min(64, changes.count - index)
            var body = try JSONEncoder().encode(CloudPartUploadRequest(parts: Array(changes[index..<(index + count)])))
            while body.count > 2 * 1024 * 1024 && count > 1 {
                count = max(1, count / 2)
                body = try JSONEncoder().encode(CloudPartUploadRequest(parts: Array(changes[index..<(index + count)])))
            }
            let response = try await account.cloudRequest(path: "/me/sync/uploads/" + id, method: "POST", body: body, expectedUserID: userID, deadline: deadline)
            try checked(response); guard response.statusCode == 200 else { return CloudPartitionResponse(response) }
            guard try JSONDecoder().decode(CloudPartAck.self, from: response.data).accepted == count else { throw CloudSyncError.message("这批记录未收到完整确认，原记录保留，请重试。") }
            index += count
        }
        let committed = try await account.cloudRequest(path: "/me/sync/uploads/" + id + "/commit", method: "POST", body: Data("{}".utf8), expectedUserID: userID, deadline: deadline)
        try checked(committed); guard committed.statusCode == 200 else { return CloudPartitionResponse(committed) }
        return try await read(account: account, userID: userID, knownRevision: nil, cache: cache, deadline: deadline)
    }
}


// These immutable containers hold copies of Codable value types only. The worker
// never receives AppStore, AccountService, or references to mutable UI state.
struct CloudMergeWork: @unchecked Sendable {
    let local: CloudState
    let remote: CloudState
    let base: CloudState?
}
struct CloudMergeComputation: @unchecked Sendable {
    let state: CloudState
    let conflictBackup: Data?
    let conflicts: Int
}
struct CloudComparisonWork: @unchecked Sendable {
    let left: CloudState
    let right: CloudState
}
enum CloudBackgroundWork {
    static func merge(_ input: CloudMergeWork) async throws -> CloudMergeComputation {
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let count = try CloudMerge.conflictCount(local: input.local, remote: input.remote, base: input.base)
            let merged = try CloudMerge.merge(local: input.local, remote: input.remote, base: input.base)
            let backup: Data?
            if count > 0 { backup = try JSONEncoder().encode(input.remote) } else { backup = nil }
            try Task.checkCancellation()
            return CloudMergeComputation(state: merged, conflictBackup: backup, conflicts: count)
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }
    static func same(_ input: CloudComparisonWork) async throws -> Bool {
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let result = try CloudMerge.same(input.left, input.right)
            try Task.checkCancellation()
            return result
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }
}
