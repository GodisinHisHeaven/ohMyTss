package com.example.onmytss.presentation.components

import androidx.compose.animation.core.animateIntAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.size
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.example.onmytss.domain.model.enums.ReadinessLevel
import com.example.onmytss.presentation.theme.BatteryBlue
import com.example.onmytss.presentation.theme.BatteryGreen
import com.example.onmytss.presentation.theme.BatteryOrange
import com.example.onmytss.presentation.theme.BatteryRed
import com.example.onmytss.presentation.theme.BatteryYellow
import com.example.onmytss.presentation.theme.IosColors

/**
 * Mirrors iOS BodyBatteryGauge.swift:
 *  - Full circle (−90° start), stroke 20, rounded cap
 *  - Background ring at gray 20%
 *  - Angular gradient R→O→Y→G→B
 *  - Large rounded bold score, small "Battery" caption
 */
@Composable
fun BodyBatteryGauge(
    score: Int,
    readinessLevel: ReadinessLevel,
    modifier: Modifier = Modifier,
    size: Dp = 220.dp
) {
    val animatedScore by animateIntAsState(
        targetValue = score.coerceIn(0, 100),
        animationSpec = tween(durationMillis = 800),
        label = "bb-score"
    )

    val scoreColor = when (readinessLevel) {
        ReadinessLevel.VERY_LOW -> BatteryRed
        ReadinessLevel.LOW -> BatteryOrange
        ReadinessLevel.MEDIUM -> BatteryYellow
        ReadinessLevel.GOOD -> BatteryGreen
        ReadinessLevel.EXCELLENT -> BatteryBlue
    }

    Box(
        modifier = modifier
            .size(size)
            .aspectRatio(1f),
        contentAlignment = Alignment.Center
    ) {
        Canvas(modifier = Modifier.fillMaxSize()) {
            val strokeWidthPx = 20.dp.toPx()
            val diameter = this.size.minDimension - strokeWidthPx
            val topLeft = Offset(strokeWidthPx / 2f, strokeWidthPx / 2f)
            val arcSize = Size(diameter, diameter)

            drawArc(
                color = Color.Gray.copy(alpha = 0.2f),
                startAngle = 0f,
                sweepAngle = 360f,
                useCenter = false,
                topLeft = topLeft,
                size = arcSize,
                style = Stroke(width = strokeWidthPx, cap = StrokeCap.Round)
            )

            val sweep = 360f * (animatedScore / 100f)
            if (sweep > 0f) {
                drawArc(
                    brush = Brush.sweepGradient(
                        colors = listOf(
                            BatteryRed, BatteryOrange, BatteryYellow,
                            BatteryGreen, BatteryBlue, BatteryRed // close the wheel
                        ),
                        center = Offset(this.size.width / 2f, this.size.height / 2f)
                    ),
                    startAngle = -90f,
                    sweepAngle = sweep,
                    useCenter = false,
                    topLeft = topLeft,
                    size = arcSize,
                    style = Stroke(width = strokeWidthPx, cap = StrokeCap.Round)
                )
            }
        }

        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(4.dp)
        ) {
            Text(
                text = "$animatedScore",
                style = TextStyle(
                    fontFamily = FontFamily.Default,
                    fontWeight = FontWeight.Bold,
                    fontSize = 64.sp
                ),
                color = scoreColor
            )
            Text(
                text = "Battery",
                style = MaterialTheme.typography.labelMedium,
                color = IosColors.current.secondaryLabel
            )
        }
    }
}
