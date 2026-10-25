//
//  TSSCalculator.swift
//  onMyTss
//
//  Created by Claude Code
//

import Foundation
import HealthKit

/// Calculator for Training Stress Score (TSS)
struct TSSCalculator {

    // MARK: - Power-Based TSS (Cycling)

    /// Calculate TSS from power samples and FTP
    /// Formula: TSS = (duration_seconds × NP × IF) / (FTP × 3600) × 100
    /// Where: NP = Normalized Power, IF = Intensity Factor (NP/FTP)
    static func calculateTSS(
        powerSamples: [HKQuantitySample],
        ftp: Int,
        duration: TimeInterval
    ) -> Double {
        guard !powerSamples.isEmpty, ftp > 0, duration > Constants.minWorkoutDuration else {
            return 0
        }

        let intervals = timedIntervals(powerSamples, unit: .watt(), duration: duration, validRange: 0...2500)
        guard let normalizedPower = SignalProcessing.normalizedPower(intervals) else { return 0 }
        let observedDuration = SignalProcessing.coveredSeconds(intervals)
        return (observedDuration / 3600 * pow(normalizedPower / Double(ftp), 2) * 100).rounded(toPlaces: 1)
    }

    /// Timestamp API: the window is 30 elapsed seconds, independent of count.
    static func calculateNormalizedPower(from samples: [TimedValue], window: TimeRange, pauses: [TimeRange] = []) -> Double? {
        let intervals = SignalProcessing.intervals(samples: samples, window: window, pauses: pauses, validRange: 0...2500)
        return SignalProcessing.normalizedPower(intervals)
    }

    /// Legacy convenience for callers explicitly supplying an evenly sampled
    /// one-Hertz signal. Importers must use timestamped samples above.
    @available(*, deprecated, message: "Use timestamped samples; this API assumes explicit 1 Hz input")
    static func calculateNormalizedPower(from powerValues: [Double]) -> Double {
        let start = Date(timeIntervalSince1970: 0)
        let samples = powerValues.enumerated().map { index, value in
            TimedValue(start: start.addingTimeInterval(Double(index)), end: start.addingTimeInterval(Double(index + 1)), value: value)
        }
        return calculateNormalizedPower(from: samples, window: TimeRange(start: start, end: start.addingTimeInterval(Double(powerValues.count)))) ?? 0
    }

    private static func timedIntervals(_ samples: [HKQuantitySample], unit: HKUnit, duration: TimeInterval, validRange: ClosedRange<Double>) -> [TimedValue] {
        // Parent samples with count > 1 are aggregates, not time series. The
        // production importer expands them using HKQuantitySeriesSampleQuery.
        guard let start = samples.map(\.startDate).min(), duration.isFinite, duration > 0 else { return [] }
        let values = samples.filter { $0.count == 1 }.map {
            TimedValue(start: $0.startDate, end: $0.endDate, value: $0.quantity.doubleValue(for: unit))
        }
        return SignalProcessing.intervals(samples: values, window: TimeRange(start: start, end: start.addingTimeInterval(duration)), validRange: validRange)
    }

    // MARK: - Heart Rate-Based TSS (Multi-Sport)

    /// Calculate TSS from heart rate when power data is unavailable
    /// Uses modified TRIMP (Training Impulse) method optimized for endurance sports
    /// This method works for all workout types: cycling, running, swimming, etc.
    /// Formula: TSS = (duration_minutes × HR_ratio × exp_factor) × sport_multiplier
    static func calculateTSSFromHeartRate(
        heartRateSamples: [HKQuantitySample],
        duration: TimeInterval,
        maxHeartRate: Int?,
        restingHeartRate: Int?
    ) -> Double {
        guard !heartRateSamples.isEmpty,
              duration > Constants.minWorkoutDuration else {
            return 0
        }

        let intervals = timedIntervals(heartRateSamples, unit: .count().unitDivided(by: .minute()), duration: duration, validRange: 30...240)
        // This remains the legacy HR-TSS heuristic with explicitly assumed
        // thresholds. It is separate from v2 Cardio Load and is never added to it.
        return legacyHeartRateTSS(intervals: intervals, maxHeartRate: maxHeartRate ?? 185,
                                  restingHeartRate: restingHeartRate ?? 60).rounded(toPlaces: 1)
    }

    static func legacyHeartRateTSS(intervals: [TimedValue], maxHeartRate: Int, restingHeartRate: Int) -> Double {
        let reserve = Double(maxHeartRate - restingHeartRate)
        guard reserve > 0 else { return 0 }
        let trimp = intervals.reduce(0.0) { sum, interval in
            let ratio = min(1, max(0, (interval.value - Double(restingHeartRate)) / reserve))
            return sum + interval.duration / 60 * ratio * exp(1.92 * ratio)
        }
        let reference = 60 * 0.85 * exp(1.92 * 0.85)
        let result = trimp / reference * 100
        return result.isFinite ? max(0, result) : 0
    }

    /// Calculate TSS from heart rate with workout type context
    /// Provides sport-specific adjustments for more accurate TSS estimation
    static func calculateTSSFromHeartRateWithType(
        heartRateSamples: [HKQuantitySample],
        duration: TimeInterval,
        workoutType: HKWorkoutActivityType,
        maxHeartRate: Int?,
        restingHeartRate: Int?
    ) -> Double {
        let baseTSS = calculateTSSFromHeartRate(
            heartRateSamples: heartRateSamples,
            duration: duration,
            maxHeartRate: maxHeartRate,
            restingHeartRate: restingHeartRate
        )

        // Sport-specific multipliers to account for differences in physiological stress
        // Running: higher impact stress, slightly higher multiplier
        // Swimming: technique-limited, lower perceived exertion for same HR
        // Cycling: baseline (1.0)
        let sportMultiplier: Double
        switch workoutType {
        case .running:
            sportMultiplier = 1.1 // Running has higher mechanical stress
        case .swimming:
            sportMultiplier = 0.95 // Swimming is technique-limited
        case .cycling:
            sportMultiplier = 1.0 // Baseline
        case .hiking, .walking:
            sportMultiplier = 0.85 // Lower intensity activities
        case .rowing, .crossTraining:
            sportMultiplier = 1.05 // Full-body activities
        default:
            sportMultiplier = 1.0 // Default to cycling baseline
        }

        return (baseTSS * sportMultiplier).rounded(toPlaces: 1)
    }

    /// Estimate maximum heart rate using age-based formula (220 - age)
    /// Default to 185 if age is unknown
    private static func estimateMaxHeartRate(age: Int? = nil) -> Int {
        if let age = age {
            return 220 - age
        }
        return 185 // Conservative default for adult athletes
    }

    // MARK: - Workout TSS Calculation

    /// Calculate TSS for a workout based on available data
    /// Prioritizes power data, falls back to heart rate if power is unavailable
    static func calculateWorkoutTSS(
        workout: HKWorkout,
        powerSamples: [HKQuantitySample],
        heartRateSamples: [HKQuantitySample],
        ftp: Int?
    ) -> Double {
        let duration = workout.duration

        // Try power-based TSS first (cycling)
        if workout.workoutActivityType == .cycling,
           !powerSamples.isEmpty,
           let ftp = ftp,
           ftp > 0 {
            return calculateTSS(powerSamples: powerSamples, ftp: ftp, duration: duration)
        }

        // Fall back to heart rate-based TSS
        if !heartRateSamples.isEmpty {
            return calculateTSSFromHeartRate(
                heartRateSamples: heartRateSamples,
                duration: duration,
                maxHeartRate: nil,
                restingHeartRate: nil
            )
        }

        // If no data available, estimate from duration and type
        return estimateTSSFromDuration(workout: workout)
    }

    /// Estimate TSS from workout duration and type when no power/HR data available
    /// Uses typical intensity factors for each workout type
    /// This is a fallback method and less accurate than power or HR-based calculations
    static func estimateTSSFromDuration(workout: HKWorkout) -> Double {
        let durationHours = workout.duration / 3600.0

        // Typical IF (Intensity Factor) values for different workout types
        // Based on typical moderate-intensity training zones
        let typicalIF: Double
        switch workout.workoutActivityType {
        case .cycling:
            typicalIF = 0.70 // Moderate endurance ride (Zone 2-3)
        case .running:
            typicalIF = 0.75 // Moderate run (Zone 2-3, higher impact)
        case .swimming:
            typicalIF = 0.65 // Moderate swim (technique-limited)
        case .hiking:
            typicalIF = 0.55 // Hiking (lower intensity, longer duration)
        case .walking:
            typicalIF = 0.45 // Walking (low intensity)
        case .rowing:
            typicalIF = 0.72 // Rowing (full-body, similar to cycling)
        case .crossTraining, .functionalStrengthTraining:
            typicalIF = 0.68 // Cross-training activities
        case .elliptical:
            typicalIF = 0.65 // Elliptical (lower impact than running)
        case .yoga, .pilates:
            typicalIF = 0.40 // Mind-body activities (low cardiovascular stress)
        default:
            typicalIF = 0.60 // Conservative default for unknown activities
        }

        // TSS ≈ hours × 100 × IF²
        // This approximation assumes TSS = 100 for 1 hour at threshold (IF = 1.0)
        let estimatedTSS = durationHours * 100 * pow(typicalIF, 2)

        return max(0, estimatedTSS.rounded(toPlaces: 1))
    }

    // MARK: - Workout Type Support

    /// Check if a workout type is supported for TSS calculation
    static func isWorkoutTypeSupported(_ type: HKWorkoutActivityType) -> Bool {
        switch type {
        case .cycling, .running, .swimming, .hiking, .walking,
             .rowing, .crossTraining, .functionalStrengthTraining,
             .elliptical, .yoga, .pilates:
            return true
        default:
            // All workout types are supported via heart rate or duration estimation
            // but some may be more accurate than others
            return true
        }
    }

    /// Get a human-readable description of TSS calculation method for a workout
    static func getTSSCalculationMethod(
        workout: HKWorkout,
        hasPowerData: Bool,
        hasHeartRateData: Bool
    ) -> String {
        if workout.workoutActivityType == .cycling && hasPowerData {
            return "Power-based (most accurate)"
        } else if hasHeartRateData {
            return "Heart rate-based"
        } else {
            return "Duration estimate"
        }
    }
}
