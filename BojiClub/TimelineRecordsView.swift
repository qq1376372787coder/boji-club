import SwiftUI

/// 记录（Tab 2）——全页面新蓝图 §四（2026-11-09 推倒重来）：今天的时间线。
/// 一屏回答「我今天记了什么」：餐 / 训练 / 体重按时间合并倒排，点任意条目进对应编辑页。
/// 时间线本身零玻璃（§20.2）；唯一玻璃件 = 底部 B1「记一餐」（长按可记体重/记训练）。
struct TimelineRecordsView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedDate = Date()
    @State private var showMealEditor = false
    @State private var editingWeight = false
    @State private var openTraining = false
    @State private var highlightID: UUID?
    @State private var editingMeal: Meal?
    @State private var openNutrition = false

    private var day: DayLog { store.log(for: selectedDate) }

    private struct TimelineEntry: Identifiable {
        let id: String
        let slot: String
        let title: String
        let detail: String
        let sortKey: Double
        let meal: Meal?
    }

    private var entries: [TimelineEntry] {
        var list: [TimelineEntry] = []
        if !day.meals.isEmpty {
            // §六 入口：时间线的「饮食」条目 → 今天吃了（摄入汇总页）
            list.append(TimelineEntry(
                id: "nutrition",
                slot: "饮食",
                title: "今天吃了",
                detail: day.knownMeals.isEmpty ? "" : "\(Int(day.calories)) 千卡",
                sortKey: -1,
                meal: nil
            ))
        }
        for meal in day.meals {
            list.append(TimelineEntry(
                id: meal.id.uuidString,
                slot: meal.category,
                title: meal.name,
                detail: meal.hasNutrition ? "\(Int(meal.calories)) 千卡" : "",
                sortKey: mealSort(meal.category),
                meal: meal
            ))
        }
        if day.confirmedTraining.hasTraining {
            let training = day.confirmedTraining
            list.append(TimelineEntry(
                id: "training",
                slot: "训练",
                title: trainingTitle,
                detail: "\(training.completedSets) 组 · \(Int(training.volume)) kg·次",
                sortKey: trainingSortKey,
                meal: nil
            ))
        }
        if let weight = day.bodyWeight?.kilograms {
            list.append(TimelineEntry(
                id: "weight",
                slot: "体重",
                title: "\(weight.formatted(.number.grouping(.never).precision(.fractionLength(0...1)))) kg",
                detail: "",
                sortKey: 21,
                meal: nil
            ))
        }
        return list.sorted { $0.sortKey < $1.sortKey }
    }

    private func mealSort(_ category: String) -> Double {
        switch category {
        case "早餐": return 8
        case "午餐": return 12.5
        case "晚餐": return 18.5
        case "加餐": return 15
        default: return 12
        }
    }

    /// 训练条目排在会话开始时刻附近；无开始时间按中午排。
    private var trainingSortKey: Double {
        if let start = day.trainingLog.workoutStartedAt {
            let hour = Calendar.current.component(.hour, from: start)
            let minute = Calendar.current.component(.minute, from: start)
            return Double(hour) + Double(minute) / 60
        }
        return 12.75
    }

    private var trainingTitle: String {
        let key = ClubDates.key(selectedDate)
        if let versions = day.planVersions {
            for version in versions.reversed() {
                if let session = version.sessions.first(where: { $0.date == key }),
                   !session.label.isEmpty, session.label != "训练安排" {
                    return session.label
                }
            }
        }
        return "力量训练"
    }

    var body: some View {
        VStack(spacing: 0) {
            dateHeader
            if entries.isEmpty {
                Spacer()
                EmptyNote(title: "今天还没有记录", detail: "记一餐、记训练或记体重，都会出现在这里。")
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(entries) { entry in
                            entryRow(entry)
                            Rectangle().fill(BojiColor.divider).frame(height: BojiLayout.hairline)
                        }
                    }
                    .padding(.horizontal, BojiLayout.pageInset)
                    .padding(.bottom, BojiLayout.actionClearance)
                }
                .scrollDismissesKeyboard(.interactively)
            }
        }
        .background { ClubBackground() }
        .navigationTitle("记录")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button {
                BojiHaptics.selection()
                BojiSound.play(.tap)
                showMealEditor = true
            } label: {
                Text("记一餐")
                    .frame(maxWidth: .infinity, minHeight: BojiLayout.actionHeight)
                    .contentShape(Rectangle())
            }
            .clubNativeGlassButton(prominent: true)
            .accessibilityIdentifier("v2-records-primary")
            .contextMenu {
                Button { BojiHaptics.selection(); editingWeight = true } label: { Label("记体重", systemImage: "scalemass") }
                Button { BojiHaptics.selection(); openTraining = true } label: { Label("记训练", systemImage: "figure.strengthtraining.traditional") }
            }
            .padding(.horizontal, BojiLayout.pageInset)
            .padding(.bottom, BojiLayout.inline)
        }
        .sheet(isPresented: $showMealEditor) {
            MealEditorView(date: selectedDate, onSaved: {
                highlightID = day.meals.last?.id
                Task {
                    try? await Task.sleep(for: .seconds(1))
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.3)) { highlightID = nil }
                }
            })
        }
        .sheet(isPresented: $editingWeight) { WeightEntryEditor(date: selectedDate) }
        .sheet(item: $editingMeal) { meal in NutritionView.editor(date: selectedDate, meal: meal) }
        .navigationDestination(isPresented: $openNutrition) { NutritionView(selectedDate: $selectedDate) }
        .navigationDestination(isPresented: $openTraining) { WorkoutView(selectedDate: $selectedDate) }
    }

    /// 日期切换（§四：今天 11月9日 ◀ ▶）。
    private var dateHeader: some View {
        HStack(spacing: BojiLayout.inline) {
            Text(dateTitle)
                .bojiType(.data)
                .foregroundStyle(BojiColor.textPrimary)
            Spacer()
            Button {
                BojiHaptics.selection()
                withAnimation(reduceMotion ? nil : BojiMotion.cardExpand(reduceMotion: reduceMotion)) {
                    selectedDate = ClubDates.calendar.date(byAdding: .day, value: -1, to: selectedDate) ?? selectedDate
                }
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: BojiLayout.controlHeight, height: BojiLayout.controlHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("前一天")
            Button {
                BojiHaptics.selection()
                withAnimation(reduceMotion ? nil : BojiMotion.cardExpand(reduceMotion: reduceMotion)) {
                    selectedDate = ClubDates.calendar.date(byAdding: .day, value: 1, to: selectedDate) ?? selectedDate
                }
            } label: {
                Image(systemName: "chevron.right")
                    .frame(width: BojiLayout.controlHeight, height: BojiLayout.controlHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("后一天")
        }
        .padding(.horizontal, BojiLayout.pageInset)
        .padding(.vertical, BojiLayout.inline)
    }

    private var dateTitle: String {
        if ClubDates.calendar.isDateInToday(selectedDate) {
            return "今天 \(ClubDates.label(selectedDate, format: "M月d日"))"
        }
        return ClubDates.label(selectedDate, format: "M月d日 EEEE")
    }

    /// 条目行（§四）：槽位 T5 + 名称 T3 + 数值 T5 右对齐；保存后新条目高亮 1 秒。
    @ViewBuilder private func entryRow(_ entry: TimelineEntry) -> some View {
        Button {
            BojiHaptics.selection()
            if let meal = entry.meal {
                editingMeal = meal
            } else if entry.id == "nutrition" {
                openNutrition = true
            } else if entry.id == "weight" {
                editingWeight = true
            } else {
                openTraining = true
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: BojiLayout.inline) {
                Text(entry.slot)
                    .bojiType(.caption)
                    .foregroundStyle(BojiColor.textTertiary)
                    .frame(width: 44, alignment: .leading)
                Text(entry.title)
                    .bojiType(.data)
                    .foregroundStyle(BojiColor.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: BojiLayout.inline)
                if !entry.detail.isEmpty {
                    Text(entry.detail)
                        .bojiType(.caption, monospacedDigits: true)
                        .foregroundStyle(BojiColor.textSecondary)
                }
            }
            .frame(minHeight: BojiLayout.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("v2-records-row")
        .background(entryHighlight(entry))
    }

    @ViewBuilder private func entryHighlight(_ entry: TimelineEntry) -> some View {
        if let meal = entry.meal, meal.id == highlightID {
            RoundedRectangle(cornerRadius: BojiLayout.Radius.control, style: .continuous)
                .fill(ClubBrand.accent.opacity(0.12))
                .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: highlightID)
        }
    }
}
