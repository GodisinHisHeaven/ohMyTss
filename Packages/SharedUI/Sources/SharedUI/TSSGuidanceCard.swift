import SwiftUI

/// Card displaying suggested TSS range and guidance text
public struct TSSGuidanceCard: View {
    public let tssRange: ClosedRange<Double>
    public let description: String

    public init(tssRange: ClosedRange<Double>, description: String) {
        self.tssRange = tssRange
        self.description = description
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Suggested Training")
                .font(.headline)

            HStack {
                Image(systemName: "figure.run")
                    .foregroundStyle(.blue)

                Text("\(Int(tssRange.lowerBound))-\(Int(tssRange.upperBound)) TSS")
                    .font(.title2.bold())
            }

            Text(description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
}

#Preview {
    VStack(spacing: 20) {
        TSSGuidanceCard(
            tssRange: 80...110,
            description: "Good day for hard training. Threshold and VO2max efforts."
        )

        TSSGuidanceCard(
            tssRange: 0...40,
            description: "Focus on rest and recovery. Keep intensity very low."
        )
    }
    .padding()
}
