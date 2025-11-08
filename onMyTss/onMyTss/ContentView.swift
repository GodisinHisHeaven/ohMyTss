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
                ProgressView()
            } else if hasCompletedOnboarding, let engine = engine, let dataStore = dataStore {
                // Main app - Today View
                TodayView(engine: engine, dataStore: dataStore)
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
        engine = BodyBatteryEngine(healthKitManager: healthKitManager, dataStore: store)

        // Check onboarding status
        do {
            let thresholds = try store.fetchUserThresholds()
            hasCompletedOnboarding = thresholds.hasCompletedOnboarding
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
