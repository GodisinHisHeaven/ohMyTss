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

    // MARK: - Heart Rate-Based TSS (Fallback)

    /// Calculate TSS from heart rate when power data is unavailable
    /// Uses TRIMP (Training Impulse) method as a fallback
    /// Formula: TSS = (duration_minutes × avg_HR × HR_ratio × exp_factor) / 60 × 100
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

        // Calculate heart rate reserve ratio
        let hrReserve = Double(maxHR) - restingHR
        let hrRatio = (avgHR - restingHR) / hrReserve

        // Exponential factor based on HR ratio (TRIMP method)
        let expFactor = exp(1.92 * hrRatio)

        // Calculate TRIMP-based TSS
        // Normalized to approximate power-based TSS scale
        let durationMinutes = duration / 60.0
        let tss = (durationMinutes * hrRatio * expFactor) / 60.0 * 100

        return max(0, tss.rounded(toPlaces: 1))
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
    private static func estimateTSSFromDuration(workout: HKWorkout) -> Double {
        let durationHours = workout.duration / 3600.0

        // Typical IF (Intensity Factor) values for different workout types
        let typicalIF: Double
        switch workout.workoutActivityType {
        case .cycling:
            typicalIF = 0.70 // Moderate endurance ride
        case .running:
            typicalIF = 0.75 // Moderate run
        case .swimming:
            typicalIF = 0.65 // Moderate swim
        default:
            typicalIF = 0.60 // Conservative default
        }

        // TSS ≈ hours × 100 × IF²
        let estimatedTSS = durationHours * 100 * pow(typicalIF, 2)

        return max(0, estimatedTSS.rounded(toPlaces: 1))
    }
}
