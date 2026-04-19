package com.example.onmytss.domain.engine

import com.example.onmytss.data.local.healthconnect.HealthConnectManager
import com.example.onmytss.domain.model.Workout
import java.time.Instant
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class WorkoutAggregator @Inject constructor(
    private val healthConnectManager: HealthConnectManager
) {

    suspend fun fetchWorkouts(start: Instant, end: Instant): List<Workout> {
        if (!healthConnectManager.isAvailable()) return emptyList()
        return healthConnectManager.readExerciseSessions(start, end)
    }
}
