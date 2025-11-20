//
//  HistoryView.swift
//  onMyTss
//
//  Created by Claude Code
//

import SwiftUI
import SwiftData
import Charts

/// History screen showing past Body Battery scores and metrics
struct HistoryView: View {
    @State private var viewModel: HistoryViewModel

    init(dataStore: DataStore) {
        _viewModel = State(initialValue: HistoryViewModel(dataStore: dataStore))
    }

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isLoading {
                    loadingView
                } else if viewModel.showEmptyState {
                    emptyStateView
                } else {
                    contentView
                }
            }
            .navigationTitle("History")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Days", selection: Binding(
                            get: { viewModel.selectedDays },
                            set: { newValue in
                                Task {
                                    await viewModel.changeDaysSelection(newValue)
                                }
                            }
                        )) {
                            Text("7 Days").tag(7)
                            Text("14 Days").tag(14)
                            Text("30 Days").tag(30)
                            Text("90 Days").tag(90)
                        }
                    } label: {
                        Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
                    }
                }
            }
            .task {
                await viewModel.loadHistory()
            }
        }
    }

    // MARK: - Content Views

    private var contentView: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Summary Cards
                summarySection

                // CTL/ATL/TSB Charts (shown for 14+ days)
                if viewModel.selectedDays >= 14 {
                    chartsSection
                }

                // History List
                VStack(spacing: 0) {
                    ForEach(viewModel.historyItems) { item in
                        HistoryRowView(item: item)

                        if item.id != viewModel.historyItems.last?.id {
                            Divider()
                                .padding(.leading, 16)
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color(uiColor: .systemBackground))
                        .shadow(color: .black.opacity(0.1), radius: 10, y: 5)
                )
                .padding(.horizontal)
            }
            .padding(.vertical)
        }
        .background(Color(uiColor: .secondarySystemBackground))
    }

    private var summarySection: some View {
        HStack(spacing: 12) {
            SummaryCard(
                title: "Avg Score",
                value: "\(viewModel.averageScore)",
                icon: "battery.75"
            )

            SummaryCard(
                title: "Avg CTL",
                value: "\(viewModel.averageCTL)",
                icon: "chart.line.uptrend.xyaxis"
            )

            SummaryCard(
                title: "Total TSS",
                value: "\(viewModel.totalTSS)",
                icon: "bolt.fill"
            )

            SummaryCard(
                title: "Workouts",
                value: "\(viewModel.totalWorkouts)",
                icon: "figure.run"
            )
        }
        .padding(.horizontal)
    }

    private var chartsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Section Header
            Text("Training Load Trends")
                .font(.headline)
                .padding(.horizontal)

            // CTL/ATL Chart
            VStack(alignment: .leading, spacing: 8) {
                Text("Fitness & Fatigue (CTL/ATL)")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)

                Chart {
                    // Use linear interpolation for large datasets for better performance
                    let interpolation: InterpolationMethod = viewModel.chartData.count > 30 ? .linear : .catmullRom

                    // CTL (Fitness) line - shown in blue
                    ForEach(viewModel.chartData) { point in
                        LineMark(
                            x: .value("Date", point.date),
                            y: .value("Load", point.ctl),
                            series: .value("Metric", "CTL (Fitness)")
                        )
                        .foregroundStyle(.blue)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .interpolationMethod(interpolation)
                        .symbol(Circle().strokeBorder(lineWidth: 1.5))
                        .symbolSize(30)
                    }

                    // ATL (Fatigue) line - shown in orange
                    ForEach(viewModel.chartData) { point in
                        LineMark(
                            x: .value("Date", point.date),
                            y: .value("Load", point.atl),
                            series: .value("Metric", "ATL (Fatigue)")
                        )
                        .foregroundStyle(.orange)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .interpolationMethod(interpolation)
                        .symbol(Circle().strokeBorder(lineWidth: 1.5))
                        .symbolSize(30)
                    }
                }
                .chartYAxisLabel("Load", alignment: .leading)
                .chartLegend(position: .bottom)
                .frame(height: 200)
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(uiColor: .systemBackground))
                )
            }
            .padding(.horizontal)

            // TSB Chart
            VStack(alignment: .leading, spacing: 8) {
                Text("Training Stress Balance (TSB)")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)

                Chart(viewModel.chartData) { point in
                    BarMark(
                        x: .value("Date", point.date),
                        y: .value("TSB", point.tsb)
                    )
                    .foregroundStyle(point.tsb >= 0 ? .green : .red)

                    RuleMark(y: .value("Zero", 0))
                        .foregroundStyle(.gray.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 5]))
                }
                .chartYAxisLabel("TSB", alignment: .leading)
                .frame(height: 160)
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(uiColor: .systemBackground))
                )
            }
            .padding(.horizontal)

            // Daily TSS Chart
            VStack(alignment: .leading, spacing: 8) {
                Text("Daily Training Stress (TSS)")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)

                Chart(viewModel.chartData) { point in
                    BarMark(
                        x: .value("Date", point.date),
                        y: .value("TSS", point.tss)
                    )
                    .foregroundStyle(.purple.gradient)
                }
                .chartYAxisLabel("TSS", alignment: .leading)
                .frame(height: 140)
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(uiColor: .systemBackground))
                )
            }
            .padding(.horizontal)
        }
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)

            Text("Loading history...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateView: some View {
        VStack(spacing: 24) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 72))
                .foregroundStyle(.blue.gradient)

            VStack(spacing: 12) {
                Text("No History Yet")
                    .font(.title2.weight(.semibold))

                Text("Complete workouts to see your Body Battery history.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Summary Card

struct SummaryCard: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.blue)

            Text(value)
                .font(.title3.weight(.bold))
                .foregroundStyle(.primary)

            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(uiColor: .systemBackground))
                .shadow(color: .black.opacity(0.05), radius: 5, y: 2)
        )
    }
}

// MARK: - History Row View

struct HistoryRowView: View {
    let item: HistoryItem

    var body: some View {
        HStack(spacing: 16) {
            // Date and Day
            VStack(alignment: .leading, spacing: 4) {
                Text(item.weekdayDisplay)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(item.dateDisplay)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)

                if item.isToday {
                    Text("Today")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                }
            }
            .frame(width: 60, alignment: .leading)

            // Score Gauge
            ZStack {
                Circle()
                    .stroke(Color.gray.opacity(0.2), lineWidth: 4)
                    .frame(width: 50, height: 50)

                Circle()
                    .trim(from: 0, to: CGFloat(item.score) / 100.0)
                    .stroke(scoreColor(item.score), lineWidth: 4)
                    .frame(width: 50, height: 50)
                    .rotationEffect(.degrees(-90))

                Text("\(item.score)")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(scoreColor(item.score))
            }

            // Metrics
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    MetricLabel(label: "TSB", value: item.tsbDisplay)
                    MetricLabel(label: "CTL", value: "\(Int(item.ctl))")
                    MetricLabel(label: "ATL", value: "\(Int(item.atl))")
                }

                HStack(spacing: 4) {
                    if item.workoutCount > 0 {
                        Image(systemName: "figure.run")
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        Text("\(item.workoutCount) workout\(item.workoutCount > 1 ? "s" : ""), \(Int(item.tss)) TSS")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Rest day")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()
        }
        .padding(16)
        .background(item.isToday ? Color.blue.opacity(0.05) : Color.clear)
    }

    private func scoreColor(_ score: Int) -> Color {
        let level = BodyBatteryCalculator.getReadinessLevel(score: score)
        switch level {
        case .veryLow: return Color(hex: "#E53E3E")
        case .low: return Color(hex: "#DD6B20")
        case .medium: return Color(hex: "#D69E2E")
        case .good: return Color(hex: "#38A169")
        case .excellent: return Color(hex: "#3182CE")
        }
    }
}

// MARK: - Metric Label

struct MetricLabel: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Text(value)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Previews

#Preview("With Data") {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: DayAggregate.self, UserThresholds.self, AppState.self, configurations: config)
    let dataStore = DataStore(modelContainer: container)

    // Create sample data
    let today = Date().startOfDay
    for i in 0..<7 {
        let date = today.addingTimeInterval(TimeInterval(-i * 86400))
        let aggregate = DayAggregate(
            date: date,
            totalTSS: Double.random(in: 50...150),
            ctl: 80 + Double(i) * 2,
            atl: 90 - Double(i) * 1.5,
            tsb: -10 + Double(i) * 3,
            bodyBatteryScore: 45 + i * 5,
            rampRate: 3.5,
            workoutCount: i % 2 == 0 ? 1 : 0,
            maxTSSWorkout: i % 2 == 0 ? 120 : nil
        )
        try! dataStore.saveDayAggregate(aggregate)
    }

    return HistoryView(dataStore: dataStore)
        .modelContainer(container)
}

#Preview("Empty") {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: DayAggregate.self, UserThresholds.self, AppState.self, configurations: config)
    let dataStore = DataStore(modelContainer: container)

    return HistoryView(dataStore: dataStore)
        .modelContainer(container)
}
