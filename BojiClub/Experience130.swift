import SwiftUI
import UIKit

@MainActor enum AccountDiagnostics130 {
    private static var owner: Int?
    static func activate(_ id: Int) { owner = id }
    private static var key: String { "boji.diagnostics130.\(owner.map(String.init) ?? "device")" }
    static func record(_ event: String, detail: String = "") {
        var entries = UserDefaults.standard.stringArray(forKey: key) ?? []
        // Only controlled codes/routes, never request bodies or credentials.
        entries.append(ISO8601DateFormatter().string(from: Date()) + " · " + event + " · " + String(detail.prefix(100)))
        UserDefaults.standard.set(Array(entries.suffix(40)), forKey: key)
    }
    static var entries: [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }
    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
    static func erase(owner id: Int) { UserDefaults.standard.removeObject(forKey: "boji.diagnostics130.\(id)") }
}

@MainActor enum SubmittedDraftClears130 {
    private static func key(_ owner: Int) -> String { "boji.sent-draft130.\(owner)" }
    static func claim(owner: Int, messageID: String) -> Bool {
        var ids = UserDefaults.standard.stringArray(forKey: key(owner)) ?? []
        guard !ids.contains(messageID) else { return false }
        ids.append(messageID); UserDefaults.standard.set(Array(ids.suffix(200)), forKey: key(owner))
        return true
    }
    static func erase(owner: Int) { UserDefaults.standard.removeObject(forKey: key(owner)) }
}

enum BojiCopy130 {
    static func isStep(_ value: String) -> Bool {
        !value.isEmpty && !value.unicodeScalars.contains { $0.isASCII && CharacterSet.letters.contains($0) }
    }
}

struct ClubReply130: View {
    let text: String
    var streaming = false
    @EnvironmentObject private var store: AppStore
    @State private var expanded = false
    @State private var displayedCount: Int = 0

    private var activeText: String {
        guard streaming else { return text }
        if displayedCount <= 0 { return "" }
        if displayedCount >= text.count { return text }
        let index = text.index(text.startIndex, offsetBy: min(displayedCount, text.count))
        return String(text[..<index])
    }

    private var entities: [String] {
        let pattern = #"\d+(?:\.\d+)?\s*(?:kg|公斤|千克|千卡|kcal|克|分钟|秒|组|次)|\d{1,2}:\d{2}|周[一二三四五六日天]"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        let values = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
        var seen = Set<String>()
        return Array(values.filter { seen.insert($0).inserted }.prefix(6))
    }
    private func highlighted(_ source: String) -> AttributedString {
        var result = (try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(source)
        let names = store.log(for: Date()).exercises.map(\.name) + ["深蹲", "卧推", "硬拉", "俯卧撑", "引体向上"]
        for value in Array(Set(entities + names)).prefix(30) {
            if let range = result.range(of: value) { result[range].backgroundColor = BojiColor.brandMist; result[range].font = .body.weight(.semibold) }
        }
        return result
    }
    var body: some View {
        VStack(alignment: .leading, spacing: BojiLayout.rowGap) {
            if !streaming && entities.count >= 2 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: BojiLayout.inline) {
                        ForEach(entities, id: \.self) { value in
                            Text(value).bojiType(.secondary).padding(.horizontal, BojiLayout.inline).padding(.vertical, BojiLayout.tight)
                                .foregroundStyle(BojiColor.textPrimary).background(BojiColor.brandMist, in: Capsule())
                        }
                    }
                }.accessibilityLabel("回答中的关键数据")
            }
            let targetText = streaming ? activeText : (!expanded && text.count > 650 ? String(text.prefix(500)) + "…" : text)
            HStack(alignment: .bottom, spacing: 0) {
                Text(highlighted(targetText))
                    .bojiType(.body).lineSpacing(6).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !streaming && text.count > 650 {
                Button(expanded ? "收起详细分析" : "展开详细分析") { expanded.toggle() }.bojiType(.secondary)
            }
        }
        .task(id: "\(text.count)-\(streaming)") {
            guard streaming else {
                displayedCount = text.count
                return
            }
            if displayedCount > text.count {
                displayedCount = text.count
            }
            while displayedCount < text.count && !Task.isCancelled {
                let lag = text.count - displayedCount
                let step = lag > 80 ? 4 : (lag > 25 ? 2 : 1)
                displayedCount = min(text.count, displayedCount + step)
                let delayMs: UInt64 = step == 1 ? 22 : 12
                try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
            }
        }
        .contextMenu { Button("复制完整回答") { UIPasteboard.general.string = text } }
    }
}

struct SettingsHub130: View {
    @EnvironmentObject private var account: AccountService
    @State private var showWalkthrough = false
    var body: some View {
        List {
            Section {
                NavigationLink { AccountSettings132().clubPushDestination132() } label: { Label("账号", systemImage: "person.crop.circle") }
                NavigationLink { MembershipView().clubPushDestination132() } label: { Label("会员与订阅", systemImage: "crown") }
            }
            Section("偏好") {
                NavigationLink { NotificationSettingsView().clubPushDestination132() } label: { Text("通知与提醒") }
                NavigationLink { ClubAISettingsView().clubPushDestination132() } label: { Text("跟进") }
            }
            Section("数据与隐私") {
                NavigationLink { HealthConnectionsView(date: Date()).clubPushDestination132() } label: { Text("健康与设备") }
                NavigationLink { CloudStorageUsageView().clubPushDestination132() } label: { Text("空间与同步") }
                NavigationLink { ClubCloudPrivacyView130().clubPushDestination132(ownsNavigationContainer: false) } label: { Text("AI 与隐私") }
            }
            Section("帮助") {
                Button {
                    showWalkthrough = true
                } label: {
                    HStack {
                        Text("重温新用户引导")
                        Spacer()
                        Image(systemName: "sparkles")
                            .bojiType(.label)
                            .foregroundStyle(BojiColor.brandAccent)
                    }
                }
                .foregroundStyle(BojiColor.textPrimary)
                NavigationLink { MemberFeedbackHub128().clubPushDestination132(ownsNavigationContainer: false) } label: { Text("意见反馈") }
                NavigationLink { ClubUsageGuideView(firstVisitAccountID: account.user?.id).clubPushDestination132() } label: { Text("使用帮助") }
                NavigationLink { AboutSettings132() } label: { Text("关于薄肌俱乐部") }
            }
        }.clubManagementList132()
            .navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
            .fullScreenCover(isPresented: $showWalkthrough) {
                FirstLaunchWalkthroughView(isPresented: $showWalkthrough)
            }
    }
}

private struct SettingsRoute130: Identifiable { let id: String }

private struct ClubCloudPrivacyView130: View {
    @EnvironmentObject private var ai: AIService
    var body: some View {
        Form {
            Section {
                AIPrivacyConsentControls130()
            } footer: { Text("主动发送的文字、照片和选中记录用于云端 AI 分析。关闭后仍可手动记录。") }
            Section {
                NavigationLink { ClubActionPreferencesView().clubPushDestination132() } label: { Text("个人资料与授权") }
                NavigationLink { LegalDocumentView(document: .privacy).clubPushDestination132() } label: { Text("隐私政策") }
                NavigationLink { LegalDocumentView(document: .aiNotice).clubPushDestination132() } label: { Text("AI 服务说明") }
                NavigationLink { LegalDocumentView(document: .healthDisclaimer).clubPushDestination132() } label: { Text("健康与运动风险提示") }
            }
        }.clubManagementList132().navigationTitle("AI 与隐私")
    }
}

struct DiagnosticsView130: View {
    @EnvironmentObject private var account: AccountService
    @EnvironmentObject private var store: AppStore
    @State private var events = AccountDiagnostics130.entries
    var body: some View {
        List {
            Section {
                LabeledContent("版本", value: AboutSettings132.version)
                LabeledContent("账号", value: account.user == nil ? "未登录" : "已登录")
                Text(store.syncStatus.label)
                Button("重新同步记录") { Task { await store.syncNow(); events = AccountDiagnostics130.entries } }
            }
            Section("诊断记录") {
                Text("只包含运行状态，不包含登录凭证、对话或照片。").bojiType(.caption).foregroundStyle(.secondary)
                ForEach(Array(events.reversed().enumerated()), id: \.offset) { _, value in Text(value).bojiType(.caption) }
                ShareLink(item: events.joined(separator: "\n")) { Label("分享诊断记录", systemImage: "square.and.arrow.up") }
                Button("清空诊断记录") { AccountDiagnostics130.clear(); events = [] }
            }
        }.clubManagementList132().navigationTitle("同步与诊断")
    }
}

private struct AIPrivacyConsentControls130: View {
    @EnvironmentObject private var ai: AIService
    @State private var explain = false
    var body: some View {
        Toggle("允许云端分析", isOn: Binding(get: { ai.routingConsentGranted }, set: { value in
            if value { explain = true } else { ai.revokeRoutingConsent() }
        })).sheet(isPresented: $explain) { AIProviderConsentSheet() }
    }
}

final class ClubComposerTextView130: UITextView {
    var insertingLineBreak130 = false
    override var keyCommands: [UIKeyCommand]? {
        (super.keyCommands ?? []) + [UIKeyCommand(input: "\r", modifierFlags: .shift, action: #selector(newline130))]
    }
    @objc private func newline130() { insertLineBreak131() }
    func insertLineBreak131() {
        insertingLineBreak130 = true; defer { insertingLineBreak130 = false }
        insertText("\n")
    }
}

struct WeeklyRecurrence130: Codable, Equatable {
    var enabled: Bool
    var start: String
    var days: [ManualPlanDay] // Monday ... Sunday, independent of start date.
    var valid: Bool { days.count == 7 && ClubDates.date(fromKey: start) != nil && days.allSatisfy { $0.movements.count <= 30 && $0.movements.allSatisfy(\.valid) } }
}

enum WeeklyPlanRules130 {
    static func index(_ date: Date) -> Int { (ClubDates.calendar.component(.weekday, from: date) + 5) % 7 }
    static func draft(days: [ManualPlanDay], start: Date, title: String, id: UUID = UUID()) -> ManualPlanDraft {
        var draft = ManualPlanDraft(); draft.id = id; draft.title = title; draft.start = ClubDates.key(start); draft.duration = 28
        for offset in 0..<28 {
            if let date = ClubDates.calendar.date(byAdding: .day, value: offset, to: start), days.count == 7 { draft.days[offset] = days[index(date)] }
        }
        return draft
    }
}

struct WeeklyPlanDraft130: Codable {
    var days: [ManualPlanDay]
    var start: Date
    var title: String
    var repeats: Bool
    var identity: UUID
}
@MainActor enum WeeklyPlanDraftStore130 {
    private static func url(owner: Int, template: UUID?) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("weekly130-\(owner)-\(template?.uuidString ?? "new").json")
    }
    static func load(owner: Int, template: UUID?) throws -> WeeklyPlanDraft130? {
        let path = url(owner: owner, template: template)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let value = try JSONDecoder().decode(WeeklyPlanDraft130.self, from: Data(contentsOf: path))
        guard value.days.count == 7 else { throw CocoaError(.fileReadCorruptFile) }
        return value
    }
    static func save(_ value: WeeklyPlanDraft130, owner: Int, template: UUID?) throws {
        let path = url(owner: owner, template: template)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: path, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    static func remove(owner: Int, template: UUID?) { try? FileManager.default.removeItem(at: url(owner: owner, template: template)) }
    @discardableResult static func erase(owner: Int) -> Bool {
        let directory = url(owner: owner, template: nil).deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: directory.path) else { return true }
        do {
            for path in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where path.lastPathComponent.hasPrefix("weekly130-\(owner)-") { try FileManager.default.removeItem(at: path) }
            return true
        } catch { return false }
    }
}

struct WeeklyPlanCreator130: View {
    var startDate = Date()
    var initialTemplate: ManualPlanTemplate? = nil
    var onSaved: (() -> Void)? = nil
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var committed = false
    @State private var days = Array(repeating: ManualPlanDay(), count: 7)
    @State private var start = Date()
    @State private var title = "我的每周训练"
    @State private var repeats = true
    @State private var owner: Int?
    @State private var identity = UUID()
    @State private var loaded = false
    @State private var conflict = false
    @State private var conflictDates: [String] = []
    @State private var baseline: [String: DayLog] = [:]
    @State private var error: String?
    private let weekdays = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
    private var draft: ManualPlanDraft { WeeklyPlanRules130.draft(days: days, start: start, title: title, id: identity) }
    var body: some View {
        ClubNavigationStack132 {
            Form {
                Section {
                    TextField("计划名称", text: $title)
                    DatePicker("开始日期", selection: $start, in: ClubDates.calendar.startOfDay(for: Date())..., displayedComponents: .date)
                    Toggle("每周自动重复", isOn: $repeats)
                }
                Section("安排一周") {
                    ForEach(0..<7, id: \.self) { index in
                        NavigationLink {
                            WeeklyDayEditor130(day: $days[index], title: weekdays[index])
                        } label: {
                            HStack {
                                Text(weekdays[index]).frame(width: 44, alignment: .leading)
                                Text(days[index].movements.isEmpty ? "休息" : (days[index].title.isEmpty ? "\(days[index].movements.count) 个动作" : days[index].title))
                                    .foregroundStyle(days[index].movements.isEmpty ? .secondary : .primary)
                                Spacer()
                            }.frame(minHeight: 44)
                        }
                        .contextMenu {
                            ForEach((0..<7).filter { $0 != index }, id: \.self) { target in
                                Button("复制到\(weekdays[target])") { var copy = days[index]; for i in copy.movements.indices { copy.movements[i].id = UUID() }; days[target] = copy }
                            }
                        }
                    }
                }
                Section("安排预览") {
                    Text("从 \(ClubDates.label(start)) 起，先安排未来 4 周。\(repeats ? "之后每周自动续排，可随时暂停。" : "4 周后结束。")").bojiType(.secondary)
                    DisclosureGroup("查看具体日期") {
                        ForEach(0..<28, id: \.self) { offset in
                            if let date = ClubDates.calendar.date(byAdding: .day, value: offset, to: start) {
                                let day = days[WeeklyPlanRules130.index(date)]
                                LabeledContent(ClubDates.label(date, format: "M月d日 EEE"), value: day.movements.isEmpty ? "休息" : "\(day.movements.count) 个动作").bojiType(.secondary)
                            }
                        }
                    }
                    if initialTemplate != nil { Text("修改从所选日期起生效，已开始和已完成的训练保留。").bojiType(.caption).foregroundStyle(.secondary) }
                }
                Section {
                    DisclosureGroup("高级安排") {
                        NavigationLink("练休循环、按日期安排与模板") { ManualPlanView(startDate: start) }
                    }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }.clubManagementList132()
            .navigationTitle(initialTemplate == nil ? "排每周计划" : "改每周安排")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .safeAreaInset(edge: .bottom) { Button("保存计划") { prepare() }.buttonStyle(.borderedProminent).frame(maxWidth: .infinity).padding().clubGlassEffect(in: RoundedRectangle(cornerRadius: BojiRadius.input, style: .continuous)) }
            .onAppear {
                guard !loaded else { return }; loaded = true; owner = store.editingAccountID
                start = max(ClubDates.calendar.startOfDay(for: Date()), startDate)
                if let template = initialTemplate, let recurrence = template.recurrence130, recurrence.valid {
                    days = recurrence.days; title = template.draft.title; repeats = recurrence.enabled
                }
                if let owner {
                    do { if let saved = try WeeklyPlanDraftStore130.load(owner: owner, template: initialTemplate?.id) {
                        days = saved.days; title = saved.title; repeats = saved.repeats; identity = saved.identity
                        start = max(ClubDates.calendar.startOfDay(for: Date()), saved.start)
                    } } catch { self.error = "上次草稿暂时无法读取，请核对后重新保存。" }
                }
            }
            .onChange(of: days) { _, _ in preserveDraft() }
            .onChange(of: start) { _, _ in preserveDraft() }
            .onChange(of: title) { _, _ in preserveDraft() }
            .onChange(of: repeats) { _, _ in preserveDraft() }
            .onChange(of: scenePhase) { _, phase in if phase != .active { preserveDraft() } }
            .onDisappear { preserveDraft() }
            .onChange(of: store.editingAccountID) { _, value in if value != owner { dismiss() } }
            .confirmationDialog("替换这些日期的未开始安排？", isPresented: $conflict, titleVisibility: .visible) {
                Button("替换并保存", role: .destructive) { commit() }
                Button("返回修改日期", role: .cancel) { }
            } message: { Text(conflictDates.joined(separator: "、") + "。已开始和已完成的训练会保留。") }
        }
    }
    private func preserveDraft() {
        guard loaded, !committed, let owner, owner == store.editingAccountID else { return }
        do { try WeeklyPlanDraftStore130.save(.init(days: days, start: start, title: title, repeats: repeats, identity: identity), owner: owner, template: initialTemplate?.id) }
        catch { self.error = "草稿尚未保存，请保持此页并重试。" }
    }
    private func prepare() {
        guard owner == store.editingAccountID else { return }
        if let problem = draft.validation() { error = problem; return }
        baseline = Dictionary(uniqueKeysWithValues: (0..<28).compactMap { offset in draft.dateKey(offset: offset).map { ($0, store.state.days[$0] ?? DayLog()) } })
        conflictDates = baseline.keys.filter { key in
            let day = baseline[key] ?? DayLog()
            return (!day.exercises.isEmpty || day.planCycle != nil) && !PlanAdoptionRules.isProtected(day)
        }.sorted()
        if conflictDates.isEmpty { commit() } else { conflict = true }
    }
    private func commit() {
        guard owner == store.editingAccountID else { return }
        guard store.saveWeeklyPlan130(draft: draft, weekdays: days, repeats: repeats, baseline: baseline, replacing: initialTemplate?.id) else { error = store.takeMessage(); return }
        committed = true
        if let owner { WeeklyPlanDraftStore130.remove(owner: owner, template: initialTemplate?.id) }
        onSaved?(); dismiss()
    }
}

private struct WeeklyDayEditor130: View {
    @Binding var day: ManualPlanDay
    let title: String
    @EnvironmentObject private var store: AppStore
    @State private var library = false
    @State private var selection: [LibraryExercise] = []
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BojiLayout.cardInset) {
                TextField("训练名称（可选）", text: $day.title).textFieldStyle(.roundedBorder)
                if day.movements.isEmpty { Text("暂时休息；添加动作后就是训练日。").foregroundStyle(.secondary) }
                ForEach($day.movements) { $movement in
                    ClubCard {
                        ManualMovementEditor(movement: $movement, moveUp: { move(movement.id, by: -1) }, moveDown: { move(movement.id, by: 1) }, remove: { day.movements.removeAll { $0.id == movement.id } })
                    }
                }
                Button("从动作库添加") { selection = []; library = true }.buttonStyle(.borderedProminent).disabled(day.movements.count >= 30)
                if !day.movements.isEmpty { Button("设为休息日", role: .destructive) { day = ManualPlanDay() } }
            }.padding(BojiLayout.blockGap)
        }.clubManagementList132().navigationTitle(title)
        .sheet(isPresented: $library) {
            ClubNavigationStack132 {
                ExerciseLibraryView(date: Date(), selectionAction: { item in
                    if let index = selection.firstIndex(where: { $0.id == item.id }) { selection.remove(at: index) }
                    else if selection.count + day.movements.count < 30 { selection.append(item) }
                }, selectedIDs: Set(selection.map(\.id)), added: {})
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { library = false } } }
                .safeAreaInset(edge: .bottom) { Button("添加 \(selection.count) 个动作") { add() }.buttonStyle(.borderedProminent).disabled(selection.isEmpty).padding() }
            }
        }
    }
    private func move(_ id: UUID, by offset: Int) {
        guard let i = day.movements.firstIndex(where: { $0.id == id }), day.movements.indices.contains(i + offset) else { return }
        day.movements.swapAt(i, i + offset)
    }
    private func add() {
        for item in selection {
            let sets = item.customID.flatMap { id in store.customExercises.first(where: { $0.id == id })?.exercise().sets } ?? ExerciseMeasurement.initialSets(name: item.displayName, query: item.name, recordingUnit: item.suggestedRecordingUnit, trainingType: item.trainingTypeZH)
            let first = sets.first ?? TrainingSet()
            day.movements.append(ManualPlanMovement(name: item.displayName, muscle: item.muscleLabel, query: item.customID == nil ? item.name : nil, libraryID: item.customID == nil ? item.id : nil, customID: item.customID, unit: first.durationSeconds == nil ? "次" : "秒", count: sets.count, weight: first.weight, reps: first.reps, seconds: first.durationSeconds ?? 30))
        }
        day.placeholder = nil; library = false
    }
}

@MainActor enum MutationReceipts130 {
    static var pending: [Int: [JSONValue]] = [:]
    static func capture(_ data: Data, owner: Int) {
        guard let receipt = try? JSONDecoder().decode(JSONValue.self, from: data), receipt.object?["status"]?.string == "succeeded", receipt.object?["diff"]?.object != nil else { return }
        pending[owner, default: []].append(receipt)
    }
}
