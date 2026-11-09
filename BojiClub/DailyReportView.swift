import SwiftUI

struct DailyReportView: View {
    var initialDateKey: String? = nil
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var ai: AIService
    @EnvironmentObject private var account: AccountService
    @Environment(\.dismiss) private var dismiss

    @State private var currentDate: Date = Date()
    @State private var isGenerating: Bool = false
    @State private var errorMessage: String? = nil
    @State private var shareDraft: ShareDraft? = nil

    private var currentDateKey: String {
        ClubDates.key(currentDate)
    }

    private var todayLog: DayLog {
        store.log(for: currentDate)
    }

    private var metrics: AIDailyMetrics {
        // Priority: model validated metrics -> deterministic on-device metrics
        if let job = activeJob, let m = job.result?.metrics {
            return m
        }
        return todayLog.deterministicMetrics(dateKey: currentDateKey)
    }

    private var activeJob: AILocalJob? {
        let deleted = Set(store.state.deletedAIJobIDs ?? [])
        return ai.jobs.first {
            $0.request.kind == "report" &&
            $0.request.date == currentDateKey &&
            $0.status == "succeeded" &&
            !deleted.contains($0.id)
        }
    }

    private var pendingJob: AILocalJob? {
        ai.jobs.first {
            $0.request.kind == "report" &&
            $0.request.date == currentDateKey &&
            !$0.isTerminal
        }
    }

    private var isFuture: Bool {
        ClubDates.isFuture(currentDate)
    }

    private var canGoNext: Bool {
        !ClubDates.calendar.isDateInToday(currentDate) && !isFuture
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BojiLayout.blockGap) {
                // 日期切换器
                dateNavigationBar

                // 蓝图 §九（2026-11-09 推倒重来）：一句话结论 → 三个数 → 可应用建议 → 完整分析
                conclusionBlock
                dailyNumbersRow

                // 明天可以这样（每条可应用）
                recommendationsSection

                // 完整分析（AI 正文，读的）
                aiAnalysisSection

                // 底部操作区
                bottomActionBar
            }
            .padding(.horizontal, BojiLayout.pageInset)
            .padding(.vertical, BojiLayout.cardInset)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("日报")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if let result = activeJob?.result {
                    Button {
                        prepareShare(result)
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("分享日报")
                }
            }
        }
        .sheet(item: $shareDraft) { draft in
            ShareCardPreview(draft: draft)
        }
        .confirmationDialog("把建议应用到目标和计划？", isPresented: $confirmApplyAll, titleVisibility: .visible) {
            Button("应用") {
                for suggestion in suggestions where !appliedSuggestionIDs.contains(suggestion.id) {
                    applySuggestion(suggestion)
                }
            }
            Button("取消", role: .cancel) {}
        }
        .sheet(isPresented: $showPlanAdjust) {
            PlanCreationSheet(date: ClubDates.calendar.date(byAdding: .day, value: 1, to: currentDate) ?? currentDate)
        }
        .onAppear {
            if let initial = initialDateKey, let d = ClubDates.date(fromKey: initial) {
                currentDate = d
            }
        }
    }

    // MARK: - 日期导航栏
    private var dateNavigationBar: some View {
        HStack {
            Button {
                stepDate(by: -1)
            } label: {
                Image(systemName: "chevron.left")
                    .bojiType(.secondary)
                    .foregroundStyle(BojiColor.textSecondary)
                    .frame(width: 36, height: 36).contentShape(Rectangle().inset(by: -4))
                    .background(BojiColor.subtleSurface, in: Circle())
            }
            .accessibilityLabel("前一天")

            Spacer()

            VStack(spacing: 0) {
                Text(ClubDates.label(currentDate, format: "yyyy年M月d日 EEEE"))
                    .bojiType(.body)
                    .foregroundStyle(BojiColor.textPrimary)
                if ClubDates.calendar.isDateInToday(currentDate) {
                    Text("今天")
                        .bojiType(.caption)
                        .foregroundStyle(BojiColor.brandGold)
                }
            }

            Spacer()

            Button {
                stepDate(by: 1)
            } label: {
                Image(systemName: "chevron.right")
                    .bojiType(.secondary)
                    .foregroundStyle(canGoNext ? BojiColor.textSecondary : BojiColor.textTertiary.opacity(0.4))
                    .frame(width: 36, height: 36).contentShape(Rectangle().inset(by: -4))
                    .background(BojiColor.subtleSurface, in: Circle())
            }
            .disabled(!canGoNext)
            .accessibilityLabel("后一天")
        }
        .padding(.vertical, BojiLayout.inline)
        .padding(.horizontal, BojiLayout.rowGap)
        .background(BojiColor.subtleSurface, in: RoundedRectangle(cornerRadius: BojiRadius.inner, style: .continuous))
    }

    private func stepDate(by days: Int) {
        if let newDate = ClubDates.calendar.date(byAdding: .day, value: days, to: currentDate) {
            if days > 0 && ClubDates.isFuture(newDate) { return }
            BojiHaptics.tick()
            currentDate = newDate
        }
    }

    // MARK: - 确定性数据看板
    private var dailyMetricsSection: some View {
        VStack(alignment: .leading, spacing: BojiLayout.rowGap) {
            HStack {
                Image(systemName: "chart.bar.xaxis")
                    .foregroundStyle(BojiColor.brandGold)
                Text("今日客观数据")
                    .bojiType(.body)
                    .foregroundStyle(BojiColor.textPrimary)
                Spacer()
                Text("确定性程序核算")
                    .bojiType(.caption)
                    .foregroundStyle(BojiColor.textTertiary)
            }

            // 训练板块
            trainingMetricCard

            // 营养板块
            nutritionMetricCard

            // 身体与活动板块
            bodyAndActivityCard
        }
    }

    private var trainingMetricCard: some View {
        VStack(alignment: .leading, spacing: BojiLayout.inline) {
            HStack {
                Label("力量训练", systemImage: "figure.strengthtraining.traditional")
                    .bojiType(.label)
                    .foregroundStyle(BojiColor.textPrimary)
                Spacer()
                if let vol = metrics.training?.total_volume_kg, vol > 0 {
                    Text("训练量 \(Int(vol)) kg·次")
                        .bojiType(.caption)
                        .foregroundStyle(BojiColor.brandGold)
                }
            }

            if let t = metrics.training, (t.completed_sets ?? 0) > 0 {
                // 指标走唯一组件（§2.6）：数字 T2 28 + 单位/标签 T5 11，跨页与首页一致
                MetricRowGroup(metrics: [
                    MetricValue(value: t.completed_exercises.map(String.init), unit: "项", label: "完成动作"),
                    MetricValue(value: t.completed_sets.map(String.init), unit: "组", label: "完成组数"),
                    t.duration_minutes.flatMap { $0 > 0 ? String($0) : nil }.map { MetricValue(value: $0, unit: "分钟", label: "训练时长") } ?? MetricValue(value: "\(t.sessions ?? 1)", unit: "次", label: "训练场次")
                ])
            } else {
                HStack {
                    Image(systemName: "bed.double")
                        .foregroundStyle(BojiColor.textTertiary)
                    Text("今天没有力量训练记录（也可能本来就是休息日）")
                        .bojiType(.label)
                        .foregroundStyle(BojiColor.textSecondary)
                }
                .padding(.vertical, BojiLayout.tight)
            }
        }
        .padding(BojiLayout.rowGap)
        .background(BojiColor.subtleSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var nutritionMetricCard: some View {
        VStack(alignment: .leading, spacing: BojiLayout.inline) {
            HStack {
                Label("饮食与能量", systemImage: "fork.knife")
                    .bojiType(.label)
                    .foregroundStyle(BojiColor.textPrimary)
                Spacer()
                if let complete = metrics.nutrition?.data_complete, complete {
                    Text("全天已记完")
                        .bojiType(.caption)
                        .foregroundStyle(.green)
                } else if metrics.nutrition?.calories != nil {
                    Text("部分记录")
                        .bojiType(.caption)
                        .foregroundStyle(BojiColor.textTertiary)
                }
            }

            if let n = metrics.nutrition, let cal = n.calories {
                MetricRowGroup(metrics: [
                    MetricValue(value: "\(Int(cal))", unit: "kcal", label: "摄入热量"),
                    MetricValue(value: (n.protein ?? 0) > 0 ? String(format: "%.0f", n.protein ?? 0) : nil, unit: "g", label: "蛋白质"),
                    MetricValue(value: (n.carbs ?? 0) > 0 ? String(format: "%.0f", n.carbs ?? 0) : nil, unit: "g", label: "碳水"),
                    MetricValue(value: (n.fat ?? 0) > 0 ? String(format: "%.0f", n.fat ?? 0) : nil, unit: "g", label: "脂肪")
                ])
            } else {
                HStack {
                    Image(systemName: "takeoutbag.and.cup.and.straw")
                        .foregroundStyle(BojiColor.textTertiary)
                    Text("今天还没记吃的")
                        .bojiType(.label)
                        .foregroundStyle(BojiColor.textSecondary)
                }
                .padding(.vertical, BojiLayout.tight)
            }
        }
        .padding(BojiLayout.rowGap)
        .background(BojiColor.subtleSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var bodyAndActivityCard: some View {
        VStack(alignment: .leading, spacing: BojiLayout.inline) {
            HStack {
                Label("身体与日常活动", systemImage: "figure.walk")
                    .bojiType(.label)
                    .foregroundStyle(BojiColor.textPrimary)
                Spacer()
            }

            // 身体与活动：走唯一指标组件，缺项整块不渲染（不再出现「— / 未记录」占位）
            MetricRowGroup(metrics: [
                MetricValue(value: metrics.body?.weight_kg.map { String(format: "%.1f", $0) }, unit: "kg", label: "今日体重"),
                MetricValue(value: (metrics.activity?.steps ?? 0) > 0 ? "\(Int(metrics.activity?.steps ?? 0))" : nil, unit: "步", label: "日常步数"),
                MetricValue(value: (metrics.activity?.active_energy_kcal ?? 0) > 0 ? "\(Int(metrics.activity?.active_energy_kcal ?? 0))" : nil, unit: "kcal", label: "活动消耗")
            ])
        }
        .padding(BojiLayout.rowGap)
        .background(BojiColor.subtleSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - AI 深度点评
    private var aiAnalysisSection: some View {
        VStack(alignment: .leading, spacing: BojiLayout.rowGap) {
            HStack {
                Image(systemName: "sparkles")
                    .foregroundStyle(BojiColor.brandGold)
                Text("今日点评")
                    .bojiType(.body)
                    .foregroundStyle(BojiColor.textPrimary)
                Spacer()
            }

            if let job = activeJob, let result = job.result {
                VStack(alignment: .leading, spacing: BojiLayout.rowGap) {
                    if let summary = result.summary, !summary.isEmpty {
                        Text(summary)
                            .bojiType(.secondary)
                            .foregroundStyle(BojiColor.textPrimary)
                            .lineSpacing(4)
                    }

                    // 亮点列表
                    if let highlights = result.highlights, !highlights.isEmpty {
                        VStack(alignment: .leading, spacing: BojiLayout.tight) {
                            Text("今日亮点")
                                .bojiType(.caption)
                                .foregroundStyle(.green)
                            ForEach(highlights, id: \.self) { item in
                                HStack(alignment: .top, spacing: BojiLayout.tight) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .bojiType(.caption)
                                        .foregroundStyle(.green)
                                        
                                    Text(item)
                                        .bojiType(.label)
                                        .foregroundStyle(BojiColor.textPrimary)
                                }
                            }
                        }
                        .padding(.top, BojiLayout.tight)
                    }

                    // 需留意的地方
                    if let obs = result.observations, !obs.isEmpty {
                        VStack(alignment: .leading, spacing: BojiLayout.tight) {
                            Text("需要留意的地方")
                                .bojiType(.caption)
                                .foregroundStyle(BojiColor.brandGold)
                            ForEach(obs, id: \.self) { item in
                                HStack(alignment: .top, spacing: BojiLayout.tight) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .bojiType(.caption)
                                        .foregroundStyle(BojiColor.brandGold)
                                        
                                    Text(item)
                                        .bojiType(.label)
                                        .foregroundStyle(BojiColor.textPrimary)
                                }
                            }
                        }
                        .padding(.top, BojiLayout.tight)
                    }

                    // 训练反馈
                    if let trainingAnalysis = result.training, !trainingAnalysis.isEmpty {
                        Divider().padding(.vertical, BojiLayout.tight)
                        VStack(alignment: .leading, spacing: BojiLayout.tight) {
                            Text("训练表现解析")
                                .bojiType(.caption)
                                .foregroundStyle(BojiColor.textSecondary)
                            Text(trainingAnalysis)
                                .bojiType(.label)
                                .foregroundStyle(BojiColor.textPrimary)
                                .lineSpacing(3)
                        }
                    }

                    // 饮食反馈
                    if let nutritionAnalysis = result.nutrition, !nutritionAnalysis.isEmpty {
                        Divider().padding(.vertical, BojiLayout.tight)
                        VStack(alignment: .leading, spacing: BojiLayout.tight) {
                            Text("营养状态评估")
                                .bojiType(.caption)
                                .foregroundStyle(BojiColor.textSecondary)
                            Text(nutritionAnalysis)
                                .bojiType(.label)
                                .foregroundStyle(BojiColor.textPrimary)
                                .lineSpacing(3)
                        }
                    }
                }
                .padding(BojiLayout.cardInset)
                .background(BojiColor.subtleSurface, in: RoundedRectangle(cornerRadius: BojiRadius.inner, style: .continuous))
            } else if pendingJob != nil {
                HStack(spacing: BojiLayout.rowGap) {
                    ProgressView()
                    Text("正在解读今日数据…")
                        .bojiType(.secondary)
                        .foregroundStyle(BojiColor.textSecondary)
                }
                .padding(BojiLayout.blockGap)
                .frame(maxWidth: .infinity, alignment: .center)
                .background(BojiColor.subtleSurface, in: RoundedRectangle(cornerRadius: BojiRadius.inner, style: .continuous))
            } else {
                VStack(spacing: BojiLayout.inline) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .bojiType(.title)
                        .foregroundStyle(BojiColor.textTertiary)
                    Text("本日尚未生成点评")
                        .bojiType(.secondary)
                        .foregroundStyle(BojiColor.textSecondary)
                    Text("完成当日训练或记录餐食后，点击下方按钮开始分析。")
                        .bojiType(.caption)
                        .foregroundStyle(BojiColor.textTertiary)
                        .multilineTextAlignment(.center)
                }
                .padding(BojiLayout.Rhythm.headerToContent)
                .frame(maxWidth: .infinity)
                .background(BojiColor.subtleSurface, in: RoundedRectangle(cornerRadius: BojiRadius.inner, style: .continuous))
            }
        }
    }

    // MARK: - 明日建议
    // MARK: - 蓝图 §九：结论、三个数、可应用建议

    /// 一句话结论（T2 28）：AI 结论优先；没有分析时用确定性分档句（不依赖运行时数据存在性）。
    private var conclusionBlock: some View {
        Text(conclusionLine)
            .bojiType(.title)
            .foregroundStyle(BojiColor.textPrimary)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var conclusionLine: String {
        if let summary = activeJob?.result?.summary, !summary.isEmpty { return summary }
        let trained = (metrics.training?.completed_sets ?? 0) > 0
        let ate = (metrics.nutrition?.calories ?? 0) > 0
        if trained && ate { return "今天练得够，也记了吃的" }
        if trained { return "今天练得够，吃少了点" }
        if ate { return "今天没练，吃得还行" }
        return "今天动静都不多，明天补上"
    }

    /// 三个数（T2 28 + T5 单位，§20.4）：训练量 / 摄入热量 / 体重；空值不渲染（P0-3）。
    private var dailyNumbersRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: BojiLayout.sectionGap) {
            numberColumn(metrics.training?.total_volume_kg.map { "\(Int($0))" }, unit: "kg·次")
            numberColumn(metrics.nutrition?.calories.map { "\(Int($0))" }, unit: "千卡")
            numberColumn(metrics.body?.weight_kg.map { $0.formatted(.number.grouping(.never).precision(.fractionLength(0...1))) }, unit: "kg")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("v2-report-numbers")
    }

    private func numberColumn(_ value: String?, unit: String) -> some View {
        Group {
            if let value, !value.isEmpty {
                VStack(alignment: .leading, spacing: BojiLayout.tight) {
                    Text(value)
                        .bojiType(.title, monospacedDigits: true)
                        .foregroundStyle(BojiColor.textPrimary)
                    Text(unit)
                        .bojiType(.caption)
                        .foregroundStyle(BojiColor.textTertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 可应用建议（§九「建议必须可应用」）：确定性生成，应用即改饮食目标 / 走计划调整。
    private struct DailySuggestion: Identifiable {
        enum Kind { case nutrition, training }
        let id: String
        let title: String
        let detail: String
        let kind: Kind
    }

    private var suggestions: [DailySuggestion] {
        var list: [DailySuggestion] = []
        if let target = store.nutritionTarget(on: currentDate), target.generalGuidanceOnly != true {
            let raised = (target.proteinMin + 10).rounded()
            list.append(DailySuggestion(
                id: "protein",
                title: "蛋白质目标上调到 \(Int(raised)) 克",
                detail: "比现在高 10 克，给明天的餐食留点余量",
                kind: .nutrition
            ))
        }
        let tomorrowKey = ClubDates.key(ClubDates.calendar.date(byAdding: .day, value: 1, to: currentDate) ?? currentDate)
        if let tomorrow = store.state.days[tomorrowKey], !tomorrow.exercises.isEmpty {
            list.append(DailySuggestion(
                id: "training",
                title: "明天的训练按状态调一调",
                detail: "睡得够就按原安排，觉得累就减点量",
                kind: .training
            ))
        }
        return Array(list.prefix(2))
    }

    @State private var appliedSuggestionIDs: Set<String> = []
    @State private var confirmApplyAll = false
    @State private var showPlanAdjust = false

    private func applySuggestion(_ suggestion: DailySuggestion) {
        switch suggestion.kind {
        case .nutrition:
            guard var target = store.nutritionTarget(on: currentDate) else { return }
            target.proteinMin = (target.proteinMin + 10).rounded()
            target.proteinMax = (target.proteinMax + 10).rounded()
            if store.applyNutritionTarget(target) {
                appliedSuggestionIDs.insert(suggestion.id)
                BojiHaptics.success()
                BojiSound.play(.setDone)
            }
        case .training:
            showPlanAdjust = true
            appliedSuggestionIDs.insert(suggestion.id)
            BojiHaptics.selection()
            BojiSound.play(.tap)
        }
    }

    private var recommendationsSection: some View {
        Group {
            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: BojiLayout.rowGap) {
                    Text("明天可以这样")
                        .bojiType(.data)
                        .foregroundStyle(BojiColor.textPrimary)
                    ForEach(suggestions) { suggestion in
                        suggestionCard(suggestion)
                    }
                }
            }
        }
    }

    @ViewBuilder private func suggestionCard(_ suggestion: DailySuggestion) -> some View {
        let applied = appliedSuggestionIDs.contains(suggestion.id)
        VStack(alignment: .leading, spacing: BojiLayout.tight) {
            Text(suggestion.title)
                .bojiType(.body15)
                .foregroundStyle(BojiColor.textPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline) {
                Text(suggestion.detail)
                    .bojiType(.caption)
                    .foregroundStyle(BojiColor.textSecondary)
                    .lineLimit(2)
                Spacer()
                if applied {
                    Label("已应用", systemImage: "checkmark.circle.fill")
                        .bojiType(.caption)
                        .foregroundStyle(ClubBrand.accent)
                } else {
                    Button {
                        applySuggestion(suggestion)
                    } label: {
                        Text("应用")
                            .bojiType(.body15)
                            .frame(minWidth: 64)
                            .frame(minHeight: BojiLayout.controlHeight)
                    }
                    .buttonStyle(SecondaryButton())
                    .buttonBorderShape(.capsule)
                    .accessibilityIdentifier("v2-report-apply-" + suggestion.id)
                }
            }
        }
        .padding(BojiLayout.cardInset)
        .overlay {
            RoundedRectangle(cornerRadius: BojiLayout.Radius.inner, style: .continuous)
                .stroke(BojiColor.divider, lineWidth: BojiLayout.hairline)
        }
    }

    // MARK: - 底部操作栏（§九：B1「应用」为唯一主操作；生成/刷新降为文字链）
    private var bottomActionBar: some View {
        VStack(spacing: BojiLayout.inline) {
            if isFuture {
                Text("未来日期无法生成日报，请返回今天或历史日期。")
                    .bojiType(.caption)
                    .foregroundStyle(BojiColor.textTertiary)
            } else if !suggestions.isEmpty {
                Button {
                    BojiHaptics.selection()
                    BojiSound.play(.tap)
                    confirmApplyAll = true
                } label: {
                    Text("应用\(suggestions.count >= 2 ? "这两条" : "这条")")
                        .frame(maxWidth: .infinity, minHeight: BojiLayout.actionHeight)
                        .contentShape(Rectangle())
                }
                .clubNativeGlassButton(prominent: true)
                .accessibilityIdentifier("v2-report-primary")
                .disabled(appliedSuggestionIDs.count >= suggestions.count)
            }
            Button {
                generateReport()
            } label: {
                HStack(spacing: BojiLayout.tight) {
                    if isGenerating {
                        ProgressView()
                    } else {
                        Image(systemName: activeJob != nil ? "arrow.clockwise" : "wand.and.stars")
                    }
                    Text(activeJob != nil ? "刷新今日分析" : "生成今日分析")
                }
                .bojiType(.body15)
                .tint(ClubBrand.accent)
                .frame(maxWidth: .infinity, alignment: .center)
                .frame(minHeight: BojiLayout.controlHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isGenerating || pendingJob != nil)

            if let err = errorMessage {
                Text(err)
                    .bojiType(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.top, BojiLayout.inline)
    }

    private func prepareShare(_ result: AIResult) {
        guard let owner = store.editingAccountID else { return }
        let sections = ReportShareContent.sections(
            summary: result.summary,
            training: result.training,
            nutrition: result.nutrition,
            recovery: result.recovery
        )
        let card = ShareCardView(
            title: currentDateKey + " 日报",
            headline: result.summary ?? "每日健身复盘",
            stats: [],
            tagline: "认真训练，认真记录。",
            sections: sections,
            trainingFeedback: result.training_feedback ?? .legacy
        )
        shareDraft = ShareDraft(card: card, ownerID: owner)
    }

    private func generateReport() {
        guard !isFuture else { return }
        BojiHaptics.tick()
        isGenerating = true
        errorMessage = nil

        do {
            let target = store.reportNutritionTarget(on: currentDate)
            let weights = store.bodyWeightPoints(through: currentDate)
            let goalContext = ClubAIContext.make(state: store.state, start: currentDate, end: currentDate)
            let input = try ai.reportInput(
                date: currentDate,
                log: todayLog,
                nutritionTarget: target,
                weightHistory: weights,
                goalContext: goalContext,
                allowEmpty: true
            )
            _ = try ai.submit(input, forceNew: true)
            isGenerating = false
            BojiHaptics.success()
        } catch {
            isGenerating = false
            errorMessage = error.localizedDescription
            BojiHaptics.error()
        }
    }
}
