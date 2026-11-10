"""Generate production Swift regression checks; execute using Swift on Mac."""
from pathlib import Path
import runpy, sys
out = Path(sys.argv[1])
runpy.run_path(str(Path(__file__).with_name('build_repair_v38_swift_tests.py')))
root = Path(__file__).resolve().parents[1]
s = out.read_text('utf-8')
if 'enum JourneyCopy {' not in s:
    s += '\n' + (root/'BojiClub/JourneyRules.swift').read_text('utf-8')
if 'func validateBackupValue(' not in s:
    store = (root/'BojiClub/AppStore.swift').read_text('utf-8')
    start = store.index('private func validateBackupValue(')
    s += '\n' + store[start:store.index('@MainActor', start)].replace('private func validateBackupValue(', 'func validateBackupValue(')
s += r'''
do {
    let beginning = checks
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    let boundary = ISO8601DateFormatter().date(from: "2026-10-10T16:15:00Z")!
    let yesterday = calendar.date(byAdding: .day, value: -1, to: boundary)!
    let future = calendar.date(byAdding: .day, value: 1, to: boundary)!
    check(StartingWeightSource.today.recordDate(selected: boundary, now: boundary, calendar: calendar) == calendar.startOfDay(for: boundary), "today measurement uses the actual measurement day")
    check(StartingWeightSource.today.recordDate(selected: yesterday, now: boundary, calendar: calendar) == calendar.startOfDay(for: yesterday), "a draft finished after midnight keeps the day on which its weight was measured")
    check(StartingWeightSource.earlier.recordDate(selected: yesterday, now: boundary, calendar: calendar) == calendar.startOfDay(for: yesterday), "recent measurement keeps its actual day")
    check(StartingWeightSource.earlier.recordDate(selected: future, now: boundary, calendar: calendar) == nil, "future measurement is rejected")
    check(StartingWeightSource.estimate.recordDate(selected: boundary, now: boundary, calendar: calendar) == nil, "estimate never becomes an actual measurement")
    check(StartingWeightSource(rawValue: "旧值") == nil, "old or unknown source requires a fresh choice")
    var measuredProfile = MemberProfile(); measuredProfile.weight = 68
    let estimatedStore = AppStore()
    check(estimatedStore.saveProfile(measuredProfile, initialWeightDate: StartingWeightSource.estimate.recordDate(selected: now, now: now, calendar: ClubDates.calendar)), "estimated body profile is accepted")
    check(estimatedStore.log(for: now).bodyWeight == nil, "estimated profile does not pollute the weight curve")
    let measuredStore = AppStore()
    check(measuredStore.saveProfile(measuredProfile, initialWeightDate: now), "confirmed measurement can seed the daily record")
    measuredProfile.weight = 70
    check(measuredStore.saveProfile(measuredProfile, initialWeightDate: now), "repeated onboarding save is safe")
    check(measuredStore.log(for: now).bodyWeight?.kilograms == 68, "retry never overwrites an existing daily weight")

    check(JourneyCopy.weeklyAction(ended: false, trainingReady: false, foodReady: false, hasReport: false) == "查看本周进度", "unfinished week offers progress instead of a dead button")
    check(JourneyCopy.weeklyAction(ended: true, trainingReady: false, foodReady: false, hasReport: false) == "查看已有记录", "insufficient week explains records")
    check(JourneyCopy.weeklyAction(ended: true, trainingReady: true, foodReady: false, hasReport: false) == "开始训练复盘", "food shortage does not block a valid training-only review")
    check(JourneyCopy.weeklyAction(ended: true, trainingReady: true, foodReady: true, hasReport: false) == "开始完整复盘", "complete input offers combined review")
    check(JourneyCopy.weeklyAction(ended: false, trainingReady: false, foodReady: false, hasReport: true) == "查看本周复盘", "saved reports remain readable without a new generation")
    check(PlanDisplayCopy.text("每组休息90秒，使用RPE7；示例60kg，约45min。") == "每组休息90秒，使用主观用力度7；示例60公斤，约45分钟。", "technical shorthand becomes readable without losing numbers")
    check(PlanDisplayCopy.text("保持动作节奏，每组10次。").contains("10次"), "Chinese numeric instructions survive")
    check(PlanDisplayCopy.heading("Upper Lower", fallback: "训练计划") == "训练计划", "unknown heading has a neutral Chinese fallback")
    check(PlanDisplayCopy.text("profile.sessionMinutes()").hasPrefix("这份旧计划"), "code is never presented as training advice")
    check(PlanDisplayCopy.notes(["Rest 90 seconds", "Unknown note"]).count == 1, "legacy untranslated warnings are deduplicated")
    var measurements = 0
    let longText = String(repeating: "认真训练💪🏻", count: 1200)
    let summary = ReportShareContent.summary(longText) { measurements += 1; return $0.count <= 80 }
    check(summary.count <= 80 && summary.hasSuffix("…"), "single-card summary fits with a visible truncation indicator")
    check(measurements <= 20, "large report does not cause hundreds of main-thread text measurements")
    check(summary.dropLast().allSatisfy { String($0) != "🏻" }, "summary preserves composed emoji boundaries")
    check(ReportShareContent.summary("完整结论") { $0.count <= 80 } == "完整结论", "short conclusions are not needlessly truncated")
    check(ReportShareContent.summary("  \n ") { _ in false }.isEmpty, "empty conclusion is safe")
    check(ReportShareContent.summary("内容") { _ in false }.isEmpty, "impossible layout cannot overflow")

    let result = WeeklyResult(kind: "weekly_review", summary: "总结", training: "训练", nutrition: "饮食", recovery: "恢复", appearance: "", photoFeedback: [], decision: "keep", reason: "保持", notes: [], sessions: [])
    var original = WeeklyReview(date: today); original.result = result; original.jobID = "job-a"; original.updatedAt = now
    var newer = original; newer.updatedAt = now.addingTimeInterval(10); newer.recoveredWithoutContext = false
    let days = [today: DayLog(weeklyReview: original)]
    let newest = WeeklyVersions.visible(days: days, local: [newer], deletedJobIDs: [])
    check(newest.first?.updatedAt == newer.updatedAt, "history selects the newest copy across disk and cloud")
    check(WeeklyVersions.visible(days: [today: DayLog(weeklyReview: newer)], local: [original], deletedJobIDs: []).first?.updatedAt == newer.updatedAt, "nil and false context flags do not allow an older copy to replace a newer report")
    var placeholder = newer; placeholder.id = UUID(); placeholder.recoveredWithoutContext = true; placeholder.updatedAt = now.addingTimeInterval(20)
    check(WeeklyVersions.visible(days: days, local: [placeholder], deletedJobIDs: []).first?.id == original.id, "context-rich report wins over a later recovered placeholder")
    check(WeeklyVersions.visible(days: days, local: [placeholder], deletedJobIDs: []).count == 1, "same weekly AI task appears once")
    var removedDay = DayLog(weeklyReview: original); removedDay.deletedWeeklyReviewIDs = [original.id.uuidString.lowercased()]
    check(WeeklyVersions.visible(days: [today: removedDay], local: [newer], deletedJobIDs: []).isEmpty, "review deletion applies to both local and synced copies")
    check(WeeklyVersions.visible(days: days, local: [newer], deletedJobIDs: ["job-a"]).isEmpty, "job deletion also hides saved report copies")
    var second = original; second.id = UUID(); second.jobID = "job-b"; second.updatedAt = now.addingTimeInterval(30)
    check(WeeklyVersions.visible(days: days, local: [second], deletedJobIDs: []).count == 2, "genuine independently generated versions are retained")
    var draft = WeeklyReview(date: today)
    check(WeeklyVersions.visible(days: [:], local: [draft], deletedJobIDs: []).count == 1, "unfinished survey can still be resumed")
    draft.status = "deleted"
    check(WeeklyVersions.visible(days: [:], local: [draft], deletedJobIDs: []).isEmpty, "deleted draft cannot return")
    print("PASS \(checks - beginning) additional v42 production Swift checks")
}
'''
out.write_text(s, 'utf-8')
print('v42 production Foundation regression harness generated; Xcode and UI checks remain separate')
