package com.example.onmytss.presentation.components

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.example.onmytss.presentation.theme.IosColors

/**
 * Mirrors iOS MetricCard (TodayView.swift):
 *  Title (.caption / secondary) / Value (.title2 bold / primary) / Subtitle (.caption2 / tertiary)
 *  12dp rounded, secondarySystemBackground fill, 16pt vertical padding, equal width (weight(1f))
 */
@Composable
fun MetricCard(
    title: String,
    value: String,
    subtitle: String,
    modifier: Modifier = Modifier
) {
    val palette = IosColors.current
    Column(
        modifier = modifier
            .clip(RoundedCornerShape(12.dp))
            .background(palette.secondarySystemBackground)
            .padding(vertical = 16.dp, horizontal = 8.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        Text(
            text = title,
            style = MaterialTheme.typography.labelMedium,
            color = palette.secondaryLabel
        )
        Text(
            text = value,
            style = MaterialTheme.typography.titleLarge.copy(fontWeight = FontWeight.Bold),
            color = palette.label
        )
        Text(
            text = subtitle,
            style = MaterialTheme.typography.labelSmall,
            color = palette.tertiaryLabel
        )
    }
}

/** Mirrors iOS PhysiologyMetricCard (heart/HRV, pink icon tint, modifier row). */
@Composable
fun PhysiologyMetricCard(
    icon: ImageVector,
    title: String,
    value: String,
    modifierText: String?,
    modifier: Modifier = Modifier
) {
    val palette = IosColors.current
    Column(
        modifier = modifier
            .clip(RoundedCornerShape(12.dp))
            .background(palette.secondarySystemBackground)
            .padding(vertical = 12.dp, horizontal = 8.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        Row(
            horizontalArrangement = Arrangement.spacedBy(4.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = palette.systemPink,
                modifier = Modifier.size(14.dp)
            )
            Text(
                text = title,
                style = MaterialTheme.typography.labelMedium,
                color = palette.secondaryLabel
            )
        }
        Text(
            text = value,
            style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold),
            color = palette.label
        )
        val modColor = when {
            modifierText == null -> palette.tertiaryLabel
            modifierText.startsWith("+") -> palette.systemGreen
            modifierText.startsWith("-") -> palette.systemOrange
            else -> palette.secondaryLabel
        }
        Text(
            text = modifierText ?: "—",
            style = MaterialTheme.typography.labelSmall.copy(fontWeight = FontWeight.Medium),
            color = modColor
        )
    }
}

/** Mirrors iOS SleepMetricCard (indigo icon tint, single value). */
@Composable
fun SleepMetricCard(
    icon: ImageVector,
    title: String,
    value: String,
    modifier: Modifier = Modifier
) {
    val palette = IosColors.current
    Column(
        modifier = modifier
            .clip(RoundedCornerShape(12.dp))
            .background(palette.secondarySystemBackground)
            .padding(vertical = 12.dp, horizontal = 8.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        Row(
            horizontalArrangement = Arrangement.spacedBy(4.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = palette.systemIndigo,
                modifier = Modifier.size(14.dp)
            )
            Text(
                text = title,
                style = MaterialTheme.typography.labelMedium,
                color = palette.secondaryLabel
            )
        }
        Text(
            text = value,
            style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold),
            color = palette.label
        )
    }
}

/** Mirrors iOS SummaryCard (history summary cards with icon). */
@Composable
fun SummaryCard(
    title: String,
    value: String,
    icon: ImageVector,
    modifier: Modifier = Modifier
) {
    val palette = IosColors.current
    Column(
        modifier = modifier
            .clip(RoundedCornerShape(12.dp))
            .background(palette.systemBackground)
            .shadowCompat(elevationDp = 2f, cornerRadiusDp = 12f, alpha = 0.05f)
            .padding(vertical = 16.dp, horizontal = 8.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            tint = palette.systemBlue,
            modifier = Modifier.size(20.dp)
        )
        Text(
            text = value,
            style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold),
            color = palette.label
        )
        Text(
            text = title,
            style = MaterialTheme.typography.labelSmall,
            color = palette.secondaryLabel
        )
    }
}

// Compose doesn't have a direct equivalent to SwiftUI's shadow-on-Color,
// but .shadow on non-surface types is fine. Keep as a no-op stub for now;
// proper shadow applied by callers via Modifier.shadow where it matters.
private fun Modifier.shadowCompat(elevationDp: Float, cornerRadiusDp: Float, alpha: Float): Modifier = this
