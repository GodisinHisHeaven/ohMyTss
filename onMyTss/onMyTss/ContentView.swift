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

                    // Today exposes explicit Sync; manual recording is immediately available offline.
                }
            }
        }
        .task {
            await initializeApp()
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

        isLoading = false
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [UserThresholds.self, DayAggregate.self, AppState.self])
}
