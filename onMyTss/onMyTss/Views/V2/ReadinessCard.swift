import SwiftUI

struct ReadinessCard: View {
    let readiness: TodayReadiness
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .largeTitle) private var scoreSize = 64
    @State private var showingInfo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SwissSectionHeading(number: "01", title: "Today's readiness")
                Spacer()
                Button("About readiness", systemImage: "info.circle") { showingInfo = true }
                    .labelStyle(.iconOnly).foregroundStyle(.secondary)
                    .frame(minWidth: 44, minHeight: 44)
                    .buttonStyle(.borderless)
            }
            if let score = readiness.score {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 8) {
                        scoreNumber(score)
                        Text(level(score)).font(.headline).foregroundStyle(color(score))
                    }
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        scoreNumber(score)
                        Spacer(minLength: 8)
                        Text(level(score)).font(.subheadline.weight(.medium)).foregroundStyle(color(score))
                    }
                }
                ProgressView(value: Double(score), total: 100).tint(color(score)).accessibilityHidden(true)
                Text(readiness.basis).font(.caption).foregroundStyle(.secondary)
                if let updatedAt = readiness.updatedAt {
                    Text("Updated \(updatedAt, format: .dateTime.hour().minute())")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                Text("Not enough data yet").font(.title3.weight(.semibold))
                    .accessibilityIdentifier("readiness.empty")
                Text("Sync today's health data to see your readiness.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $showingInfo) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("Your saved readiness estimate").font(.title2.bold())
                        Text("The score combines training load with HRV and resting heart rate when their baselines are available. It is separate from your muscle RPE ratings.")
                        if let hours = readiness.day?.sleepDuration, hours.isFinite, hours >= 0, hours <= 24 {
                            Text("Last night's sleep: \(hours, specifier: "%.1f") hours.")
                            Text("Sleep is shown for context and is not currently included in this score.").foregroundStyle(.secondary)
                        }
                        Text("An estimate can help you review how you feel; it does not establish readiness for a particular workout.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(24)
                }
                .swissCanvas()
                .navigationTitle("Readiness").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingInfo = false } } }
            }
            .presentationDetents([.medium, .large])
        }
    }

    private func scoreNumber(_ score: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(score)").font(.system(size: scoreSize, weight: .regular, design: .default)).monospacedDigit()
                .accessibilityIdentifier("readiness.score")
            Text("/ 100").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func level(_ score: Int) -> String {
        switch score { case ..<40: return "Low"; case ..<60: return "Moderate"; case ..<80: return "Good"; default: return "High" }
    }

    private func color(_ score: Int) -> Color {
        switch score { case ..<40: return SwissStyle.caution; case ..<60: return SwissStyle.accent; default: return SwissStyle.positive }
    }
}
