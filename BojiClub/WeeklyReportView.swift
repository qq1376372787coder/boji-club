import SwiftUI

struct WeeklyReportView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var ai: AIService
    @EnvironmentObject private var weekly: WeeklyReviewService
    @EnvironmentObject private var account: AccountService
    @Environment(\.dismiss) private var dismiss

    @State private var chosenCycleID: String? = nil
    @State private var isGenerating = false
    @State private var errorMessage: String? = nil
    @State private var showPlanWizard = false
    @State private var shareDraft: ShareDraft? = nil

    private var availableCycles: [TrainingCycle] {
        TrainingCycle.available(days: store.state.days)
    }

    private var currentCycle: TrainingCycle {
        if let id = chosenCycleID, let found = availableCycles.first(where: { $0.id == id }) {
            return found
        }
        return availableCycles.first ?? TrainingCycle.preferred(days: store.state.days)
    }

    private var cycleDays: [DayLog] {
        guard let start = ClubDates.date(fromKey: currentCycle.start),
              let end = ClubDates.date(fromKey: currentCycle.end) else { return [] }
        var result: [DayLog] = []
        var cur = start
        while cur <= end {
            result.append(store.log(for: cur))
            guard let next = ClubDates.calendar.date(byAdding: .day, value: 1, to: cur) else { break }
            cur = next
        }
        return result
    }

    private var existingReview: WeeklyReview? {
        let deleted = Set(store.state.deletedAIJobIDs ?? [])
        return WeeklyVersions.visible(days: store.state.days, local: weekly.reviews, deletedJobIDs: deleted)
            .first { $0.date == currentCycle.end && $0.result != nil }
    }

    private var weeklyMetrics: AIWeeklyMetrics {
        if let m = existingReview?.result?.metrics {
            return m
        }
        return computeDeterministicWeeklyMetrics()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BojiLayout.blockGap) {
                // 周期选择器
                cyclePickerBar

                // 第一层：本周客观数据看板
                overviewMetricsSection

                // 第二层：训练与容量趋势
                trainingTrendSection

                // 第三层：饮食营养与规律性
                nutritionTrendSection

                // 第四层：体重与身体变化
                bodyTrendSection

                // 第五层：AI 深度复盘
                aiDeepAnalysisSection

                // 第六层：下周安排
                nextWeekActionSection

                // 底部操作
                bottomActionBar
            }
            .padding(.horizontal, BojiLayout.pageInset)
            .padding(.vertical, BojiLayout.cardInset)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("周报")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if let res = existingReview?.result {
                    Button {
                        prepareShare(res)
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("分享周报")
                }
            }
        }
        .sheet(item: $shareDraft) { draft in
            ShareCardPreview(draft: draft)
        }
        .sheet(isPresented: $showPlanWizard) {
            NavigationStack {
                PlanView(date: Date(), initialMode: "generate_plan")
            }
        }
    }

    // MARK: - 周期选择器
    private var cyclePickerBar: some View {
        HStack {
            Image(systemName: "calendar")
                .bojiType(.secondary)
                .foregroundStyle(BojiColor.brandGold)

            Text("复盘周期")
                .bojiType(.secondary)
                .foregroundStyle(BojiColor.textPrimary)

            Spacer()

            Picker("选择周期", selection: Binding(
                get: { currentCycle.id },
                set: { chosenCycleID = $0 }
            )) {
                ForEach(availableCycles) { c in
                    Text(c.label).tag(c.id)
                }
            }
            .pickerStyle(.menu)
            .tint(BojiColor.brandGold)
        }
        .padding(.vertical, BojiLayout.inline)
        .padding(.horizontal, BojiLayout.cardInset)
        .background(BojiColor.subtleSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - 本周总览数据看板
    private var overviewMetricsSection: some View {
        VStack(alignment: .leading, spacing: BojiLayout.rowGap) {
            HStack {
                Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                    .foregroundStyle(BojiColor.brandGold)
                Text("本周客观数据")
                    .bojiType(.body)
                    .foregroundStyle(BojiColor.textPrimary)
                Spacer()
                Text("7天确定性聚合")
                    .bojiType(.caption)
                    .foregroundStyle(BojiColor.textTertiary)
            }

            let t = weeklyMetrics.training
            let n = weeklyMetrics.nutrition
            let b = weeklyMetrics.body

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: BojiLayout.rowGap) {
                metricTile(
                    title: "练了几天",
                    value: "\(t?.training_days ?? 0) 天",
                    subtext: "累计 \(t?.total_completed_sets ?? 0) 组完成",
                    symbol: "figure.strengthtraining.traditional"
                )

                metricTile(
                    title: "力量总容量",
                    value: "\(Int(t?.total_volume_kg ?? 0)) kg",
                    subtext: formatChangePct(t?.volume_change_pct),
                    symbol: "chart.line.uptrend.xyaxis"
                )

                metricTile(
                    title: "日均热量",
                    value: n?.average_calories != nil ? "\(Int(n!.average_calories!)) kcal" : "—",
                    subtext: "记满 \(n?.complete_days_count ?? 0) 天",
                    symbol: "fork.knife"
                )

                metricTile(
                    title: "体重走向",
                    value: formatWeightTrend(b?.weight_trend),
                    subtext: formatWeightChange(b?.weight_change_kg),
                    symbol: "scalemass"
                )
            }
        }
    }

    private func metricTile(title: String, value: String, subtext: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: BojiLayout.tight) {
            HStack {
                Image(systemName: symbol)
                    .bojiType(.caption)
                    .foregroundStyle(BojiColor.textTertiary)
                Text(title)
                    .bojiType(.caption)
                    .foregroundStyle(BojiColor.textTertiary)
            }
            Text(value)
                .bojiType(.body)
                .foregroundStyle(BojiColor.textPrimary)
            Text(subtext)
                .bojiType(.caption)
                .foregroundStyle(BojiColor.textSecondary)
        }
        .padding(BojiLayout.rowGap)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BojiColor.subtleSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - 训练趋势
    private var trainingTrendSection: some View {
        VStack(alignment: .leading, spacing: BojiLayout.inline) {
            HStack {
                Label("训练负荷与分布", systemImage: "dumbbell")
                    .bojiType(.secondary)
                    .foregroundStyle(BojiColor.textPrimary)
                Spacer()
            }

            VStack(alignment: .leading, spacing: BojiLayout.tight) {
                if let mins = weeklyMetrics.training?.total_duration_minutes, mins > 0 {
                    HStack {
                        Text("有效训练总时长")
                            .bojiType(.label)
                            .foregroundStyle(BojiColor.textSecondary)
                        Spacer()
                        Text("\(mins) 分钟")
                            .bojiType(.label)
                            .foregroundStyle(BojiColor.textPrimary)
                    }
                }

                HStack {
                    Text("练了几场")
                        .bojiType(.label)
                        .foregroundStyle(BojiColor.textSecondary)
                    Spacer()
                    Text("\(weeklyMetrics.training?.total_sessions ?? 0) 次")
                        .bojiType(.label)
                        .foregroundStyle(BojiColor.textPrimary)
                }
            }
            .padding(BojiLayout.rowGap)
            .background(BojiColor.subtleSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    // MARK: - 饮食趋势
    private var nutritionTrendSection: some View {
        VStack(alignment: .leading, spacing: BojiLayout.inline) {
            HStack {
                Label("营养规律性", systemImage: "flame")
                    .bojiType(.secondary)
                    .foregroundStyle(BojiColor.textPrimary)
                Spacer()
            }

            VStack(alignment: .leading, spacing: BojiLayout.tight) {
                HStack {
                    Text("日均蛋白质摄入")
                        .bojiType(.label)
                        .foregroundStyle(BojiColor.textSecondary)
                    Spacer()
                    if let prot = weeklyMetrics.nutrition?.average_protein {
                        Text(String(format: "%.0f g", prot))
                            .bojiType(.label)
                            .foregroundStyle(BojiColor.textPrimary)
                    } else {
                        Text("未记录")
                            .bojiType(.label)
                            .foregroundStyle(BojiColor.textTertiary)
                    }
                }

                HStack {
                    Text("记录有效天数")
                        .bojiType(.label)
                        .foregroundStyle(BojiColor.textSecondary)
                    Spacer()
                    Text("\(weeklyMetrics.nutrition?.days_with_records ?? 0) / 7 天")
                        .bojiType(.label)
                        .foregroundStyle(BojiColor.textPrimary)
                }
            }
            .padding(BojiLayout.rowGap)
            .background(BojiColor.subtleSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    // MARK: - 体重变化
    private var bodyTrendSection: some View {
        VStack(alignment: .leading, spacing: BojiLayout.inline) {
            HStack {
                Label("身体指标变化", systemImage: "figure.walk.motion")
                    .bojiType(.secondary)
                    .foregroundStyle(BojiColor.textPrimary)
                Spacer()
            }

            HStack {
                VStack(alignment: .leading, spacing: 0) {
                    Text("起始体重")
                        .bojiType(.caption)
                        .foregroundStyle(BojiColor.textTertiary)
                    Text(weeklyMetrics.body?.start_weight_kg != nil ? String(format: "%.1f kg", weeklyMetrics.body!.start_weight_kg!) : "—")
                        .bojiType(.body)
                        .foregroundStyle(BojiColor.textPrimary)
                }
                Spacer()
                Image(systemName: "arrow.right")
                    .bojiType(.caption)
                    .foregroundStyle(BojiColor.textTertiary)
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text("周期末体重")
                        .bojiType(.caption)
                        .foregroundStyle(BojiColor.textTertiary)
                    Text(weeklyMetrics.body?.end_weight_kg != nil ? String(format: "%.1f kg", weeklyMetrics.body!.end_weight_kg!) : "—")
                        .bojiType(.body)
                        .foregroundStyle(BojiColor.textPrimary)
                }
            }
            .padding(BojiLayout.rowGap)
            .background(BojiColor.subtleSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    // MARK: - AI 深度复盘
    private var aiDeepAnalysisSection: some View {
        VStack(alignment: .leading, spacing: BojiLayout.rowGap) {
            HStack {
                Image(systemName: "sparkles")
                    .foregroundStyle(BojiColor.brandGold)
                Text("本周深度总结")
                    .bojiType(.body)
                    .foregroundStyle(BojiColor.textPrimary)
                Spacer()
            }

            if let res = existingReview?.result {
                VStack(alignment: .leading, spacing: BojiLayout.rowGap) {
                    Text(res.summary)
                        .bojiType(.secondary)
                        .foregroundStyle(BojiColor.textPrimary)
                        .lineSpacing(4)

                    Divider().padding(.vertical, 0)

                    VStack(alignment: .leading, spacing: BojiLayout.tight) {
                        Text("训练进阶与强度")
                            .bojiType(.caption)
                            .foregroundStyle(BojiColor.textSecondary)
                        Text(res.training)
                            .bojiType(.label)
                            .foregroundStyle(BojiColor.textPrimary)
                            .lineSpacing(3)
                    }

                    Divider().padding(.vertical, 0)

                    VStack(alignment: .leading, spacing: BojiLayout.tight) {
                        Text("营养与能量恢复")
                            .bojiType(.caption)
                            .foregroundStyle(BojiColor.textSecondary)
                        Text(res.nutrition)
                            .bojiType(.label)
                            .foregroundStyle(BojiColor.textPrimary)
                            .lineSpacing(3)
                    }

                    if !res.recovery.isEmpty {
                        Divider().padding(.vertical, 0)
                        VStack(alignment: .leading, spacing: BojiLayout.tight) {
                            Text("恢复与身体感知")
                                .bojiType(.caption)
                                .foregroundStyle(BojiColor.textSecondary)
                            Text(res.recovery)
                                .bojiType(.label)
                                .foregroundStyle(BojiColor.textPrimary)
                                .lineSpacing(3)
                        }
                    }
                }
                .padding(BojiLayout.cardInset)
                .background(BojiColor.subtleSurface, in: RoundedRectangle(cornerRadius: BojiRadius.inner, style: .continuous))
            } else {
                VStack(spacing: BojiLayout.rowGap) {
                    Image(systemName: "chart.line.text.clipboard")
                        .bojiType(.title)
                        .foregroundStyle(BojiColor.textTertiary)
                    Text("本周期尚未生成深度总结")
                        .bojiType(.secondary)
                        .foregroundStyle(BojiColor.textSecondary)
                    Text("依据过去 7 天真实训练与饮食记录，全自动生成长效进阶分析。")
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

    // MARK: - 下一周建议
    private var nextWeekActionSection: some View {
        Group {
            if let res = existingReview?.result {
                VStack(alignment: .leading, spacing: BojiLayout.rowGap) {
                    HStack {
                        Image(systemName: "arrow.right.circle")
                            .foregroundStyle(BojiColor.brandGold)
                        Text("下周安排")
                            .bojiType(.body)
                            .foregroundStyle(BojiColor.textPrimary)
                    }

                    VStack(alignment: .leading, spacing: BojiLayout.inline) {
                        Text(res.reason)
                            .bojiType(.label)
                            .foregroundStyle(BojiColor.textPrimary)
                            .lineSpacing(3)

                        if res.decision == "adjust" {
                            Button {
                                showPlanWizard = true
                            } label: {
                                HStack {
                                    Image(systemName: "wand.and.stars")
                                    Text("前往调整下周训练计划")
                                }
                                .bojiType(.label)
                                .foregroundStyle(BojiColor.brandGold)
                            }
                            .padding(.top, BojiLayout.tight)
                        }
                    }
                    .padding(BojiLayout.rowGap)
                    .background(BojiColor.subtleSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
    }

    // MARK: - 底部操作栏
    private var bottomActionBar: some View {
        VStack(spacing: BojiLayout.inline) {
            Button {
                generateWeeklyReport()
            } label: {
                HStack {
                    if isGenerating {
                        ProgressView().tint(.black)
                    } else {
                        Image(systemName: existingReview != nil ? "arrow.clockwise" : "wand.and.stars")
                    }
                    Text(existingReview != nil ? "重新生成本周深度复盘" : "生成本周深度总结")
                }
                .bojiType(.body)
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(BojiColor.brandGold, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .disabled(isGenerating)

            if let err = errorMessage {
                Text(err)
                    .bojiType(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.top, BojiLayout.inline)
    }

    private func prepareShare(_ result: WeeklyResult) {
        guard let owner = store.editingAccountID else { return }
        let sections = ReportShareContent.sections(
            summary: result.summary,
            training: result.training,
            nutrition: result.nutrition,
            recovery: result.recovery,
            planReason: result.reason
        )
        let card = ShareCardView(
            title: currentCycle.label + " 周报",
            headline: result.summary,
            stats: [],
            tagline: "把进步交给时间。",
            sections: sections
        )
        shareDraft = ShareDraft(card: card, ownerID: owner)
    }

    private func generateWeeklyReport() {
        BojiHaptics.tick()
        isGenerating = true
        errorMessage = nil

        var review = existingReview ?? WeeklyReview(date: currentCycle.end)
        review.cycle = currentCycle
        review.scope = "combined"
        review.survey.days = store.state.profile.daysPerWeek
        review.survey.trainingDays = store.state.profile.trainingDays ?? Array([1,3,5,2,4,6,7].prefix(store.state.profile.daysPerWeek))
        if weekly.save(review) {
            weekly.submit(review.id, account: account, store: store, ai: ai)
        }
        isGenerating = false
        BojiHaptics.success()
    }

    // MARK: - 辅助计算
    private func computeDeterministicWeeklyMetrics() -> AIWeeklyMetrics {
        var trainingDays = 0
        var totalSets = 0
        var totalVolume = 0.0
        var totalDuration = 0
        var daysWithMeals = 0
        var completeDays = 0
        var totalCal = 0.0
        var totalProt = 0.0
        var weights: [(String, Double)] = []

        guard let start = ClubDates.date(fromKey: currentCycle.start),
              let end = ClubDates.date(fromKey: currentCycle.end) else {
            return AIWeeklyMetrics()
        }

        var cur = start
        while cur <= end {
            let key = ClubDates.key(cur)
            let log = store.log(for: cur)
            let confirmed = log.confirmedTraining
            if confirmed.hasTraining {
                trainingDays += 1
                totalSets += confirmed.completedSets
                totalVolume += confirmed.volume
                if confirmed.elapsedSeconds > 0 {
                    totalDuration += confirmed.elapsedSeconds / 60
                }
            }

            if !log.meals.isEmpty {
                daysWithMeals += 1
                if log.mealsComplete { completeDays += 1 }
                totalCal += log.calories
                totalProt += log.protein
            }

            if let w = log.bodyWeight?.kilograms, w > 0 {
                weights.append((key, w))
            }

            guard let next = ClubDates.calendar.date(byAdding: .day, value: 1, to: cur) else { break }
            cur = next
        }

        weights.sort { $0.0 < $1.0 }
        let startW = weights.first?.1
        let endW = weights.last?.1
        let diffW = (startW != nil && endW != nil && weights.count >= 2) ? round((endW! - startW!) * 10) / 10 : nil

        var trend = "insufficient_data"
        if weights.count >= 3 {
            let diffs = (1..<weights.count).map { weights[$0].1 - weights[$0 - 1].1 }
            if diffs.allSatisfy({ $0 > 0.1 }) { trend = "increasing" }
            else if diffs.allSatisfy({ $0 < -0.1 }) { trend = "decreasing" }
            else if weights.allSatisfy({ abs($0.1 - (startW ?? 0)) <= 0.3 }) { trend = "stable" }
            else { trend = "fluctuating" }
        }

        return AIWeeklyMetrics(
            training: AIWeeklyTrainingMetrics(
                training_days: trainingDays,
                total_sessions: trainingDays,
                total_duration_minutes: totalDuration > 0 ? totalDuration : nil,
                total_completed_sets: totalSets,
                total_volume_kg: totalVolume,
                volume_change_pct: nil
            ),
            nutrition: AIWeeklyNutritionMetrics(
                average_calories: daysWithMeals > 0 ? totalCal / Double(daysWithMeals) : nil,
                average_protein: daysWithMeals > 0 ? totalProt / Double(daysWithMeals) : nil,
                days_with_records: daysWithMeals,
                complete_days_count: completeDays
            ),
            body: AIWeeklyBodyMetrics(
                start_weight_kg: startW,
                end_weight_kg: endW,
                weight_change_kg: diffW,
                weight_trend: trend,
                samples_count: weights.count
            ),
            is_sufficient_for_analysis: trainingDays >= 1 || daysWithMeals >= 2 || weights.count >= 2
        )
    }

    private func formatChangePct(_ val: Double?) -> String {
        guard let val else { return "较上周稳定" }
        let prefix = val > 0 ? "+" : ""
        return "较上周 \(prefix)\(String(format: "%.1f", val))%"
    }

    private func formatWeightTrend(_ trend: String?) -> String {
        switch trend {
        case "increasing": return "持续上升"
        case "decreasing": return "稳步下降"
        case "stable": return "基本保持"
        case "fluctuating": return "正常波动"
        default: return "数据不足"
        }
    }

    private func formatWeightChange(_ change: Double?) -> String {
        guard let change else { return "样本少于2次" }
        let prefix = change > 0 ? "+" : ""
        return "净变 \(prefix)\(String(format: "%.1f", change)) kg"
    }
}
