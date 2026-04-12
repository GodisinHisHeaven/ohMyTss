package com.example.onmytss.domain.model

import com.example.onmytss.domain.model.enums.Sport
import java.util.Date

data class Workout(
    val id: String,
    val date: Date,
    val startTime: Date,
    val duration: Double, // seconds
    val workoutType: Sport,
    val distance: Double? = null,
    val tss: Double = 0.0,
    val calculationMethod: String = "unknown",
    val source: String = "healthConnect",
    val averagePower: Double? = null,
    val normalizedPower: Double? = null,
    val averageHeartRate: Double? = null,
    val maxHeartRate: Double? = null
)
