//
//  DataStore.swift
//  onMyTss
//
//  Created by Claude Code
//

import Foundation
import SwiftData

@MainActor
@Observable
class DataStore {
    private var modelContext: ModelContext

    // Avoid the older Swift runtime's isolated-deinit crash (swiftlang/swift#88036).
    nonisolated deinit {}

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    init(modelContainer: ModelContainer) {
        self.modelContext = ModelContext(modelContainer)
    }

    var workoutMaintenanceKey: ObjectIdentifier { ObjectIdentifier(modelContext.container) }

    func ensureLocalRepairAllowsMutation() throws {
        if WorkoutMaintenanceGate.isRepairing(workoutMaintenanceKey) {
            throw WorkoutMutationError.localRepairInProgress
        }
    }

    // MARK: - DayAggregate Operations

    /// Avoid manufacturing an empty historical day for a fresh installation.
    func hasSavedTrainingHistory() throws -> Bool {
        var workout = FetchDescriptor<Workout>()
        workout.fetchLimit = 1
        if !((try modelContext.fetch(workout)).isEmpty) { return true }
        var day = FetchDescriptor<DayAggregate>()
        day.fetchLimit = 1
        return !((try modelContext.fetch(day)).isEmpty)
    }

    func saveDayAggregate(_ dayAggregate: DayAggregate) throws {
        try ensureLocalRepairAllowsMutation()
        modelContext.insert(dayAggregate)
        try modelContext.save()
    }

    /// Batch save multiple day aggregates in a single transaction for better performance
    func saveDayAggregatesBatch(_ dayAggregates: [DayAggregate]) throws {
        try ensureLocalRepairAllowsMutation()
        for aggregate in dayAggregates {
            // Avoid duplicating an existing day; if it exists, the fetched instance is already tracked
            if try fetchDayAggregate(for: aggregate.date) == nil {
                modelContext.insert(aggregate)
            }
        }
        try modelContext.save()
    }

    func fetchDayAggregate(for date: Date) throws -> DayAggregate? {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)

        let descriptor = FetchDescriptor<DayAggregate>(
            predicate: #Predicate { $0.date == startOfDay }
        )

        let results = try modelContext.fetch(descriptor)
        return results.first
    }

    func fetchDayAggregates(from startDate: Date, to endDate: Date) throws -> [DayAggregate] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: startDate)
        let end = calendar.startOfDay(for: endDate)

        let descriptor = FetchDescriptor<DayAggregate>(
            predicate: #Predicate { aggregate in
                aggregate.date >= start && aggregate.date <= end
            },
            sortBy: [SortDescriptor(\.date, order: .forward)]
        )

        return try modelContext.fetch(descriptor)
    }

    func fetchAllDayAggregates() throws -> [DayAggregate] {
        let descriptor = FetchDescriptor<DayAggregate>(
            sortBy: [SortDescriptor(\.date, order: .forward)]
        )
        return try modelContext.fetch(descriptor)
    }

    func fetchRecentDayAggregates(days: Int) throws -> [DayAggregate] {
        let calendar = Calendar.current
        let endDate = calendar.startOfDay(for: Date())
        guard let startDate = calendar.date(byAdding: .day, value: -days, to: endDate) else {
            return []
        }

        return try fetchDayAggregates(from: startDate, to: endDate)
    }

    func deleteDayAggregate(_ dayAggregate: DayAggregate) throws {
        try ensureLocalRepairAllowsMutation()
        modelContext.delete(dayAggregate)
        try modelContext.save()
    }

    func deleteAllDayAggregates() throws {
        try ensureLocalRepairAllowsMutation()
        let descriptor = FetchDescriptor<DayAggregate>()
        let allAggregates = try modelContext.fetch(descriptor)
        for aggregate in allAggregates {
            modelContext.delete(aggregate)
        }
        try modelContext.save()
    }

    // MARK: - UserThresholds Operations

    func fetchUserThresholds() throws -> UserThresholds {
        let descriptor = FetchDescriptor<UserThresholds>()
        let results = try modelContext.fetch(descriptor)

        if let existing = results.first {
            return existing
        } else {
            // Create default thresholds if none exist
            let newThresholds = UserThresholds()
            modelContext.insert(newThresholds)
            try modelContext.save()
            return newThresholds
        }
    }

    func saveUserThresholds(_ thresholds: UserThresholds) throws {
        thresholds.lastModified = Date()
        try modelContext.save()
    }

    func updateFTP(_ ftp: Int) throws {
        let thresholds = try fetchUserThresholds()
        thresholds.cyclingFTP = ftp
        thresholds.lastModified = Date()
        try modelContext.save()
    }

    func updateUnitSystem(_ unitSystem: UnitSystem) throws {
        let thresholds = try fetchUserThresholds()
        thresholds.preferredUnitSystem = unitSystem
        thresholds.lastModified = Date()
        try modelContext.save()
    }

    func markOnboardingComplete() throws {
        let thresholds = try fetchUserThresholds()
        thresholds.hasCompletedOnboarding = true
        thresholds.lastModified = Date()
        try modelContext.save()
    }

    // MARK: - AppState Operations

    func fetchAppState() throws -> AppState {
        let descriptor = FetchDescriptor<AppState>()
        let results = try modelContext.fetch(descriptor)

        if let existing = results.first {
            return existing
        } else {
            // Create default app state if none exists
            let newState = AppState()
            modelContext.insert(newState)
            try modelContext.save()
            return newState
        }
    }

    func saveAppState(_ appState: AppState) throws {
        try modelContext.save()
    }

    func updateHealthKitSyncDate(_ date: Date, anchor: Data?) throws {
        let appState = try fetchAppState()
        appState.lastHealthKitSyncDate = date
        appState.healthKitAnchor = anchor
        try modelContext.save()
    }

    func updateLastOpenDate() throws {
        let appState = try fetchAppState()
        appState.lastOpenDate = Date()
        try modelContext.save()
    }

    func setComputationInProgress(_ inProgress: Bool) throws {
        let appState = try fetchAppState()
        appState.isComputationInProgress = inProgress
        if !inProgress {
            appState.lastComputationDate = Date()
        }
        try modelContext.save()
    }

    func resetAppState() throws {
        try ensureLocalRepairAllowsMutation()
        let appState = try fetchAppState()
        appState.lastHealthKitSyncDate = nil
        appState.healthKitAnchor = nil
        appState.lastHealthKitSampleRefreshDate = nil
        appState.pendingHealthKitWorkoutIDs = []
        appState.healthKitTypeBackfillVersion = 0
        appState.pendingHealthKitTypeBackfillIDs = []
        appState.healthKitSourceBackfillVersion = 0
        appState.pendingHealthKitSourceBackfillIDs = []
        appState.pendingWorkoutSourceFinalization = false
        appState.localWorkoutRepairVersion = 0
        appState.localWorkoutRepairInProgress = false
        appState.lastRecoverySyncDate = nil
        appState.lastComputationDate = nil
        appState.isComputationInProgress = false
        if let auth = try fetchStravaAuth() {
            auth.lastSyncDate = nil
            auth.lastReconciliationDate = nil
            auth.syncCursor = nil
        }
        try modelContext.save()
    }

    // MARK: - Workout Operations

    func saveWorkout(_ workout: Workout) throws {
        try saveWorkouts([workout])
    }

    /// Identity upserts preserve user data and deletion tombstones. Identical
    /// source responses do not dirty a model or trigger history reconciliation.
    @discardableResult
    func saveWorkouts(_ workouts: [Workout], reconcileSideEffects: Bool? = nil,
                      prewarmed: WorkoutPrewarmedEndpoints? = nil) throws -> WorkoutChanges {
        try ensureLocalRepairAllowsMutation()
        var changes = WorkoutChanges()
        for workout in workouts {
            if let existing = try fetchWorkout(byId: workout.id) {
                let oldDate = existing.date
                guard try merge(workout, into: existing) else { continue }
                changes.include(existing)
                changes.dates.insert(oldDate)
            } else {
                modelContext.insert(workout)
                changes.include(workout)
            }
        }
        if !changes.isEmpty {
            changes.formUnion(try reconcileWorkoutSources(applySideEffects: reconcileSideEffects, prewarmed: prewarmed))
            try modelContext.save()
        }
        return changes
    }

    private func merge(_ incoming: Workout, into existing: Workout) throws -> Bool {
        let sourceBundleIdentifier = incoming.sourceBundleIdentifier ?? existing.sourceBundleIdentifier
        let deviceManufacturer = incoming.deviceManufacturer ?? existing.deviceManufacturer
        let deviceName = incoming.deviceName ?? existing.deviceName
        if incoming.featuresData == existing.featuresData,
           incoming.date == existing.date, incoming.startTime == existing.startTime,
           incoming.duration == existing.duration, incoming.workoutType == existing.workoutType,
           incoming.distance == existing.distance, incoming.tss == existing.tss,
           incoming.calculationMethod == existing.calculationMethod, incoming.source == existing.source,
           incoming.stravaId == existing.stravaId, incoming.healthKitUUID == existing.healthKitUUID,
           incoming.averagePower == existing.averagePower, incoming.normalizedPower == existing.normalizedPower,
           incoming.averageHeartRate == existing.averageHeartRate, incoming.maxHeartRate == existing.maxHeartRate,
           deviceName == existing.deviceName,
           sourceBundleIdentifier == existing.sourceBundleIdentifier,
           deviceManufacturer == existing.deviceManufacturer,
           !(existing.isTombstoned && existing.deletionOrigin == "source") { return false }
        var features = incoming.features
        let unreadable = Set(features.failedChannels + features.unavailableChannels)
        var featuresData = incoming.featuresData ?? existing.featuresData
        if let data = incoming.featuresData, data != existing.featuresData {
            let prior = existing.features
            if incoming.source == WorkoutSource.strava.rawValue && existing.source == WorkoutSource.strava.rawValue
                && unreadable.contains("elapsed") {
                features.end = prior.end
            }
            if unreadable.contains("heartRate") { features.heartRate = prior.heartRate }
            if unreadable.contains("power") { features.power = prior.power }
            if unreadable.contains("cadence") { features.cadence = prior.cadence }
            if unreadable.contains("speed") { features.speed = prior.speed }
            if unreadable.contains("terrain") {
                features.elevation = prior.elevation
                features.grade = prior.grade
                features.ascentMeters = prior.ascentMeters
                features.descentMeters = prior.descentMeters
            }
            if !unreadable.isEmpty && existing.featuresData != nil {
                features.provenance = Array(Set(features.provenance + [
                    "Previously saved samples retained for unreadable channels: " + unreadable.sorted().joined(separator: ", ")
                ])).sorted()
            }
            if features == prior { featuresData = existing.featuresData }
            else {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                featuresData = try encoder.encode(features)
            }
        }
        let preserveTSS = (existing.calculationMethod.hasPrefix("power") && unreadable.contains("power"))
            || (existing.calculationMethod.hasPrefix("hr") && unreadable.contains("heartRate"))
        let tss = preserveTSS ? existing.tss : incoming.tss
        let method = preserveTSS ? existing.calculationMethod : incoming.calculationMethod
        let averagePower = unreadable.contains("power") ? existing.averagePower : incoming.averagePower
        let normalizedPower = unreadable.contains("power") ? existing.normalizedPower : incoming.normalizedPower
        let averageHR = unreadable.contains("heartRate") ? existing.averageHeartRate : incoming.averageHeartRate
        let maxHR = unreadable.contains("heartRate") ? existing.maxHeartRate : incoming.maxHeartRate
        let restoresSource = existing.isTombstoned && existing.deletionOrigin == "source"
        guard restoresSource || existing.date != incoming.date || existing.startTime != incoming.startTime
            || existing.duration != incoming.duration || existing.workoutType != incoming.workoutType
            || existing.distance != incoming.distance || existing.tss != tss || existing.calculationMethod != method
            || existing.source != incoming.source || existing.stravaId != incoming.stravaId
            || existing.healthKitUUID != incoming.healthKitUUID || existing.averagePower != averagePower
            || existing.normalizedPower != normalizedPower || existing.averageHeartRate != averageHR
            || existing.maxHeartRate != maxHR || existing.deviceName != deviceName
            || existing.sourceBundleIdentifier != sourceBundleIdentifier
            || existing.deviceManufacturer != deviceManufacturer
            || existing.featuresData != featuresData else { return false }
        if existing.legacyTSS == nil {
            existing.legacyTSS = existing.tss
            existing.legacyCalculationMethod = existing.calculationMethod
        }
        if existing.date != incoming.date, let oldDay = try fetchDayAggregate(for: existing.date) {
            oldDay.hasWorkoutDetails = true
            oldDay.totalTSS = 0
        }
        if restoresSource { existing.isTombstoned = false; existing.deletionOrigin = nil }
        existing.date = incoming.date
        existing.startTime = incoming.startTime
        existing.duration = incoming.duration
        existing.workoutType = incoming.workoutType
        existing.distance = incoming.distance
        existing.tss = tss
        existing.calculationMethod = method
        existing.source = incoming.source
        existing.stravaId = incoming.stravaId
        existing.healthKitUUID = incoming.healthKitUUID
        existing.averagePower = averagePower
        existing.normalizedPower = normalizedPower
        existing.averageHeartRate = averageHR
        existing.maxHeartRate = maxHR
        existing.deviceName = deviceName
        existing.sourceBundleIdentifier = sourceBundleIdentifier
        existing.deviceManufacturer = deviceManufacturer
        existing.featuresData = featuresData
        return true
    }

    /// Decode endpoints off the main actor before inserting or merging any
    /// source row. Prewarming is a bounded hint: changed, new, or oversized
    /// payloads fall back to the normal synchronous full decoder.
    func prepareWorkoutEndpoints(
        incoming: [Workout], validateSources: (() throws -> Void)? = nil,
        byteLimit: Int = 16 * 1_024 * 1_024,
        candidateIDs: @escaping @Sendable ([WorkoutEndpointCandidate]) async throws -> [String] = WorkoutEndpointPrewarmer.candidateIDs,
        decode: @escaping @Sendable ([WorkoutEndpointPayload]) async throws -> [PrewarmedWorkoutEndpoint] = WorkoutEndpointPrewarmer.decode
    ) async throws -> WorkoutPrewarmedEndpoints {
        try Task.checkCancellation()
        try validateSources?()
        let total = try modelContext.fetchCount(FetchDescriptor<Workout>())
        var candidates: [WorkoutEndpointCandidate] = []
        func candidate(_ row: Workout) -> WorkoutEndpointCandidate {
            WorkoutEndpointCandidate(id: row.id, start: row.startTime, duration: row.duration,
                                     type: row.workoutType, source: row.source)
        }
        // Fetch by page so the main actor yields without retaining a page of
        // managed models across suspension. Concurrent inserts/deletions can
        // only cause a cache miss, never an incorrect match.
        func persistedPage(_ offset: Int) throws -> [WorkoutEndpointCandidate] {
            var descriptor = FetchDescriptor<Workout>(sortBy: [SortDescriptor(\.id)])
            descriptor.fetchOffset = offset
            descriptor.fetchLimit = 50
            return try modelContext.fetch(descriptor).map(candidate)
        }
        for offset in stride(from: 0, to: total, by: 50) {
            candidates.append(contentsOf: try persistedPage(offset))
            try await Task.sleep(for: .milliseconds(1))
            try validateSources?()
        }
        for offset in stride(from: 0, to: incoming.count, by: 50) {
            candidates.append(contentsOf: incoming[offset..<min(offset + 50, incoming.count)].map(candidate))
            try await Task.sleep(for: .milliseconds(1))
            try validateSources?()
        }
        let ids = try await candidateIDs(candidates)
        try Task.checkCancellation()
        try validateSources?()
        var incomingByID: [String: [Workout]] = [:]
        for offset in stride(from: 0, to: incoming.count, by: 50) {
            for row in incoming[offset..<min(offset + 50, incoming.count)] {
                incomingByID[row.id, default: []].append(row)
            }
            try await Task.sleep(for: .milliseconds(1))
            try validateSources?()
        }
        let result = WorkoutPrewarmedEndpoints()
        let limit = max(0, byteLimit)
        var bytes = 0
        var seen: [String: [Data?]] = [:]
        var pending: [WorkoutEndpointPayload] = []
        func enqueue(_ id: String, _ data: Data?) {
            guard !(seen[id] ?? []).contains(where: { $0 == data }) else { return }
            let count = data?.count ?? 0
            guard count <= limit - bytes else { return }
            bytes += count
            seen[id, default: []].append(data)
            pending.append(WorkoutEndpointPayload(id: id, data: data))
        }
        for (offset, id) in ids.enumerated() {
            try Task.checkCancellation()
            if let stored = try fetchWorkout(byId: id) { enqueue(id, stored.featuresData) }
            for row in incomingByID[id] ?? [] { enqueue(id, row.featuresData) }
            if (offset + 1).isMultiple(of: 20) {
                if !pending.isEmpty {
                    let decoded = try await decode(pending)
                    try Task.checkCancellation()
                    try validateSources?()
                    result.append(decoded)
                    pending.removeAll(keepingCapacity: true)
                } else {
                    try await Task.sleep(for: .milliseconds(1))
                    try validateSources?()
                }
            }
        }
        if !pending.isEmpty {
            let decoded = try await decode(pending)
            try Task.checkCancellation()
            try validateSources?()
            result.append(decoded)
        }
        try Task.checkCancellation()
        try validateSources?()
        return result
    }

    /// Bounded imports combine both sources. Reconcile before committing each
    /// batch, so cancellation never leaves duplicate active source rows. Each yield
    /// allows navigation and Settings to run during a large first import.
    func applyImportedWorkouts(_ workouts: [Workout], deletedIDs: [String], finalize: Bool = true,
                               validateSources: (() throws -> Void)? = nil,
                               prewarmed: WorkoutPrewarmedEndpoints? = nil) async throws -> WorkoutChanges {
        let endpoints: WorkoutPrewarmedEndpoints?
        if let prewarmed { endpoints = prewarmed }
        else if !workouts.isEmpty || !deletedIDs.isEmpty || finalize {
            endpoints = try await prepareWorkoutEndpoints(incoming: workouts, validateSources: validateSources)
        } else { endpoints = nil }
        var changes = WorkoutChanges()
        for offset in stride(from: 0, to: workouts.count, by: 20) {
            try Task.checkCancellation()
            try validateSources?()
            changes.formUnion(try saveWorkouts(Array(workouts[offset..<min(offset + 20, workouts.count)]),
                                              reconcileSideEffects: false, prewarmed: endpoints))
            try await Task.sleep(for: .milliseconds(1))
        }
        for offset in stride(from: 0, to: deletedIDs.count, by: 20) {
            try Task.checkCancellation()
            try validateSources?()
            let deleted = try applySourceDeletions(Array(deletedIDs[offset..<min(offset + 20, deletedIDs.count)]), rebuildHistory: false)
            changes.formUnion(deleted)
            if !deleted.isEmpty {
                changes.formUnion(try reconcileWorkoutSources(applySideEffects: false, prewarmed: endpoints))
                try modelContext.save()
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        if finalize { changes.formUnion(try finalizeWorkoutSources(prewarmed: endpoints)) }
        return changes
    }

    /// Reconcile even when no source changed, to repair groups from older versions.
    @discardableResult
    func finalizeWorkoutSources(prewarmed: WorkoutPrewarmedEndpoints? = nil) throws -> WorkoutChanges {
        let changes = try reconcileWorkoutSources(applySideEffects: true, prewarmed: prewarmed)
        if !changes.isEmpty { try modelContext.save() }
        return changes
    }

    /// Group only complete, unambiguous clusters of independently sourced rows.
    /// A chain is not proof: every pair must match and a source may appear once.
    /// Unknown HealthKit apps can still match one Strava row, as before, but
    /// cannot establish that two HealthKit rows came from different apps.
    static func matchingWorkoutGroups(_ workouts: [Workout]) -> [[Workout]] {
        matchingWorkoutGroups(workouts, endpoints: WorkoutEndpointCache())
    }

    private static func matchingWorkoutGroups(_ workouts: [Workout], endpoints: WorkoutEndpointCache) -> [[Workout]] {
        let rows = workouts.sorted {
            if $0.startTime != $1.startTime { return $0.startTime < $1.startTime }
            return $0.id < $1.id
        }
        var neighbors = Array(repeating: [Int](), count: rows.count)
        for index in rows.indices {
            var other = index + 1
            while other < rows.count && rows[other].startTime.timeIntervalSince(rows[index].startTime) < 60 {
                if possibleDuplicate(rows[index], rows[other], endpoints: endpoints) {
                    neighbors[index].append(other)
                    neighbors[other].append(index)
                }
                other += 1
            }
        }
        var visited = Set<Int>()
        var result: [[Workout]] = []
        for index in rows.indices where !visited.contains(index) {
            var pending = [index]
            var component: [Int] = []
            visited.insert(index)
            while let current = pending.popLast() {
                component.append(current)
                for neighbor in neighbors[current] where visited.insert(neighbor).inserted { pending.append(neighbor) }
            }
            let members = component.map { rows[$0] }
            var complete = true
            for left in members.indices {
                for right in members.indices where right > left {
                    if !definiteDuplicate(members[left], members[right], endpoints: endpoints) { complete = false }
                }
            }
            if complete { result.append(members) }
            else { result.append(contentsOf: members.map { [$0] }) }
        }
        return result
    }

    private static func possibleDuplicate(_ first: Workout, _ second: Workout,
                                          endpoints: WorkoutEndpointCache) -> Bool {
        let firstType = WorkoutAggregator.normalizeWorkoutType(first.workoutType)
        let secondType = WorkoutAggregator.normalizeWorkoutType(second.workoutType)
        let compatible: Bool
        if firstType == secondType { compatible = !firstType.isEmpty }
        else {
            compatible = (first.source == WorkoutSource.healthKit.rawValue && firstType == "other") ||
                (second.source == WorkoutSource.healthKit.rawValue && secondType == "other")
        }
        guard compatible else { return false }
        return WorkoutAggregator.hasMatchingTiming(first, second, end: endpoints.end)
    }

    private static func definiteDuplicate(_ first: Workout, _ second: Workout,
                                          endpoints: WorkoutEndpointCache) -> Bool {
        guard possibleDuplicate(first, second, endpoints: endpoints) else { return false }
        let type = WorkoutAggregator.normalizeWorkoutType(first.workoutType)
        guard type != "other", type == WorkoutAggregator.normalizeWorkoutType(second.workoutType) else { return false }
        let healthKit = WorkoutSource.healthKit.rawValue
        let strava = WorkoutSource.strava.rawValue
        if Set([first.source, second.source]) == Set([healthKit, strava]) { return true }
        guard first.source == healthKit, second.source == healthKit,
              let firstBundle = first.sourceBundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              let secondBundle = second.sourceBundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !firstBundle.isEmpty, !secondBundle.isEmpty else { return false }
        return firstBundle != secondBundle
    }

    /// Compare only temporally adjacent sources, instead of searching every
    /// historical row for every activity. Recompute logical groups after corrections.
    @discardableResult
    func reconcileWorkoutSources(applySideEffects: Bool? = nil,
                                 prewarmed: WorkoutPrewarmedEndpoints? = nil) throws -> WorkoutChanges {
        try ensureLocalRepairAllowsMutation()
        // While an import is suspended, other UI actions may reconcile through
        // another DataStore using the same context. They must not finalize an
        // incomplete batch either. The completed import explicitly opts in.
        let state = try modelContext.fetch(FetchDescriptor<AppState>()).first
        let unresolvedSources = Set(state?.pendingHealthKitSourceBackfillIDs ?? [])
        let mayFinalize: Bool
        if let applySideEffects { mayFinalize = applySideEffects }
        else {
            mayFinalize = state?.isComputationInProgress != true && state?.pendingWorkoutSourceFinalization != true
                && state?.localWorkoutRepairInProgress != true
        }
        let all = try allWorkouts()
        let external = all.filter { $0.source != WorkoutSource.manual.rawValue }
        let endpoints = WorkoutEndpointCache(prewarmed: prewarmed)
        // Re-evaluate associations after source corrections without allowing
        // an uncertain candidate or a transitive bridge to swallow a session.
        var groupForID = Dictionary(uniqueKeysWithValues: external.map { ($0.id, $0.id) })
        for members in Self.matchingWorkoutGroups(external.filter { $0.deletionOrigin != "source" }, endpoints: endpoints) {
            guard let group = members.map(\.id).min() else { continue }
            for row in members { groupForID[row.id] = group }
        }
        // Source-deleted aliases cannot claim a live match ahead of a current
        // source. Keep a still-matching old alias attached to its former group,
        // so its manual children remain reachable after the canonical changes.
        let previousGroups = Dictionary(grouping: external.filter { $0.sessionGroupID != nil }) { $0.sessionGroupID! }
        for row in external where row.deletionOrigin == "source" {
            guard let previousGroup = row.sessionGroupID else { continue }
            let survivors = (previousGroups[previousGroup] ?? []).filter {
                $0.id != row.id && $0.deletionOrigin != "source" &&
                $0.sessionGroupID == previousGroup && Self.definiteDuplicate(row, $0, endpoints: endpoints)
            }
            let survivorGroups = Set(survivors.compactMap { groupForID[$0.id] })
            if survivorGroups.count == 1, let group = survivorGroups.first {
                groupForID[row.id] = group
            }
        }
        return applyWorkoutSourceGroups(all, groupForID: groupForID,
                                        mayFinalize: mayFinalize, unresolvedSources: unresolvedSources)
    }

    /// Apply only a complete plan without suspending. No context can observe a
    /// partially applied group through an intervening main-actor operation.
    private func applyWorkoutSourceGroups(_ all: [Workout], groupForID: [String: String],
                                          mayFinalize: Bool, unresolvedSources: Set<String>) -> WorkoutChanges {
        let before = Dictionary(uniqueKeysWithValues: all.map { ($0.id, WorkoutCanonicalState($0)) })
        let external = all.filter { $0.source != WorkoutSource.manual.rawValue }
        for row in external {
            let group = groupForID[row.id] ?? row.id
            if row.sessionGroupID != group { row.sessionGroupID = group }
        }
        let groups = Dictionary(grouping: external) { $0.sessionGroupID ?? $0.id }
        for members in groups.values {
            // Source identity can affect both the matching and the canonical
            // row. Keep irreversible actions local to resolved groups.
            let groupMayFinalize = mayFinalize && (members.count < 2 || members.allSatisfy { !unresolvedSources.contains($0.id) })
            let hasUserDeletion = members.contains { $0.deletionOrigin == "user" }
            if hasUserDeletion && groupMayFinalize {
                for row in members where !row.isTombstoned || row.deletionOrigin != "user" {
                    row.isTombstoned = true; row.deletionOrigin = "user"
                }
            }
            let canonical = (hasUserDeletion && !groupMayFinalize ? [] : members.filter { !$0.isTombstoned }).sorted {
                let leftPriority = WorkoutAggregator.sourcePriority($0)
                let rightPriority = WorkoutAggregator.sourcePriority($1)
                if leftPriority != rightPriority { return leftPriority > rightPriority }
                return $0.id < $1.id
            }.first
            for row in members {
                let suppressed = row.isTombstoned || row.id != canonical?.id
                let link = row.id == canonical?.id ? nil : canonical?.id
                if row.isSuppressed != suppressed { row.isSuppressed = suppressed }
                if row.linkedSessionID != link { row.linkedSessionID = link }
            }
        }
        for row in all where row.source == WorkoutSource.manual.rawValue {
            let suppressed = row.isTombstoned || row.linkedSessionID != nil
            if row.isSuppressed != suppressed { row.isSuppressed = suppressed }
        }
        var changes = WorkoutChanges()
        for row in all where before[row.id] != WorkoutCanonicalState(row) { changes.include(row) }
        return changes
    }

    /// Repair existing history without reading network sources. Expensive
    /// decoding and grouping use immutable values away from the main actor.
    /// The owner must retain its durable repair marker until derived history
    /// has also been rebuilt successfully.
    @discardableResult
    func repairWorkoutSourcesLocally(
        makePlan: @escaping @Sendable ([WorkoutSourceMatchInput]) async throws -> [String: String] = WorkoutSourceMatching.detachedPlan
    ) async throws -> WorkoutChanges {
        while true {
            try Task.checkCancellation()
            let initialRows = try allWorkouts()
            let snapshot = Self.sourceMatchSnapshot(initialRows)
            let plan = try await makePlan(snapshot)
            try Task.checkCancellation()
            let currentRows = try allWorkouts()
            guard snapshot == Self.sourceMatchSnapshot(currentRows) else {
                // Any concurrent source correction, deletion, tagging, or new
                // row invalidates the whole plan; no mutations have occurred.
                try await Task.sleep(for: .milliseconds(1))
                continue
            }
            // Do not suspend between validating the inputs and applying the
            // plan. Source-deletion and personal-data side effects remain
            // deferred until connected sources have been finalized.
            let changes = applyWorkoutSourceGroups(currentRows, groupForID: plan,
                                                   mayFinalize: false, unresolvedSources: [])
            if !changes.isEmpty { try modelContext.save() }
            return changes
        }
    }

    private static func sourceMatchSnapshot(_ rows: [Workout]) -> [WorkoutSourceMatchInput] {
        rows.map { row in
            WorkoutSourceMatchInput(
                id: row.id, date: row.date, start: row.startTime, duration: row.duration,
                type: row.workoutType, source: row.source, sourceBundleIdentifier: row.sourceBundleIdentifier,
                deviceManufacturer: row.deviceManufacturer, deviceName: row.deviceName,
                featuresData: row.source == WorkoutSource.manual.rawValue ? nil : row.featuresData,
                deletionOrigin: row.deletionOrigin, groupID: row.sessionGroupID, linkedID: row.linkedSessionID,
                isTombstoned: row.isTombstoned, isSuppressed: row.isSuppressed, userTags: row.userTags
            )
        }.sorted { $0.id < $1.id }
    }

    func allWorkouts() throws -> [Workout] {
        try modelContext.fetch(FetchDescriptor<Workout>(sortBy: [SortDescriptor(\.startTime)]))
    }

    func fetchWorkout(byId id: String) throws -> Workout? {
        let descriptor = FetchDescriptor<Workout>(
            predicate: #Predicate { $0.id == id }
        )
        let results = try modelContext.fetch(descriptor)
        return results.first
    }

    func fetchWorkouts(from startDate: Date, to endDate: Date, includeSupressed: Bool = false) throws -> [Workout] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: startDate)
        let end = calendar.startOfDay(for: endDate)

        let descriptor = FetchDescriptor<Workout>(
            predicate: #Predicate { workout in
                workout.date >= start && workout.date <= end && (includeSupressed || (!workout.isSuppressed && !workout.isTombstoned))
            },
            sortBy: [SortDescriptor(\.startTime, order: .forward)]
        )

        return try modelContext.fetch(descriptor)
    }

    /// Uses the actual start time so the interval remains correct after a time zone change.
    func fetchWeeklyWidgetWorkouts(from start: Date, to end: Date) throws -> [Workout] {
        let descriptor = FetchDescriptor<Workout>(
            predicate: #Predicate { workout in
                workout.startTime >= start && workout.startTime < end
                    && !workout.isSuppressed && !workout.isTombstoned
            },
            sortBy: [SortDescriptor(\.startTime, order: .forward)]
        )
        return try modelContext.fetch(descriptor)
    }

    func fetchWorkoutsForDay(_ date: Date) throws -> [Workout] {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)

        let descriptor = FetchDescriptor<Workout>(
            predicate: #Predicate { $0.date == startOfDay && !$0.isSuppressed && !$0.isTombstoned },
            sortBy: [SortDescriptor(\.startTime, order: .forward)]
        )

        return try modelContext.fetch(descriptor)
    }

    func ensureWorkoutMutationAllowed(for workout: Workout? = nil) throws {
        try ensureLocalRepairAllowsMutation()
        let state = try modelContext.fetch(FetchDescriptor<AppState>()).first
        if state?.isComputationInProgress == true || state?.pendingWorkoutSourceFinalization == true {
            throw WorkoutMutationError.syncInProgress
        }
        let unresolved = Set(state?.pendingHealthKitSourceBackfillIDs ?? [])
        guard let workout, !unresolved.isEmpty else { return }
        let all = try allWorkouts()
        var ids: Set<String> = [workout.id]
        var changed = true
        while changed {
            let count = ids.count
            let groups = Set(all.filter { ids.contains($0.id) }.compactMap(\.sessionGroupID))
            for row in all {
                if let group = row.sessionGroupID, groups.contains(group) { ids.insert(row.id) }
                if let link = row.linkedSessionID {
                    if ids.contains(link) { ids.insert(row.id) }
                    if ids.contains(row.id) { ids.insert(link) }
                }
            }
            changed = count != ids.count
        }
        if ids.count > 1 && !ids.isDisjoint(with: unresolved) { throw WorkoutMutationError.syncInProgress }
    }

    func deleteWorkout(_ workout: Workout) throws {
        try ensureWorkoutMutationAllowed(for: workout)
        workout.isTombstoned = true
        workout.deletionOrigin = "user"
        workout.isSuppressed = true
        try reconcileWorkoutSources()
        try rebuildLegacyLoadHistory()
        try modelContext.save()
    }

    /// Explicit deletion events only; empty read results do not establish deletion permission.
    func applyHealthKitDeletions(_ ids: [String]) throws {
        try applySourceDeletions(ids)
    }

    @discardableResult
    func applySourceDeletions(_ ids: [String], rebuildHistory: Bool = true) throws -> WorkoutChanges {
        try ensureLocalRepairAllowsMutation()
        var changes = WorkoutChanges()
        for id in ids {
            if let row = try fetchWorkout(byId: id), !row.isTombstoned {
                row.isTombstoned = true
                if row.deletionOrigin != "user" { row.deletionOrigin = "source" }
                row.isSuppressed = true
                changes.include(row)
            }
        }
        if !changes.isEmpty && rebuildHistory {
            changes.formUnion(try reconcileWorkoutSources())
            try rebuildLegacyLoadHistory()
        }
        if modelContext.hasChanges { try modelContext.save() }
        return changes
    }

    func deleteAllWorkouts() throws {
        try ensureLocalRepairAllowsMutation()
        let descriptor = FetchDescriptor<Workout>()
        let allWorkouts = try modelContext.fetch(descriptor)
        for workout in allWorkouts {
            modelContext.delete(workout)
        }
        try modelContext.save()
    }

    /// Summary-only legacy days stay intact; affected days and their dependent
    /// CTL/ATL tail are rebuilt from persisted canonical sessions.
    func rebuildLegacyLoadHistory(now: Date = Date()) throws {
        try ensureLocalRepairAllowsMutation()
        let rebuild = try LegacyHistoryRebuilder(context: modelContext, from: nil, now: now)
        while try !rebuild.applyBatch() {}
    }

    func refreshLegacyLoadHistory(from start: Date?, now: Date) async throws {
        let rebuild = try LegacyHistoryRebuilder(context: modelContext, from: start, now: now)
        repeat {
            try Task.checkCancellation()
            let finished = try rebuild.applyBatch()
            try await Task.sleep(for: .milliseconds(1))
            if finished { return }
        } while true
    }

    /// Threshold edits reuse saved samples and summaries; they do not redownload
    /// the source history. Recheck input values after each off-actor calculation.
    func refreshLegacyWorkoutTSS() async throws -> WorkoutChanges {
        var changes = WorkoutChanges()
        refresh: while true {
            let thresholds = try fetchUserThresholds()
            let revision = thresholds.lastModified
            let ftp = thresholds.preferStravaFTP ? thresholds.stravaFTP ?? thresholds.cyclingFTP : thresholds.cyclingFTP
            let maxHR = thresholds.maxHeartRate
            let rows = try allWorkouts().filter { $0.source != WorkoutSource.manual.rawValue && !$0.isTombstoned }
            for offset in stride(from: 0, to: rows.count, by: 20) {
                try Task.checkCancellation()
                let batch = Array(rows[offset..<min(offset + 20, rows.count)])
                let inputs = batch.map(LegacyWorkoutInput.init)
                let calculation = Task.detached(priority: .utility) {
                    try inputs.map { input in
                        try Task.checkCancellation()
                        return try input.calculate(ftp: ftp, maxHR: maxHR)
                    }
                }
                let result = try await withTaskCancellationHandler {
                    try await calculation.value
                } onCancel: { calculation.cancel() }
                try Task.checkCancellation()
                guard revision == thresholds.lastModified,
                      inputs == batch.map(LegacyWorkoutInput.init) else { continue refresh }
                for (row, value) in zip(batch, result) where row.tss != value.tss || row.calculationMethod != value.method {
                    if row.legacyTSS == nil { row.legacyTSS = row.tss; row.legacyCalculationMethod = row.calculationMethod }
                    row.tss = value.tss.isFinite ? value.tss : 0
                    row.calculationMethod = value.method
                    changes.include(row)
                }
                if modelContext.hasChanges { try modelContext.save() }
                try await Task.sleep(for: .milliseconds(1))
            }
            guard revision == thresholds.lastModified else { continue refresh }
            return changes
        }
    }

    func backfillV2Estimates() async throws {
        guard modelContext.container.schema.entities.contains(where: { $0.name == "LoadEstimateRecord" }) else { return }
        try await V2Store(context: modelContext).backfillEstimates()
    }

    func refreshV2Estimates() async throws {
        // Older focused unit-test containers may intentionally include only the legacy schema.
        guard modelContext.container.schema.entities.contains(where: { $0.name == "LoadEstimateRecord" }) else { return }
        try await V2Store(context: modelContext).refreshEstimates()
    }

    // MARK: - StravaAuth Operations

    func fetchStravaAuth() throws -> StravaAuth? {
        let descriptor = FetchDescriptor<StravaAuth>()
        let results = try modelContext.fetch(descriptor)
        return results.first
    }

    func saveStravaAuth(_ auth: StravaAuth) throws {
        // Delete any existing auth first (there should only be one)
        if let existing = try fetchStravaAuth() {
            modelContext.delete(existing)
        }

        modelContext.insert(auth)
        try modelContext.save()
    }

    func updateStravaAuth(_ auth: StravaAuth) throws {
        try modelContext.save()
    }

    func deleteStravaAuth(_ auth: StravaAuth) throws {
        modelContext.delete(auth)
        try modelContext.save()
    }
}


enum WorkoutMutationError: LocalizedError {
    case syncInProgress
    case localRepairInProgress

    var errorDescription: String? {
        switch self {
        case .syncInProgress:
            return "Activity sync is incomplete. Sync all connected sources, then try again."
        case .localRepairInProgress:
            return "Workout history is updating. Try again shortly."
        }
    }
}

struct WorkoutChanges {
    var ids: Set<String> = []
    var dates: Set<Date> = []
    var isEmpty: Bool { ids.isEmpty }
    mutating func include(_ row: Workout) { ids.insert(row.id); dates.insert(row.date) }
    mutating func formUnion(_ other: Self) { ids.formUnion(other.ids); dates.formUnion(other.dates) }
}

/// A reconciliation pass compares the same rows more than once. Decode each
/// full feature payload at most once in that synchronous pass, including nil
/// or unreadable endpoints; discard the cache before any source can change.
/// Endpoints decoded from exact raw payloads, retained only for one sync.
/// More than one payload may exist for an ID while a source correction is
/// pending. A stale value is never returned for different bytes.
@MainActor final class WorkoutPrewarmedEndpoints {
    private var values: [String: [PrewarmedWorkoutEndpoint]] = [:]

    nonisolated deinit {}

    func append(_ entries: [PrewarmedWorkoutEndpoint]) {
        for entry in entries { values[entry.id, default: []].append(entry) }
    }

    func matching(id: String, data: Data?) -> PrewarmedWorkoutEndpoint? {
        values[id]?.first { $0.data == data }
    }
}

@MainActor private final class WorkoutEndpointCache {
    private struct Value { let end: Date? }
    private var values: [ObjectIdentifier: Value] = [:]
    private let prewarmed: WorkoutPrewarmedEndpoints?

    init(prewarmed: WorkoutPrewarmedEndpoints? = nil) { self.prewarmed = prewarmed }

    nonisolated deinit {}

    func end(_ workout: Workout) -> Date? {
        let key = ObjectIdentifier(workout)
        if let cached = values[key] { return cached.end }
        let result: Date?
        if let prewarmed, let entry = prewarmed.matching(id: workout.id, data: workout.featuresData) {
            result = entry.end
        } else {
            result = workout.features.end
        }
        values[key] = Value(end: result)
        return result
    }
}

private struct WorkoutCanonicalState: Equatable {
    let suppressed: Bool
    let deleted: Bool
    let origin: String?
    let link: String?
    let group: String?
    let tags: [String]
    init(_ row: Workout) {
        suppressed = row.isSuppressed; deleted = row.isTombstoned
        origin = row.deletionOrigin; link = row.linkedSessionID
        group = row.sessionGroupID; tags = row.userTags
    }
}
