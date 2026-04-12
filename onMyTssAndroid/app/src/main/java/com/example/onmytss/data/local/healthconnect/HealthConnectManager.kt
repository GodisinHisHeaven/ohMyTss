package com.example.onmytss.data.local.healthconnect

import android.content.Context
import androidx.health.connect.client.HealthConnectClient
import androidx.health.connect.client.records.ExerciseSessionRecord
import androidx.health.connect.client.records.HeartRateRecord
import androidx.health.connect.client.records.HeartRateVariabilityRmssdRecord
import androidx.health.connect.client.records.SleepSessionRecord
import androidx.health.connect.client.request.ReadRecordsRequest
import androidx.health.connect.client.time.TimeRangeFilter
import com.example.onmytss.domain.calculator.SleepStage
import com.example.onmytss.domain.calculator.SleepSample
import com.example.onmytss.domain.model.Workout
import com.example.onmytss.domain.model.enums.Sport
import dagger.hilt.android.qualifiers.ApplicationContext
import java.time.Instant
import java.util.Date
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class HealthConnectManager @Inject constructor(
    @ApplicationContext private val context: Context
) {

    private val client by lazy { HealthConnectClient.getOrCreate(context) }

    fun isAvailable(): Boolean {
        return try {
            val status = HealthConnectClient.getSdkStatus(context)
            status == HealthConnectClient.SDK_AVAILABLE
        } catch (e: Exception) {
            false
        }
    }

    suspend fun readExerciseSessions(start: Instant, end: Instant): List<Workout> {
        val request = ReadRecordsRequest(
            recordType = ExerciseSessionRecord::class,
            timeRangeFilter = TimeRangeFilter.between(start, end)
        )
        val response = client.readRecords(request)
        return response.records.map { record ->
            val sport = mapExerciseTypeToSport(record.exerciseType)
            Workout(
                id = record.metadata.id,
                date = Date(record.startTime.toEpochMilli()),
                startTime = Date(record.startTime.toEpochMilli()),
                duration = (record.endTime.epochSecond - record.startTime.epochSecond).toDouble().coerceAtLeast(0.0),
                workoutType = sport,
                source = "healthConnect"
            )
        }
    }

    suspend fun readHeartRateSamples(start: Instant, end: Instant): List<Double> {
        val request = ReadRecordsRequest(
            recordType = HeartRateRecord::class,
            timeRangeFilter = TimeRangeFilter.between(start, end)
        )
        val response = client.readRecords(request)
        return response.records.flatMap { record ->
            record.samples.map { it.beatsPerMinute.toDouble() }
        }
    }

    suspend fun readHRVSamples(start: Instant, end: Instant): List<Double> {
        val request = ReadRecordsRequest(
            recordType = HeartRateVariabilityRmssdRecord::class,
            timeRangeFilter = TimeRangeFilter.between(start, end)
        )
        val response = client.readRecords(request)
        return response.records.map { it.heartRateVariabilityMillis }
    }

    suspend fun readSleepSamples(start: Instant, end: Instant): List<SleepSample> {
        val request = ReadRecordsRequest(
            recordType = SleepSessionRecord::class,
            timeRangeFilter = TimeRangeFilter.between(start, end)
        )
        val response = client.readRecords(request)
        val samples = mutableListOf<SleepSample>()
        for (session in response.records) {
            for (stage in session.stages) {
                val sleepStage = when (stage.stage) {
                    SleepSessionRecord.STAGE_TYPE_AWAKE -> SleepStage.AWAKE
                    SleepSessionRecord.STAGE_TYPE_LIGHT -> SleepStage.LIGHT
                    SleepSessionRecord.STAGE_TYPE_DEEP -> SleepStage.DEEP
                    SleepSessionRecord.STAGE_TYPE_REM -> SleepStage.REM
                    else -> SleepStage.UNKNOWN
                }
                samples.add(
                    SleepSample(
                        startDate = Date(stage.startTime.toEpochMilli()),
                        endDate = Date(stage.endTime.toEpochMilli()),
                        stage = sleepStage
                    )
                )
            }
        }
        return samples
    }

    private fun mapExerciseTypeToSport(type: Int): Sport {
        return when (type) {
            ExerciseSessionRecord.EXERCISE_TYPE_BIKING,
            ExerciseSessionRecord.EXERCISE_TYPE_BIKING_STATIONARY -> Sport.CYCLING
            ExerciseSessionRecord.EXERCISE_TYPE_RUNNING,
            ExerciseSessionRecord.EXERCISE_TYPE_RUNNING_TREADMILL -> Sport.RUNNING
            ExerciseSessionRecord.EXERCISE_TYPE_SWIMMING_POOL,
            ExerciseSessionRecord.EXERCISE_TYPE_SWIMMING_OPEN_WATER -> Sport.SWIMMING
            ExerciseSessionRecord.EXERCISE_TYPE_WALKING -> Sport.WALKING
            ExerciseSessionRecord.EXERCISE_TYPE_HIKING -> Sport.HIKING
            ExerciseSessionRecord.EXERCISE_TYPE_ROWING,
            ExerciseSessionRecord.EXERCISE_TYPE_ROWING_MACHINE -> Sport.ROWING
            ExerciseSessionRecord.EXERCISE_TYPE_STRENGTH_TRAINING -> Sport.CROSS_TRAINING
            ExerciseSessionRecord.EXERCISE_TYPE_ELLIPTICAL -> Sport.ELLIPTICAL
            ExerciseSessionRecord.EXERCISE_TYPE_YOGA -> Sport.YOGA
            ExerciseSessionRecord.EXERCISE_TYPE_PILATES -> Sport.PILATES
            else -> Sport.OTHER
        }
    }
}
