import Foundation

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

    /// The interval covered by this snapshot, including days without workouts.
    let weekStart: Date
    let weekEnd: Date
    let generatedAt: Date
    let records: [WeeklyWorkoutRecord]

    /// A snapshot cannot establish that a later day had no workouts.
    func covers(day: Date, asOf: Date, calendar: Calendar = .current) -> Bool {
        let dayStart = calendar.startOfDay(for: day)
        return dayStart > calendar.startOfDay(for: asOf)
            || dayStart <= calendar.startOfDay(for: generatedAt)
    }

    static func load(defaults: UserDefaults? = UserDefaults(suiteName: appGroup)) -> WeeklyWorkoutSnapshot? {
        guard let data = defaults?.data(forKey: storageKey),
              let snapshot = try? JSONDecoder().decode(Self.self, from: data),
              snapshot.weekStart < snapshot.weekEnd else { return nil }
        return snapshot
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
