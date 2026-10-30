import Foundation
import SwiftData
import SwiftUI
import WidgetKit

/// The app owns the activity data; the widget receives only dates and types.
@MainActor
enum WeeklyWorkoutSync {
    static func allowsPublishing(arguments: [String]) -> Bool {
        !arguments.contains("--v2-ui-tests") && !arguments.contains { $0.hasSuffix("-fixture") }
    }

    static func snapshot(workouts: [Workout], now: Date, calendar: Calendar = .current) -> WeeklyWorkoutSnapshot? {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: now) else { return nil }
        let records = workouts.filter {
            !$0.isSuppressed && !$0.isTombstoned && $0.startTime >= week.start
                && $0.startTime < week.end && $0.startTime <= now
        }.sorted {
            if $0.startTime != $1.startTime { return $0.startTime < $1.startTime }
            return $0.workoutType < $1.workoutType
        }.map { WeeklyWorkoutRecord(date: $0.startTime, workoutType: $0.workoutType) }
        return WeeklyWorkoutSnapshot(weekStart: week.start, weekEnd: week.end, generatedAt: now, records: records)
    }

    @discardableResult
    static func publish(workouts: [Workout], now: Date = Date(), calendar: Calendar = .current,
                        defaults: UserDefaults? = UserDefaults(suiteName: WeeklyWorkoutSnapshot.appGroup),
                        arguments: [String] = ProcessInfo.processInfo.arguments,
                        reload: () -> Void = { WidgetCenter.shared.reloadTimelines(ofKind: WeeklyWorkoutSnapshot.kind) }) -> Bool {
        guard allowsPublishing(arguments: arguments),
              let snapshot = snapshot(workouts: workouts, now: now, calendar: calendar),
              snapshot.save(defaults: defaults) else { return false }
        reload()
        return true
    }


}

/// Rebuilds after activity edits, app activation, and local day/week changes.
struct WeeklyWorkoutObserver: View {
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            WeeklyWorkoutDayObserver(now: timeline.date, isActive: scenePhase == .active)
        }
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}

private struct WeeklyWorkoutDayObserver: View {
    let now: Date
    let isActive: Bool
    @Query private var workouts: [Workout]
    @Query private var appStates: [AppState]

    init(now: Date, isActive: Bool) {
        self.now = now
        self.isActive = isActive
        let week = Calendar.current.dateInterval(of: .weekOfYear, for: now)
        let start = week?.start ?? now
        let end = week?.end ?? now
        _workouts = Query(filter: #Predicate<Workout> {
            $0.startTime >= start && $0.startTime < end && !$0.isSuppressed && !$0.isTombstoned
        }, sort: \Workout.startTime)
    }

    var body: some View {
        let canPublish = isActive && !(appStates.first?.isComputationInProgress ?? false)
        let trigger = Trigger(day: Calendar.current.startOfDay(for: now),
                              timeZone: Calendar.current.timeZone.identifier,
                              firstWeekday: Calendar.current.firstWeekday, isActive: canPublish,
                              records: workouts.filter { $0.startTime <= now }.map {
                                  Activity(id: $0.id, date: $0.startTime, type: $0.workoutType)
                              })
        Color.clear.task(id: trigger) {
            guard canPublish else { return }
            WeeklyWorkoutSync.publish(workouts: workouts, now: now)
        }
    }

    private struct Activity: Equatable {
        let id: String
        let date: Date
        let type: String
    }
    private struct Trigger: Equatable {
        let day: Date
        let timeZone: String
        let firstWeekday: Int
        let isActive: Bool
        let records: [Activity]
    }
}
