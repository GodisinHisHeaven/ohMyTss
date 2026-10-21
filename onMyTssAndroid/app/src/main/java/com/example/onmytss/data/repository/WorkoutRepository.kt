package com.example.onmytss.data.repository

import com.example.onmytss.data.local.db.dao.WorkoutDao
import com.example.onmytss.data.local.db.entity.WorkoutEntity
import com.example.onmytss.domain.model.Workout
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map
import java.util.Date
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class WorkoutRepository @Inject constructor(
    private val dao: WorkoutDao
) {
    suspend fun save(workout: Workout) = dao.insert(workout.toEntity())

    suspend fun saveAll(workouts: List<Workout>) = dao.insertAll(workouts.map { it.toEntity() })

    suspend fun getById(id: String): Workout? = dao.getById(id)?.toDomain()

    suspend fun getByDateRange(start: Date, end: Date): List<Workout> =
        dao.getByDateRange(start, end).map { it.toDomain() }

    fun getByDateRangeFlow(start: Date, end: Date): Flow<List<Workout>> =
        dao.getByDateRangeFlow(start, end).map { list -> list.map { it.toDomain() } }

    suspend fun deleteAll() = dao.deleteAll()
}

fun WorkoutEntity.toDomain() = Workout(
    id = id,
    date = date,
    startTime = startTime,
    duration = duration,
    workoutType = workoutType,
    distance = distance,
    tss = tss,
    calculationMethod = calculationMethod,
    source = source,
    averagePower = averagePower,
    normalizedPower = normalizedPower,
    averageHeartRate = averageHeartRate,
    maxHeartRate = maxHeartRate
)

fun Workout.toEntity() = WorkoutEntity(
    id = id,
    date = date,
    startTime = startTime,
    duration = duration,
    workoutType = workoutType,
    distance = distance,
    tss = tss,
    calculationMethod = calculationMethod,
    source = source,
    averagePower = averagePower,
    normalizedPower = normalizedPower,
    averageHeartRate = averageHeartRate,
    maxHeartRate = maxHeartRate
)
