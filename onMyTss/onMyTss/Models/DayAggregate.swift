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

    // Future: HRV and RHR modifiers (not in MVP)
    var hrvModifier: Double?
    var rhrModifier: Double?

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
        hrvModifier: Double? = nil,
        rhrModifier: Double? = nil
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
        self.hrvModifier = hrvModifier
        self.rhrModifier = rhrModifier
    }
}
