//
//  ohMyTssApp.swift
//  ohMyTss
//
//  Created by Mingjun Liu on 11/7/25.
//

import SwiftUI
import SwiftData
import UIKit

@main
struct ohMyTssApp: App {
    @UIApplicationDelegateAdaptor(AppBackgroundDelegate.self) private var appDelegate
    @State private var storage: Result<ModelContainer, Error>?
    @State private var hasAttemptedOpen = false

    static func makeModelContainer() throws -> ModelContainer {
        let schema = Schema(AppSchema.models)
        var inMemory = false
        var testStoreURL: URL?
        #if DEBUG
        inMemory = ProcessInfo.processInfo.arguments.contains("--v2-ui-tests")
        if inMemory && ProcessInfo.processInfo.arguments.contains("--v2-disk-history") {
            inMemory = false
            testStoreURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("ohmytss-ui-\(UUID().uuidString).store")
        }
        #endif
        let modelConfiguration = testStoreURL.map { ModelConfiguration(schema: schema, url: $0) }
            ?? ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)

        let container = try ModelContainer(for: schema, configurations: [modelConfiguration])
        #if DEBUG
        if (inMemory || testStoreURL != nil) && ProcessInfo.processInfo.arguments.contains("--v2-large-history") {
            try LaunchHistoryFixture.seed(in: container, includeEstimates:
                !ProcessInfo.processInfo.arguments.contains("--v2-missing-estimates"),
                sourceAlreadyKnown: ProcessInfo.processInfo.arguments.contains("--v2-sync-fixture"))
        }
        if inMemory && ProcessInfo.processInfo.arguments.contains("--v2-rpe-demo") {
            try LaunchHistoryFixture.seedDashboard(in: container)
        }
        if inMemory && ProcessInfo.processInfo.arguments.contains("--v2-workout-map-demo") {
            try LaunchHistoryFixture.seedDashboard(in: container, includeMuscleRatings: false, includeStrengthSets: false)
        }
        #endif
        return container
    }

    var body: some Scene {
        WindowGroup {
            Group {
                switch storage {
                case .success(let container):
                    ContentView(engine: AppSyncRuntime.shared, dataStore: AppSyncRuntime.shared.dataStore)
                        .modelContainer(container)
                case .failure:
                    ContentUnavailableView {
                        Label("Saved data could not be opened", systemImage: "externaldrive.badge.exclamationmark")
                    } description: {
                        Text("Your saved data has been kept. Try again. If this continues, contact support before reinstalling the app.")
                    } actions: {
                        Button("Try Again") { storage = nil }
                            .accessibilityIdentifier("storage.retry")
                    }
                case nil:
                    ProgressView("Opening saved data…")
                        .task { openStorage() }
                }
            }
            .tint(SwissStyle.accent)
            .fontDesign(.default)
            .background(SwissStyle.canvas.ignoresSafeArea())
            #if DEBUG
            .modifier(SwissAccessibilityFixture())
            #endif
        }
    }

    private func openStorage() {
        #if DEBUG
        if !hasAttemptedOpen && ProcessInfo.processInfo.arguments.contains("--v2-ui-tests")
            && ProcessInfo.processInfo.arguments.contains("--v2-storage-failure-once") {
            hasAttemptedOpen = true
            storage = .failure(NSError(domain: "ohmytss.synthetic-storage-test", code: 1))
            return
        }
        #endif
        hasAttemptedOpen = true
        storage = Result { try AppSyncRuntime.shared.open() }
    }
}
