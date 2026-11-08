import SwiftUI

// MARK: - V2 卡片协议（schema v1）
//
// 与 backend/card_composer.py 的信封契约一一对应。服务端只可能下发
// AICardRegistry 白名单内的只读卡；客户端再校验一次类型/版本/动作，
// 未知类型或更高版本降级为"请更新 App"占位，绝不执行未知动作。

struct AICardAction: Codable, Equatable, Identifiable {
    let action_id: String
    let label: String
    let kind: String
    var id: String { action_id }
}

struct AICardEnvelope: Codable, Equatable, Identifiable {
    let card_id: String
    let card_type: String
    let schema_version: Int
    let title: String
    let payload: JSONValue
    var actions: [AICardAction]
    let evidence_refs: [String]
    let created_at: String?
    let expires_at: String?
    var id: String { card_id }

    private static let expiryParser: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// 卡片过期只做降级（禁用动作 + 标注），不删除消息历史。
    var isExpired: Bool {
        guard let expires_at else { return false }
        guard let date = Self.expiryParser.date(from: expires_at) else { return true }
        return date < Date()
    }

    var payloadDate: String? {
        if case .object(let fields) = payload, let date = fields["date"]?.string { return date }
        return nil
    }
}

extension JSONValue {
    var numberValue: Double? { if case .number(let v) = self { return v }; return nil }
    var boolValue: Bool? { if case .bool(let v) = self { return v }; return nil }
}

// MARK: - 注册表与动作白名单

enum AICardRegistry {
    static let supportedSchemaVersion = 1
    static let knownTypes: Set<String> = ["today_training", "training_progress", "insight", "meal_draft", "weight_entry",
                                          "advice", "schedule_preview", "plan_swap_preview", "plan_activate_preview",
                                          "club_progress", "clarification", "profile_change", "memory_draft"]
    /// 双保险：即便服务端被注入未知动作，客户端也不会响应白名单外的 action_id。
    static let actionWhitelist: Set<String> = ["start_training", "view_plan", "create_plan", "view_records",
                                               "confirm_proposal", "dismiss_proposal", "undo_action",
                                               "check_execution", "open_detail", "discard_training_draft"]

    static func isRenderable(_ card: AICardEnvelope) -> Bool {
        knownTypes.contains(card.card_type) && card.schema_version <= supportedSchemaVersion
    }
}

// MARK: - Phase 2：能力路由卡片载荷

/// 建议卡（只读建议：休息 / 减量 / 正常训练）。不含伪精确的恢复分数。
struct AIAdviceCardPayload: Equatable {
    struct Option: Equatable, Identifiable {
        let choice: String
        let label: String
        let reason: String
        var id: String { choice }
    }
    let options: [Option]
    let note: String?

    init?(json: JSONValue) {
        guard case .object(let fields) = json,
              case .array(let raw)? = fields["options"], !raw.isEmpty else { return nil }
        var parsed: [Option] = []
        for item in raw {
            guard case .object(let entry) = item,
                  let choice = entry["choice"]?.string,
                  let label = entry["label"]?.string else { return nil }
            parsed.append(Option(choice: choice, label: label, reason: entry["reason"]?.string ?? ""))
        }
        guard parsed.count == raw.count else { return nil }
        options = parsed
        note = fields["note"]?.string
    }
}

/// 提案预览卡：绑定服务端 proposal_id，确认前内容不可被替换。
struct AIProposalPreviewPayload: Equatable {
    let proposalID: String
    let kind: String
    let expiresAt: String?
    let details: [String]
    var summary: String {
        switch kind {
        case "plan_change_proposal": return "改期预览：确认后才会移动训练安排。"
        case "exercise_swap": return "换肌群预览：只影响这一天，之后的安排不变。"
        case "plan_activation": return "启用新计划预览：确认后才会切换未来的安排。"
        case "meal_draft": return "待确认的饮食记录：确认后才会写入。"
        case "weight_entry": return "待确认的身体记录：确认后才会写入。"
        default: return "待确认的操作：确认后才会生效。"
        }
    }

    init?(json: JSONValue) {
        guard case .object(let fields) = json, let id = fields["proposal_id"]?.string, !id.isEmpty else { return nil }
        proposalID = id
        kind = fields["kind"]?.string ?? "plan_change_proposal"
        expiresAt = fields["expires_at"]?.string
        var lines: [String] = []
        let preview: [String: JSONValue]
        if case .object(let p)? = fields["preview"] { preview = p } else { preview = fields }
        if case .array(let retained)? = preview["retained_dates"], !retained.isEmpty { lines.append("保留的日期：" + retained.compactMap(\.string).joined(separator: "、")) }
        if let title = preview["title"]?.string { lines.append(title) }
        if preview["compensates"]?.string != nil { lines.append("这是此前变更的纠正预览，请核对列出的日期和动作。") }
        if let date = preview["date"]?.string { lines.append("日期：" + date) }
        if let duration = preview["duration"]?.numberValue { lines.append("周期：\(Int(duration)) 天") }
        if let remaining = preview["remaining_sets"]?.numberValue { lines.append("还有 \(Int(remaining)) 组未完成。确认将只保存已经登记的实际组，不会把剩余组标成完成。") }
        if case .array(let moves)? = preview["moves"] {
            for move in moves { if case .object(let m) = move { lines.append((m["from"]?.string ?? "") + " → " + (m["to"]?.string ?? "")) } }
        }
        if case .object(let before)? = preview["_preview_before"] {
            for date in before.keys.sorted() {
                if case .object(let day)? = before[date], case .array(let exercises)? = day["exercises"] {
                    let names = exercises.compactMap { ex -> String? in if case .object(let e) = ex { return e["name"]?.string }; return nil }
                    lines.append("原安排 \(date)：" + (names.isEmpty ? "休息 / 未安排" : names.joined(separator: "、")))
                }
            }
        }
        func describe(_ exercises: [JSONValue]) -> String {
            exercises.compactMap { value -> String? in
                guard case .object(let ex) = value else { return nil }
                var sets: [String] = []
                if case .array(let rows)? = ex["sets"] { sets = rows.compactMap { row in
                    guard case .object(let set) = row else { return nil }
                    if let seconds = set["durationSeconds"]?.numberValue ?? set["duration_seconds"]?.numberValue { return "\(Int(seconds)) 秒" }
                    return "\(set["weight"]?.numberValue ?? 0) kg × \(Int(set["reps"]?.numberValue ?? 0)) 次"
                } }
                return (ex["name"]?.string ?? "动作") + "：" + sets.joined(separator: "；")
            }.joined(separator: "\n")
        }
        if case .array(let exercises)? = preview["exercises"] { lines.append("新安排：\n" + describe(exercises)) }
        if case .array(let sessions)? = preview["sessions"] { for session in sessions {
            if case .object(let row) = session, case .array(let exercises)? = row["exercises"] { lines.append((row["date"]?.string ?? "") + " " + (row["label"]?.string ?? "") + "\n" + describe(exercises)) }
        } }
        details = lines
    }
}

/// 俱乐部进度卡（只读）。
struct AIClubProgressPayload: Equatable {
    struct Requirement: Equatable, Identifiable {
        let title: String
        let current: Int
        let target: Int
        var id: String { title }
    }
    let seasonTitle: String
    let requirements: [Requirement]

    init?(json: JSONValue) {
        guard case .object(let fields) = json, let title = fields["season_title"]?.string else { return nil }
        seasonTitle = title
        var parsed: [Requirement] = []
        if case .array(let raw)? = fields["requirements"] {
            for item in raw {
                guard case .object(let entry) = item, let name = entry["title"]?.string else { continue }
                parsed.append(Requirement(title: name, current: Int(entry["current"]?.numberValue ?? 0),
                                           target: Int(entry["target"]?.numberValue ?? 0)))
            }
        }
        requirements = parsed
    }
}

// MARK: - 类型化载荷（缺字段 → nil/默认，绝不猜测）

struct AITodayTrainingPayload: Equatable {
    let date: String
    var displayName: String?
    var exerciseCount: Int?
    var totalSets: Int?
    var estimatedMinutes: Int?
    var estimationBasis: String?
    var isEmpty: Bool
    var reason: String?
    var hint: String?

    init?(json: JSONValue) {
        guard case .object(let fields) = json, let date = fields["date"]?.string else { return nil }
        self.date = date
        displayName = fields["display_name"]?.string
        exerciseCount = fields["exercise_count"]?.numberValue.map(Int.init)
        totalSets = fields["total_sets"]?.numberValue.map(Int.init)
        estimatedMinutes = fields["estimated_minutes"]?.numberValue.map(Int.init)
        estimationBasis = fields["estimation_basis"]?.string
        isEmpty = fields["empty"]?.boolValue ?? false
        reason = fields["reason"]?.string
        hint = fields["hint"]?.string
    }
}

struct AITrainingProgressPayload: Equatable {
    let windowStart: String
    let windowEnd: String
    let trainingDays: Int
    let completedSets: Int
    var confirmedSessions: Int?
    var isEmpty: Bool
    var hint: String?

    init?(json: JSONValue) {
        guard case .object(let fields) = json else { return nil }
        guard let start = fields["window_start"]?.string, let end = fields["window_end"]?.string else { return nil }
        windowStart = start
        windowEnd = end
        trainingDays = fields["training_days"]?.numberValue.map(Int.init) ?? 0
        completedSets = fields["completed_sets"]?.numberValue.map(Int.init) ?? 0
        confirmedSessions = fields["confirmed_sessions"]?.numberValue.map(Int.init)
        isEmpty = fields["empty"]?.boolValue ?? false
        hint = fields["hint"]?.string
    }
}

struct AIInsightCardPayload: Equatable {
    let text: String
    var windowDays: Int?
    var trainingDays: Int?

    init?(json: JSONValue) {
        guard case .object(let fields) = json, let text = fields["text"]?.string else { return nil }
        self.text = text
        windowDays = fields["window_days"]?.numberValue.map(Int.init)
        trainingDays = fields["training_days"]?.numberValue.map(Int.init)
    }
}

// MARK: - 卡片视图

/// 对话时间线内的原生卡片容器：头部（标题/状态）+ 类型化内容 + 动作行。
struct AIMealDraftEntry: Hashable {
    let name: String
    let category: String
    let calories: Double?
    let protein: Double?
    let carbs: Double?
    let fat: Double?

    var portion: String? = nil
    var nutritionText: String {
        var parts: [String] = []
        if let calories { parts.append(String(format: "%.0f 千卡", calories)) }
        if let protein { parts.append(String(format: "蛋白 %.0f g", protein)) }
        if let carbs { parts.append(String(format: "碳水 %.0f g", carbs)) }
        if let fat { parts.append(String(format: "脂肪 %.0f g", fat)) }
        return parts.joined(separator: " · ")
    }
}

struct AIMealDraftPayload: Equatable {
    let date: String
    let meals: [AIMealDraftEntry]

    init?(json: JSONValue) {
        guard case .object(let fields) = json, let date = fields["date"]?.string,
              case .array(let rawMeals)? = fields["meals"], !rawMeals.isEmpty else { return nil }
        var entries: [AIMealDraftEntry] = []
        for meal in rawMeals {
            guard case .object(let mealFields) = meal, let name = mealFields["name"]?.string,
                  let category = mealFields["category"]?.string else { return nil }
            entries.append(AIMealDraftEntry(name: name, category: category,
                calories: mealFields["calories"]?.numberValue, protein: mealFields["protein"]?.numberValue,
                carbs: mealFields["carbs"]?.numberValue, fat: mealFields["fat"]?.numberValue, portion: mealFields["portion"]?.string))
        }
        self.date = date
        self.meals = entries
    }
}

struct AIWeightEntryPayload: Hashable {
    let date: String
    let kilograms: Double
    let bodyFatPercentage: Double?
    let waistCircumferenceCM: Double?

    init?(json: JSONValue) {
        guard case .object(let fields) = json, let date = fields["date"]?.string,
              let kilograms = fields["kilograms"]?.numberValue else { return nil }
        self.date = date
        self.kilograms = kilograms
        self.bodyFatPercentage = fields["bodyFatPercentage"]?.numberValue
        self.waistCircumferenceCM = fields["waistCircumferenceCM"]?.numberValue
    }

    var primaryText: String { String(format: "%.1f kg", kilograms) }
    var extraText: String? {
        var parts: [String] = []
        if let bodyFatPercentage { parts.append(String(format: "体脂 %.1f%%", bodyFatPercentage)) }
        if let waistCircumferenceCM { parts.append(String(format: "腰围 %.1f cm", waistCircumferenceCM)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

enum ClubDraftCardOutcome: Equatable {
    case confirming
    case confirmed
    case dismissed
    case conflict(String)
}

struct AICardView: View {
    let card: AICardEnvelope
    var outcome: ClubDraftCardOutcome? = nil
    let onAction: (AICardAction) -> Void

    private var actionsEnabled: Bool {
        guard !card.isExpired, AICardRegistry.isRenderable(card) else { return false }
        switch outcome {
        case nil, .conflict: return true
        default: return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BojiLayout.rowGap) {
            HStack(alignment: .top, spacing: BojiLayout.inline) {
                Image(systemName: "square.grid.2x2")
                    .bojiType(.secondary)
                    .foregroundStyle(BojiColor.brandAccent)
                Text(card.title)
                    .bojiFont(.label)
                    .foregroundStyle(BojiColor.textPrimary)
                    .accessibilityIdentifier("ai-card-\(card.card_type)")
                Spacer(minLength: 0)
                if card.isExpired {
                    Text("已过期")
                        .bojiType(.caption)
                        .foregroundStyle(BojiColor.textSecondary)
                        .padding(.horizontal, BojiLayout.inline)
                        .padding(.vertical, BojiLayout.tight)
                        .background(BojiColor.subtleSurface, in: Capsule())
                }
            }
            if !AICardRegistry.isRenderable(card) {
                unsupported
            } else {
                switch card.card_type {
                case "today_training": todayTraining
                case "training_progress": trainingProgress
                case "insight": insightCard
                case "meal_draft": mealDraft
                case "weight_entry": weightEntry
                case "advice": adviceCard
                case "clarification": clarificationCard
                case "schedule_preview", "plan_swap_preview", "plan_activate_preview": proposalPreview
                case "club_progress": clubProgress
                case "profile_change": AIProfileChangeCard(card: card, enabled: actionsEnabled)
                case "memory_draft": AIMemoryDraftCard(card: card, enabled: actionsEnabled)
                default: unsupported
                }
            }
            if let outcome {
                HStack(spacing: BojiLayout.tight) {
                    switch outcome {
                    case .confirming:
                        Image(systemName: "hourglass").bojiType(.caption)
                        Text("正在核对…").bojiFont(.secondary)
                    case .confirmed:
                        Image(systemName: "checkmark.circle.fill").bojiType(.caption)
                        Text("已确认写入记录").bojiFont(.secondary)
                    case .dismissed:
                        Image(systemName: "slash.circle").bojiType(.caption)
                        Text("已忽略").bojiFont(.secondary)
                    case .conflict(let message):
                        Image(systemName: "exclamationmark.triangle.fill").bojiType(.caption)
                        Text(message).bojiFont(.secondary)
                    }
                }
                .foregroundStyle(outcome == .confirmed ? BojiColor.emeraldAccent : BojiColor.textSecondary)
            }
            if !card.actions.isEmpty {
                VStack(alignment: .leading, spacing: BojiSpace.tight) {
                    ForEach(card.actions) { action in
                        actionControl(action)
                            .frame(minHeight: 44)
                            .disabled(!actionsEnabled || !AICardRegistry.actionWhitelist.contains(action.action_id))
                            // Stable identifiers distinguish card actions from other training controls.
                            .accessibilityIdentifier("ai-card-action-\(action.action_id)")
                    }
                }
                .padding(.top, BojiSpace.tightRow)
            }
            DisclosureGroup("查看卡片依据") {
                Text(evidenceLine).bojiType(.label).foregroundStyle(.secondary)
            }.bojiType(.label).foregroundStyle(.secondary)
        }
        .padding(BojiLayout.cardInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BojiColor.cardSurface, in: RoundedRectangle(cornerRadius: BojiRadius.cardSmall, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: BojiRadius.cardSmall, style: .continuous)
            .stroke(BojiColor.outline, lineWidth: 0.5).allowsHitTesting(false) }
        // 不在容器上放 accessibilityIdentifier：容器标识符会传播并覆盖所有子元素
        // （含动作按钮的 ai-card-action-*），标题文本已携带 ai-card-{type} 供测试定位。
        .opacity(card.isExpired ? 0.72 : 1)
    }

    @ViewBuilder private func actionControl(_ action: AICardAction) -> some View {
        if ["start_training", "create_plan", "confirm_proposal"].contains(action.action_id) {
            Button(action.label) { onAction(action) }
                .buttonStyle(.borderedProminent).tint(ClubBrand.accent)
        } else {
            Button(action.label) { onAction(action) }
                .buttonStyle(.bordered).tint(ClubBrand.accent)
        }
    }

    @ViewBuilder private var clarificationCard: some View {
        if case .object(let fields) = card.payload {
            Text(fields["question"]?.string ?? "请补充具体信息后继续。")
            if case .array(let choices)? = fields["choices"] { ForEach(Array(choices.enumerated()), id: \.offset) { _, value in Text(value.string ?? "").bojiType(.secondary) } }
            Text("请在消息输入框补充说明；当前没有执行写入。").bojiType(.label).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var adviceCard: some View {
        if let payload = AIAdviceCardPayload(json: card.payload) {
            VStack(alignment: .leading, spacing: BojiSpace.tight) {
                ForEach(payload.options) { option in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(option.label)
                            .bojiFont(.label)
                            .foregroundStyle(BojiColor.textPrimary)
                        Text(option.reason)
                            .bojiFont(.secondary)
                            .foregroundStyle(BojiColor.textSecondary)
                    }
                }
                if let note = payload.note {
                    Text(note)
                        .bojiFont(.secondary)
                        .foregroundStyle(BojiColor.textSecondary)
                }
            }
        } else {
            unsupported
        }
    }

    @ViewBuilder private var proposalPreview: some View {
        if let payload = AIProposalPreviewPayload(json: card.payload) {
            VStack(alignment: .leading, spacing: BojiSpace.tight) {
                Text(payload.summary)
                    .bojiFont(.secondary)
                    .foregroundStyle(BojiColor.textSecondary)
                ForEach(Array(payload.details.enumerated()), id: \.offset) { _, line in Text(line).bojiType(.secondary).fixedSize(horizontal: false, vertical: true) }
                if let expires = payload.expiresAt, !expires.isEmpty {
                    Text("提案有效期至 \(expires)")
                        .bojiFont(.secondary)
                        .foregroundStyle(BojiColor.textSecondary)
                }
            }
        } else {
            unsupported
        }
    }

    @ViewBuilder private var clubProgress: some View {
        if let payload = AIClubProgressPayload(json: card.payload) {
            VStack(alignment: .leading, spacing: BojiSpace.tight) {
                Text(payload.seasonTitle)
                    .bojiFont(.label)
                    .foregroundStyle(BojiColor.textPrimary)
                ForEach(payload.requirements) { requirement in
                    HStack {
                        Text(requirement.title)
                            .bojiFont(.secondary)
                            .foregroundStyle(BojiColor.textSecondary)
                        Spacer()
                        Text("\(requirement.current)/\(requirement.target)")
                            .bojiFont(.secondary)
                            .foregroundStyle(BojiColor.textPrimary)
                    }
                }
            }
        } else {
            unsupported
        }
    }

    @ViewBuilder private var mealDraft: some View {
        if let payload = AIMealDraftPayload(json: card.payload) {
            ForEach(payload.meals, id: \.self) { meal in
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(meal.category) · \(meal.name)")
                        .bojiFont(.label)
                        .foregroundStyle(BojiColor.textPrimary)
                    if let portion = meal.portion { Text(portion).bojiType(.caption).foregroundStyle(.secondary) }
                    if meal.nutritionText.isEmpty {
                        Text("未估算营养值；确认后按记录留存。")
                            .bojiFont(.secondary)
                            .foregroundStyle(BojiColor.textSecondary)
                    } else {
                        Text(meal.nutritionText)
                            .bojiFont(.secondary)
                            .foregroundStyle(BojiColor.textSecondary)
                    }
                }
            }
            Text("确认后将写入当天的饮食记录，可在记录页修改。")
                .bojiFont(.secondary)
                .foregroundStyle(BojiColor.textSecondary)
        } else {
            unsupported
        }
    }

    @ViewBuilder private var weightEntry: some View {
        if let payload = AIWeightEntryPayload(json: card.payload) {
            Text(payload.primaryText)
                .bojiFont(.exerciseName)
                .foregroundStyle(BojiColor.textPrimary)
            if let extra = payload.extraText {
                Text(extra)
                    .bojiFont(.secondary)
                    .foregroundStyle(BojiColor.textSecondary)
            }
            Text("确认后将写入当天的身体记录。")
                .bojiFont(.secondary)
                .foregroundStyle(BojiColor.textSecondary)
        } else {
            unsupported
        }
    }

    private var unsupported: some View {
        Text("这张卡片来自更新版本的功能，更新 App 后即可查看。")
            .bojiFont(.secondary)
            .foregroundStyle(BojiColor.textSecondary)
    }

    @ViewBuilder private var todayTraining: some View {
        if let payload = AITodayTrainingPayload(json: card.payload) {
            if payload.isEmpty {
                Text(payload.hint ?? "今天没有已安排的训练。")
                    .bojiFont(.secondary)
                    .foregroundStyle(BojiColor.textSecondary)
            } else {
                Text(payload.displayName ?? "今日训练安排")
                    .bojiFont(.exerciseName)
                    .foregroundStyle(BojiColor.textPrimary)
                if let exercises = payload.exerciseCount, let sets = payload.totalSets {
                    Text("\(exercises) 个动作 · \(sets) 组")
                        .bojiFont(.secondary)
                        .foregroundStyle(BojiColor.textSecondary)
                }
                if let minutes = payload.estimatedMinutes {
                    Text("预计约 \(minutes) 分钟\(payload.estimationBasis.map { "（\($0)）" } ?? "")")
                        .bojiFont(.secondary)
                        .foregroundStyle(BojiColor.textSecondary)
                }
            }
        } else {
            unsupported
        }
    }

    @ViewBuilder private var trainingProgress: some View {
        if let payload = AITrainingProgressPayload(json: card.payload) {
            if payload.isEmpty {
                Text(payload.hint ?? "这段时间还没有已确认的训练记录。")
                    .bojiFont(.secondary)
                    .foregroundStyle(BojiColor.textSecondary)
            } else {
                AITrainingDataCard134(payload: payload)
            }
        } else {
            unsupported
        }
    }

    @ViewBuilder private var insightCard: some View {
        if let payload = AIInsightCardPayload(json: card.payload) {
            Text(payload.text)
                .bojiFont(.body)
                .foregroundStyle(BojiColor.textPrimary)
        } else {
            unsupported
        }
    }

    private var evidenceLine: String {
        if card.evidence_refs.isEmpty {
            return "卡片数据来自本次提交的记录快照"
        }
        return "数据依据：" + card.evidence_refs.joined(separator: "、")
    }
}

// MARK: - 动作路由（白名单内 → 既有导航/通知；白名单外忽略）

extension Notification.Name {
    /// 卡片动作「开始训练」：由宿主壳（V2 双模式壳与旧 5-Tab 壳）接收并打开训练页。
    static let clubAIStartTraining = Notification.Name("clubAIStartTraining")
}

enum AICardActionRouter {
    /// dateKey 为卡片携带的日期（缺省回落请求日期）。返回 true 表示动作已被受理。
    @MainActor
    static func handle(_ action: AICardAction, card: AICardEnvelope, requestDate: String,
                       openDestination: (ClubCoachAction) -> Void) -> Bool {
        guard AICardRegistry.isRenderable(card), AICardRegistry.actionWhitelist.contains(action.action_id), !card.isExpired else { return false }
        let dateKey = card.payloadDate ?? requestDate
        switch action.action_id {
        case "start_training":
            NotificationCenter.default.post(name: .clubAIStartTraining, object: nil, userInfo: ["date": dateKey])
            return true
        case "view_plan", "create_plan":
            openDestination(ClubCoachAction(type: "plans", date: dateKey))
            return true
        case "view_records":
            openDestination(ClubCoachAction(type: "training", date: dateKey))
            return true
        default:
            return false
        }
    }
}


/// This card confirms a server-owned profile proposal, never a model-authored write.
private struct AIProfileChangeCard: View {
    let card: AICardEnvelope
    let enabled: Bool
    @EnvironmentObject private var account: AccountService
    @EnvironmentObject private var store: AppStore
    @State private var busy = false
    @State private var saved = false
    @State private var closed = false
    @State private var error: String?
    @State private var showPlan = false
    private var fields: [String: JSONValue] { if case .object(let v)=card.payload { return v };return [:] }
    private var proposalID: String? { fields["proposal_id"]?.string }
    private var start: Date { fields["plan_start_date"]?.string.flatMap(ClubDates.date(fromKey:)) ?? (ClubDates.calendar.date(byAdding:.day,value:1,to:Date()) ?? Date()) }
    var body: some View {
        VStack(alignment:.leading,spacing: BojiLayout.rowGap) {
            if case .array(let changes)?=fields["changes"] {
                ForEach(Array(changes.enumerated()),id: \.offset) { _,row in
                    if case .object(let c)=row,let key=c["field"]?.string {
                        let previous: String = {
                            if case .object(let before)?=fields["before"],case .object(let fact)?=before[key] { return fact["value"]?.displayText ?? "未填写" }
                            return "未填写"
                        }()
                        Text("\(OnboardingFieldSpec.from(apiKey:key)?.title ?? key)：\(previous) → \(c["value"]?.displayText ?? "待核对")").bojiType(.secondary)
                    }
                }
            }
            Text(closed ? "这份提案已结束。资料与计划未因此改变。" : saved ? "资料已更新。未来计划尚未改变。" : "确认后更新资料；日历安排需要另行预览确认。").bojiType(.label).foregroundStyle(.secondary)
            if let error { Text(error).bojiType(.label).foregroundStyle(.red) }
            Button(busy ? "正在核对…" : closed ? "提案已结束" : saved ? "资料已确认" : "确认更新资料") { Task { await confirm() } }
                .buttonStyle(PrimaryButton()).disabled(!enabled || busy || saved || closed || proposalID == nil)
            if !saved && !closed { Button("暂不保存") { Task { await dismiss() } }.buttonStyle(SecondaryButton()).disabled(busy || !enabled) }
            if saved { Button("预览未来计划") { showPlan = true }.buttonStyle(SecondaryButton()) }
        }
        .task { await refreshStatus() }
        .sheet(isPresented:$showPlan) { NavigationStack { PlanView(date:start,initialMode:"generate_plan") } }
    }
    private func refreshStatus() async {
        guard let id=proposalID,let uid=account.user?.id else { return }
        guard let response=try? await account.cloudRequest(path:"/me/profile-facts/proposals/\(id)",expectedUserID:uid),response.statusCode==200,
              let p=try? JSONSerialization.jsonObject(with:response.data) as? [String:Any] else { return }
        saved = p["status"] as? String == "committed"
        closed = ["dismissed","expired","cancelled"].contains(p["status"] as? String ?? "")
    }
    @MainActor private func dismiss() async {
        guard let id=proposalID,let uid=account.user?.id else { return }
        busy=true;error=nil;defer { busy=false }
        do {
            _ = try await OnboardingMutationRecovery.perform(account:account,path:"/me/profile-facts/dismiss",method:"POST",body:["proposal_id":id],owner:uid)
            guard account.user?.id==uid else { return };closed=true
        } catch { self.error=AppErrorText.message(error) }
    }
    @MainActor private func confirm() async {
        guard let id=proposalID,let uid=account.user?.id,let revision=fields["profile_revision"]?.numberValue else { return }
        busy=true;error=nil;defer { busy=false }
        do {
            var body: [String:Any]=["proposal_id":id,"expected_profile_revision":Int(revision)]
            var path="/me/profile-facts/confirm"
            if let sid=fields["session_id"]?.string,let sessionRevision=fields["session_revision"]?.numberValue {
                path="/me/onboarding/v2/sessions/\(sid)/profile-confirm";body["expected_session_revision"]=Int(sessionRevision)
            }
            let data=try await OnboardingMutationRecovery.perform(account:account,path:path,method:"POST",body:body,owner:uid)
            let response = AccountRawResponse(statusCode:200,data:data)
            guard response.statusCode==200 else { let value=(try? JSONSerialization.jsonObject(with:response.data)) as? [String:Any];throw OnboardingAPIError(message:value?["error"] as? String ?? "资料尚未保存，请重新核对。",status:response.statusCode) }
            let receipt=try JSONDecoder().decode(OnboardingConfirmResponse.self,from:response.data)
            guard receipt.status=="committed" else { throw OnboardingAPIError(message:"资料尚未确认。",status:409) }
            let factsResponse=try await account.cloudRequest(path:"/me/profile-facts",expectedUserID:uid)
            let facts=try JSONDecoder().decode(ProfileFactsDocument.self,from:factsResponse.data)
            guard account.user?.id==uid,store.editingAccountID==uid else { return }
            store.applyV2ProfileFacts(facts.facts.mapValues(\.value),meta:facts.facts.mapValues { ProfileFactMeta(sourceKind:$0.sourceKind ?? "confirmed",confirmedAt:nil,revision:nil) })
            saved=true
        } catch { self.error=AppErrorText.message(error) }
    }
}


struct AIProfileProposalView: View {
    let proposalID: String
    @EnvironmentObject private var account: AccountService
    @State private var card: AICardEnvelope?
    @State private var error: String?
    var body: some View {
        ScrollView { VStack(alignment:.leading,spacing: BojiLayout.cardInset) {
            if let card { AICardView(card:card,onAction:{_ in}) }
            else if let error { Text(error).foregroundStyle(.red) }
            else { ProgressView("正在核对资料提案…") }
        }.padding() }.navigationTitle("核对资料变更").task { await load() }
    }
    private func load() async {
        guard let uid=account.user?.id else { return }
        do {
            let response=try await account.cloudRequest(path:"/me/profile-facts/proposals/\(proposalID)",expectedUserID:uid)
            guard response.statusCode==200 else { throw OnboardingAPIError(message:"提案无法读取或已失效。",status:response.statusCode) }
            let payload=try JSONDecoder().decode(JSONValue.self,from:response.data)
            let fields: [String:JSONValue];if case .object(let values)=payload { fields=values } else { fields=[:] }
            card=AICardEnvelope(card_id:"profile-"+proposalID,card_type:"profile_change",schema_version:1,title:"资料变更",payload:payload,actions:[],evidence_refs:[],created_at:nil,expires_at:fields["expires_at"]?.string)
        } catch { self.error=AppErrorText.message(error) }
    }
}

struct AIMemoryDraftCard: View {
    let card: AICardEnvelope
    let enabled: Bool
    @EnvironmentObject private var ai: AIService
    @State private var busy = false
    @State private var saved = false
    @State private var dismissed = false
    @State private var error: String?

    private var content: String {
        if case .object(let obj) = card.payload, let c = obj["content"]?.string {
            return c
        }
        return card.title
    }

    private var kind: String {
        if case .object(let obj) = card.payload, let k = obj["kind"]?.string {
            return k
        }
        return "preference"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BojiLayout.rowGap) {
            HStack(spacing: BojiLayout.inline) {
                Image(systemName: "sparkles")
                    .bojiType(.secondary)
                    .foregroundStyle(BojiColor.aiGold)
                Text("记忆提议").bojiType(.secondary).foregroundStyle(BojiColor.textPrimary)
            }
            Text("“\(content)”")
                .bojiType(.body)
                .foregroundStyle(BojiColor.textPrimary)
                
            Text(saved ? "已存入长期记忆，AI 后续对话与排课将遵循此偏好。" : dismissed ? "已忽略此条记忆。" : "确认后将存入你的“AI 记住的内容”，后续排课与建议将自动考虑。")
                .bojiType(.label)
                .foregroundStyle(BojiColor.textSecondary)

            if !saved && !dismissed {
                HStack(spacing: BojiLayout.rowGap) {
                    Button(busy ? "正在保存…" : "存入档案") {
                        Task {
                            busy = true; error = nil
                            let ok = await ai.createMemory(content: content, kind: kind)
                            busy = false
                            if ok {
                                BojiHaptics.success()
                                saved = true
                            } else {
                                error = "未能保存，请稍后重试"
                            }
                        }
                    }
                    .buttonStyle(PrimaryButton())
                    .disabled(busy || !enabled)

                    Button("忽略") {
                        BojiHaptics.light()
                        dismissed = true
                    }
                    .buttonStyle(SecondaryButton())
                    .disabled(busy)
                }
            }
            if let error {
                Text(error).bojiType(.caption).foregroundStyle(.red)
            }
        }
        .padding(BojiLayout.rowGap)
        .background(BojiColor.subtleSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
