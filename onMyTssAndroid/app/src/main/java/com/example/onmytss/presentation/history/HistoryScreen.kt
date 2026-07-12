package com.example.onmytss.presentation.history

import androidx.compose.foundation.Canvas
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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.BatteryChargingFull
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.CalendarMonth
import androidx.compose.material.icons.filled.DirectionsRun
import androidx.compose.material.icons.filled.FilterList
import androidx.compose.material.icons.filled.TrendingUp
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LargeTopAppBar
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.example.onmytss.domain.calculator.BodyBatteryCalculator
import com.example.onmytss.domain.model.enums.ReadinessLevel
import com.example.onmytss.presentation.components.SummaryCard
import com.example.onmytss.presentation.theme.BatteryBlue
import com.example.onmytss.presentation.theme.BatteryGreen
import com.example.onmytss.presentation.theme.BatteryOrange
import com.example.onmytss.presentation.theme.BatteryRed
import com.example.onmytss.presentation.theme.BatteryYellow
import com.example.onmytss.presentation.theme.IosColors

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HistoryScreen(viewModel: HistoryViewModel = hiltViewModel()) {
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    val palette = IosColors.current
    val scrollBehavior = TopAppBarDefaults.exitUntilCollapsedScrollBehavior()
    var menuExpanded by remember { mutableStateOf(false) }

    Scaffold(
        modifier = Modifier
            .fillMaxSize()
            .nestedScroll(scrollBehavior.nestedScrollConnection),
        topBar = {
            LargeTopAppBar(
                title = {
                    Text(
                        text = "History",
                        style = MaterialTheme.typography.displayLarge,
                        color = palette.label
                    )
                },
                actions = {
                    Box {
                        IconButton(onClick = { menuExpanded = true }) {
                            Icon(
                                imageVector = Icons.Filled.FilterList,
                                contentDescription = "Filter",
                                tint = palette.systemBlue
                            )
                        }
                        DropdownMenu(
                            expanded = menuExpanded,
                            onDismissRequest = { menuExpanded = false }
                        ) {
                            listOf(7, 14, 30, 90).forEach { days ->
                                DropdownMenuItem(
                                    text = {
                                        Text(
                                            text = "$days Days" +
                                                if (state.selectedDays == days) "  ✓" else ""
                                        )
                                    },
                                    onClick = {
                                        viewModel.changeDaysSelection(days)
                                        menuExpanded = false
                                    }
                                )
                            }
                        }
                    }
                },
                scrollBehavior = scrollBehavior
            )
        },
        containerColor = palette.secondarySystemBackground
    ) { innerPadding ->
        when {
            state.isLoading -> LoadingContent(modifier = Modifier.padding(innerPadding))
            state.showEmptyState -> EmptyContent(modifier = Modifier.padding(innerPadding))
            else -> ContentView(
                state = state,
                modifier = Modifier.padding(innerPadding)
            )
        }
    }
}

@Composable
private fun ContentView(state: HistoryUiState, modifier: Modifier = Modifier) {
    val palette = IosColors.current
    Column(
        modifier = modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(vertical = 16.dp),
        verticalArrangement = Arrangement.spacedBy(20.dp)
    ) {
        // Summary row
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            SummaryCard(
                title = "Avg Score",
                value = "${state.averageScore}",
                icon = Icons.Filled.BatteryChargingFull,
                modifier = Modifier.weight(1f)
            )
            SummaryCard(
                title = "Avg CTL",
                value = "${state.averageCTL}",
                icon = Icons.Filled.TrendingUp,
                modifier = Modifier.weight(1f)
            )
            SummaryCard(
                title = "Total TSS",
                value = "${state.totalTSS}",
                icon = Icons.Filled.Bolt,
                modifier = Modifier.weight(1f)
            )
            SummaryCard(
                title = "Workouts",
                value = "${state.totalWorkouts}",
                icon = Icons.Filled.DirectionsRun,
                modifier = Modifier.weight(1f)
            )
        }

        if (state.selectedDays >= 14) {
            ChartsSection(state = state)
        }

        // History list
        Column(
            modifier = Modifier
                .padding(horizontal = 16.dp)
                .fillMaxWidth()
                .shadow(elevation = 4.dp, shape = RoundedCornerShape(16.dp))
                .clip(RoundedCornerShape(16.dp))
                .background(palette.systemBackground)
        ) {
            state.items.forEachIndexed { idx, item ->
                HistoryRow(item = item)
                if (idx != state.items.lastIndex) {
                    HorizontalDivider(
                        color = palette.separator,
                        modifier = Modifier.padding(start = 16.dp)
                    )
                }
            }
        }
    }
}

@Composable
private fun ChartsSection(state: HistoryUiState) {
    val palette = IosColors.current
    Column(
        modifier = Modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(16.dp)
    ) {
        Text(
            text = "Training Load Trends",
            style = MaterialTheme.typography.titleSmall,
            color = palette.label,
            modifier = Modifier.padding(horizontal = 16.dp)
        )

        ChartCard(title = "Fitness & Fatigue (CTL/ATL)") {
            CtlAtlChart(
                points = state.chartData,
                modifier = Modifier
                    .fillMaxWidth()
                    .height(200.dp)
            )
            Spacer(Modifier.height(8.dp))
            Row(
                horizontalArrangement = Arrangement.spacedBy(16.dp),
                modifier = Modifier.fillMaxWidth()
            ) {
                LegendSwatch(color = palette.systemBlue, label = "CTL (Fitness)")
                LegendSwatch(color = palette.systemOrange, label = "ATL (Fatigue)")
            }
        }

        ChartCard(title = "Training Stress Balance (TSB)") {
            TsbChart(
                points = state.chartData,
                modifier = Modifier
                    .fillMaxWidth()
                    .height(160.dp)
            )
        }

        ChartCard(title = "Daily Training Stress (TSS)") {
            TssChart(
                points = state.chartData,
                modifier = Modifier
                    .fillMaxWidth()
                    .height(140.dp)
            )
        }
    }
}

@Composable
private fun ChartCard(
    title: String,
    content: @Composable () -> Unit
) {
    val palette = IosColors.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        Text(
            text = title,
            style = MaterialTheme.typography.bodySmall.copy(fontWeight = FontWeight.Medium),
            color = palette.secondaryLabel
        )
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(12.dp))
                .background(palette.systemBackground)
                .padding(12.dp)
        ) {
            content()
        }
    }
}

@Composable
private fun LegendSwatch(color: Color, label: String) {
    val palette = IosColors.current
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp)
    ) {
        Box(
            modifier = Modifier
                .size(10.dp)
                .clip(RoundedCornerShape(2.dp))
                .background(color)
        )
        Text(
            text = label,
            style = MaterialTheme.typography.labelMedium,
            color = palette.secondaryLabel
        )
    }
}

@Composable
private fun CtlAtlChart(points: List<ChartPoint>, modifier: Modifier = Modifier) {
    val palette = IosColors.current
    if (points.isEmpty()) {
        Box(modifier = modifier)
        return
    }
    val ctlValues = points.map { it.ctl }
    val atlValues = points.map { it.atl }
    val minVal = (ctlValues + atlValues).min().coerceAtMost(0.0)
    val maxVal = (ctlValues + atlValues).max().coerceAtLeast(1.0)
    val gridColor = palette.systemGray5

    Canvas(modifier = modifier) {
        val range = (maxVal - minVal).coerceAtLeast(1.0)
        val stepX = if (points.size > 1) size.width / (points.size - 1) else 0f
        fun yFor(v: Double) = (size.height * (1f - ((v - minVal) / range).toFloat()))

        // Horizontal gridlines
        repeat(4) { i ->
            val y = size.height * (i + 1) / 5f
            drawLine(
                color = gridColor,
                start = Offset(0f, y),
                end = Offset(size.width, y),
                strokeWidth = 1f
            )
        }

        fun drawSeries(values: List<Double>, color: Color) {
            for (i in 0 until values.size - 1) {
                val x1 = i * stepX
                val x2 = (i + 1) * stepX
                val y1 = yFor(values[i])
                val y2 = yFor(values[i + 1])
                drawLine(
                    color = color,
                    start = Offset(x1, y1),
                    end = Offset(x2, y2),
                    strokeWidth = 2.dp.toPx(),
                    cap = StrokeCap.Round
                )
            }
            values.forEachIndexed { i, v ->
                drawCircle(
                    color = color,
                    radius = 2.5.dp.toPx(),
                    center = Offset(i * stepX, yFor(v)),
                    style = Stroke(width = 1.5.dp.toPx())
                )
            }
        }

        drawSeries(ctlValues, palette.systemBlue)
        drawSeries(atlValues, palette.systemOrange)
    }
}

@Composable
private fun TsbChart(points: List<ChartPoint>, modifier: Modifier = Modifier) {
    val palette = IosColors.current
    if (points.isEmpty()) {
        Box(modifier = modifier)
        return
    }
    val values = points.map { it.tsb }
    val minVal = values.min().coerceAtMost(0.0)
    val maxVal = values.max().coerceAtLeast(0.0)
    val range = (maxVal - minVal).coerceAtLeast(1.0)
    val gridColor = palette.systemGray5

    Canvas(modifier = modifier) {
        val barWidth = (size.width / points.size) * 0.7f
        val barSpacing = (size.width / points.size) * 0.3f
        fun yFor(v: Double) = (size.height * (1f - ((v - minVal) / range).toFloat()))
        val zeroY = yFor(0.0)

        points.forEachIndexed { i, p ->
            val slotWidth = size.width / points.size
            val x = i * slotWidth + barSpacing / 2f
            val y0 = yFor(p.tsb)
            val top = minOf(y0, zeroY)
            val bottom = maxOf(y0, zeroY)
            drawRect(
                color = if (p.tsb >= 0) palette.systemGreen else palette.systemRed,
                topLeft = Offset(x, top),
                size = Size(barWidth, (bottom - top).coerceAtLeast(1f))
            )
        }

        // Zero rule (dashed)
        drawLine(
            color = gridColor,
            start = Offset(0f, zeroY),
            end = Offset(size.width, zeroY),
            strokeWidth = 1.dp.toPx(),
            pathEffect = PathEffect.dashPathEffect(floatArrayOf(5f, 5f))
        )
    }
}

@Composable
private fun TssChart(points: List<ChartPoint>, modifier: Modifier = Modifier) {
    val palette = IosColors.current
    if (points.isEmpty()) {
        Box(modifier = modifier)
        return
    }
    val values = points.map { it.tss }
    val maxVal = values.max().coerceAtLeast(1.0)

    Canvas(modifier = modifier) {
        val slotWidth = size.width / points.size
        val barWidth = slotWidth * 0.7f
        val barSpacing = slotWidth * 0.3f
        points.forEachIndexed { i, p ->
            val h = (size.height * (p.tss / maxVal).toFloat()).coerceAtLeast(0f)
            val x = i * slotWidth + barSpacing / 2f
            val y = size.height - h
            drawRect(
                color = palette.systemPurple,
                topLeft = Offset(x, y),
                size = Size(barWidth, h)
            )
        }
    }
}

@Composable
private fun HistoryRow(item: HistoryItem) {
    val palette = IosColors.current
    val background = if (item.isToday) palette.systemBlue.copy(alpha = 0.05f) else Color.Transparent
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(background)
            .padding(16.dp),
        horizontalArrangement = Arrangement.spacedBy(16.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Column(
            modifier = Modifier.width(60.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp)
        ) {
            Text(
                text = item.weekdayDisplay,
                style = MaterialTheme.typography.labelMedium,
                color = palette.secondaryLabel
            )
            Text(
                text = item.dateDisplay,
                style = MaterialTheme.typography.bodySmall.copy(fontWeight = FontWeight.Medium),
                color = palette.label
            )
            if (item.isToday) {
                Text(
                    text = "Today",
                    style = MaterialTheme.typography.labelSmall,
                    color = palette.systemBlue
                )
            }
        }

        MiniGauge(score = item.score)

        Column(
            verticalArrangement = Arrangement.spacedBy(6.dp),
            modifier = Modifier.weight(1f)
        ) {
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                MetricLabel(label = "TSB", value = item.tsbDisplay)
                MetricLabel(label = "CTL", value = "${item.ctl.toInt()}")
                MetricLabel(label = "ATL", value = "${item.atl.toInt()}")
            }
            Row(
                horizontalArrangement = Arrangement.spacedBy(4.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                if (item.workoutCount > 0) {
                    Icon(
                        imageVector = Icons.Filled.DirectionsRun,
                        contentDescription = null,
                        tint = palette.secondaryLabel,
                        modifier = Modifier.size(11.dp)
                    )
                    val plural = if (item.workoutCount > 1) "s" else ""
                    Text(
                        text = "${item.workoutCount} workout$plural, ${item.tss.toInt()} TSS",
                        style = MaterialTheme.typography.labelMedium,
                        color = palette.secondaryLabel
                    )
                } else {
                    Text(
                        text = "Rest day",
                        style = MaterialTheme.typography.labelMedium,
                        color = palette.secondaryLabel
                    )
                }
            }
        }
    }
}

@Composable
private fun MiniGauge(score: Int) {
    val palette = IosColors.current
    val level = BodyBatteryCalculator.getReadinessLevel(score)
    val color = when (level) {
        ReadinessLevel.VERY_LOW -> BatteryRed
        ReadinessLevel.LOW -> BatteryOrange
        ReadinessLevel.MEDIUM -> BatteryYellow
        ReadinessLevel.GOOD -> BatteryGreen
        ReadinessLevel.EXCELLENT -> BatteryBlue
    }
    Box(
        modifier = Modifier.size(50.dp),
        contentAlignment = Alignment.Center
    ) {
        Canvas(modifier = Modifier.fillMaxSize()) {
            val stroke = 4.dp.toPx()
            drawArc(
                color = palette.systemGray4,
                startAngle = 0f,
                sweepAngle = 360f,
                useCenter = false,
                topLeft = Offset(stroke / 2f, stroke / 2f),
                size = Size(size.width - stroke, size.height - stroke),
                style = Stroke(width = stroke)
            )
            rotate(-90f) {
                drawArc(
                    color = color,
                    startAngle = 0f,
                    sweepAngle = 360f * (score / 100f),
                    useCenter = false,
                    topLeft = Offset(stroke / 2f, stroke / 2f),
                    size = Size(size.width - stroke, size.height - stroke),
                    style = Stroke(width = stroke, cap = StrokeCap.Round)
                )
            }
        }
        Text(
            text = "$score",
            fontSize = 16.sp,
            fontWeight = FontWeight.Bold,
            color = color
        )
    }
}

@Composable
private fun MetricLabel(label: String, value: String) {
    val palette = IosColors.current
    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Text(
            text = label,
            style = MaterialTheme.typography.labelSmall,
            color = palette.tertiaryLabel
        )
        Text(
            text = value,
            style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.SemiBold),
            color = palette.secondaryLabel
        )
    }
}

@Composable
private fun LoadingContent(modifier: Modifier = Modifier) {
    val palette = IosColors.current
    Column(
        modifier = modifier.fillMaxSize(),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        CircularProgressIndicator(color = palette.systemBlue)
        Spacer(Modifier.height(16.dp))
        Text(
            text = "Loading history...",
            style = MaterialTheme.typography.bodySmall,
            color = palette.secondaryLabel
        )
    }
}

@Composable
private fun EmptyContent(modifier: Modifier = Modifier) {
    val palette = IosColors.current
    Column(
        modifier = modifier
            .fillMaxSize()
            .padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        Icon(
            imageVector = Icons.Filled.CalendarMonth,
            contentDescription = null,
            tint = palette.systemBlue,
            modifier = Modifier.size(72.dp)
        )
        Spacer(Modifier.height(24.dp))
        Text(
            text = "No History Yet",
            style = MaterialTheme.typography.headlineMedium.copy(fontWeight = FontWeight.SemiBold),
            color = palette.label
        )
        Spacer(Modifier.height(12.dp))
        Text(
            text = "Complete workouts to see your Body Battery history.",
            style = MaterialTheme.typography.bodyLarge,
            color = palette.secondaryLabel
        )
    }
}
