import Foundation
import SwiftData

@Observable
public class DataStore {
    public let modelContainer: ModelContainer
    public let modelContext: ModelContext

    public init() {
        let schema = Schema([
            DayAggregate.self,
            UserThresholds.self,
            AppState.self
        ])

        let config = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            groupContainer: .identifier("group.com.onmytss.app")
        )

        do {
            modelContainer = try ModelContainer(for: schema, configurations: [config])
            modelContext = ModelContext(modelContainer)
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }

    // MARK: - DayAggregate Operations

    public func fetchAggregates(from startDate: Date, to endDate: Date) throws -> [DayAggregate] {
        let predicate = #Predicate<DayAggregate> { aggregate in
            aggregate.date >= startDate && aggregate.date <= endDate
        }

        let descriptor = FetchDescriptor<DayAggregate>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.date)]
        )

        return try modelContext.fetch(descriptor)
    }

    public func saveAggregates(_ aggregates: [DayAggregate]) throws {
        for aggregate in aggregates {
            // Upsert: delete existing, insert new
            if let existing = try fetchAggregate(for: aggregate.date) {
                modelContext.delete(existing)
            }
            modelContext.insert(aggregate)
        }

        try modelContext.save()
    }

    public func fetchAggregate(for date: Date) throws -> DayAggregate? {
        let startOfDay = Calendar.current.startOfDay(for: date)
        let predicate = #Predicate<DayAggregate> { $0.date == startOfDay }
        let descriptor = FetchDescriptor<DayAggregate>(predicate: predicate)
        return try modelContext.fetch(descriptor).first
    }

    // MARK: - UserThresholds Operations

    public func fetchThresholds() throws -> UserThresholds {
        let descriptor = FetchDescriptor<UserThresholds>()
        if let existing = try modelContext.fetch(descriptor).first {
            return existing
        } else {
            let new = UserThresholds()
            modelContext.insert(new)
            try modelContext.save()
            return new
        }
    }

    public func saveThresholds(_ thresholds: UserThresholds) throws {
        thresholds.lastModified = Date()
        try modelContext.save()
    }

    // MARK: - AppState Operations

    public func fetchAppState() throws -> AppState {
        let descriptor = FetchDescriptor<AppState>()
        if let existing = try modelContext.fetch(descriptor).first {
            return existing
        } else {
            let new = AppState()
            modelContext.insert(new)
            try modelContext.save()
            return new
        }
    }

    public func saveAppState(_ state: AppState) throws {
        try modelContext.save()
    }
}
