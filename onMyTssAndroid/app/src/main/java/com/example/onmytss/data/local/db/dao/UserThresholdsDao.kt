package com.example.onmytss.data.local.db.dao

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import com.example.onmytss.data.local.db.entity.UserThresholdsEntity
import kotlinx.coroutines.flow.Flow

@Dao
interface UserThresholdsDao {

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insert(entity: UserThresholdsEntity)

    @Query("SELECT * FROM user_thresholds WHERE id = 1 LIMIT 1")
    suspend fun get(): UserThresholdsEntity?

    @Query("SELECT * FROM user_thresholds WHERE id = 1 LIMIT 1")
    fun getFlow(): Flow<UserThresholdsEntity?>

    @Query("UPDATE user_thresholds SET cyclingFTP = :ftp WHERE id = 1")
    suspend fun updateFTP(ftp: Int)

    @Query("UPDATE user_thresholds SET hasCompletedOnboarding = :completed WHERE id = 1")
    suspend fun updateOnboarding(completed: Boolean)

    @Query("DELETE FROM user_thresholds")
    suspend fun deleteAll()
}
