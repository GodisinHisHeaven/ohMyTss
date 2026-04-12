package com.example.onmytss.presentation.components

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.example.onmytss.domain.model.TSSRecommendation

@Composable
fun TSSGuidanceCard(recommendation: TSSRecommendation) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.primaryContainer)
    ) {
        Column(modifier = Modifier.padding(16.dp)) {
            Text("Today's Guidance", fontWeight = FontWeight.Medium)
            Spacer(modifier = Modifier.height(8.dp))
            Text(recommendation.description)
            Spacer(modifier = Modifier.height(8.dp))
            Text("Target TSS: ${recommendation.optimal} (${recommendation.intensity.displayName})")
            Spacer(modifier = Modifier.height(4.dp))
            val progress = if (recommendation.max > 0) recommendation.optimal.toFloat() / recommendation.max.toFloat() else 0f
            LinearProgressIndicator(progress = { progress.coerceIn(0f, 1f) }, modifier = Modifier.fillMaxWidth())
        }
    }
}
