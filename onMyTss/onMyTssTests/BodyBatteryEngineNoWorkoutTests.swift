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
            XCTAssertEqual(saved.avgHRV, 45)
            XCTAssertEqual(saved.avgRHR, 55)
            XCTAssertEqual(saved.hrvModifier, -8)
            XCTAssertEqual(saved.rhrModifier, 2)
            XCTAssertEqual(saved.illnessLikelihood, 0.25)
            XCTAssertEqual(saved.bodyBatteryScore, BodyBatteryCalculator.calculateScoreWithModifiers(
                tsb: saved.tsb, hrvModifier: -8, rhrModifier: 2
            ))
            XCTAssertEqual(saved.sleepDuration, 7.5)
            XCTAssertEqual(saved.sleepQualityScore, 80)
            XCTAssertEqual(saved.deepSleepDuration, 1.5)
            let state = try store.fetchAppState()
            XCTAssertNotNil(state.lastHealthKitSyncDate)
            XCTAssertEqual(state.lastSyncMessage?.contains("HRV unavailable"), failPhysiology)
            XCTAssertEqual(state.lastSyncMessage?.contains("sleep unavailable"), failSleep)
            XCTAssertEqual(state.lastSyncMessage?.contains("HealthKit HRV samples"), !failPhysiology)
            XCTAssertEqual(state.lastSyncMessage?.contains("HealthKit resting heart rate samples"), true)
            XCTAssertEqual(state.lastSyncMessage?.contains("HealthKit sleep samples"), !failSleep)
            XCTAssertEqual(engine.lastSyncRequiresRetry, failPhysiology || failSleep)
        }
    }

    func testEmptyRecoveryTypesRetainOnlyTheirSavedFields() async throws {
        let now = Date().startOfDay.addingTimeInterval(12 * 3600)
        let oldDay = now.startOfDay.addingDays(-2)
        for hasHRV in [false, true] {
            for hasRHR in [false, true] {
                for hasSleep in [false, true] {
                    let schema = Schema(AppSchema.models)
                    let container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
                    let store = DataStore(modelContainer: container)
                    let thresholds = try store.fetchUserThresholds()
                    thresholds.hasCompletedOnboarding = true
                    try store.saveUserThresholds(thresholds)
                    try store.saveDayAggregate(DayAggregate(
                        date: oldDay, totalTSS: 100, avgHRV: 45, avgRHR: 55,
                        hrvModifier: -8, rhrModifier: 2,
                        sleepDuration: 7.5, sleepQualityScore: 80, deepSleepDuration: 1.5
                    ))
                    let health = RecoverySampleQueries(now: now, hasHRV: hasHRV, hasRHR: hasRHR, hasSleep: hasSleep)
                    let engine = BodyBatteryEngine(healthKitManager: health, dataStore: store,
                                                   stravaAuthManager: StravaAuthManager(dataStore: store), clock: { now })
                    try await engine.recomputeAll()
                    let old = try XCTUnwrap(store.fetchDayAggregate(for: oldDay))
                    XCTAssertEqual(old.avgHRV, 45)
                    XCTAssertEqual(old.hrvModifier, -8)
                    XCTAssertEqual(old.avgRHR, 55)
                    XCTAssertEqual(old.rhrModifier, 2)
                    XCTAssertEqual(old.sleepDuration, 7.5)
                    XCTAssertEqual(old.sleepQualityScore, 80)
                    XCTAssertEqual(old.deepSleepDuration, 1.5)
                    let today = try XCTUnwrap(store.fetchDayAggregate(for: now.startOfDay))
                    XCTAssertEqual(today.avgHRV, hasHRV ? 60 : nil)
                    XCTAssertEqual(today.avgRHR, hasRHR ? 50 : nil)
                    XCTAssertEqual(today.sleepDuration, hasSleep ? 1 : nil)
                    let message = try store.fetchAppState().lastSyncMessage ?? ""
                    XCTAssertTrue(message.contains("HealthKit HRV samples"))
                    XCTAssertTrue(message.contains("HealthKit resting heart rate samples"))
                    XCTAssertTrue(message.contains("HealthKit sleep samples"))
                    XCTAssertFalse(engine.lastSyncRequiresRetry)
                }
            }
        }
    }

    func testFailedHRVQueryStillUpdatesRestingHeartRateAndSleep() async throws {
        let now = Date().startOfDay.addingTimeInterval(12 * 3600)
        let schema = Schema(AppSchema.models)
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = DataStore(modelContainer: container)
        let thresholds = try store.fetchUserThresholds()
        thresholds.hasCompletedOnboarding = true
        try store.saveUserThresholds(thresholds)
        try store.saveDayAggregate(DayAggregate(date: now.startOfDay, totalTSS: 0, avgHRV: 45,
                                                avgRHR: 55, hrvModifier: -8, rhrModifier: 2,
                                                sleepDuration: 7.5, sleepQualityScore: 80, deepSleepDuration: 1.5))
        let health = RecoverySampleQueries(now: now, hasHRV: false, hasRHR: true, hasSleep: true, failHRV: true)
        let engine = BodyBatteryEngine(healthKitManager: health, dataStore: store,
                                       stravaAuthManager: StravaAuthManager(dataStore: store), clock: { now })
        try await engine.recomputeAll()
        let today = try XCTUnwrap(store.fetchDayAggregate(for: now.startOfDay))
        XCTAssertEqual(today.avgHRV, 45)
        XCTAssertEqual(today.hrvModifier, -8)
        XCTAssertEqual(today.avgRHR, 50)
        XCTAssertEqual(today.sleepDuration, 1)
        let message = try store.fetchAppState().lastSyncMessage ?? ""
        XCTAssertTrue(message.contains("HealthKit HRV unavailable"))
        XCTAssertFalse(message.contains("HealthKit resting heart rate unavailable"))
        XCTAssertTrue(engine.lastSyncRequiresRetry)
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

        XCTAssertEqual(fakeHK.workoutChangeCalls, 1)
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
    private(set) var workoutChangeCalls = 0

    override func fetchWorkouts(from startDate: Date, to endDate: Date) async throws -> [HKWorkout] {
        [] // No workouts
    }

    override func fetchWorkoutChanges(anchor: HKQueryAnchor?) async throws -> (workouts: [HKWorkout], deletedIDs: [String], newAnchor: HKQueryAnchor) {
        workoutChangeCalls += 1
        return ([], [], HKQueryAnchor(fromValue: 0))
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

@MainActor
private final class RecoverySampleQueries: HealthKitManager {
    let now: Date
    let hasHRV: Bool
    let hasRHR: Bool
    let hasSleep: Bool
    let failHRV: Bool

    init(now: Date, hasHRV: Bool, hasRHR: Bool, hasSleep: Bool, failHRV: Bool = false) {
        self.now = now
        self.hasHRV = hasHRV
        self.hasRHR = hasRHR
        self.hasSleep = hasSleep
        self.failHRV = failHRV
        super.init()
    }

    override func fetchWorkoutChanges(anchor: HKQueryAnchor?) async throws -> (workouts: [HKWorkout], deletedIDs: [String], newAnchor: HKQueryAnchor) {
        ([], [], HKQueryAnchor(fromValue: 0))
    }

    override func fetchHRVSamples(from startDate: Date, to endDate: Date) async throws -> [HKQuantitySample] {
        if failHRV { throw URLError(.notConnectedToInternet) }
        guard hasHRV else { return [] }
        return [HKQuantitySample(type: HKQuantityType(.heartRateVariabilitySDNN),
                                 quantity: HKQuantity(unit: .secondUnit(with: .milli), doubleValue: 60),
                                 start: now, end: now)]
    }

    override func fetchRestingHeartRateSamples(from startDate: Date, to endDate: Date) async throws -> [HKQuantitySample] {
        guard hasRHR else { return [] }
        return [HKQuantitySample(type: HKQuantityType(.restingHeartRate),
                                 quantity: HKQuantity(unit: HKUnit.count().unitDivided(by: .minute()), doubleValue: 50),
                                 start: now, end: now)]
    }

    override func fetchSleepSamples(from startDate: Date, to endDate: Date) async throws -> [HKCategorySample] {
        guard hasSleep else { return [] }
        return [HKCategorySample(type: HKCategoryType(.sleepAnalysis), value: HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                                 start: now.addingTimeInterval(-3600), end: now)]
    }
}
