package com.example.onmytss.presentation.settings

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.example.onmytss.data.repository.AppStateRepository
import com.example.onmytss.data.repository.DayAggregateRepository
import com.example.onmytss.data.repository.UserThresholdsRepository
import com.example.onmytss.data.repository.WorkoutRepository
import com.example.onmytss.domain.Constants
import com.example.onmytss.domain.engine.BodyBatteryEngine
import com.example.onmytss.domain.model.UserThresholds
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import java.util.Date
import javax.inject.Inject

data class SettingsUiState(
    val ftp: Int = Constants.DEFAULT_FTP,
    val lastSyncText: String = "Never",
    val isSyncing: Boolean = false,
    val error: String? = null
)

@HiltViewModel
class SettingsViewModel @Inject constructor(
    private val userThresholdsRepository: UserThresholdsRepository,
    private val appStateRepository: AppStateRepository,
    private val bodyBatteryEngine: BodyBatteryEngine,
    private val dayAggregateRepository: DayAggregateRepository,
    private val workoutRepository: WorkoutRepository
) : ViewModel() {

    private val _uiState = MutableStateFlow(SettingsUiState())
    val uiState: StateFlow<SettingsUiState> = _uiState.asStateFlow()

    init {
        viewModelScope.launch {
            val thresholds = userThresholdsRepository.getOrCreate()
            val appState = appStateRepository.getOrCreate()
            _uiState.update {
                it.copy(
                    ftp = thresholds.cyclingFTP ?: Constants.DEFAULT_FTP,
                    lastSyncText = formatLastSync(appState.lastHealthConnectSyncDate)
                )
            }
        }
    }

    fun updateFTP(ftp: Int) {
        viewModelScope.launch {
            val validFtp = ftp.coerceIn(Constants.MIN_FTP, Constants.MAX_FTP)
            userThresholdsRepository.updateFTP(validFtp)
            _uiState.update { it.copy(ftp = validFtp) }
            bodyBatteryEngine.recomputeAll()
        }
    }

    fun syncData() {
        viewModelScope.launch {
            _uiState.update { it.copy(isSyncing = true, error = null) }
            try {
                bodyBatteryEngine.recomputeAll()
                val appState = appStateRepository.getOrCreate()
                _uiState.update {
                    it.copy(
                        isSyncing = false,
                        lastSyncText = formatLastSync(appState.lastHealthConnectSyncDate)
                    )
                }
            } catch (e: Exception) {
                _uiState.update { it.copy(isSyncing = false, error = e.message) }
            }
        }
    }

    fun resetAllData() {
        viewModelScope.launch {
            dayAggregateRepository.deleteAll()
            workoutRepository.deleteAll()
            userThresholdsRepository.save(UserThresholds())
            appStateRepository.save(com.example.onmytss.domain.model.AppState())
            _uiState.update { SettingsUiState() }
        }
    }

    private fun formatLastSync(date: Date?): String {
        if (date == null) return "Never"
        val diff = System.currentTimeMillis() - date.time
        return when {
            diff < 60_000 -> "Just now"
            diff < 3_600_000 -> "${diff / 60_000}m ago"
            diff < 86_400_000 -> "${diff / 3_600_000}h ago"
            else -> "${diff / 86_400_000}d ago"
        }
    }
}
