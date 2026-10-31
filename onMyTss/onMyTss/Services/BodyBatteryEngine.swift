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
            let stravaRequired = auth?.isConnected == true
            let stravaConnectedAt = auth?.connectedAt
            let stravaAthleteID = auth?.athleteId
            func sameStravaConnection() throws -> Bool {
                let current = try dataStore.fetchStravaAuth()
                guard (current?.isConnected == true) == stravaRequired else { return false }
                guard stravaRequired else { return true }
                return current === auth && current?.connectedAt == stravaConnectedAt
                    && current?.athleteId == stravaAthleteID
            }
            let plan = ActivitySyncPlan(now: now, state: state, strava: auth)
            let interrupted = state.isComputationInProgress
            let thresholdsChanged = state.lastComputationDate.map { $0 < thresholds.lastModified } ?? true
            let initialThresholdRevision = thresholds.lastModified
            let anchor = state.healthKitAnchor.flatMap { healthKitManager.decodeAnchor(from: $0) }
            try await workoutAggregator.fetchChanges(plan: plan, anchor: anchor, now: now)
            try Task.checkCancellation()
            let sources = workoutAggregator.successfulSources
            var connectionStable = try sameStravaConnection()
            // A connection created and removed during the HealthKit query can
            // leave a Strava result even though both snapshots are disconnected.
            if !stravaRequired && sources.contains(WorkoutSource.strava.rawValue) { connectionStable = false }
            var completeSources = connectionStable && sources.contains(WorkoutSource.healthKit.rawValue)
                && (!stravaRequired || sources.contains(WorkoutSource.strava.rawValue))
                && workoutAggregator.incompleteWorkoutSources.isEmpty
            let pendingFinalization = state.pendingWorkoutSourceFinalization
            // An interrupted import may have saved only a prefix of a source.
            // Do not finalize that prefix until every connected source can be
            // replayed from its unchanged cursor.
            if interrupted {
                guard completeSources else {
                    throw EngineError.interruptedRecoveryUnavailable
                }
            }
            state.isComputationInProgress = true
            if !completeSources { state.pendingWorkoutSourceFinalization = true }
            try dataStore.saveAppState(state)
            let imported = connectionStable ? workoutAggregator.latestImportedWorkouts :
                workoutAggregator.latestImportedWorkouts.filter { $0.source != WorkoutSource.strava.rawValue }
            let deleted = workoutAggregator.latestDeletedHealthKitIDs +
                (connectionStable ? workoutAggregator.latestDeletedStravaIDs : [])
            var changes = try await dataStore.applyImportedWorkouts(
                imported, deletedIDs: deleted, finalize: false,
                validateSources: connectionStable ? {
                    guard try sameStravaConnection() else { throw EngineError.stravaConnectionChanged }
                } : nil
            )
            let typeBackfill = try await backfillHealthKitTypes(state: state, sourceAvailable: workoutAggregator.latestHealthKitAnchor != nil)
            changes.formUnion(typeBackfill.changes)
            let sourceBackfill = try await backfillHealthKitSources(state: state, sourceAvailable: workoutAggregator.latestHealthKitAnchor != nil)
            changes.formUnion(sourceBackfill.changes)
            try Task.checkCancellation()
            if connectionStable { connectionStable = try sameStravaConnection() }
            completeSources = completeSources && connectionStable
            if completeSources { changes.formUnion(try dataStore.finalizeWorkoutSources()) }
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
                if connectionStable { connectionStable = try sameStravaConnection() }
                completeSources = completeSources && connectionStable
                if !changes.isEmpty || interrupted || (pendingFinalization && completeSources) {
                    try await dataStore.refreshV2Estimates(finalizeAliases: completeSources,
                                                           validateFinalization: sameStravaConnection)
                }
                else { try await dataStore.backfillV2Estimates() }
                // Settings may change while queries or calculations are suspended.
            } while appliedThresholdRevision != thresholds.lastModified
            try Task.checkCancellation()
            if connectionStable { connectionStable = try sameStravaConnection() }
            completeSources = completeSources && connectionStable
            let connectionWarnings = connectionStable ? [] : ["Strava connection changed during sync. Saved data is retained; retry sync."]
            let warnings = workoutAggregator.warnings + typeBackfill.warnings + sourceBackfill.warnings + recoveryWarnings + connectionWarnings
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
                if !workoutAggregator.incompleteWorkoutSources.contains(WorkoutSource.healthKit.rawValue) {
                    state.lastHealthKitSyncDate = now
                }
                if workoutAggregator.refreshedHealthKitSamples { state.lastHealthKitSampleRefreshDate = now }
            }
            if workoutAggregator.successfulSources.contains(WorkoutSource.strava.rawValue),
               connectionStable,
               !workoutAggregator.incompleteWorkoutSources.contains(WorkoutSource.strava.rawValue),
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
            state.healthKitTypeBackfillVersion = 1
            state.pendingHealthKitTypeBackfillIDs = typeBackfill.pending
            state.pendingWorkoutSourceFinalization = !completeSources
            state.isComputationInProgress = false
            try dataStore.saveAppState(state)
            lastSyncDate = now
            lastSyncHadWarnings = !warnings.isEmpty
            // Historical metadata retries continue on subsequent syncs, but do
            // not invalidate this week's widget when they cannot affect it.
            let pendingMetadata = Set(typeBackfill.pending + state.pendingHealthKitSourceBackfillIDs)
            let currentWeek = Calendar.current.dateInterval(of: .weekOfYear, for: now)
            let pendingAffectsWeek: Bool
            if pendingMetadata.isEmpty { pendingAffectsWeek = false }
            else if let currentWeek {
                pendingAffectsWeek = try dataStore.allWorkouts().contains {
                    pendingMetadata.contains($0.id) && $0.startTime >= currentWeek.start && $0.startTime < currentWeek.end
                }
            } else { pendingAffectsWeek = true }
            lastSyncRequiresRetry = workoutAggregator.hasRetryableFailures || recoveryNeedsRetry
                || !completeSources || pendingAffectsWeek
            lastError = nil
        } catch {
            lastError = error
            if let state = try? dataStore.fetchAppState() {
                state.lastSyncMessage = (error as? EngineError) == .interruptedRecoveryUnavailable
                    ? EngineError.interruptedRecoveryUnavailable.localizedDescription
                    : "Sync unavailable. Saved data and manual recording remain available. Retry when connected."
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

    /// Import source metadata for old HealthKit rows in bounded, resumable batches.
    /// The persisted computation marker forces a full rebuild if work is interrupted
    /// after saving metadata but before the derived history is rebuilt.
    private func backfillHealthKitSources(state: AppState, sourceAvailable: Bool) async throws
        -> (changes: WorkoutChanges, warnings: [String]) {
        var changes = WorkoutChanges()
        if state.healthKitSourceBackfillVersion < 1 {
            state.pendingHealthKitSourceBackfillIDs = try dataStore.allWorkouts().filter {
                $0.source == WorkoutSource.healthKit.rawValue && $0.deletionOrigin != "source"
                    && $0.sourceBundleIdentifier == nil
            }.map(\.id).sorted()
            state.healthKitSourceBackfillVersion = 1
            try dataStore.saveAppState(state)
        }
        guard !state.pendingHealthKitSourceBackfillIDs.isEmpty else { return (WorkoutChanges(), []) }

        // Each pending ID is attempted at most once per sync. Unreadable entries
        // rotate behind remaining work and stay pending for a later sync.
        var leftToAttempt = state.pendingHealthKitSourceBackfillIDs.count
        var canQuery = sourceAvailable
        while leftToAttempt > 0 {
            try Task.checkCancellation()
            let batch = Array(state.pendingHealthKitSourceBackfillIDs.prefix(min(20, leftToAttempt)))
            guard !batch.isEmpty else { break }
            leftToAttempt -= batch.count
            var resolved: Set<String> = []
            var requested: [String: String] = [:]
            var provenanceInputs: [HealthKitSourceProvenanceInput] = []
            for id in batch {
                guard let row = try dataStore.fetchWorkout(byId: id), row.source == WorkoutSource.healthKit.rawValue,
                      row.deletionOrigin != "source" else {
                    resolved.insert(id)
                    continue
                }
                // HealthKitManager already persisted this exact source/UUID in
                // feature provenance on older imports. It can be recovered even
                // while HealthKit is unreadable, but does not establish a device.
                if let uuid = UUID(uuidString: row.healthKitUUID ?? row.id) {
                    requested[id] = uuid.uuidString
                    if row.sourceBundleIdentifier == nil, let data = row.featuresData {
                        provenanceInputs.append(HealthKitSourceProvenanceInput(id: id, uuid: uuid, data: data))
                    }
                }
            }
            // Decode only provenance, away from the main actor. Old sensor
            // histories may contain thousands of samples per workout.
            if !provenanceInputs.isEmpty {
                let inputs = provenanceInputs
                let worker = Task.detached(priority: .utility) { () throws -> [String: String] in
                    var bundles: [String: String] = [:]
                    for input in inputs {
                        try Task.checkCancellation()
                        if let bundle = Self.savedHealthKitSourceBundle(data: input.data, uuid: input.uuid) {
                            bundles[input.id] = bundle
                        }
                    }
                    return bundles
                }
                let bundles = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                for (id, bundle) in bundles {
                    guard let row = try dataStore.fetchWorkout(byId: id), row.source == WorkoutSource.healthKit.rawValue,
                          row.deletionOrigin != "source", row.sourceBundleIdentifier == nil else { continue }
                    row.sourceBundleIdentifier = bundle
                    changes.include(row)
                }
            }
            var results: [String: HKWorkout] = [:]
            if canQuery && !requested.isEmpty {
                do {
                    for workout in try await healthKitManager.fetchWorkouts(ids: Array(Set(requested.values)).sorted()) {
                        results[workout.uuid.uuidString] = workout
                    }
                } catch {
                    if error is CancellationError { throw error }
                    try Task.checkCancellation()
                    // Keep scanning saved provenance even after the read fails;
                    // retain all unverified IDs for a later sync.
                    canQuery = false
                }
            }
            try Task.checkCancellation()
            for (id, uuid) in requested {
                guard let workout = results[uuid] else { continue }
                resolved.insert(id)
                // A source deletion while suspended must never be restored.
                guard let row = try dataStore.fetchWorkout(byId: id), row.source == WorkoutSource.healthKit.rawValue,
                      row.deletionOrigin != "source" else { continue }
                // Completing the lookup releases any deferred group operations,
                // even if a previous attempt already saved the same metadata.
                changes.include(row)
                let bundle = workout.sourceRevision.source.bundleIdentifier
                let manufacturer = workout.device?.manufacturer ?? row.deviceManufacturer
                if row.sourceBundleIdentifier != bundle || row.deviceManufacturer != manufacturer {
                    row.sourceBundleIdentifier = bundle
                    row.deviceManufacturer = manufacturer
                    changes.include(row)
                }
            }
            state.pendingHealthKitSourceBackfillIDs = Array(state.pendingHealthKitSourceBackfillIDs.dropFirst(batch.count))
                + batch.filter { !resolved.contains($0) }
            try dataStore.saveAppState(state)
            try await Task.sleep(for: .milliseconds(1))
        }
        if !changes.isEmpty {
            changes.formUnion(try dataStore.reconcileWorkoutSources(applySideEffects: false))
            try dataStore.saveAppState(state)
        }
        let warnings = state.pendingHealthKitSourceBackfillIDs.isEmpty ? []
            : ["Some older HealthKit workout sources are unreadable. Saved history is retained; retry sync."]
        return (changes, warnings)
    }

    nonisolated private static func savedHealthKitSourceBundle(data: Data, uuid: UUID) -> String? {
        guard let saved = try? JSONDecoder().decode(HealthKitSourceProvenance.self, from: data) else { return nil }
        let prefix = "HealthKit source: "
        let separator = "; workout: "
        let invalid = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-").inverted
        var matches: Set<String> = []
        for item in saved.provenance ?? [] where item.hasPrefix(prefix) {
            let parts = String(item.dropFirst(prefix.count)).components(separatedBy: separator)
            guard parts.count == 2, !parts[0].isEmpty, parts[0].rangeOfCharacter(from: invalid) == nil,
                  UUID(uuidString: parts[1]) == uuid else { continue }
            matches.insert(parts[0])
        }
        return matches.count == 1 ? matches.first : nil
    }

    /// Revisit older HealthKit rows imported before these activity types were mapped.
    /// The checkpoint is committed only after derived history has been rebuilt.
    private func backfillHealthKitTypes(state: AppState, sourceAvailable: Bool) async throws
        -> (pending: [String], changes: WorkoutChanges, warnings: [String]) {
        let pending: [String]
        if state.healthKitTypeBackfillVersion < 1 {
            pending = try dataStore.allWorkouts().filter {
                $0.source == WorkoutSource.healthKit.rawValue && !$0.isTombstoned && $0.workoutType == "Other"
            }.map(\.id).sorted()
        } else {
            pending = state.pendingHealthKitTypeBackfillIDs
        }
        guard sourceAvailable, !pending.isEmpty else { return (pending, WorkoutChanges(), []) }
        let batch = Array(pending.prefix(20))
        var resolved: Set<String> = []
        var requested: [String: String] = [:]
        for id in batch {
            guard let row = try dataStore.fetchWorkout(byId: id), !row.isTombstoned,
                  row.source == WorkoutSource.healthKit.rawValue, row.workoutType == "Other" else {
                resolved.insert(id)
                continue
            }
            if let uuid = UUID(uuidString: row.healthKitUUID ?? row.id) { requested[id] = uuid.uuidString }
        }
        var types: [String: String] = [:]
        if !requested.isEmpty {
            do {
                let rows = try await healthKitManager.fetchWorkouts(ids: Array(Set(requested.values)).sorted())
                for row in rows { types[row.uuid.uuidString] = WorkoutAggregator.workoutTypeName(for: row.workoutActivityType) }
            } catch {
                if error is CancellationError { throw error }
                try Task.checkCancellation()
                return (Array(pending.dropFirst(batch.count)) + batch.filter { !resolved.contains($0) }, WorkoutChanges(),
                        ["Some older HealthKit workout types could not refresh. Saved history is retained; retry sync."])
            }
        }
        try Task.checkCancellation()
        var changes = WorkoutChanges()
        for (id, uuid) in requested {
            guard let type = types[uuid] else { continue }
            resolved.insert(id) // A genuine Other was successfully checked too.
            // Recheck after the query: a user or source may have deleted this row.
            guard let row = try dataStore.fetchWorkout(byId: id), !row.isTombstoned,
                  row.source == WorkoutSource.healthKit.rawValue, row.workoutType == "Other", type != "Other" else { continue }
            row.workoutType = type
            changes.include(row)
        }
        if !changes.isEmpty { changes.formUnion(try dataStore.reconcileWorkoutSources()) }
        let remainder = Array(pending.dropFirst(batch.count)) + batch.filter { !resolved.contains($0) }
        let warnings = batch.contains { !resolved.contains($0) }
            ? ["Some older HealthKit workout types are unreadable. Saved history is retained; retry sync."] : []
        return (remainder, changes, warnings)
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

nonisolated private struct HealthKitSourceProvenanceInput: Sendable {
    let id: String
    let uuid: UUID
    let data: Data
}

nonisolated private struct HealthKitSourceProvenance: Decodable {
    let provenance: [String]?
}

// MARK: - Engine Errors

enum EngineError: LocalizedError {
    case interruptedRecoveryUnavailable
    case stravaConnectionChanged
    case alreadyProcessing
    case onboardingIncomplete
    case noData

    var errorDescription: String? {
        switch self {
        case .interruptedRecoveryUnavailable:
            return "Interrupted sync could not resume because a connected activity source is unavailable. Saved data is retained; retry when connected."
        case .stravaConnectionChanged:
            return "Strava connection changed during sync. Saved data is retained; retry sync."
        case .alreadyProcessing:
            return "A computation is already in progress."
        case .onboardingIncomplete:
            return "Please complete onboarding before using Body Battery."
        case .noData:
            return "No workout data available. Start tracking workouts in the Health app."
        }
    }
}
