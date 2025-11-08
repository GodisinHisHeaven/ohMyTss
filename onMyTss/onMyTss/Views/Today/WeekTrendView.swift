//
//  WeekTrendView.swift
//  onMyTss
//
//  Created by Claude Code
//

import SwiftUI

/// 7-day mini chart showing Body Battery score trend
struct WeekTrendView: View {
    let scores: [DayScore]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Text("7-Day Trend")
                    .font(.headline)
                    .foregroundStyle(.primary)

                Spacer()

                if let trend = calculateTrend() {
                    HStack(spacing: 4) {
                        Text(trend.arrow)
                            .font(.caption)

                        Text(trend.rawValue)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Chart
            if scores.isEmpty {
                // Empty state
                VStack(spacing: 8) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.title2)
                        .foregroundStyle(.secondary)

                    Text("No data yet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 100)
                .background(Color(uiColor: .secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                // Sparkline chart
                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(Array(scores.enumerated()), id: \.element.date) { index, dayScore in
                        VStack(spacing: 4) {
                            // Bar
                            BarView(
                                score: dayScore.score,
                                maxScore: 100,
                                isToday: index == scores.count - 1
                            )

                            // Day label
                            Text(dayOfWeek(dayScore.date))
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 80)

                // Score change indicator
                if scores.count >= 2 {
                    let previousScore = scores[scores.count - 2].score
                    let currentScore = scores[scores.count - 1].score
                    let change = currentScore - previousScore

                    HStack(spacing: 4) {
                        Image(systemName: changeIcon(change))
                            .font(.caption)
                            .foregroundStyle(changeColor(change))

                        Text(changeText(change))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(uiColor: .systemBackground))
                .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: 5)
        )
    }

    // MARK: - Helper Functions

    private func calculateTrend() -> Trend? {
        guard scores.count >= 3 else { return nil }
        let scoreValues = scores.map { $0.score }
        return BodyBatteryCalculator.calculateTrend(scores: scoreValues)
    }

    private func dayOfWeek(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"
        return formatter.string(from: date)
    }

    private func changeIcon(_ change: Int) -> String {
        if change > 0 {
            return "arrow.up.circle.fill"
        } else if change < 0 {
            return "arrow.down.circle.fill"
        } else {
            return "minus.circle.fill"
        }
    }

    private func changeColor(_ change: Int) -> Color {
        if change > 0 {
            return .green
        } else if change < 0 {
            return .red
        } else {
            return .gray
        }
    }

    private func changeText(_ change: Int) -> String {
        if change > 0 {
            return "+\(change) from yesterday"
        } else if change < 0 {
            return "\(change) from yesterday"
        } else {
            return "No change from yesterday"
        }
    }
}

// MARK: - Bar View

struct BarView: View {
    let score: Int
    let maxScore: Int
    let isToday: Bool

    var body: some View {
        VStack(spacing: 2) {
            Spacer()

            // Bar
            RoundedRectangle(cornerRadius: 3)
                .fill(barColor)
                .frame(height: barHeight)
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(isToday ? Color.primary : Color.clear, lineWidth: 2)
                )

            // Score label
            if isToday {
                Text("\(score)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.primary)
            }
        }
    }

    private var barHeight: CGFloat {
        let percentage = CGFloat(score) / CGFloat(maxScore)
        return max(percentage * 60, 4) // Minimum height of 4
    }

    private var barColor: Color {
        let readinessLevel = BodyBatteryCalculator.getReadinessLevel(score: score)

        switch readinessLevel {
        case .veryLow:
            return Color(hex: "#E53E3E")
        case .low:
            return Color(hex: "#DD6B20")
        case .medium:
            return Color(hex: "#D69E2E")
        case .good:
            return Color(hex: "#38A169")
        case .excellent:
            return Color(hex: "#3182CE")
        }
    }
}

// MARK: - Day Score Model

struct DayScore: Identifiable {
    let id = UUID()
    let date: Date
    let score: Int
}

// MARK: - Previews

#Preview("With Data") {
    WeekTrendView(scores: [
        DayScore(date: Date().addingTimeInterval(-6 * 86400), score: 45),
        DayScore(date: Date().addingTimeInterval(-5 * 86400), score: 52),
        DayScore(date: Date().addingTimeInterval(-4 * 86400), score: 58),
        DayScore(date: Date().addingTimeInterval(-3 * 86400), score: 65),
        DayScore(date: Date().addingTimeInterval(-2 * 86400), score: 72),
        DayScore(date: Date().addingTimeInterval(-1 * 86400), score: 68),
        DayScore(date: Date(), score: 78)
    ])
    .padding()
}

#Preview("Declining") {
    WeekTrendView(scores: [
        DayScore(date: Date().addingTimeInterval(-6 * 86400), score: 85),
        DayScore(date: Date().addingTimeInterval(-5 * 86400), score: 78),
        DayScore(date: Date().addingTimeInterval(-4 * 86400), score: 70),
        DayScore(date: Date().addingTimeInterval(-3 * 86400), score: 62),
        DayScore(date: Date().addingTimeInterval(-2 * 86400), score: 55),
        DayScore(date: Date().addingTimeInterval(-1 * 86400), score: 48),
        DayScore(date: Date(), score: 42)
    ])
    .padding()
}

#Preview("Empty") {
    WeekTrendView(scores: [])
        .padding()
}

#Preview("Single Day") {
    WeekTrendView(scores: [
        DayScore(date: Date(), score: 75)
    ])
    .padding()
}
