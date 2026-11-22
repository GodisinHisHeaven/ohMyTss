import Foundation
import SwiftData

/// All windows end at the assessment date. Each local day gets one vote in a baseline.
@MainActor
enum TrainingReadiness {
    static let baselineDays = 30
    static let minimumBaselineDays = 7

    struct Assessment {
        var score: Int?
        var basis: String
        var isPartial = false
        var limitingFactor: String?
        var hrvModifier: Double?
        var rhrModifier: Double?
    }

    static func historyStart(for date: Date, calendar: Calendar) -> Date {
        calendar.date(byAdding: .day, value: -baselineDays, to: calendar.startOfDay(for: date))!
    }

    static func workoutQuery(from firstDay: Date, before end: Date, calendar: Calendar) -> FetchDescriptor<Workout> {
        let start = calendar.date(byAdding: .day, value: -3, to: calendar.startOfDay(for: firstDay))!
        var query = FetchDescriptor<Workout>(predicate: #Predicate {
            $0.startTime >= start && $0.startTime < end && !$0.isTombstoned && !$0.isSuppressed
        })
        // Keep dense sensor payloads off the history chart's read path.
        query.propertiesToFetch = [\.startTime, \.duration, \.tss, \.isTombstoned, \.isSuppressed]
        return query
    }

    static func dailyScores(_ rows: [DayAggregate], workouts: [Workout]? = nil, from firstDay: Date,
                            asOf now: Date, calendar: Calendar) -> [DayScore] {
        let history = DayAggregate.byLocalDay(rows, calendar: calendar)
        let sessions = workouts.map { Dictionary(grouping: $0) { calendar.startOfDay(for: $0.startTime) } }
        return history.values.filter { $0.date >= firstDay }.compactMap { day -> DayScore? in
            assess(day, history: history, workoutsByDay: sessions, asOf: now, calendar: calendar).score.map {
                DayScore(date: day.date, score: $0)
            }
        }.sorted { $0.date < $1.date }
    }

    static func assess(_ row: DayAggregate, history: [Date: DayAggregate], workoutsByDay: [Date: [Workout]]? = nil, asOf now: Date,
                       calendar: Calendar) -> Assessment {
        let day = calendar.startOfDay(for: row.date)
        let training = [row.ctl, row.atl, row.totalTSS].contains { $0.isFinite && $0 > 0 }
        let empty = Assessment(basis: training
            ? "Training load is available. Sleep or a personal heart baseline is needed for readiness."
            : "Sync sleep or heart measurements to see your readiness.")
        let hours = sleepHours(row.sleepDuration)
        guard day <= now, hours != nil || positive(row.avgHRV) != nil
                || positive(row.overnightHRV) != nil || positive(row.avgRHR) != nil else { return empty }

        var past: [DayAggregate] = []
        var recentNights: [DayAggregate] = []
        var recentTraining: [(Date, DayAggregate?)] = [(day, row)]
        var date = day
        for offset in 1...baselineDays {
            date = calendar.date(byAdding: .day, value: -1, to: date)!
            if offset <= 3 { recentTraining.append((date, history[date])) }
            guard let previous = history[date] else { continue }
            past.append(previous)
            if offset <= 2 { recentNights.append(previous) }
        }

        func modifier(_ key: KeyPath<DayAggregate, Double?>,
                      using calculate: (Double, Double) -> Double) -> Double? {
            guard let value = positive(row[keyPath: key]),
                  let baseline = median(past.compactMap { positive($0[keyPath: key]) }) else { return nil }
            return calculate(value, baseline)
        }
        let nightHRV = modifier(\.overnightHRV, using: PhysiologyModifier.calculateHRVModifier)
        let hrv = nightHRV ?? modifier(\.avgHRV, using: PhysiologyModifier.calculateHRVModifier)
        let rhr = modifier(\.avgRHR, using: PhysiologyModifier.calculateRHRModifier)
        let heart = [hrv, rhr].compactMap { $0 }.min()
        guard hours != nil || heart != nil else { return empty }

        // Starting weights are product heuristics. A light training week adds no recovery credit.
        var score = 85 + max(0, heart ?? 0) * 0.75
        var penalties: [(reason: String, points: Double)] = []
        var inputs: [String] = []
        let awakeMinutes = row.recordedAwakeMinutes.flatMap { $0.isFinite && (0...1440).contains($0) ? $0 : nil }
        if let hours {
            let usual = median(past.compactMap { $0.recordedAwakeMinutes == nil ? nil : sleepHours($0.sleepDuration) }) ?? 8
            let target = min(9, max(7, usual))
            let shortSleep = min(52, max(0, target - hours) * 12)
            let interruptedSleep = min(20, max(0, (awakeMinutes ?? 0) - 20) / 4)
            penalties.append(interruptedSleep > shortSleep ? ("Interrupted sleep last night", interruptedSleep)
                             : ("Short sleep last night", shortSleep))
            let previousNights = recentNights.compactMap { sleepHours($0.sleepDuration) }
            let debt = previousNights.reduce(0.0) { $0 + min(4, max(0, target - $1)) }
            penalties.append(("Short sleep on previous nights", debt * 2))
            inputs.append(previousNights.isEmpty ? "last night's sleep" : "recent sleep")
        }
        if hrv != nil { inputs.append(nightHRV != nil ? "overnight HRV" : "daily HRV") }
        if rhr != nil { inputs.append("resting HR") }
        if let heart, heart < 0 {
            let reason = heart == hrv ? "HRV below your baseline" : "Resting HR above your baseline"
            penalties.append((reason, -heart * 1.8))
        }

        let cutoff = min(now, calendar.dateInterval(of: .day, for: day)!.end)
        let workout = recentTrainingEffect(row, recent: recentTraining, workoutsByDay: workoutsByDay, at: cutoff, calendar: calendar)
        // Exclude unfinished sessions already included in the day's ATL/CTL rollup.
        let balance = row.tsb + workout.pendingTSS * (1 / Constants.atlTimeConstant - 1 / Constants.ctlTimeConstant)
        let loadPenalty = training && balance.isFinite ? min(32, max(0, -balance) * 0.8) : 0
        // Recent workouts are already part of TSB. Charge the larger of the two effects once.
        penalties.append(workout.penalty > loadPenalty ? ("Recent hard training", workout.penalty)
                         : ("Elevated training load", loadPenalty))
        if training || workout.penalty > 0 { inputs.append("training load") }
        score -= penalties.reduce(0) { $0 + $1.points }
        let limitingFactor = penalties.filter { $0.points >= 1 }.max { $0.points < $1.points }?.reason
        // Older saved durations could include time in bed. A verified asleep session is needed for High.
        let partial = hours == nil || awakeMinutes == nil || heart == nil
        if partial { score = min(score, 69) }
        return Assessment(score: Int(min(100, max(0, score)).rounded()),
                          basis: (partial ? "Partial estimate from " : "Based on ") + inputs.joined(separator: " · "),
                          isPartial: partial, limitingFactor: limitingFactor, hrvModifier: hrv, rhrModifier: rhr)
    }

    private static func recentTrainingEffect(_ today: DayAggregate, recent: [(Date, DayAggregate?)], workoutsByDay: [Date: [Workout]]?,
                                             at cutoff: Date, calendar: Calendar) -> (penalty: Double, pendingTSS: Double) {
        var remaining = 0.0
        var pendingTSS = 0.0
        for (date, day) in recent {
            let reference = max(60, (positive(day?.ctl) ?? positive(today.ctl) ?? 0) * 1.5)
            func recoveryHours(tss: Double, duration: Double?) -> Double {
                guard tss.isFinite, tss > 0 else { return 0 }
                var hours = max(0, tss - reference) * 0.55
                if let duration, duration.isFinite, duration >= 900 {
                    // TSS per hour also captures short, demanding sessions.
                    hours = max(hours, (tss - 65 * duration / 3600) * 0.8)
                }
                return min(48, hours)
            }
            let sessions = workoutsByDay.map { $0[date] ?? [] } ?? day?.workouts ?? []
            if day?.hasWorkoutDetails == true || !sessions.isEmpty {
                for workout in sessions where !workout.isSuppressed && !workout.isTombstoned {
                    guard workout.duration.isFinite, workout.duration >= 0 else { continue }
                    let end = workout.startTime.addingTimeInterval(workout.duration)
                    guard end <= cutoff else {
                        if day === today, today.hasWorkoutDetails { pendingTSS += positive(workout.tss) ?? 0 }
                        continue
                    }
                    let hours = recoveryHours(tss: workout.tss, duration: workout.duration)
                    remaining = max(remaining, hours - cutoff.timeIntervalSince(end) / 3600)
                }
            } else if let day {
                // Aggregate-only imports have day precision and no trustworthy session intensity.
                let age = calendar.dateComponents([.day], from: calendar.startOfDay(for: day.date),
                                                  to: calendar.startOfDay(for: today.date)).day ?? 0
                let tss = day.maxTSSWorkout ?? day.totalTSS / Double(max(1, day.workoutCount))
                remaining = max(remaining, recoveryHours(tss: tss, duration: nil) - Double(age) * 24)
            }
        }
        return (min(38, remaining * 0.9), pendingTSS)
    }

    private static func positive(_ value: Double?) -> Double? {
        value.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }

    static func sleepHours(_ value: Double?) -> Double? {
        positive(value).flatMap { $0 <= 24 ? $0 : nil }
    }

    private static func median(_ values: [Double]) -> Double? {
        guard values.count >= minimumBaselineDays else { return nil }
        let sorted = values.sorted(), middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? sorted[middle - 1] / 2 + sorted[middle] / 2 : sorted[middle]
    }
}
