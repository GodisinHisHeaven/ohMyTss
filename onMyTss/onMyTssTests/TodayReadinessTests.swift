import XCTest
@testable import onMyTss

@MainActor
final class TodayReadinessTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    func testMissingDefaultAndSleepOnlyDataDoNotInventReadiness() {
        XCTAssertNil(TodayReadiness(days: [], lastComputation: nil, now: now).score)
        let day = DayAggregate(date: now.startOfDay)
        XCTAssertNil(TodayReadiness(days: [day], lastComputation: now, now: now).score)
        day.sleepDuration = 8
        day.avgHRV = 50
        XCTAssertNil(TodayReadiness(days: [day], lastComputation: now, now: now).score)
    }

    func testTodayShowsSavedScoreWithItsActualInputs() {
        let day = DayAggregate(date: now.startOfDay, ctl: 30, atl: 20, bodyBatteryScore: 78,
                               avgHRV: 54, hrvModifier: 0)
        let snapshot = TodayReadiness(days: [day], lastComputation: now, now: now)
        XCTAssertEqual(snapshot.score, 78)
        XCTAssertEqual(snapshot.updatedAt, now)
        XCTAssertTrue(snapshot.basis.contains("training load"))
        XCTAssertTrue(snapshot.basis.contains("HRV"))
        XCTAssertFalse(snapshot.basis.contains("sleep"))
    }

    func testYesterdayNeverBecomesTodayAndFutureUpdatesAreRejected() {
        let day = DayAggregate(date: now.startOfDay.addingTimeInterval(-86400), ctl: 30, bodyBatteryScore: 88)
        XCTAssertNil(TodayReadiness(days: [day], lastComputation: now, now: now).score)
        day.date = now.startOfDay
        XCTAssertNil(TodayReadiness(days: [day], lastComputation: now.addingTimeInterval(60), now: now).updatedAt)
    }

    func testInvalidPhysiologyAndOutOfRangeScoresStayUnavailable() {
        let day = DayAggregate(date: now.startOfDay, bodyBatteryScore: 50, avgHRV: .nan, hrvModifier: 2)
        XCTAssertNil(TodayReadiness.validScore(day))
        day.avgHRV = 50
        day.bodyBatteryScore = 101
        XCTAssertNil(TodayReadiness.validScore(day))
        day.bodyBatteryScore = 0
        XCTAssertEqual(TodayReadiness.validScore(day), 0)
    }

    func testWorkoutCategoryContainsNoDetailedMetrics() {
        XCTAssertEqual(WorkoutCategory(type: "VirtualRide"), .cycling)
        XCTAssertEqual(WorkoutCategory(type: "TrailRun"), .running)
        XCTAssertEqual(WorkoutCategory(type: "Traditional Strength Training"), .strength)
        XCTAssertEqual(WorkoutCategory(type: "Pool Swim"), .swimming)
        XCTAssertEqual(WorkoutCategory(type: "Unrecognized"), .other)
    }
}
