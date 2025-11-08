//
//  MainTabView.swift
//  onMyTss
//
//  Created by Claude Code
//

import SwiftUI
import SwiftData

/// Main tab view containing Today, History, and Settings screens
struct MainTabView: View {
    let engine: BodyBatteryEngine
    let dataStore: DataStore

    @State private var selectedTab: Tab = .today

    enum Tab {
        case today
        case history
        case settings
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            // Today Tab
            TodayView(engine: engine, dataStore: dataStore)
                .tabItem {
                    Label("Today", systemImage: "battery.75")
                }
                .tag(Tab.today)

            // History Tab
            HistoryView(dataStore: dataStore)
                .tabItem {
                    Label("History", systemImage: "chart.xyaxis.line")
                }
                .tag(Tab.history)

            // Settings Tab
            SettingsView(dataStore: dataStore, engine: engine)
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
                .tag(Tab.settings)
        }
    }
}

// MARK: - Previews

#Preview {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: DayAggregate.self, UserThresholds.self, AppState.self, configurations: config)
    let dataStore = DataStore(modelContainer: container)

    // Create sample data
    let today = Date().startOfDay
    let aggregate = DayAggregate(
        date: today,
        totalTSS: 120,
        ctl: 85,
        atl: 95,
        tsb: -10,
        bodyBatteryScore: 65,
        rampRate: 3.5,
        workoutCount: 1,
        maxTSSWorkout: 120
    )
    try! dataStore.saveDayAggregate(aggregate)

    var thresholds = UserThresholds()
    thresholds.cyclingFTP = 250
    thresholds.hasCompletedOnboarding = true
    try! dataStore.saveUserThresholds(thresholds)

    let healthKitManager = HealthKitManager()
    let engine = BodyBatteryEngine(healthKitManager: healthKitManager, dataStore: dataStore)

    return MainTabView(engine: engine, dataStore: dataStore)
        .modelContainer(container)
}
