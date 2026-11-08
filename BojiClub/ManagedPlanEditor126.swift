import SwiftUI
import CryptoKit

struct PlanEditDay126: Identifiable {
    let id: String
    var date: String
    var exercises: [Exercise]
    let editable: Bool
}

enum PlanEditRules126 {
    struct Failure: LocalizedError {
        let text: String
        var errorDescription: String? { text }
    }
    private static func stableID(_ key: String) -> UUID {
        let hex = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return UUID(uuidString: "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20).prefix(12))") ?? UUID()
    }
    static func editable(_ day: DayLog, key: String, now: Date = Date()) -> Bool {
        key >= ClubDates.key(now) && !PlanAdoptionRules.isProtected(day) && !day.hasUnconfirmedTraining
    }
    static func owned(_ day: DayLog, plan: ManagedPlan, date: String? = nil) -> [Exercise] {
        let expected = Set(plan.version.sessions.flatMap { row in row.exercises.indices.map { stableID("\(plan.id)/\(row.date)/\($0)") } })
        return day.exercises.filter { e in
            if let id = e.planID { return id == plan.id || (date.map { plan.version.retainedDates.contains($0) } == true && plan.version.previousIDs.contains(id)) }
            if expected.contains(e.id) { return true }
            return plan.version.recordedAt == .distantPast && (day.planCycle?.sourceJobID == plan.id || (plan.id.hasPrefix("legacy-plan-") && day.planCycle?.start == plan.version.start) || date.map { plan.dates.contains($0) } == true)
        }
    }
    static func draft(plan: ManagedPlan, days: [String: DayLog], now: Date = Date()) -> [PlanEditDay126] {
        plan.dates.map { key in
            let day = days[key] ?? DayLog()
            return .init(id: key, date: key, exercises: owned(day, plan: plan, date: key), editable: editable(day, key: key, now: now))
        }
    }
    static func copying(_ exercises: [Exercise], planID: String) -> [Exercise] {
        exercises.map { item in
            var e = item; e.id = UUID(); e.planID = planID; e.workoutSessionID = nil; e.deletedSetIDs = nil
            e.sets = item.sets.map { source in var s = source; s.id = UUID(); s.completed = false; s.actualEntered = false; return s }
            return e
        }
    }
    /// Prepare the complete transaction before touching the store. Other plans and
    /// execution facts survive; the immutable new version documents every change.
    static func prepare(plan: ManagedPlan, draft: [PlanEditDay126], baseline: [String: DayLog], current: [String: DayLog],
                        newID: String, now: Date = Date()) throws -> [String: DayLog] {
        func fail(_ text: String) throws -> Never { throw Failure(text: text) }
        guard !PlanManagementRules.isCancelled(plan.id, days: current) else { try fail("这份计划已结束，请重新打开。") }
        let expected = Set(plan.dates)
        guard Set(draft.map(\.id)) == expected, draft.count == expected.count else { try fail("计划范围已变化，请重新打开。") }
        let targets = draft.filter { $0.editable && !$0.exercises.isEmpty }.map(\.date)
        guard Set(targets).count == targets.count else { try fail("同一份计划的训练日期重复，请调整后再保存。") }
        guard !targets.isEmpty else { try fail("如需取消全部剩余安排，请返回使用结束计划。") }
        let allDates = expected.union(targets)
        guard let first = allDates.min(), let last = allDates.max(), let firstDate = ClubDates.date(fromKey: first), let lastDate = ClubDates.date(fromKey: last),
              (ClubDates.calendar.dateComponents([.day], from: firstDate, to: lastDate).day ?? 999) < 28 else { try fail("本次编辑范围最多 28 天，请另建后续计划。") }
        for key in allDates {
            guard PlanAdoptionRules.sameTraining(current[key] ?? DayLog(), baseline[key] ?? DayLog()), (try? CloudMerge.same(current[key]?.planActions ?? [], baseline[key]?.planActions ?? [])) == true else { try fail("\(key) 的训练已变化，请重新打开编辑，不会覆盖其他设备的改动。") }
        }
        var result = current
        var changed = false
        let eventID = UUID().uuidString
        for row in draft {
            let old = baseline[row.id] ?? DayLog()
            if !row.editable {
                guard row.date == row.id, (try? CloudMerge.same(row.exercises, owned(old, plan: plan, date: row.id))) == true else { try fail("已开始或过去的训练不可通过计划编辑改写。") }
                continue
            }
            guard editable(current[row.id] ?? DayLog(), key: row.id, now: now), row.date >= ClubDates.key(now), ClubDates.date(fromKey: row.date) != nil else { try fail("只能编辑尚未开始的今天及以后安排。") }
            if !row.exercises.isEmpty {
                let target = current[row.date] ?? DayLog()
                guard editable(target, key: row.date, now: now) else { try fail("\(row.date) 已开始训练，请保留原记录并另选日期。") }
                if row.date != row.id, !target.exercises.filter({ e in !owned(target, plan: plan, date: row.date).contains(where: { $0.id == e.id }) }).isEmpty {
                    try fail("\(row.date) 已有其他训练安排，请另选日期，或先到日历处理冲突。")
                }
            }
            guard row.exercises.count <= 30 else { try fail("单日动作过多，请拆分安排。") }
            for exercise in row.exercises {
                guard !exercise.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !exercise.sets.isEmpty, exercise.sets.count <= 30,
                      exercise.sets.allSatisfy({ RecordLimits.valid($0) && !$0.completed && !$0.hasActualEntry && ($0.durationSeconds.map { $0 > 0 } ?? ($0.reps > 0)) }) else { try fail("请填写有效的目标组次；实记数据不能作为计划写入。") }
            }
            if (!row.exercises.isEmpty && row.date != row.id) || !ClubPlanChangeRules.sameContents(ClubPlanChangeRules.snapshot(owned(old, plan: plan, date: row.id)), ClubPlanChangeRules.snapshot(row.exercises)) { changed = true }
            var day = result[row.id] ?? DayLog()
            let oldIDs = Set(owned(old, plan: plan, date: row.id).map(\.id))
            day.exercises.removeAll { oldIDs.contains($0.id) }
            day.planActions = (day.planActions ?? []) + [.init(id: eventID, planID: plan.id, kind: "ended", createdAt: now, exerciseIDs: oldIDs.map { $0.uuidString }, clearsCycle: day.planCycle?.sourceJobID == plan.id)]
            result[row.id] = day
        }
        guard changed else { try fail("没有检测到计划变化。") }
        for row in draft where row.editable && !row.exercises.isEmpty {
            var day = result[row.date] ?? DayLog()
            day.exercises += copying(row.exercises, planID: newID)
            result[row.date] = day
        }
        for key in allDates {
            if var day = result[key] { PlanManagementRules.reconcile(&day); result[key] = day }
        }
        return result
    }
    static func applyFollowing(source: String, rows: inout [PlanEditDay126]) -> Int {
        guard let row = rows.first(where: { $0.id == source }), row.editable, let date = ClubDates.date(fromKey: row.date) else { return 0 }
        let weekday = ClubDates.calendar.component(.weekday, from: date)
        var count = 0
        for index in rows.indices where rows[index].editable && rows[index].date > row.date {
            guard let target = ClubDates.date(fromKey: rows[index].date), ClubDates.calendar.component(.weekday, from: target) == weekday else { continue }
            rows[index].exercises = copying(row.exercises, planID: "draft"); count += 1
        }
        return count
    }
}

struct ManagedPlanEditor126: View {
    let plan: ManagedPlan
    var initialDate: String? = nil
    let saved: (String) -> Void
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var owner: Int?
    @State private var baseline: [String: DayLog] = [:]
    @State private var rows: [PlanEditDay126] = []
    @State private var selected = ""
    @State private var loading = true
    @State private var saving = false
    @State private var review = false
    @State private var library = false
    @State private var replacingID: UUID?
    @State private var error: String?
    @State private var notice: String?
    @State private var confirmDiscard = false
    @State private var repeatConfirm = false
    @State private var originalFingerprint = ""
    private var index: Int? { rows.firstIndex { $0.id == selected } }
    private var fingerprint: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return rows.map { $0.id + ":" + $0.date + ":" + ((try? encoder.encode($0.exercises)).map { $0.base64EncodedString() } ?? "") }.joined()
    }
    private var changes: [ClubPlanDayChange] {
        rows.map { row in .init(date: row.id, before: ClubPlanChangeRules.snapshot(PlanEditRules126.owned(baseline[row.id] ?? DayLog(), plan: plan, date: row.id)), after: ClubPlanChangeRules.snapshot(row.exercises), retained: !row.editable) }
    }
    var body: some View {
        ClubNavigationStack132 {
            Form {
                if loading { Section { ProgressView("正在核对计划…") } }
                Section {
                    Text(plan.version.title).bojiType(.bodyStrong)
                    Text("只编辑这份计划。已开始与已完成训练只读，保存前核对差异。")
                        .bojiType(.label).foregroundStyle(.secondary)
                    Picker("训练日", selection: $selected) {
                        ForEach(rows) { row in Text(row.id + (row.editable ? "" : " · 只读")).tag(row.id) }
                    }
                }
                if let index {
                    dayFields(index)
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
                if let notice { Section { Text(notice).bojiType(.label) } }
            }
            .navigationTitle("编辑计划").navigationBarTitleDisplayMode(.inline)
            .disabled(loading || saving)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { if fingerprint != originalFingerprint { confirmDiscard = true } else { dismiss() } } }
                ToolbarItem(placement: .confirmationAction) { Button("预览更改") { error = nil; review = true }.disabled(fingerprint == originalFingerprint) }
            }
            .interactiveDismissDisabled(fingerprint != originalFingerprint || saving)
            .task {
                guard loading else { return }
                owner = store.editingAccountID
                await store.syncNow()
                guard owner == store.editingAccountID, !Task.isCancelled else { dismiss(); return }
                baseline = store.state.days
                rows = PlanEditRules126.draft(plan: plan, days: baseline)
                if store.planIsEnded(plan.id) { rows = rows.map { .init(id: $0.id, date: $0.date, exercises: $0.exercises, editable: false) } }
                selected = initialDate ?? rows.first(where: { $0.editable && !$0.exercises.isEmpty })?.id ?? rows.first?.id ?? ""
                originalFingerprint = fingerprint; loading = false
            }
            .onChange(of: store.editingAccountID) { _, value in if value != owner { dismiss() } }
            .sheet(isPresented: $library) {
                ClubNavigationStack132 {
                    ExerciseLibraryView(date: ClubDates.date(fromKey: selected) ?? Date(), selectionAction: { item in
                        guard let index, rows[index].editable else { return }
                        let replacement = Exercise(name: item.displayName, muscle: item.muscleLabel,
                            sets: ExerciseMeasurement.initialSets(name: item.displayName, query: item.name, recordingUnit: item.suggestedRecordingUnit, trainingType: item.trainingTypeZH),
                            libraryID: item.customID == nil ? item.id : nil, equipment: item.equipmentLabel, imageURL: item.imageURL, gifURL: item.gifURL,
                            planID: plan.id, libraryQuery: item.name, customExerciseID: item.customID)
                        if let replacingID, let e = rows[index].exercises.firstIndex(where: { $0.id == replacingID }) { rows[index].exercises[e] = replacement }
                        else { rows[index].exercises.append(replacement) }
                        replacingID = nil; library = false
                    }, added: {})
                    .navigationTitle("选择动作").toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { library = false } } }
                }
            }
            .sheet(isPresented: $review) { reviewSheet }
            .confirmationDialog("放弃未保存的计划修改？", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("放弃修改", role: .destructive) { dismiss() }; Button("继续编辑", role: .cancel) {}
            }
            .confirmationDialog("应用到已排出的同星期训练日？", isPresented: $repeatConfirm, titleVisibility: .visible) {
                Button("替换已排出的同星期安排") { let count = PlanEditRules126.applyFollowing(source: selected, rows: &rows); notice = "已更新草稿中的 \(count) 个后续训练日，尚未保存。" }
                Button("取消", role: .cancel) {}
            } message: { Text("仅替换本计划后续可编辑的同星期训练日，保留它们的日期；保存前仍需预览。") }
        }.accessibilityIdentifier("managed-plan-editor")
    }
    @ViewBuilder private func dayFields(_ i: Int) -> some View {
        Section(rows[i].editable ? "当天安排" : "已保留的训练") {
            if rows[i].editable {
                DatePicker("训练日期", selection: Binding(get: { ClubDates.date(fromKey: rows[i].date) ?? Date() }, set: { rows[i].date = ClubDates.key($0) }), in: ClubDates.calendar.startOfDay(for: Date())..., displayedComponents: .date)
            }
            if rows[i].exercises.isEmpty { Text("休息日 / 暂无动作").foregroundStyle(.secondary) }
            ForEach(rows[i].exercises.indices, id: \.self) { e in
                VStack(alignment: .leading, spacing: BojiLayout.rowGap) {
                    HStack {
                        Text(rows[i].exercises[e].displayName).bojiType(.bodyStrong)
                        Spacer()
                        if rows[i].editable {
                            Menu {
                                Button("更换动作") { replacingID = rows[i].exercises[e].id; library = true }
                                if e > 0 { Button("上移") { rows[i].exercises.swapAt(e,e-1) } }
                                if e+1 < rows[i].exercises.count { Button("下移") { rows[i].exercises.swapAt(e,e+1) } }
                                Button("移除动作", role: .destructive) { rows[i].exercises.remove(at: e) }
                            } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                        }
                    }
                    ForEach(rows[i].exercises[e].sets.indices, id: \.self) { s in
                        HStack {
                            Text("\(s+1)组").bojiType(.caption).frame(width: 32)
                            if rows[i].exercises[e].sets[s].durationSeconds == nil {
                                TextField("kg", value: $rows[i].exercises[e].sets[s].weight, format: .number).keyboardType(.decimalPad)
                                Text("kg").bojiType(.caption)
                                TextField("次数", value: $rows[i].exercises[e].sets[s].reps, format: .number).keyboardType(.numberPad)
                                Text("次").bojiType(.caption)
                            } else {
                                TextField("秒数", value: $rows[i].exercises[e].sets[s].durationSeconds, format: .number).keyboardType(.numberPad)
                                Text("秒").bojiType(.caption)
                            }
                            if rows[i].editable {
                                Button(role: .destructive) { rows[i].exercises[e].sets.remove(at: s) } label: { Image(systemName: "minus.circle").frame(width: 44,height: 44) }.buttonStyle(.borderless).accessibilityLabel("移除第\(s+1)组")
                            }
                        }.disabled(!rows[i].editable)
                    }
                    if rows[i].editable {
                        Button("添加一组") {
                            let timed = rows[i].exercises[e].sets.last?.durationSeconds != nil
                            rows[i].exercises[e].sets.append(TrainingSet(weight: rows[i].exercises[e].sets.last?.weight ?? 0, reps: timed ? 0 : 10, durationSeconds: timed ? 30 : nil, actualEntered: false))
                        }.buttonStyle(.borderless)
                    }
                }.padding(.vertical, BojiLayout.tight)
            }
            if rows[i].editable {
                Button("添加动作") { replacingID = nil; library = true }
                Button("应用到已排出的同星期训练日") { repeatConfirm = true }
            }
        }
    }
    private var reviewSheet: some View {
        ClubNavigationStack132 {
            List {
                Section { Text("确认后保存为新版本，原版本和训练记录保留。其他计划不受影响。").bojiType(.secondary) }
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                    if changes[i].changed || row.date != row.id {
                        Section(row.id + (row.date == row.id ? "" : " → " + row.date)) {
                            Text("修改前：" + changes[i].before.map { "\($0.displayName) \($0.sets.count)组" }.joined(separator: "、"))
                            Text("修改后：" + (row.exercises.isEmpty ? "休息日" : row.exercises.map { "\($0.displayName) \($0.sets.count)组" }.joined(separator: "、")))
                            ForEach(row.exercises) { exercise in Text(exercise.displayName + "：" + ClubPlanChangeRules.snapshot([exercise]).flatMap(\.sets).map(ClubPlanChangeRules.setLabel).joined(separator: " / ")).bojiType(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("确认计划改动").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("返回编辑") { review = false }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) { Button(saving ? "保存中…" : "确认保存") { Task { await commit() } }.disabled(saving) }
            }.interactiveDismissDisabled(saving)
        }
    }
    private func commit() async {
        saving = true; defer { saving = false }
        await store.syncNow()
        guard let owner, owner == store.editingAccountID else { dismiss(); return }
        if !store.isPreviewAccount126 { guard case .synced = store.syncStatus else { error = "请先联网完成同步，再确认修改；草稿仍然保留。"; return } }
        if let id = store.commitPlanEdit126(plan: plan, draft: rows, baseline: baseline, owner: owner) { saved(id); dismiss() }
        else { error = store.takeMessage(fallback: "计划未保存，原安排保留。") }
    }
}
