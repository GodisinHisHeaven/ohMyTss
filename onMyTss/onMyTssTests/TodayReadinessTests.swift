import XCTest
@testable import onMyTss

@MainActor
final class TodayReadinessTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private var day: Date { now.startOfDay }

    private func priorDays(_ count: Int = 14) -> [DayAggregate] {
        (1...count).map { DayAggregate(date: day.addingDays(-$0), avgHRV: 50, avgRHR: 55, sleepDuration: 8, recordedAwakeMinutes: 0) }
    }

    func testTrainingAloneCannotPublishAnOldHighScore() {
        let row = DayAggregate(date: day, ctl: 45, atl: 20, tsb: 25, bodyBatteryScore: 100)
        let result = TodayReadiness(days: [row], lastComputation: now, now: now)
        XCTAssertNil(result.score)
        XCTAssertTrue(result.basis.contains("Training load"))
        XCTAssertNil(TodayReadiness(days: [], lastComputation: nil, now: now).score)
    }

    func testShortNightAndRepeatedSleepLossLowerReadinessAtTheSameTrainingLoad() throws {
        let row = DayAggregate(date: day, ctl: 45, atl: 30, tsb: 15, avgHRV: 50, avgRHR: 55, sleepDuration: 8, recordedAwakeMinutes: 0)
        let prior = priorDays()
        func snapshot() -> TodayReadiness { TodayReadiness(days: prior + [row], lastComputation: now, now: now) }
        let rested = try XCTUnwrap(snapshot().score)
        XCTAssertGreaterThanOrEqual(rested, 80)
        row.sleepDuration = 4
        let short = try XCTUnwrap(snapshot().score)
        XCTAssertLessThan(short, 40)
        XCTAssertEqual(snapshot().assessment?.limitingFactor, "Short sleep last night")
        row.sleepDuration = 8
        prior[0].sleepDuration = 4
        prior[1].sleepDuration = 4
        XCTAssertLessThan(try XCTUnwrap(snapshot().score), rested)
        XCTAssertEqual(snapshot().assessment?.limitingFactor, "Short sleep on previous nights")
        XCTAssertEqual(snapshot().updatedAt, now)
    }

    func testInterruptedSleepAndUnverifiedOldSleepCannotProduceHighReadiness() throws {
        let row = DayAggregate(date: day, avgHRV: 50, sleepDuration: 8)
        let rows = priorDays() + [row]
        func snapshot() -> TodayReadiness { TodayReadiness(days: rows, lastComputation: nil, now: now) }
        XCTAssertEqual(snapshot().score, 69, "An old time-in-bed total is only partial evidence.")
        row.recordedAwakeMinutes = 60
        XCTAssertEqual(snapshot().score, 75)
        XCTAssertEqual(snapshot().assessment?.limitingFactor, "Interrupted sleep last night")
        row.recordedAwakeMinutes = 0
        XCTAssertEqual(snapshot().score, 85)
    }

    func testSparseMeasurementsAndFutureDaysCannotFormABaseline() throws {
        let row = DayAggregate(date: day, avgHRV: 50, hrvModifier: 20)
        let six = priorDays(6)
        let future = DayAggregate(date: day.addingDays(1), avgHRV: 5)
        let outside = DayAggregate(date: day.addingDays(-31), avgHRV: 5)
        let duplicate = DayAggregate(date: six[0].date.addingTimeInterval(3600), avgHRV: 5)
        let rows = [row, future, outside, duplicate] + six
        XCTAssertNil(TodayReadiness(days: rows, lastComputation: nil, now: now).score)
        let seventh = DayAggregate(date: day.addingDays(-30), avgHRV: 50)
        let partial = TodayReadiness(days: rows + [seventh], lastComputation: nil, now: now)
        XCTAssertEqual(partial.score, 69)
        XCTAssertTrue(partial.basis.contains("Partial"))
        row.avgHRV = .nan
        row.sleepDuration = .infinity
        XCTAssertNil(TodayReadiness(days: rows + [seventh], lastComputation: nil, now: now).score)
    }

    func testLowOvernightHRVAndHighRestingHRLowerScoresEvenInALightTrainingWeek() throws {
        let prior = priorDays()
        for previous in prior { previous.overnightHRV = 50 }
        let row = DayAggregate(date: day, ctl: 50, atl: 10, tsb: 40, avgHRV: 80, avgRHR: 55, sleepDuration: 8, recordedAwakeMinutes: 0)
        row.overnightHRV = 30
        func snapshot() -> TodayReadiness { TodayReadiness(days: prior + [row], lastComputation: nil, now: now) }
        XCTAssertLessThan(try XCTUnwrap(snapshot().score), 60)
        XCTAssertTrue(snapshot().basis.contains("overnight HRV"))
        XCTAssertEqual(snapshot().assessment?.limitingFactor, "HRV below your baseline")
        row.overnightHRV = 50
        row.avgRHR = 64
        XCTAssertLessThan(try XCTUnwrap(snapshot().score), 60)
        XCTAssertEqual(snapshot().assessment?.limitingFactor, "Resting HR above your baseline")
    }

    func testHardWorkoutExpiresByElapsedHoursAndExcludesSuppressedOrFutureSessions() throws {
        let prior = priorDays()
        let row = DayAggregate(date: day, avgHRV: 50, sleepDuration: 8, recordedAwakeMinutes: 0)
        let time = day.addingTimeInterval(12 * 3600)
        let workout = Workout(id: "hard", date: day, startTime: time.addingTimeInterval(-3600),
                              duration: 3600, workoutType: "Ride", tss: 130, calculationMethod: "power", source: .manual)
        row.hasWorkoutDetails = true
        row.workouts = [workout]
        func score(_ at: Date) throws -> Int {
            try XCTUnwrap(TodayReadiness(days: prior + [row], lastComputation: nil, now: at).score)
        }
        let before = try score(time.addingTimeInterval(-7200))
        let after = try score(time)
        XCTAssertLessThan(after, before)
        XCTAssertGreaterThan(try score(time.addingTimeInterval(10 * 3600)), after)
        workout.isSuppressed = true
        XCTAssertEqual(try score(time), before)
        workout.isSuppressed = false
        workout.isTombstoned = true
        XCTAssertEqual(try score(time), before)
    }

    func testMissingSleepOrHeartBaselineLimitsScoreAndNeverReusesYesterday() throws {
        let row = DayAggregate(date: day, bodyBatteryScore: 100, sleepDuration: 8, recordedAwakeMinutes: 0)
        XCTAssertEqual(TodayReadiness(days: [row], lastComputation: nil, now: now).score, 69)
        row.sleepDuration = nil
        row.avgHRV = 50
        XCTAssertEqual(TodayReadiness(days: priorDays() + [row], lastComputation: nil, now: now).score, 69)
        XCTAssertNil(TodayReadiness(days: priorDays(), lastComputation: now, now: now).score)
        XCTAssertNil(TodayReadiness(days: [row], lastComputation: now.addingTimeInterval(60), now: now).updatedAt)
    }

    func testCompletedSessionIsUsedBeforeItsDailyRollupExists() throws {
        let row = DayAggregate(date: day, avgHRV: 50, sleepDuration: 8, recordedAwakeMinutes: 0)
        let prior = Array(priorDays().dropFirst())
        let start = day.addingTimeInterval(-2 * 3600)
        let hard = Workout(id: "late-ride", date: start.startOfDay, startTime: start, duration: 3600,
                           workoutType: "Ride", tss: 135, calculationMethod: "power", source: .strava)
        let time = day.addingTimeInterval(7 * 3600)
        let snapshot = TodayReadiness(days: prior + [row], workouts: [hard], lastComputation: nil, now: time)
        XCTAssertLessThan(try XCTUnwrap(snapshot.score), 60)
        XCTAssertEqual(snapshot.assessment?.limitingFactor, "Recent hard training")
    }

    func testWorkoutCategoryContainsNoDetailedMetrics() {
        XCTAssertEqual(WorkoutCategory(type: "VirtualRide"), .cycling)
        XCTAssertEqual(WorkoutCategory(type: "TrailRun"), .running)
        XCTAssertEqual(WorkoutCategory(type: "Traditional Strength Training"), .strength)
        XCTAssertEqual(WorkoutCategory(type: "Pool Swim"), .swimming)
        XCTAssertEqual(WorkoutCategory(type: "Unrecognized"), .other)
    }
}
