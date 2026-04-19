package com.example.onmytss.worker

import android.content.Context
import androidx.hilt.work.HiltWorker
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
import com.example.onmytss.domain.engine.BodyBatteryEngine
import dagger.assisted.Assisted
import dagger.assisted.AssistedInject

@HiltWorker
class DailySyncWorker @AssistedInject constructor(
    @Assisted context: Context,
    @Assisted params: WorkerParameters,
    private val bodyBatteryEngine: BodyBatteryEngine
) : CoroutineWorker(context, params) {

    override suspend fun doWork(): Result {
        return try {
            bodyBatteryEngine.recomputeAll()
            Result.success()
        } catch (e: Exception) {
            Result.retry()
        }
    }
}
