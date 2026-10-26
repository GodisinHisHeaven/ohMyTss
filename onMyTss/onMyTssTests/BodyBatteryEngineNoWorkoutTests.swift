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

    func testFailedHealthQueriesRetainOnlyTheAffectedSavedMeasurements() async throws {
        for (failPhysiology, failSleep) in [(true, true), (true, false), (false, true), (false, false)] {
            let schema = Schema(AppSchema.models)
            let container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            let store = DataStore(modelContainer: container)
            let thresholds = try store.fetchUserThresholds()
            thresholds.hasCompletedOnboarding = true
            try store.saveUserThresholds(thresholds)
            let day = Date().startOfDay.addingDays(-2)
            try store.saveDayAggregate(DayAggregate(
                date: day, totalTSS: 100, avgHRV: 45, avgRHR: 55,
                hrvModifier: -8, rhrModifier: 2, illnessLikelihood: 0.25,
                sleepDuration: 7.5, sleepQualityScore: 80, deepSleepDuration: 1.5
            ))
            let health = FailableHealthQueries(failPhysiology: failPhysiology, failSleep: failSleep)
            let engine = BodyBatteryEngine(healthKitManager: health, dataStore: store)

            try await engine.recomputeAll()

            let saved = try XCTUnwrap(store.fetchDayAggregate(for: day))
            XCTAssertEqual(saved.totalTSS, 100)
            XCTAssertEqual(saved.avgHRV, failPhysiology ? 45 : nil)
            XCTAssertEqual(saved.avgRHR, failPhysiology ? 55 : nil)
            XCTAssertEqual(saved.hrvModifier, failPhysiology ? -8 : nil)
            XCTAssertEqual(saved.rhrModifier, failPhysiology ? 2 : nil)
            if failPhysiology { XCTAssertEqual(saved.illnessLikelihood, 0.25) }
            XCTAssertEqual(saved.bodyBatteryScore, BodyBatteryCalculator.calculateScoreWithModifiers(
                tsb: saved.tsb, hrvModifier: failPhysiology ? -8 : nil, rhrModifier: failPhysiology ? 2 : nil
            ))
            XCTAssertEqual(saved.sleepDuration, failSleep ? 7.5 : nil)
            XCTAssertEqual(saved.sleepQualityScore, failSleep ? 80 : nil)
            XCTAssertEqual(saved.deepSleepDuration, failSleep ? 1.5 : nil)
            let state = try store.fetchAppState()
            XCTAssertNotNil(state.lastHealthKitSyncDate)
            XCTAssertEqual(state.lastSyncMessage?.contains("physiology unavailable"), failPhysiology)
            XCTAssertEqual(state.lastSyncMessage?.contains("sleep unavailable"), failSleep)
        }
    }

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

@MainActor
private final class FailableHealthQueries: HealthKitManager {
    let failPhysiology: Bool
    let failSleep: Bool

    init(failPhysiology: Bool, failSleep: Bool) {
        self.failPhysiology = failPhysiology
        self.failSleep = failSleep
        super.init()
    }

    override func fetchWorkouts(from startDate: Date, to endDate: Date) async throws -> [HKWorkout] { [] }

    override func fetchWorkoutChanges(anchor: HKQueryAnchor?) async throws -> (workouts: [HKWorkout], deletedIDs: [String], newAnchor: HKQueryAnchor) {
        ([], [], HKQueryAnchor(fromValue: 0))
    }

    override func fetchHRVSamples(from startDate: Date, to endDate: Date) async throws -> [HKQuantitySample] {
        if failPhysiology { throw URLError(.notConnectedToInternet) }
        return []
    }

    override func fetchRestingHeartRateSamples(from startDate: Date, to endDate: Date) async throws -> [HKQuantitySample] { [] }

    override func fetchSleepSamples(from startDate: Date, to endDate: Date) async throws -> [HKCategorySample] {
        if failSleep { throw URLError(.notConnectedToInternet) }
        return []
    }
}
