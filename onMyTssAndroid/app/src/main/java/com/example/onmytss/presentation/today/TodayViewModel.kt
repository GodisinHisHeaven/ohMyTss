package com.example.onmytss.presentation.today

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.example.onmytss.domain.calculator.BodyBatteryCalculator
import com.example.onmytss.domain.calculator.LoadCalculator
import com.example.onmytss.domain.engine.BodyBatteryEngine
import com.example.onmytss.domain.model.DayAggregate
import com.example.onmytss.domain.model.TSSRecommendation
import com.example.onmytss.domain.model.enums.RampRateStatus
import com.example.onmytss.domain.model.enums.ReadinessLevel
import com.example.onmytss.domain.model.enums.Trend
import com.example.onmytss.data.repository.DayAggregateRepository
import com.example.onmytss.presentation.components.DayScore
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import java.util.Calendar
import java.util.Date
import javax.inject.Inject
import kotlin.math.abs
import kotlin.math.roundToInt

data class TodayUiState(
    val isLoading: Boolean = true,
    val aggregate: DayAggregate? = null,
    val trend: Trend = Trend.STABLE,
    val tssRecommendation: TSSRecommendation? = null,
    val weekScores: List<DayScore> = emptyList(),
    val error: String? = null
) {
    val score: Int get() = aggregate?.bodyBatteryScore ?: 50
    val readinessLevel: ReadinessLevel
        get() = BodyBatteryCalculator.getReadinessLevel(score)
    val readinessDescription: String get() = readinessLevel.description

    val tsbFormatted: String get() {
        val v = aggregate?.tsb ?: 0.0
        val rounded = v.roundToInt()
        return if (v > 0) "+$rounded" else "$rounded"
    }
    val ctlFormatted: String get() = "${(aggregate?.ctl ?: 0.0).roundToInt()}"
    val atlFormatted: String get() = "${(aggregate?.atl ?: 0.0).roundToInt()}"

    val hasPhysiologyData: Boolean
        get() = aggregate?.avgHRV != null || aggregate?.avgRHR != null

    val hrvFormatted: String?
        get() = aggregate?.avgHRV?.let { "${it.roundToInt()} ms" }
    val rhrFormatted: String?
        get() = aggregate?.avgRHR?.let { "${it.roundToInt()} bpm" }
    val hrvModifierFormatted: String?
        get() = aggregate?.hrvModifier?.let { formatModifier(it) }
    val rhrModifierFormatted: String?
        get() = aggregate?.rhrModifier?.let { formatModifier(it) }

    val combinedModifierFormatted: String?
        get() {
            val h = aggregate?.hrvModifier
            val r = aggregate?.rhrModifier
            if (h == null && r == null) return null
            val combined = (h ?: 0.0) + (r ?: 0.0)
            return formatModifier(combined)
        }

    val recoveryStatus: String? get() = when {
        !hasPhysiologyData -> null
        else -> {
            val m = (aggregate?.hrvModifier ?: 0.0) + (aggregate?.rhrModifier ?: 0.0)
            when {
                m > 5 -> "Excellent Recovery"
                m > 0 -> "Good Recovery"
                m > -5 -> "Moderate Recovery"
                else -> "Poor Recovery"
            }
        }
    }

    val hasSleepData: Boolean get() = aggregate?.sleepDuration != null
    val sleepDurationFormatted: String?
        get() = aggregate?.sleepDuration?.let { formatDuration(it) }
    val deepSleepFormatted: String?
        get() = aggregate?.deepSleepDuration?.let { formatDuration(it) }
    val sleepQualityFormatted: String?
        get() = aggregate?.sleepQualityScore?.let { "$it/100" }
    val sleepQualityDescription: String? get() {
        val q = aggregate?.sleepQualityScore ?: return null
        return when {
            q >= 85 -> "Excellent sleep"
            q >= 70 -> "Good sleep"
            q >= 50 -> "Fair sleep"
            else -> "Poor sleep"
        }
    }

    val rampRateStatus: String? get() {
        val rr = aggregate?.rampRate ?: return null
        val status = LoadCalculator.getRampRateStatus(rr)
        val sign = if (rr >= 0) "+" else ""
        val ratePart = "$sign${"%.1f".format(rr)} CTL/wk"
        return "${status.displayName} • $ratePart"
    }

    val todayTSS: Int get() = (aggregate?.totalTSS ?: 0.0).roundToInt()
    val todayWorkoutCount: Int get() = aggregate?.workoutCount ?: 0

    val showEmptyState: Boolean
        get() = !isLoading && aggregate == null && weekScores.isEmpty()

    val illnessAlertVisible: Boolean
        get() = (aggregate?.illnessLikelihood ?: 0.0) >= 0.7
}

private fun formatModifier(value: Double): String {
    val rounded = value.roundToInt()
    return when {
        rounded > 0 -> "+$rounded"
        rounded < 0 -> "$rounded"
        else -> "0"
    }
}

private fun formatDuration(hoursOrSeconds: Double): String {
    // Values in DayAggregate are Double hours in our iOS contract.
    // Our Android engine stores hours via SleepAnalyzer; keep hours path.
    val h = hoursOrSeconds.toInt()
    val m = ((hoursOrSeconds - h) * 60).roundToInt()
    return "${h}h ${m}m"
}

@HiltViewModel
class TodayViewModel @Inject constructor(
    private val bodyBatteryEngine: BodyBatteryEngine,
    private val dayAggregateRepository: DayAggregateRepository
) : ViewModel() {

    private val _uiState = MutableStateFlow(TodayUiState())
    val uiState: StateFlow<TodayUiState> = _uiState.asStateFlow()

    init {
        loadData()
    }

    fun loadData() {
        viewModelScope.launch {
            _uiState.update { it.copy(isLoading = true, error = null) }
            try {
                bodyBatteryEngine.recomputeAll()
                val aggregate = bodyBatteryEngine.getTodayAggregate()
                val trend = bodyBatteryEngine.getTodayTrend()
                val recommendation = bodyBatteryEngine.getTodayTSSRecommendation()
                val weekScores = loadRecentDayScores(7)
                _uiState.update {
                    it.copy(
                        isLoading = false,
                        aggregate = aggregate,
                        trend = trend,
                        tssRecommendation = recommendation,
                        weekScores = weekScores
                    )
                }
            } catch (e: Exception) {
                _uiState.update { it.copy(isLoading = false, error = e.message) }
            }
        }
    }

    suspend fun refresh() = loadData()

    private suspend fun loadRecentDayScores(days: Int): List<DayScore> {
        val cal = Calendar.getInstance().apply {
            set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
        }
        val end = cal.time
        cal.add(Calendar.DAY_OF_YEAR, -(days - 1))
        val start = cal.time
        val aggregates = dayAggregateRepository.getRange(start, Date(end.time + 24 * 3600 * 1000))
        val byDay = aggregates.associateBy { truncate(it.date) }
        return (0 until days).map { offset ->
            val c = Calendar.getInstance().apply {
                time = start
                add(Calendar.DAY_OF_YEAR, offset)
            }
            val d = truncate(c.time)
            DayScore(date = d, score = byDay[d]?.bodyBatteryScore ?: 0)
        }
    }

    private fun truncate(date: Date): Date {
        val c = Calendar.getInstance().apply {
            time = date
            set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
        }
        return c.time
    }
}
