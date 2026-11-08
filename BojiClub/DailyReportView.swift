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

                // 第一层：今日客观真实数据看板（数据优先）
                dailyMetricsSection

                // 第二层：AI 今日分析与亮点点评
                aiAnalysisSection

                // 第三层：明日建议
                recommendationsSection

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
                    Text("总容量 \(Int(vol)) kg")
                        .bojiType(.caption)
                        .foregroundStyle(BojiColor.brandGold)
                }
            }

            if let t = metrics.training, (t.completed_sets ?? 0) > 0 {
                HStack(spacing: BojiLayout.rowGap) {
                    metricItem(title: "完成动作", value: "\(t.completed_exercises ?? 0)", unit: "项")
                    metricItem(title: "完成组数", value: "\(t.completed_sets ?? 0)", unit: "组")
                    if let mins = t.duration_minutes, mins > 0 {
                        metricItem(title: "训练时长", value: "\(mins)", unit: "分钟")
                    } else {
                        metricItem(title: "训练场次", value: "\(t.sessions ?? 1)", unit: "次")
                    }
                }
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
                HStack(spacing: BojiLayout.rowGap) {
                    metricItem(title: "摄入热量", value: "\(Int(cal))", unit: "kcal")
                    metricItem(title: "蛋白质", value: String(format: "%.0f", n.protein ?? 0), unit: "g")
                    metricItem(title: "碳水", value: String(format: "%.0f", n.carbs ?? 0), unit: "g")
                    metricItem(title: "脂肪", value: String(format: "%.0f", n.fat ?? 0), unit: "g")
                }
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

            HStack(spacing: BojiLayout.rowGap) {
                if let w = metrics.body?.weight_kg {
                    metricItem(title: "今日体重", value: String(format: "%.1f", w), unit: "kg")
                } else {
                    metricItem(title: "今日体重", value: "—", unit: "未记录")
                }

                if let steps = metrics.activity?.steps, steps > 0 {
                    metricItem(title: "日常步数", value: "\(Int(steps))", unit: "步")
                }

                if let cal = metrics.activity?.active_energy_kcal, cal > 0 {
                    metricItem(title: "活动消耗", value: "\(Int(cal))", unit: "kcal")
                }
            }
        }
        .padding(BojiLayout.rowGap)
        .background(BojiColor.subtleSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func metricItem(title: String, value: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .bojiType(.caption)
                .foregroundStyle(BojiColor.textTertiary)
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(value)
                    .bojiType(.body)
                    .foregroundStyle(BojiColor.textPrimary)
                Text(unit)
                    .bojiType(.caption)
                    .foregroundStyle(BojiColor.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
    private var recommendationsSection: some View {
        Group {
            if let job = activeJob, let result = job.result,
               let recs = result.recommendations, !recs.isEmpty {
                VStack(alignment: .leading, spacing: BojiLayout.rowGap) {
                    HStack {
                        Image(systemName: "arrow.right.circle")
                            .foregroundStyle(BojiColor.brandGold)
                        Text("明日行动建议")
                            .bojiType(.body)
                            .foregroundStyle(BojiColor.textPrimary)
                    }

                    VStack(alignment: .leading, spacing: BojiLayout.inline) {
                        ForEach(recs, id: \.self) { rec in
                            HStack(alignment: .top, spacing: BojiLayout.inline) {
                                Image(systemName: "circle.fill")
                                    .bojiType(.caption)
                                    .foregroundStyle(BojiColor.brandGold)
                                    .padding(.top, BojiLayout.tight)
                                Text(rec)
                                    .bojiType(.label)
                                    .foregroundStyle(BojiColor.textPrimary)
                                    .lineSpacing(3)
                            }
                        }
                    }
                    .padding(BojiLayout.rowGap)
                    .background(BojiColor.subtleSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            } else if let recovery = activeJob?.result?.recovery, !recovery.isEmpty {
                VStack(alignment: .leading, spacing: BojiLayout.inline) {
                    HStack {
                        Image(systemName: "arrow.right.circle")
                            .foregroundStyle(BojiColor.brandGold)
                        Text("恢复与下一步")
                            .bojiType(.body)
                            .foregroundStyle(BojiColor.textPrimary)
                    }

                    Text(recovery)
                        .bojiType(.label)
                        .foregroundStyle(BojiColor.textPrimary)
                        .lineSpacing(3)
                        .padding(BojiLayout.rowGap)
                        .background(BojiColor.subtleSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
    }

    // MARK: - 底部操作栏
    private var bottomActionBar: some View {
        VStack(spacing: BojiLayout.inline) {
            if isFuture {
                Text("未来日期无法生成日报，请返回今天或历史日期。")
                    .bojiType(.caption)
                    .foregroundStyle(BojiColor.textTertiary)
            } else {
                Button {
                    generateReport()
                } label: {
                    HStack {
                        if isGenerating {
                            ProgressView().tint(.black)
                        } else {
                            Image(systemName: activeJob != nil ? "arrow.clockwise" : "wand.and.stars")
                        }
                        Text(activeJob != nil ? "刷新今日分析" : "生成今日日报分析")
                    }
                    .bojiType(.body)
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(BojiColor.brandGold, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .disabled(isGenerating || pendingJob != nil)

                if let err = errorMessage {
                    Text(err)
                        .bojiType(.caption)
                        .foregroundStyle(.red)
                }
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
