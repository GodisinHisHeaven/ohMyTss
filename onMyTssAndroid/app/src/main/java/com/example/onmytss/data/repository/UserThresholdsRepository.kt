package com.example.onmytss.data.repository

import com.example.onmytss.data.local.db.dao.UserThresholdsDao
import com.example.onmytss.data.local.db.entity.UserThresholdsEntity
import com.example.onmytss.domain.Constants
import com.example.onmytss.domain.model.UserThresholds
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class UserThresholdsRepository @Inject constructor(
    private val dao: UserThresholdsDao
) {
    suspend fun getOrCreate(): UserThresholds {
        return dao.get()?.toDomain() ?: UserThresholds().also { dao.insert(it.toEntity()) }
    }

    suspend fun save(thresholds: UserThresholds) = dao.insert(thresholds.toEntity())

    fun getFlow(): Flow<UserThresholds?> = dao.getFlow().map { it?.toDomain() }

    suspend fun updateFTP(ftp: Int) = dao.updateFTP(ftp.coerceIn(Constants.MIN_FTP, Constants.MAX_FTP))

    suspend fun markOnboardingComplete() = dao.updateOnboarding(true)

    suspend fun deleteAll() = dao.deleteAll()
}

fun UserThresholdsEntity.toDomain() = UserThresholds(
    id = id,
    cyclingFTP = cyclingFTP,
    maxHeartRate = maxHeartRate,
    preferredUnitSystem = preferredUnitSystem,
    preferredSports = preferredSports,
    hasCompletedOnboarding = hasCompletedOnboarding
)

fun UserThresholds.toEntity() = UserThresholdsEntity(
    id = id,
    cyclingFTP = cyclingFTP,
    maxHeartRate = maxHeartRate,
    preferredUnitSystem = preferredUnitSystem,
    preferredSports = preferredSports,
    hasCompletedOnboarding = hasCompletedOnboarding
)
