package com.example.onmytss.domain.model

import java.util.Date

data class SleepQuality(
    val totalDuration: Double, // seconds
    val deepSleepDuration: Double, // seconds
    val remDuration: Double, // seconds
    val awakeTime: Double, // seconds
    val qualityScore: Int, // 0-100
    val startTime: Date,
    val endTime: Date
) {
    val durationHours: Double get() = totalDuration / 3600.0
    val deepSleepHours: Double get() = deepSleepDuration / 3600.0
    val remHours: Double get() = remDuration / 3600.0
    val awakeMinutes: Double get() = awakeTime / 60.0
}
