//
//  Constants.swift
//  onMyTss
//
//  Created by Claude Code
//

import Foundation

enum Constants {
    // MARK: - Training Load Constants

    /// Time constant for Chronic Training Load (CTL) - 42 days
    static let ctlTimeConstant: Double = 42.0

    /// Time constant for Acute Training Load (ATL) - 7 days
    static let atlTimeConstant: Double = 7.0

    /// Maximum safe CTL ramp rate per week (TSS/day increase)
    static let maxSafeCTLRampRate: Double = 5.0

    /// Recommended CTL ramp rate per week (TSS/day increase)
    static let recommendedCTLRampRate: Double = 3.0

    // MARK: - TSS Calculation Constants

    /// Typical workout intensity factor for threshold efforts
    static let thresholdIntensityFactor: Double = 1.0

    /// Variability index for normalized power calculation
    static let normalizedPowerVariabilityIndex: Double = 4.0

    /// Minimum workout duration in seconds to calculate TSS
    static let minWorkoutDuration: TimeInterval = 300 // 5 minutes

    // MARK: - Body Battery Score Constants

    /// Minimum Body Battery score
    static let minBodyBatteryScore: Int = 0

    /// Maximum Body Battery score
    static let maxBodyBatteryScore: Int = 100

    /// Default Body Battery score (neutral)
    static let defaultBodyBatteryScore: Int = 50

    /// TSB value corresponding to maximum Body Battery score
    static let tsbForMaxScore: Double = 25.0

    /// TSB value corresponding to minimum Body Battery score
    static let tsbForMinScore: Double = -35.0

    // MARK: - Readiness Zones

    enum ReadinessZone: String {
        case overreaching = "Overreaching"
        case deload = "Deload"
        case maintain = "Maintain"
        case buildBase = "Build Base"
        case buildIntensity = "Build Intensity"

        var tsbRange: ClosedRange<Double> {
            switch self {
            case .overreaching: return -50...(-15)
            case .deload: return -15...(-5)
            case .maintain: return -5...5
            case .buildBase: return 5...15
            case .buildIntensity: return 15...50
            }
        }

        var description: String {
            switch self {
            case .overreaching:
                return "High fatigue. Prioritize recovery."
            case .deload:
                return "Moderate fatigue. Light training recommended."
            case .maintain:
                return "Balanced fitness and fatigue. Maintain current training."
            case .buildBase:
                return "Fresh and ready. Good for building base fitness."
            case .buildIntensity:
                return "Very fresh. Good for high-intensity training."
            }
        }
    }

    // MARK: - TSS Intensity Zones

    enum TSSIntensity: String {
        case recovery = "Recovery"
        case endurance = "Endurance"
        case tempo = "Tempo"
        case threshold = "Threshold"
        case vo2Max = "VO2 Max"
        case anaerobic = "Anaerobic"

        var range: ClosedRange<Double> {
            switch self {
            case .recovery: return 0...50
            case .endurance: return 50...100
            case .tempo: return 100...150
            case .threshold: return 150...250
            case .vo2Max: return 250...400
            case .anaerobic: return 400...1000
            }
        }
    }

    // MARK: - HealthKit Constants

    /// Maximum number of days to fetch historical workout data
    static let maxHistoricalDays: Int = 90

    /// Number of days to look back for initial data sync
    static let initialSyncDays: Int = 90

    // MARK: - UI Constants

    /// Number of days to show in the trend chart
    static let trendChartDays: Int = 7

    /// Number of days to show in the history view
    static let historyDays: Int = 30

    /// Default FTP value for new users (watts)
    static let defaultFTP: Int = 200

    /// Minimum allowed FTP value
    static let minFTP: Int = 50

    /// Maximum allowed FTP value
    static let maxFTP: Int = 500

    // MARK: - App Version

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    static var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }
}
