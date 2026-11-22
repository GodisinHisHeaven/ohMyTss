import Foundation
import HealthKit

nonisolated enum SleepAnalyzer {
    /// Merge overlapping asleep records before choosing the longest session ending on each local day.
    static func nights(from samples: [HKCategorySample], calendar: Calendar) -> [Date: SleepQuality] {
        let ordered = samples.filter { $0.endDate > $0.startDate }.sorted { $0.startDate < $1.startDate }
        var awake: [DateInterval] = []
        for sample in ordered where sample.value == HKCategoryValueSleepAnalysis.awake.rawValue {
            Session.merge(DateInterval(start: sample.startDate, end: sample.endDate), into: &awake)
        }
        let asleep = ordered.filter { sample in
            switch HKCategoryValueSleepAnalysis(rawValue: sample.value) {
            case .asleepUnspecified, .asleepCore, .asleepDeep, .asleepREM: return true
            default: return false
            }
        }
        var nights: [Date: SleepQuality] = [:]
        var session = Session()
        var wakeIndex = 0

        func finish() {
            // Overlapping devices may report the same interval as both asleep and awake.
            // Only count recorded wake that falls in a gap between actual asleep intervals.
            var seconds = 0.0
            for (left, right) in zip(session.asleep, session.asleep.dropFirst()) {
                while wakeIndex < awake.count, awake[wakeIndex].end <= left.end { wakeIndex += 1 }
                var i = wakeIndex
                while i < awake.count, awake[i].start < right.start {
                    seconds += min(awake[i].end, right.start).timeIntervalSince(max(awake[i].start, left.end))
                    i += 1
                }
            }
            guard let night = session.quality(awakeSeconds: seconds) else { return }
            let day = calendar.startOfDay(for: night.endTime)
            if night.totalDuration > (nights[day]?.totalDuration ?? 0) { nights[day] = night }
        }
        for sample in asleep {
            if let last = session.asleep.last, sample.startDate.timeIntervalSince(last.end) >= 2 * 3600 {
                finish()
                session = Session()
            }
            session.append(sample)
        }
        finish()
        return nights
    }

    private struct Session {
        var asleep: [DateInterval] = []
        var deep: [DateInterval] = []

        mutating func append(_ sample: HKCategorySample) {
            let interval = DateInterval(start: sample.startDate, end: sample.endDate)
            Self.merge(interval, into: &asleep)
            if sample.value == HKCategoryValueSleepAnalysis.asleepDeep.rawValue {
                Self.merge(interval, into: &deep)
            }
        }

        static func merge(_ next: DateInterval, into intervals: inout [DateInterval]) {
            if let last = intervals.last, next.start <= last.end {
                if next.end > last.end { intervals[intervals.count - 1].end = next.end }
            } else {
                intervals.append(next)
            }
        }

        func quality(awakeSeconds: Double) -> SleepQuality? {
            guard let start = asleep.first?.start, let end = asleep.last?.end else { return nil }
            let duration = asleep.reduce(0) { $0 + $1.duration }
            let elapsed = end.timeIntervalSince(start)
            guard duration > 0, elapsed <= 24 * 3600 else { return nil }
            let deepDuration = deep.reduce(0) { $0 + $1.duration }
            let score = SleepAnalyzer.calculateDurationScore(duration)
                + SleepAnalyzer.calculateConsistencyScore(awakeRatio: awakeSeconds / elapsed)
                + SleepAnalyzer.calculateDeepSleepScore(deepRatio: deepDuration / duration)
            return SleepQuality(totalDuration: duration, deepSleepDuration: deepDuration,
                                awakeMinutes: awakeSeconds / 60, qualityScore: Int(min(100, max(0, score))),
                                endTime: end, asleepIntervals: asleep)
        }
    }

    /// Calculate duration score (0-40 points)
    /// Optimal: 7-9 hours = 40 points
    /// 6-7 or 9-10 hours = 30 points
    /// < 6 or > 10 hours = scaled down
    private static func calculateDurationScore(_ duration: TimeInterval) -> Double {
        let hours = duration / 3600.0

        if hours >= 7 && hours <= 9 {
            return 40.0 // Optimal duration
        } else if hours >= 6 && hours < 7 {
            return 30.0 + (hours - 6) * 10 // 30-40 points
        } else if hours > 9 && hours <= 10 {
            return 40.0 - (hours - 9) * 10 // 40-30 points
        } else if hours > 5 && hours < 6 {
            return (hours - 5) * 30 // 0-30 points
        } else if hours > 10 && hours < 11 {
            return 30.0 - (hours - 10) * 30 // 30-0 points
        } else {
            return 0.0 // Too short or too long
        }
    }

    /// Calculate consistency score (0-30 points)
    /// Rewards uninterrupted sleep
    private static func calculateConsistencyScore(awakeRatio: Double) -> Double {
        // Score based on awake time
        // < 5% awake = 30 points
        // 5-10% awake = 20-30 points
        // 10-20% awake = 10-20 points
        // > 20% awake = 0-10 points

        if awakeRatio < 0.05 {
            return 30.0
        } else if awakeRatio < 0.10 {
            return 30.0 - (awakeRatio - 0.05) / 0.05 * 10 // 30-20 points
        } else if awakeRatio < 0.20 {
            return 20.0 - (awakeRatio - 0.10) / 0.10 * 10 // 20-10 points
        } else {
            return max(0, 10.0 - (awakeRatio - 0.20) / 0.10 * 10) // 10-0 points
        }
    }

    /// Calculate deep sleep score (0-30 points)
    /// Deep sleep is critical for physical recovery
    private static func calculateDeepSleepScore(deepRatio: Double) -> Double {
        if deepRatio >= 0.15 && deepRatio <= 0.25 {
            return 30.0 // Optimal deep sleep
        } else if deepRatio >= 0.10 && deepRatio < 0.15 {
            return (deepRatio - 0.10) / 0.05 * 30 // 0-30 points
        } else if deepRatio > 0.25 && deepRatio <= 0.30 {
            return 30.0 - (deepRatio - 0.25) / 0.05 * 15 // 30-15 points
        } else {
            return 0.0 // Too little or too much deep sleep
        }
    }
}

nonisolated struct SleepQuality: Sendable {
    let totalDuration: TimeInterval
    let deepSleepDuration: TimeInterval
    let awakeMinutes: Double
    let qualityScore: Int
    let endTime: Date
    let asleepIntervals: [DateInterval]

    var durationHours: Double { totalDuration / 3600 }
    var deepSleepHours: Double { deepSleepDuration / 3600 }
}
