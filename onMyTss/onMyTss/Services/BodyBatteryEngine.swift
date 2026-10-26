//
//  BodyBatteryEngine.swift
//  onMyTss
//
//  Created by Claude Code
//

import Foundation
import HealthKit
import SwiftData

/// Main orchestration engine for Body Battery calculations
/// Coordinates HealthKit data fetching, TSS calculation, load metric computation, and persistence
@MainActor
@Observable
class BodyBatteryEngine {
    private let healthKitManager: HealthKitManager
    private let dataStore: DataStore
    private let workoutAggregator: WorkoutAggregator
    private let clock: () -> Date

    // Observable state
    var isProcessing: Bool = false
    var lastError: Error?
    var lastSyncDate: Date?

    init(healthKitManager: HealthKitManager, dataStore: DataStore, stravaAuthManager: any StravaAuthManaging,
         stravaClient: (any StravaActivityFetching)? = nil, clock: @escaping () -> Date = Date.init) {
        self.healthKitManager = healthKitManager
        self.dataStore = dataStore
        self.clock = clock
        self.workoutAggregator = WorkoutAggregator(
            healthKitManager: healthKitManager,
            stravaAuthManager: stravaAuthManager,
            dataStore: dataStore, stravaClient: stravaClient
        )
    }

    // Convenience init for backward compatibility (no Strava)
    convenience init(healthKitManager: HealthKitManager, dataStore: DataStore) {
        let stravaAuthManager = StravaAuthManager(dataStore: dataStore)
        self.init(healthKitManager: healthKitManager, dataStore: dataStore, stravaAuthManager: stravaAuthManager)
    }

    // MARK: - Main Computation

    /// Recompute all Body Battery metrics from historical HealthKit data
    /// This is the main function called when:
    /// - User completes onboarding
    /// - User requests a manual refresh
    /// - App launches after being inactive
    func recomputeAll() async throws {
        try await synchronize()
    }

    /// Source cursors and bounded correction windows keep ordinary sync incremental.
    func incrementalUpdate() async throws {
        try await synchronize()
    }

    private func synchronize() async throws {
        guard !isProcessing else { throw EngineError.alreadyProcessing }
        isProcessing = true
        defer { isProcessing = false }
        do {
            let thresholds = try dataStore.fetchUserThresholds()
            guard thresholds.hasCompletedOnboarding else { throw EngineError.onboardingIncomplete }
            let now = clock()
            let state = try dataStore.fetchAppState()
            let auth = try dataStore.fetchStravaAuth()
            let plan = ActivitySyncPlan(now: now, state: state, strava: auth)
            let interrupted = state.isComputationInProgress
            let thresholdsChanged = state.lastComputationDate.map { $0 < thresholds.lastModified } ?? true
            let initialThresholdRevision = thresholds.lastModified
            let anchor = state.healthKitAnchor.flatMap { healthKitManager.decodeAnchor(from: $0) }
            try await workoutAggregator.fetchChanges(plan: plan, anchor: anchor, now: now)
            try Task.checkCancellation()
            state.isComputationInProgress = true
            try dataStore.saveAppState(state)
            var changes = try await dataStore.applyImportedWorkouts(
                workoutAggregator.latestImportedWorkouts,
                deletedIDs: workoutAggregator.latestDeletedHealthKitIDs + workoutAggregator.latestDeletedStravaIDs
            )
            var appliedThresholdRevision: Date? = thresholdsChanged || interrupted ? nil : initialThresholdRevision
            var recoveryWarnings: [String] = []
            repeat {
                if appliedThresholdRevision != thresholds.lastModified {
                    changes.formUnion(try await dataStore.refreshLegacyWorkoutTSS())
                    appliedThresholdRevision = thresholds.lastModified
                }
                // A cancelled prior write may already have changed persisted rows.
                // Rebuild fully once on recovery before advancing either cursor.
                let start = interrupted ? nil : changes.dates.min() ?? plan.recoveryStart
                try await dataStore.refreshLegacyLoadHistory(from: start, now: now)
                recoveryWarnings = try await updateRecoveryMetrics(from: plan.recoveryStart, to: now)
                if !changes.isEmpty || interrupted { try await dataStore.refreshV2Estimates() }
                else { try await dataStore.backfillV2Estimates() }
                // Settings may change while queries or calculations are suspended.
            } while appliedThresholdRevision != thresholds.lastModified
            let warnings = workoutAggregator.warnings + recoveryWarnings
            try Task.checkCancellation()
            if let newAnchor = workoutAggregator.latestHealthKitAnchor {
                guard let encoded = healthKitManager.encodeAnchor(newAnchor) else { throw HealthKitError.noData }
                state.healthKitAnchor = encoded
                let pending = workoutAggregator.latestHealthKitRetryIDs
                // Rotate attempted IDs so one persistently failing batch cannot
                // prevent later saved activities from retrying their sensors.
                let prior = plan.healthKitRetryIDs
                let rotated = Array(prior.dropFirst(20)) + Array(prior.prefix(20))
                state.pendingHealthKitWorkoutIDs = rotated.filter { pending.contains($0) }
                    + pending.subtracting(prior).sorted()
                state.lastHealthKitSyncDate = now
                if workoutAggregator.refreshedHealthKitSamples { state.lastHealthKitSampleRefreshDate = now }
            }
            if workoutAggregator.successfulSources.contains(WorkoutSource.strava.rawValue),
               let current = try dataStore.fetchStravaAuth(), current === auth, current.isConnected {
                current.lastSyncDate = now
                if plan.reconcileStrava { current.lastReconciliationDate = now }
                try dataStore.updateStravaAuth(current)
            }
            state.lastSyncMessage = warnings.isEmpty
                ? "Sync complete. Saved history remains available offline."
                : warnings.joined(separator: "\n")
            state.lastComputationDate = now
            if recoveryWarnings.isEmpty { state.lastRecoverySyncDate = now }
            state.isComputationInProgress = false
            try dataStore.saveAppState(state)
            lastSyncDate = now
            lastError = nil
        } catch {
            lastError = error
            if let state = try? dataStore.fetchAppState() {
                state.lastSyncMessage = "Sync unavailable. Saved data and manual recording remain available. Retry when connected."
                try? dataStore.saveAppState(state)
            }
            throw error
        }
    }

    // MARK: - Private Helper Methods

    /// Fetch and process HRV/RHR data for a date range
    private func processPhysiologyData(from startDate: Date, to endDate: Date) async throws -> [Date: (hrv: Double?, rhr: Double?, hrvMod: Double?, rhrMod: Double?)] {
        var physiologyMap: [Date: (hrv: Double?, rhr: Double?, hrvMod: Double?, rhrMod: Double?)] = [:]

        // Fetch all HRV and RHR samples in parallel
        async let hrvSamples = healthKitManager.fetchHRVSamples(from: startDate.addingDays(-14), to: endDate)
        async let rhrSamples = healthKitManager.fetchRestingHeartRateSamples(from: startDate.addingDays(-14), to: endDate)

        let (hrv, rhr) = try await (hrvSamples, rhrSamples)

        // Group samples by day
        var dailyHRVSamples: [Date: [HKQuantitySample]] = [:]
        var dailyRHRSamples: [Date: [HKQuantitySample]] = [:]

        for sample in hrv {
            let day = sample.startDate.startOfDay
            dailyHRVSamples[day, default: []].append(sample)
        }

        for sample in rhr {
            let day = sample.startDate.startOfDay
            dailyRHRSamples[day, default: []].append(sample)
        }

        // Calculate baseline from last 14 days of data (median of available values)
        let baselineHRV = PhysiologyModifier.calculateBaselineHRV(from: hrv)
        let baselineRHR = PhysiologyModifier.calculateBaselineRHR(from: rhr)

        // Process each day
        var currentDate = startDate.startOfDay

        while currentDate <= endDate.startOfDay {
            // Calculate daily averages
            let dailyHRV = dailyHRVSamples[currentDate].flatMap {
                PhysiologyModifier.calculateDailyAverageHRV(from: $0)
            }
            let dailyRHR = dailyRHRSamples[currentDate].flatMap {
                PhysiologyModifier.calculateDailyAverageRHR(from: $0)
            }

            // Calculate modifiers if we have baselines
            var hrvModifier: Double?
            var rhrModifier: Double?

            if let hrv = dailyHRV, let baseline = baselineHRV {
                hrvModifier = PhysiologyModifier.calculateHRVModifier(currentHRV: hrv, baselineHRV: baseline)
            }

            if let rhr = dailyRHR, let baseline = baselineRHR {
                rhrModifier = PhysiologyModifier.calculateRHRModifier(currentRHR: rhr, baselineRHR: baseline)
            }

            physiologyMap[currentDate] = (dailyHRV, dailyRHR, hrvModifier, rhrModifier)
            currentDate = currentDate.addingDays(1)
        }

        return physiologyMap
    }

    /// Fetch and process sleep data for a date range
    private func processSleepData(from startDate: Date, to endDate: Date) async throws -> [Date: SleepQuality] {
        var sleepMap: [Date: SleepQuality] = [:]

        // Fetch all sleep samples for the range
        let sleepSamples = try await healthKitManager.fetchSleepSamples(from: startDate, to: endDate)

        // Group samples by day (sleep belongs to the day it ends, not starts)
        var dailySleepSamples: [Date: [HKCategorySample]] = [:]

        for sample in sleepSamples {
            // Assign sleep to the day it ends (morning day)
            let day = sample.endDate.startOfDay
            dailySleepSamples[day, default: []].append(sample)
        }

        // Process each day
        for (date, samples) in dailySleepSamples {
            if let quality = SleepAnalyzer.calculateSleepQuality(from: samples) {
                sleepMap[date] = quality
            }
        }

        return sleepMap
    }

    private func updateRecoveryMetrics(from start: Date, to end: Date) async throws -> [String] {
        async let physiologyMap = try? processPhysiologyData(from: start, to: end)
        async let sleepMap = try? processSleepData(from: start, to: end)
        let (physiology, sleep) = await (physiologyMap, sleepMap)
        try Task.checkCancellation()
        var warnings: [String] = []
        if physiology == nil { warnings.append("HealthKit physiology unavailable. Saved HRV and resting heart rate retained; retry Sync.") }
        if sleep == nil { warnings.append("HealthKit sleep unavailable. Saved sleep measurements retained; retry Sync.") }
        var day = start.startOfDay
        var count = 0
        while day <= end.startOfDay {
            if let row = try dataStore.fetchDayAggregate(for: day) {
                if let physiology {
                    let value = physiology[day]
                    row.avgHRV = value?.hrv
                    row.avgRHR = value?.rhr
                    row.hrvModifier = value?.hrvMod
                    row.rhrModifier = value?.rhrMod
                    row.illnessLikelihood = PhysiologyModifier.detectIllness(hrvModifier: value?.hrvMod, rhrModifier: value?.rhrMod)
                }
                if let sleep {
                    row.sleepDuration = sleep[day]?.durationHours
                    row.sleepQualityScore = sleep[day]?.qualityScore
                    row.deepSleepDuration = sleep[day]?.deepSleepHours
                }
                row.bodyBatteryScore = BodyBatteryCalculator.calculateScoreWithModifiers(
                    tsb: row.tsb, hrvModifier: row.hrvModifier, rhrModifier: row.rhrModifier
                )
            }
            count += 1
            if count % 14 == 0 {
                try dataStore.saveAppState(dataStore.fetchAppState())
                try await Task.sleep(for: .milliseconds(1))
            }
            day = day.addingDays(1)
        }
        try dataStore.saveAppState(dataStore.fetchAppState())
        return warnings
    }

}

// MARK: - Engine Errors

enum EngineError: LocalizedError {
    case alreadyProcessing
    case onboardingIncomplete
    case noData

    var errorDescription: String? {
        switch self {
        case .alreadyProcessing:
            return "A computation is already in progress."
        case .onboardingIncomplete:
            return "Please complete onboarding before using Body Battery."
        case .noData:
            return "No workout data available. Start tracking workouts in the Health app."
        }
    }
}
