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

    var body: some View {
        Group {
            if isLoading {
                // Loading state
                ProgressView()
            } else if hasCompletedOnboarding {
                // Main app
                Text("Main App - Today View")
                    .font(.title)
            } else {
                // Onboarding
                OnboardingContainerView {
                    hasCompletedOnboarding = true
                }
            }
        }
        .task {
            await checkOnboardingStatus()
        }
    }

    private func checkOnboardingStatus() async {
        let dataStore = DataStore(modelContext: modelContext)

        do {
            let thresholds = try dataStore.fetchUserThresholds()
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
