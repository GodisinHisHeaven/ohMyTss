package com.example.onmytss.presentation.components

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxWidth
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
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.example.onmytss.presentation.theme.BatteryBlue
import com.example.onmytss.presentation.theme.BatteryGreen
import com.example.onmytss.presentation.theme.BatteryOrange
import com.example.onmytss.presentation.theme.BatteryRed
import com.example.onmytss.presentation.theme.BatteryYellow

@Composable
fun BodyBatteryGauge(score: Int) {
    val animatedScore by animateFloatAsState(targetValue = score.coerceIn(0, 100).toFloat(), label = "score")
    val sweepAngle = 240f * (animatedScore / 100f)

    Box(
        modifier = Modifier
            .fillMaxWidth(0.6f)
            .aspectRatio(1f),
        contentAlignment = Alignment.Center
    ) {
        Canvas(modifier = Modifier.fillMaxWidth()) {
            val strokeWidth = 24.dp.toPx()
            val diameter = size.minDimension - strokeWidth
            val topLeft = Offset(strokeWidth / 2, strokeWidth / 2)

            // Background arc
            drawArc(
                color = Color.LightGray.copy(alpha = 0.3f),
                startAngle = 150f,
                sweepAngle = 240f,
                useCenter = false,
                topLeft = topLeft,
                size = Size(diameter, diameter),
                style = Stroke(width = strokeWidth, cap = StrokeCap.Round)
            )

            // Gradient arc
            drawArc(
                brush = Brush.sweepGradient(
                    colors = listOf(BatteryRed, BatteryOrange, BatteryYellow, BatteryGreen, BatteryBlue),
                    center = Offset(size.width / 2, size.height / 2)
                ),
                startAngle = 150f,
                sweepAngle = sweepAngle,
                useCenter = false,
                topLeft = topLeft,
                size = Size(diameter, diameter),
                style = Stroke(width = strokeWidth, cap = StrokeCap.Round)
            )
        }

        Text(
            text = "${animatedScore.toInt()}",
            fontSize = 48.sp,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.onBackground
        )
    }
}
