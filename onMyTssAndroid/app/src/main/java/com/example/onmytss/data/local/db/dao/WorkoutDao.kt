package com.example.onmytss.data.local.db.dao

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import com.example.onmytss.data.local.db.entity.WorkoutEntity
import kotlinx.coroutines.flow.Flow
import java.util.Date

@Dao
interface WorkoutDao {

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insert(entity: WorkoutEntity)

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertAll(entities: List<WorkoutEntity>)

    @Query("SELECT * FROM workouts WHERE id = :id LIMIT 1")
    suspend fun getById(id: String): WorkoutEntity?

    @Query("SELECT * FROM workouts WHERE date BETWEEN :start AND :end ORDER BY startTime ASC")
    suspend fun getByDateRange(start: Date, end: Date): List<WorkoutEntity>

    @Query("SELECT * FROM workouts WHERE date BETWEEN :start AND :end ORDER BY startTime ASC")
    fun getByDateRangeFlow(start: Date, end: Date): Flow<List<WorkoutEntity>>

    @Query("DELETE FROM workouts")
    suspend fun deleteAll()
}
