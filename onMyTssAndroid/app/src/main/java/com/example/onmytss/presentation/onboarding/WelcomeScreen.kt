package com.example.onmytss.presentation.onboarding

import androidx.compose.foundation.background
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
import androidx.compose.material.icons.filled.DirectionsBike
import androidx.compose.material.icons.filled.Lightbulb
import androidx.compose.material.icons.filled.TrendingUp
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.example.onmytss.presentation.theme.IosColors

@Composable
fun WelcomeScreen(onNext: () -> Unit) {
    val palette = IosColors.current
    val gradient = Brush.linearGradient(
        colors = listOf(palette.systemBlue, palette.systemPurple)
    )

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
            imageVector = Icons.Filled.Bolt,
            contentDescription = null,
            modifier = Modifier.size(80.dp),
            tint = palette.systemBlue
        )

        Text(
            text = "Body Battery",
            style = MaterialTheme.typography.displayLarge,
            fontWeight = FontWeight.Bold,
            color = palette.label
        )

        Text(
            text = "Your Daily Readiness Score",
            style = MaterialTheme.typography.headlineSmall,
            color = palette.secondaryLabel
        )

        Spacer(Modifier.weight(1f))

        Column(
            verticalArrangement = Arrangement.spacedBy(20.dp),
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp)
        ) {
            FeatureRow(
                icon = Icons.Filled.DirectionsBike,
                title = "Track Your Training",
                description = "Automatically analyze workouts from Health Connect",
                iconColor = palette.systemBlue
            )
            FeatureRow(
                icon = Icons.Filled.TrendingUp,
                title = "Monitor Load",
                description = "See your fitness, fatigue, and form metrics",
                iconColor = palette.systemBlue
            )
            FeatureRow(
                icon = Icons.Filled.Lightbulb,
                title = "Get Guidance",
                description = "Receive personalized training recommendations",
                iconColor = palette.systemBlue
            )
        }

        Spacer(Modifier.weight(1f))

        Box(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp)
                .padding(bottom = 30.dp)
                .clip(RoundedCornerShape(12.dp))
                .background(gradient)
                .pointerInput(Unit) {
                    detectTapGestures(onTap = { onNext() })
                }
                .padding(vertical = 14.dp),
            contentAlignment = Alignment.Center
        ) {
            Text(
                text = "Get Started",
                style = MaterialTheme.typography.titleSmall.copy(fontWeight = FontWeight.SemiBold),
                color = Color.White,
                textAlign = TextAlign.Center
            )
        }
    }
}

@Composable
private fun FeatureRow(
    icon: ImageVector,
    title: String,
    description: String,
    iconColor: Color
) {
    val palette = IosColors.current
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(15.dp),
        modifier = Modifier.fillMaxWidth()
    ) {
        Box(
            modifier = Modifier.width(40.dp),
            contentAlignment = Alignment.Center
        ) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = iconColor,
                modifier = Modifier.size(24.dp)
            )
        }
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(
                text = title,
                style = MaterialTheme.typography.titleSmall.copy(fontWeight = FontWeight.SemiBold),
                color = palette.label
            )
            Text(
                text = description,
                style = MaterialTheme.typography.bodySmall,
                color = palette.secondaryLabel
            )
        }
    }
}
