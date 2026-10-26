import Foundation
import SwiftData

/// A small write batch shared by synchronous local edits and asynchronous sync.
/// Seed from the preceding saved day so older unchanged history is not rewritten.
@MainActor
final class LegacyHistoryRebuilder {
    private let context: ModelContext
    private let store: DataStore
    private let end: Date
    private var day: Date
    private var aggregates: [Date: DayAggregate]
    private var ctl: Double
    private var atl: Double
    nonisolated deinit {}

    init(context: ModelContext, from start: Date?, now: Date) throws {
        self.context = context
        store = DataStore(modelContext: context)
        end = now.startOfDay
        let saved = Dictionary(uniqueKeysWithValues: try store.fetchAllDayAggregates().map { ($0.date, $0) })
        aggregates = saved
        var firstQuery = FetchDescriptor<Workout>(sortBy: [SortDescriptor(\.date)])
        firstQuery.fetchLimit = 1
        let firstWorkout = try context.fetch(firstQuery).first?.date
        let first = (Array(aggregates.keys) + [firstWorkout].compactMap { $0 }).min() ?? start ?? end
        var beginning = start?.startOfDay ?? first
        if let last = aggregates.keys.max(), last < end { beginning = min(beginning, last.addingDays(1)) }
        let previous = aggregates.keys.filter { $0 < beginning }.max()
        if let previous { beginning = min(beginning, previous.addingDays(1)) }
        else { beginning = min(beginning, first) }
        day = beginning.startOfDay
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
            if let existing = try aggregates[day] ?? store.fetchDayAggregate(for: day) { aggregate = existing }
            else { aggregate = DayAggregate(date: day); context.insert(aggregate) }
            aggregates[day] = aggregate
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
            let ramp = aggregates[day.addingDays(-7)].map {
                LoadCalculator.calculateCTLRampRate(currentCTL: ctl, ctlOneWeekAgo: $0.ctl)
            }
            if aggregate.ctl != ctl { aggregate.ctl = ctl }
            if aggregate.atl != atl { aggregate.atl = atl }
            if aggregate.tsb != tsb { aggregate.tsb = tsb }
            if aggregate.bodyBatteryScore != score { aggregate.bodyBatteryScore = score }
            if aggregate.rampRate != ramp { aggregate.rampRate = ramp }
            day = day.addingDays(1)
        }
        if context.hasChanges { try context.save() }
        return day > end
    }
}
