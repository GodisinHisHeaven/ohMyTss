//
//  GuidanceEngine.swift
//  onMyTss
//
//  Created by Claude Code
//

import Foundation

/// Engine for generating training guidance and recommendations
struct GuidanceEngine {

    // MARK: - Readiness Zone

    /// Determine the current readiness zone based on TSB
    static func getReadinessZone(tsb: Double) -> Constants.ReadinessZone {
        for zone in [
            Constants.ReadinessZone.buildIntensity,
            Constants.ReadinessZone.buildBase,
            Constants.ReadinessZone.maintain,
            Constants.ReadinessZone.deload,
            Constants.ReadinessZone.overreaching
        ] {
            if zone.tsbRange.contains(tsb) {
                return zone
            }
        }

        // Default to overreaching if TSB is extremely negative
        if tsb < -50 {
            return .overreaching
        }

        // Default to build intensity if TSB is extremely positive
        return .buildIntensity
    }

    // MARK: - TSS Recommendations

    /// Get recommended TSS range for today based on readiness
    static func getRecommendedTSSRange(
        bodyBatteryScore: Int,
        tsb: Double,
        ctl: Double
    ) -> TSSRecommendation {
        let zone = getReadinessZone(tsb: tsb)

        switch zone {
        case .overreaching:
            // Very fatigued - minimal training
            return TSSRecommendation(
                min: 0,
                max: Int(ctl * 0.3),
                optimal: Int(ctl * 0.15),
                description: "Focus on recovery. Very light activity only.",
                intensity: .recovery
            )

        case .deload:
            // Fatigued - easy training
            return TSSRecommendation(
                min: Int(ctl * 0.3),
                max: Int(ctl * 0.6),
                optimal: Int(ctl * 0.45),
                description: "Easy recovery rides/runs recommended.",
                intensity: .endurance
            )

        case .maintain:
            // Balanced - moderate training
            return TSSRecommendation(
                min: Int(ctl * 0.6),
                max: Int(ctl * 1.0),
                optimal: Int(ctl * 0.8),
                description: "Moderate training to maintain fitness.",
                intensity: .tempo
            )

        case .buildBase:
            // Fresh - good for building
            return TSSRecommendation(
                min: Int(ctl * 0.8),
                max: Int(ctl * 1.3),
                optimal: Int(ctl * 1.1),
                description: "Good day for base building endurance work.",
                intensity: .endurance
            )

        case .buildIntensity:
            // Very fresh - ready for hard work
            return TSSRecommendation(
                min: Int(ctl * 1.0),
                max: Int(ctl * 1.5),
                optimal: Int(ctl * 1.25),
                description: "Perfect for high-intensity or long workouts.",
                intensity: .threshold
            )
        }
    }

    /// Get training suggestions based on current metrics
    static func getTrainingSuggestions(
        bodyBatteryScore: Int,
        tsb: Double,
        ctl: Double,
        atl: Double,
        rampRate: Double?,
        recentTSS: [Double]
    ) -> [String] {
        var suggestions: [String] = []

        let zone = getReadinessZone(tsb: tsb)
        let tssRec = getRecommendedTSSRange(bodyBatteryScore: bodyBatteryScore, tsb: tsb, ctl: ctl)

        // Primary suggestion based on zone
        suggestions.append(zone.description)

        // TSS recommendation
        if tssRec.optimal > 0 {
            suggestions.append("Target TSS: ~\(tssRec.optimal) (\(tssRec.intensity.rawValue))")
        }

        // Ramp rate warnings
        if let rampRate = rampRate {
            let status = LoadCalculator.getRampRateStatus(rampRate: rampRate)
            if status == .dangerous {
                suggestions.append("⚠️ CTL increasing too fast. Consider a recovery week.")
            } else if status == .aggressive {
                suggestions.append("⚡ CTL increasing rapidly. Monitor recovery closely.")
            } else if status == .detraining {
                suggestions.append("📉 CTL is decreasing. Consider adding volume if intentional taper is complete.")
            }
        }

        // Pattern detection in recent TSS
        if recentTSS.count >= 7 {
            let lastSevenDays = Array(recentTSS.suffix(7))
            let highTSSDays = lastSevenDays.filter { $0 > ctl * 1.2 }.count

            if highTSSDays >= 4 {
                suggestions.append("🔥 Multiple high TSS days recently. Schedule recovery soon.")
            }

            let veryLowTSSDays = lastSevenDays.filter { $0 < ctl * 0.3 }.count
            if veryLowTSSDays >= 3 && zone != .overreaching {
                suggestions.append("💤 Low recent training volume. Gradually increase if not in taper.")
            }
        }

        // Fitness level guidance
        if ctl < 40 {
            suggestions.append("🌱 Building base fitness. Focus on consistent, moderate volume.")
        } else if ctl > 100 {
            suggestions.append("🏆 High fitness level. Maintain with smart periodization.")
        }

        // Form guidance
        if tsb > 10 {
            suggestions.append("✨ High form. Good time for race efforts or breakthrough workouts.")
        } else if tsb < -20 {
            suggestions.append("🛌 Significant fatigue. Prioritize sleep and nutrition.")
        }

        return suggestions
    }

    // MARK: - Weekly Planning

    /// Generate a weekly training plan based on current metrics
    static func getWeeklyPlan(
        ctl: Double,
        atl: Double,
        tsb: Double,
        targetWeeklyTSS: Double?
    ) -> WeeklyPlan {
        let zone = getReadinessZone(tsb: tsb)

        // Calculate suggested weekly TSS if not provided
        let weeklyTSS = targetWeeklyTSS ?? (ctl * 7.0)

        // Distribute TSS across the week based on readiness
        let dailyTSS: [Double]

        switch zone {
        case .overreaching:
            // Recovery week - very low volume
            dailyTSS = [
                ctl * 0.2, // Monday - easy
                ctl * 0.1, // Tuesday - very easy
                ctl * 0.3, // Wednesday - light
                0,         // Thursday - rest
                ctl * 0.2, // Friday - easy
                ctl * 0.3, // Saturday - light
                0          // Sunday - rest
            ]

        case .deload:
            // Light week
            dailyTSS = [
                ctl * 0.5, // Monday
                ctl * 0.3, // Tuesday
                ctl * 0.6, // Wednesday
                ctl * 0.3, // Thursday
                0,         // Friday - rest
                ctl * 0.7, // Saturday
                ctl * 0.4  // Sunday
            ]

        case .maintain, .buildBase, .buildIntensity:
            // Normal training week with harder weekend
            dailyTSS = [
                ctl * 0.8,  // Monday
                ctl * 0.6,  // Tuesday
                ctl * 1.0,  // Wednesday - harder
                ctl * 0.6,  // Thursday
                ctl * 0.5,  // Friday - pre-weekend easy
                ctl * 1.3,  // Saturday - key workout
                ctl * 1.0   // Sunday - long
            ]
        }

        return WeeklyPlan(
            totalTSS: dailyTSS.reduce(0, +),
            dailyTSS: dailyTSS,
            primaryFocus: zone.rawValue,
            restDays: zone == .overreaching ? 2 : 1
        )
    }
}

// MARK: - TSS Recommendation

struct TSSRecommendation {
    let min: Int
    let max: Int
    let optimal: Int
    let description: String
    let intensity: Constants.TSSIntensity
}

// MARK: - Weekly Plan

struct WeeklyPlan {
    let totalTSS: Double
    let dailyTSS: [Double] // 7 days, Monday to Sunday
    let primaryFocus: String
    let restDays: Int

    var averageDailyTSS: Double {
        totalTSS / 7.0
    }
}
