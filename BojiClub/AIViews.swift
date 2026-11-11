import SwiftUI
import UIKit

private func feedbackAdaptive(_ light: UIColor, _ dark: UIColor) -> Color {
    Color(uiColor: UIColor { traits in traits.userInterfaceStyle == .dark ? dark : light })
}

private extension TrainingFeedback {
    // AUD-010/FIX-010：状态卡前景与背景成对定义。此前浅色固定卡面在深色
    // 外观里仍使用浅色正文，名义对比不足。
    var fillColor: Color {
        switch status {
        case "green": return feedbackAdaptive(UIColor(red: 234.0/255, green: 243.0/255, blue: 236.0/255, alpha: 1), UIColor(red: 34/255, green: 52/255, blue: 40/255, alpha: 1))
        case "yellow": return feedbackAdaptive(UIColor(red: 250.0/255, green: 241.0/255, blue: 216.0/255, alpha: 1), UIColor(red: 55/255, green: 47/255, blue: 26/255, alpha: 1))
        case "red": return feedbackAdaptive(UIColor(red: 248.0/255, green: 233.0/255, blue: 231.0/255, alpha: 1), UIColor(red: 57/255, green: 34/255, blue: 33/255, alpha: 1))
        default: return feedbackAdaptive(UIColor(red: 239.0/255, green: 240.0/255, blue: 241.0/255, alpha: 1), UIColor(red: 39/255, green: 41/255, blue: 44/255, alpha: 1))
        }
    }
    var inkColor: Color {
        switch status {
        case "green": return feedbackAdaptive(UIColor(red: 55.0/255, green: 98.0/255, blue: 71.0/255, alpha: 1), UIColor(red: 191/255, green: 227/255, blue: 200/255, alpha: 1))
        case "yellow": return feedbackAdaptive(UIColor(red: 112.0/255, green: 85.0/255, blue: 25.0/255, alpha: 1), UIColor(red: 236/255, green: 215/255, blue: 164/255, alpha: 1))
        case "red": return feedbackAdaptive(UIColor(red: 140.0/255, green: 63.0/255, blue: 56.0/255, alpha: 1), UIColor(red: 238/255, green: 190/255, blue: 185/255, alpha: 1))
        default: return feedbackAdaptive(UIColor(red: 79.0/255, green: 86.0/255, blue: 94.0/255, alpha: 1), UIColor(red: 188/255, green: 195/255, blue: 202/255, alpha: 1))
        }
    }
}

struct TrainingFeedbackBadge: View {
    let feedback: TrainingFeedback
    var large = false
    var body: some View {
        let value = feedback.presentation
        Label(value.title, systemImage: value.symbol)
            .font(large ? .system(size: 24, weight: .semibold) : .subheadline.weight(.semibold))
            .foregroundStyle(value.inkColor)
            .padding(.horizontal, large ? 16 : 11).padding(.vertical, large ? 9 : 6)
            .background(value.fillColor, in: Capsule())
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("训练反馈：" + value.title)
    }
}

struct TrainingFeedbackCard: View {
    let feedback: TrainingFeedback
    @ScaledMetric(relativeTo: .body) private var textSize: CGFloat = 18
    init(feedback: TrainingFeedback, baseSize: CGFloat = 18) {
        self.feedback = feedback
        _textSize = ScaledMetric(wrappedValue: baseSize, relativeTo: .body)
    }
    private var value: TrainingFeedback { feedback.presentation }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("训练反馈").bojiFont(.cardTitle).foregroundStyle(value.inkColor)
            TrainingFeedbackBadge(feedback: value)
            ForEach(value.evidence.indices, id: \.self) { index in
                Text(value.evidence[index]).font(.system(size: textSize)).foregroundStyle(BojiColor.textPrimary)
                    .lineSpacing(5).fixedSize(horizontal: false, vertical: true)
            }
            Divider().overlay(value.inkColor.opacity(0.1))
            Text("下一步").bojiFont(.cardTitle).foregroundStyle(value.inkColor)
            Text(value.next_step).font(.system(size: textSize)).foregroundStyle(BojiColor.textPrimary)
                .lineSpacing(5).fixedSize(horizontal: false, vertical: true)
            Text("依据已记录内容评价执行情况，动作标准与实际用力程度仍需本人核对。")
                .font(.footnote).foregroundStyle(value.inkColor)
            DisclosureGroup("颜色怎么看") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("浅绿：原目标组数均已登记完成；计时时长达到原目标的九成。实际秒数照实展示，不补写记录。")
                    Text("浅黄：训练已确认结束，仍有原目标组数或计时时长没有落实。")
                    Text("浅红：原目标至少六组而完成不足一半；或纯计时目标至少十分钟而实际不足一半。只在确认结束后评价。")
                    Text("浅灰：未确认、缺少对照、安排已调整或记录不足，暂不评价。休息日不参加训练评价。")
                    Text("重量大小和饮食是否记全，都不会直接改变训练颜色。")
                }.font(.footnote).foregroundStyle(value.inkColor).lineSpacing(4).padding(.top, BojiSpace.tightRow)
            }.font(.subheadline.weight(.medium)).tint(value.inkColor)
        }
        .padding(BojiSpace.pageInset).frame(maxWidth: .infinity, alignment: .leading)
        .background(value.fillColor, in: RoundedRectangle(cornerRadius: ClubUI.cardRadius, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

struct AIJobStatusView: View {
    let id: String?
    var animated = false
    @EnvironmentObject private var ai: AIService
    var body: some View {
        if let job = ai.job(id) {
            VStack(alignment: .leading, spacing: 8) {
                if ai.requiresRoutingConsent && job.request.payload["_routing_version"] == .number(2) && !job.isTerminal {
                    AIRoutingConsentView()
                } else if job.status == "discarded" {
                    Text(job.error ?? "这次分析不再使用，原记录仍保留。")
                } else if job.status == "succeeded" {
                    Label(job.consumed ? "结果已确认保存" : job.request.kind == "coach" ? "Club AI 回复已保存" : job.request.kind == "report" ? "复盘已完成，可以阅读全文" : "已准备好，请核对后保存", systemImage: "checkmark.circle")
                } else if ["failed", "waiting_connection", "waiting_service", "deleted", "expired", "rejected"].contains(job.status) {
                    Text(job.error ?? "输入已保存，可稍后重试。")
                    if job.isWaiting { AIWaitProgress(status: job.status) }
                    Button(["deleted", "expired", "rejected"].contains(job.status) ? "重新生成" : job.isWaiting ? "继续查看处理结果" : "重新尝试分析") { ai.retry(job.id) }.buttonStyle(SecondaryButton())
                } else {
                    AILoadingCard(title: job.request.kind == "food" ? "正在识别食物…" : job.request.kind == "coach" ? "Club AI 正在核对记录…" : job.request.kind == "report" ? "正在分析你的记录…" : "正在准备训练计划…",
                                  detail: "输入已保留，可以稍后回来查看。", status: job.status, compact: !animated)
                }
            }.font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct ReportCardSurface<Content: View>: View {
    let openReport: (() -> Void)?
    let embedded: Bool
    let content: Content
    init(openReport: (() -> Void)?, embedded: Bool = false, @ViewBuilder content: () -> Content) {
        self.openReport = openReport; self.embedded = embedded; self.content = content()
    }
    private var radius: CGFloat { embedded ? ClubUI.controlRadius : ClubUI.cardRadius }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(embedded ? ClubUI.cardInset : ClubUI.pageInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if let openReport {
                    Button(action: openReport) {
                        surface
                            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                    }.buttonStyle(ClubMotionButton()).accessibilityHidden(true)
                } else { surface }
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(embedded ? ClubUI.border : BojiColor.cardSurface, lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }
    @ViewBuilder private var surface: some View {
        if embedded {
            RoundedRectangle(cornerRadius: radius, style: .continuous).fill(ClubUI.insetSurface)
        } else {
            RoundedRectangle(cornerRadius: radius, style: .continuous).fill(.regularMaterial)
        }
    }
}

struct AIReportCard: View {
    let date: Date
    let log: DayLog
    var embedded = false
    @EnvironmentObject private var ai: AIService
    @EnvironmentObject private var store: AppStore
    @State private var error: String?
    @State private var readingReportID: String?
    @State private var shareDraft: ShareDraft?
    @State private var showIncompleteConfirmation = false
    @State private var confirmationContext: String?
    private var context: String { "\(store.editingAccountID ?? 0)/\(ClubDates.key(date))" }
    private var current: AILocalJob? {
        guard let input = try? ai.reportInput(date: date, log: log, nutritionTarget: store.reportNutritionTarget(on: date), weightHistory: store.bodyWeightPoints(through: date), goalContext: ClubAIContext.make(state: store.state, start: date, end: date)) else { return nil }
        guard let job = ai.matching(input), !(store.state.deletedAIJobIDs ?? []).contains(job.id) else { return nil }
        return job
    }
    var body: some View {
        let task = current
        let prior = ReportHistory.visible(ai.jobs, dateKey: ClubDates.key(date),
            deleted: Set(store.state.deletedAIJobIDs ?? [])).first
        let report = task?.status == "succeeded" && task?.result?.kind == "report" ? task : prior
        let openReport: (() -> Void)? = report.map { item in { readingReportID = item.id } }
        return ReportCardSurface(openReport: openReport, embedded: embedded) {
            SectionTitle(title: ClubDates.calendar.isDateInToday(date) ? "今日复盘" : "当日复盘", symbol: "sparkles").allowsHitTesting(false)
            if let report, let result = report.result {
                reportPreview(report, result: result, isPrevious: report.id != task?.id, showsUpdate: task?.status != "succeeded")
            } else {
                Text("完成 \(log.completedSets) 组训练，记录 \(log.meals.count) 餐。").font(.subheadline)
                Text(log.health?.hasData == true ? "结合训练、饮食和你确认分享的设备数据，看看哪些做得好、哪些需要调整。" : "认真记录的内容，值得一份具体的反馈。分析只依据实际记录；也可以先在健康入口核对并分享设备数据。")
                    .font(.subheadline).foregroundStyle(.secondary)
                NavigationLink("我的复盘档案") { ReportLibraryView(initialKind: .daily) }.buttonStyle(SecondaryButton()).font(.subheadline)
            }
            AIJobStatusView(id: task?.id, animated: true)
            if report == nil && task?.status != "succeeded" {
                analysisActionButton(title: ClubDates.calendar.isDateInToday(date) ? "生成今日复盘" : "生成当日复盘")
            }
            if !store.bodyWeightPoints(through: date).isEmpty {
                Text("也会参考实际登记的体重及近期测量历史，漏记日期保持缺失。").font(.caption).foregroundStyle(.secondary).allowsHitTesting(false)
            }
            if !ClubDates.isFuture(date) && !DailyReportEligibility.hasRecords(log) { Text(DailyReportEligibility.missingMessage).font(.subheadline).foregroundStyle(.secondary) }
            if ClubDates.isFuture(date) { Text("未来日期只能安排训练，到了当天再生成复盘。").font(.subheadline).foregroundStyle(.secondary) }
            if let error { Text(error).font(.subheadline).foregroundStyle(.secondary).allowsHitTesting(false) }
        }
        .navigationDestination(item: $readingReportID) { AIReportReaderView(jobID: $0) }
        .sheet(item: $shareDraft) { ShareCardPreview(draft: $0) }
        .alert("记录还不完整，先分析现有内容？", isPresented: $showIncompleteConfirmation) {
            Button("先分析现有记录") {
                guard confirmationContext == context else { confirmationContext = nil; return }
                confirmationContext = nil
                generateAnalysis()
            }
            Button("先补充记录", role: .cancel) { confirmationContext = nil }
        } message: {
            Text(DailyAnalysisReadiness.warnings(log).joined(separator: "\n\n"))
        }
        .onChange(of: store.editingAccountID) { _, _ in resetPresentation() }
        .onChange(of: ClubDates.key(date)) { _, _ in resetPresentation() }
    }
    private func resetPresentation() {
        readingReportID = nil; shareDraft = nil
        showIncompleteConfirmation = false; confirmationContext = nil; error = nil
    }
    private func generateAnalysis() {
        do {
            let input = try ai.reportInput(date: date, log: log, nutritionTarget: store.reportNutritionTarget(on: date), weightHistory: store.bodyWeightPoints(through: date), goalContext: ClubAIContext.make(state: store.state, start: date, end: date))
            if let task = current, ["failed", "waiting_connection", "waiting_service", "deleted", "expired", "rejected"].contains(task.status) {
                ai.retry(task.id)
            } else { _ = try ai.submit(input, forceNew: current?.status == "discarded") }
            error = nil
        } catch { self.error = AppErrorText.message(error) }
    }
    private func reportPreview(_ report: AILocalJob, result: AIResult, isPrevious: Bool, showsUpdate: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Text("核心结论 · 点击卡片查看完整分析").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                TrainingFeedbackBadge(feedback: result.training_feedback ?? .legacy)
                Text(result.summary ?? "").font(.body).lineSpacing(5).lineLimit(3)
                if isPrevious {
                    Label("记录或分析规则已有更新，下面保留的是此前分析。", systemImage: "clock.arrow.circlepath")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }.allowsHitTesting(false)
            NavigationLink("查看完整分析") { AIReportReaderView(jobID: report.id) }
                .buttonStyle(PrimaryButton()).tint(.primary)
            ReportPreviousAnalysesLink(dateKey: report.request.date)
            if showsUpdate {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        shareButton(result, dateKey: report.request.date)
                        analysisActionButton(title: "更新这份分析")
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        shareButton(result, dateKey: report.request.date)
                        analysisActionButton(title: "更新这份分析")
                    }
                }
            } else {
                shareButton(result, dateKey: report.request.date)
            }
        }
    }
    private func shareButton(_ result: AIResult, dateKey: String) -> some View {
        Button { prepareShare(result, dateKey: dateKey) } label: {
            Label("分享复盘", systemImage: "square.and.arrow.up")
                .frame(maxWidth: .infinity)
        }.font(.subheadline).buttonStyle(SecondaryButton())
    }
    private func analysisActionButton(title: String) -> some View {
        Button {
            if DailyAnalysisReadiness.warnings(log).isEmpty { generateAnalysis() }
            else { confirmationContext = context; showIncompleteConfirmation = true }
        } label: {
            Text(title).frame(maxWidth: .infinity)
        }
        .buttonStyle(SecondaryButton())
        .buttonBorderShape(.capsule)
        .disabled(ClubDates.isFuture(date) || !DailyReportEligibility.hasRecords(log) || (current.map { !$0.isTerminal && !$0.isWaiting } ?? false))
    }
    private func prepareShare(_ result: AIResult, dateKey: String) {
        // Share this report's content, without mixing later edits into its facts.
        guard let owner = store.editingAccountID else { return }
        let sections = ReportShareContent.sections(summary: result.summary, training: result.training,
            nutrition: result.nutrition, recovery: result.recovery)
        let card = ShareCardView(title: dateKey + " 日报", headline: result.summary ?? "",
            stats: [], tagline: "认真训练，认真记录。", sections: sections, trainingFeedback: result.training_feedback ?? .legacy)
        shareDraft = ShareDraft(card: card, ownerID: owner)
    }
}


struct AIReportHistoryView: View {
    @EnvironmentObject private var store: AppStore
    var dateKey: String? = nil
    var showsVersions = false
    @EnvironmentObject private var ai: AIService
    /// 指定日期没有日报时直接提交 report 任务并打开阅读页，不再绕回自由对话。
    @State private var dailyRoute: AIReportJobRoute?
    @State private var dailyError: String?
    private var reports: [AILocalJob] {
        ReportHistory.visible(ai.jobs, dateKey: dateKey, deleted: Set(store.state.deletedAIJobIDs ?? []))
    }
    var body: some View {
        Group {
            if dateKey != nil, !showsVersions, let report = reports.first {
                AIReportReaderView(jobID: report.id)
            } else if let dateKey, !showsVersions, let date = ClubDates.date(fromKey: dateKey) {
                emptyReportPrompt(date: date)
            } else { historyList }
        }
        .sheet(item: $dailyRoute) { route in
            NavigationStack {
                AIReportReaderView(jobID: route.id)
                    .background { ClubBackground() }
                    .navigationTitle("日报")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { DismissButton() } }
            }
        }
    }
    private func emptyReportPrompt(date: Date) -> some View {
        let log = store.log(for: date)
        return ScrollView {
            VStack(spacing: 14) {
                Text("这一天还没有日报").bojiFont(.cardTitle)
                Text("生成后会保留在这里，即使当天记录后来有改动。")
                    .font(.footnote).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if let dailyError {
                    Text(dailyError).font(.footnote).foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("生成当日日报") { generateDailyReport(for: date) }
                    .buttonStyle(PrimaryButton())
                    .disabled(!DailyReportEligibility.hasRecords(log))
            }
            .padding(ClubUI.pageInset)
            .frame(maxWidth: .infinity)
        }
        .background { ClubBackground() }
        .navigationTitle(ClubDates.calendar.isDateInToday(date) ? "今日日报" : "\(ClubDates.label(date, format: "M月d日"))日报")
        .navigationBarTitleDisplayMode(.inline)
    }
    private func generateDailyReport(for date: Date) {
        guard let owner = store.editingAccountID else {
            dailyError = "登录状态已变化，请重新打开报告库。"; return
        }
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
            dailyRoute = AIReportJobRoute(id: jobID)
        } catch { dailyError = AppErrorText.message(error) }
    }
    private var historyList: some View {
        List {
            if reports.isEmpty { Text("还没有生成过日报。已生成的报告会保留在这里，即使当天记录后来有改动。").foregroundStyle(.secondary) }
            ForEach(dateKey == nil ? ReportHistory.latestPerDay(reports) : reports) { job in
                NavigationLink {
                    AIReportReaderView(jobID: job.id)
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(job.request.date).bojiFont(.exerciseName).foregroundStyle(BojiColor.textPrimary)
                        Text(job.result?.summary ?? "").font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                        TrainingFeedbackBadge(feedback: job.result?.training_feedback ?? .legacy)
                        Text((job.id == reports.first(where: { $0.request.date == job.request.date })?.id ? "最新分析 · " : "此前分析 · ") + job.created.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        if dateKey == nil {
                            let versions = reports.filter { $0.request.date == job.request.date }.count
                            if versions > 1 { Text("当天重新分析过 \(versions - 1) 次，详情中可查看此前分析").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
        }.clubListSurface().navigationTitle(dateKey == nil ? "我的日报" : "此前分析").navigationBarTitleDisplayMode(.inline)
    }

}


struct ReportSectionText: View {
    let title: String
    let text: String?
    @ScaledMetric(relativeTo: .body) private var bodySize: CGFloat = 18
    init(title: String, text: String?, baseSize: CGFloat = 18) {
        self.title = title; self.text = text
        _bodySize = ScaledMetric(wrappedValue: baseSize, relativeTo: .body)
    }
    var body: some View {
        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                if !title.isEmpty {
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 2).fill(ClubBrand.accent).frame(width: 3, height: 18)
                        Text(title).bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
                    }
                }
                ForEach(ReportTextLayout.blocks(text)) { block in blockView(block) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, BojiSpace.tight)
        }
    }
    @ViewBuilder private func blockView(_ block: ReportTextBlock) -> some View {
        switch block.kind {
        case .heading:
            readable(block.text).font(.system(size: bodySize, weight: .semibold)).padding(.top, 4)
        case .bullet, .numbered:
            HStack(alignment: .top, spacing: 10) {
                Text(block.marker).font(.system(size: bodySize)).foregroundStyle(.secondary)
                    .frame(minWidth: 20, alignment: .trailing)
                readable(block.text).font(.system(size: bodySize))
            }
        case .paragraph:
            readable(block.text).font(.system(size: bodySize))
        }
    }
    private func readable(_ text: String) -> some View {
        let attributed = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        return Text(attributed).lineSpacing(7).foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
    }
}


struct AIRoutingConsentView: View {
    @EnvironmentObject private var ai: AIService
    @State private var showPrivacySheet = false
    var body: some View {
        ClubCard {
            Text("云端分析尚未开启").bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
            Text("为保护你的记录，这项 AI 任务暂时没有提交。你仍可手动记录；若要使用 AI，请在隐私说明中主动开启云端分析。")
            Button("开启云端分析") { showPrivacySheet = true }
                .buttonStyle(SecondaryButton())
            Button("取消待处理的云端任务", role: .cancel) { ai.declineRoutingConsent() }.buttonStyle(SecondaryButton())
                .font(.subheadline)
        }
        .font(.body).foregroundStyle(.primary)
        .sheet(isPresented: $showPrivacySheet) { LegalDocumentView(document: .privacy) }
    }
}

struct AIReportReaderView: View {
    let jobID: String
    @EnvironmentObject private var ai: AIService
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("report.reading.font-size") private var fontSize = 18
    @State private var ownerID: Int?
    @State private var shareDraft: ShareDraft?
    private var job: AILocalJob? {
        guard !(store.state.deletedAIJobIDs ?? []).contains(jobID), let job = ai.job(jobID),
              job.status == "succeeded", job.result?.kind == "report" else { return nil }
        return job
    }
    private var freshness: ReportFreshness {
        guard let job, let date = ClubDates.date(fromKey: job.request.date) else { return .unavailable }
        let input = try? ai.reportInput(date: date, log: store.log(for: date), nutritionTarget: store.reportNutritionTarget(on: date),
                                        weightHistory: store.bodyWeightPoints(through: date), goalContext: ClubAIContext.make(state: store.state, start: date, end: date), allowEmpty: true)
        return ReportFreshness.evaluate(request: job.request, current: input)
    }
    private var readingSize: CGFloat { CGFloat([16,18,20,22].contains(fontSize) ? fontSize : 18) }
    var body: some View {
        Group {
            ScrollView {
                if let job, let result = job.result {
                    VStack(alignment: .leading, spacing: 26) {
                        reportHeader(job)
                        ContextualTipView(screen: "report")
                        ReportSectionText(title: "今日结论", text: result.summary, baseSize: readingSize)
                        Divider()
                        TrainingFeedbackCard(feedback: result.training_feedback ?? .legacy, baseSize: readingSize)
                        ReportSectionText(title: "训练分析", text: result.training, baseSize: readingSize).id("training")
                        Divider()
                        ReportSectionText(title: "饮食分析", text: result.nutrition, baseSize: readingSize).id("nutrition")
                        Divider()
                        ReportSectionText(title: "恢复与下一步", text: result.recovery, baseSize: readingSize).id("recovery")
                        if let context = submittedGoalContext(job) {
                            ReportGoalContextView(context: context)
                        }
                        reportNotes(result.notes)
                        shareButton(job, result: result)
                        ReportPreviousAnalysesLink(dateKey: job.request.date)
                    }.padding(ClubUI.pageInset).frame(maxWidth: ClubUI.contentWidth).frame(maxWidth: .infinity, alignment: .center)
                } else {
                    ContentUnavailableView("这份日报已移除", systemImage: "doc.text", description: Text("返回后可以查看其他记录。"))
                        .padding(.top, 60)
                }
            }.background(Color(.systemBackground))
                .navigationTitle("日报").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Picker("阅读字号", selection: $fontSize) {
                                Text("紧凑").tag(16); Text("标准").tag(18)
                                Text("舒适").tag(20); Text("更大").tag(22)
                            }
                        } label: { Image(systemName: "textformat.size") }.accessibilityLabel("调整阅读字号")
                    }
                }
                .sheet(item: $shareDraft) { ShareCardPreview(draft: $0) }
                .onAppear { if ownerID == nil { ownerID = store.editingAccountID } }
                .onChange(of: store.editingAccountID) { _, id in if id != ownerID { shareDraft = nil; dismiss() } }
        }
    }
    @ViewBuilder
    private func reportNotes(_ notes: [String]) -> some View {
        if !notes.isEmpty {
            ClubCard {
                Text("分析依据与需要留意的地方").bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
                ForEach(notes.indices, id: \.self) { index in
                    ReportSectionText(title: "", text: notes[index], baseSize: readingSize)
                }
            }
        }
    }
    private func submittedGoalContext(_ job: AILocalJob) -> ClubAIContext? {
        guard let value = job.request.payload["goal_context"],
              let data = try? JSONEncoder().encode(value),
              let context = try? JSONDecoder().decode(ClubAIContext.self, from: data), context.version == 1 else { return nil }
        return context
    }
    private func shareButton(_ job: AILocalJob, result: AIResult) -> some View {
        Button { prepareShare(job, result: result) } label: {
            Label("分享这份分析", systemImage: "square.and.arrow.up")
        }.buttonStyle(SecondaryButton())
    }
    private func prepareShare(_ job: AILocalJob, result: AIResult) {
        guard let owner = store.editingAccountID, ownerID == owner else { return }
        let sections: [ReportShareSection] = ReportShareContent.sections(
            summary: result.summary, training: result.training,
            nutrition: result.nutrition, recovery: result.recovery)
        let card = ShareCardView(title: job.request.date + " 日报", headline: result.summary ?? "",
            stats: [], tagline: "认真训练，认真记录。", sections: sections, trainingFeedback: result.training_feedback ?? .legacy)
        shareDraft = ShareDraft(card: card, ownerID: owner)
    }
    private func reportHeader(_ job: AILocalJob) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            BojiBrandMark(size:24,style:.monochrome)
            Text(ClubDates.date(fromKey: job.request.date).map { ClubDates.label($0, format: "M月d日 EEEE") } ?? job.request.date)
                .bojiFont(.pageTitle).foregroundStyle(BojiColor.textPrimary)
            Text("根据 \(job.created.formatted(date: .abbreviated, time: .shortened)) 提交的记录分析")
                .font(.subheadline).foregroundStyle(.secondary)
            if freshness == .changed {
                Label("记录或分析设置已有更新。这份报告保留提交时的分析，可回到当天按最新记录重新分析。", systemImage: "clock.arrow.circlepath")
                    .font(.subheadline).lineSpacing(4).foregroundStyle(.secondary)
            } else {
                Text("基于提交时已经登记的内容分析；未记录的部分不代表没有发生。")
                    .font(.subheadline).foregroundStyle(.secondary).lineSpacing(4)
            }
        }
    }

}

private struct ReportGoalContextView: View {
    let context: ClubAIContext
    var body: some View {
        ClubCard {
            DisclosureGroup("本次分析使用的目标") {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(context.days, id: \.date) { day in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(day.date).font(.subheadline.weight(.semibold))
                            if let profile = day.profile {
                                Text("当时的目标：\(profile.goal) · \(profile.experience) · 每周计划 \(profile.daysPerWeek) 练")
                                if day.goalChangedDuringDay {
                                    Text("这一天调整过目标，以上是最后保存的资料，不代表全天都按它执行。")
                                }
                            } else {
                                Text("没有这一天的目标快照，不用今天的资料补写历史。")
                            }
                        }
                    }
                    Text("这是提交分析时保存的背景；资料体重不等于当天实测体重，计划安排不等于已完成。")
                        .foregroundStyle(.secondary)
                }.font(.subheadline).lineSpacing(4).padding(.top, BojiSpace.general)
            }
        }
    }
}

struct ReportPreviousAnalysesLink: View {
    let dateKey: String
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var ai: AIService
    private var count: Int { ReportHistory.visible(ai.jobs, dateKey: dateKey, deleted: Set(store.state.deletedAIJobIDs ?? [])).count }
    var body: some View {
        if count > 1 {
            NavigationLink { AIReportHistoryView(dateKey: dateKey, showsVersions: true) } label: {
                Label("查看此前分析 · \(count - 1) 份", systemImage: "clock.arrow.circlepath")
            }.buttonStyle(SecondaryButton())
        }
    }
}
