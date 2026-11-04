import SwiftUI
import SwiftData

struct RegionDetailView: View {
    let region: Region
    @Query(sort: \Workout.startTime, order: .reverse) private var workouts: [Workout]
    @Query(sort: \LoadEstimateRecord.computedAt, order: .reverse) private var estimates: [LoadEstimateRecord]
    @Query(sort: \LocalObservation.observedAt, order: .reverse) private var observations: [LocalObservation]
    @State private var recording = false
    @State private var editing: LocalObservation?

    private struct Contribution: Identifiable {
        var workout: Workout
        var estimate: RegionalEstimate
        var id: String { "\(workout.id):\(estimate.id)" }
    }

    private var contributions: [Contribution] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        let recent = workouts.filter { !$0.isSuppressed && !$0.isTombstoned && $0.startTime >= cutoff }
        let latest = Self.latestEstimates(for: Set(recent.map(\.id)), in: estimates)
        return recent.flatMap { workout -> [Contribution] in
            guard let estimate = latest[workout.id]?.value else { return [] }
            return estimate.regions.filter { $0.region == region }.map { Contribution(workout: workout, estimate: $0) }
        }
    }

    /// The query is ordered by computedAt descending. Keep its first record
    /// for each requested session, including records with invalid payloads.
    static func latestEstimates(for sessionIDs: Set<String>, in ordered: [LoadEstimateRecord]) -> [String: LoadEstimateRecord] {
        guard !sessionIDs.isEmpty else { return [:] }
        var latest: [String: LoadEstimateRecord] = [:]
        for estimate in ordered where sessionIDs.contains(estimate.sessionID) && latest[estimate.sessionID] == nil {
            latest[estimate.sessionID] = estimate
            if latest.count == sessionIDs.count { break }
        }
        return latest
    }

    var body: some View {
        let contributions = contributions
        SwissList {
            Section("Estimated burden · last 7 days") {
                Text("These are activity-specific proxies, not measured muscle force or damage. No left/right difference is inferred.")
                    .font(.caption).foregroundStyle(.secondary)
                if contributions.isEmpty {
                    Text("No regional estimate available. This does not establish zero burden.").foregroundStyle(.secondary)
                }
                ForEach(contributions) { contribution in
                    let workout = contribution.workout
                    let estimate = contribution.estimate
                    NavigationLink {
                        V2ActivityDetailView(workout: workout)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(workout.workoutType) · \(estimate.level)").font(.headline)
                            Text(workout.startTime, format: .dateTime.month().day().hour().minute())
                                .font(.caption)
                            Text("\(estimate.exposure, specifier: "%.1f") \(estimate.unit)").font(.caption)
                            ForEach(Array(estimate.reasons.enumerated()), id: \.offset) { _, reason in
                                Text(reason).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            Section("Your reports · independent observations") {
                Button("Record how it feels") { recording = true }
                let matching = observations.filter { $0.regionRaw == region.rawValue }
                if matching.isEmpty { Text("Not reported").foregroundStyle(.secondary) }
                ForEach(matching) { observation in
                    Button { editing = observation } label: { V2ObservationRow(observation: observation) }
                        .foregroundStyle(.primary)
                }
            }
            Section("Recovery") {
                Text("Time until your usual feeling returns: not yet estimable.")
                Text("Recent training burden and reported symptoms are separate observations. Changes in soreness do not demonstrate tissue repair or safety for the next hard session.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(region.label)
        .sheet(isPresented: $recording) { ObservationEditor(region: region) }
        .sheet(item: $editing) { ObservationEditor(existing: $0) }
    }
}
