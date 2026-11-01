//
//  WorkoutAggregatorTests.swift
//  onMyTssTests
//
//  Created by Codex.
//

import XCTest
import SwiftData
import HealthKit
@testable import onMyTss

@MainActor
final class WorkoutAggregatorTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeAggregator() throws -> WorkoutAggregator {
        let container = try ModelContainer(for: Schema(AppSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return WorkoutAggregator(healthKitManager: MockHealthKitManager(), stravaAuthManager: MockStravaAuthManager(),
                                 dataStore: DataStore(modelContainer: container))
    }

    private func workout(_ id: String, source: WorkoutSource, type: String = "Run", duration: Double = 600,
                         end: Double? = nil) -> Workout {
        let value = Workout(id: id, date: start.startOfDay, startTime: start, duration: duration,
                            workoutType: type, tss: 10, calculationMethod: "duration", source: source)
        if let end { var features = WorkoutFeatures(); features.end = start.addingTimeInterval(end); value.features = features }
        return value
    }

    func testGarminDetectionUsesTrustedSourceMetadata() {
        let hk = workout("hk", source: .healthKit)
        let strava = workout("strava", source: .strava)
        XCTAssertFalse(WorkoutAggregator.isGarminSource(hk))
        hk.sourceBundleIdentifier = "com.garmin.connect.mobile"
        XCTAssertTrue(WorkoutAggregator.isGarminSource(hk))
        hk.sourceBundleIdentifier = "com.example.garmin.connect"
        XCTAssertFalse(WorkoutAggregator.isGarminSource(hk))
        hk.deviceManufacturer = " GARMIN "
        XCTAssertTrue(WorkoutAggregator.isGarminSource(hk))
        hk.deviceManufacturer = "not Garmin"
        hk.deviceName = "Garmin Edge"
        XCTAssertFalse(WorkoutAggregator.isGarminSource(hk))
        strava.deviceName = "Garmin Edge 540"
        XCTAssertTrue(WorkoutAggregator.isGarminSource(strava))
        strava.deviceName = "Not Garmin Edge"
        XCTAssertFalse(WorkoutAggregator.isGarminSource(strava))
        XCTAssertGreaterThan(WorkoutAggregator.sourcePriority(hk), -1)
        XCTAssertGreaterThan(WorkoutAggregator.sourcePriority(strava), WorkoutAggregator.sourcePriority(hk))
        hk.deviceManufacturer = "Garmin"
        XCTAssertGreaterThan(WorkoutAggregator.sourcePriority(hk), WorkoutAggregator.sourcePriority(strava))
    }

    func testHealthKitSourceIdentitySurvivesSensorReadFailure() async throws {
        let schema = Schema(AppSchema.models)
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let source = MockHealthKitManager()
        source.failSensors = true
        let aggregator = WorkoutAggregator(healthKitManager: source, stravaAuthManager: MockStravaAuthManager(),
                                           dataStore: DataStore(modelContainer: container))
        let device = HKDevice(name: "Forerunner", manufacturer: "Garmin", model: nil, hardwareVersion: nil,
                              firmwareVersion: nil, softwareVersion: nil, localIdentifier: nil, udiDeviceIdentifier: nil)
        let input = HKWorkout(activityType: .running, start: start, end: start.addingTimeInterval(600), duration: 600,
                              totalEnergyBurned: nil, totalDistance: nil, device: device, metadata: nil)
        let importedRows = try await aggregator.convertHealthKitWorkouts([input])
        let imported = try XCTUnwrap(importedRows.first)
        XCTAssertEqual(imported.sourceBundleIdentifier, input.sourceRevision.source.bundleIdentifier)
        XCTAssertEqual(imported.deviceManufacturer, "Garmin")
        XCTAssertTrue(WorkoutAggregator.isGarminSource(imported))
        XCTAssertTrue(imported.features.failedChannels.contains("heartRate"))
    }

    func testGarminHealthKitWinsOverOtherImportsAndGarminStrava() throws {
        let aggregator = try makeAggregator()
        let garmin = workout("garmin-hk", source: .healthKit)
        garmin.sourceBundleIdentifier = "com.garmin.connect.mobile"
        let apple = workout("apple-hk", source: .healthKit)
        apple.sourceBundleIdentifier = "com.apple.Health"
        let strava = workout("strava", source: .strava)
        strava.deviceName = "Garmin Edge 540"
        XCTAssertEqual(aggregator.deduplicateWorkouts(healthKit: [apple, garmin], strava: [strava]).map(\.id), [garmin.id])
        XCTAssertTrue(apple.isSuppressed)
        XCTAssertTrue(strava.isSuppressed)
        XCTAssertFalse(garmin.isSuppressed)
        XCTAssertGreaterThan(WorkoutAggregator.sourcePriority(garmin), WorkoutAggregator.sourcePriority(strava))
    }

    func testMatchesElapsedTimeButRejectsContradictoryEnds() throws {
        let aggregator = try makeAggregator()
        let health = workout("hk", source: .healthKit, duration: 600, end: 600)
        let strava = workout("strava", source: .strava, duration: 540, end: 600)
        XCTAssertEqual(aggregator.deduplicateWorkouts(healthKit: [health], strava: [strava]).map(\.id), ["strava"])
        var features = strava.features
        features.end = start.addingTimeInterval(720)
        strava.features = features
        strava.duration = 600
        XCTAssertEqual(aggregator.deduplicateWorkouts(healthKit: [health], strava: [strava]).count, 2)
        features.end = nil
        strava.features = features
        strava.duration = 540
        XCTAssertEqual(aggregator.deduplicateWorkouts(healthKit: [health], strava: [strava]).count, 2)
    }

    func testMatchingActualEndsWithDifferentStartsKeepsGarminSource() throws {
        let aggregator = try makeAggregator()
        let garmin = workout("garmin-hk", source: .healthKit, duration: 600, end: 600)
        garmin.sourceBundleIdentifier = "com.garmin.connect.mobile"
        let strava = workout("strava", source: .strava, duration: 570, end: 600)
        strava.startTime = start.addingTimeInterval(30)

        XCTAssertEqual(aggregator.deduplicateWorkouts(healthKit: [garmin], strava: [strava]).map(\.id), [garmin.id])
        XCTAssertTrue(strava.isSuppressed)
        XCTAssertFalse(garmin.isSuppressed)
    }

    func testEqualDurationsWithShiftedEndsRemainSeparate() throws {
        let aggregator = try makeAggregator()
        let health = workout("health", source: .healthKit, duration: 600, end: 600)
        let strava = workout("strava", source: .strava, duration: 600, end: 650)
        strava.startTime = start.addingTimeInterval(50)

        XCTAssertEqual(Set(aggregator.deduplicateWorkouts(healthKit: [health], strava: [strava]).map(\.id)),
                       Set([health.id, strava.id]))
        XCTAssertFalse(health.isSuppressed)
        XCTAssertFalse(strava.isSuppressed)
    }

    func testAmbiguousAndSameSourceCandidatesRemainVisible() throws {
        let aggregator = try makeAggregator()
        let first = workout("hk1", source: .healthKit)
        let second = workout("hk2", source: .healthKit)
        let strava = workout("strava", source: .strava)
        XCTAssertEqual(aggregator.deduplicateWorkouts(healthKit: [first, second], strava: []).count, 2)
        XCTAssertEqual(aggregator.deduplicateWorkouts(healthKit: [first, second], strava: [strava]).count, 3)
        XCTAssertFalse(first.isSuppressed)
        XCTAssertFalse(second.isSuppressed)
        let unknown = workout("hk-other", source: .healthKit, type: "Other")
        let unknownStrava = workout("strava-other", source: .strava, type: "Other")
        XCTAssertEqual(aggregator.deduplicateWorkouts(healthKit: [unknown], strava: [unknownStrava]).count, 2)
        // An unidentified HealthKit activity can be the matching Strava run;
        // do not hide the known run until that ambiguity is resolved.
        XCTAssertEqual(aggregator.deduplicateWorkouts(healthKit: [first, unknown], strava: [strava]).count, 3)
    }

    func testHealthKitActivityTypesMatchStravaAliases() async throws {
        let aggregator = try makeAggregator()
        let health = try await aggregator.convertHealthKitWorkouts([HKWorkoutActivityType.hiking, .yoga].map {
            HKWorkout(activityType: $0, start: start, end: start.addingTimeInterval(600))
        })
        XCTAssertEqual(health.map(\.workoutType), ["Hiking", "Yoga"])
        let hike = workout("hike", source: .strava, type: "Hike", end: 600)
        let yoga = workout("yoga", source: .strava, type: "Yoga", end: 600)
        XCTAssertEqual(Set(aggregator.deduplicateWorkouts(healthKit: health, strava: [hike, yoga]).map(\.id)), Set(["hike", "yoga"]))
    }

    func testDeduplicationPrefersStravaPowerOverHealthKitDuplicate() throws {
        let schema = Schema([DayAggregate.self, UserThresholds.self, AppState.self, Workout.self, StravaAuth.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = DataStore(modelContainer: container)

        let aggregator = WorkoutAggregator(
            healthKitManager: MockHealthKitManager(),
            stravaAuthManager: MockStravaAuthManager(),
            dataStore: store
        )

        let hkWorkout = Workout(
            id: "hk1",
            date: Date().startOfDay,
            startTime: Date(),
            duration: 3600,
            workoutType: "Ride",
            tss: 50,
            calculationMethod: "power",
            source: .healthKit,
            averagePower: 200,
            normalizedPower: 210
        )

        // Duplicate Strava workout with power; should replace HK
        let stravaWorkout = Workout(
            id: "123",
            date: hkWorkout.date,
            startTime: hkWorkout.startTime,
            duration: 3600,
            workoutType: "Ride",
            tss: 60,
            calculationMethod: "power",
            source: .strava,
            averagePower: 220,
            normalizedPower: 230
        )

        let combined = aggregator.deduplicateWorkouts(healthKit: [hkWorkout], strava: [stravaWorkout])
        XCTAssertEqual(combined.count, 1)
        XCTAssertEqual(combined.first?.source, WorkoutSource.strava.rawValue)
        XCTAssertEqual(combined.first?.tss, 60)
    }
}

// MARK: - Test doubles

@MainActor
private final class MockHealthKitManager: HealthKitManaging {
    var failSensors = false
    func fetchWorkouts(ids: [String]) async throws -> [HKWorkout] { [] }
    func fetchWorkoutChanges(anchor: HKQueryAnchor?) async throws -> (workouts: [HKWorkout], deletedIDs: [String], newAnchor: HKQueryAnchor) {
        ([], [], HKQueryAnchor(fromValue: 0))
    }
    func fetchWorkouts(from startDate: Date, to endDate: Date) async throws -> [HKWorkout] { [] }
    func fetchPowerSamples(for workout: HKWorkout) async throws -> [HKQuantitySample] {
        if failSensors { throw HealthKitError.noData }
        return []
    }
    func fetchHeartRateSamples(for workout: HKWorkout) async throws -> [HKQuantitySample] { [] }
}

@MainActor
private final class MockStravaAuthManager: StravaAuthManaging {
    func getValidAccessToken() async throws -> String { "token" }
}
