import Foundation

@MainActor
struct TodayReadiness {
    let day: DayAggregate?
    let assessment: TrainingReadiness.Assessment?
    let updatedAt: Date?

    init(days: [DayAggregate], workouts: [Workout]? = nil, lastComputation: Date?, now: Date = Date(), calendar: Calendar = .current) {
        let history = DayAggregate.byLocalDay(days, calendar: calendar)
        day = history[calendar.startOfDay(for: now)]
        let sessions = workouts.map { Dictionary(grouping: $0) { calendar.startOfDay(for: $0.startTime) } }
        assessment = day.map { TrainingReadiness.assess($0, history: history, workoutsByDay: sessions, asOf: now, calendar: calendar) }
        updatedAt = lastComputation.flatMap {
            $0 <= now && calendar.isDate($0, inSameDayAs: now) ? $0 : nil
        }
    }

    var score: Int? { assessment?.score }
    var basis: String { assessment?.basis ?? "Sync today's health data to see your readiness." }
}
