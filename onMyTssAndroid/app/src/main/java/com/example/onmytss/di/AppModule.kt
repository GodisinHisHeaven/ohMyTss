package com.example.onmytss.di

import android.content.Context
import androidx.room.Room
import com.example.onmytss.data.local.db.AppDatabase
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.components.SingletonComponent
import javax.inject.Singleton

@Module
@InstallIn(SingletonComponent::class)
object AppModule {

    @Provides
    @Singleton
    fun provideDatabase(@ApplicationContext context: Context): AppDatabase {
        return Room.databaseBuilder(
            context,
            AppDatabase::class.java,
            "onmytss_database"
        ).build()
    }

    @Provides
    fun provideDayAggregateDao(db: AppDatabase) = db.dayAggregateDao()

    @Provides
    fun provideWorkoutDao(db: AppDatabase) = db.workoutDao()

    @Provides
    fun provideUserThresholdsDao(db: AppDatabase) = db.userThresholdsDao()

    @Provides
    fun provideAppStateDao(db: AppDatabase) = db.appStateDao()
}
