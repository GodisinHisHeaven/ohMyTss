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
    let engine: any BodyBatteryEngineProtocol
    let dataStore: DataStore
    @Environment(\.scenePhase) private var scenePhase
    @Query private var appStates: [AppState]
    @State private var morningSync = MorningSummarySync()

    @State private var selectedTab: Tab = .today

    enum Tab {
        case today
        case history
        case settings
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            // Today Tab
            V2TodayView(engine: engine, dataStore: dataStore)
                .tabItem {
                    Label("Today", systemImage: "heart.text.square")
                }
                .tag(Tab.today)

            // History Tab
            HistoryView()
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
        .background(WeeklyWorkoutObserver())
        .task(id: MorningSyncTrigger(isActive: scenePhase == .active, computedAt: appStates.first?.lastComputationDate)) {
            await syncMorningSummaryIfActive()
        }
    }

    private func syncMorningSummaryIfActive() async {
        guard scenePhase == .active else { return }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--v2-ui-tests") { return }
        #endif
        await morningSync.sync(store: dataStore)
    }
}

private struct MorningSyncTrigger: Equatable {
    let isActive: Bool
    let computedAt: Date?
}

// MARK: - Previews

#Preview {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: Schema(AppSchema.models), configurations: config)
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
