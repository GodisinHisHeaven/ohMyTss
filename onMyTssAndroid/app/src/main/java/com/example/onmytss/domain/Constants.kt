package com.example.onmytss.domain

object Constants {
    // Training Load
    const val CTL_TIME_CONSTANT: Double = 42.0
    const val ATL_TIME_CONSTANT: Double = 7.0
    const val MAX_SAFE_CTL_RAMP_RATE: Double = 5.0
    const val RECOMMENDED_CTL_RAMP_RATE: Double = 3.0

    // TSS Calculation
    const val THRESHOLD_INTENSITY_FACTOR: Double = 1.0
    const val NORMALIZED_POWER_VARIABILITY_INDEX: Double = 4.0
    const val MIN_WORKOUT_DURATION_SECONDS: Long = 300L // 5 minutes

    // Body Battery Score
    const val MIN_BODY_BATTERY_SCORE: Int = 0
    const val MAX_BODY_BATTERY_SCORE: Int = 100
    const val DEFAULT_BODY_BATTERY_SCORE: Int = 50
    const val TSB_FOR_MAX_SCORE: Double = 25.0
    const val TSB_FOR_MIN_SCORE: Double = -35.0

    // Health Sync
    const val MAX_HISTORICAL_DAYS: Int = 90
    const val INITIAL_SYNC_DAYS: Int = 90

    // UI
    const val TREND_CHART_DAYS: Int = 7
    const val HISTORY_DAYS: Int = 30

    // FTP
    const val DEFAULT_FTP: Int = 200
    const val MIN_FTP: Int = 50
    const val MAX_FTP: Int = 500
}
