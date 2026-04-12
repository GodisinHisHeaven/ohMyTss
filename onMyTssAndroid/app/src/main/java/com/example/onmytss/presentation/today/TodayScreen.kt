package com.example.onmytss.presentation.today

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.example.onmytss.presentation.components.BodyBatteryGauge
import com.example.onmytss.presentation.components.MetricCard
import com.example.onmytss.presentation.components.TSSGuidanceCard
import com.example.onmytss.presentation.components.WeekTrendChart
import com.example.onmytss.domain.model.enums.Trend

@Composable
fun TodayScreen(viewModel: TodayViewModel = hiltViewModel()) {
    val uiState by viewModel.uiState.collectAsStateWithLifecycle()

    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(16.dp),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        when {
            uiState.isLoading -> {
                Spacer(modifier = Modifier.height(64.dp))
                CircularProgressIndicator()
                Spacer(modifier = Modifier.height(16.dp))
                Text("Computing Body Battery...")
            }
            uiState.error != null -> {
                Spacer(modifier = Modifier.height(64.dp))
                Text("Error: ${uiState.error}", color = MaterialTheme.colorScheme.error)
                Spacer(modifier = Modifier.height(16.dp))
                Button(onClick = { viewModel.loadData() }) {
                    Text("Retry")
                }
            }
            else -> {
                val aggregate = uiState.aggregate
                Text(
                    text = "Today",
                    style = MaterialTheme.typography.headlineMedium,
                    fontWeight = FontWeight.Bold
                )
                Spacer(modifier = Modifier.height(24.dp))

                BodyBatteryGauge(score = aggregate?.bodyBatteryScore ?: 50)

                Spacer(modifier = Modifier.height(8.dp))
                Text(
                    text = uiState.trend.arrow + " " + uiState.trend.displayName,
                    style = MaterialTheme.typography.bodyLarge
                )

                Spacer(modifier = Modifier.height(24.dp))

                // Illness alert
                if ((aggregate?.illnessLikelihood ?: 0.0) >= 0.7) {
                    Card(
                        modifier = Modifier.fillMaxWidth(),
                        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.errorContainer)
                    ) {
                        Text(
                            "⚠️ High illness likelihood detected. Prioritize rest.",
                            modifier = Modifier.padding(16.dp),
                            color = MaterialTheme.colorScheme.onErrorContainer
                        )
                    }
                    Spacer(modifier = Modifier.height(16.dp))
                }

                // CTL/ATL/TSB cards
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    MetricCard(
                        title = "CTL",
                        value = "${(aggregate?.ctl ?: 0.0).toInt()}",
                        modifier = Modifier.weight(1f)
                    )
                    MetricCard(
                        title = "ATL",
                        value = "${(aggregate?.atl ?: 0.0).toInt()}",
                        modifier = Modifier.weight(1f)
                    )
                    MetricCard(
                        title = "TSB",
                        value = "${(aggregate?.tsb ?: 0.0).toInt()}",
                        modifier = Modifier.weight(1f)
                    )
                }

                Spacer(modifier = Modifier.height(16.dp))

                // HRV / RHR
                if (aggregate?.avgHRV != null || aggregate?.avgRHR != null) {
                    Card(modifier = Modifier.fillMaxWidth()) {
                        Column(modifier = Modifier.padding(16.dp)) {
                            Text("Recovery Metrics", fontWeight = FontWeight.Medium)
                            Spacer(modifier = Modifier.height(8.dp))
                            aggregate.avgHRV?.let {
                                Text("HRV: ${it.toInt()} ms ${if (aggregate.hrvModifier != null) "(${formatModifier(aggregate.hrvModifier!!)})" else ""}")
                            }
                            aggregate.avgRHR?.let {
                                Text("RHR: ${it.toInt()} bpm ${if (aggregate.rhrModifier != null) "(${formatModifier(aggregate.rhrModifier!!)})" else ""}")
                            }
                        }
                    }
                    Spacer(modifier = Modifier.height(16.dp))
                }

                // Sleep
                if (aggregate?.sleepDuration != null) {
                    Card(modifier = Modifier.fillMaxWidth()) {
                        Column(modifier = Modifier.padding(16.dp)) {
                            Text("Sleep", fontWeight = FontWeight.Medium)
                            Spacer(modifier = Modifier.height(8.dp))
                            Text("Duration: ${formatDuration(aggregate.sleepDuration)}")
                            aggregate.sleepQualityScore?.let { Text("Quality: $it/100") }
                            aggregate.deepSleepDuration?.let { Text("Deep: ${formatDuration(it)}") }
                        }
                    }
                    Spacer(modifier = Modifier.height(16.dp))
                }

                // TSS Guidance
                uiState.tssRecommendation?.let {
                    TSSGuidanceCard(recommendation = it)
                    Spacer(modifier = Modifier.height(16.dp))
                }

                // 7-day trend
                if (uiState.recentScores.isNotEmpty()) {
                    WeekTrendChart(scores = uiState.recentScores)
                }
            }
        }
    }
}

private fun formatModifier(value: Double): String {
    return if (value >= 0) "+${value.toInt()}" else "${value.toInt()}"
}

private fun formatDuration(seconds: Double): String {
    val hours = (seconds / 3600).toInt()
    val minutes = ((seconds % 3600) / 60).toInt()
    return "${hours}h ${minutes}m"
}
