import HealthKit
import SwiftData
import XCTest
@testable import onMyTss

@MainActor
final class RecoveryMeasurementsTests: XCTestCase {
    func testOneWakeDateForOverlappingStagesAcrossMidnightAndSDNNOnlyDuringAsleepIntervals() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Chicago"))
        // The repeated hour on this fall-back night counts twice in elapsed time.
        let midnight = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1)))
        func hour(_ offset: Double) -> Date { midnight.addingTimeInterval(offset * 3600) }
        func sleep(_ stage: HKCategoryValueSleepAnalysis, _ start: Double, _ end: Double) -> HKCategorySample {
            HKCategorySample(type: HKCategoryType(.sleepAnalysis), value: stage.rawValue, start: hour(start), end: hour(end))
        }
        func hrv(_ value: Double, at date: Date) -> HKQuantitySample {
            HKQuantitySample(type: HKQuantityType(.heartRateVariabilitySDNN),
                             quantity: HKQuantity(unit: .secondUnit(with: .milli), doubleValue: value), start: date, end: date)
        }
        let stages = [sleep(.inBed, -3, 8), sleep(.asleepCore, -2, 1), sleep(.asleepDeep, -1, 1),
                      sleep(.awake, 1, 2), sleep(.asleepUnspecified, 2, 6), sleep(.asleepREM, 4, 6),
                      sleep(.asleepCore, 12, 13), sleep(.awake, 18, 19), sleep(.inBed, 18, 20)]
        let samples = [hrv(40, at: hour(-1)), hrv(60, at: hour(4)), hrv(150, at: hour(1.5)),
                       hrv(150, at: hour(10)), hrv(150, at: hour(12.5))]
        let result = try await RecoveryMeasurements.collect(hrv: samples, rhr: [], sleep: stages,
                                                            through: hour(23), calendar: calendar)
        XCTAssertEqual(result.sleep.count, 1)
        XCTAssertEqual(result.sleep[midnight]?.durationHours, 7)
        XCTAssertEqual(result.sleep[midnight]?.deepSleepHours, 2)
        XCTAssertEqual(result.sleep[midnight]?.awakeMinutes, 60)
        XCTAssertEqual(result.overnightHRV[midnight], 50)
        XCTAssertEqual(result.hrv[midnight], 127.5)
        XCTAssertTrue(SleepAnalyzer.nights(from: [sleep(.inBed, -2, 7), sleep(.awake, 0, 1)], calendar: calendar).isEmpty)
    }

    func testUpgradeRebuildsStoredNightsAndBaselineWithoutWorkoutsAndThenUsesIncrementalWindow() async throws {
        let calendar = Calendar.current
        let now = Date().startOfDay.addingTimeInterval(12 * 3600)
        let schema = Schema(AppSchema.models)
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = DataStore(modelContainer: container)
        let thresholds = try store.fetchUserThresholds()
        thresholds.hasCompletedOnboarding = true
        try store.saveUserThresholds(thresholds)
        let state = try store.fetchAppState()
        state.lastRecoverySyncDate = now
        try store.saveDayAggregate(DayAggregate(date: now.startOfDay, bodyBatteryScore: 100))
        let source = NightHistory(now: now)
        let engine = BodyBatteryEngine(healthKitManager: source, dataStore: store,
                                      stravaAuthManager: StravaAuthManager(dataStore: store), clock: { now })
        try await engine.incrementalUpdate()
        let rows = try store.fetchAllDayAggregates()
        let today = try XCTUnwrap(store.fetchDayAggregate(for: now))
        XCTAssertEqual(today.sleepDuration, 4)
        XCTAssertEqual(today.recordedAwakeMinutes, 0)
        XCTAssertEqual(today.overnightHRV, 30)
        XCTAssertLessThan(today.bodyBatteryScore, 40)
        XCTAssertEqual(TodayReadiness(days: rows, lastComputation: now, now: now).score, today.bodyBatteryScore)
        XCTAssertEqual(state.recoveryInputVersion, ActivitySyncPlan.recoveryInputVersion)
        XCTAssertLessThan(try XCTUnwrap(source.sleepStarts.first), now.addingDays(-30))
        let old = try XCTUnwrap(store.fetchDayAggregate(for: now.addingDays(-8)))
        XCTAssertNil(old.hrvModifier, "Later samples must never calibrate the first recorded night.")
        XCTAssertNil(try store.fetchDayAggregate(for: now.addingDays(-9))?.overnightHRV)

        let before = today.bodyBatteryScore
        source.empty = true
        try await engine.incrementalUpdate()
        XCTAssertEqual(source.sleepStarts.count, 2)
        XCTAssertGreaterThan(try XCTUnwrap(source.sleepStarts.last), now.addingDays(-6))
        XCTAssertEqual(today.bodyBatteryScore, before)
        XCTAssertEqual(today.overnightHRV, 30)
        XCTAssertEqual(today.sleepDuration, 4)
        XCTAssertEqual(DayAggregate.byLocalDay(try store.fetchAllDayAggregates(), calendar: calendar).count,
                       DayAggregate.byLocalDay(rows, calendar: calendar).count)
    }

    func testNinetyDayChartOpensFromThousandMeasuredDaysWithBoundedWorkoutFields() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let schema = Schema(AppSchema.models)
        let url = directory.appendingPathComponent("readiness.store")
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
        let now = Date().startOfDay.addingTimeInterval(12 * 3600)
        let calendar = Calendar.current
        let seed = ModelContext(container)
        let payload = Data(repeating: 42, count: 8192)
        for offset in 0..<1000 {
            let date = now.startOfDay.addingDays(-offset)
            let day = DayAggregate(date: date, totalTSS: 40, ctl: 40, atl: 40, avgHRV: 50, avgRHR: 55,
                                   sleepDuration: offset == 0 ? 4 : 8, recordedAwakeMinutes: 0)
            let workout = Workout(id: "readiness-\(offset)", date: date, startTime: date, duration: 3600,
                                  workoutType: "Ride", tss: 40, calculationMethod: "power", source: .manual)
            workout.featuresData = payload
            day.hasWorkoutDetails = true
            seed.insert(day)
            seed.insert(workout)
            workout.dayAggregate = day
        }
        try seed.save()
        let context = ModelContext(container)
        let store = DataStore(modelContext: context)
        let start = now.startOfDay.addingDays(-89)
        let began = Date()
        let rows = try store.fetchDayAggregates(from: TrainingReadiness.historyStart(for: start, calendar: calendar), to: now)
        let query = TrainingReadiness.workoutQuery(from: start, before: now.startOfDay.addingDays(1), calendar: calendar)
        XCTAssertFalse(query.propertiesToFetch.contains(\Workout.featuresData))
        let workouts = try context.fetch(query)
        let scores = TrainingReadiness.dailyScores(rows, workouts: workouts, from: start, asOf: now, calendar: calendar)
        let seconds = Date().timeIntervalSince(began)
        print("READINESS_HISTORY days=\(scores.count) aggregate_rows=\(rows.count) workout_rows=\(workouts.count) seconds=\(seconds)")
        XCTAssertEqual(rows.count, 120)
        XCTAssertEqual(workouts.count, 93)
        XCTAssertEqual(scores.count, 90)
        XCTAssertTrue(scores.dropLast().allSatisfy { $0.score == 85 })
        XCTAssertEqual(scores.last?.score, 37)
        XCTAssertLessThan(seconds, 0.75)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Workout>()), 1000)
    }
}

@MainActor
private final class NightHistory: HealthKitManager {
    let now: Date
    var empty = false
    var sleepStarts: [Date] = []

    init(now: Date) { self.now = now; super.init() }

    override func fetchWorkoutChanges(anchor: HKQueryAnchor?) async throws -> (workouts: [HKWorkout], deletedIDs: [String], newAnchor: HKQueryAnchor) {
        ([], [], HKQueryAnchor(fromValue: 1))
    }

    override func fetchSleepSamples(from startDate: Date, to endDate: Date) async throws -> [HKCategorySample] {
        sleepStarts.append(startDate)
        guard !empty else { return [] }
        return (0...8).map { age in
            let end = now.startOfDay.addingDays(-age).addingTimeInterval(6 * 3600)
            return HKCategorySample(type: HKCategoryType(.sleepAnalysis), value: HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                                    start: end.addingTimeInterval(age == 0 ? -4 * 3600 : -8 * 3600), end: end)
        }
    }

    override func fetchHRVSamples(from startDate: Date, to endDate: Date) async throws -> [HKQuantitySample] {
        guard !empty else { return [] }
        return (0...8).map { age in
            let at = now.startOfDay.addingDays(-age).addingTimeInterval(3 * 3600)
            return HKQuantitySample(type: HKQuantityType(.heartRateVariabilitySDNN),
                                    quantity: HKQuantity(unit: .secondUnit(with: .milli), doubleValue: age == 0 ? 30 : 50),
                                    start: at, end: at)
        }
    }
    override func fetchRestingHeartRateSamples(from startDate: Date, to endDate: Date) async throws -> [HKQuantitySample] { [] }
}
