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

    static func snapshot(workouts: [Workout], now: Date, calendar: Calendar = .current,
                         sourceSyncedAt: Date? = nil) -> WeeklyWorkoutSnapshot? {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: now) else { return nil }
        let records = workouts.filter {
            !$0.isSuppressed && !$0.isTombstoned && $0.startTime >= week.start
                && $0.startTime < week.end && $0.startTime <= now
        }.sorted {
            if $0.startTime != $1.startTime { return $0.startTime < $1.startTime }
            return $0.workoutType < $1.workoutType
        }.map { WeeklyWorkoutRecord(date: $0.startTime, workoutType: $0.workoutType) }
        return WeeklyWorkoutSnapshot(weekStart: week.start, weekEnd: week.end, generatedAt: now,
                                     sourceSyncedAt: sourceSyncedAt, records: records)
    }

    @discardableResult
    static func publish(workouts: [Workout], now: Date = Date(), calendar: Calendar = .current,
                        sourceSyncedAt: Date? = nil, defaults: UserDefaults? = UserDefaults(suiteName: WeeklyWorkoutSnapshot.appGroup),
                        arguments: [String] = ProcessInfo.processInfo.arguments,
                        reload: () -> Void = { WidgetCenter.shared.reloadTimelines(ofKind: WeeklyWorkoutSnapshot.kind) }) -> Bool {
        guard allowsPublishing(arguments: arguments),
              let state = WeeklyWorkoutSourceState.load(defaults: defaults),
              let snapshot = snapshot(workouts: workouts, now: now, calendar: calendar,
                                      sourceSyncedAt: sourceSyncedAt) else { return false }
        let previous = WeeklyWorkoutSnapshot.load(defaults: defaults)
        if state.invalid {
            let visible = WeeklyWorkoutSnapshot(weekStart: snapshot.weekStart, weekEnd: snapshot.weekEnd,
                                                generatedAt: snapshot.generatedAt, sourceSyncedAt: nil,
                                                records: snapshot.records)
            let unchanged = previous?.hasSameDisplay(as: visible, at: now, calendar: calendar) == true
            // A successful source timestamp must be persisted before the invalid marker is cleared.
            if unchanged && sourceSyncedAt == nil { return true }
            guard snapshot.save(defaults: defaults, now: now) else { return false }
            if !unchanged { reload() }
            return true
        }
        // Keep the existing timeline and its expiry aligned when skipping a reload.
        if let previous, previous.hasSameDisplay(as: snapshot, at: now, calendar: calendar) {
            switch (previous.sourceSyncedAt, snapshot.sourceSyncedAt) {
            case (nil, nil):
                return true
            case let (old?, new?) where old == new:
                return true
            case let (old?, new?) where new > old && new <= now
                && old.addingTimeInterval(WeeklyWorkoutSnapshot.freshnessInterval - 3600) > now:
                // Reuse the existing expiry, but renew it when less than an hour remains.
                return true
            default:
                break
            }
        }
        guard snapshot.save(defaults: defaults, now: now) else { return false }
        reload()
        return true
    }

    /// A normal in-flight pass does not invalidate existing content or request a reload.
    @discardableResult
    static func beginSourceSync(defaults: UserDefaults? = UserDefaults(suiteName: WeeklyWorkoutSnapshot.appGroup),
                                arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        guard allowsPublishing(arguments: arguments),
              var state = WeeklyWorkoutSourceState.load(defaults: defaults) else { return false }
        state.inFlight = true
        return state.save(defaults: defaults)
    }

    /// A source change makes prior coverage unknown without ending an in-flight sync.
    @discardableResult
    static func invalidateSource(defaults: UserDefaults? = UserDefaults(suiteName: WeeklyWorkoutSnapshot.appGroup),
                                 arguments: [String] = ProcessInfo.processInfo.arguments,
                                 reload: () -> Void = { WidgetCenter.shared.reloadTimelines(ofKind: WeeklyWorkoutSnapshot.kind) }) -> Bool {
        guard allowsPublishing(arguments: arguments),
              var state = WeeklyWorkoutSourceState.load(defaults: defaults) else { return false }
        if state.invalid { return true }
        state.invalid = true
        guard state.save(defaults: defaults) else { return false }
        reload()
        return true
    }

    /// The caller clears invalid only after all enabled sources have been saved successfully.
    @discardableResult
    static func finishSourceSync(success: Bool,
                                 defaults: UserDefaults? = UserDefaults(suiteName: WeeklyWorkoutSnapshot.appGroup),
                                 arguments: [String] = ProcessInfo.processInfo.arguments,
                                 reload: () -> Void = { WidgetCenter.shared.reloadTimelines(ofKind: WeeklyWorkoutSnapshot.kind) }) -> Bool {
        guard allowsPublishing(arguments: arguments),
              var state = WeeklyWorkoutSourceState.load(defaults: defaults) else { return false }
        let changed = state.invalid == success
        state.invalid = !success
        state.inFlight = false
        guard state.save(defaults: defaults) else { return false }
        if changed { reload() }
        return true
    }

    /// Only call once on startup, before starting a new sync.
    @discardableResult
    static func recoverInterruptedSourceSync(defaults: UserDefaults? = UserDefaults(suiteName: WeeklyWorkoutSnapshot.appGroup),
                                             arguments: [String] = ProcessInfo.processInfo.arguments,
                                             reload: () -> Void = { WidgetCenter.shared.reloadTimelines(ofKind: WeeklyWorkoutSnapshot.kind) }) -> Bool {
        guard allowsPublishing(arguments: arguments),
              let state = WeeklyWorkoutSourceState.load(defaults: defaults) else { return false }
        guard state.inFlight else { return true }
        return finishSourceSync(success: false, defaults: defaults, arguments: arguments, reload: reload)
    }

    /// Do not turn a cache read into evidence of an external source sync.
    static func sourceSyncDate(state: AppState?, auth: StravaAuth?) -> Date? {
        guard let state, let computation = state.lastComputationDate,
              let healthKit = state.lastHealthKitSyncDate, healthKit == computation else { return nil }
        guard let auth, auth.isConnected else { return healthKit }
        guard let strava = auth.lastSyncDate, strava == computation,
              auth.connectedAt.map({ strava >= $0 }) ?? true else { return nil }
        return min(healthKit, strava)
    }

    /// Publish only after the caller has successfully saved a completed sync.
    @discardableResult
    static func publish(store: DataStore, now: Date = Date(), calendar: Calendar = .current,
                        defaults: UserDefaults? = UserDefaults(suiteName: WeeklyWorkoutSnapshot.appGroup),
                        arguments: [String] = ProcessInfo.processInfo.arguments,
                        reload: () -> Void = { WidgetCenter.shared.reloadTimelines(ofKind: WeeklyWorkoutSnapshot.kind) }) -> Bool {
        guard !Task.isCancelled, allowsPublishing(arguments: arguments) else { return false }
        let state: AppState
        let auth: StravaAuth?
        do {
            state = try store.fetchAppState()
            auth = try store.fetchStravaAuth()
        } catch { return false }
        guard !state.isComputationInProgress, !state.pendingWorkoutSourceFinalization,
              !LocalWorkoutHistoryRepair.isRequired(state) else { return false }
        guard let week = calendar.dateInterval(of: .weekOfYear, for: now),
              let workouts = try? store.fetchWeeklyWidgetWorkouts(from: week.start, to: week.end),
              !Task.isCancelled else { return false }
        let sourceSyncedAt = sourceSyncDate(state: state, auth: auth)
        return publish(workouts: workouts, now: now, calendar: calendar, sourceSyncedAt: sourceSyncedAt,
                       defaults: defaults, arguments: arguments, reload: reload)
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
    @Environment(\.modelContext) private var context
    @Query private var workouts: [Workout]
    @Query private var appStates: [AppState]
    @Query private var stravaAuths: [StravaAuth]

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
        let canPublish = isActive && appStates.first.map {
            !$0.isComputationInProgress && !$0.pendingWorkoutSourceFinalization &&
                !LocalWorkoutHistoryRepair.isRequired($0)
        } == true
        let sourceSyncedAt = WeeklyWorkoutSync.sourceSyncDate(state: appStates.first, auth: stravaAuths.first)
        let trigger = Trigger(day: Calendar.current.startOfDay(for: now),
                              timeZone: Calendar.current.timeZone.identifier,
                              firstWeekday: Calendar.current.firstWeekday, isActive: canPublish,
                              sourceSyncedAt: sourceSyncedAt, records: workouts.filter { $0.startTime <= now }.map {
                                  Activity(id: $0.id, date: $0.startTime, type: $0.workoutType)
                              })
        Color.clear.task(id: trigger) {
            guard canPublish, !Task.isCancelled else { return }
            // The task can start after the state used to construct its trigger
            // changed. Re-fetch the marker and workouts before publishing.
            WeeklyWorkoutSync.publish(store: DataStore(modelContext: context), now: now)
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
        let sourceSyncedAt: Date?
        let records: [Activity]
    }
}
