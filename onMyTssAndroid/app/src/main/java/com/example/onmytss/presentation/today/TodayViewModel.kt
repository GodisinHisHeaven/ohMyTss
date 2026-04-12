package com.example.onmytss.presentation.today

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.example.onmytss.domain.engine.BodyBatteryEngine
import com.example.onmytss.domain.model.DayAggregate
import com.example.onmytss.domain.model.TSSRecommendation
import com.example.onmytss.domain.model.enums.Trend
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import javax.inject.Inject

data class TodayUiState(
    val isLoading: Boolean = true,
    val aggregate: DayAggregate? = null,
    val trend: Trend = Trend.STABLE,
    val tssRecommendation: TSSRecommendation? = null,
    val recentScores: List<Int> = emptyList(),
    val error: String? = null
)

@HiltViewModel
class TodayViewModel @Inject constructor(
    private val bodyBatteryEngine: BodyBatteryEngine
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
                val recentScores = bodyBatteryEngine.getRecentScores(7)
                _uiState.update {
                    it.copy(
                        isLoading = false,
                        aggregate = aggregate,
                        trend = trend,
                        tssRecommendation = recommendation,
                        recentScores = recentScores
                    )
                }
            } catch (e: Exception) {
                _uiState.update { it.copy(isLoading = false, error = e.message) }
            }
        }
    }
}
