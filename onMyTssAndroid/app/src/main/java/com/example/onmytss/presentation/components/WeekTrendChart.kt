package com.example.onmytss.presentation.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDownward
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.Remove
import androidx.compose.material.icons.filled.ShowChart
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.example.onmytss.domain.calculator.BodyBatteryCalculator
import com.example.onmytss.domain.model.enums.ReadinessLevel
import com.example.onmytss.domain.model.enums.Trend
import com.example.onmytss.presentation.theme.BatteryBlue
import com.example.onmytss.presentation.theme.BatteryGreen
import com.example.onmytss.presentation.theme.BatteryOrange
import com.example.onmytss.presentation.theme.BatteryRed
import com.example.onmytss.presentation.theme.BatteryYellow
import com.example.onmytss.presentation.theme.IosColors
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

data class DayScore(val date: Date, val score: Int)

@Composable
fun WeekTrendChart(
    scores: List<DayScore>,
    modifier: Modifier = Modifier
) {
    val palette = IosColors.current
    val trend: Trend? = if (scores.size >= 3)
        BodyBatteryCalculator.calculateTrend(scores.map { it.score })
    else null

    Column(
        modifier = modifier
            .fillMaxWidth()
            .shadow(elevation = 4.dp, shape = RoundedCornerShape(16.dp))
            .clip(RoundedCornerShape(16.dp))
            .background(palette.systemBackground)
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        // Header
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.fillMaxWidth()
        ) {
            Text(
                text = "7-Day Trend",
                style = MaterialTheme.typography.titleSmall,
                color = palette.label
            )
            Spacer(modifier = Modifier.weight(1f))
            trend?.let {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(4.dp)
                ) {
                    Text(
                        text = it.arrow,
                        style = MaterialTheme.typography.labelMedium
                    )
                    Text(
                        text = it.displayName,
                        style = MaterialTheme.typography.labelMedium,
                        color = palette.secondaryLabel
                    )
                }
            }
        }

        if (scores.isEmpty()) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(100.dp)
                    .clip(RoundedCornerShape(12.dp))
                    .background(palette.secondarySystemBackground),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center
            ) {
                Icon(
                    imageVector = Icons.Filled.ShowChart,
                    contentDescription = null,
                    tint = palette.secondaryLabel,
                    modifier = Modifier.size(22.dp)
                )
                Spacer(modifier = Modifier.height(8.dp))
                Text(
                    text = "No data yet",
                    style = MaterialTheme.typography.bodySmall,
                    color = palette.secondaryLabel
                )
            }
        } else {
            // Bars row
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(80.dp),
                verticalAlignment = Alignment.Bottom
            ) {
                scores.forEachIndexed { idx, item ->
                    val isToday = idx == scores.lastIndex
                    BarColumn(
                        score = item.score,
                        isToday = isToday,
                        dayLabel = dayOfWeek(item.date),
                        modifier = Modifier.weight(1f)
                    )
                }
            }

            // Change row
            if (scores.size >= 2) {
                val change = scores.last().score - scores[scores.size - 2].score
                val iconTint = when {
                    change > 0 -> palette.systemGreen
                    change < 0 -> palette.systemRed
                    else -> palette.systemGray
                }
                val icon = when {
                    change > 0 -> Icons.Filled.ArrowUpward
                    change < 0 -> Icons.Filled.ArrowDownward
                    else -> Icons.Filled.Remove
                }
                val text = when {
                    change > 0 -> "+$change from yesterday"
                    change < 0 -> "$change from yesterday"
                    else -> "No change from yesterday"
                }
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(4.dp)
                ) {
                    Icon(
                        imageVector = icon,
                        contentDescription = null,
                        tint = iconTint,
                        modifier = Modifier.size(12.dp)
                    )
                    Text(
                        text = text,
                        style = MaterialTheme.typography.labelMedium,
                        color = palette.secondaryLabel
                    )
                }
            }
        }
    }
}

@Composable
private fun BarColumn(
    score: Int,
    isToday: Boolean,
    dayLabel: String,
    modifier: Modifier = Modifier
) {
    val palette = IosColors.current
    val level = BodyBatteryCalculator.getReadinessLevel(score)
    val barColor = when (level) {
        ReadinessLevel.VERY_LOW -> BatteryRed
        ReadinessLevel.LOW -> BatteryOrange
        ReadinessLevel.MEDIUM -> BatteryYellow
        ReadinessLevel.GOOD -> BatteryGreen
        ReadinessLevel.EXCELLENT -> BatteryBlue
    }
    val heightPct = (score / 100f).coerceAtLeast(0.05f)
    Column(
        modifier = modifier.fillMaxHeight(),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Bottom
    ) {
        // Reserve space at top for today's score label so bars align.
        if (isToday) {
            Text(
                text = "$score",
                fontSize = 10.sp,
                fontWeight = FontWeight.Bold,
                color = palette.label,
                modifier = Modifier.padding(bottom = 2.dp)
            )
        }
        val shape = RoundedCornerShape(3.dp)
        Box(
            modifier = Modifier
                .width(14.dp)
                .fillMaxHeight(heightPct.coerceIn(0.05f, 0.85f))
                .clip(shape)
                .background(barColor)
                .then(
                    if (isToday) Modifier.border(
                        width = 2.dp,
                        color = palette.label,
                        shape = shape
                    ) else Modifier
                )
        )
        Spacer(modifier = Modifier.height(4.dp))
        Text(
            text = dayLabel,
            fontSize = 9.sp,
            color = palette.secondaryLabel
        )
    }
}

private fun dayOfWeek(date: Date): String =
    SimpleDateFormat("EEE", Locale.getDefault()).format(date)
