import SwiftUI

/// Presentation helpers never infer missing feedback or a recovery state.
enum V2Presentation {
    static func coverage(_ fraction: Double) -> String {
        if fraction >= 0.8 { return "Good data coverage" }
        if fraction > 0 { return "Partial data coverage" }
        return "Limited data"
    }

    static func color(_ level: String) -> Color {
        switch level.lowercased() {
        case "high": return SwissStyle.caution
        case "moderate": return SwissStyle.accent
        case "low": return SwissStyle.positive
        default: return .secondary
        }
    }

    static func observation(_ value: LocalObservation) -> String {
        if value.discomfortRaw == "none" { return "No noticeable discomfort" }
        let kind = DiscomfortKind(rawValue: value.discomfortRaw)?.label ?? value.discomfortRaw.capitalized
        let severity = value.severity.map { " · \($0)/4" } ?? " · Severity not recorded"
        let extras = [value.weakness ? "Weakness" : nil, value.tightness ? "Tightness" : nil,
                      value.limitedMovement ? "Limited movement" : nil].compactMap { $0 }
        return kind + severity + (extras.isEmpty ? "" : " · " + extras.joined(separator: ", "))
    }

    static func exerciseName(_ id: String) -> String {
        ExerciseCatalog.exercises.first { $0.id == id }?.name ?? "Custom regional exercise"
    }
}

struct V2ErrorMessage: View {
    let message: String
    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.callout)
            .foregroundStyle(SwissStyle.caution)
            .accessibilityIdentifier("v2.error")
    }
}

struct V2ObservationRow: View {
    let observation: LocalObservation
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(Region(rawValue: observation.regionRaw)?.label ?? observation.regionRaw) · \(observation.sideRaw.capitalized)")
                .font(.headline)
            Text(V2Presentation.observation(observation)).font(.subheadline)
            Text(observation.observedAt, format: .dateTime.month().day().hour().minute())
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct V2EstimateView: View {
    let estimate: LoadEstimateValue
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let cardio = estimate.cardio {
                Text("Cardio Load · \(cardio.level)").font(.headline)
                Text("\(cardio.points, specifier: "%.1f") zone-min · \(V2Presentation.coverage(cardio.coverage))")
                    .font(.subheadline)
                Text(cardio.method).font(.caption).foregroundStyle(.secondary)
                ForEach(Array(cardio.reasons.enumerated()), id: \.offset) { _, reason in
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Cardio Load · Unknown").font(.headline)
                Text("No reliable timed heart-rate estimate. Missing data does not mean no load.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(estimate.regions) { regional in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(regional.region.label)
                        Spacer()
                        Text(regional.level).foregroundStyle(V2Presentation.color(regional.level))
                    }
                    Text("\(regional.exposure, specifier: "%.1f") \(regional.unit) · \(V2Presentation.coverage(regional.coverage))")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(Array(regional.reasons.enumerated()), id: \.offset) { _, reason in
                        Text(reason).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            ForEach(Array(estimate.reasons.enumerated()), id: \.offset) { _, reason in
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
            Text("Model \(estimate.version) · Measurement cutoff \(estimate.inputCutoff.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption2).foregroundStyle(.secondary)
            Text("Computed with information available at \(estimate.computedAt.formatted(date: .abbreviated, time: .shortened)). Later edits are not historical predictions.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}
