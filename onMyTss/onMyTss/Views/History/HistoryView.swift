import SwiftUI
import SwiftData
import Charts

struct HistoryView: View {
    @State private var days = 30
    @State private var appearedAt = Date()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Time range", selection: $days) {
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 20).padding(.bottom, 8)
                .accessibilityIdentifier("history.range")
                TimelineView(.periodic(from: .now, by: 60)) { timeline in
                    HistoryContent(days: days, now: max(timeline.date, appearedAt))
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("History")
            .onAppear { appearedAt = Date() }
        }
    }
}

private struct HistoryContent: View {
    @Query private var aggregates: [DayAggregate]
    @Query private var workouts: [Workout]
    @State private var trend = TrendKind.readiness
    private enum TrendKind: String, CaseIterable { case readiness = "Readiness", load = "Training load" }

    init(days: Int, now: Date) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -(days - 1),
                                          to: Calendar.current.startOfDay(for: now)) ?? now
        _aggregates = Query(filter: #Predicate<DayAggregate> { $0.date >= cutoff && $0.date <= now }, sort: \.date)
        var recent = FetchDescriptor<Workout>(predicate: #Predicate {
            $0.startTime >= cutoff && $0.startTime <= now && !$0.isTombstoned && !$0.isSuppressed
        }, sortBy: [SortDescriptor(\.startTime, order: .reverse)])
        recent.fetchLimit = 6
        _workouts = Query(recent)
    }

    var body: some View {
        List {
            Section("Trends") {
                VStack(alignment: .leading, spacing: 18) {
                    Picker("Trend", selection: $trend) {
                        ForEach(TrendKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("history.trend")
                    if trend == .readiness {
                        readinessChart
                    } else {
                        loadChart
                    }
                }
                .padding(.vertical, 12)
            }
            Section("Recent workouts") {
                if workouts.isEmpty {
                    Text("No workouts in this period").font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(workouts) { workout in
                    NavigationLink { V2ActivityDetailView(workout: workout) } label: {
                        WorkoutCategoryRow(type: workout.workoutType)
                    }
                    .accessibilityIdentifier("history.workout.\(workout.id)")
                }
            }
        }
        .listSectionSpacing(20)
    }

    @ViewBuilder private var readinessChart: some View {
        let readings = aggregates.filter { TodayReadiness.validScore($0) != nil }
        if readings.isEmpty {
            trendEmpty("Readiness appears when recovery data is available.")
        } else {
            Chart(readings, id: \.date) { day in
                LineMark(x: .value("Date", day.date), y: .value("Readiness", day.bodyBatteryScore))
                    .foregroundStyle(.teal).lineStyle(StrokeStyle(lineWidth: 2.5))
                PointMark(x: .value("Date", day.date), y: .value("Readiness", day.bodyBatteryScore))
                    .foregroundStyle(.teal).symbolSize(20)
            }
            .chartYScale(domain: 0...100)
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisValueLabel(format: .dateTime.month(.abbreviated).day()) } }
            .chartYAxis { AxisMarks(values: [0, 50, 100]) }
            .frame(height: 190)
            .accessibilityLabel("Readiness trend")
            .accessibilityValue("\(readings.count) days with data")
        }
    }

    @ViewBuilder private var loadChart: some View {
        let readings = aggregates.filter { $0.ctl.isFinite && $0.atl.isFinite }
        if readings.isEmpty {
            trendEmpty("Sync activities to see your training load trend.")
        } else {
            Chart(readings, id: \.date) { day in
                LineMark(x: .value("Date", day.date), y: .value("Load", day.ctl), series: .value("Trend", "Fitness"))
                    .foregroundStyle(by: .value("Trend", "Fitness")).lineStyle(StrokeStyle(lineWidth: 2))
                LineMark(x: .value("Date", day.date), y: .value("Load", day.atl), series: .value("Trend", "Fatigue"))
                    .foregroundStyle(by: .value("Trend", "Fatigue")).lineStyle(StrokeStyle(lineWidth: 2))
            }
            .chartForegroundStyleScale(["Fitness": Color.blue, "Fatigue": Color.orange])
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisValueLabel(format: .dateTime.month(.abbreviated).day()) } }
            .chartLegend(position: .bottom, alignment: .leading)
            .frame(height: 190)
            .accessibilityLabel("Training load trend")
        }
    }

    private func trendEmpty(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "chart.xyaxis.line").font(.title).foregroundStyle(.tertiary)
            Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 170)
    }
}
