import Foundation

/// Calculates HRV and RHR-based adjustments to Body Battery score
public struct PhysiologyModifier {

    /// Statistical baseline for HRV or RHR samples
    public struct Baseline {
        public let median: Double
        public let mad: Double  // Median Absolute Deviation

        public init(median: Double, mad: Double) {
            self.median = median
            self.mad = mad
        }
    }

    /// Calculates robust baseline statistics from samples
    /// - Parameters:
    ///   - samples: Array of HRV or RHR values
    ///   - excludeLast: Number of recent samples to exclude (default: 2)
    /// - Returns: Baseline with median and MAD
    public static func calculateBaseline(samples: [Double], excludeLast: Int = 2) -> Baseline {
        guard !samples.isEmpty else {
            return Baseline(median: 0, mad: 0)
        }

        let valid = Array(samples.dropLast(excludeLast))
        guard !valid.isEmpty else {
            return Baseline(median: 0, mad: 0)
        }

        let sorted = valid.sorted()
        let median = sorted[sorted.count / 2]

        let deviations = valid.map { abs($0 - median) }
        let sortedDeviations = deviations.sorted()
        let mad = sortedDeviations[sortedDeviations.count / 2]

        return Baseline(median: median, mad: mad)
    }

    /// Calculates robust z-score for a value
    /// - Parameters:
    ///   - value: The value to score
    ///   - baseline: Baseline statistics
    /// - Returns: Robust z-score
    public static func robustZScore(value: Double, baseline: Baseline) -> Double {
        guard baseline.mad > 0 else { return 0 }
        return 0.6745 * (value - baseline.median) / baseline.mad
    }

    /// Calculates Body Battery adjustment from HRV and RHR z-scores
    /// - Parameters:
    ///   - hrvZ: HRV z-score
    ///   - rhrZ: RHR z-score
    ///   - previousAdjustment: Previous day's adjustment for smoothing
    /// - Returns: Adjustment value (-12 to +12)
    public static func calculateAdjustment(
        hrvZ: Double,
        rhrZ: Double,
        previousAdjustment: Double
    ) -> Double {
        // Normalize (higher HRV = better, lower RHR = better)
        let hrvContrib = (hrvZ / 1.5).clamped(to: -1...1)
        let rhrContrib = (-rhrZ / 1.5).clamped(to: -1...1)

        // Weighted combination (HRV weighted more heavily)
        let combined = 0.6 * hrvContrib + 0.4 * rhrContrib
        let rawAdjustment = (10.0 * combined).clamped(to: -12...12)

        // EWMA smoothing to reduce day-to-day volatility
        return 0.3 * rawAdjustment + 0.7 * previousAdjustment
    }

    /// Detects potential illness/overtraining from HRV and RHR
    /// - Parameters:
    ///   - hrvZ: HRV z-score
    ///   - rhrZ: RHR z-score
    /// - Returns: True if illness pattern detected
    public static func detectIllness(hrvZ: Double, rhrZ: Double) -> Bool {
        // Low HRV + High RHR = potential illness/overtraining
        return hrvZ <= -2.0 && rhrZ >= 2.0
    }
}

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
