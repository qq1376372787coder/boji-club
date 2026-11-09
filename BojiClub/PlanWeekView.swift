import SwiftUI

/// 计划（Tab 3）——全页面新蓝图 §十一（2026-11-09 推倒重来）：这周练什么。
/// 一周圆点（点亮=训练日）+ 今天起的安排行 + B1「调整这周」；
/// 三个文字链出口：自己配（ManualPlanView）/ 选现成（TrainingPlansView）/ AI 排（PlanView）。
/// 周视图不套玻璃（§20.2），唯一玻璃件 = 底部 B1。
struct PlanWeekView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showAdjust = false
    @State private var showManual = false
    @State private var showTemplates = false
    @State private var showAI = false

    private var cycle: TrainingCycle {
        today.planCycle ?? TrainingCycle.preferred(days: store.state.days)
    }
    private var today: DayLog { store.log(for: Date()) }
    private var weekDates: [String] { cycle.dates }

    /// 从今天起还没到的安排日（含今天），蓝图 §十一 的行区。
    private var upcomingRows: [(key: String, date: Date)] {
        let todayKey = ClubDates.key(Date())
        return weekDates
            .filter { $0 >= todayKey }
            .compactMap { key in ClubDates.date(fromKey: key).map { (key, $0) } }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    BojiEditorialNumber(value: "这周计划", wrap: true)
                    Spacer()
                    // §八 入口：计划页顶部 → 看结果
                    NavigationLink {
                        WeekResultsView()
                    } label: {
                        Text("看结果 ›")
                            .bojiType(.caption)
                            .foregroundStyle(BojiColor.textSecondary)
                            .frame(minHeight: BojiLayout.controlHeight)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("v2-plans-results-link")
                }

                weekDots
                    .padding(.top, BojiLayout.blockGap)

                Rectangle().fill(BojiColor.divider).frame(height: BojiLayout.hairline)
                    .padding(.top, BojiLayout.blockGap)

                if upcomingRows.isEmpty {
                    Text("这一轮快结束了，可以看看下一周怎么安排。")
                        .bojiType(.body15)
                        .foregroundStyle(BojiColor.textSecondary)
                        .frame(minHeight: BojiLayout.rowHeight)
                } else {
                    ForEach(upcomingRows, id: \.key) { row in
                        dayRow(key: row.key, date: row.date)
                        Rectangle().fill(BojiColor.divider).frame(height: BojiLayout.hairline)
                    }
                }

                // 三个文字链（§十一：选完回这里）
                HStack(spacing: BojiLayout.sectionGap) {
                    textLink("自己配") { showManual = true }
                    textLink("选现成") { showTemplates = true }
                    textLink("AI 排") { showAI = true }
                }
                .frame(minHeight: BojiLayout.controlHeight)
                .padding(.top, BojiLayout.rowGap)
            }
            .padding(.horizontal, BojiLayout.pageInset)
            .padding(.top, BojiLayout.rowGap)
            .padding(.bottom, BojiLayout.actionClearance)
        }
        .background { ClubBackground() }
        .navigationTitle("计划")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button {
                BojiHaptics.selection()
                BojiSound.play(.tap)
                showAdjust = true
            } label: {
                Text("调整这周")
                    .frame(maxWidth: .infinity, minHeight: BojiLayout.actionHeight)
                    .contentShape(Rectangle())
            }
            .clubNativeGlassButton(prominent: true)
            .accessibilityIdentifier("v2-plans-primary")
            .padding(.horizontal, BojiLayout.pageInset)
            .padding(.bottom, BojiLayout.inline)
        }
        .sheet(isPresented: $showAdjust) { PlanCreationSheet(date: Date()) }
        .sheet(isPresented: $showManual) { NavigationStack { ManualPlanView(startDate: Date()) } }
        .sheet(isPresented: $showTemplates) { TrainingPlansView(focusDate: Date()) }
        .sheet(isPresented: $showAI) { NavigationStack { PlanView(date: Date()) } }
    }

    /// 一周圆点（§十一）：一~日，点亮=当天有动作安排。
    private var weekDots: some View {
        VStack(spacing: BojiLayout.inline) {
            HStack {
                ForEach(weekDates, id: \.self) { key in
                    Text(weekdayLabel(key))
                        .bojiType(.caption)
                        .foregroundStyle(BojiColor.textTertiary)
                        .frame(maxWidth: .infinity)
                }
            }
            HStack {
                ForEach(weekDates, id: \.self) { key in
                    Circle()
                        .fill(hasPlan(key) ? ClubBrand.accent : BojiColor.divider)
                        .frame(width: 8, height: 8)
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("\(weekdayLabel(key))\(hasPlan(key) ? "，有训练安排" : "，休息")")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("v2-plans-week-dots")
    }

    private func weekdayLabel(_ key: String) -> String {
        guard let date = ClubDates.date(fromKey: key) else { return "" }
        let weekday = ClubDates.calendar.component(.weekday, from: date) // 1=周日
        return ["日", "一", "二", "三", "四", "五", "六"][max(1, min(7, weekday)) - 1]
    }

    private func hasPlan(_ key: String) -> Bool {
        !(store.state.days[key]?.exercises.isEmpty ?? true)
    }

    /// 一天的安排行（§十一）：「今天 · 上肢推」T3 + 「4 个动作 · 45 分钟」T5。
    @ViewBuilder private func dayRow(key: String, date: Date) -> some View {
        let day = store.state.days[key] ?? DayLog()
        VStack(alignment: .leading, spacing: BojiLayout.tight) {
            Text("\(dayTitle(key)) · \(dayLabel(day, key: key))")
                .bojiType(.data)
                .foregroundStyle(BojiColor.textPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if day.exercises.isEmpty {
                Text(day.planCycle != nil ? "计划休息日" : "还没有安排")
                    .bojiType(.caption)
                    .foregroundStyle(BojiColor.textTertiary)
            } else {
                Text("\(day.exercises.count) 个动作 · 约 \(store.state.profile.sessionMinutes ?? 45) 分钟")
                    .bojiType(.caption)
                    .foregroundStyle(BojiColor.textSecondary)
            }
        }
        .frame(minHeight: BojiLayout.rowHeight)
    }

    private func dayTitle(_ key: String) -> String {
        if key == ClubDates.key(Date()) { return "今天" }
        if key == ClubDates.key(ClubDates.calendar.date(byAdding: .day, value: 1, to: Date()) ?? Date()) { return "明天" }
        guard let date = ClubDates.date(fromKey: key) else { return key }
        return ClubDates.label(date, format: "M月d日")
    }

    /// 训练主题优先取计划会话名，退化到肌群摘要（与今天页同法）。
    private func dayLabel(_ day: DayLog, key: String) -> String {
        if let versions = day.planVersions {
            for version in versions.reversed() {
                if let session = version.sessions.first(where: { $0.date == key }),
                   !session.label.isEmpty, session.label != "训练安排" {
                    return session.label
                }
            }
        }
        var muscles: [String] = []
        for exercise in day.exercises where !exercise.muscle.isEmpty && !muscles.contains(exercise.muscle) {
            muscles.append(exercise.muscle)
        }
        return muscles.isEmpty ? "力量训练" : muscles.prefix(2).joined(separator: "、")
    }

    private func textLink(_ title: String, action: @escaping () -> Void) -> some View {
        Button {
            BojiHaptics.selection()
            BojiSound.play(.tap)
            action()
        } label: {
            Text(title)
                .bojiType(.body15)
                .tint(ClubBrand.accent)
                .frame(minHeight: BojiLayout.controlHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
