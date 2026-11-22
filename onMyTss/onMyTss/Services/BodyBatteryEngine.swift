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
    private(set) var isProcessing: Bool = false
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

    /// A HealthKit launch may never create the view that normally starts local repair.
    func syncForPublication() async throws {
        try await incrementalUpdate()
        let state = try dataStore.fetchAppState()
        if !state.pendingWorkoutSourceFinalization && LocalWorkoutHistoryRepair.isRequired(state) {
            try await repairLocalWorkoutHistoryIfNeeded()
        }
    }

    /// Offline history repair shares the same gate as every source sync.
    /// No HealthKit or network access is needed for a completed local store.
    func repairLocalWorkoutHistoryIfNeeded(reconcile: (@MainActor () async throws -> Void)? = nil) async throws {
        try await beginExclusiveOperation()
        defer { isProcessing = false }
        let key = dataStore.workoutMaintenanceKey
        try await WorkoutMaintenanceGate.acquire(key, kind: .localRepair)
        defer { WorkoutMaintenanceGate.release(key) }
        let operation = reconcile ?? {
            _ = try await self.dataStore.repairWorkoutSourcesLocally()
        }
        let repair = LocalWorkoutHistoryRepair(store: dataStore, reconcile: operation, clock: clock)
        try await repair.run()
    }

    func resetActivitySync() async throws {
        try await beginExclusiveOperation()
        defer { isProcessing = false }
        let key = dataStore.workoutMaintenanceKey
        try await WorkoutMaintenanceGate.acquire(key, kind: .sourceSync)
        defer { WorkoutMaintenanceGate.release(key) }
        try dataStore.resetSyncCheckpoints()
        lastSyncDate = nil
    }

    private func beginExclusiveOperation() async throws {
        while isProcessing {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(200))
        }
        try Task.checkCancellation()
        isProcessing = true
    }

    private func synchronize() async throws {
        try await beginExclusiveOperation()
        defer { isProcessing = false }
        let key = dataStore.workoutMaintenanceKey
        try await WorkoutMaintenanceGate.acquire(key, kind: .sourceSync)
        defer { WorkoutMaintenanceGate.release(key) }
        lastSyncHadWarnings = true
        lastSyncRequiresRetry = true
        do {
            let thresholds = try dataStore.fetchUserThresholds()
            guard thresholds.hasCompletedOnboarding else { throw EngineError.onboardingIncomplete }
            let now = clock()
            let calendar = Calendar.current
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
            let plan = ActivitySyncPlan(now: now, state: state, strava: auth, calendar: calendar)
            let interrupted = state.isComputationInProgress
            let timeZoneChanged = state.lastComputedTimeZone != calendar.timeZone.identifier
            let initialFTP = thresholds.effectiveCyclingFTP(strava: auth).watts
            let thresholdsChanged = state.lastComputedCyclingFTP != initialFTP
                || (state.lastComputationDate.map { $0 < thresholds.lastModified } ?? true)
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
            let validateSources: (() throws -> Void)? = connectionStable ? {
                guard try sameStravaConnection() else { throw EngineError.stravaConnectionChanged }
            } : nil
            let endpoints = try await dataStore.prepareWorkoutEndpoints(incoming: imported, validateSources: validateSources)
            var changes = try await dataStore.applyImportedWorkouts(
                imported, deletedIDs: deleted, finalize: false,
                validateSources: validateSources, prewarmed: endpoints
            )
            let typeBackfill = try await backfillHealthKitTypes(state: state, sourceAvailable: workoutAggregator.latestHealthKitAnchor != nil, prewarmed: endpoints)
            changes.formUnion(typeBackfill.changes)
            let sourceBackfill = try await backfillHealthKitSources(state: state, sourceAvailable: workoutAggregator.latestHealthKitAnchor != nil, prewarmed: endpoints)
            changes.formUnion(sourceBackfill.changes)
            try Task.checkCancellation()
            if connectionStable { connectionStable = try sameStravaConnection() }
            completeSources = completeSources && connectionStable
            if completeSources { changes.formUnion(try dataStore.finalizeWorkoutSources(prewarmed: endpoints)) }
            var appliedThresholdRevision: Date? = thresholdsChanged || interrupted ? nil : initialThresholdRevision
            var appliedFTP = initialFTP
            var recoveryWarnings: [String] = []
            var recoveryNeedsRetry = false
            var thresholdsChangedDuringSync: Bool
            repeat {
                let ftp = try dataStore.effectiveCyclingFTP(for: thresholds)
                if appliedThresholdRevision != thresholds.lastModified || appliedFTP != ftp {
                    let refresh = try await dataStore.refreshLegacyWorkoutTSS()
                    changes.formUnion(refresh.changes)
                    appliedThresholdRevision = refresh.thresholdRevision
                    appliedFTP = refresh.ftp
                }
                // A cancelled prior write may already have changed persisted rows.
                // Rebuild fully once on recovery before advancing either cursor.
                let start = interrupted || timeZoneChanged ? nil : min(changes.dates.min() ?? plan.loadHistoryStart, plan.loadHistoryStart)
                try await dataStore.refreshLegacyLoadHistory(from: start, now: now, calendar: calendar)
                let recovery = try await updateRecoveryMetrics(from: plan.recoveryStart, to: now, calendar: calendar)
                recoveryWarnings = recovery.warnings
                recoveryNeedsRetry = recovery.needsRetry
                if connectionStable { connectionStable = try sameStravaConnection() }
                completeSources = completeSources && connectionStable
                if !changes.isEmpty || interrupted || (pendingFinalization && completeSources) {
                    try await dataStore.refreshV2Estimates()
                }
                else { try await dataStore.backfillV2Estimates() }
                // Settings may change while queries or calculations are suspended.
                let currentFTP = try dataStore.effectiveCyclingFTP(for: thresholds)
                thresholdsChangedDuringSync = appliedThresholdRevision != thresholds.lastModified || appliedFTP != currentFTP
            } while thresholdsChangedDuringSync
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
            state.lastComputedCyclingFTP = appliedFTP
            state.lastComputedTimeZone = calendar.timeZone.identifier
            if !recoveryNeedsRetry {
                state.lastRecoverySyncDate = now
                state.recoveryInputVersion = ActivitySyncPlan.recoveryInputVersion
            }
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
            let currentWeek = calendar.dateInterval(of: .weekOfYear, for: now)
            let pendingAffectsWeek: Bool
            if pendingMetadata.isEmpty { pendingAffectsWeek = false }
            else if let currentWeek {
                let start = currentWeek.start, end = currentWeek.end
                pendingAffectsWeek = try !pendingMetadata.isDisjoint(with: dataStore.workoutIDs(
                    matching: #Predicate { $0.startTime >= start && $0.startTime < end }
                ))
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
    private func backfillHealthKitSources(state: AppState, sourceAvailable: Bool, prewarmed: WorkoutPrewarmedEndpoints) async throws
        -> (changes: WorkoutChanges, warnings: [String]) {
        var changes = WorkoutChanges()
        if state.healthKitSourceBackfillVersion < 1 {
            let healthKit = WorkoutSource.healthKit.rawValue
            state.pendingHealthKitSourceBackfillIDs = try dataStore.workoutIDs(matching: #Predicate {
                $0.source == healthKit && ($0.deletionOrigin == nil || $0.deletionOrigin != "source")
                    && $0.sourceBundleIdentifier == nil
            }).sorted()
            state.healthKitSourceBackfillVersion = 1
            try dataStore.saveAppState(state)
        }
        guard !state.pendingHealthKitSourceBackfillIDs.isEmpty else { return (WorkoutChanges(), []) }

        // Each pending ID is attempted at most once per sync. Unreadable entries
        // rotate behind remaining work and stay pending for a later sync.
        // Leave time in a background refresh for current activities and recovery data.
        // The saved queue rotates unreadable IDs behind unattempted ones.
        var leftToAttempt = min(40, state.pendingHealthKitSourceBackfillIDs.count)
        var canQuery = sourceAvailable
        while leftToAttempt > 0 {
            try Task.checkCancellation()
            let batch = Array(state.pendingHealthKitSourceBackfillIDs.prefix(min(20, leftToAttempt)))
            guard !batch.isEmpty else { break }
            leftToAttempt -= batch.count
            var resolved: Set<String> = []
            var requested: [String: String] = [:]
            var provenanceInputs: [HealthKitSourceProvenanceInput] = []
            let rows = try dataStore.workoutsByID(batch)
            for id in batch {
                guard let row = rows[id], row.source == WorkoutSource.healthKit.rawValue,
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
            changes.formUnion(try dataStore.reconcileWorkoutSources(applySideEffects: false, prewarmed: prewarmed))
            try dataStore.saveAppState(state)
        }
        let warnings = state.pendingHealthKitSourceBackfillIDs.isEmpty ? []
            : ["Some older HealthKit workout sources still need verification. Sync will continue from the saved queue."]
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
    private func backfillHealthKitTypes(state: AppState, sourceAvailable: Bool, prewarmed: WorkoutPrewarmedEndpoints) async throws
        -> (pending: [String], changes: WorkoutChanges, warnings: [String]) {
        let pending: [String]
        if state.healthKitTypeBackfillVersion < 1 {
            let healthKit = WorkoutSource.healthKit.rawValue
            pending = try dataStore.workoutIDs(matching: #Predicate {
                $0.source == healthKit && !$0.isTombstoned && $0.workoutType == "Other"
            }).sorted()
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
        if !changes.isEmpty { changes.formUnion(try dataStore.reconcileWorkoutSources(prewarmed: prewarmed)) }
        let remainder = Array(pending.dropFirst(batch.count)) + batch.filter { !resolved.contains($0) }
        let warnings = batch.contains { !resolved.contains($0) }
            ? ["Some older HealthKit workout types are unreadable. Saved history is retained; retry sync."] : []
        return (remainder, changes, warnings)
    }

    private func updateRecoveryMetrics(from start: Date, to end: Date, calendar: Calendar) async throws -> (warnings: [String], needsRetry: Bool) {
        // Include the evening before the first wake date, even with strict-start HealthKit predicates.
        let evening = calendar.date(byAdding: .day, value: -1, to: start)!
        async let hrvQuery = captureHealthRead { try await self.healthKitManager.fetchHRVSamples(from: evening, to: end) }
        async let rhrQuery = captureHealthRead { try await self.healthKitManager.fetchRestingHeartRateSamples(from: start, to: end) }
        async let sleepQuery = captureHealthRead { try await self.healthKitManager.fetchSleepSamples(from: evening, to: end) }
        let results = await (hrvQuery, rhrQuery, sleepQuery)
        try Task.checkCancellation()
        let hrv = try healthValue(results.0), rhr = try healthValue(results.1), sleep = try healthValue(results.2)
        let measurements = try await RecoveryMeasurements.collect(hrv: hrv ?? [], rhr: rhr ?? [], sleep: sleep ?? [],
                                                                  through: end, calendar: calendar)
        var warnings: [String] = []
        if hrv == nil { warnings.append("HealthKit HRV unavailable. Saved HRV retained; retry Sync.") }
        if rhr == nil { warnings.append("HealthKit resting heart rate unavailable. Saved resting heart rate retained; retry Sync.") }
        if sleep == nil { warnings.append("HealthKit sleep unavailable. Saved sleep measurements retained; retry Sync.") }

        let historyStart = TrainingReadiness.historyStart(for: start, calendar: calendar)
        let rows = try dataStore.fetchDayAggregates(from: historyStart, to: end, calendar: calendar)
        var history = DayAggregate.byLocalDay(rows, calendar: calendar)
        var retainedHRV = false, retainedRHR = false, retainedSleep = false
        var day = calendar.startOfDay(for: start)
        let last = calendar.startOfDay(for: end)
        var processed = 0
        while day <= last {
            try Task.checkCancellation()
            let dailyHRV = measurements.hrv[day], dailyRHR = measurements.rhr[day]
            let overnight = measurements.overnightHRV[day], night = measurements.sleep[day]
            if history[day] == nil, dailyHRV != nil || dailyRHR != nil || night != nil || overnight != nil {
                history[day] = dataStore.insertRecoveryDay(on: day)
            }
            if let row = history[day] {
                if let value = dailyHRV {
                    if row.avgHRV != value { row.avgHRV = value }
                } else if hrv != nil, row.avgHRV != nil { retainedHRV = true }
                if let value = dailyRHR {
                    if row.avgRHR != value { row.avgRHR = value }
                } else if rhr != nil, row.avgRHR != nil { retainedRHR = true }
                if let overnight {
                    if row.overnightHRV != overnight { row.overnightHRV = overnight }
                } else if night != nil, dailyHRV != nil, row.overnightHRV != nil {
                    // Fresh HRV and sleep were both read, but the samples fall outside this sleep.
                    row.overnightHRV = nil
                }
                if let night {
                    if row.recordedAwakeMinutes != night.awakeMinutes { row.recordedAwakeMinutes = night.awakeMinutes }
                    if row.sleepDuration != night.durationHours { row.sleepDuration = night.durationHours }
                    if row.sleepQualityScore != night.qualityScore { row.sleepQualityScore = night.qualityScore }
                    if row.deepSleepDuration != night.deepSleepHours { row.deepSleepDuration = night.deepSleepHours }
                } else if sleep != nil, row.sleepDuration != nil { retainedSleep = true }
                let result = TrainingReadiness.assess(row, history: history, asOf: end, calendar: calendar)
                if dailyHRV != nil || overnight != nil, row.hrvModifier != result.hrvModifier { row.hrvModifier = result.hrvModifier }
                if dailyRHR != nil, row.rhrModifier != result.rhrModifier { row.rhrModifier = result.rhrModifier }
                if dailyHRV != nil || dailyRHR != nil || overnight != nil {
                    let likelihood = PhysiologyModifier.detectIllness(hrvModifier: result.hrvModifier, rhrModifier: result.rhrModifier)
                    if row.illnessLikelihood != likelihood { row.illnessLikelihood = likelihood }
                }
                let score = result.score ?? -1
                if row.bodyBatteryScore != score { row.bodyBatteryScore = score }
            }
            processed += 1
            if processed.isMultiple(of: 14) {
                try dataStore.saveChangesIfNeeded()
                try await Task.sleep(for: .milliseconds(1))
            }
            day = calendar.dateInterval(of: .day, for: day)!.end
        }
        try dataStore.saveChangesIfNeeded()
        if retainedHRV { warnings.append("Some days had no new HealthKit HRV samples. Saved HRV retained.") }
        if retainedRHR { warnings.append("Some days had no new HealthKit resting heart rate samples. Saved resting heart rate retained.") }
        if retainedSleep { warnings.append("Some days had no new HealthKit sleep samples. Saved sleep retained.") }
        return (warnings, hrv == nil || rhr == nil || sleep == nil)
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
