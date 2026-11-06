import Foundation
import SwiftData

/// Bounded writes shared by local edits and sync. A durable request coalesces
/// overlapping rebuilds; a suspended writer must adopt the latest request/seed.
@MainActor
final class LegacyHistoryRebuilder {
    private let context: ModelContext
    private let store: DataStore
    private let state: AppState
    private var revision: Int = -1
    private var end: Date
    private var day: Date
    private var ctl = 0.0
    private var atl = 0.0
    nonisolated deinit {}

    init(context: ModelContext, from start: Date?, now: Date) throws {
        self.context = context
        store = DataStore(modelContext: context)
        state = try store.fetchAppState()
        end = max(now.startOfDay, state.pendingLegacyHistoryEnd ?? now.startOfDay)
        day = start?.startOfDay ?? end
        // Only inspect boundary rows. A recent deletion must not load years of
        // aggregates (or their workout relationships) before its first yield.
        if start == nil { day = try firstDay() ?? day }
        if let pending = state.pendingLegacyHistoryStart { day = min(day, pending) }
        var lastQuery = FetchDescriptor<DayAggregate>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        lastQuery.fetchLimit = 1
        if let last = try context.fetch(lastQuery).first, last.date < end {
            day = min(day, last.date.addingDays(1))
        }
        try seed()
        state.pendingLegacyHistoryStart = day
        state.pendingLegacyHistoryEnd = end
        state.legacyHistoryRevision += 1
        revision = state.legacyHistoryRevision
        // Save the edit and its recovery marker together before any suspension.
        try context.save()
    }

    private func firstDay() throws -> Date? {
        var days = FetchDescriptor<DayAggregate>(sortBy: [SortDescriptor(\.date)])
        days.fetchLimit = 1
        var workouts = FetchDescriptor<Workout>(sortBy: [SortDescriptor(\.date)])
        workouts.fetchLimit = 1
        workouts.propertiesToFetch = [\.date]
        return try [context.fetch(days).first?.date, context.fetch(workouts).first?.date].compactMap { $0 }.min()
    }

    private func seed() throws {
        let beginning = day
        var query = FetchDescriptor<DayAggregate>(
            predicate: #Predicate { $0.date < beginning },
            sortBy: [SortDescriptor(\.date, order: .reverse)])
        query.fetchLimit = 1
        if let previous = try context.fetch(query).first {
            day = previous.date.addingDays(1)
            ctl = previous.ctl
            atl = previous.atl
        } else {
            day = min(day, try firstDay() ?? day)
            ctl = 0
            atl = 0
        }
    }

    func applyBatch() throws -> Bool {
        guard let pending = state.pendingLegacyHistoryStart else { return true }
        if revision != state.legacyHistoryRevision {
            // Another edit/rebuild may have repaired days already consumed by
            // this instance. Never continue with its cached recurrence state.
            day = pending
            end = state.pendingLegacyHistoryEnd ?? end
            try seed()
            revision = state.legacyHistoryRevision
        }
        for _ in 0..<14 {
            guard day <= end else {
                return try finish()
            }
            let aggregate: DayAggregate
            if let existing = try store.fetchDayAggregate(for: day) { aggregate = existing }
            else { aggregate = DayAggregate(date: day); context.insert(aggregate) }
            // Fetch at application time: a local edit during a yield must win.
            let rows = try store.fetchWorkouts(from: day, to: day, includeSupressed: true)
            let active = rows.filter { !$0.isSuppressed && !$0.isTombstoned }
            if !rows.isEmpty || aggregate.hasWorkoutDetails {
                if !aggregate.hasWorkoutDetails { aggregate.hasWorkoutDetails = true }
                let total = active.reduce(0) { $0 + $1.tss }
                let maximum = active.map(\.tss).max()
                if aggregate.totalTSS != total { aggregate.totalTSS = total }
                if aggregate.workoutCount != active.count { aggregate.workoutCount = active.count }
                if aggregate.maxTSSWorkout != maximum { aggregate.maxTSSWorkout = maximum }
                for row in rows where row.dayAggregate?.date != day { row.dayAggregate = aggregate }
            }
            ctl = LoadCalculator.calculateCTL(tssHistory: [aggregate.totalTSS], previousCTL: ctl)
            atl = LoadCalculator.calculateATL(tssHistory: [aggregate.totalTSS], previousATL: atl)
            let tsb = LoadCalculator.calculateTSB(ctl: ctl, atl: atl)
            let score = BodyBatteryCalculator.calculateScoreWithModifiers(
                tsb: tsb, hrvModifier: aggregate.hrvModifier, rhrModifier: aggregate.rhrModifier
            )
            let ramp = try store.fetchDayAggregate(for: day.addingDays(-7)).map {
                LoadCalculator.calculateCTLRampRate(currentCTL: ctl, ctlOneWeekAgo: $0.ctl)
            }
            if aggregate.ctl != ctl { aggregate.ctl = ctl }
            if aggregate.atl != atl { aggregate.atl = atl }
            if aggregate.tsb != tsb { aggregate.tsb = tsb }
            if aggregate.bodyBatteryScore != score { aggregate.bodyBatteryScore = score }
            if aggregate.rampRate != ramp { aggregate.rampRate = ramp }
            day = day.addingDays(1)
        }
        if day > end { return try finish() }
        if context.hasChanges { try context.save() }
        return false
    }

    private func finish() throws -> Bool {
        let pending = state.pendingLegacyHistoryStart
        let pendingEnd = state.pendingLegacyHistoryEnd
        state.pendingLegacyHistoryStart = nil
        state.pendingLegacyHistoryEnd = nil
        do { try context.save() }
        catch {
            state.pendingLegacyHistoryStart = pending
            state.pendingLegacyHistoryEnd = pendingEnd
            throw error
        }
        return true
    }
}
