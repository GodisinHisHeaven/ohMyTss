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
    @Query private var days: [DayAggregate]
    @Query private var appStates: [AppState]
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
        let start = Calendar.current.startOfDay(for: now)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? now
        _workouts = Query(filter: #Predicate<Workout> {
            $0.startTime >= cutoff && $0.startTime < end && !$0.isTombstoned && !$0.isSuppressed
        }, sort: \.startTime, order: .reverse)
        _days = Query(filter: #Predicate<DayAggregate> { $0.date >= start && $0.date < end })
    }

    var body: some View {
        let currentNow = Date()
        let activeWorkouts = workouts.filter { $0.startTime <= currentNow }
        NavigationStack {
            List {
                Section {
                    ReadinessCard(readiness: TodayReadiness(days: days,
                        lastComputation: appStates.first?.lastComputationDate, now: currentNow))
                    .padding(.vertical, 4)
                }
                Section {
                    MuscleRPECard(workouts: activeWorkouts, now: currentNow)
                        .padding(.vertical, 8)
                }
                Section("Recent workouts") {
                    if activeWorkouts.isEmpty {
                        Text("No workouts in the last 7 days").foregroundStyle(.secondary)
                    }
                    ForEach(Array(activeWorkouts.prefix(3))) { workout in
                        NavigationLink { V2ActivityDetailView(workout: workout) } label: {
                            WorkoutCategoryRow(type: workout.workoutType)
                        }
                    }
                    Button("Record strength", systemImage: "plus") { strength = true }
                        .accessibilityIdentifier("today.strength")
                }
                if let message = error ?? syncMessage {
                    Section {
                        Text(message).font(.caption).foregroundStyle(error == nil ? Color.secondary : .orange)
                    }
                }
            }
            .listSectionSpacing(18)
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

struct WorkoutCategoryRow: View {
    let type: String
    var body: some View {
        let category = WorkoutCategory(type: type)
        Label(category.rawValue, systemImage: category.icon)
            .font(.subheadline.weight(.medium))
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
