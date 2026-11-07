import Foundation

struct TrainingWidgetSnapshot: Codable, Equatable {
    var date: String = ""
    var workoutName: String = "今天还没有训练计划"
    var completedSets: Int = 0
    var totalSets: Int = 0
    var calories: Double = 0
    var protein: Double = 0
    var mealCount: Int? = nil
    var updatedAt: Date = .distantPast
    var knownMealCount: Int? = nil

    var nutritionSummary: String {
        let recorded=max(0,mealCount ?? 0)
        // Missing count in old snapshots means the legacy nutrition values are known.
        let known=max(0,knownMealCount ?? (recorded > 0 || calories > 0 || protein > 0 ? max(1,recorded) : 0))
        guard known > 0 else { return recorded > 0 ? "饮食已记录 · 营养待补填" : "尚未记录饮食" }
        let text="\(calories.formatted(.number.precision(.fractionLength(0)))) kcal · \(protein.formatted(.number.precision(.fractionLength(0)))) g 蛋白质"
        let unknown=max(0,recorded-known)
        return unknown > 0 ? text+" · \(unknown)餐待补填" : text
    }

    var progress: Double {
        totalSets > 0 ? Double(completedSets) / Double(totalSets) : 0
    }
}

struct TrainingWidgetCache: Codable {
    var snapshots: [TrainingWidgetSnapshot]
}

enum TrainingWidgetDates {
    static var calendar: Calendar { Calendar(identifier: .gregorian) }
    static func key(_ date: Date) -> String {
        let formatter=DateFormatter();formatter.calendar=calendar;formatter.locale=Locale(identifier:"en_US_POSIX");formatter.dateFormat="yyyy-MM-dd"
        return formatter.string(from:date)
    }
    static func date(_ key: String) -> Date? {
        let formatter=DateFormatter();formatter.calendar=calendar;formatter.locale=Locale(identifier:"en_US_POSIX");formatter.dateFormat="yyyy-MM-dd"
        return formatter.date(from:key)
    }
}

#if canImport(ActivityKit)
import ActivityKit

struct TrainingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var workoutName: String
        var completedSets: Int
        var totalSets: Int
        var remainingSeconds: Int
        var restSeconds: Int
        var restEndsAt: Date?
        // Build 111/112：新增字段必须能解码旧 Activity。
        var currentExerciseName: String? = nil
        var currentSetNumber: Int? = nil
        var isPaused: Bool = false
        var pausedElapsedSeconds: Int? = nil
        var restPausedRemaining: Int? = nil
        // Build 112 计时基准：更新时的已用时与更新时间。锁屏计时从这两个值
        // 连续推进，不需要 App 在后台每秒刷新 Activity。
        var elapsedSeconds: Int? = nil
        var updatedAt: Date? = nil

        enum CodingKeys: String, CodingKey {
            case workoutName, completedSets, totalSets, remainingSeconds, restSeconds, restEndsAt
            case currentExerciseName, currentSetNumber, isPaused, pausedElapsedSeconds, restPausedRemaining
            case elapsedSeconds, updatedAt
        }

        init(workoutName: String, completedSets: Int, totalSets: Int,
             remainingSeconds: Int, restSeconds: Int, restEndsAt: Date?,
             currentExerciseName: String? = nil, currentSetNumber: Int? = nil,
             isPaused: Bool = false, pausedElapsedSeconds: Int? = nil,
             restPausedRemaining: Int? = nil, elapsedSeconds: Int? = nil,
             updatedAt: Date? = nil) {
            self.workoutName = workoutName
            self.completedSets = completedSets
            self.totalSets = totalSets
            self.remainingSeconds = remainingSeconds
            self.restSeconds = restSeconds
            self.restEndsAt = restEndsAt
            self.currentExerciseName = currentExerciseName
            self.currentSetNumber = currentSetNumber
            self.isPaused = isPaused
            self.pausedElapsedSeconds = pausedElapsedSeconds
            self.restPausedRemaining = restPausedRemaining
            self.elapsedSeconds = elapsedSeconds
            self.updatedAt = updatedAt
        }

        // AUD-004/FIX-004：旧 Activity 缺少 Build 111/112 新增键时按缺省值解码。
        // 非可选属性声明默认值不会自动成为 Codable 默认值，必须显式兜底。
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            workoutName = try container.decodeIfPresent(String.self, forKey: .workoutName) ?? ""
            completedSets = try container.decodeIfPresent(Int.self, forKey: .completedSets) ?? 0
            totalSets = try container.decodeIfPresent(Int.self, forKey: .totalSets) ?? 0
            remainingSeconds = try container.decodeIfPresent(Int.self, forKey: .remainingSeconds) ?? 0
            restSeconds = try container.decodeIfPresent(Int.self, forKey: .restSeconds) ?? 0
            restEndsAt = try container.decodeIfPresent(Date.self, forKey: .restEndsAt)
            currentExerciseName = try container.decodeIfPresent(String.self, forKey: .currentExerciseName)
            currentSetNumber = try container.decodeIfPresent(Int.self, forKey: .currentSetNumber)
            isPaused = try container.decodeIfPresent(Bool.self, forKey: .isPaused) ?? false
            pausedElapsedSeconds = try container.decodeIfPresent(Int.self, forKey: .pausedElapsedSeconds)
            restPausedRemaining = try container.decodeIfPresent(Int.self, forKey: .restPausedRemaining)
            elapsedSeconds = try container.decodeIfPresent(Int.self, forKey: .elapsedSeconds)
            updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
        }

        /// FIX-005: the system timer counts up from this artificial start, so
        /// elapsed time keeps moving while the App is suspended. Nil for legacy
        /// states that only carry a snapshot.
        var elapsedClockStart: Date? {
            guard !isPaused, let elapsed = elapsedSeconds, let updated = updatedAt else { return nil }
            return updated.addingTimeInterval(-Double(max(0, elapsed)))
        }
    }

    var workoutName: String
    var startedAt: Date
    var accountID: Int? = nil
    var dateKey: String? = nil
}
#endif
