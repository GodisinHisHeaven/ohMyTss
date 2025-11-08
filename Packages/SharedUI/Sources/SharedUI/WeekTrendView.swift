import SwiftUI

/// Mini sparkline chart showing last 7 days of Body Battery scores
public struct WeekTrendView: View {
    public let scores: [Int]

    public init(scores: [Int]) {
        self.scores = scores
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Last 7 Days")
                .font(.headline)

            HStack(spacing: 4) {
                ForEach(Array(scores.enumerated()), id: \.offset) { index, score in
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(colorForScore(score))
                            .frame(width: 40, height: CGFloat(score) * 0.8)

                        Text("\(score)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(height: 100, alignment: .bottom)
                }
            }

            if let first = scores.first, let last = scores.last {
                let change = last - first
                let arrow = change >= 0 ? "↑" : "↓"
                Text("\(first) \(arrow) \(last)")
                    .font(.caption)
                    .foregroundStyle(change >= 0 ? .green : .red)
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }

    private func colorForScore(_ score: Int) -> Color {
        switch score {
        case 0..<20: return .zoneRecovery
        case 20..<40: return .zoneEasy
        case 40..<60: return .zoneModerate
        case 60..<80: return .zoneHard
        default: return .zonePeak
        }
    }
}

#Preview {
    WeekTrendView(scores: [45, 52, 48, 63, 71, 68, 75])
        .padding()
}
