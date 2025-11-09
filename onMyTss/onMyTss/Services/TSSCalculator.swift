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

        // Extract power values in watts
        let powerValues = powerSamples.map { sample -> Double in
            sample.quantity.doubleValue(for: HKUnit.watt())
        }

        guard !powerValues.isEmpty else { return 0 }

        // Calculate Normalized Power (NP)
        let normalizedPower = calculateNormalizedPower(from: powerValues)

        // Calculate Intensity Factor (IF)
        let intensityFactor = normalizedPower / Double(ftp)

        // Calculate TSS
        // TSS = (seconds × NP × IF) / (FTP × 3600) × 100
        let tss = (duration * normalizedPower * intensityFactor) / (Double(ftp) * 3600) * 100

        return max(0, tss.rounded(toPlaces: 1))
    }

    /// Calculate Normalized Power (NP) from power samples
    /// NP = fourth root of the average of the fourth power of all power values
    /// This algorithm uses a 30-second rolling average before raising to 4th power
    static func calculateNormalizedPower(from powerValues: [Double]) -> Double {
        guard !powerValues.isEmpty else { return 0 }

        // Step 1: Calculate 30-second rolling average
        // For simplicity, we'll use all values if we don't have timing info
        // In a production app, you'd want to align this with actual sample timestamps
        let rollingAveragePowers: [Double]

        if powerValues.count < 30 {
            // If less than 30 samples, use simple average
            rollingAveragePowers = [powerValues.average()]
        } else {
            // Calculate rolling 30-second averages
            rollingAveragePowers = stride(from: 0, to: powerValues.count - 29, by: 1).map { i in
                let window = Array(powerValues[i..<min(i + 30, powerValues.count)])
                return window.average()
            }
        }

        // Step 2: Raise each value to the 4th power
        let fourthPowers = rollingAveragePowers.map { pow($0, Constants.normalizedPowerVariabilityIndex) }

        // Step 3: Average the 4th powers
        let averageFourthPower = fourthPowers.average()

        // Step 4: Take the 4th root
        let normalizedPower = pow(averageFourthPower, 1.0 / Constants.normalizedPowerVariabilityIndex)

        return normalizedPower.rounded(toPlaces: 1)
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

        // Extract heart rate values in BPM
        let hrValues = heartRateSamples.map { sample -> Double in
            sample.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
        }

        guard !hrValues.isEmpty else { return 0 }

        let avgHR = hrValues.average()

        // If max HR and resting HR are not available, use age-based estimation
        let maxHR = maxHeartRate ?? estimateMaxHeartRate()
        let restingHR = Double(restingHeartRate ?? 60)

        // Calculate heart rate reserve ratio (0.0 to 1.0)
        let hrReserve = Double(maxHR) - restingHR
        guard hrReserve > 0 else { return 0 }

        let hrRatio = min(max((avgHR - restingHR) / hrReserve, 0.0), 1.0)

        // Exponential factor based on HR ratio (modified TRIMP method)
        // This creates a non-linear relationship where higher intensities contribute more stress
        let expFactor = exp(1.92 * hrRatio)

        // Calculate TRIMP-based TSS
        // Normalized to match power-based TSS scale (60 min at FTP = 100 TSS)
        let durationMinutes = duration / 60.0

        // Base TSS calculation using HR reserve and exponential weighting
        // The division by 60 normalizes to a 1-hour baseline
        let baseTSS = (durationMinutes * hrRatio * expFactor) / 60.0 * 100

        return max(0, baseTSS.rounded(toPlaces: 1))
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
