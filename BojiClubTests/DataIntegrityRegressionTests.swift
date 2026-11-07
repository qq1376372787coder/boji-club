import XCTest
import AVFoundation
@testable import BojiClub

/// Regressions found in the Build135 audit: deletion tombstones, server-day
/// boundaries and periodic notification routing.
final class DataIntegrityRegressionTests: XCTestCase {
    func testDeletedBodyMeasurementCannotBeResurrectedByFirstSync() throws {
        let now = Date()
        let day = ClubDates.key(now)
        let measurementID = UUID()

        var local = SavedState()
        var localDay = DayLog()
        localDay.bodyMeasurements = []
        localDay.bodyWeight = nil
        localDay.deletedBodyMeasurementIDs = [measurementID.uuidString.lowercased()]
        local.days[day] = localDay

        var remote = SavedState()
        var remoteDay = DayLog()
        remoteDay.bodyWeight = BodyWeightEntry(kilograms: 70, updatedAt: now.addingTimeInterval(-60), id: measurementID)
        remote.days[day] = remoteDay

        let merged = try CloudMerge.merge(local: CloudState(local), remote: CloudState(remote), base: nil)
        XCTAssertNil(merged.days[day]?.bodyWeight, "A stale first sync must not revive a deleted weight")
        XCTAssertEqual(merged.days[day]?.deletedBodyMeasurementIDs?.contains(measurementID.uuidString.lowercased()), true)
    }

    @MainActor
    func testCameraPreviewLayerIsAttachedAndSized() {
        let view = MealPreviewSurface(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        view.layoutSubviews()
        XCTAssertTrue(view.preview.superlayer === view.layer)
        XCTAssertEqual(view.preview.frame, view.bounds)
        XCTAssertEqual(view.layer.sublayers?.filter { $0 is AVCaptureVideoPreviewLayer }.count, 1)
    }

    func testServerKeyUsesShanghaiDayNotDeviceDay() throws {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-28T17:30:00Z"))
        XCTAssertEqual(ClubDates.serverKey(date), "2026-10-29")
    }

    func testRemoteDeletionWinsAndKeepsANewMeasurement() throws {
        let date = "2026-10-28", now = Date(), removed = UUID(), survivor = UUID()
        var local = SavedState(), remote = SavedState(), stale = DayLog(), deleted = DayLog()
        stale.bodyMeasurements = [BodyWeightEntry(kilograms: 70, updatedAt: now, id: removed, recordedAt: now)]
        stale.bodyWeight = BodyWeightEntry(kilograms: 70, updatedAt: now, id: removed)
        deleted.deletedBodyMeasurementIDs = [removed.uuidString.lowercased()]
        deleted.bodyMeasurements = [BodyWeightEntry(kilograms: 71, updatedAt: now.addingTimeInterval(60), id: survivor, recordedAt: now.addingTimeInterval(60))]
        local.days[date] = stale; remote.days[date] = deleted
        for (left, right) in [(local, remote), (remote, local)] {
            let merged = try CloudMerge.merge(local: CloudState(left), remote: CloudState(right), base: nil)
            XCTAssertEqual(merged.days[date]?.bodyMeasurements?.compactMap(\.id), [survivor])
            XCTAssertEqual(merged.days[date]?.bodyWeight?.kilograms, 71)
        }
    }

    func testLegacyWeightWithoutIDHonorsStableTombstoneInBothDirections() throws {
        let date = "2026-10-28"
        let entry = BodyWeightEntry(kilograms: 70, updatedAt: Date(timeIntervalSinceReferenceDate: 12345))
        let id = BodyMeasurementIdentity.legacy(entry, date: date)
        var old = SavedState(), deleted = SavedState(), oldDay = DayLog(), deletedDay = DayLog()
        oldDay.bodyWeight = entry
        deletedDay.bodyMeasurements = []; deletedDay.deletedBodyMeasurementIDs = [id.uuidString.uppercased()]
        old.days[date] = oldDay; deleted.days[date] = deletedDay
        for (left, right) in [(old, deleted), (deleted, old)] {
            let merged = try CloudMerge.merge(local: CloudState(left), remote: CloudState(right), base: nil)
            XCTAssertNil(merged.days[date]?.bodyWeight)
            XCTAssertEqual(merged.days[date]?.bodyMeasurements?.count, 0)
        }
    }

    func testPeriodicWeekReminderIgnoresStaleScheduledDate() {
        let now = Date()
        XCTAssertEqual(ClubNotificationRouting.dateKey(kind: "weekly_center", provided: "2000-01-01", now: now), ClubDates.key(now))
        XCTAssertEqual(ClubNotificationRouting.dateKey(kind: "weekly_review", provided: "2026-10-01", now: now), "2026-10-01")
    }

    func testDashboardDoesNotInventWeightTargetOrTrainingStreak() {
        let now = Date()
        XCTAssertTrue(ClubDashboardFacts.weightHistory(days: [:], healthDays: [:], through: now).isEmpty)
        XCTAssertNil(ClubDashboardFacts.calorieTarget(nil))
        XCTAssertEqual(ClubDashboardFacts.trainingStreak(days: [:], through: now), 0)
        var target = NutritionTarget(caloriesMin: 1800, caloriesMax: 2200, proteinMin: 90, proteinMax: 110,
                                     fatMin: 40, fatMax: 60, meals: 3, note: "")
        XCTAssertEqual(ClubDashboardFacts.calorieTarget(target), 2200)
        target.generalGuidanceOnly = true
        XCTAssertNil(ClubDashboardFacts.calorieTarget(target))
        target.generalGuidanceOnly = false; target.caloriesMax = .nan
        XCTAssertNil(ClubDashboardFacts.calorieTarget(target))
    }

    func testDashboardSingleMeasurementStaysOnePointAndHonorsDeletion() throws {
        let now = Date(), key = ClubDates.key(now), id = UUID()
        var day = DayLog()
        day.bodyWeight = BodyWeightEntry(kilograms: 68, updatedAt: now, id: id, recordedAt: now)
        var points = ClubDashboardFacts.weightHistory(days: [key: day], healthDays: [:], through: now)
        XCTAssertEqual(points.count, 1, "A single observation must not become a fake flat trend")
        XCTAssertEqual(try XCTUnwrap(points.first).weight, 68)
        XCTAssertEqual(points.first?.id, points.last?.id, "Chart IDs must be stable")
        day.bodyMeasurements = []; day.deletedBodyMeasurementIDs = [id.uuidString.lowercased()]
        points = ClubDashboardFacts.weightHistory(days: [key: day], healthDays: [:], through: now)
        XCTAssertTrue(points.isEmpty, "A stale weight mirror must not revive deleted measurements")
    }

    func testDashboardDoesNotCarryOldHealthWeightIntoTodaysChart() {
        let now = Date(), key = ClubDates.key(now)
        let old = now.addingTimeInterval(-86400)
        var health = HealthDay(date: key, timeZone: "Asia/Shanghai", updatedAt: now)
        health.bodyMass = HealthMetric(value: 69, source: HealthSource(id: "test", name: "测量设备"), recordedAt: old)
        XCTAssertTrue(ClubDashboardFacts.weightHistory(days: [:], healthDays: [key: health], through: now).isEmpty)
        health.bodyMass?.recordedAt = now
        let points = ClubDashboardFacts.weightHistory(days: [:], healthDays: [key: health], through: now)
        XCTAssertEqual(points.count, 1)
        XCTAssertEqual(points.first?.source, "测量设备")
    }

    func testDashboardCountsCalendarWeeksFromConfirmedTrainingOnly() throws {
        let now = Date(), calendar = ClubDates.calendar
        let previous = try XCTUnwrap(calendar.date(byAdding: .weekOfYear, value: -1, to: now))
        var day = DayLog()
        day.exercises = [Exercise(name: "测试动作", muscle: "腿", sets: [TrainingSet(completed: true)])]
        XCTAssertEqual(ClubDashboardFacts.trainingStreak(days: [ClubDates.key(now): day], through: now), 0)
        day.workoutSavedAt = now
        XCTAssertEqual(ClubDashboardFacts.trainingStreak(days: [ClubDates.key(now): day, ClubDates.key(previous): day], through: now), 2)
        XCTAssertEqual(ClubDashboardFacts.trainingStreak(days: [ClubDates.key(previous): day], through: now), 1)
    }

    func testWalkthroughRespectsCompletionPreviewSkipAndValidSlideBounds() {
        XCTAssertTrue(WalkthroughPresentationRules.shouldPresent(completed: false))
        XCTAssertFalse(WalkthroughPresentationRules.shouldPresent(completed: true))
        XCTAssertFalse(WalkthroughPresentationRules.shouldPresent(completed: false, skipForPreview: true))
        XCTAssertFalse(WalkthroughPresentationRules.shouldPresent(completed: false, auditScreen: "records"))
        XCTAssertTrue(WalkthroughPresentationRules.shouldPresent(completed: true, force: true, skipForPreview: true))
        XCTAssertEqual(WalkthroughPresentationRules.slide(-1), 0)
        XCTAssertEqual(WalkthroughPresentationRules.slide(999), 3)
    }
}
