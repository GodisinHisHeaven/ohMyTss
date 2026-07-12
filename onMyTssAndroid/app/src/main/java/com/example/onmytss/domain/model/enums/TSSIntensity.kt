package com.example.onmytss.domain.model.enums

enum class TSSIntensity(val displayName: String, val range: ClosedRange<Double>) {
    RECOVERY("Recovery", 0.0..50.0),
    ENDURANCE("Endurance", 50.0..100.0),
    TEMPO("Tempo", 100.0..150.0),
    THRESHOLD("Threshold", 150.0..250.0),
    VO2_MAX("VO2 Max", 250.0..400.0),
    ANAEROBIC("Anaerobic", 400.0..1000.0)
}
