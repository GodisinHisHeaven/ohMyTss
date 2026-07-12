package com.example.onmytss.domain.model.enums

enum class Trend(val displayName: String, val description: String, val arrow: String) {
    IMPROVING_FAST("Rapidly Improving", "Your readiness is rapidly improving.", "⬆️⬆️"),
    IMPROVING("Improving", "Your readiness is steadily improving.", "⬆️"),
    STABLE("Stable", "Your readiness is stable.", "→"),
    DECLINING("Declining", "Your readiness is declining.", "⬇️"),
    DECLINING_FAST("Rapidly Declining", "Your readiness is declining rapidly. Consider more recovery.", "⬇️⬇️")
}
