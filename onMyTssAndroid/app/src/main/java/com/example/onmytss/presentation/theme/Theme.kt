package com.example.onmytss.presentation.theme

import android.app.Activity
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.SideEffect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalView
import androidx.core.view.WindowCompat

// Material3 color schemes aligned to iOS semantic palette.
private val LightColorScheme = lightColorScheme(
    primary = IosLight.systemBlue,
    onPrimary = Color.White,
    primaryContainer = IosLight.systemBlue.copy(alpha = 0.12f),
    onPrimaryContainer = IosLight.systemBlue,
    secondary = IosLight.systemGray,
    onSecondary = Color.White,
    tertiary = IosLight.systemIndigo,
    onTertiary = Color.White,
    background = IosLight.systemBackground,
    onBackground = IosLight.label,
    surface = IosLight.systemBackground,
    onSurface = IosLight.label,
    surfaceVariant = IosLight.secondarySystemBackground,
    onSurfaceVariant = IosLight.secondaryLabel,
    error = IosLight.systemRed,
    onError = Color.White,
    errorContainer = IosLight.systemRed.copy(alpha = 0.12f),
    onErrorContainer = IosLight.systemRed,
    outline = IosLight.separator,
    outlineVariant = IosLight.systemGray4
)

private val DarkColorScheme = darkColorScheme(
    primary = IosDark.systemBlue,
    onPrimary = Color.White,
    primaryContainer = IosDark.systemBlue.copy(alpha = 0.22f),
    onPrimaryContainer = IosDark.systemBlue,
    secondary = IosDark.systemGray,
    onSecondary = Color.White,
    tertiary = IosDark.systemIndigo,
    onTertiary = Color.White,
    background = IosDark.systemBackground,
    onBackground = IosDark.label,
    surface = IosDark.systemBackground,
    onSurface = IosDark.label,
    surfaceVariant = IosDark.secondarySystemBackground,
    onSurfaceVariant = IosDark.secondaryLabel,
    error = IosDark.systemRed,
    onError = Color.White,
    errorContainer = IosDark.systemRed.copy(alpha = 0.22f),
    onErrorContainer = IosDark.systemRed,
    outline = IosDark.separator,
    outlineVariant = IosDark.systemGray4
)

@Composable
fun OnMyTssTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    content: @Composable () -> Unit
) {
    val colorScheme = if (darkTheme) DarkColorScheme else LightColorScheme
    val iosPalette = if (darkTheme) DarkIosPalette else LightIosPalette

    val view = LocalView.current
    if (!view.isInEditMode) {
        SideEffect {
            val window = (view.context as Activity).window
            window.statusBarColor = Color.Transparent.toArgb()
            WindowCompat.getInsetsController(window, view).isAppearanceLightStatusBars = !darkTheme
        }
    }

    ProvideIosPalette(iosPalette) {
        MaterialTheme(
            colorScheme = colorScheme,
            typography = Typography,
            content = content
        )
    }
}
