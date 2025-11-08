import SwiftUI

/// Circular gauge displaying Body Battery score (0-100)
public struct BodyBatteryGauge: View {
    public let score: Int
    public let zoneColor: Color

    public init(score: Int, zoneColor: Color) {
        self.score = score
        self.zoneColor = zoneColor
    }

    public var body: some View {
        ZStack {
            // Background circle
            Circle()
                .stroke(Color.gray.opacity(0.2), lineWidth: 20)

            // Progress arc
            Circle()
                .trim(from: 0, to: CGFloat(score) / 100.0)
                .stroke(
                    gradient,
                    style: StrokeStyle(lineWidth: 20, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.5), value: score)

            // Score text
            VStack(spacing: 4) {
                Text("\(score)")
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                    .foregroundColor(zoneColor)

                Text("Battery")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var gradient: AngularGradient {
        AngularGradient(
            colors: [
                Color(hex: "#E53E3E"),  // Red
                Color(hex: "#DD6B20"),  // Orange
                Color(hex: "#D69E2E"),  // Yellow
                Color(hex: "#38A169"),  // Green
                Color(hex: "#3182CE")   // Blue
            ],
            center: .center,
            startAngle: .degrees(-90),
            endAngle: .degrees(270)
        )
    }
}

#Preview {
    VStack(spacing: 40) {
        BodyBatteryGauge(score: 25, zoneColor: .red)
            .frame(width: 200, height: 200)

        BodyBatteryGauge(score: 75, zoneColor: .green)
            .frame(width: 200, height: 200)
    }
    .padding()
}
