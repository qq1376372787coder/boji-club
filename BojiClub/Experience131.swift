import SwiftUI
import UIKit

struct ClubReferenceChips131: View {
    @Binding var references: [AIContextReference]
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(references) { reference in
                    HStack(spacing: 4) {
                        Image(systemName: "doc.text").font(.caption)
                        Text(reference.title).font(.subheadline).lineLimit(1).frame(maxWidth: 220)
                        Button { references.removeAll { $0.id == reference.id } } label: {
                            Image(systemName: "xmark").font(.caption.weight(.medium)).frame(width: 36, height: 44)
                        }.buttonStyle(.plain).accessibilityLabel("移除引用：" + reference.title)
                    }
                    .padding(.leading, 12).padding(.trailing, 2)
                    .foregroundStyle(BojiColor.textPrimary).background(BojiColor.brandMist, in: Capsule())
                    .accessibilityElement(children: .contain)
                }
            }.padding(.horizontal, 12)
        }.accessibilityIdentifier("composer-reference-chips131")
    }
}

@MainActor enum BojiInteraction131 {
    static func referenceAdded() { if UIApplication.shared.applicationState == .active { BojiHaptics.tick() } }
    static func received(owner: Int, message: String) { emit(owner: owner, key: "received/" + message) }
    private static func emit(owner: Int, key: String) {
        let storage = "boji.feedback131.\(owner)"
        var emitted = UserDefaults.standard.stringArray(forKey: storage) ?? []
        guard !emitted.contains(key) else { return }
        emitted.append(key); UserDefaults.standard.set(Array(emitted.suffix(150)), forKey: storage)
        if UIApplication.shared.applicationState == .active { BojiHaptics.tick() }
    }
    static func erase(owner: Int) {
        UserDefaults.standard.removeObject(forKey: "boji.feedback131.\(owner)")
        UserDefaults.standard.removeObject(forKey: "boji.pendingPlan135.\(owner)")
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix("boji.planIntake131.\(owner).") {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}

extension MemberProfile {
    var missingPlanFields131: [OnboardingFieldSpec] {
        if factState == nil { return canPrepareTrainingPlan ? [] : [.ageYears, .heightCm, .profileWeightKg] }
        var result: [OnboardingFieldSpec] = []
        for field in [OnboardingFieldSpec.goal, .experience, .venue, .trainingDays, .sessionMinutes] {
            if !isFactConfirmed(field.apiKey) { result.append(field) }
        }
        if ((trainingDays ?? []).isEmpty || daysPerWeek != trainingDays?.count), !result.contains(.trainingDays) { result.append(.trainingDays) }
        if venue == "在家", (!isFactConfirmed("equipment") || (equipment ?? "").isEmpty) { result.append(.equipment) }
        if !isFactConfirmed("age_group") && !isFactConfirmed("age_years") { result.append(.ageGroup) }
        return result
    }
}

struct PlanMissingConditions131: View {
    var onReady: () -> Void
    @EnvironmentObject private var account: AccountService
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var editor = ProfileFactsEditor()
    @State private var editing: ProfileFactEditTarget?
    @State private var owner: Int?
    @State private var loading = true
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(store.state.profile.canPrepareTrainingPlan ? "训练条件已齐全，可以制定计划。" : "补充以下项目即可制定计划，已有资料会保留。")
                    ForEach(store.state.profile.missingPlanFields131, id: \.self) { field in
                        Button {
                            guard let revision = editor.facts?.revision else { return }
                            editing = .init(field: field, value: editor.facts?.facts[field.apiKey]?.value, revision: revision)
                        } label: {
                            HStack { Text(field.title); Spacer(); Text("补充").foregroundStyle(.secondary); Image(systemName: "chevron.right").font(.caption) }
                        }.foregroundStyle(.primary).disabled(editor.facts == nil || editor.busy)
                    }
                }
                if let error = editor.error { Section { Text(error); Button("重新读取") { Task { await reload() } } } }
                if loading { ProgressView("正在读取资料…") }
            }
            .navigationTitle("补充训练条件").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("稍后") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("继续生成") { guard owner == store.editingAccountID else { return }; dismiss(); onReady() }
                        .disabled(loading || !store.state.profile.canPrepareTrainingPlan)
                }
            }
            .task { owner = store.editingAccountID; await reload() }
            .onChange(of: store.editingAccountID) { _, value in if value != owner { dismiss() } }
            .sheet(item: $editing) { target in
                ProfileFactEditView(target: target, editor: editor, account: account) { Task { await reload() } }
            }
        }
    }
    private func reload() async {
        loading = true; defer { loading = false }
        await editor.load(account: account)
        guard owner == store.editingAccountID, owner == account.user?.id, let document = editor.facts else { return }
        store.applyV2ProfileFacts(document.facts.mapValues(\.value), meta: document.facts.mapValues {
            ProfileFactMeta(sourceKind: $0.sourceKind ?? "legacy_recorded", confirmedAt: nil, revision: document.revision)
        })
    }
}

struct ClubProfileEntryLabel131: View {
    let title: String
    let symbol: String
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 19, weight: .regular)).frame(width: 28, height: 28)
            Text(title).font(.body)
            Spacer()
            Image(systemName: "chevron.right").font(.caption.weight(.medium)).foregroundStyle(.secondary)
        }.foregroundStyle(BojiColor.textPrimary).frame(minHeight: 48).contentShape(Rectangle())
    }
}

struct CoachRenderRow131: Identifiable { let id: String; let row: ClubCoachTimelineRow }

@MainActor enum ReferenceSnapshot131 {
    static func payload(references: [AIContextReference], state: SavedState, jobs: [AILocalJob]) throws -> JSONValue {
        guard !references.isEmpty, references.count <= 5 else { throw AIClientError.message("请选择 1–5 项记录。") }
        var days: [String: JSONValue] = [:]
        var selectedJobs: [String: JSONValue] = [:]
        let encoder = JSONEncoder()
        for reference in references {
            guard let start = ClubDates.date(fromKey: reference.from), let end = ClubDates.date(fromKey: reference.to),
                  let length = ClubDates.calendar.dateComponents([.day], from: start, to: end).day, (0...27).contains(length) else { throw AIClientError.message("每项引用最多选择 28 天。") }
            for offset in 0...length {
                guard let date = ClubDates.calendar.date(byAdding: .day, value: offset, to: start) else { continue }
                let key = ClubDates.key(date), day = state.days[key] ?? DayLog()
                var fields = days[key]?.object ?? ["exercises": .array([]), "meals": .array([])]
                let raw = try JSONDecoder().decode(JSONValue.self, from: encoder.encode(day)).object ?? [:]
                if reference.kind.hasPrefix("meal_") {
                    let meals = raw["meals"]?.array ?? []
                    fields["meals"] = .array(meals.map { value in .object((value.object ?? [:]).filter { ["id","name","category","calories","protein","carbs","fat","portion","nutritionKnown","estimated","consumedFraction"].contains($0.key) }) })
                } else if reference.kind.hasPrefix("body_") {
                    for field in ["bodyWeight","bodyMeasurements","deletedBodyMeasurementIDs"] { if let value = raw[field] { fields[field] = value } }
                    if let body = fields["bodyWeight"]?.object {
                        fields["bodyWeight"] = .object(body.filter { ["id","kilograms","updatedAt","recordedAt","bodyFatPercentage","waistCircumferenceCM","source"].contains($0.key) })
                    }
                } else {
                    for field in ["exercises","workoutSessions","planCycle","planVersions"] { if let value = raw[field] { fields[field] = value } }
                }
                days[key] = .object(fields)
            }
            if reference.kind == "plan_version", reference.resourceID.hasPrefix("ai:") {
                let id = String(reference.resourceID.dropFirst(3))
                guard let job = jobs.first(where: { $0.id.lowercased() == id.lowercased() }), job.status == "succeeded", job.result?.kind == "plan" else { throw AIClientError.message("这份计划已删除或尚未生成完成。") }
                selectedJobs[id.lowercased()] = .object(["status": .string("succeeded"), "result": .object(["kind": .string("plan"), "sessions": try .encode(job.result?.sessions ?? [])])])
            }
        }
        let refs = references.map { ref -> JSONValue in
            var fields = ref.wire.object ?? [:]; fields.removeValue(forKey: "source_version"); fields["label131"] = .string(ref.title)
            return .object(fields)
        }
        let result = JSONValue.object(["references": .array(refs), "local_records131": .object(days), "local_jobs131": .object(selectedJobs)])
        guard try encoder.encode(result).count <= 480000 else { throw AIClientError.message("引用内容较多，请少选几天或几条记录。") }
        return result
    }
}

/// Explicit plan creation in the conversation. No calendar write occurs until preview confirmation.
struct PlanConversationCard131: View {
    let conversation: String
    var onboardingSessionID: String? = nil
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var ai: AIService
    @EnvironmentObject private var account: AccountService
    @StateObject private var editor = ProfileFactsEditor()
    @State private var start = Date()
    @State private var jobID: String?
    @State private var error: String?
    @State private var showPreview = false
    @State private var owner: Int?
    @State private var input = ProfileFactInputs133()
    @State private var saving = false
    @State private var previewFacts: [String: JSONValue] = [:]
    private var storage: String { "boji.planIntake131.\(owner ?? 0).\(conversation)" }
    private var job: AILocalJob? { ai.job(jobID) }
    private var nextField: OnboardingFieldSpec? { store.state.profile.missingPlanFields131.first }
    var body: some View {
        ClubCard {
            Text("一起安排训练").font(.headline)
            if let job {
                if job.status == "succeeded" {
                    Text("计划准备好了，看看是否适合你。")
                    Button("查看计划") { showPreview = true }.buttonStyle(PrimaryButton())
                } else if !job.isTerminal {
                    ProgressView("正在制定计划…")
                    if job.isWaiting { Button("继续生成") { showPreview = true } }
                } else {
                    Text("这次没能生成计划。")
                    Button("重试") { submit() }
                }
            } else if let field = nextField {
                Text(question(field)).font(.body.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                fieldInput(field)
                if saving { ProgressView("正在保存…").font(.caption) }
            } else {
                Text("训练条件已准备好，先给你一份可以调整的计划。")
                    .font(.subheadline).foregroundStyle(.secondary)
                DatePicker("从哪天开始", selection: $start, in: Date()..., displayedComponents: .date)
                Button("生成训练计划") { submit() }.buttonStyle(PrimaryButton())
            }
            if let message = error ?? editor.error { Text(message).font(.footnote).foregroundStyle(.red); Button("重试读取资料") { Task { await reload() } }.font(.footnote) }
        }
        .task(id: conversation) {
            owner = store.editingAccountID
            jobID = UserDefaults.standard.string(forKey: storage)
            if jobID != nil, job == nil { jobID = nil }
            await reload()
        }
        .onChange(of: store.editingAccountID) { _, id in if id != owner { error = nil; input = ProfileFactInputs133() } }
        .sheet(isPresented: $showPreview) {
            if onboardingSessionID != nil {
                PlanView(date: start, initialJobID: jobID, onPlanApplied: {
                    if let owner, let jobID { NotificationCenter.default.post(name: .bojiPlanApplied135, object: nil, userInfo: ["owner": owner, "job": jobID]) }
                })
            } else { PlanView(date: start, initialJobID: jobID) }
        }
    }
    private func question(_ field: OnboardingFieldSpec) -> String {
        switch field {
        case .goal: return "你想通过训练达到什么目标？"
        case .experience: return "你之前有训练经验吗？"
        case .venue: return "你通常在哪里训练？"
        case .trainingDays: return "每周哪几天方便训练？"
        case .sessionMinutes: return "每次大约能练多久？"
        case .equipment: return "在家有哪些器械可以用？"
        case .ageGroup: return "你已满 18 岁吗？"
        default: return "先告诉我你的\(field.title)。"
        }
    }
    @ViewBuilder private func fieldInput(_ field: OnboardingFieldSpec) -> some View {
        switch field.kind {
        case .choice(let choices):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(choices, id: \.self) { value in
                    Button(field.choiceLabel(value)) { input.text[field.apiKey] = value; Task { await save(field) } }
                        .buttonStyle(.bordered).disabled(saving || (!account.isPreviewAccount && editor.facts == nil))
                }
            }
        case .multiChoice(let choices):
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), alignment: .leading)], alignment: .leading, spacing: 8) {
                ForEach(choices, id: \.self) { value in
                    Button {
                        var chosen = input.selected[field.apiKey, default: []]
                        if chosen.contains(value) { chosen.remove(value) } else { chosen.insert(value) }
                        input.selected[field.apiKey] = chosen
                        BojiHaptics.selection()
                    } label: {
                        Text(value).frame(minHeight: 36).frame(maxWidth: .infinity)
                            .background(input.selected[field.apiKey, default: []].contains(value) ? BojiColor.brandMist : BojiColor.subtleSurface, in: Capsule())
                    }.buttonStyle(.plain).disabled(saving)
                }
            }
            Button("继续") { Task { await save(field) } }.buttonStyle(PrimaryButton())
                .disabled(saving || input.selected[field.apiKey, default: []].isEmpty || (!account.isPreviewAccount && editor.facts == nil))
        default:
            HStack {
                TextField(field.title, text: Binding(get: { input.text[field.apiKey] ?? "" }, set: { input.text[field.apiKey] = $0 }))
                    .keyboardType(.numberPad).textFieldStyle(.roundedBorder)
                Text(field == .sessionMinutes ? "分钟" : field.displayUnit133 ?? "").foregroundStyle(.secondary)
                Button("继续") { Task { await save(field) } }.disabled(saving || (!account.isPreviewAccount && editor.facts == nil))
            }
        }
    }
    private func reload() async {
        guard let owner, owner == account.user?.id, owner == store.editingAccountID else { return }
        await editor.load(account: account)
        if owner == account.user?.id && owner == store.editingAccountID { editor.applyFacts(to: store) }
    }
    private func save(_ field: OnboardingFieldSpec) async {
        guard !saving, let owner, owner == account.user?.id, owner == store.editingAccountID else { return }
        saving = true; defer { saving = false }
        do {
            var changes = try input.changes(fields: [field], facts: editor.facts?.facts ?? [:])
            if field == .trainingDays, let days = try input.value(.trainingDays)?.arrayValue,
               !changes.contains(where: { $0["field"] as? String == "days_per_week" }),
               editor.facts?.facts["days_per_week"]?.value.intValue != days.count {
                changes.append(["field": "days_per_week", "value": days.count, "unit": "days_per_week"])
            }
            guard !changes.isEmpty else { error = "请选择一项再继续。"; return }
            if account.isPreviewAccount {
                for change in changes { if let key = change["field"] as? String { previewFacts[key] = JSONValue.any(change["value"] ?? NSNull()) } }
                store.applyV2ProfileFacts(previewFacts, meta: previewFacts.mapValues { _ in ProfileFactMeta(sourceKind: "confirmed", confirmedAt: nil, revision: nil) })
            } else {
                guard await editor.apply(changes: changes, account: account) else { return }
                guard owner == account.user?.id, owner == store.editingAccountID else { return }
                editor.applyFacts(to: store)
            }
            input = ProfileFactInputs133(); error = nil; BojiHaptics.selection()
        } catch { self.error = AppErrorText.message(error) }
    }
    private func submit() {
        guard owner != nil, owner == store.editingAccountID else { return }
        guard store.state.profile.canPrepareTrainingPlan else { return }
        do {
            let profile = store.state.profile.aiProfile
            var payload: [String: JSONValue] = ["profile": try .encode(profile), "plan_days": .number(7)]
            if profile.factState != nil {
                payload["profile"] = .object(profile.v2PlanProfile)
                payload["_v2_profile"] = .bool(true); payload["_v2_schema_version"] = .number(1)
                payload["timeZone"] = .string(TimeZone.current.identifier)
            }
            let input = AIInput(kind: "generate_plan", date: ClubDates.key(max(start, Date())), payload: payload)
            if account.user?.onboardingCompleted == false && !account.isPreviewAccount && onboardingSessionID == nil {
                error = "训练计划正在准备，请稍后再试。"; return
            }
            jobID = try ai.submit(input, forceNew: job?.isTerminal == true, onboardingSessionID: onboardingSessionID)
            UserDefaults.standard.set(jobID, forKey: storage); error = nil
        } catch { self.error = AppErrorText.message(error) }
    }
}

@MainActor enum BojiInstall131 {
    static var identifier: String {
        let key = "boji.install131"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = UUID().uuidString.lowercased(); UserDefaults.standard.set(id, forKey: key); return id
    }
}
