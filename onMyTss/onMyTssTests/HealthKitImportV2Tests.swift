import XCTest
import SwiftData
import HealthKit
@testable import onMyTss

/// Synthetic fixtures check adapter behavior, not physiological accuracy.
@MainActor
final class HealthKitImportV2Tests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeStore() throws -> DataStore {
        let container = try ModelContainer(for: Schema(AppSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return DataStore(modelContainer: container)
    }

    func testMissingFTPStillImportsRunSwimAndStrength() async throws {
        let store = try makeStore()
        let thresholds = try store.fetchUserThresholds()
        thresholds.cyclingFTP = nil
        let source = SyntheticHealthSource()
        let aggregator = WorkoutAggregator(healthKitManager: source, stravaAuthManager: UnusedStravaAuth(), dataStore: store)
        let fixtures = [HKWorkoutActivityType.running, .swimming, .traditionalStrengthTraining].map {
            HKWorkout(activityType: $0, start: start, end: start.addingTimeInterval(600))
        }
        let imported = try await aggregator.convertHealthKitWorkouts(fixtures)
        XCTAssertEqual(imported.map(\.workoutType), ["Running", "Swimming", "Strength"])
        XCTAssertEqual(imported.count, 3)
        XCTAssertTrue(imported.allSatisfy { $0.tss.isFinite && $0.features.heartRate.isEmpty })
    }

    func testPowerTSSUsesObservedTimeAndExcludesPause() async throws {
        let store = try makeStore()
        let thresholds = try store.fetchUserThresholds()
        thresholds.cyclingFTP = 200
        let source = SyntheticHealthSource()
        source.features.power = [.init(start: start, end: start.addingTimeInterval(600), value: 200)]
        source.features.pauses = [.init(start: start.addingTimeInterval(120), end: start.addingTimeInterval(420))]
        let aggregator = WorkoutAggregator(healthKitManager: source, stravaAuthManager: UnusedStravaAuth(), dataStore: store)
        let workout = HKWorkout(activityType: .cycling, start: start, end: start.addingTimeInterval(600))
        let result = try await aggregator.convertHealthKitWorkouts([workout])
        let imported = try XCTUnwrap(result.first)
        // 300 seconds at FTP contributes 100 * 300/3600 legacy power TSS.
        XCTAssertEqual(imported.tss, 100.0 / 12.0, accuracy: 0.0001)
        XCTAssertEqual(imported.normalizedPower ?? -1, 200, accuracy: 0.0001)
    }

    func testSensorFailureRetainsWorkoutAndMarksMissing() async throws {
        let source = SyntheticHealthSource()
        source.sensorFails = true
        let aggregator = WorkoutAggregator(healthKitManager: source, stravaAuthManager: UnusedStravaAuth(), dataStore: try makeStore())
        let workout = HKWorkout(activityType: .running, start: start, end: start.addingTimeInterval(600))
        let imported = try await aggregator.convertHealthKitWorkouts([workout])
        XCTAssertEqual(imported.count, 1)
        XCTAssertNil(imported[0].averageHeartRate)
        XCTAssertTrue(imported[0].features.provenance.contains("Sensor query failed; retry sync"))
    }

    func testDuplicateSourcesRemainAvailableForPersistence() async throws {
        let source = SyntheticHealthSource()
        let store = try makeStore()
        let aggregator = WorkoutAggregator(healthKitManager: source, stravaAuthManager: UnusedStravaAuth(), dataStore: store)
        let hk = Workout(id: "synthetic-hk", date: start.startOfDay, startTime: start, duration: 600,
                         workoutType: "Strength", tss: 10, calculationMethod: "duration", source: .healthKit)
        let strava = Workout(id: "synthetic-strava", date: start.startOfDay, startTime: start, duration: 600,
                             workoutType: "WeightTraining", tss: 12, calculationMethod: "duration", source: .strava)
        let visible = aggregator.deduplicateWorkouts(healthKit: [hk], strava: [strava])
        XCTAssertEqual(visible.map(\.id), [strava.id])
        XCTAssertTrue(hk.isSuppressed)
        XCTAssertFalse(strava.isSuppressed)
    }

    func testLegacyHRIntegratesDistributionRatherThanWholeWorkoutMean() {
        let split = [TimedValue(start: start, end: start.addingTimeInterval(300), value: 100),
                     TimedValue(start: start.addingTimeInterval(300), end: start.addingTimeInterval(600), value: 180)]
        let average = [TimedValue(start: start, end: start.addingTimeInterval(600), value: 140)]
        let splitValue = TSSCalculator.legacyHeartRateTSS(intervals: split, maxHeartRate: 200, restingHeartRate: 60)
        let averageValue = TSSCalculator.legacyHeartRateTSS(intervals: average, maxHeartRate: 200, restingHeartRate: 60)
        XCTAssertGreaterThan(splitValue, averageValue) // convex intensity response
    }
}

@MainActor
private final class SyntheticHealthSource: HealthKitManaging {
    var features = WorkoutFeatures()
    var sensorFails = false
    func fetchWorkouts(from startDate: Date, to endDate: Date) async throws -> [HKWorkout] { [] }
    func fetchPowerSamples(for workout: HKWorkout) async throws -> [HKQuantitySample] { [] }
    func fetchHeartRateSamples(for workout: HKWorkout) async throws -> [HKQuantitySample] { [] }
    func fetchWorkoutFeatures(for workout: HKWorkout) async throws -> WorkoutFeatures {
        if sensorFails { throw HealthKitError.noData }
        return features
    }
}

@MainActor
private final class UnusedStravaAuth: StravaAuthManaging {
    func getValidAccessToken() async throws -> String { throw HealthKitError.noData }
}
