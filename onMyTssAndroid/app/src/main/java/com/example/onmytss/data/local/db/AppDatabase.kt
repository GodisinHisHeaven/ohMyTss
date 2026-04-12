package com.example.onmytss.data.local.db

import androidx.room.Database
import androidx.room.RoomDatabase
import androidx.room.TypeConverters
import com.example.onmytss.data.local.db.dao.AppStateDao
import com.example.onmytss.data.local.db.dao.DayAggregateDao
import com.example.onmytss.data.local.db.dao.UserThresholdsDao
import com.example.onmytss.data.local.db.dao.WorkoutDao
import com.example.onmytss.data.local.db.entity.AppStateEntity
import com.example.onmytss.data.local.db.entity.DayAggregateEntity
import com.example.onmytss.data.local.db.entity.UserThresholdsEntity
import com.example.onmytss.data.local.db.entity.WorkoutEntity

@Database(
    entities = [
        DayAggregateEntity::class,
        WorkoutEntity::class,
        UserThresholdsEntity::class,
        AppStateEntity::class
    ],
    version = 1,
    exportSchema = false
)
@TypeConverters(Converters::class)
abstract class AppDatabase : RoomDatabase() {
    abstract fun dayAggregateDao(): DayAggregateDao
    abstract fun workoutDao(): WorkoutDao
    abstract fun userThresholdsDao(): UserThresholdsDao
    abstract fun appStateDao(): AppStateDao
}
