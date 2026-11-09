import SwiftUI

/// 引导（首次）——全页面新蓝图 §十四（2026-11-09 推倒重来）：只有 3 步。
/// 1 你的目标（3 选 1）→ 2 每周练几次（4 选 1）→ 3 完成（生成第一周计划，落到首页）。
/// 不给教程、不给权限墙；昵称给默认值（可在我的 → 账号随时改）。
/// 第 3 步先排计划再进首页：生成面板关闭即落到「今天」，计划已在。
struct FirstRun3StepView: View {
    @EnvironmentObject private var account: AccountService
    @EnvironmentObject private var store: AppStore
    @StateObject private var editor = ProfileFactsEditor()
    @State private var step = 1
    @State private var goalChoice = ""
    @State private var daysChoice = 0
    @State private var busy = false
    @State private var errorText: String?
    @State private var showPlanGenerator = false

    /// §十四 三个大选项 → 资料字段「主要目标」的标准取值（口径与资料表单一致）。
    private let goalOptions: [(label: String, value: String)] = [
        ("减脂", "减脂瘦身"),
        ("增肌", "增肌塑形"),
        ("保持", "养成运动习惯"),
    ]

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case 1: goalStep
                case 2: frequencyStep
                default: doneStep
                }
            }
            .background { ClubBackground() }
        }
        .sheet(isPresented: $showPlanGenerator, onDismiss: {
            account.enterClub()
        }) {
            NavigationStack {
                PlanView(date: Date(), initialMode: "generate_plan")
            }
        }
        .task(id: account.user?.id) { await editor.load(account: account) }
    }

    private func stepHeader(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: BojiLayout.Rhythm.eyebrowToTitle) {
            Text("第 \(step) 步 / 共 3 步")
                .bojiType(.caption)
                .foregroundStyle(BojiColor.textTertiary)
            Text(title)
                .bojiType(.title)
                .foregroundStyle(BojiColor.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("first-run-step-header")
    }

    private var goalStep: some View {
        VStack(alignment: .leading, spacing: BojiLayout.blockGap) {
            stepHeader("你的目标")
            VStack(spacing: BojiLayout.cardGap) {
                ForEach(goalOptions, id: \.label) { option in
                    choiceRow(option.label, selected: goalChoice == option.label) {
                        goalChoice = option.label
                    }
                }
            }
            Spacer()
            primaryButton("下一步", enabled: !goalChoice.isEmpty) {
                BojiHaptics.selection()
                BojiSound.play(.tap)
                step = 2
            }
        }
        .padding(BojiLayout.pageInset)
    }

    private var frequencyStep: some View {
        VStack(alignment: .leading, spacing: BojiLayout.blockGap) {
            stepHeader("每周练几次")
            VStack(spacing: BojiLayout.cardGap) {
                ForEach([2, 3, 4, 5], id: \.self) { count in
                    choiceRow("\(count) 次", selected: daysChoice == count) {
                        daysChoice = count
                    }
                }
            }
            Spacer()
            primaryButton("下一步", enabled: daysChoice > 0) {
                BojiHaptics.selection()
                BojiSound.play(.tap)
                step = 3
            }
        }
        .padding(BojiLayout.pageInset)
    }

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: BojiLayout.blockGap) {
            stepHeader("完成")
            Text("这就去排你的第一周计划。排好就落在「今天」，随时能改。")
                .bojiType(.body15)
                .foregroundStyle(BojiColor.textSecondary)
            Spacer()
            primaryButton(busy ? "正在保存…" : "生成第一周计划", enabled: !busy) {
                Task { await finish(generatePlan: true) }
            }
            Button {
                Task { await finish(generatePlan: false) }
            } label: {
                Text("先随便看看")
                    .bojiType(.body15)
                    .tint(ClubBrand.accent)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .frame(minHeight: BojiLayout.controlHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(busy)
            if let errorText {
                Text(errorText)
                    .bojiType(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(BojiLayout.pageInset)
    }

    private func choiceRow(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            BojiHaptics.selection()
            BojiSound.play(.tap)
            action()
        } label: {
            HStack {
                Text(title)
                    .bojiType(.data)
                    .foregroundStyle(BojiColor.textPrimary)
                Spacer()
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(ClubBrand.accent)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: BojiLayout.rowHeight)
            .padding(.horizontal, BojiLayout.cardInset)
            .background(BojiColor.inputSurface, in: RoundedRectangle(cornerRadius: BojiLayout.Radius.control, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: BojiLayout.Radius.control, style: .continuous)
                    .stroke(selected ? ClubBrand.accent : BojiColor.divider, lineWidth: BojiLayout.hairline)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("first-run-choice-" + title)
    }

    private func primaryButton(_ title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .frame(maxWidth: .infinity, minHeight: BojiLayout.actionHeight)
                .contentShape(Rectangle())
        }
        .clubNativeGlassButton(prominent: true)
        .accessibilityIdentifier("first-run-primary")
        .disabled(!enabled)
    }

    /// §十四 第 3 步：落资料（目标/频率/默认昵称）→ 完成新手标记 → 排计划 → 落到首页。
    @MainActor private func finish(generatePlan: Bool) async {
        guard !busy else { return }
        busy = true
        errorText = nil
        defer { busy = false }
        let owner = account.user?.id
        var changes: [[String: Any]] = []
        if !goalChoice.isEmpty,
           let value = goalOptions.first(where: { $0.label == goalChoice })?.value,
           store.state.profile.goal != value {
            changes.append(["field": "goal", "value": value, "unit": NSNull()])
        }
        if daysChoice > 0 {
            changes.append(["field": "days_per_week", "value": daysChoice, "unit": "days_per_week"])
        }
        if !store.state.profile.isFactConfirmed("nickname") {
            changes.append(["field": "nickname", "value": "薄肌成员", "unit": NSNull()])
        }
        do {
            if !changes.isEmpty {
                if account.isPreviewAccount {
                    var facts: [String: JSONValue] = [:]
                    for change in changes {
                        if let key = change["field"] as? String { facts[key] = JSONValue.any(change["value"] ?? NSNull()) }
                    }
                    var metadata = store.state.profile.factState ?? [:]
                    metadata.merge(facts.mapValues { _ in ProfileFactMeta(sourceKind: "confirmed", confirmedAt: nil, revision: nil) }) { _, updated in updated }
                    store.applyV2ProfileFacts(facts, meta: metadata)
                } else {
                    guard await editor.apply(changes: changes, account: account) else {
                        errorText = editor.error ?? "资料未保存，请重试。"
                        return
                    }
                    editor.applyFacts(to: store)
                }
            }
            try await account.completeOnboarding()
            await account.refreshAccount()
            guard owner == account.user?.id else { return }
            if generatePlan {
                showPlanGenerator = true
            } else {
                account.enterClub()
            }
        } catch {
            errorText = AppErrorText.message(error)
        }
    }
}
