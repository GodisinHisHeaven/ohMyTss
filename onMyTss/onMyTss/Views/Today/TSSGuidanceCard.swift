//
//  TSSGuidanceCard.swift
//  onMyTss
//
//  Created by Claude Code
//

import SwiftUI

/// Card displaying daily training recommendations
struct TSSGuidanceCard: View {
    let recommendation: TSSRecommendation
    let readinessLevel: ReadinessLevel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Text("Today's Training")
                    .font(.headline)
                    .foregroundStyle(.primary)

                Spacer()

                // Intensity badge
                Text(recommendation.intensity.rawValue.uppercased())
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(intensityColor.opacity(0.2))
                    .foregroundStyle(intensityColor)
                    .clipShape(Capsule())
            }

            Divider()

            // Recommended TSS Range
            VStack(alignment: .leading, spacing: 8) {
                Text("Suggested TSS")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(recommendation.optimal)")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(intensityColor)

                    Text("(\(recommendation.min)-\(recommendation.max))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                // Visual range indicator
                TSSRangeBar(
                    min: recommendation.min,
                    optimal: recommendation.optimal,
                    max: recommendation.max,
                    color: intensityColor
                )
                .frame(height: 8)
            }

            // Description
            Text(recommendation.description)
                .font(.body)
                .foregroundStyle(.secondary)
                .lineLimit(2, reservesSpace: true)

            // Readiness indicator
            HStack(spacing: 6) {
                Text(readinessLevel.emoji)
                    .font(.title3)

                Text(readinessLevel.rawValue)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(uiColor: .systemBackground))
                .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: 5)
        )
    }

    // MARK: - Computed Properties

    private var intensityColor: Color {
        switch recommendation.intensity {
        case .recovery:
            return Color(hex: "#E53E3E") // Red
        case .endurance:
            return Color(hex: "#38A169") // Green
        case .tempo:
            return Color(hex: "#D69E2E") // Yellow
        case .threshold:
            return Color(hex: "#3182CE") // Blue
        case .vo2Max:
            return Color(hex: "#9F7AEA") // Purple
        }
    }
}

// MARK: - TSS Range Bar

struct TSSRangeBar: View {
    let min: Int
    let optimal: Int
    let max: Int
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Background
                RoundedRectangle(cornerRadius: 4)
                    .fill(color.opacity(0.2))

                // Range indicator
                RoundedRectangle(cornerRadius: 4)
                    .fill(color.opacity(0.4))
                    .frame(width: geometry.size.width)

                // Optimal marker
                Circle()
                    .fill(color)
                    .frame(width: 12, height: 12)
                    .position(x: optimalPosition(width: geometry.size.width), y: geometry.size.height / 2)
            }
        }
    }

    private func optimalPosition(width: CGFloat) -> CGFloat {
        // Position the optimal marker within the range
        guard max > min else { return width / 2 }

        let range = CGFloat(max - min)
        let optimalOffset = CGFloat(optimal - min)
        let percentage = optimalOffset / range

        return width * percentage
    }
}

// MARK: - Previews

#Preview("Excellent") {
    TSSGuidanceCard(
        recommendation: TSSRecommendation(
            min: 100,
            max: 150,
            optimal: 125,
            description: "Perfect for high-intensity or long workouts.",
            intensity: .threshold
        ),
        readinessLevel: .excellent
    )
    .padding()
}

#Preview("Good") {
    TSSGuidanceCard(
        recommendation: TSSRecommendation(
            min: 80,
            max: 130,
            optimal: 110,
            description: "Good day for base building endurance work.",
            intensity: .endurance
        ),
        readinessLevel: .good
    )
    .padding()
}

#Preview("Medium") {
    TSSGuidanceCard(
        recommendation: TSSRecommendation(
            min: 60,
            max: 100,
            optimal: 80,
            description: "Moderate training to maintain fitness.",
            intensity: .tempo
        ),
        readinessLevel: .medium
    )
    .padding()
}

#Preview("Low") {
    TSSGuidanceCard(
        recommendation: TSSRecommendation(
            min: 30,
            max: 60,
            optimal: 45,
            description: "Easy recovery rides/runs recommended.",
            intensity: .endurance
        ),
        readinessLevel: .low
    )
    .padding()
}

#Preview("Very Low") {
    TSSGuidanceCard(
        recommendation: TSSRecommendation(
            min: 0,
            max: 30,
            optimal: 15,
            description: "Focus on recovery. Very light activity only.",
            intensity: .recovery
        ),
        readinessLevel: .veryLow
    )
    .padding()
}
