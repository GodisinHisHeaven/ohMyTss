package com.example.onmytss.domain.model.enums

enum class ReadinessZone(val displayName: String, val description: String, val tsbRange: ClosedRange<Double>) {
    OVERREACHING(
        "Overreaching",
        "High fatigue. Prioritize recovery.",
        -50.0..-15.0
    ),
    DELOAD(
        "Deload",
        "Moderate fatigue. Light training recommended.",
        -15.0..-5.0
    ),
    MAINTAIN(
        "Maintain",
        "Balanced fitness and fatigue. Maintain current training.",
        -5.0..5.0
    ),
    BUILD_BASE(
        "Build Base",
        "Fresh and ready. Good for building base fitness.",
        5.0..15.0
    ),
    BUILD_INTENSITY(
        "Build Intensity",
        "Very fresh. Good for high-intensity training.",
        15.0..50.0
    )
}
