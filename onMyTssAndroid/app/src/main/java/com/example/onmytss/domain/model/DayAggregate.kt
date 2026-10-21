package com.example.onmytss.domain.model

import java.util.Date

data class DayAggregate(
    val date: Date,
    val totalTSS: Double = 0.0,
    val ctl: Double = 0.0,
    val atl: Double = 0.0,
    val tsb: Double = 0.0,
    val bodyBatteryScore: Int = 50,
    val rampRate: Double? = null,
    val workoutCount: Int = 0,
    val maxTSSWorkout: Double? = null,
    val avgHRV: Double? = null,
    val avgRHR: Double? = null,
    val hrvModifier: Double? = null,
    val rhrModifier: Double? = null,
    val illnessLikelihood: Double = 0.0,
    val sleepDuration: Double? = null,
    val sleepQualityScore: Int? = null,
    val deepSleepDuration: Double? = null
)
