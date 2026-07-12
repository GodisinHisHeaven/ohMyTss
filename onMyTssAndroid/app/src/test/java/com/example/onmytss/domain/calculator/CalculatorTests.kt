package com.example.onmytss.domain.calculator

import com.example.onmytss.domain.model.Workout
import com.example.onmytss.domain.model.enums.RampRateStatus
import com.example.onmytss.domain.model.enums.ReadinessLevel
import com.example.onmytss.domain.model.enums.Sport
import com.example.onmytss.domain.model.enums.Trend
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class TSSCalculatorTests {

    @Test
    fun testCalculateTSSWithPower() {
        val powerValues = List(300) { 200.0 }
        val tss = TSSCalculator.calculateTSS(powerValues, ftp = 200, duration = 3600.0)
        assertEquals(100.0, tss, 0.1)
    }

    @Test
    fun testCalculateTSSWithEmptySamples() {
        val tss = TSSCalculator.calculateTSS(emptyList(), ftp = 200, duration = 3600.0)
        assertEquals(0.0, tss, 0.0)
    }

    @Test
    fun testCalculateNormalizedPower() {
        val powerValues = List(300) { 200.0 }
        val np = TSSCalculator.calculateNormalizedPower(powerValues)
        assertEquals(200.0, np, 0.1)
    }

    @Test
    fun testEstimateTSSFromDurationCycling() {
        val workout = Workout(
            id = "1", date = java.util.Date(), startTime = java.util.Date(),
            duration = 3600.0, workoutType = Sport.CYCLING
        )
        val tss = TSSCalculator.estimateTSSFromDuration(workout)
        assertEquals(49.0, tss, 1.0)
    }

    @Test
    fun testEstimateTSSFromDurationRunning() {
        val workout = Workout(
            id = "1", date = java.util.Date(), startTime = java.util.Date(),
            duration = 3600.0, workoutType = Sport.RUNNING
        )
        val tss = TSSCalculator.estimateTSSFromDuration(workout)
        assertEquals(56.2, tss, 1.0)
    }

    @Test
    fun testHeartRateTSS() {
        val hrValues = List(60) { 150.0 }
        val tss = TSSCalculator.calculateTSSFromHeartRate(hrValues, duration = 3600.0, maxHeartRate = 185, restingHeartRate = 60)
        assertTrue(tss > 0)
    }
}

class BodyBatteryCalculatorTests {

    @Test
    fun testCalculateScoreFromTSB() {
        assertEquals(0, BodyBatteryCalculator.calculateScore(-35.0))
        assertEquals(50, BodyBatteryCalculator.calculateScore(0.0))
        assertEquals(100, BodyBatteryCalculator.calculateScore(25.0))
        assertEquals(25, BodyBatteryCalculator.calculateScore(-17.5))
    }

    @Test
    fun testCalculateScoreWithModifiers() {
        val score = BodyBatteryCalculator.calculateScoreWithModifiers(0.0, hrvModifier = 10.0, rhrModifier = 5.0)
        assertEquals(58, score)
    }

    @Test
    fun testGetReadinessLevel() {
        assertEquals(ReadinessLevel.VERY_LOW, BodyBatteryCalculator.getReadinessLevel(10))
        assertEquals(ReadinessLevel.LOW, BodyBatteryCalculator.getReadinessLevel(30))
        assertEquals(ReadinessLevel.MEDIUM, BodyBatteryCalculator.getReadinessLevel(50))
        assertEquals(ReadinessLevel.GOOD, BodyBatteryCalculator.getReadinessLevel(70))
        assertEquals(ReadinessLevel.EXCELLENT, BodyBatteryCalculator.getReadinessLevel(90))
    }

    @Test
    fun testCalculateTrendStable() {
        val trend = BodyBatteryCalculator.calculateTrend(listOf(50, 51, 50, 49, 50))
        assertEquals(Trend.STABLE, trend)
    }

    @Test
    fun testCalculateTrendImproving() {
        val trend = BodyBatteryCalculator.calculateTrend(listOf(50, 51, 52))
        assertEquals(Trend.IMPROVING, trend)
    }

    @Test
    fun testCalculateTrendDeclining() {
        val trend = BodyBatteryCalculator.calculateTrend(listOf(50, 48, 46))
        assertEquals(Trend.DECLINING, trend)
    }
}

class LoadCalculatorTests {

    @Test
    fun testCalculateCTL() {
        val ctl = LoadCalculator.calculateCTL(listOf(100.0), previousCTL = 50.0)
        val expected = 50.0 + (1.0 / 42.0) * (100.0 - 50.0)
        assertEquals(expected, ctl, 0.01)
    }

    @Test
    fun testCalculateATL() {
        val atl = LoadCalculator.calculateATL(listOf(100.0), previousATL = 50.0)
        val expected = 50.0 + (1.0 / 7.0) * (100.0 - 50.0)
        assertEquals(expected, atl, 0.01)
    }

    @Test
    fun testCalculateTSB() {
        val tsb = LoadCalculator.calculateTSB(ctl = 70.0, atl = 60.0)
        assertEquals(10.0, tsb, 0.01)
    }

    @Test
    fun testTimeSeries() {
        val series = LoadCalculator.calculateTimeSeries(listOf(100.0, 100.0, 100.0))
        assertEquals(3, series.size)
        val last = series.last()
        assertTrue(last.first > 0) // CTL
        assertTrue(last.second > 0) // ATL
    }

    @Test
    fun testRampRateStatus() {
        assertEquals(RampRateStatus.DETRAINING, LoadCalculator.getRampRateStatus(-1.0))
        assertEquals(RampRateStatus.SAFE, LoadCalculator.getRampRateStatus(2.0))
        assertEquals(RampRateStatus.AGGRESSIVE, LoadCalculator.getRampRateStatus(4.0))
        assertEquals(RampRateStatus.DANGEROUS, LoadCalculator.getRampRateStatus(6.0))
    }
}

class PhysiologyModifierTests {

    @Test
    fun testHRVModifierPositive() {
        val mod = PhysiologyModifier.calculateHRVModifier(currentHRV = 130.0, baselineHRV = 100.0)
        assertEquals(20.0, mod, 0.1)
    }

    @Test
    fun testHRVModifierNegative() {
        val mod = PhysiologyModifier.calculateHRVModifier(currentHRV = 70.0, baselineHRV = 100.0)
        assertEquals(-20.0, mod, 0.1)
    }

    @Test
    fun testRHRModifierPositive() {
        val mod = PhysiologyModifier.calculateRHRModifier(currentRHR = 55.0, baselineRHR = 60.0)
        assertEquals(20.0, mod, 0.1)
    }

    @Test
    fun testRHRModifierNegative() {
        val mod = PhysiologyModifier.calculateRHRModifier(currentRHR = 65.0, baselineRHR = 60.0)
        assertEquals(-20.0, mod, 0.1)
    }

    @Test
    fun testCombinedModifierWeighted() {
        val combined = PhysiologyModifier.calculateCombinedModifier(hrvModifier = 10.0, rhrModifier = 20.0)
        val expected = 10.0 * 0.7 + 20.0 * 0.3
        assertEquals(expected, combined, 0.1)
    }

    @Test
    fun testDetectIllness() {
        assertEquals(1.0, PhysiologyModifier.detectIllness(hrvModifier = -15.0, rhrModifier = -15.0), 0.0)
        assertEquals(0.7, PhysiologyModifier.detectIllness(hrvModifier = -10.0, rhrModifier = -10.0), 0.0)
        assertEquals(0.3, PhysiologyModifier.detectIllness(hrvModifier = -5.0, rhrModifier = 0.0), 0.0)
        assertEquals(0.0, PhysiologyModifier.detectIllness(hrvModifier = 0.0, rhrModifier = 0.0), 0.0)
    }
}

class GuidanceEngineTests {

    @Test
    fun testGetReadinessZone() {
        assertEquals(com.example.onmytss.domain.model.enums.ReadinessZone.OVERREACHING, GuidanceEngine.getReadinessZone(-20.0))
        assertEquals(com.example.onmytss.domain.model.enums.ReadinessZone.MAINTAIN, GuidanceEngine.getReadinessZone(0.0))
        assertEquals(com.example.onmytss.domain.model.enums.ReadinessZone.BUILD_INTENSITY, GuidanceEngine.getReadinessZone(20.0))
    }

    @Test
    fun testRecommendedTSSRange() {
        val rec = GuidanceEngine.getRecommendedTSSRange(bodyBatteryScore = 50, tsb = 0.0, ctl = 70.0)
        assertTrue(rec.min > 0)
        assertTrue(rec.max >= rec.min)
        assertEquals(com.example.onmytss.domain.model.enums.TSSIntensity.TEMPO, rec.intensity)
    }

    @Test
    fun testTrainingSuggestions() {
        val suggestions = GuidanceEngine.getTrainingSuggestions(
            bodyBatteryScore = 50, tsb = 0.0, ctl = 70.0, atl = 60.0,
            rampRate = 6.0, recentTSS = List(7) { 100.0 }
        )
        assertTrue(suggestions.isNotEmpty())
    }

    @Test
    fun testWeeklyPlan() {
        val plan = GuidanceEngine.getWeeklyPlan(ctl = 70.0, atl = 60.0, tsb = 10.0)
        assertEquals(7, plan.dailyTSS.size)
        assertTrue(plan.totalTSS > 0)
    }
}

class SleepAnalyzerTests {

    @Test
    fun testCalculateSleepQualityOptimal() {
        val base = java.util.Date().time
        val samples = listOf(
            SleepSample(java.util.Date(base), java.util.Date(base + 8 * 3600 * 1000), SleepStage.DEEP),
            SleepSample(java.util.Date(base + 8 * 3600 * 1000), java.util.Date(base + 16 * 3600 * 1000), SleepStage.DEEP)
        )
        val quality = SleepAnalyzer.calculateSleepQuality(samples)
        assertTrue(quality != null)
    }
}
