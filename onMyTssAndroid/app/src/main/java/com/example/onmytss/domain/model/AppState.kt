package com.example.onmytss.domain.model

import java.util.Date

data class AppState(
    val id: Int = 1,
    val lastHealthConnectSyncDate: Date? = null,
    val lastComputationDate: Date? = null,
    val isComputationInProgress: Boolean = false,
    val appInstallDate: Date = Date(),
    val lastOpenDate: Date? = null
)
