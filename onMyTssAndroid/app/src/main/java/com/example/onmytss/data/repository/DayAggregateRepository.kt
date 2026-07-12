package com.example.onmytss.data.repository

import com.example.onmytss.data.local.db.dao.DayAggregateDao
import com.example.onmytss.data.local.db.entity.DayAggregateEntity
import com.example.onmytss.domain.model.DayAggregate
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map
import java.util.Date
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class DayAggregateRepository @Inject constructor(
    private val dao: DayAggregateDao
) {
    suspend fun save(aggregate: DayAggregate) = dao.insert(aggregate.toEntity())

    suspend fun saveAll(aggregates: List<DayAggregate>) = dao.insertAll(aggregates.map { it.toEntity() })

    suspend fun getByDate(date: Date): DayAggregate? = dao.getByDate(date)?.toDomain()

    suspend fun getRange(start: Date, end: Date): List<DayAggregate> = dao.getRange(start, end).map { it.toDomain() }

    fun getRangeFlow(start: Date, end: Date): Flow<List<DayAggregate>> =
        dao.getRangeFlow(start, end).map { list -> list.map { it.toDomain() } }

    suspend fun getRecent(limit: Int): List<DayAggregate> = dao.getRecent(limit).map { it.toDomain() }

    suspend fun getLatest(): DayAggregate? = dao.getLatest()?.toDomain()

    suspend fun deleteAll() = dao.deleteAll()
}

fun DayAggregateEntity.toDomain() = DayAggregate(
    date = date,
    totalTSS = totalTSS,
    ctl = ctl,
    atl = atl,
    tsb = tsb,
    bodyBatteryScore = bodyBatteryScore,
    rampRate = rampRate,
    workoutCount = workoutCount,
    maxTSSWorkout = maxTSSWorkout,
    avgHRV = avgHRV,
    avgRHR = avgRHR,
    hrvModifier = hrvModifier,
    rhrModifier = rhrModifier,
    illnessLikelihood = illnessLikelihood,
    sleepDuration = sleepDuration,
    sleepQualityScore = sleepQualityScore,
    deepSleepDuration = deepSleepDuration
)

fun DayAggregate.toEntity() = DayAggregateEntity(
    date = date,
    totalTSS = totalTSS,
    ctl = ctl,
    atl = atl,
    tsb = tsb,
    bodyBatteryScore = bodyBatteryScore,
    rampRate = rampRate,
    workoutCount = workoutCount,
    maxTSSWorkout = maxTSSWorkout,
    avgHRV = avgHRV,
    avgRHR = avgRHR,
    hrvModifier = hrvModifier,
    rhrModifier = rhrModifier,
    illnessLikelihood = illnessLikelihood,
    sleepDuration = sleepDuration,
    sleepQualityScore = sleepQualityScore,
    deepSleepDuration = deepSleepDuration
)
