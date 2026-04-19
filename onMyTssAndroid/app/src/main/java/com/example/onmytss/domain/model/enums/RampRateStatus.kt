package com.example.onmytss.domain.model.enums

enum class RampRateStatus(
    val displayName: String,
    val description: String,
    val colorName: String
) {
    DETRAINING("Detraining", "CTL is decreasing. Consider adding training load.", "blue"),
    SAFE("Safe Progress", "CTL ramp rate is within recommended range.", "green"),
    AGGRESSIVE("Aggressive", "CTL ramp rate is high but manageable. Monitor recovery.", "yellow"),
    DANGEROUS("Too Fast", "CTL ramp rate is too high. Risk of overtraining. Consider reducing load.", "red")
}
