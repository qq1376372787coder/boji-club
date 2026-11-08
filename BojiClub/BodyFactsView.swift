import SwiftUI
import CryptoKit

@MainActor
final class ProfileFactsEditor: ObservableObject {
    @Published private(set) var facts: ProfileFactsDocument?
    @Published private(set) var busy = false
    @Published var error: String?
    @Published private(set) var notice: String?
    private var loadedOwner: Int?
    @Published private(set) var receipt: String?

    func load(account: AccountService) async {
        guard let uid = account.user?.id, uid > 0, !account.isPreviewAccount else { facts = nil; loadedOwner = nil; return }
        if loadedOwner != uid { facts = nil; error = nil; loadedOwner = uid }
        await OnboardingMutationRecovery.replay(account:account,owner:uid)
        do {
            let response = try await account.cloudRequest(path: "/me/profile-facts", expectedUserID: uid)
            guard response.statusCode == 200 else { throw OnboardingAPIError(message: "资料暂不可用。", status: response.statusCode) }
            guard account.user?.id == uid, loadedOwner == uid, !Task.isCancelled else { return }
            facts = try JSONDecoder().decode(ProfileFactsDocument.self, from: response.data)
            error = nil
        } catch { if account.user?.id == uid { self.error = AppErrorText.message(error) } }
    }

    func apply(changes: [[String: Any]], account: AccountService) async -> Bool {
        guard let uid = account.user?.id, uid > 0, loadedOwner == uid, let revision = facts?.revision else { return false }
        busy = true; error = nil; notice = nil; receipt = nil
        defer { busy = false }
        do {
            let preview = try await post(account: account, path: "/me/profile-facts/preview",
                body: ["expected_profile_revision": revision, "changes": changes], expectedUserID: uid)
            let proposal = try JSONDecoder().decode(OnboardingProposal.self, from: preview)
            let confirmed = try await post(account: account, path: "/me/profile-facts/confirm",
                body: ["proposal_id": proposal.proposalID, "expected_profile_revision": proposal.profileRevision], expectedUserID: uid)
            guard account.user?.id == uid, loadedOwner == uid, !Task.isCancelled else { return false }
            let decoded = try JSONDecoder().decode(OnboardingConfirmResponse.self, from: confirmed)
            receipt = decoded.receipt?.commandID
            guard decoded.status == "committed" else { return false }
            if let profile = decoded.profile { facts = profile }
            else { await load(account: account) }
            guard account.user?.id == uid, loadedOwner == uid else { return false }
            notice = "资料已保存。"
            NotificationCenter.default.post(name:.profileFactsChanged133,object:uid)
            return true
        } catch {
            if let conflict=error as? OnboardingAPIError,conflict.status==409 {
                await load(account:account)
                self.error="资料已更新，你的填写仍保留。请核对后再保存。"
            } else { self.error=AppErrorText.message(error) }
            return false
        }
    }

    func applyFacts(to store: AppStore) {
        guard let document=facts else { return }
        store.applyV2ProfileFacts(document.facts.mapValues(\.value), meta:document.facts.mapValues { ProfileFactMeta(sourceKind:$0.sourceKind ?? "legacy_recorded",confirmedAt:nil,revision:document.revision) })
    }

    func clear(field: String, account: AccountService) async -> Bool {
        guard let uid = account.user?.id, uid > 0, loadedOwner == uid, let revision = facts?.revision else { return false }
        busy = true; error = nil; notice = nil
        defer { busy = false }
        do {
            _ = try await post(account: account, path: "/me/profile-facts/clear",
                body: ["field": field, "expected_profile_revision": revision], expectedUserID: uid)
            notice = "这项资料已清空，训练、饮食和测量记录保留。"
            await load(account: account)
            NotificationCenter.default.post(name:.profileFactsChanged133,object:uid)
            return true
        } catch { self.error = AppErrorText.message(error); return false }
    }

    private func post(account: AccountService, path: String, body: [String: Any], expectedUserID: Int) async throws -> Data {
        return try await OnboardingMutationRecovery.perform(account:account,path:path,method:"POST",body:body,owner:expectedUserID)
    }
}

/// One explicit place to distinguish profile weight, a measurement and a goal.
struct BodyFactIntakeView: View {
    var initialDate: Date = Date()
    @EnvironmentObject private var account: AccountService
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var health: HealthDataService
    @Environment(\.dismiss) private var dismiss
    @StateObject private var editor = ProfileFactsEditor()
    @State private var kilograms = ""
    @State private var target = ""
    @State private var selectedDate = Date()
    @State private var nature = "measured"
    @State private var updateProfile = false
    @State private var saveMeasurement = false
    @State private var updateTarget = false
    @State private var busy = false
    @State private var measurementResult: String?
    @State private var profileResult: String?
    @State private var targetResult: String?
    @State private var error: String?

    private var value: Double? { Double(kilograms.replacingOccurrences(of: ",", with: ".")) }
    private var targetValue: Double? { Double(target.replacingOccurrences(of: ",", with: ".")) }

    var body: some View {
        ClubNavigationStack132 {
            Form {
                Section {
                    Text("资料体重、称重记录和目标体重分别保存。修改一项不会改动另外两项。")
                        .bojiType(.label)
                    DatePicker("日期", selection: $selectedDate, in: ...Date(), displayedComponents: .date)
                    LabeledContent("体重") {
                        HStack(spacing: BojiLayout.tight) {
                            TextField("0.0", text: $kilograms).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                            Text("kg").foregroundStyle(.secondary)
                        }
                    }
                    Picker("这个数字是", selection: $nature) {
                        Text("实际测量").tag("measured")
                        Text("估计/回忆").tag("estimated")
                    }.clubAdaptivePicker()
                }
                Section("明确选择要保存到哪里") {
                    Toggle("登记为一次实测记录", isOn: $saveMeasurement)
                        .disabled(nature != "measured")
                    Toggle("更新档案资料体重", isOn: $updateProfile)
                    Toggle("设为目标体重", isOn: $updateTarget)
                    if nature == "estimated" {
                        Text("估计体重只用于资料，不会加入称重记录。")
                            .bojiType(.label).foregroundStyle(.secondary)
                    }
                    if updateTarget {
                        LabeledContent("目标体重") {
                            HStack(spacing: BojiLayout.tight) {
                                TextField("0.0", text: $target).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                                Text("kg").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if let measurementResult { Text(measurementResult).bojiType(.label) }
                if let profileResult { Text(profileResult).bojiType(.label) }
                if let targetResult { Text(targetResult).bojiType(.label) }
                if let error { Text(error).bojiType(.label).foregroundStyle(.red) }
                if let notice = editor.notice { Text(notice).bojiType(.label).foregroundStyle(.secondary) }
                if let receipt = editor.receipt { Text("保存编号：" + receipt).bojiType(.caption).foregroundStyle(.secondary) }
                Section {
                    Text("保存结果分别显示。即使资料更新失败，已保存的实测记录也不会回滚；反之亦然。")
                        .bojiType(.label).foregroundStyle(.secondary)
                }
            }.clubManagementList132()
            .navigationTitle("身体数字")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(busy ? "保存中…" : "保存") { Task { await save() } }.disabled(busy) }
            }
            .task {
                selectedDate = ClubDates.isFuture(initialDate) ? Date() : initialDate
                await editor.load(account: account)
                if let f = editor.facts?.facts["profile_weight_kg"]?.value.numberValue { kilograms = String(format: "%.1f", f) }
                if let t = editor.facts?.facts["target_weight_kg"]?.value.numberValue { target = String(format: "%.1f", t) }
            }
            .onChange(of: nature) { _, value in if value == "estimated" { saveMeasurement = false } }
        }
    }

    private func save() async {
        guard let kg = value, (20...400).contains(kg) else { error = "请填写 20–400 kg 的体重。"; return }
        guard updateProfile || saveMeasurement || updateTarget else { error = "请至少明确选择一项要保存的位置。"; return }
        busy = true; error = nil
        defer { busy = false }
        measurementResult = nil; profileResult = nil; targetResult = nil
        var changes: [[String: Any]] = []
        let dateKey = ClubDates.key(selectedDate)
        if saveMeasurement {
            let ok = store.saveBodyMeasurements(kilograms: kg, bodyFatPercentage: nil, waistCircumferenceCM: nil,
                                                on: selectedDate, measurementID: nil, measuredAt: selectedDate)
            if ok, let entry = store.log(for: selectedDate).bodyWeight {
                Task { await health.writeWeight(entry) }
                measurementResult = health.enabled
                    ? "实测记录已保存（\(dateKey)），并请求写入 Apple 健康。"
                    : "实测记录已保存在本机（\(dateKey)）；Apple 健康未授权，可稍后在身体页按需开启。"
            } else {
                measurementResult = "实测记录未保存：\(store.takeMessage(fallback: "请核对日期后重试。"))"
            }
        }
        if updateProfile {
            changes.append(["field": "profile_weight_kg", "value": kg, "unit": "kg",
                            "measurement_kind": nature, "observed_at": dateKey])
        }
        if updateTarget {
            guard let targetValue, (20...400).contains(targetValue) else { error = "请填写 20–400 kg 的目标体重。"; return }
            changes.append(["field": "target_weight_kg", "value": targetValue, "unit": "kg"])
        }
        if !changes.isEmpty {
            let ok = await editor.apply(changes: changes, account: account)
            let label = ok ? "资料已更新" : "资料更新未完成：\(editor.error ?? "请重试")"
            if updateProfile { profileResult = label }
            if updateTarget { targetResult = label }
            if ok {
                if let document = editor.facts {
                    store.applyV2ProfileFacts(document.facts.mapValues(\.value),
                        meta: document.facts.mapValues { ProfileFactMeta(sourceKind: $0.sourceKind ?? "confirmed", confirmedAt: nil, revision: nil) })
                }
            }
        }
        if error == nil, measurementResult?.contains("已保存") == true || profileResult?.contains("已更新") == true || targetResult?.contains("已更新") == true {
            notice()
        }
    }

    private func notice() {
        error = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { dismiss() }
    }
}


struct ProfileFactEditTarget: Identifiable {
    let field: OnboardingFieldSpec
    let value: JSONValue?
    let revision: Int
    var id: String { field.apiKey }
}

struct ProfileFactEditView: View {
    let target: ProfileFactEditTarget
    @ObservedObject var editor: ProfileFactsEditor
    let account: AccountService
    let onSaved: () -> Void
    var body: some View {
        ProfileFactsForm133(title: target.field.title, fields: [target.field], onSaved: onSaved)
    }
}

// One manual-input contract for onboarding and “AI 对我的了解”. Only profile-facts
// preview/confirm writes confirmed information; a form draft is never AI context.
enum ProfileFields133 {
    static let basics: [OnboardingFieldSpec] = [.nickname, .heightCm, .profileWeightKg]
    static let body: [OnboardingFieldSpec] = basics + [.targetWeightKg]
    static let training: [OnboardingFieldSpec] = [.goal, .experience, .venue, .trainingDays, .sessionMinutes, .ageGroup, .equipment, .equipmentOther, .homeTrainingDays, .equipmentExclusions, .focus, .limitations]
    static let preferences: [OnboardingFieldSpec] = [.personalPreferences, .dailyActivity, .nutritionContext]
    static func task(_ task: OnboardingTaskKind?) -> [OnboardingFieldSpec] {
        if task == .explore { return [] }
        return task == .nutritionGoal ? [.sexForNutrition, .ageYears, .heightCm, .profileWeightKg, .dailyActivity, .nutritionContext] : training
    }
}

struct ProfileFactInputs133: Codable, Equatable {
    var text: [String: String] = [:]
    var selected: [String: Set<String>] = [:]
    mutating func set(_ value: JSONValue, field: OnboardingFieldSpec) {
        text[field.apiKey] = value.string ?? value.displayText
        guard case .multiChoice = field.kind else { return }
        if field == .trainingDays || field == .homeTrainingDays {
            selected[field.apiKey] = Set((value.arrayValue ?? []).compactMap(\.intValue).filter { (1...7).contains($0) }.map { "周" + ["一","二","三","四","五","六","日"][$0-1] })
        } else if let rows = value.arrayValue { selected[field.apiKey] = Set(rows.compactMap(\.string)) }
        else { selected[field.apiKey] = Set((value.string ?? "").split(separator: "、").map(String.init)) }
    }
    func value(_ field: OnboardingFieldSpec) throws -> JSONValue? {
        let raw = (text[field.apiKey] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch field.kind {
        case .multiChoice(let choices):
            let chosen = choices.filter { selected[field.apiKey, default: []].contains($0) }
            guard !chosen.isEmpty else { return nil }
            if field == .trainingDays || field == .homeTrainingDays {
                return .array(chosen.compactMap { ["周一","周二","周三","周四","周五","周六","周日"].firstIndex(of: $0).map { .number(Double($0+1)) } })
            }
            return field == .focus ? .string(chosen.joined(separator: "、")) : .array(chosen.map(JSONValue.string))
        case .choice(let choices):
            guard !raw.isEmpty else { return nil }
            guard choices.contains(raw) else { throw issue(field, "请选择一项。") }
            return .string(raw)
        case .integer(let range):
            guard !raw.isEmpty else { return nil }
            guard let n = Int(raw), range.contains(n) else { throw issue(field, "请填写 \(range.lowerBound)–\(range.upperBound) 之间的整数。") }
            return .number(Double(n))
        case .decimal(let range):
            guard !raw.isEmpty else { return nil }
            guard let n = Double(raw.replacingOccurrences(of: ",", with: ".")), n.isFinite, range.contains(n) else { throw issue(field, "请核对数值（\(range.lowerBound)–\(range.upperBound)）。") }
            return .number(n)
        case .text(let limit):
            guard !raw.isEmpty else { return nil }
            guard raw.count <= limit else { throw issue(field, "最多填写 \(limit) 字。") }
            return .string(raw)
        case .date:
            guard !raw.isEmpty else { return nil }
            guard ClubDates.date(fromKey: raw) != nil else { throw issue(field, "请核对日期。") }
            return .string(raw)
        }
    }
    private func issue(_ field: OnboardingFieldSpec, _ message: String) -> OnboardingAPIError {
        OnboardingAPIError(message: field.title + "：" + message, status: 422)
    }
    func changes(fields: [OnboardingFieldSpec], facts: [String: OnboardingFactSummary]) throws -> [[String: Any]] {
        var changes: [[String: Any]] = []
        for field in fields {
            guard let value = try value(field) else {
                if facts[field.apiKey] != nil { throw issue(field,"已有资料不能直接留空；填写新值，或在资料详情中选择清空。") }
                continue
            }
            guard value != facts[field.apiKey]?.value else { continue }
            changes.append(["field":field.apiKey,"value":value.anyValue,"unit":field.unit ?? NSNull()])
            if field == .trainingDays, let rows = value.arrayValue {
                changes.append(["field":"days_per_week","value":rows.count,"unit":"days_per_week"])
                if let home = facts["home_training_days"]?.value.arrayValue {
                    let allowed = Set(rows.compactMap(\.intValue))
                    changes.append(["field":"home_training_days","value":home.compactMap(\.intValue).filter { allowed.contains($0) },"unit":NSNull()])
                }
            }
            if field == .ageYears, let age = value.intValue, !fields.contains(.ageGroup) {
                changes.append(["field":"age_group","value":age < 18 ? "minor":"adult","unit":NSNull()])
            }
        }
        if fields.contains(.homeTrainingDays), let home = try value(.homeTrainingDays)?.arrayValue {
            let allowed = Set((try value(.trainingDays) ?? facts["training_days"]?.value)?.arrayValue?.compactMap(\.intValue) ?? [])
            guard Set(home.compactMap(\.intValue)).isSubset(of: allowed) else { throw issue(.homeTrainingDays, "请选择可训练日期中的日期。") }
        }
        // A group edit can derive the same field twice. Preserve the last explicit value.
        var seen: Set<String> = []
        return Array(changes.reversed().filter { seen.insert($0["field"] as? String ?? "").inserted }.reversed())
    }
}

struct ProfileFormDraft133: Codable {
    var input: ProfileFactInputs133
    var baseline: ProfileFactInputs133
    var measurementDate: Date? = nil
    static func url(_ owner: Int) -> URL { OnboardingDraftStore.defaultDirectory().appendingPathComponent("profile-form133-\(owner).json") }
    static func load(_ owner: Int) -> Self? { (try? Data(contentsOf: url(owner))).flatMap { try? JSONDecoder().decode(Self.self, from: $0) } }
    func save(_ owner: Int) {
        guard owner > 0, let data = try? JSONEncoder().encode(self) else { return }
        let path = Self.url(owner)
        try? FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions:0o700])
        try? data.write(to:path,options:[.atomic,.completeFileProtection])
        try? FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:path.path)
        var file=path;var flags=URLResourceValues();flags.isExcludedFromBackup=true;try? file.setResourceValues(flags)
    }
    static func erase(_ owner: Int) { try? FileManager.default.removeItem(at:url(owner)) }
}

struct ProfileFactsForm133: View {
    let title: String
    let fields: [OnboardingFieldSpec]
    var onboardingBasics = false
    var suggestions: [String: JSONValue] = [:]
    var initialMeasurementDate: Date? = nil
    var onSaved: () -> Void = {}
    @EnvironmentObject private var account: AccountService
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var editor = ProfileFactsEditor()
    @State private var input = ProfileFactInputs133()
    @State private var baseline = ProfileFactInputs133()
    @State private var owner: Int?
    @State private var loaded = false
    @State private var saving = false
    @State private var error: String?
    @FocusState private var focused: String?
    private let advanced133: Set<OnboardingFieldSpec> = [.equipmentOther,.homeTrainingDays,.equipmentExclusions,.focus]
    private var shownFields: [OnboardingFieldSpec] {
        guard loaded else { return [] }
        return fields.filter { field in
            if field == .ageGroup, !(input.text["age_years"] ?? "").isEmpty { return false }
            if [.equipment,.equipmentOther,.homeTrainingDays].contains(field), input.text["venue"] == "健身房" { return false }
            return true
        }
    }
    var body: some View {
        ClubNavigationStack132 {
            Form {
                if !loaded { Section { ProgressView("正在读取资料…") } }
                ForEach(shownFields.filter { !advanced133.contains($0) }, id:\.self) { field in
                    Section { control(field) } header: { Text(field.title) }
                }
                if shownFields.contains(where:{ advanced133.contains($0) }) {
                    Section { DisclosureGroup("更多偏好（选填）") {
                        ForEach(shownFields.filter { advanced133.contains($0) },id:\.self) { field in
                            VStack(alignment:.leading,spacing: BojiLayout.inline) { Text(field.title).bojiType(.secondary);control(field) }.padding(.vertical, BojiLayout.tight)
                        }
                    } }
                }
                if let message=error ?? editor.error { Section { Text(message).foregroundStyle(.red); if editor.facts == nil { Button("重新读取") { Task { await load() } } } }.accessibilityIdentifier("profile-form-error133") }
                Section {
                    Button(saving ? "保存中…" : onboardingBasics ? "保存并继续" : "保存资料") { Task { await save() } }
                        .disabled(!loaded || saving || (editor.facts == nil && !account.isPreviewAccount))
                        .accessibilityIdentifier("profile-form-save133")
                    if onboardingBasics { Button("稍后填写") { Task { guard !saving else { return };await finishBasic(skipped:true) } }.disabled(!loaded || saving) }
                }
            }.clubManagementList132().scrollDismissesKeyboard(.interactively).disabled(saving || !loaded)
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !onboardingBasics { ToolbarItem(placement:.cancellationAction) { Button("关闭") { dismiss() }.disabled(saving) } }
                ToolbarItemGroup(placement:.keyboard) { Spacer();Button("完成") { focused=nil } }
            }
            .task(id:account.user?.id) { await load() }
            .onChange(of:input) { _,_ in persist() }
            .onChange(of:scenePhase) { _,phase in if phase != .active { persist() } }
            .onChange(of:account.user?.id) { _,value in if value != owner { dismiss() } }
            .onDisappear { persist() }
            .interactiveDismissDisabled(saving)
        }
    }
    @ViewBuilder private func control(_ field: OnboardingFieldSpec) -> some View {
        switch field.kind {
        case .choice(let choices):
            Picker(field.title,selection:text(field)) { Text("未填写").tag("");ForEach(choices,id:\.self) { Text(field.choiceLabel($0)).tag($0) } }
                .accessibilityIdentifier("profile-input-"+field.apiKey)
        case .multiChoice(let choices):
            ForEach(choices,id:\.self) { choice in
                Toggle(field.choiceLabel(choice),isOn:Binding(get:{ input.selected[field.apiKey,default:[]].contains(choice) },set:{ on in
                    if on { input.selected[field.apiKey,default:[]].insert(choice) } else { input.selected[field.apiKey,default:[]].remove(choice) }
                })).accessibilityIdentifier("profile-choice-"+field.apiKey+"-"+choice)
            }
            if field == .trainingDays { Text("每周 \(input.selected[field.apiKey,default:[]].count) 次，按选择的日期安排。资料保存前可继续多选。") .bojiType(.label).foregroundStyle(.secondary) }
        case .integer, .decimal:
            HStack { TextField("可留空",text:text(field)).keyboardType(field.kind.isDecimal133 ? .decimalPad:.numberPad).focused($focused,equals:field.apiKey).accessibilityIdentifier("profile-input-"+field.apiKey); if let unit=field.displayUnit133 { Text(unit).foregroundStyle(.secondary) } }
        case .text:
            TextField("可留空",text:text(field),axis:.vertical).lineLimit(1...4).focused($focused,equals:field.apiKey).accessibilityIdentifier("profile-input-"+field.apiKey)
        case .date:
            DatePicker(field.title,selection:Binding(get:{ ClubDates.date(fromKey:input.text[field.apiKey] ?? "") ?? Date() },set:{ input.text[field.apiKey]=ClubDates.key($0) }),in:...Date(),displayedComponents:.date)
        }
    }
    private func text(_ field:OnboardingFieldSpec)->Binding<String> { Binding(get:{ input.text[field.apiKey] ?? "" },set:{ input.text[field.apiKey]=$0 }) }
    private func persist() { guard loaded,let owner,owner == account.user?.id,!account.isPreviewAccount else { return };ProfileFormDraft133(input:input,baseline:baseline,measurementDate:nil).save(owner) }
    private func load() async {
        guard (!loaded || editor.facts == nil),let id=account.user?.id else { return };owner=id
        await editor.load(account:account)
        guard owner == account.user?.id else { return }
        let facts=editor.facts?.facts ?? [:]
        var fresh=ProfileFactInputs133()
        for field in OnboardingFieldSpec.allCases { if let value=facts[field.apiKey]?.value { fresh.set(value,field:field) } }
        baseline=fresh;input=fresh
        for field in fields { if let value=suggestions[field.apiKey],facts[field.apiKey] == nil { input.set(value,field:field) } }
        if let saved=ProfileFormDraft133.load(id) {
            for field in OnboardingFieldSpec.allCases {
                let key=field.apiKey
                if saved.input.text[key] != saved.baseline.text[key] { input.text[key]=saved.input.text[key] }
                if saved.input.selected[key] != saved.baseline.selected[key] { input.selected[key]=saved.input.selected[key] }
            }
        }
        loaded=true
    }
    private func save() async {
        guard !saving else { return }
        guard let owner,owner == account.user?.id else { return }
        guard owner == store.editingAccountID else { error="本机资料正在准备，请稍后再保存。";return }
        focused=nil;saving=true;error=nil;defer { saving=false }
        do {
            let edited=shownFields.filter { input.text[$0.apiKey] != baseline.text[$0.apiKey] || input.selected[$0.apiKey] != baseline.selected[$0.apiKey] }
            var changes=try input.changes(fields:edited,facts:editor.facts?.facts ?? [:])
            if fields.contains(.trainingDays),let days=try input.value(.trainingDays)?.arrayValue,!days.isEmpty,
               editor.facts?.facts["days_per_week"]?.value.intValue != days.count,!changes.contains(where:{ $0["field"] as? String == "days_per_week" }) {
                changes.append(["field":"days_per_week","value":days.count,"unit":"days_per_week"])
            }
            if !changes.isEmpty {
                if account.isPreviewAccount {
                    var facts:[String:JSONValue]=[:];for change in changes { if let key=change["field"] as? String { facts[key]=JSONValue.any(change["value"] ?? NSNull()) } }
                    // Preview edits are patches; preserve confirmation of fields saved in earlier forms.
                    var metadata = store.state.profile.factState ?? [:]
                    metadata.merge(facts.mapValues { _ in ProfileFactMeta(sourceKind:"confirmed",confirmedAt:nil,revision:nil) }) { _, updated in updated }
                    store.applyV2ProfileFacts(facts, meta: metadata)
                } else {
                    guard await editor.apply(changes:changes,account:account) else { return }
                    guard owner == account.user?.id,owner == store.editingAccountID else { return }
                    editor.applyFacts(to:store)
                }
            }
            if onboardingBasics {
                let hasBasicFact=ProfileFields133.basics.contains { editor.facts?.facts[$0.apiKey] != nil }
                await finishBasic(skipped:changes.isEmpty && !hasBasicFact)
            }
            else { markSaved();onSaved();dismiss() }
        } catch { self.error=AppErrorText.message(error) }
    }
    private func markSaved() {
        guard let owner else { return }
        for field in fields { baseline.text[field.apiKey]=input.text[field.apiKey];baseline.selected[field.apiKey]=input.selected[field.apiKey] }
        ProfileFormDraft133(input:input,baseline:baseline).save(owner)
    }
    private func finishBasic(skipped:Bool) async {
        guard let owner,owner == account.user?.id else { return }
        saving=true;defer { saving=false }
        do {
            if !account.isPreviewAccount { try await account.saveProfileIntake133(status:skipped ? "skipped":"completed") }
            if !skipped { markSaved() } else { persist() }
            UserDefaults.standard.set(true,forKey:"club.basic-profile123.\(owner)")
            onSaved()
        } catch { self.error=AppErrorText.message(error) }
    }
}

private extension OnboardingFieldKind { var isDecimal133:Bool { if case .decimal = self { return true };return false } }
extension OnboardingFieldSpec {
    var displayUnit133:String? { switch self { case .ageYears:return "岁";case .heightCm:return "cm";case .profileWeightKg,.targetWeightKg:return "kg";case .sessionMinutes:return "分钟";case .daysPerWeek:return "次/周";default:return nil } }
}

extension Notification.Name { static let profileFactsChanged133 = Notification.Name("boji.profile-facts133.changed") }


/// A separate account entrance, backed by the same forms and confirmed facts as AI knowledge.
/// This view owns navigation only; drafts, field definitions and writes stay in ProfileFactsForm133.
struct IndependentProfileOnboardingView: View {
    @EnvironmentObject private var account: AccountService
    @EnvironmentObject private var store: AppStore
    @StateObject private var editor = ProfileFactsEditor()
    @StateObject private var onboarding = OnboardingV2Model()
    @State private var editing: IntakeSection?
    @State private var loading = false
    @State private var completing = false
    @State private var error: String?

    private enum IntakeSection: String, Identifiable {
        case identity, goals
        var id: String { rawValue }
        var title: String {
            switch self { case .identity: return "你的称呼"; case .goals: return "健身目标" }
        }
        var fields: [OnboardingFieldSpec] {
            switch self {
            case .identity: return [.nickname]
            case .goals: return [.goal]
            }
        }
    }
    private var hasNickname: Bool { store.state.profile.isFactConfirmed("nickname") }
    private var hasGoal: Bool { store.state.profile.isFactConfirmed("goal") }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("先认识你").bojiType(.display)
                    Text("填写适合你的资料与目标。这里与你的“个人资料”共用一份档案，之后可以随时修改。")
                        .foregroundStyle(.secondary)
                }
                Section {
                    entry(.identity, summary: hasNickname ? store.state.profile.nickname : "点击填写你的昵称")
                    entry(.goals, summary: hasGoal ? store.state.profile.goal : "选择你的主要健身目标")
                } header: { Text("个人资料") } footer: {
                    Text("只需填写昵称和主要目标即可快速开始，其他信息后续在个人中心随时调整。")
                }
                Section {
                    if !hasNickname || !hasGoal {
                        Text("请先填写昵称和主要目标，再继续。其他信息可以在需要时补充。")
                            .foregroundStyle(.secondary)
                    }
                    if loading { ProgressView("正在读取已保存的资料…") }
                    if let message = error ?? editor.error {
                        Text(message).foregroundStyle(.red)
                        Button("重新读取资料") { Task { await refresh() } }
                    }
                    Button(completing ? "正在确认…" : "确认资料并继续") { Task { await finish() } }
                        .disabled(loading || completing || !hasNickname || !hasGoal || (!account.isPreviewAccount && editor.facts == nil))
                        .accessibilityIdentifier("independent-intake-continue")
                } header: { Text("确认资料") } footer: {
                    Text("确认后将核验会员状态，再进入 App。此步骤不会生成计划或自动开始训练。")
                }
            }
            .clubManagementList132()
            .navigationTitle("新用户设置").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { ClubLogoutButton() } }
        }
        .sheet(item: $editing, onDismiss: { Task { await refresh() } }) { section in
            ProfileFactsForm133(title: section.title, fields: section.fields)
        }
        .task(id: account.user?.id) { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .profileFactsChanged133)) { note in
            if note.object as? Int == account.user?.id { Task { await refresh() } }
        }
    }

    private func entry(_ section: IntakeSection, summary: String) -> some View {
        Button { editing = section } label: {
            HStack {
                VStack(alignment: .leading, spacing: BojiLayout.tight) {
                    Text(section.title).foregroundStyle(.primary)
                    Text(summary).bojiType(.label).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }.padding(.vertical, BojiLayout.tight)
        }
        .accessibilityIdentifier("independent-intake-" + section.rawValue)
        .disabled(completing)
    }

    @MainActor private func refresh() async {
        guard !loading else { return }
        let owner = account.user?.id
        loading = true; defer { loading = false }
        await editor.load(account: account)
        guard owner == account.user?.id, owner == store.editingAccountID else { return }
        editor.applyFacts(to: store)
    }

    @MainActor private func finish() async {
        guard !completing, hasNickname, hasGoal, let owner = account.user?.id else { return }
        completing = true; error = nil; defer { completing = false }
        do {
            try await account.completeOnboarding()
            await account.refreshAccount()
            if account.user?.onboardingCompleted == true {
                account.enterClub()
                return
            }
        } catch { }
        await onboarding.load(account: account)
        guard owner == account.user?.id else { return }
        if onboarding.taskKind != .explore && !onboarding.isCompleted {
            await onboarding.createSession(.explore, account: account)
        }
        guard owner == account.user?.id else { return }
        if await onboarding.completeSession(account: account, covenantVersion: "2026-10-25") {
            guard owner == account.user?.id else { return }
            account.enterClub()
        } else {
            error = onboarding.error ?? "资料已保存，请重试。"
        }
    }
}
