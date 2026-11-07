import SwiftUI

enum PlanExplanationRules {
    static func profileDiffers(_ snapshot: JSONValue?, from profile: MemberProfile, weightReference: JSONValue? = nil) -> Bool? {
        guard let snapshot, case .object(let before) = snapshot,
              let current = try? JSONValue.encode(profile.aiProfile),
              case .object(let after) = current else { return nil }
        let keys = ["age", "height", "weight", "goal", "experience", "venue", "daysPerWeek", "focus", "gender", "equipment", "equipmentOther", "sessionMinutes", "limitations", "trainingDays", "homeTrainingDays", "dailyActivity", "nutritionContext"]
        func normalized(_ value: JSONValue?) -> JSONValue {
            if value == nil || value == .string("") { return .null }
            return value ?? .null
        }
        return keys.contains { key in
            if key == "weight", let reference = PlanWeightReference.kilograms(weightReference), before[key] == .number(reference) { return false }
            if key == "dailyActivity" || key == "nutritionContext" {
                let fallback = JSONValue.string(key == "dailyActivity" ? "主要久坐" : "普通成人")
                let a = normalized(before[key]), b = normalized(after[key])
                return (a == .null ? fallback : a) != (b == .null ? fallback : b)
            }
            return normalized(before[key]) != normalized(after[key])
        }
    }

    static func sameStructure(_ before: [AIPlanSession], _ after: [AIPlanSession]) -> Bool {
        guard before.count == after.count else { return false }
        let left = before.sorted { $0.date < $1.date }, right = after.sorted { $0.date < $1.date }
        for (a, b) in zip(left, right) {
            guard a.date == b.date, a.exercises.count == b.exercises.count else { return false }
            for (x, y) in zip(a.exercises, b.exercises) {
                guard x.library_id == y.library_id, x.custom_id == y.custom_id,
                      x.custom_unit == y.custom_unit, x.rest_seconds == y.rest_seconds, x.name == y.name, x.sets.count == y.sets.count else { return false }
                for (s, t) in zip(x.sets, y.sets) {
                    guard s.reps == t.reps, s.durationSeconds == t.durationSeconds else { return false }
                    // The AI leaves loads unset; entering an actual load is not a new prescription.
                    if let weight = s.weight, Optional(weight) != t.weight { return false }
                }
            }
        }
        return true
    }

    static func originalSessions(_ sessions: [AIPlanSession], in cycle: TrainingCycle) -> [AIPlanSession] {
        sessions.filter { cycle.dates.contains($0.date) }
    }
    static func sessions(in cycle: TrainingCycle, days: [String: DayLog]) -> [AIPlanSession] {
        cycle.dates.compactMap { key in
            guard let day = days[key], !day.exercises.isEmpty else { return nil }
            return session(date: key, exercises: day.exercises)
        }
    }

    static func session(date: String, exercises: [Exercise]) -> AIPlanSession {
        AIPlanSession(date: date, label: "", exercises: exercises.map { exercise in
            AIPlanExercise(name: exercise.name, muscle: exercise.muscle,
                sets: exercise.sets.map { AIPlanSet(weight: $0.weight, reps: $0.reps, durationSeconds: $0.durationSeconds) },
                library_query: exercise.libraryQuery, library_id: exercise.libraryID,
                custom_id: exercise.customExerciseID, custom_unit: exercise.customUnit, rest_seconds: exercise.restSeconds)
        })
    }

    static func notice(profileChanged: Bool?, planChanged: Bool) -> String? {
        if planChanged { return "你已调整动作、组次或休息目标。以下说明对应生成时的原方案，请结合当前安排核对。" }
        if profileChanged == true { return "个人资料与生成时不同。以下说明保留原方案的依据，不会自动套用现在的资料。" }
        if profileChanged == nil { return "当前资料暂无法与生成时完整核对。以下说明对应生成时保存的方案。" }
        return nil
    }
}

struct PlanExplanationCard: View {
    let explanation: AIPlanExplanation
    var notice: String? = nil
    @State private var expanded = false
    var body: some View {
        ClubCard {
            HStack(spacing: BojiLayout.inline) {
                BojiBrandMark(size:24,style:.monochrome)
                    // lint-ignore: brand-gradient（品牌渐变，一次性）
.foregroundStyle(LinearGradient(colors: [Color(red: 0.11, green: 0.31, blue: 0.85), Color(red: 0.43, green: 0.16, blue: 0.85), Color(red: 0.75, green: 0.09, blue: 0.36)], startPoint: .leading, endPoint: .trailing))  // lint-ignore: brand-gradient（品牌渐变，一次性）
                Spacer()
                Image(systemName: "text.bubble").foregroundStyle(.secondary).accessibilityHidden(true)
            }
            Text(notice == nil ? "安排依据" : "原方案的制定依据").bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
            if let notice { Text(notice).bojiType(.secondary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            ForEach(Array(explanation.summary.prefix(3).enumerated()), id: \.offset) { index, text in
                HStack(alignment: .top, spacing: BojiLayout.inline) {
                    Text("\(index + 1)").bojiType(.caption).foregroundStyle(.secondary).padding(.top, BojiLayout.tight)
                    Text(text).bojiType(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            DisclosureGroup("查看完整安排依据", isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: BojiLayout.blockGap) {
                    Text("基于生成时的个人资料与原始计划。身体信息为自填背景，训练量与时间仍需结合实际执行核对。")
                        .bojiType(.label).foregroundStyle(.secondary)
                    ForEach(explanation.sections) { reason in
                        VStack(alignment: .leading, spacing: BojiLayout.inline) {
                            Text(reason.title).bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
                            Text(reason.basis).bojiType(.secondary).foregroundStyle(.secondary)
                            Text(reason.detail).bojiType(.body).lineSpacing(5)
                        }.fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(.top, BojiSpace.workoutCardInset)
            }.bojiType(.secondary).tint(.primary)
        }
    }
}

#if DEBUG
struct SavedPlanExplanationCard: View {
    let cycle: TrainingCycle
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var ai: AIService
    private var job: AILocalJob? { ai.job(cycle.sourceJobID) }
    private var notice: String? {
        let expected = PlanExplanationRules.originalSessions(job?.result?.sessions ?? [], in: cycle)
        let changed = !PlanExplanationRules.sameStructure(expected, PlanExplanationRules.sessions(in: cycle, days: store.state.days))
        let changes = PlanExplanationRules.notice(profileChanged: PlanExplanationRules.profileDiffers(job?.request.payload["profile"], from: store.state.profile, weightReference: job?.request.payload["weight_reference"]), planChanged: changed)
        let scope: String?
        if cycle.dates.count < 7 {
            scope = "本周期因新安排缩短为 \(cycle.label)。以下保留原计划整体的制定依据，只核对当前仍保留的训练日。"
        } else if let duration = job?.result?.plan_days, duration > 7 {
            scope = "以下是完整 \(duration) 天原计划的制定依据；当前查看的周期是 \(cycle.label)。"
        } else { scope = nil }
        let messages = [scope, PlanWeightReference.description(job?.request.payload["weight_reference"]), changes].compactMap { $0 }
        return messages.isEmpty ? nil : messages.joined(separator: "\n")
    }
    var body: some View {
        if let job, let explanation = job.result?.explanation, explanation.version == 1 {
            PlanExplanationCard(explanation: explanation, notice: notice).id(job.id + "/" + cycle.start)
        } else {
            Text("这份安排没有保存 AI 制定说明。新生成的专属计划会同时保存安排依据。")
                .bojiType(.label).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
#endif

struct PlanDayPurposeView: View {
    let dateKey: String
    let day: DayLog
    @EnvironmentObject private var ai: AIService
    private var purpose: String? {
        guard let source = day.planCycle?.sourceJobID, let result = ai.job(source)?.result,
              result.explanation?.version == 1,
              let expected = result.sessions?.first(where: { $0.date == (day.movedFromDate ?? dateKey) }),
              let purpose = result.explanation?.sessions.first(where: { $0.date == (day.movedFromDate ?? dateKey) }) else { return nil }
        let current = PlanExplanationRules.session(date: day.movedFromDate ?? dateKey, exercises: day.trainingLog.exercises)
        return PlanExplanationRules.sameStructure([expected], [current]) ? purpose.purpose : nil
    }
    var body: some View {
        if let purpose {
            VStack(alignment: .leading, spacing: BojiLayout.inline) {
                Text("本次训练的目的").bojiType(.secondary)
                Text(purpose).bojiType(.secondary).foregroundStyle(.secondary).lineSpacing(3)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(BojiSpace.workoutCardInset)
                .background(ClubUI.insetSurface, in: RoundedRectangle(cornerRadius: ClubUI.controlRadius, style: .continuous))
        }
    }
}
