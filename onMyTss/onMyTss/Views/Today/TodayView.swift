//
//  TodayView.swift
//  onMyTss
//
//  Created by Claude Code
//

import SwiftUI
import SwiftData

/// Main Today screen showing current Body Battery score, guidance, and trends
struct TodayView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel: TodayViewModel

    init(engine: any BodyBatteryEngineProtocol, dataStore: DataStore) {
        _viewModel = State(initialValue: TodayViewModel(engine: engine, dataStore: dataStore))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if viewModel.isLoading {
                    loadingView
                } else if viewModel.showEmptyState {
                    emptyStateView
                } else {
                    contentView
                }
            }
            .navigationTitle("Body Battery")
            .navigationBarTitleDisplayMode(.large)
            .refreshable {
                await viewModel.refresh()
            }
            .task {
                await viewModel.loadData()
            }
            .overlay {
                if let errorMessage = viewModel.errorMessage {
                    errorBanner(message: errorMessage)
                }
            }
        }
    }

    // MARK: - Content Views

    private var contentView: some View {
        VStack(spacing: 24) {
            // Illness Alert (if detected)
            if let alert = viewModel.illnessAlert {
                illnessAlertBanner(alert: alert)
            }

            // Gauge
            BodyBatteryGauge(
                score: viewModel.todayScore,
                readinessLevel: viewModel.readinessLevel
            )
            .frame(width: 220, height: 220)
            .padding(.top, viewModel.illnessAlert == nil ? 20 : 0)

            // Readiness Info
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Text(viewModel.readinessLevel.emoji)
                        .font(.title)

                    Text(viewModel.readinessLevel.rawValue)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.primary)
                }

                Text(viewModel.readinessDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            // Metrics Cards
            HStack(spacing: 12) {
                MetricCard(title: "Freshness", value: viewModel.tsbFormatted, subtitle: "TSB")
                MetricCard(title: "Fitness", value: viewModel.ctlFormatted, subtitle: "CTL")
                MetricCard(title: "Fatigue", value: viewModel.atlFormatted, subtitle: "ATL")
            }
            .padding(.horizontal)

            // HRV/RHR Recovery Section
            if viewModel.hasPhysiologyData {
                VStack(alignment: .leading, spacing: 12) {
                    // Recovery Status Header
                    if let recoveryStatus = viewModel.recoveryStatus {
                        HStack(spacing: 8) {
                            Image(systemName: "heart.text.square.fill")
                                .font(.title3)
                                .foregroundStyle(.pink)

                            Text(recoveryStatus)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)

                            Spacer()

                            if let modifier = viewModel.combinedModifierFormatted {
                                Text(modifier)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(
                                        modifier.hasPrefix("+") ? .green :
                                        modifier.hasPrefix("-") ? .orange : .secondary
                                    )
                            }
                        }
                        .padding()
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color(uiColor: .secondarySystemBackground))
                        )
                    }

                    // HRV and RHR Values
                    HStack(spacing: 12) {
                        if let hrv = viewModel.hrvFormatted {
                            PhysiologyMetricCard(
                                icon: "waveform.path.ecg",
                                title: "HRV",
                                value: hrv,
                                modifier: viewModel.hrvModifierFormatted
                            )
                        }

                        if let rhr = viewModel.rhrFormatted {
                            PhysiologyMetricCard(
                                icon: "heart.fill",
                                title: "RHR",
                                value: rhr,
                                modifier: viewModel.rhrModifierFormatted
                            )
                        }
                    }
                }
                .padding(.horizontal)
            }

            // TSS Guidance Card
            if let recommendation = viewModel.tssRecommendation {
                TSSGuidanceCard(
                    recommendation: recommendation,
                    readinessLevel: viewModel.readinessLevel
                )
                .padding(.horizontal)
            }

            // Week Trend
            WeekTrendView(scores: viewModel.weekScores)
                .padding(.horizontal)

            // Ramp Rate Status
            if let rampRateStatus = viewModel.rampRateStatus {
                HStack(spacing: 8) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(rampRateStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
            }

            // Today's Activity Summary
            if let metrics = viewModel.todayMetrics, metrics.workoutCount > 0 {
                VStack(spacing: 8) {
                    Divider()
                        .padding(.horizontal)

                    HStack {
                        Image(systemName: "figure.run")
                            .font(.title3)
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Today's Training")
                                .font(.subheadline.weight(.medium))

                            Text("\(metrics.workoutCount) workout\(metrics.workoutCount > 1 ? "s" : ""), \(viewModel.todayTSS) TSS")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()
                    }
                    .padding(.horizontal)
                }
            }

            Spacer(minLength: 40)
        }
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            Spacer()

            ProgressView()
                .scaleEffect(1.5)

            Text("Loading your Body Battery...")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateView: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "battery.100.bolt")
                .font(.system(size: 72))
                .foregroundStyle(.blue.gradient)

            VStack(spacing: 12) {
                Text("Ready to Track Your Readiness")
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)

                Text("Complete a workout in Apple Health to see your Body Battery score.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorBanner(message: String) -> some View {
        VStack {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)

                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.primary)

                Spacer()

                Button("Dismiss") {
                    viewModel.errorMessage = nil
                }
                .font(.subheadline.weight(.medium))
            }
            .padding()
            .background(Color(uiColor: .secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.1), radius: 10, y: 5)
            .padding()

            Spacer()
        }
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func illnessAlertBanner(alert: IllnessAlert) -> some View {
        let iconName: String = {
            switch alert.severity {
            case .high: return "cross.case.fill"
            case .medium: return "exclamationmark.triangle.fill"
            case .low: return "info.circle.fill"
            }
        }()

        let iconColor: Color = {
            switch alert.severity {
            case .high: return .red
            case .medium: return .orange
            case .low: return .yellow
            }
        }()

        let bgColor = iconColor.opacity(0.1)
        let borderColor = iconColor.opacity(0.3)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: iconName)
                    .font(.title2)
                    .foregroundStyle(iconColor)

                Text(alert.title)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.primary)
            }

            Text(alert.message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(RoundedRectangle(cornerRadius: 12).fill(bgColor))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(borderColor, lineWidth: 1))
        .padding(.horizontal)
        .padding(.top, 8)
    }
}

// MARK: - Metric Card

struct MetricCard: View {
    let title: String
    let value: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(value)
                .font(.title2.weight(.bold))
                .foregroundStyle(.primary)

            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
    }
}

// MARK: - Physiology Metric Card

struct PhysiologyMetricCard: View {
    let icon: String
    let title: String
    let value: String
    let modifier: String?

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(.pink)

                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(value)
                .font(.title3.weight(.bold))
                .foregroundStyle(.primary)

            if let modifier = modifier {
                Text(modifier)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(
                        modifier.hasPrefix("+") ? .green :
                        modifier.hasPrefix("-") ? .orange : .secondary
                    )
            } else {
                Text("—")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
    }
}

// MARK: - Previews

#Preview("With Data") {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: DayAggregate.self, UserThresholds.self, AppState.self, configurations: config)
    let dataStore = DataStore(modelContainer: container)

    // Create sample data with HRV/RHR
    let today = Date().startOfDay
    let aggregate = DayAggregate(
        date: today,
        totalTSS: 120,
        ctl: 85,
        atl: 95,
        tsb: -10,
        bodyBatteryScore: 65,
        rampRate: 3.5,
        workoutCount: 1,
        maxTSSWorkout: 120,
        avgHRV: 45.0,
        avgRHR: 52.0,
        hrvModifier: 8.0,
        rhrModifier: 5.0
    )

    try! dataStore.saveDayAggregate(aggregate)

    let healthKitManager = HealthKitManager()
    let engine = BodyBatteryEngine(healthKitManager: healthKitManager, dataStore: dataStore)

    return TodayView(engine: engine, dataStore: dataStore)
        .modelContainer(container)
}

#Preview("Empty State") {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: DayAggregate.self, UserThresholds.self, AppState.self, configurations: config)
    let dataStore = DataStore(modelContainer: container)

    let healthKitManager = HealthKitManager()
    let engine = BodyBatteryEngine(healthKitManager: healthKitManager, dataStore: dataStore)

    return TodayView(engine: engine, dataStore: dataStore)
        .modelContainer(container)
}

#Preview("Loading") {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: DayAggregate.self, UserThresholds.self, AppState.self, configurations: config)
    let dataStore = DataStore(modelContainer: container)

    let healthKitManager = HealthKitManager()
    let engine = BodyBatteryEngine(healthKitManager: healthKitManager, dataStore: dataStore)

    return TodayView(engine: engine, dataStore: dataStore)
        .modelContainer(container)
}
