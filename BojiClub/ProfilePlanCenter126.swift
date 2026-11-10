import SwiftUI

enum ProfileEditSection126: String, Identifiable {
    case body, training
    var id: String { rawValue }
    var title: String { self == .body ? "身体资料" : "目标与训练条件" }
}

struct ProfileKnowledgeCards126: View {
    @ObservedObject var editor: ProfileFactsEditor
    let onEdit: (ProfileFactEditTarget) -> Void
    let onClear: (OnboardingFieldSpec) -> Void
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var account: AccountService
    let onEditGroup: (ProfileEditSection126) -> Void
    private let bodyFields: [OnboardingFieldSpec] = [.nickname, .ageYears, .sexForNutrition, .heightCm, .profileWeightKg, .targetWeightKg]
    private let trainingFields: [OnboardingFieldSpec] = [.goal, .experience, .trainingDays, .sessionMinutes, .venue, .equipment, .equipmentOther, .homeTrainingDays, .equipmentExclusions, .focus, .limitations]
    var body: some View {
        Section {
            NavigationLink {
                List {
                    Section { ForEach(bodyFields, id: \.self) { field in factRow(field) } }
                    Section {
                        if let entry = ProfileBodyRules126.latestMeasurement(store.state.days) { LabeledContent("最近体重记录", value: "\(entry.value.formatted()) kg · \(entry.date)") }
                        if let bmi = ProfileBodyRules126.bmi(profile: store.state.profile) { LabeledContent("BMI", value: bmi.formatted(.number.precision(.fractionLength(1)))) }
                    }
                    Section { Button("编辑身体资料") { onEditGroup(.body) } }
                }.clubManagementList132().navigationTitle("身体资料").navigationBarTitleDisplayMode(.inline)
            } label: { LabeledContent("身体资料", value: ProfileBodyRules126.value(field: .heightCm, profile: store.state.profile) ?? "补充资料") }
            NavigationLink {
                List {
                    Section { ForEach(trainingFields, id: \.self) { field in factRow(field) } }
                    Section {
                        Button("编辑训练条件") { onEditGroup(.training) }
                    }
                }.clubManagementList132().navigationTitle("目标与训练条件").navigationBarTitleDisplayMode(.inline)
            } label: { LabeledContent("目标与训练条件", value: ProfileBodyRules126.value(field: .goal, profile: store.state.profile) ?? "未填写") }
            NavigationLink {
                List { factRow(.personalPreferences); factRow(.dailyActivity); factRow(.nutritionContext) }
                    .clubManagementList132().navigationTitle("习惯与偏好").navigationBarTitleDisplayMode(.inline)
            } label: { Text("习惯与偏好") }
            if let error = editor.error { Text(error).font(.footnote).foregroundStyle(.secondary); Button("重新读取资料") { Task { await reload() } } }
        }
        .accessibilityIdentifier("profile-knowledge-cards")
    }
    private func header(_ title: String, group value: ProfileEditSection126) -> some View {
        HStack { Text(title).font(.headline); Spacer(); Button("编辑") { onEditGroup(value) }.font(.subheadline) }
    }
    private func factRow(_ field: OnboardingFieldSpec) -> some View {
        let fact = editor.facts?.facts[field.apiKey]
        let value = fact.map { field.displayValue($0.value) } ?? ProfileBodyRules126.value(field: field, profile: store.state.profile) ?? "未填写"
        return NavigationLink {
            Form {
                Section { LabeledContent(field.title, value: value) }
                if let fact { Section("来源") { Text(fact.sourceLabel); if let updated = fact.updatedAt { Text(updated).foregroundStyle(.secondary) } } }
                if let doc = editor.facts {
                    Section {
                        Button(fact == nil ? "填写" : "修改") { onEdit(.init(field: field, value: fact?.value, revision: doc.revision)) }
                        if fact != nil { Button("清空这项资料", role: .destructive) { onClear(field) } }
                    }
                }
            }.clubManagementList132().navigationTitle(field.title).navigationBarTitleDisplayMode(.inline)
        } label: {
            HStack { Text(field.title); Spacer(minLength: 12); Text(value).foregroundStyle(.secondary).multilineTextAlignment(.trailing).lineLimit(2) }
        }
    }
    private func reload() async {
        let owner = account.user?.id
        await editor.load(account: account)
        guard owner == account.user?.id, owner == store.editingAccountID, let doc = editor.facts else { return }
        store.applyV2ProfileFacts(doc.facts.mapValues(\.value), meta: doc.facts.mapValues { ProfileFactMeta(sourceKind: $0.sourceKind ?? "legacy_recorded", confirmedAt: nil, revision: doc.revision) })
    }
}

enum ProfileBodyRules126 {
    static func bmi(profile: MemberProfile) -> Double? { BodyProfileAssessment.bmi(profile) }
    static func latestMeasurement(_ days: [String: DayLog], now: Date = Date()) -> (date: String, value: Double)? {
        for key in days.keys.filter({ $0 <= ClubDates.key(now) }).sorted(by: >) {
            guard let day = days[key] else { continue }
            let deleted = Set(day.deletedBodyMeasurementIDs ?? [])
            let rows = (day.bodyMeasurements ?? []) + (day.bodyWeight.map { [$0] } ?? [])
            if let row = rows.filter({ $0.id.map { !deleted.contains($0.uuidString) && !deleted.contains($0.uuidString.lowercased()) } ?? true })
                .filter({ $0.measuredKilograms != nil }).max(by: { ($0.recordedAt ?? $0.updatedAt) < ($1.recordedAt ?? $1.updatedAt) }), let kg = row.measuredKilograms { return (key, kg) }
        }
        return nil
    }
    static func value(field: OnboardingFieldSpec, profile p: MemberProfile) -> String? {
        guard p.isFactConfirmed(field.apiKey) else { return nil }
        switch field {
        case .nickname: return p.nickname
        case .equipmentOther: return p.equipmentOther
        case .homeTrainingDays: return p.homeTrainingDays.map { $0.map(String.init).joined(separator: "、") }
        case .ageYears: return "\(p.age) 岁"
        case .sexForNutrition: return p.gender
        case .heightCm: return "\(p.height.formatted()) cm"
        case .profileWeightKg: return "\(p.weight.formatted()) kg"
        case .targetWeightKg: return p.targetWeightKg.map { "\($0.formatted()) kg" }
        case .goal: return p.goal
        case .experience: return p.experience
        case .trainingDays: return p.trainingDays.map { $0.map { "周\(["一","二","三","四","五","六","日"][max(1,min(7,$0))-1])" }.joined(separator: "、") }
        case .sessionMinutes: return p.sessionMinutes.map { "\($0) 分钟" }
        case .venue: return p.venue
        case .equipment: return p.equipment
        case .equipmentExclusions: return p.equipmentExclusions?.joined(separator: "、")
        case .focus: return p.focus
        case .limitations: return p.limitations
        case .dailyActivity: return p.dailyActivity
        case .nutritionContext: return p.nutritionContext
        default: return nil
        }
    }
}


enum MemoryEvidenceLabels126 {
    static func label(_ ref: String) -> String {
        switch ref {
        case "profile/goal": return "你确认的训练目标"
        case "profile/limitations": return "你填写的训练限制"
        case "profile/daysPerWeek": return "你选择的每周训练次数"
        case "workout-saved-hours": return "已保存训练的开始时间统计"
        case "meals/window": return "近期已确认饮食记录"
        default:
            let date = ref.split(separator: "/").first { part in part.count == 10 && part.filter({ $0 == "-" }).count == 2 }
            return date.map { "已确认记录 · " + $0 } ?? "已确认的训练与饮食记录"
        }
    }
}
