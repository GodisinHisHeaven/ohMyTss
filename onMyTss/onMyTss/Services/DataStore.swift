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
}
