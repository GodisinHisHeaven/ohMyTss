import Foundation

/// Only these aggregates leave the device after explicit morning-text consent.
struct MorningAppSummary: Equatable {
    let summaryDate: String
    let timezone: String
    let generatedAt: Date
    let readinessScore: Int?
    let sleepHours: Double?
    let trainingMinutes7d: Int

    var payload: [String: Any] {
        var result: [String: Any] = ["summary_date": summaryDate, "timezone": timezone,
            "generated_at": ISO8601DateFormatter().string(from: generatedAt),
            "training_minutes_7d": trainingMinutes7d]
        if let readinessScore { result["readiness_score"] = readinessScore }
        if let sleepHours { result["sleep_hours"] = sleepHours }
        return result
    }

    @MainActor
    static func make(store: DataStore, timezone: String, now: Date = Date()) throws -> Self? {
        guard let zone = TimeZone(identifier: timezone),
              zone.secondsFromGMT(for: now) == TimeZone.current.secondsFromGMT(for: now) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let state = try store.fetchAppState()
        // Do not upload provisional history while its local repair is pending.
        guard !state.isComputationInProgress, !state.pendingWorkoutSourceFinalization,
              !LocalWorkoutHistoryRepair.isRequired(state) else { return nil }
        let start = TrainingReadiness.historyStart(for: now, calendar: calendar)
        let days = try store.fetchDayAggregates(from: start, to: now, calendar: calendar)
        let cutoff = calendar.date(byAdding: .day, value: -7, to: now)!
        let end = calendar.dateInterval(of: .day, for: now)?.end ?? now
        let workouts = try store.fetchWorkouts(startingAt: cutoff, before: end)
        let lastComputation = state.lastComputationDate
        let readiness = TodayReadiness(days: days, workouts: workouts, lastComputation: lastComputation, now: now, calendar: calendar)
        let score = readiness.updatedAt == nil ? nil : readiness.score
        let sleep = readiness.updatedAt == nil ? nil : readiness.day?.sleepDuration.flatMap {
            $0.isFinite && (0...24).contains($0) ? $0 : nil
        }
        let seconds = workouts.filter { $0.startTime <= now }
            .reduce(0.0) { sum, workout in
                sum + (workout.duration.isFinite && workout.duration > 0 ? min(workout.duration, 86400) : 0)
            }
        let minutes = Int(min(10080, seconds / 60))
        guard score != nil || sleep != nil || minutes > 0 else { return nil }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.calendar = calendar
        format.timeZone = zone
        format.dateFormat = "yyyy-MM-dd"
        return Self(summaryDate: format.string(from: now), timezone: timezone, generatedAt: now,
                    readinessScore: score, sleepHours: sleep, trainingMinutes7d: minutes)
    }
}

@MainActor
final class MorningSummarySync {
    private let api: any MorningStatusServing
    private let tokenStore: any MorningSessionStoring

    convenience init() {
        self.init(api: MorningStatusAPI(), tokenStore: MorningSessionKeychain())
    }

    init(api: any MorningStatusServing, tokenStore: any MorningSessionStoring) {
        self.api = api
        self.tokenStore = tokenStore
    }

    func sync(store: DataStore) async {
        do {
            guard let token = try tokenStore.load() else { return }
            let status = try await api.fetchStatus(token: token)
            try Task.checkCancellation()
            guard status.canUploadSummary,
                  let summary = try MorningAppSummary.make(store: store, timezone: status.timezone) else { return }
            _ = try await api.uploadSummary(summary, token: token)
        } catch {
            // Foreground sync is best effort. The native morning screen shows
            // the last server acknowledgement and provides an explicit retry.
        }
    }

    nonisolated deinit {}
}
