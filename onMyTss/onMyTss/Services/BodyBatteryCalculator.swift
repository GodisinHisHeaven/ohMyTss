//
//  BodyBatteryCalculator.swift
//  onMyTss
//
//  Created by Claude Code
//

import Foundation

/// Presentation of saved readiness levels and trends.
struct BodyBatteryCalculator {
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
