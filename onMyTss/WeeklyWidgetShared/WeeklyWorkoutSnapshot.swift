import Foundation

/// Persisted separately so a failed sync never destroys the last saved records.
nonisolated struct WeeklyWorkoutSourceState: Codable, Equatable {
    private static let key = "weeklyWorkouts.sourceState.v1"
    var invalid = false
    var inFlight = false

    static func load(defaults: UserDefaults?) -> Self? {
        guard let defaults else { return nil }
        guard let raw = defaults.object(forKey: key) else { return Self() }
        guard let data = raw as? Data, let state = try? JSONDecoder().decode(Self.self, from: data) else {
            return Self(invalid: true, inFlight: true)
        }
        return state
    }

    func save(defaults: UserDefaults?) -> Bool {
        guard let defaults, let data = try? JSONEncoder().encode(self) else { return false }
        defaults.set(data, forKey: Self.key)
        return defaults.synchronize() && defaults.data(forKey: Self.key) == data
    }
}

/// A bounded copy of the phone's workout history for WidgetKit.
nonisolated struct WeeklyWorkoutRecord: Codable, Equatable {
    let date: Date
    let workoutType: String
}

nonisolated enum WeeklyWorkoutCategory: Equatable {
    case running, cycling, swimming, strength, walking, other

    init(type: String) {
        let value = type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.contains("run") { self = .running }
        else if value.contains("ride") || value.contains("cycl") || value.contains("bike") { self = .cycling }
        else if value.contains("swim") { self = .swimming }
        else if value.contains("strength") || value.contains("weight") || value.contains("resistance") { self = .strength }
        else if value.contains("walk") || value.contains("hik") { self = .walking }
        else { self = .other }
    }
}

nonisolated struct WeeklyWorkoutSnapshot: Codable, Equatable {
    static let appGroup = "group.mj6.onMyTss.weekly"
    static let kind = "ohmytss.weekly-workouts"
    private static let storageKey = "weeklyWorkouts.v1"
    static let freshnessInterval: TimeInterval = 6 * 60 * 60

    /// The interval covered by this snapshot, including days without workouts.
    let weekStart: Date
    let weekEnd: Date
    let generatedAt: Date
    /// Latest successful sync shared by all enabled external workout sources.
    /// Missing in legacy snapshots and when source coverage is unknown.
    let sourceSyncedAt: Date?
    let records: [WeeklyWorkoutRecord]

    /// A snapshot cannot establish that a later day had no workouts.
    func covers(day: Date, asOf: Date, calendar: Calendar = .current) -> Bool {
        let dayStart = calendar.startOfDay(for: day)
        let currentDay = calendar.startOfDay(for: asOf)
        if dayStart > currentDay { return true }
        guard let sourceSyncedAt, sourceSyncedAt <= asOf, sourceSyncedAt <= generatedAt else { return false }
        let syncedDay = calendar.startOfDay(for: sourceSyncedAt)
        if dayStart < currentDay { return dayStart <= syncedDay }
        return dayStart == syncedDay && asOf.timeIntervalSince(sourceSyncedAt) < Self.freshnessInterval
    }

    /// Equivalent visible content needs a reload only when freshness or the day changes.
    func hasSameDisplay(as other: Self, at now: Date, calendar: Calendar) -> Bool {
        weekStart == other.weekStart && weekEnd == other.weekEnd && records == other.records
            && calendar.isDate(generatedAt, inSameDayAs: other.generatedAt)
            && covers(day: now, asOf: now, calendar: calendar)
                == other.covers(day: now, asOf: now, calendar: calendar)
    }

    static func load(defaults: UserDefaults? = UserDefaults(suiteName: appGroup)) -> WeeklyWorkoutSnapshot? {
        guard let data = defaults?.data(forKey: storageKey),
              let snapshot = try? JSONDecoder().decode(Self.self, from: data),
              snapshot.weekStart < snapshot.weekEnd,
              let state = WeeklyWorkoutSourceState.load(defaults: defaults) else { return nil }
        guard state.invalid else { return snapshot }
        return Self(weekStart: snapshot.weekStart, weekEnd: snapshot.weekEnd,
                    generatedAt: snapshot.generatedAt, sourceSyncedAt: nil, records: snapshot.records)
    }

    @discardableResult
    func save(defaults: UserDefaults? = UserDefaults(suiteName: appGroup), now: Date = Date()) -> Bool {
        guard let defaults, weekStart < weekEnd else { return false }
        // A clock correction must not prevent fresh snapshots from being saved indefinitely.
        if let previous = Self.load(defaults: defaults), previous.generatedAt > generatedAt,
           previous.generatedAt <= now.addingTimeInterval(300) { return false }
        guard let data = try? JSONEncoder().encode(self) else { return false }
        defaults.set(data, forKey: Self.storageKey)
        return true
    }
}
