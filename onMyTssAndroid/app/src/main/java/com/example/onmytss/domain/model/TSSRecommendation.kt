package com.example.onmytss.domain.model

import com.example.onmytss.domain.model.enums.TSSIntensity

data class TSSRecommendation(
    val min: Int,
    val max: Int,
    val optimal: Int,
    val description: String,
    val intensity: TSSIntensity
)
