//
//  ContentView.swift
//  onMyTss
//
//  Created by Mingjun Liu on 11/7/25.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var hasCompletedOnboarding = false
    @State private var isLoading = true
    @State private var engine: (any BodyBatteryEngineProtocol)?
    @State private var dataStore: DataStore?
    @State private var historyRepairPending = false
    @State private var historyRepairRunning = false
    @Environment(\.scenePhase) private var scenePhase
    @Query private var appStates: [AppState]

    init(engine: (any BodyBatteryEngineProtocol)? = nil, dataStore: DataStore? = nil) {
        _engine = State(initialValue: engine)
        _dataStore = State(initialValue: dataStore)
    }

    var body: some View {
        Group {
            if isLoading {
                // Loading state
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.5)

                    Text("Loading Training History...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else if hasCompletedOnboarding, let engine = engine, let dataStore = dataStore {
                // Main app - Tab View with Today, History, Settings
                MainTabView(engine: engine, dataStore: dataStore)
            } else {
                // Onboarding
                OnboardingContainerView {
                    hasCompletedOnboarding = true

                    Task { await repairLocalHistory() }

                    // Today exposes explicit Sync; manual recording is immediately available offline.
                }
            }
        }
        .safeAreaInset(edge: .top) {
            if !isLoading && hasCompletedOnboarding && historyRepairPending {
                HStack(spacing: 8) {
                    Text(historyRepairRunning
                         ? "Updating history. Some training totals may be inaccurate."
                         : "History update incomplete. Some training totals may be inaccurate.")
                        .font(.caption)
                    if !historyRepairRunning {
                        Button("Retry") { Task { await repairLocalHistory(recoverSources: true) } }
                            .accessibilityIdentifier("history.repair.retry")
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity)
                .background(.thinMaterial)
                .accessibilityIdentifier("history.repair.status")
            }
        }
        .task {
            await initializeApp()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && historyRepairPending && !isLoading {
                Task { await repairLocalHistory() }
            }
        }
        .onChange(of: appStates.first?.isComputationInProgress) { _, inProgress in
            if inProgress == true { historyRepairPending = true }
            if inProgress == false && historyRepairPending && !isLoading {
                Task { await repairLocalHistory() }
            }
        }
        .onChange(of: appStates.first?.pendingWorkoutSourceFinalization) { _, pending in
            if pending == true { historyRepairPending = true }
            if pending == false && historyRepairPending && !isLoading {
                Task { await repairLocalHistory() }
            }
        }
    }

    private func initializeApp() async {
        // Initialize services
        let store = dataStore ?? DataStore(modelContext: modelContext)
        dataStore = store

        var healthKitManager = HealthKitManager()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--v2-ui-tests")
            && ProcessInfo.processInfo.arguments.contains("--v2-sync-fixture") {
            healthKitManager = ActivitySyncUIFixture()
        }
        #endif
        if engine == nil {
            engine = BodyBatteryEngine(healthKitManager: healthKitManager, dataStore: store)
        }

        // Check onboarding status
        do {
            let thresholds = try store.fetchUserThresholds()
            hasCompletedOnboarding = thresholds.hasCompletedOnboarding
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--v2-ui-tests") {
                // App selects isolated storage for this exact test-only flag.
                let completed = !ProcessInfo.processInfo.arguments.contains("--swiss-onboarding")
                thresholds.hasCompletedOnboarding = completed
                hasCompletedOnboarding = completed
            }
            #endif

            // Open saved data immediately. The dashboard reads a bounded window;
            // Sync maintains derived training history when explicitly requested.
        } catch {
            // If error fetching, assume not completed
            hasCompletedOnboarding = false
        }

        // Expose saved data without waiting for network access. The warning
        // remains visible until all local derived data has been rebuilt.
        if hasCompletedOnboarding {
            historyRepairPending = true
        }
        isLoading = false
        if hasCompletedOnboarding { await repairLocalHistory() }
    }

    private func repairLocalHistory(recoverSources: Bool = false) async {
        guard hasCompletedOnboarding, !historyRepairRunning else { return }
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--v2-ui-tests") && !arguments.contains("--v2-history-repair-fixture") {
            historyRepairPending = false
            return
        }
        #endif
        historyRepairPending = true
        historyRepairRunning = true
        defer { historyRepairRunning = false }
        do {
            let performRepair: @MainActor () async throws -> Void = {
                if let runtime = engine as? AppSyncRuntime {
                    try await runtime.repairLocalWorkoutHistoryIfNeeded()
                } else if let concrete = engine as? BodyBatteryEngine {
                    try await concrete.repairLocalWorkoutHistoryIfNeeded()
                }
            }
            if recoverSources, let dataStore, let engine {
                let state = try dataStore.fetchAppState()
                try await LocalWorkoutHistoryRepair.retry(state: state, isProcessing: { engine.isProcessing }, synchronize: {
                    try await engine.incrementalUpdate()
                }, repair: performRepair)
            } else {
                try await performRepair()
            }
            if let dataStore {
                let state = try dataStore.fetchAppState()
                historyRepairPending = state.localWorkoutRepairInProgress ||
                    state.localWorkoutRepairVersion < LocalWorkoutHistoryRepair.currentVersion ||
                    state.isComputationInProgress || state.pendingWorkoutSourceFinalization
            } else {
                historyRepairPending = false
            }
        } catch {
            // Keep the warning and persisted retry marker; saved history is
            // still available while source recovery or local repair is retried.
            historyRepairPending = true
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [UserThresholds.self, DayAggregate.self, AppState.self])
}
