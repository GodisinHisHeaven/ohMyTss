package com.example.onmytss.data.repository

import com.example.onmytss.data.local.db.dao.AppStateDao
import com.example.onmytss.data.local.db.entity.AppStateEntity
import com.example.onmytss.domain.model.AppState
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map
import java.util.Date
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class AppStateRepository @Inject constructor(
    private val dao: AppStateDao
) {
    suspend fun getOrCreate(): AppState {
        return dao.get()?.toDomain() ?: AppState().also { dao.insert(it.toEntity()) }
    }

    suspend fun save(state: AppState) = dao.insert(state.toEntity())

    fun getFlow(): Flow<AppState?> = dao.getFlow().map { it?.toDomain() }

    suspend fun updateLastSyncDate(date: Date) = dao.updateLastSyncDate(date)

    suspend fun updateComputationInProgress(inProgress: Boolean) = dao.updateComputationInProgress(inProgress)

    suspend fun deleteAll() = dao.deleteAll()
}

fun AppStateEntity.toDomain() = AppState(
    id = id,
    lastHealthConnectSyncDate = lastHealthConnectSyncDate,
    lastComputationDate = lastComputationDate,
    isComputationInProgress = isComputationInProgress,
    appInstallDate = appInstallDate,
    lastOpenDate = lastOpenDate
)

fun AppState.toEntity() = AppStateEntity(
    id = id,
    lastHealthConnectSyncDate = lastHealthConnectSyncDate,
    lastComputationDate = lastComputationDate,
    isComputationInProgress = isComputationInProgress,
    appInstallDate = appInstallDate,
    lastOpenDate = lastOpenDate
)
