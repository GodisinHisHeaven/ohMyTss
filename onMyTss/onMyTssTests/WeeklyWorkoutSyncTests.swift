import Foundation
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
                                             generatedAt: date(7, 23, 59), records: [])
        let nextDay = date(8, 12, 0) // Daylight-saving transition.
        XCTAssertTrue(snapshot.covers(day: date(7, 0, 0), asOf: nextDay, calendar: calendar))
        XCTAssertFalse(snapshot.covers(day: date(8, 0, 0), asOf: nextDay, calendar: calendar))

        let updated = WeeklyWorkoutSnapshot(weekStart: snapshot.weekStart, weekEnd: snapshot.weekEnd,
                                            generatedAt: nextDay, records: [])
        XCTAssertTrue(updated.covers(day: date(8, 0, 0), asOf: nextDay, calendar: calendar))
    }

    func testWorkoutCategoriesRecognizeBikeAndOtherCommonTypes() {
        XCTAssertEqual(WeeklyWorkoutCategory(type: "MountainBike"), .cycling)
        XCTAssertEqual(WeeklyWorkoutCategory(type: "VirtualRide"), .cycling)
        XCTAssertEqual(WeeklyWorkoutCategory(type: "TrailRun"), .running)
        XCTAssertEqual(WeeklyWorkoutCategory(type: "WeightTraining"), .strength)
        XCTAssertEqual(WeeklyWorkoutCategory(type: "Yoga"), .other)
    }
}
