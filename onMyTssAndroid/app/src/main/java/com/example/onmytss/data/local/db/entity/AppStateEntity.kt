package com.example.onmytss.data.local.db.entity

import androidx.room.Entity
import androidx.room.PrimaryKey
import java.util.Date

@Entity(tableName = "app_state")
data class AppStateEntity(
    @PrimaryKey
    val id: Int = 1,
    val lastHealthConnectSyncDate: Date? = null,
    val lastComputationDate: Date? = null,
    val isComputationInProgress: Boolean = false,
    val appInstallDate: Date = Date(),
    val lastOpenDate: Date? = null
)
