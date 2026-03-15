//
//  BodyBatteryEngineNoWorkoutTests.swift
//  onMyTssTests
//
//  Created by Codex.
//

import XCTest
import SwiftData
import HealthKit
@testable import onMyTss

@MainActor
final class BodyBatteryEngineNoWorkoutTests: XCTestCase {

    func testBodyBatteryCalculatesWithoutTodayWorkoutsWhenPhysiologyExists() async throws {
        // In-memory store
        let schema = Schema([DayAggregate.self, UserThresholds.self, AppState.self, Workout.self, StravaAuth.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let dataStore = DataStore(modelContainer: container)

        // Seed thresholds with onboarding completed
        let thresholds = try dataStore.fetchUserThresholds()
        thresholds.hasCompletedOnboarding = true
        thresholds.cyclingFTP = 250
        try dataStore.saveUserThresholds(thresholds)

        // Fake HealthKit manager that returns physiology but no workouts
        let fakeHK = FakeHealthKitManager()
        let engine = BodyBatteryEngine(healthKitManager: fakeHK, dataStore: dataStore)

        // Run recompute; no workouts today, but HRV/RHR present
        try await engine.recomputeAll()

        let today = Date().startOfDay
        let aggregate = try XCTUnwrap(dataStore.fetchDayAggregate(for: today))

        // Body Battery should be set (not nil) even with zero TSS today
        XCTAssertGreaterThanOrEqual(aggregate.bodyBatteryScore, 0)
        XCTAssertLessThanOrEqual(aggregate.bodyBatteryScore, 100)
    }
}

// MARK: - Fakes

@MainActor
private final class FakeHealthKitManager: HealthKitManager {
    override func fetchWorkouts(from startDate: Date, to endDate: Date) async throws -> [HKWorkout] {
        [] // No workouts
    }

    override func fetchSleepSamples(from startDate: Date, to endDate: Date) async throws -> [HKCategorySample] {
        [] // no sleep used here
    }

    override func fetchHRVSamples(from startDate: Date, to endDate: Date) async throws -> [HKQuantitySample] {
        let now = Date()
        let sample = HKQuantitySample(
            type: HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN)!,
            quantity: HKQuantity(unit: HKUnit.secondUnit(with: .milli), doubleValue: 50),
            start: now,
            end: now
        )
        return [sample]
    }

    override func fetchRestingHeartRateSamples(from startDate: Date, to endDate: Date) async throws -> [HKQuantitySample] {
        let now = Date()
        let sample = HKQuantitySample(
            type: HKObjectType.quantityType(forIdentifier: .restingHeartRate)!,
            quantity: HKQuantity(unit: HKUnit.count().unitDivided(by: .minute()), doubleValue: 52),
            start: now,
            end: now
        )
        return [sample]
    }
}
