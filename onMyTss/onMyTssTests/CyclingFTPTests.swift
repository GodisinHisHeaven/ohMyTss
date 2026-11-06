import XCTest
import SwiftData
import HealthKit
@testable import onMyTss

/// Synthetic power/HR fixtures exercise the real import, persistence and sync paths.
@MainActor
final class CyclingFTPTests: XCTestCase {
    func testUnchangedHealthKitSampleRefreshKeepsWorkoutAndDayTSS() async throws {
        let fixture = try CyclingFTPFixture()
        let thresholds = try fixture.configure(manual: 200, strava: 250, preferStrava: true)
        try await fixture.engine.incrementalUpdate()
        let row = try XCTUnwrap(fixture.store.fetchWorkout(byId: fixture.health.workout.uuid.uuidString))
        let initial = row.tss
        let samples = row.featuresData
        let revision = thresholds.lastModified
        try assertTSS(64, method: "power-time-v2", row: row, fixture: fixture)

        fixture.now = fixture.now.addingTimeInterval(6 * 3600)
        try await fixture.engine.incrementalUpdate()

        XCTAssertEqual(fixture.health.featureReads, 2, "The unchanged recent samples must actually be reimported")
        XCTAssertEqual(row.featuresData, samples)
        XCTAssertEqual(thresholds.lastModified, revision)
        XCTAssertEqual(row.tss, initial, accuracy: 0.00001)
        try assertTSS(64, method: "power-time-v2", row: row, fixture: fixture)
    }

    func testHealthKitImportAndRecalculationShareFTPAndFallbackPolicy() async throws {
        for scenario in scenarios {
            for includeHeartRate in [false, true] {
                let fixture = try CyclingFTPFixture(includeHeartRate: includeHeartRate)
                try fixture.configure(manual: scenario.manual, strava: scenario.strava, preferStrava: scenario.preferStrava)
                let rows = try await fixture.aggregator.convertHealthKitWorkouts([fixture.health.workout])
                let row = try XCTUnwrap(rows.first)
                let expected = expectedTSS(ftp: scenario.effective, includeHeartRate: includeHeartRate)
                let method = scenario.effective != nil ? "power-time-v2" :
                    includeHeartRate ? "hr-time-v2 (resting HR assumed 60)" : "duration estimate"
                XCTAssertEqual(row.tss, expected, accuracy: 0.00001, scenario.name)
                XCTAssertEqual(row.calculationMethod, method, scenario.name)
                _ = try await fixture.store.applyImportedWorkouts(rows, deletedIDs: [])
                _ = try await fixture.store.refreshLegacyWorkoutTSS()
                try await fixture.store.refreshLegacyLoadHistory(from: row.date, now: fixture.now)
                try assertTSS(expected, method: method, row: row, fixture: fixture, message: scenario.name)

                let samples = row.featuresData
                let refreshed = try await fixture.aggregator.convertHealthKitWorkouts([fixture.health.workout])
                let changes = try await fixture.store.applyImportedWorkouts(refreshed, deletedIDs: [])
                XCTAssertTrue(changes.isEmpty, "Unchanged sample refresh: \(scenario.name)")
                XCTAssertEqual(row.featuresData, samples, scenario.name)
                try assertTSS(expected, method: method, row: row, fixture: fixture, message: scenario.name)
            }
        }
    }

    func testStravaImportAndRecalculationPreserveValidManualFallback() async throws {
        for scenario in scenarios {
            for includeHeartRate in [false, true] {
                let fixture = try CyclingFTPFixture(includeHeartRate: includeHeartRate)
                try fixture.configure(manual: scenario.manual, strava: scenario.strava, preferStrava: scenario.preferStrava)
                fixture.health.includeWorkout = false
                fixture.strava.listed = [try fixture.stravaActivity(includeHeartRate: includeHeartRate)]
                try fixture.store.saveStravaAuth(StravaAuth(connectedAt: fixture.now, isConnected: true))
                let rows = try await fixture.aggregator.fetchWorkouts(from: fixture.now.addingDays(-1), to: fixture.now)
                let row = try XCTUnwrap(rows.first)
                let expected = expectedTSS(ftp: scenario.effective, includeHeartRate: includeHeartRate)
                let method = scenario.effective != nil ? "power" :
                    includeHeartRate ? "hr summary estimate" : "duration estimate"
                XCTAssertEqual(rows.count, 1)
                XCTAssertEqual(row.tss, expected, accuracy: 0.00001, scenario.name)
                XCTAssertEqual(row.calculationMethod, method, scenario.name)
                _ = try await fixture.store.applyImportedWorkouts(rows, deletedIDs: [])
                _ = try await fixture.store.refreshLegacyWorkoutTSS()
                try await fixture.store.refreshLegacyLoadHistory(from: row.date, now: fixture.now)
                try assertTSS(expected, method: method, row: row, fixture: fixture, message: scenario.name)
            }
        }
    }

    func testPreferenceEditsRecalculateSavedSamplesAndRemainStableOnRefresh() async throws {
        let fixture = try CyclingFTPFixture()
        let thresholds = try fixture.configure(manual: 200, strava: 250, preferStrava: false)
        try await fixture.engine.incrementalUpdate()
        let row = try XCTUnwrap(fixture.store.fetchWorkout(byId: fixture.health.workout.uuid.uuidString))
        let samples = row.featuresData
        try assertTSS(100, method: "power-time-v2", row: row, fixture: fixture)
        for (preferStrava, expected) in [(true, 64.0), (false, 100.0)] {
            fixture.now = fixture.now.addingTimeInterval(60)
            thresholds.preferStravaFTP = preferStrava
            thresholds.lastModified = fixture.now
            try fixture.context.save()
            let reads = fixture.health.featureReads
            try await fixture.engine.incrementalUpdate()
            XCTAssertEqual(fixture.health.featureReads, reads, "Threshold edits must reuse saved samples")
            try assertTSS(expected, method: "power-time-v2", row: row, fixture: fixture)

            fixture.now = fixture.now.addingTimeInterval(6 * 3600)
            try await fixture.engine.incrementalUpdate()
            XCTAssertEqual(fixture.health.featureReads, reads + 1)
            XCTAssertEqual(row.featuresData, samples)
            try assertTSS(expected, method: "power-time-v2", row: row, fixture: fixture)
        }
    }

    private struct Scenario {
        let name: String
        let manual: Int?
        let strava: Int?
        let preferStrava: Bool
        let effective: Int?
    }

    private var scenarios: [Scenario] {
        [
            .init(name: "different preferred", manual: 200, strava: 250, preferStrava: true, effective: 250),
            .init(name: "different manual", manual: 200, strava: 250, preferStrava: false, effective: 200),
            .init(name: "equal preferred", manual: 200, strava: 200, preferStrava: true, effective: 200),
            .init(name: "equal manual", manual: 200, strava: 200, preferStrava: false, effective: 200),
            .init(name: "missing Strava", manual: 200, strava: nil, preferStrava: true, effective: 200),
            .init(name: "zero Strava", manual: 200, strava: 0, preferStrava: true, effective: 200),
            .init(name: "negative Strava", manual: 200, strava: -1, preferStrava: true, effective: 200),
            .init(name: "missing manual", manual: nil, strava: 250, preferStrava: true, effective: 250),
            .init(name: "zero manual", manual: 0, strava: 250, preferStrava: true, effective: 250),
            .init(name: "negative manual", manual: -1, strava: 250, preferStrava: true, effective: 250),
            .init(name: "unpreferred Strava", manual: nil, strava: 250, preferStrava: false, effective: nil),
            .init(name: "unpreferred Strava zero manual", manual: 0, strava: 250, preferStrava: false, effective: nil),
            .init(name: "unpreferred Strava negative manual", manual: -1, strava: 250, preferStrava: false, effective: nil),
            .init(name: "both missing preferred", manual: nil, strava: nil, preferStrava: true, effective: nil),
            .init(name: "both missing manual", manual: nil, strava: nil, preferStrava: false, effective: nil),
            .init(name: "both invalid", manual: -1, strava: 0, preferStrava: true, effective: nil)
        ]
    }

    private func expectedTSS(ftp: Int?, includeHeartRate: Bool) -> Double {
        if let ftp { return pow(200 / Double(ftp), 2) * 100 }
        if includeHeartRate {
            let reserveFraction = (150.0 - 60) / (190 - 60)
            return reserveFraction * exp(1.92 * reserveFraction) / (0.85 * exp(1.92 * 0.85)) * 100
        }
        return 60
    }

    private func assertTSS(_ expected: Double, method: String, row: Workout,
                           fixture: CyclingFTPFixture, message: String = "",
                           file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(row.tss, expected, accuracy: 0.00001, message, file: file, line: line)
        XCTAssertEqual(row.calculationMethod, method, message, file: file, line: line)
        let day = try XCTUnwrap(fixture.store.fetchDayAggregate(for: row.date), file: file, line: line)
        XCTAssertEqual(day.totalTSS, expected, accuracy: 0.00001, message, file: file, line: line)
    }
}

@MainActor private final class CyclingFTPFixture {
    let container: ModelContainer
    let context: ModelContext
    let store: onMyTss.DataStore
    var now: Date
    let health: CyclingFTPHealthSource
    let strava = CyclingFTPStravaSource()
    lazy var aggregator = WorkoutAggregator(healthKitManager: health, stravaAuthManager: CyclingFTPToken(),
                                            dataStore: store, stravaClient: strava)
    lazy var engine = BodyBatteryEngine(healthKitManager: health, dataStore: store,
        stravaAuthManager: CyclingFTPToken(), stravaClient: strava, clock: { [unowned self] in self.now })
    nonisolated deinit {}

    init(includeHeartRate: Bool = false) throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000).startOfDay.addingTimeInterval(12 * 3600)
        self.now = now
        let schema = Schema(AppSchema.models)
        container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        context = container.mainContext
        store = DataStore(modelContext: context)
        health = CyclingFTPHealthSource(now: now, includeHeartRate: includeHeartRate)
    }

    @discardableResult
    func configure(manual: Int?, strava: Int?, preferStrava: Bool) throws -> UserThresholds {
        let thresholds = try store.fetchUserThresholds()
        thresholds.hasCompletedOnboarding = true
        thresholds.maxHeartRate = 190
        thresholds.cardioMaxHeartRate = 190
        thresholds.cyclingFTP = manual
        thresholds.stravaFTP = strava
        thresholds.preferStravaFTP = preferStrava
        thresholds.lastModified = now.addingDays(-2)
        try context.save()
        return thresholds
    }

    func stravaActivity(includeHeartRate: Bool) throws -> StravaActivity {
        var data: [String: Any] = ["id": 123, "start_date": ISO8601DateFormatter().string(from: health.workout.startDate),
                                  "moving_time": 3600, "elapsed_time": 3600, "sport_type": "Ride",
                                  "weighted_average_watts": 200, "average_watts": 200, "device_watts": true,
                                  "has_heartrate": includeHeartRate]
        if includeHeartRate { data["average_heartrate"] = 150 }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(StravaActivity.self, from: JSONSerialization.data(withJSONObject: data))
    }
}

@MainActor private final class CyclingFTPHealthSource: HealthKitManager {
    let workout: HKWorkout
    let includeHeartRate: Bool
    var includeWorkout = true
    var featureReads = 0
    init(now: Date, includeHeartRate: Bool) {
        workout = HKWorkout(activityType: .cycling, start: now.addingTimeInterval(-3600), end: now)
        self.includeHeartRate = includeHeartRate
        super.init()
    }
    override func fetchWorkoutChanges(anchor: HKQueryAnchor?) async throws -> (workouts: [HKWorkout], deletedIDs: [String], newAnchor: HKQueryAnchor) {
        (includeWorkout && anchor == nil ? [workout] : [], [], HKQueryAnchor(fromValue: 1))
    }
    override func fetchWorkouts(from startDate: Date, to endDate: Date) async throws -> [HKWorkout] {
        includeWorkout ? [workout] : []
    }
    override func fetchWorkouts(ids: [String]) async throws -> [HKWorkout] {
        includeWorkout && ids.contains(workout.uuid.uuidString) ? [workout] : []
    }
    override func fetchWorkoutFeatures(for workout: HKWorkout) async throws -> WorkoutFeatures {
        featureReads += 1
        var features = WorkoutFeatures()
        features.power = [.init(start: workout.startDate, end: workout.endDate, value: 200)]
        if includeHeartRate {
            features.heartRate = [.init(start: workout.startDate, end: workout.endDate, value: 150)]
        }
        return features
    }
    override func fetchHRVSamples(from startDate: Date, to endDate: Date) async throws -> [HKQuantitySample] { [] }
    override func fetchRestingHeartRateSamples(from startDate: Date, to endDate: Date) async throws -> [HKQuantitySample] { [] }
    override func fetchSleepSamples(from startDate: Date, to endDate: Date) async throws -> [HKCategorySample] { [] }
}

@MainActor private final class CyclingFTPStravaSource: StravaActivityFetching {
    var listed: [StravaActivity] = []
    nonisolated deinit {}
    func activities(accessToken: String, after: Date, before: Date, page: Int, perPage: Int) async throws -> [StravaActivity] { listed }
    func activity(accessToken: String, id: Int) async throws -> StravaActivity? { listed.first { $0.id == id } }
}

@MainActor private final class CyclingFTPToken: StravaAuthManaging {
    nonisolated deinit {}
    func getValidAccessToken() async throws -> String { "synthetic-ftp-token" }
}
