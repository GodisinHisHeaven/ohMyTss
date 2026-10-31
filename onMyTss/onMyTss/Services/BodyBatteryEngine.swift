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
    private(set) var lastSyncHadWarnings = true
    private(set) var lastSyncRequiresRetry = true

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

    /// Refresh imported activity and the derived readiness metrics.
    func recomputeAll() async throws {
        try await synchronize()
    }

    /// Source cursors and bounded correction windows keep ordinary sync incremental.
    func incrementalUpdate() async throws {
        try await synchronize()
    }

    private func synchronize() async throws {
        // A manual request can arrive while automatic synchronization is running.
        // Wait for it rather than reporting a false failure or dropping a settings change.
        while isProcessing {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(200))
        }
        isProcessing = true
        defer { isProcessing = false }
        lastSyncHadWarnings = true
        lastSyncRequiresRetry = true
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
            var recoveryNeedsRetry = false
            repeat {
                if appliedThresholdRevision != thresholds.lastModified {
                    changes.formUnion(try await dataStore.refreshLegacyWorkoutTSS())
                    appliedThresholdRevision = thresholds.lastModified
                }
                // A cancelled prior write may already have changed persisted rows.
                // Rebuild fully once on recovery before advancing either cursor.
                let start = interrupted ? nil : changes.dates.min() ?? plan.recoveryStart
                try await dataStore.refreshLegacyLoadHistory(from: start, now: now)
                let recovery = try await updateRecoveryMetrics(from: plan.recoveryStart, to: now)
                recoveryWarnings = recovery.warnings
                recoveryNeedsRetry = recovery.needsRetry
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
            if !recoveryNeedsRetry { state.lastRecoverySyncDate = now }
            state.isComputationInProgress = false
            try dataStore.saveAppState(state)
            lastSyncDate = now
            lastSyncHadWarnings = !warnings.isEmpty
            lastSyncRequiresRetry = workoutAggregator.hasRetryableFailures || recoveryNeedsRetry
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

    /// Keep independent channel failures while never converting cancellation to no data.
    private func captureHealthRead<Value>(_ operation: () async throws -> Value) async -> Result<Value, Error> {
        do { return .success(try await operation()) }
        catch { return .failure(error) }
    }

    private func healthValue<Value>(_ result: Result<Value, Error>) throws -> Value? {
        switch result {
        case .success(let value): return value
        case .failure(let error):
            if error is CancellationError { throw error }
            return nil
        }
    }

    /// Fetch and process HRV/RHR data for a date range
    private func processPhysiologyData(from startDate: Date, to endDate: Date) async throws -> (days: [Date: (hrv: Double?, rhr: Double?, hrvMod: Double?, rhrMod: Double?)], hrvAvailable: Bool, rhrAvailable: Bool) {
        var physiologyMap: [Date: (hrv: Double?, rhr: Double?, hrvMod: Double?, rhrMod: Double?)] = [:]

        // Fetch all HRV and RHR samples in parallel
        async let hrvSamples = captureHealthRead { try await self.healthKitManager.fetchHRVSamples(from: startDate.addingDays(-14), to: endDate) }
        async let rhrSamples = captureHealthRead { try await self.healthKitManager.fetchRestingHeartRateSamples(from: startDate.addingDays(-14), to: endDate) }

        let (hrvResult, rhrResult) = await (hrvSamples, rhrSamples)
        try Task.checkCancellation()
        let hrvValue = try healthValue(hrvResult)
        let rhrValue = try healthValue(rhrResult)
        let hrv = hrvValue ?? []
        let rhr = rhrValue ?? []

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

        return (physiologyMap, hrvValue != nil, rhrValue != nil)
    }

    /// Fetch and process sleep data for a date range
    private func processSleepData(from startDate: Date, to endDate: Date) async throws -> [Date: SleepQuality] {
        var sleepMap: [Date: SleepQuality] = [:]

        // Fetch all sleep samples for the range
        let sleepSamples = try await healthKitManager.fetchSleepSamples(from: startDate, to: endDate)
        try Task.checkCancellation()

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

    private func updateRecoveryMetrics(from start: Date, to end: Date) async throws -> (warnings: [String], needsRetry: Bool) {
        async let physiologyMap = captureHealthRead { try await self.processPhysiologyData(from: start, to: end) }
        async let sleepMap = captureHealthRead { try await self.processSleepData(from: start, to: end) }
        let (physiologyResult, sleepResult) = await (physiologyMap, sleepMap)
        try Task.checkCancellation()
        let physiology = try healthValue(physiologyResult)
        let sleep = try healthValue(sleepResult)
        var warnings: [String] = []
        if physiology == nil || physiology?.hrvAvailable == false {
            warnings.append("HealthKit HRV unavailable. Saved HRV retained; retry Sync.")
        }
        if physiology == nil || physiology?.rhrAvailable == false {
            warnings.append("HealthKit resting heart rate unavailable. Saved resting heart rate retained; retry Sync.")
        }
        if sleep == nil { warnings.append("HealthKit sleep unavailable. Saved sleep measurements retained; retry Sync.") }
        var retainedHRV = false
        var retainedRHR = false
        var retainedSleep = false
        var day = start.startOfDay
        var count = 0
        while day <= end.startOfDay {
            if let row = try dataStore.fetchDayAggregate(for: day) {
                if let physiology {
                    let value = physiology.days[day]
                    // Absence on one day is not evidence that saved data was deleted.
                    let hasValidHRV = (value?.hrv).map { $0.isFinite && $0 > 0 } ?? false
                    let hasValidRHR = (value?.rhr).map { $0.isFinite && $0 > 0 } ?? false
                    if let hrv = value?.hrv, hasValidHRV {
                        row.avgHRV = hrv
                        if let modifier = value?.hrvMod, modifier.isFinite { row.hrvModifier = modifier }
                    } else if physiology.hrvAvailable && (row.avgHRV != nil || row.hrvModifier != nil) {
                        retainedHRV = true
                    }
                    if let rhr = value?.rhr, hasValidRHR {
                        row.avgRHR = rhr
                        if let modifier = value?.rhrMod, modifier.isFinite { row.rhrModifier = modifier }
                    } else if physiology.rhrAvailable && (row.avgRHR != nil || row.rhrModifier != nil) {
                        retainedRHR = true
                    }
                    if hasValidHRV || hasValidRHR {
                        row.illnessLikelihood = PhysiologyModifier.detectIllness(hrvModifier: row.hrvModifier, rhrModifier: row.rhrModifier)
                    }
                }
                if let sleep {
                    if let quality = sleep[day], quality.durationHours.isFinite, quality.durationHours > 0 {
                        row.sleepDuration = quality.durationHours
                        row.sleepQualityScore = quality.qualityScore
                        row.deepSleepDuration = quality.deepSleepHours
                    } else if row.sleepDuration != nil || row.sleepQualityScore != nil || row.deepSleepDuration != nil {
                        retainedSleep = true
                    }
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
        if retainedHRV { warnings.append("Some days had no new HealthKit HRV samples. Saved HRV retained.") }
        if retainedRHR { warnings.append("Some days had no new HealthKit resting heart rate samples. Saved resting heart rate retained.") }
        if retainedSleep { warnings.append("Some days had no new HealthKit sleep samples. Saved sleep retained.") }
        try dataStore.saveAppState(dataStore.fetchAppState())
        let needsRetry = physiology == nil || physiology?.hrvAvailable == false
            || physiology?.rhrAvailable == false || sleep == nil
        return (warnings, needsRetry)
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
