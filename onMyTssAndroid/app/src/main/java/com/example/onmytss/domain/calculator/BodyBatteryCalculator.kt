package com.example.onmytss.domain.calculator

import com.example.onmytss.domain.Constants
import com.example.onmytss.domain.model.enums.ReadinessLevel
import com.example.onmytss.domain.model.enums.Trend

object BodyBatteryCalculator {

    fun calculateScore(tsb: Double): Int {
        val score: Double = when {
            tsb <= Constants.TSB_FOR_MIN_SCORE -> 0.0
            tsb >= Constants.TSB_FOR_MAX_SCORE -> 100.0
            tsb < 0 -> {
                // Linear from -35 to 0 maps to 0 to 50
                ((tsb - Constants.TSB_FOR_MIN_SCORE) / (-Constants.TSB_FOR_MIN_SCORE)) * 50.0
            }
            else -> {
                // Linear from 0 to 25 maps to 50 to 100
                50.0 + (tsb / Constants.TSB_FOR_MAX_SCORE) * 50.0
            }
        }
        return score.toInt().coerceIn(0, 100)
    }

    fun calculateScoreWithModifiers(tsb: Double, hrvModifier: Double? = null, rhrModifier: Double? = null): Int {
        val baseScore = calculateScore(tsb).toDouble()
        val combinedModifier = PhysiologyModifier.calculateCombinedModifier(hrvModifier, rhrModifier)
        val modifiedScore = (baseScore + combinedModifier).coerceIn(0.0, 100.0)
        return modifiedScore.toInt()
    }

    fun getReadinessLevel(score: Int): ReadinessLevel {
        return when (score) {
            in 0 until 20 -> ReadinessLevel.VERY_LOW
            in 20 until 40 -> ReadinessLevel.LOW
            in 40 until 60 -> ReadinessLevel.MEDIUM
            in 60 until 80 -> ReadinessLevel.GOOD
            else -> ReadinessLevel.EXCELLENT
        }
    }

    fun getScoreChangeDescription(previousScore: Int, currentScore: Int): String {
        val change = currentScore - previousScore
        return when {
            change > 10 -> "↑ Significantly improved (+$change)"
            change > 3 -> "↑ Improved (+$change)"
            change > 0 -> "→ Slightly improved (+$change)"
            change == 0 -> "→ No change"
            change > -3 -> "→ Slightly decreased ($change)"
            change > -10 -> "↓ Decreased ($change)"
            else -> "↓ Significantly decreased ($change)"
        }
    }

    fun calculateTrend(scores: List<Int>): Trend {
        if (scores.size < 3) return Trend.STABLE

        val n = scores.size.toDouble()
        val x = scores.indices.map { it.toDouble() }
        val y = scores.map { it.toDouble() }

        val sumX = x.sum()
        val sumY = y.sum()
        val sumXY = x.zip(y).sumOf { it.first * it.second }
        val sumX2 = x.sumOf { it * it }

        val denominator = n * sumX2 - sumX * sumX
        if (denominator == 0.0) return Trend.STABLE

        val slope = (n * sumXY - sumX * sumY) / denominator

        return when {
            slope > 2.0 -> Trend.IMPROVING_FAST
            slope > 0.5 -> Trend.IMPROVING
            slope < -2.0 -> Trend.DECLINING_FAST
            slope < -0.5 -> Trend.DECLINING
            else -> Trend.STABLE
        }
    }
}
