//
//  BodyBatteryGauge.swift
//  onMyTss
//
//  Created by Claude Code
//

import SwiftUI

/// Circular gauge displaying Body Battery score (0-100) with color gradient
struct BodyBatteryGauge: View {
    let score: Int
    let readinessLevel: ReadinessLevel

    var body: some View {
        ZStack {
            // Background circle
            Circle()
                .stroke(Color.gray.opacity(0.2), lineWidth: 20)

            // Progress arc with gradient
            Circle()
                .trim(from: 0, to: CGFloat(score) / 100.0)
                .stroke(
                    gradient,
                    style: StrokeStyle(lineWidth: 20, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.8), value: score)

            // Score text and label
            VStack(spacing: 4) {
                Text("\(score)")
                    .font(.system(size: 64, weight: .bold, design: .rounded))
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

    /// Color gradient from red (low) to blue (high)
    private var gradient: AngularGradient {
        AngularGradient(
            colors: [
                Color(hex: "#E53E3E"),  // Red (0-20)
                Color(hex: "#DD6B20"),  // Orange (20-40)
                Color(hex: "#D69E2E"),  // Yellow (40-60)
                Color(hex: "#38A169"),  // Green (60-80)
                Color(hex: "#3182CE")   // Blue (80-100)
            ],
            center: .center,
            startAngle: .degrees(-90),
            endAngle: .degrees(270)
        )
    }

    /// Color of the score number based on readiness level
    private var scoreColor: Color {
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
