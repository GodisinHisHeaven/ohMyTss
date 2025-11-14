//
//  SleepAnalyzer.swift
//  onMyTss
//
//  Created by Claude Code
//

import Foundation
import HealthKit

/// Analyzes sleep data and calculates sleep quality metrics
struct SleepAnalyzer {

    // MARK: - Sleep Quality Calculation

    /// Calculate sleep quality score (0-100) from HealthKit sleep samples
    /// Based on Garmin Body Battery model: sleep is primary recharge mechanism
    static func calculateSleepQuality(from samples: [HKCategorySample]) -> SleepQuality? {
        guard !samples.isEmpty else { return nil }

        // Group samples by sleep session (continuous sleep periods)
        let sleepSessions = groupIntoSessions(samples)

        guard let mainSession = sleepSessions.max(by: { $0.duration < $1.duration }) else {
            return nil
        }

        // Calculate duration score (0-40 points)
        let durationScore = calculateDurationScore(mainSession.duration)

        // Calculate consistency score (0-30 points)
        let consistencyScore = calculateConsistencyScore(mainSession)

        // Calculate deep sleep score (0-30 points)
        let deepSleepScore = calculateDeepSleepScore(mainSession)

        // Total quality score (0-100)
        let totalScore = durationScore + consistencyScore + deepSleepScore

        return SleepQuality(
            totalDuration: mainSession.duration,
            deepSleepDuration: mainSession.deepDuration,
            remDuration: mainSession.remDuration,
            awakeTime: mainSession.awakeDuration,
            qualityScore: Int(totalScore.clamped(to: 0...100)),
            startTime: mainSession.startDate,
            endTime: mainSession.endDate
        )
    }

    // MARK: - Private Helper Methods

    /// Group sleep samples into continuous sessions
    private static func groupIntoSessions(_ samples: [HKCategorySample]) -> [SleepSession] {
        var sessions: [SleepSession] = []
        var currentSession: SleepSession?

        let sortedSamples = samples.sorted { $0.startDate < $1.startDate }

        for sample in sortedSamples {
            // Check if this sample is part of current session (within 2 hours)
            if let session = currentSession,
               sample.startDate.timeIntervalSince(session.endDate) < 2 * 3600 {
                // Extend current session
                currentSession = extendSession(session, with: sample)
            } else {
                // Save previous session and start new one
                if let session = currentSession {
                    sessions.append(session)
                }
                currentSession = SleepSession(from: sample)
            }
        }

        // Add final session
        if let session = currentSession {
            sessions.append(session)
        }

        return sessions
    }

    /// Extend a sleep session with a new sample
    private static func extendSession(_ session: SleepSession, with sample: HKCategorySample) -> SleepSession {
        var updated = session
        updated.endDate = max(session.endDate, sample.endDate)
        updated.duration = updated.endDate.timeIntervalSince(updated.startDate)

        // Add stage durations
        let sampleDuration = sample.endDate.timeIntervalSince(sample.startDate)

        switch sample.value {
        case HKCategoryValueSleepAnalysis.asleepDeep.rawValue:
            updated.deepDuration += sampleDuration
        case HKCategoryValueSleepAnalysis.asleepREM.rawValue:
            updated.remDuration += sampleDuration
        case HKCategoryValueSleepAnalysis.awake.rawValue:
            updated.awakeDuration += sampleDuration
        default:
            break
        }

        return updated
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
    private static func calculateConsistencyScore(_ session: SleepSession) -> Double {
        // Calculate interruption ratio
        let totalSleep = session.deepDuration + session.remDuration
        let awakeDuring = session.awakeDuration

        guard session.duration > 0 else { return 0 }

        let awakeRatio = awakeDuring / session.duration

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
    private static func calculateDeepSleepScore(_ session: SleepSession) -> Double {
        guard session.duration > 0 else { return 0 }

        let deepRatio = session.deepDuration / session.duration

        // Optimal deep sleep: 15-25% of total sleep
        // Source: Sleep research guidelines

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

// MARK: - Sleep Session

private struct SleepSession {
    var startDate: Date
    var endDate: Date
    var duration: TimeInterval
    var deepDuration: TimeInterval = 0
    var remDuration: TimeInterval = 0
    var awakeDuration: TimeInterval = 0

    init(from sample: HKCategorySample) {
        self.startDate = sample.startDate
        self.endDate = sample.endDate
        self.duration = sample.endDate.timeIntervalSince(sample.startDate)

        let sampleDuration = self.duration

        switch sample.value {
        case HKCategoryValueSleepAnalysis.asleepDeep.rawValue:
            self.deepDuration = sampleDuration
        case HKCategoryValueSleepAnalysis.asleepREM.rawValue:
            self.remDuration = sampleDuration
        case HKCategoryValueSleepAnalysis.awake.rawValue:
            self.awakeDuration = sampleDuration
        default:
            break
        }
    }
}

// MARK: - Sleep Quality

struct SleepQuality {
    let totalDuration: TimeInterval // Total sleep duration in seconds
    let deepSleepDuration: TimeInterval // Deep sleep duration in seconds
    let remDuration: TimeInterval // REM sleep duration in seconds
    let awakeTime: TimeInterval // Time awake during sleep in seconds
    let qualityScore: Int // Sleep quality score (0-100)
    let startTime: Date // Sleep start time
    let endTime: Date // Sleep end time

    var durationHours: Double {
        totalDuration / 3600.0
    }

    var deepSleepHours: Double {
        deepSleepDuration / 3600.0
    }

    var remHours: Double {
        remDuration / 3600.0
    }

    var awakeMinutes: Double {
        awakeTime / 60.0
    }
}
