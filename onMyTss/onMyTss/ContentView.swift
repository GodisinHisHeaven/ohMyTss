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
    @State private var engine: BodyBatteryEngine?
    @State private var dataStore: DataStore?

    var body: some View {
        Group {
            if isLoading {
                // Loading state
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.5)

                    Text("Loading Body Battery...")
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

                    // After onboarding, trigger initial data sync
                    Task {
                        if let engine = engine {
                            try? await engine.recomputeAll()
                        }
                    }
                }
            }
        }
        .task {
            await initializeApp()
        }
    }

    private func initializeApp() async {
        // Initialize services
        let store = DataStore(modelContext: modelContext)
        dataStore = store

        let healthKitManager = HealthKitManager()
        let bodyBatteryEngine = BodyBatteryEngine(healthKitManager: healthKitManager, dataStore: store)
        engine = bodyBatteryEngine

        // Check onboarding status
        do {
            let thresholds = try store.fetchUserThresholds()
            hasCompletedOnboarding = thresholds.hasCompletedOnboarding

            // If onboarding is completed, perform automatic data refresh
            if hasCompletedOnboarding {
                // Try incremental update first (faster)
                do {
                    try await bodyBatteryEngine.incrementalUpdate()
                } catch {
                    // If incremental fails, it's not critical - user can manually refresh
                    print("Incremental update failed: \(error.localizedDescription)")
                }
            }
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
