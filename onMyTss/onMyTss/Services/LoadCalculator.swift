//
//  LoadCalculator.swift
//  onMyTss
//
//  Created by Claude Code
//

import Foundation

/// Calculator for training load metrics (CTL, ATL, TSB)
/// Based on the Banister Impulse-Response model
struct LoadCalculator {

    // MARK: - Exponential Moving Average Calculation

    /// Calculate Chronic Training Load (CTL) - 42-day exponential moving average
    /// CTL represents fitness
    static func calculateCTL(tssHistory: [Double], previousCTL: Double = 0) -> Double {
        guard !tssHistory.isEmpty else { return previousCTL }

        let todayTSS = tssHistory.last ?? 0
        let newCTL = previousCTL + (1.0 / Constants.ctlTimeConstant) * (todayTSS - previousCTL)

        return max(0, newCTL.rounded(toPlaces: 2))
    }

    /// Calculate Acute Training Load (ATL) - 7-day exponential moving average
    /// ATL represents fatigue
    static func calculateATL(tssHistory: [Double], previousATL: Double = 0) -> Double {
        guard !tssHistory.isEmpty else { return previousATL }

        let todayTSS = tssHistory.last ?? 0
        let newATL = previousATL + (1.0 / Constants.atlTimeConstant) * (todayTSS - previousATL)

        return max(0, newATL.rounded(toPlaces: 2))
    }

    /// Calculate Training Stress Balance (TSB) - difference between CTL and ATL
    /// TSB represents form/freshness
    /// Positive TSB = fresh/rested, Negative TSB = fatigued
    static func calculateTSB(ctl: Double, atl: Double) -> Double {
        let tsb = ctl - atl
        return tsb.rounded(toPlaces: 2)
    }

    // MARK: - Time Series Calculation

    /// Calculate CTL, ATL, and TSB for a series of TSS values
    /// Returns array of (CTL, ATL, TSB) tuples for each day
    static func calculateTimeSeries(tssValues: [Double]) -> [(ctl: Double, atl: Double, tsb: Double)] {
        guard !tssValues.isEmpty else { return [] }

        var results: [(ctl: Double, atl: Double, tsb: Double)] = []
        var currentCTL: Double = 0
        var currentATL: Double = 0

        for tss in tssValues {
            // Update CTL and ATL with today's TSS
            currentCTL = calculateCTL(tssHistory: [tss], previousCTL: currentCTL)
            currentATL = calculateATL(tssHistory: [tss], previousATL: currentATL)

            // Calculate TSB
            let tsb = calculateTSB(ctl: currentCTL, atl: currentATL)

            results.append((ctl: currentCTL, atl: currentATL, tsb: tsb))
        }

        return results
    }

    // MARK: - Ramp Rate Calculation

    /// Calculate CTL ramp rate (change per week)
    /// Used to monitor training load progression and avoid overtraining
    static func calculateCTLRampRate(currentCTL: Double, ctlOneWeekAgo: Double) -> Double {
        let rampRate = currentCTL - ctlOneWeekAgo
        return rampRate.rounded(toPlaces: 2)
    }

    /// Check if CTL ramp rate is within safe limits
    static func isRampRateSafe(rampRate: Double) -> Bool {
        return rampRate <= Constants.maxSafeCTLRampRate
    }

    /// Get ramp rate status
    static func getRampRateStatus(rampRate: Double) -> RampRateStatus {
        if rampRate < 0 {
            return .detraining
        } else if rampRate <= Constants.recommendedCTLRampRate {
            return .safe
        } else if rampRate <= Constants.maxSafeCTLRampRate {
            return .aggressive
        } else {
            return .dangerous
        }
    }

    // MARK: - Initialization Calculation

    /// Initialize CTL/ATL from historical TSS data
    /// Uses exponential moving average calculation starting from zero
    static func initializeLoadMetrics(historicalTSS: [Double]) -> (ctl: Double, atl: Double, tsb: Double) {
        guard !historicalTSS.isEmpty else {
            return (ctl: 0, atl: 0, tsb: 0)
        }

        // Calculate the time series to get final values
        let timeSeries = calculateTimeSeries(tssValues: historicalTSS)

        if let last = timeSeries.last {
            return last
        }

        return (ctl: 0, atl: 0, tsb: 0)
    }

    /// Calculate load metrics for a specific date given all prior history
    static func calculateLoadMetrics(
        tssHistory: [Double],
        includeToday: Bool = true
    ) -> (ctl: Double, atl: Double, tsb: Double) {
        if includeToday {
            return initializeLoadMetrics(historicalTSS: tssHistory)
        } else {
            // Exclude today's TSS
            let historyWithoutToday = Array(tssHistory.dropLast())
            return initializeLoadMetrics(historicalTSS: historyWithoutToday)
        }
    }
}

// MARK: - Ramp Rate Status

enum RampRateStatus: String {
    case detraining = "Detraining"
    case safe = "Safe Progress"
    case aggressive = "Aggressive"
    case dangerous = "Too Fast"

    var description: String {
        switch self {
        case .detraining:
            return "CTL is decreasing. Consider adding training load."
        case .safe:
            return "CTL ramp rate is within recommended range."
        case .aggressive:
            return "CTL ramp rate is high but manageable. Monitor recovery."
        case .dangerous:
            return "CTL ramp rate is too high. Risk of overtraining. Consider reducing load."
        }
    }

    var color: String {
        switch self {
        case .detraining:
            return "blue"
        case .safe:
            return "green"
        case .aggressive:
            return "yellow"
        case .dangerous:
            return "red"
        }
    }
}
