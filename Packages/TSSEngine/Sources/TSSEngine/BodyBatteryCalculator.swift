import Foundation

/// Converts TSB (Training Stress Balance) to a 0-100 Body Battery score
public struct BodyBatteryCalculator {

    /// Minimum TSB value for mapping (-30 → 0% battery)
    private static let TSB_MIN: Double = -30.0

    /// Maximum TSB value for mapping (+30 → 100% battery)
    private static let TSB_MAX: Double = 30.0

    /// Calculates raw Body Battery score from TSB
    /// - Parameter tsb: Training Stress Balance
    /// - Returns: Score from 0-100
    public static func rawScore(tsb: Double) -> Int {
        let normalized = (tsb - TSB_MIN) / (TSB_MAX - TSB_MIN)
        let score = normalized * 100.0
        return Int(score.clamped(to: 0...100))
    }

    /// Calculates final Body Battery score with HRV/RHR adjustments
    /// - Parameters:
    ///   - tsb: Training Stress Balance
    ///   - hrvAdjustment: Adjustment from HRV analysis (-12 to +12)
    ///   - rhrAdjustment: Adjustment from RHR analysis (-12 to +12)
    /// - Returns: Final score from 0-100
    public static func finalScore(tsb: Double, hrvAdjustment: Double = 0, rhrAdjustment: Double = 0) -> Int {
        let raw = Double(rawScore(tsb: tsb))
        let combined = raw + hrvAdjustment + rhrAdjustment
        return Int(combined.clamped(to: 0...100))
    }
}

// MARK: - Helper Extensions

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
