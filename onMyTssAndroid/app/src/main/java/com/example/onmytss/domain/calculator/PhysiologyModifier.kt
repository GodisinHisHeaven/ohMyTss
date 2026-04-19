package com.example.onmytss.domain.calculator

object PhysiologyModifier {

    fun calculateHRVModifier(currentHRV: Double, baselineHRV: Double): Double {
        val percentDeviation = ((currentHRV - baselineHRV) / baselineHRV) * 100.0
        val modifier = when {
            percentDeviation >= 30 -> 20.0
            percentDeviation >= 15 -> percentDeviation / 1.5
            percentDeviation >= -15 -> percentDeviation / 2.0
            percentDeviation >= -30 -> percentDeviation / 1.5
            else -> -20.0
        }
        return modifier.coerceIn(-20.0, 20.0)
    }

    fun calculateRHRModifier(currentRHR: Double, baselineRHR: Double): Double {
        val deviationBPM = currentRHR - baselineRHR
        val modifier = when {
            deviationBPM <= -5 -> 20.0
            deviationBPM <= -2 -> -deviationBPM * 4.0
            deviationBPM <= 2 -> -deviationBPM * 3.0
            deviationBPM <= 5 -> -deviationBPM * 4.0
            else -> -20.0
        }
        return modifier.coerceIn(-20.0, 20.0)
    }

    fun calculateCombinedModifier(hrvModifier: Double?, rhrModifier: Double?): Double {
        return when {
            hrvModifier != null && rhrModifier != null -> {
                (hrvModifier * 0.7 + rhrModifier * 0.3).coerceIn(-20.0, 20.0)
            }
            hrvModifier != null -> hrvModifier.coerceIn(-20.0, 20.0)
            rhrModifier != null -> rhrModifier.coerceIn(-20.0, 20.0)
            else -> 0.0
        }
    }

    fun calculateBaselineHRV(values: List<Double>): Double? {
        if (values.size < 3) return null
        val sorted = values.sorted()
        val middle = sorted.size / 2
        return if (sorted.size % 2 == 0) {
            (sorted[middle - 1] + sorted[middle]) / 2.0
        } else {
            sorted[middle]
        }
    }

    fun calculateBaselineRHR(values: List<Double>): Double? {
        if (values.size < 3) return null
        val sorted = values.sorted()
        val middle = sorted.size / 2
        return if (sorted.size % 2 == 0) {
            (sorted[middle - 1] + sorted[middle]) / 2.0
        } else {
            sorted[middle]
        }
    }

    fun calculateDailyAverageHRV(values: List<Double>): Double? {
        if (values.isEmpty()) return null
        return values.average()
    }

    fun calculateDailyAverageRHR(values: List<Double>): Double? {
        if (values.isEmpty()) return null
        return values.average()
    }

    fun detectIllness(hrvModifier: Double?, rhrModifier: Double?): Double {
        if (hrvModifier == null || rhrModifier == null) return 0.0
        return when {
            hrvModifier <= -15 && rhrModifier <= -15 -> 1.0
            hrvModifier <= -10 && rhrModifier <= -10 -> 0.7
            hrvModifier <= -5 || rhrModifier <= -5 -> 0.3
            else -> 0.0
        }
    }
}
