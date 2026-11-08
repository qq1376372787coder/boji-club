import SwiftUI

private enum PlanCreationDestination: String, Identifiable {
    case day, repeated, ai, imported, templates, history
    var id: String { rawValue }
}

struct PlanCreationSheet: View {
    let date: Date
    @Environment(\.dismiss) private var dismiss
    @State private var destination: PlanCreationDestination?
    private var isPast: Bool { ClubDates.key(date) < ClubDates.key(Date()) }
    var body: some View {
        ClubNavigationStack132 {
            ScrollView {
                VStack(alignment: .leading, spacing: BojiLayout.blockGap) {
                    Text(isPast ? "补记这一天的训练" : "你想怎么安排？").bojiFont(.pageTitle)
                    Text(ClubDates.label(date, format: "M月d日 EEEE")).foregroundStyle(.secondary)
                    if isPast {
                        choice("补记", detail: "选择当天实际做过的动作，再填写完成的组次", symbol: "square.and.pencil", target: .history)
                    } else {
                        choice("自己安排", detail: "只安排这一天，选择动作和基础组次", symbol: "slider.horizontal.3", target: .day)
                        choice("帮我安排", detail: "根据资料生成建议，确认后才加入日程", symbol: "sparkles", target: .ai)
                        DisclosureGroup("重复计划、模板与导入") {
                            VStack(spacing: BojiLayout.rowGap) {
                                choice("创建重复计划", detail: "搭好一周，再选择是否重复", symbol: "repeat", target: .repeated)
                                choice("使用我的模板", detail: "复用动作，重新确认日期", symbol: "square.on.square", target: .templates)
                                choice("整理文字计划", detail: "粘贴你已有的计划，识别后由你核对", symbol: "doc.text", target: .imported)
                            }.padding(.top, BojiSpace.general)
                        }
                    }
                }.padding(BojiSpace.pageInset)
            }.background { ClubBackground() }
                .navigationTitle(isPast ? "补记" : "安排训练")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { DismissButton() } }
        }
        .sheet(item: $destination) { target in
                    switch target {
                    case .day: ManualPlanView(startDate: date, singleDay: true, onSaved: { dismiss() })
                    case .repeated: WeeklyPlanCreator130(startDate: date, onSaved: { dismiss() })
                    case .templates: ManualPlanView(startDate: date, openTemplates: true, onSaved: { dismiss() })
                    case .ai: PlanView(date: date, onPlanApplied: { dismiss() })
                    case .imported: PlanView(date: date, initialMode: "parse_plan", onPlanApplied: { dismiss() })
                    case .history: ClubNavigationStack132 { WorkoutView(selectedDate: .constant(date), focused: true).toolbar { ToolbarItem(placement: .cancellationAction) { DismissButton() } } }
                    }
                }
    }
    private func choice(_ title: String, detail: String, symbol: String, target: PlanCreationDestination) -> some View {
        Button { destination = target } label: {
            HStack(spacing: BojiLayout.rowGap) {
                Image(systemName: symbol).bojiType(.section).frame(width: 34)
                VStack(alignment: .leading, spacing: BojiLayout.tight) {
                    Text(title).bojiType(.bodyStrong)
                    Text(detail).bojiType(.secondary).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").bojiType(.caption)
            }.frame(maxWidth: .infinity, minHeight: 64, alignment: .leading).bojiCard(padding: 16)
            .contentShape(Rectangle())
        }.buttonStyle(BojiRowPressStylePublic()).accessibilityIdentifier("create-" + target.rawValue)
    }
}

struct ManagedPlan: Identifiable {
    let version: ClubPlanVersion
    var liveDates: [String]? = nil
    var id: String { version.id }
    var dates: [String] { (liveDates ?? version.scopeDates).sorted() }
    var range: String { (dates.first ?? version.start) + " — " + (dates.last ?? version.start) }
    var sourceLabel: String {
        switch version.source { case "manual": return "自己安排"; case "continuation": return "沿用计划"; case "weekly_review": return "复盘调整"; default: return "制定" }
    }
}

struct ManagedPlanDetail132: View {
    var initialPlanID132: String? = nil
    let focusDate: Date
    let initialCycleStart: String?
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var owner: Int?
    @State private var selectedID: String?
    @State private var showArchived = false
    @State private var creation = false
    @State private var pendingAction: String?
    @State private var pendingPlanID: String?
    @State private var pendingBaseline: [String: DayLog] = [:]
    @State private var editRoute: PlanEditRoute126?
    @State private var weeklyEdit130: ManualPlanTemplate?
    @State private var error: String?
    @State private var workout: ClubTrainingRoute?
    private var plans: [ManagedPlan] {
        store.managedPlans.filter { plan in
            if showArchived { return true }
            guard !store.planIsArchived(plan.id) else { return false }
            if store.supersededPlanIDs126.contains(plan.id), store.cancellableDates(for: plan).isEmpty { return false }
            if !store.planIsEnded(plan.id) { return true }
            return plan.dates.contains { key in
                guard let day = store.state.days[key] else { return false }
                return PlanAdoptionRules.isProtected(day) && !store.exercises(in: day, ownedBy: plan).isEmpty
            }
        }
    }
    private var selected: ManagedPlan? { plans.first { $0.id == selectedID } ?? plans.first { $0.dates.contains(initialCycleStart ?? ClubDates.key(focusDate)) } ?? plans.first }
    var body: some View {
        ClubNavigationStack132 {
            List {
                    if plans.count > 1, let selected {
                        Picker("选择计划", selection: Binding(get: { selected.id }, set: { selectedID = $0 })) {
                            ForEach(plans) { plan in Text(plan.version.title + " · " + plan.version.start).tag(plan.id) }
                        }.pickerStyle(.menu)
                    }
                    if let selected {
                        planHeader(selected)
                        if let template = store.weeklyTemplate130(planID: selected.id) {
                            ClubCard {
                                Toggle("每周自动重复", isOn: Binding(get: { !store.planIsEnded(selected.id) && store.weeklyTemplate130(planID: selected.id)?.recurrence130?.enabled == true }, set: { _ = store.setWeeklyRepeat130(templateID: template.id, enabled: $0) })).disabled(store.planIsEnded(selected.id))
                                Text("暂停后不再新增日期，已排出的训练保留；可在计划中编辑或删除。").bojiType(.caption).foregroundStyle(.secondary)
                                Button("修改每周安排") { weeklyEdit130 = template }
                            }
                        }
                        ForEach(selected.dates, id: \.self) { key in dayRow(key, plan: selected) }
                        if !store.planIsEnded(selected.id), store.weeklyTemplate130(planID: selected.id)?.recurrence130?.enabled != true, let last = selected.dates.last,
                           let date = ClubDates.date(fromKey: last), !ClubDates.isFuture(date),
                           let cycle = TrainingCycle.covering(last, in: store.state.days) {
                            TrainingHandoffCard(cycle: cycle)
                        }
                    } else { EmptyNote(title: "还没有训练计划", detail: "可以自己安排，也可以自动生成。") }
                    if let error { FlowError(message: error) }
                    Button("创建新安排") { creation = true }.buttonStyle(PrimaryButton())
                    Toggle("显示已结束和归档的计划", isOn: $showArchived).bojiType(.secondary)

        }.clubManagementList132().background { ClubBackground() }
                .navigationTitle("我的计划").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { DismissButton() } }
                .onAppear { owner = store.editingAccountID; if selectedID == nil { if initialPlanID132 != nil || initialCycleStart != nil { showArchived = true }; selectedID = initialPlanID132 } }
                .onChange(of: store.editingAccountID) { _, value in if value != owner { dismiss() } }
                .sheet(isPresented: $creation) { PlanCreationSheet(date: max(Date(), focusDate)) }
                .sheet(item: $workout) { route in ClubNavigationStack132 { WorkoutView(selectedDate: .constant(route.date), focused: true).toolbar { ToolbarItem(placement: .cancellationAction) { DismissButton() } } } }
                .sheet(item: $weeklyEdit130) { WeeklyPlanCreator130(initialTemplate: $0) }
                .sheet(item: $editRoute) { route in ManagedPlanEditor126(plan: route.plan, initialDate: route.date) { selectedID = $0 } }
                .confirmationDialog("确认更改这份计划？", isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }), titleVisibility: .visible) {
                    if let selected = store.managedPlans.first(where: { $0.id == pendingPlanID }), let kind = pendingAction {
                        Button(kind == "ended" ? "移除未开始安排" : "归档计划", role: .destructive) {
                            if owner != store.editingAccountID { error = "账号已变化，请重新打开。" }
                            else if !store.managePlan(selected.id, action: kind, expectedDays: pendingBaseline) { error = store.takeMessage() }
                            pendingAction = nil
                        }
                    }
                    Button("取消", role: .cancel) { pendingAction = nil }
                } message: {
                    if let selected = store.managedPlans.first(where: { $0.id == pendingPlanID }) {
                        let count = store.cancellableDates(for: selected).count
                        Text(pendingAction == "archived" ? "只从默认列表收起这份计划，训练和历史版本仍可查询。" : "将移除 \(selected.range) 内 \(count) 个未开始训练日。已开始、已完成的训练以及饮食、身体记录全部保留。")
                    }
                }
        }
    }
    private func planHeader(_ plan: ManagedPlan) -> some View {
        ClubCard {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: BojiLayout.tight) {
                    Text(plan.version.title).bojiFont(.cardTitle)
                    Text(plan.range).bojiType(.secondary)
                    Text(plan.sourceLabel + (store.planIsEnded(plan.id) ? " · 已结束" : "")).bojiType(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    if !store.planIsEnded(plan.id), !store.cancellableDates(for: plan).isEmpty {
                        Button(plan.dates.contains(where: { PlanAdoptionRules.isProtected(store.state.days[$0] ?? DayLog()) }) ? "结束计划，取消剩余安排" : "删除未开始的计划", role: .destructive) { stage(plan, action: "ended") }
                    }
                    if !store.planIsArchived(plan.id) { Button("归档计划") { stage(plan, action: "archived") } }
                } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }.accessibilityLabel("管理这份计划")
            }
            if !store.planIsEnded(plan.id), !store.cancellableDates(for: plan).isEmpty {
                Button("编辑计划") { editRoute = .init(plan: plan, date: nil) }.buttonStyle(PrimaryButton()).accessibilityIdentifier("edit-managed-plan")
                Button("调整这份计划") { openAI(plan) }.buttonStyle(SecondaryButton())
            }
        }
    }
    private func stage(_ plan: ManagedPlan, action: String) {
        pendingPlanID = plan.id; pendingBaseline = store.state.days; pendingAction = action
    }
    private func openAI(_ plan: ManagedPlan) {
        guard let owner, owner == store.editingAccountID else { return }
        let anchor = store.state.days.keys.sorted().first { key in store.state.days[key]?.planVersions?.contains { $0.id == plan.id } == true }
        var references: [AIContextReference] = anchor.map { [.init(kind: "plan_version", resourceID: plan.id, from: $0, to: $0, title: plan.version.title)] } ?? []
        if let first = plan.dates.first, let last = plan.dates.last {
            references.append(.init(kind: "plan_day", resourceID: plan.id, from: first, to: last, title: plan.version.title + " · 当前安排"))
        }
        let prompt = "请调整我选中的“\(plan.version.title)”（\(plan.range)，计划编号 \(plan.id)）。先确认我的修改需求，给出修改前后差异。保留已开始、已完成训练及其他计划，不要未经确认修改日历。"
        ClubAIRoute.open(owner: owner, question: prompt, references: references)
        dismiss()
    }
    private func dayRow(_ key: String, plan: ManagedPlan) -> some View {
        let day = store.state.days[key] ?? DayLog()
        let date = ClubDates.date(fromKey: key) ?? focusDate
        let owned = PlanEditRules126.owned(day, plan: plan, date: key)
        return Button {
            editRoute = .init(plan: plan, date: key)
        } label: {
            VStack(alignment: .leading, spacing: BojiLayout.inline) {
                Text(ClubDates.label(date, format: "M月d日 EEEE")).bojiType(.bodyStrong)
                Text(owned.isEmpty ? (store.planIsEnded(plan.id) ? "已取消这一天的安排" : plan.version.sessions.contains(where: { $0.date == key }) ? "当天安排已调整" : "休息日") : owned.map(\.displayName).joined(separator: "、"))
                    .bojiType(.secondary).foregroundStyle(.secondary)
                Text(PlanEditRules126.editable(day, key: key) && !store.planIsEnded(plan.id) ? "编辑这份计划的当天安排" : "查看这份计划的安排（只读）").bojiType(.caption)
            }.frame(maxWidth: .infinity, alignment: .leading).bojiCard(padding: 14).contentShape(Rectangle())
        }.buttonStyle(BojiRowPressStylePublic())
    }
}


struct PlanEditRoute126: Identifiable {
    let id = UUID()
    let plan: ManagedPlan
    let date: String?
}
