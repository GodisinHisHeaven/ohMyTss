package com.example.onmytss.data.local.db.entity

import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey
import java.util.Date

@Entity(
    tableName = "day_aggregates",
    indices = [Index(value = ["date"], unique = true)]
)
data class DayAggregateEntity(
    @PrimaryKey(autoGenerate = true)
    val id: Long = 0,
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
