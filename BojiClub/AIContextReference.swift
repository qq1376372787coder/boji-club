import SwiftUI
import CryptoKit

struct AIContextReference: Codable, Equatable, Identifiable {
    var kind: String
    var resourceID: String = ""
    var from: String
    var to: String
    var title: String
    var sourceVersion: String? = nil
    var snapshot: JSONValue? = nil
    var localVersion: String? = nil
    var id: String { kind + "/" + resourceID + "/" + from + "/" + to }
    var wire: JSONValue {
        var fields: [String: JSONValue] = ["kind": .string(kind), "resource_id": .string(resourceID), "from": .string(from), "to": .string(to)]
        if let sourceVersion { fields["source_version"] = .string(sourceVersion) }
        return .object(fields)
    }
    func localFingerprint(_ state: SavedState) -> String {
        var selected: [String: JSONValue] = [:]
        for (date, day) in state.days where date >= from && date <= to {
            if kind.hasPrefix("body_") {
                selected[date] = .object(["latest": (try? .encode(day.bodyWeight)) ?? .null, "measurements": (try? .encode(day.bodyMeasurements)) ?? .null, "deleted": (try? .encode(day.deletedBodyMeasurementIDs)) ?? .null])
            } else if kind.hasPrefix("meal_") {
                selected[date] = (try? .encode(day.meals)) ?? .null
            } else if kind == "plan_version" {
                selected[date] = (try? .encode(day.planVersions)) ?? .null
            } else {
                selected[date] = .object(["exercises": (try? .encode(day.exercises)) ?? .null, "sessions": (try? .encode(day.workoutSessions)) ?? .null])
            }
        }
        if resourceID.hasPrefix("ai:") { selected["deleted_plans"] = (try? .encode(state.deletedAIJobIDs)) ?? .null }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(selected)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func day(_ kind: String, date: Date, title: String) -> Self {
        Self(kind: kind, from: ClubDates.key(date), to: ClubDates.key(date), title: title)
    }
}

struct AIContextBundle: Decodable {
    var bundleID: String
    struct Resolved: Decodable {
        var kind: String; var resourceID: String; var from: String; var to: String
        var label: String; var sourceVersion: String; var snapshot: JSONValue
        enum CodingKeys: String, CodingKey { case kind, from, to, label, snapshot; case resourceID = "resource_id", sourceVersion = "source_version" }
        var reference: AIContextReference { .init(kind: kind, resourceID: resourceID, from: from, to: to, title: label, sourceVersion: sourceVersion, snapshot: snapshot) }
    }
    var references: [Resolved]
    enum CodingKeys: String, CodingKey { case bundleID = "bundle_id", references }
    @MainActor static func resolve(_ refs: [AIContextReference], conversation: String, owner: Int, store: AppStore, account: AccountService, jobs: [AILocalJob] = []) async throws -> Self {
        guard account.user?.id == owner, store.editingAccountID == owner else { throw CancellationError() }
        var fields = try ReferenceSnapshot131.payload(references: refs, state: store.state, jobs: jobs).object ?? [:]
        fields["conversation_id"] = .string(conversation)
        let response = try await account.cloudRequest(path: "/me/ai/context/resolve", method: "POST", body: JSONEncoder().encode(JSONValue.object(fields)), expectedUserID: owner)
        guard account.user?.id == owner, store.editingAccountID == owner else { throw CancellationError() }
        guard response.statusCode == 200 else {
            let message = (try? JSONDecoder().decode([String: JSONValue].self, from: response.data))?["error"]?.string
            throw AIClientError.message(message ?? "引用暂时无法读取，问题已保留，可以重试。")
        }
        return try JSONDecoder().decode(Self.self, from: response.data)
    }
}

struct AIReferencePicker: View {
    @Binding var selection: [AIContextReference]
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var ai: AIService
    @Environment(\.dismiss) private var dismiss
    @State private var category = "训练记录"
    @State private var search = ""
    @State private var from = Date()
    @State private var to = Date()
    private let categories = ["身体数据", "训练记录", "饮食记录", "当天计划", "整套计划"]
    private var candidates: [AIContextReference] {
        var rows: [AIContextReference] = []
        for key in store.state.days.keys.sorted().reversed() {
            guard let log = store.state.days[key] else { continue }
            switch category {
            case "身体数据":
                if log.bodyWeight != nil || !(log.bodyMeasurements ?? []).isEmpty { rows.append(.init(kind: "body_range", from: key, to: key, title: key + " · 身体测量")) }
            case "饮食记录":
                if !log.meals.isEmpty { rows.append(.init(kind: "meal_day", from: key, to: key, title: key + " · \(log.meals.count)条饮食")) }
                rows += log.meals.map { .init(kind: "meal_entry", resourceID: $0.id.uuidString.lowercased(), from: key, to: key, title: key + " · " + $0.name) }
            case "训练记录":
                rows += (log.workoutSessions ?? []).filter { $0.cancelledAt == nil }.map { .init(kind: "workout_session", resourceID: $0.id.uuidString.lowercased(), from: key, to: key, title: key + ($0.savedAt == nil ? " · 进行中训练" : " · 已保存训练")) }
                if log.workoutSessions?.isEmpty != false && log.completedSets > 0 { rows.append(.init(kind: "workout_range", from: key, to: key, title: key + " · 训练记录")) }
            case "当天计划":
                if !log.exercises.isEmpty { rows.append(.init(kind: "plan_day", from: key, to: key, title: key + " · 当天计划")) }
            default:
                rows += (log.planVersions ?? []).map { .init(kind: "plan_version", resourceID: $0.id, from: key, to: key, title: $0.title + " · " + $0.start) }
            }
        }
        if category == "整套计划" {
            rows += ai.jobs.filter { ["generate_plan", "parse_plan"].contains($0.request.kind) && $0.status == "succeeded" && $0.replacementID == nil && !(store.state.deletedAIJobIDs ?? []).contains($0.id) }.map {
                .init(kind: "plan_version", resourceID: "ai:" + $0.id, from: $0.request.date, to: $0.request.date, title: $0.request.date + " · AI候选计划（未必已采用）")
            }
        }
        var seen = Set<String>()
        return rows.filter { seen.insert($0.id).inserted && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)) }
    }
    var body: some View {
        ClubNavigationStack132 {
            List {
                Section {
                    Picker("记录类型", selection: $category) { ForEach(categories, id: \.self) { Text($0).tag($0) } }
                    Text("引用仅用于讨论，修改记录仍需核对。最多选择5项。") .font(.footnote).foregroundStyle(.secondary)
                }
                if ["身体数据", "训练记录"].contains(category) {
                    Section("按日期范围") {
                        DatePicker("开始", selection: $from, in: ...Date(), displayedComponents: .date)
                        DatePicker("结束", selection: $to, in: ...Date(), displayedComponents: .date)
                        Button("引用这段记录") {
                            let a = min(from, to), b = max(from, to)
                            toggle(.init(kind: category == "身体数据" ? "body_range" : "workout_range", from: ClubDates.key(a), to: ClubDates.key(b), title: ClubDates.key(a) + " 至 " + ClubDates.key(b) + " · " + category))
                        }.disabled(abs(from.timeIntervalSince(to)) > 27 * 86400 || selection.count >= 5)
                    }
                }
                Section("选择记录 · \(selection.count)/5") {
                    if candidates.isEmpty { Text("暂无可引用记录，先记录饮食、训练或身体数据。") .foregroundStyle(.secondary) }
                    ForEach(candidates) { ref in
                        Button { toggle(ref) } label: {
                            HStack { Text(ref.title).foregroundStyle(.primary); Spacer(); if selection.contains(where: { $0.id == ref.id }) { Image(systemName: "checkmark.circle.fill") } }
                        }.disabled(selection.count >= 5 && !selection.contains(where: { $0.id == ref.id }))
                    }
                }
            }
            .searchable(text: $search, prompt: "搜索日期、计划或食物")
            .clubManagementList132().navigationTitle("引用记录").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }.tint(BojiColor.mistAccent)
    }
    private func toggle(_ ref: AIContextReference) {
        if selection.contains(where: { $0.id == ref.id }) { selection.removeAll { $0.id == ref.id } }
        else if selection.count < 5 { selection.append(ref) }
    }
}

struct AIReferenceSourceCard: View {
    let reference: AIContextReference
    @EnvironmentObject private var store: AppStore
    var body: some View {
        DisclosureGroup {
            if reference.snapshot != nil, reference.localVersion != reference.localFingerprint(store.state) {
                Text("来源已有变化或已撤回，请在输入框刷新引用后核对。") .font(.footnote).foregroundStyle(.secondary)
            } else if let rows = reference.snapshot?.array {
                if rows.contains(where: { $0.object?["source_tier131"]?.string == "local_snapshot" }) {
                    Text("本次使用本机记录副本，仅供分析。").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    if let fields = row.object {
                        Text(fields["date"]?.string ?? reference.from).font(.caption).foregroundStyle(.secondary)
                        ForEach(lines(fields), id: \.self) { Text($0).font(.footnote).frame(maxWidth: .infinity, alignment: .leading) }
                    }
                }
            } else { Text("发送时读取本机记录副本，无需等待整库同步。") .font(.footnote) }
        } label: { Label(reference.title, systemImage: "doc.text") }
    }
    private func lines(_ fields: [String: JSONValue]) -> [String] {
        var result: [String] = []
        for item in fields["measurements"]?.array ?? [] {
            guard let m = item.object else { continue }
            if case .number(let kg)? = m["kilograms"] { result.append(String(format: "体重 %.2f 公斤", kg)) }
            if case .number(let waist)? = m["waistCircumferenceCM"] { result.append(String(format: "腰围 %.1f 厘米", waist)) }
        }
        for item in fields["meals"]?.array ?? [] {
            let m = item.object ?? [:]; let name = m["name"]?.string ?? "饮食"
            if m["nutritionKnown"] == .bool(false) { result.append(name + " · 营养未知") }
            else if case .number(let kcal)? = m["calories"] { result.append(name + String(format: " · 已记录 %.0f 千卡", kcal)) }
            else { result.append(name) }
        }
        for item in fields["exercises"]?.array ?? [] {
            let e = item.object ?? [:]; result.append((e["name"]?.string ?? "动作") + " · \(e["sets"]?.array?.count ?? 0)组" + (fields["status"]?.string == "planned_targets_not_actual" ? "目标" : "实际登记"))
        }
        if let v = fields["plan_version"]?.object { result.append((v["title"]?.string ?? "计划") + " · \(v["sessions"]?.array?.count ?? 0)个训练日"); if v["status"]?.string == "draft" { result.append("计划草稿，尚未保存到日历") } }
        return result.isEmpty ? ["该范围没有对应的已登记数值。"] : result
    }
}

struct AIProviderConsentSheet: View {
    @EnvironmentObject private var ai: AIService
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("更新云端分析授权") .font(.headline)
                    Text("开启后，本次分析所需的记录、引用、主动发送的照片及已分享的健康汇总，会交给 DeepSeek 或 MiniMax 处理。两者均可能作为备用服务。录音不上传；不会自动保存或修改记录。")
                    Text("可以随时在隐私设置关闭。已经送达模型的任务无法从本机撤回。") .font(.footnote).foregroundStyle(.secondary)
                    Button("同意并继续") { ai.acceptRoutingConsent(); dismiss() }.buttonStyle(PrimaryButton())
                    Button("暂不启用") { dismiss() }
                }
            }.navigationTitle("云端分析说明").navigationBarTitleDisplayMode(.inline)
        }
    }
}

extension AccountService {
    @MainActor func syncAIConsentDecision(owner: Int) async throws {
        let pendingKey = CloudAnalysisConsent.key(accountID: owner) + ".pending-server"
        guard UserDefaults.standard.bool(forKey: pendingKey) else { return }
        let allowed = CloudAnalysisConsent.allowed(accountID: owner)
        let value = JSONValue.object(["allowed": .bool(allowed), "notice_version": .string("2026-10-26.deepseek-minimax-v1")])
        let response = try await cloudRequest(path: "/me/ai/consent", method: "POST", body: JSONEncoder().encode(value), expectedUserID: owner)
        guard response.statusCode == 200 else { throw AIClientError.message("云端分析授权尚未同步，请稍后重试。") }
        guard user?.id == owner, CloudAnalysisConsent.allowed(accountID: owner) == allowed else { return }
        UserDefaults.standard.removeObject(forKey: pendingKey)
    }
}
