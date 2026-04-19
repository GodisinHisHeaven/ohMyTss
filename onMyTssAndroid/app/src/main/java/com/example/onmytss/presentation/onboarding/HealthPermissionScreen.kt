package com.example.onmytss.presentation.onboarding

import androidx.activity.result.ActivityResultLauncher
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.DirectionsRun
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.Monitor
import androidx.compose.material.icons.filled.MonitorHeart
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
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.example.onmytss.presentation.theme.IosColors

@Composable
fun HealthPermissionScreen(
    permissionsLauncher: ActivityResultLauncher<Set<String>>,
    permissions: Set<String>,
    onNext: () -> Unit
) {
    val palette = IosColors.current
    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(palette.systemBackground)
            .padding(16.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(30.dp)
    ) {
        Spacer(Modifier.weight(1f))

        Icon(
            imageVector = Icons.Filled.MonitorHeart,
            contentDescription = null,
            modifier = Modifier.size(70.dp),
            tint = palette.systemRed
        )

        Text(
            text = "Health Data Access",
            style = MaterialTheme.typography.headlineLarge,
            fontWeight = FontWeight.Bold,
            color = palette.label
        )

        Text(
            text = "Body Battery needs access to your workout data to calculate your daily readiness score.",
            style = MaterialTheme.typography.bodyLarge,
            color = palette.secondaryLabel,
            textAlign = TextAlign.Center,
            modifier = Modifier.padding(horizontal = 16.dp)
        )

        Spacer(Modifier.weight(1f))

        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp)
                .clip(RoundedCornerShape(12.dp))
                .background(palette.secondarySystemBackground)
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(15.dp)
        ) {
            Text(
                text = "We'll access:",
                style = MaterialTheme.typography.titleSmall.copy(fontWeight = FontWeight.SemiBold),
                color = palette.label
            )
            HealthDataRow(icon = Icons.Filled.DirectionsRun, text = "Workouts")
            HealthDataRow(icon = Icons.Filled.Bolt, text = "Cycling Power")
            HealthDataRow(icon = Icons.Filled.Favorite, text = "Heart Rate")
            HealthDataRow(icon = Icons.Filled.Monitor, text = "Heart Rate Variability")
        }

        Text(
            text = "Your data never leaves your device and is not shared with anyone.",
            style = MaterialTheme.typography.labelMedium,
            color = palette.secondaryLabel,
            textAlign = TextAlign.Center,
            modifier = Modifier.padding(horizontal = 16.dp)
        )

        Spacer(Modifier.weight(1f))

        PrimaryButton(
            text = "Grant Permissions",
            onClick = { permissionsLauncher.launch(permissions) }
        )
        Spacer(Modifier.height(8.dp))
        SecondaryButton(
            text = "Continue",
            onClick = onNext
        )
        Spacer(Modifier.height(20.dp))
    }
}

@Composable
private fun HealthDataRow(icon: ImageVector, text: String) {
    val palette = IosColors.current
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        modifier = Modifier.fillMaxWidth()
    ) {
        Box(
            modifier = Modifier.width(24.dp),
            contentAlignment = Alignment.Center
        ) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = palette.systemBlue,
                modifier = Modifier.size(18.dp)
            )
        }
        Text(
            text = text,
            style = MaterialTheme.typography.bodySmall,
            color = palette.label
        )
    }
}

@Composable
internal fun PrimaryButton(
    text: String,
    enabled: Boolean = true,
    onClick: () -> Unit
) {
    val palette = IosColors.current
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp)
            .clip(RoundedCornerShape(12.dp))
            .background(if (enabled) palette.systemBlue else palette.systemGray3)
            .clickable(enabled = enabled) { onClick() }
            .padding(vertical = 14.dp),
        contentAlignment = Alignment.Center
    ) {
        Text(
            text = text,
            style = MaterialTheme.typography.titleSmall.copy(fontWeight = FontWeight.SemiBold),
            color = Color.White
        )
    }
}

@Composable
internal fun SecondaryButton(
    text: String,
    onClick: () -> Unit
) {
    val palette = IosColors.current
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp)
            .clickable { onClick() }
            .padding(vertical = 8.dp),
        contentAlignment = Alignment.Center
    ) {
        Text(
            text = text,
            style = MaterialTheme.typography.bodyLarge,
            color = palette.secondaryLabel
        )
    }
}
