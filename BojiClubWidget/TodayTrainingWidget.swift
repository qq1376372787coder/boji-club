import UIKit
import SwiftUI
import WidgetKit

struct TrainingWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: TrainingWidgetSnapshot
}

struct TrainingWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> TrainingWidgetEntry {
        TrainingWidgetEntry(date: .now, snapshot: TrainingWidgetSnapshot())
    }

    func getSnapshot(in context: Context, completion: @escaping (TrainingWidgetEntry) -> Void) {
        completion(TrainingWidgetEntry(date: .now, snapshot: Self.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TrainingWidgetEntry>) -> Void) {
        let now=Date()
        let saved=Self.snapshots()
        var entries=[TrainingWidgetEntry(date:now,snapshot:Self.load())]
        for value in saved {
            if let date=TrainingWidgetDates.date(value.date),date>now { entries.append(TrainingWidgetEntry(date:date,snapshot:value)) }
        }
        entries.sort { $0.date<$1.date }
        completion(Timeline(entries:entries,policy:.after(now.addingTimeInterval(15*60))))
    }

    private static func snapshots() -> [TrainingWidgetSnapshot] {
        let shared=UserDefaults(suiteName:"group.com.bojiclub.shared")
        if let data=shared?.data(forKey:"training.snapshots.v2"),let cache=try? JSONDecoder().decode(TrainingWidgetCache.self,from:data) { return cache.snapshots }
        if let data=shared?.data(forKey:"training.snapshot"),let value=try? JSONDecoder().decode(TrainingWidgetSnapshot.self,from:data) { return [value] }
        return []
    }
    private static func load() -> TrainingWidgetSnapshot {
        let key=TrainingWidgetDates.key(Date())
        return snapshots().first(where:{$0.date==key}) ?? TrainingWidgetSnapshot(date:key,workoutName:"打开 App 更新今日记录")
    }

}

struct TodayTrainingWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var scheme
    let entry: TrainingWidgetEntry

    var body: some View {
        VStack(alignment: .leading, spacing: family == .systemSmall ? 8 : 12) {
            HStack {
                BojiBrandSignature(size:16,style:.monochrome,font:.caption2.weight(.bold))
                Spacer()
                Text(family == .systemSmall ? String(entry.snapshot.date.suffix(5)) : entry.snapshot.date)
                    .font(.caption2)
                    .lineLimit(1)
                    .accessibilityLabel(entry.snapshot.date)
                    .foregroundStyle(.secondary)
            }
            Text(entry.snapshot.workoutName)
                .font(family == .systemSmall ? .headline : .title3.weight(.semibold))
                .lineLimit(2)
            if entry.snapshot.totalSets > 0 {
                ProgressView(value: entry.snapshot.progress)
                    .tint(BojiWidgetTheme.accent)
                HStack {
                    Text("\(entry.snapshot.completedSets)/\(entry.snapshot.totalSets) 组")
                    Spacer()
                    Text((entry.snapshot.mealCount ?? 0) > 0 ? "饮食已记录" : "可记录饮食")
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            } else {
                Text("休息日也可以记录饮食。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(entry.snapshot.nutritionSummary).font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(family == .systemSmall ? 12 : 16)
        .containerBackground(for: .widget) {
            scheme == .dark ? Color(white:0.09) : Color(white:0.97)
        }
    }
}

struct TodayTrainingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "BojiClubTodayTraining", provider: TrainingWidgetProvider()) { entry in
            TodayTrainingWidgetView(entry: entry)
        }
        .configurationDisplayName("今日训练")
        .description("查看今天训练进度和饮食记录。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

enum BojiWidgetTheme {
    // Same values as BojiColor.mistAccent in the app; the widget must not carry a
    // second brand accent or the home screen drifts from the app's visual identity.
    static let accent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 227/255, green: 231/255, blue: 240/255, alpha: 1)
            : UIColor(red: 65/255, green: 77/255, blue: 99/255, alpha: 1)
    })
}
