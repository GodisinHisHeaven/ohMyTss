package com.example.onmytss.presentation.components

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp

@Composable
fun WeekTrendChart(scores: List<Int>) {
    if (scores.isEmpty()) return

    val maxScore = scores.maxOrNull()?.coerceAtLeast(1) ?: 1
    val barColor = MaterialTheme.colorScheme.primary

    Text("7-Day Trend", modifier = Modifier.padding(vertical = 8.dp))
    Canvas(
        modifier = Modifier
            .fillMaxWidth()
            .height(100.dp)
            .padding(horizontal = 8.dp)
    ) {
        val barWidth = size.width / (scores.size * 2f)
        val spacing = barWidth
        val chartHeight = size.height

        scores.forEachIndexed { index, score ->
            val barHeight = (score.toFloat() / maxScore.toFloat()) * chartHeight
            val x = index * (barWidth + spacing) + spacing / 2
            val y = chartHeight - barHeight

            drawRect(
                color = barColor,
                topLeft = Offset(x, y),
                size = Size(barWidth, barHeight)
            )
        }
    }
}
