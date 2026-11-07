import ActivityKit
import SwiftUI
import WidgetKit

struct TrainingLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TrainingActivityAttributes.self) { context in
            TrainingLiveActivityView(state: context.state, startedAt: context.attributes.startedAt)
                .activityBackgroundTint(Color(white: 0.97))
                .activitySystemActionForegroundColor(BojiWidgetTheme.accent)
                .widgetURL(trainingURL(context.attributes.dateKey))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.state.isPaused ? "已暂停" : "训练中",
                          systemImage: context.state.isPaused ? "pause.fill" : "dumbbell.fill")
                        .font(.caption.weight(.semibold))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(context.state.completedSets)/\(context.state.totalSets) 组")
                        .font(.caption.monospacedDigit())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(currentTitle(context.state)).font(.headline)
                        ProgressView(value: context.state.totalSets > 0 ? Double(context.state.completedSets) / Double(context.state.totalSets) : 0)
                            .tint(BojiWidgetTheme.accent)
                        if let end = context.state.restEndsAt, end > Date() {
                            Text(timerInterval: Date()...end, countsDown: true)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        } else if let paused = context.state.restPausedRemaining {
                            Text("休息暂停 · 剩余 \(paused) 秒").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: "dumbbell.fill")
            } compactTrailing: {
                Text("\(context.state.completedSets)/\(context.state.totalSets)")
                    .font(.caption2.monospacedDigit())
            } minimal: {
                Image(systemName: "dumbbell.fill")
            }
        }
    }
}

struct TrainingLiveActivityView: View {
    let state: TrainingActivityAttributes.ContentState
    let startedAt: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(state.isPaused ? "已暂停" : "训练中",
                      systemImage: state.isPaused ? "pause.fill" : "dumbbell.fill")
                Spacer()
                Text("\(state.completedSets)/\(state.totalSets) 组").monospacedDigit()
            }
            Text(currentTitle(state)).font(.headline)
            ProgressView(value: state.totalSets > 0 ? Double(state.completedSets) / Double(state.totalSets) : 0)
                .tint(BojiWidgetTheme.accent)
            elapsedView(state)
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            if let end = state.restEndsAt, end > Date() {
                Text(timerInterval: Date()...end, countsDown: true).font(.caption.monospacedDigit())
            } else if let paused = state.restPausedRemaining {
                Text("休息暂停 · 剩余 \(paused) 秒").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(18)
    }
    @ViewBuilder private func elapsedView(_ state: TrainingActivityAttributes.ContentState) -> some View {
        if state.isPaused {
            Text(elapsedLabel(state.pausedElapsedSeconds ?? state.elapsedSeconds ?? state.remainingSeconds) + " · 已暂停")
        } else if let reference = state.elapsedClockStart {
            // System-driven counts-up timer: continues while the App is suspended.
            // `elapsed` already excludes accumulated pause time.
            HStack(spacing: 4) {
                Text("已用时")
                Text(timerInterval: reference...reference.addingTimeInterval(86400), countsDown: false)
            }
        } else {
            // Legacy Activity without the clock reference keeps its last snapshot.
            Text(elapsedLabel(state.remainingSeconds))
        }
    }
    private func elapsedLabel(_ seconds: Int) -> String {
        String(format: "已用时 %02d:%02d", max(0, seconds) / 60, max(0, seconds) % 60)
    }
}

private func currentTitle(_ state: TrainingActivityAttributes.ContentState) -> String {
    if let exercise = state.currentExerciseName, let set = state.currentSetNumber {
        return "\(exercise) · 第 \(set) 组"
    }
    return state.currentExerciseName ?? state.workoutName
}

private func trainingURL(_ dateKey: String?) -> URL? {
    var components = URLComponents()
    components.scheme = "bojiclub"
    components.host = "training"
    if let dateKey { components.queryItems = [URLQueryItem(name: "date", value: dateKey)] }
    return components.url
}
