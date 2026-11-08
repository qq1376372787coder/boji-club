#if DEBUG
import SwiftUI

/// 公共组件展示页：仅供开发预览核对 Token 与组件，不进产品导航。
/// 从 Xcode Preview 或调试入口打开。
struct BojiComponentGalleryView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BojiSpace.showcase) {
                brandIdentity
                colors
                typography
                surfaces
                buttons
                components
                layoutPatterns
            }
            .padding(BojiSpace.pageInset)
            .frame(maxWidth: BojiSize.contentWidth)
            .frame(maxWidth: .infinity)
        }
        .background(BojiColor.pageBackground.ignoresSafeArea())
        .navigationTitle("组件展示")
    }

    private var brandIdentity: some View {
        gallerySection("BOJI 品牌标识") {
            HStack(spacing: BojiLayout.blockGap) { BojiBrandMark(size:64);BojiBrandSignature(size:24);BojiBrandMark(size:16,style:.monochrome) }
            HStack(spacing: BojiLayout.rowGap) { AIProcessingMark(size:28);Text("正在核对记录…").bojiType(.secondary) }
            Text("Logo 是品牌身份；提交、计时、保存仍使用对应功能图标。").bojiType(.caption).foregroundStyle(.secondary)
        }
    }

    private var colors: some View {
        gallerySection("颜色") {
            let swatches: [(String, Color)] = [
                ("pageBackground", BojiColor.pageBackground), ("cardSurface", BojiColor.cardSurface),
                ("inputSurface", BojiColor.inputSurface), ("subtleSurface", BojiColor.subtleSurface),
                ("calendarSurface", BojiColor.calendarSurface), ("textPrimary", BojiColor.textPrimary),
                ("textSecondary", BojiColor.textSecondary), ("textTertiary", BojiColor.textTertiary),
                ("coverSand", BojiColor.coverSand), ("timerAccent", BojiColor.timerAccent),
                ("aiViolet", BojiColor.aiViolet), ("aiGold", BojiColor.aiGold),
            ]
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: BojiLayout.inline)], spacing: BojiLayout.inline) {
                ForEach(swatches, id: \.0) { name, color in
                    VStack(spacing: BojiLayout.tight) {
                        RoundedRectangle(cornerRadius: BojiRadius.inner).fill(color)
                            .frame(height: 52)
                            .overlay { RoundedRectangle(cornerRadius: BojiRadius.inner).stroke(BojiColor.outline) }
                        Text(name).bojiType(.caption).foregroundStyle(BojiColor.textSecondary)
                            .lineLimit(1).minimumScaleFactor(0.6)
                    }
                }
            }
        }
    }

    private var typography: some View {
        gallerySection("字体") {
            VStack(alignment: .leading, spacing: BojiLayout.rowGap) {
                Text("页面大标题 30").bojiFont(.pageTitle)
                Text("主要卡片标题 20").bojiFont(.cardTitle)
                Text("动作名称 18").bojiFont(.exerciseName)
                Text("正文 16：核对实际重量与次数").bojiFont(.body)
                Text("次要说明 14：组间休息 5:00").bojiFont(.secondary)
                Text("辅助标签 13").bojiFont(.label)
                HStack(spacing: 0) {
                    Text("40.5").bojiFont(.bodyMetric)
                    Text(" kg").bojiFont(.secondary)
                }
                Text("12:34").bojiFont(.timer)
                Text("30 × 12").bojiFont(.setNumber)
            }
        }
    }

    private var surfaces: some View {
        gallerySection("表面") {
            VStack(spacing: BojiLayout.rowGap) {
                Text("普通卡片：白色 / 28pt / 3.5% 阴影")
                    .bojiFont(.body).bojiCard()
                Text("浮起控件：近白高光 / 细边缘 / 6% 阴影")
                    .bojiFont(.body).padding(BojiLayout.cardInset).bojiRaised(cornerRadius: BojiRadius.card)
                Text("内嵌输入区 #F0F0F5 / 15pt")
                    .bojiFont(.secondary).padding(BojiLayout.cardInset).bojiInset()
            }
        }
    }

    private var buttons: some View {
        gallerySection("按钮") {
            VStack(spacing: BojiLayout.rowGap) {
                Button("主要提交：保存") {}.buttonStyle(BojiButtonStyle(kind: .primary))
                Button("展示卡主要：开始训练") {}.buttonStyle(BojiButtonStyle(kind: .displayPrimary))
                Button("次按钮") {}.buttonStyle(BojiButtonStyle(kind: .secondary))
                Button("危险操作") {}.buttonStyle(BojiButtonStyle(kind: .destructive))
                HStack(spacing: BojiLayout.rowGap) {
                    Button { } label: { Image(systemName: "ellipsis") }
                        .buttonStyle(BojiCircleButtonStyle())
                    Button { } label: { Image(systemName: "xmark") }
                        .buttonStyle(BojiCircleButtonStyle())
                    Button { } label: { Image(systemName: "minus") }
                        .buttonStyle(BojiCircleButtonStyle(visualDiameter: 36))
                    Button { } label: { Image(systemName: "plus") }
                        .buttonStyle(BojiCircleButtonStyle(visualDiameter: 36))
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var components: some View {
        gallerySection("基础组件") {
            VStack(spacing: BojiLayout.rowGap) {
                BojiTipBand(text: "建议 30.5kg：全部 4 组都做到了 12 次，可以加重", systemImage: "arrow.up")
                BojiSegmentedProgress(total: 4, completed: 2)
                HStack(spacing: BojiLayout.rowGap) {
                    BojiExerciseThumb(exercise: Exercise.demoPlaceholder, side: 64)
                    BojiExerciseThumb(exercise: Exercise.demoPlaceholder, side: 88)
                }
                BojiEntryRow(title: "页面入口行", symbol: "figure.run", detail: "整行可点击") {}
                HStack(spacing: BojiLayout.inline) {
                    ForEach(["28", "30", ""], id: \.self) { value in
                        BojiSetNumberCell(text: value) {}
                    }
                    Button("完成") {}.buttonStyle(BojiButtonStyle(kind: .secondary))
                        .frame(width: BojiSetTable.completeColumn)
                }
            }
        }
    }

    private var layoutPatterns: some View {
        gallerySection("布局组件模式库 (Patterns)") {
            VStack(spacing: BojiLayout.cardInset) {
                // Pattern 1: Hero Banner
                BojiHeroBanner(
                    title: "胸大肌上部强化训练",
                    subtitle: "今日待练 · 4 动作 · 14 组",
                    badge: "TODAY HERO"
                ) {
                    BojiCoverGraphic(title: "胸大肌强化", compact: false)
                } action: {
                    Button("开始训练") {}
                        .buttonStyle(BojiButtonStyle(kind: .displayPrimary))
                }

                // Pattern 3: Metric Band
                BojiMetricBand(items: [
                    BojiMetricItem(title: "本周出勤", value: "3", unit: "天", note: "达标"),
                    BojiMetricItem(title: "已记热量", value: "1,820", unit: "kcal", note: nil),
                    BojiMetricItem(title: "蛋白质", value: "135", unit: "g", note: "90%"),
                    BojiMetricItem(title: "睡眠", value: "7.8", unit: "h", note: "优质"),
                ])

                // Pattern 4: Bento Dual Grid
                BojiBentoDualGrid {
                    VStack(alignment: .leading, spacing: BojiLayout.tight) {
                        Text("身体状态").bojiFont(.label).foregroundStyle(BojiColor.textSecondary)
                        HStack(alignment: .firstTextBaseline, spacing: BojiLayout.tight) {
                            Text("70.0").bojiFont(.bodyMetric)
                            Text("kg").bojiFont(.label).foregroundStyle(BojiColor.textSecondary)
                        }
                        Text("相差 5.0kg 达成目标").bojiFont(.label).foregroundStyle(BojiColor.textTertiary)
                    }
                    .bojiCard()
                } right: {
                    VStack(alignment: .leading, spacing: BojiLayout.tight) {
                        Text("营养摄入").bojiFont(.label).foregroundStyle(BojiColor.textSecondary)
                        HStack(alignment: .firstTextBaseline, spacing: BojiLayout.tight) {
                            Text("1,650").bojiFont(.setNumber, monospacedDigits: true)
                            Text("kcal").bojiFont(.label).foregroundStyle(BojiColor.textSecondary)
                        }
                        Text("已记录 3 餐").bojiFont(.label).foregroundStyle(BojiColor.textTertiary)
                    }
                    .bojiCard()
                }

                // Pattern 5: Unified Container
                BojiUnifiedContainer {
                    BojiEntryRow(title: "动作库检索", symbol: "dumbbell", detail: "678 项动作分类") {}
                    Divider().overlay(BojiColor.divider)
                    BojiEntryRow(title: "训练周期历史", symbol: "calendar", detail: "查看过往计划快照") {}
                }

                // Pattern 6: Progressive Disclosure
                BojiProgressiveDisclosure(title: "同场对照") {
                    HStack {
                        Image(systemName: "chart.bar.xaxis")
                        Text("查看同重量历史对照 (上次 +2.5kg)")
                            .bojiFont(.secondary).foregroundStyle(BojiColor.textPrimary)
                    }
                } detail: {
                    Text("第 1 组 20kg × 12次\n第 2 组 22.5kg × 10次\n第 3 组 22.5kg × 8次")
                        .bojiFont(.label).foregroundStyle(BojiColor.textSecondary)
                }
            }
        }
    }

    private func gallerySection(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: BojiLayout.rowGap) {
            Text(title).bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
            content()
        }
    }
}

extension Exercise {
    /// 展示页占位：无网络、无业务数据。
    static let demoPlaceholder = Exercise(id: UUID(), name: "演示动作", muscle: "核心", sets: [])
}

#Preview {
    NavigationStack { BojiComponentGalleryView() }
}

#if DEBUG
/// Local, preview-account-only screenshot harness. Excluded from release builds.
struct BojiAuditHost: View {
    let initialScreen: String
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var account: AccountService
    @State private var route: String? = nil
    @State private var auditAX = false
    @State private var auditReferences: [AIContextReference] = []
    private var auditFolder: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    @State private var date = Date()
    private var screen: String { route ?? initialScreen }
    private var yesterday: Date { ClubDates.calendar.date(byAdding: .day, value: -1, to: Date())! }
    private var cycle: TrainingCycle { TrainingCycle.preferred(days: store.state.days) }
    private var sampleHealth: HealthDay { HealthDay(date: ClubDates.key(date), timeZone: "Asia/Shanghai", updatedAt: date) }
    var body: some View {
        NavigationStack { destination.id(screen) }
            .dynamicTypeSize(auditAX || ProcessInfo.processInfo.environment["BOJI_AUDIT_AX"] == "1" ? .accessibility3 : .large)
            .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in
                guard account.isPreviewAccount,
                      let request = try? String(contentsOf: auditFolder.appendingPathComponent("boji-audit-route.txt"), encoding: .utf8) else { return }
                let parts = request.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "|")
                if let next = parts.first, next != screen { route = next }
                auditAX = parts.last == "ax"
            }
            .task(id: screen) {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                try? screen.write(to: auditFolder.appendingPathComponent("boji-audit-ready.txt"), atomically: true, encoding: .utf8)
            }
            .onOpenURL { url in
                guard account.isPreviewAccount, url.scheme == "bojiclub", url.host == "audit" else { return }
                route = url.lastPathComponent
            }
    }
    @ViewBuilder private var destination: some View {
        switch screen {
        case "walkthrough": FirstLaunchWalkthroughView(isPresented: .constant(true))
        case "walkthrough-0": FirstLaunchWalkthroughView(isPresented: .constant(true), initialSlide: 0)
        case "walkthrough-1": FirstLaunchWalkthroughView(isPresented: .constant(true), initialSlide: 1)
        case "walkthrough-2": FirstLaunchWalkthroughView(isPresented: .constant(true), initialSlide: 2)
        case "walkthrough-3": FirstLaunchWalkthroughView(isPresented: .constant(true), initialSlide: 3)
        case "references": AIReferencePicker(selection: $auditReferences)
        case "home": ClubAIShellView()
        case "plans": ClubPlanHub(selectedDate: $date, openWorkout: {})
        case "records": ClubRecordsHub()
        case "records-workout": ClubRecordsHub(category: .constant("训练"))
        case "records-nutrition": ClubRecordsHub(category: .constant("饮食"))
        case "records-body": ClubRecordsHub(category: .constant("身体"))
        case "nutrition": NutritionView(selectedDate: $date)
        case "body": BodyWeightView()
        case "club": ClubSeasonView()
        case "profile": ProfileView()
        case "training-plans": TrainingPlansView(focusDate: date)
        case "plan-generate": PlanView(date: date)
        case "plan-import": PlanView(date: date, initialMode: "parse_plan")
        case "manual-plan": ManualPlanView()
        case "manual-day": ManualPlanView(startDate: date, singleDay: true)
        case "plan-create": PlanCreationSheet(date: date)
        case "body-overview": BodyOverviewView()
        case "plan-versions": ClubPlanVersionsView()
        case "plan-move": PlanMoveSheet(sourceDate: ClubDates.calendar.date(byAdding: .day, value: 1, to: date) ?? date.addingTimeInterval(86_400))
        case "plan-shift": ShiftScheduleView()
        case "plan-advance": AdvanceWorkoutView(date: date)
        case "plan-continue": ContinueWeekView(endDate: ClubDates.date(fromKey: cycle.end) ?? date, initialCycle: cycle)
        case "next-week": TrainingHandoffCard(cycle: cycle)
        case "plan-changes": ClubPlanChangesView(changes: [])
        case "training-preview": TrainingPreviewView(title: "今天的训练", focus: "胸 · 上肢力量", exercises: store.log(for: date).exercises, date: date, onStart: {})
        case "workout": WorkoutView(selectedDate: $date, focused: true)
        case "rest": WorkoutView(selectedDate: $date, focused: true, initialRestEnd: Date().addingTimeInterval(180))
        case "completion": WorkoutCompletionView(snapshot: WorkoutCompletionSnapshot(ownerID: store.editingAccountID ?? -1, date: yesterday, sessionID: store.log(for: yesterday).activeWorkoutSessionID))
        case "workout-summary": ClubWorkoutSummaryView(date: yesterday, sessionID: store.log(for: yesterday).activeWorkoutSessionID ?? UUID())
        case "exercise-library": ExerciseLibraryView(date: date, added: {})
        case "meal-editor": MealEditorView(date: date)
        case "meal-batch": MealBatchReviewView(jobID: "audit-unavailable")
        case "weight-editor": WeightEntryEditor(date: date)
        case "body-facts": BodyFactIntakeView()
        case "ai": ClubAIHomeView()
        case "ai-hub": ClubAIHubView(initialSection: "动态")
        case "ai-timeline": ClubInsightTimelineView()
        case "ai-settings": ClubAISettingsView()
        case "ai-evidence": ClubInsightTimelineView()
        case "daily-report": DailyReportView()
        case "weekly-report": WeeklyReportView()
        case "report-library": ReportLibraryView()
        case "report-history": AIReportHistoryView(dateKey: ClubDates.key(date))
        case "auto-reports": ClubAutomaticReportList()
        case "auto-report": ClubAutomaticReportReader(jobID: "audit-unavailable")
        case "weekly-center": WeeklyReviewCenter()
        case "weekly-history": WeeklyReviewHistoryView(dateKey: ClubDates.key(date))
        case "weekly-survey": WeeklyReviewDetail(initial: WeeklyReview(date: cycle.end, cycle: cycle))
        case "weekly-plan": WeeklyPlanPreview(review: WeeklyReview(date: cycle.end, cycle: cycle))
        case "keepsakes": ClubKeepsakeVaultView()
        case "badge": ClubKeepsakeDetailView(title: "First Light", detail: "完成真实训练，留下第一枚纪念。", icon: "sparkles", rewardType: "badge", rewardID: -1, imagePath: nil, revision: nil, canShare: false)
        case "club-history": ClubHistoryView()
        case "membership": MembershipView()
        case "membership-gate": MembershipGateView()
        case "profile-editor": ProfileEditor()
        case "identity-editor": MemberIdentityEditor()
        case "notifications": NotificationSettingsView()
        case "archive": RecordArchiveView()
        case "storage": CloudStorageUsageView()
        case "repair": RecordRepairView()
        case "health": HealthConnectionsView(date: date)
        case "health-share": HealthShareReviewView(request: HealthShareReviewRequest(ownerID: store.editingAccountID ?? -1, date: date, summary: sampleHealth, day: store.log(for: date), allowsLink: false))
        case "guide": ClubUsageGuideView()
        case "account-entry": AccountEntryView()
        case "onboarding": OnboardingView()
        case "legal-terms": LegalDocumentView(document: .terms)
        case "legal-privacy": LegalDocumentView(document: .privacy)
        case "legal-deletion": LegalDocumentView(document: .deletion)
        case "meal-history": NutritionAuditFactory.history(date: $date)
        case "meal-nutrition": NutritionAuditFactory.editor(date: date, meal: (store.log(for: date).meals.first ?? Meal(name: "燕麦、鸡蛋与无糖酸奶", category: "早餐", calories: 420, protein: 26, carbs: 48, fat: 14)))
        case "reward-claim": SeasonAuditFactory.claim()
        case "custom-exercise": ExerciseAuditFactory.custom(owner: store.editingAccountID)
        case "plan-exercise": PlanAuditFactory.editor()
        case "history-day": ReviewAuditFactory.day(date: yesterday, log: store.log(for: yesterday))
        case "history-exercise": ReviewAuditFactory.exercise()
        case "server-login": OnboardingAuditFactory.login()
        case "membership-records": ProfileAuditFactory.history()
        case "set-editor": TrainingSetEditPanel(original: TrainingSet(weight: 20, reps: 10), number: 1, previous: nil, canUsePrevious: false, weightStep: .constant(2.5), allowTimer: true, save: { _ in true }, startTimer: { _ in }, performDelete: { true })
        case "exercise-detail": LibraryExerciseDetailView(item: BojiAuditFixtures.libraryExercise, date: date, added: nil)
        case "exercise-guide": ExerciseDetailView(guide: ExerciseGuide.samples[0], add: { true })
        case "replace-exercise":
            guard let exercise = store.log(for: date).exercises.first else { return EmptyView() }
            return WorkoutAuditFactory.replace(date: date, exercise: exercise)
        case "set-timer":
            guard let exercise = store.log(for: date).exercises.first else { return EmptyView() }
            return WorkoutAuditFactory.timer(date: date, exercise: exercise)
        case "daily-report": AIReportReaderView(jobID: "audit-daily-report")
        case "weekly-report": WeeklyReviewHistoryDetail(review: BojiAuditFixtures.review(date: yesterday))
        case "phase-report": PhaseReportView(report: BojiAuditFixtures.phase(date: date))
        case "plan-version-detail": ProductAuditFactory.version(BojiAuditFixtures.version(date: date))
        case "plan-followup": ClubPlanFollowupView(version: BojiAuditFixtures.version(date: date))
        case "share-preview": ShareCardPreview(draft: ShareDraft(card: ShareCardView(title: "本次训练", headline: "认真完成，稳步进阶。", stats: ["2 组已确认"], tagline: "BOJI CLUB"), ownerID: store.editingAccountID))
        case "avatar-crop": ProfileAuditFactory.crop()
        case "review-photo": ReviewPhotoEditor(image: UIImage(named: "ClubKeepsakeHero")!, pose: "演示素材", save: { _ in })
        case "tcx-preview": TCXPreviewView(inspection: TCXInspection(workouts: [], skipped: ["缺少有效运动时间": 1]), confirm: {})
        case "member-welcome": OnboardingAuditFactory.welcome(account: account.user)
        case "onboarding-goal": OnboardingAuditFactory.page(step: 1)
        case "onboarding-conditions": OnboardingAuditFactory.page(step: 2)
        case "onboarding-confirm": OnboardingAuditFactory.page(step: 3)
        case "onboarding-covenant": OnboardingAuditFactory.page(step: 4)
        case "service-info": ContentUnavailableView("服务说明", systemImage: "link", description: Text("训练、饮食与身体记录用于回顾你的真实进步。"))
        case "membership-prices": MembershipView(screenshotPreview: true)
        case "components": BojiComponentGalleryView()
        case "about": BojiAboutView()
        default: ContentUnavailableView("未注册的审计页面", systemImage: "doc.text")
        }
    }
}
#endif

#if DEBUG
enum BojiAuditFixtures {
    static let libraryExercise = LibraryExercise(id: "0025", name: "dumbbell bench press", bodyPart: "chest", equipment: "dumbbell", target: "pectorals", muscleGroup: "胸", secondaryMuscles: ["肱三头肌"], imageURL: nil, gifURL: nil, nameZH: "哑铃卧推")
    static func sessions(date: Date) -> [AIPlanSession] {
        [AIPlanSession(date: ClubDates.key(date), label: "上肢力量", exercises: [AIPlanExercise(name: "哑铃卧推", muscle: "胸", sets: (0..<3).map { _ in AIPlanSet(weight: 20, reps: 10) }, library_query: nil, library_id: "0025")])]
    }
    static func review(date: Date) -> WeeklyReview {
        WeeklyReview(id: UUID(uuidString: "00000000-0000-0000-0000-000000000099") ?? UUID(), date: ClubDates.key(date), status: "succeeded", result: WeeklyResult(kind: "weekly", summary: "训练记录正在建立，先保持当前节奏。", training: "本周已确认一次训练；单次样本不足以判断长期力量变化。", nutrition: "餐次记录仍不完整，暂不评价全天营养。", recovery: "结合实际疲劳感安排恢复，避免把未记录误当作未休息。", appearance: "没有用于比较的体态照片。", photoFeedback: [], decision: "保持", reason: "已有数据不足以支持大幅调整。", notes: ["本页为本地审计样本，不是个人训练建议。"], sessions: sessions(date: date)))
    }
    static func report(date: Date) -> AILocalJob {
        AILocalJob(id: "audit-daily-report", digest: "audit", request: AIRequest(id: "audit-daily-report", kind: "report", date: ClubDates.key(date), payload: [:]), status: "succeeded", result: AIResult(kind: "report", notes: ["本地审计样本"], summary: "训练已经确认，下一步是补齐今天的餐次记录。", training: "已确认的数据来自实际完成组，不把计划组计算为完成。", nutrition: "只汇总已保存的一餐或多餐；记录不完整时，不评价全天摄入。", recovery: "按实际疲劳与日程安排恢复。样本不足时继续记录。"))
    }
    static func version(date: Date) -> ClubPlanVersion {
        ClubPlanVersion(id: "audit-plan-version", recordedAt: date, source: "manual", title: "上肢力量计划", start: ClubDates.key(date), duration: 7, sessions: sessions(date: date), requestedProfile: MemberProfile(), adoptedProfile: MemberProfile(), nutrition: .estimate(MemberProfile()), previousIDs: [], scopeDates: [ClubDates.key(date)], retainedDates: [])
    }
    static func phase(date: Date) -> PhaseReport {
        PhaseReport(id: "audit-phase", start: ClubDates.key(date.addingTimeInterval(-27*86400)), end: ClubDates.key(date), generatedAt: date, daysCovered: 12, daysTotal: 28, trainingDaysPlanned: 12, trainingDaysCompleted: 8, confirmedSets: 64, measuredDays: 4, weightFirstKg: 71.1, weightLastKg: 70, trends: [], plateauNote: nil, hasPreviousPhase: false, summary: "本地审计样本：训练节奏已建立，继续积累可比记录。", notes: ["此数据仅用于页面布局审计，不代表当前会员记录。"])
    }
}
#endif

#endif
