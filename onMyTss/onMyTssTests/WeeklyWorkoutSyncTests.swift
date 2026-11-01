import Foundation
import SwiftData
import XCTest
@testable import onMyTss

@MainActor
final class WeeklyWorkoutSyncTests: XCTestCase {
    private func workout(_ id: String, _ date: Date, _ type: String,
                         suppressed: Bool = false, deleted: Bool = false) -> Workout {
        let row = Workout(id: id, date: date, startTime: date, duration: 60, workoutType: type,
                          tss: 0, calculationMethod: "duration", source: .manual,
                          isSuppressed: suppressed)
        row.isTombstoned = deleted
        return row
    }

    func testWeekUsesLocalCalendarAndKeepsMultipleActivities() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Chicago"))
        calendar.firstWeekday = 2
        let date: (Int, Int, Int, Int) -> Date = { month, day, hour, minute in
            calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
        }
        // The week includes the spring daylight-saving transition.
        let now = date(3, 8, 12, 0)
        let monday = date(3, 2, 0, 0)
        let nextMonday = date(3, 9, 0, 0)
        let inputs = [workout("old", date(3, 1, 23, 59), "Run"),
                      workout("run", date(3, 3, 9, 0), "Run"),
                      workout("ride", date(3, 3, 18, 0), "Ride"),
                      workout("duplicate", date(3, 4, 8, 0), "Run", suppressed: true),
                      workout("deleted", date(3, 5, 8, 0), "Swim", deleted: true),
                      workout("future", date(3, 8, 13, 0), "Walk"),
                      workout("next", nextMonday, "Strength")]
        let snapshot = try XCTUnwrap(WeeklyWorkoutSync.snapshot(workouts: inputs, now: now, calendar: calendar))
        XCTAssertEqual(snapshot.weekStart, monday)
        XCTAssertEqual(snapshot.weekEnd, nextMonday)
        XCTAssertEqual(snapshot.records.map(\.workoutType), ["Run", "Ride"])
        XCTAssertEqual(snapshot.records.map(\.date), [date(3, 3, 9, 0), date(3, 3, 18, 0)])
    }

    func testFixtureAndUnavailableStoreNeverOverwriteOrReload() throws {
        let suiteName = "ohmytss.weekly-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let now = Date()
        let rows = [workout("one", now, "Run")]
        var reloads = 0
        XCTAssertTrue(WeeklyWorkoutSync.publish(workouts: rows, now: now, defaults: defaults,
                                                arguments: [], reload: { reloads += 1 }))
        let original = try XCTUnwrap(WeeklyWorkoutSnapshot.load(defaults: defaults))
        XCTAssertFalse(WeeklyWorkoutSync.publish(workouts: [], now: now, defaults: defaults,
                                                 arguments: ["--v2-ui-tests"], reload: { reloads += 1 }))
        XCTAssertFalse(WeeklyWorkoutSync.publish(workouts: [], now: now, defaults: defaults,
                                                 arguments: ["--v2-sync-fixture"], reload: { reloads += 1 }))
        XCTAssertFalse(WeeklyWorkoutSync.publish(workouts: [], now: now, defaults: nil,
                                                 arguments: [], reload: { reloads += 1 }))
        XCTAssertEqual(WeeklyWorkoutSnapshot.load(defaults: defaults), original)
        XCTAssertEqual(reloads, 1)
    }

    func testSnapshotMarksDaysAfterItsLastUpdateAsNotSynced() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Chicago"))
        let date: (Int, Int, Int) -> Date = { day, hour, minute in
            calendar.date(from: DateComponents(year: 2026, month: 3, day: day, hour: hour, minute: minute))!
        }
        let snapshot = WeeklyWorkoutSnapshot(weekStart: date(2, 0, 0), weekEnd: date(9, 0, 0),
                                             generatedAt: date(7, 23, 59), sourceSyncedAt: date(7, 23, 59), records: [])
        let nextDay = date(8, 12, 0) // Daylight-saving transition.
        XCTAssertTrue(snapshot.covers(day: date(7, 0, 0), asOf: nextDay, calendar: calendar))
        XCTAssertFalse(snapshot.covers(day: date(8, 0, 0), asOf: nextDay, calendar: calendar))

        let updated = WeeklyWorkoutSnapshot(weekStart: snapshot.weekStart, weekEnd: snapshot.weekEnd,
                                            generatedAt: nextDay, sourceSyncedAt: nextDay, records: [])
        XCTAssertTrue(updated.covers(day: date(8, 0, 0), asOf: nextDay, calendar: calendar))
    }

    func testWorkoutCategoriesRecognizeBikeAndOtherCommonTypes() {
        XCTAssertEqual(WeeklyWorkoutCategory(type: "MountainBike"), .cycling)
        XCTAssertEqual(WeeklyWorkoutCategory(type: "VirtualRide"), .cycling)
        XCTAssertEqual(WeeklyWorkoutCategory(type: "TrailRun"), .running)
        XCTAssertEqual(WeeklyWorkoutCategory(type: "WeightTraining"), .strength)
        XCTAssertEqual(WeeklyWorkoutCategory(type: "Yoga"), .other)
    }
    func testFreshnessAndRepeatPublishing() throws {
        let suiteName = "ohmytss.weekly-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Chicago"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 4, hour: 8)))
        let row = workout("one", now, "Run")
        var reloads = 0
        func publish(_ rows: [Workout], at date: Date, syncedAt: Date? = nil) -> Bool {
            WeeklyWorkoutSync.publish(workouts: rows, now: date, calendar: calendar,
                                      sourceSyncedAt: syncedAt ?? now, defaults: defaults,
                                      arguments: [], reload: { reloads += 1 })
        }
        XCTAssertTrue(publish([row], at: now))
        XCTAssertTrue(publish([row], at: now.addingTimeInterval(60)))
        XCTAssertEqual(reloads, 1)
        let original = try XCTUnwrap(WeeklyWorkoutSnapshot.load(defaults: defaults))
        XCTAssertTrue(original.covers(day: now, asOf: now.addingTimeInterval(5 * 3600), calendar: calendar))
        XCTAssertFalse(original.covers(day: now, asOf: now.addingTimeInterval(6 * 3600), calendar: calendar))
        XCTAssertTrue(publish([row], at: now.addingTimeInterval(5 * 3600)))
        XCTAssertEqual(reloads, 1) // Reading the cache does not advance the source timestamp.
        XCTAssertTrue(publish([row], at: now.addingTimeInterval(5 * 3600),
                              syncedAt: now.addingTimeInterval(5 * 3600)))
        XCTAssertEqual(reloads, 2)
        row.workoutType = "Ride"
        XCTAssertTrue(publish([row], at: now.addingTimeInterval(5 * 3600 + 1),
                              syncedAt: now.addingTimeInterval(5 * 3600)))
        XCTAssertEqual(reloads, 3)
        XCTAssertTrue(publish([], at: now.addingTimeInterval(5 * 3600 + 2),
                              syncedAt: now.addingTimeInterval(5 * 3600)))
        XCTAssertEqual(reloads, 4)
        XCTAssertEqual(WeeklyWorkoutSnapshot.load(defaults: defaults)?.records, [])
    }

    func testFrequentSuccessfulSyncsReuseTimelineUntilNearExpiry() throws {
        let suiteName = "ohmytss.weekly-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Chicago"))
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 4, hour: 8)))
        let row = workout("manual", start, "Run")
        var reloads = 0
        func publish(_ rows: [Workout], at date: Date, syncedAt: Date?) -> Bool {
            WeeklyWorkoutSync.publish(workouts: rows, now: date, calendar: calendar,
                                      sourceSyncedAt: syncedAt, defaults: defaults,
                                      arguments: [], reload: { reloads += 1 })
        }
        XCTAssertTrue(publish([row], at: start, syncedAt: start))
        for interval in 1..<20 {
            let date = start.addingTimeInterval(TimeInterval(interval * 15 * 60))
            XCTAssertTrue(publish([row], at: date, syncedAt: date))
        }
        XCTAssertEqual(reloads, 1)
        XCTAssertEqual(WeeklyWorkoutSnapshot.load(defaults: defaults)?.sourceSyncedAt, start)
        let renewal = start.addingTimeInterval(5 * 3600)
        XCTAssertTrue(publish([row], at: renewal, syncedAt: renewal))
        XCTAssertEqual(reloads, 2)
        XCTAssertEqual(WeeklyWorkoutSnapshot.load(defaults: defaults)?.sourceSyncedAt, renewal)
        XCTAssertTrue(publish([row], at: renewal.addingTimeInterval(1), syncedAt: nil))
        XCTAssertEqual(reloads, 3) // Partial source failure changes the visible status immediately.
        XCTAssertTrue(publish([row], at: renewal.addingTimeInterval(2), syncedAt: renewal.addingTimeInterval(2)))
        XCTAssertEqual(reloads, 4)
        let nextDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: start))
        XCTAssertTrue(publish([row], at: nextDay, syncedAt: nextDay))
        XCTAssertEqual(reloads, 5)
    }

    func testOnlySuccessfulSourcesSetFreshnessAndManualWorkoutsRemainVisible() throws {
        let now = Date()
        let previous = now.addingTimeInterval(-3600)
        let state = AppState(lastHealthKitSyncDate: previous, lastComputationDate: previous)
        XCTAssertEqual(WeeklyWorkoutSync.sourceSyncDate(state: state, auth: nil), previous)
        let auth = StravaAuth(lastSyncDate: previous, isConnected: true)
        XCTAssertEqual(WeeklyWorkoutSync.sourceSyncDate(state: state, auth: auth), previous)
        state.lastComputationDate = now
        state.lastHealthKitSyncDate = now // Strava failed in the latest completed pass.
        XCTAssertNil(WeeklyWorkoutSync.sourceSyncDate(state: state, auth: auth))
        auth.lastSyncDate = now
        XCTAssertEqual(WeeklyWorkoutSync.sourceSyncDate(state: state, auth: auth), now)
        auth.connectedAt = now.addingTimeInterval(1)
        XCTAssertNil(WeeklyWorkoutSync.sourceSyncDate(state: state, auth: auth))

        let manual = workout("manual", now, "Run")
        let snapshot = try XCTUnwrap(WeeklyWorkoutSync.snapshot(workouts: [manual], now: now))
        XCTAssertEqual(snapshot.records.map(\.workoutType), ["Run"])
        XCTAssertFalse(snapshot.covers(day: now, asOf: now))
        let encoded = try JSONEncoder().encode(snapshot) // old snapshots lack sourceSyncedAt
        let decoded = try JSONDecoder().decode(WeeklyWorkoutSnapshot.self, from: encoded)
        XCTAssertNil(decoded.sourceSyncedAt)
        XCTAssertEqual(decoded.records, snapshot.records)
    }

    func testSourceFailurePersistsAcrossRestartAndRecoversWithoutLosingRecords() throws {
        let suiteName = "ohmytss.weekly-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 4, hour: 12)))
        let row = workout("manual", now, "Run")
        var reloads = 0
        XCTAssertTrue(WeeklyWorkoutSync.publish(workouts: [row], now: now, calendar: calendar, sourceSyncedAt: now,
                                                defaults: defaults, arguments: [], reload: { reloads += 1 }))
        let rawBefore = try XCTUnwrap(defaults.data(forKey: "weeklyWorkouts.v1"))
        XCTAssertTrue(WeeklyWorkoutSync.beginSourceSync(defaults: defaults, arguments: []))
        XCTAssertEqual(WeeklyWorkoutSnapshot.load(defaults: defaults)?.sourceSyncedAt, now)
        XCTAssertEqual(reloads, 1) // Beginning normal sync never invalidates the widget.
        XCTAssertTrue(WeeklyWorkoutSync.finishSourceSync(success: false, defaults: defaults,
                                                         arguments: [], reload: { reloads += 1 }))
        XCTAssertEqual(defaults.data(forKey: "weeklyWorkouts.v1"), rawBefore)
        XCTAssertNil(WeeklyWorkoutSnapshot.load(defaults: defaults)?.sourceSyncedAt)
        XCTAssertEqual(WeeklyWorkoutSnapshot.load(defaults: defaults)?.records.map(\.workoutType), ["Run"])
        XCTAssertTrue(WeeklyWorkoutSync.finishSourceSync(success: false, defaults: defaults,
                                                         arguments: [], reload: { reloads += 1 }))
        XCTAssertEqual(reloads, 2)
        let restartedDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        XCTAssertNil(WeeklyWorkoutSnapshot.load(defaults: restartedDefaults)?.sourceSyncedAt)
        let success = now.addingTimeInterval(60)
        XCTAssertTrue(WeeklyWorkoutSync.beginSourceSync(defaults: restartedDefaults, arguments: []))
        XCTAssertTrue(WeeklyWorkoutSync.publish(workouts: [row], now: success, calendar: calendar, sourceSyncedAt: success,
                                                defaults: restartedDefaults, arguments: [], reload: { reloads += 1 }))
        XCTAssertNil(WeeklyWorkoutSnapshot.load(defaults: restartedDefaults)?.sourceSyncedAt)
        let rawSuccess = try XCTUnwrap(restartedDefaults.data(forKey: "weeklyWorkouts.v1"))
        XCTAssertEqual(try JSONDecoder().decode(WeeklyWorkoutSnapshot.self, from: rawSuccess).sourceSyncedAt, success)
        XCTAssertEqual(reloads, 2) // Still masked until the successful pass is complete.
        XCTAssertTrue(WeeklyWorkoutSync.finishSourceSync(success: true, defaults: restartedDefaults,
                                                         arguments: [], reload: { reloads += 1 }))
        XCTAssertEqual(WeeklyWorkoutSnapshot.load(defaults: restartedDefaults)?.sourceSyncedAt, success)
        XCTAssertEqual(reloads, 3)
        XCTAssertFalse(WeeklyWorkoutSync.beginSourceSync(defaults: nil, arguments: []))
        XCTAssertFalse(WeeklyWorkoutSync.finishSourceSync(success: false, defaults: nil,
                                                          arguments: [], reload: { reloads += 1 }))
        XCTAssertEqual(reloads, 3)
    }

    func testIncomingSourceEventInvalidatesWithoutEndingInFlightSync() throws {
        let suiteName = "ohmytss.weekly-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 4, hour: 12)))
        let row = workout("manual", now, "Run")
        var reloads = 0
        XCTAssertTrue(WeeklyWorkoutSync.publish(workouts: [row], now: now, calendar: calendar, sourceSyncedAt: now,
                                                defaults: defaults, arguments: [], reload: { reloads += 1 }))
        XCTAssertTrue(WeeklyWorkoutSync.beginSourceSync(defaults: defaults, arguments: []))
        XCTAssertTrue(WeeklyWorkoutSync.invalidateSource(defaults: defaults, arguments: [], reload: { reloads += 1 }))
        XCTAssertEqual(WeeklyWorkoutSourceState.load(defaults: defaults),
                       WeeklyWorkoutSourceState(invalid: true, inFlight: true))
        XCTAssertNil(WeeklyWorkoutSnapshot.load(defaults: defaults)?.sourceSyncedAt)
        XCTAssertEqual(WeeklyWorkoutSnapshot.load(defaults: defaults)?.records.map(\.workoutType), ["Run"])
        XCTAssertTrue(WeeklyWorkoutSync.invalidateSource(defaults: defaults, arguments: [], reload: { reloads += 1 }))
        XCTAssertEqual(reloads, 2)
        let next = now.addingTimeInterval(60)
        XCTAssertTrue(WeeklyWorkoutSync.publish(workouts: [row], now: next, calendar: calendar, sourceSyncedAt: next,
                                                defaults: defaults, arguments: [], reload: { reloads += 1 }))
        XCTAssertNil(WeeklyWorkoutSnapshot.load(defaults: defaults)?.sourceSyncedAt)
        XCTAssertEqual(WeeklyWorkoutSourceState.load(defaults: defaults),
                       WeeklyWorkoutSourceState(invalid: true, inFlight: true))
        XCTAssertFalse(WeeklyWorkoutSync.invalidateSource(defaults: nil, arguments: [], reload: { reloads += 1 }))
        XCTAssertEqual(reloads, 2)
    }

    func testPublishingAcrossMidnightReloadsWhileSourceRemainsInvalid() throws {
        let suiteName = "ohmytss.weekly-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        calendar.firstWeekday = 2
        let before = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 31,
                                                                      hour: 23, minute: 59, second: 54)))
        let after = before.addingTimeInterval(60)
        let row = workout("manual", before, "Run")
        var reloads = 0
        XCTAssertTrue(WeeklyWorkoutSync.publish(workouts: [row], now: before, calendar: calendar,
                                                sourceSyncedAt: before, defaults: defaults,
                                                arguments: [], reload: { reloads += 1 }))
        XCTAssertTrue(WeeklyWorkoutSync.beginSourceSync(defaults: defaults, arguments: []))
        XCTAssertTrue(WeeklyWorkoutSync.invalidateSource(defaults: defaults, arguments: [], reload: { reloads += 1 }))
        XCTAssertEqual(reloads, 2)
        XCTAssertTrue(WeeklyWorkoutSync.publish(workouts: [row], now: after, calendar: calendar,
                                                sourceSyncedAt: after, defaults: defaults,
                                                arguments: [], reload: { reloads += 1 }))
        XCTAssertEqual(reloads, 3)
        XCTAssertEqual(WeeklyWorkoutSourceState.load(defaults: defaults),
                       WeeklyWorkoutSourceState(invalid: true, inFlight: true))
        XCTAssertNil(WeeklyWorkoutSnapshot.load(defaults: defaults)?.sourceSyncedAt)
        XCTAssertEqual(WeeklyWorkoutSnapshot.load(defaults: defaults)?.records.map(\.workoutType), ["Run"])
    }

    func testInterruptedSyncIsMarkedInvalidOnNextLaunch() throws {
        let suiteName = "ohmytss.weekly-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        XCTAssertTrue(WeeklyWorkoutSync.beginSourceSync(defaults: defaults, arguments: []))
        let restartedDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        var reloads = 0
        XCTAssertTrue(WeeklyWorkoutSync.recoverInterruptedSourceSync(defaults: restartedDefaults,
                                                                      arguments: [], reload: { reloads += 1 }))
        XCTAssertEqual(WeeklyWorkoutSourceState.load(defaults: restartedDefaults),
                       WeeklyWorkoutSourceState(invalid: true, inFlight: false))
        XCTAssertTrue(WeeklyWorkoutSync.recoverInterruptedSourceSync(defaults: restartedDefaults,
                                                                      arguments: [], reload: { reloads += 1 }))
        XCTAssertEqual(reloads, 1)
    }

    func testTimeZoneChangeRebuildsWeekAndEmptyWeekIsPublished() throws {
        let suiteName = "ohmytss.weekly-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var chicago = Calendar(identifier: .gregorian)
        chicago.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Chicago"))
        chicago.firstWeekday = 2
        var tokyo = chicago
        tokyo.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let now = try XCTUnwrap(tokyo.date(from: DateComponents(year: 2026, month: 3, day: 9, hour: 12)))
        let priorWorkout = workout("prior", now.addingTimeInterval(-13 * 3600), "Run")
        var reloads = 0
        XCTAssertTrue(WeeklyWorkoutSync.publish(workouts: [priorWorkout], now: now, calendar: chicago,
                                                defaults: defaults, arguments: [], reload: { reloads += 1 }))
        let first = try XCTUnwrap(WeeklyWorkoutSnapshot.load(defaults: defaults))
        XCTAssertEqual(first.records.count, 1)
        XCTAssertTrue(WeeklyWorkoutSync.publish(workouts: [priorWorkout], now: now, calendar: tokyo,
                                                defaults: defaults, arguments: [], reload: { reloads += 1 }))
        let second = try XCTUnwrap(WeeklyWorkoutSnapshot.load(defaults: defaults))
        XCTAssertNotEqual(first.weekStart, second.weekStart)
        XCTAssertTrue(second.records.isEmpty)
        XCTAssertEqual(reloads, 2)
    }

    func testStorePublicationUsesStartTimeAndFetchFailurePreservesSnapshot() throws {
        let suiteName = "ohmytss.weekly-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Chicago"))
        calendar.firstWeekday = 2
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 4, hour: 12)))
        let container = try ModelContainer(for: Schema(AppSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let row = workout("in-week", now.addingTimeInterval(-3600), "Run")
        row.date = now.addingTimeInterval(-20 * 86400) // stale date from an earlier local time zone
        context.insert(row)
        context.insert(workout("suppressed", now, "Ride", suppressed: true))
        context.insert(workout("deleted", now, "Swim", deleted: true))
        try context.save()
        let store = onMyTss.DataStore(modelContext: context)
        var reloads = 0
        XCTAssertTrue(WeeklyWorkoutSync.publish(store: store, now: now, calendar: calendar, defaults: defaults,
                                                arguments: [], reload: { reloads += 1 }))
        let original = try XCTUnwrap(WeeklyWorkoutSnapshot.load(defaults: defaults))
        XCTAssertEqual(original.records.map(\.workoutType), ["Run"])
        let failing = FailingWidgetDataStore(modelContext: context)
        XCTAssertFalse(WeeklyWorkoutSync.publish(store: failing, now: now, calendar: calendar, defaults: defaults,
                                                 arguments: [], reload: { reloads += 1 }))
        XCTAssertEqual(WeeklyWorkoutSnapshot.load(defaults: defaults), original)
        XCTAssertEqual(reloads, 1)
    }

}

@MainActor
private final class FailingWidgetDataStore: onMyTss.DataStore {
    override func fetchWeeklyWidgetWorkouts(from start: Date, to end: Date) throws -> [Workout] {
        throw NSError(domain: "WeeklyWidgetTests", code: 1)
    }
}
