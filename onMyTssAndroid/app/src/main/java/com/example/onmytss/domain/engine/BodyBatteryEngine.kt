package com.example.onmytss.domain.engine

import com.example.onmytss.data.local.healthconnect.HealthConnectManager
import com.example.onmytss.data.repository.AppStateRepository
import com.example.onmytss.data.repository.DayAggregateRepository
import com.example.onmytss.data.repository.UserThresholdsRepository
import com.example.onmytss.data.repository.WorkoutRepository
import com.example.onmytss.domain.Constants
import com.example.onmytss.domain.calculator.BodyBatteryCalculator
import com.example.onmytss.domain.calculator.GuidanceEngine
import com.example.onmytss.domain.calculator.LoadCalculator
import com.example.onmytss.domain.calculator.PhysiologyModifier
import com.example.onmytss.domain.calculator.SleepAnalyzer
import com.example.onmytss.domain.calculator.TSSCalculator
import com.example.onmytss.domain.model.DayAggregate
import com.example.onmytss.domain.calculator.SleepSample
import com.example.onmytss.domain.model.Workout
import com.example.onmytss.domain.model.enums.ReadinessLevel
import com.example.onmytss.domain.model.enums.Trend
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext
import java.time.Instant
import java.time.temporal.ChronoUnit
import java.util.Date
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class BodyBatteryEngine @Inject constructor(
    private val workoutRepository: WorkoutRepository,
    private val dayAggregateRepository: DayAggregateRepository,
    private val userThresholdsRepository: UserThresholdsRepository,
    private val appStateRepository: AppStateRepository,
    private val healthConnectManager: HealthConnectManager,
    private val workoutAggregator: WorkoutAggregator
) {

    suspend fun recomputeAll(days: Int = Constants.MAX_HISTORICAL_DAYS) = withContext(Dispatchers.Default) {
        appStateRepository.updateComputationInProgress(true)
        try {
            val thresholds = userThresholdsRepository.getOrCreate()
            val end = Instant.now()
            val start = end.minus(days.toLong(), ChronoUnit.DAYS)

            // Fetch workouts
            val workouts = workoutAggregator.fetchWorkouts(start, end)
            workoutRepository.saveAll(workouts)

            // Group workouts by day
            val dailyWorkouts = groupWorkoutsByDay(workouts)

            // Calculate daily TSS
            val dates = (0 until days).map { i ->
                Date.from(end.minus(i.toLong(), ChronoUnit.DAYS).truncatedTo(ChronoUnit.DAYS))
            }.reversed()

            val tssByDay = dates.associateWith { date ->
                dailyWorkouts[truncateToDay(date)]?.sumOf { it.tss } ?: 0.0
            }

            // Fetch physiology and sleep in parallel
            val hrvByDay = mutableMapOf<Date, List<Double>>()
            val rhrByDay = mutableMapOf<Date, List<Double>>()
            val sleepByDay = mutableMapOf<Date, List<SleepSample>>()

            if (healthConnectManager.isAvailable()) {
                dates.chunked(7).forEach { weekDates ->
                    val weekStart = Instant.ofEpochMilli(weekDates.first().time)
                    val weekEnd = Instant.ofEpochMilli(weekDates.last().time).plus(1, ChronoUnit.DAYS)

                    val hrv = healthConnectManager.readHRVSamples(weekStart, weekEnd)
                    val hr = healthConnectManager.readHeartRateSamples(weekStart, weekEnd)
                    val sleep = healthConnectManager.readSleepSamples(weekStart, weekEnd)

                    weekDates.forEach { date ->
                        val dayStart = date.time
                        val dayEnd = dayStart + 24 * 60 * 60 * 1000
                        hrvByDay[date] = hrv.filter { false } // placeholder: Health Connect doesn't tag samples by day directly in bulk read
                        rhrByDay[date] = hr.filter { false }
                        sleepByDay[date] = sleep.filter { it.startDate.time in dayStart until dayEnd }
                    }
                }
            }

            // Compute CTL/ATL/TSB time series
            val tssValues = dates.map { tssByDay[it] ?: 0.0 }
            val timeSeries = LoadCalculator.calculateTimeSeries(tssValues)

            // Compute 14-day baselines for HRV/RHR
            val allHRV = hrvByDay.values.flatten()
            val allRHR = rhrByDay.values.flatten()
            val baselineHRV = if (allHRV.size >= 3) PhysiologyModifier.calculateBaselineHRV(allHRV) else null
            val baselineRHR = if (allRHR.size >= 3) PhysiologyModifier.calculateBaselineRHR(allRHR) else null

            // Build DayAggregates
            val aggregates = dates.mapIndexed { index, date ->
                val (ctl, atl, tsb) = timeSeries[index]
                val dayWorkouts = dailyWorkouts[truncateToDay(date)] ?: emptyList()
                val dayTSS = tssByDay[date] ?: 0.0

                val rampRate = if (index >= 7) {
                    val prevCTL = timeSeries.getOrNull(index - 7)?.first ?: ctl
                    LoadCalculator.calculateCTLRampRate(ctl, prevCTL)
                } else null

                val dayHRV = hrvByDay[date]
                val dayRHR = rhrByDay[date]
                val hrvModifier = if (baselineHRV != null && !dayHRV.isNullOrEmpty()) {
                    PhysiologyModifier.calculateHRVModifier(dayHRV.average(), baselineHRV)
                } else null
                val rhrModifier = if (baselineRHR != null && !dayRHR.isNullOrEmpty()) {
                    val avgRHR = dayRHR.average()
                    PhysiologyModifier.calculateRHRModifier(avgRHR, baselineRHR)
                } else null

                val sleepSamples = sleepByDay[date]
                val sleepQuality = sleepSamples?.let { SleepAnalyzer.calculateSleepQuality(it) }

                val illnessLikelihood = PhysiologyModifier.detectIllness(hrvModifier, rhrModifier)
                val bodyBatteryScore = BodyBatteryCalculator.calculateScoreWithModifiers(tsb, hrvModifier, rhrModifier)

                DayAggregate(
                    date = date,
                    totalTSS = dayTSS,
                    ctl = ctl,
                    atl = atl,
                    tsb = tsb,
                    bodyBatteryScore = bodyBatteryScore,
                    rampRate = rampRate,
                    workoutCount = dayWorkouts.size,
                    maxTSSWorkout = dayWorkouts.maxByOrNull { it.tss }?.tss,
                    avgHRV = dayHRV?.average(),
                    avgRHR = dayRHR?.average(),
                    hrvModifier = hrvModifier,
                    rhrModifier = rhrModifier,
                    illnessLikelihood = illnessLikelihood,
                    sleepDuration = sleepQuality?.totalDuration,
                    sleepQualityScore = sleepQuality?.qualityScore,
                    deepSleepDuration = sleepQuality?.deepSleepDuration
                )
            }

            dayAggregateRepository.saveAll(aggregates)
            appStateRepository.updateLastSyncDate(Date())
        } finally {
            appStateRepository.updateComputationInProgress(false)
        }
    }

    suspend fun getTodayScore(): Int? {
        val today = truncateToDay(Date())
        return dayAggregateRepository.getByDate(today)?.bodyBatteryScore
    }

    suspend fun getRecentScores(days: Int = 7): List<Int> {
        val end = Date()
        val start = Date(System.currentTimeMillis() - days * 24 * 60 * 60 * 1000)
        return dayAggregateRepository.getRange(start, end).map { it.bodyBatteryScore }
    }

    suspend fun getTodayTrend(): Trend {
        val scores = getRecentScores(7)
        return BodyBatteryCalculator.calculateTrend(scores)
    }

    suspend fun getTodayTSSRecommendation(): com.example.onmytss.domain.model.TSSRecommendation? {
        val today = truncateToDay(Date())
        val aggregate = dayAggregateRepository.getByDate(today) ?: return null
        val thresholds = userThresholdsRepository.getOrCreate()
        val ctl = aggregate.ctl
        val tsb = aggregate.tsb
        val score = aggregate.bodyBatteryScore
        return GuidanceEngine.getRecommendedTSSRange(score, tsb, ctl)
    }

    suspend fun getTodayAggregate(): DayAggregate? {
        val today = truncateToDay(Date())
        return dayAggregateRepository.getByDate(today)
    }

    private fun groupWorkoutsByDay(workouts: List<Workout>): Map<Date, List<Workout>> {
        return workouts.groupBy { truncateToDay(it.date) }
    }

    private fun truncateToDay(date: Date): Date {
        val cal = java.util.Calendar.getInstance().apply { time = date }
        cal.set(java.util.Calendar.HOUR_OF_DAY, 0)
        cal.set(java.util.Calendar.MINUTE, 0)
        cal.set(java.util.Calendar.SECOND, 0)
        cal.set(java.util.Calendar.MILLISECOND, 0)
        return cal.time
    }
}
