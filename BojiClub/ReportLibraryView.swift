import SwiftUI

enum ReportLibraryKind: String, CaseIterable, Hashable { case all = "全部", daily = "日报", weekly = "周报", workout = "训练解读", phase = "阶段报告" }

private enum ReportLibraryEntry: Identifiable {
    case daily(AILocalJob), weekly(WeeklyReview), followup(AILocalJob), phase(PhaseReport)
    var id: String {
        switch self { case .daily(let job): return "daily/" + job.id
        case .weekly(let review): return "weekly/" + review.id.uuidString; case .followup(let job): return "followup/" + job.id
        case .phase(let report): return report.id }
    }
    var date: String {
        switch self { case .daily(let job): return job.request.date; case .weekly(let review): return review.date; case .followup(let job): return job.request.date
        case .phase(let report): return report.end }
    }
    var created: Date {
        switch self { case .daily(let job): return job.created; case .weekly(let review): return review.updatedAt; case .followup(let job): return job.created
        case .phase(let report): return report.generatedAt }
    }
    var summary: String {
        switch self { case .daily(let job): return job.result?.summary ?? ""; case .weekly(let review): return review.result?.summary ?? ""; case .followup(let job): return job.result?.coach?.answer ?? ""
        case .phase(let report): return report.summary }
    }
}

struct ReportLibraryView: View {
    var embedded: Bool = false
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var ai: AIService
    @EnvironmentObject private var weekly: WeeklyReviewService
    @Environment(\.dismiss) private var dismiss
    @State private var kind: ReportLibraryKind
    @State private var filteringDate = false
    @State private var selectedDate = Date()
    @State private var ownerID: Int?
    /// 日报：直接走 report 管线（kind == "report"），不经过对话。
    @State private var dailyJobID: String?
    @State private var dailyError: String?
    /// 周报：打开专属的每周回顾中心，而不是对话。
    @State private var showWeeklyCenter = false
    init(initialKind: ReportLibraryKind = .all, embedded: Bool = false) {
        self.embedded = embedded
        _kind = State(initialValue: initialKind)
    }

    private var allEntries: [ReportLibraryEntry] {
        let deleted = Set(store.state.deletedAIJobIDs ?? [])
        let daily = ReportHistory.latestPerDay(ReportHistory.visible(ai.jobs, dateKey: nil, deleted: deleted))
        let reviews = WeeklyVersions.visible(days: store.state.days, local: weekly.reviews, deletedJobIDs: deleted)
            .filter { $0.result != nil }
        let followups = ClubAutomaticReports.items(ai.jobs, deleted: deleted).filter { $0.status == "succeeded" }
        // F7：同一区间只列最新一版；重生成的旧版本留在数据里（历史保留），不堆重复卡片。
        var seenWindows = Set<String>()
        let phases = store.phaseReports().filter { seenWindows.insert($0.start + "~" + $0.end).inserted }
        return (daily.map(ReportLibraryEntry.daily) + reviews.map(ReportLibraryEntry.weekly) + followups.map(ReportLibraryEntry.followup) + phases.map(ReportLibraryEntry.phase)).sorted {
            $0.date == $1.date ? ($0.created == $1.created ? $0.id > $1.id : $0.created > $1.created) : $0.date > $1.date
        }
    }
    private var entries: [ReportLibraryEntry] {
        let key = ClubDates.key(selectedDate)
        return allEntries.filter { entry in
            switch entry {
            case .daily(let job): return (kind == .all || kind == .daily) && (!filteringDate || job.request.date == key)
            case .weekly(let review):
                let start = review.cycle?.start ?? ClubDates.key(ClubDates.calendar.date(byAdding: .day, value: -6, to: ClubDates.date(fromKey: review.date) ?? selectedDate) ?? selectedDate)
                return (kind == .all || kind == .weekly) && (!filteringDate || (start <= key && key <= review.date))
            case .followup(let job):
                let weekly = job.result?.coach?.purpose == "weekly"
                let start = weekly ? ClubDates.key(ClubDates.calendar.date(byAdding: .day, value: -6, to: ClubDates.date(fromKey: job.request.date) ?? selectedDate) ?? selectedDate) : job.request.date
                return (kind == .all || kind == (weekly ? .weekly : .workout)) && (!filteringDate || (start <= key && key <= job.request.date))
            case .phase(let report):
                return (kind == .all || kind == .phase) && (!filteringDate || (report.start <= key && key <= report.end))
            }
        }
    }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: ClubUI.sectionSpacing) {
                BojiBrandSignature(size:24)
                if ai.hasMoreTaskHistory {
                    Text("历史报告正在分批恢复，列表会随同步继续补齐。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                filters
                if entries.isEmpty { emptyState }
                ForEach(entries) { entry in
                    NavigationLink { destination(entry) } label: {
                        HStack(alignment: .center, spacing: 12) {
                            row(entry)
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary).accessibilityHidden(true)
                        }.padding(.vertical, BojiSpace.general).frame(minHeight: 44)
                            .multilineTextAlignment(.leading)
                    }.buttonStyle(ClubMotionButton())
                    Divider().overlay(BojiColor.divider)
                }
            }.padding(ClubUI.pageInset).frame(maxWidth: ClubUI.contentWidth)
                .frame(maxWidth: .infinity)
        }.background { ClubBackground() }.tint(ClubBrand.accent)
            .navigationTitle("AI 解读档案").navigationBarTitleDisplayMode(.inline)
            .sheet(item: $dailyJobID) { jobID in
                NavigationStack {
                    AIReportReaderView(jobID: jobID)
                        .background { ClubBackground() }
                        .navigationTitle("日报")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { DismissButton() } }
                }
            }
            .sheet(isPresented: $showWeeklyCenter) {
                WeeklyReviewCenter().background { ClubBackground() }
            }
            .onAppear { if ownerID == nil { ownerID = store.editingAccountID } }
            .onChange(of: store.editingAccountID) { _, id in if id != ownerID { dismiss() } }
    }

    private var generationHubCard: some View {
        let todayKey = ClubDates.key(Date())
        let deleted = Set(store.state.deletedAIJobIDs ?? [])
        let todayReport = ReportHistory.visible(ai.jobs, dateKey: todayKey, deleted: deleted).first
        let todayLog = store.log(for: Date())
        let cycle = TrainingCycle.preferred(days: store.state.days)
        let readiness = WeeklyReadiness(cycle: cycle, days: store.state.days)
        let weeklyDone = WeeklyVersions.visible(days: store.state.days, local: weekly.reviews, deletedJobIDs: deleted)
            .contains { $0.date == cycle.end && $0.result != nil }

        return ClubCard {
            Text("生成与更新报告").bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
            Text("随时生成今日复盘、本周总结或近 4 周阶段报告。")
                .font(.footnote).foregroundStyle(.secondary)

            VStack(spacing: 8) {
                Button { generateDailyReport() } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "sun.max.fill").foregroundStyle(BojiColor.aiGold).frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("日报").font(.subheadline.weight(.semibold)).foregroundStyle(BojiColor.textPrimary)
                            Text(todayReport?.status == "succeeded" ? "今日已生成 · 点击查看或重新生成" : DailyReportEligibility.hasRecords(todayLog) ? "已有今日记录 · 可立即生成" : "记录训练、饮食或称重后即可生成")
                                .font(.caption).foregroundStyle(BojiColor.textSecondary).lineLimit(1)
                        }
                        Spacer()
                        Text(todayReport?.status == "succeeded" ? "查看" : "生成")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(BojiColor.textPrimary.opacity(0.08), in: Capsule())
                            .foregroundStyle(BojiColor.textPrimary)
                    }
                    .padding(10)
                    .background(BojiColor.subtleSurface, in: RoundedRectangle(cornerRadius: BojiRadius.inner, style: .continuous))
                }
                .buttonStyle(.plain)
                if let dailyError { Text(dailyError).font(.caption).foregroundStyle(.red) }

                Button { showWeeklyCenter = true } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "calendar.badge.checkmark").foregroundStyle(BojiColor.aiViolet).frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("周报").font(.subheadline.weight(.semibold)).foregroundStyle(BojiColor.textPrimary)
                            Text(weeklyDone ? "本周已完成 · 点击查看或调整下周" : readiness.trainingReady ? "已满足本周条件 · 可开始复盘" : "已完成训练 \(readiness.trainingDays)/\(readiness.neededTrainingDays) 天 · 饮食 \(readiness.foodDays)/3 天")
                                .font(.caption).foregroundStyle(BojiColor.textSecondary).lineLimit(1)
                        }
                        Spacer()
                        Text(weeklyDone ? "查看" : readiness.trainingReady ? "开始复盘" : "查看进度")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(BojiColor.textPrimary.opacity(0.08), in: Capsule())
                            .foregroundStyle(BojiColor.textPrimary)
                    }
                    .padding(10)
                    .background(BojiColor.subtleSurface, in: RoundedRectangle(cornerRadius: BojiRadius.inner, style: .continuous))
                }
                .buttonStyle(.plain)

                Button(phaseBusy ? "正在生成阶段报告…" : "生成阶段报告（近 4 周趋势）") { generatePhaseReport() }
                    .buttonStyle(BojiButtonStyle(kind: .secondary))
                    .disabled(phaseBusy)
                if let phaseError { Text(phaseError).bojiFont(.secondary).foregroundStyle(.red) }
            }
        }
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 10) {
            BojiChipRow(
                items: ReportLibraryKind.allCases.map(\.rawValue),
                selection: Binding(
                    get: { kind.rawValue },
                    set: { raw in kind = ReportLibraryKind(rawValue: raw) ?? .all }
                )
            )
            HStack {
                Toggle("按日期筛选", isOn: $filteringDate)
                    .font(.subheadline)
                if filteringDate {
                    DatePicker("日期", selection: $selectedDate, in: ...Date(), displayedComponents: .date)
                        .labelsHidden()
                }
            }
        }
    }
    private var emptyState: some View {
        ClubCard {
            EmptyNote(title: allEntries.isEmpty ? "你的分析，会在这里留下记录" : "这个筛选条件下没有报告",
                      detail: allEntries.isEmpty ? "生成日报、周报或阶段报告后，分析会按生成时的记录保留在这里。" : "换一个日期或报告类型，也可以关闭日期筛选查看全部。")
            if filteringDate { Button("查看全部日期") { filteringDate = false }.buttonStyle(SecondaryButton()) }
        }
    }
    @ViewBuilder private func destination(_ entry: ReportLibraryEntry) -> some View {
        switch entry {
        case .daily(let job): AIReportReaderView(jobID: job.id)
        case .weekly(let review): WeeklyReviewHistoryDetail(review: review)
        case .followup(let job): ClubAutomaticReportReader(jobID: job.id)
        case .phase(let report): PhaseReportView(report: report)
        }
    }
    private func row(_ entry: ReportLibraryEntry) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(entry.date).bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
                Spacer()
                Text(label(entry)).font(.caption.weight(.semibold)).padding(.horizontal, 9).padding(.vertical, 4)
                    .background(.black.opacity(0.05), in: Capsule())
            }
            Text(entry.summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            if case .daily(let job) = entry { TrainingFeedbackBadge(feedback: job.result?.training_feedback ?? .legacy) }
            if case .weekly(let review) = entry { Text(review.cycle?.label ?? "截至 \(review.date) 的七天").font(.footnote).foregroundStyle(.secondary) }
            if case .phase(let report) = entry {
                let versions = store.phaseReports().filter { $0.start == report.start && $0.end == report.end }.count
                Text("\(report.start) — \(report.end) · \(report.daysCovered)/\(report.daysTotal) 天有记录 · \(versions) 个版本")
                    .font(.footnote).foregroundStyle(.secondary)
                if PhaseReportRules.isStale(report, state: store.state) {
                    Text("依据的记录已变化，这份报告可能过时").font(.footnote).foregroundStyle(.orange)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func label(_ entry: ReportLibraryEntry) -> String {
        switch entry { case .daily: return "日报"; case .weekly: return "周报"; case .followup(let job): return job.result?.coach?.purpose == "weekly" ? "周报" : "训练解读"; case .phase: return "阶段报告" }
    }

    // D3：阶段报告生成。本地规则计算，幂等（同区间同 ID）；数据不足如实说明，不生成空报告。
    @State private var phaseBusy = false
    @State private var phaseError: String?
    /// 日报生成：直接提交 report 任务并打开阅读页，全程不经过对话。
    private func generateDailyReport() {
        guard let owner = store.editingAccountID else {
            dailyError = "登录状态已变化，请重新打开报告库。"; return
        }
        let date = Date()
        do {
            let input = try ai.reportInput(date: date, log: store.log(for: date),
                nutritionTarget: store.state.nutritionTarget,
                weightHistory: store.bodyWeightPoints(through: date),
                goalContext: ClubAIContext.make(state: store.state, start: date, end: date))
            let jobID = try ai.submit(input)
            guard owner == store.editingAccountID else {
                dailyError = "账号已切换，这份日报没有生成；请重新打开后再试。"; return
            }
            dailyError = nil
            dailyJobID = jobID
        } catch { dailyError = AppErrorText.message(error) }
    }
    private func generatePhaseReport() {
        guard !phaseBusy else { return }
        phaseBusy = true; phaseError = nil
        let calendar = ClubDates.calendar
        let end = calendar.startOfDay(for: Date())
        // 含今天在内共 28 天：起点为 end − 27 天。
        let start = calendar.date(byAdding: .day, value: -(PhaseReportRules.minimumDays - 1), to: end) ?? end
        guard let owner = store.editingAccountID else {
            phaseBusy = false; phaseError = "登录状态已变化，请重新打开后再生成。"; return
        }
        let generation = store.stateGeneration
        Task {
            defer { phaseBusy = false }
            do {
                guard store.editingAccountID == owner else {
                    phaseError = "账号已切换，这份阶段报告没有写入；请重新生成。"; return
                }
                let report = try PhaseReportRules.make(state: store.state, start: start, end: end)
                if store.savePhaseReport(report, expectedOwner: owner, expectedGeneration: generation) { phaseError = nil }
                else { phaseError = store.takeMessage(fallback: "阶段报告未能保存，请重试。") }
            } catch {
                phaseError = AppErrorText.message(error)
            }
        }
    }
}

// MARK: - 阶段报告阅读页

struct PhaseReportView: View {
    let report: PhaseReport
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var ai: AIService
    @State private var reviewJobID: String?
    @State private var reviewError: String?
    private var versions: [PhaseReport] {
        store.phaseReports()
            .filter { $0.start == report.start && $0.end == report.end }
            .sorted { $0.generatedAt == $1.generatedAt ? $0.id > $1.id : $0.generatedAt > $1.generatedAt }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BojiSpace.sectionSpacing) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("阶段报告").bojiFont(.label).foregroundStyle(BojiColor.textSecondary)
                    Text("\(report.start) — \(report.end)").bojiFont(.pageTitle).foregroundStyle(BojiColor.textPrimary)
                    Text(report.summary).bojiFont(.body).foregroundStyle(BojiColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if PhaseReportRules.isStale(report, state: store.state) {
                        Label("生成后原始记录已有变化；这份报告保留为当时版本，可重新生成一份新的。", systemImage: "exclamationmark.triangle")
                            .font(.footnote).foregroundStyle(.orange)
                    } else if report.evidenceDigest == nil {
                        Text("这是旧版报告，没有保存依据指纹；无法判断生成后记录是否变化。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                ClubCard {
                    Text("数据覆盖").bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
                    Text("共 \(report.daysTotal) 天，\(report.daysCovered) 天有实际记录").bojiFont(.body)
                    Text("训练日：计划 \(report.trainingDaysPlanned) 天，已确认完成 \(report.trainingDaysCompleted) 天，累计 \(report.confirmedSets) 个完成组")
                        .bojiFont(.secondary).foregroundStyle(BojiColor.textSecondary)
                    if report.measuredDays > 0 {
                        Text("实测体重 \(report.measuredDays) 次" + (report.weightFirstKg != nil && report.weightLastKg != nil ? "，区间 \(report.weightFirstKg!.formatted(.number.precision(.fractionLength(1)))) → \(report.weightLastKg!.formatted(.number.precision(.fractionLength(1)))) kg" : ""))
                            .bojiFont(.secondary).foregroundStyle(BojiColor.textSecondary)
                    } else {
                        Text("区间内没有实测体重记录").bojiFont(.secondary).foregroundStyle(BojiColor.textSecondary)
                    }
                }
                if !report.trends.isEmpty {
                    ClubCard {
                        Text("可比训练趋势").bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
                        ForEach(report.trends) { trend in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(trend.verdict).bojiFont(.exerciseName)
                                    .foregroundStyle(trend.verdict == "样本不足" ? BojiColor.textTertiary : BojiColor.textPrimary)
                                Text(trend.detail).bojiFont(.secondary).foregroundStyle(BojiColor.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }.padding(.vertical, 5)
                            if trend.id != report.trends.last?.id { Divider().overlay(BojiColor.divider) }
                        }
                    }
                }
                if let plateau = report.plateauNote {
                    ClubCard {
                        Text("体重状态").bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
                        Text(plateau).bojiFont(.body).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if versions.count > 1 {
                    ClubCard {
                        Text("同一区间的历史版本").bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
                        Text("重新生成不会删除旧报告；每份保留生成时的依据快照。")
                            .font(.footnote).foregroundStyle(.secondary)
                        ForEach(versions) { version in
                            if version.id == report.id {
                                Text("\(ClubDates.label(version.generatedAt, format: "M月d日 HH:mm")) · 正在查看")
                                    .font(.subheadline.weight(.semibold))
                            } else {
                                NavigationLink {
                                    PhaseReportView(report: version)
                                } label: {
                                    Text("\(ClubDates.label(version.generatedAt, format: "M月d日 HH:mm")) · 查看该版本")
                                        .font(.subheadline)
                                }
                            }
                            if version.id != versions.last?.id { Divider() }
                        }
                    }
                }
                ClubCard {
                    Text("依据与边界").bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
                    ForEach(Array(report.notes.enumerated()), id: \.offset) { _, note in
                        Text(note).bojiFont(.secondary).foregroundStyle(BojiColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !report.hasPreviousPhase {
                        Text("没有完整上一阶段，不提供环比。").bojiFont(.label).foregroundStyle(BojiColor.textTertiary)
                    }
                }
                phaseAIReview
            }
            .padding(ClubUI.pageInset)
            .frame(maxWidth: BojiSize.contentWidth)
            .frame(maxWidth: .infinity)
        }
        .background { ClubBackground() }
        .navigationTitle("阶段报告").navigationBarTitleDisplayMode(.inline)
    }

    /// F10：AI 增强是显式、可追溯、可降级的附加解读。本地阶段报告仍是准据；
    /// 失败或关闭云端分析时不会覆盖、删除或改写本地报告。
    @ViewBuilder private var phaseAIReview: some View {
        ClubCard {
            Text("可选的 AI 解读").bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
            Text("本地阶段报告按真实覆盖计算，是这份回顾的准据。下面的解读会额外发送阶段摘要与截至阶段结束的近 14 天记录；不会自动触发，也不会改写记录或计划。")
                .font(.footnote).foregroundStyle(.secondary)
            if !ai.routingConsentGranted {
                Text("云端分析已关闭，本地阶段报告不受影响；可在“设置 → 云端分析与隐私”开启后再使用。")
                    .font(.footnote).foregroundStyle(BojiColor.textTertiary)
            }
            if let jobID = reviewJobID, let job = ai.job(jobID) {
                switch job.status {
                case "succeeded":
                    if let answer = job.result?.coach?.answer {
                        Text("AI 增强解读").font(.subheadline.weight(.semibold))
                        BojiBrandMark(size:22,style:.monochrome)
                        Text(answer).font(.body).lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("以上为 AI 对近 14 天记录与阶段摘要的解读，不替代本地报告；依据缺失时本地结论优先。")
                            .font(.caption2).foregroundStyle(BojiColor.textTertiary)
                    }
                case "failed", "rejected", "expired":
                    Text("这次 AI 解读未能完成，本地阶段报告仍完整保留。可以稍后重试，或继续只看本地结论。")
                        .font(.footnote).foregroundStyle(BojiColor.textSecondary)
                default:
                    HStack(spacing: 8) { ClubActivityMark(size: 16); Text("正在整理可选解读，本地报告仍可阅读。").font(.footnote) }
                }
            }
            if let reviewError { Text(reviewError).font(.footnote).foregroundStyle(.red) }
            Button(reviewJobID == nil ? "用 Club AI 解读这份阶段回顾" : "重新请求一次解读") { requestPhaseAIReview() }
                .buttonStyle(SecondaryButton())
                .disabled(!ai.routingConsentGranted)
        }
    }

    private func requestPhaseAIReview() {
        guard ai.routingConsentGranted else {
            reviewError = "请先在“设置 → 云端分析与隐私”开启云端分析。"; return
        }
        guard let endDate = ClubDates.date(fromKey: report.end) else {
            reviewError = "阶段结束日期无法读取。"; return
        }
        let through = min(endDate, Date())
        let trends = report.trends.prefix(6).map { "\($0.name)：\($0.verdict)" }.joined(separator: "；")
        let question = """
        这是我 \(report.start) 至 \(report.end) 的阶段报告摘要：\(report.summary)。可比趋势：\(trends.isEmpty ? "样本不足" : trends)。请只依据随附近 14 天记录与这段摘要，用不超过三条指出：1）有记录支持的变化；2）仍缺少依据、不能判断的部分；3）下一阶段一个可执行的小行动。不要改写或否定本地阶段报告，不要编造未记录的数据、体脂或恢复评分。
        """
        let conversation = UUID(uuidString: String(report.id.suffix(36))) ?? UUID()
        do {
            let input = try ai.coachInput(question: question, conversation: conversation.uuidString.lowercased(),
                                          history: [], through: through, contextDays: 14, store: store)
            reviewJobID = try ai.submit(input)
            reviewError = nil
        } catch {
            reviewError = AppErrorText.message(error)
        }
    }
}
