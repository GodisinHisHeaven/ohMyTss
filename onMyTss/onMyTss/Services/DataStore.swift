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
        appState.lastComputationDate = nil
        appState.isComputationInProgress = false
        try modelContext.save()
    }

    // MARK: - Workout Operations

    func saveWorkout(_ workout: Workout) throws {
        try saveWorkouts([workout])
    }

    /// Identity upserts preserve user data and deletion tombstones; a resync cannot resurrect a deleted row.
    func saveWorkouts(_ workouts: [Workout]) throws {
        for workout in workouts {
            if let existing = try fetchWorkout(byId: workout.id) {
                if existing.legacyTSS == nil {
                    existing.legacyTSS = existing.tss
                    existing.legacyCalculationMethod = existing.calculationMethod
                }
                if existing.date != workout.date, let oldDay = try fetchDayAggregate(for: existing.date) {
                    oldDay.hasWorkoutDetails = true
                    oldDay.totalTSS = 0 // Rebuilt from remaining records, never preserved as summary-only.
                }
                if existing.isTombstoned && existing.deletionOrigin == "source" {
                    existing.isTombstoned = false
                    existing.deletionOrigin = nil
                }
                existing.date = workout.date
                existing.startTime = workout.startTime
                existing.duration = workout.duration
                existing.workoutType = workout.workoutType
                existing.distance = workout.distance
                let unreadable = Set(workout.features.failedChannels + workout.features.unavailableChannels)
                let preserveTSS = (existing.calculationMethod.hasPrefix("power") && unreadable.contains("power"))
                    || (existing.calculationMethod.hasPrefix("hr") && unreadable.contains("heartRate"))
                if !preserveTSS {
                    existing.tss = workout.tss
                    existing.calculationMethod = workout.calculationMethod
                }
                existing.source = workout.source
                existing.stravaId = workout.stravaId
                existing.healthKitUUID = workout.healthKitUUID
                if !unreadable.contains("power") {
                    existing.averagePower = workout.averagePower
                    existing.normalizedPower = workout.normalizedPower
                }
                if !unreadable.contains("heartRate") {
                    existing.averageHeartRate = workout.averageHeartRate
                    existing.maxHeartRate = workout.maxHeartRate
                }
                existing.deviceName = workout.deviceName
                // Preserve unavailable channels individually. Explicit observed zero remains replaceable data.
                if workout.featuresData != nil {
                    var incoming = workout.features
                    let prior = existing.features
                    let unavailable = Set(incoming.failedChannels + incoming.unavailableChannels)
                    if unavailable.contains("heartRate") { incoming.heartRate = prior.heartRate }
                    if unavailable.contains("power") { incoming.power = prior.power }
                    if unavailable.contains("cadence") { incoming.cadence = prior.cadence }
                    if unavailable.contains("speed") { incoming.speed = prior.speed }
                    if unavailable.contains("terrain") {
                        incoming.elevation = prior.elevation
                        incoming.grade = prior.grade
                        incoming.ascentMeters = prior.ascentMeters
                        incoming.descentMeters = prior.descentMeters
                    }
                    if !unavailable.isEmpty && existing.featuresData != nil {
                        incoming.provenance += ["Previously saved samples retained for unreadable channels: " + unavailable.sorted().joined(separator: ", ")]
                    }
                    existing.features = incoming
                }
            } else {
                modelContext.insert(workout)
            }
        }
        try reconcileWorkoutSources()
        try modelContext.save()
    }

    /// Keep all source rows for audit, while only one canonical session contributes.
    func reconcileWorkoutSources() throws {
        let all = try modelContext.fetch(FetchDescriptor<Workout>())
        let external = all.filter { $0.source != WorkoutSource.manual.rawValue }
        // Durable logical groups survive which external source currently wins.
        // Existing groups can join when a later source establishes a duplicate.
        for row in external where row.sessionGroupID == nil { row.sessionGroupID = row.id }
        for row in external {
            if let match = external.first(where: { $0.id != row.id && sameSession($0, row) }),
               let left = row.sessionGroupID, let right = match.sessionGroupID, left != right {
                let chosen = min(left, right)
                for member in external where member.sessionGroupID == left || member.sessionGroupID == right {
                    member.sessionGroupID = chosen
                }
            }
        }
        let groups = Dictionary(grouping: external) { $0.sessionGroupID ?? $0.id }
        for members in groups.values {
            if members.contains(where: { $0.deletionOrigin == "user" }) {
                for row in members { row.isTombstoned = true; row.deletionOrigin = "user" }
            }
            let canonical = members.filter { !$0.isTombstoned }.sorted {
                if $0.source != $1.source { return $0.source == WorkoutSource.strava.rawValue }
                return $0.id < $1.id
            }.first
            if let canonical {
                canonical.userTags = Array(Set(members.flatMap(\.userTags))).sorted()
                for alias in members where alias.id != canonical.id { alias.userTags = [] }
            }
            for row in members {
                row.isSuppressed = row.isTombstoned || row.id != canonical?.id
                row.linkedSessionID = row.id == canonical?.id ? nil : canonical?.id
            }
        }
        // Manual sessions are merged only by an explicit user action, never inferred from timing.
        for row in all where row.source == WorkoutSource.manual.rawValue {
            row.isSuppressed = row.isTombstoned || row.linkedSessionID != nil
        }
    }

    private func sameSession(_ lhs: Workout, _ rhs: Workout) -> Bool {
        return WorkoutAggregator.normalizeWorkoutType(lhs.workoutType) == WorkoutAggregator.normalizeWorkoutType(rhs.workoutType)
            && abs(lhs.startTime.timeIntervalSince(rhs.startTime)) < 60
            && abs(lhs.duration - rhs.duration) < 5
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

    func applySourceDeletions(_ ids: [String]) throws {
        for id in ids {
            if let row = try fetchWorkout(byId: id) {
                row.isTombstoned = true
                if row.deletionOrigin != "user" { row.deletionOrigin = "source" }
                row.isSuppressed = true
            }
        }
        try reconcileWorkoutSources()
        try rebuildLegacyLoadHistory()
        try modelContext.save()
    }

    func deleteAllWorkouts() throws {
        let descriptor = FetchDescriptor<Workout>()
        let allWorkouts = try modelContext.fetch(descriptor)
        for workout in allWorkouts {
            modelContext.delete(workout)
        }
        try modelContext.save()
    }

    /// Rebuild from all persisted canonical sessions, not just this network response.
    /// Summary-only legacy days stay intact; deleted/linked session days become zero if appropriate.
    func rebuildLegacyLoadHistory(now: Date = Date()) throws {
        let rows = try allWorkouts()
        var aggregates = try fetchAllDayAggregates()
        let calendar = Calendar.current
        guard let first = (aggregates.map(\.date) + rows.map(\.date)).min() else { return }
        let grouped = Dictionary(grouping: rows) { calendar.startOfDay(for: $0.startTime) }
        var day = calendar.startOfDay(for: first)
        var ctl = 0.0
        var atl = 0.0
        var ctlHistory: [Double] = []
        while day <= calendar.startOfDay(for: now) {
            let aggregate: DayAggregate
            if let existing = aggregates.first(where: { $0.date == day }) {
                aggregate = existing
            } else {
                aggregate = DayAggregate(date: day)
                modelContext.insert(aggregate)
                aggregates.append(aggregate)
            }
            if let dayRows = grouped[day] {
                aggregate.hasWorkoutDetails = true
                let active = dayRows.filter { !$0.isSuppressed && !$0.isTombstoned }
                aggregate.totalTSS = active.reduce(0) { $0 + $1.tss }
                aggregate.workoutCount = active.count
                aggregate.maxTSSWorkout = active.map(\.tss).max()
                for row in dayRows { row.dayAggregate = aggregate }
            } else if aggregate.hasWorkoutDetails {
                aggregate.totalTSS = 0
                aggregate.workoutCount = 0
                aggregate.maxTSSWorkout = nil
            }
            ctl = LoadCalculator.calculateCTL(tssHistory: [aggregate.totalTSS], previousCTL: ctl)
            atl = LoadCalculator.calculateATL(tssHistory: [aggregate.totalTSS], previousATL: atl)
            aggregate.ctl = ctl
            aggregate.atl = atl
            aggregate.tsb = LoadCalculator.calculateTSB(ctl: ctl, atl: atl)
            aggregate.bodyBatteryScore = BodyBatteryCalculator.calculateScoreWithModifiers(
                tsb: aggregate.tsb, hrvModifier: aggregate.hrvModifier, rhrModifier: aggregate.rhrModifier
            )
            ctlHistory.append(ctl)
            aggregate.rampRate = ctlHistory.count >= 8
                ? LoadCalculator.calculateCTLRampRate(currentCTL: ctl, ctlOneWeekAgo: ctlHistory[ctlHistory.count - 8])
                : nil
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        try modelContext.save()
    }

    func refreshV2Estimates() throws {
        // Older focused unit-test containers may intentionally include only the legacy schema.
        guard modelContext.container.schema.entities.contains(where: { $0.name == "LoadEstimateRecord" }) else { return }
        try V2Store(context: modelContext).refreshEstimates()
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
