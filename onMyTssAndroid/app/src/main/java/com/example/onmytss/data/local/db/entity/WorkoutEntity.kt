package com.example.onmytss.data.local.db.entity

import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey
import com.example.onmytss.domain.model.enums.Sport
import java.util.Date

@Entity(
    tableName = "workouts",
    indices = [
        Index(value = ["id"], unique = true),
        Index(value = ["date"]),
        Index(value = ["source"])
    ]
)
data class WorkoutEntity(
    @PrimaryKey
    val id: String,
    val date: Date,
    val startTime: Date,
    val duration: Double,
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
