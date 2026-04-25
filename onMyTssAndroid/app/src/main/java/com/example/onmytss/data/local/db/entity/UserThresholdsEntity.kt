package com.example.onmytss.data.local.db.entity

import androidx.room.Entity
import androidx.room.PrimaryKey
import com.example.onmytss.domain.model.enums.Sport

@Entity(tableName = "user_thresholds")
data class UserThresholdsEntity(
    @PrimaryKey
    val id: Int = 1,
    val cyclingFTP: Int? = null,
    val maxHeartRate: Int? = 190,
    val preferredUnitSystem: String = "metric",
    val preferredSports: List<Sport> = listOf(Sport.CYCLING),
    val hasCompletedOnboarding: Boolean = false
)
