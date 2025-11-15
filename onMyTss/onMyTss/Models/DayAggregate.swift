//
//  DayAggregate.swift
//  onMyTss
//
//  Created by Claude Code
//

import Foundation
import SwiftData

@Model
final class DayAggregate {
    @Attribute(.unique) var date: Date
    var totalTSS: Double
    var ctl: Double // Chronic Training Load (42-day EMA)
    var atl: Double // Acute Training Load (7-day EMA)
    var tsb: Double // Training Stress Balance (CTL - ATL)
    var bodyBatteryScore: Int // 0-100 scale
    var rampRate: Double? // CTL week-over-week change
    var workoutCount: Int
    var maxTSSWorkout: Double?

    // Phase 1: HRV and RHR physiological data
    var avgHRV: Double? // Average HRV for the day (ms)
    var avgRHR: Double? // Average resting heart rate for the day (bpm)
    var hrvModifier: Double? // BB modifier from HRV (-20 to +20)
    var rhrModifier: Double? // BB modifier from RHR (-20 to +20)
    var illnessLikelihood: Double? // Illness detection score (0.0-1.0)

    // Sleep quality data
    var sleepDuration: Double? // Total sleep duration in hours
    var sleepQualityScore: Int? // Sleep quality score (0-100)
    var deepSleepDuration: Double? // Deep sleep duration in hours

    // MARK: - Relationships

    /// Individual workouts for this day
    @Relationship(deleteRule: .cascade, inverse: \Workout.dayAggregate)
    var workouts: [Workout] = []

    init(
        date: Date,
        totalTSS: Double = 0.0,
        ctl: Double = 0.0,
        atl: Double = 0.0,
        tsb: Double = 0.0,
        bodyBatteryScore: Int = 50,
        rampRate: Double? = nil,
        workoutCount: Int = 0,
        maxTSSWorkout: Double? = nil,
        avgHRV: Double? = nil,
        avgRHR: Double? = nil,
        hrvModifier: Double? = nil,
        rhrModifier: Double? = nil,
        illnessLikelihood: Double? = nil,
        sleepDuration: Double? = nil,
        sleepQualityScore: Int? = nil,
        deepSleepDuration: Double? = nil
    ) {
        self.date = date
        self.totalTSS = totalTSS
        self.ctl = ctl
        self.atl = atl
        self.tsb = tsb
        self.bodyBatteryScore = bodyBatteryScore
        self.rampRate = rampRate
        self.workoutCount = workoutCount
        self.maxTSSWorkout = maxTSSWorkout
        self.avgHRV = avgHRV
        self.avgRHR = avgRHR
        self.hrvModifier = hrvModifier
        self.rhrModifier = rhrModifier
        self.illnessLikelihood = illnessLikelihood
        self.sleepDuration = sleepDuration
        self.sleepQualityScore = sleepQualityScore
        self.deepSleepDuration = deepSleepDuration
    }
}
