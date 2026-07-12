package com.example.onmytss.presentation.today

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Bedtime
import androidx.compose.material.icons.filled.DirectionsRun
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.MonitorHeart
import androidx.compose.material.icons.filled.NightsStay
import androidx.compose.material.icons.filled.ShowChart
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.outlined.Battery5Bar
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.LargeTopAppBar
import androidx.compose.material3.Scaffold
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.rememberTopAppBarState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.example.onmytss.presentation.components.BodyBatteryGauge
import com.example.onmytss.presentation.components.MetricCard
import com.example.onmytss.presentation.components.PhysiologyMetricCard
import com.example.onmytss.presentation.components.SleepMetricCard
import com.example.onmytss.presentation.components.TSSGuidanceCard
import com.example.onmytss.presentation.components.WeekTrendChart
import com.example.onmytss.presentation.theme.IosColors

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TodayScreen(viewModel: TodayViewModel = hiltViewModel()) {
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    val palette = IosColors.current
    val scrollBehavior = TopAppBarDefaults.exitUntilCollapsedScrollBehavior(rememberTopAppBarState())

    Scaffold(
        modifier = Modifier
            .fillMaxSize()
            .background(palette.systemGroupedBackground)
            .nestedScroll(scrollBehavior.nestedScrollConnection),
        topBar = {
            LargeTopAppBar(
                title = {
                    Text(
                        text = "Body Battery",
                        style = MaterialTheme.typography.displayLarge,
                        fontWeight = FontWeight.Bold,
                        color = palette.label
                    )
                },
                scrollBehavior = scrollBehavior,
                colors = TopAppBarDefaults.largeTopAppBarColors(
                    containerColor = palette.systemGroupedBackground,
                    scrolledContainerColor = palette.systemGroupedBackground
                )
            )
        },
        containerColor = palette.systemGroupedBackground
    ) { insets ->
        when {
            state.isLoading -> LoadingView(insets)
            state.showEmptyState -> EmptyStateView(insets)
            else -> ContentView(state, insets)
        }
    }
}

@Composable
private fun ContentView(state: TodayUiState, insets: PaddingValues) {
    val palette = IosColors.current
    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(insets)
            .padding(vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        if (state.illnessAlertVisible) {
            IllnessAlertBanner()
        }

        BodyBatteryGauge(
            score = state.score,
            readinessLevel = state.readinessLevel,
            modifier = Modifier.padding(top = if (state.illnessAlertVisible) 0.dp else 20.dp)
        )

        // Readiness info
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                Text(
                    text = state.readinessLevel.emoji,
                    style = MaterialTheme.typography.headlineMedium
                )
                Text(
                    text = state.readinessLevel.displayName,
                    style = MaterialTheme.typography.headlineMedium.copy(fontWeight = FontWeight.SemiBold),
                    color = palette.label
                )
            }
            Text(
                text = state.readinessDescription,
                style = MaterialTheme.typography.bodySmall,
                color = palette.secondaryLabel
            )
        }

        // Metric cards row
        Row(
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp)
        ) {
            MetricCard(title = "Freshness", value = state.tsbFormatted, subtitle = "TSB", modifier = Modifier.weight(1f))
            MetricCard(title = "Fitness", value = state.ctlFormatted, subtitle = "CTL", modifier = Modifier.weight(1f))
            MetricCard(title = "Fatigue", value = state.atlFormatted, subtitle = "ATL", modifier = Modifier.weight(1f))
        }

        if (state.hasPhysiologyData) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                state.recoveryStatus?.let { recovery ->
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(12.dp))
                            .background(palette.secondarySystemBackground)
                            .padding(16.dp)
                    ) {
                        Icon(
                            imageVector = Icons.Filled.MonitorHeart,
                            contentDescription = null,
                            tint = palette.systemPink,
                            modifier = Modifier.size(20.dp)
                        )
                        Text(
                            text = recovery,
                            style = MaterialTheme.typography.bodySmall.copy(fontWeight = FontWeight.Medium),
                            color = palette.label
                        )
                        Spacer(modifier = Modifier.weight(1f))
                        state.combinedModifierFormatted?.let { mod ->
                            val c = when {
                                mod.startsWith("+") -> palette.systemGreen
                                mod.startsWith("-") -> palette.systemOrange
                                else -> palette.secondaryLabel
                            }
                            Text(
                                text = mod,
                                style = MaterialTheme.typography.bodySmall.copy(fontWeight = FontWeight.SemiBold),
                                color = c
                            )
                        }
                    }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    state.hrvFormatted?.let {
                        PhysiologyMetricCard(
                            icon = Icons.Filled.MonitorHeart,
                            title = "HRV",
                            value = it,
                            modifierText = state.hrvModifierFormatted,
                            modifier = Modifier.weight(1f)
                        )
                    }
                    state.rhrFormatted?.let {
                        PhysiologyMetricCard(
                            icon = Icons.Filled.Favorite,
                            title = "RHR",
                            value = it,
                            modifierText = state.rhrModifierFormatted,
                            modifier = Modifier.weight(1f)
                        )
                    }
                }
            }
        }

        if (state.hasSleepData) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Icon(
                        imageVector = Icons.Filled.NightsStay,
                        contentDescription = null,
                        tint = palette.systemIndigo,
                        modifier = Modifier.size(20.dp)
                    )
                    state.sleepQualityDescription?.let {
                        Text(
                            text = it,
                            style = MaterialTheme.typography.bodySmall.copy(fontWeight = FontWeight.Medium),
                            color = palette.label
                        )
                    }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    state.sleepDurationFormatted?.let {
                        SleepMetricCard(
                            icon = Icons.Filled.Bedtime,
                            title = "Sleep",
                            value = it,
                            modifier = Modifier.weight(1f)
                        )
                    }
                    state.deepSleepFormatted?.let {
                        SleepMetricCard(
                            icon = Icons.Filled.NightsStay,
                            title = "Deep",
                            value = it,
                            modifier = Modifier.weight(1f)
                        )
                    }
                    state.sleepQualityFormatted?.let {
                        SleepMetricCard(
                            icon = Icons.Filled.Star,
                            title = "Quality",
                            value = it,
                            modifier = Modifier.weight(1f)
                        )
                    }
                }
            }
        }

        state.tssRecommendation?.let { rec ->
            TSSGuidanceCard(
                recommendation = rec,
                readinessLevel = state.readinessLevel,
                modifier = Modifier.padding(horizontal = 16.dp)
            )
        }

        WeekTrendChart(
            scores = state.weekScores,
            modifier = Modifier.padding(horizontal = 16.dp)
        )

        state.rampRateStatus?.let { s ->
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                modifier = Modifier.padding(horizontal = 16.dp)
            ) {
                Icon(
                    imageVector = Icons.Filled.ShowChart,
                    contentDescription = null,
                    tint = palette.secondaryLabel,
                    modifier = Modifier.size(14.dp)
                )
                Text(
                    text = s,
                    style = MaterialTheme.typography.labelMedium,
                    color = palette.secondaryLabel
                )
            }
        }

        if (state.todayWorkoutCount > 0) {
            Column(modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp)) {
                HorizontalDivider(color = palette.separator)
                Spacer(modifier = Modifier.height(8.dp))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(
                        imageVector = Icons.Filled.DirectionsRun,
                        contentDescription = null,
                        tint = palette.secondaryLabel,
                        modifier = Modifier.size(20.dp)
                    )
                    Spacer(modifier = Modifier.size(8.dp))
                    Column {
                        Text(
                            text = "Today's Training",
                            style = MaterialTheme.typography.bodySmall.copy(fontWeight = FontWeight.Medium),
                            color = palette.label
                        )
                        val label = if (state.todayWorkoutCount > 1) "workouts" else "workout"
                        Text(
                            text = "${state.todayWorkoutCount} $label, ${state.todayTSS} TSS",
                            style = MaterialTheme.typography.labelMedium,
                            color = palette.secondaryLabel
                        )
                    }
                }
            }
        }

        Spacer(modifier = Modifier.height(40.dp))
    }
}

@Composable
private fun IllnessAlertBanner() {
    val palette = IosColors.current
    val color = palette.systemOrange
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 8.dp)
            .clip(RoundedCornerShape(12.dp))
            .background(color.copy(alpha = 0.1f))
            .border(width = 1.dp, color = color.copy(alpha = 0.3f), shape = RoundedCornerShape(12.dp))
            .padding(16.dp)
    ) {
        Icon(
            imageVector = Icons.Filled.Warning,
            contentDescription = null,
            tint = color,
            modifier = Modifier.size(22.dp)
        )
        Column {
            Text(
                text = "Elevated Illness Risk",
                style = MaterialTheme.typography.titleSmall,
                color = palette.label
            )
            Text(
                text = "HRV and/or RHR suggest your body is under stress. Consider rest.",
                style = MaterialTheme.typography.bodySmall,
                color = palette.secondaryLabel
            )
        }
    }
}

@Composable
private fun LoadingView(insets: PaddingValues) {
    val palette = IosColors.current
    Column(
        modifier = Modifier.fillMaxSize().padding(insets),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        CircularProgressIndicator(color = palette.systemBlue)
        Spacer(modifier = Modifier.height(16.dp))
        Text(
            text = "Loading your Body Battery...",
            style = MaterialTheme.typography.bodySmall,
            color = palette.secondaryLabel
        )
    }
}

@Composable
private fun EmptyStateView(insets: PaddingValues) {
    val palette = IosColors.current
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(insets)
            .padding(horizontal = 32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        Icon(
            imageVector = Icons.Outlined.Battery5Bar,
            contentDescription = null,
            tint = palette.systemBlue,
            modifier = Modifier.size(72.dp)
        )
        Spacer(modifier = Modifier.height(24.dp))
        Text(
            text = "Ready to Track Your Readiness",
            style = MaterialTheme.typography.headlineMedium.copy(fontWeight = FontWeight.SemiBold),
            color = palette.label
        )
        Spacer(modifier = Modifier.height(12.dp))
        Text(
            text = "Complete a workout in Health Connect to see your Body Battery score.",
            style = MaterialTheme.typography.bodyLarge,
            color = palette.secondaryLabel
        )
    }
}
