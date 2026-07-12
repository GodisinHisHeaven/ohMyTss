package com.example.onmytss.domain.model

data class WeeklyPlan(
    val totalTSS: Double,
    val dailyTSS: List<Double>, // 7 days, Monday to Sunday
    val primaryFocus: String,
    val restDays: Int
) {
    val averageDailyTSS: Double get() = totalTSS / 7.0
}
