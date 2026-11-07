import Foundation

struct ManualPlanMovement: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var muscle: String
    var query: String?
    var libraryID: String?
    var customID: UUID?
    var unit = "次"
    var count = 3
    var weight: Double = 0
    var reps = 10
    var seconds = 30
    var restSeconds: Int? = nil
    var individualSets: [AIPlanSet]? = nil

    var effectiveSets: [AIPlanSet] {
        individualSets ?? Array(repeating: AIPlanSet(weight: unit == "秒" ? 0 : weight, reps: unit == "秒" ? 0 : reps, durationSeconds: unit == "秒" ? seconds : nil), count: max(0, min(count, 50)))
    }

    var valid: Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 100,
              ["次", "秒"].contains(unit), (1...50).contains(effectiveSets.count),
              restSeconds.map({ (0...3600).contains($0) }) ?? true else { return false }
        if individualSets == nil && !(1...50).contains(count) { return false }
        return effectiveSets.allSatisfy { set in
            let weight = set.weight ?? 0
            guard weight.isFinite, (0...RecordLimits.maximumWeight).contains(weight) else { return false }
            if unit == "秒" { return set.durationSeconds.map { (1...RecordLimits.maximumSeconds).contains($0) } == true }
            return set.durationSeconds == nil && (1...RecordLimits.maximumReps).contains(set.reps)
        }
    }
    var plannedExercise: AIPlanExercise {
        return AIPlanExercise(name: name, muscle: muscle, sets: effectiveSets,
            library_query: query, library_id: libraryID, custom_id: customID, custom_unit: customID == nil ? nil : unit, rest_seconds: restSeconds)
    }
}

struct ManualPlanDay: Codable, Equatable {
    var title = ""
    var movements: [ManualPlanMovement] = []
    // F3：循环编排生成的「待配置训练日」标记——还没有动作，不能当成已排好的训练或休息日。
    var placeholder: Bool? = nil
    /// 明确的休息日：没有动作、没有标题，也没有待配置标记。
    var isRestDay: Bool { movements.isEmpty && title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    /// 需要用户在采用前处理的待配置日：仍有标题却没有动作。
    var isUnconfiguredPlaceholder: Bool { placeholder == true && movements.isEmpty && !isRestDay }
}

struct ManualPlanDraft: Identifiable, Codable, Equatable {
    var version = 1
    var id = UUID()
    var title = "我的训练计划"
    var start = ClubDates.key(Date())
    var duration = 7
    var singleDay: Bool? = nil
    var editingDuration: Int { singleDay == true ? 1 : duration }
    // Keep hidden days when shortening a draft, so changing duration is reversible.
    var days = Array(repeating: ManualPlanDay(), count: 28)
    var proposalJobID: String? = nil
    var suggestedForProfile: MemberProfile? = nil
    // E1：计划描述与本计划意图（可选）。与共享身体目标分开：单份计划的意图
    // 只服务这份计划，不改全局 goal；nil/空=未设置。
    var planDescription: String? = nil
    var planIntent: String? = nil
    // E3：续排范围显式记录（编排方式生成后写入）。
    var planPatternLabel: String? = nil
    // E5：跨设备同步修订与删除标记。全部可选——Build 107 的旧草稿没有这些键，
    // 合成解码对可选字段用 decodeIfPresent，旧数据可正常读入（F2）。
    var updatedAt: Date? = nil
    var deleted: Bool? = nil
    var operationID: String { proposalJobID.map { "coach-plan-" + $0 } ?? ("manual-plan-" + id.uuidString.lowercased()) }
    var activeDays: [ManualPlanDay] { Array(days.prefix(max(0, min(editingDuration, 28)))) }
    /// 云端旧数据/异常数据可能缺少 28 天数组；进入 UI 前必须先过滤，避免下标越界。
    var structurallyValid: Bool {
        version == 1 && days.count == 28 && [7,14,28].contains(duration) && ClubDates.date(fromKey: start) != nil
    }
    func dateKey(offset: Int) -> String? {
        guard let date = ClubDates.date(fromKey: start), (0..<28).contains(offset),
              let result = ClubDates.calendar.date(byAdding: .day, value: offset, to: date) else { return nil }
        return ClubDates.key(result)
    }
    func validation(now: Date = Date()) -> String? {
        guard version == 1, days.count == 28, [7,14,28].contains(duration),
              let date = ClubDates.date(fromKey: start), !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              title.count <= 80 else { return "计划名称、周期或草稿格式不正确。" }
        guard ClubDates.key(date) >= ClubDates.key(now) else { return "开始日期已过去，请选择今天或未来日期。" }
        // F3：循环编排生成的待配置日必须先配动作，不能把半成品当训练日采用。
        // 用户已把标题清空（或点了“设为休息日”）时，这一天就是休息日，不再拦截。
        if placeholderCount > 0 {
            return "还有 \(placeholderCount) 个待配置训练日（循环编排生成、还没有动作）。请给它们添加动作，或使用“设为休息日”。"
        }
        guard activeDays.contains(where: { !$0.movements.isEmpty }) else { return "至少安排一个训练日，其他空白日期会作为休息日。" }
        guard activeDays.allSatisfy({ $0.title.count <= 80 && $0.movements.count <= 30 && $0.movements.allSatisfy(\.valid) }) else {
            return "请核对动作与每组目标：每个训练日最多 30 个动作，每个动作 1–50 组，次数和时间不能为零。"
        }
        return nil
    }
    func result(now: Date = Date()) throws -> AIResult {
        if let message = validation(now: now) { throw ManualPlanError.message(message) }
        let sessions = try activeDays.enumerated().compactMap { offset, day -> AIPlanSession? in
            guard !day.movements.isEmpty else { return nil }
            guard let key = dateKey(offset: offset) else { throw ManualPlanError.message("日期计算失败，请重新选择开始日期。") }
            return AIPlanSession(date: key, label: day.title.isEmpty ? "自由训练" : day.title,
                                 exercises: day.movements.map(\.plannedExercise))
        }
        // E1：计划描述与意图随方案进入版本记录（notes），不改全局身体目标。
        var notes: [String] = []
        if let description = planDescription, !description.isEmpty { notes.append("计划描述：" + description) }
        if let intent = planIntent, !intent.isEmpty { notes.append("计划意图：" + intent) }
        if let pattern = planPatternLabel, !pattern.isEmpty { notes.append("编排方式：" + pattern) }
        return AIResult(kind: "plan", notes: notes, title: title, sessions: sessions, plan_days: duration,
                        plan_description: planDescription, plan_intent: planIntent, plan_pattern: planPatternLabel)
    }
    static func importing(_ result: AIResult, originalStart: String, start: Date = Date()) throws -> ManualPlanDraft {
        guard result.kind == "plan", let sessions = result.sessions, !sessions.isEmpty,
              let origin = ClubDates.date(fromKey: originalStart), [7,14,28].contains(result.plan_days ?? 7),
              Set(sessions.map(\.date)).count == sessions.count else { throw ManualPlanError.message("方案格式不完整，无法创建可编辑副本。") }
        var draft = ManualPlanDraft(); draft.title = String((result.title ?? "复用训练计划").prefix(80))
        draft.start = ClubDates.key(start); draft.duration = result.plan_days ?? 7
        for session in sessions {
            guard let date = ClubDates.date(fromKey: session.date),
                  let offset = ClubDates.calendar.dateComponents([.day], from: origin, to: date).day,
                  (0..<draft.duration).contains(offset) else { throw ManualPlanError.message("方案日期超出周期，请重新选择。") }
            draft.days[offset].title = session.label
            draft.days[offset].movements = try session.exercises.map { exercise in
                let timed = exercise.sets.first?.durationSeconds != nil
                guard !exercise.sets.isEmpty, exercise.sets.allSatisfy({ ($0.durationSeconds != nil) == timed }) else { throw ManualPlanError.message("同一动作包含混合计量方式，请先核对原方案。") }
                let first = exercise.sets[0]
                return ManualPlanMovement(name: exercise.displayName, muscle: exercise.muscle, query: exercise.library_query,
                    libraryID: exercise.library_id, customID: exercise.custom_id, unit: timed ? "秒" : "次", count: exercise.sets.count,
                    weight: first.weight ?? 0, reps: first.reps, seconds: first.durationSeconds ?? 30,
                    restSeconds: exercise.rest_seconds, individualSets: exercise.sets)
            }
        }
        if let issue = draft.validation(now: start) { throw ManualPlanError.message(issue) }
        return draft
    }
    mutating func repeatFirstWeek() {
        guard days.count == 28, [14,28].contains(duration) else { return }
        for index in 7..<duration {
            days[index] = days[index % 7]
            for movement in days[index].movements.indices { days[index].movements[movement].id = UUID() }
        }
    }
    mutating func copyDay(from source: Int, to target: Int) {
        guard days.count == 28, [7,14,28].contains(duration), (0..<duration).contains(source), (0..<duration).contains(target), source != target else { return }
        days[target] = days[source]
        for index in days[target].movements.indices { days[target].movements[index].id = UUID() }
    }
    // E4：交换两天（休息日与动作顺序随天整体移动；只动草稿，已采用与已完成内容不受影响）。
    mutating func swapDays(_ a: Int, _ b: Int) {
        guard days.count == 28, [7,14,28].contains(duration), (0..<duration).contains(a), (0..<duration).contains(b), a != b else { return }
        days.swapAt(a, b)
    }
    func reusable(start: Date = Date()) -> ManualPlanDraft {
        var copy = self; copy.id = UUID(); copy.start = ClubDates.key(start); copy.proposalJobID = nil; copy.suggestedForProfile = nil
        for day in copy.days.indices {
            for movement in copy.days[day].movements.indices { copy.days[day].movements[movement].id = UUID() }
        }
        return copy
    }
}

struct ManualPlanTemplate: Identifiable, Codable, Equatable {
    var id = UUID()
    let createdAt: Date
    let draft: ManualPlanDraft
    var recurrence130: WeeklyRecurrence130? = nil
    // E5/F2：同步修订与删除标记可选——旧模板文件没有这些键也能解码。
    var updatedAt: Date? = nil
    var deleted: Bool? = nil
}
struct ManualTemplateList {
    let items: [ManualPlanTemplate]
    let unreadableCount: Int
}

enum ManualPlanError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

// E2/E3：循环编排方式。保留 7/14/28 天入口兼容；循环先生成明确可预览的日期安排，
// 只填充草稿中的空白日（不动已编排内容），续排范围显式记录在草稿上。
// 星期编号沿用资料约定：1=周一 … 7=周日（与 profile.trainingDays 一致）。
enum PlanCyclePattern: String, CaseIterable {
    case weeklyFixed = "按周固定"
    case on2off1 = "练二休一"
    case on3off1 = "练三休一"
    case custom = "自定义循环"

    /// 把日期的 Calendar 星期（1=周日）换算为约定编号（1=周一）。
    static func weekdayIndex(_ date: Date) -> Int {
        (ClubDates.calendar.component(.weekday, from: date) + 5) % 7 + 1
    }

    /// 在 0..<duration 的偏移里选出训练日（按真实开始日的星期锚定）。
    func trainingOffsets(duration: Int, startDateKey: String, weekdays: Set<Int>, customCycle: [Bool]) -> [Int] {
        switch self {
        case .weeklyFixed:
            guard let start = ClubDates.date(fromKey: startDateKey) else { return [] }
            return (0..<duration).filter { offset in
                guard let date = ClubDates.calendar.date(byAdding: .day, value: offset, to: start) else { return false }
                return weekdays.contains(Self.weekdayIndex(date))
            }
        case .on2off1:
            return (0..<duration).filter { $0 % 3 < 2 }
        case .on3off1:
            return (0..<duration).filter { $0 % 4 < 3 }
        case .custom:
            let cycle = customCycle.isEmpty ? [true, true, false] : customCycle
            return (0..<duration).filter { cycle[$0 % cycle.count] }
        }
    }
    var needsWeekdays: Bool { self == .weeklyFixed }
    var needsCustomCycle: Bool { self == .custom }
}

extension ManualPlanDraft {
    /// E3：编排预览——生成明确日期列表供确认，不预生成无限数据。
    func patternPreview(_ pattern: PlanCyclePattern, weekdays: Set<Int>, customCycle: [Bool]) -> [String] {
        pattern.trainingOffsets(duration: duration, startDateKey: start, weekdays: weekdays, customCycle: customCycle)
            .compactMap { dateKey(offset: $0) }
    }
    /// E2/E3：应用编排到空白日（已编排的训练日与休息保持不动）。
    /// 生成的是「待配置训练日」——需添加动作后才算训练日（F3）；续排范围写入 planPatternLabel。
    @discardableResult
    mutating func applyPattern(_ pattern: PlanCyclePattern, weekdays: Set<Int>, customCycle: [Bool]) -> Int {
        let offsets = pattern.trainingOffsets(duration: duration, startDateKey: start, weekdays: weekdays, customCycle: customCycle)
        var filled = 0
        for offset in offsets where days[offset].movements.isEmpty && days[offset].title.isEmpty {
            days[offset].title = "待配置训练日"
            days[offset].placeholder = true
            filled += 1
        }
        planPatternLabel = "\(pattern.rawValue) · \(start) 起 \(duration) 天内 \(offsets.count) 个训练日"
        return filled
    }
    /// Repeat real configured training days; never create empty placeholder workouts.
    mutating func fillPattern(_ pattern: PlanCyclePattern, weekdays: Set<Int>, customCycle: [Bool]) -> Int {
        let templates = activeDays.filter { !$0.movements.isEmpty }
        guard !templates.isEmpty else { return 0 }
        let offsets = pattern.trainingOffsets(duration: editingDuration, startDateKey: start, weekdays: weekdays, customCycle: customCycle)
        var count = 0
        for (index, offset) in offsets.enumerated() where days[offset].movements.isEmpty {
            days[offset] = templates[index % templates.count]
            days[offset].placeholder = nil
            for movement in days[offset].movements.indices { days[offset].movements[movement].id = UUID() }
            count += 1
        }
        planPatternLabel = "\(pattern.rawValue) · \(start) 起 \(editingDuration) 天"
        return count
    }
    /// 待配置训练日数量（采用前必须清零）。
    var placeholderCount: Int { activeDays.filter(\.isUnconfiguredPlaceholder).count }
    /// 明确把某一天设为休息日：一次性清理占位标记、标题和动作。
    /// 只修改草稿；已采用的计划与训练记录不受影响。
    mutating func setRestDay(at index: Int) {
        guard days.indices.contains(index), (0..<duration).contains(index) else { return }
        days[index] = ManualPlanDay()
    }
}

enum ManualPlanDraftStorage {
    static func directory(owner: Int) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BojiClub/manual-plans-user-\(owner)", isDirectory: true)
    }
    /// Plan drafts can contain profile-derived intent and must follow the same
    /// privacy boundary as records: complete protection and no iCloud backup.
    private static func prepare(_ folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var resourceFolder = folder
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? resourceFolder.setResourceValues(values)
    }
    static func load(owner: Int) throws -> ManualPlanDraft? {
        let url = directory(owner: owner).appendingPathComponent("draft.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let result = try JSONDecoder().decode(ManualPlanDraft.self, from: Data(contentsOf: url))
        guard result.version == 1, result.days.count == 28, [7,14,28].contains(result.duration) else {
            throw ManualPlanError.message("草稿格式暂不支持，原文件已保留。")
        }
        return result
    }
    static func save(_ draft: ManualPlanDraft, owner: Int) throws {
        let folder = directory(owner: owner)
        try prepare(folder)
        try JSONEncoder().encode(draft).write(to: folder.appendingPathComponent("draft.json"),
                                             options: [.atomic, .completeFileProtection])
    }
    static func clear(owner: Int) throws {
        let url = directory(owner: owner).appendingPathComponent("draft.json")
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
    static func archive(_ draft: ManualPlanDraft, owner: Int) throws {
        let folder = directory(owner: owner)
        try prepare(folder)
        try JSONEncoder().encode(draft).write(to: folder.appendingPathComponent("adopted-\(draft.id.uuidString).json"),
            options: [.atomic, .completeFileProtection])
    }
    static func saveTemplate(_ draft: ManualPlanDraft, owner: Int) throws {
        guard let start = ClubDates.date(fromKey: draft.start), draft.validation(now: start) == nil else {
            throw ManualPlanError.message("请先完成计划名称、至少一个训练日和动作目标，再保存模板。")
        }
        let folder = directory(owner: owner).appendingPathComponent("templates", isDirectory: true)
        try prepare(folder)
        let value = ManualPlanTemplate(createdAt: Date(), draft: draft)
        try JSONEncoder().encode(value).write(to: folder.appendingPathComponent(value.id.uuidString + ".json"),
            options: [.atomic, .completeFileProtection])
    }
    static func templates(owner: Int) throws -> ManualTemplateList {
        let folder = directory(owner: owner).appendingPathComponent("templates", isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else { return ManualTemplateList(items: [], unreadableCount: 0) }
        var values: [ManualPlanTemplate] = []; var unreadable = 0
        for path in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) where path.pathExtension == "json" {
            do {
                let value = try JSONDecoder().decode(ManualPlanTemplate.self, from: Data(contentsOf: path))
                guard path.deletingPathExtension().lastPathComponent == value.id.uuidString,
                      let start = ClubDates.date(fromKey: value.draft.start), value.draft.validation(now: start) == nil else { throw ManualPlanError.message("模板格式不正确") }
                values.append(value)
            } catch { unreadable += 1 }
        }
        return ManualTemplateList(items: values.sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString > $1.id.uuidString : $0.createdAt > $1.createdAt }, unreadableCount: unreadable)
    }
    static func deleteTemplate(_ id: UUID, owner: Int) throws {
        let file = directory(owner: owner).appendingPathComponent("templates", isDirectory: true).appendingPathComponent(id.uuidString + ".json")
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
}
