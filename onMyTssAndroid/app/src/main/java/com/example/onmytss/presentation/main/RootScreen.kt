package com.example.onmytss.presentation.main

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.health.connect.client.PermissionController
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.example.onmytss.data.local.healthconnect.HealthConnectPermissionHelper
import com.example.onmytss.presentation.onboarding.HealthPermissionScreen
import com.example.onmytss.presentation.onboarding.ThresholdInputScreen
import com.example.onmytss.presentation.onboarding.WelcomeScreen

@Composable
fun RootScreen(
    viewModel: RootViewModel = hiltViewModel(),
    permissionHelper: HealthConnectPermissionHelper = hiltViewModel<RootViewModel>().permissionHelper
) {
    val onboardingComplete by viewModel.onboardingComplete.collectAsStateWithLifecycle()
    var onboardingStep by remember { mutableIntStateOf(0) }
    var healthPermissionsGranted by remember { mutableStateOf(false) }

    val permissionLauncher = rememberLauncherForActivityResult(
        contract = PermissionController.createRequestPermissionResultContract()
    ) { granted: Set<String> ->
        healthPermissionsGranted = granted.isNotEmpty()
    }

    LaunchedEffect(onboardingComplete) {
        if (onboardingComplete == true) {
            onboardingStep = 3
        }
    }

    when (onboardingStep) {
        0 -> WelcomeScreen(onNext = { onboardingStep = 1 })
        1 -> HealthPermissionScreen(
            permissionsLauncher = permissionLauncher,
            permissions = permissionHelper.permissionStrings,
            onNext = { onboardingStep = 2 }
        )
        2 -> ThresholdInputScreen(onComplete = { ftp ->
            viewModel.completeOnboarding(ftp)
            onboardingStep = 3
        })
        else -> MainScreen()
    }
}
