import SwiftUI
import SwiftData

struct V2TodayView: View {
    let engine: any BodyBatteryEngineProtocol
    let dataStore: DataStore
    @Environment(\.modelContext) private var context
    @Query(sort: \Workout.startTime, order: .reverse) private var workouts: [Workout]
    @Query(sort: \LoadEstimateRecord.computedAt, order: .reverse) private var estimates: [LoadEstimateRecord]
    @Query(sort: \LocalObservation.observedAt, order: .reverse) private var observations: [LocalObservation]
    @Query private var appStates: [AppState]
    @State private var selectedRegion: Region?
    @State private var strength = false
    @State private var syncing = false
    @State private var error: String?
    @State private var syncMessage: String?
    @State private var nextSport = "None"

    init(engine: any BodyBatteryEngineProtocol, dataStore: DataStore) {
        self.engine = engine
        self.dataStore = dataStore
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        // Today only displays recent estimates. Backfilling older sessions must
        // not change this query's result and rerender the entire home screen.
        _estimates = Query(filter: #Predicate<LoadEstimateRecord> { $0.inputCutoff >= cutoff },
                           sort: \LoadEstimateRecord.computedAt, order: .reverse)
    }

    var body: some View {
        let summary = V2TodaySummary(workouts: workouts, estimates: estimates, observations: observations)
        return NavigationStack {
            List {
                Section("Quick check-in") {
                    BodyMapView(observations: observations) { selectedRegion = $0 }
                    NavigationLink("Report history") { ObservationHistoryView() }
                }
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Cardio Load", systemImage: "heart.text.square").font(.title2.bold())
                        cardioSummary(summary)
                        Text("Estimated cardiovascular demand from timed heart rate. Legacy TSS remains in History.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }
                Section("Regional context") {
                    Text("Highest activity grade in the last 7 days, shown separately for each method. Reports with recent discomfort appear first. Recovery time cannot yet be estimated.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(summary.prioritizedRegions) { region in
                        NavigationLink { RegionDetailView(region: region) } label: { regionRow(region, summary: summary) }
                    }
                }
                Section("Strength training") {
                    Button("Record or supplement a session", systemImage: "dumbbell") { strength = true }
                        .accessibilityIdentifier("today.strength")
                }
                Section("Activities") {
                    if summary.activeWorkouts.isEmpty {
                        Text("No activities available. Sync Apple Health or connected Strava, or record strength training here.")
                        Text("No readable Health data may mean no records or a permission choice. Manual reports work offline.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(Array(summary.activeWorkouts.prefix(5))) { workout in
                        NavigationLink { V2ActivityDetailView(workout: workout) } label: {
                            V2WorkoutRow(workout: workout)
                        }
                    }
                    NavigationLink("All activities") { V2ActivityHistoryView() }
                }
                Section("Next activity · optional") {
                    Picker("Considering", selection: $nextSport) {
                        ForEach(["None", "Run", "Ride", "Swim", "Strength"], id: \.self) { Text($0) }
                    }
                    if nextSport != "None" {
                        Text(nextActivityContext).font(.caption).foregroundStyle(.secondary)
                        Text("Review those regions and your reports above. This is context, not a training prescription.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button {
                        Task { await sync() }
                    } label: {
                        if syncing { ProgressView("Syncing…") }
                        else { Label("Sync activities", systemImage: "arrow.clockwise") }
                    }
                    .disabled(syncing)
                    .accessibilityIdentifier("today.sync")
                    if let message = syncMessage ?? appStates.first?.lastSyncMessage {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                    if let error { V2ErrorMessage(message: error) }
                }
            }
            .navigationTitle("Today")
            .refreshable { await sync() }
            .sheet(item: $selectedRegion) { ObservationEditor(region: $0) }
            .sheet(isPresented: $strength) { StrengthSessionChooser() }
            .task {
                // Add v2 estimates to legacy records without replacing their stored TSS.
                do {
                    try await V2Store(context: context).backfillEstimates()
                } catch is CancellationError {
                    // Leaving Today pauses backfill; saved progress is reused next time.
                } catch { self.error = error.localizedDescription }
            }
        }
    }

    @ViewBuilder private func cardioSummary(_ summary: V2TodaySummary) -> some View {
        let measured = summary.cardio
        if summary.todayCount == 0 {
            Text("No activity recorded today").font(.headline)
            Text("Cardio demand is not estimated yet.").font(.subheadline).foregroundStyle(.secondary)
        } else if measured.isEmpty {
            Text("Unknown").font(.title.bold())
            Text("Timed heart rate or a personal maximum heart rate is missing.")
                .font(.subheadline).foregroundStyle(.secondary)
        } else {
            let methods = Array(Set(measured.map(\.method))).sorted()
            if methods.count == 1 {
                let points = measured.reduce(0) { $0 + $1.points }
                Text(LoadModel.cardioLevel(points)).font(.title.bold())
                Text("\(points, specifier: "%.1f") observed zone-min today").font(.subheadline)
            } else {
                Text("Multiple estimation methods").font(.headline)
                Text("Open each activity for its method and observed load; unlike methods are not totalled.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("\(measured.count) of \(summary.todayCount) activities have an estimate. Unobserved intervals are excluded.")
                .font(.caption).foregroundStyle(.secondary)
            if measured.contains(where: { $0.coverage < 0.8 }) {
                Text("Partial heart-rate coverage: the displayed load covers observed intervals only.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(methods, id: \.self) { Text($0).font(.caption2).foregroundStyle(.secondary) }
        }
    }

    private func regionRow(_ region: Region, summary: V2TodaySummary) -> some View {
        let summaries = summary.regionalSummaries[region] ?? []
        let latestReports = summary.reports[region] ?? []
        return VStack(alignment: .leading, spacing: 4) {
            Text(region.label).font(.headline)
            if summaries.isEmpty {
                Text("Model: no recent estimate").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(summaries) { summary in
                HStack {
                    Text("Model · \(summary.method.components(separatedBy: " ").first ?? summary.method): \(summary.level)")
                    Spacer()
                }
                .font(.caption).foregroundStyle(V2Presentation.color(summary.level))
                Text("\(summary.unit) · \(V2Presentation.coverage(summary.coverage))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if latestReports.isEmpty {
                Text("You: not reported").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(latestReports) { report in
                Text("You · \(report.sideRaw.capitalized): \(V2Presentation.observation(report))").font(.caption)
                Text(report.observedAt, format: .dateTime.month().day().hour().minute())
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var nextActivityContext: String {
        switch nextSport {
        case "Run", "Ride": return "Commonly involved: front and back thighs, glutes, calves and core. Actual involvement depends on the session."
        case "Swim": return "Commonly involved: shoulders, back, arms and core; legs depend on stroke and equipment."
        default: return "Involvement depends on the exercises you choose. Open a region to review recent training and reports."
        }
    }

    @MainActor private func sync() async {
        guard !syncing else { return }
        syncing = true
        error = nil
        defer { syncing = false }
        do {
            try await engine.recomputeAll()
            syncMessage = appStates.first?.lastSyncMessage ?? "Sync finished. No readable records can also reflect permissions."
        } catch {
            self.error = "Sync unavailable. Saved records remain available. \(error.localizedDescription)"
        }
    }
}

struct V2WorkoutRow: View {
    let workout: Workout
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(workout.workoutType).font(.headline)
            Text(workout.startTime, format: .dateTime.month().day().hour().minute()).font(.caption)
            Text("\(Int(workout.duration / 60)) min · \(workout.source)").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct V2ActivityHistoryView: View {
    @Query(sort: \Workout.startTime, order: .reverse) private var workouts: [Workout]
    var body: some View {
        List {
            ForEach(workouts.filter { !$0.isSuppressed && !$0.isTombstoned }) { workout in
                NavigationLink { V2ActivityDetailView(workout: workout) } label: { V2WorkoutRow(workout: workout) }
            }
            NavigationLink("Archived and linked activities") { V2ArchivedActivitiesView() }
        }
        .overlay {
            if workouts.isEmpty {
                ContentUnavailableView("No activities", systemImage: "figure.run", description: Text("Import activities or record a strength session from Today."))
            }
        }
        .navigationTitle("Activities")
    }
}


struct V2ArchivedActivitiesView: View {
    @Query(sort: \Workout.startTime, order: .reverse) private var workouts: [Workout]
    var body: some View {
        List {
            Text("These source records are excluded from totals. Retained sets, reports and estimates remain available for review.")
                .font(.caption).foregroundStyle(.secondary)
            let archived = workouts.filter { $0.isTombstoned || $0.isSuppressed }
            if archived.isEmpty { Text("No archived or linked records").foregroundStyle(.secondary) }
            ForEach(archived) { workout in
                NavigationLink { V2ActivityDetailView(workout: workout) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        V2WorkoutRow(workout: workout)
                        Text(workout.isTombstoned ? "Removed from totals" : "Linked source")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Archived activities")
    }
}
