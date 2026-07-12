package com.example.onmytss.presentation.history

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.example.onmytss.data.repository.DayAggregateRepository
import com.example.onmytss.domain.model.DayAggregate
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale
import javax.inject.Inject
import kotlin.math.roundToInt

data class HistoryItem(
    val date: Date,
    val score: Int,
    val ctl: Double,
    val atl: Double,
    val tsb: Double,
    val tss: Double,
    val workoutCount: Int
) {
    val isToday: Boolean get() {
        val today = truncateToDay(Date())
        return truncateToDay(date) == today
    }
    val weekdayDisplay: String
        get() = SimpleDateFormat("EEE", Locale.getDefault()).format(date)
    val dateDisplay: String
        get() = SimpleDateFormat("MMM d", Locale.getDefault()).format(date)
    val tsbDisplay: String
        get() {
            val v = tsb.roundToInt()
            return if (v > 0) "+$v" else "$v"
        }
}

data class ChartPoint(
    val date: Date,
    val ctl: Double,
    val atl: Double,
    val tsb: Double,
    val tss: Double
)

data class HistoryUiState(
    val isLoading: Boolean = true,
    val selectedDays: Int = 30,
    val items: List<HistoryItem> = emptyList(),
    val chartData: List<ChartPoint> = emptyList()
) {
    val showEmptyState: Boolean get() = !isLoading && items.isEmpty()
    val averageScore: Int
        get() = if (items.isEmpty()) 0 else items.map { it.score }.average().roundToInt()
    val averageCTL: Int
        get() = if (items.isEmpty()) 0 else items.map { it.ctl }.average().roundToInt()
    val totalTSS: Int
        get() = items.sumOf { it.tss }.roundToInt()
    val totalWorkouts: Int
        get() = items.sumOf { it.workoutCount }
}

@HiltViewModel
class HistoryViewModel @Inject constructor(
    private val dayAggregateRepository: DayAggregateRepository
) : ViewModel() {

    private val _uiState = MutableStateFlow(HistoryUiState())
    val uiState: StateFlow<HistoryUiState> = _uiState.asStateFlow()

    init { loadHistory() }

    fun loadHistory() {
        viewModelScope.launch {
            _uiState.update { it.copy(isLoading = true) }
            val aggregates = fetchRange(_uiState.value.selectedDays)
            _uiState.update {
                it.copy(
                    isLoading = false,
                    items = aggregates.map(::toItem).sortedByDescending { row -> row.date },
                    chartData = aggregates.map(::toChartPoint).sortedBy { p -> p.date }
                )
            }
        }
    }

    fun changeDaysSelection(days: Int) {
        _uiState.update { it.copy(selectedDays = days) }
        loadHistory()
    }

    private suspend fun fetchRange(days: Int): List<DayAggregate> {
        val cal = Calendar.getInstance().apply {
            set(Calendar.HOUR_OF_DAY, 23); set(Calendar.MINUTE, 59)
            set(Calendar.SECOND, 59); set(Calendar.MILLISECOND, 999)
        }
        val end = cal.time
        cal.add(Calendar.DAY_OF_YEAR, -(days - 1))
        cal.set(Calendar.HOUR_OF_DAY, 0); cal.set(Calendar.MINUTE, 0)
        cal.set(Calendar.SECOND, 0); cal.set(Calendar.MILLISECOND, 0)
        val start = cal.time
        return dayAggregateRepository.getRange(start, end)
    }

    private fun toItem(a: DayAggregate) = HistoryItem(
        date = a.date,
        score = a.bodyBatteryScore,
        ctl = a.ctl,
        atl = a.atl,
        tsb = a.tsb,
        tss = a.totalTSS,
        workoutCount = a.workoutCount
    )

    private fun toChartPoint(a: DayAggregate) = ChartPoint(
        date = a.date, ctl = a.ctl, atl = a.atl, tsb = a.tsb, tss = a.totalTSS
    )
}

private fun truncateToDay(date: Date): Date {
    val c = Calendar.getInstance().apply {
        time = date
        set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0)
        set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
    }
    return c.time
}
