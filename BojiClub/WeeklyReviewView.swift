import SwiftUI
import PhotosUI
import UIKit

struct WeeklyReviewCenter: View {
    var initialCycle: TrainingCycle? = nil
    @EnvironmentObject private var weekly: WeeklyReviewService
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var ai: AIService
    @Environment(\.dismiss) private var dismiss
    @State private var selected: WeeklyReview?
    @State private var chosenCycle: TrainingCycle?
    @State private var showRuleHelp = false
    @State private var ownerID: Int?
    @State private var quickReportError: String?
    private var cycle: TrainingCycle { chosenCycle ?? TrainingCycle.preferred(days: store.state.days) }
    private var readiness: WeeklyReadiness { WeeklyReadiness(cycle: cycle, days: store.state.days) }
    private var entryTitle: String {
        let current = records.first { $0.date == cycle.end }
        if current?.result != nil { return "查看本周复盘" }
        if current != nil { return "继续填写本周反馈" }
        if !readiness.trainingReady { return "查看复盘条件" }
        return readiness.combinedReady ? "开始完整复盘" : "开始训练复盘"
    }
    private var records: [WeeklyReview] {
        WeeklyVersions.visible(days: store.state.days, local: weekly.reviews,
            deletedJobIDs: Set(store.state.deletedAIJobIDs ?? []))
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    FlowHeading(eyebrow: "YOUR WEEK, IN PERSPECTIVE", title: "本周训练总结", subtitle: "查看本周记录，再决定是否调整下周训练。")
                    Picker("训练周期", selection: Binding(get: { cycle.id }, set: { id in chosenCycle = TrainingCycle.available(days: store.state.days).first { $0.id == id } })) {
                        ForEach(TrainingCycle.available(days: store.state.days)) { value in Text(value.label).tag(value.id) }
                    }.pickerStyle(.menu)
                    WeeklyCoverageCard(cycle: cycle)
                    ClubCard {
                        Text("下一步由你决定").bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
                        Button(entryTitle) {
                            guard readiness.trainingReady || records.contains(where: { $0.date == cycle.end }) else { showRuleHelp = true; return }
                            if let existing = records.first(where: { $0.date == cycle.end }) { selected = existing }
                            else {
                                var review = WeeklyReview(date: cycle.end)
                                review.cycle = cycle; review.scope = readiness.combinedReady ? "combined" : "training"
                                review.survey.days = store.state.profile.daysPerWeek
                                review.survey.trainingDays = store.state.profile.trainingDays ?? Array([1,3,5,2,4,6,7].prefix(store.state.profile.daysPerWeek))
                                if weekly.save(review) { selected = review }
                            }
                        }.buttonStyle(PrimaryButton())
                        quickWeeklyReportSection
                        if let notice = readiness.adjustmentNotice { Text(notice).font(.subheadline).foregroundStyle(.secondary) }
                        Text("支持结合问卷调整下周计划，或一键生成周度记录报告。").font(.footnote).foregroundStyle(.secondary)
                    }
                    ClubCard {
                        DisclosureGroup("提醒与隐私设置") {
                        Toggle("每周提醒我", isOn: Binding(get: { weekly.reminder }, set: { enabled in Task { await weekly.setReminder(enabled, weekday: weekly.weekday) } }))
                        Picker("提醒日 · 19:00", selection: Binding(get: { weekly.weekday }, set: { day in Task { await weekly.setReminder(weekly.reminder, weekday: day) } })) {
                            ForEach(Array(["周日","周一","周二","周三","周四","周五","周六"].enumerated()), id: \.offset) { i, day in Text(day).tag(i+1) }
                        }
                        Text("提醒只在这台设备设置。照片留在本机，完成的复盘摘要会同步到账号。")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    }
                    Text("复盘时间轴").bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
                    if records.isEmpty { EmptyNote(title: "从这周开始", detail: "先看执行与感受，照片变化更适合跨多周比较。") }
                    ForEach(records) { review in
                        Button { selected = review } label: {
                            ClubCard {
                                HStack { Text(review.date).bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary); Spacer(); Text(review.result == nil ? "草稿 / 待完成" : "已完成").font(.caption) }
                                Text(review.result?.summary ?? "继续填写身体感受与训练反馈。")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(3).multilineTextAlignment(.leading)
                                HStack {
                                    ForEach(review.photos) { photo in
                                        if let data = weekly.photo(photo) {
                                            ClubPhotoPreview(data: data, pixels: 216).frame(width: 55,height: 72).clipped().clipShape(RoundedRectangle(cornerRadius: 8))
                                        }
                                    }
                                }
                            }
                        }.buttonStyle(ClubMotionButton())
                    }
                    if let message = weekly.message { Text(message).font(.caption).foregroundStyle(.secondary) }
                }.padding(ClubUI.pageInset)
            }.background { ClubBackground() }
                .navigationTitle("每周回顾").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                .sheet(item: $selected) { WeeklyReviewDetail(initial: $0) }
                .onAppear { if ownerID == nil { ownerID = store.editingAccountID }; if chosenCycle == nil { chosenCycle = initialCycle } }
                .onChange(of: store.editingAccountID) { _, id in if id != ownerID { selected = nil; dismiss() } }
                .alert("什么时候可以生成复盘？", isPresented: $showRuleHelp) { Button("知道了") { } } message: { Text(readiness.explanation) }
        }.tint(ClubBrand.accent)
    }

    @ViewBuilder private var quickWeeklyReportSection: some View {
        let owner = ownerID ?? store.editingAccountID ?? 0
        let jobID = owner > 0 ? ClubAutomaticReports.jobID(owner: owner, mode: "weekly", key: cycle.end) : nil
        if let jobID, ai.job(jobID) != nil {
            NavigationLink {
                ClubAutomaticReportReader(jobID: jobID)
            } label: {
                Label("查看本周免问卷 AI 记录报告", systemImage: "doc.text.magnifyingglass")
            }
            .buttonStyle(SecondaryButton())
        } else if readiness.trainingDays >= 1 || readiness.foodDays >= 1 {
            Button {
                requestQuickWeeklyReport(jobID: jobID)
            } label: {
                Label("免填问卷 · 直接生成本周记录报告", systemImage: "sparkles")
            }
            .buttonStyle(SecondaryButton())
            if let quickReportError {
                Text(quickReportError).font(.footnote).foregroundStyle(.red)
            }
        }
    }

    private func requestQuickWeeklyReport(jobID: String?) {
        guard ai.routingConsentGranted else {
            quickReportError = "请先在“设置 → 云端分析与隐私”开启云端分析。"; return
        }
        guard let jobID, let endDate = ClubDates.date(fromKey: cycle.end) else {
            quickReportError = "当前账号或周期日期未就绪。"; return
        }
        let through = min(endDate, Date())
        let scope = ClubReviewScope.make(.rolling7, through: through)
        let actualJobID = ClubAutomaticReports.jobID(owner: ownerID ?? store.editingAccountID ?? 0, mode: "weekly", key: scope.to)
        do {
            var input = try ai.coachInput(
                question: "生成截至请求日期这七天的记录成长报告：训练执行、饮食覆盖、身体测量趋势、最值得肯定与最需要改正的行为、下一周一件事。此前额外七天仅作为上一周对照，缺少可比数据时说明，不合并成两周评价。专业直白、有适度幽默；不代填感受，不把缺记录当未完成。",
                conversation: actualJobID,
                history: [],
                through: through,
                contextDays: 14,
                store: store
            )
            input.payload["purpose"] = .string("weekly")
            input.payload["review_scope"] = try JSONValue.encode(scope)
            _ = try ai.submit(input, submissionID: actualJobID)
            quickReportError = nil
        } catch {
            quickReportError = AppErrorText.message(error)
        }
    }
}

#if DEBUG
/// Completed reports remain readable without routes to new paid work or plan changes.
struct WeeklyReviewHistoryView: View {
    @EnvironmentObject private var weekly: WeeklyReviewService
    @EnvironmentObject private var store: AppStore
    var dateKey: String? = nil
    private var records: [WeeklyReview] {
        WeeklyVersions.visible(days: store.state.days, local: weekly.reviews,
            deletedJobIDs: Set(store.state.deletedAIJobIDs ?? []))
            .filter { $0.result != nil && (dateKey == nil || $0.date == dateKey) }
    }
    var body: some View {
        List {
            if records.isEmpty { Text("暂无已完成的每周回顾。已有文字结果会在这里保留。") }
            ForEach(records) { review in
                NavigationLink {
                    WeeklyReviewHistoryDetail(review: review)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(review.date).bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
                        Text(review.result?.summary ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    }
                }
            }
        }.clubListSurface().navigationTitle("历史每周回顾").navigationBarTitleDisplayMode(.inline)
    }
}
#endif

struct WeeklyReviewHistoryDetail: View {
    let review: WeeklyReview
    @EnvironmentObject private var weekly: WeeklyReviewService
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("report.reading.font-size") private var fontSize = 18
    @State private var ownerID: Int?
    @State private var shareDraft: ShareDraft?
    @State private var contextSource: ClubContextSource?
    private var current: WeeklyReview? {
        WeeklyVersions.visible(days: store.state.days, local: weekly.reviews,
            deletedJobIDs: Set(store.state.deletedAIJobIDs ?? [])).first { $0.id == review.id }
    }
    private var readingSize: CGFloat { CGFloat([16,18,20,22].contains(fontSize) ? fontSize : 18) }
    var body: some View {
        ScrollView {
            if let current, let result = current.result {
                article(current, result: result)
            } else {
                ContentUnavailableView("这份周报已移除", systemImage: "doc.text", description: Text("返回报告列表，查看其他分析。"))
                    .padding(.top, 60)
            }
        }.background(Color(.systemBackground))
            .navigationTitle("每周复盘").navigationBarTitleDisplayMode(.inline)
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
    private func article(_ current: WeeklyReview, result: WeeklyResult) -> some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 12) {
                BojiBrandMark(size:24,style:.monochrome)
                    .foregroundStyle(LinearGradient(colors: [.blue, .purple, .pink], startPoint: .leading, endPoint: .trailing))
                Text("这一周的认真，\n有迹可循。").bojiFont(.pageTitle).foregroundStyle(BojiColor.textPrimary)
                Text(current.cycle?.label ?? "截至 \(current.date) 的七天").bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
                Text("保存于 \(current.updatedAt.formatted(date: .abbreviated, time: .shortened)) · 根据当时提交的记录分析")
                    .font(.subheadline).foregroundStyle(.secondary).lineSpacing(4)
            }
            ReportSectionText(title: "本周结论", text: result.summary, baseSize: readingSize)
            Divider()
            ReportSectionText(title: "训练执行", text: result.training, baseSize: readingSize)
            ReportSectionText(title: "饮食记录", text: result.nutrition, baseSize: readingSize)
            ReportSectionText(title: "身体反馈与恢复", text: result.recovery, baseSize: readingSize)
            ReportSectionText(title: "照片观察", text: result.appearance, baseSize: readingSize)
            Divider()
            ReportSectionText(title: "接下来怎么做", text: result.reason, baseSize: readingSize)
            if !(result.photoFeedback + result.notes).isEmpty {
                ClubCard {
                    Text("分析依据与需要留意的地方").bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
                    ForEach(Array((result.photoFeedback + result.notes).enumerated()), id: \.offset) { _, text in
                        ReportSectionText(title: "", text: text, baseSize: readingSize)
                    }
                }
            }
            if !result.sessions.isEmpty {
                DisclosureGroup("当时建议的训练安排 · 仅供回看") {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(Array(result.sessions.enumerated()), id: \.offset) { _, session in
                            Text(session.date + " · " + PlanDisplayCopy.heading(session.label)).bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
                            ForEach(Array(session.exercises.enumerated()), id: \.offset) { _, exercise in
                                Text(exercise.displayName + " · \(exercise.sets.count) 组").font(.body)
                            }
                        }
                    }.padding(.top, BojiSpace.workoutCardInset)
                }
            }
            if !current.photos.isEmpty {
                DisclosureGroup("本机保存的复盘照片") {
                    ForEach(current.photos) { photo in
                        if let data = weekly.photo(photo) { ClubPhotoPreview(data: data, pixels: 900).frame(height: 260) }
                    }
                }
            }
            Button { prepareShare(current, result: result) } label: {
                Label("分享这份分析", systemImage: "square.and.arrow.up")
            }.buttonStyle(SecondaryButton())
            if let jobID = current.jobID {
                Button {
                    contextSource = ClubContextSource(type: "weekly", jobID: jobID, version: nil, sessionID: nil,
                                                      title: "继续问这份每周回顾")
                } label: {
                    Label("继续问 AI", systemImage: "bubble.left.and.bubble.right")
                }.buttonStyle(SecondaryButton())
            }
        }.padding(ClubUI.pageInset).frame(maxWidth: ClubUI.contentWidth).frame(maxWidth: .infinity, alignment: .center)
        .sheet(item: $contextSource) { source in ContextAskView(source: source) }
    }
    private func prepareShare(_ current: WeeklyReview, result: WeeklyResult) {
        guard let owner = ownerID, owner == store.editingAccountID else { return }
        let sections = ReportShareContent.sections(summary: result.summary, training: result.training,
            nutrition: result.nutrition, recovery: result.recovery, planReason: result.reason)
        let card = ShareCardView(title: current.date + " 每周复盘", headline: result.summary,
            stats: [], tagline: "把进步交给时间。", sections: sections)
        shareDraft = ShareDraft(card: card, ownerID: owner)
    }
}

private struct ReviewImageInput: Identifiable {
    let id = UUID()
    let image: UIImage
    let pose: String
}

struct WeeklyReviewDetail: View {
    let initial: WeeklyReview
    @EnvironmentObject private var weekly: WeeklyReviewService
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var ai: AIService
    @EnvironmentObject private var account: AccountService
    @Environment(\.dismiss) private var dismiss
    @State private var survey = WeeklySurvey()
    @State private var loaded = false
    @State private var pose = "正面"
    @State private var photoItem: PhotosPickerItem?
    @State private var picking = false
    @State private var camera = false
    @State private var capturedImage: UIImage?
    @State private var choosingSource = false
    @State private var imageInput: ReviewImageInput?
    @State private var confirmSubmit = false
    @State private var confirmDelete = false
    @State private var confirmRemovePhotos = false
    @State private var compare = false
    @State private var error: String?
    @State private var showMyPlans = false
    @State private var showPrivacySettings = false
    @State private var scope = "combined"
    @State private var updatedDraft: WeeklyReview?
    @State private var ownerID: Int?
    @State private var contextSource: ClubContextSource?
    private var ownsAccount: Bool { ownerID != nil && ownerID == store.editingAccountID }
    private var cycle: TrainingCycle { review.cycle ?? TrainingCycle(start: ClubDates.key(ClubDates.calendar.date(byAdding: .day, value: -6, to: ClubDates.date(fromKey: review.date) ?? Date())!), plannedDates: []) }
    private var readiness: WeeklyReadiness { WeeklyReadiness(cycle: cycle, days: store.state.days) }
    private var review: WeeklyReview {
        if let local = weekly.reviews.first(where: { $0.id == initial.id }) { return local }
        if let cloud = store.state.days[initial.date]?.weeklyReview,
           cloud.id == initial.id || (initial.jobID != nil && cloud.jobID == initial.jobID) { return cloud }
        return initial
    }
    private var previous: WeeklyReview? { weekly.reviews.filter { $0.date < review.date && !$0.photos.isEmpty && $0.result != nil }.sorted { $0.date > $1.date }.first }
    private var editable: Bool { ownsAccount && review.result == nil && review.jobID == nil && !weekly.busy }
    private var valid: Bool {
        !survey.fatigue.isEmpty && !survey.difficulty.isEmpty && !survey.pain.isEmpty && (scope == "training" || !survey.diet.isEmpty) &&
        (survey.weight.map { $0.isFinite && (20...400).contains($0) } ?? true) &&
        (survey.waist.map { $0.isFinite && (30...250).contains($0) } ?? true) &&
        (survey.bodyFat.map { $0.isFinite && (2...75).contains($0) && !survey.bodyFatSource.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty } ?? true) && survey.notes.count <= 500
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("截至 \(review.date) 的七天记录").font(.caption).foregroundStyle(.secondary)
                    if let result = review.result {
                        resultContent(result).clubReveal()
                    } else {
                        WeeklyCoverageCard(cycle: cycle)
                        if editable {
                            ClubCard {
                                Text("1 · 选择复盘范围").bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
                                Picker("分析范围", selection: $scope) {
                                    Text("训练＋饮食").tag("combined"); Text("仅训练").tag("training")
                                }.clubAdaptivePicker()
                                Text(scope == "training" ? "分析训练执行与恢复；不对饮食是否达标作评价。" : "需要达到训练条件，并有至少 3 天已确认记完且营养数据完整的饮食。").font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        surveyContent.disabled(!editable)
                        ClubCard { DisclosureGroup("身体照片 · 可选") { photoContent } }.disabled(!editable)
                        ClubCard {
                            Text("生成后可查看本周执行总结、身体反馈与下周调整建议。")
                                .font(.caption).foregroundStyle(.secondary)
                            if review.jobID == nil {
                                if !valid { Text("请回答疲劳、难度、疼痛及适用的饮食问题；测量数据可留空，体脂填写后需注明来源。").font(.footnote).foregroundStyle(.secondary) }
                                Button(ai.routingConsentGranted ? (scope == "training" ? "生成训练复盘" : "生成综合复盘") : "前往隐私说明开启云端分析") {
                                    guard ai.routingConsentGranted else { showPrivacySettings = true; return }
                                    guard readiness.allowed(scope: scope) else { error = readiness.explanation; return }
                                    guard valid else { error = "还需要回答疲劳、训练难度、疼痛和适用的饮食问题。测量数据可以留空。"; return }
                                    confirmSubmit = true
                                }.buttonStyle(PrimaryButton()).disabled(weekly.busy)
                                if !ai.routingConsentGranted { Text("开启后返回这里即可生成；不开启时，问卷、训练记录与照片不会提交给 AI 服务。").font(.footnote).foregroundStyle(.secondary) }
                                if !readiness.allowed(scope: scope) { Text(readiness.explanation).font(.footnote).foregroundStyle(.secondary) }
                            } else {
                                Text("分析进度：\(review.statusLabel)").font(.caption)
                                if ["failed", "deleted", "expired", "rejected"].contains(review.status) {
                                    Button("保留问卷与照片，修改后重试") { weekly.prepareRetry(review.id) }.buttonStyle(SecondaryButton()).disabled(weekly.busy)
                                } else { Button("继续查询结果") { weekly.resume(review.id, account: account, store: store) }.buttonStyle(SecondaryButton()).disabled(weekly.busy) }
                            }
                            if weekly.busy && review.jobID != nil && !["succeeded", "failed", "deleted", "expired", "rejected"].contains(review.status) {
                                AILoadingCard(title: review.statusLabel, detail: "问卷与输入已保留，可以返回其他页面，稍后查看结果。", status: review.status)
                            }
                        }
                    }
                    if let message = weekly.message { Text(message).font(.caption).foregroundStyle(.secondary) }
                    if let error { Text(error).font(.caption).foregroundStyle(.red) }
                    Button("删除这份复盘及本机照片", role: .destructive) { confirmDelete = true }.buttonStyle(DestructiveButton())
                }.padding(ClubUI.pageInset)
            }.background { ClubBackground() }
                .navigationTitle("每周回顾").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement:.confirmationAction) { Button("完成") { if !editable || saveDraft() { dismiss() } } } }
                .onAppear {
                    if ownerID == nil { ownerID = store.editingAccountID }
                    if !loaded {
                        survey = review.survey
                        if survey.trainingDays == nil { survey.trainingDays = Array([1,3,5,2,4,6,7].prefix(min(7, max(1, survey.days)))) }
                        survey.days = survey.trainingDays?.count ?? survey.days
                        scope = review.scope ?? (readiness.combinedReady ? "combined" : "training"); compare = review.compareWith != nil; loaded = true
                    }
                }
                .task(id: try? JSONEncoder().encode(survey)) {
                    do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
                    guard !Task.isCancelled else { return }; saveDraft()
                }
                .onDisappear { saveDraft() }
                .onChange(of: store.editingAccountID) { _, id in
                    if id != ownerID { camera = false; capturedImage = nil; imageInput = nil; photoItem = nil; dismiss() }
                }
                .onChange(of: compare) { _, _ in saveDraft() }
                .onChange(of: scope) { _, _ in saveDraft() }
                .sheet(isPresented: $showMyPlans) { TrainingPlansView(focusDate: ClubDates.date(fromKey: cycle.end) ?? Date()) }
                .sheet(isPresented: $showPrivacySettings) { LegalDocumentView(document: .privacy) }
                .sheet(item: $updatedDraft) { WeeklyReviewDetail(initial: $0) }
                .confirmationDialog("选择\(pose)照片", isPresented: $choosingSource, titleVisibility: .visible) {
                    Button("倒计时拍照") { camera = true }
                    Button("从相册选择") { picking = true }
                }
                .photosPicker(isPresented: $picking, selection: $photoItem, matching: .images)
                .task(id: photoItem) {
                    guard let photoItem else { return }
                    do {
                        guard let data = try await photoItem.loadTransferable(type: Data.self), let image = await ClubImage.preview(data, pixels: 1800), !Task.isCancelled else { return }
                        guard ownsAccount else { return }
                        imageInput = ReviewImageInput(image: image, pose: pose)
                    } catch { self.error = AppErrorText.message(error) }
                }
                .fullScreenCover(isPresented: $camera, onDismiss: {
                    if let capturedImage { imageInput = ReviewImageInput(image: capturedImage, pose: pose); self.capturedImage = nil }
                }) { WeeklyCamera(pose: pose, reference: previous?.photos.first(where: { $0.pose == pose }).flatMap { weekly.photo($0) }.flatMap { ClubImage.downsample($0,pixels:900) }) { image in
                    capturedImage = image
                    camera = false
                } }
                .sheet(item: $imageInput) { input in
                    ReviewPhotoEditor(image: input.image, pose: input.pose) { data in
                        guard ownsAccount else { throw AccountError.message("账号已切换，请在当前账号重新打开复盘。") }
                        try weekly.addPhoto(data, pose: input.pose, to: review.id)
                    }
                }
                .confirmationDialog("确认生成本周回顾？", isPresented: $confirmSubmit, titleVisibility: .visible) {
                    Button("确认并开始分析") { if saveDraft() { weekly.submit(review.id, account: account, store: store, ai: ai) } }
                } message: {
                    Text("将上传本周训练、饮食、实际登记的体重及近期测量历史、已分享健康汇总和问卷。\(review.photos.isEmpty && !compare ? "本次不含照片；将进行云端文字分析。" : "本次包含你选择的身体照片和对比照片，仅交给支持图片分析的服务，失败时尝试备用服务。")按 DeepSeek、MiniMax 顺序尝试，图片只由支持图片的服务分析。照片不进入管理后台，任务完成或最终失败后清除服务端任务中的图片；处理中的照片不能从已送达的模型处撤回。复盘摘要会同步云端。")
                }
                .confirmationDialog("删除这份复盘的本机照片？", isPresented: $confirmRemovePhotos, titleVisibility: .visible) {
                    Button("删除本机照片", role: .destructive, action: removeLocalPhotos).disabled(weekly.busy)
                    Button("保留照片", role: .cancel) { }
                } message: {
                    Text("本次照片不会同步到其他手机，删除后无法从云端恢复。已经生成的分析文字保留；仍被其他复盘使用的照片文件也会保留。")
                }
                .confirmationDialog("删除复盘？", isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button("删除复盘与照片", role: .destructive) { Task {
                        await weekly.delete(review, account: account, store: store)
                        if !weekly.reviews.contains(where: { $0.id == initial.id }) && store.state.days[initial.date]?.weeklyReview?.id != initial.id { dismiss() }
                    } }
                } message: { Text("将清除本机照片、服务端复盘任务及账号中的复盘摘要。需要联网完成；已经采用的训练安排继续保留。") }
        }.tint(ClubBrand.accent)
    }
    @discardableResult
    private func saveDraft() -> Bool {
        guard ownsAccount, loaded, editable, weekly.reviews.contains(where: { $0.id == review.id }) else { return false }
        var copy = review; copy.survey = survey; copy.scope = scope; copy.cycle = cycle; copy.compareWith = compare ? previous?.id : nil; copy.updatedAt = Date(); return weekly.save(copy)
    }
    private var surveyContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            ClubCard {
                Text("2 · 这周的真实感受").bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
                Text("按本周真实体感选择即可。").font(.footnote).foregroundStyle(.secondary)
                ReviewQuestion(title: "训练后到第二天，疲劳是否影响日常生活？", detail: "回想整周整体感受，不只看最后一次训练。", options: ["轻松","适中","明显疲劳"], selection: $survey.fatigue)
                ReviewQuestion(title: "完成计划的难度如何？", detail: "以动作可控、能完成计划组数为参考。", options: ["偏轻松","合适","偏困难"], selection: $survey.difficulty)
                ReviewQuestion(title: "是否出现疼痛或不适？", detail: "不确定时如实选择；疼痛不是训练有效的证明。", options: ["无疼痛","有疼痛","不确定"], selection: $survey.pain)
                if scope != "training" { ReviewQuestion(title: "这周的饮食安排容易坚持吗？", detail: "反馈饥饿感、生活安排和执行困难，不能仅按记录数量判断。", options: ["容易坚持","基本能坚持","难以坚持","记录不完整"], selection: $survey.diet) }
                TextField("补充感受或疼痛部位（选填）", text: $survey.notes, axis: .vertical).lineLimit(3...6).textFieldStyle(.roundedBorder)
                    .onChange(of: survey.notes) { _, value in if value.count > 500 { survey.notes = String(value.prefix(500)) } }
            }
            ClubCard {
                DisclosureGroup("补充测量 · 可跳过") {
                    optionalNumber("实测体重 kg", value: $survey.weight)
                    optionalNumber("腰围 cm", value: $survey.waist)
                    optionalNumber("实测体脂 %", value: $survey.bodyFat)
                    if survey.bodyFat != nil { TextField("测量来源，例如体脂秤", text: $survey.bodyFatSource).textFieldStyle(.roundedBorder) }
                    Text("每日已登记的体重会自动用于分析，不必再填。这里仅填写已有测量，不从照片推算。").font(.footnote).foregroundStyle(.secondary)
                }
            }
            ClubCard {
                Text("3 · 下周能够训练的时间").bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
                Text("请选择实际做得到的日期。调整计划会遵守这些日期，预览确认后才保存。").font(.footnote).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 58))], spacing: 8) {
                    ForEach(1...7, id: \.self) { day in
                        let selected = (survey.trainingDays ?? store.state.profile.trainingDays ?? [1,3,5]).contains(day)
                        Button("周" + ["一","二","三","四","五","六","日"][day-1]) {
                            var days = Set(survey.trainingDays ?? store.state.profile.trainingDays ?? [1,3,5])
                            if days.contains(day) { if days.count > 1 { days.remove(day) } } else { days.insert(day) }
                            survey.trainingDays = days.sorted(); survey.days = days.count
                        }.buttonStyle(ClubSelectionButtonStyle(selected: selected)).accessibilityAddTraits(selected ? [.isSelected] : [])
                    }
                }
            }
        }
    }
    private var photoContent: some View {
        ClubCard {
            SectionTitle(title: "身体照片（可选，先保存在这台手机）", symbol: "camera")
            Text("请穿合身运动服自然站立拍摄，保持相近光线与距离，无需脱衣。")
                .font(.caption).foregroundStyle(.secondary)
            if store.state.profile.age >= 18 {
                HStack(alignment: .top) {
                    ForEach(["正面","背面","侧面"],id:\.self) { position in
                        Button { pose = position; choosingSource = true } label: {
                            VStack(spacing: 8) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: BojiRadius.inner).fill(.black.opacity(0.04))
                                    if let photo = review.photos.first(where: { $0.pose == position }), let data = weekly.photo(photo) {
                                        ClubPhotoPreview(data: data, pixels: 600)
                                    } else { Image(systemName: "figure.stand").font(.system(size: 42,weight:.ultraLight)).foregroundStyle(.secondary) }
                                }.frame(height: 140).clipShape(RoundedRectangle(cornerRadius: BojiRadius.inner))
                                Text(position + (position == "侧面" ? "（可选）" : "")).font(.caption)
                            }.frame(maxWidth:.infinity)
                        }.buttonStyle(ClubMotionButton())
                    }
                }
                if !review.photos.isEmpty { Button("移除本次照片，改为文字复盘", role: .destructive) { confirmRemovePhotos = true }.buttonStyle(DestructiveButton()).disabled(weekly.busy) }
                if let previous {
                    Toggle("加入 \(previous.date) 的照片作对比",isOn:$compare).font(.caption)
                    HStack { ForEach(previous.photos) { photo in
                        if let data = weekly.photo(photo) { ClubPhotoPreview(data:data, pixels:270).frame(height:90) }
                    } }
                }
            } else { Text("未成年账号使用无照片的训练与饮食复盘。").font(.caption) }
            Text("照片先保存在这台手机，不会同步到其他设备。提交复盘分析前会另行确认。更换手机无法恢复这些本机照片。")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
    private func resultContent(_ result: WeeklyResult) -> some View {
        VStack(alignment:.leading,spacing:18) {
            ClubCard { Text(result.summary).bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary); Text("\(review.date) · 每周回顾").font(.caption).foregroundStyle(.secondary) }
            if review.recoveredWithoutContext == true {
                Text("已恢复分析结果，原问卷和计划对比资料尚未恢复。联网同步后会继续合并；当前不会用空白问卷覆盖原记录。").font(.caption).foregroundStyle(.secondary)
            } else if store.state.days[review.date]?.weeklyReview?.id != review.id {
                Button("保存复盘摘要到云端") { if !store.saveWeeklyReview(review) { error = store.takeMessage() } }.buttonStyle(SecondaryButton())
            }
            ClubCard {
                resultLine("训练执行", result.training); resultLine("饮食记录",result.nutrition)
                resultLine("身体反馈与恢复", result.recovery)
                if !review.photos.isEmpty || review.compareWith != nil { resultLine("照片观察", result.appearance) }
                ForEach(Array((result.photoFeedback + result.notes).enumerated()),id:\.offset) { _, text in Text(text).font(.caption).foregroundStyle(.secondary) }
            }
            ClubCard {
                Text(result.decision == "adjust" ? "下周有一份调整建议" : result.decision == "keep" ? "建议保持当前安排" : "先补充依据，再调整").bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
                Text(result.reason).font(.subheadline)
                Text("建议已收进“我的计划”。在那里查看原安排与调整，预览后再确认下一周。").font(.subheadline).foregroundStyle(.secondary)
                if result.decision == "adjust" && review.baseline.isEmpty {
                    Text("原计划对比资料尚未恢复，暂不能采用调整；仍可以继续现有计划。").font(.footnote).foregroundStyle(.secondary)
                }
                if store.hasAppliedAIJob("weekly/" + review.id.uuidString) {
                    Label("已采用这份复盘的调整", systemImage: "checkmark.circle").font(.subheadline)
                }
                Button("查看我的计划") { showMyPlans = true }.buttonStyle(SecondaryButton())
            }
            Button("补充了记录？更新本周期复盘") {
                var copy = review; copy.id = UUID(); copy.jobID = nil; copy.result = nil; copy.status = "draft"
                copy.inputFingerprint = nil; copy.applied = false; copy.baseline = [:]; copy.priorJobIDs = nil; copy.updatedAt = Date()
                if weekly.save(copy) { updatedDraft = copy }
            }.buttonStyle(SecondaryButton())
            if !review.photos.isEmpty {
                ClubCard { Text("本次本机照片").bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary); HStack { ForEach(review.photos) { photo in
                    if let data = weekly.photo(photo) { ClubPhotoPreview(data:data, pixels:540).frame(maxHeight:180) }
                } }; Button("仅删除本机照片", role: .destructive) { confirmRemovePhotos = true }.buttonStyle(DestructiveButton()).disabled(weekly.busy) }
            }
        }
    }
    private func removeLocalPhotos() {
        guard ownsAccount else { error = "账号已切换，请重新打开这份复盘。"; return }
        guard !weekly.busy else { error = "正在处理复盘，请稍后再删除照片。"; return }
        guard weekly.reviews.contains(where: { $0.id == review.id }) else {
            error = "这台手机没有这份复盘的本机照片，请重新打开核对。"; return
        }
        do {
            try weekly.removePhotos(review.id)
            compare = false
            ClubAccessibility.announce("这份复盘的本机照片已移除。")
        } catch { self.error = AppErrorText.message(error) }
    }
    private func resultLine(_ title:String,_ text:String) -> some View { ReportSectionText(title: title, text: text) }
    private func optionalNumber(_ title:String,value:Binding<Double?>) -> some View { HStack { Text(title).font(.subheadline); Spacer(); TextField("未填写",value:value,format:.number).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(minWidth:105, maxWidth:150).accessibilityLabel(title) } }
}

struct WeeklyPlanPreview: View {
    let review: WeeklyReview
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var weekly: WeeklyReviewService
    @Environment(\.dismiss) private var dismiss
    @State private var sessions: [AIPlanSession] = []
    @State private var selected = Set<String>()
    @State private var replaceWholeWeek = true
    private var restDates: [String] {
        guard let end = ClubDates.date(fromKey: review.date) else { return [] }
        let training = Set(sessions.map(\.date))
        return (1...7).compactMap { ClubDates.calendar.date(byAdding: .day, value: $0, to: end) }.map(ClubDates.key).filter { !training.contains($0) }
    }
    private var chosenSessions: [AIPlanSession] { sessions.filter { replaceWholeWeek || selected.contains($0.date) } }
    private var adoptionScope: [String] { replaceWholeWeek ? (sessions.map(\.date) + restDates).sorted() : chosenSessions.map(\.date) }
    private var blockedDates: [String] {
        adoptionScope.filter { key in
            guard key >= ClubDates.key(Date()), let original = review.baseline[key] else { return true }
            let day = store.state.days[key] ?? DayLog()
            return WorkoutEditing.isProtected(day) || (try? CloudMerge.same(day.exercises, original)) != true
        }
    }
    @State private var busy = false
    @State private var confirming = false
    @State private var error: String?
    @State private var ownerID: Int?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(review.result?.reason ?? "")
                    Toggle("整周调整（含休息日）", isOn: $replaceWholeWeek)
                    Text(replaceWholeWeek ? "采用全部建议训练日；其余日期改为休息日并移除未开始的旧安排。任何已开始的训练或后来修改的安排都不会被覆盖。" : "只替换勾选日期；其他日期保留原安排，因此实际训练天数可能多于复盘建议。")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text("可以修改建议组次和重量。重量 0 表示自重或尚未设置，请按能力确认。").font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    ClubPlanChangesView(changes: ClubPlanChangeRules.preview(before: store.state.days,
                        sessions: chosenSessions, scope: adoptionScope, replace: true))
                    if chosenSessions.isEmpty {
                        Text("请勾选至少一个训练日，或开启整周调整后采用完整建议。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    if !blockedDates.isEmpty {
                        Text("以下日期已过去、开始训练或在复盘后更改：" + blockedDates.joined(separator: "、") + "。请重新复盘，或关闭整周调整并只选择未变化的日期。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                if replaceWholeWeek {
                    Section("下周休息日") {
                        ForEach(restDates, id: \.self) { key in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(key + " · 休息")
                                let old = review.baseline[key] ?? []
                                Text(old.isEmpty ? "原本没有训练安排" : "将移除旧安排：" + old.map(\.displayName).joined(separator: "、"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                ForEach(sessions.indices,id:\.self) { i in
                    Section(sessions[i].date) {
                        Toggle("采用这一天的建议",isOn:Binding(get:{replaceWholeWeek || selected.contains(sessions[i].date)},set:{yes in if yes { selected.insert(sessions[i].date) } else { selected.remove(sessions[i].date) }})).disabled(replaceWholeWeek)
                        Text("原安排："+(review.baseline[sessions[i].date] ?? []).map { "\($0.displayName) \($0.sets.count)组" }.joined(separator:"、")).font(.caption).foregroundStyle(.secondary)
                        Text(PlanDisplayCopy.heading(sessions[i].label)).font(.subheadline)
                        ForEach(sessions[i].exercises.indices,id:\.self) { j in
                            Text(sessions[i].exercises[j].displayName).bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
                            ForEach(sessions[i].exercises[j].sets.indices,id:\.self) { k in
                                HStack {
                                    Text("第\(k+1)组").font(.caption)
                                    if sessions[i].exercises[j].sets[k].durationSeconds == nil {
                                        TextField("kg", value: Binding(get:{sessions[i].exercises[j].sets[k].weight ?? 0},set:{sessions[i].exercises[j].sets[k].weight=$0}),format:.number).keyboardType(.decimalPad).accessibilityLabel("重量公斤")
                                        Text("kg").font(.caption)
                                    }
                                    if sessions[i].exercises[j].sets[k].durationSeconds != nil {
                                        Stepper("\(sessions[i].exercises[j].sets[k].durationSeconds ?? 30) 秒", value: Binding(get: { sessions[i].exercises[j].sets[k].durationSeconds ?? 30 }, set: { sessions[i].exercises[j].sets[k].durationSeconds = $0 }), in: 1...RecordLimits.maximumSeconds).font(.caption)
                                    } else { Stepper("\(sessions[i].exercises[j].sets[k].reps) 次",value:$sessions[i].exercises[j].sets[k].reps,in:1...200).font(.caption) }
                                }
                            }
                        }
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
                Section {
                    Button(store.hasAppliedAIJob("weekly/"+review.id.uuidString) ? "已确认这份调整" : busy ? "正在同步…" : (replaceWholeWeek ? "确认更新整周安排" : "确认更新所选日期")) {
                        if !replaceWholeWeek && selected.isEmpty { error = "请至少选择一天采用建议，其余日期会保留原安排。" }
                        else { confirming = true }
                    }.buttonStyle(PrimaryButton()).disabled(busy || !blockedDates.isEmpty || (!replaceWholeWeek && selected.isEmpty) || store.hasAppliedAIJob("weekly/"+review.id.uuidString))
                    if busy { ClubLoadingCard(title: "正在同步并保存计划调整…") }
                }
            }.clubGroupedSurface().navigationTitle("下周计划预览").navigationBarTitleDisplayMode(.inline)
                .onAppear { if ownerID == nil { ownerID = store.editingAccountID }; if sessions.isEmpty { sessions = review.result?.sessions ?? []; selected = Set(sessions.map(\.date)) } }
                .onChange(of: store.editingAccountID) { _, id in if id != ownerID { dismiss() } }
                .interactiveDismissDisabled(busy)
                .toolbar { ToolbarItem(placement:.cancellationAction) { Button("保持原计划") { dismiss() }.disabled(busy) } }
                .confirmationDialog(replaceWholeWeek ? "确认更新整周训练与休息安排？" : "确认替换所选日期的训练安排？",isPresented:$confirming,titleVisibility:.visible) {
                    Button("确认应用") { Task {
                        guard let owner = ownerID, owner == store.editingAccountID, !busy else { return }
                        busy = true; defer { busy = false }
                        let synchronized = await store.syncForPlanAdoption(ownerID: owner)
                        guard owner == store.editingAccountID, !Task.isCancelled else { return }
                        guard synchronized else { error = store.takeMessage(fallback: "同步尚未完成，请稍后重试。原安排已保留。"); return }
                        if store.applyWeeklyPlan(review,sessions:sessions.filter { replaceWholeWeek || selected.contains($0.date) },replaceWholeWeek:replaceWholeWeek) {
                            var copy = review; copy.applied = true; copy.updatedAt = Date()
                            if weekly.save(copy) { dismiss() } else { error = "训练安排已更新，但复盘标记保存失败：\(weekly.message ?? "请检查手机存储空间。")" }
                        } else { error = store.takeMessage() }
                    } }
                }
        }.tint(ClubBrand.accent)
    }
}


private struct ReviewQuestion: View {
    let title: String
    let detail: String
    let options: [String]
    @Binding var selection: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(detail).font(.footnote).foregroundStyle(.secondary)
            Picker(title, selection: $selection) {
                Text("请选择").tag("")
                ForEach(options, id: \.self) { Text($0).tag($0) }
            }.pickerStyle(.menu).labelsHidden().padding(BojiSpace.tightRow)
                .frame(maxWidth: .infinity, alignment: .leading).background(.black.opacity(0.04), in: RoundedRectangle(cornerRadius: BojiRadius.inner))
        }.padding(.vertical, 5)
    }
}
struct WeeklyCoverageCard: View {
    let cycle: TrainingCycle
    @EnvironmentObject private var store: AppStore
    private var coverage: WeeklyReadiness { WeeklyReadiness(cycle: cycle, days: store.state.days) }
    var body: some View {
        ClubCard {
            Text("回看这周，决定下周怎么练").bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
            Text(cycle.label).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            Text("AI 会分析实际训练、饮食和身体反馈，给出继续或调整计划的建议。查看进度不消耗 AI 次数。").font(.subheadline).foregroundStyle(.secondary)
            requirement(
                coverage.ended ? "这一周已结束" : coverage.allPlannedCompleted ? "本周计划训练已全部完成（可提前复盘）" : coverage.isCycleEndDay ? "已到本周最后一天（可开始复盘）" : "完成全部计划训练或等待周期结束",
                done: coverage.cycleReady
            )
            requirement("已完成并保存训练 \(coverage.trainingDays) / \(coverage.neededTrainingDays) 天", done: coverage.trainingDays >= coverage.neededTrainingDays)
            requirement("完整饮食记录 \(coverage.foodDays) / 3 天 · 用于完整复盘", done: coverage.foodDays >= 3)
            Text(coverage.explanation).font(.footnote).foregroundStyle(.secondary)
            if let notice = coverage.adjustmentNotice { Text(notice).font(.footnote).foregroundStyle(.secondary) }
            if coverage.trainingReady && !coverage.combinedReady {
                Text("现在可先做训练复盘，无需补齐饮食，也不会评价未记录的摄入。").font(.footnote.weight(.medium))
            }
        }
    }
    private func requirement(_ title: String, done: Bool) -> some View {
        Label(title, systemImage: done ? "checkmark.circle.fill" : "circle")
            .font(.subheadline).foregroundStyle(done ? Color.primary : .secondary)
    }
}
