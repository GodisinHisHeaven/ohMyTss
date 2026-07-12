package com.example.onmytss.presentation.theme

import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color

/**
 * Semantic palette mirroring SwiftUI's `Color(uiColor: .systemBackground)` etc.
 * Access via `IosColors.current` inside a composable.
 */
data class IosPalette(
    val systemBackground: Color,
    val secondarySystemBackground: Color,
    val tertiarySystemBackground: Color,
    val systemGroupedBackground: Color,
    val secondarySystemGroupedBackground: Color,
    val label: Color,
    val secondaryLabel: Color,
    val tertiaryLabel: Color,
    val quaternaryLabel: Color,
    val separator: Color,
    val systemBlue: Color,
    val systemRed: Color,
    val systemOrange: Color,
    val systemYellow: Color,
    val systemGreen: Color,
    val systemPink: Color,
    val systemPurple: Color,
    val systemIndigo: Color,
    val systemGray: Color,
    val systemGray2: Color,
    val systemGray3: Color,
    val systemGray4: Color,
    val systemGray5: Color,
    val systemGray6: Color
)

val LightIosPalette = IosPalette(
    systemBackground = IosLight.systemBackground,
    secondarySystemBackground = IosLight.secondarySystemBackground,
    tertiarySystemBackground = IosLight.tertiarySystemBackground,
    systemGroupedBackground = IosLight.systemGroupedBackground,
    secondarySystemGroupedBackground = IosLight.secondarySystemGroupedBackground,
    label = IosLight.label,
    secondaryLabel = IosLight.secondaryLabel,
    tertiaryLabel = IosLight.tertiaryLabel,
    quaternaryLabel = IosLight.quaternaryLabel,
    separator = IosLight.separator,
    systemBlue = IosLight.systemBlue,
    systemRed = IosLight.systemRed,
    systemOrange = IosLight.systemOrange,
    systemYellow = IosLight.systemYellow,
    systemGreen = IosLight.systemGreen,
    systemPink = IosLight.systemPink,
    systemPurple = IosLight.systemPurple,
    systemIndigo = IosLight.systemIndigo,
    systemGray = IosLight.systemGray,
    systemGray2 = IosLight.systemGray2,
    systemGray3 = IosLight.systemGray3,
    systemGray4 = IosLight.systemGray4,
    systemGray5 = IosLight.systemGray5,
    systemGray6 = IosLight.systemGray6
)

val DarkIosPalette = IosPalette(
    systemBackground = IosDark.systemBackground,
    secondarySystemBackground = IosDark.secondarySystemBackground,
    tertiarySystemBackground = IosDark.tertiarySystemBackground,
    systemGroupedBackground = IosDark.systemGroupedBackground,
    secondarySystemGroupedBackground = IosDark.secondarySystemGroupedBackground,
    label = IosDark.label,
    secondaryLabel = IosDark.secondaryLabel,
    tertiaryLabel = IosDark.tertiaryLabel,
    quaternaryLabel = IosDark.quaternaryLabel,
    separator = IosDark.separator,
    systemBlue = IosDark.systemBlue,
    systemRed = IosDark.systemRed,
    systemOrange = IosDark.systemOrange,
    systemYellow = IosDark.systemYellow,
    systemGreen = IosDark.systemGreen,
    systemPink = IosDark.systemPink,
    systemPurple = IosDark.systemPurple,
    systemIndigo = IosDark.systemIndigo,
    systemGray = IosDark.systemGray,
    systemGray2 = IosDark.systemGray2,
    systemGray3 = IosDark.systemGray3,
    systemGray4 = IosDark.systemGray4,
    systemGray5 = IosDark.systemGray5,
    systemGray6 = IosDark.systemGray6
)

val LocalIosPalette = staticCompositionLocalOf { LightIosPalette }

object IosColors {
    val current: IosPalette
        @Composable
        @ReadOnlyComposable
        get() = LocalIosPalette.current
}

@Composable
fun ProvideIosPalette(palette: IosPalette, content: @Composable () -> Unit) {
    CompositionLocalProvider(LocalIosPalette provides palette, content = content)
}
