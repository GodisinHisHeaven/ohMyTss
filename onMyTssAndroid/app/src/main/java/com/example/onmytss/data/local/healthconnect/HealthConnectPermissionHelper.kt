package com.example.onmytss.data.local.healthconnect

import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.health.connect.client.HealthConnectClient
import androidx.health.connect.client.permission.HealthPermission
import androidx.health.connect.client.records.ExerciseSessionRecord
import androidx.health.connect.client.records.HeartRateRecord
import androidx.health.connect.client.records.HeartRateVariabilityRmssdRecord
import androidx.health.connect.client.records.SleepSessionRecord

import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class HealthConnectPermissionHelper @Inject constructor(
    @ApplicationContext private val context: Context
) {

    val permissions = setOf(
        HealthPermission.getReadPermission(ExerciseSessionRecord::class),
        HealthPermission.getReadPermission(HeartRateRecord::class),
        HealthPermission.getReadPermission(HeartRateVariabilityRmssdRecord::class),
        HealthPermission.getReadPermission(SleepSessionRecord::class)
    )

    val permissionStrings: Set<String>
        get() = permissions.map { it.toString() }.toSet()

    fun isAvailable(): Boolean {
        return try {
            HealthConnectClient.getSdkStatus(context) == HealthConnectClient.SDK_AVAILABLE
        } catch (e: Exception) {
            false
        }
    }

    fun getInstallIntent(): Intent {
        val intent = Intent(Intent.ACTION_VIEW)
        intent.setPackage("com.android.vending")
        intent.data = Uri.parse("market://details?id=com.google.android.apps.healthdata")
        return intent
    }
}
