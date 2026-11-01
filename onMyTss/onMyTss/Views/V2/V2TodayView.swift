import SwiftUI
import SwiftData

struct V2TodayView: View {
    let engine: any BodyBatteryEngineProtocol
    let dataStore: DataStore

    var body: some View {
        // Refresh time boundaries even when the app remains open overnight.
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            TodayDashboard(engine: engine, dataStore: dataStore, now: timeline.date)
        }
    }
}

private struct TodayDashboard: View {
    let engine: any BodyBatteryEngineProtocol
    let dataStore: DataStore
    let now: Date
    @Query private var workouts: [Workout]
    @Query private var intensitySources: [Workout]
    @Query private var muscleSources: [Workout]
    @Query private var days: [DayAggregate]
    @Query private var appStates: [AppState]
    @AppStorage("intensityLT1HeartRate") private var lt1 = 0
    @AppStorage("intensityLT2HeartRate") private var lt2 = 0
    @State private var strength = false
    @State private var reports = false
    @State private var syncing = false
    @State private var error: String?
    @State private var syncMessage: String?

    init(engine: any BodyBatteryEngineProtocol, dataStore: DataStore, now: Date) {
        self.engine = engine
        self.dataStore = dataStore
        self.now = now
        let cutoff = MuscleRPESummary.cutoff(for: now)
        // Duplicate source timestamps can differ by up to a minute.
        let sourceCutoff = MuscleRPESummary.sourceCutoff(for: now)
        let start = Calendar.current.startOfDay(for: now)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? now
        _workouts = Query(filter: #Predicate<Workout> {
            $0.startTime >= cutoff && $0.startTime < end && !$0.isTombstoned && !$0.isSuppressed
        }, sort: \.startTime, order: .reverse)
        _intensitySources = Query(filter: #Predicate<Workout> {
            $0.startTime >= sourceCutoff && $0.startTime < end && !$0.isTombstoned
        })
        // Source-deleted aliases may still own user-entered sets and tags.
        _muscleSources = Query(filter: #Predicate<Workout> {
            $0.startTime >= sourceCutoff && $0.startTime < end
        })
        _days = Query(filter: #Predicate<DayAggregate> { $0.date >= start && $0.date < end })
    }

    var body: some View {
        let currentNow = Date()
        let activeWorkouts = workouts.filter { $0.startTime <= currentNow }
        NavigationStack {
            SwissList {
                Section {
                    ReadinessCard(readiness: TodayReadiness(days: days,
                        lastComputation: appStates.first?.lastComputationDate, now: currentNow))
                    .padding(.vertical, 4)
                }
                Section {
                    MuscleRPECard(workouts: muscleSources, now: currentNow)
                        .padding(.vertical, 8)
                }
                Section {
                    IntensityDistributionCard(workouts: activeWorkouts, sources: intensitySources,
                                              lt1: lt1, lt2: lt2, now: now)
                        .padding(.vertical, 8)
                }
                Section {
                    if activeWorkouts.isEmpty {
                        Text("No workouts in the last 7 days").foregroundStyle(.secondary)
                    }
                    ForEach(Array(activeWorkouts.prefix(3))) { workout in
                        NavigationLink { V2ActivityDetailView(workout: workout) } label: {
                            WorkoutCategoryRow(type: workout.workoutType)
                        }
                        .accessibilityIdentifier("today.workout.\(workout.id)")
                    }
                    Button("Record strength", systemImage: "plus") { strength = true }
                        .swissAction()
                        .accessibilityIdentifier("today.strength")
                } header: {
                    SwissSectionHeading(number: "04", title: "Recent workouts")
                }
                if let message = error ?? syncMessage {
                    Section {
                        Text(message).font(.caption).foregroundStyle(error == nil ? Color.secondary : SwissStyle.caution)
                    }
                }
            }
            .navigationTitle("Today")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await sync() }
                    } label: {
                        if syncing { ProgressView() }
                        else { Label("Sync", systemImage: "arrow.clockwise") }
                    }
                    .disabled(syncing)
                    .accessibilityIdentifier("today.sync")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        NavigationLink("All activities") { V2ActivityHistoryView() }
                        Button("Discomfort reports") { reports = true }
                    } label: { Label("More", systemImage: "ellipsis.circle") }
                    .accessibilityIdentifier("today.more")
                }
            }
            .refreshable { await sync() }
            .sheet(isPresented: $strength) { StrengthSessionChooser() }
            .navigationDestination(isPresented: $reports) { ObservationHistoryView() }
            // Opening the dashboard does not start a whole-history backfill.
            // Sync and activity editing still maintain the stored load estimates.
        }
    }

    @MainActor private func sync() async {
        guard !syncing else { return }
        syncing = true
        error = nil
        defer { syncing = false }
        do {
            try await engine.recomputeAll()
            syncMessage = appStates.first?.lastSyncMessage ?? "Updated."
        } catch {
            self.error = "Sync unavailable. Saved records remain available."
        }
    }
}

private struct IntensityDistributionCard: View {
    let workouts: [Workout]
    let sources: [Workout]
    let lt1: Int
    let lt2: Int
    let now: Date
    @State private var completed: IntensityCalculationCompleted?
    @State private var generation = UUID()

    private var request: IntensityCalculationRequest {
        let activeIDs = Set(workouts.map(\.id))
        let inputs = sources.filter { $0.isSuppressed || activeIDs.contains($0.id) }.sorted { $0.id < $1.id }.map { workout in
            IntensityInputSnapshot(id: workout.id, linkedID: workout.linkedSessionID,
                isGarmin: WorkoutAggregator.isGarminSource(workout), isSuppressed: workout.isSuppressed,
                isDeleted: workout.isTombstoned, start: workout.startTime,
                duration: workout.duration, featuresData: workout.featuresData)
        }
        return IntensityCalculationRequest(sources: inputs, lt1: lt1, lt2: lt2,
            window: TimeRange(start: MuscleRPESummary.cutoff(for: now), end: now))
    }

    var body: some View {
        let request = request
        VStack(alignment: .leading, spacing: 12) {
            SwissSectionHeading(number: "03", title: "Training intensity")
            if !(30...240).contains(lt1) || !(30...240).contains(lt2) || lt1 >= lt2 {
                Text("LT1 / LT2 not set")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else if completed?.matches(request) != true {
                ProgressView()
            } else if let distribution = completed?.distribution {
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        Rectangle().fill(SwissStyle.positive)
                            .frame(width: geometry.size.width * distribution.lowSeconds / distribution.totalSeconds)
                        Rectangle().fill(SwissStyle.accent)
                            .frame(width: geometry.size.width * distribution.moderateSeconds / distribution.totalSeconds)
                        Rectangle().fill(SwissStyle.caution)
                            .frame(width: geometry.size.width * distribution.highSeconds / distribution.totalSeconds)
                    }
                    .clipShape(Capsule())
                }
                .frame(height: 10)
                .accessibilityHidden(true)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 8) {
                        intensityColumn("Below LT1", id: "low", color: SwissStyle.positive, seconds: distribution.lowSeconds, total: distribution.totalSeconds)
                        intensityColumn("LT1–LT2", id: "middle", color: SwissStyle.accent, seconds: distribution.moderateSeconds, total: distribution.totalSeconds)
                        intensityColumn("≥ LT2", id: "high", color: SwissStyle.caution, seconds: distribution.highSeconds, total: distribution.totalSeconds)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        intensityRow("Below LT1", id: "low", color: SwissStyle.positive, seconds: distribution.lowSeconds, total: distribution.totalSeconds)
                        intensityRow("LT1–LT2", id: "middle", color: SwissStyle.accent, seconds: distribution.moderateSeconds, total: distribution.totalSeconds)
                        intensityRow("≥ LT2", id: "high", color: SwissStyle.caution, seconds: distribution.highSeconds, total: distribution.totalSeconds)
                    }
                }
            } else {
                Text("No heart rate data")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
        .task(id: request) {
            let currentGeneration = UUID()
            generation = currentGeneration
            guard request.hasValidThresholds else { completed = nil; return }
            let worker = Task.detached(priority: .userInitiated) { try request.calculate() }
            do {
                let distribution = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard !Task.isCancelled, generation == currentGeneration else { return }
                completed = IntensityCalculationCompleted(request: request, distribution: distribution)
            } catch {
                // A canceled or superseded calculation never replaces a newer result.
            }
        }
    }

    private func intensityColumn(_ title: String, id: String, color: Color, seconds: Double, total: Double) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(seconds / total, format: .percent.precision(.fractionLength(0)))
                .font(.title3.weight(.medium)).monospacedDigit()
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 7, height: 7).accessibilityHidden(true)
                Text(title).font(.caption).fixedSize()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("today.intensity.\(id)")
    }

    private func intensityRow(_ title: String, id: String, color: Color, seconds: Double, total: Double) -> some View {
        HStack {
            Circle().fill(color).frame(width: 8, height: 8).accessibilityHidden(true)
            Text(title)
            Spacer()
            Text(seconds / total, format: .percent.precision(.fractionLength(0)))
                .monospacedDigit()
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("today.intensity.\(id)")
    }

}

/// Immutable snapshots keep SwiftData and JSON decoding on their respective actors.
nonisolated struct IntensityInputSnapshot: Equatable, Sendable {
    let id: String
    let linkedID: String?
    let isGarmin: Bool
    let isSuppressed: Bool
    let isDeleted: Bool
    let start: Date
    let duration: TimeInterval
    let featuresData: Data?
}

nonisolated struct IntensityCalculationResult: Equatable, Sendable {
    let lowSeconds: Double
    let moderateSeconds: Double
    let highSeconds: Double
    var totalSeconds: Double { lowSeconds + moderateSeconds + highSeconds }
}

nonisolated struct IntensityCalculationRequest: Equatable, Sendable {
    let sources: [IntensityInputSnapshot]
    let lt1: Int
    let lt2: Int
    let window: TimeRange

    var hasValidThresholds: Bool { (30...240).contains(lt1) && (30...240).contains(lt2) && lt1 < lt2 }

    func calculate() throws -> IntensityCalculationResult? {
        try Task.checkCancellation()
        let decoder = JSONDecoder()
        var inputs: [IntensitySource] = []
        inputs.reserveCapacity(sources.count)
        for source in sources {
            try Task.checkCancellation()
            let features = source.featuresData.flatMap { try? decoder.decode(WorkoutFeatures.self, from: $0) } ?? WorkoutFeatures()
            inputs.append(IntensitySource(id: source.id, linkedID: source.linkedID,
                isGarmin: source.isGarmin, isSuppressed: source.isSuppressed, isDeleted: source.isDeleted,
                workout: IntensityWorkout(start: source.start,
                    end: features.end ?? source.start.addingTimeInterval(source.duration),
                    heartRate: features.heartRate, pauses: features.pauses)))
        }
        try Task.checkCancellation()
        let result = IntensityDistribution.calculate(sources: inputs, lt1: lt1, lt2: lt2, window: window)
        try Task.checkCancellation()
        return result.map { IntensityCalculationResult(lowSeconds: $0.lowSeconds,
            moderateSeconds: $0.moderateSeconds, highSeconds: $0.highSeconds) }
    }
}

nonisolated struct IntensityCalculationCompleted: Equatable, Sendable {
    let request: IntensityCalculationRequest
    let distribution: IntensityCalculationResult?
    func matches(_ current: IntensityCalculationRequest) -> Bool { request == current }
}

struct WorkoutCategoryRow: View {
    let type: String
    var body: some View {
        let category = WorkoutCategory(type: type)
        Label {
            Text(category.rawValue).font(.subheadline.weight(.medium))
        } icon: {
            Image(systemName: category.icon).font(.body.weight(.regular))
                .foregroundStyle(SwissStyle.accent).frame(width: 28)
        }
        .padding(.vertical, 8)
        .accessibilityIdentifier("workout.category")
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
        SwissList {
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
        SwissList {
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
