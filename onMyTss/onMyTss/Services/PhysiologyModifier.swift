//
//  PhysiologyModifier.swift
//  onMyTss
//
//  Created by Claude Code
//

import Foundation

/// Calculates Body Battery modifiers based on physiological markers (HRV and RHR)
/// These modifiers adjust the base Body Battery score to account for recovery state
struct PhysiologyModifier {

    // MARK: - HRV Modifier Calculation

    /// Calculate Body Battery modifier from HRV deviation from baseline
    /// - Parameters:
    ///   - currentHRV: Today's average HRV (ms)
    ///   - baselineHRV: median of prior daily HRV values (ms)
    /// - Returns: Modifier value (-20 to +20)
    static func calculateHRVModifier(currentHRV: Double, baselineHRV: Double) -> Double {
        // HRV deviation as percentage
        let percentDeviation = ((currentHRV - baselineHRV) / baselineHRV) * 100.0

        // Apply non-linear scaling:
        // +30% deviation = +20 modifier (excellent recovery)
        // +15% deviation = +10 modifier (good recovery)
        // -15% deviation = -10 modifier (poor recovery)
        // -30% deviation = -20 modifier (very poor recovery/illness)

        let modifier: Double

        if percentDeviation >= 30 {
            modifier = 20.0
        } else if percentDeviation >= 15 {
            modifier = percentDeviation / 1.5 // 15% → +10, 30% → +20
        } else if percentDeviation >= -15 {
            modifier = percentDeviation / 2.0 // -15% → -7.5, +15% → +7.5
        } else if percentDeviation >= -30 {
            modifier = percentDeviation / 1.5 // -30% → -20, -15% → -10
        } else {
            modifier = -20.0
        }

        return modifier.clamped(to: -20...20)
    }

    // MARK: - RHR Modifier Calculation

    /// Calculate Body Battery modifier from RHR deviation from baseline
    /// - Parameters:
    ///   - currentRHR: Today's resting heart rate (bpm)
    ///   - baselineRHR: median of prior daily resting heart rates (bpm)
    /// - Returns: Modifier value (-20 to +20)
    static func calculateRHRModifier(currentRHR: Double, baselineRHR: Double) -> Double {
        // RHR deviation (note: LOWER is better for recovery)
        let deviationBPM = currentRHR - baselineRHR

        // Apply non-linear scaling:
        // -5 bpm = +20 modifier (excellent recovery)
        // -2 bpm = +10 modifier (good recovery)
        // +2 bpm = -10 modifier (poor recovery)
        // +5 bpm = -20 modifier (very poor recovery/illness)

        let modifier: Double

        if deviationBPM <= -5 {
            modifier = 20.0
        } else if deviationBPM <= -2 {
            modifier = -deviationBPM * 4.0 // -2 → +8, -5 → +20
        } else if deviationBPM <= 2 {
            modifier = -deviationBPM * 3.0 // -2 → +6, +2 → -6
        } else if deviationBPM <= 5 {
            modifier = -deviationBPM * 4.0 // +2 → -8, +5 → -20
        } else {
            modifier = -20.0
        }

        return modifier.clamped(to: -20...20)
    }

    // MARK: - Combined Modifier

    /// Calculate combined BB modifier from both HRV and RHR
    /// - Parameters:
    ///   - hrvModifier: HRV-based modifier
    ///   - rhrModifier: RHR-based modifier
    /// - Returns: Combined modifier (-20 to +20)
    static func calculateCombinedModifier(hrvModifier: Double?, rhrModifier: Double?) -> Double {
        // Weight HRV more heavily (70%) as it's typically more sensitive to recovery
        let hrvWeight = 0.7
        let rhrWeight = 0.3

        switch (hrvModifier, rhrModifier) {
        case (.some(let hrv), .some(let rhr)):
            // Both available: weighted average
            return (hrv * hrvWeight + rhr * rhrWeight).clamped(to: -20...20)

        case (.some(let hrv), .none):
            // Only HRV available
            return hrv.clamped(to: -20...20)

        case (.none, .some(let rhr)):
            // Only RHR available
            return rhr.clamped(to: -20...20)

        case (.none, .none):
            // No physiological data available
            return 0.0
        }
    }

    // MARK: - Illness Detection

    /// Detect potential illness from combined HRV/RHR signals
    /// - Parameters:
    ///   - hrvModifier: Current HRV modifier
    ///   - rhrModifier: Current RHR modifier
    /// - Returns: Illness likelihood (0.0-1.0)
    static func detectIllness(hrvModifier: Double?, rhrModifier: Double?) -> Double {
        guard let hrv = hrvModifier, let rhr = rhrModifier else {
            return 0.0
        }

        // Strong illness signal: both HRV very low AND RHR very high
        if hrv <= -15 && rhr <= -15 {
            return 1.0 // Very likely illness
        } else if hrv <= -10 && rhr <= -10 {
            return 0.7 // Likely illness or overtraining
        } else if hrv <= -5 || rhr <= -5 {
            return 0.3 // Possible poor recovery
        } else {
            return 0.0 // No illness signal
        }
    }
}
