import Foundation

/// Banister-style EWMA (Exponentially Weighted Moving Average) load calculator
/// for CTL (Chronic Training Load), ATL (Acute Training Load), and TSB (Training Stress Balance)
public struct LoadCalculator {

    /// CTL decay constant (42-day time constant)
    public static let CTL_DECAY: Double = 1.0 - exp(-1.0/42.0) // ≈ 0.0235283133

    /// ATL decay constant (7-day time constant)
    public static let ATL_DECAY: Double = 1.0 - exp(-1.0/7.0)  // ≈ 0.1331221002

    /// Represents the training load state for a single day
    public struct DayState {
        public var ctl: Double
        public var atl: Double
        public var tsb: Double { ctl - atl }

        public init(ctl: Double, atl: Double) {
            self.ctl = ctl
            self.atl = atl
        }
    }

    /// Updates load metrics for a new day
    /// - Parameters:
    ///   - previous: Previous day's load state
    ///   - dailyTSS: Total TSS for the current day
    /// - Returns: Updated load state
    public static func updateLoad(previous: DayState, dailyTSS: Double) -> DayState {
        let newCTL = previous.ctl + CTL_DECAY * (dailyTSS - previous.ctl)
        let newATL = previous.atl + ATL_DECAY * (dailyTSS - previous.atl)

        return DayState(ctl: newCTL, atl: newATL)
    }

    /// Initializes load state from recent workout history
    /// - Parameter recentWorkouts: Array of (date, tss) tuples
    /// - Returns: Initial load state seeded with recent average
    public static func initializeLoad(recentWorkouts: [(date: Date, tss: Double)]) -> DayState {
        // Seed CTL with 7-day average TSS
        let last7Days = recentWorkouts.suffix(7)
        let avgTSS = last7Days.isEmpty ? 0 : last7Days.map(\.tss).reduce(0, +) / Double(last7Days.count)
        return DayState(ctl: avgTSS, atl: avgTSS)
    }
}
