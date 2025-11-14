//
//  BodyBatteryCalculator.swift
//  onMyTss
//
//  Created by Claude Code
//

import Foundation

/// Calculator for Body Battery score (0-100 scale)
/// Converts Training Stress Balance (TSB) to an intuitive readiness score
struct BodyBatteryCalculator {

    // MARK: - Score Calculation

    /// Convert TSB to Body Battery score (0-100)
    /// TSB typically ranges from -50 (very fatigued) to +30 (very fresh)
    /// We map this to 0-100 scale with 50 as neutral (TSB = 0)
    ///
    /// Mapping:
    /// TSB = -35 or lower → Score = 0 (completely depleted)
    /// TSB = 0 → Score = 50 (neutral)
    /// TSB = +25 or higher → Score = 100 (fully charged)
    static func calculateScore(from tsb: Double) -> Int {
        // Linear interpolation between TSB ranges
        let score: Double

        if tsb <= Constants.tsbForMinScore {
            // Very fatigued - score is 0
            score = 0
        } else if tsb >= Constants.tsbForMaxScore {
            // Very fresh - score is 100
            score = 100
        } else {
            // Linear mapping from TSB to 0-100 scale
            // Formula: score = ((TSB - minTSB) / (maxTSB - minTSB)) × 100
            let tsbRange = Constants.tsbForMaxScore - Constants.tsbForMinScore
            let normalizedTSB = tsb - Constants.tsbForMinScore
            score = (normalizedTSB / tsbRange) * 100
        }

        // Clamp to 0-100 and round to integer
        return Int(score.clamped(to: 0...100))
    }

    /// Calculate score with HRV/RHR modifiers applied
    /// Combines base TSB score with physiological recovery signals
    static func calculateScoreWithModifiers(
        tsb: Double,
        hrvModifier: Double? = nil,
        rhrModifier: Double? = nil
    ) -> Int {
        let baseScore = Double(calculateScore(from: tsb))

        // Calculate combined modifier from HRV and RHR
        let combinedModifier = PhysiologyModifier.calculateCombinedModifier(
            hrvModifier: hrvModifier,
            rhrModifier: rhrModifier
        )

        // Apply modifier to base score and clamp to 0-100
        let modifiedScore = (baseScore + combinedModifier).clamped(to: 0...100)

        return Int(modifiedScore)
    }

    // MARK: - Score Interpretation

    /// Get readiness level based on score
    static func getReadinessLevel(score: Int) -> ReadinessLevel {
        switch score {
        case 0..<20:
            return .veryLow
        case 20..<40:
            return .low
        case 40..<60:
            return .medium
        case 60..<80:
            return .good
        default:
            return .excellent
        }
    }

    /// Get score change description
    static func getScoreChangeDescription(previousScore: Int, currentScore: Int) -> String {
        let change = currentScore - previousScore

        if change > 10 {
            return "↑ Significantly improved (+\(change))"
        } else if change > 3 {
            return "↑ Improved (+\(change))"
        } else if change > 0 {
            return "→ Slightly improved (+\(change))"
        } else if change == 0 {
            return "→ No change"
        } else if change > -3 {
            return "→ Slightly decreased (\(change))"
        } else if change > -10 {
            return "↓ Decreased (\(change))"
        } else {
            return "↓ Significantly decreased (\(change))"
        }
    }

    // MARK: - Trend Analysis

    /// Calculate trend over last N days
    static func calculateTrend(scores: [Int]) -> Trend {
        guard scores.count >= 3 else { return .stable }

        // Calculate simple linear regression slope
        let n = Double(scores.count)
        let x = Array(0..<scores.count).map { Double($0) }
        let y = scores.map { Double($0) }

        let sumX = x.reduce(0, +)
        let sumY = y.reduce(0, +)
        let sumXY = zip(x, y).map(*).reduce(0, +)
        let sumX2 = x.map { $0 * $0 }.reduce(0, +)

        let slope = (n * sumXY - sumX * sumY) / (n * sumX2 - sumX * sumX)

        // Interpret slope
        if slope > 2.0 {
            return .improvingFast
        } else if slope > 0.5 {
            return .improving
        } else if slope < -2.0 {
            return .decliningFast
        } else if slope < -0.5 {
            return .declining
        } else {
            return .stable
        }
    }
}

// MARK: - Readiness Level

enum ReadinessLevel: String {
    case veryLow = "Very Low"
    case low = "Low"
    case medium = "Medium"
    case good = "Good"
    case excellent = "Excellent"

    var description: String {
        switch self {
        case .veryLow:
            return "Severely fatigued. Rest is critical."
        case .low:
            return "Fatigued. Focus on recovery."
        case .medium:
            return "Moderate readiness. Light training okay."
        case .good:
            return "Good readiness for training."
        case .excellent:
            return "Excellent! Ready for hard efforts."
        }
    }

    var emoji: String {
        switch self {
        case .veryLow:
            return "😴"
        case .low:
            return "😓"
        case .medium:
            return "😐"
        case .good:
            return "🙂"
        case .excellent:
            return "💪"
        }
    }
}

// MARK: - Trend

enum Trend: String {
    case improvingFast = "Rapidly Improving"
    case improving = "Improving"
    case stable = "Stable"
    case declining = "Declining"
    case decliningFast = "Rapidly Declining"

    var description: String {
        switch self {
        case .improvingFast:
            return "Your readiness is rapidly improving."
        case .improving:
            return "Your readiness is steadily improving."
        case .stable:
            return "Your readiness is stable."
        case .declining:
            return "Your readiness is declining."
        case .decliningFast:
            return "Your readiness is declining rapidly. Consider more recovery."
        }
    }

    var arrow: String {
        switch self {
        case .improvingFast:
            return "⬆️⬆️"
        case .improving:
            return "⬆️"
        case .stable:
            return "→"
        case .declining:
            return "⬇️"
        case .decliningFast:
            return "⬇️⬇️"
        }
    }
}
