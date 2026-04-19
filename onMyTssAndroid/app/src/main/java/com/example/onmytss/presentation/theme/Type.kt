package com.example.onmytss.presentation.theme

import androidx.compose.material3.Typography
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp

/**
 * Compose Typography tuned to SwiftUI's Dynamic Type default sizes (SF Pro).
 *
 * SwiftUI mapping (used as pixel targets on Android):
 *   largeTitle → 34/41, bold
 *   title      → 28/34, regular
 *   title2     → 22/28, regular
 *   title3     → 20/25, regular
 *   headline   → 17/22, semibold
 *   body       → 17/22, regular
 *   callout    → 16/21, regular
 *   subheadline→ 15/20, regular
 *   footnote   → 13/18, regular
 *   caption    → 12/16, regular
 *   caption2   → 11/13, regular
 *
 * Mapping to Material3 Typography slots we use across the screens:
 *   displayLarge  → largeTitle (navigationTitle .large)
 *   headlineLarge → title
 *   headlineMedium→ title2
 *   headlineSmall → title3
 *   titleLarge    → title2 bold (MetricCard value)
 *   titleMedium   → title3 bold
 *   titleSmall    → headline
 *   bodyLarge     → body
 *   bodyMedium    → callout
 *   bodySmall     → subheadline
 *   labelLarge    → footnote
 *   labelMedium   → caption
 *   labelSmall    → caption2
 */

private val system = FontFamily.Default

val Typography = Typography(
    displayLarge = TextStyle(
        fontFamily = system,
        fontWeight = FontWeight.Bold,
        fontSize = 34.sp,
        lineHeight = 41.sp,
        letterSpacing = 0.37.sp
    ),
    headlineLarge = TextStyle(
        fontFamily = system,
        fontWeight = FontWeight.Normal,
        fontSize = 28.sp,
        lineHeight = 34.sp,
        letterSpacing = 0.36.sp
    ),
    headlineMedium = TextStyle(
        fontFamily = system,
        fontWeight = FontWeight.Normal,
        fontSize = 22.sp,
        lineHeight = 28.sp,
        letterSpacing = 0.35.sp
    ),
    headlineSmall = TextStyle(
        fontFamily = system,
        fontWeight = FontWeight.Normal,
        fontSize = 20.sp,
        lineHeight = 25.sp,
        letterSpacing = 0.38.sp
    ),
    titleLarge = TextStyle(
        fontFamily = system,
        fontWeight = FontWeight.Bold,
        fontSize = 22.sp,
        lineHeight = 28.sp,
        letterSpacing = 0.35.sp
    ),
    titleMedium = TextStyle(
        fontFamily = system,
        fontWeight = FontWeight.Bold,
        fontSize = 20.sp,
        lineHeight = 25.sp,
        letterSpacing = 0.38.sp
    ),
    titleSmall = TextStyle(
        fontFamily = system,
        fontWeight = FontWeight.SemiBold,
        fontSize = 17.sp,
        lineHeight = 22.sp,
        letterSpacing = (-0.41).sp
    ),
    bodyLarge = TextStyle(
        fontFamily = system,
        fontWeight = FontWeight.Normal,
        fontSize = 17.sp,
        lineHeight = 22.sp,
        letterSpacing = (-0.41).sp
    ),
    bodyMedium = TextStyle(
        fontFamily = system,
        fontWeight = FontWeight.Normal,
        fontSize = 16.sp,
        lineHeight = 21.sp,
        letterSpacing = (-0.32).sp
    ),
    bodySmall = TextStyle(
        fontFamily = system,
        fontWeight = FontWeight.Normal,
        fontSize = 15.sp,
        lineHeight = 20.sp,
        letterSpacing = (-0.24).sp
    ),
    labelLarge = TextStyle(
        fontFamily = system,
        fontWeight = FontWeight.Medium,
        fontSize = 13.sp,
        lineHeight = 18.sp,
        letterSpacing = (-0.08).sp
    ),
    labelMedium = TextStyle(
        fontFamily = system,
        fontWeight = FontWeight.Normal,
        fontSize = 12.sp,
        lineHeight = 16.sp,
        letterSpacing = 0.sp
    ),
    labelSmall = TextStyle(
        fontFamily = system,
        fontWeight = FontWeight.Normal,
        fontSize = 11.sp,
        lineHeight = 13.sp,
        letterSpacing = 0.07.sp
    )
)
