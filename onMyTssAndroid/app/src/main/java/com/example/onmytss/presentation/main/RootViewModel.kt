package com.example.onmytss.presentation.main

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.example.onmytss.data.local.healthconnect.HealthConnectPermissionHelper
import com.example.onmytss.data.repository.UserThresholdsRepository
import com.example.onmytss.domain.engine.BodyBatteryEngine
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject

@HiltViewModel
class RootViewModel @Inject constructor(
    private val userThresholdsRepository: UserThresholdsRepository,
    private val bodyBatteryEngine: BodyBatteryEngine,
    val permissionHelper: HealthConnectPermissionHelper
) : ViewModel() {

    private val _onboardingComplete = MutableStateFlow<Boolean?>(null)
    val onboardingComplete: StateFlow<Boolean?> = _onboardingComplete.asStateFlow()

    init {
        viewModelScope.launch {
            val thresholds = userThresholdsRepository.getOrCreate()
            _onboardingComplete.value = thresholds.hasCompletedOnboarding
        }
    }

    fun completeOnboarding(ftp: Int) {
        viewModelScope.launch {
            userThresholdsRepository.updateFTP(ftp)
            userThresholdsRepository.markOnboardingComplete()
            _onboardingComplete.value = true
            bodyBatteryEngine.recomputeAll()
        }
    }
}
