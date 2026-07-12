package com.example.onmytss.domain.engine

import com.example.onmytss.data.local.healthconnect.HealthConnectManager
import com.example.onmytss.data.repository.UserThresholdsRepository
import com.example.onmytss.domain.calculator.TSSCalculator
import com.example.onmytss.domain.model.Workout
import java.time.Instant
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class WorkoutAggregator @Inject constructor(
    private val healthConnectManager: HealthConnectManager,
    private val userThresholdsRepository: UserThresholdsRepository
) {

    /**
     * Fetch exercise sessions from Health Connect and compute TSS for each.
     * Health Connect sessions carry no TSS, so we derive it here:
     * heart-rate based (TRIMP) when HR samples exist for the session window,
     * otherwise a duration/sport-based estimate — mirroring the iOS pipeline.
     */
    suspend fun fetchWorkouts(start: Instant, end: Instant): List<Workout> {
        if (!healthConnectManager.isAvailable()) return emptyList()
        val sessions = healthConnectManager.readExerciseSessions(start, end)
        if (sessions.isEmpty()) return emptyList()

        val thresholds = userThresholdsRepository.getOrCreate()

        return sessions.map { workout ->
            val sessionStart = Instant.ofEpochMilli(workout.startTime.time)
            val sessionEnd = sessionStart.plusSeconds(workout.duration.toLong())

            // HR read failures (e.g. permission revoked) shouldn't drop the
            // workout; fall back to the duration estimate instead.
            val hrSamples = runCatching {
                healthConnectManager.readHeartRateSamples(sessionStart, sessionEnd)
            }.getOrDefault(emptyList())

            if (hrSamples.isNotEmpty()) {
                workout.copy(
                    tss = TSSCalculator.calculateTSSFromHeartRate(
                        heartRateValues = hrSamples,
                        duration = workout.duration,
                        maxHeartRate = thresholds.maxHeartRate
                    ),
                    calculationMethod = "hr",
                    averageHeartRate = hrSamples.average(),
                    maxHeartRate = hrSamples.max()
                )
            } else {
                workout.copy(
                    tss = TSSCalculator.estimateTSSFromDuration(workout),
                    calculationMethod = "duration"
                )
            }
        }
    }
}
