package com.example.onmytss.data.local.db.dao

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import com.example.onmytss.data.local.db.entity.DayAggregateEntity
import kotlinx.coroutines.flow.Flow
import java.util.Date

@Dao
interface DayAggregateDao {

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insert(entity: DayAggregateEntity)

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertAll(entities: List<DayAggregateEntity>)

    @Query("SELECT * FROM day_aggregates WHERE date = :date LIMIT 1")
    suspend fun getByDate(date: Date): DayAggregateEntity?

    @Query("SELECT * FROM day_aggregates WHERE date BETWEEN :start AND :end ORDER BY date ASC")
    suspend fun getRange(start: Date, end: Date): List<DayAggregateEntity>

    @Query("SELECT * FROM day_aggregates WHERE date BETWEEN :start AND :end ORDER BY date ASC")
    fun getRangeFlow(start: Date, end: Date): Flow<List<DayAggregateEntity>>

    @Query("SELECT * FROM day_aggregates ORDER BY date DESC LIMIT :limit")
    suspend fun getRecent(limit: Int): List<DayAggregateEntity>

    @Query("SELECT * FROM day_aggregates ORDER BY date DESC LIMIT 1")
    suspend fun getLatest(): DayAggregateEntity?

    @Query("DELETE FROM day_aggregates")
    suspend fun deleteAll()
}
