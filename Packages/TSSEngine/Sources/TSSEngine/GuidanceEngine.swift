import Foundation

/// Provides training guidance based on Body Battery score and CTL
public struct GuidanceEngine {

    /// Readiness zones based on Body Battery score
    public enum ReadinessZone {
        case recovery      // BB 0-20
        case easy          // BB 20-40
        case moderate      // BB 40-60
        case hard          // BB 60-80
        case peak          // BB 80-100

        public init(bodyBattery: Int) {
            switch bodyBattery {
            case 0..<20: self = .recovery
            case 20..<40: self = .easy
            case 40..<60: self = .moderate
            case 60..<80: self = .hard
            default: self = .peak
            }
        }

        public var name: String {
            switch self {
            case .recovery: return "Recovery"
            case .easy: return "Easy Endurance"
            case .moderate: return "Tempo/Sweetspot"
            case .hard: return "Threshold/VO2max"
            case .peak: return "Race/Peak"
            }
        }

        public var colorHex: String {
            switch self {
            case .recovery: return "#E53E3E"      // Red
            case .easy: return "#DD6B20"          // Orange
            case .moderate: return "#D69E2E"      // Yellow
            case .hard: return "#38A169"          // Green
            case .peak: return "#3182CE"          // Blue
            }
        }

        public var description: String {
            switch self {
            case .recovery:
                return "Focus on rest and recovery. Keep intensity very low."
            case .easy:
                return "Easy aerobic work. Build endurance without accumulating fatigue."
            case .moderate:
                return "Moderate efforts are appropriate. Tempo and sweetspot zones."
            case .hard:
                return "Good day for hard training. Threshold and VO2max efforts."
            case .peak:
                return "Excellent readiness. Race or peak training efforts."
            }
        }
    }

    /// Calculates suggested TSS range for the day
    /// - Parameters:
    ///   - bodyBattery: Current Body Battery score (0-100)
    ///   - ctl: Current Chronic Training Load
    ///   - adjustment: HRV/RHR adjustment value
    /// - Returns: Suggested TSS range
    public static func suggestedTSSRange(
        bodyBattery: Int,
        ctl: Double,
        adjustment: Double = 0
    ) -> ClosedRange<Double> {
        let zone = ReadinessZone(bodyBattery: bodyBattery)

        var (lowerMultiplier, upperMultiplier): (Double, Double) = {
            switch zone {
            case .recovery: return (0.0, 0.5)
            case .easy: return (0.5, 0.8)
            case .moderate: return (0.8, 1.1)
            case .hard: return (1.1, 1.4)
            case .peak: return (1.4, 1.8)
            }
        }()

        // Apply HRV/RHR modifier
        if adjustment >= 6 {
            // Feeling great, can push harder
            upperMultiplier *= 1.1
        } else if adjustment <= -6 {
            // Stressed, reduce load
            lowerMultiplier *= 0.8
            upperMultiplier *= 0.8
        }

        let lower = max(0, ctl * lowerMultiplier)
        let upper = ctl * upperMultiplier

        return lower...upper
    }

    /// Checks if weekly CTL ramp is too aggressive
    /// - Parameters:
    ///   - currentCTL: Current CTL value
    ///   - ctlWeekAgo: CTL from 7 days ago
    /// - Returns: True if ramp exceeds safe threshold
    public static func isRampTooAggressive(currentCTL: Double, ctlWeekAgo: Double) -> Bool {
        let weeklyChange = currentCTL - ctlWeekAgo
        return weeklyChange > 8.0  // Conservative ramp limit
    }
}
