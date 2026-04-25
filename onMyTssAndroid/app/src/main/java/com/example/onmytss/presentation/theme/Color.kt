package com.example.onmytss.presentation.theme

import androidx.compose.ui.graphics.Color

// Battery gradient (shared with iOS BodyBatteryGauge)
val BatteryRed = Color(0xFFE53E3E)
val BatteryOrange = Color(0xFFDD6B20)
val BatteryYellow = Color(0xFFD69E2E)
val BatteryGreen = Color(0xFF38A169)
val BatteryBlue = Color(0xFF3182CE)
val BatteryPurple = Color(0xFF9F7AEA)

// iOS system colors (light mode) — used to match SwiftUI's semantic palette
// References: Apple HIG, UIColor.systemBackground, etc.
object IosLight {
    val systemBackground = Color(0xFFFFFFFF)
    val secondarySystemBackground = Color(0xFFF2F2F7)
    val tertiarySystemBackground = Color(0xFFFFFFFF)
    val systemGroupedBackground = Color(0xFFF2F2F7)
    val secondarySystemGroupedBackground = Color(0xFFFFFFFF)

    val label = Color(0xFF000000)
    val secondaryLabel = Color(0x993C3C43) // 60% of 3C3C43
    val tertiaryLabel = Color(0x4D3C3C43)  // 30%
    val quaternaryLabel = Color(0x2E3C3C43) // 18%

    val separator = Color(0x493C3C43)

    // Accent / system tints
    val systemBlue = Color(0xFF007AFF)
    val systemRed = Color(0xFFFF3B30)
    val systemOrange = Color(0xFFFF9500)
    val systemYellow = Color(0xFFFFCC00)
    val systemGreen = Color(0xFF34C759)
    val systemPink = Color(0xFFFF2D55)
    val systemPurple = Color(0xFFAF52DE)
    val systemIndigo = Color(0xFF5856D6)
    val systemGray = Color(0xFF8E8E93)
    val systemGray2 = Color(0xFFAEAEB2)
    val systemGray3 = Color(0xFFC7C7CC)
    val systemGray4 = Color(0xFFD1D1D6)
    val systemGray5 = Color(0xFFE5E5EA)
    val systemGray6 = Color(0xFFF2F2F7)
}

object IosDark {
    val systemBackground = Color(0xFF000000)
    val secondarySystemBackground = Color(0xFF1C1C1E)
    val tertiarySystemBackground = Color(0xFF2C2C2E)
    val systemGroupedBackground = Color(0xFF000000)
    val secondarySystemGroupedBackground = Color(0xFF1C1C1E)

    val label = Color(0xFFFFFFFF)
    val secondaryLabel = Color(0x99EBEBF5) // 60%
    val tertiaryLabel = Color(0x4DEBEBF5)
    val quaternaryLabel = Color(0x2EEBEBF5)

    val separator = Color(0x99545458)

    val systemBlue = Color(0xFF0A84FF)
    val systemRed = Color(0xFFFF453A)
    val systemOrange = Color(0xFFFF9F0A)
    val systemYellow = Color(0xFFFFD60A)
    val systemGreen = Color(0xFF30D158)
    val systemPink = Color(0xFFFF375F)
    val systemPurple = Color(0xFFBF5AF2)
    val systemIndigo = Color(0xFF5E5CE6)
    val systemGray = Color(0xFF8E8E93)
    val systemGray2 = Color(0xFF636366)
    val systemGray3 = Color(0xFF48484A)
    val systemGray4 = Color(0xFF3A3A3C)
    val systemGray5 = Color(0xFF2C2C2E)
    val systemGray6 = Color(0xFF1C1C1E)
}
