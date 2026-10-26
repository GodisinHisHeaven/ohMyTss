//
//  BodyBatteryGauge.swift
//  onMyTss
//
//  Created by Claude Code
//

import SwiftUI

/// Circular gauge displaying Body Battery score (0-100) with a semantic accent
struct BodyBatteryGauge: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let score: Int
    let readinessLevel: ReadinessLevel

    var body: some View {
        ZStack {
            // Background circle
            Circle()
                .stroke(Color.gray.opacity(0.2), lineWidth: 20)

            // The label carries the meaning as well as color.
            Circle()
                .trim(from: 0, to: CGFloat(score) / 100.0)
                .stroke(
                    scoreColor,
                    style: StrokeStyle(lineWidth: 20, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: score)

            // Score text and label
            VStack(spacing: 4) {
                Text("\(score)")
                    .font(.system(size: 64, weight: .bold, design: .default))
                    .foregroundStyle(scoreColor)
                    .contentTransition(.numericText())

                Text("Battery")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    // MARK: - Computed Properties

    /// Color of the score number based on readiness level
    private var scoreColor: Color {
        switch readinessLevel {
        case .veryLow:
            return SwissStyle.critical
        case .low:
            return SwissStyle.caution
        case .medium:
            return SwissStyle.caution
        case .good:
            return SwissStyle.positive
        case .excellent:
            return SwissStyle.accent
        }
    }
}

// MARK: - Previews

#Preview("Excellent") {
    BodyBatteryGauge(score: 85, readinessLevel: .excellent)
        .frame(width: 200, height: 200)
        .padding()
}

#Preview("Good") {
    BodyBatteryGauge(score: 70, readinessLevel: .good)
        .frame(width: 200, height: 200)
        .padding()
}

#Preview("Medium") {
    BodyBatteryGauge(score: 50, readinessLevel: .medium)
        .frame(width: 200, height: 200)
        .padding()
}

#Preview("Low") {
    BodyBatteryGauge(score: 30, readinessLevel: .low)
        .frame(width: 200, height: 200)
        .padding()
}

#Preview("Very Low") {
    BodyBatteryGauge(score: 15, readinessLevel: .veryLow)
        .frame(width: 200, height: 200)
        .padding()
}
