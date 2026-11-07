import SwiftUI
import UniformTypeIdentifiers

struct HealthSummaryCard: View {
    let date: Date
    @EnvironmentObject private var health: HealthDataService
    @EnvironmentObject private var store: AppStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var showConnections = false
    private var summary: HealthDay? { health.summary(for: date) ?? store.log(for: date).health }
    private var hasNewData: Bool {
        guard let local = health.summary(for: date), let shared = store.log(for: date).health else { return false }
        var normalized = local.sharingSummary; normalized.updatedAt = shared.updatedAt
        return HealthShareConsent.encoded(normalized) != HealthShareConsent.encoded(shared)
    }
    var body: some View {
        ClubCard {
            HStack {
                SectionTitle(title: "设备与身体状态", symbol: "applewatch")
                Spacer()
                Button { showConnections = true } label: { Image(systemName: "slider.horizontal.3") }.buttonStyle(ClubIconButtonStyle()).accessibilityLabel("设备与健康数据设置")
            }
            if let summary, summary.hasData {
                HealthMetricsView(summary: summary)
                if let shared = store.log(for: date).health {
                    Text("已分享供 AI 分析（读取于 \(shared.updatedAt.formatted(date: .abbreviated, time: .shortened))）").bojiType(.caption).foregroundStyle(.secondary)
                } else {
                    Text("仅保存在本机，确认分享后可用于 AI 分析。").bojiType(.caption).foregroundStyle(.secondary)
                }
                if hasNewData {
                    Button("核对并更新已分享数据") { showConnections = true }.buttonStyle(SecondaryButton())
                }
            } else {
                EmptyNote(title: health.enabled ? "这一天暂无可读取的健康数据" : "把身体的反馈一起记录",
                          detail: health.enabled ? "请确认手表已同步至 Apple 健康。" : "支持读取 Apple 健康记录或导入 TCX 运动文件。")
                Button("管理设备与分享设置") { showConnections = true }.buttonStyle(SecondaryButton()).buttonBorderShape(.capsule)
            }
            if health.busy { ClubLoadingCard(title: "正在读取设备数据…") }
            if let message = health.message { Text(message).bojiType(.label).foregroundStyle(.secondary) }
        }
        .sheet(isPresented: $showConnections) { HealthConnectionsView(date: date) }
        .task(id: "\(ClubDates.key(date))-\(scenePhase == .active)") {
            if scenePhase == .active { await health.refresh(date, force: true) }
        }
    }
}

struct HealthMetricsView: View {
    let summary: HealthDay
    private var measurements: [HealthMeasurementRow] {
        [
            HealthMeasurementRow(title: "Apple 健康体重", metric: summary.bodyMass, unit: "kg"),
            HealthMeasurementRow(title: "体脂率", metric: summary.bodyFatPercentage, unit: "%"),
            HealthMeasurementRow(title: "去脂体重", metric: summary.leanBodyMass, unit: "kg"),
            HealthMeasurementRow(title: "身高", metric: summary.height, unit: "cm"),
            HealthMeasurementRow(title: "BMI（健康记录）", metric: summary.bodyMassIndex, unit: ""),
            HealthMeasurementRow(title: "腰围", metric: summary.waistCircumference, unit: "cm")
        ].filter { $0.metric != nil }
    }
    private func value(_ metric: HealthMetric?, decimals: Int = 0) -> String {
        metric.map { $0.value.formatted(.number.precision(.fractionLength(decimals))) } ?? "—"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: BojiLayout.rowGap) {
            HStack(spacing: BojiLayout.inline) {
                Metric(title: "步数", value: value(summary.steps), unit: "步")
                Metric(title: "活动能量", value: value(summary.activeEnergy), unit: "kcal")
                Metric(title: "当天记录的睡眠", value: value(summary.sleep, decimals: 1), unit: "小时")
            }
            HStack(spacing: BojiLayout.inline) {
                Metric(title: "平均心率", value: value(summary.heartRate), unit: "次 / 分")
                Metric(title: "静息心率", value: value(summary.restingHeartRate), unit: "次 / 分")
                Metric(title: "设备记录", value: "\(summary.workouts.count)", unit: "条 · 已去重")
            }
            if !measurements.isEmpty {
                Divider()
                Text("身体测量 · Apple 健康实际记录").bojiType(.secondary)
                ForEach(measurements) { item in
                    HStack(alignment: .firstTextBaseline) {
                        Text(item.title).bojiType(.secondary)
                        Spacer(minLength: 8)
                        if let metric = item.metric {
                            Text(metric.value.formatted(.number.precision(.fractionLength(1))) + (item.unit.isEmpty ? "" : " \(item.unit)"))
                                .bojiType(.secondary)
                        }
                    }
                    if let metric = item.metric {
                        Text("\(metric.source.name) · \(metric.recordedAt?.formatted(date: .abbreviated, time: .shortened) ?? "日期未提供")")
                            .bojiType(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Text("来源：\(summary.sources.map(\.name).joined(separator: "、")) · 读取于 \(summary.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                .bojiType(.label).foregroundStyle(.secondary)
        }
    }
}

private struct HealthMeasurementRow: Identifiable {
    let title: String
    let metric: HealthMetric?
    let unit: String
    var id: String { title }
}

struct HealthConnectionsView: View {
    @State var date: Date
    @EnvironmentObject private var health: HealthDataService
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var shareReview: HealthShareReviewRequest?
    @State private var confirmDisconnect = false
    @State private var error: String?
    @State private var shareMessage: String?
    @State private var owner: Int?
    private var summary: HealthDay? { health.summary(for: date) ?? store.log(for: date).health }
    private let brands: [(String, String, String)] = [
        ("Apple Watch", "通过 Apple 健康读取已同步的记录。", "https://support.apple.com/zh-cn/108779"),
        ("小米 / Redmi", "在 Mi Fitness（小米运动健康）的第三方数据设置中开启健康共享，再同步手表。", "https://www.mi.com/uk/support/faq/details/KA-230360/"),
        ("Garmin 佳明", "在 Garmin Connect 中连接 Apple 健康，保持品牌 App 在前台完成同步。", "https://support.garmin.com/en-AU/?faq=lK5FPB9iPF5PXFkIpFlFPA"),
        ("Amazfit / Zepp", "在 Zepp 中启用 Apple 健康共享。具体项目以你的设备和 App 提供的选项为准。", "https://support.amazfit.com/it/amazfit_x/docs/YfPEdX2R1oaMNexokstc8BkhnWb"),
        ("Polar", "在 Polar Flow 中开启 Apple 健康共享并同步设备。", "https://support.polar.com/en/support/connecting_polar_flow_with_apple_health"),
        ("华为", "先检查华为运动健康当前版本的健康共享设置。能写入 Apple 健康的项目才可在此读取，因地区、机型和版本而异。", "https://consumer.huawei.com/minisite/cloudservice/health/common/b0/latest/default/privacy-statement.htm?timestamp=202107221700")
    ]
    var body: some View {
        ClubNavigationStack132 {
            List {
                    Section("连接健康数据") {
                        Text(health.connectionStatus(for:date)).bojiType(.caption).foregroundStyle(.secondary)
                        Text("先在手表的 App 中同步数据，再允许薄肌俱乐部读取 Apple 健康。")
                            .bojiType(.secondary).foregroundStyle(.secondary)
                        Button(health.enabled ? "管理读取授权" : "连接 Apple 健康") {
                            let requestedDate=date
                            Task { await health.connect(on:requestedDate) }
                        }
                            .buttonStyle(PrimaryButton()).disabled(health.busy || !health.available)
                        Toggle("训练结束后可写入 Apple 健康", isOn: Binding(
                            get: { health.writeWorkoutsEnabled },
                            set: { value in Task { await health.setWorkoutWritingEnabled(value) } }
                        ))
                        .disabled(health.busy || !health.available || !health.enabled)
                        Text("已有手表记录时，可以直接关联，避免重复。")
                            .bojiType(.label).foregroundStyle(.secondary)
                        if !health.available { Text("请在支持健康数据的 iPhone 真机上使用此功能。").bojiType(.caption) }
                    }
                    ClubCard {
                        DatePicker("记录日期", selection: $date, in: ...Date(), displayedComponents: .date)
                        if let summary, summary.hasData { HealthMetricsView(summary: summary) }
                        else { EmptyNote(title: "这一天没有设备数据", detail: "请同步品牌 App，或选择有记录的日期。") }
                        Button { Task { await health.refresh(date, force: true) } } label: { Label(health.busy ? "正在读取…" : "刷新所选日期", systemImage: "arrow.clockwise") }.buttonStyle(SecondaryButton())
                            .disabled(health.busy || !health.enabled)
                        if health.busy { ClubLoadingCard(title: "正在读取健康数据…") }
                        if let message = health.message { Text(message).bojiType(.caption).foregroundStyle(.secondary) }
                    }
                    if !health.sources.isEmpty {
                        ClubCard {
                            Picker("优先数据来源", selection: Binding(get: { health.preferredSource }, set: { health.prefer($0); Task { await health.refresh(date, force: true) } })) {
                                Text("自动选择单一来源").tag("")
                                ForEach(health.sources) { Text($0.name).tag($0.id) }
                            }.disabled(health.busy)
                            Text("同一项数据只采用一个来源，避免重复统计。数值可能与 Apple 健康不同。")
                                .bojiType(.caption).foregroundStyle(.secondary)
                            DisclosureGroup("数据来源说明") {
                                Text("每个指标优先使用所选来源。无数据时，步数、能量、睡眠选择单一来源中总量较高者；心率使用固定顺序的首个来源。不同来源不会相加。不同来源、同类且时间重叠超过 80% 的运动只保留一条；类型未知或不同的记录不会强行合并。睡眠按当天 0 点至 24 点统计，不一定等于上一整晚的睡眠。")
                                    .bojiType(.caption).foregroundStyle(.secondary).padding(.top, BojiSpace.tight)
                            }
                        }
                    }
                    Section("运动记录") {
                        if let summary, !summary.workouts.isEmpty {
                            ForEach(summary.workouts) { workout in
                                VStack(alignment: .leading, spacing: BojiLayout.tight) {
                                    Text(workout.name).bojiType(.secondary)
                                    Text("\(workout.start.formatted(date: .omitted, time: .shortened)) · \(workout.minutes.formatted(.number.precision(.fractionLength(0)))) 分钟 · \(workout.source.name)")
                                        .bojiType(.caption).foregroundStyle(.secondary)
                                    if let calories = workout.calories { Text("运动能量 \(calories.formatted(.number.precision(.fractionLength(0)))) kcal").bojiType(.label) }
                                }
                            }
                        } else { Text("暂无运动记录").bojiType(.caption).foregroundStyle(.secondary) }
                    }
                    Section("用于你的训练分析") {
                        Text(HealthShareConsent.disclosure)
                            .bojiType(.caption).foregroundStyle(.secondary)
                        Button(store.log(for:date).trainingLog.completedSets > 0 ? "核对健康数据并关联当前训练" : "核对所选日期的健康数据") {
                            guard let owner, owner == store.editingAccountID, let value=health.summary(for:date) else { return }
                            shareReview = HealthShareReviewRequest(ownerID:owner,date:date,summary:value,day:store.log(for:date),allowsLink:store.log(for:date).trainingLog.completedSets > 0)
                        }
                            .buttonStyle(PrimaryButton()).disabled(health.summary(for: date)?.hasData != true || health.busy || owner == nil || owner != store.editingAccountID)
                        if owner == nil { Text("本机记录尚未就绪，暂不能分享。请等待恢复，或返回主页面查看提示。").bojiType(.label).foregroundStyle(.secondary) }
                        if store.log(for: date).health != nil {
                            Text("刷新后，确认分享即可更新数据。")
                                .bojiType(.label).foregroundStyle(.secondary)
                            Button("移除该日已分享的设备汇总", role: .destructive) {
                                guard store.removeHealth(on: date) else { shareMessage = store.takeMessage(fallback: "健康数据尚未移除，请重试。"); return }
                                shareMessage = "已移除这一天的健康汇总，联网后同步。以前生成的日报和分析输入仍会保留。"
                            }.buttonStyle(DestructiveButton())
                        }
                        if let shareMessage { Text(shareMessage).bojiType(.caption).foregroundStyle(.secondary) }
                    }
                    if store.log(for: date).completedSets > 0 { WorkoutHealthLinkCard(date: date, allowsManage: false) }
                    Section("品牌连接指南") {
                        ForEach(brands, id: \.0) { brand in
                            DisclosureGroup(brand.0) {
                                VStack(alignment: .leading, spacing: BojiLayout.inline) {
                                    Text(brand.1).bojiType(.caption).foregroundStyle(.secondary)
                                    Link("品牌官方说明 ↗", destination: URL(string: brand.2)!)
                                        .buttonStyle(SecondaryButton())
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, BojiSpace.tightRow)
                            }
                        }
                        Text("其他设备也可通过 Apple 健康同步，或导入 TCX 文件。")
                            .bojiType(.label).foregroundStyle(.secondary)
                    }
                    if health.enabled || !health.days.isEmpty {
                        Button("停止读取并清除本机设备缓存", role: .destructive) { confirmDisconnect = true }.buttonStyle(DestructiveButton())
                    }
                    if let error { Text(error).bojiType(.caption).foregroundStyle(.red) }

        }.clubManagementList132()
            .background { ClubBackground() }
            .navigationTitle("设备与健康数据").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { DismissButton() } }
            .task(id: ClubDates.key(date)) { await health.refresh(date, force: true) }
            .onAppear { if owner == nil { owner=store.editingAccountID } }
            .onChange(of:store.editingAccountID) { _, id in
                if owner == nil { owner=id }
                else if id != owner { dismiss() }
            }
            .confirmationDialog("停止读取并清除本机缓存？", isPresented: $confirmDisconnect, titleVisibility: .visible) {
                Button("停止并清除", role: .destructive) { health.disconnect() }
            } message: { Text("已确认分享的云端数据和日报不会随本机缓存删除。") }
            .sheet(item:$shareReview) { request in
                HealthShareReviewView(request:request) { shareMessage = "已保存，联网后同步；后续 AI 分析使用这份已确认的汇总。" }
            }
        }.tint(ClubBrand.accent)
    }
}


struct WorkoutHealthLinkCard: View {
    let date: Date
    var allowsManage = true
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var health: HealthDataService
    @State private var showConnections = false
    @State private var shareReview: HealthShareReviewRequest?
    private var day: DayLog { store.log(for: date).trainingLog }
    private var linked: DeviceWorkout? { day.health?.workouts.first { $0.id == day.linkedDeviceWorkoutID } }
    private var candidateSummary: HealthDay? {
        if let local = health.summary(for:date), !local.workouts.isEmpty { return local }
        return day.health
    }

    var body: some View {
        Section("本次训练与手表记录") {
            if let linked {
                Text("已关联：\(linked.name)").bojiType(.secondary)
                Text("\(linked.start.formatted(date: .omitted, time: .shortened))–\(linked.end.formatted(date: .omitted, time: .shortened)) · \(linked.source.name)")
                    .bojiType(.caption).foregroundStyle(.secondary)
                HStack {
                    Metric(title: "设备训练时长", value: linked.minutes.formatted(.number.precision(.fractionLength(0))), unit: "分钟")
                    Metric(title: "本次平均心率", value: linked.averageHeartRate.map { $0.formatted(.number.precision(.fractionLength(0))) } ?? "—", unit: "次 / 分")
                    Metric(title: "设备估算消耗", value: linked.calories.map { $0.formatted(.number.precision(.fractionLength(0))) } ?? "—", unit: "kcal")
                }
                Text("关联后将补充本次训练的时长、心率与消耗数据。")
                    .bojiType(.label).foregroundStyle(.secondary)
                Button("取消关联", role: .destructive) { store.linkDeviceWorkout(nil, on: date) }.buttonStyle(DestructiveButton())
            } else {
                Text("App 保留动作、重量和组数；手表补充同一次训练的时长、心率和消耗。")
                    .bojiType(.caption).foregroundStyle(.secondary)
                if candidateSummary?.workouts.isEmpty == false {
                    let suggestions = WorkoutAssociation.suggestedIDs(for: store.log(for: date), workouts: candidateSummary?.workouts ?? [])
                    Text(suggestions.isEmpty ? "请选择确实属于这次训练的设备记录，不会仅凭同一天自动合并。" : "找到运动类型和时间接近的训练，请核对后关联。")
                        .bojiType(.caption).foregroundStyle(.secondary)
                } else {
                    Text("暂未找到设备训练。手表同步可能延迟；刷新或连接健康后，可在一次确认中完成分享和关联。")
                        .bojiType(.caption).foregroundStyle(.secondary)
                }
            }
            if candidateSummary?.workouts.isEmpty == false {
                Button(linked == nil ? "核对并关联设备训练" : "更换关联") {
                    guard let owner = store.editingAccountID, let summary = candidateSummary else { return }
                    shareReview = HealthShareReviewRequest(ownerID:owner,date:date,summary:summary,day:store.log(for: date),allowsLink:true)
                }
                    .buttonStyle(SecondaryButton())
            }
            if allowsManage {
                Button(health.busy ? "正在查找设备训练…" : "刷新并查找设备训练") { Task { await health.refresh(date, force: true) } }
                    .buttonStyle(SecondaryButton()).disabled(health.busy || !health.enabled)
                if health.busy { ClubLoadingCard(title: "正在查找设备训练…") }
                Button("查看设备数据与分享设置") { showConnections = true }.buttonStyle(SecondaryButton()).bojiType(.caption)
            }
        }
        .sheet(isPresented: $showConnections) { HealthConnectionsView(date: date) }
        .sheet(item: $shareReview) { request in HealthShareReviewView(request:request) }
    }
}

struct HealthShareReviewView: View {
    let request: HealthShareReviewRequest
    var onSaved: (() -> Void)? = nil
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: String?
    @State private var initialized = false
    @State private var shareOnly = false
    @State private var submitting = false
    @State private var error: String?
    private var day: DayLog { store.log(for:request.date) }
    private var workouts: [DeviceWorkout] { request.summary.workouts }
    private var suggestions: Set<String> { WorkoutAssociation.suggestedIDs(for:day,workouts:workouts) }
    private var reservedIDs: Set<String> { Set((day.workoutSessions ?? []).filter { $0.id != day.activeWorkoutSessionID }.compactMap(\.linkedDeviceWorkoutID)) }
    private var selected: DeviceWorkout? { workouts.first { $0.id == selectedID } }
    private var linkingID: String? { request.allowsLink && !shareOnly ? selectedID : nil }
    private var issue: String? { HealthShareConsent.issue(request,workoutID:linkingID,current:day,ownerID:store.editingAccountID) }
    private var needsSelection: Bool { request.allowsLink && !shareOnly && selected == nil }
    var body: some View {
        let validationIssue = issue
        return ClubNavigationStack132 {
            List {
                Section {
                    Text("\(ClubDates.label(request.date)) · \(request.allowsLink ? "核对后分享并关联" : "核对后分享")").bojiFont(.exerciseName).foregroundStyle(BojiColor.textPrimary)
                    if request.allowsLink {
                        Text(suggestions.isEmpty ? "请按实际时间选择设备训练，也可以先只分享每日汇总。" : "找到 \(suggestions.count) 条时间接近的设备训练，请核对后确认。")
                            .bojiType(.caption).foregroundStyle(.secondary)
                    }
                    Text(HealthShareConsent.disclosure).bojiType(.caption).foregroundStyle(.secondary)
                    Text("这是打开确认页时的数据。后续设备刷新不会替换你正在核对的内容。").bojiType(.label).foregroundStyle(.secondary)
                    HealthMetricsView(summary:request.summary)
                }
                if request.allowsLink {
                    Section("选择同一次设备训练") {
                        Text("关联只补充时长、心率和消耗，不额外增加训练次数，也不重复累加热量。时间接近只是提示，请核对。")
                            .bojiType(.caption).foregroundStyle(.secondary)
                        ForEach(workouts) { workout in
                    Button { selectedID = workout.id; shareOnly = false; error = nil } label: {
                        VStack(alignment: .leading, spacing: BojiLayout.tight) {
                            HStack(alignment: .top, spacing: BojiLayout.rowGap) {
                                VStack(alignment: .leading, spacing: BojiLayout.tight) {
                                    Text(workout.name).bojiType(.body)
                                    if reservedIDs.contains(workout.id) { Text("已关联另一次训练").bojiType(.label).foregroundStyle(.secondary) }
                                    if suggestions.contains(workout.id) { Text("时间接近，待核对").bojiType(.label).foregroundStyle(.secondary) }
                                }
                                Spacer()
                                if !shareOnly && selectedID == workout.id { Image(systemName:"checkmark.circle.fill") }
                            }
                            Text("\(workout.start.formatted(date: .abbreviated, time: .shortened))–\(workout.end.formatted(date: .abbreviated, time: .shortened)) · \(workout.minutes.formatted(.number.precision(.fractionLength(0)))) 分钟 · \(workout.source.name)")
                                .bojiType(.caption).foregroundStyle(.secondary)
                            Text("平均心率 \(workout.averageHeartRate.map { $0.formatted(.number.precision(.fractionLength(0))) } ?? "—") 次/分 · 消耗 \(workout.calories.map { $0.formatted(.number.precision(.fractionLength(0))) } ?? "—") kcal")
                                .bojiType(.label).foregroundStyle(.secondary)
                        }.padding(.vertical, BojiLayout.tight)
                    }.buttonStyle(ClubMotionButton()).disabled(reservedIDs.contains(workout.id)).accessibilityAddTraits(!shareOnly && selectedID == workout.id ? .isSelected : [])
                        }
                        Button { shareOnly = true; error = nil } label: {
                            HStack { Text("只分享每日汇总，不新增关联"); Spacer(); if shareOnly { Image(systemName:"checkmark.circle.fill") } }
                        }.buttonStyle(ClubMotionButton()).accessibilityAddTraits(shareOnly ? .isSelected : [])
                        if let linked = day.linkedDeviceWorkoutID {
                            Text(workouts.contains(where:{$0.id == linked}) ? "只分享时会保留仍在汇总中的已有设备关联。" : "本次汇总不再包含原设备训练，确认分享会同时取消原关联；取消本页则保留原记录。")
                                .bojiType(.label).foregroundStyle(.secondary)
                        }
                        if workouts.isEmpty { Text("没有设备训练可关联，可先只分享汇总。").bojiType(.caption).foregroundStyle(.secondary) }
                    }
                }
                Section {
                    if needsSelection { Text("请先选择设备训练，或选择只分享每日汇总。").bojiType(.caption).foregroundStyle(.secondary) }
                    if let validationIssue { Text(validationIssue).bojiType(.caption).foregroundStyle(.red) }
                    if let error { Text(error).bojiType(.caption).foregroundStyle(.red) }
                    Text("确认后先保存到本机，联网后同步。可以在设备页移除每日汇总；已生成的 AI 报告和分析输入仍会保留。").bojiType(.label).foregroundStyle(.secondary)
                }
            }.clubListSurface()
            .navigationTitle(request.allowsLink ? "核对健康与训练" : "核对健康数据").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消，不分享") { dismiss() }.disabled(submitting) } }
            .safeAreaInset(edge:.bottom) {
                VStack(alignment:.leading,spacing: BojiLayout.inline) {
                if linkingID != nil, let selected {
                    Text("将关联：\(selected.name)").bojiType(.caption).lineLimit(2)
                    Text("\(selected.start.formatted(date:.abbreviated,time:.shortened))–\(selected.end.formatted(date:.abbreviated,time:.shortened)) · \(selected.source.name)")
                        .bojiType(.label).foregroundStyle(.secondary).lineLimit(2)
                }
                Button {
                    guard !submitting, !needsSelection, issue == nil else { return }
                    submitting = true
                    if store.saveHealthAndLink(request,workoutID:linkingID) { onSaved?(); dismiss() }
                    else { error = store.takeMessage(fallback: "保存失败，请重试。"); submitting = false }
                } label: {
                    Text(linkingID == nil ? "同意分享，用于复盘与趋势解读" : "同意分享并关联这次训练").bojiFont(.exerciseName).frame(maxWidth:.infinity)
                }
                .buttonStyle(PrimaryButton()).disabled(submitting || needsSelection || validationIssue != nil)
                }
                .padding(.horizontal, ClubUI.pageInset).padding(.vertical, BojiLayout.rowGap).background(.regularMaterial)
            }
            .onAppear {
                guard store.editingAccountID == request.ownerID else { dismiss(); return }
                guard !initialized else { return }; initialized = true
                selectedID = HealthShareConsent.initialWorkoutID(request,day:day)
                shareOnly = !request.allowsLink || workouts.isEmpty
            }
            .onChange(of:store.editingAccountID) { _, id in if id != request.ownerID { dismiss() } }
        }
    }
}

/// Always visible, including before the user enables workout sharing.
struct WorkoutHealthSyncCard: View {
    let date: Date
    let sessionID: UUID
    let ownerID: Int
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var health: HealthDataService
    @State private var pending: ConfirmedWorkoutSnapshot?
    @State private var busy = false
    @State private var message: String?
    @State private var written = false
    private var snapshot: ConfirmedWorkoutSnapshot? {
        guard store.editingAccountID == ownerID else { return nil }
        return .make(owner: ownerID, date: date, sessionID: sessionID, day: store.log(for: date))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: BojiLayout.inline) {
            Label("Apple 健康", systemImage: "heart.text.square").bojiType(.bodyStrong)
            if ownerID < 0 {
                Button("连接并同步本次训练") {}.buttonStyle(SecondaryButton()).disabled(true)
                Text("预览模式不请求权限或写入 Apple 健康。")
                    .bojiType(.caption).foregroundStyle(.secondary)
            } else if let snapshot {
                if snapshot.linkedDeviceWorkoutID != nil {
                    Label("已关联设备训练", systemImage: "checkmark.circle").bojiType(.secondary)
                } else if written || health.hasWrittenWorkout(sessionID) {
                    Label("本次训练已写入", systemImage: "checkmark.circle").bojiType(.secondary)
                } else if !snapshot.canExport {
                    Text("这场训练没有可靠的起止时间，暂不能写入。")
                        .bojiType(.label).foregroundStyle(.secondary)
                } else {
                    Button(busy ? "正在处理…" : health.writeWorkoutsEnabled ? "同步本次训练" : "连接并同步本次训练") {
                        Task { await prepare(snapshot) }
                    }.buttonStyle(SecondaryButton()).disabled(busy)
                    Text("只写入本场训练时段；已有手表记录时请在设备与健康中核对关联。")
                        .bojiType(.caption).foregroundStyle(.secondary)
                }
            } else { Text("本次记录有变化，请重新核对训练。 ").bojiType(.label).foregroundStyle(.secondary) }
            if let message { Text(message).bojiType(.label).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            if let captured = pending {
                ClubNavigationStack132 {
                    VStack(alignment: .leading, spacing: BojiLayout.blockGap) {
                        Text("加入 iOS 健身记录").bojiType(.section)
                        Text("本次已登记 \(captured.completedSets) 组。仅同步这场训练的实际时段与完成信息。")
                        Text("如果 Apple Watch 或其他 App 已记录同一场训练，请返回核对并关联，避免重复记录。")
                            .bojiType(.secondary).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Button("确认加入") { pending = nil; Task { await export(captured) } }.buttonStyle(PrimaryButton())
                        Button("返回核对") { pending = nil }.buttonStyle(SecondaryButton())
                    }.padding(BojiLayout.Rhythm.headerToContent).navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { pending = nil } } }
                }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
            }
        }
        .onChange(of: store.editingAccountID) { _, _ in pending = nil; message = nil; written = false }
    }
    private func prepare(_ captured: ConfirmedWorkoutSnapshot) async {
        guard snapshot == captured else { message = "训练有变化，请重新核对。"; return }
        busy = true; defer { busy = false }
        if !health.writeWorkoutsEnabled { await health.setWorkoutWritingEnabled(true) }
        guard !Task.isCancelled, snapshot == captured else { return }
        guard health.writeWorkoutsEnabled else { message = health.message ?? "未开启训练写入，可以稍后再试。"; return }
        pending = captured
    }
    private func export(_ captured: ConfirmedWorkoutSnapshot) async {
        guard snapshot == captured, let start = captured.startedAt, let end = captured.endedAt else { message = "训练有变化，请重新核对。"; return }
        busy = true; defer { busy = false }
        do {
            let result = try await health.writeConfirmedWorkout(sessionID: captured.sessionID, start: start,
                end: end, completedSets: captured.completedSets, expectedOwner: captured.ownerID, pauseIntervals: captured.pauseIntervals ?? [])
            guard snapshot == captured else { return }
            written = true; message = result
        } catch { if store.editingAccountID == captured.ownerID { message = AppErrorText.message(error) } }
    }
}
