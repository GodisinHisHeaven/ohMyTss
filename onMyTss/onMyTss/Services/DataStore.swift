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

    // MARK: - DayAggregate Operations

    func saveDayAggregate(_ dayAggregate: DayAggregate) throws {
        modelContext.insert(dayAggregate)
        try modelContext.save()
    }

    /// Batch save multiple day aggregates in a single transaction for better performance
    func saveDayAggregatesBatch(_ dayAggregates: [DayAggregate]) throws {
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
        modelContext.delete(dayAggregate)
        try modelContext.save()
    }

    func deleteAllDayAggregates() throws {
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
        let appState = try fetchAppState()
        appState.lastHealthKitSyncDate = nil
        appState.healthKitAnchor = nil
        appState.lastHealthKitSampleRefreshDate = nil
        appState.pendingHealthKitWorkoutIDs = []
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
    func saveWorkouts(_ workouts: [Workout]) throws -> WorkoutChanges {
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
            changes.formUnion(try reconcileWorkoutSources())
            try modelContext.save()
        }
        return changes
    }

    private func merge(_ incoming: Workout, into existing: Workout) throws -> Bool {
        if incoming.featuresData == existing.featuresData,
           incoming.date == existing.date, incoming.startTime == existing.startTime,
           incoming.duration == existing.duration, incoming.workoutType == existing.workoutType,
           incoming.distance == existing.distance, incoming.tss == existing.tss,
           incoming.calculationMethod == existing.calculationMethod, incoming.source == existing.source,
           incoming.stravaId == existing.stravaId, incoming.healthKitUUID == existing.healthKitUUID,
           incoming.averagePower == existing.averagePower, incoming.normalizedPower == existing.normalizedPower,
           incoming.averageHeartRate == existing.averageHeartRate, incoming.maxHeartRate == existing.maxHeartRate,
           incoming.deviceName == existing.deviceName,
           !(existing.isTombstoned && existing.deletionOrigin == "source") { return false }
        var features = incoming.features
        let unreadable = Set(features.failedChannels + features.unavailableChannels)
        var featuresData = incoming.featuresData ?? existing.featuresData
        if let data = incoming.featuresData, data != existing.featuresData {
            let prior = existing.features
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
            || existing.maxHeartRate != maxHR || existing.deviceName != incoming.deviceName
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
        existing.deviceName = incoming.deviceName
        existing.featuresData = featuresData
        return true
    }

    /// Bounded imports combine both sources. Reconcile before committing each
    /// batch, so cancellation never leaves duplicate active source rows. Each yield
    /// allows navigation and Settings to run during a large first import.
    func applyImportedWorkouts(_ workouts: [Workout], deletedIDs: [String]) async throws -> WorkoutChanges {
        var changes = WorkoutChanges()
        for offset in stride(from: 0, to: workouts.count, by: 20) {
            try Task.checkCancellation()
            changes.formUnion(try saveWorkouts(Array(workouts[offset..<min(offset + 20, workouts.count)])))
            try await Task.sleep(for: .milliseconds(1))
        }
        for offset in stride(from: 0, to: deletedIDs.count, by: 20) {
            try Task.checkCancellation()
            let deleted = try applySourceDeletions(Array(deletedIDs[offset..<min(offset + 20, deletedIDs.count)]), rebuildHistory: false)
            changes.formUnion(deleted)
            if !deleted.isEmpty {
                changes.formUnion(try reconcileWorkoutSources())
                try modelContext.save()
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        return changes
    }

    /// Compare only temporally adjacent sources, instead of searching every
    /// historical row for every activity. Existing logical groups stay durable.
    @discardableResult
    func reconcileWorkoutSources() throws -> WorkoutChanges {
        let all = try allWorkouts()
        let before = Dictionary(uniqueKeysWithValues: all.map { ($0.id, WorkoutCanonicalState($0)) })
        let external = all.filter { $0.source != WorkoutSource.manual.rawValue }
        var parents: [String: String] = [:]
        func root(_ value: String) -> String {
            var current = value
            while let parent = parents[current], parent != current { current = parent }
            return current
        }
        let types = external.map { WorkoutAggregator.normalizeWorkoutType($0.workoutType) }
        for index in external.indices {
            let row = external[index]
            var candidate = index + 1
            while candidate < external.count && external[candidate].startTime.timeIntervalSince(row.startTime) < 60 {
                let other = external[candidate]
                if types[index] == types[candidate] && abs(row.duration - other.duration) < 5 {
                    let left = root(row.sessionGroupID ?? row.id)
                    let right = root(other.sessionGroupID ?? other.id)
                    if left != right { parents[max(left, right)] = min(left, right) }
                }
                candidate += 1
            }
        }
        for row in external {
            let group = root(row.sessionGroupID ?? row.id)
            if row.sessionGroupID != group { row.sessionGroupID = group }
        }
        let groups = Dictionary(grouping: external) { $0.sessionGroupID ?? $0.id }
        for members in groups.values {
            if members.contains(where: { $0.deletionOrigin == "user" }) {
                for row in members where !row.isTombstoned || row.deletionOrigin != "user" {
                    row.isTombstoned = true; row.deletionOrigin = "user"
                }
            }
            let canonical = members.filter { !$0.isTombstoned }.sorted {
                if $0.source != $1.source { return $0.source == WorkoutSource.strava.rawValue }
                return $0.id < $1.id
            }.first
            if let canonical {
                let tags = Array(Set(members.flatMap(\.userTags))).sorted()
                if canonical.userTags != tags { canonical.userTags = tags }
                for alias in members where alias.id != canonical.id && !alias.userTags.isEmpty { alias.userTags = [] }
            }
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

    func fetchWorkoutsForDay(_ date: Date) throws -> [Workout] {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)

        let descriptor = FetchDescriptor<Workout>(
            predicate: #Predicate { $0.date == startOfDay && !$0.isSuppressed && !$0.isTombstoned },
            sortBy: [SortDescriptor(\.startTime, order: .forward)]
        )

        return try modelContext.fetch(descriptor)
    }

    func deleteWorkout(_ workout: Workout) throws {
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


struct WorkoutChanges {
    var ids: Set<String> = []
    var dates: Set<Date> = []
    var isEmpty: Bool { ids.isEmpty }
    mutating func include(_ row: Workout) { ids.insert(row.id); dates.insert(row.date) }
    mutating func formUnion(_ other: Self) { ids.formUnion(other.ids); dates.formUnion(other.dates) }
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
