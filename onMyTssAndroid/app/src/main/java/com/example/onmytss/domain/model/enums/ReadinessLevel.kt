package com.example.onmytss.domain.model.enums

enum class ReadinessLevel(val displayName: String, val description: String, val emoji: String) {
    VERY_LOW("Very Low", "Severely fatigued. Rest is critical.", "😴"),
    LOW("Low", "Fatigued. Focus on recovery.", "😓"),
    MEDIUM("Medium", "Moderate readiness. Light training okay.", "😐"),
    GOOD("Good", "Good readiness for training.", "🙂"),
    EXCELLENT("Excellent", "Excellent! Ready for hard efforts.", "💪")
}
