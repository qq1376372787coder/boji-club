import SwiftUI

/// 看结果（数据面板）——全页面新蓝图 §八（2026-11-09 推倒重来）：这周我做得怎么样。
/// 一页 = 巨号「这周」+ 三个数（次训练/记饭天/体重变化）+ 一个可切换趋势图 + B1「看这周报告」。
/// 数据来源：WeeklyMetricsCalculator（唯一）+ ReviewTrendRules。
struct WeekResultsView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var trendMetric: ReviewTrendMetric = .volume

    private var cycle: TrainingCycle {
        TrainingCycle.preferred(days: store.state.days)
    }
    private var weekStart: Date {
        ClubDates.date(fromKey: cycle.start) ?? Date()
    }
    private var weekEnd: Date {
        ClubDates.date(fromKey: cycle.end) ?? Date()
    }
    private var metrics: AIWeeklyMetrics {
        WeeklyMetricsCalculator.compute(state: store.state, start: weekStart, end: weekEnd)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                BojiEditorialNumber(value: "这周", wrap: true)
                Text("\(ClubDates.label(weekStart, format: "M/d")) - \(ClubDates.label(weekEnd, format: "M/d"))")
                    .bojiType(.caption)
                    .foregroundStyle(BojiColor.textTertiary)
                    .padding(.top, BojiLayout.Rhythm.eyebrowToTitle)

                Rectangle().fill(BojiColor.divider).frame(height: BojiLayout.hairline)
                    .padding(.top, BojiLayout.blockGap)

                HStack(alignment: .firstTextBaseline, spacing: BojiLayout.sectionGap) {
                    statColumn(value: metrics.training?.total_sessions.map { "\($0)" }, unit: "次训练")
                    statColumn(value: metrics.nutrition?.days_with_records.map { "\($0)" }, unit: "记饭天")
                    statColumn(value: metrics.body?.weight_change_kg.map { change in
                        (change >= 0 ? "↑" : "↓") + abs(change).formatted(.number.precision(.fractionLength(1)))
                    }, unit: "kg")
                }
                .padding(.vertical, BojiLayout.blockGap)

                Rectangle().fill(BojiColor.divider).frame(height: BojiLayout.hairline)

                trendBlock
                    .padding(.top, BojiLayout.blockGap)
            }
            .padding(.horizontal, BojiLayout.pageInset)
            .padding(.top, BojiLayout.rowGap)
            .padding(.bottom, BojiLayout.actionClearance)
        }
        .background { ClubBackground() }
        .navigationTitle("看结果")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            NavigationLink {
                WeeklyReportView()
            } label: {
                Text("看这周报告")
                    .frame(maxWidth: .infinity, minHeight: BojiLayout.actionHeight)
                    .contentShape(Rectangle())
            }
            .clubNativeGlassButton(prominent: true)
            .accessibilityIdentifier("v2-results-primary")
            .padding(.horizontal, BojiLayout.pageInset)
            .padding(.bottom, BojiLayout.inline)
        }
    }

    /// 空值不渲染（P0-3）：没数据的格子不摆 0。
    private func statColumn(value: String?, unit: String) -> some View {
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

    /// 趋势块（§八）：指标名 T3 + 分段控件切换 + 柱图。
    private var trendBlock: some View {
        VStack(alignment: .leading, spacing: BojiLayout.rowGap) {
            Text(trendMetric.title + "趋势")
                .bojiType(.data)
                .foregroundStyle(BojiColor.textPrimary)
            Picker("趋势指标", selection: $trendMetric) {
                Text("训练量").tag(ReviewTrendMetric.volume)
                Text("摄入").tag(ReviewTrendMetric.calories)
                Text("体重").tag(ReviewTrendMetric.weight)
            }
            .pickerStyle(.segmented)
            trendBars
        }
    }

    /// 柱图（业务图形）：一周 7 天，按当周最大值归一。
    private var trendBars: some View {
        let series = ReviewTrendRules.series(state: store.state, scale: .custom(start: weekStart, end: weekEnd), metric: trendMetric)
        let values = series.points.map(\.value)
        let maxValue = values.compactMap { $0 }.max() ?? 0
        return HStack(alignment: .bottom, spacing: BojiLayout.inline) {
            ForEach(series.points) { point in
                VStack(spacing: BojiLayout.tight) {
                    RoundedRectangle(cornerRadius: BojiLayout.Radius.badge, style: .continuous)
                        .fill(point.value == nil ? BojiColor.divider : ClubBrand.accent.opacity(0.85))
                        .frame(height: maxValue > 0 && point.value != nil
                              ? max(4, CGFloat((point.value ?? 0) / maxValue) * 72)
                              : 4)
                    Text(ClubDates.label(point.date, format: "d"))
                        .bojiType(.caption)
                        .foregroundStyle(BojiColor.textTertiary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 100)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("v2-results-trend")
    }
}
