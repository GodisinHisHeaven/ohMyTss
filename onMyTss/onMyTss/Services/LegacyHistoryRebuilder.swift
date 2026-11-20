import Foundation
import SwiftData

/// A small write batch shared by synchronous local edits and asynchronous sync.
/// Seed from the preceding saved day so older unchanged history is not rewritten.
@MainActor
final class LegacyHistoryRebuilder {
    private let context: ModelContext
    private let store: DataStore
    private let calendar: Calendar
    private let end: Date
    private var day: Date
    private var aggregates: [Date: DayAggregate]
    private var ctl: Double
    private var atl: Double
    nonisolated deinit {}

    init(context: ModelContext, from start: Date?, now: Date, calendar: Calendar = .current) throws {
        self.context = context
        self.calendar = calendar
        store = DataStore(modelContext: context)
        end = calendar.startOfDay(for: now)
        if let start {
            let requested = calendar.startOfDay(for: start)
            var prior = FetchDescriptor<DayAggregate>(predicate: #Predicate { $0.date < requested },
                                                      sortBy: [SortDescriptor(\.date, order: .reverse)])
            prior.fetchLimit = 1
            prior.propertiesToFetch = [\.date]
            if requested <= end, let date = try context.fetch(prior).first?.date,
               let interval = calendar.dateInterval(of: .day, for: date),
               let rampStart = calendar.date(byAdding: .day, value: -7, to: interval.end) {
                // Include gaps after the saved seed and the prior week used for ramp rate.
                // Old stores can have two rows on one local day after a time zone change.
                let rows = try store.fetchDayAggregates(from: rampStart, to: end, calendar: calendar)
                aggregates = DayAggregate.byLocalDay(rows, calendar: calendar)
                day = interval.end
                ctl = aggregates[interval.start]?.ctl ?? 0
                atl = aggregates[interval.start]?.atl ?? 0
                return
            }
        }
        let saved = try DayAggregate.byLocalDay(store.fetchAllDayAggregates(), calendar: calendar)
        aggregates = saved
        var firstQuery = FetchDescriptor<Workout>(sortBy: [SortDescriptor(\.startTime)])
        firstQuery.fetchLimit = 1
        firstQuery.propertiesToFetch = [\.startTime]
        let firstWorkout = try context.fetch(firstQuery).first.map { calendar.startOfDay(for: $0.startTime) }
        let first = (Array(aggregates.keys) + [firstWorkout].compactMap { $0 }).min() ?? start ?? end
        var beginning = start.map { calendar.startOfDay(for: $0) } ?? first
        if let last = aggregates.keys.max(), last < end, let next = calendar.dateInterval(of: .day, for: last)?.end {
            beginning = min(beginning, next)
        }
        let previous = aggregates.keys.filter { $0 < beginning }.max()
        if let previous, let next = calendar.dateInterval(of: .day, for: previous)?.end {
            beginning = min(beginning, next)
        }
        else { beginning = min(beginning, first) }
        day = calendar.startOfDay(for: beginning)
        ctl = previous.flatMap { saved[$0]?.ctl } ?? 0
        atl = previous.flatMap { saved[$0]?.atl } ?? 0
    }

    func applyBatch() throws -> Bool {
        for _ in 0..<14 {
            guard day <= end else {
                if context.hasChanges { try context.save() }
                return true
            }
            let aggregate: DayAggregate
            if let existing = try aggregates[day] ?? store.fetchDayAggregate(for: day, calendar: calendar) { aggregate = existing }
            else { aggregate = DayAggregate(date: day); context.insert(aggregate) }
            aggregates[day] = aggregate
            // Fetch at application time: a local edit during a yield must win.
            let rows = try store.fetchWorkouts(from: day, to: day, includeSuppressed: true, calendar: calendar)
            let active = rows.filter { !$0.isSuppressed && !$0.isTombstoned }
            if !rows.isEmpty || aggregate.hasWorkoutDetails {
                if !aggregate.hasWorkoutDetails { aggregate.hasWorkoutDetails = true }
                let total = active.reduce(0) { $0 + $1.tss }
                let maximum = active.map(\.tss).max()
                if aggregate.totalTSS != total { aggregate.totalTSS = total }
                if aggregate.workoutCount != active.count { aggregate.workoutCount = active.count }
                if aggregate.maxTSSWorkout != maximum { aggregate.maxTSSWorkout = maximum }
                for row in rows where row.dayAggregate?.date != aggregate.date { row.dayAggregate = aggregate }
            }
            ctl = LoadCalculator.calculateCTL(tssHistory: [aggregate.totalTSS], previousCTL: ctl)
            atl = LoadCalculator.calculateATL(tssHistory: [aggregate.totalTSS], previousATL: atl)
            let tsb = LoadCalculator.calculateTSB(ctl: ctl, atl: atl)
            let score = BodyBatteryCalculator.calculateScoreWithModifiers(
                tsb: tsb, hrvModifier: aggregate.hrvModifier, rhrModifier: aggregate.rhrModifier
            )
            let ramp = calendar.date(byAdding: .day, value: -7, to: day)
                .flatMap { aggregates[calendar.startOfDay(for: $0)] }.map {
                LoadCalculator.calculateCTLRampRate(currentCTL: ctl, ctlOneWeekAgo: $0.ctl)
            }
            if aggregate.ctl != ctl { aggregate.ctl = ctl }
            if aggregate.atl != atl { aggregate.atl = atl }
            if aggregate.tsb != tsb { aggregate.tsb = tsb }
            if aggregate.bodyBatteryScore != score { aggregate.bodyBatteryScore = score }
            if aggregate.rampRate != ramp { aggregate.rampRate = ramp }
            day = calendar.dateInterval(of: .day, for: day)?.end ?? end.addingTimeInterval(1)
        }
        if context.hasChanges { try context.save() }
        return day > end
    }
}
