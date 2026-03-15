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
    func fetchWorkouts(from startDate: Date, to endDate: Date) async throws -> [HKWorkout] { [] }
    func fetchPowerSamples(for workout: HKWorkout) async throws -> [HKQuantitySample] { [] }
    func fetchHeartRateSamples(for workout: HKWorkout) async throws -> [HKQuantitySample] { [] }
}

@MainActor
private final class MockStravaAuthManager: StravaAuthManaging {
    func getValidAccessToken() async throws -> String { "token" }
}
