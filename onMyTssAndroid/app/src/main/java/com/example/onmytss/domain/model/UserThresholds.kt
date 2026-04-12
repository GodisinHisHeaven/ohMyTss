package com.example.onmytss.domain.model

import com.example.onmytss.domain.model.enums.Sport

data class UserThresholds(
    val id: Int = 1,
    val cyclingFTP: Int? = null,
    val maxHeartRate: Int? = 190,
    val preferredUnitSystem: String = "metric",
    val preferredSports: List<Sport> = listOf(Sport.CYCLING),
    val hasCompletedOnboarding: Boolean = false
)
