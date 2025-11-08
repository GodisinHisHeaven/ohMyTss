import Foundation

/// Calculates Training Stress Score (TSS) for different sports
public struct TSSCalculator {

    // MARK: - Cycling TSS (Power-based)

    /// Calculates cycling TSS from power data
    /// - Parameters:
    ///   - powerSamples: Array of power values in watts
    ///   - duration: Workout duration in seconds
    ///   - ftp: Functional Threshold Power in watts
    /// - Returns: TSS value, or nil if insufficient data
    public static func cyclingTSS(powerSamples: [Double], duration: TimeInterval, ftp: Double) -> Double? {
        guard !powerSamples.isEmpty, ftp > 0 else { return nil }

        let np = normalizedPower(powerSamples)
        let durationHours = duration / 3600.0
        let intensityFactor = np / ftp

        return (durationHours * np * intensityFactor) / (ftp * 3600.0) * 100.0
    }

    /// Calculates Normalized Power (NP) from power samples
    /// Uses 30-second rolling average raised to 4th power
    private static func normalizedPower(_ samples: [Double]) -> Double {
        guard !samples.isEmpty else { return 0 }

        // 30-second rolling average (assuming 1Hz sampling)
        let windowSize = 30
        let rollingAvg = samples.chunked(into: windowSize).map { $0.average() }

        // 4th power, then 4th root
        let fourthPowers = rollingAvg.map { pow($0, 4) }
        return pow(fourthPowers.average(), 0.25)
    }

    // MARK: - Running TSS (Pace-based)

    /// Calculates running TSS from pace
    /// - Parameters:
    ///   - distance: Distance in meters
    ///   - duration: Duration in seconds
    ///   - thresholdPace: Threshold pace in seconds/meter
    /// - Returns: TSS value
    public static func runningTSS(distance: Double, duration: TimeInterval, thresholdPace: Double) -> Double {
        guard distance > 0, thresholdPace > 0 else { return 0 }

        let pace = duration / distance  // sec/meter
        let intensityFactor = thresholdPace / pace
        let hours = duration / 3600.0

        return hours * pow(intensityFactor, 2) * 100.0
    }

    // MARK: - Swimming TSS (Time-based)

    /// Calculates swimming TSS from pace
    /// - Parameters:
    ///   - distance: Distance in meters
    ///   - duration: Duration in seconds
    ///   - cssPace: Critical Swim Speed pace in seconds/meter
    /// - Returns: TSS value
    public static func swimmingTSS(distance: Double, duration: TimeInterval, cssPace: Double) -> Double {
        guard distance > 0, cssPace > 0 else { return 0 }

        let pace = duration / distance  // sec/meter
        let intensityFactor = cssPace / pace
        let hours = duration / 3600.0

        return hours * pow(intensityFactor, 2) * 100.0
    }

    // MARK: - Heart Rate-based TSS (Fallback)

    /// Estimates TSS from heart rate using TRIMP method
    /// - Parameters:
    ///   - avgHR: Average heart rate during workout
    ///   - duration: Duration in seconds
    ///   - thresholdHR: Threshold heart rate (LTHR)
    ///   - restingHR: Resting heart rate
    /// - Returns: Estimated TSS
    public static func heartRateTSS(
        avgHR: Double,
        duration: TimeInterval,
        thresholdHR: Double,
        restingHR: Double
    ) -> Double {
        guard avgHR > restingHR, thresholdHR > restingHR else { return 0 }

        let hrReserve = (avgHR - restingHR) / (thresholdHR - restingHR)
        let minutes = duration / 60.0
        let trimp = minutes * hrReserve * exp(1.92 * hrReserve)

        // Scale TRIMP to TSS range (rough approximation)
        return trimp * 0.1
    }
}

// MARK: - Array Extensions

extension Array where Element == Double {
    func average() -> Double {
        isEmpty ? 0 : reduce(0, +) / Double(count)
    }

    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}
