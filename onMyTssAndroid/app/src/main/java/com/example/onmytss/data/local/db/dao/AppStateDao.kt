package com.example.onmytss.data.local.db.dao

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import com.example.onmytss.data.local.db.entity.AppStateEntity
import kotlinx.coroutines.flow.Flow
import java.util.Date

@Dao
interface AppStateDao {

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insert(entity: AppStateEntity)

    @Query("SELECT * FROM app_state WHERE id = 1 LIMIT 1")
    suspend fun get(): AppStateEntity?

    @Query("SELECT * FROM app_state WHERE id = 1 LIMIT 1")
    fun getFlow(): Flow<AppStateEntity?>

    @Query("UPDATE app_state SET lastHealthConnectSyncDate = :date WHERE id = 1")
    suspend fun updateLastSyncDate(date: Date)

    @Query("UPDATE app_state SET isComputationInProgress = :inProgress WHERE id = 1")
    suspend fun updateComputationInProgress(inProgress: Boolean)

    @Query("DELETE FROM app_state")
    suspend fun deleteAll()
}
