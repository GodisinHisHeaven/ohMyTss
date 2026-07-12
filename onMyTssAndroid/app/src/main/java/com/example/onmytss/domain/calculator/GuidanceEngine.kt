package com.example.onmytss.domain.calculator

import com.example.onmytss.domain.model.TSSRecommendation
import com.example.onmytss.domain.model.WeeklyPlan
import com.example.onmytss.domain.model.enums.ReadinessZone
import com.example.onmytss.domain.model.enums.TSSIntensity

object GuidanceEngine {

    fun getReadinessZone(tsb: Double): ReadinessZone {
        val zones = listOf(
            ReadinessZone.BUILD_INTENSITY,
            ReadinessZone.BUILD_BASE,
            ReadinessZone.MAINTAIN,
            ReadinessZone.DELOAD,
            ReadinessZone.OVERREACHING
        )
        for (zone in zones) {
            if (zone.tsbRange.contains(tsb)) {
                return zone
            }
        }
        return if (tsb < -50) ReadinessZone.OVERREACHING else ReadinessZone.BUILD_INTENSITY
    }

    fun getRecommendedTSSRange(bodyBatteryScore: Int, tsb: Double, ctl: Double): TSSRecommendation {
        val zone = getReadinessZone(tsb)
        return when (zone) {
            ReadinessZone.OVERREACHING -> TSSRecommendation(
                min = 0,
                max = (ctl * 0.3).toInt(),
                optimal = (ctl * 0.15).toInt(),
                description = "Focus on recovery. Very light activity only.",
                intensity = TSSIntensity.RECOVERY
            )
            ReadinessZone.DELOAD -> TSSRecommendation(
                min = (ctl * 0.3).toInt(),
                max = (ctl * 0.6).toInt(),
                optimal = (ctl * 0.45).toInt(),
                description = "Easy recovery rides/runs recommended.",
                intensity = TSSIntensity.ENDURANCE
            )
            ReadinessZone.MAINTAIN -> TSSRecommendation(
                min = (ctl * 0.6).toInt(),
                max = ctl.toInt(),
                optimal = (ctl * 0.8).toInt(),
                description = "Moderate training to maintain fitness.",
                intensity = TSSIntensity.TEMPO
            )
            ReadinessZone.BUILD_BASE -> TSSRecommendation(
                min = (ctl * 0.8).toInt(),
                max = (ctl * 1.3).toInt(),
                optimal = (ctl * 1.1).toInt(),
                description = "Good day for base building endurance work.",
                intensity = TSSIntensity.ENDURANCE
            )
            ReadinessZone.BUILD_INTENSITY -> TSSRecommendation(
                min = ctl.toInt(),
                max = (ctl * 1.5).toInt(),
                optimal = (ctl * 1.25).toInt(),
                description = "Perfect for high-intensity or long workouts.",
                intensity = TSSIntensity.THRESHOLD
            )
        }
    }

    fun getTrainingSuggestions(
        bodyBatteryScore: Int,
        tsb: Double,
        ctl: Double,
        atl: Double,
        rampRate: Double?,
        recentTSS: List<Double>
    ): List<String> {
        val suggestions = mutableListOf<String>()
        val zone = getReadinessZone(tsb)
        val tssRec = getRecommendedTSSRange(bodyBatteryScore, tsb, ctl)

        suggestions.add(zone.description)
        if (tssRec.optimal > 0) {
            suggestions.add("Target TSS: ~${tssRec.optimal} (${tssRec.intensity.displayName})")
        }

        rampRate?.let {
            val status = LoadCalculator.getRampRateStatus(it)
            when (status) {
                com.example.onmytss.domain.model.enums.RampRateStatus.DANGEROUS ->
                    suggestions.add("⚠️ CTL increasing too fast. Consider a recovery week.")
                com.example.onmytss.domain.model.enums.RampRateStatus.AGGRESSIVE ->
                    suggestions.add("⚡ CTL increasing rapidly. Monitor recovery closely.")
                com.example.onmytss.domain.model.enums.RampRateStatus.DETRAINING ->
                    suggestions.add("📉 CTL is decreasing. Consider adding volume if intentional taper is complete.")
                else -> {}
            }
        }

        if (recentTSS.size >= 7) {
            val lastSevenDays = recentTSS.takeLast(7)
            val highTSSDays = lastSevenDays.count { it > ctl * 1.2 }
            if (highTSSDays >= 4) {
                suggestions.add("🔥 Multiple high TSS days recently. Schedule recovery soon.")
            }
            val veryLowTSSDays = lastSevenDays.count { it < ctl * 0.3 }
            if (veryLowTSSDays >= 3 && zone != ReadinessZone.OVERREACHING) {
                suggestions.add("💤 Low recent training volume. Gradually increase if not in taper.")
            }
        }

        if (ctl < 40) {
            suggestions.add("🌱 Building base fitness. Focus on consistent, moderate volume.")
        } else if (ctl > 100) {
            suggestions.add("🏆 High fitness level. Maintain with smart periodization.")
        }

        if (tsb > 10) {
            suggestions.add("✨ High form. Good time for race efforts or breakthrough workouts.")
        } else if (tsb < -20) {
            suggestions.add("🛌 Significant fatigue. Prioritize sleep and nutrition.")
        }

        return suggestions
    }

    fun getWeeklyPlan(ctl: Double, atl: Double, tsb: Double, targetWeeklyTSS: Double? = null): WeeklyPlan {
        val zone = getReadinessZone(tsb)
        val weeklyTSS = targetWeeklyTSS ?: (ctl * 7.0)

        val dailyTSS = when (zone) {
            ReadinessZone.OVERREACHING -> listOf(
                ctl * 0.2, ctl * 0.1, ctl * 0.3, 0.0, ctl * 0.2, ctl * 0.3, 0.0
            )
            ReadinessZone.DELOAD -> listOf(
                ctl * 0.5, ctl * 0.3, ctl * 0.6, ctl * 0.3, 0.0, ctl * 0.7, ctl * 0.4
            )
            else -> listOf(
                ctl * 0.8, ctl * 0.6, ctl * 1.0, ctl * 0.6, ctl * 0.5, ctl * 1.3, ctl * 1.0
            )
        }

        return WeeklyPlan(
            totalTSS = dailyTSS.sum(),
            dailyTSS = dailyTSS,
            primaryFocus = zone.displayName,
            restDays = if (zone == ReadinessZone.OVERREACHING) 2 else 1
        )
    }
}
