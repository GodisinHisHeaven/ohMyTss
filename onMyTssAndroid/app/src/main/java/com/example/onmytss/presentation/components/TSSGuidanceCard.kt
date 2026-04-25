package com.example.onmytss.presentation.components

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.example.onmytss.domain.model.TSSRecommendation
import com.example.onmytss.domain.model.enums.ReadinessLevel
import com.example.onmytss.domain.model.enums.TSSIntensity
import com.example.onmytss.presentation.theme.BatteryBlue
import com.example.onmytss.presentation.theme.BatteryGreen
import com.example.onmytss.presentation.theme.BatteryPurple
import com.example.onmytss.presentation.theme.BatteryRed
import com.example.onmytss.presentation.theme.BatteryYellow
import com.example.onmytss.presentation.theme.IosColors

@Composable
fun TSSGuidanceCard(
    recommendation: TSSRecommendation,
    readinessLevel: ReadinessLevel,
    modifier: Modifier = Modifier
) {
    val palette = IosColors.current
    val intensityColor = when (recommendation.intensity) {
        TSSIntensity.RECOVERY -> BatteryRed
        TSSIntensity.ENDURANCE -> BatteryGreen
        TSSIntensity.TEMPO -> BatteryYellow
        TSSIntensity.THRESHOLD -> BatteryBlue
        TSSIntensity.VO2_MAX -> BatteryPurple
        TSSIntensity.ANAEROBIC -> BatteryRed
    }

    Column(
        modifier = modifier
            .fillMaxWidth()
            .shadow(elevation = 4.dp, shape = RoundedCornerShape(16.dp))
            .clip(RoundedCornerShape(16.dp))
            .background(palette.systemBackground)
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        // Header: "Today's Training" + intensity capsule
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.fillMaxWidth()
        ) {
            Text(
                text = "Today's Training",
                style = MaterialTheme.typography.titleSmall,
                color = palette.label
            )
            Spacer(modifier = Modifier.weight(1f))
            Text(
                text = recommendation.intensity.displayName.uppercase(),
                style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.SemiBold),
                color = intensityColor,
                modifier = Modifier
                    .clip(CircleShape)
                    .background(intensityColor.copy(alpha = 0.2f))
                    .padding(horizontal = 8.dp, vertical = 4.dp)
            )
        }

        HorizontalDivider(color = palette.separator)

        // Suggested TSS value
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(
                text = "Suggested TSS",
                style = MaterialTheme.typography.bodySmall,
                color = palette.secondaryLabel
            )
            Row(verticalAlignment = Alignment.Bottom) {
                Text(
                    text = "${recommendation.optimal}",
                    style = TextStyle(
                        fontFamily = FontFamily.Default,
                        fontWeight = FontWeight.Bold,
                        fontSize = 32.sp
                    ),
                    color = intensityColor
                )
                Spacer(modifier = Modifier.padding(horizontal = 2.dp))
                Text(
                    text = "(${recommendation.min}-${recommendation.max})",
                    style = MaterialTheme.typography.bodySmall,
                    color = palette.secondaryLabel,
                    modifier = Modifier.padding(bottom = 4.dp)
                )
            }
            TSSRangeBar(
                min = recommendation.min,
                optimal = recommendation.optimal,
                max = recommendation.max,
                color = intensityColor,
                modifier = Modifier
                    .fillMaxWidth()
                    .height(8.dp)
            )
        }

        // Description
        Text(
            text = recommendation.description,
            style = MaterialTheme.typography.bodyLarge,
            color = palette.secondaryLabel,
            maxLines = 2
        )

        // Readiness indicator row
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
            modifier = Modifier.padding(top = 4.dp)
        ) {
            Text(
                text = readinessLevel.emoji,
                style = MaterialTheme.typography.headlineSmall
            )
            Text(
                text = readinessLevel.displayName,
                style = MaterialTheme.typography.bodySmall.copy(fontWeight = FontWeight.Medium),
                color = palette.secondaryLabel
            )
        }
    }
}

@Composable
private fun TSSRangeBar(
    min: Int,
    optimal: Int,
    max: Int,
    color: Color,
    modifier: Modifier = Modifier
) {
    Box(modifier = modifier) {
        Canvas(modifier = Modifier.fillMaxWidth().height(8.dp)) {
            val corner = CornerRadius(4.dp.toPx(), 4.dp.toPx())
            // Background (0.2 alpha)
            drawRoundRect(
                color = color.copy(alpha = 0.2f),
                size = size,
                cornerRadius = corner
            )
            // Range fill (0.4 alpha — full width in iOS impl)
            drawRoundRect(
                color = color.copy(alpha = 0.4f),
                size = Size(size.width, size.height),
                cornerRadius = corner
            )
            // Optimal dot
            val range = (max - min).coerceAtLeast(1)
            val ratio = (optimal - min).toFloat() / range.toFloat()
            val cx = (size.width * ratio).coerceIn(6.dp.toPx(), size.width - 6.dp.toPx())
            drawCircle(
                color = color,
                radius = 6.dp.toPx(),
                center = Offset(cx, size.height / 2f)
            )
        }
    }
}
