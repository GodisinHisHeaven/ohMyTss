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
            modelContext.insert(aggregate)
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
        modelContext.insert(workout)
        try modelContext.save()
    }

    func saveWorkouts(_ workouts: [Workout]) throws {
        for workout in workouts {
            modelContext.insert(workout)
        }
        try modelContext.save()
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
                workout.date >= start && workout.date <= end && (includeSupressed || !workout.isSuppressed)
            },
            sortBy: [SortDescriptor(\.startTime, order: .forward)]
        )

        return try modelContext.fetch(descriptor)
    }

    func fetchWorkoutsForDay(_ date: Date) throws -> [Workout] {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)

        let descriptor = FetchDescriptor<Workout>(
            predicate: #Predicate { $0.date == startOfDay && !$0.isSuppressed },
            sortBy: [SortDescriptor(\.startTime, order: .forward)]
        )

        return try modelContext.fetch(descriptor)
    }

    func deleteWorkout(_ workout: Workout) throws {
        modelContext.delete(workout)
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
