package com.example.onmytss.domain.calculator

import com.example.onmytss.domain.Constants
import com.example.onmytss.domain.model.enums.RampRateStatus

object LoadCalculator {

    fun calculateCTL(tssHistory: List<Double>, previousCTL: Double = 0.0): Double {
        if (tssHistory.isEmpty()) return previousCTL
        val todayTSS = tssHistory.last()
        val newCTL = previousCTL + (1.0 / Constants.CTL_TIME_CONSTANT) * (todayTSS - previousCTL)
        return maxOf(0.0, newCTL.roundTo(2))
    }

    fun calculateATL(tssHistory: List<Double>, previousATL: Double = 0.0): Double {
        if (tssHistory.isEmpty()) return previousATL
        val todayTSS = tssHistory.last()
        val newATL = previousATL + (1.0 / Constants.ATL_TIME_CONSTANT) * (todayTSS - previousATL)
        return maxOf(0.0, newATL.roundTo(2))
    }

    fun calculateTSB(ctl: Double, atl: Double): Double {
        return (ctl - atl).roundTo(2)
    }

    fun calculateTimeSeries(tssValues: List<Double>): List<Triple<Double, Double, Double>> {
        if (tssValues.isEmpty()) return emptyList()

        val results = mutableListOf<Triple<Double, Double, Double>>()
        var currentCTL = 0.0
        var currentATL = 0.0

        for (tss in tssValues) {
            currentCTL = calculateCTL(listOf(tss), currentCTL)
            currentATL = calculateATL(listOf(tss), currentATL)
            val tsb = calculateTSB(currentCTL, currentATL)
            results.add(Triple(currentCTL, currentATL, tsb))
        }

        return results
    }

    fun calculateCTLRampRate(currentCTL: Double, ctlOneWeekAgo: Double): Double {
        return (currentCTL - ctlOneWeekAgo).roundTo(2)
    }

    fun isRampRateSafe(rampRate: Double): Boolean {
        return rampRate <= Constants.MAX_SAFE_CTL_RAMP_RATE
    }

    fun getRampRateStatus(rampRate: Double): RampRateStatus {
        return when {
            rampRate < 0 -> RampRateStatus.DETRAINING
            rampRate <= Constants.RECOMMENDED_CTL_RAMP_RATE -> RampRateStatus.SAFE
            rampRate <= Constants.MAX_SAFE_CTL_RAMP_RATE -> RampRateStatus.AGGRESSIVE
            else -> RampRateStatus.DANGEROUS
        }
    }

    fun initializeLoadMetrics(historicalTSS: List<Double>): Triple<Double, Double, Double> {
        if (historicalTSS.isEmpty()) return Triple(0.0, 0.0, 0.0)
        val timeSeries = calculateTimeSeries(historicalTSS)
        return timeSeries.lastOrNull() ?: Triple(0.0, 0.0, 0.0)
    }

    fun calculateLoadMetrics(tssHistory: List<Double>, includeToday: Boolean = true): Triple<Double, Double, Double> {
        return if (includeToday) {
            initializeLoadMetrics(tssHistory)
        } else {
            initializeLoadMetrics(tssHistory.dropLast(1))
        }
    }

    private fun Double.roundTo(decimals: Int): Double {
        var multiplier = 1.0
        repeat(decimals) { multiplier *= 10 }
        return kotlin.math.round(this * multiplier) / multiplier
    }
}
