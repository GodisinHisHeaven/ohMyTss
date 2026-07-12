package com.example.onmytss.domain.calculator

import com.example.onmytss.domain.Constants
import com.example.onmytss.domain.model.Workout
import com.example.onmytss.domain.model.enums.Sport
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow

object TSSCalculator {

    // Power-Based TSS (Cycling)
    fun calculateTSS(powerValues: List<Double>, ftp: Int, duration: Double): Double {
        if (powerValues.isEmpty() || ftp <= 0 || duration <= Constants.MIN_WORKOUT_DURATION_SECONDS) {
            return 0.0
        }

        val normalizedPower = calculateNormalizedPower(powerValues)
        val intensityFactor = normalizedPower / ftp.toDouble()
        val tss = (duration * normalizedPower * intensityFactor) / (ftp.toDouble() * 3600.0) * 100.0
        return max(0.0, tss.roundTo(1))
    }

    fun calculateNormalizedPower(powerValues: List<Double>): Double {
        if (powerValues.isEmpty()) return 0.0

        val rollingAveragePowers: List<Double> = if (powerValues.size < 30) {
            listOf(powerValues.average())
        } else {
            (0..powerValues.size - 30).map { i ->
                powerValues.subList(i, min(i + 30, powerValues.size)).average()
            }
        }

        val fourthPowers = rollingAveragePowers.map { it.pow(Constants.NORMALIZED_POWER_VARIABILITY_INDEX) }
        val averageFourthPower = fourthPowers.average()
        val normalizedPower = averageFourthPower.pow(1.0 / Constants.NORMALIZED_POWER_VARIABILITY_INDEX)
        return normalizedPower.roundTo(1)
    }

    // Heart Rate-Based TSS
    fun calculateTSSFromHeartRate(
        heartRateValues: List<Double>,
        duration: Double,
        maxHeartRate: Int? = null,
        restingHeartRate: Int? = null
    ): Double {
        if (heartRateValues.isEmpty() || duration <= Constants.MIN_WORKOUT_DURATION_SECONDS) {
            return 0.0
        }

        val avgHR = heartRateValues.average()
        val maxHR = maxHeartRate ?: estimateMaxHeartRate()
        val restingHR = restingHeartRate?.toDouble() ?: 60.0

        val hrReserve = maxHR.toDouble() - restingHR
        if (hrReserve <= 0) return 0.0

        val hrRatio = min(max((avgHR - restingHR) / hrReserve, 0.0), 1.0)
        val durationMinutes = duration / 60.0
        val exerciseTRIMP = durationMinutes * hrRatio * kotlin.math.exp(1.92 * hrRatio)

        val hrRatioAtFTP = 0.85
        val oneHourFTPTRIMP = 60.0 * hrRatioAtFTP * kotlin.math.exp(1.92 * hrRatioAtFTP)
        val hrTSS = (exerciseTRIMP / oneHourFTPTRIMP) * 100.0

        return max(0.0, hrTSS.roundTo(1))
    }

    fun calculateTSSFromHeartRateWithType(
        heartRateValues: List<Double>,
        duration: Double,
        sport: Sport,
        maxHeartRate: Int? = null,
        restingHeartRate: Int? = null
    ): Double {
        val baseTSS = calculateTSSFromHeartRate(heartRateValues, duration, maxHeartRate, restingHeartRate)
        val sportMultiplier = when (sport) {
            Sport.RUNNING -> 1.1
            Sport.SWIMMING -> 0.95
            Sport.CYCLING -> 1.0
            Sport.WALKING, Sport.HIKING -> 0.85
            Sport.ROWING, Sport.CROSS_TRAINING -> 1.05
            else -> 1.0
        }
        return (baseTSS * sportMultiplier).roundTo(1)
    }

    private fun estimateMaxHeartRate(age: Int? = null): Int {
        return age?.let { 220 - it } ?: 185
    }

    fun calculateWorkoutTSS(
        workout: Workout,
        powerSamples: List<Double> = emptyList(),
        heartRateSamples: List<Double> = emptyList(),
        ftp: Int? = null
    ): Double {
        val duration = workout.duration

        if (workout.workoutType == Sport.CYCLING && powerSamples.isNotEmpty() && ftp != null && ftp > 0) {
            return calculateTSS(powerSamples, ftp, duration)
        }

        if (heartRateSamples.isNotEmpty()) {
            return calculateTSSFromHeartRate(heartRateSamples, duration)
        }

        return estimateTSSFromDuration(workout)
    }

    fun estimateTSSFromDuration(workout: Workout): Double {
        val durationHours = workout.duration / 3600.0
        val typicalIF = when (workout.workoutType) {
            Sport.CYCLING -> 0.70
            Sport.RUNNING -> 0.75
            Sport.SWIMMING -> 0.65
            Sport.HIKING -> 0.55
            Sport.WALKING -> 0.45
            Sport.ROWING -> 0.72
            Sport.CROSS_TRAINING -> 0.68
            Sport.ELLIPTICAL -> 0.65
            Sport.YOGA, Sport.PILATES -> 0.40
            else -> 0.60
        }
        val estimatedTSS = durationHours * 100.0 * typicalIF.pow(2)
        return max(0.0, estimatedTSS.roundTo(1))
    }

    fun isWorkoutTypeSupported(sport: Sport): Boolean = true

    fun getTSSCalculationMethod(workout: Workout, hasPowerData: Boolean, hasHeartRateData: Boolean): String {
        return when {
            workout.workoutType == Sport.CYCLING && hasPowerData -> "Power-based (most accurate)"
            hasHeartRateData -> "Heart rate-based"
            else -> "Duration estimate"
        }
    }

    private fun Double.roundTo(decimals: Int): Double {
        var multiplier = 1.0
        repeat(decimals) { multiplier *= 10 }
        return kotlin.math.round(this * multiplier) / multiplier
    }
}
